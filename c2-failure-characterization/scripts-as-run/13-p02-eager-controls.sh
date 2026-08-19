#!/usr/bin/env bash
# v3.1 P0.2: eager-path controls for symmetry with the lazy-path findings.
#   1. eager-ENOSPC: fill /data so free < 140GB image size, apply eager
#      140GB, full events timeline, confirm Ready never happens.
#   2. eager + manual file corruption: eager pod Ready -> corrupt a model
#      file from the node side -> same sampler as P0.1. Expected: silence
#      (this IS the needed symmetry result -- lazy's novelty isn't "K8s
#      can't see corrupted files", it's "lazy corrupts files itself, under
#      default config, with no operator action").
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl; need envsubst
OUT="${RESULTS_DIR}/p02"
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

# ================================================================ P0.2.1 eager-ENOSPC
log "=== P0.2.1: filling /data so free < 140GB, then eager 140GB apply ==="
teardown_isvc "b-p02-eager-enospc"
node_rmi "${MODEL_IMG_PREFIX}:A-140g"
docker exec "${NODE}" crictl rmi --prune >/dev/null 2>&1 || true

AVAIL_KB=$(df --output=avail /data | tail -1)
TARGET_FREE_GB=100
FILL_GB=$(( (AVAIL_KB/1024/1024) - TARGET_FREE_GB ))
if [ "${FILL_GB}" -gt 0 ]; then
  log "filling /data/p02-filler.img with ${FILL_GB}GB (leaving ~${TARGET_FREE_GB}GB free, < 140GB image)"
  fallocate -l "${FILL_GB}G" /data/p02-filler.img
fi
df -h /data | tee "${OUT}/df-before-eager-enospc.txt"

t0=$(now)
deploy_isvc "b-p02-eager-enospc" "${MODEL_IMG_PREFIX}:A-140g"
# poll for up to 10 min: does it ever reach Ready? capture full event timeline throughout
: > "${OUT}/events-eager-enospc-timeline.txt"
GOT_READY="false"
for i in $(seq 1 60); do
  t=$(elapsed "${t0}")
  ready=$(kubectl -n "${TEST_NS}" get pod -l serving.kserve.io/inferenceservice=b-p02-eager-enospc -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  echo "--- t=${t}s ready=${ready} ---" >> "${OUT}/events-eager-enospc-timeline.txt"
  kubectl -n "${TEST_NS}" get events --field-selector involvedObject.kind=Pod --sort-by=.lastTimestamp 2>&1 | tail -10 >> "${OUT}/events-eager-enospc-timeline.txt"
  kubectl get nodes -o jsonpath='{.items[0].status.conditions}' 2>&1 | python3 -m json.tool >> "${OUT}/events-eager-enospc-timeline.txt" 2>&1 || true
  if [ "${ready}" = "True" ]; then GOT_READY="true"; break; fi
  sleep 10
done
echo "GOT_READY=${GOT_READY} (expected: false -- eager pull should never succeed under real ENOSPC)" | tee -a "${OUT}/summary.txt"

teardown_isvc "b-p02-eager-enospc"
rm -f /data/p02-filler.img
df -h /data | tee "${OUT}/df-after-cleanup.txt"

# ================================================================ P0.2.2 eager + manual corruption
log "=== P0.2.2: eager pod Ready, then corrupt a model file from the node side ==="
teardown_isvc "b-p02-eager-corrupt"
node_rmi "${MODEL_IMG_PREFIX}:A-2g"
deploy_isvc "b-p02-eager-corrupt" "${MODEL_IMG_PREFIX}:A-2g"
wait_for 120 "pod created" sh -c "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=b-p02-eager-corrupt -o name | grep -q pod"
pod=$(isvc_pod "${TEST_NS}" "b-p02-eager-corrupt")
wait_for 300 "Ready ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Ready

# find the backing overlayfs upper/merged dir on the node for this container's rootfs
CID=$(docker exec "${NODE}" crictl ps --name kserve-container -q 2>/dev/null | head -1)
MERGED=$(docker exec "${NODE}" sh -c "crictl inspect ${CID} 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(\"info\",{}).get(\"runtimeSpec\",{}).get(\"root\",{}).get(\"path\",\"\"))'" 2>&1)
log "container rootfs merged path (best-effort): ${MERGED}"
# corrupt via the pod's own writable... actually ImageVolume is read-only; corrupt the
# underlying containerd snapshot content directly on the node filesystem instead.
SNAP_DIR=$(docker exec "${NODE}" sh -c "find /data/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots -maxdepth 2 -newer /etc/hostname -type d -name fs 2>/dev/null | tail -1" 2>&1)
log "attempting corruption via node-side snapshot dir: ${SNAP_DIR}"
if [ -n "${SNAP_DIR}" ]; then
  docker exec "${NODE}" sh -c "find ${SNAP_DIR} -name 'ballast-1.bin' -exec sh -c 'echo CORRUPTED > {}' \\;" 2>&1 | tee "${OUT}/corruption-attempt.txt"
else
  echo "could not locate snapshot dir automatically -- see corruption-attempt.txt for manual approach" > "${OUT}/corruption-attempt.txt"
fi

sleep 5
health_code=$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://b-p02-eager-corrupt-predictor.${TEST_NS}.svc.cluster.local/" 2>/dev/null || echo "ERR")
predict_code=$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -d '{"instances": [[6.8, 2.8, 4.8, 1.4]]}' "http://b-p02-eager-corrupt-predictor.${TEST_NS}.svc.cluster.local/v1/models/b-p02-eager-corrupt:predict" 2>/dev/null || echo "ERR")
ready_after=$(kubectl -n "${TEST_NS}" get pod "${pod}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
restarts_after=$(kubectl -n "${TEST_NS}" get pod "${pod}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
{
  echo "after corrupting ballast-1.bin on the node's backing store:"
  echo "  ready=${ready_after} restarts=${restarts_after} health=${health_code} sklearn_predict=${predict_code}"
  echo "  (sklearn never reads ballast files at all -- expected: no change regardless of corruption,"
  echo "   confirming the symmetry point: node/K8s-level checks are blind to on-disk corruption for"
  echo "   ANY delivery path, eager or lazy, when the app doesn't touch the affected bytes)"
} | tee -a "${OUT}/summary.txt"

teardown_isvc "b-p02-eager-corrupt"
log "P0.2 done -> ${OUT}"
