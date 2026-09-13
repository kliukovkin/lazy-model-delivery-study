# shellcheck shell=bash
# Central config for the spike-v8 (the last measuring spike: attributing the 16%, and the decisive RQ1 arm) harness.
# Two-host rig, identical topology to v3.1: registry-host + node-host, i4i.2xlarge,
# stargz chunk cache on a REAL 92GB NVMe partition (/dev/nvme1n1p2 -> /cache-part).
# Source from every node-host script: . "$(dirname "$0")/env.sh"

# v9: load hosts.env ourselves if the caller did not. v8 relied on every entry
# point doing `set -a; . ./hosts.env; set +a` first, which is fine for a bootstrap
# script and a trap for an experiment script launched straight from nohup.
if [ -z "${REG_PRIV:-}" ]; then
  _hosts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosts.env"
  [ -f "${_hosts}" ] && { set -a; . "${_hosts}"; set +a; }
fi
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
export PREDICTOR_IMG="${REG_PRIV}:${REG_PORT}/custom-predictor:v5"

# Only the sizes S1-S3 actually need. 140g must exceed the 92GB cache partition
# (that inequality IS the S2 experiment); 14g is the cheap warm-up/fill image.
export SIZES_GB="${SIZES_GB:-140 14}"

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCH_ROOT
export RESULTS_DIR="${RESULTS_DIR:-${BENCH_ROOT}/../results}"

# v5 live fix: NVMe enumeration is not stable across launches (this run got the
# instance store as nvme0n1 and the EBS root as nvme1n1, the reverse of v4).
# Resolve the cache partition from what is actually mounted at the cache mount
# point, and only fall back to a guess if nothing is mounted there yet.
_resolve_cache_part() {
  local src; src=$(findmnt -no SOURCE "${STARGZ_CACHE_MOUNT:-/cache-part}" 2>/dev/null)
  [ -n "${src}" ] && { echo "${src}"; return; }
  echo "/dev/nvme0n1p2"
}
export STARGZ_CACHE_PART="${STARGZ_CACHE_PART:-$(_resolve_cache_part)}"
export STARGZ_CACHE_MOUNT="${STARGZ_CACHE_MOUNT:-/cache-part}"
export STARGZ_METRICS_ADDRESS="${STARGZ_METRICS_ADDRESS:-0.0.0.0:9110}"
# v5 finding 1: with [fuse_manager] enable = true the filesystem -- and therefore
# the C1 accounting index and the C2 eviction metrics -- lives in the
# stargz-fuse-manager PROCESS, not in containerd-stargz-grpc. Its Prometheus
# registry is exposed only via the manager's OWN metrics endpoint, which is off
# unless [fuse_manager] metrics_address is set. Without this key every
# stargz_cache_* and stargz_fs_cache_* series is silently absent while the
# eviction machinery is in fact running. See RUN-REPORT-v5 finding 1.
# v6: DELIBERATELY EMPTY by default. v5 had to set this, because with
# [fuse_manager] enable = true every stargz_cache_* series was registered in the
# manager's process and the documented metrics_address served none of them. The
# F2 fix federates them onto the documented endpoint, and a rig that still sets
# this key cannot tell a working federation from a second endpoint being read
# directly -- which is exactly what E1.1 has to distinguish. Only E1's
# negative-control arm sets it, because the pre-fix build has nothing readable
# without it.
export STARGZ_FM_METRICS_ADDRESS="${STARGZ_FM_METRICS_ADDRESS:-}"
# Snapshotter root INSIDE the kind node. /cache-part is bind-mounted here via
# kind extraMounts, so BOTH subtrees the snapshotter uses land on the 92GB
# partition: <root>/snapshotter (layer snapshots) and <root>/stargz
# (httpcache + fscache). Same layout as v3.1 -- see v3.1 RUN-REPORT s12.2.
export STARGZ_ROOT_IN_NODE="${STARGZ_ROOT_IN_NODE:-/var/lib/containerd-stargz-grpc}"

export STARGZ_VER="${STARGZ_VER:-v0.18.2}"          # the vanilla control build
# --- v5: the system under test is OUR fork, not a release tarball.
export OUR_REPO="${OUR_REPO:-https://github.com/kliukovkin/stargz-snapshotter.git}"
export OUR_BRANCH="${OUR_BRANCH:-c2-eviction}"
export OUR_SHA="${OUR_SHA:-6e87e34e}"
export ARTIFACT_SNAPSHOT="${ARTIFACT_SNAPSHOT:-snap-0118cc5716e9e8a54}"
# The commit spike v5 ran: the last one BEFORE the F12/F2/F3/F10 fix round.
# E1's negative control is built from this and must reproduce v5's symptom, or
# E1's before/after is void (PRE-REGISTRATION-v6.md s1.5).
# The previous SUT: head of fix round v5, the commit v6 measured. E1's and E2's
# negative controls are built from this and must reproduce v6's C1 and C4, or
# those before/afters are void.
export BASE_SHA="${BASE_SHA:-9829d7cf}"  # E1 arm A; also v6's SUT
# Budget under test. 80GB on the 92GB partition; watermarks are the shipped
# defaults and are written explicitly so the config is self-documenting.
export CACHE_BUDGET_BYTES="${CACHE_BUDGET_BYTES:-80000000000}"
export CACHE_HIGH_WM="${CACHE_HIGH_WM:-0.95}"
export CACHE_LOW_WM="${CACHE_LOW_WM:-0.85}"
export CACHE_POLICY="${CACHE_POLICY:-lru}"
export CACHE_ACCOUNTING="${CACHE_ACCOUNTING:-true}"

mkdir -p "${RESULTS_DIR}"

# ============================================================ spike-v9 additions
# V9-A needs a SECOND, DISJOINT image for the resident tenant. v8's E2 used one
# image with disjoint file ranges, which is fine for a policy question but not
# for this one: V9-A attributes refetches registry-side, by blob digest, and that
# is only unambiguous if A's bytes live in blobs B never touches.
export MODEL_IMG_A="${MODEL_IMG_A:-${REG_PRIV}:${REG_PORT}/model-ballast:estargz-20g}"
export MODEL_IMG_B="${MODEL_IMG_B:-${REG_PRIV}:${REG_PORT}/model-ballast:estargz-140g}"
export A_FILES="${A_FILES:-40}"      # 40 x 512MiB = 20 GiB
export B_FILES="${B_FILES:-280}"     # 280 x 512MiB = 140 GiB
export SPIKE="${SPIKE:-v9}"
