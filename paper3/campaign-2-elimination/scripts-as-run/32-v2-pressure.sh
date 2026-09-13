#!/usr/bin/env bash
# V2 [P0] -- the pressure matrix, before/after.
#
# Pre-fill {0,50,90}% of the 92GB partition, N=2, budget 80GB, then read all 280
# files. The geometry decides which mechanism is under test at each level: with
# an 80GB budget on a 92GB partition, a filler of X GB leaves (92-X) GB for the
# cache, and the budget only binds when 92-X > 80. See PRE-REGISTRATION s2.
#
# The vanilla v0.18.2 control at 90% is the load-bearing negative control: if it
# does NOT reproduce the v4 failure, V2's before/after is void for this run.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

IMG="${MODEL_IMG_PREFIX}:estargz-140g"
LEVELS="${LEVELS:-0 50 90}"
REPS="${REPS:-2}"
PART_BYTES=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')

switch_arm() { # switch_arm <ours|vanilla>
  case "$1" in
    ours)    BINSRC=/data/stargz-bin-ours ARM_LABEL=ours    CACHE_ACCOUNTING=true  "$(dirname "$0")/05-setup-stargz.sh" ;;
    vanilla) BINSRC=/data/stargz-bin      ARM_LABEL=vanilla CACHE_ACCOUNTING=false "$(dirname "$0")/05-setup-stargz.sh" ;;
  esac
}

prefill() { # prefill <pct>
  local pct="$1" bytes
  sudo rm -f "${STARGZ_CACHE_MOUNT}"/v5filler.img
  [ "${pct}" -eq 0 ] && { log "prefill 0% -- no filler"; return 0; }
  bytes=$(( PART_BYTES * pct / 100 ))
  log "prefill ${pct}% -> fallocate ${bytes} bytes"
  # v4 s4: ext4 ENOSPC triggers on free block count, so a filler file is
  # equivalent to foreign chunk occupancy for this purpose.
  sudo fallocate -l "${bytes}" "${STARGZ_CACHE_MOUNT}/v5filler.img" || die "fallocate ${bytes} failed"
  df -h "${STARGZ_CACHE_MOUNT}" | tail -1
}

trial() { # trial <arm> <pct> <rep>
  local arm="$1" pct="$2" rep="$3"
  local out="${RESULTS_DIR}/v2/${arm}-${pct}pct-rep${rep}"; mkdir -p "${out}"
  local pod="v2-${arm}-${pct}-${rep}"

  log "=== V2 trial arm=${arm} prefill=${pct}% rep=${rep} ==="
  hard_reset || { log "hard_reset failed; marking trial INVALID"; mv "${out}" "${out}-INVALID" 2>/dev/null; return 0; }
  prefill "${pct}"

  {
    echo "experiment=V2"; echo "arm=${arm}"; echo "prefill_pct=${pct}"; echo "rep=${rep}"
    echo "partition_bytes=${PART_BYTES}"
    echo "budget_bytes=$([ "${arm}" = ours ] && echo "${CACHE_BUDGET_BYTES}" || echo 0)"
    echo "sha=$([ "${arm}" = ours ] && echo "${OUR_SHA}" || echo "${STARGZ_VER}")"
    echo "started_utc=$(date -u +%FT%TZ)"
    df -B1 "${STARGZ_CACHE_MOUNT}" | tail -1
  } > "${out}/meta.txt"

  start_sampler "${out}/sampler.csv" 10
  trap 'stop_sampler' RETURN

  local t0 ready_s sweep_s
  t0=$(now)
  deploy_pod "${pod}" "${IMG}" normal 3
  if ! wait_for 300 "pod ready" pod_ready "${pod}"; then
    kubectl -n "${TEST_NS}" describe pod "${pod}" > "${out}/pod-describe.txt" 2>&1 || true
    echo "ready=NEVER" >> "${out}/meta.txt"
  else
    ready_s=$(elapsed "${t0}"); echo "deploy_to_ready_s=${ready_s}" >> "${out}/meta.txt"
  fi

  local st0; st0=$(now)
  full_read "${pod}" 280 > "${out}/full-read.txt" 2>&1 || true
  sweep_s=$(elapsed "${st0}"); echo "sweep_s=${sweep_s}" >> "${out}/meta.txt"

  sleep 10; stop_sampler; trap - RETURN
  sg_metrics > "${out}/metrics-after.txt"
  docker exec "$(NODE_CTR)" journalctl -u stargz-snapshotter --no-pager > "${out}/journal-stargz.txt" 2>&1 || true
  docker exec "$(NODE_CTR)" sh -c 'cat /var/log/stargz-fuse-manager.log 2>/dev/null' > "${out}/fuse-manager.log" 2>&1 || true
  # v4 s4 finding: grepping only the snapshotter journal undercounts ENOSPC by
  # ~40% when fuse_manager is on. Count both.
  { echo "journal=$(grep -ci 'no space left' "${out}/journal-stargz.txt" || echo 0)"
    echo "fuse_manager=$(grep -ci 'no space left' "${out}/fuse-manager.log" || echo 0)"; } > "${out}/enospc-counts.txt"
  kubectl -n "${TEST_NS}" get events --sort-by=.lastTimestamp > "${out}/pod-events.txt" 2>&1 || true
  teardown_pod "${pod}"

  { grep -E '^(READ|ERRNOS|DIRSTAT|LISTDIR)' "${out}/full-read.txt" || true
    echo "--- enospc ---"; cat "${out}/enospc-counts.txt"
    echo "--- writes_skipped ---"
    metric_sum "$(cat "${out}/metrics-after.txt")" stargz_fs_cache_writes_skipped_total
    echo; echo "--- evictions ---"
    metric_sum "$(cat "${out}/metrics-after.txt")" stargz_fs_cache_evictions_total; echo
  } > "${out}/SUMMARY.txt"
  cat "${out}/SUMMARY.txt"
}

mkdir -p "${RESULTS_DIR}/v2"
log "V2: our build first, all levels"
switch_arm ours
for pct in ${LEVELS}; do
  for rep in $(seq 1 "${REPS}"); do trial ours "${pct}" "${rep}"; done
done

log "V2: vanilla ${STARGZ_VER} control at 90% -- the negative control"
switch_arm vanilla
trial vanilla 90 1
log "V2: restoring our arm"
switch_arm ours

# one CSV across every trial, for the report table
{
  echo "arm,prefill_pct,rep,ready_s,sweep_s,attempted,ok,err,bytes,writes_skipped,evictions,enospc_journal,enospc_fm"
  for d in "${RESULTS_DIR}"/v2/*/; do
    [ -f "${d}/meta.txt" ] || continue
    a=$(awk -F= '/^arm=/{print $2}' "${d}/meta.txt")
    p=$(awk -F= '/^prefill_pct=/{print $2}' "${d}/meta.txt")
    r=$(awk -F= '/^rep=/{print $2}' "${d}/meta.txt")
    rd=$(awk -F= '/^deploy_to_ready_s=/{print $2}' "${d}/meta.txt")
    sw=$(awk -F= '/^sweep_s=/{print $2}' "${d}/meta.txt")
    read -r at ok er by <<<"$(sed -n 's/.*attempted=\([0-9]*\) ok=\([0-9]*\) err=\([0-9]*\) bytes=\([0-9]*\).*/\1 \2 \3 \4/p' "${d}/full-read.txt" 2>/dev/null | head -1)"
    ws=$(metric_sum "$(cat "${d}/metrics-after.txt" 2>/dev/null)" stargz_fs_cache_writes_skipped_total)
    ev=$(metric_sum "$(cat "${d}/metrics-after.txt" 2>/dev/null)" stargz_fs_cache_evictions_total)
    ej=$(awk -F= '/^journal=/{print $2}' "${d}/enospc-counts.txt" 2>/dev/null)
    ef=$(awk -F= '/^fuse_manager=/{print $2}' "${d}/enospc-counts.txt" 2>/dev/null)
    echo "${a},${p},${r},${rd},${sw},${at},${ok},${er},${by},${ws:-},${ev:-},${ej:-},${ef:-}"
  done
} > "${RESULTS_DIR}/v2/v2-summary.csv"
column -s, -t < "${RESULTS_DIR}/v2/v2-summary.csv"
log "V2 done -> ${RESULTS_DIR}/v2"
