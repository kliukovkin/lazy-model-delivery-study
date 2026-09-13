#!/usr/bin/env bash
# Registry host: fold the v7 artifact snapshot's blob store into the LIVE
# registry, which serves from the NVMe instance store.
#
# Why not just mount the restored volume at /data and serve from it, as v8 did?
# PRE-REGISTRATION-v9 s1.3. Two reasons, both measured rather than assumed:
# v8's E0 clocked the snapshot's lazy load from S3 at 14-48 MB/s, and even fully
# warmed the volume is gp3 at 750 MB/s -- which sits BELOW the registry NIC that
# V9-B's clause (iii) is about. Serving from the 1.7 TB instance store puts the
# disk ceiling far above the NIC ceiling, so V9-B measures the thing it names.
#
# Fast Snapshot Restore is what makes the copy itself cheap: without it this read
# is the same 14 MB/s v8 paid three hours for.
#
# The merge is safe because registry:2's blob store is content-addressed: blobs
# live at .../blobs/sha256/<ab>/<digest>/data and repository metadata is a tree
# of per-tag directories, so copying the restored tree over the live one adds the
# 140g/14g tags without touching the 20g one built here. -n (no-clobber) so an
# identical blob already present is never rewritten.
set -euo pipefail
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
SRC_MNT=/artifacts
LIVE=/data/registry

DEV=""
for d in /sys/block/nvme*n1; do
  b=$(basename "$d")
  m=$(cat "$d/device/model" 2>/dev/null || true)
  sz=$(cat "$d/size" 2>/dev/null || echo 0)
  root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
  [ "$b" = "${root_disk}" ] && continue
  case "$m" in *"Elastic Block Store"*) [ "${sz}" -gt 209715200 ] && DEV="/dev/$b";; esac
done
[ -n "${DEV}" ] || { echo "FATAL: no restored EBS artifact volume found"; lsblk; exit 1; }
log "artifact volume = ${DEV}"
sudo blkid "${DEV}" || { echo "FATAL: no filesystem on ${DEV} -- refusing to touch it"; exit 1; }
mountpoint -q "${SRC_MNT}" || { sudo mkdir -p "${SRC_MNT}"; sudo mount -o ro "${DEV}" "${SRC_MNT}"; }
df -h "${SRC_MNT}" | tail -1
[ -d "${SRC_MNT}/registry/docker/registry/v2" ] || { echo "FATAL: ${SRC_MNT}/registry is not a registry:2 store"; ls "${SRC_MNT}"; exit 1; }

log "restored store holds: $(sudo du -sh "${SRC_MNT}/registry" 2>/dev/null | awk '{print $1}')"
log "copying restored blob store -> ${LIVE} (no-clobber)"
t0=$(date +%s)
sudo mkdir -p "${LIVE}"
sudo cp -a -n "${SRC_MNT}/registry/." "${LIVE}/"
t1=$(date +%s)
log "copy done in $(( t1 - t0 ))s; live store now $(sudo du -sh "${LIVE}" | awk '{print $1}')"

log "restarting the registry so it re-reads the store"
sudo docker restart registry >/dev/null
for i in $(seq 1 30); do curl -sf http://localhost:5000/v2/_catalog >/dev/null && break; sleep 2; done

echo "--- catalog ---"; curl -sf http://localhost:5000/v2/_catalog; echo
echo "--- model-ballast tags ---"; curl -sf http://localhost:5000/v2/model-ballast/tags/list; echo
FAIL=0
for t in estargz-140g estargz-20g; do
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "http://localhost:5000/v2/model-ballast/manifests/${t}")
  echo "manifest ${t}: HTTP ${code}"
  [ "${code}" = "200" ] || FAIL=1
done
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' "http://localhost:5000/v2/custom-predictor/manifests/v5")
echo "manifest custom-predictor:v5: HTTP ${code}"
[ "${code}" = "200" ] || FAIL=1

# A manifest nobody has read a byte through is a belief, not an artifact (v7
# rule 2 applied to the merge): pull one real blob range back.
D=$(curl -sf -H 'Accept: application/vnd.oci.image.index.v1+json' http://localhost:5000/v2/model-ballast/manifests/estargz-140g \
    | python3 -c 'import json,sys,urllib.request
d=json.load(sys.stdin)
m=d["manifests"][0] if "manifests" in d else None
if m:
    r=urllib.request.Request("http://localhost:5000/v2/model-ballast/manifests/"+m["digest"],headers={"Accept":m["mediaType"]})
    d=json.load(urllib.request.urlopen(r))
print(d["layers"][0]["digest"])' 2>/dev/null || true)
if [ -n "${D}" ]; then
  n=$(curl -sf -r 0-1048575 "http://localhost:5000/v2/model-ballast/blobs/${D}" | wc -c)
  echo "read-back of ${D:0:24}...: ${n} bytes"
  [ "${n}" -ge 1048576 ] || FAIL=1
fi
sudo umount "${SRC_MNT}" 2>/dev/null || true
[ "${FAIL}" = "0" ] && echo "MERGE OK" || { echo "MERGE FAILED"; exit 1; }
