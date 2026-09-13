#!/usr/bin/env bash
# E2 [P0] -- does the budget hold when the accounting queue is flooded?
#
# The direct falsifier for v6's C4. There, a 140GB sweep against an 80GB budget
# dropped 127,337 index updates, the index under-counted by 12.8GB, eviction
# acted on the under-count, the partition reached 100%, and the snapshotter then
# refused to start at all. The fix keys pressure to statfs instead of to the
# index. This asks the rig whether that works.
#
# Two arms, because a defect that needs a flooded queue must be tested with one
# that is certainly flooded:
#   default : queue_size at the shipped 8192 -- the configuration v6 broke under
#   tiny    : queue_size 256, 32x smaller, so dropping is guaranteed rather than
#             hoped for
#
# Expectations and falsifiers: PRE-REGISTRATION-v7.md s2.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

SWEEP_IMG="${MODEL_IMG_PREFIX}:estargz-140g"
E2="${RESULTS_DIR}/e2"
NODE="$(NODE_CTR)"
ARMS="${ARMS:-default tiny}"

queue_for() { case "$1" in tiny) echo 256 ;; *) echo 8192 ;; esac; }

arm() { # arm <name>
  local name="$1" qs out
  qs=$(queue_for "${name}")
  out="${E2}/${name}"; mkdir -p "${out}"
  log "=== E2 arm=${name} queue_size=${qs} budget=${CACHE_BUDGET_BYTES} ==="

  # Install with the arm's queue size. hard_reset inside 05-setup replaces the
  # manager, so the config is read by the process that acts on it.
  CACHE_POLICY=lru BINSRC=/data/stargz-bin-ours ARM_LABEL=ours FM_METRICS_ADDRESS="" \
    CACHE_ACCOUNTING=true CACHE_QUEUE_SIZE="${qs}" \
    "$(dirname "$0")/05-setup-stargz.sh" > "${out}/setup.log" 2>&1 \
    || { tail -30 "${out}/setup.log"; die "setup failed"; }
  docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml > "${out}/config.toml"
  hard_reset || die "hard_reset failed"

  # Refuse to measure through a dead index -- v6 spent two attempts discovering
  # that a stale collector keeps exporting the previous index's values.
  local fds; fds=$(db_open_fd_count)
  [ "${fds:-0}" -ge 1 ] || die "the accounting index is not open; this arm would measure an unbounded cache"

  { echo "experiment=E2"; echo "arm=${name}"; echo "queue_size=${qs}"
    echo "sha=$(awk -F= '/^sha=/{print $2}' /data/stargz-bin-ours/PROVENANCE.txt 2>/dev/null)"
    echo "budget_bytes=${CACHE_BUDGET_BYTES}"
    echo "partition_bytes=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')"
    echo "index_open_fds_at_start=${fds}"
    echo "started_utc=$(date -u +%FT%TZ)"; } > "${out}/meta.txt"

  start_sampler "${out}/sampler.csv" 10
  trap 'stop_sampler' RETURN

  teardown_pod e2-sweep
  deploy_pod e2-sweep "${SWEEP_IMG}" normal 3
  wait_for 300 "sweep ready" pod_ready e2-sweep || log "  WARN: sweep pod not Ready; continuing"
  log "  reading the whole 140GB image; this is the flood"
  full_read e2-sweep 280 > "${out}/sweep-read.txt" 2>&1 || true
  grep -E '^(READ|ERRNOS)' "${out}/sweep-read.txt" || true

  sleep 15
  stop_sampler; trap - RETURN
  sg_metrics_snapshotter > "${out}/metrics-after.txt"
  df -B1 "${STARGZ_CACHE_MOUNT}" > "${out}/df-after.txt"
  cache_du > "${out}/du-after.txt"
  teardown_pod e2-sweep

  # E2.6 -- the one that says whether the NODE survived, not just the partition.
  # v6's end state was a snapshotter that could not start because its startup
  # mkdir hit ENOSPC.
  log "  can the snapshotter still start?"
  if docker exec "${NODE}" systemctl restart stargz-snapshotter 2>"${out}/restart-err.txt"; then
    sleep 10
    if docker exec "${NODE}" systemctl is-active stargz-snapshotter >/dev/null 2>&1; then
      echo "startable_after=yes" >> "${out}/meta.txt"
    else
      echo "startable_after=no-not-active" >> "${out}/meta.txt"
    fi
  else
    echo "startable_after=no-restart-failed" >> "${out}/meta.txt"
  fi
  docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager | tail -80 > "${out}/journal-tail.txt" 2>&1 || true
  echo "ended_utc=$(date -u +%FT%TZ)" >> "${out}/meta.txt"

  bash "$(dirname "$0")/91-collect-one.sh" "e2/${name}" || log "  WARN: collection failed for ${name}"
}

mkdir -p "${E2}"
for a in ${ARMS}; do arm "${a}"; done
python3 "$(dirname "$0")/24-e2-verdict.py" "${E2}" | tee "${E2}/E2-RESULT.txt"
log "E2 done -> ${E2}"
