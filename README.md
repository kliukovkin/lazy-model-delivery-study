# Measurement Artifact: *The Lazy Pod That Lies*

This repository is the measurement artifact for the paper:

> **The Lazy Pod That Lies: Failure Characterization of Lazy Container-Image
> Model Delivery in Kubernetes**
> Georgii Kliukovkin
> arXiv: [2608.19412](https://arxiv.org/abs/2608.19412) (submitted to IEEE Access)

It contains the raw measurement data, calibration runs, failure logs, and the
exact scripts that produced them, from two measurement campaigns run on
dedicated AWS hardware in August 2026:

- **C1 — performance matrix** (`c1-performance/`): cold/warm time-to-first-prediction
  matrix across delivery schemes (S3 via storage-initializer, OCI native,
  eStargz lazy, SOCI lazy), plus cache-growth traces, calibration baselines,
  and the ENOSPC failure captures.
- **C2 — failure characterization** (`c2-failure-characterization/`): instrumented
  capture runs that induce and characterize the silent-corruption failure mode
  of lazy snapshotters under disk pressure ("the lazy pod that lies"), plus
  recovery experiments, TTFP decomposition, real-weights validation, and a full
  environment identity bundle.

## Reproducing the paper's tables and figures

| Paper item | Source file in this repo |
|---|---|
| Table 1 (performance matrix) | `c1-performance/matrix.csv` |
| Fig. 1 (lying-pod timeline) | `c2-failure-characterization/results/p01/sampler.csv` |
| Table 2 / Fig. 2 (pressure matrix) | `c2-failure-characterization/results/p05/pressure-matrix.csv` |
| Table 3 (TTFP decomposition) | `c2-failure-characterization/results/p15-ttfp-decomp/ttfp-decomposition.csv` |
| Table 4 (real-weights eager variants) | `c2-failure-characterization/results/p2-realweights/` |
| Table 5 (mechanism & recovery) | `c2-failure-characterization/results/p03/` |
| Table 6 (failure-state observability) | `c2-failure-characterization/results/p01/` + `c2-failure-characterization/results/identity-bundle/` |
| SOCI performance numbers | `c2-failure-characterization/results/p1-soci-performance-CLEAN.md` |

`scripts-as-run/` under each campaign directory contains the harness exactly as
executed (including `custom-predictor/`, the raw-Pod predictor used for the
failure-induction experiments, which the paper references directly). Script
comments occasionally reference "RUN-REPORT" documents; those are internal lab
notes that are not published — all facts from them that the paper relies on
are captured in this README and in the data files themselves.

## Data-hygiene notes (read before parsing)

- `c2-failure-characterization/results/p01/sampler.csv`: pre-failure rows are
  **line-wrapped** — a logical row's columns are split across two physical
  lines. Rejoin wrapped lines before parsing.
- `c2-failure-characterization/results/p05/pressure-matrix.csv`: row `25,1` is
  line-wrapped the same way.
- `c1-performance/cache_growth.csv`: `cache_bytes` is **apparent size**
  (`du -sb` over sparse files), *not* bytes-on-disk. Do not compare it against
  partition free space.
- `c2-failure-characterization/results/p1-soci-clean/soci-clean-matrix.csv` is
  header-only; the clean SOCI numbers live in
  `results/p1-soci-performance-CLEAN.md` (N=2 per variant).
- `c2-failure-characterization/results/p03/p03-recovery-1-stability.txt`: the
  corrupted-file list contains exactly **224 files** per reread (identical
  across all three rereads); 224 is the figure the paper quotes.
- `c2-failure-characterization/results/p15-ttfp-decomp/ttfp-decomposition.csv`
  has small negative `t_scheduled_s` values (apply-vs-event clock skew); clamp
  to 0 when plotting.

## Excluded / invalidated datasets (preserved, not used)

These are kept for completeness and provenance; the paper does **not** use them:

- `c2-failure-characterization/results/matrix-soci-contaminated.csv` — SOCI
  runs contaminated by residual snapshotter state; superseded by
  `p1-soci-performance-CLEAN.md`.
- `c2-failure-characterization/results/p05-attempt1-INVALID/` — first
  pressure-matrix attempt, invalidated (see `NOTE.txt` inside); superseded by
  `results/p05/`.

## Environment

- 2 × AWS `i4i.2xlarge` (us-east-1): one registry host, one node host,
  communicating over private VPC addresses (`172.31.x.x` in logs; both
  instances are terminated).
- kind v1.36.1 (Kubernetes node image `kindest/node:v1.36.1`)
- containerd 2.3.1
- stargz-snapshotter v0.18.2
- soci-snapshotter v0.15.0
- KServe built from source — the exact git SHA for each campaign is recorded in
  `c1-performance/kserve-git-sha.txt` and
  `c2-failure-characterization/results/kserve-git-sha.txt`.
- Full toolchain versions, containerd/stargz configs, disk layout, and kubelet
  config: `c2-failure-characterization/results/identity-bundle/`.
  (Credential blobs in `kubeconfig-copy.yaml` are redacted; the kind cluster
  and both instances no longer exist.)

## Calibration

Both campaigns include calibration baselines (fio on node and registry disks,
iperf3 host-to-host, direct blob `curl` from the registry):
`c1-performance/calibration/` and
`c2-failure-characterization/results/calibration-*`. C2 calibration was run at
both the start and the end of the campaign to bound drift.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
