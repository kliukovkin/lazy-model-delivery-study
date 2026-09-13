#!/usr/bin/env bash
# spike-v4 registry-host bootstrap. Descended from v3.1's 00-registry-host-setup.sh.
# Differences from v3.1:
#   - MinIO dropped: v4 has no S3/eager control arm, nothing reads it.
#   - Same proactive containerd-root relocation to /data (v3 pitfall #1).
#   - Same retained registry access log (json-file, max-size=1g).
set -euo pipefail
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
STARGZ_VER="${STARGZ_VER:-v0.18.2}"

if ! mountpoint -q /data; then
  log "formatting+mounting /dev/nvme1n1 -> /data"
  sudo mkfs.ext4 -F /dev/nvme1n1
  sudo mkdir -p /data && sudo mount /dev/nvme1n1 /data && sudo chown ubuntu:ubuntu /data
fi
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
