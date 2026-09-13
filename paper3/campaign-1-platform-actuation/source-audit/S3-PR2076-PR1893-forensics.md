# S3 extra -- what PR #2076 and PR #1893 actually do (source-level)

Repo: github.com/containerd/stargz-snapshotter. Verified against a local clone.
Refs: main = `624678b4e421947534cbf0618f9609853cccee0f`, v0.18.2 = `3070538befb5a6c09f93e99164762b3a76310357`.

## Issue status (verified)

- **#1213** "Is there an explicit way of clearing cache?" -- CLOSED 2025-07-09T06:52:05Z, by PR **#2076**.
- **#1349** "stargz-snapshotter uses up all available disk space" -- CLOSED 2025-07-16T06:21:31Z, by PR **#1893**.

## PR #2076 -- what exactly is released

Merge commit `a744b5da80ebb525ba68a18d0ea3c05d71b76536` ("Fix TTLCache could't release
resources just after layer creation", 2025-07-09); the substantive commit is
`22f7f7164ae6432e10bb65377f16965215116f2`.

It touches `util/cacheutil/ttlcache.go`, `fs/layer/layer.go` and `fs/fs.go`. Before the fix,
the per-entry "done" callback only decremented a refcount, so the `TTLCache` map entry and
its `time.AfterFunc` timer survived until natural TTL expiry even when the layer was already
finished with. The fix threads an `evict bool` through `decreaseOnceFunc`
(`util/cacheutil/ttlcache.go:103-118`) so a caller can force `rc.t.Stop()`, `rc.finalize()`
and `delete(c.m, key)` immediately, and adds a `Close()` method on the filesystem
(`fs/fs.go:450-455`) which `Unmount()` now calls in place of `Done()`.

**What is freed is in-memory only.** `TTLCache.m` is a `map[string]*refCounterWithTimer`
(`util/cacheutil/ttlcache.go:26`); the reclaimed resources are the map entry, the per-entry
Go timer, and the referenced `*layer` / `remote.Blob` object being closed sooner. The diff
contains no `os.Remove`/`os.RemoveAll` and does not touch the on-disk directory caches.

**Therefore #1213 being closed does NOT mean a disk-cache reclaim mechanism landed.** It
makes an in-memory leak deterministic. It is not an answer to "the blob cache grows without
bound on disk".

## PR #1893 -- what root is exported, and what that root contains

Merge commit `7de6607e7fd881ce2fd6991ec5b45c89d2853747` ("Fix GC failure of CRI plugin",
2025-07-16). **The PR contains no Go code at all** -- `git show --stat` lists only
`README.md`, `docs/INSTALL.md`, `docs/overview.md`, three sample `config.toml`s and the
integration entrypoint (7 files, +17/-2). It documents adding a containerd-side stanza:

```toml
[proxy_plugins.stargz.exports]
  root = "/var/lib/containerd-stargz-grpc/"
```

with the note (`docs/overview.md:56`): "`root` field of `proxy_plugins` is needed for the CRI
plugin to recognize stargz snapshotter's root directory."

### CORRECTION to the v4 task's stated premise

The task brief says #1893 hooks up "snapshots-root ... но это snapshot-слои, НЕ
httpcache/fscache". **The path scope is wider than that.** The exported value is the
snapshotter's TOP-LEVEL root, and both trees hang off it (`service/service.go:128-133`):

```go
func snapshotterRoot(root string) string { return filepath.Join(root, "snapshotter") }  // layer snapshots
func fsRoot(root string) string          { return filepath.Join(root, "stargz") }       // httpcache + fscache
```

`fsRoot(root)` is what `stargzfs.NewFilesystem` receives (`service/service.go:120`), and the
httpcache/fscache directories are created under it (`fs/layer/layer.go:288,370`). So
`exports.root` does cover the content caches, not just the snapshot layers.

**But the correction cuts the other way on the load-bearing point.** `exports.root` is a
*reporting/accounting* field -- it tells containerd's CRI plugin where the snapshotter's data
lives so image-filesystem stats and GC bookkeeping stop failing. It is not an eviction
mechanism and it introduces no size threshold. So the right statement is not "the fix misses
httpcache/fscache" but "the fix makes the whole root *visible* to containerd's accounting
while adding nothing that *reclaims* bytes from it." (Whether that visibility reaches kubelet
as imageFs pressure is an empirical question -- measured live in this run, see RUN-REPORT S2.)

## Current main: every on-disk cache deletion path

On `main` @`624678b4`, the sole function that removes on-disk cache content is
`directoryCache.Close()` (`cache/cache.go:379-387`, `os.RemoveAll(dc.directory)`), reached by
four triggers:

1. **Resolution-error cleanup** -- `fs/layer/layer.go:292-296` and `:374-378`, deferred
   `Close()` when `Resolve`/`resolveBlob` fails before registration. Not eviction of live data.
2. **TTL expiry** -- `util/cacheutil/ttlcache.go:78-82`, `time.AfterFunc(c.ttl, ...)`, default
   TTL 120s (`fs/layer/layer.go:55,148-151`) -> `OnEvicted` -> `layer.close()` -> cache
   `Close()`. **Time-based.**
3. **Validity-check invalidation** -- explicit `Remove()` when `Check()` fails on a stale
   cached layer/blob (`fs/layer/layer.go:264-273`, `:359-368`).
4. **Snapshot lifecycle** -- `snapshot/snapshot.go:494-507` `cleanupSnapshotDirectory()` ->
   `fs.Unmount()` (`fs/fs.go:434-448`) -> forced `layerRef.Close()`
   (`fs/layer/layer.go:616-619`) -> cache `Close()`. Driven by containerd removing a snapshot.

The in-memory `*cacheutil.LRUCache` buffers (`cache/cache.go:142-164`,
`fs/layer/layer.go:219-226`) are bounded by **entry count** (`MaxLRUCacheEntry`/`MaxCacheFds`,
default 10, `cache/cache.go:34-35`), never by bytes; their eviction resets a pooled buffer or
closes an fd and leaves the on-disk file in place.

**No eviction site anywhere in `cache/`, `fs/` or `snapshot/` is driven by a disk-size,
free-space, or byte-budget threshold.**

## SHAs cited
- `624678b4e421947534cbf0618f9609853cccee0f` -- main HEAD at audit time
- `3070538befb5a6c09f93e99164762b3a76310357` -- tag v0.18.2
- `a744b5da80ebb525ba68a18d0ea3c05d71b76536` -- merge commit, PR #2076
- `22f7f7164ae6432e10bb65377f16965215116f2` -- substantive commit inside PR #2076
- `7de6607e7fd881ce2fd6991ec5b45c89d2853747` -- merge commit, PR #1893
