#!/usr/bin/env bash
# V4 [P1] -- the lying pod, and whether our sentinel probe catches it.
#
# v4 s5 recorded a pod under pressure answering GET /healthz 200 and POST
# /predict 200 with byte-identical output while 262 of 280 files were unreadable.
# The standard probes cannot see that. This asks whether contrib/sentinel-probe
# can, on the vanilla build, and whether it stays quiet on ours.
#
# The sentinel probe is run alongside the pod's normal httpGet readiness rather
# than replacing it: replacing it would hide the very contrast being measured
# (standard probe green while the mount is broken). The command line is exactly
# the one contrib/sentinel-probe/README.md recommends for a readinessProbe.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

IMG="${MODEL_IMG_PREFIX}:estargz-140g"
PREFILL="${PREFILL:-90}"
PART_BYTES=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')
PROBE_SRC="${PROBE_SRC:-$HOME/sentinel-probe.sh}"
[ -f "${PROBE_SRC}" ] || die "sentinel probe not found at ${PROBE_SRC}"

switch_arm() {
  case "$1" in
    ours)    BINSRC=/data/stargz-bin-ours ARM_LABEL=ours    CACHE_ACCOUNTING=true  "$(dirname "$0")/05-setup-stargz.sh" ;;
    vanilla) BINSRC=/data/stargz-bin      ARM_LABEL=vanilla CACHE_ACCOUNTING=false "$(dirname "$0")/05-setup-stargz.sh" ;;
  esac
}

arm_run() { # arm_run <ours|vanilla>
  local arm="$1"
  local out="${RESULTS_DIR}/v4/${arm}-${PREFILL}pct"; mkdir -p "${out}"
  local pod="v4-${arm}"
  log "=== V4 arm=${arm} prefill=${PREFILL}% ==="
  switch_arm "${arm}"
  hard_reset || die "hard_reset failed"
  sudo rm -f "${STARGZ_CACHE_MOUNT}/v5filler.img"
  sudo fallocate -l "$(( PART_BYTES * PREFILL / 100 ))" "${STARGZ_CACHE_MOUNT}/v5filler.img"
  df -h "${STARGZ_CACHE_MOUNT}" | tail -1

  { echo "experiment=V4"; echo "arm=${arm}"; echo "prefill_pct=${PREFILL}"
    echo "sha=$([ "${arm}" = ours ] && echo "${OUR_SHA}" || echo "${STARGZ_VER}")"
    echo "started_utc=$(date -u +%FT%TZ)"; } > "${out}/meta.txt"

  deploy_pod "${pod}" "${IMG}" normal 3
  wait_for 300 "pod ready" pod_ready "${pod}" || { kubectl -n "${TEST_NS}" describe pod "${pod}" > "${out}/pod-describe.txt"; echo "ready=NEVER" >> "${out}/meta.txt"; }
  # `kubectl cp` requires tar in the target container; piping through exec does
  # not, and the predictor image is not guaranteed to have tar.
  kubectl -n "${TEST_NS}" exec -i "${pod}" -- sh -c 'cat > /tmp/sentinel-probe.sh' < "${PROBE_SRC}"
  kubectl -n "${TEST_NS}" exec "${pod}" -- sh -c 'chmod +x /tmp/sentinel-probe.sh; for t in find stat tail wc; do command -v $t >/dev/null || echo "MISSING_PROBE_DEP=$t"; done' 

  start_sampler "${out}/sampler.csv" 10
  trap 'stop_sampler' RETURN

  # Baseline round, before the read storm fills the volume.
  probe_round() { # probe_round <label>
    local label="$1" rc ready health predict
    set +e
    kubectl -n "${TEST_NS}" exec "${pod}" -- sh -c \
      'SENTINEL_ROOT=/mnt/models SENTINEL_TAIL_BYTES=1048576 SENTINEL_COUNT=3 SENTINEL_VERBOSE=1 sh /tmp/sentinel-probe.sh' \
      > "${out}/sentinel-${label}.txt" 2>&1
    rc=$?
    ready=$(kubectl -n "${TEST_NS}" get pod "${pod}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    health=$(kubectl -n "${TEST_NS}" exec "${pod}" -- sh -c 'curl -s -o /dev/null -w "%{http_code}" localhost:8080/healthz' 2>/dev/null)
    predict=$(kubectl -n "${TEST_NS}" exec "${pod}" -- sh -c 'curl -s -o /dev/null -w "%{http_code}" -X POST localhost:8080/predict -d "{\"seed\":7}"' 2>/dev/null)
    set -e
    echo "${label},${rc},${ready},${health},${predict}" >> "${out}/probe-rounds.csv"
    log "  ${label}: sentinel_exit=${rc} k8s_ready=${ready} healthz=${health} predict=${predict}"
  }
  echo "label,sentinel_exit,k8s_ready,healthz,predict" > "${out}/probe-rounds.csv"
  probe_round before

  log "  driving the read storm (full 280-file read)"
  full_read "${pod}" 280 > "${out}/full-read.txt" 2>&1 || true
  grep -E '^READ|^ERRNOS' "${out}/full-read.txt" || true

  probe_round after
  sleep 10; probe_round after2

  stop_sampler; trap - RETURN
  sg_metrics > "${out}/metrics-after.txt"
  docker exec "$(NODE_CTR)" journalctl -u stargz-snapshotter --no-pager > "${out}/journal-stargz.txt" 2>&1 || true
  kubectl -n "${TEST_NS}" get events --sort-by=.lastTimestamp > "${out}/pod-events.txt" 2>&1 || true
  teardown_pod "${pod}"

  { echo "arm=${arm}"
    grep -E '^READ|^ERRNOS' "${out}/full-read.txt" || true
    echo "--- probe rounds (label,sentinel_exit,k8s_ready,healthz,predict) ---"
    cat "${out}/probe-rounds.csv"
    echo "--- writes_skipped ---"; metric_sum "$(cat "${out}/metrics-after.txt")" stargz_fs_cache_writes_skipped_total; echo
  } > "${out}/SUMMARY.txt"
  cat "${out}/SUMMARY.txt"
}

mkdir -p "${RESULTS_DIR}/v4"
arm_run vanilla
arm_run ours
log "V4 done -> ${RESULTS_DIR}/v4"
