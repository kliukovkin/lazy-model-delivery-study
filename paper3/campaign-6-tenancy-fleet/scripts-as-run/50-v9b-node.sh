#!/usr/bin/env bash
# V9-B, node side. One long-lived process per node, launched with nohup from the
# workstation, so that nothing measured depends on an ssh session staying open
# (v4 s9 finding 5) and the 10 s sampler cannot be SIGHUPed out from under a
# round that is still running.
#
# Three stages, split by two files on /data so the REGISTRY host can time the
# start without also owning the setup:
#   prepare -> touch /data/v9b-ready-<round>   (reset, 90% pre-fill, pod Ready)
#   wait    -> for /data/v9b-go-<round>        (the registry's fan-out writes it)
#   read    -> full read, collect, touch /data/v9b-done-<round>
#
# Pre-filling before the coordinated start is the whole point of the split: a
# 90% fallocate plus a pod pull inside the measured window would put minutes of
# per-node setup variance into a 5 s start-skew requirement.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

ROUND="${1:?usage: 50-v9b-node.sh <round-label>}"
LEVEL="${LEVEL:-90}"
NODE_LABEL="${NODE_LABEL:-$(hostname)}"
IMG="${MODEL_IMG_B}"
OUT="${RESULTS_DIR}/v9b/${ROUND}-${NODE_LABEL}"
PART_BYTES=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')
READY="/data/v9b-ready-${ROUND}"; GO="/data/v9b-go-${ROUND}"; DONE="/data/v9b-done-${ROUND}"
rm -f "${READY}" "${GO}" "${DONE}"
mkdir -p "${OUT}"

assert_kubelet_wont_evict() {
  local t; t="$(kubelet_eviction_thresholds)"
  echo "kubelet_eviction=${t}"
  kubelet_eviction_disabled || die "kubelet would evict at ${LEVEL}% pre-fill (${t}) -- v5 F8"
}

log "=== V9-B ${ROUND} on ${NODE_LABEL}: prepare ==="
hard_reset || die "hard_reset failed"
assert_kubelet_wont_evict > "${OUT}/kubelet.txt"
sudo rm -f "${STARGZ_CACHE_MOUNT}"/v9filler.img
if [ "${LEVEL}" -gt 0 ]; then
  sudo fallocate -l "$(( PART_BYTES * LEVEL / 100 ))" "${STARGZ_CACHE_MOUNT}/v9filler.img" || die "fallocate failed"
fi
sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
df -B1 "${STARGZ_CACHE_MOUNT}" | tail -1 > "${OUT}/df-after-prefill.txt"

POD="v9b-${ROUND}"
teardown_pod "${POD}"
deploy_pod "${POD}" "${IMG}" normal 3
wait_for 300 "pod ready" pod_ready "${POD}" || die "pod never Ready"

{ echo "experiment=V9-B"; echo "round=${ROUND}"; echo "node=${NODE_LABEL}"
  echo "prefill_pct=${LEVEL}"; echo "image=${IMG}"; echo "b_files=${B_FILES}"
  echo "budget_bytes=${CACHE_BUDGET_BYTES}"; echo "policy=${CACHE_POLICY}"
  echo "partition_bytes=${PART_BYTES}"
  echo "sha=$(awk -F= '/^sha=/{print $2}' /data/stargz-bin-ours/PROVENANCE.txt 2>/dev/null)"
  echo "prepared_utc=$(date -u +%FT%T.%3NZ)"; } > "${OUT}/meta.txt"

# Sampler starts BEFORE the go signal, so the idle margin either side of the
# read is in the same series as the read itself.
start_sampler "${OUT}/sampler.csv" 10
touch "${READY}"
# PATIENCE: 1 hour, not 10 minutes.
#
# The first V9-B attempt died here. The node was ready at 23:37:11 and waited
# exactly 600 s; the workstation's launch ssh did not return for 10.5 minutes
# (the backgrounded remote job held the session channel open, so no readiness
# poll was even attempted -- the node's sshd log shows NO connection between
# 23:36:37 and 23:47:13), and the go signal landed 31 s after the node had
# already given up. The registry then waited 2.5 h for a "done" marker that
# could never appear.
#
# The lesson is that a measured host must not be on a shorter clock than the
# orchestrator that drives it. An hour is far longer than any plausible
# orchestration hiccup and still bounded, and an expiry now cleans up after
# itself so the next attempt starts from a known state rather than from a
# pre-filled partition and a live pod.
log "  ready; waiting for ${GO} (up to 3600s)"
for _ in $(seq 1 7200); do [ -f "${GO}" ] && break; sleep 0.5; done
if [ ! -f "${GO}" ]; then
  stop_sampler || true
  teardown_pod "${POD}" || true
  sudo rm -f "${STARGZ_CACHE_MOUNT}"/v9filler.img || true
  die "no go signal after 3600s -- cleaned up, partition released"
fi

echo "go_seen_utc=$(date -u +%FT%T.%3NZ)" >> "${OUT}/meta.txt"
echo "read_begin_utc=$(date -u +%FT%T.%3NZ)" >> "${OUT}/meta.txt"
echo "read_begin_epoch=$(date +%s.%N)" >> "${OUT}/meta.txt"
t0=$(now)
full_read "${POD}" "${B_FILES}" > "${OUT}/full-read.txt" 2>&1 || true
echo "read_s=$(elapsed "${t0}")" >> "${OUT}/meta.txt"
echo "read_end_utc=$(date -u +%FT%T.%3NZ)" >> "${OUT}/meta.txt"
echo "read_end_epoch=$(date +%s.%N)" >> "${OUT}/meta.txt"
touch "${DONE}"

sleep 10; stop_sampler
sg_metrics_snapshotter > "${OUT}/metrics-after.txt"
df -B1 "${STARGZ_CACHE_MOUNT}" | tail -1 > "${OUT}/df-after.txt"
cache_du > "${OUT}/du-after.txt"
docker exec "$(NODE_CTR)" journalctl -u stargz-snapshotter --no-pager > "${OUT}/journal-stargz.txt" 2>&1 || true
docker exec "$(NODE_CTR)" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${OUT}/fuse-manager.log" 2>&1 || true
kubectl -n "${TEST_NS}" get events --sort-by=.lastTimestamp > "${OUT}/pod-events.txt" 2>&1 || true
echo "pod_phase_at_end=$(pod_phase "${POD}")" >> "${OUT}/meta.txt"
teardown_pod "${POD}"
sudo rm -f "${STARGZ_CACHE_MOUNT}"/v9filler.img

{ grep -E '^(READ|ERRNOS|DIRSTAT|LISTDIR)' "${OUT}/full-read.txt" || true
  echo "--- read_s ---";      awk -F= '/^read_s=/{print $2}' "${OUT}/meta.txt"
  echo "--- du (h f stargz snap total) ---"; cat "${OUT}/du-after.txt"
  echo "--- df after ---";    cat "${OUT}/df-after.txt"
  printf -- "--- evictions --- ";     metric_sum "$(cat "${OUT}/metrics-after.txt")" stargz_fs_cache_evictions_total; echo
  printf -- "--- evicted_bytes --- "; metric_sum "$(cat "${OUT}/metrics-after.txt")" stargz_fs_cache_evicted_bytes_total; echo
  printf -- "--- writes_skipped --- ";metric_sum "$(cat "${OUT}/metrics-after.txt")" stargz_fs_cache_writes_skipped_total; echo
} > "${OUT}/SUMMARY.txt"
cat "${OUT}/SUMMARY.txt"
bash "$(dirname "$0")/91-collect-one.sh" "v9b/${ROUND}-${NODE_LABEL}" || log "  WARN: collection failed"
log "=== V9-B ${ROUND} on ${NODE_LABEL}: done ==="
