# Code findings — spike v6

Defects in the **system under test**, found live. None of these were patched on
the rig: a patched binary is no longer the SHA this run claims to measure
(PRE-REGISTRATION-v6.md §5.1). They are written here in the form the next fix
round needs.

---

## C1 [P0] — `Init` opens the new accounting index before releasing the old one

**Where:** `fusemanager/service.go`, `(*Server).Init`.
**Introduced by:** the F12 fix, commit `137e9661`.
**Found by:** E1, observations 2–3, reproduced on two independent runs.

### What happens

```go
fs, err := service.NewFileSystem(ctx, fm.root, &fm.config.Config, opts...)
if err != nil {
    return &pb.Response{}, err
}
releaseFileSystem(ctx, fm.curFs)   // <-- one statement too late
fm.curFs = fs
```

`service.NewFileSystem` constructs the filesystem, which opens the cache
accounting index, which takes an exclusive flock on `cache-accounting.db`. At
that moment the **previous** filesystem's index still holds that flock, because
`releaseFileSystem` has not run yet.

Consequence chain, all five steps observed:

| step | observable |
| --- | --- |
| `openDB` waits 3 s and times out | — |
| F3 classifies it as `ErrIndexLocked`, does not rename | `.corrupt` count stays 0 |
| `newAccountant` warns, counts, returns `nil` | `stargz_cache_index_lock_lost_total` 0 → 1 |
| accountant is nil, so `cachemetrics.Register` is never called | collector keeps its previous binding |
| `releaseFileSystem` closes the previous index | index holders 1 → 0 |

Net effect: **a `systemctl restart` with a changed `[cache_accounting]` policy
silently does not apply it, and the process runs with no accounting and no
eviction at all until the next restart.** That second part is the more serious
half: a node in this state has a configured budget and enforces nothing.

It alternates. Restart 1 loses the race; restart 2 finds no incumbent index and
succeeds; restart 3 loses again. So roughly every other restart leaves the node
unbounded.

### Evidence

`results/e1/sut/VERDICT.txt`, observations 1–5. Reproduced in
`results/e1/sut-attempt2/` on a separate run. The negative control
(`results/e1/prefix/`) shows the pre-F3 form of the same race, where the index is
renamed `.corrupt` and rebuilt by scanning 304,406 files.

### Fix

Release before constructing:

```go
releaseFileSystem(ctx, fm.curFs)
fm.curFs = nil
fs, err := service.NewFileSystem(ctx, fm.root, &fm.config.Config, opts...)
if err != nil {
    return &pb.Response{}, err
}
fm.curFs = fs
```

The ordering has a cost that must be stated rather than glossed: between the
release and the successful construction there is a window with no filesystem. If
`NewFileSystem` fails, the manager is left with `curFs == nil` where today it
keeps the old one. Today's behaviour is not actually better — the old
filesystem's index has been closed by the time anything notices — but the error
path deserves a deliberate decision rather than an accident of ordering.

### Test that would have caught it, and why the existing one does not

`TestInitReleasesTheSupersededFilesystem` asserts that the superseded filesystem
**is** released, and it passes. The defect is in the *order* of two individually
correct operations, which no single-statement mutation expresses.

The test that catches it has to assert that the new filesystem's index can
actually be opened — i.e. that `Init` leaves a *working* accountant, not merely a
replaced pointer. Concretely: run `Init` twice against the same root with a
changed policy, and assert that the second `Init`'s filesystem reports the new
policy through `Stats()`. That fails today and passes after the reorder, and it
needs no FUSE mount, no systemd and no rig.

---

## C2 [P2] — the FUSE manager truncates its log on every start

**Where:** manager startup, `--log-path <root>/stargz-fuse-manager.log`.
**Found by:** E1, while collecting evidence.

The manager rewrites rather than appends, so the log covering a restart is gone
as soon as the next manager starts. Any post-hoc investigation of a restart —
exactly the scenario `KillMode=process` exists to support — finds only the
current manager's log.

Not a correctness bug and not on any experiment's critical path; recorded
because it cost this spike one re-run to capture a warn line that had already
been emitted, and because it makes field diagnosis of restart-related problems
harder than it needs to be.

---

## C3 [P2] — `stargz_fs_blob_fetch_errors_total` counts background prefetch failures, and the docs tell you to alert on it as if it meant reads are failing

**Where:** `fs/remote/blob.go:266,272` (the counter), `fs/fs.go:490` (the
background caller), `docs/overview.md` (the alert rule).
**Found by:** E2 run 1, incidentally.

### What was observed

During E2 run 1, with the resident pod reading a 14 GB hot set and the 140 GB
sweep beside it:

```
stargz_fs_blob_fetch_errors_total{errno="none"} 1
```

and, at the same time, **zero** reader-visible errors: no `errno=` line in any of
the three warm passes, none in the resident latency series, and the eviction
engine running normally (1.38 M chunks / 136.8 GB evicted, `writes_skipped=0`).

### Why both are true at once

`blob.ReadAt` increments the counter and returns the error, and one of its
callers is not a reader:

```go
// fs/fs.go:490
go l.Prefetch(defaultPrefetchSize)
```

Prefetch runs in a background goroutine at mount time. A transient failure there
is counted, and by design fails nothing — which is correct behaviour, and is
presumably what happened here: one failure in the cold-fetch window, against
roughly 300k chunk fetches, with no read affected.

### Why it matters

`docs/overview.md` lists

```
rate(stargz_fs_blob_fetch_errors_total[5m]) > 0
```

as an alert-rule shape, glossed as "reads are actually failing". On the evidence
above that gloss is wrong: the counter fires when a *background prefetch* fails,
with every read succeeding. An operator following the documented rule gets paged
for a condition that has no user-visible effect.

The counter is also the one v5 and v6 both lean on to assert "no EIO reached the
reader", so the conflation matters to our own claims as well as to operators.

### Options, in order of preference

1. **Split the label.** Add a `source` label (`read` | `prefetch`), so the
   existing series keeps its name and the alert becomes
   `rate(stargz_fs_blob_fetch_errors_total{source="read"}[5m]) > 0`. Cheap, and
   it keeps the prefetch failures visible, which are worth seeing.
2. Do not count prefetch failures at all. Simpler, but it throws away a signal:
   a node whose prefetches are failing is a node about to serve slow reads.
3. Leave the code and fix the documentation. Cheapest, and worst: the metric
   keeps a name that does not mean what it says.

Option 1 is what the eviction counters already do with `policy` — carry the
distinction in a label rather than in prose — and it is consistent with F3's
choice to make the effective policy visible rather than explained.

### Note on this spike's own claims

E2.5 and E3.1 are stated over **reader-visible** errors (the `errno=` lines the
read probes emit), not over this counter, so they are unaffected. Where this
report quotes `stargz_fs_blob_fetch_errors_total`, it says which of the two it
means.

---

## C4 [P0] — a full accounting queue does not just misreport occupancy, it defeats the budget

**Where:** `cache/accounting` — the bounded update queue and everything that
reasons from `Stats()`.
**Found by:** E2 run 1, and then by the rig falling over.
**This is the failure mode C1+C2 exist to prevent, reproduced by C1+C2.**

### Facts

E2 run 1: resident 14 GB hot set, 140 GB sweep beside it, `budget = 80 GB`,
`policy = lru`, 92 GB partition. Sampled every 10 s. `stargz_cache_bytes_used`
is what the index believes; `du -sb` over the two cache trees is what is
actually there.

| time | index (GB) | `du -sb` (GB) | drift (GB) | dropped events | writes_skipped |
| --- | --- | --- | --- | --- | --- |
| 04:32:33 | 58.5 | 59.3 | 0.8 | 0 | 0 |
| 04:34:24 | 75.8 | 78.4 | 2.6 | 22,838 | 0 |
| 04:38:14 | 75.6 | 81.2 | 5.6 | 53,859 | 0 |
| 04:42:09 | 75.7 | 83.4 | 7.7 | 76,674 | 0 |
| 04:46:04 | 75.8 | 85.7 | 9.9 | 102,368 | 0 |
| 04:48:33 | 75.6 | 88.5 | 12.8 | 127,337 | 0 |

After the run, with the sweep finished:

```
/cache-part/stargz/httpcache  files=942416  apparent=47.1GB  allocated=50.4GB
/cache-part/stargz/fscache    files=11206   apparent=47.0GB  allocated=47.0GB
df: /dev/nvme1n1p2  92G  92G  0  100%
```

And the snapshotter then refused to start:

```json
{"error":"mkdir /var/lib/containerd-stargz-grpc/snapshotter/multiple-lowerdir-check.../lower2:
 no space left on device","level":"fatal","msg":"snapshotter is not supported"}
```

### Mechanism

The drift is linear in dropped events at **~100 KB per drop**, which is one
~50 KB chunk written into *both* trees — the compressed copy in `httpcache` and
the uncompressed copy in `fscache`. Mean chunk size measured on this cache:
50,000 bytes over 200,000 sampled files.

So: the update queue fills under sustained write pressure, `Added` events are
dropped rather than waited on, the index never learns about those chunks, and
**eviction evicts to 76 GB of what it knows about while the disk holds 88.5 GB
and rising**. Occupancy reported 0.947 of budget throughout. Nothing in the
metrics said the bound had stopped holding: `writes_skipped` stayed 0, because
the writes were succeeding — there was still room, right up until there wasn't.

### Why this is worse than the documented behaviour

`docs/overview.md` says:

> Accounting never blocks the cache. Updates go to a bounded queue and are
> dropped when it is full rather than waited on. A non-zero
> `stargz_cache_index_dropped_events_total`, or an unclean shutdown, leaves the
> reported occupancy below the truth until the next rebuild.

That describes a **reporting** inaccuracy. What it actually is, once a budget is
configured, is a **containment** failure: the number eviction acts on is the
number that drifts, so the budget silently stops bounding the partition. The
node then fills up and the snapshotter dies on its next start — a hard failure,
from the component whose purpose is to prevent exactly that.

The drift does not self-correct while pressure continues. It is corrected by a
rebuild scan, which happens at startup — i.e. after the damage.

### Options

1. **Make eviction act on ground truth when the queue has dropped anything.**
   Cheapest correct version: when `dropped > 0`, treat the budget as
   `bytes * (1 - safety)` until the next rebuild, or trigger a rebuild scan once
   drops exceed a threshold. A scan of this cache took 1.3 s for 304k files and
   ~13 s for 1.5 M, which is affordable against losing the node.
2. **Do not drop `opAdd`.** Dropping a *touch* costs recency accuracy; dropping
   an *add* costs containment. They are not the same event and should not share
   a policy. Block, or grow the queue, on adds only.
3. **Reconcile against `df` periodically.** The engine already has the partition;
   comparing the index's total against `statfs` once a cycle would catch any
   drift, from any cause, including unclean shutdown.
4. Raise `queue_size`. A mitigation, not a fix: it moves the write rate at which
   the bound fails, and gives no signal when it is exceeded.

(2) and (3) together are the honest pair: adds are what the bound depends on, and
a periodic reconciliation is what makes the bound robust to anything the queue
misses. (1) is the smallest change that removes the hard failure.

### Also worth fixing: the fatal on startup

`multiple-lowerdir-check` at startup does `mkdir` and treats `ENOSPC` as
"snapshotter is not supported", which is fatal and puts the unit in a restart
loop. A full disk is a condition this component is specifically supposed to
survive; failing to start because of it turns a degraded node into a dead one,
and makes recovery need manual intervention on a node that has no space for the
operator to work with either.

### Caveat on scope

This was observed with `flush_interval_sec` and `queue_size` at their shipped
defaults (5 s, 8192) under a 140 GB sweep — a deliberately extreme write rate.
It says the bound is not robust at that rate; it does not say how common that
rate is in production. The right next measurement is the write rate at which
drops begin, which is cheap to determine offline.
