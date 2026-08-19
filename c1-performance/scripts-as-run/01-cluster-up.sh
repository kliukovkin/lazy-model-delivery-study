#!/usr/bin/env bash
# v3 node-host: kind cluster (ImageVolume) wired to the REMOTE registry
# (REG_PRIV:5000, plain HTTP) + KServe (master) from source, RawDeployment.
# Registry and MinIO both live on the OTHER host -- no local registry/MinIO here.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

need docker; need kind; need kubectl; need helm; need git; need jq

# ---------------------------------------------------------------- reachability check FIRST (task step 2.1)
log "checking remote registry reachability from node-host: http://${REG_PRIV}:${REG_PORT}/v2/_catalog"
curl -sf "http://${REG_PRIV}:${REG_PORT}/v2/_catalog" || die "registry not reachable from node-host"
log "registry reachable: $(curl -s http://${REG_PRIV}:${REG_PORT}/v2/_catalog)"

# ---------------------------------------------------------------- docker: allow push to remote insecure registry
if ! grep -q "${REG_PRIV}:${REG_PORT}" /etc/docker/daemon.json 2>/dev/null; then
  log "adding insecure-registries entry for ${REG_PRIV}:${REG_PORT} to docker daemon.json"
  sudo python3 -c "
import json
p='/etc/docker/daemon.json'
d=json.load(open(p))
d.setdefault('insecure-registries', [])
if '${REG_PRIV}:${REG_PORT}' not in d['insecure-registries']:
    d['insecure-registries'].append('${REG_PRIV}:${REG_PORT}')
json.dump(d, open(p,'w'))
"
  sudo systemctl restart docker
  sleep 3
fi

# ---------------------------------------------------------------- stargz chunk-cache loopback (task step 2.3)
# MUST be created+mounted BEFORE `kind create cluster` and bind-mounted in via
# extraMounts, otherwise the kind node container has no visibility into a
# dedicated bounded filesystem for the controlled ENOSPC experiment (step 5.4)
# -- it would just fall through to the node-host's general /data/docker
# overlay storage, same as everything else, and the "100GB < image" ENOSPC
# control would not actually be size-bounded.
if [ ! -f "${STARGZ_CACHE_LOOPBACK_FILE}" ]; then
  log "creating ${STARGZ_CACHE_LOOPBACK_SIZE_GB}GB loopback for stargz chunk-cache (controlled ENOSPC experiment)"
  sudo fallocate -l "${STARGZ_CACHE_LOOPBACK_SIZE_GB}G" "${STARGZ_CACHE_LOOPBACK_FILE}"
  sudo mkfs.ext4 -F "${STARGZ_CACHE_LOOPBACK_FILE}"
  sudo mkdir -p "${STARGZ_CACHE_MOUNT}"
  sudo mount -o loop "${STARGZ_CACHE_LOOPBACK_FILE}" "${STARGZ_CACHE_MOUNT}"
  sudo chown ubuntu:ubuntu "${STARGZ_CACHE_MOUNT}"
fi
df -h "${STARGZ_CACHE_MOUNT}"

# ---------------------------------------------------------------- kind cluster
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  log "creating kind cluster ${CLUSTER_NAME} (${KIND_NODE_IMAGE})"
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  ImageVolume: true
nodes:
- role: control-plane
  extraMounts:
  - hostPath: ${STARGZ_CACHE_MOUNT}
    containerPath: /var/lib/containerd-stargz-grpc
containerdConfigPatches:
- |-
  [plugins."io.containerd.cri.v1.images".registry]
    config_path = "/etc/containerd/certs.d"
  [plugins."io.containerd.cri.v1.images"]
    max_concurrent_downloads = ${MAX_CONCURRENT_DOWNLOADS}
EOF
fi

# ---------------------------------------------------------------- remote-registry hosts.toml (task step 2.1: REG_PRIV, NOT localhost)
REGISTRY_DIR="/etc/containerd/certs.d/${REG_PRIV}:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
server = "http://${REG_PRIV}:${REG_PORT}"
[host."http://${REG_PRIV}:${REG_PORT}"]
  capabilities = ["pull", "resolve"]
EOF
done

# ---------------------------------------------------------------- preflight: runtime supports ImageVolume+subPath
CTRD_VER=$(docker exec "${CLUSTER_NAME}-control-plane" containerd --version | awk '{print $3}' | sed 's/^v//')
log "node containerd: ${CTRD_VER}"
case "${CTRD_VER}" in
  0.*|1.*|2.0*|2.1*) die "containerd ${CTRD_VER} lacks ImageVolume subPath support (need >=2.2)";;
esac
log "max_concurrent_downloads in generated config: $(docker exec "${CLUSTER_NAME}-control-plane" grep -A2 'io.containerd.cri.v1.images"\]' /etc/containerd/config.toml | grep max_concurrent_downloads || echo 'NOT FOUND')"

# ---------------------------------------------------------------- verify pull from node's containerd works BEFORE going further
log "verifying node containerd can resolve+pull from remote registry"
docker exec "${CLUSTER_NAME}-control-plane" crictl pull "${REG_PRIV}:${REG_PORT}/model-ballast:B-2g" 2>&1 | tail -5 || log "WARN: verification pull failed (image may not be pushed yet -- retry once registry-host finishes 2g build)"

# ---------------------------------------------------------------- build KServe images from source
if [ ! -d "${KSERVE_SRC}/.git" ]; then
  log "cloning kserve @ ${KSERVE_REF}"
  git clone --depth 1 --branch "${KSERVE_REF}" "${KSERVE_REPO}" "${KSERVE_SRC}"
fi
GIT_SHA=$(git -C "${KSERVE_SRC}" rev-parse --short HEAD)
log "kserve source at ${GIT_SHA}"
echo "${GIT_SHA}" > "${RESULTS_DIR}/kserve-git-sha.txt"

( cd "${KSERVE_SRC}" && \
  KO_DOCKER_REPO="${REG_PRIV}:${REG_PORT}" make docker-build && \
  KO_DOCKER_REPO="${REG_PRIV}:${REG_PORT}" make docker-build-storageInitializer )
CONTROLLER_IMG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${REG_PRIV}:${REG_PORT}/kserve-controller" | head -1)
STORAGE_INIT_IMG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${REG_PRIV}:${REG_PORT}/storage-initializer" | head -1)
[ -n "${CONTROLLER_IMG}" ] || die "controller image not found after make docker-build"
[ -n "${STORAGE_INIT_IMG}" ] || die "storage-initializer image not found"
docker push "${CONTROLLER_IMG}"
docker push "${STORAGE_INIT_IMG}"
log "controller=${CONTROLLER_IMG} storage-initializer=${STORAGE_INIT_IMG}"

# ---------------------------------------------------------------- install KServe (standard/raw mode)
"${KSERVE_SRC}/hack/setup/quick-install/kserve-standard-mode-full-install-helm.sh"

kubectl -n "${KSERVE_NS}" set image deployment/kserve-controller-manager "manager=${CONTROLLER_IMG}"
CONFIG_PATCH=$(jq -cn --arg img "${STORAGE_INIT_IMG}" '{
  "storageInitializer": ("{\"image\": \"" + $img + "\", \"memoryRequest\": \"100Mi\", \"memoryLimit\": \"4Gi\", \"cpuRequest\": \"100m\", \"cpuLimit\": \"1\", \"enableOciModelSupport\": true, \"ociModelMode\": \"modelcar\", \"uidModelcar\": 10}")
}')
kubectl -n "${KSERVE_NS}" patch configmap inferenceservice-config --type merge -p "{\"data\": ${CONFIG_PATCH}}"
kubectl -n "${KSERVE_NS}" rollout restart deployment/kserve-controller-manager
kubectl -n "${KSERVE_NS}" rollout status deployment/kserve-controller-manager --timeout=300s

# ---------------------------------------------------------------- bench namespace + REMOTE s3 (MinIO on registry-host) credentials + curl runner
kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${TEST_NS}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-s3-secret
  annotations:
    serving.kserve.io/s3-endpoint: "${REG_PRIV}:9000"
    serving.kserve.io/s3-usehttps: "0"
    serving.kserve.io/s3-region: "us-east-1"
    serving.kserve.io/s3-useanoncredential: "false"
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "${MINIO_USER}"
  AWS_SECRET_ACCESS_KEY: "${MINIO_PASS}"
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bench-s3-sa
secrets:
- name: minio-s3-secret
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: curl-runner
spec:
  replicas: 1
  selector: { matchLabels: { app: curl-runner } }
  template:
    metadata: { labels: { app: curl-runner } }
    spec:
      containers:
      - name: curl
        image: curlimages/curl:8.9.1
        command: ["sleep", "infinity"]
EOF
kubectl -n "${TEST_NS}" rollout status deployment/curl-runner --timeout=120s

# ---------------------------------------------------------------- pod-level reachability check (task step 2.1: "и из тестового пода")
log "checking registry reachability from a test pod"
kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -sf "http://${REG_PRIV}:${REG_PORT}/v2/_catalog" || die "registry NOT reachable from pod -- check SG/NAT"
log "checking MinIO reachability from a test pod"
kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -sf -o /dev/null -w 'minio:%{http_code}\n' "http://${REG_PRIV}:9000/minio/health/live" || die "MinIO NOT reachable from pod"

log "cluster is up. kserve sha: ${GIT_SHA}. Next: 03-calibration.sh"
