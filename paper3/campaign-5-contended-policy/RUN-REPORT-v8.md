# Spike v8 — the last measuring spike

**STATUS: COMPLETE**, with one experiment answered cleanly, one answered
partially, and one skipped. Facts are kept separate from interpretation.

- pre-registration: [`PRE-REGISTRATION-v8.md`](PRE-REGISTRATION-v8.md), locked
  before launch.
- E0 finding: [`results/E0-FINDING.md`](results/E0-FINDING.md)

| experiment | question | outcome |
| --- | --- | --- |
| **E0** | does the v7 artifact snapshot save a rebuild? | **partly — and it is slower than rebuilding as implemented** |
| **E1** [P0] | is the 16% attributable to fix round 2? | **no. +0.2% same-session against +16.4% cross-spike. Suspicion withdrawn** |
| **E2** [P0] | are lru and 2q separable with the hot set at the budget? | **gate failed at 6.1%; no comparison computed. The facts show no advantage for 2q** |
| **E3** [P2] | the C4 rate ceiling | **not run** — E2 took 5 h against a 2 h estimate |

---

## 1. What was run, and on what

| | |
| --- | --- |
| builds | `6e87e34e` (fix round 2) and `9829d7cf` (fix round 1) |
| rig | 2× `i4i.2xlarge`, us-east-1; node `i-02c8a923b2bda755b`, registry `i-013339713dd82cd34` |
| registry data | `vol-017c001b8c55b4042`, **restored from `snap-0118cc5716e9e8a54`** — no image rebuild |
| budget | 80 GB on the 92 GB `/cache-part` |
| launched / torn down | 2026-09-12T04:24Z → 14:40Z (≈ 10 h 15 m) |

---

## 2. E0 — the snapshot, measured

Full detail in `results/E0-FINDING.md`. The short form:

| | |
| --- | --- |
| restore worked | filesystem detected and **not** reformatted; 463 GB present; all four tags resolved 200 |
| launch → registry serving images | **~6 minutes** |
| **but: lazy load from S3** | 15 MB/s (`xargs -P 4`), 48 MB/s (`-P 48`), 15 MB/s (fio iodepth 32), **14 MB/s through the snapshotter's own concurrent fetches** |
| pre-warm cost | **2 h 57 m** (10,591 s for the full 150 GB pull, 280/280 files, 0 errors) |
| after warming | **1.6 GB/s** on the same blob — a 114× difference |

```
v5 / v6 / v7:  build the image                       ≈ 1 h 40 m
v8:            restore (6 min) + warm (2 h 57 m)     ≈ 3 h 03 m
```

**Interpretation.** The snapshot restores correctly and quickly; what it does not
do is make the data *readable* quickly. `estargz-140g` is 11 blobs, so there is
almost nothing for local concurrency to work with, and even the snapshotter's own
many-ranged-fetch pattern ran at the same 14 MB/s. **As implemented, v7's
snapshot rule costs more than the rebuild it replaced.** That contradicts what
v7 §9 claimed for it, on the basis of an argument that had never been tested.

The fix is **Fast Snapshot Restore**, pre-enabled on the snapshot for the target
AZ: about $0.75/hour per snapshot-AZ against three hours of two-host time. Any
future spike on this lineage should enable it before launching.

One methodological note against myself: an early `fio --iodepth=64` on raw device
offset 0 reported 177 MB/s and sent me down two dead ends. Those blocks had
already been touched by the mount. The number was real and the inference from it
was not.

---

## 3. E1 [P0] — the 16%, attributed

### 3.1 Facts

50% pre-fill, full 280-file sweep, four arms, order `9829d7cf`, `6e87e34e`,
`9829d7cf`, `6e87e34e`.

| run | build | sweep (s) | reads | dropped | evictions | writes_skipped |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `9829d7cf` | 1353.6 | 280/0 | 0 | 2,588,671 | 268 |
| 2 | `6e87e34e` | 1368.7 | 280/0 | 0 | 2,580,479 | 426 |
| 3 | `9829d7cf` | 1362.1 | 280/0 | 0 | 2,584,575 | 260 |
| 4 | `6e87e34e` | 1351.2 | 280/0 | 0 | 2,584,575 | 265 |

```
between-build gap  2.1 s          max within-build spread  17.5 s   ->  NOT SEPARABLE
cross-spike   v6 1235.4 / 1240.9   v7 1432.9 / 1454.7   +16.4%
same session  9829d7cf 1353.6 / 1362.1   6e87e34e 1368.7 / 1351.2   +0.2%
```

Score 2/3. E1.1 and E1.2 passed; **E1.3 failed.**

### 3.2 Interpretation

**The 16% was cross-session variation. RUN-REPORT-v7 §5.2 named fix round 2 as
the suspect and declined to convict; v8 acquits it.** Same instance, same
session, alternating: the two builds differ by 0.2%, an eighth of the
within-build spread. The profiling in §1.4 of the pre-registration was
conditional on this failing and was therefore not run.

**E1.3 failed because my expectation was wrong, not the system.** I predicted
zero evictions, reasoning that at 50% pre-fill the 80 GB budget exceeds the ~46 GB
of available space and so never binds. Evictions were 2.58 M per arm. The path I
overlooked: the partition fills (`df` 97.6 of 97.8 GB), cache writes hit ENOSPC,
and `Reclaim()` runs emergency eviction independently of the budget. The
behaviour is correct; the pre-registered reasoning was incomplete.

It does not harm E1.2 — both builds met the identical regime with eviction counts
within 0.3% of each other — and it means the comparison covered more of the code
than intended.

**What E1 does not establish.** With `dropped = 0`, `pressureBytes()` returns
before calling `statfs`, because `lossy()` gates it. So E1 shows fix round 2
costs nothing measurable **when the queue never overflows**; it does not measure
the `statfs` path, which engages only while updates are being dropped. That
regime is v7's E2, where both arms completed 280/280 and no slowdown was
observed, but it was never timed against the previous build.

---

## 4. E2 [P0] — the decisive RQ1 arm

### 4.1 Facts

Hot set files 1–130 (~70 GB, **88% of the budget**), sweep files 131–280 (~80 GB),
disjoint. ABBA, N=2 per policy, adaptive warm-up.

| run | policy | warm ref p50 | under-sweep p50 | p95 | p99 | n | errors | evictions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | lru | **4512.3** | 4515.9 | 5420.9 | 5762.0 | 520 | 0 | 10,768,380 |
| 2 | 2q | 4890.5 | 4926.5 | 5824.8 | 6399.2 | 520 | 0 | 10,545,161 |
| 3 | 2q | 4849.8 | 4995.5 | 5836.1 | 6141.3 | 520 | 0 | 10,350,794 |
| 4 | lru | 4963.9 | 4929.2 | 5862.2 | 6511.9 | 520 | 0 | 10,645,092 |

```
G0  PASS  4 of 4 arms valid
G1  FAIL  warm refs 4512.3 4890.5 4849.8 4963.9 ; mean 4804.1 ; max deviation 6.1%  (tolerance 5%)
G2  PASS  per-arm convergence 0.1% 1.9% 0.3% 2.1%
```

**No comparison was computed**, per the binding rule.

Every arm: **0 resident read errors**, `writes_skipped = 0`, ~10.5 M evictions,
and the 2q arms carry `2q,2q-unpromoted`.

### 4.2 Interpretation

**The gate failed narrowly, and on one arm.** Run 1's warm reference is 6.1%
below the mean; runs 2–4 agree with each other to within **1.3%**. Run 1 is the
first arm after the pre-warm, so the most likely cause is that it inherited a
machine state the later arms did not — which is exactly the confound the gate
exists to catch, and exactly why it is applied before the comparison rather than
after.

**The regime was right.** ~10.5 M evictions per arm against v7's 2.4 M, and
per-file latency of ~4.5 s against v7's ~0.52 s, confirm the hot set was genuinely
contended: at 88% of the budget with an 80 GB sweep beside it, the resident's
working set was being evicted and re-fetched. This is the regime v7 §10.1 said
was needed, and v8 reached it.

**What the facts show, recorded as facts and not as a comparison.** Under-sweep
p50 was lru 4515.9 / 4929.2 (mean 4722.5) and 2q 4926.5 / 4995.5 (mean 4961.0).
The between-policy gap is 238.5 ms against a within-policy spread of 413.3 ms, so
even with a passing gate this would have read **not separable** — and the
direction is **2q 5.0% slower**, not faster.

**On the pre-registered commitment.** §2.1 said that if 2q were not separable
here the negative would be final. Strictly, the gate failed, so "not separable"
was not formally established, and I am not going to claim the commitment
discharged on data that did not meet its own entry condition. What can be said:

- v7's E3 established not-separable at N=4 **with a passing gate**, on a
  comfortable hot set.
- v8 reached the contended regime and found **no advantage for 2q**, with the
  trend against it, on a gate that failed by 1.1 percentage points.
- Across the whole campaign — v5, v6, v7, v8 — there is **no positive evidence
  anywhere that 2q improves resident read latency**, and the one striking number
  that suggested it (v5's `hit_rate 0.143 vs 1.000`) was shown in v7 to be an
  artefact of unmatched baselines.

**Recommendation for the paper:** quote the negative from **v7's E3**, which had
a passing gate and N=4, and cite v8 as consistent supporting evidence whose gate
failed. Do not present v8's numbers as a comparison.

---

## 5. E3 [P2] — not run

E2 took 5 hours against a 2-hour estimate, because a 70 GB hot set makes every
adaptive warm pass a 70 GB read. That consumed the window E3 would have used.

Skipping it was pre-registered as a legitimate outcome (§3). The C4 rate ceiling
remains unmeasured, and the cheap version of it — the write rate at which
reconciliation stops converging — is still worth an hour on a future rig.

---

## 6. Pre-registration scorecard

| id | expectation | outcome |
| --- | --- | --- |
| E0.1 | all four tags resolve from the restored registry | **CONFIRMED** |
| E0.2 | a pod can pull and read from it | **CONFIRMED** (280/280, 0 errors) |
| E0.3 | time-to-ready recorded and compared | **CONFIRMED**, and the comparison is unfavourable |
| E1.1 | 280/280, 0 errors, all four arms | **CONFIRMED** |
| E1.2 | builds differ by less than the within-build spread | **CONFIRMED** — 2.1 s vs 17.5 s |
| E1.3 | dropped and evictions both zero | **FALSIFIED** — my reasoning omitted the ENOSPC reclaim path |
| E2.1 | gates G1 and G2 pass | **G2 PASS, G1 FAIL at 6.1%** |
| E2.2 | 2q faster than lru by more than the spread | **NOT COMPUTED** — gate binding |
| E2.3 | zero resident read errors | **CONFIRMED** (2,080 measured reads) |
| E2.4 | evictions > 0 | **CONFIRMED** (~10.5 M per arm) |
| E2.5 | effective policy label is 2q | **CONFIRMED** |
| E3.* | rate ceiling | **NOT RUN** |

---

## 7. Cost and teardown

| | |
| --- | --- |
| instances | 2 × `i4i.2xlarge` @ $0.686/h, ≈ 10 h 15 m |
| compute | ≈ **$14.1** |
| EBS (1200 GB restored volume + roots) | ≈ **$1.3** |
| **total** | **≈ $15.4 of the $100 ceiling** |

Teardown verified (`results/TEARDOWN-VERIFICATION.txt`): **0 instances,
0 volumes, 0 AMIs, 1 snapshot** — `snap-0118cc5716e9e8a54`, which survives.

Of the 10 h 15 m, **3 h** was the snapshot pre-warm and **5 h** was E2. The
remaining ~2 h covered setup, E1 and teardown.

---

## 8. What this spike does not establish

1. **RQ1 is not formally closed by v8.** E2's gate failed, so its comparison was
   not computed. The campaign's negative rests on v7's E3.
2. **The `statfs` overhead is still unmeasured.** E1 ran with `dropped = 0`,
   where the code path is never entered. Timing it needs an A/B in the lossy
   regime — v7's E2 conditions with both builds.
3. **The C4 rate ceiling** is unmeasured; E3 was not run.
4. **Whether Fast Snapshot Restore fixes E0** is inferred from AWS's
   documentation, not measured here.
