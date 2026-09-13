#!/usr/bin/env bash
# v9 node-host bootstrap phase 2: cluster -> binaries -> idxdump.
#
# Phase 1 (00-node-host-setup.sh) is run separately and BEFORE this, because it
# adds ubuntu to the docker group and a process cannot see a group it was not
# started with. v6 got past this only by accident.
#
# v9 drops v8's second fork build: v8's E1 settled the 9829d7cf-vs-6e87e34e
# question (0.2% same-session, suspicion withdrawn) and no v9 campaign has a
# negative-control arm, so building 9829d7cf here would cost ~5 min per node to
# produce binaries nothing runs.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./hosts.env; set +a
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
docker info >/dev/null 2>&1 || { log "FATAL: cannot reach the docker API (run under 'sg docker')"; exit 1; }

# v5 F8: production-like evictionHard kills the pod at 90% pre-fill before any
# read happens. Scripted here and asserted again inside every pre-filled trial.
log "=== 01-cluster-up (EVICTION_MODE=kind-default) ==="; EVICTION_MODE=kind-default bash ./01-cluster-up.sh
log "=== 04-fetch-binaries (vanilla v0.18.2) ==="; bash ./04-fetch-binaries.sh
log "=== 04b: SUT @ 6e87e34e ==="; OUR_SHA=6e87e34e OURBIN=/data/stargz-bin-ours bash ./04b-build-our-fork.sh
log "=== idxdump ==="; export PATH=$PATH:/usr/local/go/bin; (cd idxdump && go build -o /data/idxdump .)
log "=== 05-setup-stargz (arm=ours) ==="; BINSRC=/data/stargz-bin-ours ARM_LABEL=ours bash ./05-setup-stargz.sh
log "NODE BOOTSTRAP COMPLETE"
