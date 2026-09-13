# Spike v6 — pre-registration

Written **before** the rig is launched. Nothing below is edited afterwards; where
a run contradicts it, the contradiction is recorded in `RUN-REPORT-v6.md` and
this file stays as written. That is the whole point of it existing.

- authored (workstation clock): 2026-09-10
- system under test: `github.com/kliukovkin/stargz-snapshotter`, branch
  `c2-eviction`, **`9829d7cf43fc645a28d2a79e86fe614d62764833`** — the head of
  the fix round that closed F12/F2/F3/F10.
- negative-control build: **`f6547d991f0587429af5f9e42a3d80acc0f26f09`** — the
  commit spike v5 ran, i.e. the last one *before* those four fixes.
- vanilla control build: upstream `v0.18.2`.
- rig: 2× `i4i.2xlarge`, `us-east-1`, kind + containerd 2.3.1, stargz cache on a
  real 92 GB NVMe partition at `/cache-part`, `budget = 80 GB`, watermarks
  0.95/0.85, `[fuse_manager] enable = true` plus the `KillMode=process` drop-in.

---

## 0. Why this spike exists

Two debts from v5.

The first is that the four fixes shipped in the fix round were verified by unit
test and by mutation, on a laptop. **Every one of them is a fix to a symptom
that only appears on a two-host rig under restart**, which is precisely the
setting no unit test reaches. F12 in particular was re-diagnosed during the fix
round: RUN-REPORT-v5's account of its mechanism was wrong (the config does reach
the manager; what leaked was the superseded filesystem), so the fix does not
follow from the published diagnosis and the live behaviour has never been
checked against the corrected one.

The second is that v5's V5 — the price-of-eviction measurement, and the first
live RQ1 datapoint — produced an **uninterpretable** comparison. The two policy
arms did not share a baseline: the all-hits warm reference was p50 484.9 ms
under `lru` and p50 589.5 ms under `2q`, a 21.6% gap on a measurement whose
whole content is a latency difference between the two. Worse, the derived
hit-rate is computed against a threshold taken from each arm's *own* warm
reference, so the slower baseline mechanically produced the headline
`derived_hit_rate=1.000` for 2q against `0.143` for lru. That number cannot be
quoted, and v6 exists partly to replace it with one that can.

---

## 1. E1 [P0] — F12 and F2, live, where they appeared

### 1.1 What is being tested

Whether a `systemctl restart stargz-snapshotter` with a changed
`[cache_accounting.budget] policy`, on a node where `KillMode=process`
deliberately keeps the FUSE manager alive across that restart, now (a) delivers
the new policy to the process that evicts and (b) leaves every `stargz_*` series
readable from the single documented endpoint.

### 1.2 Configuration, and one deliberate omission

`[fuse_manager] metrics_address` is **left unset** on the SUT arm. v5 had to set
it — its run-order README records the 20 minutes that discovering this cost —
and the F2 fix claims it is no longer necessary, because the snapshotter's own
`metrics_address` now federates the manager's series. Leaving it unset is what
makes E1.1 a test rather than a formality. The negative-control arm sets it (see
§1.5), because without it the old build has no reachable metrics at all and the
F12 symptom would be unobservable rather than absent.

### 1.3 Procedure

1. Install the SUT arm (`9829d7cf`), `policy = "lru"`, `budget = 80 GB`.
2. Read the 14 GB image through the lazy mount, so the counters carry real
   values and at least one eviction cycle has had a chance to run.
3. Record the manager's PID and the set of processes holding
   `<root>/stargz/cache-accounting.db`.
4. Scrape **only** `metrics_address` (`:9110`). Save verbatim.
5. Edit the config: `policy = "lru"` → `policy = "2q"`.
6. `systemctl restart stargz-snapshotter`. Nothing else — no manager kill, no
   socket removal. This is the operator gesture, and it is the gesture v5's
   `set_policy()` had to work around.
7. Record the manager's PID again, and the db holders again.
8. Scrape `:9110` again. Save verbatim.
9. Repeat 5–8 once more in the other direction (`2q` → `lru`), so the label is
   shown to track the config rather than to have moved once.

### 1.4 Pre-registered expectations, SUT arm

| id | expectation | falsifier |
| --- | --- | --- |
| E1.1 | `stargz_cache_bytes_used`, `stargz_cache_chunk_count`, `stargz_fs_cache_budget_bytes` and `stargz_fs_cache_evictions_total` are all present in the `:9110` scrape, before and after each restart | any one of them absent |
| E1.2 | after the `lru`→`2q` restart, `stargz_fs_cache_evictions_total` carries a series with `policy="2q"` or `policy="2q-unpromoted"`, and `stargz_fs_cache_budget_bytes` is still 8e10 | the only policy label present is still `lru` |
| E1.3 | after the `2q`→`lru` restart, a `policy="lru"` series is present again | label stuck at 2q |
| E1.4 | `stargz_cache_index_lock_lost_total` is present and reads **0** at every scrape | > 0 at any scrape |
| E1.5 | exactly **one** process holds `cache-accounting.db` at every check | ≥ 2 holders |
| E1.6 | no `cache-accounting.db.corrupt` exists at any point | the file appears |
| E1.7 | the manager PID is **unchanged** across the restarts | manager was replaced — then the restart is not the scenario F12 is about, and E1.2 proves nothing |
| E1.8 | `go_goroutines` and `process_open_fds` each appear **exactly once** in the `:9110` scrape | duplicated — the federation is emitting two copies of the runtime collectors, which is a malformed exposition |
| E1.9 | the `:9110` body parses as a valid Prometheus exposition (no duplicate family, no malformed line) | parse fails |

E1.7 deserves a note: it is a *precondition*, not a result. If the manager turns
out to be replaced by the restart, then this rig is not reproducing the
configuration F12 describes, and E1.2's success would be vacuous. It is listed
as an expectation so that it cannot be quietly skipped.

### 1.5 Pre-registered expectations, negative control (`f6547d99`)

Same procedure, same config **plus** `[fuse_manager] metrics_address = 0.0.0.0:9111`,
so the old build's metrics exist somewhere to be read.

| id | expectation | falsifier |
| --- | --- | --- |
| N1.1 | **no** `stargz_cache_*` or `stargz_fs_cache_*` series on `:9110`, while they are present on `:9111` | present on `:9110` — F2 was not a real defect on this rig |
| N1.2 | after the `lru`→`2q` restart, the policy label on `:9111` still reads `lru` | label changes — F12's symptom does not reproduce |
| N1.3 | at least one of: a `cache-accounting.db.corrupt` appears, or ≥ 2 processes hold the db | neither — the leak does not reproduce |

**If N1.1 and N1.2 both fail to reproduce, E1's before/after is void for this
run** and will be reported as such rather than as a confirmation. A fix whose
symptom cannot be shown on the same rig is not demonstrated by that rig.

---

## 2. E2 [P0] — the price of eviction, done cleanly

### 2.1 The v5 confound, stated so it can be checked

v5 ran one arm per policy, back to back, `lru` first. Its all-hits warm
reference differed by 21.6% between arms, and the hit-rate classifier used a
per-arm threshold taken from that reference. Two consequences, both fatal to
interpretation:

- the latency comparison is confounded with whatever made the baselines differ
  (arm order, NVMe state, page cache, residue from the previous arm's sweep);
- `derived_hit_rate` is not comparable across arms at all, because a slower
  baseline raises the threshold that decides what counts as a hit. 2q's
  `1.000` is what that artefact looks like.

### 2.2 Design

**ABBA crossover**, N = 2 per policy, four arm-runs in the order
`lru, 2q, 2q, lru`. A crossover is what makes an order effect visible: if the
first and last `lru` runs differ from each other by as much as `lru` differs
from `2q`, the experiment has measured drift and says so.

Per arm-run:

0. Change the policy with a **plain `systemctl restart stargz-snapshotter`**, not
   with v5's kill-and-replace-the-manager workaround, and assert the new policy
   through the metric label before proceeding. The workaround existed only
   because of F12; using it here would hide a regression and would also make E2
   run on a different mechanism than E1 tests. If the assertion fails, that is a
   finding: it is recorded, E1's verdict is revisited, and only then does the run
   fall back to the workaround so E2 can still produce data.
1. `hard_reset` — wipe both cache trees, restart the stack.
2. Deploy the resident pod on the 14 GB image (28 × 500 MB hot set).
3. **Three** warm passes over the hot set, not two:
   - pass 1 populates the cache (cold, discarded),
   - pass 2 is the first all-hits pass and is what promotes chunks out of 2q's
     probation,
   - pass 3 is the **warm reference** used for the baseline gate and for the
     hit threshold.
   Pass 2 is kept as a convergence check: pass 3 must be within 5% of pass 2,
   or the cache was not actually warm and the "reference" is not one.
4. Start the sampler and the periodic index dump.
5. Deploy the sweep pod on the 140 GB image and start its full read.
6. Measure resident latency for 4 rounds under that pressure.

### 2.3 Gate — run before any comparison is computed

**G1 (baseline agreement).** Let `p50_i` be the pass-3 warm p50 of arm-run
i ∈ {1..4} and `m` their mean. Require

    max_i |p50_i − m| / m ≤ 0.05

**G2 (warmth).** For every arm-run, |p50(pass 3) − p50(pass 2)| / p50(pass 2) ≤ 0.05.

If G1 or G2 fails: **stop E2, do not run or report the policy comparison**,
and spend the time on diagnosis instead — dump per-round latencies, NVMe
`iostat`, page-cache state, `df`/`du` residue, and the order in which arms ran.
The task's instruction is explicit that a knowingly dirty comparison is not
worth rig hours, and v5 is the precedent.

Diagnosis output is a deliverable in its own right: `results/e2/GATE-FAILURE.md`.

### 2.4 Pre-registered expectations, if the gate passes

| id | expectation | direction pre-registered because |
| --- | --- | --- |
| E2.1 | G1 and G2 pass | the point of the redesign |
| E2.2 | resident p50 under sweep is **lower under 2q than under lru** | 2q protects a hot set that has been read twice; the sweep's own chunks are read once and stay in probation. This is the mechanism C2-REPORT §6.2 claims and the reason 2q exists |
| E2.3 | resident p95 and p99 likewise lower under 2q | the tail is where eviction of the hot set shows up |
| E2.4 | derived hit-rate higher under 2q, computed against the **pooled** threshold (§2.5) | same mechanism |
| E2.5 | **zero** resident read errors under both policies | the C2 honesty claim; a single EIO falsifies the headline result of the whole branch |
| E2.6 | `stargz_fs_cache_evictions_total` > 0 under both policies | with a 140 GB sweep against an 80 GB budget, eviction must run, or the experiment did not apply pressure |
| E2.7 | `stargz_fs_cache_writes_skipped_total` = 0 under both | the budget should bind before the partition fills; a non-zero value means eviction did not keep up and the run is measuring pass-through, not policy |
| E2.8 | on the 2q arms the policy label is `2q` and/or `2q-unpromoted`, never `lru`; on the lru arms it is `lru` | F3's effective-policy label, live for the first time |
| E2.9 | on a 2q arm, a `policy="2q"` series (not only `2q-unpromoted`) carries a non-zero count by the end | the hot set was read twice in warm-up, so something is promoted and the ranking is genuinely scan-resistant. If everything lands under `2q-unpromoted`, 2q degenerated to lru for the whole run and E2.2 would be expected to fail — the two are linked |

**Effect-size rule for N=2.** With two reps per policy the honest statement is
non-parametric: a difference between policies counts as observed only if

    |median(2q) − median(lru)| > max( |rep1−rep2| within lru , |rep1−rep2| within 2q )

i.e. the between-policy gap exceeds the largest within-policy gap. Anything
smaller is reported as "not separable at N=2" and not as a result.

### 2.5 Hit-rate: two thresholds, both reported

- **per-arm threshold** — max of that arm's own pass-3 warm reference. This is
  what v5 reported, kept only so the two spikes are comparable.
- **pooled threshold** — max of the pass-3 warm references of all four arm-runs
  pooled. This is the one E2.4 is stated against, and the one the paper will
  quote, because it does not move when a baseline moves.

Both distributions are written out raw so the classification can be redone by
anyone who disagrees with either threshold.

---

## 3. E3 [P1] — V2 at 90%, N = 2, both arms

Brings the paper's main table to N = 2 at the level that matters.

| id | expectation | falsifier |
| --- | --- | --- |
| E3.1 | ours, 90% pre-fill: **280/280 files read, 0 errors**, both reps | any read error |
| E3.2 | vanilla v0.18.2, 90% pre-fill: a large majority of reads fail with EIO, both reps | vanilla is clean — then this rig no longer reproduces the paper-2 failure and E3's before/after is **void**, which is recorded rather than worked around |
| E3.3 | ours: `stargz_fs_cache_writes_skipped_total` > 0 | zero means the pressure never reached the cache-write path |
| E3.4 | ours: sweep wall-clock recorded per rep — the price of honesty, with a spread | — |

E3.2 is the load-bearing control. It is listed with a falsifier that voids the
comparison because a before/after whose "before" is healthy says nothing.

---

## 4. E4 [P1] — access-log capture for the simulator

### 4.1 Amendment, made before launch

This section was rewritten after reading v5's F13 and re-checking the source,
and **before the rig was launched**. The first draft assumed the capture was a
matter of rig time. It is not, and pretending otherwise would have pre-registered
an expectation that could not fail honestly.

`cache/accounting/sim/trace.go:77-79`, at the SUT SHA `9829d7cf`, says it
outright: the trace format "is not emitted by the accounting index today -
producing it from a live node is the next piece of work this simulator needs".
Nothing in `cache/accounting/` writes one. So a *real* capture needs a code
change, and §5.1 forbids changing code on the rig — a patched binary would not
be the SHA this report claims to measure.

v5 already tried the only rig-side substitute: dump the bolt index every 30 s and
diff consecutive dumps. Its F13 quantifies why that fails, on v5's own V1 sweep:
**615 `get` events out of 1,197,434**, because the index stores last-access in
one-minute buckets and any faster reuse collapses into the existing record; and
**1,097,392 of 1,196,819 admissions (92%) disappeared between consecutive
snapshots**, admitted and evicted inside one interval, never observed at all.
Feeding that to a policy simulator would compare policies on a workload with no
reuse, which is not the workload.

v6 therefore does **not** re-run that substitute at sweep scale. Repeating a
measurement already shown to be structurally inadequate is not evidence.

### 4.2 What E4 actually is in v6

A bounded test of whether the substitute is salvageable *at a scale where it
might be*, plus the design input that unblocks the real thing.

The v5 failure has two causes and they scale in opposite directions. The
one-minute bucket is fixed and defeats fast reuse regardless of workload. The
92% vanishing rate is a consequence of the sweep: 140 GB against an 80 GB budget
admits and evicts faster than any sampler can watch. The resident hot set in E2
is the opposite case — 14 GB, inside the budget, deliberately re-read. If the
approach works anywhere, it works there.

So: during E2's warm-up phase only (resident pod, no sweep running), dump the
index every **5 s** instead of 30 s, and measure the two failure modes directly.

| id | expectation | falsifier / meaning |
| --- | --- | --- |
| E4.1 | during the resident-only phase, the fraction of admissions that vanish between consecutive 5 s dumps is **< 10%** | ≥ 10% — the sampling approach fails even on a workload chosen to favour it, and the derived trace is dead at any scale |
| E4.2 | `get` events are **> 5%** of total events in that window | ≤ 5% — the one-minute bucket dominates, and no sampling interval fixes it; only emission from the update path can |
| E4.3 | a trace file is produced in the documented format (`<unix seconds> <add\|get> <key> <size>`), header-labelled `DERIVED-NOT-CAPTURED`, and `ParseTrace` accepts it | parse error — the dumper's output does not match the format the simulator reads, which is worth knowing before the real writer is built |

E4.1 and E4.2 are **pre-registered to be reported either way**. A failure here is
a useful result: it converts "we should build trace emission" from an opinion
into a measured claim, with the sampling alternative eliminated at the one scale
where it had a chance.

### 4.3 What E4 does not claim

No policy comparison will be computed from this trace, at any vanishing rate.
The artefact is labelled `DERIVED-NOT-CAPTURED` in its header, as v5's was, so it
cannot later be mistaken for a captured workload.

## 4b. Inherited hazards — things v5 paid for that v6 must not pay for again

Listed here, in the pre-registration, because each one silently invalidates a
trial rather than failing loudly, and "we knew about that" after the fact is
worth nothing.

| v5 id | hazard | what v6 does about it |
| --- | --- | --- |
| F6 | `02-build-artifacts.sh` does not source `env.sh` and defaults `SIZES_GB=140`, so the 14 GB image is silently not built — and E2's resident pod needs it | pass `SIZES_GB="140 14"` explicitly at invocation, and **assert both manifests exist** before any experiment starts |
| F8 | kubelet's `evictionHard` at `nodefs.available: 10%` kills the pod at 90% pre-fill before any read happens, so the trial measures kubelet rather than the cache. v5 fixed this live and **never scripted it** | set `evictionHard` to 0%/0% and **verify through kubelet's `configz` endpoint**, as a scripted, asserted step of E3 — not a remembered manual one |
| F11 | a long background copy run in parallel with a measurement contaminated V5 attempt 1 | **nothing runs in parallel with a measurement.** No exports, no snapshots, no builds, during E1–E3 |
| F5 | a Prometheus `CounterVec` exports nothing until first use, so an absent series reads as blank, not 0 | already fixed in `lib.sh`; v6 additionally asserts that `stargz_cache_index_lock_lost_total` — a plain Counter, which *does* export at 0 — is present, which is exactly why F3's fix made it a plain Counter |
| — | v5 built no registry snapshot, so v6 pays the full ~1 h 39 m artifact rebuild | accepted. The task requires 0 snapshots at teardown, so v6 cannot leave one either; the rebuild is priced in and is not on the critical path of anything but the start |

## 5. Stop rules

These are binding, and are written here so that deciding to invoke one is not a
judgement made under time pressure at 2 a.m.

1. **A bug in our code stops the experiment that hit it.** It is recorded in
   `results/LIVE-FIXES-v6.md` and in the report, and it is *not* patched on the
   rig. A rig patch would mean the run no longer measures the SHA it claims to.
2. **Environment bugs are fixed on the rig** and recorded with the same
   discipline.
3. **G1/G2 failure stops E2's comparison**, as above. Rig hours go to diagnosis.
4. **A void control voids its comparison** (N1.1/N1.2 for E1, E3.2 for E3). The
   result is reported as void, not as a pass.
5. **Every trial that is started is preserved**, including the ones that go
   wrong. Invalid trials keep their data and are renamed `*-INVALID` with a
   `WHY-INVALID.txt` beside them.
6. The rig is terminated at the end, and the termination is *verified*: 0
   instances, 0 volumes, 0 snapshots.

## 6. What would make this spike a failure

Stated in advance so it cannot be redefined afterwards:

- E1 confirms nothing because the negative control does not reproduce the v5
  symptom — the fixes remain unvalidated live.
- E2's gate fails and the price-of-eviction number is still not quotable after
  a second attempt.
- Any resident read error under our build at any point, which would contradict
  the branch's central claim.

Any of these is a legitimate outcome of a live run and will be reported as one.

---

## 7. Amendments after authoring, before the experiment they affect

Recorded here, in the pre-registration itself, so the diff between what was
promised and what was run is visible in one place rather than reconstructed from
the report.

| when | what | why it is not a silent edit |
| --- | --- | --- |
| before launch | §4 (E4) rewritten from "capture a trace" to "test whether the sampled substitute survives at a scale that favours it", with two numeric falsifiers | the first draft was written without v5's F13. `cache/accounting/sim/trace.go` says at the SUT SHA that the index does not emit a trace, so a real capture needs a code change, which §5.1 forbids on the rig. Pre-registering an unachievable expectation is worse than admitting the block |
| before launch | §4b added: the v5 hazards (F6, F8, F11, F5) that silently void trials, each with the countermeasure v6 uses | they were known before the rig started and would otherwise have been "we knew about that" after the fact |
| before launch | §2.2 step 0 added: E2 changes policy with a plain `systemctl restart` and asserts the label, falling back to v5's manager-replacement workaround only if that fails, and recording it as a finding if it does | v5's workaround existed because of F12; using it unconditionally would hide a regression and would run E2 on a different mechanism than E1 tests |
| before E2 ran | `sync` + `drop_caches` between E2 arm-runs | the node has 64 GB of RAM and the hot set is 14 GB, so page-cache residue from the previous arm's 140 GB sweep is a between-arm difference unrelated to policy. It is belt-and-braces on gate G1, not a substitute: it cannot manufacture agreement, and a gate failure still stops the comparison |

Nothing in §§1–6 was weakened, and no expectation or falsifier was changed after
the rig was launched.
