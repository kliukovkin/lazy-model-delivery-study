#!/usr/bin/env bash
# v3.1 P0.3 setup: capture the "identity bundle" -- exact versions/configs at
# rest, before any experiment runs, so a reviewer's "what exactly did your
# probe check?" is answerable after the hardware is gone.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"

OUT="${RESULTS_DIR}/identity-bundle"
mkdir -p "${OUT}"
NODE="${CLUSTER_NAME}-control-plane"

log "capturing stargz-grpc config.toml + actual running cmdline"
docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml > "${OUT}/stargz-grpc-config.toml"
docker exec "${NODE}" ps aux | grep containerd-stargz-grpc | grep -v grep > "${OUT}/stargz-grpc-ps.txt" || true

log "capturing containerd config dump"
docker exec "${NODE}" containerd config dump > "${OUT}/containerd-config-dump.toml" 2>&1 || true
docker exec "${NODE}" cat /etc/containerd/config.toml > "${OUT}/containerd-config-toml-raw.toml"

log "capturing kind config + versions"
kind get kubeconfig --name "${CLUSTER_NAME}" > "${OUT}/kubeconfig-copy.yaml" 2>&1 || true
{
  echo "kind: $(kind --version)"
  echo "kubectl client: $(kubectl version --client=true --output=yaml 2>&1 | head -5)"
  echo "helm: $(helm version)"
  echo "docker: $(docker --version)"
  docker exec "${NODE}" containerd --version
  docker exec "${NODE}" ctr version 2>&1 | head -10
  docker exec "${NODE}" sh -c 'containerd-stargz-grpc --version; ctr-remote --version' 2>&1
} > "${OUT}/versions.txt"

log "capturing kubelet configz"
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/configz" > "${OUT}/kubelet-configz.json" 2>&1 || log "WARN: kubelet configz fetch failed"

log "capturing all model-ballast image digests + manifests"
{
  for tag in $(curl -s "http://${REG_PRIV}:${REG_PORT}/v2/model-ballast/tags/list" | python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin)['tags']))"); do
    echo "=== ${tag} ==="
    curl -s "http://${REG_PRIV}:${REG_PORT}/v2/model-ballast/manifests/${tag}" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json"
    echo
  done
} > "${OUT}/model-ballast-manifests.txt"

log "capturing kind cluster config (from docker inspect, since kind doesn't expose the applied config directly)"
docker inspect "${NODE}" > "${OUT}/kind-node-docker-inspect.json"

log "capturing node disk layout"
{
  lsblk
  echo "---"
  df -h
  echo "--- stargz cache partition ---"
  df -h "${STARGZ_CACHE_MOUNT}"
} > "${OUT}/disk-layout.txt"

log "identity bundle captured -> ${OUT}"
ls -la "${OUT}"
