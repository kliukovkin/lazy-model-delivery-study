# E0 — the artifact snapshot: what it saved, and what it cost

The first reuse of `snap-0118cc5716e9e8a54`, and therefore the first real test of
v7's snapshot discipline. The answer is mixed, and the negative half is the more
useful one.

## What worked, exactly as intended

| | |
| --- | --- |
| volume restored from snapshot | `vol-017c001b8c55b4042`, 1200 GiB, `SnapshotId=snap-0118cc5716e9e8a54` |
| filesystem | detected and **not** reformatted; 463 GB of data present |
| registry | started against the restored blob store |
| **all four tags resolved** | `estargz-140g`, `estargz-14g`, `B-140g`, `B-14g` — 200 each |
| launch → registry serving images | **~6 minutes** |

Against ~1 h 40 m of image rebuilding in v5, v6 and v7. On that comparison alone
the snapshot is a clear win, and E0.1/E0.2 pass.

## What it cost, and this was not anticipated

A volume created from a snapshot loads its blocks **lazily from S3** on first
touch, and until they are loaded, throughput is dire. Measured on this rig:

| method | throughput |
| --- | --- |
| `xargs -P 4 cat` over the blob store | 15 MB/s |
| `xargs -P 48 cat` | 48 MB/s |
| `fio --iodepth=32 --numjobs=4` over the blob files | 15 MB/s |
| `fio --iodepth=64` on raw device offset 0 | 177 MB/s *(misleading — those blocks were already touched by the mount)* |
| **full image pull through the node** (the snapshotter's own concurrent ranged fetches) | **14 MB/s** |
| the same blob **after** warming | **1.6 GB/s** |

Local concurrency does not rescue it, and the reason is structural:
`estargz-140g` is **11 blobs**, so there is almost nothing to parallelise across.
Nor did the snapshotter's own concurrency help — the full 150 GB pull ran at the
same 14 MB/s and took **2 h 57 m** (10,591 s, 280/280 files, 0 errors).

## The honest accounting

```
v5 / v6 / v7:  build the image          ≈ 1 h 40 m
v8:            restore + warm           ≈ 0 h 06 m + 2 h 57 m  =  3 h 03 m
```

**As implemented, the snapshot is slower than rebuilding.** That is the opposite
of what v7's §9 claimed for it, and it is recorded here rather than buried,
because v7's operational lesson was adopted on the strength of an argument that
had never been tested.

## What would actually make it pay

1. **Fast Snapshot Restore.** Enabling FSR on the snapshot for the target AZ
   gives a restored volume full performance immediately. It must be enabled
   ahead of time, takes time to initialise, and costs about $0.75 per hour per
   snapshot-AZ while enabled. For a rig that runs for a day, that is a few
   dollars against three hours of instance time for two hosts — comfortably
   worth it, and it is the change v9 should make.
2. **Warm only what will be read.** v8 narrowed the warm set from the 309 GB blob
   store to the 11 blobs of `estargz-140g` (~150 GB). Half the work, same result.
3. **Do not size the snapshot from the build peak.** The 1200 GiB volume exists
   because the *build* needed that much headroom (live fix G8 in v7); a snapshot
   taken from a volume sized for the artifacts alone would restore less.

## For the record

The pre-warm is a one-off per rig, not per experiment, and the volume reached
1.6 GB/s afterwards — so the experiments that follow measure the snapshotter
rather than S3, which was the point of doing it at all.
