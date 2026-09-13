#!/usr/bin/env python3
"""V9-C analysis: the honesty price at N=5, median + min-max.

The statistic is fixed by PRE-REGISTRATION-v9 s2 and is computed here exactly as
written there: pair i is (0% run, 90% run) run back to back in that order,
price_i = (t90_i - t0_i)/t0_i, and the headline is the MEDIAN of the five with
min-max beside it. The pre-registered interval is [15%, 26%].

Nothing here chooses a statistic after seeing data, and a trial that failed its
entry conditions is counted as missing rather than quietly dropped.
"""
import os, re, sys, statistics

root = sys.argv[1]
PREREG_LO, PREREG_HI = 15.0, 26.0


def meta(d):
    out = {}
    p = os.path.join(d, "meta.txt")
    if not os.path.exists(p):
        return out
    for line in open(p, errors="replace"):
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def readres(d):
    p = os.path.join(d, "full-read.txt")
    if not os.path.exists(p):
        return None
    for line in open(p, errors="replace"):
        m = re.search(r"attempted=(\d+) ok=(\d+) err=(\d+) bytes=(\d+)", line)
        if m:
            return tuple(int(x) for x in m.groups())
    return None


def metric(d, name):
    p = os.path.join(d, "metrics-after.txt")
    if not os.path.exists(p):
        return 0
    s = 0
    for line in open(p, errors="replace"):
        if line.startswith(name + "{") or line.split(" ")[0] == name:
            try:
                s += float(line.rsplit(" ", 1)[1])
            except (ValueError, IndexError):
                pass
    return s


runs, invalid = {}, []
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    if not os.path.isdir(d):
        continue
    if name.endswith("-INVALID"):
        invalid.append(name)
        continue
    m = re.match(r"pair(\d+)-(\d+)pct$", name)
    if not m:
        continue
    runs[(int(m.group(1)), int(m.group(2)))] = d

print("=" * 78)
print("V9-C  honesty price, N=5 interleaved pairs, one instance, one session")
print("=" * 78)
print()
hdr = ("pair", "level", "sweep_s", "ready_s", "ok", "err", "bytes_GB", "wr_skip", "evictions")
print("%-5s %-6s %10s %9s %5s %5s %10s %10s %14s" % hdr)
rows = {}
for (pair, lvl), d in sorted(runs.items()):
    mm = meta(d)
    rr = readres(d) or (0, 0, 0, 0)
    t = mm.get("sweep_s", "nan")
    rows[(pair, lvl)] = (float(t) if t not in ("nan", "") else float("nan"), rr)
    print("%-5d %-6s %10s %9s %5d %5d %10.1f %10.0f %14.0f" % (
        pair, "%d%%" % lvl, t, mm.get("deploy_to_ready_s", "?"),
        rr[1], rr[2], rr[3] / 1e9,
        metric(d, "stargz_fs_cache_writes_skipped_total"),
        metric(d, "stargz_fs_cache_evictions_total")))

print()
errs = sum(r[1][2] for r in rows.values())
print("total read errors across every V9-C run: %d" % errs)
if errs:
    print("  *** P0: our build is supposed to eliminate these. See the report. ***")

prices, detail = [], []
for pair in sorted({p for p, _ in rows}):
    a, b = rows.get((pair, 0)), rows.get((pair, 90))
    if not a or not b:
        detail.append((pair, None, "incomplete pair"))
        continue
    t0, t90 = a[0], b[0]
    if t0 != t0 or t90 != t90 or t0 <= 0:
        detail.append((pair, None, "unusable timing"))
        continue
    pct = 100.0 * (t90 - t0) / t0
    prices.append(pct)
    detail.append((pair, pct, "%.1f -> %.1f s" % (t0, t90)))

print()
print("-" * 78)
print("per-pair price  (t90 - t0) / t0")
print("-" * 78)
for pair, pct, note in detail:
    print("  pair %d: %s   %s" % (pair, "%+7.2f%%" % pct if pct is not None else "   n/a  ", note))

if prices:
    med, lo, hi = statistics.median(prices), min(prices), max(prices)
    print()
    print("  N            = %d pairs" % len(prices))
    print("  MEDIAN price = %+.2f%%" % med)
    print("  min-max      = %+.2f%% .. %+.2f%%   (spread %.2f pp)" % (lo, hi, hi - lo))
    if len(prices) > 1:
        print("  mean / stdev = %+.2f%% / %.2f pp" % (statistics.mean(prices), statistics.stdev(prices)))
    print()
    inside = PREREG_LO <= med <= PREREG_HI
    print("  pre-registered interval [%.0f%%, %.0f%%]: %s" % (
        PREREG_LO, PREREG_HI, "CONFIRMED" if inside else "FALSIFIED"))
    if not inside:
        print("    the median lies OUTSIDE the pre-registered interval. The paper's")
        print("    \\honestyPricePct is not reproducible as stated and must change.")
    # The pre-registration also asks whether the median is a meaningful summary.
    if hi - lo > abs(med):
        print("  NOTE: the min-max spread (%.2f pp) exceeds the median itself." % (hi - lo))
        print("    The median is reported, but it is not a stable summary of these")
        print("    five pairs, and the report says so rather than smoothing it.")
else:
    print("\n  no complete pairs -- no price computed")

if invalid:
    print()
    print("INVALID trials preserved (not deleted, not counted): %s" % ", ".join(invalid))
print()
print("Scope note: v9 measured 0% and 90% only. v5's non-monotonic 50% result")
print("(50% slower than 90%) is NOT addressed by this campaign.")
