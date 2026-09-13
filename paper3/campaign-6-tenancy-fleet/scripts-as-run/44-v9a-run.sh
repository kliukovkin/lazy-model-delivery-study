#!/usr/bin/env bash
# V9-A driver, workstation side. One repetition at a time, with the registry's
# access-log window opened before it and closed after it.
#   44-v9a-run.sh [rep...]      default: 1 2
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPS=("$@"); [ "${#REPS[@]}" -gt 0 ] || REPS=(1 2)
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

log "recording A's and B's blob digests (and asserting they are disjoint)"
"${HERE}/rsh.sh" reg 'cd ~/bench && bash 41-v9a-regcap.sh digests'

for r in "${REPS[@]}"; do
  log "=== V9-A rep ${r} ==="
  "${HERE}/rsh.sh" reg "cd ~/bench && bash 41-v9a-regcap.sh begin ${r}"
  "${HERE}/rsh.sh" node1 "cd ~/bench && REP_LIST=${r} sg docker -c 'REP_LIST=${r} bash ~/bench/40-v9a-interference.sh' > ~/bench/v9a-rep${r}.log 2>&1" || log "  rep ${r} returned non-zero"
  "${HERE}/rsh.sh" reg "cd ~/bench && bash 41-v9a-regcap.sh end ${r}"
  "${HERE}/92-fetch.sh" "v9a/rep${r}" node1 || log "  WARN: node fetch failed for rep ${r}"
  mkdir -p "${HERE}/../results/v9a/rep${r}"
  for f in refetch.txt window.txt registry-access.log; do
    "${HERE}/rsh.sh" reg "cat /data/v9a/rep${r}/${f} 2>/dev/null" > "${HERE}/../results/v9a/rep${r}/${f}" 2>/dev/null || true
  done
  "${HERE}/rsh.sh" reg "cat /data/v9a/blob-disjointness.txt 2>/dev/null" > "${HERE}/../results/v9a/blob-disjointness.txt" 2>/dev/null || true
  log "=== rep ${r} collected ==="
done
python3 "${HERE}/43-v9a-rollup.py" "${HERE}/../results/v9a" | tee "${HERE}/../results/v9a/V9A-RESULT.txt"
