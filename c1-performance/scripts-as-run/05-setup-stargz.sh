#!/usr/bin/env bash
# v3 node-host, Step 5 setup: install stargz-snapshotter inside the kind node,
# switch node's CRI snapshotter to "stargz", set disable_snapshot_annotations=false
# (v2 pitfall: left at default -> stargz never actually engages, "layer is
# normal snapshot(overlayfs)" in the log, cold pulls proportional to size).
# The stargz chunk-cache root (/var/lib/containerd-stargz-grpc INSIDE the node
# container) is bind-mounted via kind extraMounts to the host's dedicated
# 100GB loopback fs (${STARGZ_CACHE_MOUNT}) -- set up in 01-cluster-up.sh,
# BEFORE cluster creation, so this is a real bounded filesystem, not shared
# node/docker overlay storage.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need docker; need kubectl

STARGZ_VER="v0.18.2"
NODE="${CLUSTER_NAME}-control-plane"
TARBALL="stargz-snapshotter-${STARGZ_VER}-linux-amd64.tar.gz"
URL="https://github.com/containerd/stargz-snapshotter/releases/download/${STARGZ_VER}/${TARBALL}"

log "checking FUSE availability in node ${NODE}"
docker exec "${NODE}" sh -c 'test -c /dev/fuse' || die "no /dev/fuse in kind node"
log "FUSE ok"

log "confirming stargz chunk-cache bind mount landed at /var/lib/containerd-stargz-grpc"
docker exec "${NODE}" sh -c 'mountpoint -q /var/lib/containerd-stargz-grpc' \
  || die "extraMounts bind for stargz cache did not land -- check kind cluster config"

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

log "writing stargz-snapshotter config (remote registry ${REG_PRIV}:${REG_PORT}, plain http)"
docker exec "${NODE}" mkdir -p /etc/containerd-stargz-grpc /run/containerd-stargz-grpc
docker exec -i "${NODE}" sh -c 'cat > /etc/containerd-stargz-grpc/config.toml' <<EOF
[[resolver.host."${REG_PRIV}:${REG_PORT}".mirrors]]
  host = "${REG_PRIV}:${REG_PORT}"
  insecure = true
EOF

log "starting containerd-stargz-grpc (root=/var/lib/containerd-stargz-grpc == bind-mounted loopback)"
docker exec -d "${NODE}" sh -c \
  'containerd-stargz-grpc --log-level debug --address /run/containerd-stargz-grpc/containerd-stargz-grpc.sock --config /etc/containerd-stargz-grpc/config.toml > /var/log/stargz-grpc.log 2>&1'
sleep 3
docker exec "${NODE}" sh -c 'test -S /run/containerd-stargz-grpc/containerd-stargz-grpc.sock' \
  || die "stargz-grpc socket did not appear -- check /var/log/stargz-grpc.log in node"
log "stargz-grpc socket up"

log "wiring proxy_plugins.stargz into node containerd config.toml (backup first)"
docker exec "${NODE}" cp /etc/containerd/config.toml /etc/containerd/config.toml.pre-stargz
# NOTE (v2 pitfall avoided): a [proxy_plugins] table header ALREADY exists in
# kind's generated config (fuse-overlayfs is registered there). Appending a
# SECOND "[proxy_plugins]" header is a TOML duplicate-table error; appending
# just "[proxy_plugins.stargz]" (no parent header) is valid TOML and reopens
# the existing table.
docker exec -i "${NODE}" sh -c 'cat >> /etc/containerd/config.toml' <<'EOF'
  [proxy_plugins.stargz]
    address = "/run/containerd-stargz-grpc/containerd-stargz-grpc.sock"
    type = "snapshot"
EOF

log "setting snapshotter=stargz and disable_snapshot_annotations=false under [...cri.containerd]"
docker exec "${NODE}" sh -c \
  "sed -i 's/snapshotter = \"overlayfs\"/snapshotter = \"stargz\"/' /etc/containerd/config.toml"
docker exec "${NODE}" sh -c \
  "grep -q disable_snapshot_annotations /etc/containerd/config.toml || sed -i '/discard_unpacked_layers = true/a\\      disable_snapshot_annotations = false' /etc/containerd/config.toml"
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

log "stargz-snapshotter setup done."
