#!/usr/bin/env bash
# E4 [P1] -- the pressure matrix at 90%, N=2, both arms, on FIXED code.
#
# v5 ran this at N=1 for time (its F7), so the paper's main table has a single
# observation at the level that matters. E3 brings it to N=2 on both arms.
#
# The vanilla v0.18.2 arm is the load-bearing control: if it does NOT reproduce
# the failure, the before/after says nothing and is reported void rather than as
# a pass. See PRE-REGISTRATION-v7.md s4.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

IMG="${MODEL_IMG_PREFIX}:estargz-140g"
LEVEL="${LEVEL:-90}"
REPS="${REPS:-2}"
E4="${RESULTS_DIR}/e4"
PART_BYTES=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')

# v5 F8 killed four trials because kubelet evicted the pod at 90% pre-fill before
# a single read happened, and the fix was applied by hand and never scripted.
# Assert it against the RUNNING kubelet, not against the file we wrote.
assert_kubelet_wont_evict() {
  local t; t="$(kubelet_eviction_thresholds)"
  echo "kubelet_eviction=${t}"
  kubelet_eviction_disabled || die "kubelet would evict at ${LEVEL}% pre-fill (thresholds: ${t}) -- v5 F8. Refusing to run a trial that would measure kubelet instead of the cache."
}

switch_arm() { # switch_arm <ours|vanilla>
  case "$1" in
    ours)    BINSRC=/data/stargz-bin-ours ARM_LABEL=ours    CACHE_ACCOUNTING=true  FM_METRICS_ADDRESS="" "$(dirname "$0")/05-setup-stargz.sh" ;;
    vanilla) BINSRC=/data/stargz-bin      ARM_LABEL=vanilla CACHE_ACCOUNTING=false FM_METRICS_ADDRESS="" "$(dirname "$0")/05-setup-stargz.sh" ;;
  esac
}

prefill() { # prefill <pct>
  local pct="$1" bytes
  sudo rm -f "${STARGZ_CACHE_MOUNT}"/v6filler.img
  [ "${pct}" -eq 0 ] && return 0
  bytes=$(( PART_BYTES * pct / 100 ))
  # ext4 ENOSPC triggers on free block count, so a filler file is equivalent to
  # foreign chunk occupancy for this purpose (inherited from v4 s4).
  sudo fallocate -l "${bytes}" "${STARGZ_CACHE_MOUNT}/v6filler.img" || die "fallocate ${bytes} failed"
  df -h "${STARGZ_CACHE_MOUNT}" | tail -1
}

trial() { # trial <arm> <rep>
  local arm="$1" rep="$2"
  local out="${E4}/${arm}-${LEVEL}pct-rep${rep}"; mkdir -p "${out}"
  local pod="e4-${arm}-${rep}"
  log "=== E4 arm=${arm} prefill=${LEVEL}% rep=${rep} ==="

  hard_reset || { echo "hard_reset failed" > "${out}/WHY-INVALID.txt"; mv "${out}" "${out}-INVALID"; return 0; }
  assert_kubelet_wont_evict > "${out}/kubelet.txt"
  prefill "${LEVEL}"

  { echo "experiment=E4"; echo "arm=${arm}"; echo "prefill_pct=${LEVEL}"; echo "rep=${rep}"
    echo "partition_bytes=${PART_BYTES}"
    echo "budget_bytes=$([ "${arm}" = ours ] && echo "${CACHE_BUDGET_BYTES}" || true)"
    echo "sha=$([ "${arm}" = ours ] && awk -F= '/^sha=/{print $2}' /data/stargz-bin-ours/PROVENANCE.txt || echo "${STARGZ_VER}")"
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
  full_read "${pod}" 280 > "${out}/full-read.txt" 2>&1 || true
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
  teardown_pod "${pod}"
  sudo rm -f "${STARGZ_CACHE_MOUNT}"/v6filler.img

  { grep -E '^(READ|ERRNOS|DIRSTAT|LISTDIR)' "${out}/full-read.txt" || true
    echo "--- enospc ---"; cat "${out}/enospc-counts.txt"
    echo "--- writes_skipped ---"; metric_sum "$(cat "${out}/metrics-after.txt")" stargz_fs_cache_writes_skipped_total; echo
    echo "--- evictions ---";     metric_sum "$(cat "${out}/metrics-after.txt")" stargz_fs_cache_evictions_total; echo
  } > "${out}/SUMMARY.txt"
  cat "${out}/SUMMARY.txt"
  bash "$(dirname "$0")/91-collect-one.sh" "e4/${arm}-${LEVEL}pct-rep${rep}" || log "  WARN: collection failed"
}

mkdir -p "${E4}"
log "E4: our build, ${REPS} reps at ${LEVEL}%"
switch_arm ours
for r in $(seq 1 "${REPS}"); do trial ours "${r}"; done

log "E4: vanilla ${STARGZ_VER} control, ${REPS} reps at ${LEVEL}% -- the load-bearing negative control"
switch_arm vanilla
for r in $(seq 1 "${REPS}"); do trial vanilla "${r}"; done

log "E4: restoring our arm"
switch_arm ours

{
  echo "arm,prefill_pct,rep,ready_s,sweep_s,attempted,ok,err,bytes,writes_skipped,evictions,enospc_journal,enospc_fm,pod_phase"
  for d in "${E4}"/*/; do
    [ -f "${d}/meta.txt" ] || continue
    g() { awk -F= "/^$1=/{print \$2}" "${d}/meta.txt"; }
    read -r at ok er by <<<"$(sed -n 's/.*attempted=\([0-9]*\) ok=\([0-9]*\) err=\([0-9]*\) bytes=\([0-9]*\).*/\1 \2 \3 \4/p' "${d}/full-read.txt" 2>/dev/null | head -1)"
    echo "$(g arm),$(g prefill_pct),$(g rep),$(g deploy_to_ready_s),$(g sweep_s),${at},${ok},${er},${by},$(metric_sum "$(cat "${d}/metrics-after.txt" 2>/dev/null)" stargz_fs_cache_writes_skipped_total),$(metric_sum "$(cat "${d}/metrics-after.txt" 2>/dev/null)" stargz_fs_cache_evictions_total),$(awk -F= '/^journal=/{print $2}' "${d}/enospc-counts.txt" 2>/dev/null),$(awk -F= '/^fuse_manager=/{print $2}' "${d}/enospc-counts.txt" 2>/dev/null),$(g pod_phase_at_end)"
  done
} > "${E4}/e4-summary.csv"
column -s, -t < "${E4}/e4-summary.csv" | tee "${E4}/E4-RESULT.txt"
log "E4 done -> ${E4}"
