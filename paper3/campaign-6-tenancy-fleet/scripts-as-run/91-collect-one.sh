#!/usr/bin/env bash
# v7 rule 1: collect after EVERY experiment, not at the end of the session.
#
# v6 lost E1's observation bundles, E2's samplers and all of E3's and E4's raw
# evidence because its single end-of-session collection step never ran: the
# watchdog fired during an idle gap first, and the instance store went with the
# instance. The results survived only as command output quoted while the rig was
# alive. An experiment that has not been collected is not finished.
#
# Run ON THE NODE, at the end of each experiment.
#   91-collect-one.sh <name>     e.g. 91-collect-one.sh e1-sut
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
NAME="${1:?usage: 91-collect-one.sh <experiment-name>}"
SRC="${RESULTS_DIR}/${NAME}"
[ -d "${SRC}" ] || { echo "nothing to collect at ${SRC}"; exit 1; }

NODE="$(NODE_CTR)"
# Per-experiment context that is gone once the next experiment restarts things.
docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${SRC}/journal-stargz.txt" 2>&1 || true
docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${SRC}/fuse-manager.log" 2>&1 || true
kubectl get events -A --sort-by=.lastTimestamp > "${SRC}/k8s-events.txt" 2>&1 || true
df -B1 "${STARGZ_CACHE_MOUNT}" > "${SRC}/df-at-collect.txt" 2>&1 || true
{ echo "collected_utc=$(date -u +%FT%TZ)"; echo "experiment=${NAME}"; } > "${SRC}/COLLECTED.txt"

# The name doubles as a results subdirectory ("e3/run1-lru"), so flatten it for
# the tarball: /data/v7-e3/run1-lru.tar.gz would need a directory that is not there.
FLAT="$(echo "${NAME}" | tr '/' '-')"
TAR="/data/v9-${FLAT}.tar.gz"
tar -czf "${TAR}" -C "$(dirname "${SRC}")" "$(basename "${SRC}")"
ls -lh "${TAR}"
echo "COLLECTED ${NAME} -> ${TAR}"
