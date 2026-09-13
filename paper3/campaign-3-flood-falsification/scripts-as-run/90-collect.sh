#!/usr/bin/env bash
# spike-v6: bundle every result on the node-host into one tarball for retrieval
# BEFORE the instances are terminated.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$(dirname "$0")/lib.sh"
NODE="$(NODE_CTR)"
docker exec "${NODE}" journalctl -u stargz-snapshotter --no-pager > "${RESULTS_DIR}/final-journal-stargz.txt" 2>&1 || true
docker exec "${NODE}" journalctl -u containerd --no-pager | tail -5000 > "${RESULTS_DIR}/final-journal-containerd.txt" 2>&1 || true
docker exec "${NODE}" sh -c "cat ${STARGZ_ROOT_IN_NODE}/stargz-fuse-manager.log 2>/dev/null" > "${RESULTS_DIR}/final-fuse-manager.log" 2>&1 || true
kubectl get events -A --sort-by=.lastTimestamp > "${RESULTS_DIR}/final-all-events.txt" 2>&1 || true
# v6: the identity bundle needs a config to read, so it is collected here rather
# than before the experiments (it failed at that point in v5's order too).
bash "$(dirname "$0")/10-identity-bundle.sh" > "${RESULTS_DIR}/identity-bundle.log" 2>&1 || true
mkdir -p "${RESULTS_DIR}/identity-bundle"
for d in /data/stargz-bin /data/stargz-bin-ours /data/stargz-bin-prefix; do
  n=$(basename "${d}")
  cp "${d}/PROVENANCE.txt"  "${RESULTS_DIR}/identity-bundle/${n}-PROVENANCE.txt"  2>/dev/null || true
  cp "${d}/SHA256SUMS.txt"  "${RESULTS_DIR}/identity-bundle/${n}-SHA256SUMS.txt"  2>/dev/null || true
  cp "${d}/TARBALL-SHA256.txt" "${RESULTS_DIR}/identity-bundle/${n}-TARBALL-SHA256.txt" 2>/dev/null || true
done
{ echo "kind=$(kind version 2>/dev/null)"
  echo "kubectl=$(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null)"
  echo "k8s_server=$(kubectl version -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null)"
  echo "containerd_in_node=$(docker exec "${NODE}" containerd --version 2>/dev/null)"
  echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  echo "go=$(/usr/local/go/bin/go version 2>/dev/null)"
  echo "kernel=$(uname -r)"
  echo "node_image=${KIND_NODE_IMAGE}"
  echo "cache_part=${STARGZ_CACHE_PART} mount=${STARGZ_CACHE_MOUNT}"
  echo "partition_bytes=$(df -B1 --output=size "${STARGZ_CACHE_MOUNT}" | tail -1 | tr -d ' ')"
  echo "kubelet_eviction=$(kubelet_eviction_thresholds)"
  echo "collected_utc=$(date -u +%FT%TZ)"; } > "${RESULTS_DIR}/identity-bundle/environment.txt"
cat "${RESULTS_DIR}/identity-bundle/environment.txt"

tar -czf /data/v6-results.tar.gz -C "$(dirname "${RESULTS_DIR}")" "$(basename "${RESULTS_DIR}")"
ls -lh /data/v6-results.tar.gz
