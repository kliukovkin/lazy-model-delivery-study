# Pre-checks

Observations taken **before** the experiments proper, while the 140 GB artifact
build was still running, to de-risk E1 rather than discover its problems at
measurement time. These are not trials and are not scored against the
pre-registration; E1 repeats every one of them with a warmed cache and a full
bundle.

Two things came out of them:

1. **The F2 before/after reproduces cleanly on an empty cache.** With
   `[fuse_manager] metrics_address` unset, the SUT (`9829d7cf`) serves 39
   `stargz_(cache|fs_cache)_*` series on the documented `metrics_address`, and
   the pre-fix build (`f6547d99`) serves 0 there while serving 38 on the
   manager's own endpoint. The one-series difference is
   `stargz_cache_index_lock_lost_total`, which F3 added.
2. **Live fix G2** — see `../LIVE-FIXES-v6.md`. Switching arms by installing
   binaries and restarting does not switch the binary that produces the metrics,
   because `KillMode=process` keeps the old manager alive. Found here; fixed in
   `05-setup-stargz.sh` with an md5 assertion.

Files: `prefix-9110-metrics.txt`, `prefix-9111-metrics.txt` — the pre-fix arm's
two endpoints, verbatim.
