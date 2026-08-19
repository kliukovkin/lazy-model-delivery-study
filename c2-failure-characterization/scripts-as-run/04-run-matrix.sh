#!/usr/bin/env bash
# v3 node-host, Step 4: SIZES_GB x VARIANTS(A/B/D) x REPS eager matrix (cold),
# + 1 s3-calibration rep/size (MinIO now lives on the OTHER host), + 2 warm
# reps of A per size (node-cache control).
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl; need envsubst; need awk
csv_init "${CSV}"

PREDICT_PAYLOAD='{"instances": [[6.8, 2.8, 4.8, 1.4]]}'

cluster_image_ref() { echo "${MODEL_IMG_PREFIX}:$1"; } # <variant>-<size>g

predict_200() {
  local url="http://$1-predictor.${TEST_NS}.svc.cluster.local/v1/models/$1:predict"
  local code
  code=$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    -H 'Content-Type: application/json' -d "${PREDICT_PAYLOAD}" "${url}" 2>/dev/null) || return 1
  [ "${code}" = "200" ]
}

# run_one <scheme> <size> <mode> <rep> <img_ref> <variant> <layers> <compression>
run_one() {
  local scheme="$1" size="$2" mode="$3" rep="$4" img="$5" variant="$6" layers="$7" compression="$8"
  local tag="${size}g"
  local name="b-${scheme}-${variant,,}-${tag//./-}-${mode}-${rep}"
  local tmpl="${BENCH_ROOT}/templates/isvc-${scheme}.yaml"
  [ -f "${tmpl}" ] || die "no template for scheme ${scheme}"

  if awk -F, -v s="${scheme}" -v sz="${size}" -v m="${mode}" -v r="${rep}" -v v="${variant}" \
      'NR>1 && $1==s && $2==sz && $3==m && $4==r && $15==v {f=1} END{exit !f}' "${CSV}" 2>/dev/null; then
    log "skip (already recorded): ${name}"
    return
  fi

  local init_timeout=3600 ready_timeout=3600
  awk -v s="${size}" 'BEGIN{exit !(s>=100)}' && { init_timeout=9000; ready_timeout=9000; }
  local notes=""

  if [ "${mode}" = "cold" ] && [ "${scheme}" = "oci-native" ]; then
    node_rmi "${img}"
    docker exec "${CLUSTER_NAME}-control-plane" crictl rmi --prune >/dev/null 2>&1 || true
    sleep 5
  fi
  local disk0; disk0=$(node_containerd_bytes)

  local t_apply; t_apply=$(now)
  NAME="${name}" TEST_NS="${TEST_NS}" IMAGE_REF="${img}" \
    MINIO_BUCKET="${MINIO_BUCKET}" SIZE_TAG="${tag}" \
    envsubst < "${tmpl}" | kubectl apply -f - >/dev/null

  local pod="" t_pod t_sched t_init t_ready t_pred
  wait_for 120 "pod created for ${name}" sh -c \
    "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o name | grep -q pod" \
    || { echo "${scheme},${size},${mode},${rep},,,,,,,,,,TIMEOUT_POD_CREATE,${variant},${layers},${compression}" >> "${CSV}"; kubectl -n "${TEST_NS}" delete isvc "${name}" --ignore-not-found >/dev/null; return; }
  t_pod=$(elapsed "${t_apply}")
  pod=$(isvc_pod "${TEST_NS}" "${name}")

  wait_for 300  "PodScheduled ${pod}"      pod_condition_true "${TEST_NS}" "${pod}" PodScheduled   || true
  t_sched=$(elapsed "${t_apply}")
  wait_for "${init_timeout}"  "Initialized ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Initialized || notes="${notes}TIMEOUT_INIT;"
  t_init=$(elapsed "${t_apply}")
  wait_for "${ready_timeout}" "Ready ${pod}"       pod_condition_true "${TEST_NS}" "${pod}" Ready       || notes="${notes}TIMEOUT_READY;"
  t_ready=$(elapsed "${t_apply}")
  wait_for 600  "first 200 from ${name}"   predict_200 "${name}"                                     || notes="${notes}TIMEOUT_PREDICT;"
  t_pred=$(elapsed "${t_apply}")

  local disk1 pull
  disk1=$(node_containerd_bytes)
  pull=$(pull_seconds_from_events "${TEST_NS}" "${pod}" "model-ballast" || true)

  local d_sched d_init d_ready d_pred
  d_sched=$(awk -v a="${t_pod}" -v b="${t_sched}" 'BEGIN{printf "%.3f", b-a}')
  d_init=$(awk -v a="${t_sched}" -v b="${t_init}" 'BEGIN{printf "%.3f", b-a}')
  d_ready=$(awk -v a="${t_init}" -v b="${t_ready}" 'BEGIN{printf "%.3f", b-a}')
  d_pred=$(awk -v a="${t_ready}" -v b="${t_pred}" 'BEGIN{printf "%.3f", b-a}')

  echo "${scheme},${size},${mode},${rep},${t_pod},${d_sched},${d_init},${d_ready},${d_pred},${t_pred},${pull:-},$((disk1-disk0)),${pod},${notes},${variant},${layers},${compression}" >> "${CSV}"
  log "${name}: total=${t_pred}s (pod=${t_pod} sched=+${d_sched} init=+${d_init} ready=+${d_ready} predict=+${d_pred} pull=${pull:-n/a})${notes:+ notes=${notes}}"

  kubectl -n "${TEST_NS}" delete isvc "${name}" --ignore-not-found >/dev/null
  wait_for 300 "pods gone for ${name}" sh -c \
    "! kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o name | grep -q pod" \
    || true
}

log "v3 eager matrix: sizes=[${SIZES_GB}] variants=[${VARIANTS}] reps=${REPS}/${REPS_LARGE}(>=100g)"
for size in ${SIZES_GB}; do
  tag="${size}g"

  for variant in ${VARIANTS}; do
    img=$(cluster_image_ref "${variant}-${tag}")
    layers=$(variant_layers "${variant}")
    compression=$(variant_compression "${variant}")
    RUNS="${REPS}"
    awk -v s="${size}" 'BEGIN{exit !(s>=100)}' && RUNS="${REPS_LARGE}"
    for rep in $(seq 1 "${RUNS}"); do
      run_one "oci-native" "${size}" "cold" "${rep}" "${img}" "${variant}" "${layers}" "${compression}"
    done
  done

  # 2 warm reps of A per size (node-cache control) -- image stays cached from A's last cold rep
  imgA=$(cluster_image_ref "A-${tag}")
  layersA=$(variant_layers A); compA=$(variant_compression A)
  for rep in 1 2; do
    run_one "oci-native" "${size}" "warm" "${rep}" "${imgA}" "A" "${layersA}" "${compA}"
  done

  log "s3 calibration rep for ${tag}"
  run_one "s3" "${size}" "cold" "1" "" "s3-control" "0" "none"
done

log "eager matrix done. Results: ${CSV}"
