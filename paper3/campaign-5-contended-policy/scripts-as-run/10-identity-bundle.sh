#!/usr/bin/env bash
# spike-v4: identity bundle -- exact versions/configs at rest, so "what exactly
# did you measure?" is answerable after the hardware is gone.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
OUT="${RESULTS_DIR}/identity-bundle"; mkdir -p "${OUT}"
NODE="$(NODE_CTR)"
SUFFIX="${1:-}"
docker exec "${NODE}" cat /etc/containerd-stargz-grpc/config.toml            > "${OUT}/stargz-grpc-config${SUFFIX}.toml"
docker exec "${NODE}" cat /etc/systemd/system/stargz-snapshotter.service     > "${OUT}/stargz-snapshotter.service${SUFFIX}"
docker exec "${NODE}" sh -c 'cat /etc/systemd/system/stargz-snapshotter.service.d/*.conf 2>/dev/null || echo "(no drop-ins)"' > "${OUT}/stargz-unit-dropins${SUFFIX}.txt"
docker exec "${NODE}" systemctl show stargz-snapshotter -p KillMode -p Restart -p Type > "${OUT}/stargz-unit-effective${SUFFIX}.txt"
docker exec "${NODE}" cat /etc/containerd/config.toml                        > "${OUT}/containerd-config-raw${SUFFIX}.toml"
docker exec "${NODE}" containerd config dump                                 > "${OUT}/containerd-config-dump${SUFFIX}.toml" 2>&1 || true
docker exec "${NODE}" sh -c 'ps aux | grep -E "stargz" | grep -v grep'       > "${OUT}/stargz-ps${SUFFIX}.txt" 2>&1 || true
{ echo "kind: $(kind --version)"; docker --version
  docker exec "${NODE}" containerd --version
  docker exec "${NODE}" sh -c 'containerd-stargz-grpc --version; ctr-remote --version'
  kubectl version 2>/dev/null | head -5
} > "${OUT}/versions${SUFFIX}.txt" 2>&1
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw "/api/v1/nodes/${NODE_NAME}/proxy/configz" > "${OUT}/kubelet-configz${SUFFIX}.json" 2>&1 || true
{ for tag in $(curl -s "http://${REG_PRIV}:${REG_PORT}/v2/model-ballast/tags/list" | python3 -c "import json,sys;print('\n'.join(json.load(sys.stdin)['tags']))" 2>/dev/null); do
    echo "=== ${tag} ==="
    curl -s -D - -o /tmp/m.json "http://${REG_PRIV}:${REG_PORT}/v2/model-ballast/manifests/${tag}" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json" | grep -i docker-content-digest
    python3 -m json.tool < /tmp/m.json 2>/dev/null | head -40
  done; } > "${OUT}/model-ballast-manifests${SUFFIX}.txt" 2>&1
{ lsblk; echo "---"; df -h; echo "--- cache partition ---"; df -h "${STARGZ_CACHE_MOUNT}"
  echo "--- inside node ---"; docker exec "${NODE}" df -h "${STARGZ_ROOT_IN_NODE}"
  echo "--- root layout ---"; docker exec "${NODE}" sh -c "ls -la ${STARGZ_ROOT_IN_NODE}; ls -la ${STARGZ_ROOT_IN_NODE}/stargz 2>/dev/null"
} > "${OUT}/disk-layout${SUFFIX}.txt" 2>&1
echo "identity bundle -> ${OUT}"; ls -la "${OUT}"
