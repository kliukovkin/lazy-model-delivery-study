# v4 spike — FuseManager & upstream-fix verification — RUN REPORT

Private research artifact. Follow-up to the v3.1 capture run, driven by the red-team
review of the article-#3 plan. Numbers here are private — do not post, quote, or
reference externally.

**Scope.** Three measured questions plus a source audit:
- **S1 [P0]** — does v0.18.2's opt-in FUSE manager cure the permanent-ESTALE that
  v3.1 §5 recovery-5 recorded (daemon restarted under a live pod → `Stale file
  handle`, exit 1, while `kubectl get pod` still said `1/1 Running`)?
- **S2 [P0]** — does enabling it change anything about the ENOSPC failure?
- **S3 [P1]** — on current `main`: any new byte-budget knob; does S1 reproduce; does
  the lying-pod class still reproduce.
- **Source audit** — what PR #2076 and PR #1893 actually do.

**Rig.** Two AWS EC2 `i4i.2xlarge` (us-east-1), tags `v4-registry` / `v4-node`, IAM
`REDACTED-IAM-ARN`. Local NVMe on the node-host partitioned
exactly as v3.1: `nvme1n1p1` → 1.6TB `/data` (containerd + docker roots, relocated
proactively before any image activity) and `nvme1n1p2` → **92GB** `/cache-part`, a
real block device (not a loopback file), bind-mounted into the kind node at
`/var/lib/containerd-stargz-grpc`. kind `ocibench`, containerd **2.3.1**,
stargz-snapshotter **v0.18.2** for S1/S2 and **main @624678b4** for S3.

## Deviations from the v3.1 harness, and why

1. **No KServe.** S1–S3 exercise only containerd → proxy-plugin snapshotter →
   ImageVolume. v4 uses the raw Pod + native `image:` volume that v3.1's own P0.1
   "money artifact" used — the identical delivery path, plus a datapath-coupled
   predictor giving health/predict/sha256 signals the sklearn isvc never produced.
   This also removes the KServe install race documented in v3.1 §10.
2. **The snapshotter runs under systemd inside the kind node**, using upstream's
   `script/config/etc/systemd/system/stargz-snapshotter.service` verbatim and
   upstream's default socket/root paths. So S1's `systemctl restart
   stargz-snapshotter` is the literal operator gesture, not v3.1's `pkill` stand-in.
3. **`[proxy_plugins.stargz.exports] root = "/var/lib/containerd-stargz-grpc/"` is
   set** — i.e. PR #1893 applied as upstream documents it. v3.1 did not have this,
   so S2 can measure what that visibility actually buys kubelet.
4. **Only the 140g image is built.** v3.1's A/D variants, the 2g/14g sizes and the
   MinIO/S3 arm are dropped — no v4 experiment references them.
5. **journald rate limiting disabled inside the node** (`RateLimitBurst=0`). Under an
   ENOSPC storm the snapshotter emits errors faster than journald's default burst
   allows, and the dropped lines would have silently truncated the evidence.

## Contents
- §1 Setup, identity bundle, calibration
- §2 S1 [P0] — daemon restart under a live pod, FUSE manager on/off  ← headline
- §3 S1 — cache duplication and cache amplification
- §4 S2 [P0] — ENOSPC under pressure with the FUSE manager enabled
- §5 S2b — the lying pod, sharpened
- §6 S3 [P1] — current main
- §7 Source audit (no rig needed)
- §8 Erratum: which signal path produced v3.1's published permanent-ESTALE
- §9 Live fixes, harness bugs, and one invalidated attempt
- §10 Honest gaps
- §11 Exact versions, SHAs, digests
- §12 Cost

---

## §1 Setup, identity bundle, calibration

Full identity bundle in `results/identity-bundle/` (stargz config.toml, the systemd unit
and its effective `KillMode`, containerd config raw + dump, kubelet configz, image
manifests/digests, disk layout, tool versions), captured three times: `-v0182`, `-main`,
`-final`.

Confirmed at rest before any experiment:
- `[fuse_manager] enable = true` accepted, and the journal carries
  `Start snapshotter with fusemanager mode` — the feature genuinely engaged, with both
  `containerd-stargz-grpc.sock` and `fuse-manager.sock` present.
- `[proxy_plugins.stargz.exports] root = "/var/lib/containerd-stargz-grpc/"` wired in.
- `/cache-part` = 92G real partition (`/dev/nvme1n1p2`), bind-mounted to the snapshotter root.

**Calibration (drift control, start vs end)** — `results/calibration/`:

| metric | start | end |
|---|---|---|
| node `/data` fio seq write | 1103 MiB/s | 1111 MiB/s |
| node `/data` fio seq read | 1412 MiB/s | 1410 MiB/s |
| `/cache-part` fio seq write | 1061 MiB/s | 1116 MiB/s |
| iperf3 single-stream | 9.53 Gbit/s | 9.53 Gbit/s |
| iperf3 `-P8` aggregate | 11.9 Gbit/s | 11.9 Gbit/s |

No meaningful drift on any axis across the run.

**Smoke test** (`results/smoke/`): the 140GB eStargz pod reached Ready in **4.009 s**, with
280 ballast files visible and a real 64 MiB read served through the FUSE mount.

---

## §2 S1 [P0] — daemon restart under a live pod  (headline result)

Protocol per trial: clean cache → deploy the 140GB-class eStargz pod → wait Ready → warm-read
8 files (4.295 GB) through the mount → snapshot state → perform the restart action → re-read
the same 8 warm files **and** 4 files never touched before → snapshot again. Evidence bundle
per trial in `results/s1/<trial>/`; machine-readable summary `results/s1/s1-summary.csv`.

| trial | fuse_manager | KillMode | action | fm PID pre→post | post warm read | post fresh read | pod Ready / restarts | verdict |
|---|---|---|---|---|---|---|---|---|
| T0-control-nofm | false | default | systemctl | n/a → **none** | 0/8 ok, 8 err (ESTALE=8) | 0/4 ok, 4 err (ENOTCONN=4) | true / 0 | **MOUNT_BROKEN** |
| T1-shipped-unit-rep1 | true | default | systemctl | 11120 → 11551 | 0/8 ok, 8 err (ESTALE=8) | 0/4 ok, 4 err (ENOTCONN=4) | true / 0 | **MOUNT_BROKEN** |
| T2-shipped-unit-rep2 | true | default | systemctl | 12014 → 12432 | 0/8 ok, 8 err (ESTALE=8) | 0/4 ok, 4 err (ENOTCONN=4) | true / 0 | **MOUNT_BROKEN** |
| T3-killmode-process-rep1 | true | process | systemctl | 12949 → 12949 | 8/8 ok, 0 err (none) | 4/4 ok, 0 err (none) | true / 0 | **MOUNT_SURVIVED** |
| T4-killmode-process-rep2 | true | process | systemctl | 13789 → 13789 | 8/8 ok, 0 err (none) | 4/4 ok, 0 err (none) | true / 0 | **MOUNT_SURVIVED** |
| T5-kill9-grpc-only | true | process | kill9-grpc | 14584 → 14584 | 8/8 ok, 0 err (none) | 4/4 ok, 0 err (none) | true / 0 | **MOUNT_SURVIVED** |
| T6-kill9-both | true | process | kill9-both | 15441 → **none** | 0/8 ok, 8 err (ESTALE=8) | 0/4 ok, 4 err (ENOTCONN=4) | true / 0 | **MOUNT_BROKEN** |


**Facts.**
1. Every trial that broke, broke identically: already-touched files return **ESTALE (116)**,
   never-touched files and `stat()`/`listdir()` on the mount directory itself return
   **ENOTCONN (107)**.
2. In **all seven trials**, including every broken one, `kubectl` reported the pod
   `Ready=true` with `restarts=0` for the entire window.
3. The FUSE manager's PID **changed** in exactly the trials that broke under `systemctl`
   (T1, T2) and was **preserved** in exactly the trials that survived (T3, T4, T5).
4. T6 is the only trial where the FUSE manager never came back at all (`fm_pid_post` empty).

**Interpretation.** The opt-in FUSE manager *does* cure the permanent-ESTALE — but only when
systemd is configured not to kill it. Upstream ships
`script/config/etc/systemd/system/stargz-snapshotter.service` with **no `KillMode`**, so
systemd's default `KillMode=control-group` SIGTERMs every process in the unit cgroup. The
manager is detached with `SysProcAttr{Setpgid:true}` only (`fusemanager/fusemanager.go:117-121`),
which escapes the process *group* but not the *cgroup*, and it treats SIGTERM exactly like
SIGINT — `fm.Close(ctx)`, unmounting everything (`fusemanager/fusemanager.go:207-219`). So the
protection deliberately built into `cmd/containerd-stargz-grpc/main.go:278`
(`if cleanup || !fuseManagerConfig.Enable { rs.Close() }`) is silently void under upstream's
own unit file. A one-line `KillMode=process` drop-in restores it (T3/T4).

This was **predicted from source before the rig was built** and pre-registered in
`source-audit/S1-preregistered-predictions.md`; all seven predictions held. The mechanism was
also confirmed independently, with no image involved, in
`results/preflight/preflight-killmode.txt` (manager PID 2057→2594 under the shipped unit,
2594→2594 with the drop-in).

**T5 vs T6 — the two "unexpected restart" paths differ sharply.** `kill -9` of the snapshotter
alone (T5) is survivable: the manager never receives a signal, keeps serving, and the mount is
untouched. `kill -9` of *both* (T6, the node-crash analogue) is not, and is the one case where
the manager did not return — consistent with `StartFuseManager`
(`fusemanager/fusemanager.go:225-231`) returning `newlyStarted=false` whenever a stale
`fuse-manager.sock` exists, which then sets `snbase.NoRestore` in `main.go:194-199`: the
snapshotter declines to restore mounts *because it believes a live manager already holds them*.
SIGKILL cannot unlink that socket. Raw journal: `results/s1/T6-kill9-both/journal-stargz-snapshotter.txt`.

**Answer for the SPE reviewer.** "v0.18.2 already has a FUSE manager that preserves mounts
across restarts" is true only with a caveat that upstream's own packaging does not satisfy:
with the shipped systemd unit, enabling `fuse_manager` changes **nothing** about the
permanent-ESTALE failure (T1/T2 are indistinguishable from the T0 control), and the pod keeps
reporting Ready throughout either way.

---

## §3 S1 — cache duplication and cache amplification

Both measured from the same bundles. `du -sb` on `httpcache`+`fscache` only (real files);
`<root>/snapshotter` is excluded because it walks *into* the FUSE mounts and returns apparent
TOC sizes — 150 GB of "usage" on a 92 GB partition (see the caveat appended to
`source-audit/S1-preregistered-predictions.md`).

**Amplification.** Reading 4.295 GB (8 × 512 MiB) through the mount leaves **8.59–9.17 GB** of
on-disk cache across the seven trials — **2.00×–2.13×**. httpcache (compressed chunks) and
fscache (decompressed content) each retain roughly a full copy of what was read.

**Duplication across the restart.** The middle column is measured *after* the restart and
*before* any post-restart read, so it is growth caused by the restart alone:

| trial | after warm read | immediately after restart | after re-read | net change from restart |
|---|---|---|---|---|
| T0-control-nofm | 9.17 GB | 4.90 GB | 5.52 GB | -4.27 GB |
| T1-shipped-unit-rep1 | 8.59 GB | 12.93 GB | 14.05 GB | +4.34 GB |
| T2-shipped-unit-rep2 | 9.08 GB | 14.14 GB | 14.14 GB | +5.07 GB |
| T3-killmode-process-rep1 | 9.08 GB | 21.55 GB | 31.06 GB | +12.48 GB |
| T4-killmode-process-rep2 | 9.14 GB | 21.45 GB | 30.73 GB | +12.31 GB |
| T5-kill9-grpc-only | 9.11 GB | 19.72 GB | 28.07 GB | +10.61 GB |
| T6-kill9-both | 9.16 GB | 9.16 GB | 9.16 GB | +0.00 GB |

**The asymmetry is the finding.** With the FUSE manager **off** (T0), a restart *reclaims*
cache (−4.27 GB): `rs.Close()` runs, and `directoryCache.Close()` does `os.RemoveAll` on the
cache directory (`cache/cache.go:379-387`). With the manager **on**, that cleanup is
deliberately skipped, and the cache instead **grows by 10.6–12.5 GB from the restart alone**,
ending at ~31 GB for 4.3 GB of unique data read — **≈7.2×**.

Upstream documents cache duplication only for the *unexpected* restart case
(`docs/overview.md`, "Unexpected restart handling", which advises manually cleaning the cache
directory). T3 and T4 show the same duplication after an ordinary, graceful
`systemctl restart` — a case the docs do not warn about. Combined with §7's finding that no
byte-budget knob exists, enabling the FUSE manager makes the unbounded-cache problem
measurably *worse*, not better.

Caveat: this run did not instrument the per-directory breakdown that would prove the growth is
specifically orphaned `directoryCache` directories rather than re-fetched chunks. The measured
fact — cache more than doubles across a restart with zero intervening application reads — is
solid; that specific mechanism is inferred from `cache/cache.go`, not separately measured.

---

## §4 S2 [P0] — ENOSPC under pressure, FUSE manager enabled

75% pre-fill of the 92GB partition (plain `fallocate` filler — the v3.1 simplification,
carried over and flagged: ext4 ENOSPC triggers on free block count, so a filler file is
equivalent to foreign chunk occupancy for this purpose), then a full 280-file read of the
140GB-class image. N=1 per the task, plus the S2b repetition in §5. Bundle:
`results/s2/S2-75pct-fm-on/`.

| quantity | value |
|---|---|
| deploy → Ready | **1.823 s** |
| full read | **20 / 280 files ok, 260 EIO**, 11.61 GB moved, 81.2 s |
| errno | `EIO (5)` uniformly — *not* ESTALE/ENOTCONN |
| cache occupancy during read | 81% → 89% → 96% → **100%** |
| pod throughout | `ready=true restarts=0 phase=Running` |
| ENOSPC log lines | **48** in the snapshotter journal, **34** in `stargz-fuse-manager.log` |

**Answer: no, `fuse_manager` changes nothing about the ENOSPC failure** — same EIO class, same
severity band, same silent pod, as expected and now measured rather than assumed. Note that
ENOSPC errors land in *both* sinks: with the manager enabled the FUSE serving (and therefore
the failing cache write) happens in the detached manager process, so a report that greps only
the snapshotter journal undercounts by ~40% here.

**What `exports.root` (PR #1893) actually bought** — `results/s2/S2-75pct-fm-on/kubelet-view-timeline.txt`:

| t (s) | imageFs availableBytes | imageFs usedBytes | DiskPressure |
|---|---|---|---|
| 1.9 | 92,658,450,432 | 150,233,088 | False |
| 22.1 | 12,839,718,912 | 152,571,904 | False |
| 42.3 | 6,342,639,616 | 152,571,904 | False |
| 62.5 | **0** | 152,571,904 | False |
| 82.6 | **0** | 152,571,904 | False |

`capacityBytes` = 97,828,376,576 — **exactly the cache partition**, so the fix genuinely works:
kubelet now maps the snapshotter root as imageFs, and `availableBytes` tracks the real fill
from 92.66 GB to 0. This is a real improvement on v3.1, where the cache volume was invisible.

But `usedBytes` stays pinned at ~152 MB while 92 GB is actually consumed. That matters
independently of any threshold: kubelet's image GC triggers on *used ÷ capacity*, which reads
**0.16%** here and would therefore never fire **at any `imageGCHighThresholdPercent`**.

**Do not over-read `DiskPressure=False` in this rig.** kind pins
`evictionHard: {imagefs.available: "0%", nodefs.available: "0%", nodefs.inodesFree: "0%"}` and
`imageGCHighThresholdPercent: 100` (`results/identity-bundle/kubelet-configz-v0182.json`), so
eviction is effectively disabled here. Whether an *available*-keyed eviction threshold would
fire on a production kubelet was **not tested** — see §10.

---

## §5 S2b — the lying pod, sharpened

Same induction, second rep, with the health/predict signal taken from **inside** the predictor
pod over loopback. Bundle: `results/s2/S2b-75pct-fm-on-rep2/`.

| | before induction | after induction |
|---|---|---|
| cache occupancy | 80% | **100%** |
| `GET /healthz` | 200 | **200** |
| `POST /predict` (seed=7) | 200 | **200**, byte-identical sha256 |
| first 1 MiB of each file | 280/280 readable | **280/280 readable** |
| full read of each file | — | **18/280 ok, 262 EIO** |
| pod | Ready | `ready=true phase=Running restarts=0` |

This is a stronger statement than v3.1 §3's "dice roll". Reading the **first 1 MiB** of all 280
files succeeds *after* the induction, while reading the same files **whole** fails on 262 of
them. The damage is concentrated in the file tails — the regions never cached before the
partition filled. A partial-read health check is therefore not merely unlucky; it is
**systematically biased toward the cached head of each file** and will report a fully healthy
model while 94% of files fail a complete read. The seeded `/predict` returned the identical
digest before and after precisely because its deterministic offsets had already been cached.

---

## §6 S3 [P1] — current main

Built on-rig from `main` = **`624678b4e421947534cbf0618f9609853cccee0f`**
(`containerd-stargz-grpc v0.18.2-135-g624678b4`); build SHA256s in
`results/s3/main-binaries-sha256.txt`.

**(a) New byte-budget knobs: none.** The TOML key surface of `main` is byte-identical to
v0.18.2 — 74 keys, none added, none removed, verified in both directions. Full evidence:
`source-audit/S3a-config-key-surface.txt` (audited before the rig existed) and
`results/s3/S3a-config-surface-on-built-binary.txt` (re-asserted against the binary actually
installed). The only cache-sizing knobs remain `max_lru_cache_entry` and `max_cache_fds`, both
**entry counts on in-memory structures**, not on-disk bytes. **The "no disk-bound knob"
core-claim survives on current main.**

**(b) S1a on main**, N=1 per unit variant (`results/s3/s1/s1-summary.csv`):

| trial | KillMode | fm PID pre→post | verdict |
|---|---|---|---|
| M1-main-shipped-unit | control-group (as shipped) | 18871 → 19240 | **MOUNT_BROKEN** (ESTALE=8 / ENOTCONN=4) |
| M2-main-killmode-process | process | 19709 → 19709 | **MOUNT_SURVIVED** |

Identical to v0.18.2. Nothing on main changes the restart behaviour.

**(c) ENOSPC on main** (`results/s3/s2/S3c-main-75pct-fm-on/`): Ready in **1.240 s**, full read
**21/280 ok, 259 EIO**, 11.71 GB moved in 77.6 s, pod Ready throughout. Statistically
indistinguishable from v0.18.2's 20/260. **The lying-pod class reproduces unchanged on current
main.**

---

## §7 Source audit (no rig needed)

Full write-up with line-precise citations: `source-audit/S3-PR2076-PR1893-forensics.md`.

- **Issue #1213** closed 2025-07-09 by **PR #2076** (`a744b5da`, core commit `22f7f716`). What
  it frees is **in-memory only**: a `TTLCache` map entry and its `time.AfterFunc` timer, via a
  new `evict bool` on `decreaseOnceFunc` (`util/cacheutil/ttlcache.go:103-118`) and a new
  `Close()` called on `Unmount()` (`fs/fs.go:450-455`). The diff contains **no `os.Remove`
  call** and never touches the on-disk caches. #1213 being closed is **not** a disk-cache
  reclaim mechanism.
- **Issue #1349** closed 2025-07-16 by **PR #1893** (`7de6607e`). The PR contains **no Go code
  at all** — 7 files, +17/−2, all docs and sample configs — adding
  `[proxy_plugins.stargz.exports] root = …`.
  **Correction to the task brief:** the exported root is the snapshotter's *top level*, and
  `service/service.go:128-133` puts **both** `snapshotter/` (layers) and `stargz/`
  (httpcache+fscache) under it, so it is *not* "snapshot layers only". But the point still
  lands, for a different reason: `exports.root` is *accounting*, not eviction — §4 measures
  exactly that (available tracks reality; used does not; nothing reclaims).
- On `main`, every on-disk cache deletion path is driven by TTL expiry (120 s default),
  validity-check invalidation, snapshot lifecycle, or resolution-error cleanup. **No eviction
  site anywhere is driven by a disk-size, free-space, or byte-budget threshold.**

---

## §8 Erratum — which signal path produced v3.1's published permanent-ESTALE

Full text: `source-audit/ERRATUM-v3.1-signal-path.md`. The v3.1 report is **not** modified.

Prompted by v4 harness bug #1 (below): if v3.1 had killed the daemon by process *name*, its
recovery-5 kill might never have fired. It did not use name matching — every kill site in the
v3.1 harness uses **`pkill -f`** (`14-p03-mechanism-recovery.sh:29` and **`:124`**, the
recovery-5 block; `15-p05-pressure-matrix.sh:45`; `05c-switch-stargz-cache-root.sh:39`), and
`identity-bundle/stargz-grpc-ps.txt` shows both the wrapper `sh -c` and the daemon carrying the
pattern. **The v3.1 kill worked; v3.1 is not affected by the v4 bug.**

However, the archived `14-p03` script **did not produce** the published `results/p03/` files
(different filenames, different headers, `dd` on `ballast-3.bin` where the script reads
`ballast-1.bin` with `cat`, a `SOCKET_OK` check and a pod-status block that exist nowhere in
the script, and no `recovery-4` file at all). This matches v3.1 §10's own note that a script
died mid-run and the remainder was done manually over SSH. **The exact command is not
preserved**, so the literal signal cannot be asserted.

It does not matter for the conclusion. v3.1 ran with the FUSE manager **disabled** — its
`identity-bundle/stargz-grpc-config.toml` has no `[fuse_manager]` block and the string appears
nowhere in the v3.1 tree — and with `Enable=false`, `main.go:278` unmounts on SIGTERM and
SIGINT alike while SIGKILL orphans the connection. **All three candidate signals converge on a
dead mount.** The published result is signal-independent.

**Consequences for the SPE revision.** v3.1's recovery-5 occupies exactly one cell of the v4
matrix — `fuse_manager=false` + graceful signal — reproduced here as **T0**, giving a same-rig
comparator. v3.1 says **nothing** about fuse_manager-enabled behaviour; v4 S1 is the first
measurement of it in this lineage. Safe phrasing: *"with the FUSE manager disabled (the
v0.18.2 default), restarting the snapshotter under a live pod leaves the container's mount
dead — ESTALE at open() — while Kubernetes still reports the pod Ready."* The parenthetical is
load-bearing. Do not write "v3.1 sent SIGTERM" as a bare fact.

---

## §9 Live fixes, harness bugs, and one invalidated attempt

**Four harness bugs, all mine, all found and fixed during the run:**

1. **`pgrep -x` / `pkill -x` against `containerd-stargz-grpc` matches nothing.** The kernel
   truncates `/proc/PID/comm` to 15 chars (`containerd-star`, `stargz-fuse-man`). Every PID
   capture and every `kill -9` in S1 would have silently no-op'd, and the kill trials would
   have reported a false "mount survived". Also `pgrep -f containerd-stargz-grpc`
   **over**-matches: the FUSE manager's own argv contains
   `-address /run/containerd-stargz-grpc/fuse-manager.sock`. Fixed by anchoring on the absolute
   executable path (`^/usr/local/bin/…`), which additionally avoids the v3.1 pkill-self-match
   pitfall. Verified live before use.
2. **The cache was never cleared, in any trial of attempt 1.** `/cache-part/stargz` is
   `drwx------ root:root`, so the calling `ubuntu` shell cannot expand
   `…/httpcache/*`; the glob stayed literal and `sudo rm -rf …/httpcache/*` deleted a file
   named `*`. The partition filled by trial 3 and every later trial failed. **v3.1 got this
   right** (`15-p05:45` uses `sudo sh -c "rm -rf …"`, so root expands the glob) — this is a v4
   regression only, and the published v3.1 pressure curve is unaffected. Fixed by restoring the
   `sudo sh -c` wrapper, plus a post-wipe assertion that the partition is actually back under
   10%.
3. **A dead FUSE mount made `glob()` return `[]` silently, and the verdict logic read that as
   success.** Attempt 1 scored `ok=0 err=0` as `MOUNT_SURVIVED` — three false positives,
   including a T0 control that contradicted v3.1. Fixed by probing **fixed, computed
   filenames** (so `attempted` is constant regardless of mount state) and by explicitly
   `stat()`ing and listing the mount directory; `MOUNT_GONE` and `PROBE_FAILED` are now
   distinct verdicts. This is what turned the run from wrong to right.
4. **journald rate limiting** was disabled in the node before any measurement
   (`RateLimitBurst=0`), because under an ENOSPC storm the snapshotter emits errors faster than
   the default burst and the dropped lines would have silently truncated the evidence.

**Infrastructure notes:**
- `ssh host "cmd &"` hangs whenever the backgrounded remote process keeps any session fd open;
  the driver wedged on it once. Replaced throughout by `setsid` + full fd redirection inside a
  subshell + a sentinel file polled from the workstation.
- S1's T6 (`kill -9` of both daemons) deliberately leaves stale FUSE mountpoints, a stale
  socket, and a systemd unit at its start limit. The next experiment then fails with
  `fusermount exited with code 256`. Consolidated into one `hard_reset()` (graceful SIGTERM to
  the manager first so it unmounts itself, then lazy-unmount stragglers, then wipe, then
  `systemctl reset-failed`).
- `du -sb` on `<root>/snapshotter` walks into the FUSE mounts and reports apparent TOC sizes
  (150 GB on a 92 GB partition). All cache numbers in this report come from `httpcache`/`fscache`
  and `df`.

**Preserved, not deleted** (per the task's rule): `results/s1-attempt1-INVALID/`,
`results/s2-attempt1-INVALID/`, `results/s3-attempt1-INVALID/` hold the entire invalid first
attempt, and `results/s1-probe-validation/` holds the single-trial run used to validate the
fixed probe before committing to the full matrix.

---

## §10 Honest gaps

- **Eviction behaviour was not tested.** kind pins `evictionHard` to `0%` and
  `imageGCHighThresholdPercent` to 100, so `DiskPressure=False` in §4 is a rig artifact. What
  §4 *does* establish rig-independently is that `usedBytes` excludes the FUSE content cache, so
  used-keyed image GC could never fire. Whether an *available*-keyed threshold would evict on a
  production kubelet is future work on a node with real thresholds.
- **S1 uses an 8-file / 4.295 GB working set**, not a full 140GB read, by design: a genuine
  140GB read would itself exhaust the 92GB partition and confound S1 with S2. "Cache
  duplication after full re-read" therefore means re-reading that working set.
- **S2 rep1 lost its health/predict signal** because the `curl-runner` deployment was collateral
  damage from attempt 1 filling the partition and would not restart. Recovered in S2b (§5) with
  an in-pod probe, which is the better instrument anyway. `results/s2/S2-75pct-fm-on/sampler.txt`
  shows `CURLFAIL` throughout and should not be read as a pod-health result.
- **N is small**: S1 N=2 per systemd variant, S2 N=1 (+1 in S2b), S3 N=1 per arm — as the task
  specified. The S1 result is nonetheless unambiguous (7/7 trials matched pre-registered
  predictions, with no intermediate outcomes).
- **Only one pressure level (75%)** was run; v4 does not repeat v3.1's pressure curve.
- The §3 duplication mechanism is inferred from `cache/cache.go`, not separately instrumented.

---

## §11 Exact versions, SHAs, digests

| component | version / SHA |
|---|---|
| stargz-snapshotter (S1, S2) | **v0.18.2** = `3070538befb5a6c09f93e99164762b3a76310357` |
| stargz-snapshotter (S3) | **main** = `624678b4e421947534cbf0618f9609853cccee0f` (`v0.18.2-135-g624678b4`) |
| release tarball sha256 | `results/identity-bundle/TARBALL-SHA256.txt`, per-binary in `SHA256SUMS.txt` |
| `containerd-stargz-grpc` v0.18.2 binary | `c04029ae5be9c9fad84e5312848d8df876247989d0a93e6a21e9d463945912e2` |
| `stargz-fuse-manager` v0.18.2 binary | `d6ae9229363f069403d98a06cea700ca03ebc34030973bb8db4b07603e5ba7dd` |
| `containerd-stargz-grpc` main build | `451a842fc3a635a5e52e38795012bed4758b1a223ae5f544a90e6166d1382c5e` |
| `stargz-fuse-manager` main build | `009c1e4cc68d79eb60f36ecd1eba278f58a5d7bbc915b971c11a8523be0ffc49` |
| containerd (kind node) | `v2.3.1` `64b425cf570b3b8dd1d4cc46da7c1fce65c6651a` |
| Kubernetes | server `v1.36.1`, kind `v0.30.0`, node image `kindest/node:v1.36.1` |
| Docker (hosts) | `29.8.0` build `88096ef` |
| Go (main build) | `go1.24.7 linux/amd64` |
| model image (eStargz, 140GB-class) | `model-ballast:estargz-140g` digest `sha256:76447f513c7ace1e72012fa05f9713abb90adb4e43c2b187f2f213f8ae68f79b` |
| model image (source, 8-layer gzip) | `model-ballast:B-140g` |
| predictor image | `custom-predictor:v4` digest `sha256:04ad4d235f7aea241fe552826a76569acdebf68318d368bdd9dd884e647cbf45` |
| PR #2076 | merge `a744b5da80ebb525ba68a18d0ea3c05d71b76536`, fix `22f7f7164ae6432e10bb65377f16965215116f2` |
| PR #1893 | merge `7de6607e7fd881ce2fd6991ec5b45c89d2853747` |

eStargz conversion of the 140GB image: pulled 140.0 GB at 356.2 MiB/s in 402.6 s, converted and
pushed (`results/estargz-convert-140g.log`).

---

# RUN 2 — closing the two gaps (second rig, same geometry)

Run 1 left two "not tested" caveats in §10. Both were worth paying for, so a second
identical rig (2x `i4i.2xlarge`, same 140GB image / 92GB partition) was built to close
them. Evidence for everything below is in `results-run2/`; run 1's evidence is
untouched in `results/`.

The one deliberate configuration difference: this cluster was created with
**production-like kubelet eviction thresholds** instead of kind's defaults —
`evictionHard {imagefs.available: 10%, nodefs.available: 10%, memory.available: 100Mi}`,
`evictionPressureTransitionPeriod: 30s`, `imageGCHighThresholdPercent: 85`. Run 1 had
kind's `imagefs.available: 0%` / `imageGCHighThresholdPercent: 100`, i.e. eviction
effectively off, which is why run 1 could not interpret `DiskPressure=False`.

## §13 S5 — restart-driven cache growth is cumulative, not bounded

Run 1 §3 measured that ONE restart with the FUSE manager on grows the cache by
10.6-12.5 GB with no application reads, and inferred the mechanism from source. S5
tests whether it repeats, and measures the mechanism. One warm pod (8 files, 4.295 GB),
then N consecutive `systemctl restart`s with **zero application reads in between**.
`df` is the authoritative figure. Bundles: `results-run2/s5/`.

**S5a — `fuse_manager = true`, `KillMode=process`** (`s5a-fm-on/restart-loop.csv`):

| after restart | df used | % of 92GB | httpcache dirs | fscache dirs | fm PID | mount | read |
|---|---|---|---|---|---|---|---|
| 0 (baseline) | 10.01 GB | 11% | 10 | 10 | 3825 | ok | 8/8 |
| 1 | 23.53 GB | 26% | 10 | 10 | 3825 | ok | 8/8 |
| 2 | 41.76 GB | 45% | 10 | 10 | 3825 | ok | 8/8 |
| 3 | 59.94 GB | 65% | 10 | 10 | 3825 | ok | 8/8 |
| 4 | 77.76 GB | 84% | 10 | 10 | 3825 | ok | 8/8 |

**S5b — `fuse_manager = false`, control** (`s5b-fm-off/restart-loop.csv`): df used stays
between **4.03 and 4.85 GB across all 8 restarts** (5-6%), never trending upward. The
mount dies at restart 1 (`ESTALE=8`) and stays dead, exactly reproducing S1's T0.

**Findings.**
1. The growth is **cumulative and linear at ~17-18 GB per restart**, not a one-off. Five
   ordinary `systemctl restart`s take a 92GB cache partition from 11% to over 84%; the
   loop was cut short at restart 5 by the node itself. Nothing ever reclaims it.
2. **The mechanism is not what run 1 inferred.** `httpcache_dirs`/`fscache_dirs` stay
   pinned at **10/10** (one `directoryCache` per layer) across every restart. So this is
   NOT orphaned cache *directories*; it is duplicate chunk data accumulating *inside* the
   same ten directories. Run 1 §3's inference from `cache/cache.go` was wrong on that
   point and is corrected here by measurement.
3. `fm_pid` is **3825 in every row** — the manager survived all restarts, and the mount
   kept serving reads (`8/8 ok`) the whole time. The growth is the price of that survival:
   S5b shows the same restarts cost nothing when the feature is off, because the mount is
   simply destroyed instead.

**The operational statement.** Reloading snapshotter configuration is a routine,
sanctioned operation. With `fuse_manager` enabled and no byte-budget knob anywhere in the
codebase (§7), roughly five such reloads walk a 92GB cache partition into ENOSPC with no
application traffic at all.

## §14 S4b — kubelet is now sighted, but powerless

Run 1 could not say whether PR #1893's `exports.root` visibility leads to action. With
real thresholds it does — and what follows is worse than blindness. Bundle:
`results-run2/s4/S4b-eviction-direct/`.

The first attempt (`results-run2/s4/S4-eviction-75pct/`, preserved and flagged) tried to
cross the threshold using a 140GB lazy read; the read was SIGKILLed at ~30s with
`imagefs.available` still at 12.6%, just above the 10% threshold, so it never reached the
decisive point. S4b instead consumes the partition directly with `fallocate`, decoupling
the kubelet question from the pod/read machinery.

**Phase 1 (no pod at all, partition at 100%)** — `phase1-nopod.csv`:
`imagefs_avail = 0`, `imagefs_avail_pct = 0.00`, **`disk_pressure = True`**, sustained for
the whole 150s window. Node event: `NodeHasDiskPressure`.

**So PR #1893 genuinely works as a signal.** kubelet maps the snapshotter root as imageFs
(`capacityBytes` = 97,828,376,576, exactly the partition), tracks `availableBytes`
correctly, and raises DiskPressure. This is a real improvement on v3.1, where the cache
volume was wholly invisible.

**But nothing can act on it.** The node events tell the whole story:

```
Warning  FreeDiskSpaceFailed  node/ocibench-control-plane
  Insufficient free disk space on the node's image filesystem (100% of 91.1 GiB used).
  Failed to free sufficient space by deleting unused images (freed 0 bytes).
Warning  EvictionThresholdMet node/ocibench-control-plane  Attempting to reclaim ephemeral-storage
Warning  Evicted  pod/curl-runner-...        The node was low on resource: ephemeral-storage.
                                             Threshold quantity: 9782837803, available: 0.
Warning  Evicted  pod/local-path-provisioner-...  The node had condition: [DiskPressure].   (x17)
```

Image GC ran and **freed 0 bytes** — precisely the consequence of the used-accounting gap
measured in run 1 §4 and re-confirmed here (`imagefs_used` max = **741,376 bytes** while
91.1 GiB is consumed). containerd does not consider the stargz content cache to be images,
so there is nothing for GC to delete. kubelet then falls through to its only remaining
lever, pod eviction, and evicts **innocent bystanders** — `local-path-provisioner`
seventeen times in a crash-evict loop, plus `curl-runner` — none of which put a byte on
that partition. The actual consumer is never touched, so the evictions do not help and
simply repeat.

**Phase 2**: a fresh eStargz pod deployed against the starved node never leaves
`Pending` — `pod_ready=false` for the entire window, because the node carries DiskPressure.

**The v4 statement of the problem, in full.** The snapshotter has no byte-budget knob
(§7, unchanged on `main`), its cache grows ~2.1x per byte read (§3) and ~18 GB per daemon
restart without any reads at all (§13). PR #1893 makes that growth *visible* to kubelet
but supplies nothing that can *reclaim* it, and the used-bytes accounting stays at ~0. The
result is not a silent failure — it is a loud, self-perpetuating one, in which the
platform correctly diagnoses disk exhaustion and then destroys unrelated workloads in a
futile attempt to fix it.

## §15 Run 2 — what changed in the conclusions

- Run 1 §4's `DiskPressure=False` is **fully explained** and was correctly flagged as a
  rig artifact, not a finding. The real behaviour with production thresholds is §14.
- Run 1 §3's cache-duplication **mechanism** (orphaned `directoryCache` directories) is
  **corrected** by §13: the directory count is constant; the duplication is inside them.
  The magnitude reported in run 1 stands and is now shown to be cumulative.
- Everything else from run 1 — S1's 7/7 matrix, the ESTALE/ENOTCONN signature, the
  lying-pod result, S3's parity between v0.18.2 and `main` — is unchanged.

## §16 Run 2 gaps

- S5a stopped after restart 5 of 8 (the driver was killed once the partition neared
  exhaustion). Five points are enough to establish linearity, but the trial did not run to
  a clean ENOSPC endpoint under its own guard.
- S5 was run only with `KillMode=process` for the ON arm; the growth per restart under the
  shipped unit (where the mount dies anyway) was not separately characterised.
- The first S4 attempt is preserved but produced no usable timeline.
- Eviction was measured at one threshold (`imagefs.available: 10%`); no threshold sweep.

---

## §17 Cost (both runs)

`i4i.2xlarge` on-demand, us-east-1, Linux, $0.686/instance-hour, 2 instances per run.

| run | instances | launched (UTC) | terminated (UTC) | wall clock | instance-hours | cost |
|---|---|---|---|---|---|---|
| run 1 (S1, S2, S2b, S3) | `i-0b9af50b48e4b64a0`, `i-0d218bbe06251c284` | 02:54:28 | 05:32:19 | 2.63 h | 5.262 | $3.61 |
| run 2 (S5a, S5b, S4b) | `i-0ae9a31108f5202ff`, `i-04703c2b31abab34c` | 05:51:10 | 07:52:08 | 2.02 h | 4.032 | $2.77 |
| **total** | | | | **4.65 h** | **9.294** | **$6.38** |

Plus a few cents of gp3 root volumes (4 x 30 GB, deleted on termination) and no egress or
inter-AZ charges -- both hosts of each run sat in the same AZ and security group, and all
registry traffic was private. **Total $6.38 against the $25 reference
figure (~26%).**

In each run roughly 60% of the paid time was the one-off 140GB artifact build (ballast
generation, the 8-layer gzip image, and the eStargz conversion). The measurements
themselves took about 35 minutes in run 1 and about 30 minutes in run 2. The dominant cost
of this spike is rebuilding a 140GB image twice, not running the experiments; a future
spike on this lineage should snapshot the built image to a persistent volume or an AMI
rather than regenerating it.

### Teardown verification (run after each collection)
```
run 1:  i-0b9af50b48e4b64a0 terminated   i-0d218bbe06251c284 terminated
run 2:  i-0ae9a31108f5202ff terminated   i-04703c2b31abab34c terminated
non-terminated instances, ALL regions swept: 0
unattached EBS volumes in us-east-1:        0
```
All results were rsynced to `results/` (run 1) and `results-run2/` (run 2) before each
termination.

## Independent verification note, run 2 (Chat C, 2026-09-11)
Spot-verified against raw bundles: (1) S4b event chain present verbatim in s4/S4b-eviction-direct/all-events.txt (NodeHasDiskPressure; FreeDiskSpaceFailed "100% of 91.1 GiB used... freed 0 bytes"; 26 Evicted events; timeline rows show usedBytes=741,376 with df at 100% and the eStargz pod Pending). (2) S5a restart-loop.csv: df_used 10.0/23.5/41.8/59.9/77.8 GB over restarts 0-4, httpcache+fscache dirs pinned at 10/10 throughout (duplicate-chunks-in-place mechanism confirmed; §3 run-1 inference correctly retracted in §15), fm_pid constant 3825, reads clean. (3) S5b control flat at 4.0-4.8 GB across 8 restarts, ESTALE=8 from restart 1 (fm off). No discrepancies. §16 gaps (S5a stopped at restart 5; single eviction threshold) noted and accepted as honest scope limits.
