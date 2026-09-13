#!/usr/bin/env bash
# spike-v4: clone + compile stargz-snapshotter from main EARLY, in parallel with the
# registry-host's 140GB image build, so S3 doesn't pay for the Go build later.
# Build only -- installation and the S3 trials stay in 22-s3-main.sh.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
export PATH=$PATH:/usr/local/go/bin
SRC="${SRC:-/data/stargz-src}"
OUT="${RESULTS_DIR}/s3"; mkdir -p "${OUT}"
[ -d "${SRC}/.git" ] || git clone https://github.com/containerd/stargz-snapshotter.git "${SRC}"
git -C "${SRC}" fetch --all --tags -q
git -C "${SRC}" checkout -q main
git -C "${SRC}" pull -q --ff-only || true
{ echo "main_sha=$(git -C "${SRC}" rev-parse HEAD)"
  echo "main_sha_short=$(git -C "${SRC}" rev-parse --short HEAD)"
  git -C "${SRC}" log -1 --format='%H%n%ci%n%s'
  echo "--- go version ---"; go version
} | tee "${OUT}/main-commit.txt"
( cd "${SRC}" && make containerd-stargz-grpc stargz-fuse-manager ) 2>&1 | tail -10
mkdir -p /data/stargz-bin-main
cp "${SRC}/out/containerd-stargz-grpc" "${SRC}/out/stargz-fuse-manager" /data/stargz-bin-main/
sha256sum /data/stargz-bin-main/* | tee "${OUT}/main-binaries-sha256.txt"
/data/stargz-bin-main/containerd-stargz-grpc --version | tee "${OUT}/main-binary-version.txt"
echo "PREBUILD_MAIN_OK"
