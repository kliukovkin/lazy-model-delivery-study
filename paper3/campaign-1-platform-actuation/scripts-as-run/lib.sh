# shellcheck shell=bash
# spike-v4 shared helpers. Descended from v3.1's lib.sh; the KServe/isvc helpers
# are dropped (v4 uses raw Pods, see env.sh) and stargz-daemon / errno-probe /
# cache-accounting helpers are added.

now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.3f", b-a}'; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# wait_for <timeout_s> <desc> <cmd...>
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local t0; t0=$(now)
  while true; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    if awk -v a="$t0" -v b="$(now)" -v t="$timeout" 'BEGIN{exit !(b-a>t)}'; then
      log "timeout (${timeout}s) waiting for: ${desc}"; return 1
    fi
    sleep 0.5
  done
}

NODE_CTR() { echo "${CLUSTER_NAME}-control-plane"; }

# Process-matching patterns. NOT negotiable details:
#  - `pgrep -x containerd-stargz-grpc` matches NOTHING: pgrep -x compares against
#    /proc/PID/comm, which the kernel truncates to 15 chars ("containerd-star").
#    Same for stargz-fuse-manager -> "stargz-fuse-man". Verified live on this rig.
#  - `pgrep -f containerd-stargz-grpc` OVER-matches: the FUSE manager's own argv
#    contains "-address /run/containerd-stargz-grpc/fuse-manager.sock", so it hits
#    both daemons, plus the matching shell itself.
#  - Anchoring on the absolute executable path is exact, and the leading "^" also
#    prevents the v3.1 pkill-self-match pitfall (the `sh -c` wrapper's argv does not
#    start with /usr/local/bin).
export GRPC_PAT='^/usr/local/bin/containerd-stargz-grpc'
export FM_PAT='^/usr/local/bin/stargz-fuse-manager'
export FM_PAT_MAIN='^/usr/local/bin/stargz-fuse-manager'


pod_condition_true() { # <ns> <pod> <ConditionType>
  [ "$(kubectl -n "$1" get pod "$2" -o jsonpath="{.status.conditions[?(@.type=='$3')].status}" 2>/dev/null)" = "True" ]
}
pod_ready()    { pod_condition_true "${TEST_NS}" "$1" Ready; }
pod_restarts() { kubectl -n "${TEST_NS}" get pod "$1" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null; }
pod_phase()    { kubectl -n "${TEST_NS}" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }

deploy_pod() { # deploy_pod <name> <image-ref> [mode] [num_sample_files]
  NAME="$1" TEST_NS="${TEST_NS}" IMAGE_REF="$2" PREDICTOR_IMG="${PREDICTOR_IMG}" \
  PREDICTOR_MODE="${3:-normal}" NUM_SAMPLE_FILES="${4:-3}" READ_BYTES="${READ_BYTES:-67108864}" \
    envsubst < "${BENCH_ROOT}/templates/pod-custom-predictor.yaml" | kubectl apply -f - >/dev/null
}
teardown_pod() { # <name>
  kubectl -n "${TEST_NS}" delete pod "$1" --ignore-not-found --grace-period=5 >/dev/null 2>&1 || true
  wait_for 180 "pod $1 gone" sh -c "! kubectl -n ${TEST_NS} get pod $1 >/dev/null 2>&1" || true
}

# ---------------------------------------------------------------- stargz cache accounting
# du -sb on each cache subtree, from INSIDE the kind node. Reported separately
# because the S1 cache-duplication question is specifically about httpcache and
# fscache, not about the snapshotter's layer tree that shares the same root.
cache_du() { # cache_du -> "httpcache_bytes fscache_bytes stargzroot_bytes snapshotter_bytes total_bytes"
  docker exec "$(NODE_CTR)" sh -c "
    h=\$(du -sb ${STARGZ_ROOT_IN_NODE}/stargz/httpcache 2>/dev/null | awk '{print \$1}'); h=\${h:-0}
    f=\$(du -sb ${STARGZ_ROOT_IN_NODE}/stargz/fscache   2>/dev/null | awk '{print \$1}'); f=\${f:-0}
    s=\$(du -sb ${STARGZ_ROOT_IN_NODE}/stargz           2>/dev/null | awk '{print \$1}'); s=\${s:-0}
    n=\$(du -sb ${STARGZ_ROOT_IN_NODE}/snapshotter      2>/dev/null | awk '{print \$1}'); n=\${n:-0}
    t=\$(du -sb ${STARGZ_ROOT_IN_NODE}                  2>/dev/null | awk '{print \$1}'); t=\${t:-0}
    echo \"\$h \$f \$s \$n \$t\"
  " 2>/dev/null || echo "0 0 0 0 0"
}
cache_df() { docker exec "$(NODE_CTR)" df -B1 "${STARGZ_ROOT_IN_NODE}" 2>/dev/null | tail -1; }
cache_pct() { df --output=pcent "${STARGZ_CACHE_MOUNT}" 2>/dev/null | tail -1 | tr -d ' %'; }

# ---------------------------------------------------------------- stargz daemon control
sg_pids() { docker exec "$(NODE_CTR)" sh -c "ps -eo pid,etimes,args | grep -E '/usr/local/bin/(containerd-stargz-grpc|stargz-fuse-manager)' | grep -v grep" 2>/dev/null || true; }
sg_grpc_pid() { docker exec "$(NODE_CTR)" sh -c "pgrep -f '${GRPC_PAT}'" 2>/dev/null | head -1 || true; }
sg_fm_pid()   { docker exec "$(NODE_CTR)" sh -c "pgrep -f '${FM_PAT}'"   2>/dev/null | head -1 || true; }
sg_kill() {  # sg_kill <signal> <grpc|fm|both>
  local sig="$1" who="$2" n; n="$(NODE_CTR)"
  case "${who}" in
    grpc) docker exec "${n}" sh -c "pkill -${sig} -f '${GRPC_PAT}'" || true ;;
    fm)   docker exec "${n}" sh -c "pkill -${sig} -f '${FM_PAT}'"   || true ;;
    both) docker exec "${n}" sh -c "pkill -${sig} -f '${FM_PAT}'; pkill -${sig} -f '${GRPC_PAT}'" || true ;;
  esac
}
sg_mounts()   { docker exec "$(NODE_CTR)" sh -c "grep -c 'containerd-stargz-grpc' /proc/self/mountinfo" 2>/dev/null || echo 0; }
sg_unit_active() { docker exec "$(NODE_CTR)" systemctl is-active stargz-snapshotter 2>/dev/null || echo unknown; }

# Lazily detach any stargz FUSE snapshot mounts still present. Needed because a
# SIGKILLed FUSE manager does NOT unmount, and the orphaned mounts then hold the
# deleted cache files open so `rm` frees no blocks. NEVER touches <root>/snapshotter
# itself -- v3.1 RUN-REPORT s10 records that deleting it bricked the whole node.
sg_umount_stale() {
  docker exec "$(NODE_CTR)" sh -c '
    awk "\$5 ~ /containerd-stargz-grpc/ && \$5 ~ /\/fs\$/ {print \$5}" /proc/self/mountinfo       | while read -r m; do umount -l "$m" 2>/dev/null || true; done' 2>/dev/null || true
}

# Authoritative on-disk usage: df counts real blocks. `du -sb` on <root>/snapshotter
# walks INTO the FUSE mounts and returns apparent (TOC) sizes -- 150GB on a 92GB
# partition -- so df is what the report quotes.
cache_used_bytes() { df -B1 --output=used "${STARGZ_CACHE_MOUNT}" 2>/dev/null | tail -1 | tr -d " "; }

# ---------------------------------------------------------------- errno probe
# Reads the first 1MiB of each of the first N ballast files through the FUSE
# mount and reports the NUMERIC errno per file. `dd` only prints a strerror
# string ("Stale file handle"); the numeric code is what distinguishes
# ESTALE(116) from EIO(5) from ENOTCONN(107) unambiguously in the report.
# A dead FUSE mount makes glob("/mnt/models/ballast-*.bin") return [] SILENTLY. The
# first S1 attempt scored that as ok=0/err=0 and the verdict logic read it as success.
# This probe therefore (a) stats and lists the mount directory explicitly and
# (b) opens FIXED, computed filenames, so "attempted" is constant regardless of
# whether the mount is alive.
MOUNT_PROBE_PY='
import os, sys, errno, time, collections
d = "/mnt/models"
lo = int(sys.argv[1]); hi = int(sys.argv[2])
try:
    os.stat(d); print("DIRSTAT ok")
except OSError as e:
    print("DIRSTAT errno=%d %s" % (e.errno, errno.errorcode.get(e.errno, "?")))
try:
    print("LISTDIR n=%d" % len(os.listdir(d)))
except OSError as e:
    print("LISTDIR errno=%d %s" % (e.errno, errno.errorcode.get(e.errno, "?")))
names = ["ballast-%d.bin" % i for i in range(lo + 1, hi + 1)]
t0 = time.time(); total = 0; ok = 0; errs = collections.Counter(); bad = []
for n in names:
    p = os.path.join(d, n)
    try:
        with open(p, "rb") as f:
            while True:
                c = f.read(32 << 20)
                if not c: break
                total += len(c)
        ok += 1
    except OSError as e:
        errs[e.errno] += 1
        bad.append("%s errno=%d %s" % (n, e.errno, errno.errorcode.get(e.errno, "?")))
print("READ range=[%d:%d] attempted=%d ok=%d err=%d bytes=%d elapsed_s=%.3f"
      % (lo, hi, len(names), ok, len(bad), total, time.time() - t0))
print("ERRNOS " + (";".join("%s=%d" % (errno.errorcode.get(k, str(k)), v)
      for k, v in sorted(errs.items())) or "none"))
for b in bad: print("BADFILE " + b)
'
mount_probe() { kubectl -n "${TEST_NS}" exec "$1" -- python3 -c "${MOUNT_PROBE_PY}" "$2" "$3" 2>&1; }

# S2/S3 call these; both are now the same fixed-name, mount-aware probe, so a dead
# mount can never masquerade as "zero errors" the way it did in S1 attempt 1.
full_read()   { mount_probe "$1" 0 "${2:-280}"; }   # all 280 ballast files
errno_probe() { mount_probe "$1" 0 "${2:-10}"; }

# Full reset to a known-good, empty-cache, running state. Must tolerate the state
# S1's T6 (kill -9 of BOTH daemons) deliberately leaves behind: a stale
# fuse-manager.sock, an orphaned manager, stale FUSE mountpoints (which make the
# next mount fail with "fusermount exited with code 256"), and a systemd unit that
# has hit its start limit ("Start request repeated too quickly").
hard_reset() {
  local n; n="$(NODE_CTR)"
  docker exec "${n}" systemctl stop stargz-snapshotter 2>/dev/null || true
  sleep 2
  sg_kill TERM fm; sleep 4          # graceful: lets the manager unmount its own mounts
  sg_kill 9 fm; sg_kill 9 grpc; sleep 1
  docker exec "${n}" sh -c 'rm -f /run/containerd-stargz-grpc/fuse-manager.sock' || true
  sg_umount_stale                    # anything a SIGKILLed manager left mounted
  # remove EVERY pre-fill filler, not just S2's: an aborted trial leaves its own
  # filler behind and the next hard_reset would silently start from a full partition.
  sudo sh -c "rm -rf ${STARGZ_CACHE_MOUNT}/stargz/httpcache/* ${STARGZ_CACHE_MOUNT}/stargz/fscache/* ${STARGZ_CACHE_MOUNT}/*filler*.img" 2>/dev/null || true
  sync
  local pct; pct=$(cache_pct)
  if [ "${pct:-100}" -gt 15 ]; then
    log "hard_reset: cache still ${pct}% after wipe -- listing what is holding it"
    sudo du -x -h -d2 "${STARGZ_CACHE_MOUNT}" 2>/dev/null | sort -h | tail -6 >&2
  fi
  docker exec "${n}" systemctl reset-failed stargz-snapshotter 2>/dev/null || true
  docker exec "${n}" systemctl start stargz-snapshotter
  sleep 6
  if ! docker exec "${n}" systemctl is-active stargz-snapshotter >/dev/null 2>&1; then
    log "hard_reset: unit still not active"; docker exec "${n}" journalctl -u stargz-snapshotter --no-pager -n 15 >&2
    return 1
  fi
  log "hard_reset ok: cache $(cache_pct)% used, grpc=$(sg_grpc_pid) fm=$(sg_fm_pid)"
  return 0
}

# ---------------------------------------------------------------- kubelet view
kubelet_view() {
  local n; n=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  echo "--- node conditions ---"
  kubectl get node "${n}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
  echo "--- stats/summary node.fs + imageFs ---"
  kubectl get --raw "/api/v1/nodes/${n}/proxy/stats/summary" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["node"]; print(json.dumps({"fs":d.get("fs"),"runtime":d.get("runtime")}, indent=2))' 2>&1
}

# Rewrite the unit's --log-level and reload. S1's trials are short (24-file reads)
# and want debug for the restore/mount detail; S2/S3c do a full 140GB read where
# debug would produce gigabytes and perturb the very timing being measured.
set_log_level() { # set_log_level <trace|debug|info|warn|error>
  local n; n="$(NODE_CTR)"
  docker exec "${n}" sh -c "sed -i 's/--log-level=[a-z]*/--log-level=$1/' /etc/systemd/system/stargz-snapshotter.service"
  docker exec "${n}" systemctl daemon-reload
  docker exec "${n}" grep ExecStart /etc/systemd/system/stargz-snapshotter.service >&2
}
