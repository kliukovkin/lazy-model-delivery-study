#!/usr/bin/env bash
# v3.1: switch the single "stargz" proxy_plugin's cache ROOT between the
# bounded 100GB partition (/var/lib/containerd-stargz-grpc, for ENOSPC-
# inducing experiments) and the big /data-backed one (/var/lib/containerd-
# stargz-grpc-big, for P0.6's "sufficient cache" run).
#
# NOTE (live pitfall, v3.1): originally tried running TWO simultaneous
# containerd-stargz-grpc daemon instances (different --address/--config,
# registered as two separate proxy_plugins "stargz"/"stargzbig") so both
# cache roots would be live at once and switchable via containerd's
# snapshotter= key alone. The second instance hung completely silently
# (alive per `ps`, zero log output even at debug level, zero for 15s+) --
# consistent with the binary taking some global lock (pidfile/flock) at
# startup BEFORE its own logger initializes, so a second instance blocks
# invisibly forever. Simpler fix: only ever run ONE stargz-grpc process;
# stop it, rewrite its config.toml root, restart it at the SAME socket path
# containerd already has registered -- containerd itself does not need a
# restart, since the proxy_plugin address is unchanged, only what's
# listening there.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

TARGET="${1:?usage: 05c-switch-stargz-cache-root.sh <small|big>}"
NODE="${CLUSTER_NAME}-control-plane"
case "${TARGET}" in
  small) ROOT="/var/lib/containerd-stargz-grpc" ;;
  big)   ROOT="/var/lib/containerd-stargz-grpc-big" ;;
  *) die "target must be 'small' or 'big'" ;;
esac

CURRENT_ROOT=$(docker exec "${NODE}" grep -oP 'root = "\K[^"]+' /etc/containerd-stargz-grpc-stargz/config.toml || echo "")
if [ "${CURRENT_ROOT}" = "${ROOT}" ]; then
  log "stargz cache root already ${ROOT}, no-op"
  exit 0
fi
log "switching stargz cache root: ${CURRENT_ROOT:-<default>} -> ${ROOT}"

docker exec "${NODE}" pkill -f 'containerd-stargz-grpc.*stargz/containerd-stargz-grpc.sock' || true
sleep 2
docker exec "${NODE}" sh -c "rm -f /run/containerd-stargz-grpc-stargz/*.sock"

docker exec -i "${NODE}" sh -c 'cat > /etc/containerd-stargz-grpc-stargz/config.toml' <<EOF
metrics_address = "${STARGZ_METRICS_ADDRESS}"
root = "${ROOT}"

[[resolver.host."${REG_PRIV}:${REG_PORT}".mirrors]]
  host = "${REG_PRIV}:${REG_PORT}"
  insecure = true
EOF

docker exec -d "${NODE}" sh -c \
  "containerd-stargz-grpc --log-level ${STARGZ_LOG_LEVEL:-info} --address /run/containerd-stargz-grpc-stargz/containerd-stargz-grpc.sock --config /etc/containerd-stargz-grpc-stargz/config.toml > /var/log/stargz-grpc-stargz.log 2>&1"
sleep 3
docker exec "${NODE}" sh -c 'test -S /run/containerd-stargz-grpc-stargz/containerd-stargz-grpc.sock' \
  || die "stargz-grpc did not come back up after cache-root switch -- check /var/log/stargz-grpc-stargz.log"
log "stargz cache root now: ${ROOT}"
