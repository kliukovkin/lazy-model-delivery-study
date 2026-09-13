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
  # The glob must be expanded by the ROOT shell: these directories are
  # root-owned, so `sudo rm -rf <glob>` from the ubuntu shell expands to nothing
  # and silently removes nothing. Hence sudo sh -c "...".
  sudo sh -c "rm -rf ${STARGZ_CACHE_MOUNT}/stargz/httpcache/* ${STARGZ_CACHE_MOUNT}/stargz/fscache/* ${STARGZ_CACHE_MOUNT}/*filler*.img" 2>/dev/null || true
  # v6: reset the accounting index too. Leaving it behind means the next index
  # loads a database describing ~950k chunks that were just deleted, notices the
  # mismatch, and rebuilds by scanning -- while the next experiment is already
  # writing at full speed. A reset that leaves the index describing a cache that
  # no longer exists is not a reset.
  sudo sh -c "rm -f ${STARGZ_CACHE_MOUNT}/stargz/cache-accounting.db ${STARGZ_CACHE_MOUNT}/stargz/cache-accounting.db.corrupt" 2>/dev/null || true
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

# ============================================================ spike-v5 additions
# The metrics endpoint binds 0.0.0.0:9110 INSIDE the kind node and kind maps no
# host port for it. The node is a docker container on this host, so its bridge IP
# is directly reachable from the host, which has curl for certain; `docker exec
# curl` is kept as a fallback because kindest/node's tool set is not guaranteed.
NODE_IP_CACHE=""
node_ip() {
  [ -n "${NODE_IP_CACHE}" ] && { echo "${NODE_IP_CACHE}"; return; }
  NODE_IP_CACHE=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(NODE_CTR)" 2>/dev/null)
  echo "${NODE_IP_CACHE}"
}
# BOTH endpoints are scraped and concatenated. The snapshotter process serves
# :9110; the FUSE manager process serves :9111 and is where every stargz_cache_*
# and stargz_fs_cache_* series actually lives (v5 finding 1). Scraping only the
# documented one returns nothing at all for this spike.
sg_metrics() {
  local ip; ip=$(node_ip)
  { curl -s --max-time 5 "http://${ip}:9110/metrics" 2>/dev/null
    curl -s --max-time 5 "http://${ip}:${STARGZ_FM_METRICS_ADDRESS##*:}/metrics" 2>/dev/null; } || true
}
# metric_sum <metrics-text> <metric name> -- sums every labelled series of one
# metric. Occupancy is per cache_type and eviction counters are per policy AND
# cache_type, so nearly every number this spike wants is a sum over labels.
metric_sum() {
  awk -v m="$2" '
    $1 == m { s += $2; n++ ; next }
    index($1, m "{") == 1 { s += $2; n++ }
    # An absent counter is 0, not blank: a Prometheus CounterVec exports
    # nothing until a label combination is first used, and a blank column would
    # break every downstream numeric parse.
    END { printf "%.0f", s+0 }
  ' <<< "$1"
}
metric_one() { awk -v m="$2" '$1 == m { print $2; f=1; exit } END { if (!f) print 0 }' <<< "$1"; }

# One sampler row.
#
# v7 adds pressure, rebuilds and the two lock counters. The C4 evidence is the
# pairing of what the index believes (metric_bytes), what the filesystem holds
# (du_total, df_used) and what the budget is now enforced against (pressure) --
# in v6 the first of those stayed at 0.947 of budget while the second ran to
# 100% of the partition, and nothing in between was recorded.
#   ts, metric bytes (http+fs), du http, du fs, df used, budget, occupancy_ratio,
#   evictions, evicted_bytes, writes_skipped, fetch_errors, dropped_events, pinned
sample_header() {
  echo "ts,iso,metric_bytes,metric_http,metric_fs,du_http,du_fs,du_total,df_used,budget,occ_ratio,evictions,evicted_bytes,writes_skipped,fetch_errors,dropped,pinned,rebuilding,pressure,rebuilds,lock_lost,lock_retry"
}
sample_row() {
  local m du h f t dfu
  m="$(sg_metrics)"
  du="$(cache_du)"; h=$(echo "${du}" | awk '{print $1}'); f=$(echo "${du}" | awk '{print $2}')
  t=$(( ${h:-0} + ${f:-0} ))
  dfu="$(cache_used_bytes)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date +%s)" "$(date -u +%FT%TZ)" \
    "$(metric_sum "${m}" stargz_cache_bytes_used)" \
    "$(awk '/^stargz_cache_bytes_used\{cache_type="httpcache"\}/{print $2}' <<< "${m}")" \
    "$(awk '/^stargz_cache_bytes_used\{cache_type="fscache"\}/{print $2}' <<< "${m}")" \
    "${h:-0}" "${f:-0}" "${t}" "${dfu:-0}" \
    "$(metric_one "${m}" stargz_fs_cache_budget_bytes)" \
    "$(metric_one "${m}" stargz_fs_cache_occupancy_ratio)" \
    "$(metric_sum "${m}" stargz_fs_cache_evictions_total)" \
    "$(metric_sum "${m}" stargz_fs_cache_evicted_bytes_total)" \
    "$(metric_sum "${m}" stargz_fs_cache_writes_skipped_total)" \
    "$(metric_sum "${m}" stargz_fs_blob_fetch_errors_total)" \
    "$(metric_one "${m}" stargz_cache_index_dropped_events_total)" \
    "$(metric_one "${m}" stargz_cache_pinned_chunks)" \
    "$(metric_one "${m}" stargz_cache_index_rebuild_in_progress)" \
    "$(metric_one "${m}" stargz_fs_cache_pressure_bytes)" \
    "$(metric_one "${m}" stargz_cache_index_rebuilds_total)" \
    "$(metric_one "${m}" stargz_cache_index_lock_lost_total)" \
    "$(metric_one "${m}" stargz_cache_index_lock_retry_total)"
}

# start_sampler <outfile> <interval_s> ; stop_sampler
# setsid + full fd redirection: v4 §9 finding 5 -- `ssh host "cmd &"` hangs if the
# backgrounded process keeps a session fd open.
SAMPLER_PID=""
start_sampler() {
  local out="$1" iv="${2:-15}"
  sample_header > "${out}"
  ( while :; do sample_row >> "${out}" 2>/dev/null; sleep "${iv}"; done ) </dev/null >/dev/null 2>&1 &
  SAMPLER_PID=$!
  log "sampler ${SAMPLER_PID} -> ${out} every ${iv}s"
}
stop_sampler() { [ -n "${SAMPLER_PID}" ] && kill "${SAMPLER_PID}" 2>/dev/null; SAMPLER_PID=""; }

# ---------------------------------------------------------------- deleted-but-open
# V3's half of the C1 §6.2 question: how much of df-minus-du is inodes that have
# been unlinked but are still held open. Run from the HOST, covering every
# process, because the holder is the FUSE manager inside the kind node.
lsof_deleted() {
  sudo lsof +L1 2>/dev/null | awk 'NR>1 && $NF ~ /'"$(echo "${STARGZ_CACHE_MOUNT}" | sed 's,/,\\/,g')"'/ {print}' || true
}
lsof_deleted_bytes() {
  sudo lsof +L1 2>/dev/null \
    | awk -v m="${STARGZ_CACHE_MOUNT}" 'NR>1 && index($NF, m)==1 {s+=$(NF-2)} END{printf "%.0f", s+0}' || echo 0
}

# ---------------------------------------------------------------- V6 index dump
# Read-only dump of the accounting index, for the DERIVED access trace. The
# dumper is a standalone tool, NOT part of the system under test: it opens a COPY
# of the bolt file so it can never take the writer's lock or perturb timing.
index_dump() { # index_dump <outfile>
  # The index lives under <root>/stargz, which is where the filesystem root is.
  local db="${STARGZ_CACHE_MOUNT}/stargz/cache-accounting.db"
  sudo test -f "${db}" || { echo "no index at ${db}" >&2; return 1; }
  sudo cp "${db}" /tmp/idx-snap.db 2>/dev/null || return 1
  sudo chown ubuntu:ubuntu /tmp/idx-snap.db
  /data/idxdump /tmp/idx-snap.db > "$1" 2>/dev/null || return 1
}

# ---------------------------------------------------------------- V5 latency probe
# Reads a fixed hot set repeatedly and prints ONE LINE PER READ, so the report
# can compute percentiles rather than an average. Timing is per file, because
# that is the granularity a serving pod actually experiences.
LAT_PROBE_PY='
import os, sys, time, errno
d="/mnt/models"; lo=int(sys.argv[1]); hi=int(sys.argv[2]); rounds=int(sys.argv[3])
names=["ballast-%d.bin"%i for i in range(lo+1,hi+1)]
for r in range(rounds):
    for n in names:
        p=os.path.join(d,n); t0=time.time(); nb=0; err=""
        try:
            with open(p,"rb") as f:
                while True:
                    c=f.read(32<<20)
                    if not c: break
                    nb+=len(c)
        except OSError as e:
            err="errno=%d %s"%(e.errno, errno.errorcode.get(e.errno,"?"))
        print("ROUND=%d FILE=%s bytes=%d ms=%.3f %s"%(r,n,nb,(time.time()-t0)*1000.0,err), flush=True)
'
lat_probe() { kubectl -n "${TEST_NS}" exec "$1" -- python3 -c "${LAT_PROBE_PY}" "$2" "$3" "$4" 2>&1; }

# True once the index has finished its startup load or rebuild scan. Occupancy
# is incomplete while it is rebuilding, so V3 waits on this between restarts
# rather than catching a mid-rebuild zero and reporting it as a measurement.
index_not_rebuilding() {
  [ "$(metric_one "$(sg_metrics)" stargz_cache_index_rebuild_in_progress)" = "0" ]
}

# ============================================================ spike-v6 additions
# v6 splits what v5's sg_metrics fused together. v5 scraped :9110 and :9111 and
# concatenated them, because with fuse_manager on, the accounting series existed
# only on the manager's own endpoint. The F2 fix claims the snapshotter's
# documented endpoint now federates them, and a concatenating scraper cannot tell
# a working federation from a second endpoint being read directly. So E1 needs
# the two separately, and every v6 measurement reads the DOCUMENTED one.

# The single documented endpoint. This is what an operator scrapes, what the
# alert rules in docs/overview.md target, and what cmd/stargz-cache-events reads.
sg_metrics_snapshotter() {
  curl -s --max-time 10 "http://$(node_ip):${STARGZ_METRICS_ADDRESS##*:}/metrics" 2>/dev/null || true
}
# The manager's optional endpoint. Only configured on the negative-control arm.
sg_metrics_manager() {
  local port="${1:-9111}"
  curl -s --max-time 10 "http://$(node_ip):${port}/metrics" 2>/dev/null || true
}
# v6 default: every experiment reads the documented endpoint and nothing else.
# If that is empty, the run has a finding, not a scraping problem.
sg_metrics() { sg_metrics_snapshotter; }

# ---------------------------------------------------------------- index holders
# Which processes hold the accounting index open. E1.5's whole content: a leaked
# filesystem shows up here as a second holder, and that is what made the newcomer
# lose the flock, rebuild, and report a stale policy label (RUN-REPORT-v5 F12,
# corrected in C2-REPORT §10.1).
INDEX_DB_IN_NODE() { echo "${STARGZ_ROOT_IN_NODE}/stargz/cache-accounting.db"; }

# Every (pid, fd) pointing at the index, plus any fd still pointing at a file
# that has been renamed .corrupt. Both matter, and they say different things.
#
# Counting PIDs alone is too weak for the negative control: without the F12 fix
# the LEAK is inside one process -- the manager builds a second filesystem, the
# second index loses the flock, renames the healthy db .corrupt and opens a new
# one -- so the pid count stays 1 while the fd count goes to 2. The fd is the
# observable that distinguishes "one index" from "two".
db_open_fds() {
  local n db; n="$(NODE_CTR)"; db="$(INDEX_DB_IN_NODE)"
  docker exec "${n}" sh -c '
    db="'"${db}"'"
    for p in /proc/[0-9]*; do
      pid=${p#/proc/}
      [ -d "$p/fd" ] || continue
      for fd in "$p"/fd/*; do
        [ -e "$fd" ] || continue
        tgt=$(readlink "$fd" 2>/dev/null) || continue
        case "$tgt" in
          "$db"|"$db".corrupt|"$db"*.corrupt)
            echo "$pid ${fd##*/} $tgt $(tr "\0" " " < "$p/cmdline" 2>/dev/null | cut -c1-46)";;
        esac
      done
    done' 2>/dev/null | sort
}
db_holders() { db_open_fds | awk '{print $1, $4, $5, $6}' | sort -u; }
# Distinct processes, and distinct open fds, pointing at the index. `grep -c`
# already prints 0 and exits 1 when there is no match, so `|| true` -- never
# `|| echo 0`, which appends a SECOND zero.
db_holder_count()  { db_holders  | grep -c . || true; }
db_open_fd_count() { db_open_fds | grep -c . || true; }
db_corrupt_files() {
  docker exec "$(NODE_CTR)" sh -c "ls -1 ${STARGZ_ROOT_IN_NODE}/stargz/*.corrupt 2>/dev/null" 2>/dev/null || true
}

# ---------------------------------------------------------------- exposition sanity
# E1.8/E1.9. A federated endpoint that emits two copies of a metric family is a
# document Prometheus rejects, and the failure is silent at the curl level: you
# get 200 and a body. This is the check that turns that into an assertion.
# Prints "OK" or one "DUP <family>" line per duplicated family.
exposition_check() { # exposition_check <metrics-text>
  awk '
    /^# HELP / { if (seen[$3]++) print "DUP-HELP " $3; next }
    /^# TYPE / { if (typ[$3]++)  print "DUP-TYPE " $3; next }
    /^#/ { next }
    NF == 0 { next }
    { split($1, a, "{"); fam[a[1]]++ }
    END { }
  ' <<< "$1"
  # a bare sample name appearing under two different families is what a naive
  # concatenation produces; check the two runtime collectors explicitly, since
  # those are the ones BOTH processes export.
  local g p
  g=$(grep -c '^go_goroutines ' <<< "$1" || true)
  p=$(grep -c '^process_open_fds ' <<< "$1" || true)
  echo "go_goroutines_lines=${g:-0} process_open_fds_lines=${p:-0}"
}

# ---------------------------------------------------------------- kubelet
# v5 F8 was applied by hand and never scripted, which is exactly how it came
# back. Read the thresholds from the running kubelet, not from the file we wrote.
kubelet_eviction_thresholds() {
  local n; n=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
  kubectl get --raw "/api/v1/nodes/${n}/proxy/configz" 2>/dev/null \
    | python3 -c 'import json,sys; k=json.load(sys.stdin)["kubeletconfig"]; print(json.dumps({"evictionHard":k.get("evictionHard"),"imageGCHighThresholdPercent":k.get("imageGCHighThresholdPercent")}))' 2>/dev/null \
    || echo '{"evictionHard":"UNREADABLE"}'
}
# True when nodefs/imagefs eviction cannot fire before the cache partition fills.
kubelet_eviction_disabled() {
  local t; t=$(kubelet_eviction_thresholds)
  echo "${t}" | grep -q '"nodefs.available": *"0%"' && echo "${t}" | grep -q '"imagefs.available": *"0%"'
}

# ---------------------------------------------------------------- policy label
# Every policy label currently present on the eviction counters, deduplicated.
# F3 made this the EFFECTIVE policy, so "2q-unpromoted" is a legitimate value and
# is not the same statement as "lru".
policy_labels() { # policy_labels <metrics-text>
  sed -n 's/^stargz_fs_cache_evictions_total{[^}]*policy="\([^"]*\)".*/\1/p' <<< "$1" | sort -u | paste -sd, -
}
