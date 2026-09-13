#!/usr/bin/env bash
# V9-C -- honesty-price replication at N=5.
#
# The paper carries +20.6% as the price of serving chunks the cache cannot keep
# (\honestyPricePct). That number is v5's, from its V2 pressure matrix at N=1 --
# ONE observation at 90% pre-fill against ONE at 0%, on an instance that no
# longer exists. v8 never re-measured it. This script measures it five times,
# interleaved, in one session on one instance, which is the only way a price
# quoted to one decimal place can be defended.
#
# Design (PRE-REGISTRATION-v9 s2): 5 pairs, each pair is (0% run, then 90% run)
# back to back, alternating 0,90,0,90,... Pair i's price is
# (t90_i - t0_i)/t0_i; the statistic is the MEDIAN of the five, reported with
# min-max. Pairing and statistic are fixed here, before any data exists, so
# neither can be chosen after seeing it.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

IMG="${MODEL_IMG_B}"
PAIRS="${PAIRS:-5}"
V9C="${RESULTS_DIR}/v9c"
PART_BYTES=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')

# v5 F8 killed four trials because kubelet evicted the pod at 90% pre-fill before
# a single read happened, and the fix was applied by hand and never scripted.
# Assert it against the RUNNING kubelet, not against the file we wrote.
assert_kubelet_wont_evict() {
  local t; t="$(kubelet_eviction_thresholds)"
  echo "kubelet_eviction=${t}"
  kubelet_eviction_disabled || die "kubelet would evict at 90% pre-fill (thresholds: ${t}) -- v5 F8. Refusing to run a trial that would measure kubelet instead of the cache."
}

# THE reset procedure. One function, called identically before every arm, because
# the task requires the between-arms reset to be the same procedure every time
# and "the same procedure" is only checkable if there is exactly one of it.
reset_to_prefill() { # reset_to_prefill <pct> <outdir>
  local pct="$1" out="$2" bytes
  hard_reset || return 1
  assert_kubelet_wont_evict > "${out}/kubelet.txt"
  sudo rm -f "${STARGZ_CACHE_MOUNT}"/v9filler.img
  if [ "${pct}" -gt 0 ]; then
    bytes=$(( PART_BYTES * pct / 100 ))
    # ext4 ENOSPC triggers on the free block count, so a filler file is
    # equivalent to foreign chunk occupancy for this purpose (v4 s4).
    sudo fallocate -l "${bytes}" "${STARGZ_CACHE_MOUNT}/v9filler.img" || die "fallocate ${bytes} failed"
  fi
  # 64 GB of RAM and a 150 GB previous read: page-cache residue is a difference
  # between arms that has nothing to do with the budget. PRE-REGISTRATION-v9 s2.
  sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || echo "  (could not drop page cache)" >&2
  df -B1 "${STARGZ_CACHE_MOUNT}" | tail -1 > "${out}/df-after-prefill.txt"
  return 0
}

trial() { # trial <pair> <level>
  local pair="$1" lvl="$2"
  local out="${V9C}/pair${pair}-${lvl}pct"; mkdir -p "${out}"
  local pod="v9c-p${pair}-${lvl}"
  log "=== V9-C pair ${pair} level ${lvl}% ==="

  if ! reset_to_prefill "${lvl}" "${out}"; then
    echo "reset_to_prefill failed before any measurement" > "${out}/WHY-INVALID.txt"
    mv "${out}" "${out}-INVALID"; return 0
  fi

  { echo "experiment=V9-C"; echo "pair=${pair}"; echo "prefill_pct=${lvl}"
    echo "arm=ours"; echo "policy=${CACHE_POLICY}"
    echo "partition_bytes=${PART_BYTES}"; echo "budget_bytes=${CACHE_BUDGET_BYTES}"
    echo "image=${IMG}"
    echo "sha=$(awk -F= '/^sha=/{print $2}' /data/stargz-bin-ours/PROVENANCE.txt 2>/dev/null)"
    echo "started_utc=$(date -u +%FT%TZ)"
    df -B1 "${STARGZ_CACHE_MOUNT}" | tail -1; } > "${out}/meta.txt"

  start_sampler "${out}/sampler.csv" 10
  trap 'stop_sampler' RETURN

  local t0 st0; t0=$(now)
  deploy_pod "${pod}" "${IMG}" normal 3
  if ! wait_for 300 "pod ready" pod_ready "${pod}"; then
    kubectl -n "${TEST_NS}" describe pod "${pod}" > "${out}/pod-describe.txt" 2>&1 || true
    echo "deploy_to_ready_s=NEVER" >> "${out}/meta.txt"
  else
    echo "deploy_to_ready_s=$(elapsed "${t0}")" >> "${out}/meta.txt"
  fi
  st0=$(now)
  full_read "${pod}" "${B_FILES}" > "${out}/full-read.txt" 2>&1 || true
  echo "sweep_s=$(elapsed "${st0}")" >> "${out}/meta.txt"

  sleep 10; stop_sampler; trap - RETURN
  sg_metrics_snapshotter > "${out}/metrics-after.txt"
  docker exec "$(NODE_CTR)" journalctl -u stargz-snapshotter --no-pager > "${out}/journal-stargz.txt" 2>&1 || true
  docker exec "$(NODE_CTR)" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${out}/fuse-manager.log" 2>&1 || true
  # v4 s4: grepping only the snapshotter journal undercounts ENOSPC by ~40% when
  # fuse_manager is on. Count both.
  { echo "journal=$(grep -ci 'no space left' "${out}/journal-stargz.txt" || true)"
    echo "fuse_manager=$(grep -ci 'no space left' "${out}/fuse-manager.log" || true)"; } > "${out}/enospc-counts.txt"
  kubectl -n "${TEST_NS}" get events --sort-by=.lastTimestamp > "${out}/pod-events.txt" 2>&1 || true
  echo "pod_phase_at_end=$(pod_phase "${pod}")" >> "${out}/meta.txt"
  df -B1 "${STARGZ_CACHE_MOUNT}" | tail -1 > "${out}/df-after.txt"
  teardown_pod "${pod}"
  sudo rm -f "${STARGZ_CACHE_MOUNT}"/v9filler.img

  { grep -E '^(READ|ERRNOS|DIRSTAT|LISTDIR)' "${out}/full-read.txt" || true
    echo "--- enospc ---"; cat "${out}/enospc-counts.txt"
    printf -- "--- writes_skipped --- "; metric_sum "$(cat "${out}/metrics-after.txt")" stargz_fs_cache_writes_skipped_total; echo
    printf -- "--- evictions --- ";     metric_sum "$(cat "${out}/metrics-after.txt")" stargz_fs_cache_evictions_total; echo
    printf -- "--- evicted_bytes --- "; metric_sum "$(cat "${out}/metrics-after.txt")" stargz_fs_cache_evicted_bytes_total; echo
  } > "${out}/SUMMARY.txt"
  cat "${out}/SUMMARY.txt"
  bash "$(dirname "$0")/91-collect-one.sh" "v9c/pair${pair}-${lvl}pct" || log "  WARN: collection failed"
}

mkdir -p "${V9C}"
log "V9-C: ${PAIRS} interleaved pairs, 0% then 90%, ours @ $(awk -F= '/^sha=/{print $2}' /data/stargz-bin-ours/PROVENANCE.txt 2>/dev/null)"
for p in $(seq 1 "${PAIRS}"); do
  trial "${p}" 0
  trial "${p}" 90
done

python3 "$(dirname "$0")/30-v9c-analyse.py" "${V9C}" | tee "${V9C}/V9C-RESULT.txt"
log "V9-C done -> ${V9C}"
