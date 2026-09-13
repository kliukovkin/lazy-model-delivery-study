#!/usr/bin/env bash
# spike-v4: bundle every result on the node-host into one tarball for retrieval
# BEFORE the instances are terminated.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
NODE="$(NODE_CTR)"
docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${RESULTS_DIR}/final-journal-stargz.txt" 2>&1 || true
docker exec "${NODE}" journalctl -u containerd --no-pager | tail -5000 > "${RESULTS_DIR}/final-journal-containerd.txt" 2>&1 || true
docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${RESULTS_DIR}/final-fuse-manager.log" 2>&1 || true
kubectl get events -A --sort-by=.lastTimestamp > "${RESULTS_DIR}/final-all-events.txt" 2>&1 || true
tar -czf /data/v4-results.tar.gz -C "$(dirname "${RESULTS_DIR}")" "$(basename "${RESULTS_DIR}")"
ls -lh /data/v4-results.tar.gz
