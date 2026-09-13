# Spike v7 — pre-registration

Written **before** the rig is launched. Nothing in §§1–6 is edited afterwards;
amendments go in §7 with the time they were made, as in v6.

- authored: 2026-09-11
- system under test: `kliukovkin/stargz-snapshotter`, `c2-eviction`,
  **`6e87e34e1d8da4ca10e44b81a1891d583a4e66d5`** — head of fix round v6.
- previous SUT, for arms that need a "before":
  **`9829d7cf43fc645a28d2a79e86fe614d62764833`** — head of fix round v5, the
  commit v6 measured.
- vanilla control: upstream `v0.18.2`.
- rig: 2× `i4i.2xlarge`, us-east-1, kind + containerd, cache on a real 92 GB
  NVMe partition at `/cache-part`, `budget = 80 GB`, watermarks 0.95/0.85,
  `[fuse_manager] enable = true` with the `KillMode=process` drop-in and
  `[fuse_manager] metrics_address` **unset**.

---

## 0. Why this spike exists

v6 produced four findings and one unfinished measurement. Two of the findings
were P0 defects in this branch's own code, and fix round v6 closed both — by
test and by mutation, on a laptop. **Every one of those defects appeared only on
a rig**, so a fix verified only off-rig is a fix with the same standing as the
one it replaces. That is the first half of v7.

The second half is the measurement v5 and v6 both failed to produce. v5's
comparison was confounded (warm baselines 21.6% apart). v6 fixed that — 1.8%
apart — and then failed its own warmth gate on two of four arms, and at N=2 the
within-policy spread exceeded the between-policy gap. The adaptive warm-up
written in response has never run.

### What went wrong operationally in v6, and the rules that follow

v6 lost E1's observation bundles, E2's samplers and all of E3's and E4's raw
evidence, because the rig's watchdog fired during an idle gap **before the
single end-of-session collection step ran**. Two mechanical rules follow, and
they are conditions of this spike rather than good intentions:

1. **Collect after every experiment**, not at the end of the session. An
   experiment that has not been collected is not finished.
2. **Snapshot the built artifacts before any experiment runs**, as soon as the
   140 GB image exists, and verify the snapshot is readable before relying on
   it. v5 and v6 each paid ~1 h 40 m to rebuild an image that v5 had already
   built and failed to preserve.

---

## 1. E1 [P0] — C1 fixed, live

### 1.1 What is tested

That a `systemctl restart stargz-snapshotter` with a changed
`[cache_accounting.budget] policy`, on a node where `KillMode=process` keeps the
FUSE manager alive, now delivers the new policy **and leaves accounting alive**.

v6's finding was that it did neither: the replacement index lost the bolt lock to
the one it was replacing, `newAccountant` returned nil, and the node ran with a
configured budget and nothing evicting.

### 1.2 Procedure

As v6's E1, with one addition. Install the SUT at `policy = "lru"`, read the
14 GB image to put real values behind the counters, then **six** alternating
restarts (`lru`→`2q`→`lru`→`2q`→`lru`→`2q`), observing after each. Six because
v6's defect alternated: restart 1 lost the race, restart 2 found no incumbent and
won. Three of each parity is what distinguishes "fixed" from "got lucky".

Every observation records: the `:9110` scrape verbatim, open fds on the index
database, `.corrupt` files, both lock counters, the manager pid, and the
manager's log since the previous observation.

### 1.3 Expectations

| id | expectation | falsifier |
| --- | --- | --- |
| E1.1 | after **every** restart, the policy label on `:9110` is the one just configured | any observation shows the previous policy |
| E1.2 | `stargz_cache_index_lock_lost_total` reads **0** at every observation | ≥ 1 at any point — a process ran unenforced |
| E1.3 | exactly **one** open fd on the index at every observation | 0 (no accounting) or ≥ 2 (a leak) |
| E1.4 | the manager pid is unchanged across all six restarts (precondition) | manager replaced — the rig is not reproducing the scenario and E1.1 proves nothing |
| E1.5 | no `cache-accounting.db.corrupt` at any point | the file appears |
| E1.6 | `stargz_cache_index_lock_retry_total` is reported; its value is recorded either way | absent from the endpoint |
| E1.7 | all `stargz_cache_*`/`stargz_fs_cache_*` series present on `:9110` with the manager's own endpoint unset | any absent — F2 regressed |

E1.6 is deliberately not a pass/fail. A non-zero retry count would mean the
ordering fix did not remove the race and the retry is carrying it, which is worth
knowing and is not a failure of the node; zero means the ordering alone is
sufficient. Both are reportable results.

### 1.4 Negative control

The same procedure on `9829d7cf` (the v6 SUT), with
`[fuse_manager] metrics_address = 0.0.0.0:9111` so its metrics are reachable.

| id | expectation | falsifier |
| --- | --- | --- |
| N1.1 | `index_lock_lost_total` reaches ≥ 1 within six restarts | stays 0 — v6's C1 does not reproduce, and E1's before/after is **void** |
| N1.2 | at least one observation shows 0 processes holding the index | never — same |
| N1.3 | at least one observation shows the policy label lagging the config | never — same |

---

## 2. E2 [P0] — C4 fixed, live: the budget must hold under a flooded queue

The direct falsifier for the more serious of v6's two P0 findings.

### 2.1 Procedure

`budget = 80 GB` on the 92 GB partition. Run the 140 GB sweep — the same
workload that produced C4 — and sample every 10 s: `stargz_cache_bytes_used`,
the new `stargz_fs_cache_pressure_bytes`, `du -sb` over both cache trees, `df`,
dropped events, evictions, `writes_skipped`, and rebuild-in-progress.

To make the flood adversarial rather than incidental, a second arm runs the same
sweep with `[cache_accounting] queue_size = 256` — 32× below the shipped default,
chosen to guarantee heavy dropping rather than to hope for it.

### 2.2 Expectations

| id | expectation | falsifier |
| --- | --- | --- |
| E2.1 | `df` on `/cache-part` **never reaches 100%** in either arm | it does — C4 is not fixed |
| E2.2 | `du -sb` over the cache trees stays at or below `budget × 1.05` throughout | a sustained excess beyond block-rounding |
| E2.3 | drops occur in both arms (`dropped > 0`), so the run actually exercises the defect | no drops — the arm is not a test of C4 and must be rerun with a smaller queue |
| E2.4 | `pressure_bytes ≥ bytes_used` whenever `dropped > 0` | pressure below the index total means the correction is not applying |
| E2.5 | where the index under-counts, pressure tracks `du` to within 10% | a large gap means the filesystem signal is not being used |
| E2.6 | the snapshotter is **startable** at the end of each arm (`systemctl restart` succeeds) | it is not — the v6 end state, which is the failure in its most consequential form |
| E2.7 | zero read errors from the sweep pod, both arms | any EIO |

E2.1 and E2.6 are the two that matter. The first says the partition survived;
the second says the node did.

### 2.3 Reconciliation rescan

The fix includes a rescan that runs when eviction has exhausted its candidates
while the filesystem still reports over budget. Whether it fires is a fact to
record, not an expectation: `stargz_cache_index_rebuilds_total` and the
`rebuilding` gauge are sampled throughout, and the report states how many rescans
ran, how long each took, and whether occupancy came down afterwards.

---

## 3. E3 [P0] — the price of eviction, with the adaptive warm-up

### 3.1 What changed since v6

v6's gate G1 (arms share a baseline) **passed** at 1.8%. Its gate G2 (the
reference pass is converged) failed on two of four arms, because the protocol
used a fixed three passes and never checked convergence. The fix — warm until two
consecutive passes agree within the same 5% the gate tests, then use the last —
is written and has not run.

Bootstrap on v6's data rules out sampling noise as the cause: two 28-sample
medians drawn from one arm's own distribution differ by >5% in 0.0% of 4000
resamples.

### 3.2 Design

ABBA crossover as in v6, but **N = 4 per policy**, eight arm-runs in the order
`lru 2q 2q lru lru 2q 2q lru`. v6 ran N=2 and found the within-policy spread
(112 ms at p50) exceeding the between-policy gap, so N=2 cannot separate the
policies whatever it measures. Four gives the effect-size rule something to work
with and leaves a run spare if one arm is invalidated.

Per arm: apply policy, full reset, verify accounting live (open index fd **and**
an unmoved lock counter — v6's first health check was fooled by a stale collector
still exporting the previous index's values), cold pass, then adaptive warm
passes to convergence, then 4 measured rounds under the concurrent sweep.

### 3.3 Gates, unchanged from v6

- **G1** — the eight warm references agree within 5% of their mean.
- **G2** — within each arm, the reference pass is within 5% of the one before.

An arm that does not converge within 7 passes is marked INVALID and excluded; if
more than two arms are excluded, E3 reports no comparison.

### 3.4 Expectations

| id | expectation |
| --- | --- |
| E3.1 | G1 and G2 pass for at least 6 of 8 arms |
| E3.2 | resident p50/p95/p99 under sweep **lower under 2q than lru** |
| E3.3 | derived hit-rate higher under 2q, against the **pooled** threshold |
| E3.4 | zero resident read errors, every arm |
| E3.5 | `writes_skipped = 0` every arm (the budget binds before the disk fills) |
| E3.6 | the effective policy label is `2q` (not only `2q-unpromoted`) on 2q arms |

**Effect-size rule, N=4.** A difference counts as observed only if the gap
between the policy medians exceeds the larger of the two within-policy ranges.
If it does not, the finding is **"not separable at N=4"**, and that is reported
as the result rather than as a failure. A negative result here is a real answer
to RQ1 and will be written up as one.

---

## 4. E4 [P1] — pressure at 90%, N=2, on the fixed code

v6's E3, rerun on `6e87e34e` so the paper's main table describes shipped code.

| id | expectation | falsifier |
| --- | --- | --- |
| E4.1 | ours: 280/280 files, 0 errors, both reps | any read error |
| E4.2 | vanilla v0.18.2: the failure reproduces | it does not — the comparison is **void** |
| E4.3 | ours: `writes_skipped > 0` | zero — pressure never reached the cache-write path |
| E4.4 | completion time recorded per rep | — |

v6 measured ours 280/280 with 0 errors in both reps and vanilla 7/280 with 273
EIO in both. If the fixed code changes either side of that, it is a regression
and is reported as one.

---

## 5. Operating rules

Binding, and listed so that invoking one is not a judgement call made late.

1. **Collect after every experiment.** Each experiment ends by tarring its
   bundle and retrieving it to the workstation. An uncollected experiment is
   unfinished, and the next one does not start.
2. **Snapshot before experiments.** As soon as the 140 GB image is built and
   pushed, take an EBS snapshot of the registry's data volume, **verify it is
   readable** (attach it to a volume and read the manifest back), and record the
   snapshot ID and its monthly cost in the report. This is the only resource
   that outlives the run.
3. **A bug in our code stops the experiment that hit it**, is recorded, and is
   **not patched on the rig**.
4. **Environment bugs are fixed on the rig** and recorded.
5. **A void control voids its comparison** (N1.* for E1, E4.2 for E4).
6. **Every started trial is preserved**, including the bad ones, renamed
   `*-INVALID` with a `WHY-INVALID.txt`.
7. **Nothing runs in parallel with a measurement** — v5's F11.
8. Teardown verifies **0 instances, 0 volumes, 0 AMIs**, and exactly **one**
   snapshot: the one from rule 2.

## 6. What would make this spike a failure

- E1's or E2's negative control does not reproduce v6's defect, leaving the
  fixes unvalidated live for a second round.
- E2.1 or E2.6 fails: the partition or the node still dies under a flooded
  queue, and C4 is not fixed.
- E3's gates fail again, leaving the price of eviction unmeasured for a third
  consecutive spike.
- The snapshot is taken and turns out not to be readable, which would mean the
  rule adopted to stop paying for rebuilds does not work either.

Any of these is a legitimate outcome and will be reported as one.
