#!/usr/bin/env bash
# spike-v4 node-host bootstrap. Identical disk topology to v3.1 (this is the
# "как тогда" requirement): /dev/nvme1n1 partitioned into p1 (~1.7TB -> /data,
# containerd/docker roots) and p2 (100GB nominal -> ~92GB usable ext4 ->
# /cache-part), a REAL block device for the stargz chunk cache.
# Added vs v3.1: a Go toolchain, needed to build stargz-snapshotter from main for S3.
set -euo pipefail
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
GO_VER="${GO_VER:-1.24.7}"

if [ ! -b /dev/nvme1n1p1 ]; then
  log "partitioning /dev/nvme1n1: p1 (rest) + p2 (100GB nominal)"
  # v3.1 live fix: parted's option parser chokes on the leading "-100GB"
  # negative offset unless "--" stops option parsing first.
  sudo parted -s /dev/nvme1n1 mklabel gpt
  sudo parted -s /dev/nvme1n1 -- mkpart primary ext4 0% -100GB
  sudo parted -s /dev/nvme1n1 -- mkpart primary ext4 -100GB 100%
  sleep 2; sudo partprobe /dev/nvme1n1; sleep 2
fi
if ! mountpoint -q /data; then
  sudo mkfs.ext4 -F /dev/nvme1n1p1; sudo mkdir -p /data
  sudo mount /dev/nvme1n1p1 /data; sudo chown ubuntu:ubuntu /data
fi
if ! mountpoint -q /cache-part; then
  sudo mkfs.ext4 -F /dev/nvme1n1p2; sudo mkdir -p /cache-part
  sudo mount /dev/nvme1n1p2 /cache-part; sudo chown ubuntu:ubuntu /cache-part
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
  sudo systemctl start containerd; sleep 2; sudo systemctl start docker; sleep 2
fi
sudo mkdir -p /data/docker
if ! grep -q '"data-root": "/data/docker"' /etc/docker/daemon.json 2>/dev/null; then
  sudo systemctl stop docker || true
  echo '{"data-root": "/data/docker"}' | sudo tee /etc/docker/daemon.json
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
