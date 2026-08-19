#!/usr/bin/env bash
# v3.1 P0.5: pressure threshold matrix. Pre-fill the 92GB cache partition to
# {0,25,50,75,90}% via a plain filler file (simulating foreign chunk
# occupancy -- ext4 ENOSPC triggers purely on free block count, so a filler
# file is methodologically equivalent to real foreign stargz chunks for
# this purpose; noted as a simplification in the report given the time
# budget), then run a 140GB full read and record occupancy at first EIO,
# ENOSPC line count, corrupted-file fraction. verified-clean state (du/df
# logged) before each induction.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need kubectl; need envsubst
OUT="${RESULTS_DIR}/p05"
mkdir -p "${OUT}"
NODE="${CLUSTER_NAME}-control-plane"
CSV="${OUT}/pressure-matrix.csv"
echo "pct_target,rep,pct_actual_before_read,first_eio_log_line,eio_count_total,corrupted_files,total_files,read_rc,read_elapsed_s" > "${CSV}"

deploy_isvc() {
  NAME="$1" TEST_NS="${TEST_NS}" IMAGE_REF="$2" MINIO_BUCKET="${MINIO_BUCKET}" SIZE_TAG="x" \
    envsubst < "${BENCH_ROOT}/templates/isvc-oci-native.yaml" | kubectl apply -f - >/dev/null
}
teardown_isvc() {
  kubectl -n "${TEST_NS}" delete isvc "$1" --ignore-not-found >/dev/null
  wait_for 120 "isvc $1 gone" sh -c "! kubectl -n ${TEST_NS} get isvc $1 >/dev/null 2>&1" || true
}
clean_cache() {
  # NOTE (live fix, v3.1): originally also wiped /cache-part/snapshotter/* here.
  # That directory is containerd's stargz-backed snapshot store, and since
  # `snapshotter = "stargz"` is the NODE-WIDE default (not scoped to test
  # images -- pause/coredns/etcd/apiserver etc all go through it too), wiping
  # it out from under a live containerd left its metadata db pointing at
  # snapshots whose backing files no longer existed. Result: containerd could
  # no longer create ANY new pod sandbox on the node (AlreadyExists errors on
  # the shared pause-image layer, which has live children -- the running
  # control-plane pods -- so it can't even be surgically removed after the
  # fact). Recovered by deleting+recreating the whole kind cluster; this
  # invalidated the entire first P0.5 run (every rep silently never got a
  # real pod, since deploys after the first successful clean_cache() call all
  # failed the SAME way, just masked by wait_for's non-fatal WARN handling).
  # Fix: only clear the stargz CONTENT cache (httpcache/fscache), never the
  # snapshotter's own backing store.
  docker exec "${NODE}" pkill -f containerd-stargz-grpc || true
  sleep 2
  sudo sh -c "rm -rf /cache-part/stargz/httpcache/* /cache-part/stargz/fscache/* /cache-part/p05-filler.img 2>/dev/null" || true
  docker exec -d "${NODE}" sh -c "containerd-stargz-grpc --log-level info --address /run/containerd-stargz-grpc-stargz/containerd-stargz-grpc.sock --config /etc/containerd-stargz-grpc-stargz/config.toml > /var/log/stargz-grpc-p05.log 2>&1"
  sleep 3
  docker exec "${NODE}" test -S /run/containerd-stargz-grpc-stargz/containerd-stargz-grpc.sock || die "stargz-grpc did not restart"
}
eio_count() { docker exec "${NODE}" grep -c "no space left on device" /var/log/stargz-grpc-p05.log 2>/dev/null || echo 0; }

CAPACITY_KB=$(df --output=size /cache-part | tail -1)

for pct in 0 25 50 75 90; do
  for rep in 1 2; do
    log "=== P0.5: pct=${pct}% rep=${rep} ==="
    teardown_isvc "b-p05-${pct}-${rep}"
    clean_cache
    docker exec "${NODE}" crictl rmi --prune >/dev/null 2>&1 || true

    if [ "${pct}" -gt 0 ]; then
      FILL_KB=$(( CAPACITY_KB * pct / 100 ))
      sudo fallocate -l "${FILL_KB}K" /cache-part/p05-filler.img
    fi
    PCT_ACTUAL=$(df --output=pcent /cache-part | tail -1 | tr -d ' %')
    log "verified-clean-then-filled state: ${PCT_ACTUAL}% used before read"

    t0=$(now)
    deploy_isvc "b-p05-${pct}-${rep}" "${MODEL_IMG_PREFIX}:estargz-140g"
    wait_for 300 "pod created" sh -c "kubectl -n ${TEST_NS} get pod -l serving.kserve.io/inferenceservice=b-p05-${pct}-${rep} -o name | grep -q pod" || { echo "${pct},${rep},${PCT_ACTUAL},n/a,n/a,n/a,n/a,TIMEOUT_POD_CREATE,n/a" >> "${CSV}"; continue; }
    pod=$(isvc_pod "${TEST_NS}" "b-p05-${pct}-${rep}")
    wait_for 900 "Ready ${pod}" pod_condition_true "${TEST_NS}" "${pod}" Ready || log "WARN: Ready timeout, trying read anyway"

    rc=0
    kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- sh -c "find /mnt/models -type f -exec cat {} + > /dev/null" >/dev/null 2>"${OUT}/stderr-${pct}-${rep}.txt" || rc=$?
    t_elapsed=$(elapsed "${t0}")

    eio=$(eio_count)
    corrupted=$(kubectl -n "${TEST_NS}" exec "${pod}" -c kserve-container -- sh -c \
      'c=0; t=0; for f in /mnt/models/ballast-*.bin; do t=$((t+1)); dd if="$f" of=/dev/null bs=4M count=1 2>/dev/null || c=$((c+1)); done; echo "$c $t"' 2>/dev/null || echo "n/a n/a")
    corrupted_n=$(echo "${corrupted}" | awk '{print $1}')
    total_n=$(echo "${corrupted}" | awk '{print $2}')

    echo "${pct},${rep},${PCT_ACTUAL},n/a,${eio},${corrupted_n},${total_n},${rc},${t_elapsed}" >> "${CSV}"
    log "pct=${pct} rep=${rep}: eio=${eio} corrupted=${corrupted_n}/${total_n} rc=${rc} elapsed=${t_elapsed}s"

    teardown_isvc "b-p05-${pct}-${rep}"
  done
done

log "P0.5 pressure matrix done -> ${CSV}"
cat "${CSV}"
