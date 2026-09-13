#!/usr/bin/env bash
# rsh.sh <reg|node|node1|node2|node3> <command...>   -- run a command on a rig host
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/hosts.env"
K=REDACTED-KEY.pem
O=(-i "$K" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30)
SSHN=()
if [ "${1:-}" = "-n" ]; then SSHN=(-n); shift; fi
case "$1" in
  reg)          H="${REG_PUB}";;
  node|node1)   H="${NODE1_PUB}";;
  node2)        H="${NODE2_PUB}";;
  node3)        H="${NODE3_PUB}";;
  *) echo "usage: rsh.sh <reg|node1|node2|node3> <cmd...>" >&2; exit 2;;
esac
shift
exec ssh "${SSHN[@]}" "${O[@]}" "ubuntu@${H}" "$@"
