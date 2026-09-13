# S1 pre-registered predictions (written BEFORE the rig was launched)

Derived purely from reading v0.18.2 source. Recorded here so the RUN-REPORT can
show which predictions survived measurement and which did not, rather than
fitting an explanation to whatever came out.

## The three source facts

1. `cmd/containerd-stargz-grpc/main.go:262-281`
   ```go
   cleanup, err := serve(...)              // cleanup == (received signal was SIGINT)
   if cleanup || !fuseManagerConfig.Enable { rs.Close() }
   ```
   So with `fuse_manager.enable = true`, a **SIGTERM** deliberately skips `rs.Close()`
   and leaves the mounts up; a **SIGINT** tears them down.

2. `fusemanager/fusemanager.go:207-219` — the FUSE manager's own signal loop registers
   `unix.SIGINT, unix.SIGTERM` and, on **either**, runs `server.Stop()` + `fm.Close(ctx)`.
   SIGTERM is NOT survivable for the manager itself.

3. `fusemanager/fusemanager.go:117-121` — the manager is detached with
   `SysProcAttr{Setpgid: true}` and nothing else. That creates a new *process group*.
   It does **not** create a new cgroup and does not `setsid`. Upstream's shipped
   `script/config/etc/systemd/system/stargz-snapshotter.service` declares no
   `KillMode`, so systemd's default `KillMode=control-group` applies.

Composition: (3) says `systemctl restart` SIGTERMs every process in the unit cgroup;
(2) says that SIGTERM makes the FUSE manager unmount everything; therefore (1)'s
protection is expected to be **void under upstream's own shipped unit**.

## Predictions

| trial | config | prediction |
|---|---|---|
| T0 | fuse_manager=false, unit as shipped | MOUNT_BROKEN — reproduces v3.1 recovery-5 ESTALE on the same rig |
| T1 | fuse_manager=true, unit as shipped, rep1 | **MOUNT_BROKEN** — cgroup kill takes the manager with it |
| T2 | fuse_manager=true, unit as shipped, rep2 | MOUNT_BROKEN |
| T3 | fuse_manager=true, `KillMode=process`, rep1 | **MOUNT_SURVIVED** — manager outlives the restart |
| T4 | fuse_manager=true, `KillMode=process`, rep2 | MOUNT_SURVIVED |
| T5 | fuse_manager=true, kill -9 grpc only | MOUNT_SURVIVED — manager never receives a signal; this is docs' "unexpected restart", so fscache duplication is expected on re-read |
| T6 | fuse_manager=true, kill -9 both | MOUNT_BROKEN, and possibly *permanently*: SIGKILL cannot unlink `fuse-manager.sock`, and `StartFuseManager` (fusemanager/fusemanager.go:225-231) returns `newlyStarted=false` whenever that socket path exists, which makes `main.go:194-199` set `snbase.NoRestore` — i.e. the snapshotter would decline to restore mounts *because it believes a live manager already holds them* |

Errno prediction for every MOUNT_BROKEN case: **ESTALE (116)** at the application
`open()`/`read()`, matching v3.1 §5 recovery-4/5, with `kubectl get pod` continuing to
report Ready=True and restarts=0 throughout.

## What would falsify the headline

If T1/T2 come out MOUNT_SURVIVED, fact (3) is wrong (systemd is not killing the
manager) and the "shipped unit defeats the feature" claim must be dropped entirely.
If T3/T4 come out MOUNT_BROKEN, fuse_manager does not cure permanent-ESTALE at all
and the answer to the SPE reviewer is simply "no".

---

## Measurement caveat discovered during the smoke test (before S1 ran)

`du -sb` on `<root>/snapshotter` reports **apparent** size, not disk usage, because the
eStargz snapshots are FUSE mounts: `stat()` returns each file's full logical size from the
image TOC while only fetched chunks occupy real blocks. Smoke test, same instant:

```
cache_du  httpcache=75,458,967  fscache=71,303,168  stargz=146,762,135
          snapshotter=150,464,285,615   total=150,611,239,020
df        /dev/nvme1n1p2  used=306,159,616  (0.3 GB of 92 GB, 1%)
```

150 GB "used" vs 306 MB actually consumed. Therefore the S1 cache-duplication analysis
uses ONLY the `httpcache` and `fscache` columns (real on-disk cache files) plus `df`
(real blocks). The `snapshotter` and `total` columns are recorded for completeness but
MUST NOT be quoted as disk consumption.
