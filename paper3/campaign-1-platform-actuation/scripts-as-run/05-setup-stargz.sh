#!/usr/bin/env bash
# spike-v4 node-host: install stargz-snapshotter INSIDE the kind node, under
# systemd, using upstream's own shipped unit file and upstream's own DEFAULT
# socket/root paths -- so that "systemctl restart stargz-snapshotter" in S1 is
# the literal operator gesture, not v3.1's pkill approximation.
#
# Differences from v3.1's 05-setup-stargz.sh:
#   - runs under systemd (v3.1 used `docker exec -d` bare processes)
#   - installs stargz-fuse-manager alongside (shipped in the same tarball)
#   - default paths (/run/containerd-stargz-grpc/...), not the v3.1 "-stargz" suffixed ones
#   - [fuse_manager] enable = true in the snapshotter config
#   - [proxy_plugins.stargz.exports] root = ... in the containerd config, i.e.
#     PR #1893 as upstream documents it, so S2 can measure what that visibility
#     actually buys kubelet
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kubectl

FUSE_MANAGER="${FUSE_MANAGER:-true}"        # true|false -- [fuse_manager] enable
STARGZ_LOG_LEVEL="${STARGZ_LOG_LEVEL:-debug}"
NODE="$(NODE_CTR)"
BINSRC="${BINSRC:-/data/stargz-bin}"        # populated by 04-fetch-binaries.sh

log "checking FUSE availability in node ${NODE}"
docker exec "${NODE}" sh -c 'test -c /dev/fuse' || die "no /dev/fuse in kind node"
log "confirming the 92GB cache partition is bind-mounted at ${STARGZ_ROOT_IN_NODE}"
docker exec "${NODE}" sh -c "mountpoint -q ${STARGZ_ROOT_IN_NODE}" || die "cache bind mount missing"

log "installing stargz binaries from ${BINSRC} into ${NODE}"
for b in containerd-stargz-grpc ctr-remote stargz-fuse-manager; do
  [ -f "${BINSRC}/${b}" ] || die "missing ${BINSRC}/${b}"
  docker cp "${BINSRC}/${b}" "${NODE}:/usr/local/bin/${b}"
  docker exec "${NODE}" chmod 0755 "/usr/local/bin/${b}"
done
docker exec "${NODE}" sh -c 'containerd-stargz-grpc --version; stargz-fuse-manager -v 2>/dev/null || true'

log "writing /etc/containerd-stargz-grpc/config.toml (fuse_manager enable=${FUSE_MANAGER})"
docker exec "${NODE}" mkdir -p /etc/containerd-stargz-grpc
docker exec -i "${NODE}" sh -c 'cat > /etc/containerd-stargz-grpc/config.toml' <<EOF
metrics_address = "${STARGZ_METRICS_ADDRESS}"

# Exact TOML per cmd/containerd-stargz-grpc/main.go:89,92-100 and docs/overview.md:111-121
# of v0.18.2. 'address' and 'path' are left at their documented defaults
# (/run/containerd-stargz-grpc/fuse-manager.sock, and PATH lookup for the
# "stargz-fuse-manager" binary).
[fuse_manager]
  enable = ${FUSE_MANAGER}

[[resolver.host."${REG_PRIV}:${REG_PORT}".mirrors]]
  host = "${REG_PRIV}:${REG_PORT}"
  insecure = true
EOF
docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml

# journald rate-limits by default (RateLimitBurst) and DROPS lines beyond it. Under an
# ENOSPC storm the snapshotter emits errors far faster than that, so the evidence would
# be silently incomplete. Disable the limit and give the journal room.
log "disabling journald rate limiting inside the node (evidence integrity)"
docker exec "${NODE}" mkdir -p /etc/systemd/journald.conf.d
docker exec -i "${NODE}" sh -c 'cat > /etc/systemd/journald.conf.d/nolimit.conf' <<'EOF2'
[Journal]
RateLimitIntervalSec=0
RateLimitBurst=0
SystemMaxUse=6G
EOF2
docker exec "${NODE}" systemctl restart systemd-journald || true
sleep 2

log "installing upstream's stargz-snapshotter.service VERBATIM (script/config/etc/systemd/system/)"
docker exec -i "${NODE}" sh -c 'cat > /etc/systemd/system/stargz-snapshotter.service' <<EOF
[Unit]
Description=stargz snapshotter
After=network.target
Before=containerd.service

[Service]
Type=notify
Environment=HOME=/root
ExecStart=/usr/local/bin/containerd-stargz-grpc --log-level=${STARGZ_LOG_LEVEL} --config=/etc/containerd-stargz-grpc/config.toml
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
# NOTE: the shipped unit sets no KillMode, so systemd's default
# KillMode=control-group applies. That matters for S1 and is measured there,
# not silently worked around here -- see 20-s1-restart.sh.
docker exec "${NODE}" rm -rf /etc/systemd/system/stargz-snapshotter.service.d
docker exec "${NODE}" systemctl daemon-reload
docker exec "${NODE}" systemctl enable --now stargz-snapshotter
sleep 5
docker exec "${NODE}" systemctl is-active stargz-snapshotter || {
  docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager | tail -40; die "unit failed to start"; }
docker exec "${NODE}" test -S /run/containerd-stargz-grpc/containerd-stargz-grpc.sock || die "snapshotter socket absent"
if [ "${FUSE_MANAGER}" = "true" ]; then
  docker exec "${NODE}" test -S /run/containerd-stargz-grpc/fuse-manager.sock || die "fuse-manager socket absent -- fuse_manager did not engage"
  docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager | grep -q "fusemanager mode" \
    && log "CONFIRMED: 'Start snapshotter with fusemanager mode' in the unit journal" \
    || log "WARN: fusemanager-mode log line not found"
fi

if ! docker exec "${NODE}" grep -q 'proxy_plugins.stargz' /etc/containerd/config.toml; then
  log "wiring proxy_plugins.stargz + exports.root into node containerd config"
  docker exec "${NODE}" cp /etc/containerd/config.toml /etc/containerd/config.toml.pre-stargz
  # v2 pitfall: a [proxy_plugins] parent table already exists in kind's generated
  # config (fuse-overlayfs). Appending a second parent header is a TOML duplicate-
  # table error; appending only the child tables reopens the existing table.
  docker exec -i "${NODE}" sh -c 'cat >> /etc/containerd/config.toml' <<EOF
  [proxy_plugins.stargz]
    address = "/run/containerd-stargz-grpc/containerd-stargz-grpc.sock"
    type = "snapshot"
  [proxy_plugins.stargz.exports]
    root = "${STARGZ_ROOT_IN_NODE}/"
EOF
fi
docker exec "${NODE}" sh -c \
  "grep -q disable_snapshot_annotations /etc/containerd/config.toml || sed -i '/discard_unpacked_layers = true/a\\      disable_snapshot_annotations = false' /etc/containerd/config.toml"
docker exec "${NODE}" sh -c "sed -i 's/snapshotter = \"overlayfs\"/snapshotter = \"stargz\"/' /etc/containerd/config.toml"
docker exec "${NODE}" grep -nE 'snapshotter =|disable_snapshot_annotations|proxy_plugins.stargz|root =' /etc/containerd/config.toml

log "pre-restart cluster health check"
kubectl -n kube-system get pods --field-selector=status.phase!=Running 2>&1 | grep -v '^No resources' && die "unhealthy kube-system pods BEFORE restart" || log "kube-system clean"
log "restarting node-internal containerd (NOT the host's containerd.service)"
docker exec "${NODE}" systemctl restart containerd
sleep 5
docker exec "${NODE}" ctr version >/dev/null || die "node containerd did not come back"
for i in $(seq 1 40); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 3; done
kubectl get nodes
kubectl -n kube-system get pods
log "stargz-snapshotter ${STARGZ_VER} up under systemd, fuse_manager=${FUSE_MANAGER}"
