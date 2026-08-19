#!/usr/bin/env bash
# v3 registry-host bootstrap: NVMe mount, docker (data-root on NVMe), OCI
# registry:2, MinIO, ctr-remote (stargz) for eStargz conversion, iperf3 server.
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

# ---------------------------------------------------------------- docker (official install script, gives buildx plugin)
if ! command -v docker >/dev/null 2>&1; then
  log "installing docker"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker ubuntu
fi

sudo mkdir -p /data/docker
if [ ! -f /etc/docker/daemon.json ] || ! grep -q '"data-root": "/data/docker"' /etc/docker/daemon.json 2>/dev/null; then
  log "relocating docker data-root to /data/docker"
  sudo systemctl stop docker || true
  echo '{"data-root": "/data/docker", "insecure-registries": ["localhost:5000", "127.0.0.1:5000"]}' | sudo tee /etc/docker/daemon.json
  sudo systemctl start docker
fi
sudo systemctl enable docker
sudo docker info >/dev/null && log "docker ok"

# ---------------------------------------------------------------- registry:2
sudo mkdir -p /data/registry
if [ "$(sudo docker inspect -f '{{.State.Running}}' registry 2>/dev/null || true)" != 'true' ]; then
  log "starting registry:2 on 0.0.0.0:5000"
  sudo docker rm -f registry >/dev/null 2>&1 || true
  sudo docker run -d --restart=always -p 0.0.0.0:5000:5000 \
    -v /data/registry:/var/lib/registry --name registry registry:2
fi

# ---------------------------------------------------------------- MinIO
sudo mkdir -p /data/minio
if [ "$(sudo docker inspect -f '{{.State.Running}}' minio 2>/dev/null || true)" != 'true' ]; then
  log "starting MinIO on :9000/:9001"
  sudo docker rm -f minio >/dev/null 2>&1 || true
  sudo docker run -d --restart=always -p 0.0.0.0:9000:9000 -p 0.0.0.0:9001:9001 \
    -v /data/minio:/data \
    -e MINIO_ROOT_USER=benchadmin -e MINIO_ROOT_PASSWORD=benchadmin123 \
    --name minio minio/minio:RELEASE.2025-09-07T16-13-09Z server /data --console-address ":9001"
fi

# ---------------------------------------------------------------- ctr-remote (stargz) for image convert
STARGZ_VER="v0.18.2"
if ! command -v ctr-remote >/dev/null 2>&1; then
  log "installing ctr-remote ${STARGZ_VER}"
  cd /tmp
  curl -sSL -o stargz.tar.gz "https://github.com/containerd/stargz-snapshotter/releases/download/${STARGZ_VER}/stargz-snapshotter-${STARGZ_VER}-linux-amd64.tar.gz"
  mkdir -p /tmp/stargz-bin
  tar -xzf stargz.tar.gz -C /tmp/stargz-bin
  sudo install -m 0755 /tmp/stargz-bin/ctr-remote /usr/local/bin/
  sudo install -m 0755 /tmp/stargz-bin/containerd-stargz-grpc /usr/local/bin/ || true
fi
ctr-remote --version

# ctr-remote talks to the docker-bundled containerd socket (installed by get.docker.com as containerd.io)
sudo test -S /run/containerd/containerd.sock && log "containerd socket present"

# ---------------------------------------------------------------- iperf3 server
sudo apt-get update -qq
sudo apt-get install -y -qq iperf3 jq git python3 python3-pip fio >/dev/null
if ! pgrep -f "iperf3 -s" >/dev/null; then
  log "starting iperf3 -s daemon"
  iperf3 -s -D
fi

log "registry-host base setup done"
