# Live fixes — spike v7

Environment and harness bugs, fixed on the rig and recorded. Bugs in the system
under test are **not** fixed here: they stop the experiment that hit them and go
into the report (PRE-REGISTRATION-v7.md §5.3).

Numbering continues from v6's G-series.

---

## G7 — the bootstrap could not reach docker, because it granted itself the group mid-run

**Class:** environment (harness).

**What happened.** The node bootstrap created the kind cluster and failed:

```
ERROR: failed to create cluster: failed to get docker info:
  command "docker info --format '{{json .}}'" failed with error: exit status 1
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

while `groups` on the same host showed `ubuntu` *was* in the `docker` group.

**Cause.** `00-node-host-setup.sh` adds `ubuntu` to the `docker` group, and the
bootstrap then runs `01-cluster-up.sh` in the same process. A process carries the
group set it was started with; a grant made after it started is invisible to it.
So every docker call in the rest of the bootstrap ran without the group.

v6 never saw this, and not because it was structured better: its bootstrap
crashed on an unrelated problem (G1, the docker start-rate limiter), and the
retry was issued from a *fresh* SSH session that did have the group. The
protection was luck, twice over.

**Fix.** `06-node-bootstrap.sh` is split into two phases. Phase 1 runs the base
setup; it then checks whether the docker API is reachable and, if not,
re-executes itself under `sg docker` so phase 2 runs in a process that has the
group. Phase 2 asserts `docker info` works before doing anything, so a future
variation of this fails loudly instead of ten steps later.

**Cost:** ~6 minutes, and it was concurrent with the artifact build, so nothing
was waiting on it.

---

## G8 — the EBS data volume was sized from the artifacts, not from the build's peak

**Class:** environment (harness), and a direct consequence of v7's own snapshot design.

**What happened.** With the 140 GB image still building, `/data` on the registry
reached **547 GB of 590 GB (93%)** before the eStargz conversion — which needs
roughly another 280 GB — had started. The build was minutes from ENOSPC.

```
/data/bench        141G   raw ballast
/data/docker       141G   build layers
/data/containerd   265G   the build's containerd backend
/data/registry      47M   (nothing pushed yet)
```

**Cause.** The volume was sized at 600 GB from the *artifacts* — a 140 GB image
plus a 14 GB one, with headroom. The **build's peak** is several times that: the
raw ballast, a hardlinked copy for layering, the docker/containerd build
backend, the pushed registry blobs, and then the conversion's own pull, convert
and push. v5 and v6 never met this because they built on the i4i instance store,
which is 1.7 TB and free; moving the build to EBS so the artifacts could be
snapshotted (v7 rule 2) is what introduced the constraint, and the first sizing
did not account for it.

**Fix, applied live with no interruption to the build.** gp3 volumes grow online:

```
aws ec2 modify-volume --volume-id vol-028c6acbe8d7e2007 --size 1200
# ... ModificationState=optimizing, usable immediately ...
sudo resize2fs /dev/nvme1n1      # no partition table; the volume is the filesystem
```

```
before:  /dev/nvme1n1  590G  547G   17G  93%  /data
after:   /dev/nvme1n1  1.2T  414G  713G  37%  /data
```

The running build did not notice. `99-aws-lifecycle.sh` should launch the
registry with 1200 GB rather than 600 GB next time; the cost difference is
about $0.07/hour and the snapshot still bills only on blocks actually written,
so there is no reason to have been frugal here.

**Cost:** ~2 minutes, and it avoided losing a ~50-minute build.

---

## G9 — an edit removed less than it meant to, and E1 ran eight restarts instead of six

**Class:** harness (mine), caught while E1 was running. **No data was invalidated.**

**What happened.** E1's log switched mid-run from the v7 format
(`--- restart 5: policy -> 2q ---`) back to v6's (`--- restart 1: policy lru ->
2q ---`), after the six-restart loop had already completed cleanly.

**Cause.** The edit that replaced v6's fixed two-restart sequence with v7's
six-restart loop sliced the file from `observe 1-baseline-lru` up to
`teardown_pod e1-warm` — and `teardown_pod e1-warm` first appears *before* the
warm read, because v6's live fix G6 added it there to kill the stale-pod trap.
So the slice ended too early, the new loop was inserted ahead of the warm read's
teardown, and v6's two-restart block survived below it.

E1 therefore ran its six pre-registered restarts and then two more. Every
observation from all eight is clean and consistent, so this cost nothing except
two duplicated observation names (`1-baseline-lru` alongside `00-baseline-lru`).

**Fix.** The leftover block is removed before the negative-control arm runs, so
that arm executes exactly the pre-registered six. The SUT arm's bundle keeps all
eight observations, with this note explaining why there are more than the
pre-registration says.

**Lesson worth keeping:** an index-based slice needs an anchor that is unique.
`s.index(x)` silently takes the first match, and v6's own fix had introduced a
second one.
