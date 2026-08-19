# shellcheck shell=bash
# Shared helpers: timing, pod-phase polling, event scraping, node cache control.

now() { date +%s.%N; }

elapsed() { # elapsed <t0> -> seconds with ms precision
  awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.3f", b-a}'
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

die() { log "FATAL: $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Poll until the given command succeeds or timeout (seconds) expires.
# wait_for <timeout> <desc> <cmd...>
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local t0; t0=$(now)
  while true; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    if awk -v a="$t0" -v b="$(now)" -v t="$timeout" 'BEGIN{exit !(b-a>t)}'; then
      log "timeout (${timeout}s) waiting for: ${desc}"
      return 1
    fi
    sleep 0.2
  done
}

# Name of the single pod for an InferenceService predictor (RawDeployment).
isvc_pod() { # isvc_pod <ns> <isvc-name>
  kubectl -n "$1" get pod -l "serving.kserve.io/inferenceservice=$2" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

pod_condition_true() { # pod_condition_true <ns> <pod> <ConditionType>
  [ "$(kubectl -n "$1" get pod "$2" -o jsonpath="{.status.conditions[?(@.type=='$3')].status}" 2>/dev/null)" = "True" ]
}

# Extract kubelet-reported pull duration for the model image from pod events.
# GNU grep -oP is available on the Ubuntu VM this harness targets.
pull_seconds_from_events() { # pull_seconds_from_events <ns> <pod> <image-substr>
  kubectl -n "$1" get events --field-selector "involvedObject.name=$2" \
    -o jsonpath='{range .items[?(@.reason=="Pulled")]}{.message}{"\n"}{end}' 2>/dev/null \
    | grep -F "$3" | grep -oP 'in \K[0-9a-z.]+(?=( \(|$))' | head -1
}

# Bytes used by containerd on the (single) kind node.
node_containerd_bytes() {
  docker exec "${CLUSTER_NAME}-control-plane" df -B1 --output=used /var/lib/containerd | tail -1 | tr -d ' '
}

# Drop a model image from the node's containerd cache (cold-start prep).
node_rmi() { # node_rmi <image-ref>
  docker exec "${CLUSTER_NAME}-control-plane" crictl rmi "$1" >/dev/null 2>&1 || true
}

csv_init() { # csv_init <file>
  if [ ! -f "$1" ]; then
    echo "scheme,size_gb,mode,rep,apply_to_pod_s,pod_to_scheduled_s,scheduled_to_initialized_s,initialized_to_ready_s,ready_to_first200_s,total_s,kubelet_pull,disk_delta_bytes,pod,notes,variant,layers,compression" > "$1"
  fi
}

# spike v2: layer count / compression algorithm for each packaging variant
# under test. Shared between 02-build-artifacts.sh (which
# builds these) and 03-run-matrix.sh (which records them per CSV row).
variant_layers() {
  case "$1" in
    A) echo 1 ;;
    B) echo 8 ;;
    D) echo 8 ;;
    E) echo 8 ;;
    *) die "unknown variant $1" ;;
  esac
}
variant_compression() {
  case "$1" in
    A) echo gzip ;;
    B) echo gzip ;;
    C) echo gzip ;;
    D) echo zstd ;;
    E) echo estargz ;;
    *) die "unknown variant $1" ;;
  esac
}
