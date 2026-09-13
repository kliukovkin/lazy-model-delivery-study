#!/usr/bin/env bash
# spike-v4 S2b: the "lying pod" dimension of S2, N=1, second rep of the same
# 75%-pre-fill induction.
#
# S2 rep1 lost its health/predict signal because the curl-runner deployment was
# collateral damage from attempt 1 filling the partition, and would not come back
# (its image pull now goes through the stargz snapshotter). Rather than repair a
# second pod, this asks the question more directly: the probe runs INSIDE the
# predictor pod and hits the predictor's OWN endpoints over loopback. That is the
# sharper form of the question anyway -- does this pod's own health surface keep
# answering 200 while its model files are unreadable?
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need kubectl; need envsubst; need docker

NODE="$(NODE_CTR)"
TRIAL="${TRIAL:-S2b-75pct-fm-on-rep2}"
PREFILL_PCT="${PREFILL_PCT:-75}"
OUT="${RESULTS_DIR}/s2/${TRIAL}"; mkdir -p "${OUT}"
IMG="${MODEL_IMG_PREFIX}:estargz-140g"
POD="s2b-probe"

# Queries the pod's own HTTP surface from inside the pod, plus a direct data read,
# so the two signals are captured at the same instant.
SELFCHECK_PY='
import json, urllib.request, os, glob, errno
def http(method, path, body=None):
    req = urllib.request.Request("http://127.0.0.1:8080" + path, method=method,
                                 data=(json.dumps(body).encode() if body else None),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read()[:200]
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:200]
    except Exception as e:
        return "EXC", str(e)[:200]
hc, hb = http("GET", "/healthz")
pc, pb = http("POST", "/v1/models/x:predict", {"seed": 7})
print("HEALTH  status=%s body=%s" % (hc, hb))
print("PREDICT status=%s body=%s" % (pc, pb))
ok = bad = 0
for p in sorted(glob.glob("/mnt/models/ballast-*.bin")):
    try:
        with open(p, "rb") as f: f.read(1 << 20)
        ok += 1
    except OSError: bad += 1
print("DATA    readable=%d unreadable=%d total=%d" % (ok, bad, ok + bad))
'
selfcheck() { kubectl -n "${TEST_NS}" exec "$1" -- python3 -c "${SELFCHECK_PY}" 2>&1; }

log "=== S2b ${TRIAL}: pre-fill ${PREFILL_PCT}%, lying-pod signal from inside the pod ==="
teardown_pod "${POD}"
set_log_level info
hard_reset || die "could not reach a clean state"

CAPACITY_KB=$(df --output=size "${STARGZ_CACHE_MOUNT}" | tail -1)
FILL_KB=$(( CAPACITY_KB * PREFILL_PCT / 100 ))
sudo fallocate -l "${FILL_KB}K" "${STARGZ_CACHE_MOUNT}/s2-filler.img"
log "cache at $(cache_pct)% before the read"

t0=$(now)
deploy_pod "${POD}" "${IMG}" normal 3
wait_for 900 "pod Ready" pod_ready "${POD}" || log "WARN: Ready timeout"
echo "deploy_to_ready_s=$(elapsed "${t0}") ready=$(pod_ready "${POD}" && echo true || echo false)" > "${OUT}/ready.txt"

log "--- BEFORE induction ---"
{ echo "=== BEFORE induction ==="; echo "cache_pct=$(cache_pct)"; selfcheck "${POD}"; } > "${OUT}/selfcheck-before.txt" 2>&1
cat "${OUT}/selfcheck-before.txt" >&2

log "--- induction: full 280-file read ---"
full_read "${POD}" > "${OUT}/full-read.txt" 2>&1 || true
grep -E '^DIRSTAT|^LISTDIR|^READ|^ERRNOS' "${OUT}/full-read.txt" >&2

log "--- AFTER induction (the money question) ---"
{ echo "=== AFTER induction ==="; echo "cache_pct=$(cache_pct)"
  echo "pod_ready=$(pod_ready "${POD}" && echo true || echo false) phase=$(pod_phase "${POD}") restarts=$(pod_restarts "${POD}")"
  selfcheck "${POD}"
} > "${OUT}/selfcheck-after.txt" 2>&1
cat "${OUT}/selfcheck-after.txt" >&2

{ echo "--- pod status ---"; kubectl -n "${TEST_NS}" get pod "${POD}" -o wide
  echo "restarts=$(pod_restarts "${POD}")"
  echo "--- kubelet node view ---"; kubelet_view
  echo "--- df ---"; df -h "${STARGZ_CACHE_MOUNT}"
} > "${OUT}/post-state.txt" 2>&1
{ echo "### journal"; docker exec "${NODE}" sh -c "journalctl -u stargz-snapshotter --no-pager | grep -c 'no space left on device'" 2>&1 || echo 0
  echo "### stargz-fuse-manager.log"; docker exec "${NODE}" sh -c "grep -c 'no space left on device' ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" 2>&1 || echo 0
} > "${OUT}/enospc-counts.txt" 2>&1
docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${OUT}/journal-stargz-snapshotter.txt" 2>&1 || true
docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${OUT}/fuse-manager.log" 2>&1 || true
kubectl -n "${TEST_NS}" describe pod "${POD}" > "${OUT}/pod-describe.txt" 2>&1 || true

teardown_pod "${POD}"
sudo rm -f "${STARGZ_CACHE_MOUNT}/s2-filler.img" 2>/dev/null || true
log "S2b done -> ${OUT}"
