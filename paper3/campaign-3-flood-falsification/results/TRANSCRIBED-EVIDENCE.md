# Transcribed evidence

The rig self-terminated on its 11-hour watchdog at ~13:36Z, during an idle gap,
**before `90-collect.sh` had been run**. The instance store and both EBS roots
went with it (`DeleteOnTermination=true`).

The results below were read off the rig and quoted verbatim while it was alive,
but their bundle files did not survive. They are reproduced here so the report
has a source, and they are **explicitly marked as transcribed rather than
file-backed**. Nothing here is reconstructed from memory or inference — each
block is the literal output of a command run on the node.

What *is* file-backed is listed in `EVIDENCE-INVENTORY.md`.

---

## E1 — negative control (`f6547d99`), VERDICT.txt

```
=== FACTS ===
tag	config_policy	fm_pid	grpc_pid	n9110_cache_series	policy_labels_9110	budget_9110	lock_lost_9110	db_holders	db_corrupt	n9111_cache_series	policy_labels_9111
1-baseline-lru	lru	20439	20415	0		0	0	1	0	38	lru
2-after-restart-to-2q	2q	20439	21581	0		0	0	1	1	38	lru
3-after-read-under-2q	2q	20439	21581	0		0	0	1	1	38	lru
4-after-restart-to-lru	lru	20439	23391	0		0	0	1	1	38	lru
5-after-read-under-lru	lru	20439	23391	0		0	0	1	1	38	lru

=== SCORING (ids from PRE-REGISTRATION-v6.md) ===
N1.1   PASS      cache series on :9110 = [0, 0, 0, 0, 0] ; on :9111 = [38, 38, 38, 38, 38]
N1.2   PASS      policy labels on :9111 after the lru->2q restart = ['lru', 'lru'] (expected to be stuck at lru)
N1.3   PASS      max corrupt=1, max db holders=1

fuse-manager pids across observations = ['20439']

E1[prefix] RESULT: 3/3 expectations met
```

## E3 — pressure at 90%, N=2, both arms (`e3-summary.csv` rendered)

```
arm      prefill_pct  rep  ready_s  sweep_s   attempted  ok   err  bytes         writes_skipped  evictions  enospc_journal  enospc_fm  pod_phase
ours     90           1    1.846    1235.379  280        280  0    150323855360  6499            2981840    10              17         Running
ours     90           2    1.843    1240.853  280        280  0    150323855360  7969            2981841    10              6          Running
vanilla  90           1    1.301    30.128    280        7    273  4227858432    0               0          10              71         Running
vanilla  90           2    2.932    25.796    280        7    273  4194304000    0               0          10              6          Running
```

Per-trial read probe output:

```
ours-90pct-rep1:    READ range=[0:280] attempted=280 ok=280 err=0   bytes=150323855360 elapsed_s=1235.260 | ERRNOS none
ours-90pct-rep2:    READ range=[0:280] attempted=280 ok=280 err=0   bytes=150323855360 elapsed_s=1240.767 | ERRNOS none
vanilla-90pct-rep1: READ range=[0:280] attempted=280 ok=7   err=273 bytes=4227858432   elapsed_s=30.035   | ERRNOS EIO=273
vanilla-90pct-rep2: READ range=[0:280] attempted=280 ok=7   err=273 bytes=4194304000   elapsed_s=25.705   | ERRNOS EIO=273
```

## E4 — sampled-trace probe, `E4-RESULT.txt`

```
=== E4 FACTS ===
snapshots=18 interval_span_s=91
adds=312662 gets=12005 total=324667
carried_over_between_snapshots=3135727
vanished_between_snapshots=1181
vanish_rate=0.0038   (E4.1 wants < 0.10)
get_share=0.0370     (E4.2 wants > 0.05)

=== E4 SCORING ===
E4.1 PASS  0.4% of admissions vanished between consecutive 5s dumps (v5 at 30s/sweep scale: 92%)
E4.2 FAIL  gets are 3.7% of events (v5 at sweep scale: 0.05%)

E4.3 trace written -> ../results/e4/derived.trace (324667 events)
```

## E2 run 1 (first attempt) — the C4 evidence, `sampler.csv` extract

```
ts        metric  du_tot  drift   dropped  pinned rebuilding
04:32:33    58.5    59.3     0.8         0      1 0
04:34:24    75.8    78.4     2.6     22838      0 0
04:36:18    75.8    78.2     2.5     22838      0 0
04:38:14    75.6    81.2     5.6     53859      1 0
04:40:11    75.8    81.1     5.3     53859      0 0
04:42:09    75.7    83.4     7.7     76674      1 0
04:44:06    75.7    83.6     7.9     76674      1 0
04:46:04    75.8    85.7     9.9    102368      0 0
04:48:33    75.6    88.5    12.8    127337      1 0
```

Post-run filesystem state:

```
/cache-part/stargz/httpcache  files=942416  apparent=47.1GB  allocated=50.4GB  overhead=3.2GB (6.9%)
/cache-part/stargz/fscache    files=11206   apparent=47.0GB  allocated=47.0GB  overhead=0.0GB (0.0%)
mean chunk size: n=200000 mean=50000 bytes ; ext4 block size 4096
df: /dev/nvme1n1p2  92G  92G  0  100% /cache-part
```

And the fatal that followed:

```json
{"error":"mkdir /var/lib/containerd-stargz-grpc/snapshotter/multiple-lowerdir-check3824518876/lower2:
 no space left on device","level":"fatal","msg":"snapshotter is not supported",
 "time":"2026-09-11T04:49:43.796449278Z"}
```

## C1 — the manager's own log, caught in the act

```json
{"error":"the accounting index is held by another process: \"/var/lib/containerd-stargz-grpc/stargz/cache-accounting.db\"",
 "level":"warning","msg":"cache accounting: another process holds the index; this process will not account for or evict cached chunks",
 "time":"2026-09-11T04:56:39.381844299Z"}
{"level":"debug","msg":"cache accounting: closing the superseded index","time":"2026-09-11T04:56:39.381912050Z"}
```

## Environment, as recorded during the run

```
node     i-0646a633e5b8d4254  172.31.58.99   (i4i.2xlarge)
registry i-0b67a16180b574408  172.31.54.210  (i4i.2xlarge)
base AMI ami-025d99823a4caad37 (Ubuntu 24.04 amd64)
launched 2026-09-11T02:36:44Z ; watchdog shutdown -h +660 -> ~13:36Z
kind node image kindest/node:v1.36.1 ; k8s server v1.36.1
docker 29.8.0 ; ext4 block size 4096
cache partition /dev/nvme1n1p2 -> /cache-part, 92 GB (resolved by device model)
kubelet evictionHard {"imagefs.available":"0%","nodefs.available":"0%","nodefs.inodesFree":"0%"},
        imageGCHighThresholdPercent 100   (read from the running kubelet's configz)
SUT              /data/stargz-bin-ours    sha=9829d7cf43fc645a28d2a79e86fe614d62764833
negative control /data/stargz-bin-prefix  sha=f6547d991f0587429af5f9e42a3d80acc0f26f09
vanilla control  /data/stargz-bin         v0.18.2 release tarball
fuse-manager md5: ours cb5cb4d0fdeb1198fbf04e2271486db7 ; prefix 86587d6fe34dbfa6e712dc6513342ee2
140GB image: model-ballast:estargz-140g, 150323855360 bytes read per full sweep
```
