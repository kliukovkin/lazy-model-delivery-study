#!/usr/bin/env bash
# v8 E0: does the artifact snapshot actually save a rebuild?
#
# The first use of snap-0118cc5716e9e8a54 as a working rig. If this fails, v7's
# central operational lesson is wrong and that is the headline result, not a
# footnote.
#
# Run ON THE REGISTRY HOST.
set -euo pipefail
cd "$(dirname "$0")"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
OUT=../results/e0; mkdir -p "${OUT}"

log "=== what came back on the restored volume ==="
{ cat /data/DATA-DEVICE.txt 2>/dev/null
  df -h /data | tail -1
  echo "--- artifacts ---"
  sudo du -sh /data/registry 2>/dev/null
  ls /data 2>/dev/null | tr '\n' ' '; echo
} | tee "${OUT}/restored-volume.txt"

log "=== starting the registry against the restored blob store ==="
sudo systemctl restart docker 2>/dev/null || true
if ! curl -sf http://localhost:5000/v2/ >/dev/null 2>&1; then
  docker rm -f registry >/dev/null 2>&1 || true
  docker run -d --restart=always --name registry -p 5000:5000 \
    -v /data/registry:/var/lib/registry registry:2 >/dev/null
  sleep 5
fi

log "=== E0.1: do all four tags resolve? ==="
ACC='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
# NOT inside a `{ ... } | tee` pipeline: that runs in a subshell, so the counter
# increments never reach the outer shell and the check reads 0 however many tags
# actually resolved. Write the file first, then count from it.
{
  curl -s http://localhost:5000/v2/model-ballast/tags/list; echo
  for t in estargz-140g estargz-14g B-140g B-14g; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "${ACC}" "http://localhost:5000/v2/model-ballast/manifests/${t}")
    echo "${t}: ${code}"
  done
} > "${OUT}/tags.txt"
ok=$(grep -cE '^(estargz|B)-[0-9]+g: 200$' "${OUT}/tags.txt" || true)
echo "tags_resolving=${ok}/4" >> "${OUT}/tags.txt"
cat "${OUT}/tags.txt"
[ "${ok}" = "4" ] || { log "FATAL: only ${ok}/4 tags resolve from the restored registry"; exit 1; }

log "=== pre-warming the blobs this spike will actually read ==="
# A snapshot-backed volume loads blocks lazily from S3, and uninitialised reads
# are SLOW: measured at 15 MB/s with four concurrent `cat`s, and 177 MB/s with
# fio at iodepth=64. The difference is latency, not bandwidth, so the fix is
# concurrency.
#
# And scope: v8 reads only estargz-140g. The gzip variants B-140g and B-14g are
# roughly half the 309 GB blob store and no experiment touches them, so warming
# them would be minutes spent on blocks nothing will read. Resolve the manifest,
# take its layer digests, and warm exactly those.
ACC2='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json'
BLOBDIR=/data/registry/docker/registry/v2/blobs/sha256
digests() {
  local ref="$1"
  local body; body=$(curl -s -H "${ACC2}" "http://localhost:5000/v2/model-ballast/manifests/${ref}")
  # index -> manifests -> layers; follow one level when it is an index.
  echo "${body}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
out=[]
if "manifests" in d: out=[m["digest"] for m in d["manifests"]]
for l in d.get("layers",[]): out.append(l["digest"])
print("\n".join(out))' 2>/dev/null
}
{
  for d in $(digests estargz-140g); do echo "$d"; done
  for sub in $(digests estargz-140g); do
    h=${sub#sha256:}; f="${BLOBDIR}/${h:0:2}/${h}/data"
    [ -f "$f" ] || continue
    python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for l in d.get("layers",[]): print(l["digest"])
except Exception: pass' "$f" 2>/dev/null
  done
} | sort -u > /tmp/warm-digests.txt
n=$(grep -c . /tmp/warm-digests.txt || true)
log "estargz-140g references ${n} blobs"

t0=$(date +%s)
awk '{h=substr($0,8); printf "/data/registry/docker/registry/v2/blobs/sha256/%s/%s/data\n", substr(h,1,2), h}' /tmp/warm-digests.txt \
  | while read -r f; do [ -f "$f" ] && echo "$f"; done \
  | xargs -P 48 -n 1 -I{} dd if={} of=/dev/null bs=4M status=none 2>/dev/null || true
sync
t1=$(date +%s)
WB=$(awk '{h=substr($0,8); printf "/data/registry/docker/registry/v2/blobs/sha256/%s/%s/data\n", substr(h,1,2), h}' /tmp/warm-digests.txt | while read -r f; do [ -f "$f" ] && stat -c %s "$f"; done | awk '{s+=$1} END{print s+0}')
{ echo "prewarm_scope=blobs referenced by estargz-140g only"
  echo "prewarm_blobs=${n}"
  echo "prewarm_bytes=${WB}"
  echo "prewarm_seconds=$((t1-t0))"
  echo "prewarm_MBps=$(awk -v b="${WB}" -v s="$((t1-t0))" 'BEGIN{if(s>0) printf "%.0f", b/s/1e6; else print "na"}')"
  echo "prewarm_finished_utc=$(date -u +%FT%TZ)"; } | tee "${OUT}/prewarm.txt"
log "pre-warm complete in $((t1-t0))s"
log "E0 done -> ${OUT}"
