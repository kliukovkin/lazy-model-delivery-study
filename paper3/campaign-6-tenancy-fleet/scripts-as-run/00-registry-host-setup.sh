#!/usr/bin/env bash
# spike-v4 registry-host bootstrap. Descended from v3.1's 00-registry-host-setup.sh.
# Differences from v3.1:
#   - MinIO dropped: v4 has no S3/eager control arm, nothing reads it.
#   - Same proactive containerd-root relocation to /data (v3 pitfall #1).
#   - Same retained registry access log (json-file, max-size=1g).
set -euo pipefail

# ---------------------------------------------------------------- v5 live fix
# v4 hardcoded /dev/nvme1n1 as the instance store. On the instances this run got,
# NVMe enumeration is REVERSED: nvme1n1 is the 30GB EBS root and nvme0n1 is the
# 1.7TB instance store. v4's script would therefore have run `parted mklabel gpt`
# over the ROOT disk; it survived only because its `[ ! -b /dev/nvme1n1p1 ]`
# guard happened to be true (the root's own p1 exists) and mkfs refuses a mounted
# device. That is luck, not safety. Detect by device model instead, and assert
# the result is not the disk holding /.
detect_instance_store() {
  local d m root_disk
  root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
  for d in /sys/block/nvme*n1; do
    [ -e "$d" ] || continue
    m=$(cat "$d/device/model" 2>/dev/null || true)
    case "$m" in
      *"Instance Storage"*)
        [ "$(basename "$d")" = "${root_disk}" ] && continue
        echo "/dev/$(basename "$d")"; return 0 ;;
    esac
  done
  return 1
}
# v7: the registry builds onto an EBS data volume, not onto the instance store.
#
# The artifacts have to be snapshottable. v5 built onto the instance store, could
# not snapshot it, tried to copy 309 GB onto a fresh volume instead, and the copy
# died mid-flight; v6 therefore paid the full rebuild again. Building straight
# onto EBS turns preserving them into a metadata operation.
#
# Detected by model and size rather than by device name, for the same reason the
# instance-store detector is: NVMe enumeration is not stable across launches
# (v5 F1), and getting this wrong means formatting the root disk.
detect_ebs_data() {
  local d m sz root_disk
  root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
  for d in /sys/block/nvme*n1; do
    [ -e "$d" ] || continue
    [ "$(basename "$d")" = "${root_disk}" ] && continue
    m=$(cat "$d/device/model" 2>/dev/null || true)
    sz=$(cat "$d/size" 2>/dev/null || echo 0)          # 512-byte sectors
    case "$m" in
      *"Elastic Block Store"*)
        # Bigger than any root volume this rig uses, so it cannot be one.
        [ "${sz}" -gt 209715200 ] && { echo "/dev/$(basename "$d")"; return 0; } ;;
    esac
  done
  return 1
}

ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
STARGZ_VER="${STARGZ_VER:-v0.18.2}"

if DATA_DEV="$(detect_ebs_data)"; then
  DATA_KIND=ebs
else
  DATA_DEV="$(detect_instance_store)" || { echo "FATAL: no data device found"; lsblk; exit 1; }
  DATA_KIND=instance-store
  log "WARNING: no EBS data volume found; falling back to the instance store."
  log "         Artifacts built here CANNOT be snapshotted (v7 rule 2)."
fi
[ "${DATA_DEV}" != "/dev/${ROOT_DISK}" ] || { echo "FATAL: refusing to format the root disk ${DATA_DEV}"; exit 1; }
echo "registry data device = ${DATA_DEV} (${DATA_KIND}); root disk = /dev/${ROOT_DISK}, left alone"

if ! mountpoint -q /data; then
  # v8: the data volume may be RESTORED FROM A SNAPSHOT and already hold the
  # artifacts. Formatting it would destroy exactly what this spike exists to
  # reuse, so probe for an existing filesystem first and only create one if
  # there is nothing there. RESTORED=1 is exported for later steps.
  if sudo blkid "${DATA_DEV}" >/dev/null 2>&1; then
    log "existing filesystem found on ${DATA_DEV}; mounting WITHOUT formatting (restored artifacts)"
    sudo mkdir -p /data && sudo mount "${DATA_DEV}" /data
    RESTORED=1
  else
    log "no filesystem on ${DATA_DEV}; formatting+mounting -> /data"
    sudo mkfs.ext4 -F "${DATA_DEV}"
    sudo mkdir -p /data && sudo mount "${DATA_DEV}" /data && sudo chown ubuntu:ubuntu /data
    RESTORED=0
  fi
fi
echo "restored_volume=${RESTORED:-unknown}" | sudo tee -a /data/DATA-DEVICE.txt >/dev/null
df -h /data | tail -1
# Recorded so the snapshot step knows what to capture and the report can say
# what the artifacts were built on.
{ echo "data_device=${DATA_DEV}"; echo "data_kind=${DATA_KIND}"; } | sudo tee /data/DATA-DEVICE.txt >/dev/null
df -h /data
sudo loginctl enable-linger ubuntu

if ! command -v docker >/dev/null 2>&1; then
  log "installing docker"; curl -fsSL https://get.docker.com | sudo sh; sudo usermod -aG docker ubuntu
fi

if ! grep -q 'root = "/data/containerd"' /etc/containerd/config.toml 2>/dev/null; then
  log "relocating system containerd root to /data/containerd (proactive; v3 pitfall #1)"
  sudo systemctl stop docker containerd || true
  sudo rm -rf /var/lib/containerd/*
  sudo mkdir -p /data/containerd
  printf 'version = 2\ndisabled_plugins = ["io.containerd.grpc.v1.cri"]\nroot = "/data/containerd"\nstate = "/run/containerd"\n' | sudo tee /etc/containerd/config.toml
  sudo systemctl start containerd; sleep 2; sudo systemctl start docker; sleep 2
fi

sudo mkdir -p /data/docker
if ! grep -q '"data-root": "/data/docker"' /etc/docker/daemon.json 2>/dev/null; then
  log "relocating docker data-root to /data/docker"
  sudo systemctl stop docker || true
  echo '{"data-root": "/data/docker", "insecure-registries": ["localhost:5000", "127.0.0.1:5000"]}' | sudo tee /etc/docker/daemon.json
  sudo systemctl start docker
fi
sudo systemctl enable docker
sudo docker info >/dev/null && log "docker ok"

sudo mkdir -p /data/registry
if [ "$(sudo docker inspect -f '{{.State.Running}}' registry 2>/dev/null || true)" != 'true' ]; then
  log "starting registry:2 on 0.0.0.0:5000 with a retained access log"
  sudo docker rm -f registry >/dev/null 2>&1 || true
  sudo docker run -d --restart=always -p 0.0.0.0:5000:5000 \
    --log-driver json-file --log-opt max-size=1g --log-opt max-file=5 \
    -v /data/registry:/var/lib/registry --name registry registry:2
fi

# ctr-remote for the eStargz conversion. The v0.18.2 release tarball also ships
# stargz-fuse-manager and stargz-store; grab the whole set so the node-host can
# scp the exact same binaries rather than re-downloading a possibly different one.
# v8: on a restored volume the tarball is already here, but its ctr-remote has
# not been installed into /usr/local/bin on THIS instance. Install it if present
# rather than re-fetching, and only download when it is genuinely missing.
if [ -f /data/stargz-bin/ctr-remote ] && ! command -v ctr-remote >/dev/null 2>&1; then
  log "installing ctr-remote from the restored /data/stargz-bin"
  sudo install -m 0755 /data/stargz-bin/ctr-remote /usr/local/bin/
fi
if [ ! -f /data/stargz-bin/ctr-remote ]; then
  log "fetching stargz-snapshotter ${STARGZ_VER} release tarball"
  mkdir -p /data/stargz-bin && cd /tmp
  curl -sSL -o stargz.tar.gz "https://github.com/containerd/stargz-snapshotter/releases/download/${STARGZ_VER}/stargz-snapshotter-${STARGZ_VER}-linux-amd64.tar.gz"
  tar -xzf stargz.tar.gz -C /data/stargz-bin
  sha256sum /data/stargz-bin/* | tee /data/stargz-bin/SHA256SUMS.txt
  sudo install -m 0755 /data/stargz-bin/ctr-remote /usr/local/bin/
fi
ctr-remote --version

sudo apt-get update -qq
sudo apt-get install -y -qq iperf3 jq git python3 python3-pip fio sysstat >/dev/null
sudo sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
pgrep -f "iperf3 -s" >/dev/null || iperf3 -s -D
log "registry-host base setup done"
