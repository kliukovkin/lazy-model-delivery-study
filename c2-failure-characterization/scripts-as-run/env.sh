# shellcheck shell=bash
# Central config for the C2 instrumented capture-run harness (two-host,
# real NVMe partition for stargz cache).
# Source from every node-host script: . "$(dirname "$0")/env.sh"

export REG_PRIV="${REG_PRIV:-172.31.67.78}"
export REG_PUB="${REG_PUB:-REPLACE_WITH_REGISTRY_PUBLIC_IP}"
export NODE_PRIV="${NODE_PRIV:-172.31.69.174}"
export NODE_PUB="${NODE_PUB:-REPLACE_WITH_NODE_PUBLIC_IP}"
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

# stargz chunk-cache on a REAL NVMe partition (v3.1: red-team pushback on v3's
# loopback file -- "you hid the fs from kubelet by hand"; a real partition on
# /dev/nvme1n1 is visible to the OS/kubelet the same way any other block
# device would be). nvme1n1 is split into p1 (~1.7TB, /data) + p2 (100GB,
# ext4, cache partition) at setup time -- see 00-node-host-setup.sh.
export STARGZ_CACHE_PART="${STARGZ_CACHE_PART:-/dev/nvme1n1p2}"
export STARGZ_CACHE_MOUNT="${STARGZ_CACHE_MOUNT:-/cache-part}"
export STARGZ_METRICS_ADDRESS="${STARGZ_METRICS_ADDRESS:-0.0.0.0:9110}"

mkdir -p "${RESULTS_DIR}"
