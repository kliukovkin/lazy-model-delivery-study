#!/usr/bin/env bash
# v7 node-host bootstrap: base -> cluster -> all three binary sets -> idxdump.
#
# Two phases, and the split is load-bearing. 00-node-host-setup.sh adds ubuntu to
# the docker group, and a process cannot see a group it was not started with — so
# everything after it must run in a process that began AFTER the grant. v6 got
# past this only by accident: its bootstrap crashed on an unrelated problem and
# the retry came from a fresh session that happened to have the group.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./hosts.env; set +a
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

if [ "${1:-base}" = "base" ]; then
  log "=== phase 1: 00-node-host-setup ==="
  sudo -E bash ./00-node-host-setup.sh
  if docker info >/dev/null 2>&1; then
    log "docker already reachable; continuing in this process"
    exec bash "$0" rest
  fi
  log "re-entering under the docker group (membership was just granted)"
  exec sg docker -c "bash '$(pwd)/06-node-bootstrap.sh' rest"
fi

log "=== phase 2 ==="
docker info >/dev/null 2>&1 || { log "FATAL: still cannot reach the docker API"; exit 1; }
# v5 F8: production-like evictionHard kills the pod at 90% pre-fill before any
# read happens. Scripted here and asserted against the running kubelet in E4.
log "=== 01-cluster-up (EVICTION_MODE=kind-default) ==="; EVICTION_MODE=kind-default bash ./01-cluster-up.sh
log "=== 04-fetch-binaries (vanilla v0.18.2) ==="; bash ./04-fetch-binaries.sh
log "=== 04b: SUT @ 6e87e34e ==="; OUR_SHA=6e87e34e OURBIN=/data/stargz-bin-ours bash ./04b-build-our-fork.sh
log "=== 04b: previous SUT @ 9829d7cf (negative control) ==="; OUR_SHA=9829d7cf OURBIN=/data/stargz-bin-prev bash ./04b-build-our-fork.sh
log "=== idxdump ==="; export PATH=$PATH:/usr/local/go/bin; (cd idxdump && go build -o /data/idxdump .)
log "=== inventory ==="
for d in /data/stargz-bin /data/stargz-bin-ours /data/stargz-bin-prev; do
  printf -- "--- %s: " "$d"; grep -E '^sha=' "$d/PROVENANCE.txt" 2>/dev/null || echo "(release tarball)"
done
log "NODE BOOTSTRAP COMPLETE"
