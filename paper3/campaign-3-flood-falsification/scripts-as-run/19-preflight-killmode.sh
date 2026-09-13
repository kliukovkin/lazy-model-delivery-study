#!/usr/bin/env bash
# Mechanism preflight: does systemd cgroup-kill take the detached FUSE manager
# with it? Needs no image -- pure process-lifecycle observation.
set -a; . ~/v4/hosts.env; set +a
cd ~/v4; . ./env.sh; . ./lib.sh
N="$(NODE_CTR)"
out=~/preflight-killmode.txt
{
echo "=== PREFLIGHT: fuse-manager survival across systemctl restart ==="
echo "date=$(date -Is)"
echo
echo "--- A) unit AS SHIPPED (no drop-in; KillMode=$(docker exec $N systemctl show stargz-snapshotter -p KillMode --value)) ---"
echo "before: grpc=$(sg_grpc_pid) fm=$(sg_fm_pid)"
docker exec $N systemctl restart stargz-snapshotter
sleep 6
echo "after : grpc=$(sg_grpc_pid) fm=$(sg_fm_pid)"
echo
echo "--- B) with KillMode=process drop-in ---"
docker exec $N mkdir -p /etc/systemd/system/stargz-snapshotter.service.d
docker exec -i $N sh -c "cat > /etc/systemd/system/stargz-snapshotter.service.d/killmode.conf" <<EOF
[Service]
KillMode=process
EOF
docker exec $N systemctl daemon-reload
docker exec $N systemctl restart stargz-snapshotter
sleep 6
echo "effective KillMode=$(docker exec $N systemctl show stargz-snapshotter -p KillMode --value)"
echo "before(new baseline): grpc=$(sg_grpc_pid) fm=$(sg_fm_pid)"
FM1=$(sg_fm_pid)
docker exec $N systemctl restart stargz-snapshotter
sleep 6
FM2=$(sg_fm_pid)
echo "after : grpc=$(sg_grpc_pid) fm=${FM2}"
echo "fuse-manager PID preserved across restart: $([ -n "$FM1" ] && [ "$FM1" = "$FM2" ] && echo YES || echo NO)"
echo
echo "--- restore unit to as-shipped for the real S1 run ---"
docker exec $N rm -rf /etc/systemd/system/stargz-snapshotter.service.d
docker exec $N systemctl daemon-reload
docker exec $N systemctl restart stargz-snapshotter
sleep 5
echo "final: KillMode=$(docker exec $N systemctl show stargz-snapshotter -p KillMode --value) active=$(sg_unit_active) grpc=$(sg_grpc_pid) fm=$(sg_fm_pid)"
} | tee $out
