#!/usr/bin/env bash
# V9-A -- two-pod interference on ONE node, under ONE shared 80 GB budget.
#
# The paper's Limitations section says cross-pod interference "is scoped to the
# eviction policy by I6 and was not evaluated". This evaluates it.
#
# Pod A serves from a fully warm ~20 GB hot set (estargz-20g). Pod B sweeps the
# 140 GB image (estargz-140g) through the same budget. The two images are
# DISJOINT -- different blobs, different digests -- which is what makes A's
# refetches attributable registry-side without any inference.
#
# PRE-REGISTRATION-v9 s3 records the expectation (A is partially evicted, p99
# rises, refetches > 0) AND records, before the fact, that the mechanism argument
# runs the other way: A's reader is continuous, so under LRU B's own tail is
# older than anything of A's and I6 predicts B largely self-evicts. Both outcomes
# are pre-registered as publishable. Nothing here is retuned if A survives.
#
# FATAL: any read error on A. Not a failed run -- a P0 finding against the paper.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

REPS="${REPS:-2}"
BASELINE_S="${BASELINE_S:-300}"     # >= 5 min of A alone, per the task
TAIL_S="${TAIL_S:-300}"             # 5 min after B finishes, per the task
MAX_READER_S="${MAX_READER_S:-7200}"
V9A="${RESULTS_DIR}/v9a"
NODE="$(NODE_CTR)"
SENTINEL=/tmp/v9a-stop

# p50 of an ms= probe file, for the warm-up convergence check.
p50_of() {
  python3 - "$1" <<'PYEOF'
import re, sys
v = sorted(float(m.group(1)) for l in open(sys.argv[1], errors="replace")
           for m in [re.search(r"ms=([0-9.]+)", l)] if m and "errno=" not in l)
print("%.3f" % (v[len(v)//2] if len(v) % 2 else (v[len(v)//2-1]+v[len(v)//2])/2) if v else "nan")
PYEOF
}

phase() { # phase <outdir> <name>   -- stamp a phase boundary, UTC, to the ms
  printf '%s=%s\n' "$2" "$(date -u +%FT%T.%3NZ)" >> "$1/phases.txt"
}

rep_run() { # rep_run <rep>
  local rep="$1"
  local out="${V9A}/rep${rep}"; mkdir -p "${out}"
  log "=== V9-A rep ${rep} ==="

  if ! hard_reset; then
    echo "hard_reset failed before any measurement" > "${out}/WHY-INVALID.txt"
    mv "${out}" "${out}-INVALID"; return 0
  fi
  # No filler. A (20 GB) + B (150 GB) is already ~170 GB against an 80 GB budget;
  # a filler would only change WHICH resource binds and muddy what is being asked.
  sync; sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

  { echo "experiment=V9-A"; echo "rep=${rep}"
    echo "img_a=${MODEL_IMG_A}"; echo "a_files=${A_FILES}"
    echo "img_b=${MODEL_IMG_B}"; echo "b_files=${B_FILES}"
    echo "budget_bytes=${CACHE_BUDGET_BYTES}"; echo "policy=${CACHE_POLICY}"
    echo "partition_bytes=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')"
    echo "sha=$(awk -F= '/^sha=/{print $2}' /data/stargz-bin-ours/PROVENANCE.txt 2>/dev/null)"
    echo "baseline_s=${BASELINE_S}"; echo "tail_s=${TAIL_S}"
    echo "started_utc=$(date -u +%FT%TZ)"; } > "${out}/meta.txt"
  : > "${out}/phases.txt"

  teardown_pod v9a-a; teardown_pod v9a-b
  phase "${out}" a_deploy
  deploy_pod v9a-a "${MODEL_IMG_A}" normal 3
  wait_for 300 "pod A ready" pod_ready v9a-a || die "pod A never Ready"

  # ---- warm A fully: read everything twice, then confirm steady state ---------
  phase "${out}" a_warm_begin
  log "  warming A: pass 1 (cold)"
  lat_probe v9a-a 0 "${A_FILES}" 1 > "${out}/a-warm-1.txt" 2>&1 || true
  log "  warming A: pass 2"
  lat_probe v9a-a 0 "${A_FILES}" 1 > "${out}/a-warm-2.txt" 2>&1 || true
  # ADAPTIVE WARM-UP. POST-LOCK PROTOCOL CHANGE, disclosed in RUN-REPORT-v9.
  #
  # PRE-REGISTRATION-v9 s3 step 2 specified a FIXED third pass gated at 5%. That
  # is the design v8's own results/e2/GATE-FAILURE-ANALYSIS.md had already shown
  # does not reliably converge -- two of its four arms failed it, one still
  # warming and one "drifting the other way" -- and v8 replaced it with an
  # adaptive warm-up for exactly that reason. Writing the superseded version into
  # v9 was an authoring mistake, and v9-A rep 1 reproduced the known failure on
  # its first attempt: pass2 607.4 ms, pass3 643.1 ms, +5.9%, drifting the wrong
  # way. That repetition is preserved as rep1-INVALID.
  #
  # The TOLERANCE IS NOT MOVED. It is still 5%, and it still gates the baseline.
  # What changes is that the protocol now ACHIEVES the pre-registered condition
  # ("fully warm", "steady state") instead of assuming three passes achieve it.
  # An arm that never converges is still INVALID and still says so.
  local prev cur k dw converged=0
  prev=$(p50_of "${out}/a-warm-2.txt")
  for k in 3 4 5 6 7 8; do
    log "  warming A: pass ${k} (adaptive; converges when two consecutive agree within 5%)"
    [ "${k}" = "3" ] && phase "${out}" a_warm3_begin
    lat_probe v9a-a 0 "${A_FILES}" 1 > "${out}/a-warm-${k}.txt" 2>&1 || true
    if [ "$(grep -c 'errno=' "${out}/a-warm-${k}.txt" || true)" -gt 0 ]; then
      log "  rep ${rep} FATAL: read errors on A during warm-up"
      { echo "READ ERRORS ON POD A DURING WARM-UP -- P0"; grep 'errno=' "${out}/a-warm-${k}.txt" | head; } > "${out}/FATAL.txt"
      cat "${out}/FATAL.txt"
    fi
    cur=$(p50_of "${out}/a-warm-${k}.txt")
    dw=$(awk -v a="${prev}" -v b="${cur}" 'BEGIN{printf "%.4f", (a>b?a-b:b-a)/a}')
    log "    pass ${k} p50=${cur} ms (previous ${prev} ms, delta $(awk -v x="${dw}" 'BEGIN{printf "%.1f%%", 100*x}'))"
    if [ "$(awk -v x="${dw}" 'BEGIN{print (x<=0.05)?1:0}')" = "1" ]; then
      cp "${out}/a-warm-${k}.txt" "${out}/a-warm-ref.txt"
      { echo "a_warm_passes=${k}"; echo "a_warm_p50_prev=${prev}"; echo "a_warm_p50_ref=${cur}"
        echo "a_warm_delta=${dw}"; echo "a_warm_converged=yes"; } >> "${out}/meta.txt"
      converged=1; log "    converged after ${k} passes"; break
    fi
    prev="${cur}"
  done
  phase "${out}" a_warm3_end
  if [ "${converged}" != "1" ]; then
    log "  rep ${rep} INVALID: A never reached steady state"
    { echo "pod A's warm-up never reached two consecutive passes within 5%."
      echo "the baseline envelope this experiment compares against would not be a"
      echo "warm baseline, so no comparison is computed for this repetition."; } > "${out}/WHY-INVALID.txt"
    teardown_pod v9a-a; mv "${out}" "${out}-INVALID"; return 0
  fi

  start_sampler "${out}/sampler.csv" 10
  trap 'stop_sampler' RETURN

  # ---- A's loop reader: runs across all three phases, one CSV -----------------
  kubectl -n "${TEST_NS}" exec v9a-a -- rm -f "${SENTINEL}" 2>/dev/null || true
  phase "${out}" baseline_begin
  log "  A loop reader up; baseline ${BASELINE_S}s with nothing else on the node"
  ( kubectl -n "${TEST_NS}" exec v9a-a -- python3 -c "$(cat "$(dirname "$0")/v9-lat-loop.py")" \
      0 "${A_FILES}" "${MAX_READER_S}" "${SENTINEL}" > "${out}/a-latency.csv" 2>"${out}/a-latency.err"
  ) </dev/null &
  local APID=$!
  sleep "${BASELINE_S}"
  phase "${out}" baseline_end

  # ---- B's sweep --------------------------------------------------------------
  phase "${out}" b_deploy
  log "  deploying B and sweeping ${B_FILES} files of the 140GB image"
  deploy_pod v9a-b "${MODEL_IMG_B}" normal 3
  wait_for 300 "pod B ready" pod_ready v9a-b || log "  WARN: pod B not Ready; continuing"
  phase "${out}" b_read_begin
  full_read v9a-b "${B_FILES}" > "${out}/b-full-read.txt" 2>&1 || true
  phase "${out}" b_read_end
  log "  B done: $(grep -E '^READ' "${out}/b-full-read.txt" || echo '(no READ line)')"

  # ---- 5 minute tail, A still reading ----------------------------------------
  phase "${out}" tail_begin
  log "  tail: ${TAIL_S}s with A still reading and B gone"
  teardown_pod v9a-b
  sleep "${TAIL_S}"
  phase "${out}" tail_end

  kubectl -n "${TEST_NS}" exec v9a-a -- touch "${SENTINEL}" 2>/dev/null || true
  wait "${APID}" 2>/dev/null || true
  stop_sampler; trap - RETURN
  phase "${out}" reader_stopped

  sg_metrics_snapshotter > "${out}/metrics-after.txt"
  docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${out}/journal-stargz.txt" 2>&1 || true
  docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${out}/fuse-manager.log" 2>&1 || true
  kubectl -n "${TEST_NS}" get events --sort-by=.lastTimestamp > "${out}/pod-events.txt" 2>&1 || true
  { echo "ended_utc=$(date -u +%FT%TZ)"
    echo "a_read_errors=$(awk -F, 'NR>1 && $7!="" {n++} END{print n+0}' "${out}/a-latency.csv")"
    echo "a_reads=$(awk 'NR>1' "${out}/a-latency.csv" | wc -l | tr -d ' ')"; } >> "${out}/meta.txt"
  teardown_pod v9a-a

  local aerr; aerr=$(awk -F= '/^a_read_errors=/{print $2}' "${out}/meta.txt")
  if [ "${aerr:-0}" -gt 0 ]; then
    log "  *** FATAL: ${aerr} read errors on pod A -- P0 finding against the paper ***"
    { echo "pod A saw ${aerr} read errors during V9-A rep ${rep}."
      echo "PRE-REGISTRATION-v9 s3: any EIO/ESTALE on A is a FATAL finding."
      awk -F, 'NR==1 || $7!=""' "${out}/a-latency.csv" | head -20; } > "${out}/FATAL.txt"
  fi

  python3 "$(dirname "$0")/42-v9a-analyse.py" "${out}" > "${out}/REP-SUMMARY.txt" 2>&1 || true
  cat "${out}/REP-SUMMARY.txt"
  bash "$(dirname "$0")/91-collect-one.sh" "v9a/rep${rep}" || log "  WARN: collection failed"
}

mkdir -p "${V9A}"
# REP_LIST rather than a plain 1..N loop: the registry-side refetch capture has
# to be opened and closed AROUND each repetition, and that is driven from the
# workstation (44-v9a-run.sh), which runs this script one repetition at a time.
# Giving the node an ssh key to the registry purely to bracket a log would be a
# worse trade than passing the loop outward.
REP_LIST="${REP_LIST:-$(seq 1 "${REPS}")}"
for r in ${REP_LIST}; do rep_run "${r}"; done
log "V9-A done -> ${V9A}"
