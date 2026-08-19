#!/usr/bin/env bash
# v3 node-host: Step 3 calibration -- MUST run before any benchmark rep.
# fio on both /data (registry-host fio run remotely via ssh), iperf3
# single-stream + -P8 node->registry, one real blob curl download.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

OUT="${RESULTS_DIR}/calibration.txt"
: > "${OUT}"

log "fio on node-host /data (1min seq read+write)"
{
  echo "=== fio node-host /data ==="
  fio --name=seqwrite --directory=/data --rw=write --bs=1M --size=4G --runtime=60 --time_based --group_reporting --numjobs=1 2>&1 | grep -E "WRITE:|write:"
  fio --name=seqread --directory=/data --rw=read --bs=1M --size=4G --runtime=60 --time_based --group_reporting --numjobs=1 2>&1 | grep -E "READ:|read :"
} | tee -a "${OUT}"

# FIX (live pitfall, v3): the oci-bench.pem key lives only on the operator's
# local machine, NOT on node-host -- an ssh-from-node-host-to-registry-host
# hop here fails with "Permission denied (publickey)" and (set -euo pipefail)
# kills the whole calibration run before iperf3/curl even start. registry-host
# fio must be run from the operator's machine directly (see RUN-REPORT-v3),
# this script only records node-host's own side + the network/blob tests.
log "fio on registry-host /data -- run externally: ssh ubuntu@\${REG_PUB} 'fio ...' (see RUN-REPORT-v3 calibration section)"

log "iperf3 node-host -> registry-host (${REG_PRIV}), single-stream"
{
  echo "=== iperf3 single-stream node->registry ==="
  iperf3 -c "${REG_PRIV}" -t 10 2>&1 | tail -5
} | tee -a "${OUT}"

log "iperf3 node-host -> registry-host (${REG_PRIV}), -P 8"
{
  echo "=== iperf3 -P8 node->registry ==="
  iperf3 -c "${REG_PRIV}" -t 10 -P 8 2>&1 | tail -8
} | tee -a "${OUT}"

log "one real blob download timing from registry"
DIGEST=$(curl -s "http://${REG_PRIV}:${REG_PORT}/v2/model-ballast/manifests/A-14g" -H "Accept: application/vnd.oci.image.manifest.v1+json" | jq -r '.layers[0].digest' 2>/dev/null || true)
if [ -n "${DIGEST}" ] && [ "${DIGEST}" != "null" ]; then
  {
    echo "=== curl blob download (A-14g layer ${DIGEST}) ==="
    curl -o /dev/null -w 'size=%{size_download} bytes, time=%{time_total}s, speed=%{speed_download} B/s\n' \
      "http://${REG_PRIV}:${REG_PORT}/v2/model-ballast/blobs/${DIGEST}"
  } | tee -a "${OUT}"
else
  log "WARN: could not resolve A-14g manifest yet (image not built?) -- skipping blob timing, rerun later"
fi

log "calibration done -> ${OUT}"
cat "${OUT}"
