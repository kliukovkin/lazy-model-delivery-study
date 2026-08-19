#!/usr/bin/env bash
# v3, registry-host: build model ballast artifacts for SIZES_GB x VARIANTS,
# push to the local registry:2 (0.0.0.0:5000), upload raw ballast to MinIO.
# Priority order: size 140 first, and specifically variant B (8-layer gzip)
# built+pushed before anything else, so the eStargz conversion (34min) can be
# kicked off in nohup as early as possible while the rest of the matrix builds.
set -euo pipefail

REG_PORT=5000
MINIO_USER=benchadmin
MINIO_PASS=benchadmin123
MINIO_BUCKET=models
SIZES_GB="140 14 2"
VARIANTS="A B D"
MODEL_IMG_PREFIX="localhost:${REG_PORT}/model-ballast"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

WORK="/data/bench/artifacts"
mkdir -p "${WORK}"

variant_layers() { case "$1" in A) echo 1;; B) echo 8;; D) echo 8;; *) die "unknown variant $1";; esac; }
variant_compression() { case "$1" in A) echo gzip;; B) echo gzip;; D) echo zstd;; *) die "unknown variant $1";; esac; }

# ---------------------------------------------------------------- tiny real model (once)
if [ ! -f "${WORK}/model.joblib" ]; then
  log "training tiny sklearn iris model"
  cat > "${WORK}/make_model.py" <<'EOF'
from sklearn import datasets, svm
import joblib
X, y = datasets.load_iris(return_X_y=True)
clf = svm.SVC(gamma="scale", probability=True)
clf.fit(X, y)
joblib.dump(clf, "/out/model.joblib")
print("model.joblib written")
EOF
  docker run --rm -v "${WORK}:/out" python:3.11-slim \
    bash -c "pip install --quiet 'scikit-learn==1.5.*' joblib && python /out/make_model.py"
fi

# ---------------------------------------------------------------- mc client (via host network)
MC_HOME="${WORK}/.mc-home"
mkdir -p "${MC_HOME}"
MC="docker run --rm --network host -v ${WORK}:/work -v ${MC_HOME}:/root/.mc --entrypoint /bin/sh minio/mc:latest -c"
${MC} "mc alias set bench http://127.0.0.1:9000 ${MINIO_USER} ${MINIO_PASS} && mc mb --ignore-existing bench/${MINIO_BUCKET}"

# ---------------------------------------------------------------- buildx builder for zstd (variant D)
if ! docker buildx inspect zstdbuilder >/dev/null 2>&1; then
  log "creating buildx builder 'zstdbuilder'"
  cat > "${WORK}/buildkitd.toml" <<EOF
[registry."localhost:${REG_PORT}"]
  http = true
  insecure = true
EOF
  docker buildx create --name zstdbuilder --driver docker-container \
    --driver-opt network=host --config "${WORK}/buildkitd.toml"
fi

split_into_layers() { # split_into_layers <raw_models_dir> <dest_dir> <n>
  local raw="$1" dest="$2" n="$3"
  rm -rf "${dest}"
  for i in $(seq 0 $((n - 1))); do mkdir -p "${dest}/models-${i}"; done
  ln "${raw}/model.joblib" "${dest}/models-0/model.joblib"
  local idx=0
  for f in "${raw}"/ballast-*.bin; do
    ln "${f}" "${dest}/models-$((idx % n))/$(basename "${f}")"
    idx=$((idx + 1))
  done
}

gen_dockerfile() { # gen_dockerfile <dest_dir> <n>
  local dest="$1" n="$2"
  {
    echo "FROM busybox:1.36"
    echo 'RUN echo "kserve:x:10:10:kserve:/:/bin/sh" >> /etc/passwd'
    for i in $(seq 0 $((n - 1))); do echo "COPY models-${i} /models"; done
  } > "${dest}/Dockerfile"
}

kick_estargz_conversion() { # kick_estargz_conversion <size_tag> <src_img>
  local tag="$1" src="$2"
  local dst="${MODEL_IMG_PREFIX}:estargz-${tag}"
  local logf="/data/bench/estargz-convert-${tag}.log"
  if curl -sf "http://localhost:${REG_PORT}/v2/model-ballast/manifests/estargz-${tag}" >/dev/null 2>&1; then
    log "estargz ${tag} already pushed, skip conversion"
    return
  fi
  log "kicking off nohup eStargz conversion: ${src} -> ${dst} (log: ${logf})"
  mkdir -p /data/tmp
  # FIX (live pitfall, v3): ctr-remote needs root to dial containerd.sock
  # (0660 root:root) -- the registry-host build script itself runs as user
  # ubuntu (docker group membership covers dockerd, NOT containerd.sock
  # directly). First attempt without sudo failed immediately with
  # "permission denied" on /run/containerd/containerd.sock.
  # FIX (live pitfall, v3): `ctr-remote image convert` writes uncompressed
  # intermediate data to $TMPDIR, which defaults to /tmp (the 30GB root
  # disk) -- blew ENOSPC mid-convert on a 140GB image. TMPDIR=/data/tmp
  # keeps it on the big NVMe.
  nohup sudo bash -c "
    export TMPDIR=/data/tmp
    set -x
    ctr-remote image pull --plain-http ${src} && \
    ctr-remote image convert --oci --estargz ${src} ${dst} && \
    ctr-remote image push --plain-http ${dst} ${dst}
  " > "${logf}" 2>&1 < /dev/null &
  disown
  log "estargz-${tag} conversion PID=$! (backgrounded, survives SSH disconnect via nohup+disown)"
}

for SIZE in ${SIZES_GB}; do
  TAG="${SIZE}g"
  RAWDIR="${WORK}/models-${TAG}"
  if [ ! -f "${RAWDIR}/.done" ]; then
    log "generating raw ballast ${TAG}"
    rm -rf "${RAWDIR}"; mkdir -p "${RAWDIR}"
    cp "${WORK}/model.joblib" "${RAWDIR}/model.joblib"
    CHUNKS=$(awk -v s="${SIZE}" 'BEGIN{c=int((s*2)+0.5); if (c<1) c=1; printf "%d", c}')
    for i in $(seq 1 "${CHUNKS}"); do
      dd if=/dev/urandom of="${RAWDIR}/ballast-${i}.bin" bs=1M count=512 status=none
    done
    ( cd "${RAWDIR}" && sha256sum ./* > "sha256-manifest-${TAG}.txt" )
    touch "${RAWDIR}/.done"
  fi

  log "uploading raw ${TAG} to MinIO s3://${MINIO_BUCKET}/${TAG}/"
  ${MC} "mc mirror --overwrite --exclude '.done' --exclude 'sha256-manifest-*' /work/models-${TAG} bench/${MINIO_BUCKET}/${TAG}"

  # priority variant order: B first at 140g so the estargz conversion can start ASAP
  ORDER="${VARIANTS}"
  if [ "${SIZE}" = "140" ]; then ORDER="B A D"; fi

  for VARIANT in ${ORDER}; do
    N=$(variant_layers "${VARIANT}")
    COMPRESSION=$(variant_compression "${VARIANT}")
    IMG="${MODEL_IMG_PREFIX}:${VARIANT}-${TAG}"
    VDIR="${WORK}/variant-${VARIANT}-${TAG}"

    if curl -sf "http://localhost:${REG_PORT}/v2/model-ballast/manifests/${VARIANT}-${TAG}" >/dev/null 2>&1; then
      log "skip (already pushed): ${IMG}"
    else
      log "building variant ${VARIANT} (${N} layers, ${COMPRESSION}) for ${TAG}"
      if [ "${VARIANT}" = "A" ]; then
        rm -rf "${VDIR}"; mkdir -p "${VDIR}/models-0"
        ln "${RAWDIR}/model.joblib" "${VDIR}/models-0/model.joblib"
        for f in "${RAWDIR}"/ballast-*.bin; do ln "${f}" "${VDIR}/models-0/$(basename "${f}")"; done
      elif [ "${VARIANT}" = "D" ]; then
        BDIR="${WORK}/variant-B-${TAG}"
        if [ -d "${BDIR}" ]; then VDIR="${BDIR}"; else split_into_layers "${RAWDIR}" "${VDIR}" "${N}"; fi
      else
        split_into_layers "${RAWDIR}" "${VDIR}" "${N}"
      fi
      gen_dockerfile "${VDIR}" "${N}"

      if [ "${VARIANT}" = "D" ]; then
        BUILD_OK=0
        for attempt in 1 2 3; do
          if docker buildx build --builder zstdbuilder \
               --output "type=image,name=${IMG},compression=zstd,force-compression=true,push=true" \
               "${VDIR}"; then BUILD_OK=1; break; fi
          log "buildx attempt ${attempt}/3 failed for ${IMG}, retrying in 15s"; sleep 15
        done
        [ "${BUILD_OK}" = "1" ] || die "buildx build failed after 3 attempts for ${IMG}"
      else
        BUILD_OK=0
        for attempt in 1 2 3; do
          if docker build -q -t "${IMG}" "${VDIR}"; then BUILD_OK=1; break; fi
          log "docker build attempt ${attempt}/3 failed for ${IMG}, retrying in 15s"; sleep 15
        done
        [ "${BUILD_OK}" = "1" ] || die "docker build failed after 3 attempts for ${IMG}"
        docker push "${IMG}"
      fi
      log "pushed ${IMG}"
      docker system prune -af >/dev/null 2>&1 || true
      sleep 5
    fi

    # kick off eStargz conversion right after B is available for this size
    if [ "${VARIANT}" = "B" ]; then
      kick_estargz_conversion "${TAG}" "${IMG}"
    fi
  done
done

${MC} "mc anonymous set download bench/${MINIO_BUCKET}"
log "artifact build script done (eStargz conversions may still be running in background -- check /data/bench/estargz-convert-*.log)"
