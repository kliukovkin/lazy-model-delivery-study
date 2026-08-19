#!/usr/bin/env bash
# v3.1 registry-host bootstrap. Differences from v3's 00-registry-host-setup.sh:
#   - containerd root relocated to /data/containerd BEFORE any image
#     activity (proactive version of v3 pitfall #1).
#   - registry:2 run with an explicit json-file log driver + generous
#     max-size, so `docker logs registry` reliably retains the FULL access
#     log for the whole run (each blob GET/Range request is its own line,
#     with response size + status + duration -- this is the "access-log for
#     a range-request histogram" the v3.1 task asks for; distribution's
#     registry logs this by default at info level, no special config
#     needed beyond making sure the log driver doesn't truncate it).
#   - sysstat (sar, pidstat) installed for P0.6 sampling.
#   - loginctl enable-linger set immediately.
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

# ---------------------------------------------------------------- linger
sudo loginctl enable-linger ubuntu

# ---------------------------------------------------------------- docker + containerd root relocation (proactive)
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
  echo '{"data-root": "/data/docker", "insecure-registries": ["localhost:5000", "127.0.0.1:5000"]}' | sudo tee /etc/docker/daemon.json
  sudo systemctl start docker
fi
sudo systemctl enable docker
sudo docker info >/dev/null && log "docker ok"
sudo docker info 2>&1 | grep -E "Storage Driver|Docker Root Dir"

# ---------------------------------------------------------------- registry:2 (with retained access log)
sudo mkdir -p /data/registry
if [ "$(sudo docker inspect -f '{{.State.Running}}' registry 2>/dev/null || true)" != 'true' ]; then
  log "starting registry:2 on 0.0.0.0:5000 (json-file log, max-size=1g, retained for the whole run)"
  sudo docker rm -f registry >/dev/null 2>&1 || true
  sudo docker run -d --restart=always -p 0.0.0.0:5000:5000 \
    --log-driver json-file --log-opt max-size=1g --log-opt max-file=5 \
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
sudo test -S /run/containerd/containerd.sock && log "containerd socket present"

# ---------------------------------------------------------------- iperf3 server + sysstat
sudo apt-get update -qq
sudo apt-get install -y -qq iperf3 jq git python3 python3-pip fio sysstat strace >/dev/null
sudo sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
if ! pgrep -f "iperf3 -s" >/dev/null; then
  log "starting iperf3 -s daemon"
  iperf3 -s -D
fi

log "registry-host base setup done"
