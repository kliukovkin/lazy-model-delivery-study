#!/usr/bin/env bash
# Retrieve a collected experiment bundle to the workstation, and verify it
# arrived intact. Run from the WORKSTATION.
#   92-fetch.sh <experiment-name> [host]     host defaults to node1
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: 92-fetch.sh <experiment-name> [host]}"
HOST="${2:-node1}"
DEST="${HERE}/../results"
mkdir -p "${DEST}"
FLAT="$(echo "${NAME}" | tr '/' '-')"
"${HERE}/rsh.sh" "${HOST}" "cat /data/v9-${FLAT}.tar.gz" > "${DEST}/${FLAT}.tar.gz"
tar -tzf "${DEST}/${FLAT}.tar.gz" >/dev/null || { echo "FATAL: ${FLAT}.tar.gz did not arrive intact"; exit 1; }
mkdir -p "${DEST}/$(dirname "${NAME}")"
tar -xzf "${DEST}/${FLAT}.tar.gz" -C "${DEST}/$(dirname "${NAME}")"
rm -f "${DEST}/${FLAT}.tar.gz"
n=$(ls -1 "${DEST}/${NAME}" | wc -l | tr -d ' ')
echo "FETCHED ${NAME} from ${HOST}: ${n} entries -> ${DEST}/${NAME}/"
