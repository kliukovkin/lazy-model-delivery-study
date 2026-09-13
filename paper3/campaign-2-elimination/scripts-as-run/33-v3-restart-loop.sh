#!/usr/bin/env bash
# V3 [P0] -- the S5 restart loop, before/after, plus the C1 6.2 inode question.
#
# v4 s13 measured ~17-18GB of cache growth per graceful restart, linear, with
# nothing reclaiming it: five restarts took a 92GB partition from 11% to 84%.
# With an 80GB budget the duplication should still be created and then evicted,
# so occupancy should stay bounded where v4's ran away.
#
# The second question is what that space actually IS. C1-REPORT 6.2 hypothesises
# deleted-but-open inodes held by the surviving FUSE manager, which would explain
# v4's directory counts staying pinned at 10/10 while df climbed. Every step here
# records du (link-visible bytes), df (real blocks) and lsof +L1 (unlinked but
# still open), which is the first direct test of it. See PRE-REGISTRATION s3.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

RESTARTS="${RESTARTS:-8}"
POD=v3-resident
IMG="${MODEL_IMG_PREFIX}:estargz-140g"
WARM_FILES="${WARM_FILES:-8}"
OUT="${RESULTS_DIR}/v3/restart-loop"; mkdir -p "${OUT}"

{
  echo "experiment=V3"; echo "sha=${OUR_SHA}"; echo "restarts=${RESTARTS}"
  echo "budget_bytes=${CACHE_BUDGET_BYTES}"; echo "policy=${CACHE_POLICY}"
  echo "warm_files=${WARM_FILES}"; echo "started_utc=$(date -u +%FT%TZ)"
} > "${OUT}/meta.txt"

log "V3: hard reset"
hard_reset || die "hard_reset failed"

log "V3: deploying resident pod and warming ${WARM_FILES} files"
deploy_pod "${POD}" "${IMG}" normal 3
wait_for 300 "pod ready" pod_ready "${POD}" || die "pod never Ready"
mount_probe "${POD}" 0 "${WARM_FILES}" > "${OUT}/warm-read.txt" 2>&1 || true
grep -E '^READ|^ERRNOS' "${OUT}/warm-read.txt"

# One row per step. du/df/lsof are the C1 6.2 triple; the metric columns are the
# budget question.
echo "step,ts,df_used,du_http,du_fs,du_total,df_minus_du,lsof_deleted_bytes,lsof_deleted_files,metric_bytes,evictions,evicted_bytes,writes_skipped,fm_pid,grpc_pid,mounts,read_ok,read_err,errnos" > "${OUT}/restart-loop.csv"

step_row() { # step_row <step>
  local step="$1" du h f t dfu lb lf m
  du="$(cache_du)"; h=$(echo "${du}" | awk '{print $1}'); f=$(echo "${du}" | awk '{print $2}')
  t=$(( ${h:-0} + ${f:-0} )); dfu="$(cache_used_bytes)"
  lb="$(lsof_deleted_bytes)"; lf="$(sudo lsof +L1 2>/dev/null | awk -v m="${STARGZ_CACHE_MOUNT}" 'NR>1 && index($NF,m)==1' | wc -l | tr -d ' ')"
  m="$(sg_metrics)"
  local ok err errnos
  mount_probe "${POD}" 0 "${WARM_FILES}" > "${OUT}/probe-after-restart-${step}.txt" 2>&1 || true
  ok=$(sed -n 's/.*ok=\([0-9]*\) err=.*/\1/p' "${OUT}/probe-after-restart-${step}.txt" | head -1)
  err=$(sed -n 's/.*err=\([0-9]*\) bytes=.*/\1/p' "${OUT}/probe-after-restart-${step}.txt" | head -1)
  errnos=$(sed -n 's/^ERRNOS //p' "${OUT}/probe-after-restart-${step}.txt" | head -1 | tr ',' ';')
  sudo lsof +L1 2>/dev/null | awk -v m="${STARGZ_CACHE_MOUNT}" 'NR==1 || index($NF,m)==1' > "${OUT}/lsof-L1-${step}.txt" || true
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${step}" "$(date -u +%FT%TZ)" "${dfu:-0}" "${h:-0}" "${f:-0}" "${t}" "$(( ${dfu:-0} - t ))" \
    "${lb:-0}" "${lf:-0}" \
    "$(metric_sum "${m}" stargz_cache_bytes_used)" \
    "$(metric_sum "${m}" stargz_fs_cache_evictions_total)" \
    "$(metric_sum "${m}" stargz_fs_cache_evicted_bytes_total)" \
    "$(metric_sum "${m}" stargz_fs_cache_writes_skipped_total)" \
    "$(sg_fm_pid)" "$(sg_grpc_pid)" "$(sg_mounts)" \
    "${ok:-}" "${err:-}" "${errnos:-}" >> "${OUT}/restart-loop.csv"
}

log "V3: baseline (step 0)"
step_row 0
for i in $(seq 1 "${RESTARTS}"); do
  log "V3: graceful restart ${i}/${RESTARTS}"
  docker exec "$(NODE_CTR)" systemctl restart stargz-snapshotter
  sleep 8
  docker exec "$(NODE_CTR)" systemctl is-active stargz-snapshotter >/dev/null 2>&1 \
    || { log "unit not active after restart ${i} -- stopping loop"; break; }
  # The index rebuilds asynchronously after a restart; wait for it so the metric
  # column is comparable step to step rather than catching a mid-rebuild zero.
  wait_for 180 "index rebuild to finish" index_not_rebuilding || true
  step_row "${i}"
  tail -1 "${OUT}/restart-loop.csv"
  # Guard: v4's loop was cut short by the node itself. Stop cleanly instead.
  pct=$(cache_pct); if [ "${pct:-0}" -ge 95 ]; then log "partition at ${pct}% -- stopping loop at step ${i}"; break; fi
done

docker exec "$(NODE_CTR)" journalctl -u stargz-snapshotter --no-pager > "${OUT}/journal-stargz.txt" 2>&1 || true
sg_metrics > "${OUT}/metrics-after.txt"
teardown_pod "${POD}"

python3 - "${OUT}/restart-loop.csv" "${CACHE_BUDGET_BYTES}" > "${OUT}/VERDICT.txt" <<'PY'
import csv, sys
rows=list(csv.DictReader(open(sys.argv[1]))); budget=float(sys.argv[2])
g=lambda r,k: float(r[k]) if r.get(k) not in (None,"") else 0.0
print("steps=%d" % len(rows))
if rows:
    print("df_used_first=%d df_used_last=%d df_used_max=%d"
          % (g(rows[0],"df_used"), g(rows[-1],"df_used"), max(g(r,"df_used") for r in rows)))
    print("budget=%d exceeded_budget=%s" % (budget, max(g(r,"df_used") for r in rows) > budget))
    print("evicted_bytes_total=%d" % g(rows[-1],"evicted_bytes"))
    errs=sum(g(r,"read_err") for r in rows); print("read_err_total=%d" % errs)
    pids={r["fm_pid"] for r in rows if r["fm_pid"]}; print("fm_pids_seen=%s stable=%s" % (sorted(pids), len(pids)==1))
    # C1 6.2: does df-minus-du match what lsof says is unlinked-but-open?
    print("--- C1 6.2 inode hypothesis ---")
    for r in rows:
        d=g(r,"df_minus_du"); l=g(r,"lsof_deleted_bytes")
        ratio = (l/d*100) if d>0 else float("nan")
        print("step=%s df_minus_du=%d lsof_deleted=%d lsof_as_pct_of_gap=%.1f files=%s"
              % (r["step"], d, l, ratio, r["lsof_deleted_files"]))
PY
cat "${OUT}/VERDICT.txt"
log "V3 done -> ${OUT}"
