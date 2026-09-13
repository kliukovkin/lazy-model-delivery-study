#!/usr/bin/env bash
# V1 [P0] -- integration and accounting accuracy.
#
# One full sweep of the 140GB-class image through a lazy mount with an 80GB
# budget on a 92GB partition, sampling occupancy every 15s from three
# independent sources (the index's own metric, du on the two cache trees, df on
# the partition) so that the metric can be checked against the filesystem rather
# than against itself.
#
# Pre-registered expectations: source-audit/PRE-REGISTRATION-v5.md s1.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

OUT="${RESULTS_DIR}/v1/$(date +%H%M%S)-sweep"; mkdir -p "${OUT}"
POD=v1-sweep
IMG="${MODEL_IMG_PREFIX}:estargz-140g"
INTERVAL="${INTERVAL:-15}"

{
  echo "experiment=V1"
  echo "sha=${OUR_SHA}"
  echo "budget_bytes=${CACHE_BUDGET_BYTES}"
  echo "high_watermark=${CACHE_HIGH_WM}"
  echo "low_watermark=${CACHE_LOW_WM}"
  echo "policy=${CACHE_POLICY}"
  echo "image=${IMG}"
  echo "sample_interval_s=${INTERVAL}"
  echo "started_utc=$(date -u +%FT%TZ)"
} > "${OUT}/meta.txt"

log "V1: hard reset to an empty cache"
hard_reset || die "hard_reset failed"
sg_metrics > "${OUT}/metrics-before.txt"
grep -E '^stargz_(cache|fs)' "${OUT}/metrics-before.txt" | head -40 || true

# The budget must actually be in force, or the whole experiment measures nothing.
# Prometheus renders this as 8e+10, so the comparison has to be numeric.
BUDGET_SEEN=$(metric_one "$(sg_metrics)" stargz_fs_cache_budget_bytes)
awk -v a="${BUDGET_SEEN}" -v b="${CACHE_BUDGET_BYTES}" 'BEGIN{exit !(a+0 == b+0)}' \
  || die "budget metric reads '${BUDGET_SEEN}', expected ${CACHE_BUDGET_BYTES} -- config did not take"
log "V1: budget confirmed live at ${BUDGET_SEEN}"

start_sampler "${OUT}/sampler.csv" "${INTERVAL}"
# V6: derived access trace. Snapshot the index every 30s; see PRE-REGISTRATION s0b
# for why this is DERIVED-NOT-CAPTURED.
mkdir -p "${OUT}/index-snapshots"
( while :; do index_dump "${OUT}/index-snapshots/idx-$(date +%s).tsv" 2>/dev/null; sleep 30; done ) </dev/null >/dev/null 2>&1 &
IDXPID=$!
trap 'stop_sampler; kill ${IDXPID} 2>/dev/null || true' EXIT

log "V1: deploying ${POD}"
T0=$(now)
deploy_pod "${POD}" "${IMG}" normal 3
wait_for 300 "pod ready" pod_ready "${POD}" || { kubectl -n "${TEST_NS}" describe pod "${POD}" > "${OUT}/pod-describe.txt"; die "pod never became Ready"; }
READY_S=$(elapsed "${T0}")
echo "deploy_to_ready_s=${READY_S}" >> "${OUT}/meta.txt"
log "V1: Ready in ${READY_S}s -- starting the full 280-file sweep"

SWEEP_T0=$(now)
full_read "${POD}" 280 > "${OUT}/full-read.txt" 2>&1 || true
SWEEP_S=$(elapsed "${SWEEP_T0}")
echo "sweep_s=${SWEEP_S}" >> "${OUT}/meta.txt"
cat "${OUT}/full-read.txt"

sleep "${INTERVAL}"          # let one more sample land after the sweep
stop_sampler; kill ${IDXPID} 2>/dev/null || true; trap - EXIT

sg_metrics > "${OUT}/metrics-after.txt"
kubectl -n "${TEST_NS}" describe pod "${POD}" > "${OUT}/pod-describe.txt" 2>&1 || true
kubectl -n "${TEST_NS}" get events --sort-by=.lastTimestamp > "${OUT}/pod-events.txt" 2>&1 || true
docker exec "$(NODE_CTR)" journalctl -u stargz-snapshotter --no-pager > "${OUT}/journal-stargz.txt" 2>&1 || true
grep -ci "no space left" "${OUT}/journal-stargz.txt" > "${OUT}/enospc-count.txt" || echo 0 > "${OUT}/enospc-count.txt"
teardown_pod "${POD}"

# ---------------------------------------------------------------- verdict
# Facts only. Interpretation belongs in the report, not in the harness.
python3 - "${OUT}/sampler.csv" "${OUT}/full-read.txt" "${CACHE_BUDGET_BYTES}" "${CACHE_HIGH_WM}" "${CACHE_LOW_WM}" > "${OUT}/VERDICT.txt" <<'PY'
import csv, sys, re
rows = list(csv.DictReader(open(sys.argv[1])))
read = open(sys.argv[2]).read()
budget = float(sys.argv[3]); hi = budget*float(sys.argv[4]); lo = budget*float(sys.argv[5])
def f(r, k):
    try: return float(r[k])
    except: return 0.0
print("samples=%d" % len(rows))
if rows:
    peak = max(f(r,"metric_bytes") for r in rows)
    peak_df = max(f(r,"df_used") for r in rows)
    fin = f(rows[-1],"metric_bytes")
    print("peak_metric_bytes=%d (%.1f%% of budget)" % (peak, 100*peak/budget))
    print("peak_df_used=%d" % peak_df)
    print("final_metric_bytes=%d" % fin)
    print("high_watermark_bytes=%d low_watermark_bytes=%d" % (hi, lo))
    print("exceeded_budget=%s" % (peak > budget))
    print("exceeded_high_wm=%s" % (peak > hi))
    # V1a drift: |metric - du| / du, only where du > 1GB (below that the
    # relative error is dominated by the flush interval, not by drift).
    drifts = [(f(r,"metric_bytes")-f(r,"du_total"))/f(r,"du_total")*100
              for r in rows if f(r,"du_total") > 1e9]
    if drifts:
        print("drift_pct_min=%.2f drift_pct_max=%.2f drift_pct_final=%.2f"
              % (min(drifts), max(drifts), drifts[-1]))
        print("drift_pct_abs_max=%.2f" % max(abs(d) for d in drifts))
    # df >= du is the C1 6.2 direction; report it, do not judge it here.
    gaps = [f(r,"df_used")-f(r,"du_total") for r in rows if f(r,"du_total") > 1e9]
    if gaps:
        print("df_minus_du_min=%d df_minus_du_max=%d" % (min(gaps), max(gaps)))
    print("evictions_final=%d" % f(rows[-1],"evictions"))
    print("evicted_bytes_final=%d" % f(rows[-1],"evicted_bytes"))
    print("writes_skipped_final=%d" % f(rows[-1],"writes_skipped"))
    print("fetch_errors_final=%d" % f(rows[-1],"fetch_errors"))
    print("dropped_events_final=%d" % f(rows[-1],"dropped"))
m = re.search(r"attempted=(\d+) ok=(\d+) err=(\d+) bytes=(\d+)", read)
if m:
    print("read_attempted=%s read_ok=%s read_err=%s read_bytes=%s" % m.groups())
print("ERRNOS " + (re.search(r"^ERRNOS (.*)$", read, re.M).group(1) if re.search(r"^ERRNOS ", read, re.M) else "?"))
PY
cat "${OUT}/VERDICT.txt"
log "V1 done -> ${OUT}"
