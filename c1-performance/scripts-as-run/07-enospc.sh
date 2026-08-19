#!/usr/bin/env bash
# v3 node-host, Step 5.4: controlled ENOSPC experiment. 140GB image, 100GB
# loopback stargz chunk-cache (< image size) -- full read MUST eventually
# exhaust the cache. Records: bytes read before first I/O error, what the
# app-level read sees, pod status in k8s (stays "Ready=True" while lying?),
# stargz-grpc logs around the failure. Thesis: "lazy pod that lies."
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl
OUT="${RESULTS_DIR}/enospc-140g.txt"
CACHE_CSV="${RESULTS_DIR}/cache_growth.csv"
[ -f "${CACHE_CSV}" ] || echo "size_gb,phase,t_s,cache_bytes" > "${CACHE_CSV}"
STARGZ_CACHE_ROOT_IN_NODE="/var/lib/containerd-stargz-grpc"
NAME="b-estargz-enospc-140g"
IMG="${MODEL_IMG_PREFIX}:estargz-140g"

stargz_cache_bytes() {
  docker exec "${CLUSTER_NAME}-control-plane" du -sb "${STARGZ_CACHE_ROOT_IN_NODE}" 2>/dev/null | awk '{print $1}'
}

log "ENOSPC experiment: fresh cold deploy of 140g eStargz against 100GB loopback cache"
kubectl -n "${TEST_NS}" delete isvc "${NAME}" --ignore-not-found >/dev/null
wait_for 300 "pods gone" sh -c "! kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${NAME} -o name | grep -q pod" || true
node_rmi "${IMG}"
docker exec "${CLUSTER_NAME}-control-plane" crictl rmi --prune >/dev/null 2>&1 || true
sleep 3

NAME="${NAME}" TEST_NS="${TEST_NS}" IMAGE_REF="${IMG}" MINIO_BUCKET="${MINIO_BUCKET}" SIZE_TAG="x" \
  envsubst < "${BENCH_ROOT}/templates/isvc-oci-native.yaml" | kubectl apply -f - >/dev/null
wait_for 300 "Ready ${NAME}" bash -c \
  "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${NAME} -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
  || die "pod never became Ready -- cannot run ENOSPC read test"
POD=$(isvc_pod "${TEST_NS}" "${NAME}")
log "pod ${POD} Ready, starting full sequential read + cache sampler"

t_sample0=$(now)
( while true; do
    b=$(stargz_cache_bytes || echo "")
    [ -n "${b}" ] && echo "140,enospc,$(elapsed "${t_sample0}"),${b}" >> "${CACHE_CSV}"
    sleep 5
  done ) &
SAMPLER_PID=$!

log "running one-file-at-a-time read loop in pod (stops at first I/O error)"
READ_LOG=$(kubectl -n "${TEST_NS}" exec "${POD}" -c kserve-container -- sh -c '
  total_bytes=0
  total_files=0
  ok_files=0
  for f in $(find /mnt/models -type f | sort); do
    total_files=$((total_files+1))
    sz=$(wc -c < "$f" 2>&1)
    rc=$?
    if [ "$rc" != "0" ]; then
      echo "STOPPED_AT_FILE=$f AFTER_OK_FILES=$ok_files AFTER_BYTES=$total_bytes ERROR=\"$sz\""
      exit 1
    fi
    total_bytes=$((total_bytes+sz))
    ok_files=$((ok_files+1))
  done
  echo "COMPLETED_ALL_FILES=$total_files TOTAL_BYTES=$total_bytes"
' 2>&1) || READ_RC=$?
READ_RC="${READ_RC:-0}"
t_read=$(elapsed "${t_sample0}")

kill "${SAMPLER_PID}" 2>/dev/null || true

log "read loop exited rc=${READ_RC} after ${t_read}s"
{
  echo "=== ENOSPC experiment: 140g eStargz vs 100GB loopback chunk-cache ==="
  echo "read loop exit code: ${READ_RC}"
  echo "elapsed: ${t_read}s"
  echo "--- read loop output (last lines) ---"
  echo "${READ_LOG}" | tail -20
  echo
  echo "--- pod status (k8s view -- does it still claim Ready?) ---"
  kubectl -n "${TEST_NS}" get pod "${POD}" -o wide
  kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.conditions}' | jq . 2>/dev/null || kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.conditions}'
  echo
  echo "--- container restart count ---"
  kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.containerStatuses[*].restartCount}'
  echo
  echo "--- predict still 200 after ENOSPC? (does the pod 'lie') ---"
  kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -s -o /dev/null -w 'predict_http_code=%{http_code}\n' --max-time 10 -X POST \
    -H 'Content-Type: application/json' -d '{"instances": [[6.8, 2.8, 4.8, 1.4]]}' \
    "http://${NAME}-predictor.${TEST_NS}.svc.cluster.local/v1/models/${NAME}:predict" || echo "predict_http_code=CURL_FAILED"
  echo
  echo "--- final stargz chunk-cache size vs 100GB loopback ---"
  docker exec "${CLUSTER_NAME}-control-plane" df -h "${STARGZ_CACHE_ROOT_IN_NODE}"
  echo
  echo "--- stargz-grpc log tail (around the failure) ---"
  docker exec "${CLUSTER_NAME}-control-plane" tail -80 /var/log/stargz-grpc.log
} | tee "${OUT}"

log "ENOSPC experiment done -> ${OUT}"
