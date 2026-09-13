#!/usr/bin/env bash
# spike-v4 node-host bootstrap. Identical disk topology to v3.1 (this is the
# "как тогда" requirement): /dev/nvme1n1 partitioned into p1 (~1.7TB -> /data,
# containerd/docker roots) and p2 (100GB nominal -> ~92GB usable ext4 ->
# /cache-part), a REAL block device for the stargz chunk cache.
# Added vs v3.1: a Go toolchain. v5 needs go>=1.26 to build our fork (go.mod line 3).
set -euo pipefail
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
GO_VER="${GO_VER:-1.26.0}"   # v5: our go.mod requires go >= 1.26.0

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
NVME="$(detect_instance_store)" || { echo "FATAL: no NVMe instance store found"; lsblk; exit 1; }
ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)"
[ "${NVME}" != "/dev/${ROOT_DISK}" ] || { echo "FATAL: refusing to partition the root disk ${NVME}"; exit 1; }
echo "instance store = ${NVME} (root disk = /dev/${ROOT_DISK}, left alone)"


if [ ! -b "${NVME}p2" ]; then
  log "partitioning ${NVME}: p1 (rest) + p2 (100GB nominal)"
  # v3.1 live fix: parted's option parser chokes on the leading "-100GB"
  # negative offset unless "--" stops option parsing first.
  sudo parted -s "${NVME}" mklabel gpt
  sudo parted -s "${NVME}" -- mkpart primary ext4 0% -100GB
  sudo parted -s "${NVME}" -- mkpart primary ext4 -100GB 100%
  sleep 2; sudo partprobe "${NVME}"; sleep 2
fi
if ! mountpoint -q /data; then
  sudo mkfs.ext4 -F "${NVME}p1"; sudo mkdir -p /data
  sudo mount "${NVME}p1" /data; sudo chown ubuntu:ubuntu /data
fi
if ! mountpoint -q /cache-part; then
  sudo mkfs.ext4 -F "${NVME}p2"; sudo mkdir -p /cache-part
  sudo mount "${NVME}p2" /cache-part; sudo chown ubuntu:ubuntu /cache-part
fi
df -h /data /cache-part
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
  # v6 live fix: two docker restarts inside one setup run trip systemd's
  # start rate limiter (start-limit-hit) and the second one fails.
  sudo systemctl reset-failed docker.service docker.socket 2>/dev/null || true
  sudo systemctl start containerd; sleep 2; sudo systemctl start docker; sleep 2
fi
sudo mkdir -p /data/docker
if ! grep -q '"data-root": "/data/docker"' /etc/docker/daemon.json 2>/dev/null; then
  sudo systemctl stop docker || true
  echo '{"data-root": "/data/docker"}' | sudo tee /etc/docker/daemon.json
  # v6 live fix: two docker restarts inside one setup run trip systemd's
  # start rate limiter (start-limit-hit) and the second one fails.
  sudo systemctl reset-failed docker.service docker.socket 2>/dev/null || true
  sudo systemctl start docker
fi
sudo systemctl enable docker
sudo docker info 2>&1 | grep -E "Storage Driver|Docker Root Dir"

if ! command -v kind >/dev/null 2>&1; then
  curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.30.0/kind-linux-amd64
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
fi
if ! command -v kubectl >/dev/null 2>&1; then
  KVER=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -Lo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi
# Go, for the S3 build of stargz-snapshotter from main.
if ! /usr/local/go/bin/go version >/dev/null 2>&1; then
  log "installing go ${GO_VER}"
  curl -sSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"
  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz
fi
export PATH=$PATH:/usr/local/go/bin
grep -q '/usr/local/go/bin' ~/.bashrc || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc

sudo apt-get update -qq
sudo apt-get install -y -qq jq git gettext-base fio iperf3 python3 python3-pip sysstat strace fuse3 >/dev/null
sudo sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true

kind --version; kubectl version --client=true 2>/dev/null | head -2; docker --version; /usr/local/go/bin/go version
log "node-host base setup done"
