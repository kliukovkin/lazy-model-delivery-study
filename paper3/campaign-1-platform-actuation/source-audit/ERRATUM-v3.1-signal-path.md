# ERRATUM (v4 → v3.1): which signal path actually produced the published permanent-ESTALE

Prompted by a v4 finding: `pgrep -x` / `pkill -x` against `containerd-stargz-grpc`
silently match nothing, because the kernel truncates `/proc/PID/comm` to 15 characters
(`containerd-star`). If v3.1 had used name-based `-x` matching, its recovery-5 "kill"
might never have fired and the published result would rest on a no-op. This section
records what v3.1 actually did. **The v3.1 report is not modified.**

## Finding 1 — v3.1 is NOT affected by the v4 bug

Every daemon-kill site in the archived v3.1 harness uses **`pkill -f`** (full command
line), never `-x`:

- `scripts-as-run/14-p03-mechanism-recovery.sh:29` — `docker exec "${NODE}" pkill -f containerd-stargz-grpc || true`
- `scripts-as-run/14-p03-mechanism-recovery.sh:124` — same, this is the **recovery-5** block
- `scripts-as-run/15-p05-pressure-matrix.sh:45` — same, inside `clean_cache()`
- `scripts-as-run/05c-switch-stargz-cache-root.sh:39` — `pkill -f 'containerd-stargz-grpc.*stargz/containerd-stargz-grpc.sock'`

`-f` matches the full argv and does match the daemon. `results/identity-bundle/stargz-grpc-ps.txt`
shows the live process pair:

```
14591 sh -c containerd-stargz-grpc --log-level info --address /run/containerd-stargz-grpc/containerd-stargz-grpc.sock --config /etc/containerd-stargz-grpc/config.toml > /var/log/stargz-grpc.log 2>&1
14597 containerd-stargz-grpc --log-level info --address /run/containerd-stargz-grpc/containerd-stargz-grpc.sock --config /etc/containerd-stargz-grpc/config.toml
```

Both entries contain the pattern, so `pkill -f` signalled the wrapper shell *and* the
daemon. No signal was lost. **The v3.1 kill worked.**

(Incidentally this confirms the mechanism of the v4 bug: `pkill -x containerd-stargz-grpc`
would NOT have matched PID 14597, since its `comm` is the truncated `containerd-star`.)

## Finding 2 — but the archived 14-p03 script is NOT what produced the published p03 files

The files in `results/p03/` cannot have been written by the archived script:

| archived `14-p03-mechanism-recovery.sh` | file actually in `results/p03/` |
|---|---|
| writes `${OUT}/recovery-5-daemon-restart-live.txt` | file on disk is `p03-recovery-5-daemon-restart-live.txt` |
| header `5) restart stargz-grpc daemon UNDER the live pod -- mount survives/heals/ENOTCONN?` | header `=== recovery-5: restart stargz-grpc daemon UNDER the live pod ===` |
| reads with `cat /mnt/models/ballast-1.bin \| wc -c` | shows `dd: failed to open '/mnt/models/ballast-3.bin'` |
| has no socket check and no post-restart `kubectl get pod` | contains `SOCKET_OK` and a pod-status block |
| writes `recovery-4-prune-fresh.txt` | **no recovery-4 file exists at all** |

Also, the archived `05-setup-stargz.sh` starts the daemon on suffixed paths
(`/run/containerd-stargz-grpc-stargz/...`, `/etc/containerd-stargz-grpc-stargz/...`),
but the identity bundle shows it running on the **default** unsuffixed paths.

This is consistent with v3.1 RUN-REPORT §10, which records that a script died partway
(the `docker exec ... wc -l < localfile` redirect bug) and "the remaining steps [were run]
manually via direct SSH." **The exact manual command that produced recovery-5 is not
preserved.** So the literal signal cannot be read off the archive with certainty.

## Finding 3 — why the v3.1 conclusion nevertheless stands, whatever the signal was

v3.1 ran with the FUSE manager **disabled**. `results/identity-bundle/stargz-grpc-config.toml`
is complete and contains only `metrics_address` and a resolver mirror — no `[fuse_manager]`
block — and the string `fuse_manager` / `stargz-fuse` appears **nowhere** in the entire
v3.1 results tree. So `FuseManagerConfig.Enable` was `false` (struct default).

With `Enable=false`, `cmd/containerd-stargz-grpc/main.go:278` reads
`if cleanup || !fuseManagerConfig.Enable { rs.Close() }` — the `!Enable` disjunct is
true, so **every** graceful exit tears the mounts down, SIGTERM and SIGINT alike. And a
SIGKILL leaves the FUSE connection orphaned, which is equally dead to the container.

**All three candidate signal paths converge on the same outcome when fuse_manager is off.**
The published ESTALE-under-a-live-pod result is therefore robust to which signal the
unpreserved manual command actually sent. No correction to the v3.1 finding is required.

## Consequence for the v4 axis, and for the SPE revision

- v3.1's recovery-5 maps onto exactly one cell of the v4 matrix: **fuse_manager=false +
  graceful signal** — reproduced on the v4 rig as trial **T0**, so the two runs have a
  same-rig comparator rather than only a cross-run one.
- v3.1 says **nothing** about fuse_manager-enabled behaviour, because that mode was never
  configured. Any SPE wording implying v3.1 tested it would be wrong; v4 S1 is the first
  measurement of it in this lineage.
- Safe phrasing for the revision: *"with the FUSE manager disabled (v0.18.2 default),
  restarting the snapshotter under a live pod leaves the container's mount dead — ESTALE
  at open() — while Kubernetes continues to report the pod Ready."* The clause "with the
  FUSE manager disabled (the default)" is load-bearing and must not be dropped.
- Do **not** write "v3.1 sent SIGTERM" as a bare fact. The archived scripts' default is
  SIGTERM and that is the most probable path, but the file that produced the published
  output was not generated by those scripts.

## Files cited
- `bench-results-v3.1/scripts-as-run/14-p03-mechanism-recovery.sh:29,124`
- `bench-results-v3.1/scripts-as-run/15-p05-pressure-matrix.sh:45`
- `bench-results-v3.1/scripts-as-run/05c-switch-stargz-cache-root.sh:39`
- `bench-results-v3.1/scripts-as-run/05-setup-stargz.sh:56-61`
- `bench-results-v3.1/results/identity-bundle/stargz-grpc-config.toml`
- `bench-results-v3.1/results/identity-bundle/stargz-grpc-ps.txt`
- `bench-results-v3.1/results/p03/p03-recovery-5-daemon-restart-live.txt`
- `bench-results-v3.1/RUN-REPORT-v3.1.md` §5 item 5, §10
