#!/usr/bin/env python3
"""E2 verdict: did the budget hold under a flooded queue? PRE-REGISTRATION-v7 s2."""
import os, re, sys, glob, csv

E2 = sys.argv[1]

def meta(d):
    kv = {}
    p = os.path.join(d, "meta.txt")
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            k, _, v = line.strip().partition("=")
            kv[k] = v
    return kv

def rows(d):
    p = os.path.join(d, "sampler.csv")
    if not os.path.exists(p):
        return []
    with open(p, errors="replace") as f:
        return list(csv.DictReader(f))

def num(v, d=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d

arms = []
for d in sorted(glob.glob(os.path.join(E2, "*"))):
    if not os.path.isdir(d):
        continue
    m, r = meta(d), rows(d)
    if not m:
        continue
    budget = num(m.get("budget_bytes"), 0)
    part = num(m.get("partition_bytes"), 0)
    peak_df = max((num(x.get("df_used")) for x in r), default=0)
    peak_du = max((num(x.get("du_total")) for x in r), default=0)
    peak_idx = max((num(x.get("metric_bytes")) for x in r), default=0)
    dropped = max((num(x.get("dropped")) for x in r), default=0)
    evic = max((num(x.get("evictions")) for x in r), default=0)
    skipped = max((num(x.get("writes_skipped")) for x in r), default=0)
    rebuilds = max((num(x.get("rebuilds")) for x in r), default=0)
    read = ""
    p = os.path.join(d, "sweep-read.txt")
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            if line.startswith("READ"):
                read = line.strip()
    ok = err = 0
    mm = re.search(r"ok=(\d+) err=(\d+)", read)
    if mm:
        ok, err = int(mm.group(1)), int(mm.group(2))
    arms.append(dict(name=os.path.basename(d), qs=m.get("queue_size", "?"),
                     budget=budget, part=part, peak_df=peak_df, peak_du=peak_du,
                     peak_idx=peak_idx, dropped=dropped, evictions=evic,
                     skipped=skipped, rebuilds=rebuilds, ok=ok, err=err,
                     startable=m.get("startable_after", "?"), rowcount=len(r)))

if not arms:
    print("no arms produced data")
    sys.exit(0)

g = lambda x: x / 1e9
print("=== FACTS ===")
print("arm\tqueue\tbudget_GB\tpeak_df_GB\tpeak_du_GB\tpeak_index_GB\tdropped\tevictions\tskipped\tread_ok/err\tstartable")
for a in arms:
    print("%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%d/%d\t%s" % (
        a["name"], a["qs"], g(a["budget"]), g(a["peak_df"]), g(a["peak_du"]),
        g(a["peak_idx"]), a["dropped"], a["evictions"], a["skipped"],
        a["ok"], a["err"], a["startable"]))

print()
print("=== SCORING ===")
res = {}
def score(i, ok, detail):
    res[i] = ok
    print("%-6s %-5s %s" % (i, "PASS" if ok else "FAIL", detail))

full = [(a["name"], g(a["peak_df"]), g(a["part"])) for a in arms
        if a["part"] and a["peak_df"] >= a["part"] * 0.995]
score("E2.1", not full,
      "the partition never filled" if not full else "partition reached capacity in: %s" % full)

over = [(a["name"], g(a["peak_du"]), g(a["budget"] * 1.05)) for a in arms
        if a["budget"] and a["peak_du"] > a["budget"] * 1.05]
score("E2.2", not over,
      "cache trees stayed within budget x1.05 in every arm"
      if not over else "exceeded budget x1.05: %s" % over)

nodrop = [a["name"] for a in arms if a["dropped"] == 0]
score("E2.3", not nodrop,
      "every arm dropped updates, so every arm exercised the defect"
      if not nodrop else "NO DROPS in %s -- those arms do not test C4 and must be rerun with a smaller queue" % nodrop)

score("E2.6", all(a["startable"] == "yes" for a in arms),
      "the snapshotter restarted cleanly after every arm: %s"
      % [(a["name"], a["startable"]) for a in arms])

score("E2.7", all(a["err"] == 0 for a in arms),
      "sweep read errors per arm = %s" % [(a["name"], a["err"]) for a in arms])

# E2.4/E2.5 need the paired columns, so they are computed per sample.
print()
print("=== PRESSURE vs INDEX (E2.4, E2.5) ===")
for d in sorted(glob.glob(os.path.join(E2, "*"))):
    if not os.path.isdir(d):
        continue
    r = rows(d)
    if not r:
        continue
    name = os.path.basename(d)
    bad4 = bad5 = 0
    worst = 0.0
    for x in r:
        dropped, idx = num(x.get("dropped")), num(x.get("metric_bytes"))
        pres, du = num(x.get("pressure")), num(x.get("du_total"))
        if dropped > 0 and pres < idx:
            bad4 += 1
        if dropped > 0 and du > 0:
            gap = abs(pres - du) / du
            worst = max(worst, gap)
            if gap > 0.10:
                bad5 += 1
    print("%-8s samples=%d  pressure<index while dropping: %d  |pressure-du|/du worst: %.1f%%  over-10%% samples: %d"
          % (name, len(r), bad4, 100 * worst, bad5))
    res.setdefault("E2.4", True)
    res.setdefault("E2.5", True)
    if bad4:
        res["E2.4"] = False
    if bad5 > len(r) * 0.25:
        res["E2.5"] = False
print("E2.4  %-5s pressure never fell below the index total while updates were being dropped"
      % ("PASS" if res.get("E2.4", False) else "FAIL"))
print("E2.5  %-5s pressure tracked the filesystem within 10%% on at least three quarters of dropping samples"
      % ("PASS" if res.get("E2.5", False) else "FAIL"))

print()
print("=== RECONCILIATION RESCANS (recorded, not scored) ===")
for a in arms:
    print("%-8s rebuilds observed during the arm: %d" % (a["name"], a["rebuilds"]))

bad = [k for k, v in res.items() if not v]
print()
print("E2 RESULT: %d/%d expectations met%s"
      % (len(res) - len(bad), len(res), "" if not bad else "   FAILED: " + ",".join(sorted(bad))))
