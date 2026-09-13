#!/usr/bin/env bash
# spike-v4 S3 [P1]: rebuild stargz-snapshotter from main, pin the commit SHA, and
# re-run the two P0 questions on current code.
#   (a) config-key surface -- answered by source audit BEFORE the rig existed
#       (source-audit/S3a-config-key-surface.txt); re-asserted here against the
#       binary actually built, so the report's claim is about the same artifact
#       that was measured.
#   (b) S1a on main, N=1 per unit variant (shipped unit and KillMode=process), so
#       main is comparable to BOTH v0.18.2 arms rather than only one.
#   (c) quick ENOSPC on main, N=1 -- does the lying-pod class still reproduce?
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl
export PATH=$PATH:/usr/local/go/bin
NODE="$(NODE_CTR)"
SRC="${SRC:-/data/stargz-src}"
OUT="${RESULTS_DIR}/s3"; mkdir -p "${OUT}"

if [ ! -d "${SRC}/.git" ]; then
  log "cloning stargz-snapshotter main"
  git clone https://github.com/containerd/stargz-snapshotter.git "${SRC}"
fi
git -C "${SRC}" fetch --all --tags -q
git -C "${SRC}" checkout -q main
git -C "${SRC}" pull -q --ff-only || true
MAIN_SHA=$(git -C "${SRC}" rev-parse HEAD)
{ echo "main_sha=${MAIN_SHA}"
  echo "main_sha_short=$(git -C "${SRC}" rev-parse --short HEAD)"
  git -C "${SRC}" log -1 --format='%H%n%ci%n%s'
  echo "--- go version ---"; go version
} > "${OUT}/main-commit.txt"
cat "${OUT}/main-commit.txt" >&2

if [ -x /data/stargz-bin-main/containerd-stargz-grpc ] && [ -x /data/stargz-bin-main/stargz-fuse-manager ]; then
  log "reusing binaries from 22a-prebuild-main.sh"
else
  log "building containerd-stargz-grpc + stargz-fuse-manager from main"
  ( cd "${SRC}" && make containerd-stargz-grpc stargz-fuse-manager ) 2>&1 | tail -20
  mkdir -p /data/stargz-bin-main
  cp "${SRC}/out/containerd-stargz-grpc" "${SRC}/out/stargz-fuse-manager" /data/stargz-bin-main/
fi
sha256sum /data/stargz-bin-main/* | tee "${OUT}/main-binaries-sha256.txt"

# ---------------- (a) re-assert the config-key surface against THIS build
{ echo "S3(a) -- config-key surface of the binary actually installed for S3."
  echo "Source tree at ${MAIN_SHA}."
  echo
  echo "### every toml struct tag in non-vendor, non-test Go source:"
  ( cd "${SRC}" && grep -rhn 'toml:"' --include='*.go' . | grep -v '_test.go' | grep -oE 'toml:"[a-z_]+"' | sort -u )
  echo
  echo "### keys matching size|byte|limit|quota|capacit|budget|gc|prune|evict|disk|space:"
  ( cd "${SRC}" && grep -rn 'toml:"' --include='*.go' . | grep -v '^./vendor/' | grep -v '_test.go' \
      | grep -iE 'size|byte|limit|quota|capacit|budget|gc|prune|evict|disk|space' )
  echo
  echo "### --help / flags of the built binary:"
  /data/stargz-bin-main/containerd-stargz-grpc --help 2>&1 || true
  echo
  echo "### version:"
  /data/stargz-bin-main/containerd-stargz-grpc --version 2>&1 || true
} > "${OUT}/S3a-config-surface-on-built-binary.txt" 2>&1
grep -c . "${OUT}/S3a-config-surface-on-built-binary.txt" >/dev/null

# ---------------- install the main build into the node, keeping v0.18.2 aside
log "installing main-built binaries into ${NODE} (v0.18.2 binaries preserved as *.v0182)"
docker exec "${NODE}" sh -c 'for b in containerd-stargz-grpc stargz-fuse-manager; do [ -f /usr/local/bin/$b.v0182 ] || cp /usr/local/bin/$b /usr/local/bin/$b.v0182; done'
hard_reset || log "WARN: pre-swap hard_reset reported a problem; continuing to binary swap"
docker exec "${NODE}" systemctl stop stargz-snapshotter || true
sleep 2
sg_kill TERM fm; sleep 3; sg_kill 9 fm; sg_kill 9 grpc
docker exec "${NODE}" sh -c 'rm -f /run/containerd-stargz-grpc/fuse-manager.sock' || true
sg_umount_stale
for b in containerd-stargz-grpc stargz-fuse-manager; do
  docker cp "/data/stargz-bin-main/${b}" "${NODE}:/usr/local/bin/${b}"
  docker exec "${NODE}" chmod 0755 "/usr/local/bin/${b}"
done
docker exec "${NODE}" systemctl reset-failed stargz-snapshotter 2>/dev/null || true
docker exec "${NODE}" systemctl start stargz-snapshotter
sleep 6
docker exec "${NODE}" systemctl is-active stargz-snapshotter >/dev/null || {
  docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager | tail -40 > "${OUT}/main-start-FAILED.txt"; die "main build did not start"; }
docker exec "${NODE}" sh -c 'containerd-stargz-grpc --version' > "${OUT}/installed-version.txt" 2>&1
cat "${OUT}/installed-version.txt" >&2

# ---------------- (b) S1a on main
log "S3(b): re-running the S1 restart trials on main"
RESULTS_DIR="${RESULTS_DIR}/s3" \
TRIALS="M1-main-shipped-unit:true:default:systemctl
M2-main-killmode-process:true:process:systemctl" \
  "${BENCH_ROOT}/20-s1-restart.sh"

# ---------------- (c) quick ENOSPC on main
log "S3(c): re-running the S2 ENOSPC induction on main"
RESULTS_DIR="${RESULTS_DIR}/s3" TRIAL="S3c-main-75pct-fm-on" FUSE_MANAGER=true PREFILL_PCT=75 \
  "${BENCH_ROOT}/21-s2-enospc.sh"

log "S3 done -> ${OUT}. main SHA: ${MAIN_SHA}"
