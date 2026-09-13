#!/usr/bin/env bash
# v7 experiments E2 -> E3 -> E4, back to back, each collected as it finishes.
#
# Rule 1 (collect after every experiment) is enforced inside each script, not
# here, so a chain that dies halfway still leaves every completed experiment
# retrieved. Rule 7 (nothing in parallel with a measurement) is why this is one
# sequential chain rather than three background jobs.
set -uo pipefail
cd "$(dirname "$0")"
set -a; . ./hosts.env; set +a
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

log "### preflight: both images servable ###"
ACC='Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
for t in estargz-140g estargz-14g; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "${ACC}" "http://${REG_PRIV}:5000/v2/model-ballast/manifests/${t}" 2>/dev/null)
  log "manifest ${t}: ${code}"
  [ "${code}" = "200" ] || { log "FATAL: ${t} not servable"; exit 2; }
done

log "### E2 [P0] -- does the budget hold under a flooded queue? ###"
bash ./24-e2-c4-confirm.sh; echo "E2_EXIT=$?"

log "### E3 [P0] -- the price of eviction, N=4, adaptive warm-up ###"
bash ./25-e3-eviction-price.sh; echo "E3_EXIT=$?"

log "### E4 [P1] -- pressure at 90%, N=2, both arms ###"
bash ./26-e4-pressure.sh; echo "E4_EXIT=$?"

log "### calibration end ###"
bash ./03-calibration.sh end || true
log "EXPERIMENTS COMPLETE"; echo "CHAIN_DONE"
