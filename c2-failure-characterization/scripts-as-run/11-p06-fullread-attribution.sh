#!/usr/bin/env bash
# v3.1 P0.6: eStargz 14GB + 140GB full-read on the BIG (/data-backed) cache
# -- sufficient headroom, no ENOSPC -- with attribution (where does 105s-23s
# go for 14GB: network vs FUSE vs CPU) and a FUSE-tax isolation number
# (warm-FUSE full read vs the same bytes read directly off an eager
# ImageVolume mount, no FUSE in the path).
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl; need envsubst
OUT="${RESULTS_DIR}/p06"
mkdir -p "${OUT}"
NODE="${CLUSTER_NAME}-control-plane"

deploy_isvc() {
  local name="$1" img="$2"
  NAME="${name}" TEST_NS="${TEST_NS}" IMAGE_REF="${img}" MINIO_BUCKET="${MINIO_BUCKET}" SIZE_TAG="x" \
    envsubst < "${BENCH_ROOT}/templates/isvc-oci-native.yaml" | kubectl apply -f - >/dev/null
}
teardown_isvc() {
  kubectl -n "${TEST_NS}" delete isvc "$1" --ignore-not-found >/dev/null
  wait_for 300 "pods gone for $1" sh -c \
    "! kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=$1 -o name | grep -q pod" || true
}

net_bytes_rx() { # sum RX bytes of the node-host's primary NIC (docker0 excluded)
  cat /sys/class/net/*/statistics/rx_bytes 2>/dev/null | awk '{s+=$1} END{print s}'
}

run_size() { # run_size <size_gb>
  local size="$1"
  local tag="${size}g"
  local img="${MODEL_IMG_PREFIX}:estargz-${tag}"
  local name="b-p06-${tag}"

  log "=== P0.6 ${tag}: cold TTFP + sustained read on big cache ==="
  teardown_isvc "${name}"
  node_rmi "${img}"
  docker exec "${NODE}" crictl rmi --prune >/dev/null 2>&1 || true
  sleep 3

  # --- sar/pidstat capture window starts now ---
  local sarlog="${OUT}/sar-node-${tag}.txt" pidstatlog="${OUT}/pidstat-stargz-${tag}.txt"
  sar -n DEV 2 > "${sarlog}" 2>&1 &
  local sar_pid=$!
  STARGZ_PID=$(docker exec "${NODE}" pgrep -f 'containerd-stargz-grpc.*stargz/containerd-stargz-grpc.sock' | head -1)
  ( docker exec "${NODE}" pidstat -p "${STARGZ_PID}" 2 > "${pidstatlog}" 2>&1 ) &
  local pidstat_pid=$!
  # NOTE: registry access-log capture happens from the OPERATOR's machine
  # (bracketing this whole script), NOT via an ssh hop from node-host to
  # registry-host -- same pitfall as v3's calibration script (oci-bench.pem
  # only exists on the operator's laptop, not on either EC2 host).

  local rx0; rx0=$(net_bytes_rx)
  local t0; t0=$(now)
  deploy_isvc "${name}" "${img}"
  wait_for 300 "pod created ${name}" sh -c \
    "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o name | grep -q pod"
  local pod; pod=$(isvc_pod "${TEST_NS}" "${name}")
  wait_for 900 "Ready ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Ready || log "WARN: Ready wait timed out for ${pod}, continuing anyway (note in summary)"
  local t_ttfp; t_ttfp=$(elapsed "${t0}")
  local pull; pull=$(pull_seconds_from_events "${TEST_NS}" "${pod}" "model-ballast" || true)
  local rx_ttfp; rx_ttfp=$(net_bytes_rx)

  # du-curve sampler during the sustained read (per-subtree, KB not apparent-size-bytes -- v3 §11 fix)
  local ducsv="${OUT}/du-curve-${tag}.csv"
  echo "t_s,httpcache_kb,fscache_kb,total_kb" > "${ducsv}"
  local t_du0; t_du0=$(now)
  ( while true; do
      root="/var/lib/containerd-stargz-grpc-big"
      hc=$(docker exec "${NODE}" du -sk "${root}/stargz/httpcache" 2>/dev/null | awk '{print $1}')
      fc=$(docker exec "${NODE}" du -sk "${root}/stargz/fscache" 2>/dev/null | awk '{print $1}')
      tot=$(docker exec "${NODE}" du -sk "${root}" 2>/dev/null | awk '{print $1}')
      echo "$(elapsed "${t_du0}"),${hc:-0},${fc:-0},${tot:-0}" >> "${ducsv}"
      sleep 5
    done ) &
  local du_pid=$!

  local t_read0; t_read0=$(now)
  local rx_read0; rx_read0=$(net_bytes_rx)
  local rc=0
  kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- \
    sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" || rc=$?
  local t_read; t_read=$(elapsed "${t_read0}")
  local rx_read1; rx_read1=$(net_bytes_rx)

  kill "${du_pid}" 2>/dev/null || true
  kill "${sar_pid}" 2>/dev/null || true
  kill "${pidstat_pid}" 2>/dev/null || true

  local net_bytes_during_read=$((rx_read1 - rx_read0))

  # --- warm re-read (same pod, FUSE cache fully resident) ---
  local t_warm0; t_warm0=$(now)
  kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- \
    sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" || true
  local t_warm; t_warm=$(elapsed "${t_warm0}")

  {
    echo "size_gb=${size} ttfp_s=${t_ttfp} kubelet_pull=${pull:-n/a} cold_read_s=${t_read} cold_read_rc=${rc} warm_read_s=${t_warm} net_bytes_during_cold_read=${net_bytes_during_read}"
  } | tee -a "${OUT}/summary.txt"

  echo "${name} ${pod}" >> "${OUT}/.pods-to-cleanup-later"
  teardown_isvc "${name}"
}

# ---------------------------------------------------------------- FUSE-tax isolation
# warm-cache full read via FUSE (above, size=14) vs direct read of the SAME
# bytes off an EAGER ImageVolume mount (variant B, no FUSE anywhere in path).
fuse_tax_isolation() {
  local tag="14g"
  local eager_img="${MODEL_IMG_PREFIX}:B-${tag}" name="b-p06-fusetax-eager"
  log "=== FUSE-tax isolation: direct eager-mount read, ${tag} ==="
  teardown_isvc "${name}"
  deploy_isvc "${name}" "${eager_img}"
  wait_for 300 "pod created ${name}" sh -c \
    "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o name | grep -q pod"
  local pod; pod=$(isvc_pod "${TEST_NS}" "${name}")
  wait_for 900 "Ready ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Ready || log "WARN: Ready wait timed out for ${pod}, continuing anyway"
  # warm the page cache with one read, then time a second (matches "warm" comparison)
  kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" || true
  local t0; t0=$(now)
  kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" || true
  local t_direct; t_direct=$(elapsed "${t0}")
  echo "direct_eager_warm_read_s=${t_direct} (compare against estargz-${tag} warm_read_s in summary.txt for FUSE tax)" | tee -a "${OUT}/summary.txt"
  teardown_isvc "${name}"
}

run_size 14
# NOTE: 140GB "sufficient cache" full-read dropped -- see 01-cluster-up.sh
# comment. Only the 100GB partition proved stable in this environment;
# 140GB against it is the P0.5 pressure-matrix's job, not P0.6's.
fuse_tax_isolation

log "P0.6 done -> ${OUT}"
cat "${OUT}/summary.txt"
