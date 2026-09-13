# Live fixes — spike v6

Environment bugs are fixed on the rig and recorded here. Bugs in the system
under test are **not** fixed on the rig: they stop the experiment that hit them
and go into `RUN-REPORT-v6.md`, because a patched binary is no longer the SHA
this run claims to measure (PRE-REGISTRATION-v6.md §5.1).

Numbering continues the v5 series in spirit but restarts at G1 (for "v6") to
avoid collision with v5's F-numbers, which the report still cites.

---

## G1 — docker hits systemd's start rate limiter during node setup

**Class:** environment (harness).

**What happened.** `node-bootstrap.sh` died at `01-cluster-up.sh` with
`Job for docker.service failed`. The daemon itself was fine; systemd had
refused to start it:

```
docker.service: Start request repeated too quickly.
docker.service: Failed with result 'start-limit-hit'.
```

**Cause.** `00-node-host-setup.sh` restarts docker twice in quick succession —
once after moving `data-root` to `/data/docker`, once after writing
`insecure-registries` — and `01-cluster-up.sh` then restarts it a third time for
its own registry entry. Three starts inside systemd's default
`StartLimitIntervalSec` trips the limiter. Nothing about it is specific to this
run; v5 survived it by timing luck.

**Fix.** `systemctl reset-failed docker.service docker.socket` before every
start, in `00-node-host-setup.sh` (both sites). Applied live to recover this
run, and committed to the script so it cannot recur.

**Cost:** ~4 minutes.

---

## G2 — switching arms does not switch the binary that produces the metrics

**Class:** environment (harness). Found by a pre-check, before it could cost a trial.

**What happened.** After installing the pre-fix build (`f6547d99`) over the SUT
build and restarting the snapshotter, the documented endpoint still served 39
`stargz_(cache|fs_cache)_*` series — the SUT's behaviour, from a build that
cannot produce it. The negative control was silently measuring the system under
test.

**Cause.** `KillMode=process` — our own fix for upstream #2387, and the premise
of every experiment in this spike — deliberately keeps the FUSE manager alive
across a snapshotter restart. With `[fuse_manager] enable = true` the manager is
where the filesystem, the accounting index and the eviction engine live, so
`systemctl restart` leaves the *previous arm's manager binary* serving every
metric. `05-setup-stargz.sh` copied the new binaries and restarted the unit, and
that is not sufficient.

v5 was safe here only by ordering: its `switch_arm` was always followed by a
`trial()` whose first action is `hard_reset`, which does kill the manager. The
protection was accidental, and nothing asserted it.

**Evidence.**

```
manager pid BEFORE hard_reset: 2391      manager pid AFTER: 5608
manager binary md5:  86587d6fe34dbfa6e712dc6513342ee2
/data/stargz-bin-prefix md5: 86587d6fe34dbfa6e712dc6513342ee2   <- matches
/data/stargz-bin-ours   md5: cb5cb4d0fdeb1198fbf04e2271486db7

before the manager was replaced:  :9110 cache_series=39   (the SUT's)
after  the manager was replaced:  :9110 cache_series=0    (the pre-fix build's)
                                  :9111 cache_series=38
```

**Fix.** `05-setup-stargz.sh` now replaces a running manager whenever it installs
binaries, and then **asserts the running manager's md5 matches the binaries it
installed**, dying if it does not. An arm can no longer be switched in name only.

This is setup, not measurement: E1 still performs its own plain `systemctl
restart` afterwards, which is the gesture under test.

**Cost:** ~6 minutes, and it bought a clean negative control.

---

## G3 — the readiness probe could not see an eStargz image

**Class:** environment (observation tooling only — no experiment was affected).

**What happened.** The build-status probe reported `estargz-14g` as 404 for
several minutes after its conversion log had already printed `CONVERT_DONE_OK`
and `Completed push`.

**Cause.** `ctr-remote image convert --oci` produces an **OCI image index**
(`application/vnd.oci.image.index.v1+json`), and the probe's `Accept` header
listed only the two *manifest* media types. A registry that has the index but
not a matching manifest type answers 404.

**Fix.** Added the index and manifest-list media types to the probe's `Accept`.
Worth recording because the failure mode is "your readiness check says the
artifact is missing when it is there", which costs waiting time rather than
correctness — and on a metered rig, waiting time is the cost.

**Cost:** ~3 minutes of unnecessary waiting.

---

## G4 — `local a="$1" b="${a}"` silently killed a 40-minute experiment

**Class:** harness bug, mine, in the v6 observation code.

**What happened.** E1's first run did the expensive part correctly — the warm
read completed with `attempted=28 ok=28 err=0 bytes=15032385536 elapsed_s=96.897`
— and then died immediately, at the first observation:

```
./20-e1-restart-confirm.sh: line 41: tag: unbound variable
```

The run produced `meta.txt`, `setup.log` and `warm-read.txt`, and not one of the
five observation bundles the experiment exists to collect.

**Cause.**

```sh
observe() {
  local tag="$1" d="${OUT}/obs-${tag}"      # <- ${tag} is NOT set yet
```

Bash expands every argument to the `local` builtin *before* the builtin assigns
any of them, so `${tag}` is still unset when `d` is computed, and `set -u` makes
that fatal. The same line is fine without `set -u`, and fine if the two
assignments are separate statements, which is why it reads as correct.

Checked every other v6 script for the pattern: the other four matches
(`21-e2`, `22-e3`, `32-v2`, `35-v5`) reference variables bound by a *previous*
`local` statement and are not affected.

**A second failure made the first one expensive.** The progress monitor decided
"still running" from `pgrep -fc 20-e1-restart`, and the shell running that check
has `20-e1-restart` in its own command line, so the count never reached zero. The
experiment had been dead for 40 minutes while the watch reported progress.

**Fix.** Three things, because one of them alone would have left the trap open:

1. Split the `local` into two statements, with a comment saying why.
2. `trap 'rc=$?; echo "FATAL: ... line ${LINENO} exited ${rc}" >&2' ERR` in the
   experiment script, so a failure announces itself instead of leaving the log's
   last line pointing at the step *before* the one that failed.
3. A wrapper that appends `E1_EXIT=$?` to the log, and a monitor that keys on
   that marker rather than on a process table it can match itself.

**Cost:** ~40 minutes of rig time (~$0.90), and it was concurrent with the 140 GB
conversion, so nothing else was waiting on it.

---

## G5 — an arm-run leaves the partition full, and the next arm restarts before wiping

**Class:** harness (ordering), caused by a real defect in the SUT (C4).

**What happened.** E2 run 1 completed normally, and then run 2 died immediately,
taking E3 with it:

```
Job for stargz-snapshotter.service failed because the control process exited with error code.
{"error":"mkdir .../snapshotter/multiple-lowerdir-check.../lower2: no space left on device",
 "level":"fatal","msg":"snapshotter is not supported"}
```

**Cause, two layers deep.**

The partition was at 89 GB of 92 GB when run 1 ended, because the accounting
index had under-counted by 12.8 GB and eviction therefore stopped short — that
is CODE-FINDINGS-v6 C4, a defect in the system under test, not in the harness.

The harness's contribution is ordering: `armrun` called `apply_policy` — which
does `systemctl restart` — *before* `hard_reset`, which is what wipes. So the
snapshotter was asked to start on a full disk, hit a fatal ENOSPC in its startup
probe, and the `set -e` chain stopped.

**Fix.** `hard_reset` first, then `apply_policy`. `hard_reset` wipes before it
starts anything, so it is safe on a full disk; `apply_policy` is not.

Added at the same time, because the C1 race can leave a process with no
accounting index at all: an **accounting health gate** before each arm is
measured. It asserts that occupancy series exist and that the policy label is
the requested one, and marks the arm `-INVALID` rather than measuring an
unbounded cache while claiming a policy.

**Also worth recording, so it is not rediscovered:** a manual
`sudo rm -rf /cache-part/stargz/httpcache/*` from the ubuntu shell silently
removes nothing — the directory is root-owned, so the glob never expands for the
unprivileged shell and `rm` gets a literal `*` that matches no file. `hard_reset`
does this correctly with `sudo sh -c "rm -rf .../*"`, where a root shell expands
the glob. Removing the directory and recreating it takes ~18 s for ~950k files.

**Cost:** ~20 minutes, plus re-running E2 from the start so all four arm-runs
share identical starting conditions.

---

## G6 — a pod left from a previous run makes the next run's reads fail instantly

**Class:** harness. Same root cause as E1 attempt 1; fixed there and not in E2,
so it recurred.

**What happened.** E2 run 1 of the second re-run "completed" in 43 seconds. All
three warm passes returned instantly:

```
ROUND=0 FILE=ballast-1.bin bytes=0 ms=0.027 errno=107 ENOTCONN
```

**Cause.** The previous chain had been stopped, leaving `e2-resident` and
`e2-sweep` Running. `hard_reset` then destroyed the FUSE mounts underneath them.
`deploy_pod` re-applies an identical spec, which kubectl treats as a no-op, so
the pod kept running against a dead mount and every read returned ENOTCONN.

**Fix.** Two changes, because the first alone only prevents the known path:

1. `teardown_pod` for both pods before deploying, in `armrun` — the same fix E1
   already carries.
2. A guard that **refuses to measure an arm whose warm reference pass returned
   any read error**, marking it `-INVALID` with the first three offending lines.
   A trial that reads nothing must not be able to look like a fast success.

**Why it is worth two fixes.** The failure is silent and fast, and fast looks
like healthy. The 43-second arm produced a complete-looking bundle — `meta.txt`,
three warm files, a sampler, a verdict line — and the only way to tell was to
notice that three passes over 14 GB had taken under a second.

**Cost:** ~8 minutes.
