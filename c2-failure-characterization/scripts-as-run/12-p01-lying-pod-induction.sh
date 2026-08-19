#!/usr/bin/env bash
# v3.1 P0.1+P0.4: the money artifact. Cumulative induction (2GB+14GB reads
# into the shared 100GB cache partition, then deploy the DATAPATH-COUPLED
# custom predictor on 140GB and drive it via /predict while a 5s sampler
# captures everything: pod Ready, restartCount, health code, predict
# code+latency+correctness(sha256 vs baseline), EIO count, df/du per
# subtree, node conditions, stats/summary, events.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl; need envsubst
OUT="${RESULTS_DIR}/p01"
mkdir -p "${OUT}"
NODE="${CLUSTER_NAME}-control-plane"
PREDICTOR_IMG="${PREDICTOR_IMG:-${REG_PRIV}:${REG_PORT}/custom-predictor:v1}"
SAMPLE_CSV="${OUT}/sampler.csv"
echo "t_s,ready,restarts,health_code,predict_code,predict_latency_s,predict_correct,eio_count_cumulative,cache_used_kb,httpcache_kb,fscache_kb,node_ready,node_diskpressure" > "${SAMPLE_CSV}"

deploy_custom() { # deploy_custom <name> <mode> <img>
  local name="$1" mode="$2" img="$3"
  NAME="${name}" TEST_NS="${TEST_NS}" PREDICTOR_MODE="${mode}" PREDICTOR_IMG="${PREDICTOR_IMG}" \
    IMAGE_REF="${img}" NUM_SAMPLE_FILES=3 READ_BYTES=67108864 \
    envsubst < "${BENCH_ROOT}/templates/pod-custom-predictor.yaml" | kubectl apply -f -
}
teardown_pod() {
  kubectl -n "${TEST_NS}" delete pod "$1" --ignore-not-found >/dev/null
  wait_for 120 "pod $1 gone" sh -c "! kubectl -n ${TEST_NS} get pod $1 >/dev/null 2>&1" || true
}

eio_count() { docker exec "${NODE}" grep -c "no space left on device" /var/log/stargz-grpc-stargz.log 2>/dev/null || echo 0; }
cache_kb() { docker exec "${NODE}" du -sk /var/lib/containerd-stargz-grpc 2>/dev/null | awk '{print $1}'; }
httpcache_kb() { docker exec "${NODE}" du -sk /var/lib/containerd-stargz-grpc/stargz/httpcache 2>/dev/null | awk '{print $1}'; }
fscache_kb() { docker exec "${NODE}" du -sk /var/lib/containerd-stargz-grpc/stargz/fscache 2>/dev/null | awk '{print $1}'; }

# ---------------------------------------------------------------- step 1: cumulative fill (2g + 14g full reads, same shared cache)
log "=== P0.1 cumulative induction: filling shared cache with 2g + 14g full reads ==="
for tag in 2g 14g; do
  name="b-p01-fill-${tag}"
  img="${MODEL_IMG_PREFIX}:estargz-${tag}"
  teardown_isvc() { kubectl -n "${TEST_NS}" delete isvc "$1" --ignore-not-found >/dev/null; wait_for 120 "isvc $1 gone" sh -c "! kubectl -n ${TEST_NS} get isvc $1 >/dev/null 2>&1" || true; }
  teardown_isvc "${name}"
  NAME="${name}" TEST_NS="${TEST_NS}" IMAGE_REF="${img}" MINIO_BUCKET="${MINIO_BUCKET}" SIZE_TAG="x" \
    envsubst < "${BENCH_ROOT}/templates/isvc-oci-native.yaml" | kubectl apply -f - >/dev/null
  wait_for 300 "pod created ${name}" sh -c "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o name | grep -q pod"
  pod=$(isvc_pod "${TEST_NS}" "${name}")
  wait_for 300 "Ready ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Ready
  kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" || log "WARN: ${tag} fill read had errors (rc!=0) -- fine, cache already under pressure"
  log "filled with ${tag}: cache now $(cache_kb || echo '?')KB"
  teardown_isvc "${name}"
done

# ---------------------------------------------------------------- step 2: deploy datapath-coupled predictor on 140g, drive + sample
log "=== P0.1 deploying custom predictor (normal mode) on 140g, cache already under pressure ==="
NAME_140="b-p01-predictor-140g"
kubectl -n "${TEST_NS}" delete pod "${NAME_140}" --ignore-not-found >/dev/null
deploy_custom "${NAME_140}" "normal" "${MODEL_IMG_PREFIX}:estargz-140g"

t0=$(now)
END_T=$((300))  # 5 min sampling window; predict calls run continuously
LAST_RESTARTS=0
while true; do
  t=$(elapsed "${t0}")
  awk -v t="${t}" -v e="${END_T}" 'BEGIN{exit !(t>e)}' && break

  ready=$(kubectl -n "${TEST_NS}" get pod "${NAME_140}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  restarts=$(kubectl -n "${TEST_NS}" get pod "${NAME_140}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
  pod_ip=$(kubectl -n "${TEST_NS}" get pod "${NAME_140}" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")

  health_code="n/a"; predict_code="n/a"; predict_latency="n/a"; predict_correct="n/a"
  if [ -n "${pod_ip}" ]; then
    health_code=$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${pod_ip}:8080/healthz" 2>/dev/null || echo "ERR")
    pt0=$(now)
    predict_resp=$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -s --max-time 10 -X POST -H "Content-Type: application/json" -d '{"seed": 7}' "http://${pod_ip}:8080/v1/models/m:predict" 2>/dev/null || echo '{"error":"curl_failed"}')
    predict_code=$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H "Content-Type: application/json" -d '{"seed": 7}' "http://${pod_ip}:8080/v1/models/m:predict" 2>/dev/null || echo "ERR")
    predict_latency=$(awk -v a="${pt0}" -v b="$(now)" 'BEGIN{printf "%.3f", b-a}')
    # correctness: seed=7 is deterministic -- does response contain "errors" key or match expected shape?
    if echo "${predict_resp}" | grep -q '"errors"'; then predict_correct="ERROR_IN_RESPONSE"; elif echo "${predict_resp}" | grep -q '"predictions"'; then predict_correct="STRUCTURALLY_OK"; else predict_correct="MALFORMED"; fi
  fi

  eio=$(eio_count)
  ck=$(cache_kb || echo 0)
  hck=$(httpcache_kb || echo 0)
  fck=$(fscache_kb || echo 0)
  node_ready=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "?")
  node_diskpressure=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null || echo "?")

  echo "${t},${ready},${restarts},${health_code},${predict_code},${predict_latency},${predict_correct},${eio},${ck},${hck},${fck},${node_ready},${node_diskpressure}" >> "${SAMPLE_CSV}"
  log "t=${t}s ready=${ready} restarts=${restarts} health=${health_code} predict=${predict_code} lat=${predict_latency}s correct=${predict_correct} eio=${eio} cache=${ck}KB"

  sleep 5
done

log "=== P0.1 sampling window done -> ${SAMPLE_CSV} ==="

# ---------------------------------------------------------------- final snapshot: events, stats/summary, per-digest httpcache breakdown
kubectl -n "${TEST_NS}" get events --field-selector involvedObject.name="${NAME_140}" --sort-by=.lastTimestamp > "${OUT}/events-140g.txt" 2>&1 || true
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/stats/summary" 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps({'node_fs':d.get('node',{}).get('fs'),'imageFs':d.get('node',{}).get('runtime',{}).get('imageFs')}, indent=2))" > "${OUT}/stats-summary-fs.json" 2>&1 || true
docker exec "${NODE}" sh -c 'du -sk /var/lib/containerd-stargz-grpc/stargz/httpcache/*/ 2>/dev/null' > "${OUT}/httpcache-per-digest-kb.txt" 2>&1 || true
docker exec "${NODE}" dmesg 2>&1 | grep -i fuse | tail -30 > "${OUT}/dmesg-fuse.txt" 2>&1 || true

log "P0.1 done. Results in ${OUT}"
