#!/usr/bin/env bash
# Registry host: pull ONLY the blobs v9 actually reads out of the restored
# artifact volume, with enough concurrency to work around a lazy-loading restore,
# and verify every one against its own digest.
#
# Why this exists. PRE-REGISTRATION-v9 s1.3 planned to use Fast Snapshot Restore
# so the restored volume would read at gp3 speed. FSR reached "enabled" and the
# volume created 57 s later came back with FastRestored=None: an FSR snapshot-AZ
# registration starts with an EMPTY credit bucket, and for a 1200 GiB snapshot
# that bucket holds ONE credit and refills at ~0.85/hour. So the volume lazy-loads
# from S3 exactly as v8's E0 measured, and this host has to work around it.
#
# The workaround is concurrency, because a lazy-loading restore is latency-bound,
# not bandwidth-bound: measured on this volume, 1 reader = 61 MB/s, 16 = 208 MB/s,
# 64 = 339 MB/s. So each blob is copied as parallel byte ranges.
#
# Correctness is not taken on trust: a registry blob's filename IS the sha256 of
# its content, so every copied blob is re-hashed and compared. A chunked parallel
# copy that got a range wrong cannot survive that check.
set -euo pipefail
SRC=/artifacts/registry/docker/registry/v2
DST=/data/registry/docker/registry/v2
PAR="${PAR:-64}"              # concurrent ranges
CHUNK="${CHUNK:-$((256*1024*1024))}"
WANT_TAGS="${WANT_TAGS:-estargz-140g}"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Detect the restored volume by model+size and create the mount point.
# NVMe enumeration is NOT stable across launches -- v5's F1, and the reason
# 00-registry-host-setup.sh detects by model rather than by name. Hardcoding
# /dev/nvme2n1 worked on the first rig and broke on the rebuild, which is
# exactly the failure mode that comment warns about.
if ! sudo mountpoint -q /artifacts; then
  ART=""
  root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
  for d in /sys/block/nvme*n1; do
    [ -e "$d" ] || continue
    b=$(basename "$d"); [ "$b" = "${root_disk}" ] && continue
    m=$(cat "$d/device/model" 2>/dev/null || true)
    sz=$(cat "$d/size" 2>/dev/null || echo 0)
    case "$m" in *"Elastic Block Store"*) [ "${sz}" -gt 209715200 ] && ART="/dev/$b";; esac
  done
  [ -n "${ART}" ] || { echo "FATAL: no restored artifact volume found"; lsblk; exit 1; }
  echo "artifact volume = ${ART}"
  sudo mkdir -p /artifacts
  sudo mount -o ro "${ART}" /artifacts || { echo "FATAL: cannot mount ${ART}"; exit 1; }
fi

log "copying the repositories metadata tree (small files)"
sudo mkdir -p "${DST}/repositories"
sudo cp -a -n "${SRC}/repositories/." "${DST}/repositories/" 2>/dev/null || true

blobpath() { echo "$1/blobs/sha256/${2:7:2}/${2:7}/data"; }

copy_blob() { # copy_blob <digest>
  local d="$1" s t sz have
  s="$(blobpath "${SRC}" "${d}")"; t="$(blobpath "${DST}" "${d}")"
  [ -f "${s}" ] || { log "  MISSING in restored store: ${d}"; return 1; }
  sz=$(sudo stat -c %s "${s}")
  have=$(sudo stat -c %s "${t}" 2>/dev/null || echo 0)
  if [ "${have}" = "${sz}" ]; then log "  present ${d:7:12} ($(( sz/1000000 )) MB) -- skip"; return 0; fi
  log "  copying ${d:7:12} $(( sz/1000000 )) MB with ${PAR}-way range concurrency"
  sudo mkdir -p "$(dirname "${t}")"
  sudo truncate -s "${sz}" "${t}"
  local n=$(( (sz + CHUNK - 1) / CHUNK ))
  # The offset arithmetic has to happen in the CHILD shell: an xargs -I{} token
  # inside $(( )) would be evaluated by this shell, before {} is ever substituted.
  seq 0 $(( n - 1 )) | xargs -P "${PAR}" -I{} sh -c '
      i="$1"
      sudo dd if="$2" of="$3" bs="$4" count="$4" \
        skip=$(( i * $4 )) seek=$(( i * $4 )) \
        iflag=skip_bytes,count_bytes oflag=seek_bytes conv=notrunc status=none
    ' _ {} "${s}" "${t}" "${CHUNK}" \
    || { log "  copy failed for ${d}"; return 1; }
  return 0
}

DIGESTS=()
for tag in ${WANT_TAGS}; do
  link=$(sudo cat "${DST}/repositories/model-ballast/_manifests/tags/${tag}/current/link" 2>/dev/null || true)
  [ -n "${link}" ] || { log "no tag link for ${tag}"; continue; }
  log "tag ${tag} -> ${link}"
  copy_blob "${link}" || true                     # the manifest (or index) itself
  # An OCI index points at per-platform manifests; both shapes are handled.
  subs=$(sudo cat "$(blobpath "${DST}" "${link}")" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for m in d.get("manifests",[]): print(m["digest"])' 2>/dev/null || true)
  for s in ${subs}; do copy_blob "${s}" || true; done
  for m in ${link} ${subs}; do
    ds=$(sudo cat "$(blobpath "${DST}" "${m}")" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for l in d.get("layers",[]): print(l["digest"])
if "config" in d: print(d["config"]["digest"])' 2>/dev/null || true)
    for x in ${ds}; do DIGESTS+=("${x}"); done
  done
done

# de-duplicate
mapfile -t DIGESTS < <(printf '%s\n' "${DIGESTS[@]}" | sort -u)
log "${#DIGESTS[@]} content blobs to ensure"
T0=$(date +%s)
for d in "${DIGESTS[@]}"; do copy_blob "${d}" || exit 1; done
T1=$(date +%s)
log "copy stage done in $(( T1 - T0 ))s"

log "verifying every blob against its own digest (a blob's name IS its sha256)"
FAIL=0
for d in "${DIGESTS[@]}"; do
  t="$(blobpath "${DST}" "${d}")"
  got=$(sudo sha256sum "${t}" | cut -d' ' -f1)
  if [ "sha256:${got}" = "${d}" ]; then echo "  OK   ${d:7:16}"
  else echo "  BAD  ${d:7:16} -> sha256:${got}"; FAIL=1; fi
done
[ "${FAIL}" = "0" ] || { log "DIGEST VERIFICATION FAILED -- refusing to serve this store"; exit 1; }
log "all ${#DIGESTS[@]} blobs verified"

sudo docker restart registry >/dev/null
for i in $(seq 1 30); do curl -sf http://localhost:5000/v2/_catalog >/dev/null && break; sleep 2; done
echo "--- tags ---"; curl -sf http://localhost:5000/v2/model-ballast/tags/list; echo
for t in estargz-140g estargz-20g; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "http://localhost:5000/v2/model-ballast/manifests/${t}")
  echo "manifest ${t}: HTTP ${code}"
done
sudo umount /artifacts 2>/dev/null || true
echo "BLOB FETCH OK"
