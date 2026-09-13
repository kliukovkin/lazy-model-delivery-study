#!/usr/bin/env bash
# push.sh <reg|node1|node2|node3>  -- copy the harness + hosts.env to a rig host
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../hosts.env"
K=REDACTED-KEY.pem
O=(-i "$K" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
case "$1" in
  reg)        H="${REG_PUB}";;
  node|node1) H="${NODE1_PUB}";;
  node2)      H="${NODE2_PUB}";;
  node3)      H="${NODE3_PUB}";;
  *) echo "usage: push.sh <reg|node1|node2|node3>" >&2; exit 2;;
esac
ssh "${O[@]}" "ubuntu@${H}" 'mkdir -p ~/bench'
tar -czf - -C "${HERE}" . | ssh "${O[@]}" "ubuntu@${H}" 'tar -xzf - -C ~/bench'
scp "${O[@]}" "${HERE}/../hosts.env" "ubuntu@${H}:~/bench/hosts.env" >/dev/null
echo "pushed harness -> $1 (${H}):~/bench"
