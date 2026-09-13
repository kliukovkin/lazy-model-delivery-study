#!/usr/bin/env bash
# rsh.sh <reg|node> <command...>   -- run a command on a rig host
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/hosts.env"
K=REDACTED-KEY.pem
O=(-i "$K" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=30)
case "$1" in
  reg)  H="${REG_PUB}";;
  node) H="${NODE_PUB}";;
  *) echo "usage: rsh.sh <reg|node> <cmd...>" >&2; exit 2;;
esac
shift
exec ssh "${O[@]}" "ubuntu@${H}" "$@"
