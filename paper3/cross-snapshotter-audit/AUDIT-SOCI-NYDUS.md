# Cross-snapshotter audit: is the lazy-pull cache failure class shared?

Read-only source audit of soci-snapshotter and Nydus (nydusd + nydus-snapshotter),
answering Q1 (on-disk byte bound, F1 analogue), Q2 (cache-write/read coupling, F2
mechanism analogue) and Q3 (restart re-adoption vs. duplication, F5 analogue).

Every claim below carries a `file:line` at the pinned commit. Claims that cannot be
established from source are marked **not determinable statically**.

---

## 0. Pinned revisions

| Repo | Tag | Commit | Tag date |
|---|---|---|---|
| `awslabs/soci-snapshotter` | `v0.15.0` | `7716bd67e813f8e80873948e0a02d0a7c5370854` | 2026-07-30 |
| `dragonflyoss/nydus` (nydusd) | `v2.4.5` | `e3190057422fee17f594bb3a5c10741b45dac6ce` | 2026-07-27 |
| `containerd/nydus-snapshotter` | `v0.15.16` | `aab11e826dd7596c1c932905aef9cd307c05e26e` | 2026-08-24 |

Latest non-prerelease tags as of 2026-09-12. Clones at
`$PROJECT/audit/`.

Nydus is audited in two modes, which differ materially and are answered separately:

- **RAFS-userspace mode** — nydusd FUSE daemon, `filecache` blob cache
  (`storage/src/cache/filecache/mod.rs`), snapshotter `daemon.fs_driver = "fusedev"`.
- **EROFS-over-fscache mode** — nydusd populates kernel `cachefiles` backing files
  (`storage/src/cache/fscache/mod.rs`, `service/src/fs_cache.rs`),
  `daemon.fs_driver = "fscache"`.

Throughout, "the cache" means the snapshotter's own content cache, **not** containerd's
content store. SOCI's containerd content-store usage is configured separately
(`config/fs.go:209`, `config/fs.go:213`) and is out of scope; nydus-snapshotter's blob
cache (`cache_manager.cache_dir`, `config/config.go:196`) is likewise distinct from the
containerd content store.

---

## 1. SURPRISES — things that cut against paper 3's current framing

Ordered by how much they change what the paper can claim.

### S1. Nydus RAFS mode **decouples** cache-write failure from read failure. The class is not universal.

This is a genuine counter-example, and the strongest single result in this audit.

In `read_single_chunk`, nydusd fetches the chunk from the backend into an in-memory
buffer, hands the cache write to an **asynchronous** worker, and then serves the reader
**from the in-memory buffer**, not from the cache:

```rust
// storage/src/cache/cachedfile.rs:1478-1487
            } else {
                buffer_holder = Arc::new(d.convert_to_owned_buffer());
                self.delay_persist_chunk_data(chunk.clone(), buffer_holder.clone());
                buffer_holder.as_ref()
            }
        };

        let dst_buffers = mem_cursor.inner_slice();
        let read_size = copyv(
            &[buffer.slice()],
```

`delay_persist_chunk_data` dispatches to a thread pool and never returns a result to the
caller (`storage/src/cache/cachedfile.rs:252`, `self.runtime.spawn_blocking(move || {`).
The write's only consequence is a readiness bit:

```rust
// storage/src/cache/cachedfile.rs:300-306
            let res = Self::persist_cached_data(&file, offset, buf);
            Self::_update_chunk_pending_status(
                &delayed_chunk_map,
                chunk.as_ref(),
                res.is_ok(),
                &metrics,
            );
```

An ENOSPC therefore costs a cache entry, not a read. This is **serve-then-cache**, the
design paper 3 argues for, already shipping in a production lazy-pull snapshotter.

**Consequence for the manuscript:** F2 cannot be presented as an intrinsic property of
lazy pulling. It is a property of a *read-through* cache placement, and at least one
major implementation does not make that choice. Paper 3's design test sharpens
accordingly: the contribution is not "we noticed reads can fail", it is "stargz and SOCI
put the cache write on the delivery path, and here is the bound + decoupling that fixes
it" — with Nydus as existence proof that decoupling is compatible with the workload.

### S2. SOCI shares F2, but the mechanism is **not** `io.MultiWriter` — and the coupling is strictly stronger.

SOCI has no `io.MultiWriter` on any read path (`grep -rn 'MultiWriter\|TeeReader'` over
non-test Go yields only `util/testutil/tar.go:201`, `util/testutil/shell.go:141-142`,
`util/testutil/ensurehello.go:70`, `fs/unpacker.go:139,207`). It has no cache in
`fs/remote/blob.go` at all — the stargz file paper 3 cites (`fs/remote/blob.go:534`) has
no SOCI analogue, because SOCI removed the blob-level cache and caches *spans* instead.

The coupling is in `fetchAndCacheSpan`. The span is already fully fetched, decompressed
and resident in `buf`; the function then throws that buffer away if the cache write
fails:

```go
// fs/span-manager/span_manager.go:389-392
	// cache span data
	if err := m.addSpanToCache(spanID, buf); err != nil {
		return nil, err
	}
```

`io.MultiWriter` at least delivers the prefix written before the error. SOCI delivers
nothing: data that reached the node successfully is discarded because a *different*
device was full.

**Consequence for the manuscript:** F2 should be stated as a *placement* property —
"the cache write is on the delivery path" — with `io.MultiWriter` as stargz's
instance and `fetchAndCacheSpan`'s error return as SOCI's. Naming the mechanism after
`io.MultiWriter` understates the class and makes the SOCI case look like a different
finding when it is the same one.

### S3. SOCI's restart duplication is worse than stargz's, and for a different reason.

Paper 3's F5 is about a FUSE manager whose graceful restart duplicates cache contents.
SOCI has no FUSE-manager analogue at all; its duplication is unconditional and structural:

- The span cache directory is `os.MkdirTemp` — a **fresh random directory per layer
  resolution**, under `<root>/spancache` (`fs/layer/layer.go:227`, called from
  `fs/layer/layer.go:286`). Nothing derives the path from the layer digest, so nothing
  can ever find a previous run's cache.
- On restart, `restoreRemoteSnapshot` force-unmounts every existing mount and re-prepares
  every remote snapshot (`snapshot/snapshot.go:*`, entry at the `restoreRemoteSnapshot`
  definition; the unmount loop is the first statement of the function), which drives a
  fresh `Resolve` → fresh `MkdirTemp` for every layer.
- The old directories are not swept. `grep -rn 'spancache'` over non-test Go returns
  exactly four sites (`fs/span-manager/span_manager.go:497`, `fs/layer/layer.go:286`,
  `:292`, `:373`) — there is **no startup scan** of `<root>/spancache`.

Worse, on `SIGTERM` the daemon does not even run its in-process cleanup. Only `SIGINT`
requests cleanup:

```go
// cmd/soci-snapshotter-grpc/main.go:320-323
	if s == unix.SIGINT {
		return true, nil // do cleanup on SIGINT
	}
	return false, nil
```

and that boolean gates the only `Close()` call (`cmd/soci-snapshotter-grpc/main.go:211`,
`:217`, `:219`). `systemctl restart` / `stop` sends `SIGTERM`, and the shipped unit
(`soci-snapshotter.service`) sets no `KillSignal`. Even on `SIGINT`, `snapshotter.Close()`
unmounts snapshots and closes the metadata store (`snapshot/snapshot.go:1003-1013`) but
never reaches the layer resolver — `Resolver` has no `Close` method at all — so the span
cache directories are never removed on exit under any signal.

Net: **every** daemon restart orphans the entire span cache tree and starts a new one.
Not "up to N GB per restart under a corrected unit" as in stargz, but the whole
steady-state working set, every time, with the stock unit.

### S4. Nydus is the only one of the three that **re-adopts** its cache across restarts.

The blob cache file path is deterministic, derived from the blob id:

```rust
// storage/src/cache/filecache/mod.rs:232
        let blob_file_path = format!("{}/{}", mgr.work_dir, blob_id);
```

and it is reopened, not recreated (`storage/src/cache/filecache/mod.rs:264-269`:
`.create(true).truncate(false).write(true).read(true)`). Readiness survives too: the
chunk map is an mmap'd bitmap file that is *not* truncated on open in filecache mode
(`storage/src/cache/state/persist_map.rs:56-60`, `.truncate(!persist)` with
`persist = true` from `storage/src/cache/filecache/mod.rs:262` via
`IndexedChunkMap::new(..., true)`).

This directly contradicts any generalization of F5 to "lazy-pull snapshotters duplicate
cache on restart". Paper 3 should say *stargz and SOCI* duplicate; Nydus does not, and
name the mechanism that makes the difference (content-addressed path + persisted
readiness bitmap), because that is precisely the design paper 3 wants to advocate.

### S5. Both projects ship a cache-management config key that does nothing.

- **SOCI `http_cache_type`** — declared at `config/fs.go:49`, shipped in the sample
  config at `config/config.toml:1`, and read by nothing. `grep -rn 'http_cache_type\|HTTPCacheType'`
  over the whole repo returns exactly those two lines.
- **nydus-snapshotter `cache_manager.gc_period`** — declared at
  `config/config.go:195` with the doc comment `// Trigger GC gc_period after the specified period.`
  (`config/config.go:193`), defaulted to 24h (`config/default.go:50-51`), threaded into the
  cache manager at `snapshot/snapshot.go:221` and stored at `pkg/cache/manager.go:56`.
  The field `Manager.period` (`pkg/cache/manager.go:36`) and the companion
  `Manager.eventCh` (`:37`) are **never read anywhere** — `grep -rn '\.period\|\.eventCh'`
  over non-test Go in `pkg/` returns no hits. There is no ticker, no goroutine, no GC.

This is a sharper version of F1 than "no key bounds bytes". The key surface does not
merely omit a bound — it advertises periodic cache GC that is not implemented. An
operator reading `gc_period = 24h` has every reason to believe the cache is managed.

---

## 2. soci-snapshotter v0.15.0

### Q1 — Disk-byte bound (F1 analogue)

**Verdict: no key bounds bytes on disk. Confirmed, same shape as stargz.**

**Key surface.** `config/` declares 85 `toml:` tags (non-test). Subtracting 18 section
containers (`config/fs.go:59,60,62,64,66,68,70`; `config/service.go:40,43,46,49,52`;
`config/pull_modes.go:22,23,24`; `config/parallel.go:60`; `config/resolver.go:43,62`) and
one explicitly-excluded field (`config/parallel.go:54`, `toml:"-"`) leaves **66 tagged
leaf keys**. Six further keys are live but **untagged**, decoding under their PascalCase
Go field names inside `[http]` — `DialTimeoutMsec`, `ResponseHeaderTimeoutMsec`,
`RequestTimeoutMsec` (`config/fs.go:180,183,186`) and `MaxRetries`, `MinWaitMsec`,
`MaxWaitMsec` (`config/fs.go:167,170,173`), confirmed by the shipped sample
(`config/config.toml:18-24`).

**Total: 72 leaf keys** (71 distinct TOML paths — `no_prometheus` is declared twice, at
`config/config.go:67` and `config/fs.go:55`). Directly comparable to stargz's 74.

**Every key matching cache/size/limit/gc/quota/max/bytes/disk/evict/threshold:**

| Key | Declared | Bounds what | Enforcement |
|---|---|---|---|
| `directory_cache.max_lru_cache_entry` | `config/fs.go:102` | **in-memory LRU entries** (default 10) | `cache/cache.go:49` (`defaultMaxLRUCacheEntry = 10`), applied `fs/layer/layer.go:201-203`; eviction callback only resets a `bytes.Buffer` and returns it to a pool (`fs/layer/layer.go:216-219`) |
| `directory_cache.max_cache_fds` | `config/fs.go:103` | **open file descriptors** (default 10) | `cache/cache.go:50`, applied `fs/layer/layer.go:205-207`; eviction callback only calls `value.(*os.File).Close()` (`fs/layer/layer.go:220-222`) |
| `resolve_result_entry` | `config/fs.go:51` | **number of resolved layers** retained (default 30) | `fs/layer/layer.go:82,144-146,152`; see "the one real bound" below |
| `filesystem_cache_type` | `config/fs.go:50` | selects cache backend | `fs/layer/layer.go:196-198`; `"memory"` selects `cache.NewMemoryCache()` — a plain `map[string]*bytes.Buffer` with **no eviction at all** (`cache/cache.go:386-424`) |
| `http_cache_type` | `config/fs.go:49` | nothing — dead key | see S5 |
| `directory_cache.sync_add` | `config/fs.go:104` | write timing, not size | `cache/cache.go:64,180` |
| `directory_cache.direct` | `config/fs.go:105` | bypasses in-memory cache | `cache/cache.go:79-80`, `fs/layer/layer.go:238` |
| `background_fetch.max_queue_size` | `config/fs.go:151` | **work-queue length** (default 300, `config/defaults.go:76`) | applied `config/fs.go:268-270`. Note the doc comment at `config/fs.go:150` says "Default: 100" — stale |
| `snapshotter.min_layer_size` | `config/service.go:77` | which layers are lazily mounted | `config/service.go:76` |
| `pull_modes.parallel_pull_unpack.discard_unpacked_layers` | `config/parallel.go:62` | deletes decompressed blobs post-unpack in the *eager* parallel-pull path — not the lazy cache | — |
| `pull_modes.parallel_pull_unpack.concurrent_download_chunk_size` | `config/parallel.go:53` | bytes **per network read**, not stored bytes | default `-1` = unbounded, `config/defaults.go:151` |
| `max_concurrency`, `prefetch.max_concurrency`, `max_concurrent_*` | `config/fs.go:54,82`; `config/parallel.go:50,51,56,57` | concurrency slots | — |

**Keys that bound bytes on disk: NONE.**
**Keys that bound in-memory entries / FDs:** `directory_cache.max_lru_cache_entry`,
`directory_cache.max_cache_fds`, `resolve_result_entry`, `background_fetch.max_queue_size`.

**No disk-space awareness anywhere.** `grep -rniE 'enospc|no space|statfs|freespace'`
over non-test Go finds no ENOSPC handling and no free-space check in the cache path.
`fs.DiskUsage` appears only in snapshot accounting (`snapshot/snapshot.go:311`,
`:579-580`), and remote snapshots are explicitly skipped there
(`snapshot/snapshot.go:579`: `if !isRemote { // skip diskusage for remote snapshots ...`).

**Critically, LRU eviction never deletes a cache file.** Committed spans are `os.Rename`d
into the cache directory (`cache/cache.go:299`) and the only code that removes them is a
wholesale `os.RemoveAll` of the entire directory on `Close`:

```go
// cache/cache.go:361-369
func (dc *directoryCache) Close() error {
	dc.closedMu.Lock()
	defer dc.closedMu.Unlock()
	if dc.closed {
		return nil
	}
	dc.closed = true
	return os.RemoveAll(dc.directory)
}
```

So `max_lru_cache_entry = 10` bounds a memory index in front of an unbounded on-disk tree.

**The one real bound, and it is not in bytes.** `resolve_result_entry` (default 30,
`fs/layer/layer.go:82`) is a refcounted LRU of *resolved layers*
(`fs/layer/layer.go:152`); its eviction callback closes the layer
(`fs/layer/layer.go:153-158`) → `layer.close()` (`fs/layer/layer.go:523-535`) →
`reader.Close()` (`fs/reader/reader.go:124,132`) → `SpanManager.Close()`
(`fs/span-manager/span_manager.go:495-505`) → `cache.Close()` → the `RemoveAll` above.
Because `util/lrucache` defers `OnEvicted` until the refcount reaches zero
(`util/lrucache/lrucache.go:43-44`, `:141-149`), a mounted layer is never wiped underneath
a running container.

This yields a bound of the form *(number of idle resolved layers) × (arbitrary layer
size)* — a lifecycle bound in units of layers, with no relationship to the size of the
volume. It is nonetheless a real structural difference from stargz worth stating in the
paper: SOCI does reclaim a layer's cache when the layer falls out of the resolve LRU and
is unreferenced, whereas stargz's cache directories are cleaned only per-layer on image
removal.

### Q2 — Write-failure coupling (F2 mechanism analogue)

**Verdict: read-through-then-serve. A cache write failure vetoes the read. Confirmed.**

Full chain, all on the synchronous FUSE read path:

1. `file.Read` → `f.ra.ReadAt` → EIO on any error:
   ```go
   // fs/layer/node.go:586-590
   	n, err := f.ra.ReadAt(dest, off)
   	if err != nil && err != io.EOF {
   		f.n.fs.reportFailure(fuseOpFileRead, fmt.Errorf("%s: %w", fuseOpFileRead, err))
   		return nil, syscall.EIO
   	}
   ```
2. `fs/reader/reader.go:175-178` — `GetContents` error is returned verbatim.
3. `SpanManager.GetContents` runs `getSpanContent` per span in an errgroup and fails the
   whole read if any span fails (`fs/span-manager/span_manager.go:241-244`).
4. `getSpanContent` on a cache miss calls `fetchAndCacheSpan`
   (`fs/span-manager/span_manager.go:343`), and on the *fetched-but-not-uncompressed*
   path calls `addSpanToCache` directly, again returning on error
   (`fs/span-manager/span_manager.go:331-333`).
5. **The decisive lines** — data is in hand, then discarded:
   ```go
   // fs/span-manager/span_manager.go:389-392
   	// cache span data
   	if err := m.addSpanToCache(spanID, buf); err != nil {
   		return nil, err
   	}
   ```
6. `addSpanToCache` surfaces the write error, as its own doc comment states:
   ```go
   // fs/span-manager/span_manager.go:449-462
   // addSpanToCache adds contents of the span to the cache.
   // A non-nil error is returned if the data is not written to the cache.
   func (m *SpanManager) addSpanToCache(spanID compression.SpanID, contents []byte) error {
   	w, err := m.cache.Add(fmt.Sprintf("%d", spanID), m.cacheOpt...)
   	if err != nil {
   		return err
   	}
   	defer w.Close()

   	_, err = w.Write(contents)
   	if err != nil {
   		w.Abort()
   		return err
   	}
   ```

**Where ENOSPC lands.** The span cache is constructed in *direct* mode unconditionally —
the option is passed at the call site, independent of the `directory_cache.direct` config
key:

```go
// fs/layer/layer.go:373
	spanManager, err := spanmanager.New(ztoc, sr, spanCache, r.config.BlobConfig.MaxSpanVerificationRetries, desc.Digest, cache.Direct())
```

In direct mode `directoryCache.Add` returns the raw work-in-progress `*os.File` writer
(`cache/cache.go:309-311`, returning `w` built at `cache/cache.go:282-284` from
`dc.wipFile(key)` = `os.CreateTemp`, `cache/cache.go:382-384`). Therefore
`w.Write(contents)` at `fs/span-manager/span_manager.go:458` is a synchronous write to
the cache volume and returns ENOSPC directly. A full cache volume fails reads of
already-mounted images with `EIO`.

Two secondary observations that qualify the severity, both differences from stargz's F2:

- **No poisoned cache entry.** On write failure `w.Abort()` runs
  (`fs/span-manager/span_manager.go:460`), which is `os.Remove(wip.Name())`
  (`cache/cache.go:302-304`); `Commit` (the `os.Rename` at `cache/cache.go:299`) never
  runs. No truncated span is ever published.
- **Self-healing.** The span state is rolled back to `unrequested` on any error
  (`fs/span-manager/span_manager.go:364-368`), so reads recover once space is freed.

So SOCI's F2 analogue presents as hard, repeatable `EIO` for the duration of the
exhaustion rather than as stargz's silent tail truncation. Whether SOCI also exhibits
stargz's *health-check blindness* (F2's bias toward cached heads) is **not determinable
statically** — it depends on which spans happen to be resident, which is a runtime
property.

`w.Commit()`'s error is discarded at `fs/span-manager/span_manager.go:464`, contradicting
the function's doc comment at `:450`. In direct mode this is harmless (Commit is only the
rename); in non-direct mode it would drop a real write error. Since the span manager is
always direct (`fs/layer/layer.go:373`), the live path is the coupled one.

### Q3 — Restart behavior (F5 analogue)

**Verdict: duplication and orphaning on every restart. No re-adoption. See S3.**

Citations consolidated:

- Per-resolution random cache directory: `fs/layer/layer.go:227` (`os.MkdirTemp(root, "")`),
  root `<snapshotter root>/spancache` at `fs/layer/layer.go:286`.
- No startup sweep: the only non-test references to `spancache` are
  `fs/layer/layer.go:286,292,373` and `fs/span-manager/span_manager.go:497`.
- Restart re-mounts everything, driving fresh resolutions: `restoreRemoteSnapshot`
  (called at `snapshot/snapshot.go:240-241`) force-unmounts all snapshot mountpoints and
  then calls `prepareRemoteSnapshot` for each remote snapshot.
- Exit performs no cache cleanup: `cmd/soci-snapshotter-grpc/main.go:320-323` (only
  `SIGINT` requests cleanup), gating `rs.Close()` at
  `cmd/soci-snapshotter-grpc/main.go:217-219`; `snapshotter.Close()`
  (`snapshot/snapshot.go:1003-1013`) unmounts and closes the metadata store only.
- The shipped unit sets no `KillSignal`/`KillMode` (`soci-snapshotter.service`,
  `[Service]` block), so `systemctl restart` delivers `SIGTERM` — the no-cleanup branch.

Mounts themselves are re-established rather than preserved: SOCI has no detached
FUSE-manager analogue of stargz's, so there is no F5-style "shipped remediation defeats
itself" finding here. The `snapshotter.allow_invalid_mounts_on_restart` key
(`config/service.go:83`) governs whether a failed restore is fatal or merely warned about
(`snapshot/snapshot.go`, the `o.allowInvalidMountsOnRestart` branch inside
`restoreRemoteSnapshot`).

---

## 3. Nydus — RAFS userspace mode (nydusd v2.4.5 `filecache` + nydus-snapshotter v0.15.16 `fusedev`)

### Q1 — Disk-byte bound (F1 analogue)

**Verdict: no key bounds bytes on disk, in either repo. A byte-bound GC does NOT exist.**

The task asked specifically whether `blob_cache_gc` / work-dir GC constitutes a byte
bound. It does not, in either component. Detail below.

**nydusd cache config surface** (`api/src/config.rs`, `CacheConfigV2` at `:643`):

| Key path | Declared | Bounds what |
|---|---|---|
| `cache.type` | `api/src/config.rs:646` | backend selection (`"blobcache"`/`"fscache"`/`"dummy"`) |
| `cache.compressed` | `api/src/config.rs:649` | store raw vs. plaintext. Doc: `/// Whether the data from the cache is compressed, not used anymore.` (`:648`). Default `false`. **Load-bearing for Q2 — see below** |
| `cache.validate` | `api/src/config.rs:652` | digest validation on read |
| `cache.filecache.work_dir` | `api/src/config.rs:752` | cache **location** |
| `cache.filecache.disable_indexed_map` | `api/src/config.rs:755` | chunk-map implementation |
| `cache.filecache.enable_encryption` | `api/src/config.rs:758` | at-rest encryption |
| `cache.filecache.enable_convergent_encryption` | `api/src/config.rs:761` | dedup-compatible encryption |
| `cache.filecache.encryption_key` | `api/src/config.rs:764` | key material |
| `cache.fscache.work_dir` | `api/src/config.rs:796` | cache location (fscache mode) |
| `cache.prefetch.{enable,threads,batch_size,bandwidth_limit,prefetch_all,stream_prefetch}` | `api/src/config.rs:880,883,886,889,892,901` | prefetch concurrency / **network** bandwidth / per-request batch bytes — none is a stored-bytes bound |

`rafs.batch_size` (`api/src/config.rs:831`) is an IO amplification size, not a cache bound.

**Keys that bound bytes on disk: NONE.** An independent sweep for
`quota|max_size|size_limit|disk_limit|capacity_limit|high_water|low_water|bcull|brun`
over `storage/`, `service/`, `api/`, `src/` returns only IO-merge sizes
(`storage/src/cache/mod.rs:115,173,179`, `storage/src/meta/mod.rs:672,1001,1320`) and an
SQLite pool size (`storage/src/cache/dedup/db.rs:30`). `ENOSPC`, `NoSpace`, `gc_interval`,
`punch_hole`, `FALLOC_FL_PUNCH_HOLE`, `disk_usage` have zero hits anywhere in the repo.

The code says so explicitly:

```rust
// utils/src/metrics.rs:725-727
    // Scale of blobcache. Blobcache does not evict entries.
    // Means the number of chunks in ready status.
    pub entries_count: BasicMetric,
```

**`blob_cache_gc` is not a GC.** It is a single-blob delete API, caller-driven:

```rust
// src/bin/nydusd/api_server_glue.rs:317-322
    fn blob_cache_gc(&self, blob_id: String) -> ApiResponse {
        self.get_daemon_object()?
            .delete_blob(blob_id)
            .map_err(|e| ApiError::DaemonAbnormal(e.into()))
            .map(|_| ApiResponsePayload::Empty)
    }
```

The default `delete_blob` is a no-op (`service/src/daemon.rs:189-192`); the only
implementation is fscache-specific (`service/src/singleton.rs:232-241`, see §4). In RAFS
filecache mode there is **no** nydusd-side deletion path at all: no timer, no threshold,
no size trigger, synchronous or otherwise.

**nydus-snapshotter side.** `cache_manager.cache_dir` (`config/config.go:196`, defaulted
to `<root>/cache` at `config/global.go:167-170`) is wired to
`device.cache.config.work_dir` (`config/daemonconfig/daemonconfig.go:124`). The only
reclamation is `snapshotter.Cleanup` (`snapshot/snapshot.go:322-365`), which is
**triggered externally by containerd's snapshotter GC**, not by a timer or a disk
threshold, and is gated purely on liveness:

```go
// snapshot/snapshot.go:346-358 (excerpt)
	cleanup, err = o.getUnusedCacheBlobs(ctx)
	...
	for _, blob := range cleanup {
		...
		if err := o.fs.RemoveCache("sha256:" + blob); err != nil {
```

`getUnusedCacheBlobs` (`snapshot/snapshot.go:1453-…`) walks live daemons' RAFS instances
and treats anything referenced — or anything whose usage is *unknown* — as in use
(`snapshot/snapshot.go:1483-1491`, returning `nil, nil` when knowledge is incomplete). No
size or quota check gates it anywhere in the chain to `pkg/cache/manager.go:100-123`.

Cache size is **observed but not acted on**: `pkg/metrics/collector/snapshotter.go:36-40`
exports a Prometheus gauge from `fs.DiskUsage(ctx, s.cacheDir)`; nothing reads it back.
This is the F4 shape — accounting without an actuator — inside the snapshotter itself.

And `cache_manager.gc_period` is dead (S5).

**Sparse pre-allocation note, relevant to any F4-style accounting argument.** The cache
file is `set_len` to the full uncompressed blob size at open
(`storage/src/cache/filecache/mod.rs:276-277`), so it is a sparse file whose apparent
size (`stat` st_size) is the whole layer while its allocated size (`du`) tracks only
fetched chunks. Any node-level accounting that samples apparent size will wildly
over-report; anything sampling allocated blocks will be correct. Worth one sentence in
the paper — it is a concrete instance of the accounting/actuator misalignment F4 is about.

### Q2 — Write-failure coupling (F2 mechanism analogue)

**Verdict: serve-then-cache in the default configuration. A cache write failure cannot
fail a read. See S1 for the decisive quote.**

The chain is: `read_iter` (`storage/src/cache/cachedfile.rs:1121`) →
`dispatch_one_range` (`:1151`) → for a chunk not present, `RegionType::Backend`
(`:1237`) → either `read_single_chunk` (`:1421`) or the multi-chunk region path
(`:1366-1416`). In both, the user's buffer is filled by `copyv` from the **in-memory**
fetch buffer (`:1402` and `:1486`), and the cache write goes through
`delay_persist_chunk_data` (`:1395`, `:1469`, `:1474`, `:1480`), which is
`self.runtime.spawn_blocking` (`:252`) and returns nothing.

Where the write result is consumed at all, it only sets a readiness bit:
`persist_chunk_data` (`:319-322`) discards `res` into
`update_chunk_pending_status(chunk, res.is_ok())`, and
`_update_chunk_pending_status` on failure merely logs
`"Failed to persist data for chunk at offset {}"` (`:382-386`).

The prefetch/fetch path behaves the same: `do_fetch_chunks` (`:975`) calls
`persist_chunk_data` at `:1054` and `:1094` without inspecting the result and returns
`Ok(())` (`:1100`).

**The one coupled path, and it is off by default.** When `is_raw_data` is set, the
multi-chunk region path persists *synchronously* and propagates the error before any
data is copied to the user:

```rust
// storage/src/cache/cachedfile.rs:1378-1385
        if self.is_raw_data {
            let res =
                Self::persist_cached_data(&self.file, region.blob_address, bufs.compressed_buf());
            for chunk in region.chunks.iter() {
                self.update_chunk_pending_status(chunk.as_ref(), res.is_ok());
            }
            res?;
        }
```

`is_raw_data` comes from `mgr.cache_raw_data` (`storage/src/cache/filecache/mod.rs:364`),
which is `config.cache_compressed` (`storage/src/cache/filecache/mod.rs:79`), i.e. the `cache.compressed` TOML/JSON key
(`api/src/config.rs:649`). It is `#[serde(default)]` → **false**, and its own doc comment
says `not used anymore` (`api/src/config.rs:648`). nydus-snapshotter exposes it as
`device.cache.compressed` (`config/daemonconfig/daemonconfig.go:122`, `omitempty`) and
never sets it.

So: **Nydus RAFS mode as shipped is decoupled; enabling a deprecated key re-couples it.**
That is a clean, citable data point for the paper — the decoupling is a design choice
someone made, and the one path that skipped it is the legacy one.

### Q3 — Restart behavior (F5 analogue)

**Verdict: re-adoption, not duplication. See S4.**

- Deterministic path: `storage/src/cache/filecache/mod.rs:232`.
- Reopen without truncation: `storage/src/cache/filecache/mod.rs:264-266`.
- Size consistency check on reopen — a mismatched cache file is rejected rather than
  silently reused (`storage/src/cache/filecache/mod.rs:278-284`).
- Readiness persists: `IndexedChunkMap::new(..., true)` in `create_chunk_map`
  (`storage/src/cache/filecache/mod.rs:394-398`) → `PersistMap::open(&filename, chunk_count, true, persist)`
  (`storage/src/cache/state/indexed_chunk_map.rs:37-41`) → `.truncate(!persist)`
  (`storage/src/cache/state/persist_map.rs:59`), i.e. **not** truncated. Corrupt or
  wrong-sized maps are rejected (`storage/src/cache/state/persist_map.rs:81-86`).
- Snapshotter-side recovery is state-store driven (`pkg/manager/manager.go:124-134`
  `Recover` → `recoverDaemons` `:331` → `recoverRafsInstances` `:176`), and the cache
  directory is a fixed path (`config/global.go:167-170`), so the same `work_dir/blob_id`
  files are found again.
- Live-daemon death is handled by policy `restart` (default,
  `config/default.go:44`) or `failover` (`pkg/manager/daemon_event.go:60-69`); neither
  relocates the cache directory.

**Caveat, stated as a limit of static analysis:** whether a *crashed* nydusd can leave the
persisted chunk map marking a chunk ready whose data never reached stable storage is
**not determinable statically** — `persist_cached_data` uses `pwrite`
(`storage/src/cache/cachedfile.rs:337`) with no `fsync` before the map bit is set
(`:300-306`), so the ordering across a power loss depends on filesystem semantics, not on
code in this repo. On a clean process restart (the F5 scenario) this does not arise.

---

## 4. Nydus — EROFS-over-fscache mode (nydusd v2.4.5 `fscache` + nydus-snapshotter `fscache`)

### Q1 — Disk-byte bound (F1 analogue)

**Verdict: nydusd and nydus-snapshotter impose no byte bound. A byte bound DOES exist,
but it is the Linux kernel's `cachefiles` culling, configured entirely outside both
repos.**

This is the one place in the audit where a real on-disk byte bound appears, so it is
worth characterizing precisely.

**Who enforces it.** Not nydusd. In fscache mode the backing files are owned by the
kernel `cachefiles` subsystem; nydusd only populates ranges on demand. The only
nydusd-side deletion is an explicit, named-blob cull, reached from the HTTP API:

```rust
// service/src/singleton.rs:232-241
    fn delete_blob(&self, _blob_id: String) -> Result<()> {
        #[cfg(target_os = "linux")]
        if self.fscache_enabled.load(Ordering::Acquire) {
            if let Some(fscache) = self.fscache.lock().unwrap().clone() {
                return fscache
                    .cull_cache(_blob_id)
                    .map_err(|e| Error::StartService(format!("{}", e)));
            }
        }
        Err(Error::Unsupported)
    }
```

`cull_cache` (`service/src/fs_cache.rs:758-816`) scans the cache dir for the volume
directories, resolves the cookie path for that one blob, checks `inuse`
(`service/src/fs_cache.rs:792-800`) and issues a `cull` command to `/dev/cachefiles`
(`service/src/fs_cache.rs:904-907`, writing `format!("cull {}", cookie_name)`). It is
per-blob and caller-triggered: **no threshold, no interval, no total-usage input.**

**Granularity and enforcement of the real bound.** Automatic capacity reclamation is
`cachefilesd`'s, keyed on the *whole filesystem's* free space and free inodes
(`brun`/`bcull`/`bstop`, `frun`/`fcull`/`fstop` in `/etc/cachefilesd.conf`), and the
kernel culls **entire cache objects** (whole blob files), asynchronously, on a
free-space watermark — not per-chunk, and not on any signal from nydusd. The nydus docs
treat it purely as a prerequisite to install and start, documenting no tuning
(`docs/nydus-fscache.md:65-73`), and the nydusd config for fscache mode carries only
`cache_type` and `work_dir` (`docs/nydus-fscache.md:115-125`,
`api/src/config.rs:793-796`).

Neither repo references `cachefilesd.conf`, `brun`, `bcull`, or any culling parameter —
grep for `cachefilesd|brun|bcull|bstop|culling` over both repos returns only the five
doc lines above. **The bound exists, is coarse (whole blobs), is asynchronous, is keyed
to whole-filesystem watermarks rather than to the snapshotter's own usage, and is
configured outside the software under audit.**

**nydus-snapshotter cannot even observe it.** The code says so:

```go
// pkg/cache/manager.go:67-70
// Report each blob disk usage
// TODO: For fscache cache files, the cache files are managed by nydusd and Linux kernel
// We don't know how it manages cache files. A method to address this is to query nydusd.
// So we can't report cache usage in the case of fscache now
```

and in fscache mode removal is delegated to nydusd's API rather than direct unlink
(`pkg/filesystem/fs.go:812-823`).

For the paper's table this is a genuine "yes, but" — it should be reported as a bound
with the enforcer named, not scored as equivalent to an in-process byte budget.

### Q2 — Write-failure coupling (F2 mechanism analogue)

**Verdict: neither. There is no "serve" path to decouple from — the cache file *is* the
delivery channel — and a failed populate is not reported to the kernel.**

The kernel asks nydusd to populate a range; nydusd fetches and writes; nydusd
acknowledges. The acknowledgement is unconditional:

```rust
// service/src/fs_cache.rs:704-707, 754-756
                            if let Err(e) = obj.fetch_range_uncompressed(msg.off, msg.len) {
                                error!("fscache: failed to read data from blob object: {}", e,);
                            }
...
        if let Err(e) = unsafe { fscache_cread(fd as i32, hdr.msg_id as u64) } {
            warn!("failed to send reply for cread request, {}", e);
        }
```

The fetch error at `:705` is logged and dropped; `fscache_cread`
(`service/src/fs_cache.rs:39`, `ioctl_write_int!(fscache_cread, 0x98, 1)`) then fires at
`:754` regardless. And `fetch_range_uncompressed` itself would not report a write failure
anyway — it ends in `do_fetch_chunks` (`storage/src/cache/cachedfile.rs:942`), whose
persist failures are swallowed into readiness bits (`:1054`, `:1094`) and which returns
`Ok(())` (`:1100`).

So on ENOSPC the reader is told neither "error" nor given fetched data. **What the
application observes is decided kernel-side and is not determinable statically from
these repos.** I am not going to guess between "short read", "zero-fill", and "re-issued
request"; establishing it requires the `cachefiles`/EROFS kernel sources or a rig, both
out of scope here.

What *can* be said from these sources, and is worth saying: this is a third distinct
shape, neither stargz/SOCI's "write failure vetoes the read" nor Nydus-RAFS's "write
failure costs a cache entry". It is "write failure is invisible to both the reader and
the kernel". For a paper about *honest* lazy pulling that is a pointed finding, because
the dishonesty is structural rather than incidental.

### Q3 — Restart behavior (F5 analogue)

**Verdict: re-adoption, with readiness rebuilt from the file's real extents rather than
trusted from a persisted map.**

fscache mode deliberately does **not** persist its chunk map:

```rust
// storage/src/cache/fscache/mod.rs:278-283
        let chunk_map = Arc::new(BlobStateMap::from(IndexedChunkMap::new(
            &format!("{}{}", blob_file_path, BLOB_DATA_FILE_SUFFIX),
            blob_info.chunk_count(),
            false,
        )?));
        Self::restore_chunk_map(blob_info.clone(), file.clone(), &meta, &chunk_map);
```

`persist = false` → `.truncate(!persist)` = truncate (`storage/src/cache/state/persist_map.rs:60`, via
`storage/src/cache/state/indexed_chunk_map.rs:37-41`),
so the map is reset at every open. It is then rebuilt by walking the backing file's holes:

```rust
// storage/src/cache/fscache/mod.rs:344-350
            let hole_offset = unsafe {
                libc::lseek64(
                    file.as_raw_fd(),
                    blob_meta.get_uncompressed_offset(i as usize) as i64,
                    libc::SEEK_HOLE,
                )
            };
```

with ready ranges set from the gaps between holes (`storage/src/cache/fscache/mod.rs:365-368`,
`:385-390`). `restore_chunk_map` exists only here — `grep -rn 'restore_chunk_map\|SEEK_HOLE'`
over `storage/` returns only `fscache/mod.rs:283,328,348`.

This is the right design given §4-Q1: because the kernel can cull whole blob files behind
nydusd's back, a persisted readiness map would go stale, so fscache mode makes the file's
own extent layout the source of truth at open time. **No duplication, no orphaning, and
no stale-readiness hazard across restarts.**

Note the asymmetry with RAFS mode (§3-Q3), which *does* trust a persisted map. That is
sound there only because nothing outside nydusd deletes from `work_dir`. Whether a
mid-session cull of an *open* blob file would leave a live fscache-mode instance with
stale ready bits — culling is supposed to skip in-use objects, checked at
`service/src/fs_cache.rs:792-800` for nydusd's own culls but not for `cachefilesd`'s — is
**not determinable statically** from these repos.

---

## 5. Draft comparison table for the manuscript

| System (pinned) | On-disk byte bound? | Cache-write failure can fail a read? | Restart re-adoption? | Evidence |
|---|---|---|---|---|
| **stargz-snapshotter v0.18.2** | **No.** 74 config keys, none size-related; the two cache-sizing knobs bound in-memory LRU entries and FDs | **Yes** — `io.MultiWriter(cacheWriter, callerBuffer)` stops at the first writer returning an error | **No** — duplicates in place; up to 18 GB per steady-state restart | paper 3 §F1, §F2 (`fs/remote/blob.go:534`), §F5 |
| **soci-snapshotter v0.15.0** | **No.** 72 leaf keys (71 paths); `max_lru_cache_entry`/`max_cache_fds` bound in-memory entries and FDs, `resolve_result_entry` bounds *resolved layers* (30). LRU eviction never unlinks a cache file | **Yes, more strongly** — the span is fully fetched into `buf`, then discarded if the cache write fails; span cache is forced `Direct()` so ENOSPC hits the synchronous write. Surfaces as `EIO` | **No, worse** — fresh `os.MkdirTemp` per resolution, no startup sweep, and `SIGTERM` skips cleanup entirely | `config/fs.go:102,103,51`; `cache/cache.go:49,50,361-369`; `fs/span-manager/span_manager.go:389-392,449-462`; `fs/layer/layer.go:373`; `fs/layer/node.go:586-590`; `fs/layer/layer.go:227,286`; `cmd/soci-snapshotter-grpc/main.go:320-323,217-219` |
| **Nydus RAFS v2.4.5** | **No.** No key bounds bytes; `blob_cache_gc` is a named-blob delete API, not a GC; snapshotter `gc_period` is dead code; cache usage is exported as a metric and never acted on | **No (default).** Serve-then-cache: reader is filled by `copyv` from the in-memory buffer, cache write is `spawn_blocking` and only clears a ready bit. *Exception:* deprecated `cache.compressed = true` makes the persist synchronous and `res?` vetoes the read | **Yes** — deterministic `work_dir/blob_id`, reopened untruncated, persisted mmap'd chunk map | `api/src/config.rs:643-661,752-764,796`; `utils/src/metrics.rs:725-727`; `src/bin/nydusd/api_server_glue.rs:317-322`; `nydus-snapshotter config/config.go:195` + `pkg/cache/manager.go:36-37,56`; `storage/src/cache/cachedfile.rs:1478-1487,252,300-306,1378-1385`; `storage/src/cache/filecache/mod.rs:232,264-266,276-284,394-398`; `storage/src/cache/state/persist_map.rs:60` |
| **Nydus fscache v2.4.5** | **Yes, but external.** Kernel `cachefiles`/`cachefilesd` culling — whole cache objects, asynchronous, keyed to whole-filesystem free-space watermarks, configured outside both repos; nydusd's own cull is per-named-blob and caller-triggered; the snapshotter cannot even measure usage | **No — and no error either.** The cache file *is* the delivery channel; the fetch error is logged and `fscache_cread` is issued unconditionally. Reader-visible effect is kernel-side, **not determinable statically** | **Yes** — chunk map deliberately *not* persisted; readiness rebuilt from the backing file's real extents via `SEEK_HOLE` | `service/src/singleton.rs:232-241`; `service/src/fs_cache.rs:758-816,904-907,704-707,754-756,39`; `docs/nydus-fscache.md:65-73`; `nydus-snapshotter pkg/cache/manager.go:67-70`, `pkg/filesystem/fs.go:812-823`; `storage/src/cache/fscache/mod.rs:278-283,344-350` |

### How to read the table in the paper

Three of the four rows have no in-process on-disk byte bound, and the fourth's bound
belongs to the kernel and is not configured by the snapshotter — so **F1 generalizes
across the class**, and the fscache row should be reported as the interesting partial
exception rather than folded into a "no" or a "yes".

**F2 does not generalize.** Two of four couple cache-write failure into read failure;
one decouples by design; one makes the failure invisible to everyone. The honest claim is
that the failure class is shared by the *read-through* designs (stargz, SOCI) and that
Nydus RAFS demonstrates the decoupled alternative is viable in production. Stating it
this way is stronger than a universality claim, because it converts F2 from an observation
into a design axis with existing points on both ends.

**F5 splits cleanly along the same line**: the two that duplicate are the two that
name cache directories non-deterministically; the two that re-adopt are the two that
derive the path from the content id. That is a one-sentence design lesson the paper can
state with four supporting data points.

---

## 6. Method and limits

- Static reading only. No daemon was built or run; no rig, no fault injection. Every
  claim above is traceable to the cited lines at the pinned commits.
- Exhaustive key enumeration was done by mechanically extracting struct tags
  (`toml:` for Go, serde attributes for Rust) and then reading each declaration; counts
  were recomputed by hand from the full tag listing rather than taken from any summary.
- Explicitly **not determinable statically**, and flagged as such in place:
  1. What an application reads when a Nydus fscache-mode populate fails (§4-Q2) —
     requires kernel `cachefiles`/EROFS sources or a rig.
  2. Whether a *crashed* nydusd can leave a persisted chunk map bit set for data that
     never reached stable storage (§3-Q3) — no `fsync` ordering in these sources.
  3. Whether a mid-session `cachefilesd` cull can leave a live fscache-mode nydusd with
     stale ready bits (§4-Q3).
  4. Whether SOCI exhibits stargz's health-check blindness (cached heads readable,
     tails failing) under exhaustion (§2-Q2) — a runtime residency property.
- Read-only audit, as instructed: nothing was pushed, no issues or PRs were opened, and
  all three clones were left on detached HEADs at the pinned tags.
