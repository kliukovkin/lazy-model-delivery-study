#!/usr/bin/env bash
# v3 node-host, Step 6: SOCI measurements -- reps 1-3 from step 5 (TTFP cold,
# sustained read cold, sustained read warm), scheme="soci", variants A and B
# at 14GB (timeboxed 2h total for the whole SOCI step; no ENOSPC repeat).
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl; need envsubst
csv_init "${CSV}"
PREDICT_PAYLOAD='{"instances": [[6.8, 2.8, 4.8, 1.4]]}'
SOCI_VARIANTS="${SOCI_VARIANTS:-A B}"
SOCI_SIZE="${SOCI_SIZE:-14}"

img_ref() { echo "${MODEL_IMG_PREFIX}:$1"; } # <variant>-<size>g

predict_200() {
  local url="http://$1-predictor.${TEST_NS}.svc.cluster.local/v1/models/$1:predict"
  local code
  code=$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    -H 'Content-Type: application/json' -d "${PREDICT_PAYLOAD}" "${url}" 2>/dev/null) || return 1
  [ "${code}" = "200" ]
}

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

ttfp_cold() { # ttfp_cold <variant> <size> <rep>
  local variant="$1" size="$2" rep="$3"
  local tag="${size}g"
  local name="b-soci-ttfp-${variant,,}-${tag//./-}-${rep}"
  local img; img=$(img_ref "${variant}-${tag}")

  if awk -F, -v s="soci-ttfp" -v v="${variant}" -v sz="${size}" -v r="${rep}" \
      'NR>1 && $1==s && $15==v && $2==sz && $4==r {f=1} END{exit !f}' "${CSV}" 2>/dev/null; then
    log "skip (recorded): ${name}"; return
  fi

  node_rmi "${img}"
  docker exec "${CLUSTER_NAME}-control-plane" crictl rmi --prune >/dev/null 2>&1 || true
  sleep 3

  local t0; t0=$(now)
  deploy_isvc "${name}" "${img}"
  wait_for 120 "pod created ${name}" sh -c \
    "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o name | grep -q pod" \
    || { echo "soci-ttfp,${size},cold,${rep},,,,,,,,,,TIMEOUT_POD_CREATE,${variant},8,gzip" >> "${CSV}"; teardown_isvc "${name}"; return; }
  local pod; pod=$(isvc_pod "${TEST_NS}" "${name}")
  local notes=""
  wait_for 300 "Initialized ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Initialized || notes="${notes}TIMEOUT_INIT;"
  wait_for 300 "Ready ${pod}"       pod_condition_true "${TEST_NS}" "${pod}" Ready       || notes="${notes}TIMEOUT_READY;"
  wait_for 300 "first 200 ${name}" predict_200 "${name}" || notes="${notes}TIMEOUT_PREDICT;"
  local t_pred; t_pred=$(elapsed "${t0}")
  local pull; pull=$(pull_seconds_from_events "${TEST_NS}" "${pod}" "model-ballast" || true)

  echo "soci-ttfp,${size},cold,${rep},,,,,,${t_pred},${pull:-},,${pod},${notes},${variant},8,gzip" >> "${CSV}"
  log "SOCI TTFP ${name}: total=${t_pred}s pull=${pull:-n/a}${notes:+ notes=${notes}}"
  teardown_isvc "${name}"
}

sustained_read() { # sustained_read <variant> <size> <mode> <rep>
  local variant="$1" size="$2" mode="$3" rep="$4"
  local tag="${size}g"
  local name="b-soci-read-${variant,,}-${tag//./-}"
  local img; img=$(img_ref "${variant}-${tag}")

  if awk -F, -v s="soci-read" -v v="${variant}" -v sz="${size}" -v m="${mode}" -v r="${rep}" \
      'NR>1 && $1==s && $15==v && $2==sz && $3==m && $4==r {f=1} END{exit !f}' "${CSV}" 2>/dev/null; then
    log "skip (recorded): ${name} ${mode} rep${rep}"; return
  fi

  if [ "${mode}" = "cold" ] && [ "${rep}" = "1" ]; then
    node_rmi "${img}"
    docker exec "${CLUSTER_NAME}-control-plane" crictl rmi --prune >/dev/null 2>&1 || true
    sleep 3
    deploy_isvc "${name}" "${img}"
    wait_for 300 "Ready ${name}" bash -c \
      "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
  fi

  local pod; pod=$(isvc_pod "${TEST_NS}" "${name}")
  [ -n "${pod}" ] || die "no pod found for ${name}"

  local t0; t0=$(now)
  local rc=0
  kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- \
    sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" || rc=$?
  local t_read; t_read=$(elapsed "${t0}")

  local notes=""
  [ "${rc}" != "0" ] && notes="READ_ERROR_rc${rc};"
  echo "soci-read,${size},${mode},${rep},,,,,,${t_read},,,${pod},${notes},${variant},8,gzip" >> "${CSV}"
  log "SOCI sustained-read ${name} mode=${mode} rep${rep}: ${t_read}s${notes:+ notes=${notes}}"
}

log "v3 SOCI measurements: variants=[${SOCI_VARIANTS}] size=${SOCI_SIZE}g"
for variant in ${SOCI_VARIANTS}; do
  for rep in 1 2 3; do
    ttfp_cold "${variant}" "${SOCI_SIZE}" "${rep}"
  done
  for rep in 1 2 3; do
    if [ "${rep}" != "1" ]; then
      teardown_isvc "b-soci-read-${variant,,}-${SOCI_SIZE}g"
      node_rmi "$(img_ref "${variant}-${SOCI_SIZE}g")"
      docker exec "${CLUSTER_NAME}-control-plane" crictl rmi --prune >/dev/null 2>&1 || true
      sleep 3
      deploy_isvc "b-soci-read-${variant,,}-${SOCI_SIZE}g" "$(img_ref "${variant}-${SOCI_SIZE}g")"
      wait_for 300 "Ready b-soci-read-${variant,,}-${SOCI_SIZE}g" bash -c \
        "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=b-soci-read-${variant,,}-${SOCI_SIZE}g -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    fi
    sustained_read "${variant}" "${SOCI_SIZE}" "cold" "${rep}"
  done
  for rep in 1 2 3; do
    sustained_read "${variant}" "${SOCI_SIZE}" "warm" "${rep}"
  done
  teardown_isvc "b-soci-read-${variant,,}-${SOCI_SIZE}g"
  log "SOCI variant ${variant} done"
done

log "SOCI measurements done."
