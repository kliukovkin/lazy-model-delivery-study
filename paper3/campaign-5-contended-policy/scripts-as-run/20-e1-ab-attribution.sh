#!/usr/bin/env bash
# E1 [P0] -- attributing the 16%.
#
# RUN-REPORT-v7 s5.2 recorded our arm completing a 150GB sweep in 1432.9/1454.7s
# against v6's 1235.4/1240.9s on 9829d7cf, and explicitly declined to blame fix
# round 2 because the two spikes ran on different instances on different days.
# This removes that confound: both builds, one session, one instance, identical
# pre-fill, alternating A-B-A-B.
#
# The hypothesis on record (PRE-REGISTRATION-v8 s1.3) is H0 - that the gap was
# cross-session variation. At 50% pre-fill the budget never binds, so fix round
# 2's extra work is one statfs per drain, which cannot plausibly cost 16%.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

IMG="${MODEL_IMG_PREFIX}:estargz-140g"
LEVEL="${LEVEL:-50}"
SEQUENCE="${SEQUENCE:-prev sut prev sut}"   # A B A B
E1="${RESULTS_DIR}/e1"
NODE="$(NODE_CTR)"
PART_BYTES=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')

binsrc_for() { case "$1" in sut) echo /data/stargz-bin-ours ;; prev) echo /data/stargz-bin-prev ;; esac; }

prefill() {
  local pct="$1" bytes
  sudo rm -f "${STARGZ_CACHE_MOUNT}"/v8filler.img
  [ "${pct}" -eq 0 ] && return 0
  bytes=$(( PART_BYTES * pct / 100 ))
  sudo fallocate -l "${bytes}" "${STARGZ_CACHE_MOUNT}/v8filler.img" || die "fallocate ${bytes} failed"
}

arm() { # arm <index> <build>
  local idx="$1" build="$2" src out
  src=$(binsrc_for "${build}")
  out="${E1}/run${idx}-${build}"; mkdir -p "${out}"
  log "=== E1 run ${idx}: build=${build} ($(basename ${src})) prefill=${LEVEL}% ==="

  CACHE_POLICY=lru BINSRC="${src}" ARM_LABEL=ours FM_METRICS_ADDRESS="" \
    CACHE_ACCOUNTING=true "$(dirname "$0")/05-setup-stargz.sh" > "${out}/setup.log" 2>&1 \
    || { tail -30 "${out}/setup.log"; die "setup failed for ${build}"; }
  hard_reset || die "hard_reset failed"

  # Refuse to measure through a dead index.
  local fds; fds=$(db_open_fd_count)
  [ "${fds:-0}" -ge 1 ] || die "accounting index not open; this arm would not be comparable"

  prefill "${LEVEL}"
  { echo "experiment=E1"; echo "run_index=${idx}"; echo "build=${build}"
    echo "binsrc=${src}"
    echo "sha=$(awk -F= '/^sha=/{print $2}' "${src}/PROVENANCE.txt" 2>/dev/null)"
    echo "prefill_pct=${LEVEL}"; echo "partition_bytes=${PART_BYTES}"
    echo "budget_bytes=${CACHE_BUDGET_BYTES}"
    echo "index_open_fds=${fds}"
    echo "started_utc=$(date -u +%FT%TZ)"
    df -B1 "${STARGZ_CACHE_MOUNT}" | tail -1; } > "${out}/meta.txt"

  start_sampler "${out}/sampler.csv" 10
  trap 'stop_sampler' RETURN

  local pod="e1-${build}-${idx}"
  teardown_pod "${pod}"
  local t0; t0=$(now)
  deploy_pod "${pod}" "${IMG}" normal 3
  wait_for 300 "pod ready" pod_ready "${pod}" || log "  WARN: pod not Ready"
  echo "deploy_to_ready_s=$(elapsed "${t0}")" >> "${out}/meta.txt"

  log "  full 280-file sweep; wall clock is the measurement"
  local s0; s0=$(now)
  full_read "${pod}" 280 > "${out}/full-read.txt" 2>&1 || true
  echo "sweep_s=$(elapsed "${s0}")" >> "${out}/meta.txt"
  grep -E '^(READ|ERRNOS)' "${out}/full-read.txt" || true

  sleep 10; stop_sampler; trap - RETURN
  sg_metrics_snapshotter > "${out}/metrics-after.txt"
  df -B1 "${STARGZ_CACHE_MOUNT}" > "${out}/df-after.txt"
  echo "ended_utc=$(date -u +%FT%TZ)" >> "${out}/meta.txt"
  teardown_pod "${pod}"
  sudo rm -f "${STARGZ_CACHE_MOUNT}"/v8filler.img

  bash "$(dirname "$0")/91-collect-one.sh" "e1/run${idx}-${build}" || log "  WARN: collection failed"
}

mkdir -p "${E1}"
i=0
for b in ${SEQUENCE}; do i=$((i+1)); arm "${i}" "${b}"; done
python3 "$(dirname "$0")/20-e1-verdict.py" "${E1}" | tee "${E1}/E1-RESULT.txt"
log "E1 done -> ${E1}"
