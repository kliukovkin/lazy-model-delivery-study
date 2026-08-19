#!/usr/bin/env bash
# v3 node-host, Step 6 (timebox 2h): SOCI snapshotter as a second lazy-pulling
# path, for variants A and B (no re-encoding needed -- SOCI builds a separate
# index over the EXISTING gzip image, unlike eStargz's re-encode). Repeats
# measurements 1-3 from step 5 (TTFP cold, sustained read cold, sustained read
# warm) -- NO ENOSPC repeat (stretch goal only).
# If setup blows the timebox, abort and record "attempted-failed-why" -- do
# NOT silently skip without a note (task explicit requirement).
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need docker; need kubectl
SOCI_VER="v0.15.0"
NODE="${CLUSTER_NAME}-control-plane"
SOCI_VARIANTS="${SOCI_VARIANTS:-A B}"
SOCI_SIZES="${SOCI_SIZES:-14}"   # timeboxed -- 14g only unless time remains; override via env

log "installing soci-snapshotter ${SOCI_VER} + soci CLI into ${NODE}"
docker exec "${NODE}" sh -c "
  set -e
  cd /tmp
  curl -sSL -o soci.tar.gz 'https://github.com/awslabs/soci-snapshotter/releases/download/${SOCI_VER}/soci-snapshotter-${SOCI_VER#v}-linux-amd64.tar.gz'
  mkdir -p /tmp/soci-bin
  tar -xzf soci.tar.gz -C /tmp/soci-bin
  install -m 0755 /tmp/soci-bin/soci-snapshotter-grpc /usr/local/bin/
  install -m 0755 /tmp/soci-bin/soci /usr/local/bin/
  soci-snapshotter-grpc --version || true
  soci --version || true
"

log "writing soci config (remote registry ${REG_PRIV}:${REG_PORT}, plain http)"
docker exec "${NODE}" mkdir -p /etc/soci-snapshotter-grpc /run/soci-snapshotter-grpc /var/lib/soci-snapshotter-grpc
docker exec -i "${NODE}" sh -c 'cat > /etc/soci-snapshotter-grpc/config.toml' <<EOF
[[resolver.host."${REG_PRIV}:${REG_PORT}".mirrors]]
  host = "http://${REG_PRIV}:${REG_PORT}"
  insecure = true
EOF
# FIX (live pitfall, v3): unlike stargz-grpc, soci-snapshotter's resolver
# chokes on a bare "host:port" mirror value with a Go url.Parse error
# ("first path segment in URL cannot contain colon"), silently falling back
# to eager unpack (which then fails since the layer was never downloaded) --
# needs an explicit http:// scheme.

log "starting soci-snapshotter-grpc"
docker exec -d "${NODE}" sh -c \
  'soci-snapshotter-grpc --log-level debug --address /run/soci-snapshotter-grpc/soci-snapshotter-grpc.sock --config /etc/soci-snapshotter-grpc/config.toml > /var/log/soci-grpc.log 2>&1'
sleep 3
docker exec "${NODE}" sh -c 'test -S /run/soci-snapshotter-grpc/soci-snapshotter-grpc.sock' \
  || die "soci-grpc socket did not appear -- check /var/log/soci-grpc.log"

log "wiring proxy_plugins.soci + switching default snapshotter stargz->soci"
docker exec "${NODE}" cp /etc/containerd/config.toml /etc/containerd/config.toml.pre-soci
docker exec -i "${NODE}" sh -c 'cat >> /etc/containerd/config.toml' <<'EOF'
  [proxy_plugins.soci]
    address = "/run/soci-snapshotter-grpc/soci-snapshotter-grpc.sock"
    type = "snapshot"
EOF
docker exec "${NODE}" sh -c "sed -i 's/snapshotter = \"stargz\"/snapshotter = \"soci\"/' /etc/containerd/config.toml"
docker exec "${NODE}" grep -n 'snapshotter =' /etc/containerd/config.toml

log "restarting node-internal containerd"
docker exec "${NODE}" systemctl restart containerd
sleep 5
docker exec "${NODE}" ctr version || die "containerd did not come back"
for i in $(seq 1 30); do kubectl get nodes 2>/dev/null | grep -q Ready && break; sleep 2; done
kubectl get nodes

# ---------------------------------------------------------------- build+push SOCI indices for A/B, per size
for size in ${SOCI_SIZES}; do
  tag="${size}g"
  for variant in ${SOCI_VARIANTS}; do
    img="${MODEL_IMG_PREFIX}:${variant}-${tag}"
    log "building SOCI index for ${img}"
    docker exec "${NODE}" sh -c "
      set -ex
      ctr-remote content fetch --plain-http ${img} || true
      soci --address /run/containerd/containerd.sock create ${img} --platform linux/amd64 || soci create ${img} --platform linux/amd64
      soci --address /run/containerd/containerd.sock push --plain-http ${img} || soci push --plain-http ${img}
    " 2>&1 | tee -a "${RESULTS_DIR}/soci-index-build.log" || log "WARN: soci index build failed for ${img} -- see soci-index-build.log"
  done
done

log "SOCI setup done. Next: run TTFP/sustained-read reps for scheme=soci (reuse 04/06 run_one-style logic, scheme label 'soci')."
