#!/usr/bin/env bash
# v8 pre-warm.
#
# The restored volume loads lazily from S3 and local readers cannot defeat that
# latency: `xargs -P 48 cat` gave 48 MB/s and fio at iodepth=32 gave 15 MB/s,
# because estargz-140g is only 11 blobs so there is little to parallelise over.
# (The 177 MB/s measured earlier was reading device offset 0, which the mount had
# already touched.)
#
# So warm the way the experiments read: pull the whole image through the node.
# The snapshotter issues many concurrent ranged fetches, which is exactly the
# access pattern that hides per-block S3 latency, and it warms precisely the
# blocks the experiments need.
#
# This run is DISCARDED. Its products are warm blocks and a recorded cost.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./hosts.env; set +a
. ./env.sh; . ./lib.sh
OUT=../results/e0; mkdir -p "${OUT}"

log "installing the SUT arm for the warm sweep"
CACHE_POLICY=lru BINSRC=/data/stargz-bin-ours ARM_LABEL=ours FM_METRICS_ADDRESS="" \
  CACHE_ACCOUNTING=true bash ./05-setup-stargz.sh > "${OUT}/warm-setup.log" 2>&1
hard_reset >/dev/null 2>&1 || true
teardown_pod warm-sweep
deploy_pod warm-sweep "${MODEL_IMG_PREFIX}:estargz-140g" normal 3
wait_for 900 "warm pod ready" pod_ready warm-sweep || log "WARN: warm pod not Ready"

log "pulling all 280 files through the node; this is the pre-warm"
t0=$(now)
full_read warm-sweep 280 > "${OUT}/warm-sweep-read.txt" 2>&1 || true
el=$(elapsed "${t0}")
grep -E '^(READ|ERRNOS)' "${OUT}/warm-sweep-read.txt" || true
teardown_pod warm-sweep

{ echo "prewarm_method=full image pull through the node (discarded run)"
  echo "prewarm_seconds=${el}"
  echo "prewarm_note=local readers on the registry host could not exceed 48 MB/s on the lazily-restored volume; the snapshotter's concurrent ranged fetches warm it at a usable rate"
  echo "prewarm_finished_utc=$(date -u +%FT%TZ)"; } | tee "${OUT}/prewarm.txt"
log "pre-warm sweep done in ${el}s"
