# Spike v5 — pre-registered expectations for V1–V5

**Written before the rig was launched.** Nothing in this file may be edited after
the first EC2 instance for v5 enters `running`; corrections go in RUN-REPORT-v5.md
as errata, per the v4 convention of never rewriting a prior artifact (v4 §8).

**System under test:** `github.com/kliukovkin/stargz-snapshotter`, branch
`c2-eviction` @ `f6547d99` (tip of the C2 branch; 8 commits on top of
`c1-cache-accounting` @ `b7306eee`, itself on upstream `main` @ `624678b4`).

**Configuration under test unless a section says otherwise:**

```toml
[cache_accounting]
enable = true
[cache_accounting.budget]
bytes = 80000000000      # 80 GB on a 92 GB partition
high_watermark = 0.95    # evict above 76.0 GB
low_watermark  = 0.85    # evict down to 68.0 GB
policy = "lru"
```

plus `[fuse_manager] enable = true` and a `KillMode=process` drop-in (upstream
issue [#2387](https://github.com/containerd/stargz-snapshotter/issues/2387),
verified OPEN at the time of writing; the fix is ours and unmerged).

---

## 0. Corrections to the task's framing, recorded before the run

Two citations in the task do not resolve, and getting them wrong would make the
v5 report cite something that does not exist:

1. **"inode-гипотеза v4 §6.2"** — v4's RUN-REPORT has no §6.2, and no
   deleted-but-open-inode hypothesis anywhere. The hypothesis being referred to
   is **C1-REPORT.md §6.2** ("Unlinked-but-open bytes are invisible to a rebuild
   scan"), which itself points at **v4 §13** (the ~17–18 GB/restart growth with
   `httpcache`/`fscache` directory counts pinned at 10/10). V3 below tests the
   C1 §6.2 hypothesis against the v4 §13 measurement. The v5 report will cite it
   that way.
2. **Metric name `stargz_fs_cache_bytes_used`** does not exist. Occupancy is
   `stargz_cache_bytes_used{cache_type}` (namespace `stargz`, subsystem
   `cache`, from C1). The `stargz_fs_cache_*` prefix belongs to the C2 metrics
   only (`cache_evictions_total`, `cache_evicted_bytes_total`,
   `cache_budget_bytes`, `cache_occupancy_ratio`, `cache_writes_skipped_total`).
   V1 measures the former and reports both families.

## 0b. V6 cannot be delivered as specified, and this is known before the run

V6 asks for an access log "in the simulator's format" captured during V1/V5.
**At `f6547d99` the accounting index does not emit one.** This is not a bug
found on the rig; it is a documented gap — `cache/accounting/sim/trace.go:78`
says so in the source, and C2-REPORT §8.1 lists "get one real trace" as the
first thing this spike should produce. Emitting it requires a code change, which
this task forbids on the rig and which would also break the pinned SHA.

**Substitute, pre-registered so it cannot be presented later as if it were the
real thing:** during V1 and V5, snapshot the bolt index (`cache-accounting.db`)
every 30 s and dump the `chunks` bucket read-only with a standalone tool that is
*not* part of the system under test. Diffing consecutive snapshots yields
`(key, size, last-access)` transitions, from which a `get`/`add` trace can be
reconstructed **at the index's one-minute last-access bucket resolution**, not
at true per-read resolution. Every chunk read more than once inside one bucket
is invisible to it — which is a property of the index, not of the tool.

This is strictly weaker than the real thing and will be labelled
`DERIVED-NOT-CAPTURED` in the evidence tree. What it is good for: relative
policy comparison in the simulator, which is what RQ1 needs. What it is not good
for: any claim about sub-minute reuse distance.

---

## 1. V1 [P0] — integration and accounting accuracy

Full sweep of the 140 GB-class image through a lazy mount, budget 80 GB,
sampling every ~15 s.

### 1a. Accounting drift

| | prediction |
| --- | --- |
| `stargz_cache_bytes_used` (sum over both cache types) vs `du -sb httpcache + du -sb fscache` | within **±2 %** at steady state |
| transient excursions during an eviction burst | up to **±5 %**, lasting < 1 sampling interval |
| `stargz_cache_index_dropped_events_total` | **0** |
| `df` used on `/cache-part` vs `du` total | `df ≥ du` always |

Reasoning: updates are committed on a ≤5 s flush timer, so at 15 s sampling the
index should be at most one flush behind. The queue is 8192 deep; a 140 GB sweep
at ~50 KB chunks is ~2.8 M updates over the sweep, and the touch filter drops
repeats, so the queue should never saturate.

**Falsified if:** sustained (> 3 consecutive samples) drift > 5 %, or
`dropped_events_total` > 0. Either means the reported occupancy cannot be
trusted as the basis for eviction, which would undercut V2, V3 and V5 as well.

**Not a falsification:** `df` exceeding `du`. That gap is the C1 §6.2 prediction
and is measured properly in V3.

### 1b. Convergence to the low watermark

- Occupancy crosses 76.0 GB, an eviction cycle runs, and occupancy returns to
  **≤ 68.0 GB**.
- Steady state thereafter oscillates in **[68.0, 76.0] GB**.
- Occupancy never exceeds **80.0 GB** (the budget itself) by more than one
  cycle's worth of writes.
- `stargz_fs_cache_occupancy_ratio` tracks `bytes_used / 80e9` and stays ≤ 1.0.

**Falsified if:** occupancy sits above 76.0 GB for > 60 s while eviction is
enabled, or undershoots below 61.2 GB (10 % past the low watermark — the
takeInOrder overshoot bound), or `evictions_total` stays 0 while occupancy is
above the high watermark.

### 1c. No EIO for the whole sweep — the headline claim

- **0** read errors across all 280 ballast files, for the entire sweep, with
  occupancy pinned at the watermark the whole time.
- `stargz_fs_blob_fetch_errors_total` = **0**.
- `stargz_fs_cache_writes_skipped_total` = **0** *at this pre-fill level*: the
  partition is 92 GB and the budget 80 GB, so eviction should keep the volume
  from ever filling and pass-through should never engage.

**Falsified if:** any file returns a non-zero errno. This is the claim the
paper rests on; a single EIO here is a stop-and-report event.

**Note on what V1 does *not* prove:** `writes_skipped == 0` here is the
*eviction* claim, not the *pass-through* claim. Pass-through is exercised in V2,
where the partition genuinely fills.

---

## 2. V2 [P0] — pressure matrix, before/after

Pre-fill {0, 50, 90} % of the 92 GB partition with a `fallocate` filler, N=2,
budget 80 GB, then read all 280 files.

Note the geometry, because it decides which mechanism is under test at each
level: with an 80 GB budget on a 92 GB partition, a filler of X GB leaves
(92 − X) GB for the cache, and the budget only binds when 92 − X > 80.

| pre-fill | free for cache | which mechanism binds | predicted `writes_skipped` | predicted corrupted files |
| --- | --- | --- | --- | --- |
| 0 % | 92 GB | watermark eviction at 76 GB | **0** | **0 / 280** |
| 50 % (~46 GB) | ~46 GB | partition fills before the watermark → ENOSPC → emergency reclaim | **> 0** | **0 / 280** |
| 90 % (~83 GB) | ~9 GB | ENOSPC almost immediately, repeatedly | **≫ 0** (order 10³–10⁴) | **0 / 280** |

**Control — vanilla v0.18.2 at 90 %:** must reproduce the v4 failure. v4's S2 at
75 % pre-fill gave **20/280 ok, 260 EIO**. At 90 % we predict **≥ 200 of 280
files EIO**.

**Falsified if:**
- any corrupted/EIO file appears on our build at any level → the central claim
  of the paper is wrong, stop and report;
- `writes_skipped` stays 0 at 90 % on our build → pass-through never engaged and
  the level did not test what it was meant to;
- the vanilla control shows 0 EIO at 90 % → **the rig no longer reproduces the
  failure**, and V2's before/after is void for this run. This is the single most
  important negative control in the spike.

**Completion time (the price of honesty).** Predicted monotonic in pre-fill:
t(90 %) ≥ **1.5 ×** t(0 %). Recorded as a fact either way; there is no
pass/fail attached to the ratio, only to its sign (it must not be faster).

---

## 3. V3 [P0] — S5 restart loop, before/after

8 graceful `systemctl restart`s, no reads in between, budget 80 GB. v4 §13
measured **~17–18 GB per restart, linear, nothing reclaiming it**, reaching 84 %
of the partition after 5 restarts.

- **Occupancy never exceeds the budget.** `df` used stays **≤ 80 GB + one
  cycle's slack** at every step. Concretely: `df` ≤ **82 GB** after every
  restart, against v4's trajectory which would have passed 92 GB at restart 6.
- Duplication is still *created* — `evicted_bytes_total` should climb by roughly
  the per-restart duplication once the budget binds, i.e. **≥ 10 GB** of
  eviction across the 8 restarts.
- **0** read errors on the warm read after every restart, and the fuse-manager
  PID unchanged across all 8 (the #2387 fix holding).

**Falsified if:** `df` exceeds 85 GB at any step, or any restart produces a read
error, or the manager PID changes.

### 3b. The C1 §6.2 inode hypothesis

At every step record `du -sb` on `httpcache`+`fscache`, `df` used on
`/cache-part`, and `lsof +L1` (files with link count 0 still held open).

- **If C1 §6.2 is right:** `df_used − du_total` ≈ the total size reported by
  `lsof +L1`, within **±20 %**, and both grow across restarts. The duplication
  is deleted-but-open inodes held by the surviving FUSE manager.
- **If it is wrong:** `df_used ≈ du_total` (within the same ±20 %) and
  `lsof +L1` reports ≈ 0 bytes. The duplication is live files, and C1 §6.2 is
  refuted — which is a publishable result in its own right and would change what
  a future reattach-with-dedup has to do.

Both outcomes are pre-registered as informative. There is no "expected" one;
this is the first direct measurement of the question.

---

## 4. V4 [P1] — lying pod + sentinel probe

`contrib/sentinel-probe/sentinel-probe.sh` as a readiness probe on the predictor
pod, under pressure, two arms.

| arm | predicted probe exit | predicted standard readiness | predicted corruption |
| --- | --- | --- | --- |
| vanilla v0.18.2, 90 % pre-fill | **1** (red) | stays **green** | **> 0** files EIO |
| ours, 90 % pre-fill | **0** (green) throughout | green | **0** files EIO |

The vanilla arm is the point: v4 §5 showed a pod answering `GET /healthz` 200
and `POST /predict` 200 with byte-identical output while 262 of 280 files were
unreadable. The probe must catch what the standard probes miss.

**Falsified if:**
- the probe returns 0 on the vanilla arm while files are corrupt → **false
  negative, the probe is worthless** and must not be recommended;
- the probe returns 1 on our arm with 0 corruption → **false positive**, it
  would take healthy pods out of service;
- the probe returns exit 2 (cannot run) in either arm → inconclusive, not a
  result; the probe is misconfigured for this mount and the trial is void.

`writes_skipped_total` is expected to rise on our arm — that is the pod being
honest about degradation rather than failing.

---

## 5. V5 [P1] — the price of eviction (first live RQ1 datapoint)

Resident pod re-reading a 14 GB-class hot set, plus a concurrent 140 GB sweep,
budget 80 GB. Two separate runs: `policy = "lru"` then `policy = "2q"`.

The offline simulator on a synthetic scenario (C2-REPORT §4) gave resident hit
rate **0.286 lru vs 0.857 2q**, with lru evicting the resident set four times
over. That is synthetic and its effect size is not a prediction for the rig.
What is predicted is the *direction*:

| quantity | prediction |
| --- | --- |
| resident-pod read hit rate | **2q > lru by ≥ 10 percentage points** |
| resident-pod p95 read latency | **2q ≤ lru** |
| resident-pod p99 read latency | **2q ≤ 1.2 × lru** (allowing 2q to be slightly worse at the tail without counting as a reversal) |
| `evictions_total` over the run | **2q ≤ lru** (2q should churn less) |
| sweep completion time | **2q ≥ lru** (2q gives up the sweep, so the sweep refetches more) |

**Falsified if:** 2q's resident hit rate is ≤ lru's. That is the RQ1 result
reversing against the simulator, and it would mean the synthetic scenario is not
representative — worth more than a confirmation, and to be reported as the
headline of V5 if it happens.

**Known confound, recorded in advance:** 2q's protected set is empty after any
rebuild scan (C2-REPORT §6.2/§7.1), so the first pass of the resident workload
runs 2q as lru. The measurement window must start **after** the resident set has
been read twice. If it does not, the arm is void and will be flagged, not
reinterpreted.

---

## 6. Rules for this run

Carried from v4 unless noted:

1. **Facts and interpretation are separate blocks** in every section of the
   report.
2. **Per-trial bundles** under `results/<experiment>/<trial>/`, each with a
   `meta.txt` recording SHA, config, and wall-clock start.
3. **Invalid trials are preserved, never deleted**, in a directory suffixed
   `-INVALID`, with the reason narrated in the report's live-fixes section.
4. **Never `du` the `snapshotter/` subtree** — it walks into FUSE mounts and
   reports apparent TOC sizes (v4 §3/§9). Cache numbers come from `httpcache` +
   `fscache` via `du -sb`, cross-checked against `df`.
5. **Environment bugs are fixed and logged; bugs in our code stop the run** and
   go in the report. No patching the system under test on the rig.
6. Every binary, image digest and SHA recorded in an identity bundle.
7. The report's contents list is either kept current or omitted — v4's went
   stale (it still lists a §12 Cost that the finished document renumbered to
   §17 and never fixed).

## 7. Budget and stop conditions

- Hard budget **$40**. At $0.686/instance-hour × 2 instances, that is ~29 h of
  two-host time; v4's two runs together cost $6.38 in 4.65 h.
- The rig carries a **self-terminate watchdog** so that a lost session cannot
  leave instances billing.
- **Stop the run and report** if: any V1/V2 trial on our build produces a read
  error; the vanilla control fails to reproduce the v4 failure; or accounting
  drift falsifies V1a (every downstream measurement depends on it).
