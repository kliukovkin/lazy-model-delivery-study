#!/usr/bin/env bash
# Retrieve a collected experiment bundle to the workstation, and verify it
# arrived intact. Run from the WORKSTATION.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: 92-fetch.sh <experiment-name>}"
DEST="${HERE}/../results"
mkdir -p "${DEST}"
FLAT="$(echo "${NAME}" | tr '/' '-')"
"${HERE}/rsh.sh" node "cat /data/v7-${FLAT}.tar.gz" > "${DEST}/${FLAT}.tar.gz"
tar -tzf "${DEST}/${FLAT}.tar.gz" >/dev/null || { echo "FATAL: ${FLAT}.tar.gz did not arrive intact"; exit 1; }
mkdir -p "${DEST}/$(dirname "${NAME}")"
tar -xzf "${DEST}/${FLAT}.tar.gz" -C "${DEST}/$(dirname "${NAME}")"
n=$(tar -tzf "${DEST}/${FLAT}.tar.gz" | wc -l | tr -d ' ')
echo "FETCHED ${NAME}: ${n} entries -> ${DEST}/${NAME}/"
