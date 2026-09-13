#!/usr/bin/env python3
"""V9-A rollup across repetitions, joining node-side latency with the
registry-side refetch evidence.

PRE-REGISTRATION-v9 s3 fixed the decision rule: "p99 rises" means the
under-sweep or after p99 exceeds the BASELINE p99 by more than the baseline's
own between-repetition spread. That spread only exists with N>=2, which is why
the campaign runs two repetitions, and it is computed here from the baselines
themselves rather than from any assumed noise model.

Refetch is bytes the registry served for A's blob digests after A's warm-up
completed. Zero is zero, and a zero is reported as falsifying the expectation,
not smoothed into "small".
"""
import csv, datetime, os, re, sys

root = sys.argv[1] if len(sys.argv) > 1 else "../results/v9a"


def kv(p):
    d = {}
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            if "=" in line:
                k, _, v = line.strip().partition("=")
                d[k.strip()] = v.strip()
    return d


def ep(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def q(v, p):
    if not v:
        return float("nan")
    k = max(0, min(len(v) - 1, int(round(p * (len(v) - 1)))))
    return v[k]


WINDOWS = [("baseline", "baseline_begin", "baseline_end"),
           ("under-sweep", "b_read_begin", "b_read_end"),
           ("after", "tail_begin", "tail_end")]

reps = {}
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    if os.path.isdir(d) and re.match(r"rep\d+$", name):
        reps[name] = d
invalid = [n for n in os.listdir(root) if n.endswith("-INVALID")]

print("=" * 88)
print("V9-A  two-pod interference, rollup across %d repetition(s)" % len(reps))
print("=" * 88)

stats = {}
total_a_errs = 0
for rep in sorted(reps):
    d = reps[rep]
    ph = kv(os.path.join(d, "phases.txt"))
    rows = []
    p = os.path.join(d, "a-latency.csv")
    if os.path.exists(p):
        with open(p, errors="replace") as f:
            for r in csv.DictReader(f):
                try:
                    rows.append((float(r["ts_epoch"]), float(r["ms"]), r.get("errno", "")))
                except (ValueError, KeyError, TypeError):
                    pass
    total_a_errs += sum(1 for r in rows if r[2])
    print()
    print("--- %s ---" % rep)
    print("%-12s %8s %9s %9s %9s %7s" % ("window", "n", "p50 ms", "p95 ms", "p99 ms", "errs"))
    for label, a, b in WINDOWS:
        if a not in ph or b not in ph:
            print("%-12s  phase boundary missing" % label)
            continue
        t0, t1 = ep(ph[a]), ep(ph[b])
        sel = [r for r in rows if t0 <= r[0] <= t1]
        good = sorted(r[1] for r in sel if not r[2])
        e = sum(1 for r in sel if r[2])
        if not good:
            print("%-12s %8d  (no successful reads)" % (label, len(sel)))
            continue
        stats.setdefault(label, {})[rep] = dict(
            n=len(good), p50=q(good, .5), p95=q(good, .95), p99=q(good, .99))
        print("%-12s %8d %9.1f %9.1f %9.1f %7d" % (
            label, len(good), q(good, .5), q(good, .95), q(good, .99), e))
    bp = os.path.join(d, "b-full-read.txt")
    if os.path.exists(bp):
        for line in open(bp, errors="replace"):
            if line.startswith("READ") or line.startswith("ERRNOS"):
                print("  B: " + line.strip())

# ---- the pre-registered decision rule -------------------------------------
print()
print("-" * 88)
print("decision rule (PRE-REGISTRATION-v9 s3)")
print("-" * 88)
bl = stats.get("baseline", {})
if len(bl) >= 2:
    v = [bl[r]["p99"] for r in bl]
    spread = max(v) - min(v)
    print("  baseline p99 per rep: %s" % ", ".join("%.1f" % x for x in v))
    print("  between-repetition spread of the baseline p99: %.1f ms" % spread)
    for label in ("under-sweep", "after"):
        s = stats.get(label, {})
        if not s:
            continue
        for rep in sorted(s):
            if rep not in bl:
                continue
            rise = s[rep]["p99"] - bl[rep]["p99"]
            verdict = "RISE (> baseline spread)" if rise > spread else "within the baseline envelope"
            print("  %-12s %s: p99 %.1f vs baseline %.1f  ->  %+.1f ms   %s" % (
                label, rep, s[rep]["p99"], bl[rep]["p99"], rise, verdict))
elif len(bl) == 1:
    print("  only one valid repetition: the between-repetition spread the rule needs")
    print("  does not exist, so no verdict on 'p99 rises' is computed.")
else:
    print("  no valid baseline windows")

# ---- registry-side refetch -------------------------------------------------
print()
print("-" * 88)
print("registry-side refetch for A's own blobs")
print("-" * 88)
any_ref = False
for rep in sorted(reps):
    rp = os.path.join(root, rep, "refetch.txt")
    if not os.path.exists(rp):
        print("  %s: no registry capture" % rep)
        continue
    d = kv(rp)
    ab = float(d.get("A_bytes", 0))
    any_ref = any_ref or ab > 0
    print("  %s: A_bytes=%.3f GB  A_requests=%s" % (rep, ab / 1e9, d.get("A_requests", "?")))
    for line in open(rp):
        if line.startswith(("A ", "B ", "other ", "tenant")):
            print("      " + line.rstrip())

print()
print("-" * 88)
print("fatal condition")
print("-" * 88)
if total_a_errs:
    print("  *** %d READ ERRORS ON POD A -- P0 FINDING AGAINST THE PAPER ***" % total_a_errs)
else:
    print("  0 read errors on pod A across every repetition. The pre-registered")
    print("  fatal condition did not fire.")

print()
print("-" * 88)
print("what this means for I6")
print("-" * 88)
if not any_ref:
    print("  A performed NO refetches. The pre-registered expectation ('A's hot set")
    print("  WILL be partially evicted') is FALSIFIED, and I6's second clause -- that")
    print("  a sweep MAY flush another image's resident hot set -- does not hold for")
    print("  this workload shape under LRU. Reported as a falsification, per s3.")
else:
    print("  A refetched. The direction of the pre-registered expectation is")
    print("  confirmed; the magnitude is above, with the p99 verdict.")
if invalid:
    print()
    print("INVALID repetitions preserved (not deleted): %s" % ", ".join(invalid))
