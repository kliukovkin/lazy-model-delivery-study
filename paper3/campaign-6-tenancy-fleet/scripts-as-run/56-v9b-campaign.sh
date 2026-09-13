#!/usr/bin/env bash
# V9-B full campaign, workstation side.
#
# Order matters and is pre-registered (PRE-REGISTRATION-v9 s4):
#   1. k=1 baselines, IN THIS SESSION, one per node. The pre-registration
#      requires one; running all three is an ADDITION made after the lock and
#      disclosed as such, because clause (iii) compares each node against its
#      OWN k=1 time and rule 0.2 forbids comparing node A with node B. Without a
#      per-node baseline, clause (iii) is simply not evaluable for nodes 2 and 3.
#   2. Two k=3 rounds, re-prefilled and hard_reset between them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

for n in node1 node2 node3; do
  log "=== k=1 baseline on ${n} ==="
  "${HERE}/53-v9b-run.sh" "k1-${n}" "${n}"
done

for r in 1 2; do
  log "=== k=3 round ${r} ==="
  "${HERE}/53-v9b-run.sh" "k3-round${r}" node1 node2 node3
done

log "=== V9-B analysis ==="
python3 "${HERE}/55-v9b-analyse.py" "${HERE}/../results/v9b" | tee "${HERE}/../results/v9b/V9B-RESULT.txt"
