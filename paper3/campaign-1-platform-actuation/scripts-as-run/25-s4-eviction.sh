#!/usr/bin/env bash
# spike-v4 S4: with REAL kubelet eviction thresholds, does the imageFs visibility
# that PR #1893 provides actually make the platform act?
#
# Run 1 could not answer this. kind pins evictionHard to imagefs.available=0% /
# nodefs.available=0% and imageGCHighThresholdPercent=100, so eviction is effectively
# disabled and run 1's "DiskPressure=False" was uninterpretable -- flagged as a gap in
# RUN-REPORT §10. This cluster is created with production-like thresholds
# (imagefs.available: 10%, imageGCHighThresholdPercent: 85, transition period 30s),
# so the question becomes answerable.
#
# Two sub-questions, and they can diverge:
#   (a) does kubelet raise DiskPressure as imageFs availableBytes falls below 10%?
#       availableBytes comes from statfs and DID track reality in run 1, so it should.
#   (b) does anything actually reclaim, or does the pod get evicted? Image GC keys on
#       used/capacity, and run 1 measured usedBytes stuck at ~152MB (0.16%) while 92GB
#       was consumed -- so GC should find "nothing to collect" and, if it acts at all,
#       kubelet must fall through to evicting pods.
#
# Sampling is every 5s (not run 1's 20s) so the DiskPressure transition and any
# eviction are actually caught in the timeline.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need kubectl; need envsubst; need docker

NODE="$(NODE_CTR)"
TRIAL="${TRIAL:-S4-eviction-75pct}"
FUSE_MANAGER="${FUSE_MANAGER:-true}"
PREFILL_PCT="${PREFILL_PCT:-75}"
OUT="${RESULTS_DIR}/s4/${TRIAL}"; mkdir -p "${OUT}"
IMG="${MODEL_IMG_PREFIX}:estargz-140g"
POD="s4-probe"

log "=== S4 ${TRIAL}: fuse_manager=${FUSE_MANAGER}, pre-fill ${PREFILL_PCT}%, REAL eviction thresholds ==="
teardown_pod "${POD}"
set_log_level info
docker exec "${NODE}" sh -c "sed -i 's/^  enable = .*/  enable = ${FUSE_MANAGER}/' /etc/containerd-stargz-grpc/config.toml"
hard_reset || die "could not reach a clean state"

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
{ echo "trial=${TRIAL} fuse_manager=${FUSE_MANAGER} prefill=${PREFILL_PCT}%"
  echo "date=$(date -Is)"
  echo "--- kubelet eviction settings actually in force ---"
  kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/configz" \
    | python3 -c 'import json,sys; k=json.load(sys.stdin)["kubeletconfig"]; print(json.dumps({x:k.get(x) for x in ("evictionHard","evictionSoft","evictionPressureTransitionPeriod","imageGCHighThresholdPercent","imageGCLowThresholdPercent")}, indent=2))'
  echo "--- stargz config ---"; docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml
  echo "--- containerd exports ---"; docker exec "${NODE}" grep -A6 'proxy_plugins.stargz' /etc/containerd/config.toml
  docker exec "${NODE}" containerd-stargz-grpc --version
} > "${OUT}/meta.txt" 2>&1

CAPACITY_KB=$(df --output=size "${STARGZ_CACHE_MOUNT}" | tail -1)
sudo fallocate -l "$(( CAPACITY_KB * PREFILL_PCT / 100 ))K" "${STARGZ_CACHE_MOUNT}/s4-filler.img"
log "cache at $(cache_pct)% before the read"

t0=$(now)
deploy_pod "${POD}" "${IMG}" normal 3
wait_for 900 "pod Ready" pod_ready "${POD}" || log "WARN: Ready timeout"
echo "deploy_to_ready_s=$(elapsed "${t0}")" > "${OUT}/ready.txt"

# 5s sampler: node conditions + imageFs + pod phase/eviction reason
( echo "t_s,cache_pct,imagefs_avail,imagefs_used,disk_pressure,pod_phase,pod_ready,restarts,pod_reason"
  while true; do
    stats=$(kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/stats/summary" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["node"]; i=(d.get("runtime") or {}).get("imageFs") or {}
    print("%s,%s"%(i.get("availableBytes"),i.get("usedBytes")))
except Exception: print("na,na")' 2>/dev/null || echo "na,na")
    dp=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null)
    ph=$(kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null)
    rd=$(pod_ready "${POD}" && echo true || echo false)
    rs=$(pod_restarts "${POD}")
    rn=$(kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.reason}' 2>/dev/null)
    echo "$(elapsed "${t0}"),$(cache_pct),${stats},${dp},${ph},${rd},${rs},${rn}"
    sleep 5
  done ) > "${OUT}/eviction-timeline.csv" 2>&1 &
SAMPLER=$!
trap 'kill ${SAMPLER} 2>/dev/null || true' EXIT

log "induction: full 280-file read"
full_read "${POD}" > "${OUT}/full-read.txt" 2>&1 || true
grep -E '^DIRSTAT|^LISTDIR|^READ|^ERRNOS' "${OUT}/full-read.txt" >&2 || true   # never abort on no-match under set -e

# keep sampling past the read: eviction is asynchronous, and
# evictionPressureTransitionPeriod is 30s, so give it well over that to fire.
log "read done; sampling a further 180s to catch asynchronous eviction"
sleep 180
kill "${SAMPLER}" 2>/dev/null || true

{ echo "--- did kubelet raise DiskPressure at any point? ---"
  awk -F, 'NR>1 && $5=="True"' "${OUT}/eviction-timeline.csv" | head -5
  echo "(empty above = DiskPressure never became True)"
  echo
  echo "--- did the pod get evicted / restarted / killed? ---"
  awk -F, 'NR>1 && ($6!="Running" || $9!="")' "${OUT}/eviction-timeline.csv" | head -5
  echo "(empty above = pod stayed Running with no eviction reason)"
  echo
  echo "--- node events mentioning eviction / disk / image GC ---"
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null \
    | grep -iE 'evict|diskpressure|freeDiskSpace|ImageGC|failed to garbage collect' | tail -20
  echo "(empty above = no such events)"
} > "${OUT}/VERDICT.txt" 2>&1
cat "${OUT}/VERDICT.txt" >&2

{ echo "--- final pod ---"; kubectl -n "${TEST_NS}" get pod "${POD}" -o wide
  kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.conditions}' | python3 -m json.tool 2>/dev/null || true
  echo "--- node conditions ---"; kubectl get node "${NODE_NAME}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
  echo "--- kubelet view ---"; kubelet_view
  echo "--- df ---"; df -h "${STARGZ_CACHE_MOUNT}"
} > "${OUT}/post-state.txt" 2>&1
kubectl get events -A --sort-by=.lastTimestamp > "${OUT}/all-events.txt" 2>&1 || true
docker exec "${NODE}" journalctl -u kubelet --no-pager 2>/dev/null | tail -400 > "${OUT}/kubelet-journal-tail.txt" 2>&1 || true
docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${OUT}/journal-stargz-snapshotter.txt" 2>&1 || true
kubectl -n "${TEST_NS}" describe pod "${POD}" > "${OUT}/pod-describe.txt" 2>&1 || true

teardown_pod "${POD}"
sudo rm -f "${STARGZ_CACHE_MOUNT}/s4-filler.img" 2>/dev/null || true
log "S4 ${TRIAL} done -> ${OUT}"
