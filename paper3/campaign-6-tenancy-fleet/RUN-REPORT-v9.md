# Spike v9 — multi-node amplification, two-tenant interference, N=5 replication

**STATUS: COMPLETE** — all three campaigns ran. Facts are kept separate from interpretation. Anomalies are
at the top, not buried.

- pre-registration: [`PRE-REGISTRATION-v9.md`](PRE-REGISTRATION-v9.md), locked
  before any v9 instance existed.
- raw data: `results/v9a/`, `results/v9b/`, `results/v9c/`
- scripts as run: `scripts-as-run/`

| campaign | question | outcome |
| --- | --- | --- |
| **V9-C** | is the honesty price reproducible at N=5? | **yes — median +18.51%, inside the pre-registered interval. But v5's 20.6% point estimate is NOT reproduced** |
| **V9-A** | does one tenant's sweep flush another's hot set? | **yes, measurably — and a bigger finding: one tenant alone already thrashes the budget** |
| **V9-B** | is registry read amplification linear in k? | **yes — linear to within 0.1% at k=3. But per-node time did NOT degrade, falsifying clause (iii)** |

---

## 0. Anomalies and failures, up front

### 0.1 Four hours of rig time lost to an orchestration bug I wrote

> **Read §0.1b with this section.** The diagnosis below was my first one and it
> is *incomplete*: it blames a node-side timeout and the ssh client, and both
> turned out to be innocent bystanders. The actual cause is in §0.1b. This
> section is kept as written because the sequence of symptoms is the useful part.

V9-B's first attempt produced nothing. The node-side script waited a fixed 600 s
for the registry's "go" signal; the workstation's launch `ssh` did not return for
10.5 minutes, so the readiness poll never ran, and the node aborted 31 s before
the signal arrived. The registry then waited 2.5 h for a completion marker that
could not appear. node1's own sshd journal is unambiguous: **no connection was
attempted between 23:36:37 and 23:47:13**.

Compounding it, the progress monitor fired only on log *change*, so a frozen
campaign was indistinguishable from a quiet one. The stall ran undetected for
about four hours (~$9 of idle rig time).

Three fixes, all in `scripts-as-run/`: node patience 600 s → 3600 s with
self-cleanup on expiry (`50-v9b-node.sh`); the launch `ssh` backgrounded on the
workstation and never waited on (`53-v9b-run.sh`) — `setsid` + `ssh -n` + a
remote `exit 0` were tried first and were **not** sufficient, the client still
did not return; and a liveness probe in the registry's wait loop so a dead node
aborts the round instead of hanging it (`52-v9b-registry.sh`). After the fix,
readiness detection took **16 s** instead of 10.5 min.

### 0.2 Fast Snapshot Restore does not do what v8 recommended it for

RUN-REPORT-v8 §2 recommended FSR on the strength of AWS's documentation, never
tested. v9 tested it. FSR reached `enabled` at 18:18:36; the volume created 57 s
later came back **`FastRestored: None`** and read at 61 MB/s at QD1 with 91 ms
await — i.e. still lazy-loading from S3, exactly v8's symptom.

**Cause: an FSR registration starts with an empty credit bucket.** For a 1200 GiB
snapshot the bucket holds one credit and refills at ~0.85/hour, so a volume
created minutes after enabling gets no fast restore at all. FSR is useless to a
same-day rig unless enabled ~2 h ahead. It billed 1.5 h ($1.16) for nothing and
was disabled.

**The workaround is concurrency**, because a lazy restore is latency-bound rather
than bandwidth-bound. Measured on this volume: 1 reader 61 MB/s, 16 readers
208 MB/s, 64 readers 339 MB/s. A chunk-parallel copier
(`07b-fetch-blobs.sh`) moved only the 11 blobs v9 reads — 150 GB in **17.8 min**
against v8's 2 h 57 m — and **every blob was verified against its own sha256**,
which a registry blob's filename is.

### 0.3 The account cannot run this rig on-demand

The vCPU quota is 16, so 4 × `i4i.2xlarge` on-demand is impossible, and the
`REDACTED-IAM-USER` principal has no `servicequotas` permission to request an increase.
Nodes 2 and 3 ran as **spot** (same type, same AZ, $0.364/h). Both were reclaimed
by AWS mid-session and relaunched. Disclosed because it is a real constraint on
reproducing this rig, not because it changed any measurement.

### 0.4 A post-lock protocol change in V9-A

V9-A's warm-up was changed from the pre-registered fixed third pass to an
adaptive one. See §3.1. The tolerance did not move; the protocol changed so that
it *achieves* the pre-registered condition instead of assuming it.

---

## 1. What was run, and on what

| | |
| --- | --- |
| SUT | `kliukovkin/stargz-snapshotter` `c2-eviction` @ **`6e87e34e1d8da4ca10e44b81a1891d583a4e66d5`** |
| rig | `i4i.2xlarge`, us-east-1a; registry + node1 on-demand, node2/node3 spot |
| budget | 80 GB, watermarks 0.95/0.85, policy `lru`, accounting on |
| partition | 97.83 GB real NVMe at `/cache-part`, bind-mounted into the kind node |
| kubelet | eviction thresholds asserted 0%/0%, `imageGCHighThresholdPercent: 100`, against the RUNNING kubelet every pre-filled trial (v5 F8) |
| images | `estargz-140g` (280 files, **150.4 GB in 11 blobs**), `estargz-20g` (40 files, 21.5 GB, built fresh) |
| registry | served from the **1.7 TB NVMe instance store**, not the restored EBS volume (pre-reg §1.3) |

`estargz-140g` measuring 150.4 GB across 11 blobs independently confirms the
manuscript's `\oursBytesRead` of 150.3 GB.

**Registry ceilings, measured before any round** (`results/v9b/ceilings.txt`):

| ceiling | value |
| --- | --- |
| NIC, iperf3 registry→each node | **11.918 Gb/s** (≈1.49 GB/s), identical to all three |
| disk, fio direct 4×16 on the serving filesystem | **1560 MB/s** |
| disk, buffered | 2934 MB/s |

The direct-I/O disk figure is only ~5% above the NIC, so the disk cannot be
cleanly excluded as a co-limiter at full saturation. Serving is buffered in
practice and the host has 64 GB of page cache, so the NIC is the more likely
binding constraint — but v9 does not claim that as established.

### 0.1b The actual root cause, found on the third attempt

The first diagnosis in §0.1 was incomplete, and the correction matters more than
the original claim. The node-side 600 s timeout was real but was **not** why V9-B
hung. The registry-side orchestrator contained:

```sh
{ ...5 s NIC sampler, an infinite loop... } > registry-nic.csv &
SPID=$!
for p in "${NODES[@]}"; do ( ssh "$p" touch go ) & done
wait                       # waits for EVERY job -- including the sampler
```

**A bare `wait` in a shell that owns a daemon never returns.** Both attempts
stopped at exactly the same line, "fanning out the go signal", and would have
hung indefinitely regardless of any node timeout. The fix is to collect the
fan-out pids and `wait "${FANPIDS[@]}"`.

Two further consequences were only visible once this was understood. The stale
registry orchestrators from the failed attempts were **still running their 5 s
samplers hours later** — killing a workstation-side driver does not kill the
remote process it started over ssh — so they were adding load to the registry
host during the retry and had to be reaped explicitly. And node1's k=1 trial
actually *succeeded* on attempt 2 (`read_s = 1164.5`); only the registry side of
that round was lost, which is why the round was re-run rather than salvaged.

This is recorded at length because the surface symptom — "ssh does not return",
"the node timed out waiting" — pointed at the network and the node, and both were
innocent.

### 0.5 V9-B was rebuilt in a second availability zone

Partway through V9-B, **us-east-1a ran out of `i4i.2xlarge` capacity entirely**.
The session's spot nodes were reclaimed twice — at 04:49:39 with
`instance-terminated-no-capacity` — and a subsequent single-instance probe was
refused with `InsufficientInstanceCapacity`, AWS explicitly naming other AZs.
With the on-demand vCPU quota at 16 (two hosts), k=3 could not be assembled in
us-east-1a by any combination of on-demand and spot.

The whole V9-B rig was therefore rebuilt in **us-east-1b** and every V9-B
measurement — the k=1 baseline and both k=3 rounds — was taken there, in one
session, on that rig. This preserves the pre-registered requirement that all
hosts share one AZ and that comparisons are within-session; it does mean **V9-B
ran on different instances, in a different AZ, from V9-C and V9-A**. Under rule
0.2 no absolute number is compared across those campaigns anyway, and none is in
this report.

The node1 k=1 baseline measured in us-east-1a before the move
(`read_s = 1174.2`, 280/280, 0 errors, 158.71 GB registry egress) is **not** used
in any V9-B comparison, for that reason. It is retained under
`results/v9b/k1-node1-*` as a first-rig observation and labelled as such.

### 0.6 Two more orchestration defects, found during the rebuild

**`ssh` without `BatchMode=yes` blocks on a password prompt.** The rebuilt
registry had not been given the rig's ssh key (it was installed on the *first*
registry hours earlier), so the ceiling probe fell through publickey to an
interactive prompt and hung for 8 minutes with no error. `BatchMode=yes` turns
that into an immediate failure. The same latent bug would have hung V9-B's
go-signal fan-out, which is ssh from the registry to every node.

**`SIZES_GB= ` does not disable the artifact build.** `02-build-artifacts.sh`
reads `SIZES_GB="${SIZES_GB:-140 14}"`, and `:-` substitutes the default for an
*empty* value as well as an unset one. An invocation intended to build only the
small predictor image therefore started **regenerating the 140 GB ballast from
`/dev/urandom` on the registry host**, and a retry loop around it would have
restarted that build every 15 s. It was caught and killed before any V9-B round
ran; had it run underneath one, it would have contaminated the registry-side
throughput measurement that V9-B exists to make. The retry loop was removed and
both images verified present by manifest instead.

Both are recorded because they are the same class of defect as §0.1b: an
orchestration bug whose surface symptom points somewhere else entirely.

---

## 2. V9-C — the honesty price, replicated at N=5

### 2.1 Facts

Five interleaved pairs, `0, 90, 0, 90, …`, one instance, one session, our build
only. Every run read all 280 files and exactly 150.3 GB.

| pair | 0% sweep_s | 90% sweep_s | price | wr_skip 0% / 90% | evictions 0% / 90% |
| --- | --- | --- | --- | --- | --- |
| 1 | 974.196 | 1123.267 | **+15.30%** | 0 / 7,999 | 2,342,302 / 2,990,029 |
| 2 | 954.676 | 1131.591 | **+18.53%** | 0 / 7,467 | 2,187,502 / 2,985,934 |
| 3 | 950.492 | 1131.265 | **+19.02%** | 0 / 9,256 | 2,167,346 / 2,994,134 |
| 4 | 953.362 | 1129.828 | **+18.51%** | 0 / 12,815 | 2,362,652 / 2,990,029 |
| 5 | 950.935 | 1124.103 | **+18.21%** | 0 / 13,632 | 2,261,292 / 2,994,121 |

```
N = 5 pairs
MEDIAN  +18.51%      min-max  +15.30% .. +19.02%   (spread 3.72 pp)
mean/sd +17.91% / 1.49 pp
read errors, all 10 runs: 0        files: 280/280 every run
pre-registered interval [15%, 26%]:  CONFIRMED
```

### 2.2 Interpretation

**The interval is confirmed; the point estimate is not.** The paper carries
`\honestyPricePct = 20.6%`, which is v5's single observation (1289.2 s vs
1069.4 s, N=1, on an instance that no longer exists). **All five v9 pairs came in
below it** — the largest was 19.02%. The pre-registered [15%, 26%] holds, but
20.6% is outside the entire observed range of a five-pair within-session
replication.

Recommendation for the manuscript: quote **+18.5% (median of N=5, within-session,
range 15.3–19.0%)**, or quote a range. Do not keep a one-decimal point estimate
derived from N=1 cross-session.

**Pair 1 is the low outlier** at +15.30% against 18.2–19.0% for pairs 2–5, and its
0% arm (974.2 s) is the slowest of the five. It is the first trial after the smoke
tests — the same "first arm inherits machine state" pattern that failed v8's E2
gate. It is reported, not dropped; the median is robust to it either way.

**`writes_skipped` behaves exactly as designed** and reproduces v5: 0 at every 0%
arm, where the budget binds before the partition; 7,467–13,632 at every 90% arm,
where the partition binds first and the ENOSPC pass-through path engages.

**An ENOSPC logging asymmetry, confirmed.** At 90% pre-fill the snapshotter
journal contains **0** "no space left" lines while the fuse-manager log contains
**16**. An operator grepping the documented journal would see a clean node. v4 §4
flagged this; v9 confirms it at a 100% undercount. Against ~8–14 k
`writes_skipped`, the counter remains the only reliable signal.

**Scope.** v9 measured 0% and 90% only. v5's non-monotonic 50% result (50% slower
than 90%) is **not** addressed by this campaign and remains unexplained at N=1.

---

## 3. V9-A — two-pod interference on one node

### 3.1 The post-lock protocol change, stated first

PRE-REGISTRATION-v9 §3 step 2 specified a fixed third warm-up pass gated at 5%.
That is the design v8's own `results/e2/GATE-FAILURE-ANALYSIS.md` had already
shown does not reliably converge, and which v8 replaced with an adaptive warm-up.
Writing the superseded version into v9 was an authoring error, and **rep 1
reproduced the known failure on the first attempt**: pass 2 607.4 ms, pass 3
643.1 ms, +5.9%, drifting the wrong way. That repetition is preserved as
`results/v9a/rep1-INVALID/` with its `WHY-INVALID.txt`.

The warm-up is now adaptive (passes 3–8, converge when two consecutive agree
within 5%). **The 5% tolerance did not move.** What changed is that the protocol
achieves the pre-registered condition instead of assuming three passes achieve
it, and a repetition that never converges is still INVALID. Rep 3 then needed
**5 passes** — it too would have been discarded by the original design.

Two valid repetitions (rep 2, rep 3) plus one preserved invalid.

### 3.2 Facts — A's read latency, by phase

| rep | window | n | p50 ms | p95 ms | p99 ms | errors |
| --- | --- | --- | --- | --- | --- | --- |
| 2 | baseline | 453 | 465.6 | 1770.2 | 3301.4 | 0 |
| 2 | under-sweep | 1012 | 551.8 | 4204.1 | 4728.8 | 0 |
| 2 | after | 575 | 459.3 | 738.6 | 1672.0 | 0 |
| 3 | baseline | 565 | 462.0 | 709.0 | 1320.5 | 0 |
| 3 | under-sweep | 991 | 548.9 | 4150.5 | 4902.7 | 0 |
| 3 | after | 498 | 459.7 | 1353.5 | 3208.0 | 0 |

B completed 280/280, 150.3 GB, in 1133.5 s and 1137.6 s — within 0.4% of each
other and of the V9-C 90% arms, despite sharing the node with A.

### 3.3 Facts — A's cache hit rate, by phase

Latency alone cannot separate cache eviction from B merely competing for CPU and
NVMe bandwidth. The decisive quantity is how much of A's read volume the node
served without going back to the registry, attributable because A's image has its
own blobs (`41-v9a-regcap.sh`, `45-v9a-refetch-by-phase.py`).

| rep | phase | A read | registry served | hit rate | refetch rate |
| --- | --- | --- | --- | --- | --- |
| 2 | baseline (A alone) | 243.2 GB | 12.609 GB | **94.82%** | 42.0 MB/s |
| 2 | under-sweep | 543.3 GB | 56.350 GB | **89.63%** | 49.7 MB/s |
| 2 | after | 308.7 GB | 5.560 GB | **98.20%** | 18.0 MB/s |
| 3 | baseline (A alone) | 303.3 GB | 4.054 GB | **98.66%** | 13.5 MB/s |
| 3 | under-sweep | 532.0 GB | 77.682 GB | **85.40%** | 68.3 MB/s |
| 3 | after | 267.4 GB | 12.315 GB | **95.39%** | 40.1 MB/s |

A and B share exactly one blob — the 2.28 MB `busybox:1.36` base layer, since both
images are `FROM busybox`. Attribution uses **A-unique blobs only**; the shared
layer is reported on its own line (2.3 MB total) rather than folded in or dropped.

### 3.4 Interpretation

**The refetch clause is CONFIRMED, and the fatal condition did not fire.** A
performed 74.5 GB (rep 2) and 94.1 GB (rep 3) of post-warm-up refetch, and saw
**zero read errors** across every repetition — no EIO, no ESTALE, in 3,094
measured reads. The paper's central elimination claim survives a second tenant.

**The interference is real but modest, and the p50 is the stable signal.** A's p50
rose **+18.5%** (rep 2) and **+18.8%** (rep 3) under B's sweep — two independent
repetitions agreeing to 0.3 pp. Hit rate fell 5.2 pp and 13.3 pp. Both
repetitions move the same way.

**The pre-registered p99 rule was under-powered and I am not going to pretend
otherwise.** §3 defined "p99 rises" as exceeding the baseline p99 by more than the
baseline's own between-repetition spread. That spread is |3301.4 − 1320.5| =
1980.9 ms — larger than most of the effect — so the rule marks only rep 3 as a
rise and is close to unfalsifiable at N=2. The rule as written cannot decide this
question; the p50 and hit-rate measures can, and both replicate.

### 3.5 The finding V9-A did not set out to make

**A single tenant cannot hold a 21.5 GB hot set in an 80 GB budget.** During the
baseline phase — pod A alone on the node, nothing else running — both repetitions
agree closely:

| rep | occupancy mean / max | du_http + du_fs | evictions in 300 s |
| --- | --- | --- | --- |
| 2 | 0.930 / 0.954 | 73.0 GB | 610,324 |
| 3 | 0.946 / 0.951 | 73.2 GB | 610,271 |

A's 21.5 GB of content occupies **~73 GB of cache — 3.4×** — pinning occupancy at
the 0.95 high watermark and evicting continuously with no second tenant present.
The smoke test measured 43 GB (2.0×, the known httpcache + fscache duplication)
after a *single* read, so the extra inflation accrues with re-reads. **v9 did not
isolate which tier dominates or whether the growth is stale copies or
accounting**, and that is the obvious next measurement.

This reframes I6. I6 asks whether a sweep may flush *another* image's hot set. The
prior question is that a tenant whose hot set is 27% of the nominal budget already
cannot keep it: the effective capacity is roughly budget/3.4, and A was refetching
at 13–42 MB/s before B existed. A's steady state is a ~95–99% hit rate, not the
zero-refetch state the pre-registration assumed — and the pre-registered entry
condition "0 registry GETs in steady state" was therefore **never satisfied**. I
implemented only the p50 half of that check, so the experiment ran without it;
had it been enforced, V9-A could not have started as designed.

Both reported interference numbers are therefore **interference on top of an
already-thrashing tenant**, not interference against a quiescent warm baseline.

---

## 4. V9-B — multi-node registry amplification, k = 3

All V9-B numbers come from the **us-east-1b rig** (§0.5). Every k=1 baseline and
both k=3 rounds were measured there, in one session.

### 4.1 Measured ceilings, before any round

| ceiling | value |
| --- | --- |
| NIC, iperf3 registry→node1 / node2 / node3 | **10.357 / 10.266 / 10.211 Gb/s** (≈1.29 GB/s) |
| disk, fio direct 4 jobs × iodepth 16 on the serving filesystem | **1485 MB/s** |

Clause (iii) is uninterpretable without these, which is why they are measured
rather than assumed. The registry serves from the NVMe instance store (§1.3), so
the disk ceiling sits above the NIC ceiling and the NIC is the binding resource.

### 4.2 In-session k = 1 baselines, one per node

The pre-registration requires **one** k=1 baseline. Running one per node is an
**addition made after the lock**, disclosed here: clause (iii) compares each node
against its *own* k=1 time, and rule 0.2 forbids comparing node A with node B, so
without a per-node baseline clause (iii) is simply not evaluable for nodes 2 and
3. Every baseline read all 280 files with zero errors.

| node | read_s | registry egress | files | errors |
| --- | --- | --- | --- | --- |
| node1 | 1344.565 | 157.92 GB | 280/280 | 0 |
| node2 | 1320.042 | 157.53 GB | 280/280 | 0 |
| node3 | 1327.898 | 157.05 GB | 280/280 | 0 |

Mean egress **157.50 GB**; spread across nodes 1.9% on time and 0.55% on egress.
Registry NIC during a k=1 read: mean 119 MB/s, peak 308 MB/s — **23.9%** of the
1.29 GB/s ceiling.

### 4.3 k = 3 rounds

Both rounds: all three nodes start within a measured skew of **4 ms** (round 1)
and **20 ms** (round 2), against a pre-registered requirement of 5 s.

| round | node | read_s | vs own k=1 | files | errors | du | aggregate egress |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | node1 | 1305.408 | **−2.9%** | 280/280 | 0 | 9.0 GB | **473.94 GB** |
| 1 | node2 | 1305.454 | **−1.1%** | 280/280 | 0 | 9.1 GB | |
| 1 | node3 | 1305.155 | **−1.7%** | 280/280 | 0 | 9.0 GB | |
| 2 | node1 | 1269.620 | **−5.6%** | 280/280 | 0 | 9.2 GB | **473.48 GB** |
| 2 | node2 | 1269.556 | **−3.8%** | 280/280 | 0 | 8.9 GB | |
| 2 | node3 | 1269.465 | **−4.4%** | 280/280 | 0 | 9.0 GB | |

Registry NIC: **9%** of ceiling at k=1, **28–29%** at k=3. Never saturated.
NIC-vs-access-log cross-check agreed to 2.1% (round 1) and 4.5% (round 2), both
inside the pre-registered 5% tolerance, so no disagreement had to be adjudicated.

### 4.4 Verdicts against the pre-registration

| clause | pre-registered expectation | outcome |
| --- | --- | --- |
| (i) | every node's budget holds, 0 read errors, ~same per-node behaviour as single-node | **CONFIRMED** — du 8.8–9.2 GB against an 80 GB budget on every node in every round, **0 read errors in 2,520 file reads** |
| (ii) | aggregate egress ≈ 3× the single-node figure, i.e. linear in k | **CONFIRMED** — 473.94 GB (**+0.0%**) and 473.48 GB (**−0.1%**) against 3 × 157.92 = 473.77 GB |
| (iii) | per-node completion **≥** the single-node time, growing if the NIC saturates | **FALSIFIED** — every one of the six node-round comparisons was *faster*, by 1.1% to 5.6% |

### 4.5 Interpretation

**Registry-side read amplification is linear in k, and the evidence is about as
clean as this rig can produce.** Two independent rounds landed within 0.1% of
3× the in-session single-node egress. Nothing about three exhausted nodes is
cheaper for the registry than three sequential ones: the bytes go over the wire
three times, exactly as the paper's placement argument assumes.

**Clause (iii) is falsified, and the reason is visible in the same data.** The
clause was conditional — "growing **if** the registry NIC saturates" — and the
NIC never got close: 28–29% of a measured 10.28 Gb/s ceiling, with the serving
filesystem's 1485 MB/s sitting above that. With no contended resource there was
no mechanism for per-node slowdown, so the prediction's premise did not hold.

What is left to explain is why k=3 was consistently *faster* than k=1. Round 1's
margin (1.1–2.9%) is inside the 1.9% spread of the baselines themselves and would
be unsafe to interpret; **round 2's (3.8–5.6%) is not**. The ordering is also
monotone — k=1, then round 1, then round 2, each faster than the last — which
points at the registry host's own page cache: 64 GB of RAM in front of a blob set
whose hot portion is repeatedly re-read, warmed further by every preceding round.
Three nodes requesting the same blobs within milliseconds of each other hit that
cache together, where one node reading alone hits NVMe.

**v9 does not prove that mechanism.** It was not instrumented — the registry's
page-cache hit rate was never sampled, and no round was run with a cold page
cache to test it. What v9 establishes is the fact (k=3 no slower, and in round 2
measurably faster) and the bound (the NIC was at 28%). A future spike wanting the
mechanism should drop the registry's caches between rounds and re-run; that is
one line of setup and about forty minutes.

**A caveat the report should not bury.** Because the NIC never saturated, this
campaign says nothing about the regime the paper's scheduling argument actually
cares about — many more than three nodes, or a registry NIC small enough to
contend. Linear egress at k=3 is consistent with linear egress at k=30, and is
not evidence for it. The honest claim is: **at k=3 on a 10 Gb/s registry,
amplification is linear and per-node service does not degrade.**

---

## 5. Pre-registration scorecard

| id | expectation | outcome |
| --- | --- | --- |
| **V9-C** | median price within [15%, 26%]; report median + min–max | **CONFIRMED** — median **+18.51%**, range +15.30% to +19.02% |
| V9-C | zero read errors at both levels | **CONFIRMED** — 0 errors, 280/280 files, 150.3 GB, in all 10 runs |
| **V9-A** | A's hot set partially evicted; p99 rises; >0 refetched bytes | **CONFIRMED on refetch and p50; the p99 rule was under-powered** (§3.4) |
| V9-A | A must not see a single read error — any EIO/ESTALE is FATAL | **CONFIRMED — 0 read errors**, 3,094 measured reads across two valid reps |
| V9-A | "0 refetches in steady state" entry condition | **NEVER SATISFIED, and not enforced** — see §3.5. My implementation checked only the p50 half |
| **V9-B (i)** | every node's budget holds, 0 errors, ~single-node behaviour | **CONFIRMED** — du 8.8–9.2 GB vs 80 GB budget, 0 errors in 2,520 reads |
| **V9-B (ii)** | aggregate egress ≈ 3× single-node, linear in k | **CONFIRMED** — +0.0% and −0.1% |
| **V9-B (iii)** | per-node completion ≥ single-node, growing if NIC saturates | **FALSIFIED** — all six comparisons faster; NIC only 28–29% utilised |

Three pre-registered expectations were wrong in some part (V9-A's p99 rule and
its steady-state premise, V9-B's clause (iii)). All three are reported as
falsifications rather than reinterpreted, per rule 0.1.

---

## 6. What this spike changes for the paper

1. **`\honestyPricePct` should not stay at 20.6%.** That figure is v5's N=1
   cross-session observation. Five interleaved within-session pairs give a median
   of **+18.51%** and never exceeded **+19.02%** — 20.6% lies outside the entire
   observed range. Quote the median with its range, or quote a range.
2. **The cross-pod interference limitation can be closed, with a caveat.** A
   second tenant's 140 GB sweep costs the resident 5.2–13.3 points of cache hit
   rate and ~18.5% of p50 read latency, **with zero read errors**. I6's second
   clause is real and now measured.
3. **A prior question outranks I6.** A single tenant with a 21.5 GB hot set
   occupies ~73 GB of an 80 GB budget and thrashes alone (§3.5). Effective
   capacity is roughly budget/3.4 for this workload shape. That belongs in the
   paper before any two-tenant claim.
4. **The multi-node limitation can be closed at k=3.** Registry egress is linear
   in k to within 0.1%, and per-node service does **not** degrade — at 28% NIC
   utilisation. The scheduling argument's premise (N exhausted nodes generate N×
   registry load) is confirmed; the claim that this *hurts* is not tested here.
5. **v8's Fast Snapshot Restore recommendation should be corrected, not
   repeated.** It is unusable without ~2 h of lead time (§0.2). The working
   technique is concurrency against the lazy restore.

---

## 7. What this spike does NOT establish

1. **Why k=3 is faster than k=1.** The registry page-cache explanation fits the
   monotone ordering but was not instrumented or tested against a cold cache.
2. **Anything about k > 3, or about a saturated registry.** The NIC never went
   above 29%.
3. **Which cache tier drives the 3.4× occupancy inflation** in §3.5, or whether
   it is stale copies or accounting.
4. **The 50% pre-fill non-monotonicity** v5 found at N=1. v9 ran 0% and 90% only.
5. **Whether V9-A's interference numbers would differ from a genuinely
   zero-refetch baseline**, since no such baseline was reachable (§3.5).

---

## 8. Cost and teardown

| item | |
| --- | --- |
| rig 1, us-east-1a, 11.82 h | 2 × on-demand $16.21 + 2 × spot (≈6.2 h) $4.51 |
| rig 2, us-east-1b, 2.75 h | 2 × on-demand $3.77 + 2 × spot $2.00 |
| Fast Snapshot Restore (1.55 h, delivered nothing) | $1.16 |
| EBS (roots + the 1200 GB restored volume, twice) | $0.40 |
| **total** | **≈ $28.06 of the $120 tripwire** |

About $9 of that was the four hours lost to the orchestration stall in §0.1b.

**Teardown verified** (`results/TEARDOWN-VERIFICATION.txt`): **0 instances,
0 volumes, 0 AMIs, 0 FSR registrations enabled, exactly 1 snapshot** —
`snap-0118cc5716e9e8a54`, the v7 artifact snapshot, which survives by design.

---

## 9. Where the evidence is

```
results/v9c/pair{1..5}-{0,90}pct/     10 trials, 15 artefacts each
results/v9a/rep{2,3}/                 2 valid repetitions + phase analyses
results/v9a/rep1-INVALID/             preserved, with WHY-INVALID.txt
results/v9b/{k1-node{1,2,3},k3-round{1,2}}-*/   9 node bundles + 5 registry bundles
results/v9b-firstrig-us-east-1a/      first-rig observations, excluded from comparison
results/TEARDOWN-VERIFICATION.txt
scripts-as-run/                       every script as actually executed
```

Each trial bundle carries the sampler CSV, both daemons' logs, the full metrics
dump, the kubelet eviction assertion, ENOSPC counts and `df` at three points.
No trial was deleted; invalid trials are labelled and kept.

---

## Verification note (Chat C, 2026-09-13)

Independent re-check against raw evidence bundles:

- **V9-C**: all 10 `full-read.txt` elapsed values match the summary table;
  per-pair prices recomputed by hand (15.30 / 18.53 / 19.02 / 18.51 /
  18.21%), median +18.51%, mean +17.91% — all confirmed. 280/280 × 10,
  0 errors confirmed.
- **V9-A**: p50 rises recomputed (+18.5% / +18.8%), hit-rate deltas
  (−5.19 / −13.26 pp) confirmed from §3.3 table; thrash tables agree
  across reps (73.0 / 73.2 GB, occupancy 0.930–0.951).
  **CORRECTION**: the read count "3,094" at §3.4 and in the verdict table
  is wrong. Raw `a-latency.csv` rows: rep2 = 2,044, rep3 = 2,056, total
  **4,100** measured reads (4,094 inside the three phase windows). The
  zero-error claim itself is confirmed (`a-latency.err` empty in both
  reps). The error is in the count, not the verdict.
- **V9-B**: linearity recomputed from NIC tx (473.94 and 473.48 vs
  473.77 GB → +0.04% / −0.06%), all six clause-(iii) comparisons
  confirmed faster-at-k=3, 9 × 280 = 2,520 reads, 0 errors, ceilings
  table consistent (measured 10.21–10.36 Gbps iperf3; 28–29% peak
  utilization at k=3).

Paper integration uses: median +18.5% (range +15.3..+19.0, N=5) as the
honesty price; 4,100 as the V9-A read count; V9-B as measured.
