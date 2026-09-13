#!/usr/bin/env bash
# spike-v4 smoke test: prove the 140GB eStargz image actually lazy-mounts and is
# readable before committing an hour of rig time to S1. Cheap, and it catches an
# image/registry/snapshotter wiring problem at the point where it is still trivial.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
POD=smoke-probe
OUT="${RESULTS_DIR}/smoke"; mkdir -p "${OUT}"
teardown_pod "${POD}"
t0=$(now)
deploy_pod "${POD}" "${MODEL_IMG_PREFIX}:estargz-140g" normal 3
if wait_for 600 "smoke Ready" pod_ready "${POD}"; then
  echo "SMOKE_READY_OK ttfp_s=$(elapsed "${t0}")"
else
  echo "SMOKE_READY_FAIL"; kubectl -n "${TEST_NS}" describe pod "${POD}" | tail -30; teardown_pod "${POD}"; exit 1
fi
echo "--- file count + a real read through the FUSE mount ---"
kubectl -n "${TEST_NS}" exec "${POD}" -- python3 -c '
import glob, os
fs = sorted(glob.glob("/mnt/models/ballast-*.bin"))
print("ballast_files=%d" % len(fs))
if fs:
    with open(fs[0], "rb") as f:
        d = f.read(64 << 20)
    print("first_file=%s read_bytes=%d size=%d" % (os.path.basename(fs[0]), len(d), os.path.getsize(fs[0])))
'
echo "--- snapshotter/cache state after the smoke read ---"
cache_du; cache_df; sg_pids
{ echo "smoke ttfp_s=$(elapsed "${t0}")"; cache_du; } > "${OUT}/smoke.txt"
teardown_pod "${POD}"
echo "SMOKE_OK"
