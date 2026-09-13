#!/usr/bin/env python3
"""V9-A per-repetition analysis: slice pod A's latency CSV by phase.

The windows and the statistic are fixed by PRE-REGISTRATION-v9 s3:
  baseline    = baseline_begin .. baseline_end     (A alone, >= 5 min)
  under-sweep = b_read_begin   .. b_read_end       (B sweeping beside it)
  after       = tail_begin     .. tail_end         (B gone, 5 min)
A read is assigned to the window containing its START timestamp.

"p99 rises" means the under-sweep or after p99 exceeds the baseline p99. Whether
that rise is larger than the between-repetition spread is decided across reps by
the run report, not here -- this script reports one repetition's facts.
"""
import os, sys, csv, statistics

out = sys.argv[1]


def phases(p):
    d = {}
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            if "=" in line:
                k, _, v = line.strip().partition("=")
                d[k] = v
    return d


def iso_to_epoch(s):
    import datetime
    s = s.replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(s).timestamp()


ph = phases(os.path.join(out, "phases.txt"))
csv_path = os.path.join(out, "a-latency.csv")
if not os.path.exists(csv_path):
    print("no a-latency.csv -- nothing to analyse")
    sys.exit(0)

rows = []
with open(csv_path, errors="replace") as f:
    for r in csv.DictReader(f):
        try:
            rows.append((float(r["ts_epoch"]), float(r["ms"]), r.get("errno", ""), r["file"]))
        except (ValueError, KeyError, TypeError):
            pass

windows = [("baseline", "baseline_begin", "baseline_end"),
           ("under-sweep", "b_read_begin", "b_read_end"),
           ("after", "tail_begin", "tail_end")]

print("=" * 72)
print("V9-A  pod A latency by phase   (%s)" % os.path.basename(out))
print("=" * 72)
print()
print("%-12s %7s %9s %9s %9s %9s %7s" % ("window", "n", "p50 ms", "p95 ms", "p99 ms", "max ms", "errs"))

res = {}
for label, a, b in windows:
    if a not in ph or b not in ph:
        print("%-12s  (phase boundary missing: %s/%s)" % (label, a, b))
        continue
    t0, t1 = iso_to_epoch(ph[a]), iso_to_epoch(ph[b])
    sel = [r for r in rows if t0 <= r[0] <= t1]
    good = sorted(r[1] for r in sel if not r[2])
    errs = sum(1 for r in sel if r[2])
    if not good:
        print("%-12s %7d  (no successful reads in window)" % (label, len(sel)))
        continue

    def q(p):
        k = max(0, min(len(good) - 1, int(round(p * (len(good) - 1)))))
        return good[k]

    res[label] = dict(n=len(good), p50=q(.50), p95=q(.95), p99=q(.99), mx=good[-1], errs=errs)
    print("%-12s %7d %9.1f %9.1f %9.1f %9.1f %7d" % (
        label, len(good), q(.50), q(.95), q(.99), good[-1], errs))

print()
if "baseline" in res:
    b = res["baseline"]
    for label in ("under-sweep", "after"):
        if label in res:
            r = res[label]
            print("  %-12s vs baseline:  p50 %+7.1f%%   p95 %+7.1f%%   p99 %+7.1f%%" % (
                label,
                100 * (r["p50"] - b["p50"]) / b["p50"],
                100 * (r["p95"] - b["p95"]) / b["p95"],
                100 * (r["p99"] - b["p99"]) / b["p99"]))

total_errs = sum(1 for r in rows if r[2])
print()
print("  pod A read errors, whole repetition: %d" % total_errs)
if total_errs:
    print("  *** FATAL per PRE-REGISTRATION-v9 s3: any read error on A is a P0")
    print("      finding against the paper's elimination claim. ***")
else:
    print("  (zero read errors on A -- the pre-registered fatal condition did not fire)")

# B's side, for context.
bp = os.path.join(out, "b-full-read.txt")
if os.path.exists(bp):
    for line in open(bp, errors="replace"):
        if line.startswith("READ") or line.startswith("ERRNOS"):
            print("  B: " + line.strip())

# Node-side eviction totals -- the other half of "was A's hot set evicted".
mp = os.path.join(out, "metrics-after.txt")
if os.path.exists(mp):
    tot = {}
    for line in open(mp, errors="replace"):
        for name in ("stargz_fs_cache_evictions_total", "stargz_fs_cache_evicted_bytes_total",
                     "stargz_fs_cache_writes_skipped_total"):
            if line.startswith(name + "{") or line.split(" ")[0] == name:
                try:
                    tot[name] = tot.get(name, 0) + float(line.rsplit(" ", 1)[1])
                except (ValueError, IndexError):
                    pass
    print()
    for k, v in sorted(tot.items()):
        print("  %-40s %15.0f%s" % (k, v, "  (%.1f GB)" % (v / 1e9) if "bytes" in k else ""))
