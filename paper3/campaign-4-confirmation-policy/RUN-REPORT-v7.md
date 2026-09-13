# Spike v7 — does fix round v6 work on a rig, and what does eviction cost?

**STATUS: COMPLETE.** All four experiments ran, were scored against the
pre-registration, and their bundles were collected and retrieved.

- pre-registration: [`PRE-REGISTRATION-v7.md`](PRE-REGISTRATION-v7.md), locked
  before launch; §7 carries any amendment and when it was made.
- live fixes: [`results/LIVE-FIXES-v7.md`](results/LIVE-FIXES-v7.md)
- artifact snapshot: [`results/snapshot/`](results/snapshot/)

---

## 1. What was run, and on what

| | |
| --- | --- |
| system under test | `c2-eviction` @ `6e87e34e1d8da4ca10e44b81a1891d583a4e66d5` — head of fix round v6 |
| negative control | same fork @ `9829d7cf43fc645a28d2a79e86fe614d62764833` — head of fix round v5, the commit v6 measured |
| vanilla control | upstream `v0.18.2` |
| rig | 2× `i4i.2xlarge`, us-east-1; node `i-0d30e88cfa319aa03`, registry `i-004d004f93671ea81` |
| registry data | **600 GB gp3 EBS at 750 MB/s** (`vol-028c6acbe8d7e2007`), not the instance store — so the artifacts can be snapshotted |
| node cache | `/dev/nvme1n1p2` → `/cache-part`, 92 GB instance-store partition |
| budget | `bytes = 80000000000`, high 0.95, low 0.85 |
| fuse manager | `enable = true`, `KillMode=process`, `metrics_address` **unset** |
| launched | 2026-09-11T16:57Z |

---

## 2. E1 [P0] — C1 fixed, live

### 2.1 Facts

`[fuse_manager] metrics_address` unset; scrapes of the documented endpoint only;
the gesture between observations is `systemctl restart stargz-snapshotter` and
nothing else. Eight restarts on the SUT (six pre-registered plus two from live
fix G9), six on the control.

**System under test, `6e87e34e` — every one of 18 observations identical in the
columns that matter:**

| | value at every observation |
| --- | --- |
| policy label | **matches the config it was just given** |
| `stargz_cache_index_lock_lost_total` | **0** |
| open fds on the index database | **1** |
| `stargz_cache_index_lock_retry_total` | **0** |
| `.corrupt` files | **0** |
| cache series on `:9110` | **41** |
| fuse-manager pid | **5375** throughout |

Score **6/6**.

**Negative control, `9829d7cf` — the defect reproduces, and it alternates:**

| restart | → policy | `lock_lost` | open index fds | label |
| --- | --- | --- | --- | --- |
| 1 | 2q | 0 → **1** | 1 → **0** | stuck `lru` |
| 2 | lru | 1 | 1 | `lru` |
| 3 | 2q | 1 → **2** | **0** | stuck `lru` |
| 4 | lru | 2 | 1 | `lru` |
| 5 | 2q | 2 → **3** | **0** | stuck `lru` |
| 6 | lru | 3 | 1 | `lru` |

Score **3/3**: `index_lock_lost_total` reached 3, open fds hit 0 on three
observations, and the label lagged its config on six.

### 2.2 Interpretation

**C1 is fixed, and the before/after is valid because the control fails on the
same rig, in the same session, under the same procedure.**

The alternation is worth stating precisely: **every odd restart loses the index
lock and every even one wins**, because a restart that finds no incumbent index
has nothing to race. Two restarts would have produced one pass and one failure
and been readable either way. Six was chosen in the pre-registration for exactly
this reason, and the control demonstrates the parity effect directly rather than
leaving it inferred from v6.

**The retry never fired.** E1.6 was pre-registered as reportable either way, and
zero is the stronger of the two answers: the *ordering* change removed the race,
rather than the bounded retry absorbing it. Had it been non-zero, the claim would
have been "works, with a safety net catching it" — materially weaker.

**`index_open_fds` is the observable that made this checkable.** v6's first health
check was fooled because a dead index leaves the metrics collector bound to its
predecessor, still exporting plausible values. Counting open file descriptors on
the database distinguishes "one live index" from "none" and from "two", and it is
what turns the control's failure into something visible rather than inferred.

## 3. E2 [P0] — C4 fixed, live

### 3.1 Facts

The 140 GB sweep against an 80 GB budget on a 92 GB partition — the workload that
produced C4 — run twice: once at the shipped `queue_size = 8192`, once at 256 so
that dropping is guaranteed rather than incidental.

| arm | queue | dropped updates | peak `du` | peak `df` | evictions | `writes_skipped` | reads | startable after |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| default | 8192 | 190,158 | 78.0 GB | 80.8 GB | 2.31 M | 0 | 280/0 | **yes** |
| tiny | 256 | **301,322** | 76.4 GB | 80.8 GB | 2.13 M | 0 | 280/0 | **yes** |

Score **7/7**. Reconciliation rescans observed: 3 in the default arm, 4 in the
tiny arm.

A sample from the middle of the default arm, where the mechanism is visible:

```
23:05:06   index 75.7 GB   du 75.3 GB   df 78.9 GB   pressure 79.7 GB   occ 0.996   dropped 4,816
```

Pressure is deliberately **ahead** of the index, driving occupancy to 0.996 and
provoking eviction the index alone would not have triggered.

### 3.2 Interpretation

**C4 is fixed.** v6 reached 100% of the partition on 127,337 dropped updates and
left a snapshotter that would not start. v7 absorbed **301,322** — 2.4× more —
and held the cache trees at 76 GB against an 80 GB budget, with `df` peaking at
88% of the partition and the node restarting cleanly.

**The reconciliation rescan is load-bearing, not decorative.** It fired 3–4 times
per arm. That is the path for the case where eviction has given up every chunk it
knows about and the filesystem still reports over budget — v6's worst state had
the index holding *zero* accounted bytes against 94 GB on disk, and a trigger
alone cannot evict its way out of that.

**The residual predicted before the run showed up, bounded.** §3's caveat — that
a rescan racing with writes leaves the non-cache share over-estimated and
pressure under-estimated — was measured at a worst gap of **12.3% / 12.8%**, on
**3 of ~95 samples** per arm. Real, transient, and never near the 12 GB of
headroom. E2.4 recorded **zero** samples where pressure fell below the index
total while updates were being dropped.

### A residual this experiment is asked to measure

`nonCacheBytes` is measured at each reconciliation as
`filesystem used − index total`. If a rescan's tree walk races with writes, the
index total is short, so the non-cache share comes out too large and the
filesystem-derived cache occupancy too small — the unsafe direction. The
magnitude is bounded by what lands during the walk: ~13 s for 1.5 M files at
v6's observed ~15 GB/min is about 3 GB, against 12 GB of headroom on the shipped
geometry.

This is not asserted to be harmless. E2.5 measures it directly, by requiring
pressure to track `du` within 10% on the samples where updates are being
dropped, and the report states what was observed rather than what was hoped.

## 4. E3 [P0] — the price of eviction

### 4.1 Facts

ABBA crossover, `lru 2q 2q lru lru 2q 2q lru`, N=4 per policy. Each arm: policy
applied, full reset, accounting verified live, cold pass, adaptive warm passes to
convergence, then 4 measured rounds of a 14 GB resident hot set under a
concurrent 140 GB sweep.

**Gate — passed, for the first time in three spikes.**

```
G0  8 of 8 arm-runs valid
G1  warm references: 610.9 584.4 568.2 578.3 609.8 579.7 566.8 569.4
    mean 583.4, max deviation 4.7%   (tolerance 5%)
G2  per-arm convergence: 1.2% 1.8% 4.1% 0.8% 1.1% 0.3% 4.7% 3.8%
```

Arms needed **3, 4 or 5** warm passes to converge. No fixed count would have been
right for all of them, which is what broke v6.

**Comparison.**

| percentile | lru (mean of 4) | 2q (mean of 4) | between | largest within-policy range | verdict |
| --- | --- | --- | --- | --- | --- |
| p50 | 529.2 | 520.8 | 8.5 | 24.7 | **not separable** |
| p95 | 596.5 | 590.7 | 5.8 | 48.4 | **not separable** |
| p99 | 627.7 | 619.2 | 8.4 | **362.2** | **not separable** |
| hit rate (pooled) | ~1.000 | 1.000 | 0.000 | 0.054 | **not separable** |

Raw per-arm p50: lru 529.2 / 520.6 / 543.8 / 519.2; 2q 525.5 / 519.6 / 519.8 / 520.8.

Every arm: **0 resident read errors**, **0 `writes_skipped`**, 2.35–2.84 M
evictions.

All four 2q arms carry a non-zero `policy="2q"` series distinct from
`2q-unpromoted` (2.34 M, 2.72 M, 2.83 M, 2.77 M evictions), so the scan-resistant
ranking was genuinely active rather than degenerating to lru.

### 4.2 Interpretation

**The answer to RQ1, on this workload, is that the policy does not matter.**

Under the pre-registered effect-size rule, the difference between lru and 2q is
smaller than the spread between repetitions of the same policy, at every
percentile. This is a result, not a failed measurement: the gate passed, the arms
shared a baseline to within 4.7%, N=4 gives the rule something to work with, and
2q demonstrably did what it claims to do. It simply bought nothing measurable.

**It also retires v5's headline number.** v5 reported
`derived_hit_rate = 0.143` for lru against `1.000` for 2q — the most striking
figure that campaign produced. With matched baselines both policies sit at
~1.000. That difference was an artefact of v5's 21.6% baseline mismatch raising
2q's hit threshold, exactly as v6's diagnosis predicted, and it should not be
quoted anywhere.

**The tail signal that looked real at N=1 was noise.** After two arms, lru's p99
was 947.6 against 2q's 619.2, which is the shape scan resistance predicts. Four
arms later, lru's own p99 ranges 585.4–947.6 — a 62% spread within one policy.
The single high arm carried the apparent effect.

**What this does not say.** It does not say 2q is useless in general. It says
that on *this* workload — a 14 GB hot set re-read under a 140 GB sequential
sweep, 80 GB budget, 92 GB partition — the working set is small enough relative
to the budget that lru retains it anyway, so scan resistance has nothing to
protect that was at risk. A workload where the hot set is closer to the budget,
or where the sweep is larger relative to it, is where the two should diverge, and
that is the experiment worth running next rather than repeating this one at
higher N.

## 5. E4 [P1] — pressure at 90%, N=2, on fixed code

### 5.1 Facts

| arm | rep | ready | sweep | ok / 280 | errors | bytes | `writes_skipped` | evictions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **ours** `6e87e34e` | 1 | 1.37 s | 1432.9 s | **280** | **0** | 150,323,855,360 | 4,142 | 2,977,739 |
| **ours** | 2 | 1.89 s | 1454.7 s | **280** | **0** | 150,323,855,360 | 4,079 | 2,977,738 |
| vanilla `v0.18.2` | 1 | 1.89 s | 41.9 s | 7 | **273 EIO** | 4,127,195,136 | 0 | 0 |
| vanilla | 2 | 1.91 s | 27.4 s | 7 | **273 EIO** | 4,093,640,704 | 0 | 0 |

### 5.2 Interpretation

**No regression, and the control still reproduces.** Fix round 2 did not disturb
the pass-through behaviour: our build reads the entire 150 GB model with zero
errors at 90% pre-fill in both reps, while upstream reads 4.1 GB and fails 273 of
280 files.

`writes_skipped` of 4,079–4,142 confirms the out-of-space path was genuinely
exercised rather than the budget quietly having room, which is what makes the
zero-error result meaningful.

The control's **7/280 with 273 EIO** is identical to v5's and v6's figures,
across three rig instances on three different days.

**A completion-time difference, observed and not explained.** Our arm took
1432.9 / 1454.7 s here against v6's 1235.4 / 1240.9 s on `9829d7cf` — about 16%
slower, consistent across both reps, so not noise. Fix round 2 is the obvious
suspect: pressure is now read from `statfs` on every eviction decision and the
reconciliation rescan can fire. **This report does not claim that.** E4 was not
designed to attribute completion time, the two spikes ran on different instances,
and `writes_skipped` differs between them (4.1 k here against 6.5–8.0 k in v6),
which changes how much work the pass-through path did. Establishing it needs a
same-session A/B of the two builds under identical pre-fill, which is cheap and
is the obvious next measurement.

**One useful negative check on the C4 fix.** At 90% pre-fill only ~9 GB of the
partition is available for cache, far below the 80 GB budget, so the budget never
binds and the queue never overflows: `dropped = 0`, and pressure read 8.8 GB
against a `du` of 9.0 GB. The fix correctly did **not** inflate pressure where
there was nothing to correct — the complement to E2, where it ran deliberately
ahead of the index under 301 k dropped updates.

## 6. Findings and their status

| id | severity | found | status after v7 |
| --- | --- | --- | --- |
| **C1** — `Init` opened the new accounting index before releasing the old one | P0 | v6 | **fixed, confirmed live.** 8/8 restarts clean; control fails 3 of 6 |
| **C4** — a full accounting queue defeated the budget | P0 | v6 | **fixed, confirmed live.** 301 k dropped updates absorbed; partition peaked 88% |
| **C2** — the FUSE manager truncates its log on every start | P2 | v6 | unfixed, deliberately |
| **C3** — `blob_fetch_errors_total` counts background prefetch failures while the docs offer it as "reads are failing" | P2 | v6 | unfixed, deliberately |
| **completion-time difference** on E4 (~16% slower than v6) | — | v7 | **observed, not explained**; see §5.2 |

No new defect in the system under test was found by v7.

---

## 7. Live fixes

Environment and harness, recorded in `results/LIVE-FIXES-v7.md`.

| id | what |
| --- | --- |
| G7 | the bootstrap granted itself the `docker` group and then used docker in the same process; a process cannot see a group it was not started with. v6 survived this only because an unrelated crash forced a reconnect |
| G8 | the EBS data volume was sized from the artifacts (600 GB) when the constraint is the build's peak; hit 93% before the conversion started, grown to 1200 GB online with `modify-volume` + `resize2fs` while the build kept running |
| G9 | an edit removed less than it meant to, because `s.index()` matched an anchor that v6's own fix had duplicated; E1 ran 8 restarts instead of 6. No data invalidated |

Two of these — G7 and G8 — are hazards v5 and v6 avoided by accident rather than
design: v6 got past the group problem via a crash-forced reconnect, and neither
met the volume ceiling because they built on a 1.7 TB instance store, which is
precisely what made their artifacts impossible to snapshot.

---

## 8. Pre-registration scorecard

| id | expectation | outcome |
| --- | --- | --- |
| E1.1 | label follows the config after every restart | **CONFIRMED** (18/18 observations) |
| E1.2 | `index_lock_lost_total` stays 0 | **CONFIRMED** |
| E1.3 | exactly one open fd on the index | **CONFIRMED** |
| E1.4 | manager pid unchanged (precondition) | confirmed |
| E1.5 | no `.corrupt` | confirmed |
| E1.6 | retry counter reported either way | **reported: 0** — ordering alone sufficed |
| E1.7 | cache series present on the documented endpoint | confirmed (41) |
| N1.1–N1.3 | the control reproduces C1 | **ALL CONFIRMED** |
| E2.1 | the partition never fills | **CONFIRMED** (peak 88%) |
| E2.2 | cache trees within budget × 1.05 | **CONFIRMED** |
| E2.3 | drops occur in both arms | **CONFIRMED** (190 k, 301 k) |
| E2.4 | pressure never below the index while dropping | **CONFIRMED** (0 violations / 189 samples) |
| E2.5 | pressure tracks `du` within 10% | **CONFIRMED** (3 of ~95 samples exceeded, worst 12.8%) |
| E2.6 | the snapshotter is startable afterwards | **CONFIRMED**, both arms |
| E2.7 | zero sweep read errors | **CONFIRMED** |
| E3.1 | gates G1 and G2 pass | **CONFIRMED** — first time in three spikes |
| E3.2–E3.3 | 2q faster / higher hit rate | **FALSIFIED — not separable at N=4** |
| E3.4 | zero resident read errors | **CONFIRMED** (8 arms) |
| E3.5 | `writes_skipped` = 0 | **CONFIRMED** (8 arms) |
| E3.6 | effective policy label correct; 2q promotes | **CONFIRMED** |
| E4.1 | ours 280/280, both reps | **CONFIRMED** |
| E4.2 | vanilla reproduces the failure | **CONFIRMED** (7/280, 273 EIO, both reps) |
| E4.3 | `writes_skipped` > 0 | **CONFIRMED** (4,079 / 4,142) |
| E4.4 | completion time recorded | confirmed, and §5.2 flags an unexplained difference |

**One falsification (E3.2/E3.3), and it is the most useful result in the spike.**

---

## 9. Cost, artifacts and teardown

| | |
| --- | --- |
| instances | 2 × `i4i.2xlarge`, us-east-1, on-demand @ $0.686/h |
| lifetime | 2026-09-11T16:57:43Z → teardown ~04:30Z, ≈ 11 h 35 m |
| compute | ≈ **$15.9** |
| EBS during the run | 1200 GB gp3 (registry data) + 2 × 30 GB roots, ~11.5 h ≈ **$1.4** |
| **total for the spike** | **≈ $17.3 of the $100 ceiling (17%)** |

**Artifact snapshot — the one resource that outlives the run.**

```
snapshot_id   snap-0118cc5716e9e8a54
source        vol-028c6acbe8d7e2007 (1200 GiB gp3)
taken         2026-09-11T19:28:11Z
verified      2026-09-11T22:56:21Z, by readback from a restored volume
contents      registry blob store, 309 GB: model-ballast {B-140g, B-14g,
              estargz-140g, estargz-14g}
estargz-140g  sha256:82756576229f65580e9728248c4c878689caaa8cf70709c78c65525a56e2881b
estargz-14g   sha256:1722c16da2fc850e942a2f4bc8612f4dd898240799d7a53508854fc6c5de8237
restore       aws ec2 create-volume --snapshot-id snap-0118cc5716e9e8a54 \
                --availability-zone <az>
```

Verification was a genuine readback, not a status check: the snapshot was
restored to a fresh volume, attached, mounted read-only, and its tag metadata,
manifest digests and 64 MiB of an 18.8 GB layer blob were read off it. The
verification volume was then deleted.

On cost, what is known rather than what sounds tidy: EBS bills **stored blocks**,
not volume size. `fstrim` is unsupported on this volume, so free space was
zero-filled before the snapshot to stop it paying for the ~925 GB build peak;
billing should land near the 463 GB live footprint, roughly **$23/month**.
**Confirm against the first bill.** Delete the snapshot when this lineage stops
being re-run.

---

## 10. What this spike does not establish

1. **That 2q is useless.** E3 says lru and 2q are not separable *on this
   workload*: a 14 GB hot set under a 140 GB sweep against an 80 GB budget. The
   hot set is small enough relative to the budget that lru retains it anyway, so
   scan resistance has nothing at risk to protect. The experiment worth running
   is a hot set closer to the budget — not this one at higher N.
2. **Why E4 is ~16% slower than v6.** Observed consistently across both reps,
   with fix round 2 the obvious suspect and nothing here sufficient to attribute
   it. Needs a same-session A/B of the two builds under identical pre-fill.
3. **That C4 cannot recur at a higher write rate.** v7 drove 301 k dropped
   updates through a 256-deep queue and the budget held. It does not bound what
   happens at a rate high enough that the rescan cannot keep up; the cheap next
   measurement is the write rate at which the reconciliation stops converging.
4. **C2 and C3 remain unfixed**, deliberately. C3 changes what an existing alert
   means, and should ship with its documentation rather than ahead of it.
5. **The 12.3–12.8% pressure/`du` gap** on a handful of samples is understood in
   direction and bounded in magnitude here, but it was measured on one geometry.
   A partition with less headroom than 12 GB would deserve its own check.
