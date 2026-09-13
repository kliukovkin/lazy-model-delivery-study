#!/usr/bin/env python3
"""E1 verdict: is the 16% real? PRE-REGISTRATION-v8 s1.3.

The effect-size rule is v7's: a difference between builds counts as observed only
if it exceeds the spread between repetitions of the same build. Two reps each, so
"spread" is the absolute difference between them.
"""
import os, re, sys, glob, csv

E1 = sys.argv[1]

def meta(d):
    kv = {}
    p = os.path.join(d, "meta.txt")
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            k, _, v = line.strip().partition("=")
            kv[k] = v
    return kv

def num(v, d=0.0):
    try: return float(v)
    except (TypeError, ValueError): return d

def lastrow(d):
    p = os.path.join(d, "sampler.csv")
    if not os.path.exists(p): return {}
    rows = list(csv.DictReader(open(p, errors="replace")))
    return rows[-1] if rows else {}

runs = []
for d in sorted(glob.glob(os.path.join(E1, "run*-*"))):
    if not os.path.isdir(d) or d.endswith("-INVALID"): continue
    m, last = meta(d), lastrow(d)
    read = ""
    p = os.path.join(d, "full-read.txt")
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            if line.startswith("READ"): read = line.strip()
    mm = re.search(r"ok=(\d+) err=(\d+)", read)
    runs.append(dict(
        idx=int(num(m.get("run_index"))), build=m.get("build", "?"),
        sha=(m.get("sha") or "")[:8],
        sweep=num(m.get("sweep_s")), ready=num(m.get("deploy_to_ready_s")),
        ok=int(mm.group(1)) if mm else 0, err=int(mm.group(2)) if mm else -1,
        dropped=num(last.get("dropped")), evictions=num(last.get("evictions")),
        skipped=num(last.get("writes_skipped")), du=num(last.get("du_total")),
        df=num(last.get("df_used")), pressure=num(last.get("pressure")),
    ))
runs.sort(key=lambda r: r["idx"])

if not runs:
    print("no arms produced data"); sys.exit(0)

print("=== FACTS ===")
print("run\tbuild\tsha\t\tsweep_s\t\tok/err\tdropped\tevictions\tskipped\tdu_GB\tdf_GB")
for r in runs:
    print("%d\t%s\t%s\t%.1f\t\t%d/%d\t%d\t%d\t\t%d\t%.1f\t%.1f" % (
        r["idx"], r["build"], r["sha"], r["sweep"], r["ok"], r["err"],
        r["dropped"], r["evictions"], r["skipped"], r["du"]/1e9, r["df"]/1e9))

by = {}
for r in runs:
    by.setdefault(r["build"], []).append(r)

print()
print("=== SCORING ===")
res = {}
def score(i, ok, detail):
    res[i] = ok
    print("%-6s %-5s %s" % (i, "PASS" if ok else "FAIL", detail))

score("E1.1", all(r["ok"] == 280 and r["err"] == 0 for r in runs),
      "reads per arm = %s" % [(r["build"], "%d/%d" % (r["ok"], r["err"])) for r in runs])

score("E1.3", all(r["dropped"] == 0 and r["evictions"] == 0 for r in runs),
      "dropped/evictions per arm = %s  (both zero confirms the budget never bound, "
      "which is the regime s1.3 reasons about)"
      % [(r["build"], int(r["dropped"]), int(r["evictions"])) for r in runs])

if len(by.get("prev", [])) >= 2 and len(by.get("sut", [])) >= 2:
    prev = [r["sweep"] for r in by["prev"]]
    sut = [r["sweep"] for r in by["sut"]]
    within = max(abs(prev[0]-prev[1]), abs(sut[0]-sut[1]))
    mprev, msut = sum(prev)/len(prev), sum(sut)/len(sut)
    between = abs(msut - mprev)
    sep = between > within
    score("E1.2", not sep,
          "9829d7cf=%s (mean %.1f)  6e87e34e=%s (mean %.1f)  between=%.1fs  max_within=%.1fs  ->  %s"
          % (["%.1f" % x for x in prev], mprev, ["%.1f" % x for x in sut], msut,
             between, within,
             "NOT SEPARABLE: the 16%% was cross-session variation" if not sep
             else "SEPARABLE: %.1f%% %s on 6e87e34e -- profiling required (s1.4)"
                  % (100*between/mprev, "slower" if msut > mprev else "faster")))
    print()
    print("For reference, the cross-spike numbers this experiment exists to explain:")
    print("  v6 on 9829d7cf: 1235.4 / 1240.9 s      v7 on 6e87e34e: 1432.9 / 1454.7 s  (+16.4%%)")
    print("  v8 same-session: 9829d7cf %.1f / %.1f   6e87e34e %.1f / %.1f  (%+.1f%%)"
          % (prev[0], prev[1], sut[0], sut[1], 100*(msut-mprev)/mprev))
else:
    print("E1.2  SKIP   need 2 reps of each build; have prev=%d sut=%d"
          % (len(by.get("prev", [])), len(by.get("sut", []))))

bad = [k for k, v in res.items() if not v]
print()
print("E1 RESULT: %d/%d expectations met%s"
      % (len(res)-len(bad), len(res), "" if not bad else "   FAILED: " + ",".join(sorted(bad))))
