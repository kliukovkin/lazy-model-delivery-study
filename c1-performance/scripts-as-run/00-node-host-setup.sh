#!/usr/bin/env bash
# v3 node-host bootstrap: NVMe mount, docker (for `make docker-build`), kind,
# kubectl, helm, misc tooling. kind cluster creation itself happens in
# 01-cluster-up.sh (separate step, needs REG_PRIV).
set -euo pipefail

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------- NVMe /data
if ! mountpoint -q /data; then
  log "formatting+mounting /dev/nvme1n1 -> /data"
  sudo mkfs.ext4 -F /dev/nvme1n1
  sudo mkdir -p /data
  sudo mount /dev/nvme1n1 /data
  sudo chown ubuntu:ubuntu /data
fi
df -h /data

# ---------------------------------------------------------------- docker
if ! command -v docker >/dev/null 2>&1; then
  log "installing docker"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker ubuntu
fi

sudo mkdir -p /data/docker
if [ ! -f /etc/docker/daemon.json ] || ! grep -q '"data-root": "/data/docker"' /etc/docker/daemon.json 2>/dev/null; then
  log "relocating docker data-root to /data/docker"
  sudo systemctl stop docker || true
  echo '{"data-root": "/data/docker"}' | sudo tee /etc/docker/daemon.json
  sudo systemctl start docker
fi
sudo systemctl enable docker
sudo docker info >/dev/null && log "docker ok"

# ---------------------------------------------------------------- kind, kubectl, helm
if ! command -v kind >/dev/null 2>&1; then
  log "installing kind"
  curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.30.0/kind-linux-amd64
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
fi
if ! command -v kubectl >/dev/null 2>&1; then
  log "installing kubectl"
  KVER=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -Lo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi
if ! command -v helm >/dev/null 2>&1; then
  log "installing helm"
  curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh
fi

sudo apt-get update -qq
sudo apt-get install -y -qq jq git gettext-base fio iperf3 python3 python3-pip >/dev/null

# ---------------------------------------------------------------- kserve source tree on fast disk
mkdir -p /data/kserve-src

kind --version; kubectl version --client=true; helm version; docker --version
log "node-host base setup done"
