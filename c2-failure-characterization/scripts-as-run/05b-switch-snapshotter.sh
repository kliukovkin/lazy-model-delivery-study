#!/usr/bin/env bash
# v3.1: flip which registered proxy_plugin containerd uses as its default
# snapshotter for new pulls (stargz | stargzbig | soci | overlayfs), then
# restart node-internal containerd to apply. Usage: 05b-switch-snapshotter.sh <name>
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

TARGET="${1:?usage: 05b-switch-snapshotter.sh <stargz|stargzbig|soci|overlayfs>}"
NODE="${CLUSTER_NAME}-control-plane"

CURRENT=$(docker exec "${NODE}" grep -oP 'snapshotter = "\K[^"]+' /etc/containerd/config.toml | head -1)
log "current snapshotter: ${CURRENT} -> switching to: ${TARGET}"
if [ "${CURRENT}" = "${TARGET}" ]; then
  log "already active, no-op"
  exit 0
fi
docker exec "${NODE}" sh -c "sed -i 's/snapshotter = \"${CURRENT}\"/snapshotter = \"${TARGET}\"/' /etc/containerd/config.toml"
docker exec "${NODE}" grep -n 'snapshotter =' /etc/containerd/config.toml

docker exec "${NODE}" systemctl restart containerd
sleep 5
docker exec "${NODE}" sh -c 'ctr version' || die "node containerd did not come back after restart"
for i in $(seq 1 30); do
  kubectl get nodes 2>/dev/null | grep -q Ready && break
  sleep 2
done
kubectl get nodes
log "snapshotter now: ${TARGET}"
