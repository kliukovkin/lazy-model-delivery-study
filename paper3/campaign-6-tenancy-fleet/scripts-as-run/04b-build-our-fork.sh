#!/usr/bin/env bash
# spike-v5 node-host: build the system under test -- OUR fork, pinned SHA.
#
# v4 fetched an upstream release tarball (04-fetch-binaries.sh); that path is
# kept, because v5 still needs v0.18.2 as the vanilla control arm for V2 and V4.
# This script produces the second set of binaries, into a SEPARATE directory, so
# that switching arms is a file copy and never a rebuild.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
export PATH=$PATH:/usr/local/go/bin
need git; need go

DEST="${OURBIN:-/data/stargz-bin-ours}"
SRC=/data/src/stargz-ours
mkdir -p "${DEST}" "$(dirname "${SRC}")"

if [ ! -d "${SRC}/.git" ]; then
  log "cloning ${OUR_REPO} (branch ${OUR_BRANCH})"
  git clone --branch "${OUR_BRANCH}" "${OUR_REPO}" "${SRC}"
fi
cd "${SRC}"
git fetch --all --quiet
git checkout --quiet "${OUR_SHA}"
FULL_SHA=$(git rev-parse HEAD)
log "building at ${FULL_SHA}"
[ "${FULL_SHA:0:8}" = "${OUR_SHA:0:8}" ] || die "checked out ${FULL_SHA}, wanted ${OUR_SHA}"

# Same three binaries 04-fetch-binaries.sh provides from the release tarball.
go version
for t in containerd-stargz-grpc stargz-fuse-manager ctr-remote; do
  log "go build ./cmd/${t}"
  ( cd cmd && go build -o "${DEST}/${t}" "./${t}" )
done

# Provenance, at the same level of detail as the release tarball's checksums.
{
  echo "repo=${OUR_REPO}"
  echo "branch=${OUR_BRANCH}"
  echo "sha=${FULL_SHA}"
  echo "go=$(go version)"
  echo "built_at=$(date -u +%FT%TZ)"
  echo "--- git log -1 ---"
  git log -1 --format='%H%n%an%n%aI%n%s'
  echo "--- git status (must be clean) ---"
  git status --porcelain
} > "${DEST}/PROVENANCE.txt"
[ -z "$(git status --porcelain)" ] || die "working tree dirty -- the built binaries would not match ${OUR_SHA}"

sha256sum "${DEST}"/* 2>/dev/null | grep -v SHA256 > "${DEST}/SHA256SUMS.txt"
mkdir -p "${RESULTS_DIR}/identity-bundle"
cp "${DEST}/PROVENANCE.txt" "${DEST}/SHA256SUMS.txt" "${RESULTS_DIR}/identity-bundle/" 2>/dev/null || true
cat "${DEST}/PROVENANCE.txt"; cat "${DEST}/SHA256SUMS.txt"
"${DEST}/containerd-stargz-grpc" --version
