#!/usr/bin/env bash
# spike-v4 node-host: kind cluster (ImageVolume feature gate) wired to the REMOTE
# registry on REG_PRIV:5000. No KServe (see env.sh) -- just the bench namespace
# and a curl-runner, which is all S1-S3 need.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
need docker; need kind; need kubectl; need jq

log "checking remote registry reachability: http://${REG_PRIV}:${REG_PORT}/v2/_catalog"
curl -sf "http://${REG_PRIV}:${REG_PORT}/v2/_catalog" || die "registry not reachable from node-host"

if ! grep -q "${REG_PRIV}:${REG_PORT}" /etc/docker/daemon.json 2>/dev/null; then
  log "adding insecure-registries entry for ${REG_PRIV}:${REG_PORT}"
  sudo python3 -c "
import json; p='/etc/docker/daemon.json'; d=json.load(open(p))
d.setdefault('insecure-registries', [])
if '${REG_PRIV}:${REG_PORT}' not in d['insecure-registries']: d['insecure-registries'].append('${REG_PRIV}:${REG_PORT}')
json.dump(d, open(p,'w'))"
  sudo systemctl restart docker; sleep 3
fi

mountpoint -q "${STARGZ_CACHE_MOUNT}" || die "${STARGZ_CACHE_MOUNT} not mounted -- run 00-node-host-setup.sh first"
df -h "${STARGZ_CACHE_MOUNT}"

if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  log "creating kind cluster ${CLUSTER_NAME} (${KIND_NODE_IMAGE})"
  # EVICTION_MODE controls kubelet's eviction thresholds.
  #   kind-default : leave kind's own settings, which pin evictionHard to
  #                  imagefs.available=0% / nodefs.available=0% and
  #                  imageGCHighThresholdPercent=100 -- i.e. eviction effectively
  #                  DISABLED. This is what v4 run 1 measured, and it is why run 1
  #                  could not interpret DiskPressure=False.
  #   realistic    : production-like thresholds, so S4 can ask whether the imageFs
  #                  visibility that PR #1893 provides actually causes kubelet to act.
  EVICTION_PATCH=""
  if [ "${EVICTION_MODE:-realistic}" = "realistic" ]; then
    EVICTION_PATCH=$(cat <<'EOP'
kubeadmConfigPatches:
- |
  kind: KubeletConfiguration
  evictionHard:
    imagefs.available: "10%"
    nodefs.available: "10%"
    memory.available: "100Mi"
  evictionPressureTransitionPeriod: "30s"
  imageGCHighThresholdPercent: 85
  imageGCLowThresholdPercent: 80
EOP
)
  fi
  log "EVICTION_MODE=${EVICTION_MODE:-realistic}"
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  ImageVolume: true
${EVICTION_PATCH}
nodes:
- role: control-plane
  extraMounts:
  - hostPath: ${STARGZ_CACHE_MOUNT}
    containerPath: ${STARGZ_ROOT_IN_NODE}
containerdConfigPatches:
- |-
  [plugins."io.containerd.cri.v1.images".registry]
    config_path = "/etc/containerd/certs.d"
  [plugins."io.containerd.cri.v1.images"]
    max_concurrent_downloads = ${MAX_CONCURRENT_DOWNLOADS}
EOF
fi

REGISTRY_DIR="/etc/containerd/certs.d/${REG_PRIV}:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
server = "http://${REG_PRIV}:${REG_PORT}"
[host."http://${REG_PRIV}:${REG_PORT}"]
  capabilities = ["pull", "resolve"]
EOF
done

CTRD_VER=$(docker exec "${CLUSTER_NAME}-control-plane" containerd --version | awk '{print $3}' | sed 's/^v//')
log "node containerd: ${CTRD_VER}"
case "${CTRD_VER}" in 0.*|1.*|2.0*|2.1*) die "containerd ${CTRD_VER} lacks ImageVolume subPath support (need >=2.2)";; esac

kubectl create namespace "${TEST_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${TEST_NS}" apply -f - <<EOF
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
kubectl -n "${TEST_NS}" rollout status deployment/curl-runner --timeout=180s
kubectl -n "${TEST_NS}" exec deploy/curl-runner -- curl -sf "http://${REG_PRIV}:${REG_PORT}/v2/_catalog" \
  || die "registry NOT reachable from pod -- check SG/NAT"
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
log "effective kubelet eviction settings:"
kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/configz" \
  | python3 -c 'import json,sys; k=json.load(sys.stdin)["kubeletconfig"]; print({x:k.get(x) for x in ("evictionHard","evictionPressureTransitionPeriod","imageGCHighThresholdPercent","imageGCLowThresholdPercent")})'
log "cluster up. Next: 05-setup-stargz.sh"
