# v5 spike — live validation of C1+C2 — RUN REPORT

Private research artifact. First run of our own snapshotter build on a live
two-host rig. Numbers here are private — do not post, quote, or reference
externally.

**System under test:** `github.com/kliukovkin/stargz-snapshotter`, branch
`c2-eviction` @ `f6547d991f0587429af5f9e42a3d80acc0f26f09`, built on the rig
from source with go1.26.0, working tree clean (`identity-bundle/PROVENANCE.txt`).
**Control arm:** upstream `v0.18.2` release tarball.
**Rig:** two `i4i.2xlarge`, us-east-1, kind + `kindest/node:v1.36.1`,
containerd 2.3.1, a real 92 GB NVMe partition at `/cache-part` bind-mounted as
the snapshotter root. Base AMI `ami-025d99823a4caad37` (Ubuntu 24.04) — recorded
here because v4's report did not capture it.
**Budget under test:** `bytes = 80000000000`, `high_watermark = 0.95`,
`low_watermark = 0.85`, `policy = "lru"`, `[fuse_manager] enable = true` with a
`KillMode=process` drop-in (our fix for upstream issue #2387, verified OPEN).

**Expectations for V1–V5 were pre-registered before the rig was launched**, in
`source-audit/PRE-REGISTRATION-v5.md`. That file also records, before the run,
two mis-citations in the task and the fact that V6 could not be delivered as
specified. Several pre-registered expectations were falsified; they are marked
as such below rather than quietly restated.

---

## Contents

1. Setup, calibration, identity
2. V1 [P0] — integration and accounting accuracy
3. V2 [P0] — pressure matrix, before/after
4. V3 [P0] — restart loop, and the C1 §6.2 inode question
5. V4 [P1] — lying pod and the sentinel probe
6. V5 [P1] — the price of eviction
7. V6 — access-log capture
8. Findings about our own code
9. Live fixes, invalidated trials
10. Honest gaps
11. Pre-registration scorecard
12. Exact versions and SHAs
13. Cost and teardown

(This list is kept current. v4's equivalent went stale — it still lists a "§12
Cost" the finished document renumbered to §17 and never fixed.)

---

## 1. Setup, calibration, identity

Calibration start-of-run, against v4's figures on the same instance type:

| metric | v5 | v4 |
| --- | --- | --- |
| node `/data` fio seq write | 1116 MiB/s | 1103 MiB/s |
| node `/data` fio seq read | 1411 MiB/s | 1412 MiB/s |
| `/cache-part` fio seq write | 1101 MiB/s | 1061 MiB/s |

The rig is comparable to v4's within noise, which is what makes the v4/v5
before/after comparisons meaningful at all.

Artifact build: 140 GB-class image (280 × 512 MiB incompressible ballast, 8 gzip
layers) plus a 14 GB image, both converted to eStargz and pushed to a local
registry. The eStargz pull during conversion ran at 367.2 MiB/s / 390.5 s
(v4: 356.2 MiB/s / 402.6 s). Build phase wall clock: **1 h 39 m**, of a 6 h 30 m
run — consistent with v4 §17's "roughly 60% of paid time is the one-off image
build".

Smoke test on the 14 GB image before any experiment: pod Ready in **2.834 s**,
4 files / 2.15 GB read, 0 errors. Cache amplification visible immediately —
2.15 GB read left 4.30 GB on disk (**2.0×**), matching v4's 2.00–2.13×.

---

## 2. V1 [P0] — integration and accounting accuracy

One full 280-file (140 GB) sweep through a lazy mount, budget 80 GB, sampled
every 15 s from three independent sources: the index's own metric, `du -sb` on
the two cache trees, and `df` on the partition.

**Facts.**

```
deploy -> Ready                 1.862 s
read    attempted=280 ok=280 err=0  bytes=150,323,855,360  elapsed=1089.0 s
ERRNOS  none
peak_metric_bytes    75,993,973,984   (95.0% of budget)
peak_df_used         80,831,811,584
exceeded_budget      False
exceeded_high_wm     False
evictions            2,273,279 chunks
evicted_bytes        224,576,561,660  (224.6 GB)
writes_skipped       0
blob_fetch_errors    2      (constant from the first sample; see below)
dropped_events       14,085
drift  min -7.75%  max +0.08%  final -2.36%
df - du  between 0.54 GB and 3.78 GB, always positive
```

**Interpretation.**

*V1c, the headline, is confirmed.* 280 of 280 files read cleanly, 150.3 GB
moved, while 224.6 GB was evicted underneath the reader. Occupancy never
exceeded the budget or the high watermark. This is the central claim of the
design — that a bounded cache serves reads correctly while it evicts — measured
live at full scale for the first time.

*V1a is falsified, in two ways.* Drift against `du` reached **−7.75%**, past the
±2% steady-state and ±5% transient bands pre-registered for it, and
`dropped_events_total` reached **14,085** where 0 was predicted. The two are the
same phenomenon: at roughly 280 MB/s of cache writes the 8192-deep update queue
saturates and the index drops updates rather than blocking the cache, exactly as
C1 designed it to. 14,085 dropped updates at ~50 KB is about 0.42 GB, which is
0.55% of occupancy and accounts for a large part of the observed drift.

The consequence is not cosmetic. **Eviction acts on the number the index
reports.** An index that understates occupancy by up to 7.75% under load evicts
later than it should, and the safety margin between the high watermark
(76.0 GB) and the partition (92 GB) is what absorbs the error. On this geometry
that margin is comfortable; on a tighter one it would not be.

*V1b is confirmed in its letter and wrong in its spirit.* Occupancy stayed
inside the predicted [68.0, 76.0] GB band — but at the top of it, pinned at
0.944–0.950 for the whole sweep, never descending to the low watermark. The
cause is arithmetic: one eviction cycle is capped at 4096 chunks ≈ 200 MB, while
reaching the low watermark from the high one requires freeing 8 GB. Under a
continuous sweep the writer refills faster than a capped cycle drains, so
eviction runs permanently at the high watermark and the designed hysteresis
never materialises. Eviction is therefore not a periodic background event on a
busy node; it is a continuous one.

*The two blob fetch errors* appear in the very first sample and never increase.
They are not read failures — the reader saw none — and are most likely the
metadata/TOC fetch path. Not diagnosed further; flagged in §10.

---

## 3. V2 [P0] — pressure matrix, before/after

Pre-fill {0, 50, 90}% of the 92 GB partition, then read all 280 files.
**N=1, not the pre-registered N=2** (§9, F7). Levels were run 90 → 50 → 0 so the
most informative one and the control completed first.

**This section is measured with kubelet eviction disabled, and that qualifier is
load-bearing** — see §9 F8. Under production-like thresholds the pod is evicted
before it reads anything and the experiment cannot run at all.

**Facts.**

| arm | pre-fill | free for cache | ready | sweep_s | ok / 280 | err | errno | writes_skipped | evictions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ours | 0% | 92 GB | 1.30 s | 1069.4 | **280** | **0** | none | 0 | 2,178,287 |
| ours | 50% | ~46 GB | 1.87 s | 1312.8 | **280** | **0** | none | 3,505 | 2,592,767 |
| ours | 90% | ~4.2 GB | 2.36 s | 1289.2 | **280** | **0** | none | 2,641 | 2,961,337 |
| **v0.18.2** | **90%** | ~4.2 GB | 1.92 s | **30.3** | **7** | **273** | **EIO=273** | — | — |

**Interpretation.**

*The before/after is unambiguous.* At an identical 90% pre-fill, upstream
v0.18.2 fails 273 of 280 files with EIO after moving 4.4 GB of 150 GB, and dies
in 30 seconds. Our build reads all 280 files and the full 150.3 GB. This is
paper 2's failure reproduced on this rig and then removed by construction, which
is the result the whole C2 design exists to produce.

*The price of honesty is 20.6%.* 1289.2 s at 90% pre-fill against 1069.4 s at
0%. That is the latency cost of serving chunks the cache cannot keep.

*The pre-registered time prediction is falsified.* t(90%) ≥ 1.5 × t(0%) was
predicted; the measurement is 1.21×. The relation is also not monotonic — 50%
(1312.8 s) is slower than 90% (1289.2 s), which the pre-registration did not
anticipate and this run does not explain. One sample per level (F7) is not
enough to say whether the inversion is real.

*`writes_skipped` behaves as designed* — 0 where the budget binds before the
partition does, non-zero where the partition binds first. Note that ENOSPC log
lines were **0** in both the journal and the fuse-manager log at every level:
pass-through counts the condition rather than logging it, so an operator
grepping logs for "no space left" would see a clean node. The counter is the
only signal.

---

## 4. V3 [P0] — restart loop, and the C1 §6.2 inode question

8 graceful `systemctl restart`s, no reads between them, budget 80 GB.

**Facts.**

| step | df used | du total | df − du | lsof +L1 bytes | evictions |
| --- | --- | --- | --- | --- | --- |
| 0 | 9.49 GB | 8.59 GB | 0.89 GB | **0** | 0 |
| 1 | 21.73 GB | 19.44 GB | 2.29 GB | **0** | 0 |
| 2 | 44.21 GB | 40.31 GB | 3.90 GB | **0** | 0 |
| 3 | 68.63 GB | 63.15 GB | 5.47 GB | **0** | 0 |
| 4 | 79.39 GB | 76.07 GB | 3.32 GB | **0** | 147,456 |
| 5 | 79.74 GB | 75.89 GB | 3.85 GB | **0** | 348,160 |
| 6 | 82.55 GB | 77.65 GB | 4.91 GB | **0** | 524,288 |
| 7 | 82.54 GB | 77.88 GB | 4.66 GB | **0** | 659,456 |
| 8 | 83.69 GB | 78.13 GB | 5.56 GB | **0** | 847,872 |

`evicted_bytes_total` 79.8 GB, `read_err_total` **0**, fuse-manager PID constant
(`26172`) across all 8 restarts.

**Interpretation.**

*Restart-driven growth is now bounded.* v4 §13 measured ~17–18 GB per restart,
linear, with nothing reclaiming it; its loop was cut short at restart 5 with the
partition at 84%. v5 tracks the same trajectory for the first four restarts and
then **flattens**: steps 4 through 8 sit between 79.4 and 83.7 GB. On v4's slope,
restart 8 would have been near 144 GB — half again the size of the partition.
The duplication is still created; it is now evicted.

*My pre-registered bound is falsified, and the reason matters.* I predicted
`df ≤ 82 GB` at every step; steps 6–8 reach 82.55, 82.54 and 83.69 GB. But
`du_total` — the bytes the budget actually governs — was 78.13 GB at step 8,
under the 80 GB budget. **The budget bounds the accounted cache, not the
partition.** Roughly 5.5 GB lives outside it. An operator who sets
`bytes = 88000000000` on a 92 GB partition expecting 4 GB of headroom does not
have 4 GB of headroom.

*The C1 §6.2 inode hypothesis is refuted.* `lsof +L1` reports **zero
deleted-but-open files and zero bytes at every one of the nine steps**, while
`df − du` runs 0.89–5.56 GB and grows with the number of cached chunks. The gap
is not unlinked-but-open inodes held by the surviving FUSE manager.

The most likely explanation is mundane and should be stated as the hypothesis it
is: `du -sb` reports *apparent* size (`--apparent-size`), `df` reports
*allocated blocks*. At ~1.5 M chunk files averaging ~50 KB on a 4 KB-block ext4,
per-file rounding alone is on the order of gigabytes, and it scales with chunk
count — which is what the table shows. This run did not measure `du` without
`-b` to confirm it, so it remains a hypothesis; §10.

This retires the C1 §6.2 question in the direction of "no special mechanism",
and it means a future reattach-with-dedup has nothing to dedup here.

---

## 5. V4 [P1] — lying pod and the sentinel probe

Two arms at 90% pre-fill, with `contrib/sentinel-probe` run alongside the pod's
normal readiness probe rather than replacing it, so that the contrast between
them is observable.

**Facts.**

| arm | full read | sentinel probe (3 rounds) | kubelet Ready | writes_skipped |
| --- | --- | --- | --- | --- |
| v0.18.2 | 8/280 ok, **272 EIO** | **exit 0 — green — every round** | True | 0 |
| ours | **280/280 ok, 0 err** | exit 0 — green — every round | True | 4,068 |

Sentinel output on the failing arm, verbatim:

```
sentinel-probe: ok: /mnt/models/ballast-99.bin tail 1048576 bytes
sentinel-probe: ok: /mnt/models/ballast-98.bin tail 1048576 bytes
sentinel-probe: ok: /mnt/models/ballast-97.bin tail 1048576 bytes
```

**Interpretation.**

*Our arm is as designed*: 280/280 readable under the same pressure that destroys
the control, with 4,068 chunks served-but-not-cached.

*The probe half of V4 is falsified, and it is a result about our own
deliverable.* On the vanilla arm, 97% of the model was unreadable and the
sentinel probe reported the pod healthy, three rounds running. That is precisely
the falsifier written into the pre-registration: "the probe returns 0 on the
vanilla arm while files are corrupt → false negative, the probe is worthless and
must not be recommended."

The probe has **no discriminating power on this rig**: it is green in both arms,
so it cannot distinguish a healthy pod from one serving 8 of 280 files. Two
candidate mechanisms, which this run cannot separate (§9 F10): the sample is 3
files of 280 (3 MiB of 150 GB), and the probe re-reads the *same* remembered
files every period, so from its second round onward it is reading files it has
itself kept warm — a self-fulfilling health check.

`contrib/sentinel-probe/README.md` currently claims "on a snapshotter without
pass-through, a pressure test should turn this probe red". On this rig it did
not. That sentence must be corrected before the probe is recommended anywhere.

What v5 does **not** overturn is v4's tail-bias measurement (280/280 clean at
head, 262/280 broken at tail) which motivated reading the tail. What it shows is
that reading the tail is *not sufficient*.

---

## 6. V5 [P1] — the price of eviction

Resident pod re-reading a 14 GB hot set (its own image, so its own cache
directories) while a 140 GB sweep runs beside it, budget 80 GB. Two arms,
`policy = "lru"` then `policy = "2q"`. **This is attempt 3.** Attempts 1 and 2
are preserved as invalid (§9, F11 and F12) and the reasons are worth more than
this section's numbers.

**Verification that the arms actually differed**, which attempt 2 failed:

```
lru arm:  stargz_fs_cache_evictions_total{cache_type="httpcache",policy="lru"} 2.400283e+06
2q  arm:  stargz_fs_cache_evictions_total{cache_type="httpcache",policy="2q"}  2.727114e+06
```

**Facts.**

| | lru | 2q |
| --- | --- | --- |
| warm reference p50 / p95 (ms) | 484.9 / 539.7 | 589.5 / 622.7 |
| resident under sweep p50 (ms) | 578.7 | **516.0** |
| resident under sweep p95 (ms) | 621.8 | **540.7** |
| resident under sweep p99 (ms) | 630.3 | **545.7** |
| resident under sweep max (ms) | 658.8 | **552.7** |
| resident read errors | 0 | 0 |
| evictions | 2,428,928 | 2,756,560 |
| evicted bytes | 240.1 GB | 259.7 GB |
| writes_skipped | 0 | 0 |
| sweep completion | 1143.0 s | 1089.4 s |
| sweep result | 280/280 ok | 280/280 ok |

**Interpretation — and this is a weak result that must not be oversold.**

*Direction.* 2q is better on every resident latency percentile under sweep
pressure: p95 540.7 vs 621.8 ms (−13%), p99 545.7 vs 630.3 (−13%), max 552.7 vs
658.8 (−16%). That is the direction the simulator predicted and the direction
the design argues for.

*Magnitude is nothing like the simulator's.* C2-REPORT §4 showed 0.286 vs 0.857
resident hit rate on a synthetic scenario — a 3x difference. Live, on this
workload, the difference is ~13% at the tail. The synthetic scenario was built
to separate the policies and it did; it is not a prediction of effect size, and
this run confirms it should never be quoted as one.

*The effect is close to this run's noise floor, so the result is suggestive
rather than established.* The two arms' **warm reference** distributions — a
phase with no sweep, no eviction pressure and no policy involvement, which
should therefore be identical — differ by 22% (p50 484.9 vs 589.5 ms). A single
run whose supposedly-identical baselines differ by 22% cannot firmly establish a
13% difference in the measured phase. The honest statement is: *consistent with
2q helping the resident set, not sufficient to establish it.* Repeating with
several interleaved rounds per arm is the fix, and it is cheap now that the rig
recipe exists.

*The derived hit rate must be discarded, and the reason is my error.* It reads
0.143 for lru and 1.000 for 2q, which looks decisive and is not. Each arm
classifies a read as a hit if it is no slower than **its own** warm-reference
maximum — 541.5 ms for lru, 631.3 ms for 2q. lru therefore got a threshold 90 ms
tighter than 2q's, and its under-sweep p50 (578.7) sits just above it while 2q's
(516.0) sits comfortably below. Against a common threshold the two are close:
lru's p99 is 630.3 ms, inside 2q's 631.3 ms threshold. The metric is a
methodological flaw in the harness, not a finding; the percentiles above are the
comparable measure.

*Pre-registered expectations.* p95 and p99 predictions **confirmed**. The
"2q evicts less than lru" prediction is **falsified** — 2q evicted 13% *more*
chunks (2.76 M vs 2.43 M) and 8% more bytes. The "2q sweep completes slower"
prediction is **falsified** too: 2q's sweep finished faster (1089.4 s vs
1143.0 s). Both falsifications point the same way — on this workload 2q is not
trading sweep throughput for resident latency the way the design's reasoning
assumed; it is doing more eviction work and finishing sooner. This run does not
explain that, and it is the most interesting thing in the section.

*Neither arm dropped a read.* 0 errors on the resident pod and 280/280 on the
sweep in both arms, with `writes_skipped` 0 throughout — the budget bound
before the partition did.


---

## 7. V6 — access-log capture

**Pre-registered as undeliverable before the run.** At `f6547d99` the accounting
index does not emit a simulator-format trace;
`cache/accounting/sim/trace.go:78` says so in the source, and C2-REPORT §8.1
lists producing one as the first thing this spike should motivate. Emitting it
is a code change, which this task forbids on the rig and which would break the
pinned SHA.

The pre-registered substitute was built and run: a standalone read-only bolt
dumper (`scripts-as-run/idxdump/`, its own module, never linked into the system
under test) snapshotting the index every 30 s, plus an offline differ
(`97-derive-trace.py`). Applied to V1's sweep:

```
1,197,434 events  (1,196,819 add, 615 get)  from 16 snapshots
1,097,392 keys vanished between snapshots
```

**It does not work, and the numbers say why.** 615 `get` events out of 1.2 M —
a sweep reads each chunk once and the index's one-minute last-access bucket
hides the rest, so almost no reuse survives. 1,097,392 keys (92% of admissions)
were added *and* evicted inside one 30 s interval and were never observed.
Feeding this to the simulator would compare policies on a workload with no
reuse, which is not the workload.

The artifact is preserved as `results/v1/v6-derived.trace`, labelled
`DERIVED-NOT-CAPTURED` in its own header, as a demonstration that the approach
is inadequate rather than as data. RQ1 needs real trace emission from the index.

---

## 8. Findings about our own code

Four, none patched on the rig. Full evidence in `results/LIVE-FIXES.md`.

**F2 — the accounting and eviction metrics are invisible in the configuration
the design mandates.** With `[fuse_manager] enable = true` the filesystem, the
C1 index and the C2 eviction engine all run inside the `stargz-fuse-manager`
process (`fusemanager/service.go:212`, called from `Init` at startup).
`metrics_address` is served by `containerd-stargz-grpc`, which has none of those
collectors, and the manager's own endpoint is off unless
`[fuse_manager] metrics_address` is set. Result: every `stargz_cache_*` and
`stargz_fs_cache_*` series silently absent while eviction runs normally. An
operator would conclude the feature is off. `docs/overview.md` documents only
the one endpoint; `cmd/stargz-cache-events/README.md` points the events agent at
the wrong one.

**F12 — `[cache_accounting]` config changes are silently ignored on
`systemctl restart`.** Same root cause, worse consequence. The manager receives
its config when it starts; our own `KillMode=process` drop-in for #2387
deliberately keeps it alive across a snapshotter restart, so a restart never
delivers the new config. Edit `policy`, restart, watch the unit come back
healthy — and the old policy is still running, with no warning. This was not
theorised; it **destroyed two V5 attempts** before being identified, and the
evidence is V5 attempt 2's own metric label reading `policy="lru"` on the arm
configured as 2q. F2 and F12 compound: the setting is ignored *and*, without the
manager's metrics endpoint, the label proving it was ignored is not exported.

**F3 — a restart that overlaps the previous process's bolt lock discards the
index.** `openDB` opens bolt with a 3 s timeout and treats *any* open failure as
corruption: it renames the database `.corrupt` and rebuilds by scanning. Seen
once in V3's 8 restarts, and once during setup. It matters beyond tidiness: a
rebuild resets `addedAt` and zeroes `firstHitAt` for every chunk, which is
exactly the state in which 2Q degrades to LRU (C2-REPORT §6.2/§7.1). A restart
that merely lost a lock race silently downgrades the eviction policy.

**F10 — the sentinel probe is a false negative on the failure it was built
for.** §5 above.

---

## 9. Live fixes and invalidated trials

Full narrative in `results/LIVE-FIXES.md`. Summary:

| id | class | what |
| --- | --- | --- |
| F1 | environment | NVMe enumeration reversed; v4's scripts would have run `parted mklabel gpt` on the **root disk** and survived only by luck. Now detected by device model with an explicit refuse-to-touch-root assertion. |
| F4 | environment | hardcoded `~/v4/` path and a stale predictor tag |
| F5 | harness | absent Prometheus CounterVecs are not 0; sampler columns were blank |
| F6 | environment | the 14 GB image was silently not built (`02-build-artifacts.sh` does not source `env.sh`) |
| F7 | deviation | V2 run at N=1, not the pre-registered N=2, for time |
| F8 | **finding** + fix | kubelet evicts the pod before the cache volume can fill |
| F9 | harness gap | V4's healthz/predict columns empty (no curl in the image) |
| F11 | invalidated | V5 attempt 1 void — the registry snapshot copy contaminated one arm |
| F13 | V6 | the derived-trace substitute is inadequate |

**Invalid trials preserved, not deleted:** `results/v2/*-INVALID/` (4 trials
killed by kubelet eviction), `results/v5-attempt1-INVALID/`,
`results/v5-attempt2-INVALID/`.

**F8 deserves promotion out of the fix list.** kubelet's
`evictionHard: nodefs.available: 10%` fires at 9.78 GB free on the 92 GB cache
partition, so at 90% pre-fill it evicts every pod on the node before a single
read happens. This sharpens v4 §14: v4 showed kubelet is *sighted but powerless*
(`imageFs usedBytes` pinned near 152 MB, image GC frees 0 bytes). v5 adds the
other half — `nodefs.available` measures free space directly, so kubelet cannot
reclaim the stargz cache but **can and does evict the tenants**. On the common
deployment where the cache shares a filesystem with kubelet's nodefs, a full
stargz cache does not corrupt reads first; it gets pods killed first.

---

## 10. Honest gaps

1. **N=1 everywhere.** V2 at one trial per level (F7), V3 one loop, V4 one run
   per arm. No variance estimates. The corruption results are binary so N=1
   answers them; the timing comparisons are single samples.
2. **V2 and V4 ran with kubelet eviction disabled.** Necessary to reach the
   question at all (F8), but it means neither is a statement about a
   production-threshold node.
3. **The `df − du` explanation is a hypothesis.** Apparent-vs-allocated size is
   the likely cause and fits the scaling, but this run did not measure `du`
   without `--apparent-size` to confirm it.
4. **The two `blob_fetch_errors` in V1 were not diagnosed.** Constant from the
   first sample, no reader-visible effect.
5. **V5's confound was self-inflicted** (F11) and cost two attempts.
6. **No production-threshold pressure run.** The most realistic configuration —
   cache and kubelet nodefs sharing a filesystem, thresholds at 10% — was
   observed only as a failure to run the experiment.
7. **The registry EBS snapshot was not produced.** §13.
8. **fuse_manager=false was never measured as a control** for F2/F12, beyond the
   diagnostic that established them.

---

## 11. Pre-registration scorecard

| # | pre-registered | outcome |
| --- | --- | --- |
| V1a | drift ≤2% steady / ≤5% transient; dropped_events = 0 | **FALSIFIED** — −7.75%, 14,085 dropped |
| V1b | converges to low watermark, oscillates [68, 76] GB | confirmed in letter; **mechanism wrong** — pins at high watermark |
| V1c | 0 read errors for the whole sweep | **CONFIRMED** — 280/280 |
| V2 | 0 corrupted on ours at every level | **CONFIRMED** — 0/0/0 |
| V2 | writes_skipped 0 / >0 / ≫0 by level | **CONFIRMED** — 0 / 3,505 / 2,641 |
| V2 | vanilla ≥200 of 280 EIO | **CONFIRMED** — 273 |
| V2 | t(90%) ≥ 1.5 × t(0%) | **FALSIFIED** — 1.21× |
| V3 | df ≤ 82 GB at every step | **FALSIFIED** — 83.69 GB (but `du` under budget) |
| V3 | occupancy never exceeds budget | confirmed for the accounted cache; **not** for the partition |
| V3 | C1 §6.2: df−du ≈ lsof +L1 within 20% | **REFUTED** — lsof +L1 = 0 at every step |
| V4 | vanilla probe red | **FALSIFIED** — green while 272/280 EIO |
| V4 | ours probe green, 0 corruption | **CONFIRMED** |
| V5 | — | see §6 |

Seven confirmations, five falsifications, one refutation. The falsifications are
the valuable part: four of them are about our own system and would not have been
found by a run that checked only what it expected.

---

## 12. Exact versions and SHAs

| component | version |
| --- | --- |
| system under test | `c2-eviction` @ `f6547d991f0587429af5f9e42a3d80acc0f26f09`, built go1.26.0 linux/amd64, tree clean |
| control | stargz-snapshotter `v0.18.2` release tarball |
| upstream base | `main` @ `624678b4` (via `c1-cache-accounting` @ `b7306eee`) |
| Kubernetes | kind v0.30.0, `kindest/node:v1.36.1`, server v1.36.1 |
| containerd | 2.3.1 (node-internal) |
| base AMI | `ami-025d99823a4caad37` (Ubuntu 24.04 amd64) |
| instances | `i-057c5e1a7e18582bb` (node), `i-02e85d1266881661a` (registry) |
| 140 GB image | `model-ballast:estargz-140g`, 150,374,663,046 bytes |
| binary SHA256 | `identity-bundle/SHA256SUMS.txt` |

Note: our binaries report `containerd-stargz-grpc <unknown> <unknown>` for
`--version` — they are built without the release ldflags. Provenance is the
commit SHA plus the recorded checksums, not the version string.

---

## 13. Cost and teardown

**Instances.** Two `i4i.2xlarge`, us-east-1, on-demand $0.686/instance-hour.

| | |
| --- | --- |
| launched | 2026-09-10 17:32:28 UTC |
| terminated | 2026-09-11 01:01:44 UTC |
| wall clock | 7 h 29 m |
| instance-hours | 14.97 |
| **compute cost** | **$10.27** |

Plus a 357 GiB gp3 volume alive for ~1.5 h during the failed registry export
(~$0.05) and negligible EBS root storage. **Total ≈ $10.3 against the $40
budget (26%).**

For comparison, v4's two runs together cost $6.38 in 4.65 h. v5 is longer
because it ran six experiments rather than three, re-ran V2 once and V5 twice,
and spent 1 h 39 m on the artifact build.

**Where the time went.**

| phase | wall clock | share |
| --- | --- | --- |
| host bootstrap + cluster + building our fork | 0 h 09 m | 2% |
| 140 GB + 14 GB artifact build and eStargz conversion | 1 h 39 m | 22% |
| V1 | 0 h 20 m | 4% |
| V2 (including the invalidated first attempt) | 1 h 38 m | 22% |
| V3 | 0 h 05 m | 1% |
| V4 | 0 h 24 m | 5% |
| V5 (three attempts, two invalid) | 2 h 21 m | 31% |
| diagnosis, re-runs, collection, teardown | 0 h 53 m | 12% |

The artifact build is no longer the dominant cost — **V5's two invalid attempts
are**, at 1 h 24 m of the 2 h 21 m. Both were caused by findings (F11 self-
inflicted, F12 a real defect), so the time was not wasted, but a future run that
already knows about F12 gets V5 for ~45 minutes.

**Teardown, verified.**

```
non-terminated instance count = 0
volumes (any state)           = none
snapshots owned by this account = 0
AMIs owned by this account      = 0
```

**The registry snapshot was NOT produced, and this is a miss against the task.**
The task asked for an AMI or EBS snapshot of the built 140 GB artifacts so future
spikes on this lineage need not rebuild them, and it is the one thing that was
supposed to outlive the rig. What happened:

1. An AMI is the wrong instrument and that was established early: the registry
   blob store lives on the i4i **instance store**, which an AMI does not capture.
   The script was written to snapshot an EBS volume instead, which is the task's
   own stated alternative.
2. The export (309 GiB, `tar` to a fresh 357 GiB gp3 volume) was started in
   parallel with V4 to use the wait productively. That was a mistake on two
   counts: it was launched with `nohup ... &` from a shell that exited, so it
   died mid-copy with `Connection reset by peer`, and while it lived it
   contaminated V5's first attempt (F11).
3. The working volume was detached and deleted; no snapshot exists.

So the next spike on this lineage still pays the 1 h 39 m rebuild. The fix is
mechanical — run `96-registry-snapshot.sh` after the last measurement, with
`setsid` and full fd redirection (which v4 §9 finding 5 already prescribes for
exactly this failure mode, and which this harness applies everywhere except
here). Had it succeeded it would have been ~309 GiB of snapshot storage at
$0.05/GB-month, so roughly **$15/month** — worth stating plainly, because at
that price it only pays for itself if this lineage is re-run more than about
twice a month.

