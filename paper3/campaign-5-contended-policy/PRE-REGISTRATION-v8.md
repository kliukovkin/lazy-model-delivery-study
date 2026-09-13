# Spike v8 — pre-registration

Written **before** the rig is launched. §§1–6 are not edited afterwards;
amendments go in §7 with the time they were made.

- authored: 2026-09-12
- builds under test:
  - **`6e87e34e1d8da4ca10e44b81a1891d583a4e66d5`** — head of fix round 2 (the
    build the paper's numbers will come from)
  - **`9829d7cf43fc645a28d2a79e86fe614d62764833`** — head of fix round 1, the
    build v6 measured
- rig: 2× `i4i.2xlarge`, us-east-1, restored from **`snap-0118cc5716e9e8a54`**
  — no image rebuild.
- budget 80 GB on the 92 GB `/cache-part`, `[fuse_manager] enable = true`,
  `KillMode=process`, `metrics_address` unset.

This is the last measuring spike. It closes the two tails §10 of RUN-REPORT-v7
left open, and it is meant to produce two numbers the paper can quote.

---

## 0. Two things settled before launch, so they are not rediscovered mid-run

**No code change is needed for the profiling.** The task asks for a rescan
duration line; `cache/accounting/scan.go` `rescan()` already emits
`log.L.WithField("duration", time.Since(start))`. Time spent in `statfs` will be
measured **externally with `strace -c -f -e trace=statfs`** against the running
FUSE manager, not by instrumenting the binary. That matters: the price figure the
paper quotes has to come from the shipped `6e87e34e`, and a binary carrying
timing instrumentation is not that build. If a profiled arm is needed it will be
a separate, clearly-labelled binary, used for attribution only and never for the
headline number.

**The restored volume is pre-warmed before any measurement.** A volume created
from a snapshot loads its blocks lazily from S3 on first touch. Reading 150 GB of
image through that during a timed experiment would measure S3, not the
snapshotter. The whole device is read to `/dev/null` once, and the time that
takes is recorded, before anything is measured.

---

## 1. E1 [P0] — attributing the 16%

### 1.1 What is being tested

RUN-REPORT-v7 §5.2 recorded our arm completing a 150 GB sweep in 1432.9 / 1454.7 s
against v6's 1235.4 / 1240.9 s on `9829d7cf` — about 16% slower, consistent
across both reps. It named fix round 2 as the obvious suspect and explicitly
declined to claim it, because the two spikes ran on different instances on
different days and their `writes_skipped` differed.

E1 removes that confound: both builds, one session, one instance, identical
pre-fill, alternating.

### 1.2 Design

`prefill = 50%`, full 280-file sweep, **N = 2 per build**, order **A B A B**
(`9829d7cf`, `6e87e34e`, `9829d7cf`, `6e87e34e`). Alternating rather than
grouped, so a monotonic drift across the session shows up as the two reps of one
build disagreeing rather than as a difference between builds.

Each arm: install the build, `hard_reset`, verify the accounting index is live,
deploy the sweep pod, read all 280 files, record wall clock and every counter.

### 1.3 The hypotheses, stated in advance

**H0 — the difference is between-session variation, not the code.** This is the
outcome I consider most likely, and saying so before the data exists is the
point. At 50% pre-fill the 92 GB partition leaves ~46 GB for cache against an
80 GB budget, so **the budget never binds and eviction never runs**. In that
regime fix round 2's extra work is one `statfs` per drain plus a few arithmetic
operations — nanoseconds against a 24-minute sweep. The same was true of v7's E4
at 90% pre-fill, where the 16% was observed. There is no mechanism in the diff
that plausibly costs 16% when eviction is not running.

**H1 — fix round 2 really is slower**, by some path not yet identified.

| id | expectation | falsifier |
| --- | --- | --- |
| E1.1 | both builds complete 280/280 with 0 read errors, all four arms | any read error |
| E1.2 | the per-build mean sweep times differ by **less than the larger within-build range** | they differ by more — H1, and §1.4 applies |
| E1.3 | `dropped = 0` and `evictions = 0` in every arm, confirming the budget never bound | either non-zero — the regime is not what §1.3 assumes and the reasoning above must be revisited |

E1.2 uses the same effect-size rule as v7's E3: a difference counts only if it
exceeds the within-build spread. **If E1.2 passes, the honest conclusion is that
the 16% was cross-session variation and RUN-REPORT-v7 §5.2's suspicion is
withdrawn** — which is the result I expect and will report as readily as the
other one.

### 1.4 Profiling, only if the difference is real

Run only if E1.2 fails. Coarse by design:

1. `strace -c -f -p <fuse-manager pid>` for a 60 s window mid-sweep on each
   build, recording `statfs` call count and total time.
2. `grep` the manager log for reconciliation rescans and their already-logged
   durations.
3. Report both as a fraction of the sweep wall clock.

If `statfs` plus rescans account for less than a tenth of the observed
difference, the report says the difference is real and **unexplained**, rather
than assigning it to the nearest available suspect.

---

## 2. E2 [P0] — the decisive RQ1 arm

### 2.1 Why this one is decisive

v7's E3 found lru and 2q not separable at N=4, and §10.1 named the reason: a
14 GB hot set against an 80 GB budget is so comfortable that lru retains it
anyway, so scan resistance has nothing at risk to protect. E2 puts the hot set
**at** the budget, which is the only regime where the two policies can differ.

**Pre-registered in advance: if 2q is not separable here either, the negative is
final.** No further RQ1 measurement will be proposed, and the paper will state
that on this workload class the eviction policy does not measurably affect
resident read latency. That commitment is made now, before the data, so that a
null result cannot be answered with one more experiment.

### 2.2 Design, and one deviation from the task

Hot set **~70 GB**, budget 80 GB, resident pod re-reading it while a sweep runs
beside it. lru and 2q, warm gate ≤5% as in v7, adaptive warm-up, **N = 2 per
policy**, ABBA.

**Deviation, disclosed:** the task says a 140 GB sweep. The snapshot carries one
large image (280 files, 150 GB) and one small one (14 GB), and rebuilding is
explicitly out of scope. A 70 GB hot set and a 140 GB sweep cannot both come from
a 150 GB image **and be disjoint** — and they must be disjoint, or the sweep's
own reads promote the hot set's chunks and destroy the distinction the experiment
exists to measure.

So: the resident reads **files 1–130** (~70 GB) and the sweep reads **files
131–280** (~80 GB), from the same image but with no chunk in common. Total
working set ~150 GB against an 80 GB budget on a 92 GB partition. The pressure
ratio — working set nearly twice the budget, hot set at 88% of it — is what makes
this the decisive regime, and it is preserved.

### 2.3 Expectations

| id | expectation |
| --- | --- |
| E2.1 | gates G1 (arms share a warm baseline within 5%) and G2 (each arm converged) pass |
| E2.2 | resident p50/p95/p99 **lower under 2q than lru**, by more than the within-policy spread |
| E2.3 | zero resident read errors, every arm |
| E2.4 | evictions > 0 in every arm — with a 150 GB working set against an 80 GB budget, eviction must run or the experiment applied no pressure |
| E2.5 | the effective policy label is `2q` (not only `2q-unpromoted`) on the 2q arms |

E2.2 is the one under test. Its falsifier is the finding: **not separable, and
final.**

---

## 3. E3 [P2] — the C4 rate ceiling

Runs only if E1 and E2 are complete and time and budget allow. Skipping it is a
legitimate outcome and will be recorded as such rather than rushed.

### 3.1 What is being asked

v7 showed the budget holding through 301,322 dropped updates with a 256-deep
queue. It did not bound the write rate at which the reconciliation rescan stops
converging. E3 looks for that ceiling coarsely.

**Knob: concurrency.** 1, 2 and 3 sweep pods reading disjoint file ranges,
multiplying the write rate into the cache roughly linearly. `queue_size` is left
at 256 so that dropping is guaranteed at every point.

| id | expectation |
| --- | --- |
| E3.1 | at 1 pod the budget holds (this is v7's result, re-confirmed as the control point) |
| E3.2 | the report states, for each concurrency, whether `df` stayed bounded and whether occupancy returned below the high watermark after each rescan |

No hypothesis is pre-registered about where the ceiling is. Two or three points
locate it between two concurrencies or show it is above the rig's capacity; both
are reportable.

---

## 4. Rig from the snapshot

The first use of `snap-0118cc5716e9e8a54`, and therefore also a test of whether
v7's snapshot discipline actually pays.

1. Launch both hosts; the registry gets a volume **restored from the snapshot**
   instead of a blank one.
2. Mount it, start the registry against the restored blob store, and confirm all
   four tags resolve.
3. **Pre-warm**: read the whole device to `/dev/null`, record how long it takes.
4. Record the wall clock from launch to first-experiment-ready, against v7's
   ~2 h 45 m of building.

| id | expectation |
| --- | --- |
| E0.1 | all four image tags resolve from the restored registry |
| E0.2 | a pod can pull and read from the restored registry |
| E0.3 | time-to-ready is recorded and compared with v7's build time |

If the restore fails, v8 falls back to rebuilding and **that is the headline
result**: the snapshot discipline did not work and the rule needs rethinking.

---

## 5. Operating rules

Unchanged from v7, and binding.

1. **Collect after every experiment**, retrieved to the workstation before the
   next begins.
2. **A bug in our code stops the experiment that hit it**, is recorded, and is
   **not patched on the rig**. Instrumentation for §1.4, if needed, is a
   separate labelled binary and never the source of a quoted number.
3. **Environment bugs are fixed on the rig** and recorded.
4. **Nothing runs in parallel with a measurement.**
5. **Every started trial is preserved**, bad ones renamed `*-INVALID` with a
   `WHY-INVALID.txt`.
6. Teardown verifies **0 instances, 0 volumes, 0 AMIs**, and exactly **one**
   snapshot: `snap-0118cc5716e9e8a54`, which survives.
7. Ceiling $100, a runaway guard rather than a limit on experiments.

## 6. What would make this spike a failure

- E1 cannot distinguish the builds because the arms disagree with themselves —
  the 16% stays unattributed after a second attempt.
- E2's gate fails, leaving RQ1 unresolved for a fourth spike.
- The snapshot does not restore, making v7's central operational lesson wrong.

Any of these is a legitimate outcome and will be reported as one.
