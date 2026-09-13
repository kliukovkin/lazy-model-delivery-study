#!/usr/bin/env bash
# spike-v4 node-host: fetch the official stargz-snapshotter release tarball and
# record its checksums, so the report can pin exactly which binaries were measured.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
DEST=/data/stargz-bin
mkdir -p "${DEST}"
if [ ! -f "${DEST}/containerd-stargz-grpc" ]; then
  URL="https://github.com/containerd/stargz-snapshotter/releases/download/${STARGZ_VER}/stargz-snapshotter-${STARGZ_VER}-linux-amd64.tar.gz"
  log "downloading ${URL}"
  curl -sSL -o /tmp/stargz.tgz "${URL}"
  sha256sum /tmp/stargz.tgz > "${DEST}/TARBALL-SHA256.txt"
  tar -xzf /tmp/stargz.tgz -C "${DEST}"
fi
sha256sum "${DEST}"/* 2>/dev/null | grep -v SHA256 > "${DEST}/SHA256SUMS.txt"
mkdir -p "${RESULTS_DIR}/identity-bundle"
cp "${DEST}/TARBALL-SHA256.txt" "${DEST}/SHA256SUMS.txt" "${RESULTS_DIR}/identity-bundle/" 2>/dev/null || true
cat "${DEST}/SHA256SUMS.txt"
"${DEST}/containerd-stargz-grpc" --version
