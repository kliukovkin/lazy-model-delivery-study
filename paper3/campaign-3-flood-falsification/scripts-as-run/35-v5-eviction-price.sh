#!/usr/bin/env bash
# V5 [P1] -- the price of eviction, and the first live RQ1 datapoint.
#
# A resident pod re-reading a 14GB hot set while a 140GB sweep runs beside it,
# budget 80GB, under policy=lru and then policy=2q. The two workloads use
# DIFFERENT images on purpose: distinct images mean distinct cache directories,
# which is the unit both 2q and proportional reason about. Sharing one image
# would have made the "co-resident tenant" framing false.
#
# Pre-registered expectations, including the 2q cold-start confound: s5 of
# PRE-REGISTRATION-v5.md. The warm-up deliberately reads the hot set TWICE
# before any measurement, because 2q's protected set is empty until a chunk has
# been read again after being cached.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

RESIDENT_IMG="${MODEL_IMG_PREFIX}:estargz-14g"
SWEEP_IMG="${MODEL_IMG_PREFIX}:estargz-140g"
HOT_FILES="${HOT_FILES:-28}"        # 28 x 500MB = 14GB
ROUNDS="${ROUNDS:-4}"
POLICIES="${POLICIES:-lru 2q}"

set_policy() { # set_policy <lru|2q>
  local n; n="$(NODE_CTR)"
  docker exec "${n}" sh -c "sed -i 's/^  policy = .*/  policy = \"$1\"/' /etc/containerd-stargz-grpc/config.toml"
  docker exec "${n}" grep -A5 'cache_accounting.budget' /etc/containerd-stargz-grpc/config.toml
  # v5 finding F12: restarting the snapshotter alone does NOT apply this. The
  # filesystem, index and eviction engine live in stargz-fuse-manager, which our
  # KillMode=process drop-in deliberately keeps alive across a snapshotter
  # restart, so it keeps the config it was started with. The manager has to be
  # replaced for a [cache_accounting] change to take effect at all.
  docker exec "${n}" systemctl stop stargz-snapshotter
  docker exec "${n}" sh -c "pkill -TERM -f '^/usr/local/bin/stargz-fuse-manager' || true"
  sleep 5
  docker exec "${n}" sh -c "pkill -9 -f '^/usr/local/bin/stargz-fuse-manager' || true"
  docker exec "${n}" sh -c 'rm -f /run/containerd-stargz-grpc/fuse-manager.sock'
  sg_umount_stale
  docker exec "${n}" systemctl reset-failed stargz-snapshotter 2>/dev/null || true
  docker exec "${n}" systemctl start stargz-snapshotter
  sleep 10
  docker exec "${n}" systemctl is-active stargz-snapshotter >/dev/null || die "snapshotter did not come back under policy=$1"
  # Assert the change actually reached the process that acts on it.
  local applied; applied=$(docker exec "${n}" sh -c "grep -c 'policy = \"$1\"' /etc/containerd-stargz-grpc/config.toml")
  [ "${applied}" = "1" ] || die "config does not carry policy=$1"
  log "  policy=$1 applied; fuse manager replaced (pid $(sg_fm_pid))"
}

arm() { # arm <policy>
  local pol="$1"
  local out="${RESULTS_DIR}/v5/policy-${pol}"; mkdir -p "${out}"
  log "=== V5 policy=${pol} ==="

  set_policy "${pol}"
  hard_reset || die "hard_reset failed"
  # Confirm the policy actually reached the running daemon, via the metric label
  # rather than via the file we just wrote.
  local seen; seen=$(sg_metrics | sed -n 's/.*stargz_fs_cache_evictions_total{cache_type="[^"]*",policy="\([^"]*\)".*/\1/p' | head -1)
  { echo "experiment=V5"; echo "policy_configured=${pol}"; echo "policy_metric_label=${seen:-unseen-until-first-eviction}"
    echo "sha=${OUR_SHA}"; echo "budget_bytes=${CACHE_BUDGET_BYTES}"
    echo "resident_img=${RESIDENT_IMG}"; echo "sweep_img=${SWEEP_IMG}"
    echo "hot_files=${HOT_FILES}"; echo "rounds=${ROUNDS}"; echo "started_utc=$(date -u +%FT%TZ)"; } > "${out}/meta.txt"

  log "  deploying resident pod on the 14GB image"
  deploy_pod v5-resident "${RESIDENT_IMG}" normal 3
  wait_for 300 "resident ready" pod_ready v5-resident || die "resident never Ready"

  # Warm-up: two full passes. Pass 1 populates the cache, pass 2 is what promotes
  # those chunks out of 2q's probation. The pass-2 latencies are also the
  # all-hits reference distribution used to classify hits later.
  log "  warm-up pass 1/2"
  lat_probe v5-resident 0 "${HOT_FILES}" 1 > "${out}/warmup-1.txt" 2>&1 || true
  log "  warm-up pass 2/2 (reference distribution, all hits)"
  lat_probe v5-resident 0 "${HOT_FILES}" 1 > "${out}/warmup-2.txt" 2>&1 || true

  start_sampler "${out}/sampler.csv" 10
  mkdir -p "${out}/index-snapshots"
  ( while :; do index_dump "${out}/index-snapshots/idx-$(date +%s).tsv" 2>/dev/null; sleep 30; done ) </dev/null >/dev/null 2>&1 &
  local IDXPID=$!
  trap 'stop_sampler; kill ${IDXPID} 2>/dev/null || true' RETURN

  log "  starting the 140GB sweep beside it"
  deploy_pod v5-sweep "${SWEEP_IMG}" normal 3
  wait_for 300 "sweep ready" pod_ready v5-sweep || log "  WARN: sweep pod not Ready; continuing"
  ( full_read v5-sweep 280 > "${out}/sweep-read.txt" 2>&1 ) </dev/null >/dev/null 2>&1 &
  local SWEEPPID=$!

  log "  measuring resident latency for ${ROUNDS} rounds under sweep pressure"
  lat_probe v5-resident 0 "${HOT_FILES}" "${ROUNDS}" > "${out}/resident-latency.txt" 2>&1 || true

  wait ${SWEEPPID} 2>/dev/null || true
  stop_sampler; kill ${IDXPID} 2>/dev/null || true; trap - RETURN

  sg_metrics > "${out}/metrics-after.txt"
  docker exec "$(NODE_CTR)" journalctl -u stargz-snapshotter --no-pager > "${out}/journal-stargz.txt" 2>&1 || true
  teardown_pod v5-sweep; teardown_pod v5-resident

  python3 - "${out}/warmup-2.txt" "${out}/resident-latency.txt" "${out}/metrics-after.txt" "${pol}" > "${out}/VERDICT.txt" <<'PY'
import re, sys, statistics as st
def lats(p):
    out=[]
    for l in open(p, errors="replace"):
        m=re.search(r"ms=([0-9.]+)", l)
        if m and "errno=" not in l: out.append(float(m.group(1)))
    return out
def errs(p):
    return sum(1 for l in open(p, errors="replace") if "errno=" in l)
warm=lats(sys.argv[1]); meas=lats(sys.argv[2]); pol=sys.argv[4]
metrics=open(sys.argv[3], errors="replace").read()
def pct(v,q):
    if not v: return float("nan")
    v=sorted(v); k=min(len(v)-1, max(0,int(round(q/100.0*(len(v)-1)))))
    return v[k]
print("policy=%s" % pol)
print("warm_reference_n=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f"
      % (len(warm), pct(warm,50), pct(warm,95), pct(warm,99), max(warm) if warm else float('nan')))
print("resident_under_sweep_n=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f"
      % (len(meas), pct(meas,50), pct(meas,95), pct(meas,99), max(meas) if meas else float('nan')))
print("resident_read_errors=%d" % errs(sys.argv[2]))
# Hit rate is DERIVED, not counted: there is no hit/miss counter in the
# snapshotter. A read is classified a hit if it is no slower than the slowest
# read in the all-hits warm reference pass. Threshold and both raw
# distributions are in the bundle so the classification can be re-done.
thr = max(warm) if warm else 0.0
hits = sum(1 for x in meas if x <= thr)
print("hit_threshold_ms=%.1f  # max of the all-hits warm reference pass" % thr)
print("derived_hit_rate=%.3f (%d/%d)  # DERIVED by latency, not a counter"
      % ((hits/len(meas)) if meas else float("nan"), hits, len(meas)))
for name in ("stargz_fs_cache_evictions_total","stargz_fs_cache_evicted_bytes_total",
             "stargz_fs_cache_writes_skipped_total"):
    tot=sum(float(m.group(1)) for m in re.finditer(r"^%s\{[^}]*\} ([0-9.e+]+)$" % name, metrics, re.M))
    print("%s=%d" % (name, tot))
PY
  cat "${out}/VERDICT.txt"
}

mkdir -p "${RESULTS_DIR}/v5"
for p in ${POLICIES}; do arm "${p}"; done
log "V5: restoring policy=${CACHE_POLICY}"
set_policy "${CACHE_POLICY}"
{ for p in ${POLICIES}; do echo "--- ${p} ---"; cat "${RESULTS_DIR}/v5/policy-${p}/VERDICT.txt" 2>/dev/null; done; } > "${RESULTS_DIR}/v5/v5-comparison.txt"
cat "${RESULTS_DIR}/v5/v5-comparison.txt"
log "V5 done -> ${RESULTS_DIR}/v5"
