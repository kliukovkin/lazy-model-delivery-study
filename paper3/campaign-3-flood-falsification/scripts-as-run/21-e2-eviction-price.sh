#!/usr/bin/env bash
# E2 [P0] -- the price of eviction, done so the answer is quotable.
#
# v5 ran one arm per policy, lru first, and its all-hits warm references differed
# by 21.6% between the arms. That confounds the latency comparison with whatever
# made the baselines differ, and it breaks the hit-rate outright, because v5
# classified a read as a hit against a threshold taken from each arm's OWN warm
# reference -- so the slower baseline mechanically produced 2q's headline
# derived_hit_rate=1.000. See PRE-REGISTRATION-v6.md s2.1.
#
# Three changes:
#   1. ABBA crossover (lru, 2q, 2q, lru), N=2 per policy, so an order effect is
#      visible rather than confounded.
#   2. THREE warm passes, not two. Pass 3 is the reference; pass 2 exists so
#      warmth itself can be checked (gate G2) instead of assumed.
#   3. A gate that runs BEFORE any comparison is computed. If the baselines do
#      not agree within 5%, this script writes GATE-FAILURE.md and computes no
#      comparison at all. Rig hours go to diagnosis, per the task's own rule.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

RESIDENT_IMG="${MODEL_IMG_PREFIX}:estargz-14g"
SWEEP_IMG="${MODEL_IMG_PREFIX}:estargz-140g"
HOT_FILES="${HOT_FILES:-28}"          # 28 x 500MB = 14GB
ROUNDS="${ROUNDS:-4}"
ARM_SEQUENCE="${ARM_SEQUENCE:-lru 2q 2q lru}"   # ABBA
E2="${RESULTS_DIR}/e2"
NODE="$(NODE_CTR)"

# Change the policy the way an operator does, and check it landed. v5 needed a
# kill-and-replace workaround here because of F12; using that workaround now
# would hide a regression AND would run E2 on a different mechanism than E1
# tests. If the plain restart does not apply the policy, that is a finding.
# Set the policy for an arm.
#
# v5 used a kill-and-replace-the-manager workaround here and v6 set out to test
# whether a plain `systemctl restart` had made it unnecessary. E1 answered that
# question definitively -- it has not; see CODE-FINDINGS-v6 C1 -- and E2's first
# two attempts then demonstrated the cost of relying on it anyway: the arm runs
# with NO accounting index, nothing evicts, and the partition fills.
#
# So E2 no longer relies on a plain restart. It edits the config and does a full
# hard_reset, which replaces the manager, so the new index has no incumbent to
# lose a lock race against. The mechanism question belongs to E1 and has been
# answered there; E2's job is to measure policies, and it cannot do that on an
# arm whose index never opened.
apply_policy() { # apply_policy <lru|2q> <outdir>
  local pol="$1" out="$2"
  docker exec "${NODE}" sh -c "sed -i 's/^  policy = .*/  policy = \"${pol}\"/' /etc/containerd-stargz-grpc/config.toml"
  {
    echo "policy_requested=${pol}"
    echo "mechanism=config-edit-plus-hard_reset"
    echo "why=CODE-FINDINGS-v6 C1: a plain restart loses the index lock race to"
    echo "    the incumbent index, leaving this process with no accounting and"
    echo "    no eviction. E1 establishes that; E2 must not measure through it."
  } > "${out}/policy-apply.txt"
  hard_reset || return 1
  return 0
}

# Refuse to measure an arm whose accounting index is not actually open.
#
# Checking the metrics alone is not enough and E2 attempt 2 proved it: when the
# index fails to open, the collector keeps its previous binding, so
# stargz_cache_bytes_used is still exported and the policy label still reads
# whatever the last live index was configured with. For an arm that requests the
# same policy as the previous one, that passes a naive check while nothing is
# evicting. The load-bearing signals are an actually-open index file and a lock
# counter that has not moved.
assert_accounting_live() { # assert_accounting_live <policy> <outdir>
  local pol="$1" out="$2" fds lost labels
  fds=$(db_open_fd_count)
  lost=$(metric_one "$(sg_metrics_snapshotter)" stargz_cache_index_lock_lost_total)
  labels=$(policy_labels "$(sg_metrics_snapshotter)")
  {
    echo "index_open_fds=${fds}"
    echo "index_lock_lost_total=${lost}"
    echo "policy_labels=${labels}"
  } >> "${out}/policy-apply.txt"
  [ "${fds:-0}" -ge 1 ] || { log "  no process holds the accounting index"; return 1; }
  echo ",${labels}," | grep -q ",${pol}\|,${pol}-" || { log "  policy label [${labels}] is not ${pol}"; return 1; }
  log "  accounting live: index_fds=${fds} lock_lost=${lost} labels=[${labels}]"
  return 0
}

# Median of the latency lines in a probe output, in ms. Used by the adaptive
# warm-up to decide whether two consecutive passes agree.
p50_of() { # p50_of <file>
  python3 - "$1" <<'PYEOF'
import re, sys
v = sorted(float(m.group(1)) for l in open(sys.argv[1], errors="replace")
           for m in [re.search(r"ms=([0-9.]+)", l)] if m and "errno=" not in l)
print("%.3f" % (v[len(v)//2] if len(v) % 2 else (v[len(v)//2-1]+v[len(v)//2])/2) if v else "nan")
PYEOF
}

armrun() { # armrun <seq-index> <policy>
  local idx="$1" pol="$2"
  local out="${E2}/run${idx}-${pol}"; mkdir -p "${out}"
  log "=== E2 run ${idx}: policy=${pol} ==="

  # apply_policy edits the config and does a full hard_reset, which both wipes
  # the cache (an arm-run ends with the partition near full, see C4) and replaces
  # the manager (so the new index has no incumbent to lose a lock race to, see C1).
  apply_policy "${pol}" "${out}"

  # The C1 race can leave this process with NO accounting index at all (the
  # newcomer loses the bolt lock, newAccountant returns nil, and nothing evicts).
  # An arm measured in that state would be measuring an unbounded cache while
  # claiming a policy, so refuse to measure until the index is actually there.
  if ! assert_accounting_live "${pol}" "${out}"; then
    log "  run ${idx} INVALID: accounting index is not live"
    { echo "the accounting index was not open before measurement"
      echo "requested policy=${pol}"
      echo "see CODE-FINDINGS-v6 C1"; } > "${out}/WHY-INVALID.txt"
    mv "${out}" "${out}-INVALID"; return 0
  fi

  # METHOD ADDITION, not in PRE-REGISTRATION-v6.md -- added before E2 ran and
  # disclosed in the report rather than folded in silently.
  #
  # Every arm-run must start from the same machine state, and the page cache is
  # one piece of that: this node has 64 GB of RAM and the hot set is 14 GB, so
  # whatever the previous arm's 140 GB sweep left resident is a difference
  # between arms that has nothing to do with the policy under test. The
  # three-pass warm-up should already equalise it -- by pass 3 the hot set has
  # been read twice -- so this is belt-and-braces on the gate rather than a
  # substitute for it. It cannot manufacture agreement: if the baselines still
  # disagree, the gate still fails and E2 still reports no comparison.
  sync
  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || log "  (could not drop page cache)"

  { echo "experiment=E2"; echo "run_index=${idx}"; echo "policy=${pol}"
    echo "arm_sequence=${ARM_SEQUENCE}"
    echo "sha=$(awk -F= '/^sha=/{print $2}' /data/stargz-bin-ours/PROVENANCE.txt 2>/dev/null)"
    echo "budget_bytes=${CACHE_BUDGET_BYTES}"; echo "hot_files=${HOT_FILES}"; echo "rounds=${ROUNDS}"
    echo "resident_img=${RESIDENT_IMG}"; echo "sweep_img=${SWEEP_IMG}"
    echo "started_utc=$(date -u +%FT%TZ)"
    echo "policy_label_at_start=$(policy_labels "$(sg_metrics_snapshotter)")"; } > "${out}/meta.txt"

  teardown_pod e2-resident; teardown_pod e2-sweep
  deploy_pod e2-resident "${RESIDENT_IMG}" normal 3
  wait_for 300 "resident ready" pod_ready e2-resident || die "resident never Ready"

  # ---- E4 piggy-back: dump the index at 5s, but ONLY while the cheap resident
  # workload runs and NOTHING is being measured. v5's F11 is exactly the lesson
  # that a background copy job beside a measurement invalidates the measurement,
  # so this stops before pass 3, which is the reference distribution.
  if [ "${idx}" = "1" ]; then
    mkdir -p "${out}/idx5s"
    ( while :; do index_dump "${out}/idx5s/idx-$(date +%s).tsv" 2>/dev/null; sleep 5; done ) </dev/null >/dev/null 2>&1 &
    E4PID=$!
  else E4PID=""; fi

  log "  warm pass 1 (cold: populates the cache)"
  lat_probe e2-resident 0 "${HOT_FILES}" 1 > "${out}/warm-1.txt" 2>&1 || true

  if [ -n "${E4PID}" ]; then
    kill "${E4PID}" 2>/dev/null || true
    log "  E4 index sampling stopped before the reference pass"
  fi

  # ADAPTIVE WARM-UP. The first crossover used a fixed three passes and two of
  # its four arms had not converged by pass 3 -- one still warming (11.3%), one
  # drifting the other way (5.8%) -- which failed gate G2 after the fact. The
  # bootstrap in results/e2/GATE-FAILURE-ANALYSIS.md rules out sampling noise:
  # two 28-sample medians from one run's own distribution differ by >5% in 0.0%
  # of 4000 resamples.
  #
  # So warm until two CONSECUTIVE passes agree within the same 5% the gate
  # tests, and use the last as the reference. The tolerance is not moved -- the
  # protocol now achieves the condition the gate checks instead of assuming
  # three passes achieve it. An arm that never converges is INVALID and says so.
  local prev="" cur k converged=0
  for k in 2 3 4 5 6 7; do
    log "  warm pass ${k} (adaptive; converges when two consecutive agree within 5%)"
    lat_probe e2-resident 0 "${HOT_FILES}" 1 > "${out}/warm-${k}.txt" 2>&1 || true
    if [ "$(grep -c 'errno=' "${out}/warm-${k}.txt" || true)" -gt 0 ]; then
      log "  run ${idx} INVALID: read errors during warm pass ${k}"
      { echo "read errors during warm pass ${k}"; head -3 "${out}/warm-${k}.txt"; } > "${out}/WHY-INVALID.txt"
      teardown_pod e2-resident; mv "${out}" "${out}-INVALID"; return 0
    fi
    cur=$(p50_of "${out}/warm-${k}.txt")
    if [ -n "${prev}" ]; then
      local d; d=$(awk -v a="${prev}" -v b="${cur}" 'BEGIN{printf "%.4f", (a>b?a-b:b-a)/a}')
      log "    pass ${k} p50=${cur} ms (previous ${prev} ms, delta $(awk -v x="${d}" 'BEGIN{printf "%.1f%%", 100*x}'))"
      if awk -v x="${d}" 'BEGIN{exit !(x<=0.05)}'; then
        cp "${out}/warm-$((k-1)).txt" "${out}/warm-prev.txt"
        cp "${out}/warm-${k}.txt"     "${out}/warm-ref.txt"
        echo "warm_passes=${k} converged_delta=${d}" >> "${out}/meta.txt"
        converged=1; log "    converged after ${k} passes"; break
      fi
    else
      log "    pass ${k} p50=${cur} ms (first comparable pass)"
    fi
    prev="${cur}"
  done
  if [ "${converged}" != "1" ]; then
    log "  run ${idx} INVALID: warm-up never converged"
    { echo "the warm-up never reached two consecutive passes within 5%"
      echo "see results/e2/GATE-FAILURE-ANALYSIS.md"; } > "${out}/WHY-INVALID.txt"
    teardown_pod e2-resident; mv "${out}" "${out}-INVALID"; return 0
  fi

  start_sampler "${out}/sampler.csv" 10
  trap 'stop_sampler' RETURN

  log "  starting the 140GB sweep beside it"
  deploy_pod e2-sweep "${SWEEP_IMG}" normal 3
  wait_for 300 "sweep ready" pod_ready e2-sweep || log "  WARN: sweep pod not Ready; continuing"
  ( full_read e2-sweep 280 > "${out}/sweep-read.txt" 2>&1 ) </dev/null >/dev/null 2>&1 &
  local SWEEPPID=$!

  log "  measuring resident latency, ${ROUNDS} rounds, under sweep pressure"
  lat_probe e2-resident 0 "${HOT_FILES}" "${ROUNDS}" > "${out}/resident-latency.txt" 2>&1 || true

  wait ${SWEEPPID} 2>/dev/null || true
  stop_sampler; trap - RETURN

  sg_metrics_snapshotter > "${out}/metrics-after.txt"
  { echo "policy_labels_end=$(policy_labels "$(cat "${out}/metrics-after.txt")")"
    echo "ended_utc=$(date -u +%FT%TZ)"; } >> "${out}/meta.txt"
  docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${out}/journal-stargz.txt" 2>&1 || true
  teardown_pod e2-sweep; teardown_pod e2-resident
  log "  run ${idx} done: $(grep -E '^policy_labels_end=' "${out}/meta.txt")"
}

mkdir -p "${E2}"
i=0
for pol in ${ARM_SEQUENCE}; do i=$((i+1)); armrun "${i}" "${pol}"; done

log "=== E2 gate + analysis ==="
python3 "$(dirname "$0")/21-e2-analyse.py" "${E2}" | tee "${E2}/E2-RESULT.txt"
log "E2 done -> ${E2}"
