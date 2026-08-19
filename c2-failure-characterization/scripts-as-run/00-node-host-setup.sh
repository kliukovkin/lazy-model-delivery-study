#!/usr/bin/env bash
# v3.1 node-host bootstrap. Differences from v3's 00-node-host-setup.sh:
#   - nvme1n1 is PARTITIONED (not one big fs): p1 (~1.7TB) -> /data,
#     p2 (100GB, ext4) -> /cache-part, a REAL block device for the stargz
#     chunk cache (red-team pushback on v3's loopback file: "you hid the fs
#     from kubelet by hand" -- a real partition is visible the same way any
#     other disk would be in production).
#   - containerd root relocated to /data/containerd BEFORE any image
#     activity (v3 pitfall #1: docker 29.x's containerd-snapshotter feature
#     writes through the *system* containerd, whose root defaults to
#     /var/lib/containerd on the 30GB boot disk regardless of docker's own
#     data-root -- filled the root disk mid-build last time; fixing this
#     up-front instead of after an ENOSPC crash this round).
#   - sysstat (sar, pidstat) installed for P0.6/P0.3 sampling.
#   - loginctl enable-linger set immediately (v3 pitfall #6: Ubuntu's
#     KillUserProcesses=yes silently kills nohup+disown'd background jobs
#     when the launching SSH session closes).
set -euo pipefail

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------- partition nvme1n1: p1 (/data) + p2 (100GB cache-part)
if [ ! -b /dev/nvme1n1p1 ]; then
  log "partitioning /dev/nvme1n1: p1 (rest) + p2 (100GB)"
  # FIX (live pitfall, v3.1): parted's own option parser chokes on a
  # leading "-100GB" negative-offset argument ("invalid option -- '1'")
  # unless "--" tells it to stop parsing options first.
  sudo parted -s /dev/nvme1n1 mklabel gpt
  sudo parted -s /dev/nvme1n1 -- mkpart primary ext4 0% -100GB
  sudo parted -s /dev/nvme1n1 -- mkpart primary ext4 -100GB 100%
  sleep 2
  sudo partprobe /dev/nvme1n1
  sleep 2
fi
if ! mountpoint -q /data; then
  sudo mkfs.ext4 -F /dev/nvme1n1p1
  sudo mkdir -p /data
  sudo mount /dev/nvme1n1p1 /data
  sudo chown ubuntu:ubuntu /data
fi
if ! mountpoint -q /cache-part; then
  sudo mkfs.ext4 -F /dev/nvme1n1p2
  sudo mkdir -p /cache-part
  sudo mount /dev/nvme1n1p2 /cache-part
  sudo chown ubuntu:ubuntu /cache-part
fi
df -h /data /cache-part

# ---------------------------------------------------------------- linger (survive SSH disconnects for nohup jobs)
sudo loginctl enable-linger ubuntu

# ---------------------------------------------------------------- docker + containerd root relocation (proactive, before any real use)
if ! command -v docker >/dev/null 2>&1; then
  log "installing docker"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker ubuntu
fi

if ! grep -q 'root = "/data/containerd"' /etc/containerd/config.toml 2>/dev/null; then
  log "relocating system containerd root to /data/containerd (proactive fix)"
  sudo systemctl stop docker containerd || true
  sudo rm -rf /var/lib/containerd/*
  sudo mkdir -p /data/containerd
  printf 'version = 2\ndisabled_plugins = ["io.containerd.grpc.v1.cri"]\nroot = "/data/containerd"\nstate = "/run/containerd"\n' | sudo tee /etc/containerd/config.toml
  sudo systemctl start containerd
  sleep 2
  sudo systemctl start docker
  sleep 2
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
sudo docker info 2>&1 | grep -E "Storage Driver|Docker Root Dir"

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
sudo apt-get install -y -qq jq git gettext-base fio iperf3 python3 python3-pip sysstat strace >/dev/null
# enable sysstat data collection service (some distros ship it disabled by default)
sudo sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true

# ---------------------------------------------------------------- kserve source tree on fast disk
mkdir -p /data/kserve-src

kind --version; kubectl version --client=true; helm version; docker --version; sar -V 2>&1 | head -1
log "node-host base setup done"
