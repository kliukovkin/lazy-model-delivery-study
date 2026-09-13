#!/usr/bin/env bash
# V9-B, registry side. Runs ON the registry host.
#
#   52-v9b-registry.sh ceilings <node_priv...>     -- iperf3 + fio, once, before any round
#   52-v9b-registry.sh go <round> <node_priv...>   -- sample the NIC, fan the start
#                                                     signal out over ssh, stop
#
# Clause (iii) of the V9-B expectation is about the registry NIC saturating, and
# that clause is uninterpretable without knowing where the ceilings are. So both
# are measured explicitly and recorded: the NIC with iperf3 against each node,
# and the serving filesystem with fio. PRE-REGISTRATION-v9 s4 step 1.
set -euo pipefail
OUT="${OUT:-/data/v9b}"
mkdir -p "${OUT}"
K="${K:-REDACTED-KEY.pem}"
# BatchMode=yes: without it a missing/rejected key makes ssh fall through to a
# password prompt and BLOCK. That hung the ceilings probe for 8 minutes on the
# rebuilt rig, whose registry had not yet been given the key.
SSHO=(-i "${K}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# tx bytes on the primary interface, from /proc/net/dev
IFACE="${IFACE:-$(ip -o -4 route show to default | awk '{print $5}' | head -1)}"
txbytes() { awk -v i="${IFACE}:" '$1==i {print $10}' /proc/net/dev; }

case "${1:?ceilings|go}" in
ceilings)
  shift
  log "=== registry ceilings: iface=${IFACE} ==="
  { echo "iface=${IFACE}"
    echo "measured_utc=$(date -u +%FT%TZ)"
    echo "instance_type=$(curl -s --max-time 3 -H "X-aws-ec2-metadata-token: $(curl -sX PUT --max-time 3 http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-type || echo unknown)"
  } > "${OUT}/ceilings.txt"
  for p in "$@"; do
    log "iperf3 registry -> ${p} (NIC ceiling), 3 streams, 15 s"
    # The node runs iperf3 -s from its base setup; -R would measure the wrong
    # direction. Default direction is client->server, i.e. registry->node, which
    # is the direction V9-B's egress actually flows.
    # NOT `pgrep -f "iperf3 -s" || start`: over an ssh command line that string
    # is IN the remote shell's own argv, so pgrep matches itself, the guard is
    # always true and the server is never started. lib.sh documents this exact
    # trap for the stargz daemons; it bites identically here. iperf3 -D is
    # harmless when a server is already listening, so just always ask.
    ssh "${SSHO[@]}" "ubuntu@${p}" 'iperf3 -s -D >/dev/null 2>&1 || true' >/dev/null 2>&1
    sleep 1
    r=$(iperf3 -c "${p}" -P 3 -t 15 -J 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%.3f" % (d["end"]["sum_sent"]["bits_per_second"]/1e9))' 2>/dev/null || echo "NA")
    echo "iperf3_gbps_to_${p}=${r}" | tee -a "${OUT}/ceilings.txt"
  done
  log "fio sequential read on the serving filesystem (disk ceiling)"
  # Read a file that is actually in the blob store's filesystem, direct I/O so
  # the 64 GB page cache does not answer instead of the disk.
  # stderr is KEPT: a swallowed fio error reads as "NA" and an NA here would
  # silently remove the disk ceiling that clause (iii) is interpreted against.
  rm -f /data/regread.*.0 2>/dev/null || true
  # libaio, not the default psync: with a synchronous engine fio caps the queue
  # depth at 1 AND prints a "note:" line per job to STDOUT, ahead of the JSON,
  # which is what made the first two attempts parse as NA. A ceiling wants real
  # queue depth anyway.
  fio --name=regread --directory=/data --size=4G --rw=read --bs=1M --direct=1 \
      --ioengine=libaio --numjobs=4 --iodepth=16 --group_reporting --output-format=json \
      > /tmp/fio-reg.json 2>/tmp/fio-reg.err || true
  python3 -c 'import json; t=open("/tmp/fio-reg.json").read(); d=json.loads(t[t.index("{"):]); print("fio_read_MBps=%.1f" % (d["jobs"][0]["read"]["bw"]/1024.0))' \
    >> "${OUT}/ceilings.txt" 2>/dev/null \
    || { echo "fio_read_MBps=NA" >> "${OUT}/ceilings.txt"; echo "--- fio stderr ---"; cat /tmp/fio-reg.err; }
  rm -f /data/regread.*.0 2>/dev/null || true
  cat "${OUT}/ceilings.txt"
  ;;
go)
  ROUND="${2:?round}"; shift 2
  NODES=("$@")
  R="${OUT}/${ROUND}"; mkdir -p "${R}"
  log "=== V9-B ${ROUND}: k=${#NODES[@]} nodes ${NODES[*]} ==="

  # Registry access log: record how many lines exist now, so the round's slice
  # can be cut without re-reading a 1 GB log.
  sudo docker logs registry 2>&1 | wc -l > "${R}/reglog-offset-before.txt"

  # NIC + disk sampler, 5 s cadence, for the whole window including margins.
  { echo "ts_epoch,iso,tx_bytes,rx_bytes,loadavg1"
    while :; do
      printf '%s,%s,%s,%s,%s\n' "$(date +%s.%N)" "$(date -u +%FT%T.%3NZ)" \
        "$(txbytes)" "$(awk -v i="${IFACE}:" '$1==i {print $2}' /proc/net/dev)" \
        "$(awk '{print $1}' /proc/loadavg)"
      sleep 5
    done
  } > "${R}/registry-nic.csv" 2>/dev/null &
  SPID=$!
  trap 'kill ${SPID} 2>/dev/null || true' EXIT
  sleep 15                                   # idle margin before the start

  TX0=$(txbytes); T0=$(date +%s.%N)
  echo "tx_before=${TX0}" > "${R}/egress.txt"
  echo "window_begin_utc=$(date -u +%FT%T.%3NZ)" >> "${R}/egress.txt"

  # THE fan-out. Parallel ssh, each recording the instant its own signal landed,
  # so the start skew is MEASURED rather than assumed to be small.
  log "fanning out the go signal"
  FANPIDS=()
  for p in "${NODES[@]}"; do
    ( s=$(date +%s.%N)
      ssh "${SSHO[@]}" "ubuntu@${p}" "touch /data/v9b-go-${ROUND}" >/dev/null 2>&1
      e=$(date +%s.%N)
      printf '%s,%s,%s\n' "${p}" "${s}" "${e}" >> "${R}/fanout.csv" ) &
    FANPIDS+=($!)
  done
  # Wait for the FAN-OUT ONLY, by pid.
  #
  # A bare `wait` here waits for every background job of this shell -- which
  # includes the 5 s NIC sampler started above, an infinite loop. That is the
  # true root cause of V9-B's first stall: both attempts hung at exactly this
  # line, forever, and the node-side 600 s go-signal timeout merely decided
  # which symptom surfaced first. Never `wait` in a shell that owns a daemon.
  wait "${FANPIDS[@]}"
  sort -t, -k3 -n "${R}/fanout.csv" -o "${R}/fanout.csv" 2>/dev/null || true
  python3 - "${R}/fanout.csv" >> "${R}/egress.txt" <<'PY'
import sys
rows = [l.strip().split(",") for l in open(sys.argv[1]) if l.strip()]
ends = sorted(float(r[2]) for r in rows)
print("fanout_nodes=%d" % len(ends))
print("fanout_skew_s=%.3f" % (ends[-1] - ends[0] if len(ends) > 1 else 0.0))
PY
  cat "${R}/fanout.csv" >&2

  # Wait for done, but ALSO notice a node that has died. The first V9-B attempt
  # sat here for 2.5 h waiting on a node whose reader had already exited with
  # FATAL, because the only thing this loop tested was the presence of a marker
  # that was never going to appear. A liveness check costs one extra ssh per
  # poll and turns a silent 2.5 h stall into an immediate, reported failure.
  log "waiting for every node to report done"
  DEAD=""
  for _ in $(seq 1 480); do
    n=0; alive=0
    for p in "${NODES[@]}"; do
      ssh "${SSHO[@]}" "ubuntu@${p}" "test -f /data/v9b-done-${ROUND}" >/dev/null 2>&1 && { n=$((n+1)); alive=$((alive+1)); continue; }
      ssh "${SSHO[@]}" "ubuntu@${p}" "pgrep -f '50-v9b-node.sh ${ROUND}' >/dev/null" >/dev/null 2>&1 && alive=$((alive+1)) || DEAD="${DEAD} ${p}"
    done
    [ "${n}" -eq "${#NODES[@]}" ] && break
    if [ "${alive}" -eq 0 ]; then
      log "ABORT: no node is still running ${ROUND} and not all reported done (dead:${DEAD})"
      echo "aborted_reason=all nodes gone before done${DEAD}" >> "${R}/egress.txt"
      break
    fi
    sleep 10
  done

  TX1=$(txbytes); T1=$(date +%s.%N)
  { echo "tx_after=${TX1}"
    echo "window_end_utc=$(date -u +%FT%T.%3NZ)"
    echo "window_s=$(awk -v a="${T0}" -v b="${T1}" 'BEGIN{printf "%.1f", b-a}')"
    echo "tx_delta_bytes=$(( TX1 - TX0 ))"
    echo "tx_delta_GB=$(awk -v d="$(( TX1 - TX0 ))" 'BEGIN{printf "%.2f", d/1e9}')"
    echo "k=${#NODES[@]}"; } >> "${R}/egress.txt"
  sleep 15                                   # idle margin after
  kill ${SPID} 2>/dev/null || true; trap - EXIT

  # Registry access log slice for this round, plus per-blob response bytes.
  sudo docker logs registry 2>&1 | tail -n +"$(( $(cat "${R}/reglog-offset-before.txt") + 1 ))" > "${R}/registry-access.log" || true
  python3 - "${R}/registry-access.log" > "${R}/registry-blobs.txt" <<'PY'
import re, sys, collections
tot = collections.Counter(); cnt = collections.Counter(); allb = 0
for line in open(sys.argv[1], errors="replace"):
    if "response completed" not in line and "http.response.written" not in line:
        continue
    u = re.search(r'http\.request\.uri="([^"]+)"', line)
    w = re.search(r'http\.response\.written=(\d+)', line)
    if not (u and w):
        continue
    n = int(w.group(1)); allb += n
    m = re.search(r'/blobs/(sha256:[0-9a-f]+)', u.group(1))
    key = m.group(1) if m else u.group(1)
    tot[key] += n; cnt[key] += 1
print("total_response_bytes=%d" % allb)
print("total_response_GB=%.2f" % (allb / 1e9))
print()
print("%-75s %10s %14s" % ("blob/uri", "requests", "bytes"))
for k, v in tot.most_common(30):
    print("%-75s %10d %14d" % (k, cnt[k], v))
PY
  cat "${R}/egress.txt"; head -5 "${R}/registry-blobs.txt"
  log "=== V9-B ${ROUND}: registry side done -> ${R} ==="
  ;;
esac
