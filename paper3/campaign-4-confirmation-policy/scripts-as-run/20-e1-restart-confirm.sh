#!/usr/bin/env bash
# E1 [P0] -- F12 and F2, live, on the two-host restart where they appeared.
#
# The gesture under test is one line: an operator edits [cache_accounting.budget]
# policy and runs `systemctl restart stargz-snapshotter`. With KillMode=process
# the FUSE manager survives that restart by design (our fix for upstream #2387),
# and with fuse_manager on, the manager is where the index, the eviction engine
# and every stargz_cache_* series live. v5 found the config appeared not to
# arrive and the metrics were unreachable; the fix round found the config DOES
# arrive and what leaked was the superseded filesystem (C2-REPORT s10.1).
#
# Expectations and falsifiers: PRE-REGISTRATION-v6.md s1.
#
#   ARM=sut     -> /data/stargz-bin-ours   @ 9829d7cf, NO [fuse_manager] metrics_address
#   ARM=prefix  -> /data/stargz-bin-prefix @ f6547d99, WITH it (else nothing to read)
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl; need curl

# A failure in a 40-minute experiment must announce itself. Without this the
# script simply stopped mid-run and the log's last line was the step BEFORE the
# one that failed, which is indistinguishable from "still working".
trap 'rc=$?; echo "FATAL: ${BASH_SOURCE[0]} line ${LINENO} exited ${rc}" >&2' ERR

ARM="${ARM:-sut}"
# E1 needs the cache to hold real chunks so the counters carry real values; it
# does not care which image they came from. The 140g image is built first, so
# reading its first WARM_FILES files gets E1 started ~40 minutes earlier than
# waiting for the 14g one, which only E2 actually needs (E2's resident and sweep
# pods must use DIFFERENT images, since a cache directory per image is the unit
# 2q reasons about).
WARM_IMG="${WARM_IMG:-${MODEL_IMG_PREFIX}:estargz-140g}"
WARM_FILES="${WARM_FILES:-28}"
OUT="${RESULTS_DIR}/e1/${ARM}"; mkdir -p "${OUT}"
NODE="$(NODE_CTR)"

case "${ARM}" in
  sut)    BINSRC=/data/stargz-bin-ours   LABEL=ours   FMM="" ;;
  prev)   BINSRC=/data/stargz-bin-prev   LABEL=prev   FMM="0.0.0.0:9111" ;;
  *) die "ARM must be sut or prev" ;;
esac

# One observation: everything E1 asserts on, at one instant, written as a bundle.
observe() { # observe <tag>
  # NOT `local tag="$1" d=".../obs-${tag}"`: bash expands every argument to the
  # `local` builtin BEFORE the builtin assigns any of them, so ${tag} would
  # still be unset and `set -u` would kill the run. It did, once, silently.
  local tag="$1"
  local d="${OUT}/obs-${tag}"
  mkdir -p "${d}"
  sg_metrics_snapshotter > "${d}/metrics-9110.txt"
  if [ -n "${FMM}" ]; then sg_metrics_manager "${FMM##*:}" > "${d}/metrics-9111.txt"; fi
  db_holders            > "${d}/db-holders.txt"
  db_corrupt_files      > "${d}/db-corrupt.txt"
  {
    echo "tag=${tag}"
    echo "iso=$(date -u +%FT%TZ)"
    echo "grpc_pid=$(sg_grpc_pid)"
    echo "fm_pid=$(sg_fm_pid)"
    echo "config_policy=$(docker exec "${NODE}" sed -n 's/^  policy = "\(.*\)"/\1/p' /etc/containerd-stargz-grpc/config.toml | head -1)"
    echo "db_holders=$(grep -c . < "${d}/db-holders.txt" || true)"
    echo "index_open_fds=$(db_open_fd_count)"
    echo "lock_retry_9110=$(metric_one "$(cat "${d}/metrics-9110.txt")" stargz_cache_index_lock_retry_total)"
    echo "pressure_9110=$(metric_one "$(cat "${d}/metrics-9110.txt")" stargz_fs_cache_pressure_bytes)"
    echo "db_corrupt=$(grep -c . < "${d}/db-corrupt.txt" || true)"
    echo "n9110_bytes=$(wc -c < "${d}/metrics-9110.txt" | tr -d ' ')"
    echo "n9110_stargz_series=$(grep -c '^stargz_' "${d}/metrics-9110.txt" || true)"
    echo "n9110_cache_series=$(grep -cE '^stargz_(cache|fs_cache)_' "${d}/metrics-9110.txt" || true)"
    echo "policy_labels_9110=$(policy_labels "$(cat "${d}/metrics-9110.txt")")"
    echo "budget_9110=$(metric_one "$(cat "${d}/metrics-9110.txt")" stargz_fs_cache_budget_bytes)"
    echo "lock_lost_9110=$(metric_one "$(cat "${d}/metrics-9110.txt")" stargz_cache_index_lock_lost_total)"
    echo "lock_lost_present_9110=$(grep -c '^stargz_cache_index_lock_lost_total ' "${d}/metrics-9110.txt" || true)"
    echo "bytes_used_9110=$(metric_sum "$(cat "${d}/metrics-9110.txt")" stargz_cache_bytes_used)"
    if [ -n "${FMM}" ]; then
      echo "n9111_cache_series=$(grep -cE '^stargz_(cache|fs_cache)_' "${d}/metrics-9111.txt" || true)"
      echo "policy_labels_9111=$(policy_labels "$(cat "${d}/metrics-9111.txt")")"
    fi
    echo "--- exposition check (9110) ---"
    exposition_check "$(cat "${d}/metrics-9110.txt")"
  } > "${d}/observation.txt"
  # The manager truncates its log on every start, and this experiment restarts
  # the stack repeatedly, so the window that matters is gone by the end. Capture
  # it per observation instead of once at the end.
  docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${d}/fuse-manager.log" 2>&1 || true
  grep -iE "accounting|another process holds" "${d}/fuse-manager.log" > "${d}/accounting-lines.txt" 2>/dev/null || true
  log "  [obs ${tag}] $(grep -E '^(config_policy|fm_pid|n9110_cache_series|policy_labels_9110|lock_lost_9110|lock_retry_9110|index_open_fds)=' "${d}/observation.txt" | paste -sd' ' -)"
}

set_policy_in_config() { # <lru|2q>
  docker exec "${NODE}" sh -c "sed -i 's/^  policy = .*/  policy = \"$1\"/' /etc/containerd-stargz-grpc/config.toml"
  docker exec "${NODE}" grep -A6 'cache_accounting.budget' /etc/containerd-stargz-grpc/config.toml
}

# THE gesture. Deliberately nothing else: no manager kill, no socket removal,
# no hard_reset. v5's set_policy() had to do all three; if that is still needed,
# E1 has falsified its own premise and says so rather than working around it.
plain_restart() {
  log "  systemctl restart stargz-snapshotter  (and nothing else)"
  docker exec "${NODE}" systemctl restart stargz-snapshotter
  sleep 12
  docker exec "${NODE}" systemctl is-active stargz-snapshotter >/dev/null \
    || die "snapshotter did not come back from the restart"
}

log "=== E1 arm=${ARM} (${BINSRC}) fm_metrics=${FMM:-<unset>} ==="
{ echo "experiment=E1"; echo "arm=${ARM}"; echo "binsrc=${BINSRC}"
  echo "fm_metrics_address=${FMM:-<unset>}"
  echo "sut_sha=$(awk -F= '/^sha=/{print $2}' "${BINSRC}/PROVENANCE.txt" 2>/dev/null)"
  echo "budget_bytes=${CACHE_BUDGET_BYTES}"; echo "started_utc=$(date -u +%FT%TZ)"; } > "${OUT}/meta.txt"

# 1. install the arm at policy=lru
CACHE_POLICY=lru BINSRC="${BINSRC}" ARM_LABEL="${LABEL}" FM_METRICS_ADDRESS="${FMM}" \
  CACHE_ACCOUNTING=true "$(dirname "$0")/05-setup-stargz.sh" > "${OUT}/setup.log" 2>&1 \
  || { tail -30 "${OUT}/setup.log"; die "setup failed"; }
docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml > "${OUT}/config-initial.toml"
hard_reset || die "hard_reset failed"

# 2. put real numbers behind the counters
log "  warming the cache with the 14GB image"
# Tear down first, always. A pod left from an earlier attempt survives
# hard_reset -- which destroys the FUSE mounts under it -- and `deploy_pod` then
# re-applies an identical spec, which kubectl treats as a no-op. The pod keeps
# running on a dead mount and every read returns ESTALE. That invalidated E1
# attempt 1; see results/e1/sut-attempt1-INVALID/WHY-INVALID.txt.
teardown_pod e1-warm
deploy_pod e1-warm "${WARM_IMG}" normal 3
wait_for 300 "warm pod ready" pod_ready e1-warm || die "warm pod never Ready"
full_read e1-warm "${WARM_FILES}" > "${OUT}/warm-read.txt" 2>&1 || true
grep -E '^(READ|ERRNOS)' "${OUT}/warm-read.txt" || true
warm_ok=$(sed -n 's/.*attempted=[0-9]* ok=\([0-9]*\).*/\1/p' "${OUT}/warm-read.txt" | head -1)
[ "${warm_ok:-0}" -ge 1 ] || die "the warm read served 0 files (see ${OUT}/warm-read.txt) -- refusing to run a trial on a cache that was never filled"

observe 00-baseline-lru

# SIX restarts, alternating. v6's defect alternated: the first restart met an
# incumbent index and lost the lock, the second found none and won, the third
# lost again. Two restarts could therefore show one failure and one success and
# be read either way. Three of each parity is what separates "fixed" from
# "got lucky on the parity we happened to sample".
RESTARTS="${RESTARTS:-2q lru 2q lru 2q lru}"
n=0
for pol in ${RESTARTS}; do
  n=$((n+1))
  log "  --- restart ${n}: policy -> ${pol} ---"
  set_policy_in_config "${pol}" > "${OUT}/config-change-${n}.txt" 2>&1
  plain_restart
  observe "$(printf '%02d' $((n*2-1)))-after-restart-${n}-${pol}"
  # A cycle has to run for a counter to carry the new label, and a read is also
  # what would expose an index that came up dead.
  full_read e1-warm "${WARM_FILES}" > "${OUT}/reread-${n}-${pol}.txt" 2>&1 || true
  observe "$(printf '%02d' $((n*2)))-after-read-${n}-${pol}"
done

teardown_pod e1-warm
deploy_pod e1-warm "${WARM_IMG}" normal 3
wait_for 300 "warm pod ready" pod_ready e1-warm || die "warm pod never Ready"
full_read e1-warm "${WARM_FILES}" > "${OUT}/warm-read.txt" 2>&1 || true
grep -E '^(READ|ERRNOS)' "${OUT}/warm-read.txt" || true
warm_ok=$(sed -n 's/.*attempted=[0-9]* ok=\([0-9]*\).*/\1/p' "${OUT}/warm-read.txt" | head -1)
[ "${warm_ok:-0}" -ge 1 ] || die "the warm read served 0 files (see ${OUT}/warm-read.txt) -- refusing to run a trial on a cache that was never filled"

observe 1-baseline-lru

# 3. the gesture: lru -> 2q
teardown_pod e1-warm
docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${OUT}/journal-stargz.txt" 2>&1 || true
docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${OUT}/fuse-manager.log" 2>&1 || true

python3 "$(dirname "$0")/20-e1-verdict.py" "${OUT}" "${ARM}" > "${OUT}/VERDICT.txt"
cat "${OUT}/VERDICT.txt"
log "E1 arm=${ARM} done -> ${OUT}"
