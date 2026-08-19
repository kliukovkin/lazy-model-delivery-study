#!/usr/bin/env bash
# v3 node-host, Step 5: lazy pulling (eStargz variant E) core measurements.
# For each size in SIZES_GB:
#   1. Cold TTFP x5 (apply -> first HTTP 200) + kubelet pull time
#   2. Sustained full read, cold x3, WITH a parallel cache_growth.csv sampler
#   3. Sustained full read, warm x3
# Then (140GB only, once): ENOSPC experiment against the 100GB loopback cache.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl; need envsubst; need awk
csv_init "${CSV}"
CACHE_CSV="${RESULTS_DIR}/cache_growth.csv"
[ -f "${CACHE_CSV}" ] || echo "size_gb,phase,t_s,cache_bytes" > "${CACHE_CSV}"

PREDICT_PAYLOAD='{"instances": [[6.8, 2.8, 4.8, 1.4]]}'
STARGZ_CACHE_ROOT_IN_NODE="/var/lib/containerd-stargz-grpc"  # == bind-mounted loopback

cluster_image_ref() { echo "${MODEL_IMG_PREFIX}:estargz-$1"; } # <size>g

predict_200() {
  local url="http://$1-predictor.${TEST_NS}.svc.cluster.local/v1/models/$1:predict"
  local code
  code=$(kubectl -n "${TEST_NS}" exec deploy/curl-runner -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    -H 'Content-Type: application/json' -d "${PREDICT_PAYLOAD}" "${url}" 2>/dev/null) || return 1
  [ "${code}" = "200" ]
}

stargz_cache_bytes() {
  docker exec "${CLUSTER_NAME}-control-plane" du -sb "${STARGZ_CACHE_ROOT_IN_NODE}" 2>/dev/null | awk '{print $1}'
}

deploy_isvc() { # deploy_isvc <name> <img>
  local name="$1" img="$2"
  NAME="${name}" TEST_NS="${TEST_NS}" IMAGE_REF="${img}" \
    MINIO_BUCKET="${MINIO_BUCKET}" SIZE_TAG="x" \
    envsubst < "${BENCH_ROOT}/templates/isvc-oci-native.yaml" | kubectl apply -f - >/dev/null
}

teardown_isvc() { # teardown_isvc <name>
  kubectl -n "${TEST_NS}" delete isvc "$1" --ignore-not-found >/dev/null
  wait_for 300 "pods gone for $1" sh -c \
    "! kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=$1 -o name | grep -q pod" || true
}

# ---------------------------------------------------------------- 1. cold TTFP x5
ttfp_cold() { # ttfp_cold <size> <rep>
  local size="$1" rep="$2" tag="${size}g"
  local name="b-estargz-ttfp-${tag//./-}-${rep}"
  local img; img=$(cluster_image_ref "${tag}")

  if awk -F, -v s="estargz-ttfp" -v sz="${size}" -v r="${rep}" \
      'NR>1 && $1==s && $2==sz && $4==r {f=1} END{exit !f}' "${CSV}" 2>/dev/null; then
    log "skip (recorded): ${name}"; return
  fi

  node_rmi "${img}"
  docker exec "${CLUSTER_NAME}-control-plane" crictl rmi --prune >/dev/null 2>&1 || true
  sleep 3

  local t0; t0=$(now)
  deploy_isvc "${name}" "${img}"
  wait_for 120 "pod created ${name}" sh -c \
    "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o name | grep -q pod" \
    || { echo "estargz-ttfp,${size},cold,${rep},,,,,,,,,,TIMEOUT_POD_CREATE,E,8,estargz" >> "${CSV}"; teardown_isvc "${name}"; return; }
  local pod; pod=$(isvc_pod "${TEST_NS}" "${name}")
  local t_pod; t_pod=$(elapsed "${t0}")
  wait_for 300 "PodScheduled ${pod}" pod_condition_true "${TEST_NS}" "${pod}" PodScheduled || true
  local notes=""
  wait_for 600 "Initialized ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Initialized || notes="${notes}TIMEOUT_INIT;"
  wait_for 600 "Ready ${pod}"       pod_condition_true "${TEST_NS}" "${pod}" Ready       || notes="${notes}TIMEOUT_READY;"
  wait_for 300 "first 200 ${name}"  predict_200 "${name}"                               || notes="${notes}TIMEOUT_PREDICT;"
  local t_pred; t_pred=$(elapsed "${t0}")
  local pull; pull=$(pull_seconds_from_events "${TEST_NS}" "${pod}" "model-ballast" || true)

  echo "estargz-ttfp,${size},cold,${rep},${t_pod},,,,,${t_pred},${pull:-},,${pod},${notes},E,8,estargz" >> "${CSV}"
  log "TTFP ${name}: total=${t_pred}s pull=${pull:-n/a}${notes:+ notes=${notes}}"
  teardown_isvc "${name}"
}

# ---------------------------------------------------------------- 2/3. sustained full read (cold/warm) + cache sampler
sustained_read() { # sustained_read <size> <mode: cold|warm> <rep>
  local size="$1" mode="$2" rep="$3" tag="${size}g"
  # FIX (live pitfall, v3): warm reps reuse the SAME still-running pod left
  # over from the last cold rep (see main loop below) -- the isvc name must
  # stay "...-cold-..." for warm lookups too, or isvc_pod finds nothing for
  # a "...-warm-..." name that was never deployed and die() kills the whole
  # script silently mid-matrix (first caught when a dropped SSH session also
  # masked it -- see RUN-REPORT-v3 pitfalls).
  local name="b-estargz-read-cold-${tag}"
  local img; img=$(cluster_image_ref "${tag}")

  if awk -F, -v s="estargz-read" -v sz="${size}" -v m="${mode}" -v r="${rep}" \
      'NR>1 && $1==s && $2==sz && $3==m && $4==r {f=1} END{exit !f}' "${CSV}" 2>/dev/null; then
    log "skip (recorded): ${name} rep${rep}"; return
  fi

  if [ "${mode}" = "cold" ] && [ "${rep}" = "1" ]; then
    node_rmi "${img}"
    docker exec "${CLUSTER_NAME}-control-plane" crictl rmi --prune >/dev/null 2>&1 || true
    sleep 3
    deploy_isvc "${name}" "${img}"
    wait_for 300 "Ready ${name}" sh -c \
      "kubectl -n ${TEST_NS} wait pod -l serving.kserve.io/inferenceservice=${name} --for=condition=Ready --timeout=10s" || \
      wait_for 600 "Ready ${name} (long)" bash -c \
      "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=${name} -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
  fi
  # for warm reps, or cold reps 2/3, the pod from rep 1 stays up (no teardown between reads in this loop)

  local pod; pod=$(isvc_pod "${TEST_NS}" "${name}")
  [ -n "${pod}" ] || die "no pod found for ${name}, cannot run sustained read"

  # background cache-growth sampler (only meaningful for cold, but sample warm too for symmetry)
  local sampler_pid="" t_sample0
  if [ "${mode}" = "cold" ] && [ "${rep}" = "1" ]; then
    t_sample0=$(now)
    ( while true; do
        b=$(stargz_cache_bytes || echo "")
        [ -n "${b}" ] && echo "${size},${mode},$(elapsed "${t_sample0}"),${b}" >> "${CACHE_CSV}"
        sleep 10
      done ) &
    sampler_pid=$!
  fi

  local t0; t0=$(now)
  local rc=0
  kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- \
    sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" || rc=$?
  local t_read; t_read=$(elapsed "${t0}")

  if [ -n "${sampler_pid}" ]; then kill "${sampler_pid}" 2>/dev/null || true; fi

  local notes=""
  [ "${rc}" != "0" ] && notes="READ_ERROR_rc${rc};"
  echo "estargz-read,${size},${mode},${rep},,,,,,${t_read},,,${pod},${notes},E,8,estargz" >> "${CSV}"
  log "sustained-read ${name} mode=${mode} rep${rep}: ${t_read}s${notes:+ notes=${notes}}"
}

log "v3 lazy (eStargz) core: sizes=[${SIZES_GB}]"
for size in ${SIZES_GB}; do
  for rep in 1 2 3 4 5; do
    ttfp_cold "${size}" "${rep}"
  done

  # sustained cold reads x3 (rep1 deploys+cold-reads+samples, reps 2/3 re-read same still-cold-cache pod... )
  # NOTE: true repeated "cold" reads need a fresh pod each time; rep1 is the
  # real cold measurement (with sampler), reps 2/3 tear down+redeploy fresh too.
  for rep in 1 2 3; do
    if [ "${rep}" != "1" ]; then
      teardown_isvc "b-estargz-read-cold-${size}g"
      node_rmi "$(cluster_image_ref "${size}g")"
      docker exec "${CLUSTER_NAME}-control-plane" crictl rmi --prune >/dev/null 2>&1 || true
      sleep 3
      deploy_isvc "b-estargz-read-cold-${size}g" "$(cluster_image_ref "${size}g")"
      wait_for 600 "Ready b-estargz-read-cold-${size}g" bash -c \
        "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=b-estargz-read-cold-${size}g -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    fi
    sustained_read "${size}" "cold" "${rep}"
  done

  # warm reads x3 on the SAME pod left running from the last cold read (image + FUSE cache fully resident)
  for rep in 1 2 3; do
    sustained_read "${size}" "warm" "${rep}"
  done
  teardown_isvc "b-estargz-read-cold-${size}g"

  log "size ${size}g eStargz core done"
done

log "lazy core matrix done. Next: ENOSPC experiment (140g only) -- see 07-enospc.sh"
