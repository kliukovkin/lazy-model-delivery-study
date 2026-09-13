#!/usr/bin/env bash
# V9-A, registry side: the refetch evidence.
#
#   41-v9a-regcap.sh digests            -- record which blobs belong to A and to B
#   41-v9a-regcap.sh begin <rep>        -- mark the log position at the start of a rep
#   41-v9a-regcap.sh end   <rep>        -- cut the rep's slice and total it per blob
#
# A's refetches are counted as BYTES THE REGISTRY SERVED FOR A'S BLOB DIGESTS.
# That is only an unambiguous measure because V9-A gives A its own image
# (estargz-20g) with its own blobs -- with a shared image and disjoint file
# ranges, as v8's E2 used, a GET tells you nothing about which tenant caused it.
set -euo pipefail
OUT="${OUT:-/data/v9a}"; mkdir -p "${OUT}"
REG="localhost:5000"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

blobs_of() { # blobs_of <tag>
  curl -sf -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "http://${REG}/v2/model-ballast/manifests/$1" \
  | python3 -c '
import json,sys,urllib.request
d=json.load(sys.stdin)
def emit(m):
    for l in m.get("layers",[]): print(l["digest"], l.get("size",0))
    if "config" in m: print(m["config"]["digest"], m["config"].get("size",0))
if "manifests" in d:
    for sub in d["manifests"]:
        with urllib.request.urlopen(urllib.request.Request(
            "http://'"${REG}"'/v2/model-ballast/manifests/"+sub["digest"],
            headers={"Accept": sub["mediaType"]})) as r:
            emit(json.load(r))
else:
    emit(d)'
}

case "${1:?digests|begin|end}" in
digests)
  for t in estargz-20g estargz-140g; do
    blobs_of "${t}" > "${OUT}/blobs-${t}.txt" || true
    echo "${t}: $(wc -l < "${OUT}/blobs-${t}.txt") blobs, $(awk '{s+=$2} END{printf "%.1f GB", s/1e9}' "${OUT}/blobs-${t}.txt")"
  done
  # A blob shared between the two images would break the attribution outright,
  # so check rather than assume.
  common=$(comm -12 <(awk '{print $1}' "${OUT}/blobs-estargz-20g.txt" | sort) \
                    <(awk '{print $1}' "${OUT}/blobs-estargz-140g.txt" | sort) | wc -l)
  echo "blobs_shared_between_A_and_B=${common}" | tee "${OUT}/blob-disjointness.txt"
  # Both images are FROM busybox:1.36, so one small base layer is expected to be
  # shared. That is handled, not ignored: the `end` stage attributes refetch to
  # blobs UNIQUE to A and reports the shared layer on its own line.
  if [ "${common}" -gt 0 ]; then
    echo "NOTE: A and B share ${common} blob(s); attribution uses A-unique blobs only:" >&2
    comm -12 <(sort "${OUT}/blobs-estargz-20g.txt") <(sort "${OUT}/blobs-estargz-140g.txt") >&2
  fi
  ;;
begin)
  R="${OUT}/rep${2:?rep}"; mkdir -p "${R}"
  sudo docker logs registry 2>&1 | wc -l > "${R}/reglog-offset.txt"
  echo "begin_utc=$(date -u +%FT%T.%3NZ)" > "${R}/window.txt"
  log "rep ${2}: registry log offset $(cat "${R}/reglog-offset.txt")"
  ;;
end)
  R="${OUT}/rep${2:?rep}"
  echo "end_utc=$(date -u +%FT%T.%3NZ)" >> "${R}/window.txt"
  sudo docker logs registry 2>&1 | tail -n +"$(( $(cat "${R}/reglog-offset.txt") + 1 ))" > "${R}/registry-access.log" || true
  python3 - "${R}/registry-access.log" "${OUT}/blobs-estargz-20g.txt" "${OUT}/blobs-estargz-140g.txt" \
    > "${R}/refetch.txt" <<'PY'
import re, sys, collections, datetime
logp, ap, bp = sys.argv[1], sys.argv[2], sys.argv[3]
Araw = {l.split()[0] for l in open(ap) if l.strip()}
B = {l.split()[0] for l in open(bp) if l.strip()}
# A and B are both FROM busybox:1.36, so they share the 2.28 MB base layer --
# 0.01% of A's data, but a GET on it cannot be attributed to either tenant.
# Attribution therefore uses blobs UNIQUE to A; the shared blob is reported
# separately rather than silently folded into A or silently dropped.
SHARED = Araw & B
A = Araw - B
rows = []
for line in open(logp, errors="replace"):
    u = re.search(r'http\.request\.uri="([^"]+)"', line)
    w = re.search(r'http\.response\.written=(\d+)', line)
    t = re.search(r'time="([^"]+)"', line)
    if not (u and w):
        continue
    m = re.search(r'/blobs/(sha256:[0-9a-f]+)', u.group(1))
    if not m:
        continue
    d = m.group(1)
    who = "A" if d in A else ("shared-base" if d in SHARED else ("B" if d in B else "other"))
    ts = None
    if t:
        try:
            ts = datetime.datetime.fromisoformat(t.group(1).replace("Z", "+00:00")).timestamp()
        except ValueError:
            ts = None
    rows.append((ts, who, d, int(w.group(1))))
byt = collections.Counter(); cnt = collections.Counter()
for _, who, _, n in rows:
    byt[who] += n; cnt[who] += 1
print("registry blob traffic in this repetition's window")
print("%-8s %10s %16s %12s" % ("tenant", "requests", "bytes", "GB"))
for who in ("A", "shared-base", "B", "other"):
    print("%-8s %10d %16d %12.3f" % (who, cnt[who], byt[who], byt[who] / 1e9))
print()
print("A_bytes=%d" % byt["A"])
print("A_requests=%d" % cnt["A"])
print("A_unique_blobs=%d" % len(A))
print("shared_base_bytes=%d" % byt["shared-base"])
# The per-request timeline for A is what lets the report say WHEN A refetched.
ts = [r for r in rows if r[1] == "A" and r[0]]
if ts:
    print("A_first_ts=%.3f" % min(r[0] for r in ts))
    print("A_last_ts=%.3f" % max(r[0] for r in ts))
    with open(sys.argv[1] + ".a-timeline.csv", "w") as f:
        f.write("ts_epoch,bytes\n")
        for r in sorted(ts):
            f.write("%.3f,%d\n" % (r[0], r[3]))
PY
  cat "${R}/refetch.txt"
  ;;
esac
