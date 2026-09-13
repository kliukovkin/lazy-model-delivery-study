# Live fixes and findings, recorded as they happened

Written during the run, not reconstructed afterwards. Environment fixes are
applied; anything that looks like a bug in our own code is recorded and NOT
patched on the rig, per the task.

---

## F1 [environment, harness] NVMe enumeration is not stable — v4's scripts would have repartitioned the root disk

**Symptom.** Both host bootstraps failed immediately:

```
[17:34:38] formatting+mounting /dev/nvme1n1 -> /data
/dev/nvme1n1 is apparently in use by the system; will not make a filesystem here!
/dev/nvme1n1p1 is mounted; will not make a filesystem here!
```

**Cause.** v4's `00-*-setup.sh` hardcode `/dev/nvme1n1` as the NVMe instance
store. On the instances this run got, enumeration is **reversed**:

```
nvme1n1   30G   Amazon Elastic Block Store      <- root, / and /boot
nvme0n1  1.7T   Amazon EC2 NVMe Instance Storage <- the instance store
```

**Why this is worth writing down rather than just fixing.** v4's node script
runs `parted -s /dev/nvme1n1 mklabel gpt` — on this layout that is *the root
disk*. It did not destroy the instance only because of an accident: the guard
`[ ! -b /dev/nvme1n1p1 ]` was false (the root's own p1 exists), so partitioning
was skipped, and `mkfs.ext4 -F` then refused a mounted device. That is luck, not
safety. The same script on a layout with a differently-numbered root partition
would have relabelled the boot disk.

**Fix.** Detect the instance store by device model
(`/sys/block/*/device/model` containing `Instance Storage`) and assert the
result is not the disk holding `/` before touching it. `env.sh` now resolves
`STARGZ_CACHE_PART` from what is actually mounted at `/cache-part` rather than
from a hardcoded name.

**Result.** `/data` = 1.6 T on `nvme0n1p1`, `/cache-part` = 92 G on `nvme0n1p2`,
identical geometry to v4, root disk untouched.

---

## F2 [OUR CODE — documentation/wiring defect, NOT patched] the accounting and eviction metrics are invisible in the configuration the design mandates

**Symptom.** With the config the design specifies — `[fuse_manager] enable =
true`, `[cache_accounting] enable = true`, budget 80 GB — the metrics endpoint
served **zero** `stargz_cache_*` and `stargz_fs_cache_*` series. Only `go_*`
metrics were present. The snapshotter journal contained one line, `Start
snapshotter with fusemanager mode`, and nothing about accounting.

**First hypothesis was wrong and is recorded because it nearly went into the
report.** The initial read was "the index never runs under fuse_manager". That
is false. The index *does* run:

```
/cache-part/stargz/cache-accounting.db                 <- exists
stargz-fuse-manager.log:
  {"msg":"cache accounting: rebuilt index by scanning the cache tree","files":0}
```

**Actual cause, confirmed at source and on the rig.** With
`[fuse_manager] enable = true`, `cmd/containerd-stargz-grpc/main.go:162-212`
does **not** build a filesystem in this process at all: it starts
`stargz-fuse-manager` as a separate process and creates an RPC client
(`fusemanager.NewManagerClient`). The filesystem is constructed inside the
manager, in `fusemanager/service.go:212` (`service.NewFileSystem`, called from
`Init`, at startup — not lazily). So `layer.NewResolver` → `newAccountant` →
`cachemetrics.Register` all execute **in the manager process**, and register into
*its* Prometheus registry.

`metrics_address` at the top level of the config is served by
`containerd-stargz-grpc`, which has none of those collectors. The manager has
its own endpoint, passed as `-metrics-address` and taken from
`[fuse_manager] metrics_address` (`main.go:180-183`), which is **empty by
default**. Evidence — the manager's argv with the key unset:

```
/usr/local/bin/stargz-fuse-manager -address ... -fusestore-path ... -log-level debug
```

**Consequence.** In the configuration this design mandates, C1 accounting and C2
eviction run correctly and are *completely unobservable*. Every dashboard,
every alert rule in `docs/overview.md`, and the whole C3.2 events agent
(which scrapes one endpoint) see nothing at all — while the cache is being
evicted normally. An operator would conclude the feature is off.

**Workaround is configuration, not code, so the run continues.** Setting

```toml
[fuse_manager]
  enable = true
  metrics_address = "0.0.0.0:9111"
```

and replacing the manager process (the flag is argv, and the manager survives a
snapshotter restart under `KillMode=process`) exposes everything:

```
manager argv now ends: -metrics-address 0.0.0.0:9111
:9110  stargz_ series = 0
:9111  stargz_ series = 38
:9111  stargz_fs_cache_budget_bytes 8e+10
:9111  stargz_fs_cache_occupancy_ratio 0
```

`lib.sh:sg_metrics` now scrapes **both** endpoints and concatenates.

**What our code should do about it (NOT done on the rig).** This is a real
defect in C1/C2 as shipped, at three levels:
1. `docs/overview.md` documents only `metrics_address` and never says the
   accounting metrics move when `fuse_manager` is on. That is the minimum fix.
2. `cmd/stargz-cache-events/README.md` tells the operator to point the agent at
   `http://127.0.0.1:1338/metrics` — a single endpoint that, in this
   configuration, is the wrong one.
3. Arguably the snapshotter should default the manager's metrics address, or
   proxy the manager's registry, rather than silently exporting nothing.

Filed as a finding for the C2 branch; no code was changed on the rig.

---

## F3 [OUR CODE — observed, under investigation in V3] the index is discarded on restart when the previous process still holds the bolt lock

**Symptom.** After restarting the snapshotter, the journal shows:

```
{"error":"timeout","level":"warning",
 "msg":"cache accounting: cannot use index at \"/var/lib/containerd-stargz-grpc/stargz/cache-accounting.db\", recreating it"}
{"msg":"cache accounting: rebuilt index by scanning the cache tree","files":0}
```

and `/cache-part/stargz/cache-accounting.db.corrupt` appears on disk.

**Reading.** `openDB` (`cache/accounting/store.go`) opens bolt with
`Timeout: 3 * time.Second`. bolt takes an exclusive flock. When a restart
overlaps with the previous process still holding it, the open times out, and the
error path treats *any* open failure as corruption: it renames the database to
`.corrupt` and rebuilds by scanning the tree.

**Why it matters beyond tidiness.** A rebuild scan resets `addedAt` to the scan
time and leaves `firstHitAt` zero for every chunk, which is exactly the state in
which the 2Q policy degrades to LRU (C2-REPORT §6.2/§7.1). So a restart that
merely overlapped a lock can silently downgrade the eviction policy. It also
means the `.corrupt` files accumulate on the very partition the feature exists
to protect.

Not patched. V3 measures how often this fires across 8 restarts.

---

## F4 [environment, harness] hardcoded `~/v4/` path and a stale predictor tag

`02-build-artifacts.sh` copied the predictor sources from
`/home/ubuntu/v4/custom-predictor/`, a path that only existed on the v4 rig, and
tagged the image `custom-predictor:v4` while `env.sh` referenced `:v5`. Fixed to
use the script's own directory and a consistent tag.

---

## F5 [harness] absent Prometheus counters are not zero

A Prometheus `CounterVec` exports **nothing** until a label combination is first
used, so `stargz_fs_cache_writes_skipped_total` and
`stargz_fs_blob_fetch_errors_total` are simply missing from a healthy node's
scrape rather than present at 0. The first sampler rows had blank columns.
`metric_sum`/`metric_one` now return 0 for an absent series. This is a real
property of the metric, not a harness bug, and it matters for the alert rules
`docs/overview.md` suggests: `rate(stargz_fs_cache_writes_skipped_total[5m]) > 0`
never fires on a node that has never skipped a write, which is the intended
behaviour, but `absent()` handling is the operator's problem.

---

## F6 [environment, harness] the 14 GB image was silently not built

`02-build-artifacts.sh` does not source `env.sh`; it redefines `SIZES_GB`,
`MODEL_IMG_PREFIX`, `REG_PORT` and `WORK` locally, with
`SIZES_GB="${SIZES_GB:-140}"` and the comment "14g dropped: no v4 experiment
references it". v5's `env.sh` sets `SIZES_GB="140 14"`, but that never reaches
the build script, so only the 140 GB image was produced and the omission was
silent — the build reported success.

V5 needs a second, independent image for the resident hot set: sharing one image
between the resident pod and the sweep would put both workloads in the same
cache directory, and "which layer is over its share" is exactly what the 2q and
proportional policies reason about. Rebuilt with `SIZES_GB=14` passed
explicitly, concurrently with the 140 GB eStargz conversion.

---

## F7 [deviation from pre-registration, deliberate] V2 run at N=1, not N=2

PRE-REGISTRATION-v5.md §2 specifies N=2 per pre-fill level. V1's full 280-file
read took 1089 s, and every V2 trial contains one, so N=2 across three levels
plus the vanilla control is ~2.3 h of the ~5 h remaining before the watchdog —
which would have left no time for V3 [P0], V4 or V5.

Run at **N=1**, levels ordered `90 50 0` so that the most informative level (and
the load-bearing vanilla control) completes first. v4 made the same call for its
S2 (N=1) and recorded it under "Honest gaps"; this is recorded the same way
rather than being presented as the pre-registered design.

Consequence: no within-level variance estimate at any pre-fill level. The
corruption result is binary (0 or not 0), so N=1 still answers the primary
question; the completion-time comparison is a single sample per level and should
be read as indicative only.

---

## F8 [FINDING + environment fix] kubelet evicts the pod before the cache volume can fill

**Symptom.** Every V2 trial at 90% and 50% pre-fill produced no read at all.
`kubectl exec` returned `exit code 137` on our arm and
`cannot exec into a container in a completed pod; current phase is Failed` on
the vanilla arm. Sweep times were 0.05-41 s against V1's 1089 s.

**Cause, from the pod events:**

```
Warning  Evicted  kubelet  The node was low on resource: ephemeral-storage.
                           Threshold quantity: 9782837803, available: 1488568Ki
```

9,782,837,803 bytes is exactly **10% of the 97.8 GB cache partition** — kind's
`evictionHard: nodefs.available: 10%`, the production-like threshold v4 run 2
deliberately introduced (v4 §9 gotcha 7). Pre-filling the partition to 90% puts
free space below that threshold, so kubelet evicts the pod before it can read a
single file. The trials measured kubelet, not the cache.

**This is a real result, not only a harness problem, and it sharpens v4 §14.**
v4 found kubelet "sighted but powerless": `imageFs usedBytes` stayed pinned near
152 MB while the partition filled, so image GC "freed 0 bytes" and could never
reclaim the stargz cache. What v5 adds is the other half: kubelet cannot
*reclaim* the cache, but `nodefs.available` measures free space directly, so it
can and does **evict the tenants**. On a node where the snapshotter cache shares
a filesystem with kubelet's nodefs — the common deployment — a full stargz cache
does not corrupt reads first; it gets the pods killed first. That is arguably
the node protecting itself, and it changes what the pressure matrix is even
able to observe.

**Fix, to isolate the question V2 actually asks.** V2 exists to test whether a
full cache volume corrupts reads. With kubelet killing the pod first, that
question cannot be reached. For the V2 re-run, `evictionHard` is set to
`nodefs.available: 0%` / `imagefs.available: 0%` — which is exactly kind's
default and what v4 **run 1** used — and the original file is preserved at
`/var/lib/kubelet/config.yaml.prod-thresholds`. Verified live through the
kubelet's own `configz` endpoint, not just the file.

The four invalid trials are preserved as `results/v2/*-INVALID/` with their pod
events, per the v4 convention of never deleting a bad run.

**For the report:** the before/after pressure matrix below is therefore measured
with kubelet eviction disabled, and that qualifier is load-bearing. It must not
be quoted as "under production thresholds" — under production thresholds the
pod is evicted at 90% pre-fill and no read happens at all.

---

## F9 [harness gap, not fixed in-run] V4's healthz/predict columns are empty

`34-v4-lyingpod-probe.sh` probes the pod's own HTTP endpoints with `curl` from
inside the container. The predictor image has python3 (the read probe and the
sentinel probe both rely on it) but not curl, so the `healthz` and `predict`
columns of `probe-rounds.csv` are blank in both arms.

Consequence: v5 does not independently reproduce v4 §5's "pod answers /healthz
200 and /predict 200 with byte-identical output while 262/280 files are
unreadable". V4's *primary* comparison is unaffected — `sentinel_exit` versus
the kubelet's own `Ready` condition are both captured — but the HTTP half of
the lying-pod demonstration is inherited from v4 rather than re-measured here.

Not fixed mid-run: V4 was already executing and the remaining rig time was
committed to V5, which had no other opportunity to run. The fix is one line
(use `python3 -c urllib.request` instead of curl) and is noted for v6.

---

## F10 [OUR CODE — pre-registered falsification] the sentinel probe is a false negative on the exact failure it was built for

**Fact.** V4, vanilla v0.18.2, 90% pre-fill, same pod, same moment:

```
full read of all 280 files : attempted=280 ok=8 err=272   ERRNOS EIO=272
contrib/sentinel-probe      : exit 0  (green), three rounds in a row
                              "ok: ballast-99.bin tail 1048576 bytes"
                              "ok: ballast-98.bin tail 1048576 bytes"
                              "ok: ballast-97.bin tail 1048576 bytes"
kubelet Ready condition     : True
```

97% of the model was unreadable and the probe said the pod was healthy. This is
the falsifier written into PRE-REGISTRATION-v5.md §4 before the rig existed:
"the probe returns 0 on the vanilla arm while files are corrupt -> **false
negative, the probe is worthless** and must not be recommended".

**It must not be recommended in its current form.** That is a result about our
own C3.3 deliverable, not about the snapshotter.

**Two candidate mechanisms, and the evidence does not yet separate them.**

1. *Sample size.* The probe reads the last 1 MiB of K=3 files — 3 MiB out of
   150 GB, about 0.002% of the model. With 272/280 files broken, drawing three
   readable ones by chance is very unlikely ((8/280)^3 is about 2e-5), so pure
   bad luck is not a sufficient explanation on its own.
2. *The probe warms its own sentinels.* It picks the same K files every period
   and remembers them in `SENTINEL_LIST` precisely so it does not re-walk the
   mount. Reading them caches their tails. From the second round onward it is
   therefore reading files it has itself kept warm — a self-fulfilling health
   check. The `before` round ran before the read storm and would have cached
   exactly those three tails.

Mechanism 2 is the more plausible given mechanism 1's arithmetic, but this run
did not instrument it (no per-file cache state was captured alongside the probe).
Separating them needs a v6 experiment: rotate the sentinel set every period, or
probe files chosen by the *reader* rather than remembered by the probe.

**What this does NOT overturn.** The v4 tail-bias measurement (280/280 clean at
head, 262/280 broken at tail) motivated reading the tail rather than the head,
and nothing here contradicts that. What v5 shows is that *reading the tail is
not sufficient* — the probe also has to sample enough files, and it must not be
allowed to keep its own sample warm.

**Not patched on the rig**, per the task. The probe's README and
RUN-REPORT-v5 must both carry this result; the README currently claims
"on a snapshotter without pass-through, a pressure test should turn this probe
red", and on this rig it did not.

---

## F12 [OUR CODE — significant] cache_accounting config changes are silently ignored on `systemctl restart` when fuse_manager is on

**Discovered by V5 failing twice.** V5's second attempt configured
`policy = "2q"`, restarted stargz-snapshotter, confirmed the unit healthy and
the config file correct — and the arm ran LRU. Its own metrics say so:

```
arm=2q   stargz_fs_cache_evictions_total{cache_type="httpcache",policy="lru"} 2.50554e+06
         policy_configured=2q      policy_metric_label=lru
```

**Cause, and it is the same root as F2.** With `[fuse_manager] enable = true`
the filesystem, the C1 index and the C2 eviction engine live in the
`stargz-fuse-manager` process (`fusemanager/service.go:212`). The config is
handed to that process when it is *started*. `systemctl restart
stargz-snapshotter` replaces `containerd-stargz-grpc` only — and, because of
**our own `KillMode=process` drop-in for upstream issue #2387**, deliberately
does not touch the manager. The manager therefore keeps serving with the config
it was born with.

**The operator-visible failure.** Edit `policy`, `bytes`, or any
`[cache_accounting]` key; `systemctl restart stargz-snapshotter`; the unit comes
back active; `systemctl status` is green; the config file on disk says what you
wrote. The running behaviour is unchanged, with no warning anywhere. The only
signal is the `policy` label on the eviction counters — which, per F2, is not
even exported unless `[fuse_manager] metrics_address` is set. Both failures
compound: the setting is silently ignored *and* the evidence that it was ignored
is silently absent.

**This is a consequence of our own fix.** #2387 exists to keep the manager alive
across a snapshotter restart so running pods keep their mounts. That is right.
But it converts "restart the service to apply config" — the universal operator
gesture, and the one the C2 docs implicitly assume — into a no-op for everything
the manager owns. Nothing in `docs/overview.md` says so.

**What the code should do (NOT done on the rig).** At minimum, the manager
should be told the new config on re-Init, or the snapshotter should refuse to
start with a config that differs from the running manager's and say so. At
minimum-minimum, document it. This is a bigger finding than F2 and should gate
any recommendation to operate C2 with `fuse_manager` enabled.

**Consequence for V5.** Attempt 2 did not compare two policies; both arms ran
lru. Preserved as `results/v5-attempt2-INVALID/`. The lru arm of that attempt
also recorded 0 evictions with 24,244 skipped writes, which is not consistent
with an 80 GB budget being in force on a 92 GB partition, so that arm's state
was not what was intended either. Neither arm is reportable.

---

## F13 [V6 result] the derived trace substitute is not good enough either, and the numbers say why

PRE-REGISTRATION-v5.md §0b recorded before the run that V6 could not be done as
specified — the index does not emit a trace at `f6547d99` — and pre-registered a
substitute: diff periodic read-only index snapshots. That substitute was built
(`idxdump` + `97-derive-trace.py`) and run against V1's sweep. The result:

```
1,197,434 events  (1,196,819 add, 615 get)  from 16 snapshots
1,097,392 keys vanished between snapshots
```

Three things are wrong with it, and they are quantitative, not aesthetic:

1. **615 `get` events out of 1.2 M.** A sweep reads each chunk once, and the
   index's one-minute last-access bucket hides re-reads inside a bucket, so
   almost no reuse survives into the trace. A policy simulator fed this would be
   comparing policies on a workload with no reuse — which is not the workload.
2. **1,097,392 keys vanished between consecutive snapshots** — 92% of the adds.
   With eviction running at ~2.27 M chunks over the sweep and snapshots every
   30 s, most chunks are admitted and evicted inside one interval and are never
   observed at all. Shortening the interval fights the cost of dumping a 1.5 M
   row bolt bucket.
3. It is 131 MB of trace for one 18-minute experiment, most of it adds.

**Conclusion.** The substitute is preserved (`results/v1/v6-derived.trace`,
labelled DERIVED-NOT-CAPTURED in its own header) and should be treated as a
demonstration that the approach does not work, not as data. RQ1 needs real trace
emission from the index — an optional writer on the update path — which is
exactly what C2-REPORT §8.1 already lists as the first thing this spike should
motivate. v5 now has the numbers to justify building it.
