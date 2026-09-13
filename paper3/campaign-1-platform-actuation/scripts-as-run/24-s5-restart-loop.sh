#!/usr/bin/env bash
# spike-v4 S5: is the FUSE-manager cache duplication BOUNDED or CUMULATIVE?
#
# Run 1 (RUN-REPORT §3) measured that ONE snapshotter restart with fuse_manager
# enabled grows the on-disk cache by 10.6-12.5 GB with zero intervening application
# reads, and that the same restart with fuse_manager DISABLED instead reclaims cache.
# The mechanism (orphaned directoryCache directories, cache/cache.go:379-387 never
# running) was inferred from source, not measured. Two things were therefore open:
#   (a) does the growth repeat on EVERY restart, without bound, or does it plateau?
#   (b) is it actually orphaned cache DIRECTORIES, as inferred?
#
# This answers both. One warm pod, no application reads at all after the initial
# warm-up, then N consecutive `systemctl restart`s. After each restart we record
# df (authoritative real blocks), du of httpcache/fscache, and the NUMBER of
# subdirectories in each -- one directoryCache per resolved layer, so a rising
# directory count is direct evidence of orphaning rather than re-fetching.
#
# The practical question behind it: an operator reloading snapshotter config is a
# routine, sanctioned action. If each reload permanently consumes several GB that
# nothing ever reclaims, then routine operations walk the node into ENOSPC.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need kubectl; need envsubst; need docker

NODE="$(NODE_CTR)"
TRIAL="${TRIAL:-S5-restart-loop}"
FUSE_MANAGER="${FUSE_MANAGER:-true}"
KILLMODE="${KILLMODE:-process}"     # process = the config under which the mount survives
RESTARTS="${RESTARTS:-8}"
WARM_FILES="${WARM_FILES:-8}"
OUT="${RESULTS_DIR}/s5/${TRIAL}"; mkdir -p "${OUT}"
IMG="${MODEL_IMG_PREFIX}:estargz-140g"
POD="s5-probe"
CSV="${OUT}/restart-loop.csv"
echo "restart_n,df_used_bytes,df_pct,httpcache_bytes,fscache_bytes,httpcache_dirs,fscache_dirs,grpc_pid,fm_pid,mount_ok,read_ok,read_err,errnos" > "${CSV}"

cache_dirs() { # -> "httpcache_dirs fscache_dirs"
  docker exec "${NODE}" sh -c "
    h=\$(ls -1 ${STARGZ_ROOT_IN_NODE}/stargz/httpcache 2>/dev/null | wc -l)
    f=\$(ls -1 ${STARGZ_ROOT_IN_NODE}/stargz/fscache   2>/dev/null | wc -l)
    echo \"\$h \$f\"" 2>/dev/null || echo "0 0"
}

set_fm() { docker exec "${NODE}" sh -c "sed -i 's/^  enable = .*/  enable = $1/' /etc/containerd-stargz-grpc/config.toml"; }
set_km() {
  if [ "$1" = "process" ]; then
    docker exec "${NODE}" mkdir -p /etc/systemd/system/stargz-snapshotter.service.d
    docker exec -i "${NODE}" sh -c 'cat > /etc/systemd/system/stargz-snapshotter.service.d/killmode.conf' <<'EOF'
[Service]
KillMode=process
EOF
  else
    docker exec "${NODE}" rm -rf /etc/systemd/system/stargz-snapshotter.service.d
  fi
  docker exec "${NODE}" systemctl daemon-reload
}

log "=== S5 ${TRIAL}: fuse_manager=${FUSE_MANAGER} killmode=${KILLMODE} restarts=${RESTARTS} ==="
teardown_pod "${POD}"
set_log_level info
set_fm "${FUSE_MANAGER}"; set_km "${KILLMODE}"
hard_reset || die "could not reach a clean state"

{ echo "trial=${TRIAL} fuse_manager=${FUSE_MANAGER} killmode=${KILLMODE} restarts=${RESTARTS}"
  echo "date=$(date -Is)"
  docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml
  docker exec "${NODE}" systemctl show stargz-snapshotter -p KillMode
  docker exec "${NODE}" containerd-stargz-grpc --version
} > "${OUT}/meta.txt" 2>&1

deploy_pod "${POD}" "${IMG}" normal 3
wait_for 900 "pod Ready" pod_ready "${POD}" || die "pod never Ready"
log "warming ${WARM_FILES} files (this is the ONLY application read in the whole trial)"
mount_probe "${POD}" 0 "${WARM_FILES}" > "${OUT}/warm-read.txt" 2>&1
grep -E '^READ|^ERRNOS' "${OUT}/warm-read.txt" >&2

record() { # record <n>
  local n="$1" d p pr
  d=$(cache_du); pr=$(cache_dirs)
  p=$(mount_probe "${POD}" 0 "${WARM_FILES}" 2>&1)
  echo "${p}" > "${OUT}/probe-after-restart-${n}.txt"
  local ok err ern mok
  ok=$(echo "${p}"  | grep -m1 '^READ ' | sed -E 's/.* ok=([0-9]+) .*/\1/')
  err=$(echo "${p}" | grep -m1 '^READ ' | sed -E 's/.* err=([0-9]+) .*/\1/')
  ern=$(echo "${p}" | grep -m1 '^ERRNOS ' | sed 's/^ERRNOS //')
  mok=$(echo "${p}" | grep -q '^DIRSTAT ok' && echo yes || echo no)
  echo "${n},$(cache_used_bytes),$(cache_pct),$(echo "${d}"|awk '{print $1","$2}'),$(echo "${pr}"|tr ' ' ','),$(sg_grpc_pid),$(sg_fm_pid),${mok},${ok},${err},${ern}" >> "${CSV}"
  log "restart ${n}: df_used=$(cache_used_bytes) pct=$(cache_pct)% dirs=${pr} read_ok=${ok} err=${err}"
}

record 0
for i in $(seq 1 "${RESTARTS}"); do
  log "--- restart ${i}/${RESTARTS} (no application reads in between) ---"
  docker exec "${NODE}" systemctl restart stargz-snapshotter || true
  sleep 10
  docker exec "${NODE}" systemctl is-active stargz-snapshotter >/dev/null 2>&1 || {
    log "unit inactive after restart ${i}; recording and stopping the loop"
    record "${i}"; echo "UNIT_FAILED_AT_RESTART_${i}" > "${OUT}/FLAGGED-unit-failed.txt"
    docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager | tail -60 > "${OUT}/journal-at-failure.txt"
    break; }
  record "${i}"
  if [ "$(cache_pct)" -ge 97 ]; then
    log "cache partition at $(cache_pct)% -- ENOSPC reached after ${i} restarts, stopping"
    echo "ENOSPC_AFTER_${i}_RESTARTS" > "${OUT}/RESULT-enospc.txt"
    break
  fi
done

{ echo "--- final pod state ---"; kubectl -n "${TEST_NS}" get pod "${POD}" -o wide
  echo "ready=$(pod_ready "${POD}" && echo true || echo false) restarts=$(pod_restarts "${POD}")"
  echo "--- kubelet view ---"; kubelet_view
  echo "--- df ---"; df -h "${STARGZ_CACHE_MOUNT}"
  echo "--- cache dirs ---"; cache_dirs
} > "${OUT}/final-state.txt" 2>&1
docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${OUT}/journal-stargz-snapshotter.txt" 2>&1 || true
kubectl -n "${TEST_NS}" describe pod "${POD}" > "${OUT}/pod-describe.txt" 2>&1 || true

teardown_pod "${POD}"
log "S5 ${TRIAL} done -> ${CSV}"
cat "${CSV}"
