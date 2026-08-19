# shellcheck shell=bash
# Central config for the v3 two-host OCI model-delivery benchmark harness.
# Source from every node-host script: . "$(dirname "$0")/env.sh"

export REG_PRIV="${REG_PRIV:-172.31.46.168}"
export REG_PUB="${REG_PUB:-REPLACE_WITH_REGISTRY_PUBLIC_IP}"
export NODE_PRIV="${NODE_PRIV:-172.31.44.56}"
export REG_PORT="${REG_PORT:-5000}"

export CLUSTER_NAME="${CLUSTER_NAME:-ocibench}"
export KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.36.1}"
export KSERVE_NS="${KSERVE_NS:-kserve}"
export TEST_NS="${TEST_NS:-bench}"
export MAX_CONCURRENT_DOWNLOADS="${MAX_CONCURRENT_DOWNLOADS:-8}"

export KSERVE_REPO="${KSERVE_REPO:-https://github.com/kserve/kserve.git}"
export KSERVE_REF="${KSERVE_REF:-master}"
export KSERVE_SRC="${KSERVE_SRC:-/data/kserve-src}"

export MINIO_USER="${MINIO_USER:-benchadmin}"
export MINIO_PASS="${MINIO_PASS:-benchadmin123}"
export MINIO_BUCKET="${MINIO_BUCKET:-models}"

export SIZES_GB="${SIZES_GB:-2 14 140}"
export REPS="${REPS:-5}"
export REPS_LARGE="${REPS_LARGE:-3}"
export VARIANTS="${VARIANTS:-A B D}"

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCH_ROOT
export RESULTS_DIR="${RESULTS_DIR:-${BENCH_ROOT}/results}"
export CSV="${CSV:-${RESULTS_DIR}/matrix.csv}"
export MODEL_IMG_PREFIX="${REG_PRIV}:${REG_PORT}/model-ballast"

# stargz chunk-cache loopback (Step 2 item 3 / Step 5 ENOSPC control)
export STARGZ_CACHE_LOOPBACK_FILE="${STARGZ_CACHE_LOOPBACK_FILE:-/data/stargz-cache.img}"
export STARGZ_CACHE_LOOPBACK_SIZE_GB="${STARGZ_CACHE_LOOPBACK_SIZE_GB:-100}"
export STARGZ_CACHE_MOUNT="${STARGZ_CACHE_MOUNT:-/data/stargz-cache}"

mkdir -p "${RESULTS_DIR}"
