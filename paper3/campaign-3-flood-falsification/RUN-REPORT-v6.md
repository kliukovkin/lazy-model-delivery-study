# Spike v6 — live confirmation of the fix round, and a clean repeat of v5's V5

**STATUS: COMPLETE**, with one deliverable unfinished and one evidence shortfall,
both stated plainly in §7 and §8. Facts are kept separate from interpretation
throughout, as in v5.

Read `results/EVIDENCE-INVENTORY.md` first if you intend to check anything: the
rig self-terminated on its watchdog before the collection step, so some results
are file-backed and others survive only as transcribed command output.

- pre-registration: [`PRE-REGISTRATION-v6.md`](PRE-REGISTRATION-v6.md), written
  and locked before the rig launched; §7 of it lists every amendment and when it
  was made.
- live fixes: [`results/LIVE-FIXES-v6.md`](results/LIVE-FIXES-v6.md)
- pre-checks: [`results/pre-checks/`](results/pre-checks/)

---

## 1. What was run, and on what

| | |
| --- | --- |
| system under test | `kliukovkin/stargz-snapshotter` `c2-eviction` @ `9829d7cf43fc645a28d2a79e86fe614d62764833` |
| negative control | same fork @ `f6547d991f0587429af5f9e42a3d80acc0f26f09` — the commit v5 ran, last before the F12/F2/F3/F10 fix round |
| vanilla control | upstream `v0.18.2` |
| rig | 2× `i4i.2xlarge`, us-east-1; node `i-0646a633e5b8d4254`, registry `i-0b67a16180b574408` |
| base AMI | `ami-025d99823a4caad37` (Ubuntu 24.04 amd64) |
| kubernetes | kind, `kindest/node:v1.36.1` |
| cache partition | `/dev/nvme1n1p2` → `/cache-part`, 92 GB, resolved by device model not by name (v5 F1) |
| budget | `bytes = 80000000000`, high 0.95, low 0.85 |
| fuse manager | `enable = true`, `KillMode=process` drop-in, **`metrics_address` deliberately unset** |
| launched | 2026-09-11T02:36:44Z |

The three binary sets were built on the node from source, and each arm's running
manager is md5-checked against the directory it was installed from before any
measurement (live fix G2).

---

## 2. E1 [P0] — F12 and F2, live

### 2.1 Facts — system under test (`9829d7cf`)

`[fuse_manager] metrics_address` **unset**. Scrapes are of the documented
`metrics_address` only. The gesture between observations is
`systemctl restart stargz-snapshotter` and nothing else.

| observation | config policy | cache series on :9110 | policy label | `index_lock_lost_total` | processes holding the index | `.corrupt` files | manager pid |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 baseline | lru | 39 | `lru` | 0 | 1 | 0 | 14929 |
| 2 after restart → 2q | **2q** | 39 | **`lru`** | **1** | **0** | 0 | 14929 |
| 3 after read under 2q | 2q | 39 | **`lru`** | 1 | 0 | 0 | 14929 |
| 4 after restart → lru | lru | 39 | `lru` | 1 | 1 | 0 | 14929 |
| 5 after read under lru | lru | 39 | `lru` | 1 | 1 | 0 | 14929 |

Warm read: `attempted=28 ok=28 err=0 bytes=15032385536 elapsed_s=80.275`.

Score: **7/9**. `E1.2` and `E1.4` failed; `E1.1, E1.3, E1.5, E1.6, E1.7, E1.8,
E1.9` passed.

`E1.7` is the precondition, and it holds: one manager pid across all five
observations. The manager survived every restart, which is the configuration
F12 is about, so the failures below are not an artefact of the rig failing to
reproduce the scenario.

### 2.2 Facts — negative control (`f6547d99`, the commit v5 ran)

Same procedure, plus `[fuse_manager] metrics_address = 0.0.0.0:9111` so the old
build has reachable metrics at all.

| observation | config policy | :9110 cache series | :9111 cache series | :9111 policy label | `.corrupt` |
| --- | --- | --- | --- | --- | --- |
| 1 baseline | lru | **0** | 38 | `lru` | 0 |
| 2 after restart → 2q | 2q | **0** | 38 | **`lru`** | **1** |
| 3–5 | … | **0** | 38 | **`lru`** | 1 |

Score: **3/3**. `N1.1`, `N1.2`, `N1.3` all reproduce.

From the manager's own log on this arm:

```json
{"error":"timeout","level":"warning","msg":"cache accounting: cannot use index at
 \"/var/lib/containerd-stargz-grpc/stargz/cache-accounting.db\", recreating it"}
{"duration":1326392141,"files":304406,"level":"info","msg":"cache accounting:
 rebuilt index by scanning the cache tree"}
```

A lock timeout, classified as corruption, renaming a healthy database and
rebuilding it by scanning 304,406 files. That is v5's F3, verbatim, on the
commit v5 ran.

### 2.3 Interpretation

**Three of the four fixes are confirmed live, on the rig where their symptoms
appeared.**

- **F2 — confirmed.** 39 `stargz_(cache|fs_cache)_*` series on the documented
  endpoint with the manager's own endpoint switched off, against 0 on the
  pre-fix build. The federation carries the cache metrics, and `E1.8`/`E1.9`
  confirm it does not do so by duplicating the runtime collectors, which was the
  hazard that made naive concatenation unusable.
- **F3, classification — confirmed.** `db_corrupt = 0` at every observation on
  the SUT, against `1` on the pre-fix build. A lost lock race no longer destroys
  a healthy index.
- **F3, counter — confirmed, and load-bearing.** `stargz_cache_index_lock_lost_total`
  is present, exports at 0 on a healthy node, and is what made the defect below
  visible at all.

**F12 is not fully fixed. `E1.2` is falsified.**

A `systemctl restart` with a changed policy does not deliver the new policy. The
label stays `lru` while the config on disk says `2q` — the same symptom v5
reported, from a different cause than either v5 *or* the fix round identified.

The mechanism is visible in the three columns that move together at observation
2: `index_lock_lost_total` 0 → 1, index holders 1 → 0, label frozen.
`fusemanager/service.go` `Init`:

```go
fs, err := service.NewFileSystem(ctx, fm.root, &fm.config.Config, opts...)  // opens the NEW index
...
releaseFileSystem(ctx, fm.curFs)                                           // releases the OLD one
fm.curFs = fs
```

The new filesystem is constructed — which opens the new accounting index, and
therefore tries to take the bolt flock — **while the old index still holds it**.
`releaseFileSystem` is the next statement, one line too late. So:

1. `openDB` waits 3 s and times out.
2. F3's new classification returns `ErrIndexLocked` instead of renaming the
   database — which is why nothing is corrupted, and why the old build's
   `.corrupt` does not appear here.
3. `newAccountant` logs, increments `index_lock_lost_total`, and returns `nil`.
4. Because the accountant is nil, `cachemetrics.Register` is never called, so
   the collector keeps pointing at the **previous** index.
5. `releaseFileSystem` then closes that previous index — hence holders drop to
   0 — and the collector goes on reporting a closed index's last known state,
   including its policy label.

The alternation in the table is consistent with this and is a second signature:
restart 1 loses the race (holders 0), restart 2 finds no incumbent index to
contend with and succeeds (holders 1).

**This is a bug in our code, so under PRE-REGISTRATION-v6.md §5.1 it stops the
experiment and goes in this report. It was not patched on the rig.** The fix is
a reorder — release the superseded filesystem before constructing its
replacement — but a rig carrying that patch would no longer be measuring
`9829d7cf`, and the point of E1 is what `9829d7cf` does.

**What this says about the fix round.** F3 is what made F12's residual defect
diagnosable. Before F3, this identical race renamed the index `.corrupt` and
rebuilt it, and the policy label went stale as collateral — indistinguishable, from
the outside, from "the config never arrived", which is exactly the wrong
diagnosis RUN-REPORT-v5 recorded and C2-REPORT §10.1 corrected. After F3 the
same race leaves a counter at 1, a healthy database, and a log line. The two
fixes caught each other.

**What no unit test could have caught.** The race needs a live FUSE manager that
survives a real `systemctl restart` while holding a bolt flock on a real
filesystem. `TestInitReleasesTheSupersededFilesystem` asserts that the
superseded filesystem *is* released, and it passes — the defect is in the
**order** of two correct operations, and the mutation that would have exposed it
(construct-then-release vs release-then-construct) is not a mutation of any
single statement.

---

## 3. E2 [P0] — the price of eviction

### 3.0 What E2's first run found before it measured anything

E2 run 1 completed normally and produced a result that matters more than the
latency comparison it was run for: **with a budget configured, a full accounting
queue stops the budget from bounding the partition.** Facts, mechanism and
options are in `results/CODE-FINDINGS-v6.md` C4; the short form is that the index
under-counted by 12.8 GB while dropping 127,337 update events, eviction acted on
the under-count, the partition filled, and the snapshotter then refused to start
with a fatal ENOSPC.

That run's bundle is preserved at `results/e2/run1-lru-attempt1/` with a note.
It is valid data — three warm passes, a full sweep, four measured rounds,
`writes_skipped = 0` throughout — and its `sampler.csv` is the evidence for C4.

E2 was then re-run from the start so that all four arm-runs share identical
starting conditions, with two harness changes (live fix G5): `hard_reset` before
`apply_policy`, and an accounting-health gate that refuses to measure an arm
whose index did not come up.

### 3.1 A caveat that applies to every number below

Because of C4, both policy arms run with a quantity of cached data the index does
not know about — up to ~13 GB by the end of a sweep, growing with dropped events.
So E2 does not compare "lru over an 80 GB cache" with "2q over an 80 GB cache".
It compares two policies each governing ~76 GB of *tracked* chunks inside an
~89 GB *actual* cache, with the untracked remainder evicted by neither.

This is symmetric between the arms, and the ABBA crossover plus gate G1 test
whether conditions were in fact comparable. It is stated here because a reader
entitled to quote the latency difference is also entitled to know that neither
arm was operating on the cache size its configuration named.

### 3.2 Facts

ABBA crossover, four arm-runs, `lru, 2q, 2q, lru`. Each: policy applied, full
`hard_reset`, accounting verified live, three warm passes, then 4 rounds of
resident latency under a concurrent 140 GB sweep. Latency files for all four
survive and the analysis below is reproducible with
`python3 scripts-as-run/21-e2-analyse.py results/e2`.

| run | policy | warm pass2 p50 | warm pass3 p50 | under sweep p50 | p95 | p99 | n | read errors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | lru | 588.6 | 604.1 | 539.1 | 628.7 | 685.6 | 112 | 0 |
| 2 | 2q | 590.5 | 603.6 | 532.1 | 581.5 | 617.6 | 112 | 0 |
| 3 | 2q | 706.0 | 620.6 | 644.1 | 717.1 | 729.2 | 112 | 0 |
| 4 | lru | 577.5 | 610.2 | 535.2 | 584.2 | 612.0 | 112 | 0 |

Gate:

| gate | result |
| --- | --- |
| **G1** — the four warm references agree within 5% | **PASS**, max deviation **1.8%** |
| **G2** — within each run, the reference pass is within 5% of the one before | **FAIL** — run3 12.1%, run4 5.7% |

**No comparison was computed**, as §2.3 of the pre-registration makes binding.

Every arm-run also recorded a full 140 GB sweep completing with
`attempted=280 ok=280 err=0 bytes=150323855360`, and `writes_skipped = 0` in
runs 1–3 (2 in run 4).

### 3.3 Interpretation

**The v5 confound is fixed.** v5's two arms had warm references 21.6% apart,
which is what made its `derived_hit_rate=1.000` for 2q an artefact of the
threshold rather than a result. v6's four arms agree to **1.8%**. G1 passing is
the thing v6 was built to achieve, and it achieved it.

**G2's failure is real, not noise, and that was checked rather than asserted.**
A 5% tolerance on a 28-sample median could plausibly be tighter than the
statistic's own error. It is not: bootstrap 95% CIs of the per-run pass-3 median
are 1.8–3.3% wide, and two independent 28-sample medians resampled from a single
run's own distribution differ by more than 5% in **0.0% of 4000 pairs**. Full
working in `results/e2/GATE-FAILURE-ANALYSIS.md`.

So in two of four arms the warm-up had not converged when the reference was
taken — run3 still warming (pass 2 was 11.3% *slower* than pass 3), run4 drifting
the other way. The failures point in opposite directions, so the fault is not "too
few passes" but **a fixed pass count that does not check whether it converged**.

**Even with a passing gate, this crossover would not have separated the
policies.** For the record and explicitly not as a result: the two 2q arms differ
from each other by 112 ms at p50, which exceeds any difference between the
policies. Under the pre-registered effect-size rule (§2.4) that is
"not separable at N=2". The run3 anomaly appears in both its warm-up and its
measurement, which is what one arm running in a different state throughout looks
like — not what a policy effect looks like.

**Fix, implemented but not run.** An adaptive warm-up: keep warming until two
consecutive passes agree within the same 5% the gate tests, use the last as the
reference, and mark the arm INVALID if it never converges. The tolerance is not
moved — the protocol now achieves the condition the gate checks instead of
assuming three passes achieve it. It is in `scripts-as-run/21-e2-eviction-price.sh`
and was staged to run when the rig's watchdog ended the session. **E2 therefore
remains the one unfinished deliverable of this spike.**

---

## 4. E3 [P1] — pressure at 90%, N=2, both arms

### 4.1 Facts

Transcribed; see `results/TRANSCRIBED-EVIDENCE.md`. 90% pre-fill of the 92 GB
partition via `fallocate`, then a full read of all 280 files. kubelet eviction
confirmed disabled through the running kubelet's `configz` before each trial
(v5's F8, scripted and asserted this time rather than remembered).

| arm | rep | ready | sweep | ok / 280 | errors | bytes read | writes_skipped | evictions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **ours** `9829d7cf` | 1 | 1.85 s | 1235.4 s | **280** | **0** | 150,323,855,360 | 6,499 | 2,981,840 |
| **ours** | 2 | 1.84 s | 1240.9 s | **280** | **0** | 150,323,855,360 | 7,969 | 2,981,841 |
| vanilla `v0.18.2` | 1 | 1.30 s | 30.1 s | 7 | **273 EIO** | 4,227,858,432 | 0 | 0 |
| vanilla | 2 | 2.93 s | 25.8 s | 7 | **273 EIO** | 4,194,304,000 | 0 | 0 |

### 4.2 Interpretation

**Every pre-registered expectation met, at N=2, with both reps agreeing closely.**

- **E3.1 confirmed.** Our build reads the entire 150 GB model with zero errors at
  90% pre-fill, both reps.
- **E3.2 confirmed — the control reproduces.** Upstream v0.18.2 reads 4.2 GB and
  fails 273 of 280 files with EIO, both reps. This is the load-bearing negative
  control: without it the before/after says nothing. It also reproduces v5's
  figure **exactly** (v5 V2 vanilla: 7/280 ok, 273 EIO), across a different rig
  instance and a different day.
- **E3.3 confirmed.** `writes_skipped` of 6,499 and 7,969 — the pass-through path
  was genuinely exercised rather than the budget quietly having room.
- **E3.4.** The price of honesty, now with a spread: 1235.4 s and 1240.9 s, 0.4%
  apart. The control "finishes" in ~28 s because it fails, which is not a
  completion time and is not comparable.

This is the paper's main table at N=2, and it is the cleanest result in the
spike: two arms, two reps each, near-identical within arm and total between arms.

---

## 5. E4 [P1] — is the sampled trace salvageable?

### 5.1 Facts

Transcribed. Index dumped every 5 s during E2 run 1's resident-only phase —
14 GB hot set, inside an 80 GB budget, nothing else running, which is the scale
most favourable to the approach.

```
snapshots=18 interval_span_s=91
adds=312662 gets=12005 total=324667
vanished_between_snapshots=1181     vanish_rate=0.0038
get_share=0.0370
```

| id | expectation | result |
| --- | --- | --- |
| E4.1 | < 10% of admissions vanish between dumps | **PASS — 0.38%** (v5 at 30 s/sweep scale: 92%) |
| E4.2 | gets are > 5% of events | **FAIL — 3.7%** (v5: 0.05%) |
| E4.3 | trace parses in the documented format | PASS, 324,667 events |

### 5.2 Interpretation

This is a more useful outcome than a clean pass, because it separates two causes
that v5 could not.

**Sampling can capture admissions.** At 5 s on a workload that fits the budget,
the vanish rate falls from 92% to 0.38% — a 240× improvement. v5's conclusion
that "92% of chunks are never observed" is a property of sweep-scale churn
against a 30 s interval, not of the approach.

**Sampling cannot capture reuse.** Gets improved 74× (0.05% → 3.7%) and still
missed the 5% bar, on a workload constructed to be nothing but reuse. That
isolates the blocker to the index's **one-minute last-access bucket**: reads
falling inside the bucket of a chunk's own admission collapse into it and are
never visible, at any dump interval.

So the standing recommendation — build trace emission on the update path — is now
a measured claim with the cheap alternative eliminated at the one scale where it
had a chance, rather than an opinion. The artefact is header-labelled
`DERIVED-NOT-CAPTURED` and no policy comparison is computed from it.

---

## 6. Findings in the system under test

Full detail, with fixes and the tests that would catch each, in
`results/CODE-FINDINGS-v6.md`. **None was patched on the rig** — a patched binary
would no longer be the SHA this report claims to measure.

| id | sev | what |
| --- | --- | --- |
| **C1** | P0 | `Init` constructs the new filesystem — which opens the accounting index — **before** releasing the old one, so the newcomer loses the bolt lock. `newAccountant` returns nil, nothing evicts, and the metrics collector keeps a stale binding. Roughly every other restart leaves the node with a configured budget and no enforcement. Introduced by the F12 fix in `137e9661`. |
| **C4** | P0 | A full accounting queue does not merely misreport occupancy — with a budget configured it **defeats the budget**. Drift is linear in dropped events at ~100 KB per drop (one chunk × two cache trees); eviction acts on the under-count; the partition fills; the snapshotter then dies on start with a fatal ENOSPC. |
| **C2** | P2 | The FUSE manager truncates its log on every start, so the log covering a restart is gone as soon as the next manager starts — in the scenario `KillMode=process` exists to support. |
| **C3** | P2 | `stargz_fs_blob_fetch_errors_total` counts **background prefetch** failures, while `docs/overview.md` offers `rate(...) > 0` as an alert meaning "reads are actually failing". Observed: counter at 1, zero reads affected. |

### What this says about the fix round

**F2 and F3 are confirmed working; F12's fix is incomplete; F10 was documentation
and is unaffected.**

The interesting part is that they caught each other. Pre-F3, the C1 race renamed
the index `.corrupt` and rebuilt it, and the policy label went stale as
collateral — externally indistinguishable from "the config never arrived", which
is the wrong diagnosis RUN-REPORT-v5 recorded and C2-REPORT §10.1 corrected.
After F3, the same race leaves a counter at 1, a healthy database, and a log line
naming the cause. **F3 is what made F12's residual defect diagnosable.**

And none of it was reachable by unit test. C1 is a defect in the *order* of two
individually correct statements, which no single-statement mutation expresses;
`TestInitReleasesTheSupersededFilesystem` asserts the release happens and passes.
C4 needs sustained write pressure against a real partition. Both need a live FUSE
manager surviving a real `systemctl restart`.

---

## 7. Live fixes

Environment and harness, fixed on the rig and recorded in
`results/LIVE-FIXES-v6.md`.

| id | what |
| --- | --- |
| G1 | three docker restarts in one setup run trip systemd's start rate limiter |
| G2 | installing binaries + restarting does **not** switch arms — `KillMode=process` keeps the previous manager, which is what produces every metric. Now replaced explicitly, with an md5 assertion |
| G3 | the build-readiness probe could not see an eStargz image (OCI *index*, not manifest, in the `Accept` header) |
| G4 | `local tag="$1" d="${OUT}/obs-${tag}"` — bash expands all arguments to `local` before assigning any, so `set -u` killed a 40-minute experiment. Compounded by a monitor whose `pgrep -f` matched its own command line and reported "running" for 40 minutes after the script had died |
| G5 | an arm-run leaves the partition full (because of C4) and the next arm restarted the snapshotter *before* wiping, hitting the ENOSPC fatal |
| G6 | a pod left from a previous run survives `hard_reset`, which destroys its mount; `deploy_pod` is then a no-op and every read returns ENOTCONN. A 43-second arm produced a complete-looking bundle |

G4 and G6 share a shape worth naming: **a failure that is fast looks like a
success**. Both now have explicit guards — an `ERR` trap and an exit marker for
G4, a refusal to measure an arm whose warm pass returned any read error for G6.

---

## 8. Pre-registration scorecard

| id | expectation | outcome |
| --- | --- | --- |
| E1.1 | cache series present on the documented endpoint | **CONFIRMED** (39 series, `[fuse_manager] metrics_address` unset) |
| E1.2 | policy label follows a restart to 2q | **FALSIFIED** → C1 |
| E1.3 | label follows back to lru | confirmed (vacuously — label never left `lru`) |
| E1.4 | `index_lock_lost_total` present and 0 throughout | **FALSIFIED** (went to 1) → C1 |
| E1.5 | exactly one process holds the index | confirmed |
| E1.6 | no `.corrupt` appears | **CONFIRMED** — F3 working |
| E1.7 | manager pid unchanged (precondition) | confirmed |
| E1.8 | runtime collectors not duplicated | confirmed |
| E1.9 | exposition parses | confirmed |
| N1.1 | pre-fix build: no cache series on `:9110`, present on `:9111` | **CONFIRMED** |
| N1.2 | pre-fix build: label stuck at lru | **CONFIRMED** |
| N1.3 | pre-fix build: `.corrupt` or ≥2 holders | **CONFIRMED** (`.corrupt` appeared) |
| E2.1 | gates G1 and G2 pass | **G1 PASS (1.8%), G2 FAIL** |
| E2.2–E2.4 | 2q faster / higher hit rate | **NOT COMPUTED** — gate binding |
| E2.5 | zero resident read errors | **CONFIRMED**, 448 measured reads across four arms |
| E2.6 | evictions > 0 | confirmed (2.6–2.8 M per arm) |
| E2.7 | `writes_skipped` = 0 | confirmed in 3 of 4 arms; run4 had 2 |
| E2.8–E2.9 | effective policy label correct, 2q promotes | confirmed (`2q`, not `2q-unpromoted`) |
| E3.1 | ours 280/280, 0 errors, both reps | **CONFIRMED** |
| E3.2 | vanilla reproduces the failure | **CONFIRMED** (7/280, 273 EIO, both reps) |
| E3.3 | `writes_skipped` > 0 | **CONFIRMED** |
| E3.4 | completion time recorded | confirmed (1235.4 / 1240.9 s) |
| E4.1 | vanish rate < 10% | **CONFIRMED** (0.38%) |
| E4.2 | gets > 5% of events | **FALSIFIED** (3.7%) |
| E4.3 | trace parses | confirmed |

**7 falsifications or partial failures out of 26**, all of them informative. The
pre-registration did its job twice over: it stopped a latency comparison that
would not have survived scrutiny (E2), and it turned E4's shortfall into a
measurement that eliminates an alternative rather than a vague "needs more work".

---

## 9. Cost and timing

| | |
| --- | --- |
| instances | 2 × `i4i.2xlarge`, us-east-1, on-demand @ $0.686/h |
| lifetime | 2026-09-11T02:36:44Z → ~13:36Z (11 h, the user-data watchdog) |
| **compute** | **≈ $15.1** |
| EBS | 2 × 30 GB gp3 for 11 h, ≈ $0.06 |
| **total** | **≈ $15.2 of the $100 ceiling (15%)** |

Wall clock of actual work was ~4 h 45 m (02:36Z–07:21Z); the remaining ~6 h were
an idle gap in which the watchdog did exactly what it is for. Phases: setup and
artifact build ~50 m (the 140 GB image is still the single largest fixed cost, and
v5 left no snapshot to reuse); E1 ~35 m including one invalidated attempt; E2
~2 h 20 m across three attempts; E3 ~45 m; E4 and diagnosis the remainder.

**Teardown verified** (`results/TEARDOWN-VERIFICATION.txt`): 0 instances,
0 volumes, 0 snapshots, 0 AMIs in us-east-1, and 0 running instances in three
other regions.

---

## 10. What this spike does not establish

1. **The price of eviction is still not quotable.** G1 passing means the method
   now works; G2 failing means two arms were measured before converging. The
   adaptive warm-up that fixes it is written and staged but never ran. This is
   the one deliverable v6 owes.
2. **Nothing here says 2q beats lru.** At N=2 the within-policy spread (112 ms)
   exceeds the between-policy gap, so the honest statement is "not separable",
   and more reps are needed *after* the warm-up fix, not instead of it.
3. **C4's scope is one write rate.** It was observed with shipped defaults
   (`queue_size` 8192, `flush_interval_sec` 5) under a deliberately extreme
   140 GB sweep. It shows the bound is not robust at that rate; it does not say
   how common that rate is. The cheap next measurement is the write rate at which
   drops begin, determinable offline.
4. **Evidence is incomplete.** The watchdog fired before `90-collect.sh` ran, so
   E3's and E4's bundles, E1's observation dumps and E2's samplers were lost with
   the instance store. Their results are transcribed verbatim in
   `results/TRANSCRIBED-EVIDENCE.md` and the split is stated in
   `results/EVIDENCE-INVENTORY.md`. v6 does not meet the bundle-per-trial
   convention v4 and v5 met. The fix is mechanical and should be a standing rule:
   **collect after every experiment, not once at the end.**
5. **C1's fix is unverified.** The reorder is a two-line change with a stated
   trade-off (a window where `curFs` is nil if construction fails) and a unit
   test that needs no rig. Neither has been written.
