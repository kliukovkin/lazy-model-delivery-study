#!/usr/bin/env bash
# v3.1 node-host, Step 5 setup: install stargz-snapshotter inside the kind
# node, TWO daemon instances registered as separate containerd proxy_plugins:
#   "stargz"    -- root=/var/lib/containerd-stargz-grpc, bind-mounted to the
#                  REAL 100GB NVMe partition (/cache-part) -- for the
#                  ENOSPC-inducing P0.1/P0.4/P0.5 experiments.
#   "stargzbig" -- root=/var/lib/containerd-stargz-grpc-big, bind-mounted to
#                  /data/stargz-bigcache on the big ~1.6TB partition -- for
#                  P0.6's "sufficient cache" full-read + attribution run.
# Both run simultaneously; which one containerd actually USES for new pulls
# is controlled separately by 05b-switch-snapshotter.sh (sed + node-internal
# containerd restart, same pattern v3 used to switch stargz<->soci).
# disable_snapshot_annotations=false set once, applies to whichever
# snapshotter is active (v2 pitfall: left at default -> stargz never
# actually engages).
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need docker; need kubectl

STARGZ_LOG_LEVEL="${STARGZ_LOG_LEVEL:-info}"
STARGZ_VER="v0.18.2"
NODE="${CLUSTER_NAME}-control-plane"
TARBALL="stargz-snapshotter-${STARGZ_VER}-linux-amd64.tar.gz"
URL="https://github.com/containerd/stargz-snapshotter/releases/download/${STARGZ_VER}/${TARBALL}"

log "checking FUSE availability in node ${NODE}"
docker exec "${NODE}" sh -c 'test -c /dev/fuse' || die "no /dev/fuse in kind node"

log "confirming stargz cache bind mount landed"
docker exec "${NODE}" sh -c 'mountpoint -q /var/lib/containerd-stargz-grpc' || die "main cache bind (100GB partition) missing"

log "installing stargz-snapshotter ${STARGZ_VER} binaries into ${NODE}"
docker exec "${NODE}" sh -c "
  set -e
  cd /tmp
  curl -sSL -o stargz.tar.gz '${URL}'
  mkdir -p /tmp/stargz-bin
  tar -xzf stargz.tar.gz -C /tmp/stargz-bin
  install -m 0755 /tmp/stargz-bin/containerd-stargz-grpc /usr/local/bin/
  install -m 0755 /tmp/stargz-bin/ctr-remote /usr/local/bin/
  containerd-stargz-grpc --version
  ctr-remote --version
"

# start_instance <name> <root_dir> <metrics_port>
start_instance() {
  local name="$1" root="$2" metrics_port="$3"
  log "configuring+starting stargz-grpc instance '${name}' (root=${root}, metrics=:${metrics_port})"
  docker exec "${NODE}" mkdir -p "/etc/containerd-stargz-grpc-${name}" "/run/containerd-stargz-grpc-${name}"
  docker exec -i "${NODE}" sh -c "cat > /etc/containerd-stargz-grpc-${name}/config.toml" <<EOF
metrics_address = "0.0.0.0:${metrics_port}"
root = "${root}"

[[resolver.host."${REG_PRIV}:${REG_PORT}".mirrors]]
  host = "${REG_PRIV}:${REG_PORT}"
  insecure = true
EOF
  docker exec -d "${NODE}" sh -c \
    "containerd-stargz-grpc --log-level ${STARGZ_LOG_LEVEL} --address /run/containerd-stargz-grpc-${name}/containerd-stargz-grpc.sock --config /etc/containerd-stargz-grpc-${name}/config.toml > /var/log/stargz-grpc-${name}.log 2>&1"
  sleep 3
  docker exec "${NODE}" sh -c "test -S /run/containerd-stargz-grpc-${name}/containerd-stargz-grpc.sock" \
    || die "stargz-grpc '${name}' socket did not appear -- check /var/log/stargz-grpc-${name}.log in node"
  log "stargz-grpc '${name}' socket up"
}

# FIX (live pitfall, v3.1): a genuine SECOND simultaneous instance
# ("stargzbig") hangs completely silently forever (alive per `ps`, zero log
# output even at debug level) -- consistent with the binary taking some
# global lock/pidfile at startup before its own logger initializes, so a
# second instance blocks invisibly. Only ever run ONE instance; switch its
# `root` between the small (100GB) and big (/data) partitions via
# 05c-switch-stargz-cache-root.sh instead (stop, rewrite config, restart at
# the same socket path).
start_instance stargz /var/lib/containerd-stargz-grpc "${STARGZ_METRICS_ADDRESS##*:}"

log "wiring proxy_plugins.stargz into node containerd config.toml (backup first)"
docker exec "${NODE}" cp /etc/containerd/config.toml /etc/containerd/config.toml.pre-stargz
# NOTE (v2 pitfall avoided): a [proxy_plugins] table header ALREADY exists in
# kind's generated config (fuse-overlayfs is registered there). Appending a
# SECOND "[proxy_plugins]" header is a TOML duplicate-table error; appending
# just "[proxy_plugins.NAME]" (no parent header) is valid TOML and reopens
# the existing table.
docker exec -i "${NODE}" sh -c 'cat >> /etc/containerd/config.toml' <<'EOF'
  [proxy_plugins.stargz]
    address = "/run/containerd-stargz-grpc-stargz/containerd-stargz-grpc.sock"
    type = "snapshot"
EOF

log "setting disable_snapshot_annotations=false under [...cri.containerd] (applies regardless of which snapshotter is active)"
docker exec "${NODE}" sh -c \
  "grep -q disable_snapshot_annotations /etc/containerd/config.toml || sed -i '/discard_unpacked_layers = true/a\\      disable_snapshot_annotations = false' /etc/containerd/config.toml"

log "activating 'stargz' (100GB partition) as the default snapshotter for the initial setup"
docker exec "${NODE}" sh -c \
  "sed -i 's/snapshotter = \"overlayfs\"/snapshotter = \"stargz\"/' /etc/containerd/config.toml"
docker exec "${NODE}" grep -nE 'snapshotter =|disable_snapshot_annotations' /etc/containerd/config.toml

log "pre-restart cluster health check"
kubectl get nodes
kubectl -n kube-system get pods --field-selector=status.phase!=Running 2>&1 | grep -v '^No resources' && die "unhealthy kube-system pods BEFORE restart" || log "kube-system clean"

log "restarting node-internal containerd (NOT host containerd.service -- see v2 RUN-REPORT safety note)"
docker exec "${NODE}" systemctl restart containerd
sleep 5
docker exec "${NODE}" sh -c 'ctr version' || die "node containerd did not come back after restart"
docker exec "${NODE}" crictl info 2>/dev/null | grep -i snapshotter || true
log "post-restart cluster health check"
for i in $(seq 1 30); do
  if kubectl get nodes 2>/dev/null | grep -q Ready; then break; fi
  sleep 2
done
kubectl get nodes
kubectl -n kube-system get pods -o wide
kubectl -n kserve get pods

log "stargz-snapshotter setup done (both instances running; 'stargz' active)."
