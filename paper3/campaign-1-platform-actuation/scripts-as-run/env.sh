# shellcheck shell=bash
# Central config for the spike-v4 (FuseManager & upstream-fix verification) harness.
# Two-host rig, identical topology to v3.1: registry-host + node-host, i4i.2xlarge,
# stargz chunk cache on a REAL 92GB NVMe partition (/dev/nvme1n1p2 -> /cache-part).
# Source from every node-host script: . "$(dirname "$0")/env.sh"

export REG_PRIV="${REG_PRIV:?REG_PRIV must be set (see hosts.env)}"
export REG_PUB="${REG_PUB:-}"
export NODE_PRIV="${NODE_PRIV:-}"
export NODE_PUB="${NODE_PUB:-}"
export REG_PORT="${REG_PORT:-5000}"

export CLUSTER_NAME="${CLUSTER_NAME:-ocibench}"
export KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.36.1}"
export TEST_NS="${TEST_NS:-bench}"
export MAX_CONCURRENT_DOWNLOADS="${MAX_CONCURRENT_DOWNLOADS:-8}"

# v4 drops KServe entirely: S1-S3 exercise only the
# containerd -> proxy-plugin snapshotter -> ImageVolume path, which the raw
# Pod + native `image:` volume drives identically (this is exactly what v3.1's
# P0.1 "money artifact" used). Dropping the KServe-from-source build removes
# the single most failure-prone step in the v3.1 rig (see v3.1 RUN-REPORT s10).
export MODEL_IMG_PREFIX="${REG_PRIV}:${REG_PORT}/model-ballast"
export PREDICTOR_IMG="${REG_PRIV}:${REG_PORT}/custom-predictor:v4"

# Only the sizes S1-S3 actually need. 140g must exceed the 92GB cache partition
# (that inequality IS the S2 experiment); 14g is the cheap warm-up/fill image.
export SIZES_GB="${SIZES_GB:-140 14}"

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCH_ROOT
export RESULTS_DIR="${RESULTS_DIR:-${BENCH_ROOT}/../results}"

export STARGZ_CACHE_PART="${STARGZ_CACHE_PART:-/dev/nvme1n1p2}"
export STARGZ_CACHE_MOUNT="${STARGZ_CACHE_MOUNT:-/cache-part}"
export STARGZ_METRICS_ADDRESS="${STARGZ_METRICS_ADDRESS:-0.0.0.0:9110}"
# Snapshotter root INSIDE the kind node. /cache-part is bind-mounted here via
# kind extraMounts, so BOTH subtrees the snapshotter uses land on the 92GB
# partition: <root>/snapshotter (layer snapshots) and <root>/stargz
# (httpcache + fscache). Same layout as v3.1 -- see v3.1 RUN-REPORT s12.2.
export STARGZ_ROOT_IN_NODE="${STARGZ_ROOT_IN_NODE:-/var/lib/containerd-stargz-grpc}"

export STARGZ_VER="${STARGZ_VER:-v0.18.2}"

mkdir -p "${RESULTS_DIR}"
