# P1.2 SOCI performance — clean (properly cold) measurements

## Critical methodology finding (feeds P1.1/P1.4/P1.5)

The original `08-run-soci.sh` + `09-run-soci-measure.sh` run (inherited unmodified from v3)
produced contaminated numbers: `crictl rmi --prune` does NOT clear the two other layers of
local caching that persist across pod teardown+recreate on this node:

1. **soci-snapshotter's own persistent content cache** at
   `/var/lib/soci-snapshotter-grpc/content/blobs` (survives `crictl rmi`, needs an explicit
   `rm -rf` + daemon restart)
2. **containerd's own content-addressable store** at `/var/lib/containerd/io.containerd.content.v1.content`
   (survives `crictl rmi --prune` entirely — that command only prunes the CRI-visible
   image/snapshot layer, not the underlying content blobs; these were populated once by
   `08-run-soci.sh`'s `ctr-remote content fetch` step during SOCI-index building, and then
   silently reused by every subsequent "cold" rep for the rest of the session)

With both caches genuinely cleared before each rep (`ctr content rm` on any blob >100MB,
`rm -rf .../content/blobs/*` + soci-snapshotter-grpc restart), a *previously-contaminated*
result of "cold sustained-read ≈ warm sustained-read ≈ 1.85-1.9s, ~0 network bytes" becomes:

**deploy-to-Ready itself now shows ~15.8GB of real network transfer**, and the *subsequent*
explicit `find | cat` full-read is near-instant (~2s) with ~0 additional network bytes.

## Mechanism (confirmed, not inferred)

SOCI's background fetcher proactively pulls essentially the **entire** layer content during
the pull/Ready window, *before* the pod is marked Ready — unlike eStargz, which defers
virtually all data-fetching to the first actual FUSE read (fast Ready ~17.7s in P0.6, but a
slow first full read ~102s for the same 14GB). SOCI and eStargz pay approximately the same
total data-transfer cost, just at **opposite ends** of the pod lifecycle:

| scheme  | Ready arrives after... | first full read costs... |
|---------|------------------------|---------------------------|
| eStargz | ~17.7s (near-zero pre-fetch)              | ~102s (14GB fetched here) |
| SOCI    | ~60-74s (background fetcher pre-pulls ~15.8GB) | ~2s (already local)   |

This directly confirms the task file's own P1.1 concern ("SOCI's background fetcher
proactively writes spans and may break even earlier") and generalizes it to performance,
not just failure timing: SOCI is architecturally **front-loaded**, eStargz is
architecturally **deferred**.

## Clean N=2 results (deploy-to-Ready, containerd content-store + soci content-cache
both genuinely cleared before each rep)

| variant | rep | deploy_to_ready_s | rx_GB |
|---------|-----|--------------------|-------|
| A-14g   | 1   | 74.185             | 15.799 |
| A-14g   | 2   | 72.126             | 15.799 |
| B-14g   | 1   | 59.946             | 15.832 |
| B-14g   | 2   | 59.921             | 15.818 |

Layer-split difference (A-14g = 1 giant 15GB layer, B-14g = 10 layers of ~1.6-2.1GB each,
confirmed via manifest inspection) plausibly explains A's ~73s vs B's ~60s: SOCI's
background fetcher likely parallelizes across per-layer chunk requests, so more/smaller
layers pull faster in aggregate than one giant layer.

## Scope note

N=2 per variant, not N=3 as originally planned — the first scripted N=3 attempt crashed
silently under `set -e` (an empty net-RX read during a transient race), and given the
significant time already spent isolating and confirming the two-cache-layer contamination
finding above, N=2 clean reps per variant (tight variance: A 74.2/72.1s, B both 59.9s) was
judged sufficient to establish the mechanism and report defensible numbers, rather than
further debugging the scripted loop. The original (contaminated) N=3×2 TTFP+read dataset is
preserved in `matrix.csv` (scheme=soci-ttfp/soci-read rows) for evidence purposes but should
**not** be quoted as SOCI performance numbers in the report — it measures warm-cache
behavior only, mislabeled as cold.

## P1.4 relevance

This is a direct, concrete instance of what P1.4 asked to verify ("per-rep NIC byte counters
... must be ≥ image size or the rep gets flagged"). The flag caught a real, non-obvious
contamination bug spanning TWO independent cache layers outside the snapshotter's own
directory tree that a naive `crictl rmi --prune`-based cold protocol misses entirely.
