# Pre-registration — spike v9

**Locked at 2026-09-12, BEFORE any v9 rig exists.** No v9 instance had been
launched, no snapshot had been touched and no measurement had been taken when
this file was written. Everything below that is a refinement of the task's
pre-registered text is marked **[REFINEMENT]** and carries its reason; the
refinements were all decided before the rig build, as the task permits.

Three campaigns, closing the three gaps the red team flagged against paper 3:

| id | question | rig |
| --- | --- | --- |
| **V9-C** | is the honesty price (0% vs 90% pre-fill) reproducible at N=5? | registry + 1 node |
| **V9-A** | does one tenant's sweep flush another tenant's hot set? | same rig, reused session |
| **V9-B** | is registry-side read amplification linear in the number of exhausted nodes? | registry + 3 nodes |

Run order is V9-C, then V9-A, then V9-B — cheapest first, and V9-B is the only
one that needs the two extra hosts.

---

## 0. Binding rules

1. **Honest reporting is the pass condition, not a particular outcome.** Each
   campaign below names what would falsify its expectation. A falsified
   expectation is reported as falsified, at the top of the report, in the same
   type size as a confirmation.
2. **Within-session only.** No absolute time from v9 is compared with an
   absolute time from v5–v8, or from one v9 instance with another. Every
   comparison this spike makes is between arms measured on the *same* instance
   in the *same* session. v8's E1 is why: the 16% it chased was cross-session
   variation and vanished at 0.2% within a session.
3. **Invalid trials are preserved and flagged**, never deleted. A trial that
   fails its entry conditions gets `WHY-INVALID.txt` and a `-INVALID` suffix and
   stays in `results/`.
4. **An experiment that has not been collected is not finished.** Evidence
   bundle per trial, pulled to the workstation at the end of that trial, before
   the next one starts (v7 rule 1; v6 lost four experiments to the alternative).
5. **Cost tripwire: $120.** Accounting is instance-hours × on-demand rate +
   EBS + Fast Snapshot Restore, recomputed at each campaign boundary. If the
   *projection to completion* crosses $120 the run stops and reports. It does
   not silently continue and it does not silently shrink the design.

---

## 1. What is measured, and on what

| | |
| --- | --- |
| system under test | `kliukovkin/stargz-snapshotter`, branch `c2-eviction`, commit **`6e87e34e`** — the binary the paper evaluates |
| vanilla control | upstream `v0.18.2` (only where an arm needs it; no v9 campaign requires it) |
| rig | `i4i.2xlarge`, us-east-1, **all hosts in one AZ** |
| cache partition | real NVMe partition, ~92 GB at `/cache-part`, bind-mounted into the kind node |
| budget | 80 GB, watermarks 0.95 / 0.85, policy `lru`, accounting on — identical to v7/v8 |
| kubelet | `EVICTION_MODE=kind-default` (eviction thresholds 0%), asserted against the *running* kubelet before any pre-filled trial (v5 F8) |
| images | `model-ballast:estargz-140g` (280 × 512 MiB files, ~150 GB read), `model-ballast:estargz-20g` (40 × 512 MiB files, ~20 GB) |

### 1.1 [REFINEMENT] Harness lineage

The task says to reuse `bench-results-v7/scripts-as-run/`. v9 is built on
**`bench-results-v8/scripts-as-run/`**, which is that same harness (identical
`lib.sh`, `env.sh`, `00-*`, `01-`, `02-`, `04*-`, `05-`, `06-`, `9*-`) plus the
resident-pod-under-sweep machinery v8's E2 added, which is exactly the shape
V9-A needs. Using v7's copy would mean re-deriving that machinery. The v9 copies
of every script actually executed are preserved under `scripts-as-run/`.

### 1.2 [REFINEMENT] Correction to a figure quoted in the task

The task states the 20.6% honesty price as "v8 point estimate". It is not v8's:
v8 measured build attribution (E1) and the policy question (E2) and never
measured the honesty price. The figure is **v5's**, from its V2 pressure matrix
at N=1 — 1289.2 s at 90% pre-fill against 1069.4 s at 0%, +20.55% — and it is
what the manuscript carries as `\honestyPricePct`. The pre-registered interval
below is unchanged; only the attribution is corrected, and it is corrected here
rather than in the report so that the correction cannot be mistaken for a
post-hoc adjustment.

### 1.3 [REFINEMENT] The registry serves from NVMe, not from the restored EBS volume

Two facts force this, and both were established before v9 launched:

- v8's E0 measured the v7 artifact snapshot's lazy load from S3 at **14–48 MB/s**
  and paid **2 h 57 m** to pre-warm it. A restore left in that state cannot feed
  one node, let alone three.
- The restored volume is gp3 provisioned at **750 MB/s**. V9-B expects three
  nodes drawing ~140 MB/s each, and its pre-registered question is whether the
  *registry NIC* saturates. A 750 MB/s disk ceiling sitting below the ~1.5 GB/s
  NIC ceiling would answer a different question than the one asked.

So: **Fast Snapshot Restore** is enabled on `snap-0118cc5716e9e8a54` for the
target AZ before launch (v8's own §2 recommendation, never tested — v9 tests it),
and the registry's blob store is **copied onto the host's NVMe instance store**
and served from there. Both ceilings are measured explicitly and recorded in the
report: `fio` on the serving filesystem, and `iperf3` registry→node for the NIC.
Nothing is snapshotted from the instance store — the artifact snapshot already
exists and is not rewritten — so v5's F-series trap does not reopen.

### 1.4 New code written for v9

`v9-lat-loop.py` — pod A's reader for V9-A. The harness's existing `lat_probe`
walks a fixed file list in order and prints one line per read; V9-A needs
**continuous random-order full-file reads with wall-clock timestamps in CSV**, so
that A's latency can be sliced by "before B", "during B" and "after B". It is a
new reader, not a modified one, and the existing `lat_probe` is used unchanged
for the warm-up passes.

---

## 2. V9-C — honesty-price replication, N=5

**Design.** Interleaved same-session A/B of full-read completion at 0% vs 90%
pre-fill, our build only, N=5 pairs alternating `0, 90, 0, 90, …` on one
instance in one session.

**Pre-registered expectation (verbatim from the task):**

> Expect the median price within **[15%, 26%]** (v8 point estimate 20.6%);
> report median + min–max.

**How the price is computed.** Pair *i* is (run at 0%, run at 90%) run
back-to-back in that order; price_i = (t90_i − t0_i) / t0_i. The reported
statistic is the **median of the five pair-wise prices**, with min–max. Pairing
is fixed in advance so the statistic cannot be chosen after seeing the data.

**Reset procedure between arms — identical every time, documented because the
task requires it:**

1. `hard_reset` — stop the unit, SIGTERM then SIGKILL the FUSE manager, remove
   the stale socket, lazily unmount orphaned stargz FUSE mounts, wipe
   `stargz/httpcache/*`, `stargz/fscache/*` and every `*filler*.img`, delete
   `cache-accounting.db` (a reset that leaves the index describing a cache that
   no longer exists is not a reset), `sync`, restart the unit, assert active.
2. Assert the running kubelet's eviction thresholds are 0% (v5 F8).
3. `fallocate` the arm's filler: nothing at 0%, 90% of the partition at 90%.
4. `sync; echo 3 > /proc/sys/vm/drop_caches` — the node has 64 GB of RAM and the
   previous arm read 150 GB through it; page-cache residue is a difference
   between arms that has nothing to do with the budget. **[REFINEMENT]**, carried
   over from v8's E2 where it was added mid-run and disclosed.
5. Deploy a fresh pod, wait Ready, read all 280 files.

**Collected per run:** completion s, files ok/err, `writes_skipped`, evictions,
`du`/`df` samples at 10 s, full metrics dump, snapshotter journal, fuse-manager
log, pod events, ENOSPC counts. Evidence bundle collected at trial end.

**What falsifies it.** A median outside [15%, 26%]; or a min–max spread so wide
that the median is not a meaningful summary (reported as such, with the five
prices in full, not smoothed). Either is reported as a falsification of the
paper's point estimate, and the manuscript's `\honestyPricePct` is then wrong
and must change.

**Additional pre-registered check.** v5 found the relation **non-monotonic**
(50% slower than 90%) and could not say whether that was real at N=1. v9 does
not run the 50% level, so v9 cannot settle it; the report will say so rather
than leave the impression that N=5 at two levels addressed it.

**Zero read errors are required at both levels.** Any EIO/ESTALE on our build at
any pre-fill level is a P0 finding against the paper's central elimination
claim, and is reported as one.

---

## 3. V9-A — two-pod interference on one node

**Design.** Pod A serves from a fully warm ~20 GB hot set (`estargz-20g`, 40
files, an image **disjoint from B's** so that registry-side attribution is
unambiguous by blob digest). Pod B sweeps the 140 GB-class image through the
same 80 GB budget under LRU. N=2 repetitions.

**Pre-registered expectation (verbatim from the task):**

> With pod A serving from a fully warm ~20 GB hot set and pod B sweeping a
> 140 GB-class image through an 80 GB budget (LRU), A's hot set WILL be partially
> evicted: A's p99 read latency rises during/after B's sweep and A performs
> refetches (>0 refetched bytes). Pass/fail is honest reporting either way: "no
> interference" (A's p99 within the warm-baseline envelope, 0 refetches) would
> falsify I6's premise and must be reported as such. A MUST NOT see a single read
> error — any EIO/ESTALE on A is a FATAL finding for the paper.

**Stated plainly, because it cuts against the expectation.** The mechanism
argument runs the other way and this is recorded *before* the measurement: A's
reader is continuous, so A's chunks are re-referenced every loop (~20 GB at warm
speed is on the order of 20 s), while B's sweep is a single pass whose own tail
ages for minutes. Under LRU the oldest resident chunks are B's own, so I6's
"a sweep must evict its own tail" predicts B largely self-evicts and A is
substantially protected. **If A is not evicted, that is a result, not a failed
run**, and it revises what I6's second clause ("whether it may also flush other
images' resident hot sets is the eviction policy's business") means in practice.
Both outcomes are pre-registered as publishable; neither is a reason to retune
the experiment.

**Protocol per repetition.**

1. `hard_reset`, cache empty, no filler (A + B working set is already ~170 GB
   against an 80 GB budget; a filler would only change which resource binds).
2. Deploy A. Warm it: read all 40 files twice via the existing `lat_probe`, then
   confirm steady state — a third pass whose p50 agrees with the second within
   5% and **0 registry GETs on A's blob digests during that pass** (this is the
   "confirm 0 refetches in steady state" condition, made checkable).
3. **Baseline:** A's random-order loop reader runs ≥ 5 min with nothing else on
   the node. Record p50/p95/p99 and the full per-read CSV. This is the envelope
   the expectation refers to.
4. Deploy B; B reads all 280 files of `estargz-140g`. A's reader keeps running
   throughout and for **5 min after** B completes.
5. Collect: A's latency CSV with timestamps; A's refetched bytes from the
   registry access log, keyed on A's blob digests, split by phase; node-side
   eviction counters and `evicted_bytes`; B's completion; budget/`du`/`df`
   samples at 10 s; both daemons' logs.

**Statistics fixed in advance.** A's read latency is summarised as p50/p95/p99
over three disjoint windows: `baseline` (step 3), `under-sweep` (B Ready →
B's last read), `after` (the 5 min tail). "p99 rises" means the under-sweep or
after p99 exceeds the baseline p99 by more than the baseline's own
between-repetition spread. Refetch is counted as **bytes served by the registry
for A's blob digests after A's warm-up completed**; 0 is 0.

**Fatal condition.** Any read error on A — any `errno` at all in A's CSV — stops
the campaign and is reported at the top of the run report as a P0 finding
against the paper.

---

## 4. V9-B — multi-node registry amplification, k = 3

**Design.** One registry host; k = 3 node hosts, each a single-node kind cluster
with our snapshotter, each on its own ~92 GB partition with its own 80 GB budget
at 90% pre-fill. All three read the same 140 GB-class image.

**Pre-registered expectation (verbatim from the task):**

> (i) every node's budget holds (du ≤ budget, 0 read errors, ~same per-node
> behavior as single-node); (ii) aggregate registry egress ≈ 3× the single-node
> 150.3 GB, i.e. registry-side read amplification is linear in k; (iii) per-node
> completion time ≥ the single-node same-class time, growing if the registry NIC
> saturates (record NIC throughput ceiling explicitly).

**Protocol.**

1. **Ceilings, recorded before any round.** `iperf3` registry→each node (NIC
   ceiling, GB/s) and `fio` sequential read on the registry's serving filesystem
   (disk ceiling, GB/s). Both go in the report. Without them, clause (iii) is
   uninterpretable.
2. **k = 1 baseline, in this session.** One node alone does the full read at 90%
   pre-fill. Records that node's completion time *and* the registry egress for
   k = 1 measured the same way as for k = 3. This is the only baseline any v9
   comparison uses; v5's 150.3 GB is quoted as context, never as a term in a
   v9 comparison (rule 0.2).
3. **k = 3 rounds.** All three nodes start within a 5 s window, coordinated by
   `ssh` fan-out from the registry host; the **actual start skew is measured and
   reported**, not assumed. N = 2 rounds, with a full re-prefill and `hard_reset`
   on every node between rounds.
4. **Registry host sampling**, 5 s cadence for the whole window: `/proc/net/dev`
   tx bytes, plus `/proc/diskstats` and load, for the whole window including the
   idle margins either side. The registry container's access log is retained
   (`json-file`, `max-size=1g`) and parsed per blob digest.
5. **Per node**, the standard v7 sampler (`du`/`df`/metrics/evictions/pressure)
   plus the full-read result.

**Definitions fixed in advance.** "Aggregate registry egress" is the registry
host's **`/proc/net/dev` tx byte delta** over the round, which counts everything
that actually left the host. The access log's summed response bytes is reported
beside it as a cross-check; if the two disagree by more than 5% the report says
so and treats the NIC counter as authoritative. "Linear in k" means the k = 3
aggregate lies within **±15%** of 3× the in-session k = 1 egress.

**What falsifies it.** Any node exceeding its budget on `du`; any read error on
any node; aggregate egress outside ±15% of 3×; or per-node completion *faster*
than the in-session k = 1 baseline. Each is reported as a falsification.

**Known confound, declared now.** The three nodes are separate instances, so
their absolute completion times are not comparable with each other under rule
0.2 — only each node's k = 3 time against **its own** k = 1 time is. The k = 1
baseline is therefore run on the node that will also be measured in k = 3, and
the report will not rank the three nodes against one another.

---

## 5. Cost model

| item | rate | note |
| --- | --- | --- |
| `i4i.2xlarge` on-demand, us-east-1 | $0.686 / h | 2 hosts for V9-C + V9-A, 4 for V9-B |
| gp3 1200 GB restored data volume | ~$0.13 / h all-in | incl. provisioned 8000 IOPS / 750 MB/s |
| Fast Snapshot Restore | $0.75 / h per snapshot-AZ | enabled before launch, disabled at teardown |
| EBS roots, 4 × 30 GB | negligible | |
| data transfer | $0 | all hosts in one AZ, private IPs only |

**Projection at lock time: ≈ $50 for a ~13 h session** (2 hosts for ~7 h, 4 for
~5 h, FSR for the whole window). The tripwire is $120. The projection is
recomputed at each campaign boundary and printed in the report; crossing it
stops the run.

**Watchdog.** Every instance boots with `shutdown -h +900` and
`instance-initiated-shutdown-behavior=terminate`, so a lost workstation cannot
leave the rig billing indefinitely. 15 h is above the projection and below the
tripwire even at four hosts.

---

## 6. Teardown

All instances terminated; FSR disabled; the v9 data volume deleted with its
instances. **The v7 artifact snapshot `snap-0118cc5716e9e8a54` survives** — it is
the only object this account is expected to keep. Teardown is verified by
enumerating instances, volumes, snapshots, AMIs and FSR registrations, and the
raw output goes in `results/TEARDOWN-VERIFICATION.txt`.
