#!/usr/bin/env bash
# v3.1 P0.3: mechanism/config audit + recovery matrix + micro-experiments,
# all on a single induced failure (per task: "на одном отказе по порядку").
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl; need envsubst
OUT="${RESULTS_DIR}/p03"
mkdir -p "${OUT}"
NODE="${CLUSTER_NAME}-control-plane"

deploy_isvc() {
  local name="$1" img="$2"
  NAME="${name}" TEST_NS="${TEST_NS}" IMAGE_REF="${img}" MINIO_BUCKET="${MINIO_BUCKET}" SIZE_TAG="x" \
    envsubst < "${BENCH_ROOT}/templates/isvc-oci-native.yaml" | kubectl apply -f - >/dev/null
}
teardown_isvc() {
  kubectl -n "${TEST_NS}" delete isvc "$1" --ignore-not-found >/dev/null
  wait_for 120 "isvc $1 gone" sh -c "! kubectl -n ${TEST_NS} get isvc $1 >/dev/null 2>&1" || true
}
corrupted_file_list() { # <pod>
  kubectl -n "${TEST_NS}" exec "$1" -c kserve-container -- sh -c \
    'for f in /mnt/models/ballast-*.bin; do dd if="$f" of=/dev/null bs=4M count=1 2>/dev/null || echo "$(basename $f)"; done' 2>&1
}

# ---------------------------------------------------------------- switch stargz to debug logging for this whole experiment
log "=== switching stargz-grpc to debug logging for mechanism audit ==="
docker exec "${NODE}" pkill -f containerd-stargz-grpc || true
sleep 2
docker exec -d "${NODE}" sh -c \
  "containerd-stargz-grpc --log-level debug --address /run/containerd-stargz-grpc-stargz/containerd-stargz-grpc.sock --config /etc/containerd-stargz-grpc-stargz/config.toml > /var/log/stargz-grpc-debug.log 2>&1"
sleep 3
docker exec "${NODE}" test -S /run/containerd-stargz-grpc-stargz/containerd-stargz-grpc.sock || die "stargz-grpc did not restart"

# ---------------------------------------------------------------- induce ONE clean failure (cumulative, matches P0.1's pattern)
log "=== inducing one failure: 2g+14g fill, then 140g read ==="
for tag in 2g 14g; do
  name="b-p03-fill-${tag}"; img="${MODEL_IMG_PREFIX}:estargz-${tag}"
  teardown_isvc "${name}"
  deploy_isvc "${name}" "${img}"
  wait_for 300 "pod created" sh -c "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o name | grep -q pod"
  pod=$(isvc_pod "${TEST_NS}" "${name}")
  wait_for 300 "Ready ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Ready
  kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" || true
  teardown_isvc "${name}"
done

NAME140="b-p03-fail-140g"
teardown_isvc "${NAME140}"
deploy_isvc "${NAME140}" "${MODEL_IMG_PREFIX}:estargz-140g"
wait_for 300 "pod created" sh -c "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${NAME140} -o name | grep -q pod"
POD=$(isvc_pod "${TEST_NS}" "${NAME140}")
wait_for 300 "Ready ${POD}" pod_condition_true "${TEST_NS}" "${POD}" Ready

log "log line count before induction read: $(docker exec "${NODE}" wc -l < /var/log/stargz-grpc-debug.log)"
MARK_LINE=$(docker exec "${NODE}" wc -l < /var/log/stargz-grpc-debug.log)
kubectl -n "${TEST_NS}" exec "${POD}" -c kserve-container -- sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" 2>"${OUT}/read1-stderr.txt" || true
log "induction read done, rc captured in read1-stderr.txt"

# ---------------------------------------------------------------- errno at application level: strace one cat
log "=== errno check: strace a single cat on a likely-corrupted file ==="
BAD_FILE=$(kubectl -n "${TEST_NS}" exec "${POD}" -c kserve-container -- sh -c \
  'for f in /mnt/models/ballast-*.bin; do dd if="$f" of=/dev/null bs=4M count=1 2>/dev/null || { echo "$f"; break; }; done' 2>&1 | tail -1)
log "testing file: ${BAD_FILE}"
if [ -n "${BAD_FILE}" ]; then
  # strace isn't in the sklearnserver image; run via nsenter from the node against the container's pid instead
  CPID=$(docker exec "${NODE}" crictl inspect "$(docker exec "${NODE}" crictl ps --name kserve-container -q | head -1)" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])' 2>&1)
  docker exec "${NODE}" sh -c "nsenter -t ${CPID} -m -p strace -e trace=read,openat cat ${BAD_FILE} 2>&1 | tail -20" > "${OUT}/strace-output.txt" 2>&1 || echo "strace attempt failed, see file" >> "${OUT}/strace-output.txt"
fi

# ---------------------------------------------------------------- full debug log around the failure (not grepped)
docker exec "${NODE}" sh -c "tail -n +$((MARK_LINE+1)) /var/log/stargz-grpc-debug.log" > "${OUT}/full-debug-log-around-failure.log" 2>&1
wc -l "${OUT}/full-debug-log-around-failure.log"

# ---------------------------------------------------------------- recovery matrix
log "=== recovery matrix (single failure, in order) ==="
{
echo "1) stability of corrupted-file list across 3 rereads:"
for i in 1 2 3; do
  echo "-- reread $i --"
  corrupted_file_list "${POD}"
done
} > "${OUT}/recovery-1-stability.txt" 2>&1
cat "${OUT}/recovery-1-stability.txt"

{
echo "2) free space under the LIVE pod (rm foreign httpcache digests), reread SAME pod:"
docker exec "${NODE}" df -h /var/lib/containerd-stargz-grpc
docker exec "${NODE}" sh -c "rm -rf /var/lib/containerd-stargz-grpc/stargz/httpcache/*/wip 2>/dev/null; true"
docker exec "${NODE}" df -h /var/lib/containerd-stargz-grpc
echo "reread after freeing space (same pod, same mount):"
corrupted_file_list "${POD}"
} > "${OUT}/recovery-2-free-space-live.txt" 2>&1
cat "${OUT}/recovery-2-free-space-live.txt"

{
echo "3) kubectl delete pod (restart, no prune) -- does new pod fail on first read or ok?"
kubectl -n "${TEST_NS}" delete pod "${POD}" --ignore-not-found
wait_for 300 "new pod for ${NAME140}" sh -c "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${NAME140} -o jsonpath='{.items[0].status.phase}' | grep -qE 'Running|Pending'"
NEWPOD=$(isvc_pod "${TEST_NS}" "${NAME140}")
wait_for 300 "Ready ${NEWPOD}" pod_condition_true "${TEST_NS}" "${NEWPOD}" Ready || echo "TIMEOUT_READY"
echo "new pod: ${NEWPOD}"
corrupted_file_list "${NEWPOD}"
} > "${OUT}/recovery-3-restart-no-prune.txt" 2>&1
cat "${OUT}/recovery-3-restart-no-prune.txt"

{
echo "4) prune + fresh pod (repeat v3 protocol):"
teardown_isvc "${NAME140}"
node_rmi "${MODEL_IMG_PREFIX}:estargz-140g"
docker exec "${NODE}" crictl rmi --prune >/dev/null 2>&1 || true
deploy_isvc "${NAME140}" "${MODEL_IMG_PREFIX}:estargz-140g"
wait_for 300 "pod created" sh -c "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${NAME140} -o name | grep -q pod" || true
FRESHPOD=$(isvc_pod "${TEST_NS}" "${NAME140}")
wait_for 300 "Ready ${FRESHPOD}" pod_condition_true "${TEST_NS}" "${FRESHPOD}" Ready || echo "TIMEOUT_READY"
corrupted_file_list "${FRESHPOD}"
} > "${OUT}/recovery-4-prune-fresh.txt" 2>&1
cat "${OUT}/recovery-4-prune-fresh.txt"

{
echo "5) restart stargz-grpc daemon UNDER the live pod -- mount survives/heals/ENOTCONN?"
FRESHPOD=$(isvc_pod "${TEST_NS}" "${NAME140}")
docker exec "${NODE}" pkill -f containerd-stargz-grpc || true
sleep 2
docker exec -d "${NODE}" sh -c \
  "containerd-stargz-grpc --log-level debug --address /run/containerd-stargz-grpc-stargz/containerd-stargz-grpc.sock --config /etc/containerd-stargz-grpc-stargz/config.toml > /var/log/stargz-grpc-debug2.log 2>&1"
sleep 3
echo "daemon restarted, testing read on the pod that was live during restart:"
kubectl -n "${TEST_NS}" exec "${FRESHPOD}" -c kserve-container -- sh -c 'cat /mnt/models/ballast-1.bin | wc -c' 2>&1 || echo "READ FAILED (possibly ENOTCONN or similar)"
} > "${OUT}/recovery-5-daemon-restart-live.txt" 2>&1
cat "${OUT}/recovery-5-daemon-restart-live.txt"

teardown_isvc "${NAME140}"

log "P0.3 recovery matrix done. Micro-experiments next (separate script)."
