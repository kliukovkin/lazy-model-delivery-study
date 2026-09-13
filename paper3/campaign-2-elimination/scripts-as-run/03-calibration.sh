#!/usr/bin/env bash
# spike-v4: start/end calibration, for drift control across the run (v3.1 s2).
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
WHEN="${1:?usage: 03-calibration.sh <start|end>}"
O="${RESULTS_DIR}/calibration"; mkdir -p "$O"
fio --name=seqwrite --directory=/data --size=2G --bs=1M --rw=write --direct=1 --numjobs=1 \
    --runtime=30 --time_based --group_reporting > "${O}/node-fio-write-${WHEN}.txt" 2>&1 || true
fio --name=seqread --directory=/data --size=2G --bs=1M --rw=read --direct=1 --numjobs=1 \
    --runtime=30 --time_based --group_reporting > "${O}/node-fio-read-${WHEN}.txt" 2>&1 || true
fio --name=cachewrite --directory="${STARGZ_CACHE_MOUNT}" --size=2G --bs=1M --rw=write --direct=1 \
    --numjobs=1 --runtime=30 --time_based --group_reporting > "${O}/cachepart-fio-write-${WHEN}.txt" 2>&1 || true
rm -f "${STARGZ_CACHE_MOUNT}"/cachewrite* /data/seqwrite* /data/seqread* 2>/dev/null || true
iperf3 -c "${REG_PRIV}" -t 10       > "${O}/iperf3-single-${WHEN}.txt" 2>&1 || true
iperf3 -c "${REG_PRIV}" -t 10 -P 8  > "${O}/iperf3-p8-${WHEN}.txt" 2>&1 || true
df -h /data "${STARGZ_CACHE_MOUNT}" > "${O}/df-${WHEN}.txt" 2>&1
echo "calibration ${WHEN} -> ${O}"
