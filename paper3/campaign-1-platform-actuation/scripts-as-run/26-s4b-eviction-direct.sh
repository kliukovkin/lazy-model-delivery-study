#!/usr/bin/env bash
# spike-v4 S4b: does kubelet ACT on the imageFs visibility that PR #1893 provides?
#
# S4 (first attempt) tried to drive the partition below the 10% threshold using a
# 140GB lazy read. That coupled the kubelet question to the pod/read machinery, and
# the read was SIGKILLed at ~30s with imagefs.available still at 12.6% -- just above
# the threshold -- so the decisive point was never reached. Preserved as
# results/s4/S4-eviction-75pct/ and flagged.
#
# This isolates the question. The pod and the lazy read are only ever a *vehicle* for
# consuming the partition; `fallocate` consumes it directly and deterministically, and
# kubelet's imageFs availableBytes comes from statfs on that filesystem (run 1 showed
# it tracking a fallocate filler exactly). Two phases:
#
#   Phase 1 -- no pod at all. Fill to ~95%, i.e. imagefs.available ~5%, well under the
#              10% evictionHard threshold. Sample node conditions for 150s (the
#              evictionPressureTransitionPeriod is 30s, so this is 5x the settling time).
#              Answers: does kubelet raise DiskPressure on the snapshotter's partition?
#
#   Phase 2 -- with the partition still starved, run a real eStargz pod and sample.
#              Answers: under sustained DiskPressure, does kubelet evict the pod, and
#              does image GC reclaim anything (it keys on used/capacity, which run 1
#              measured stuck at ~0.16%)?
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need kubectl; need envsubst; need docker

NODE="$(NODE_CTR)"
TRIAL="${TRIAL:-S4b-eviction-direct}"
FILL_PCT="${FILL_PCT:-95}"
WATCH_S="${WATCH_S:-150}"
OUT="${RESULTS_DIR}/s4/${TRIAL}"; mkdir -p "${OUT}"
IMG="${MODEL_IMG_PREFIX}:estargz-140g"
POD="s4b-probe"
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

sample_line() { # sample_line <t0> <podname-or-empty>
  local t0="$1" pod="${2:-}" stats dp ph rd rn
  stats=$(kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/stats/summary" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["node"]; i=(d.get("runtime") or {}).get("imageFs") or {}
    a=i.get("availableBytes"); c=i.get("capacityBytes"); u=i.get("usedBytes")
    pct=(100.0*a/c) if (a is not None and c) else -1
    print("%s,%s,%.2f"%(a,u,pct))
except Exception: print("na,na,-1")' 2>/dev/null || echo "na,na,-1")
  dp=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null)
  if [ -n "${pod}" ]; then
    ph=$(kubectl -n "${TEST_NS}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null)
    rd=$(pod_condition_true "${TEST_NS}" "${pod}" Ready && echo true || echo false)
    rn=$(kubectl -n "${TEST_NS}" get pod "${pod}" -o jsonpath='{.status.reason}' 2>/dev/null)
  fi
  echo "$(elapsed "${t0}"),$(cache_pct),${stats},${dp},${ph:-},${rd:-},${rn:-}"
}

log "=== S4b ${TRIAL}: fill to ${FILL_PCT}%, evictionHard imagefs.available=10% ==="
teardown_pod "${POD}"
set_log_level info
hard_reset || die "could not reach a clean state"

{ echo "trial=${TRIAL} fill=${FILL_PCT}% watch=${WATCH_S}s date=$(date -Is)"
  echo "--- kubelet eviction settings actually in force ---"
  kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/configz" \
    | python3 -c 'import json,sys; k=json.load(sys.stdin)["kubeletconfig"]; print(json.dumps({x:k.get(x) for x in ("evictionHard","evictionPressureTransitionPeriod","imageGCHighThresholdPercent","imageGCLowThresholdPercent")}, indent=2))'
  docker exec "${NODE}" containerd-stargz-grpc --version
  docker exec "${NODE}" grep -A6 'proxy_plugins.stargz' /etc/containerd/config.toml
} > "${OUT}/meta.txt" 2>&1

# ---------------------------------------------------------------- phase 1: no pod
CAPACITY_KB=$(df --output=size "${STARGZ_CACHE_MOUNT}" | tail -1)
sudo fallocate -l "$(( CAPACITY_KB * FILL_PCT / 100 ))K" "${STARGZ_CACHE_MOUNT}/s4b-filler.img"
log "phase 1: partition at $(cache_pct)%, no pod running; watching ${WATCH_S}s"
t0=$(now)
echo "t_s,cache_pct,imagefs_avail,imagefs_used,imagefs_avail_pct,disk_pressure,pod_phase,pod_ready,pod_reason" > "${OUT}/phase1-nopod.csv"
end=$(( $(date +%s) + WATCH_S ))
while [ "$(date +%s)" -lt "${end}" ]; do sample_line "${t0}" "" >> "${OUT}/phase1-nopod.csv"; sleep 5; done
tail -3 "${OUT}/phase1-nopod.csv" >&2

# ---------------------------------------------------------------- phase 2: with a pod
log "phase 2: deploying an eStargz pod against the starved partition"
t1=$(now)
deploy_pod "${POD}" "${IMG}" normal 3
wait_for 600 "pod Ready" pod_ready "${POD}" || log "WARN: pod not Ready (itself a result)"
echo "deploy_to_ready_s=$(elapsed "${t1}") ready=$(pod_ready "${POD}" && echo true || echo false)" > "${OUT}/phase2-ready.txt"
echo "t_s,cache_pct,imagefs_avail,imagefs_used,imagefs_avail_pct,disk_pressure,pod_phase,pod_ready,pod_reason" > "${OUT}/phase2-withpod.csv"
t2=$(now); end=$(( $(date +%s) + WATCH_S ))
# a bounded read gives the snapshotter something to do without a 140GB SIGKILL risk
( set +e; mount_probe "${POD}" 0 12 > "${OUT}/phase2-read.txt" 2>&1 ) &
READER=$!
while [ "$(date +%s)" -lt "${end}" ]; do sample_line "${t2}" "${POD}" >> "${OUT}/phase2-withpod.csv"; sleep 5; done
wait "${READER}" 2>/dev/null || true
tail -3 "${OUT}/phase2-withpod.csv" >&2

# ---------------------------------------------------------------- verdict
{ echo "### Q1: did kubelet EVER raise DiskPressure=True?"
  if awk -F, 'NR>1 && $6=="True"{f=1} END{exit !f}' "${OUT}/phase1-nopod.csv" "${OUT}/phase2-withpod.csv" 2>/dev/null; then
    echo "YES -- first occurrence:"
    awk -F, 'NR>1 && $6=="True"{print FILENAME": "$0; exit}' "${OUT}/phase1-nopod.csv" "${OUT}/phase2-withpod.csv"
  else
    echo "NO -- DiskPressure stayed False in every sample of both phases."
  fi
  echo
  echo "### lowest imageFs available% observed"
  awk -F, 'NR>1 && $5!="-1" && $5!=""{if(m==""||$5+0<m+0)m=$5} END{print (m==""?"n/a":m"%")}' "${OUT}/phase1-nopod.csv" "${OUT}/phase2-withpod.csv"
  echo "(evictionHard threshold is imagefs.available=10%)"
  echo
  echo "### imageFs usedBytes range (image GC keys on used/capacity)"
  awk -F, 'NR>1 && $4!="na" && $4!=""{if(lo==""||$4+0<lo+0)lo=$4; if($4+0>hi+0)hi=$4} END{print "min="lo" max="hi}' "${OUT}/phase1-nopod.csv" "${OUT}/phase2-withpod.csv"
  echo
  echo "### was the pod evicted / did it stop Running?"
  awk -F, 'NR>1 && $7!="" && $7!="Running"' "${OUT}/phase2-withpod.csv" | head -5
  echo "(empty above = pod stayed Running throughout)"
  echo
  echo "### eviction / disk / imageGC events"
  kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | grep -iE 'evict|diskpressure|freeDiskSpace|ImageGC|garbage collect' | tail -20
  echo "(empty above = none)"
} > "${OUT}/VERDICT.txt" 2>&1
cat "${OUT}/VERDICT.txt" >&2

{ echo "--- node conditions ---"; kubectl get node "${NODE_NAME}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
  echo "--- df ---"; df -h "${STARGZ_CACHE_MOUNT}"
  echo "--- pod ---"; kubectl -n "${TEST_NS}" get pod "${POD}" -o wide 2>&1
} > "${OUT}/post-state.txt" 2>&1
kubectl get events -A --sort-by=.lastTimestamp > "${OUT}/all-events.txt" 2>&1 || true
docker exec "${NODE}" journalctl -u kubelet --no-pager 2>/dev/null | grep -iE 'evict|diskpressure|imagegc|garbage' | tail -60 > "${OUT}/kubelet-eviction-lines.txt" 2>&1 || true
kubectl -n "${TEST_NS}" describe pod "${POD}" > "${OUT}/pod-describe.txt" 2>&1 || true

teardown_pod "${POD}"
sudo rm -f "${STARGZ_CACHE_MOUNT}/s4b-filler.img" 2>/dev/null || true
log "S4b done -> ${OUT}"
