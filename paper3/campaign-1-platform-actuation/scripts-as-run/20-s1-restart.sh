#!/usr/bin/env bash
# spike-v4 S1 [P0]: does the opt-in FUSE manager cure the permanent-ESTALE that
# v3.1/C2 recovery-5 recorded (daemon restarted under a live pod -> "Stale file
# handle", exit 1, while kubectl still reported 1/1 Running)?
#
# Three source-level facts, established before the rig was built, define the
# trial matrix (see source-audit/):
#   (a) cmd/containerd-stargz-grpc/main.go:278 -- `if cleanup || !fuseManagerConfig.Enable
#       { rs.Close() }` where cleanup == (signal was SIGINT). So with fuse_manager on,
#       SIGTERM deliberately does NOT tear the mounts down.
#   (b) fusemanager/fusemanager.go:207-219 -- the FUSE manager itself treats SIGINT and
#       SIGTERM IDENTICALLY: either one runs fm.Close(ctx), unmounting everything.
#   (c) fusemanager/fusemanager.go:117-121 -- the manager is detached with
#       SysProcAttr{Setpgid:true} ONLY. That escapes the process group, NOT the cgroup.
#       Upstream's shipped stargz-snapshotter.service sets no KillMode, so systemd's
#       default KillMode=control-group applies and `systemctl restart` SIGTERMs every
#       process in the unit cgroup -- including the detached FUSE manager, which by (b)
#       then unmounts everything.
# (c)+(b) predict that the shipped unit defeats (a). That prediction is the reason the
# matrix has a KillMode axis; it is measured, not assumed, and not patched around
# (a systemd drop-in is configuration, not a change to the snapshotter).
#
# Trials (each gets its own evidence bundle; nothing is deleted, failures are flagged):
#   T0  fuse_manager=false, unit as shipped        -- v3.1 recovery-5 baseline, same rig
#   T1  fuse_manager=true,  unit as shipped, rep1  -- systemctl restart
#   T2  fuse_manager=true,  unit as shipped, rep2
#   T3  fuse_manager=true,  KillMode=process, rep1 -- systemctl restart
#   T4  fuse_manager=true,  KillMode=process, rep2
#   T5  fuse_manager=true,  KillMode=process       -- kill -9 containerd-stargz-grpc only
#                                                     (docs' "unexpected restart" path)
#   T6  fuse_manager=true,  KillMode=process       -- kill -9 BOTH (node-crash analogue)
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need kubectl; need envsubst; need docker

NODE="$(NODE_CTR)"
OUT="${RESULTS_DIR}/s1"; mkdir -p "${OUT}"
set_log_level "${STARGZ_LOG_LEVEL:-debug}"   # short reads; debug is affordable here
IMG="${MODEL_IMG_PREFIX}:estargz-140g"
POD="s1-probe"
WARM_FILES="${WARM_FILES:-8}"         # 8x512MB=4GB read; attempt 1 measured ~3.2x
                                      # cache amplification, so ~13GB of the 92GB partition
FRESH_FILES="${FRESH_FILES:-4}"       # never touched pre-restart -> forces a real refetch
CSV="${OUT}/s1-summary.csv"
[ -f "${CSV}" ] || echo "trial,fuse_manager,killmode,action,pod_ready_pre,pod_ready_post,restarts_post,warm_ok_pre,warm_err_pre,warm_ok_post,warm_err_post,warm_errnos_post,fresh_ok_post,fresh_err_post,fresh_errnos_post,mounts_pre,mounts_post,fm_pid_pre,fm_pid_post,httpcache_pre,fscache_pre,httpcache_post,fscache_post,httpcache_reread,fscache_reread,verdict,notes" > "${CSV}"

partial_read() { mount_probe "$1" "$2" "$3"; }
parse_att()    { grep -m1 '^READ ' "$1" | sed -E 's/.* attempted=([0-9]+) .*/\1/'; }
parse_ok()     { grep -m1 '^READ ' "$1" | sed -E 's/.* ok=([0-9]+) .*/\1/'; }
parse_listdir(){ grep -m1 '^LISTDIR ' "$1" | sed 's/^LISTDIR //'; }
parse_err()    { grep -m1 '^READ ' "$1" | sed -E 's/.* err=([0-9]+) .*/\1/'; }
parse_errnos() { grep -m1 '^ERRNOS ' "$1" | sed 's/^ERRNOS //'; }

set_fuse_manager() { # <true|false>
  docker exec "${NODE}" sh -c "sed -i 's/^  enable = .*/  enable = $1/' /etc/containerd-stargz-grpc/config.toml"
  docker exec "${NODE}" grep -A1 'fuse_manager' /etc/containerd-stargz-grpc/config.toml >&2
}
set_killmode() { # <default|process>
  if [ "$1" = "process" ]; then
    docker exec "${NODE}" mkdir -p /etc/systemd/system/stargz-snapshotter.service.d
    docker exec -i "${NODE}" sh -c 'cat > /etc/systemd/system/stargz-snapshotter.service.d/killmode.conf' <<'EOF'
# systemd's default KillMode=control-group SIGTERMs every process in the unit
# cgroup on stop/restart, including the Setpgid-detached stargz-fuse-manager.
# KillMode=process restricts the kill to the main process only, which is what
# the FUSE manager design assumes. This is a systemd configuration change; the
# snapshotter itself is untouched.
[Service]
KillMode=process
EOF
  else
    docker exec "${NODE}" rm -rf /etc/systemd/system/stargz-snapshotter.service.d
  fi
  docker exec "${NODE}" systemctl daemon-reload
}

# Full clean slate. Only the CONTENT caches are wiped, never <root>/snapshotter --
# v3.1 RUN-REPORT s10: snapshotter=stargz is node-wide, so wiping its backing store
# out from under a live containerd bricked the whole cluster and cost a rebuild.
clean_slate() {
  docker exec "${NODE}" systemctl stop stargz-snapshotter || true
  sleep 2
  # SIGTERM first: the manager unmounts gracefully (fusemanager.go:207-219). A SIGKILL
  # leaves the mounts behind, and those orphaned mounts hold the deleted cache files
  # open so `rm` frees no blocks -- exactly what filled the partition in attempt 1.
  sg_kill TERM fm; sleep 4
  sg_kill 9 fm; sg_kill 9 grpc; sleep 1
  docker exec "${NODE}" sh -c 'rm -f /run/containerd-stargz-grpc/fuse-manager.sock' || true
  sg_umount_stale
  # NOTE: the glob MUST be expanded by root. /cache-part/stargz is drwx------ root:root,
  # so a non-root shell cannot list it: `sudo rm -rf .../httpcache/*` leaves the "*"
  # literal and silently deletes nothing. v3.1 15-p05:45 had this right with sudo sh -c;
  # v4 attempt 1 dropped the wrapper and never cleared the cache in ANY trial.
  sudo sh -c "rm -rf ${STARGZ_CACHE_MOUNT}/stargz/httpcache/* ${STARGZ_CACHE_MOUNT}/stargz/fscache/*" 2>/dev/null || true
  sync
  local pct; pct=$(cache_pct)
  if [ "${pct:-100}" -gt 10 ]; then
    log "clean_slate: cache STILL ${pct}% used after wipe -- retrying with a second unmount pass"
    sg_umount_stale
    # NOTE: the glob MUST be expanded by root. /cache-part/stargz is drwx------ root:root,
  # so a non-root shell cannot list it: `sudo rm -rf .../httpcache/*` leaves the "*"
  # literal and silently deletes nothing. v3.1 15-p05:45 had this right with sudo sh -c;
  # v4 attempt 1 dropped the wrapper and never cleared the cache in ANY trial.
  sudo sh -c "rm -rf ${STARGZ_CACHE_MOUNT}/stargz/httpcache/* ${STARGZ_CACHE_MOUNT}/stargz/fscache/*" 2>/dev/null || true
    sync; pct=$(cache_pct)
    [ "${pct:-100}" -le 10 ] || { log "clean_slate FAILED: cache at ${pct}%"; return 1; }
  fi
  log "clean_slate: cache at ${pct}% used, $(cache_used_bytes) bytes"
  docker exec "${NODE}" systemctl reset-failed stargz-snapshotter 2>/dev/null || true
  docker exec "${NODE}" systemctl start stargz-snapshotter
  sleep 5
  docker exec "${NODE}" systemctl is-active stargz-snapshotter >/dev/null \
    || { docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager | tail -30 >&2; return 1; }
  # cluster sanity: a wipe must never have taken system pods down with it
  local unhealthy
  unhealthy=$(kubectl -n kube-system get pods --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${unhealthy}" = "0" ] || log "WARN: ${unhealthy} kube-system pods not Running after clean_slate"
  return 0
}

run_trial() { # run_trial <id> <fuse_manager> <killmode> <action>
  local id="$1" fm="$2" km="$3" action="$4"
  local d="${OUT}/${id}"; mkdir -p "${d}"
  log "================ S1 ${id}: fm=${fm} killmode=${km} action=${action} ================"

  teardown_pod "${POD}"
  set_fuse_manager "${fm}"
  set_killmode "${km}"
  if ! clean_slate; then
    echo "CLEAN_SLATE_FAILED" > "${d}/FLAGGED-INVALID.txt"
    docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${d}/journal.txt" 2>&1 || true
    echo "${id},${fm},${km},${action},,,,,,,,,,,,,,,,,,,,FLAGGED_CLEAN_SLATE_FAILED," >> "${CSV}"
    return 0
  fi

  { echo "trial=${id} fuse_manager=${fm} killmode=${km} action=${action}"
    echo "date=$(date -Is)"; echo "image=${IMG}"
    echo "--- stargz config.toml ---"; docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml
    echo "--- systemd unit ---";        docker exec "${NODE}" cat /etc/systemd/system/stargz-snapshotter.service
    echo "--- systemd drop-ins ---";    docker exec "${NODE}" sh -c 'cat /etc/systemd/system/stargz-snapshotter.service.d/*.conf 2>/dev/null || echo "(none -- unit as shipped, KillMode=control-group default)"'
    echo "--- effective KillMode ---";  docker exec "${NODE}" systemctl show stargz-snapshotter -p KillMode
    echo "--- versions ---";            docker exec "${NODE}" sh -c 'containerd-stargz-grpc --version; containerd --version'
  } > "${d}/meta.txt" 2>&1

  log "deploying ${POD} on ${IMG}"
  deploy_pod "${POD}" "${IMG}" normal 3
  if ! wait_for 600 "pod Ready" pod_ready "${POD}"; then
    kubectl -n "${TEST_NS}" describe pod "${POD}" > "${d}/pod-describe-NEVER-READY.txt" 2>&1
    docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${d}/journal.txt" 2>&1
    echo "POD_NEVER_READY" > "${d}/FLAGGED-INVALID.txt"
    echo "${id},${fm},${km},${action},false,,,,,,,,,,,,,,,,,,,FLAGGED_POD_NEVER_READY," >> "${CSV}"
    teardown_pod "${POD}"; return 0
  fi

  log "warming ${WARM_FILES} files through the FUSE mount"
  partial_read "${POD}" 0 "${WARM_FILES}" > "${d}/pre-warm-read.txt" 2>&1
  cat "${d}/pre-warm-read.txt" >&2

  # ---------------- pre-restart snapshot
  local ready_pre mounts_pre fmpid_pre du_pre
  ready_pre=$(pod_ready "${POD}" && echo true || echo false)
  mounts_pre=$(sg_mounts); fmpid_pre=$(sg_fm_pid); du_pre=$(cache_du)
  { echo "pod_ready=${ready_pre} phase=$(pod_phase "${POD}") restarts=$(pod_restarts "${POD}")"
    echo "grpc_pid=$(sg_grpc_pid) fusemanager_pid=${fmpid_pre}"
    echo "stargz_mounts_in_mountinfo=${mounts_pre}"
    echo "cache_du(httpcache fscache stargz snapshotter total)=${du_pre}"
    echo "df: $(cache_df)"
    echo "--- ps ---"; sg_pids
    echo "--- sockets ---"; docker exec "${NODE}" ls -la /run/containerd-stargz-grpc/ 2>&1
  } > "${d}/pre-restart-state.txt" 2>&1
  mount_probe "${POD}" 0 "${WARM_FILES}" > "${d}/pre-restart-errno-probe.txt" 2>&1

  # ---------------- the action under test
  local t0; t0=$(now)
  case "${action}" in
    systemctl)
      log "ACTION: systemctl restart stargz-snapshotter"
      docker exec "${NODE}" systemctl restart stargz-snapshotter 2>&1 | tee "${d}/action.txt" || true
      ;;
    kill9-grpc)
      log "ACTION: kill -9 containerd-stargz-grpc only (fuse manager left alive)"
      { echo "kill -9 on containerd-stargz-grpc pid=$(sg_grpc_pid); Restart=always lets systemd bring it back"
        sg_kill 9 grpc; } > "${d}/action.txt" 2>&1 || true
      ;;
    kill9-both)
      log "ACTION: kill -9 BOTH containerd-stargz-grpc and stargz-fuse-manager"
      { echo "kill -9 grpc pid=$(sg_grpc_pid) fusemanager pid=$(sg_fm_pid)"
        sg_kill 9 both
        echo "fuse-manager.sock left in place deliberately (SIGKILL cannot unlink it) --"
        echo "StartFuseManager (fusemanager/fusemanager.go:225-231) returns newlyStarted=false"
        echo "when that socket exists, which sets snbase.NoRestore in main.go:194-199."; } > "${d}/action.txt" 2>&1 || true
      ;;
  esac
  # let systemd's Restart=always (RestartSec=1) do its thing, then ensure it is up
  sleep 12
  docker exec "${NODE}" systemctl is-active stargz-snapshotter >/dev/null 2>&1 \
    || { log "unit not active after action; starting it explicitly"; docker exec "${NODE}" systemctl start stargz-snapshotter || true; sleep 8; }
  local t_restart; t_restart=$(elapsed "${t0}")

  # ---------------- post-restart snapshot
  local ready_post restarts_post mounts_post fmpid_post du_post
  ready_post=$(pod_ready "${POD}" && echo true || echo false)
  restarts_post=$(pod_restarts "${POD}"); mounts_post=$(sg_mounts); fmpid_post=$(sg_fm_pid); du_post=$(cache_du)
  { echo "action=${action} action_to_active_s=${t_restart}"
    echo "unit_active=$(sg_unit_active)"
    echo "pod_ready=${ready_post} phase=$(pod_phase "${POD}") restarts=${restarts_post}"
    echo "grpc_pid=$(sg_grpc_pid) fusemanager_pid=${fmpid_post} (pre: ${fmpid_pre})"
    echo "fusemanager_pid_changed=$([ "${fmpid_pre}" = "${fmpid_post}" ] && echo no || echo YES)"
    echo "stargz_mounts_in_mountinfo=${mounts_post} (pre: ${mounts_pre})"
    echo "cache_du(httpcache fscache stargz snapshotter total)=${du_post}"
    echo "df: $(cache_df)"
    echo "--- ps ---"; sg_pids
    echo "--- sockets ---"; docker exec "${NODE}" ls -la /run/containerd-stargz-grpc/ 2>&1
    echo "--- pod conditions (does k8s notice anything?) ---"
    kubectl -n "${TEST_NS}" get pod "${POD}" -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -m json.tool 2>/dev/null || true
    echo "--- kubelet node view ---"; kubelet_view
  } > "${d}/post-restart-state.txt" 2>&1

  log "post-restart: re-reading the SAME ${WARM_FILES} warm files"
  partial_read "${POD}" 0 "${WARM_FILES}" > "${d}/post-warm-read.txt" 2>&1
  cat "${d}/post-warm-read.txt" >&2
  log "post-restart: reading ${FRESH_FILES} files NEVER touched before (forces a real refetch)"
  partial_read "${POD}" "${WARM_FILES}" "$(( WARM_FILES + FRESH_FILES ))" > "${d}/post-fresh-read.txt" 2>&1
  cat "${d}/post-fresh-read.txt" >&2
  mount_probe "${POD}" 0 "${WARM_FILES}" > "${d}/post-restart-errno-probe.txt" 2>&1

  # ---------------- cache-duplication measurement (docs/overview.md:154-162)
  local du_reread
  du_reread=$(cache_du)
  { echo "du -sb, bytes: httpcache fscache stargz snapshotter total"
    echo "pre-restart        : ${du_pre}"
    echo "post-restart       : ${du_post}"
    echo "post-full-re-read  : ${du_reread}"
    echo
    echo "NOTE: 'full re-read' here means re-reading the SAME ${WARM_FILES}-file warm working"
    echo "set, not all 280 files of the 140GB image -- a genuine 140GB read would itself"
    echo "exhaust the 92GB partition and confound S1 with S2's ENOSPC failure."
  } > "${d}/cache-duplication.txt"
  cat "${d}/cache-duplication.txt" >&2

  # ---------------- logs + events
  docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${d}/journal-stargz-snapshotter.txt" 2>&1 || true
  docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${d}/fuse-manager.log" 2>&1 || true
  kubectl -n "${TEST_NS}" get events --field-selector "involvedObject.name=${POD}" -o wide > "${d}/pod-events.txt" 2>&1 || true
  kubectl -n "${TEST_NS}" describe pod "${POD}" > "${d}/pod-describe.txt" 2>&1 || true
  docker exec "${NODE}" sh -c "grep -c 'no space left on device' ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null || true" > "${d}/enospc-count.txt" 2>&1 || true

  local wop wep woq weq wnq fop fep fnq verdict
  local att_post ld_post
  att_post=$(parse_att "${d}/post-warm-read.txt"); ld_post=$(parse_listdir "${d}/post-warm-read.txt")
  wop=$(parse_ok "${d}/pre-warm-read.txt");  wep=$(parse_err "${d}/pre-warm-read.txt")
  woq=$(parse_ok "${d}/post-warm-read.txt"); weq=$(parse_err "${d}/post-warm-read.txt"); wnq=$(parse_errnos "${d}/post-warm-read.txt")
  fop=$(parse_ok "${d}/post-fresh-read.txt"); fep=$(parse_err "${d}/post-fresh-read.txt"); fnq=$(parse_errnos "${d}/post-fresh-read.txt")
  if [ -z "${weq}" ] || [ -z "${fep}" ] || [ -z "${att_post}" ]; then
    verdict="PROBE_FAILED"
    echo "read probe produced no parseable READ line" > "${d}/FLAGGED-PROBE-FAILED.txt"
  elif [ "${woq:-0}" = "${att_post}" ] && [ "${weq}" = "0" ] && [ "${fep}" = "0" ]; then
    verdict="MOUNT_SURVIVED"
  elif [ "${weq}" != "0" ] || [ "${fep}" != "0" ]; then
    verdict="MOUNT_BROKEN"
  else
    # every open failed to even be attempted, or the directory came back empty
    verdict="MOUNT_GONE"
  fi
  echo "post_listdir=${ld_post} attempted=${att_post} ok=${woq}" >> "${d}/post-restart-state.txt"
  echo "${id},${fm},${km},${action},${ready_pre},${ready_post},${restarts_post},${wop},${wep},${woq},${weq},${wnq},${fop},${fep},${fnq},${mounts_pre},${mounts_post},${fmpid_pre},${fmpid_post},$(echo "${du_pre}"|awk '{print $1","$2}'),$(echo "${du_post}"|awk '{print $1","$2}'),$(echo "${du_reread}"|awk '{print $1","$2}'),${verdict},listdir=${ld_post}" >> "${CSV}"
  log "=== ${id} verdict: ${verdict} (post warm err=${weq} [${wnq}], fresh err=${fep} [${fnq}]) ==="

  teardown_pod "${POD}"
}

TRIALS="${TRIALS:-T0-control-nofm:false:default:systemctl
T1-shipped-unit-rep1:true:default:systemctl
T2-shipped-unit-rep2:true:default:systemctl
T3-killmode-process-rep1:true:process:systemctl
T4-killmode-process-rep2:true:process:systemctl
T5-kill9-grpc-only:true:process:kill9-grpc
T6-kill9-both:true:process:kill9-both}"

echo "${TRIALS}" | while IFS=: read -r id fm km action; do
  [ -n "${id}" ] || continue
  run_trial "${id}" "${fm}" "${km}" "${action}"
done

log "S1 done -> ${CSV}"
cat "${CSV}"
