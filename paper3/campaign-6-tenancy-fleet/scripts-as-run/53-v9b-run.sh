#!/usr/bin/env bash
# V9-B, workstation side. Drives one round end to end.
#   53-v9b-run.sh <round-label> <node1 [node2 node3]>
#
# The workstation owns SETUP (which is slow and per-node and must not be inside
# the measured window) and the REGISTRY owns the START (which is what the task
# asks for and what makes the 5 s skew requirement meaningful).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../hosts.env"
ROUND="${1:?usage: 53-v9b-run.sh <round> <node...>}"; shift
NODES=("$@")
[ "${#NODES[@]}" -ge 1 ] || { echo "need at least one node"; exit 2; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

priv_of() { case "$1" in node1) echo "${NODE1_PRIV}";; node2) echo "${NODE2_PRIV}";; node3) echo "${NODE3_PRIV}";; esac; }

log "=== round ${ROUND}: k=${#NODES[@]} (${NODES[*]}) ==="
# setsid + an explicit exit, and ssh -n. Without these the remote job keeps the
# ssh session channel open and the CLIENT does not return -- which is exactly
# how the first attempt lost 10.5 minutes and raced the node's go-signal timeout.
# The launch ssh is BACKGROUNDED ON THE WORKSTATION and never waited on.
#
# setsid + ssh -n + an explicit remote `exit 0` were not enough: the remote job
# starts correctly (the node's sampler comes up within seconds) but the ssh
# CLIENT still does not return. That cost the first attempt 10.5 minutes and a
# whole campaign, because the readiness poll could not begin until the launch
# call returned. Whatever holds the channel open, the orchestrator must not be
# hostage to it -- so the launch is fire-and-forget and readiness is detected by
# polling the node's own marker file, which is the real signal anyway.
for n in "${NODES[@]}"; do
  ( "${HERE}/rsh.sh" -n "$n" "cd ~/bench && setsid nohup env NODE_LABEL=${n} sg docker -c 'NODE_LABEL=${n} bash ~/bench/50-v9b-node.sh ${ROUND}' > ~/bench/v9b-${ROUND}.log 2>&1 < /dev/null & disown; exit 0" >/dev/null 2>&1 || true ) &
  echo "launched-${n} (detached)"
done
sleep 5

log "waiting for every node to finish pre-fill and reach pod-Ready"
for i in $(seq 1 240); do
  ready=0
  for n in "${NODES[@]}"; do
    "${HERE}/rsh.sh" "$n" "test -f /data/v9b-ready-${ROUND}" >/dev/null 2>&1 && ready=$((ready+1))
  done
  log "  ready ${ready}/${#NODES[@]}"
  [ "${ready}" -eq "${#NODES[@]}" ] && break
  sleep 15
done
[ "${ready}" -eq "${#NODES[@]}" ] || { echo "FATAL: not every node reached ready for ${ROUND}"; exit 1; }

PRIVS=(); for n in "${NODES[@]}"; do PRIVS+=("$(priv_of "$n")"); done
log "handing the start to the registry host: ${PRIVS[*]}"
"${HERE}/rsh.sh" reg "cd ~/bench && bash 52-v9b-registry.sh go ${ROUND} ${PRIVS[*]}"

log "collecting"
for n in "${NODES[@]}"; do
  "${HERE}/rsh.sh" "$n" "tail -20 ~/bench/v9b-${ROUND}.log" || true
  "${HERE}/92-fetch.sh" "v9b/${ROUND}-${n}" "$n" || log "  WARN: fetch failed for ${ROUND}-${n}"
done
mkdir -p "${HERE}/../results/v9b/${ROUND}-registry"
for f in egress.txt fanout.csv registry-nic.csv registry-blobs.txt registry-access.log; do
  "${HERE}/rsh.sh" reg "cat /data/v9b/${ROUND}/${f} 2>/dev/null" > "${HERE}/../results/v9b/${ROUND}-registry/${f}" 2>/dev/null || true
done
log "=== round ${ROUND} complete ==="
cat "${HERE}/../results/v9b/${ROUND}-registry/egress.txt" 2>/dev/null || true
