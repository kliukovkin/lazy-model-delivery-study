#!/usr/bin/env bash
# spike-v4 S2 [P0]: does enabling fuse_manager change ANYTHING about the ENOSPC
# failure? Expected answer: no (fuse_manager is about daemon restarts, not about
# cache capacity) -- but the task requires that expectation be measured, not asserted.
#
# Short form of the v3.1/C2 P0.5 pressure scenario: ONE level, 75% pre-fill, N=1,
# full 140GB-class read against the 92GB partition.
#
# Two things are captured here that v3.1 could not capture:
#   1. ENOSPC errors are grepped from BOTH the snapshotter journal AND
#      <root>/stargz-fuse-manager.log -- with fuse_manager on, the FUSE serving
#      (and therefore the cache write that hits ENOSPC) happens in the DETACHED
#      manager process, so its log is where the errors actually land.
#   2. kubelet's node view (DiskPressure, node.fs, runtime.imageFs) is sampled
#      throughout. v3.1 s9 recorded DiskPressure=False throughout every ENOSPC
#      induction because the cache volume was invisible to kubelet. v4's
#      containerd config carries [proxy_plugins.stargz.exports] root = ...
#      (PR #1893 as upstream documents it), so this is the empirical test of what
#      that visibility actually buys.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need kubectl; need envsubst; need docker

NODE="$(NODE_CTR)"
TRIAL="${TRIAL:-S2-75pct-fm-on}"
FUSE_MANAGER="${FUSE_MANAGER:-true}"
PREFILL_PCT="${PREFILL_PCT:-75}"
OUT="${RESULTS_DIR}/s2/${TRIAL}"; mkdir -p "${OUT}"
IMG="${MODEL_IMG_PREFIX}:estargz-140g"
POD="s2-probe"

set_log_level "${STARGZ_LOG_LEVEL:-info}"   # a full 140GB read at debug is GBs of log
log "=== S2 ${TRIAL}: fuse_manager=${FUSE_MANAGER}, pre-fill ${PREFILL_PCT}% ==="
teardown_pod "${POD}"

docker exec "${NODE}" sh -c "sed -i 's/^  enable = .*/  enable = ${FUSE_MANAGER}/' /etc/containerd-stargz-grpc/config.toml"
if ! hard_reset; then
  echo "HARD_RESET_FAILED" > "${OUT}/FLAGGED-INVALID.txt"
  docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager | tail -40 > "${OUT}/journal-reset-failure.txt"
  die "could not bring the snapshotter to a clean state for S2"
fi

# Pre-fill with a plain filler file. Methodological note carried over from v3.1
# P0.5: ext4 ENOSPC triggers purely on free block count, so a filler file is
# equivalent to real foreign chunk occupancy for this purpose. Flagged as a
# simplification, same as it was in v3.1.
CAPACITY_KB=$(df --output=size "${STARGZ_CACHE_MOUNT}" | tail -1)
if [ "${PREFILL_PCT}" -gt 0 ]; then
  FILL_KB=$(( CAPACITY_KB * PREFILL_PCT / 100 ))
  sudo fallocate -l "${FILL_KB}K" "${STARGZ_CACHE_MOUNT}/s2-filler.img"
fi
PCT_ACTUAL=$(cache_pct)
log "cache partition at ${PCT_ACTUAL}% used before the read"

{ echo "trial=${TRIAL} fuse_manager=${FUSE_MANAGER} prefill_target=${PREFILL_PCT}% actual=${PCT_ACTUAL}%"
  echo "date=$(date -Is) image=${IMG}"
  echo "--- stargz config.toml ---";    docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml
  echo "--- containerd proxy_plugins ---"; docker exec "${NODE}" grep -A6 'proxy_plugins.stargz' /etc/containerd/config.toml
  echo "--- versions ---";              docker exec "${NODE}" sh -c 'containerd-stargz-grpc --version; containerd --version'
  echo "--- df before ---";             df -h "${STARGZ_CACHE_MOUNT}"
  echo "--- cache_du before ---";       cache_du
} > "${OUT}/meta.txt" 2>&1

log "deploying ${POD}"
t0=$(now)
deploy_pod "${POD}" "${IMG}" normal 3
if ! wait_for 900 "pod Ready" pod_ready "${POD}"; then
  log "WARN: Ready timeout -- proceeding to read anyway, this is itself a result"
  kubectl -n "${TEST_NS}" describe pod "${POD}" > "${OUT}/pod-describe-not-ready.txt" 2>&1
fi
T_READY=$(elapsed "${t0}")
POD_IP=$(kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.podIP}' 2>/dev/null)
log "pod IP: ${POD_IP:-<none>}"
echo "deploy_to_ready_s=${T_READY} ready=$(pod_ready "${POD}" && echo true || echo false)" > "${OUT}/ready.txt"

# ---------------- background samplers: the "lying pod" signal + kubelet's view
( while true; do
    printf '%s ready=%s restarts=%s phase=%s cache_pct=%s ' \
      "$(elapsed "${t0}")" "$(pod_ready "${POD}" && echo true || echo false)" \
      "$(pod_restarts "${POD}")" "$(pod_phase "${POD}")" "$(cache_pct)"
    printf 'health=%s ' "$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://${POD_IP}:8080/healthz" 2>/dev/null || echo CURLFAIL)"
    printf 'predict=%s\n' "$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST -H 'Content-Type: application/json' -d '{"seed":7}' "http://${POD_IP}:8080/v1/models/x:predict" 2>/dev/null || echo CURLFAIL)"
    sleep 10
  done ) > "${OUT}/sampler.txt" 2>&1 &
SAMPLER=$!
( while true; do echo "=== $(elapsed "${t0}") ==="; kubelet_view; sleep 20; done ) > "${OUT}/kubelet-view-timeline.txt" 2>&1 &
KSAMPLER=$!
trap 'kill ${SAMPLER} ${KSAMPLER} 2>/dev/null || true' EXIT

log "full read of all 280 ballast files (this is the induction)"
t_read0=$(now)
full_read "${POD}" > "${OUT}/full-read.txt" 2>&1 || true
T_READ=$(elapsed "${t_read0}")
echo "full_read_elapsed_s=${T_READ}" >> "${OUT}/ready.txt"
cat "${OUT}/full-read.txt" >&2

kill "${SAMPLER}" "${KSAMPLER}" 2>/dev/null || true
sleep 1

log "post-induction: corrupted-file census + errno census"
errno_probe "${POD}" 280 > "${OUT}/errno-census.txt" 2>&1 || true

{ echo "--- pod status AFTER the ENOSPC storm (does k8s notice?) ---"
  kubectl -n "${TEST_NS}" get pod "${POD}" -o wide
  kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.conditions}' | python3 -m json.tool 2>/dev/null || true
  echo "restarts=$(pod_restarts "${POD}")"
  echo "--- kubelet node view AFTER ---"; kubelet_view
  echo "--- df after ---"; df -h "${STARGZ_CACHE_MOUNT}"
  echo "--- cache_du after (httpcache fscache stargz snapshotter total) ---"; cache_du
  echo "--- daemon processes ---"; sg_pids
} > "${OUT}/post-state.txt" 2>&1

# ENOSPC accounting from BOTH sinks -- see the header note.
{ echo "### journal (containerd-stargz-grpc, systemd unit)"
  docker exec "${NODE}" sh -c "journalctl -u stargz-snapshotter --no-pager | grep -c 'no space left on device'" 2>&1 || echo 0
  echo "### stargz-fuse-manager.log (the detached FUSE server -- where the writes actually happen)"
  docker exec "${NODE}" sh -c "grep -c 'no space left on device' ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" 2>&1 || echo 0
} > "${OUT}/enospc-counts.txt" 2>&1
cat "${OUT}/enospc-counts.txt" >&2

docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${OUT}/journal-stargz-snapshotter.txt" 2>&1 || true
docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${OUT}/fuse-manager.log" 2>&1 || true
kubectl -n "${TEST_NS}" get events --field-selector "involvedObject.name=${POD}" -o wide > "${OUT}/pod-events.txt" 2>&1 || true
kubectl -n "${TEST_NS}" describe pod "${POD}" > "${OUT}/pod-describe.txt" 2>&1 || true
docker exec "${NODE}" sh -c 'dmesg 2>/dev/null | grep -i fuse | tail -50' > "${OUT}/dmesg-fuse.txt" 2>&1 || true
curl -s "http://localhost:9110/metrics" > "${OUT}/stargz-metrics.txt" 2>&1 || \
  docker exec "${NODE}" sh -c 'curl -s http://localhost:9110/metrics' > "${OUT}/stargz-metrics.txt" 2>&1 || true

teardown_pod "${POD}"
sudo rm -f "${STARGZ_CACHE_MOUNT}/s2-filler.img" 2>/dev/null || true
log "S2 ${TRIAL} done -> ${OUT}"
