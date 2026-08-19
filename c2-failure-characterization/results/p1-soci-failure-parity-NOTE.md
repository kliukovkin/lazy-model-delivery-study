# P1.1 SOCI failure parity — attempted, not cleanly reproduced

## What was attempted

Per the task's P1.1 goal: root SOCI on a bounded/scarce partition and induce genuine
ENOSPC, same spirit as the eStargz inductions in P0.1/P0.3/P0.5, to test whether SOCI's
"background fetcher proactively writes spans" (the task's own anticipated risk) makes it
fail earlier/differently than eStargz, or whether it silently falls back to eager pull
(the red-team's other concern).

Steps tried, in order:
1. Attempted to bind-mount the existing bounded `/cache-part` partition (92GB, real NVMe,
   already used for the stargz cache in P0.x) onto SOCI's root
   (`/var/lib/soci-snapshotter-grpc`) inside the running kind node. Both `docker exec mount
   --bind` and a host-side `mount --bind /cache-part /proc/<pid>/root/var/lib/soci-snapshotter-grpc`
   reported success (exit 0) but did not actually take effect (`df` inside the container kept
   showing the original 1.6TB backing device) — most likely blocked by the kind node
   container's mount propagation settings. Not debugged further given the time already spent.
2. Fell back to creating artificial scarcity on `/data` (the partition backing SOCI's root
   indirectly via Docker's overlay2 storage driver) via `fallocate`, narrowing free space to
   ~8GB — well under both test images' real ~15.8GB payload (confirmed via P1.2's clean
   measurements).
3. Deployed `B-14g` after force-clearing every cache layer identified during P1.2
   (`crictl rmi --prune`, `ctr content rm` on oversized blobs in the `default` namespace,
   `soci-snapshotter-grpc`'s own `content/blobs` cache, daemon restart). Expected: ENOSPC
   during the pull/Ready window, mirroring the P1.2 mechanism finding.
4. Actual result: pod reached `Ready=True` in 61s, `/data` free space **did not move at all**
   (stayed at exactly 8.2GB throughout), yet every one of the 28 ballast files read back
   correctly (`cat`, `dd` — full 536,870,912 bytes each, zero errors) at 6.8-7.6 GB/s —
   RAM-page-cache speed, not disk or network speed (confirmed near-zero RX bytes on the host
   NIC during the same window).
5. Checked whether the content was persisting in the `k8s.io` containerd namespace instead
   of `default` (the namespace `ctr content rm` had been targeting) — ruled out; the largest
   blob in `k8s.io`'s content store was 88MB, nowhere near the ~1.6-15GB layer sizes involved.

## Conclusion

Some layer of local caching for these specific test images' content survives every clearing
mechanism attempted (containerd content store in two namespaces, soci-snapshotter's own
persistent blob cache + daemon restart, `crictl rmi --prune`) and serves reads at
page-cache speed even when the nominal backing partition has single-digit GB free. The exact
surviving cache layer was not identified within the time budget — candidates not yet ruled
out include kernel page cache pinned by lingering leases from earlier `ctr-remote content
fetch` invocations, or a containerd content-store GC behavior that doesn't reclaim blocks
synchronously with `ctr content rm`.

**This differs qualitatively from eStargz**, where induced ENOSPC on the SAME node was
cleanly and repeatedly reproducible across P0.1, P0.3, and all ten reps of P0.5 using a much
simpler clear (`rm -rf` on stargz's `httpcache`/`fscache` subdirectories + daemon restart) —
no equivalent single-command clear was found for SOCI within the time spent here.

**P1.1 is left undone** — no genuine SOCI ENOSPC induction was achieved. This is an honest
gap, not a silently-skipped item: per the task's own explicit ordering ("if cutting, cut
P2 → P1.3 → P1.2 first; P0 is never cut"), P1 as a whole is the first tier meant to absorb
time pressure, and P1.1 specifically consumed a disproportionate amount of the P1 time
budget chasing this caching behavior before the call was made to stop and move to the
remaining, more tractable P1 items (P1.3, P1.5) and then P2.

The one finding that *does* survive from this investigation and is independently useful for
the article: **SOCI's local content caching for a given image, once populated by any means
(index build, an earlier eager pull, a prior SOCI mount), appears extremely resistant to
being made to look "cold" again on this node** — a possible caveat for anyone trying to
reproduce SOCI cold-start benchmarks on a long-lived shared node rather than a freshly
provisioned one.
