#!/usr/bin/env bash
# spike-v5 registry-host: build ONLY what S1-S3 need.
#   - model-ballast:B-140g / :estargz-140g   (the >92GB-cache image; S1 + S2)
#   - model-ballast:B-14g  / :estargz-14g    (cheap warm-up / pre-fill image)
#   - custom-predictor:v4                    (v3.1's P0.1 datapath-coupled predictor)
# v3.1's A/D variants, the 2g size, and the MinIO/S3 arm are all dropped: no
# v4 experiment reads them.
set -euo pipefail
REG_PORT=5000
# v5 F6: this default used to be "140" with a stale comment saying 14g was
# dropped, while env.sh said "140 14" -- and this script does not source env.sh.
# The 14GB image E2's resident pod needs was therefore silently never built, and
# had to be recovered mid-run. Both sizes are the default here now.
SIZES_GB="${SIZES_GB:-140 14}"
MODEL_IMG_PREFIX="localhost:${REG_PORT}/model-ballast"
PRED_IMG="localhost:${REG_PORT}/custom-predictor:v5"
WORK="/data/bench/artifacts"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }
mkdir -p "${WORK}" /data/tmp

# ---------------------------------------------------------------- custom predictor image (small, do it first)
if ! curl -sf "http://localhost:${REG_PORT}/v2/custom-predictor/manifests/v5" >/dev/null 2>&1; then
  log "building custom-predictor image"
  mkdir -p "${WORK}/predictor"
  cp "$(dirname "$0")/custom-predictor/predictor.py" "${WORK}/predictor/"
  cp "$(dirname "$0")/custom-predictor/Dockerfile"   "${WORK}/predictor/"
  docker build -q -t "${PRED_IMG}" "${WORK}/predictor"
  docker push "${PRED_IMG}"
fi

split_into_layers() { # <raw_dir> <dest_dir> <n>
  local raw="$1" dest="$2" n="$3"
  rm -rf "${dest}"
  for i in $(seq 0 $((n-1))); do mkdir -p "${dest}/models-${i}"; done
  ln "${raw}/model.joblib" "${dest}/models-0/model.joblib" 2>/dev/null || true
  local idx=0
  for f in "${raw}"/ballast-*.bin; do
    ln "${f}" "${dest}/models-$((idx % n))/$(basename "${f}")"; idx=$((idx+1))
  done
}
gen_dockerfile() { # <dest_dir> <n>
  { echo "FROM busybox:1.36"
    echo 'RUN echo "kserve:x:10:10:kserve:/:/bin/sh" >> /etc/passwd'
    for i in $(seq 0 $(( $2 - 1 ))); do echo "COPY models-${i} /models"; done
  } > "$1/Dockerfile"
}
kick_estargz_conversion() { # <size_tag> <src_img>
  local tag="$1" src="$2" dst logf
  dst="${MODEL_IMG_PREFIX}:estargz-${tag}"
  logf="/data/bench/estargz-convert-${tag}.log"
  if curl -sf "http://localhost:${REG_PORT}/v2/model-ballast/manifests/estargz-${tag}" >/dev/null 2>&1; then
    log "estargz ${tag} already pushed, skip"; return
  fi
  log "backgrounding eStargz conversion ${src} -> ${dst} (log ${logf})"
  # v3 pitfalls preserved: ctr-remote needs root for containerd.sock, and its
  # uncompressed intermediates must NOT land on the 30GB root disk.
  nohup sudo bash -c "
    export TMPDIR=/data/tmp
    set -x
    ctr-remote image pull --plain-http ${src} && \
    ctr-remote image convert --oci --estargz ${src} ${dst} && \
    ctr-remote image push --plain-http ${dst} ${dst} && \
    echo CONVERT_DONE_OK
  " > "${logf}" 2>&1 < /dev/null &
  disown
}

for SIZE in ${SIZES_GB}; do
  TAG="${SIZE}g"; RAWDIR="${WORK}/models-${TAG}"
  if [ ! -f "${RAWDIR}/.done" ]; then
    log "generating raw incompressible ballast ${TAG} (512MiB chunks)"
    rm -rf "${RAWDIR}"; mkdir -p "${RAWDIR}"
    CHUNKS=$(( SIZE * 2 ))
    for i in $(seq 1 "${CHUNKS}"); do
      dd if=/dev/urandom of="${RAWDIR}/ballast-${i}.bin" bs=1M count=512 status=none
    done
    ( cd "${RAWDIR}" && sha256sum ./* > "sha256-manifest-${TAG}.txt" )
    touch "${RAWDIR}/.done"
  fi
  IMG="${MODEL_IMG_PREFIX}:B-${TAG}"; VDIR="${WORK}/variant-B-${TAG}"
  if curl -sf "http://localhost:${REG_PORT}/v2/model-ballast/manifests/B-${TAG}" >/dev/null 2>&1; then
    log "skip (already pushed): ${IMG}"
  else
    log "building variant B (8 layers, gzip) for ${TAG}"
    split_into_layers "${RAWDIR}" "${VDIR}" 8
    gen_dockerfile "${VDIR}" 8
    ok=0; for a in 1 2 3; do docker build -q -t "${IMG}" "${VDIR}" && { ok=1; break; }; log "build attempt ${a} failed, retry"; sleep 15; done
    [ "${ok}" = 1 ] || die "docker build failed for ${IMG}"
    docker push "${IMG}"
    log "pushed ${IMG}; reclaiming docker's local copy (registry now holds it)"
    docker rmi "${IMG}" >/dev/null 2>&1 || true
    docker builder prune -af >/dev/null 2>&1 || true
    df -h /data | tail -1
  fi
  kick_estargz_conversion "${TAG}" "${IMG}"
done
log "build script done; eStargz conversions running in background (/data/bench/estargz-convert-*.log)"
