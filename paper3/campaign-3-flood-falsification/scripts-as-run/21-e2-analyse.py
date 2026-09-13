#!/usr/bin/env python3
"""E2 gate and analysis. PRE-REGISTRATION-v6.md s2.3 / s2.4 / s2.5.

The gate runs first and is binding: if the four arm-runs do not share a warm
baseline within 5%, NO policy comparison is computed. v5's comparison was
uninterpretable for exactly that reason, and computing one anyway is how a dirty
number gets quoted later.
"""
import os, re, sys, glob, json

E2 = sys.argv[1]
GATE_TOL = 0.05

def lats(path):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, errors="replace"):
        if "errno=" in line:
            continue
        m = re.search(r"ms=([0-9.]+)", line)
        if m:
            out.append(float(m.group(1)))
    return out

def errcount(path):
    if not os.path.exists(path):
        return 0
    return sum(1 for l in open(path, errors="replace") if "errno=" in l)

def pct(v, q):
    if not v:
        return float("nan")
    v = sorted(v)
    k = min(len(v) - 1, max(0, int(round(q / 100.0 * (len(v) - 1)))))
    return v[k]

def meta(d):
    kv = {}
    p = os.path.join(d, "meta.txt")
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            k, _, v = line.strip().partition("=")
            kv[k] = v
    return kv

def msum(text, name):
    return sum(float(m.group(1)) for m in
               re.finditer(r"^%s\{[^}]*\} ([0-9.eE+\-]+)$" % re.escape(name), text, re.M))

runs = []
# Only the arm-runs of THIS crossover. Bundles kept from a superseded attempt
# are preserved on disk under a suffix, and they ran under different conditions
# -- mixing them in would compare arms that never shared a starting state, which
# is the exact error the gate exists to catch.
for d in sorted(glob.glob(os.path.join(E2, "run*-*"))):
    base = os.path.basename(d)
    if not re.fullmatch(r"run\d+-(lru|2q|proportional)", base):
        continue
    m = meta(d)
    metrics = ""
    mp = os.path.join(d, "metrics-after.txt")
    if os.path.exists(mp):
        metrics = open(mp, errors="replace").read()
    runs.append(dict(
        dir=d, idx=int(m.get("run_index", 0)), policy=m.get("policy", "?"),
        w2=(lats(os.path.join(d, "warm-prev.txt")) or lats(os.path.join(d, "warm-2.txt"))),
        w3=(lats(os.path.join(d, "warm-ref.txt")) or lats(os.path.join(d, "warm-3.txt"))),
        meas=lats(os.path.join(d, "resident-latency.txt")),
        errs=errcount(os.path.join(d, "resident-latency.txt")),
        sweep_errs=errcount(os.path.join(d, "sweep-read.txt")),
        labels_end=m.get("policy_labels_end", ""),
        plain_ok=open(os.path.join(d, "policy-apply.txt"), errors="replace").read()
                 if os.path.exists(os.path.join(d, "policy-apply.txt")) else "",
        evictions=msum(metrics, "stargz_fs_cache_evictions_total"),
        evicted_bytes=msum(metrics, "stargz_fs_cache_evicted_bytes_total"),
        skipped=msum(metrics, "stargz_fs_cache_writes_skipped_total"),
        metrics=metrics,
    ))
runs.sort(key=lambda r: r["idx"])

print("=== FACTS: per arm-run ===")
print("run\tpolicy\twarm2_p50\twarm3_p50\twarm3_n\tmeas_p50\tmeas_p95\tmeas_p99\tmeas_n\tres_err\tevictions\tskipped\tpolicy_label_end")
for r in runs:
    print("%d\t%s\t%.1f\t%.1f\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%d\t%s" % (
        r["idx"], r["policy"], pct(r["w2"], 50), pct(r["w3"], 50), len(r["w3"]),
        pct(r["meas"], 50), pct(r["meas"], 95), pct(r["meas"], 99), len(r["meas"]),
        r["errs"], r["evictions"], r["skipped"], r["labels_end"] or "-"))

print()
print("=== HOW THE POLICY WAS APPLIED (v6 finding C1) ===")
print("A plain `systemctl restart` should be enough. Where it was not, the run")
print("fell back to replacing the FUSE manager, and said so. See CODE-FINDINGS-v6 C1.")
for r in runs:
    suff = "?"
    for line in r["plain_ok"].splitlines():
        if line.startswith("plain_restart_sufficient="):
            suff = line.split("=", 1)[1]
    labs = ""
    for line in r["plain_ok"].splitlines():
        if line.startswith("policy_labels_after_restart="):
            labs = line.split("=", 1)[1]
    print("run%d %-4s plain_restart_sufficient=%-3s labels_right_after_restart=[%s]"
          % (r["idx"], r["policy"], suff, labs))

print()
print("=== GATE ===")
gate_ok = True
if len(runs) < 4:
    print("G0 FAIL  only %d valid arm-runs; the ABBA crossover needs 4" % len(runs))
    gate_ok = False

w3p50 = [pct(r["w3"], 50) for r in runs if r["w3"]]
if len(w3p50) != len(runs) or not w3p50:
    print("G1 FAIL  a warm reference pass is missing or empty")
    gate_ok = False
else:
    m = sum(w3p50) / len(w3p50)
    devs = [abs(x - m) / m for x in w3p50]
    ok1 = max(devs) <= GATE_TOL
    gate_ok = gate_ok and ok1
    print("G1 %s  warm(pass3) p50 per run = %s ; mean=%.1f ; max deviation=%.1f%% (tolerance %.0f%%)"
          % ("PASS" if ok1 else "FAIL",
             ", ".join("%.1f" % x for x in w3p50), m, 100 * max(devs), 100 * GATE_TOL))

g2 = []
for r in runs:
    if not r["w2"] or not r["w3"]:
        g2.append((r["idx"], float("nan"))); continue
    a, b = pct(r["w2"], 50), pct(r["w3"], 50)
    g2.append((r["idx"], abs(b - a) / a))
ok2 = all(d == d and d <= GATE_TOL for _, d in g2)
gate_ok = gate_ok and ok2
print("G2 %s  |ref-prev|/prev per run = %s (tolerance %.0f%%)"
      % ("PASS" if ok2 else "FAIL",
         ", ".join("run%d:%.1f%%" % (i, 100 * d) for i, d in g2), 100 * GATE_TOL))

print()
if not gate_ok:
    print("=== GATE FAILED -- NO POLICY COMPARISON IS COMPUTED ===")
    print("PRE-REGISTRATION-v6.md s2.3 makes this binding: the arms do not share a")
    print("baseline, so any latency difference between them is confounded with")
    print("whatever moved the baseline. v5 published such a comparison and it could")
    print("not be quoted. Diagnosis goes to results/e2/GATE-FAILURE.md.")
    lru_w = [pct(r["w3"], 50) for r in runs if r["policy"] == "lru"]
    twq_w = [pct(r["w3"], 50) for r in runs if r["policy"] == "2q"]
    grouped = (len(lru_w) == 2 and len(twq_w) == 2
               and max(abs(lru_w[0] - lru_w[1]), abs(twq_w[0] - twq_w[1]))
                   < abs(sum(twq_w) / 2 - sum(lru_w) / 2))
    with open(os.path.join(E2, "GATE-FAILURE.md"), "w") as f:
        f.write("# E2 gate failure\n\n")
        f.write("No policy comparison was computed. PRE-REGISTRATION-v6.md s2.3 makes\n")
        f.write("that binding: the arms do not share a baseline, so a latency difference\n")
        f.write("between them is confounded with whatever moved the baseline.\n\n")
        f.write("## Facts\n\nWarm reference (pass 3) and measurement, per arm-run:\n\n")
        f.write("| run | policy | warm pass2 p50 | warm pass3 p50 | n | under-sweep p50 |\n")
        f.write("| --- | --- | --- | --- | --- | --- |\n")
        for r in runs:
            f.write("| %d | %s | %.1f ms | %.1f ms | %d | %.1f ms |\n"
                    % (r["idx"], r["policy"], pct(r["w2"], 50), pct(r["w3"], 50),
                       len(r["w3"]), pct(r["meas"], 50)))
        f.write("\nThe under-sweep column is recorded as a fact. It is **not** a result:\n")
        f.write("comparing it across arms is exactly what the gate forbids.\n\n")
        f.write("Tolerance on both gates was 5%.\n\n## Which kind of failure this is\n\n")
        if grouped:
            f.write("**The baselines cluster BY POLICY**: the two lru runs agree with each\n")
            f.write("other (%.1f, %.1f) and the two 2q runs agree with each other (%.1f,\n"
                    % (lru_w[0], lru_w[1], twq_w[0]))
            f.write("%.1f), and the gap between the clusters is larger than the spread\n"
                    % twq_w[1])
            f.write("within either. That is not drift. The warm-up runs a 14 GB hot set\n")
            f.write("against an 80 GB budget, so **no eviction happens during it at all**\n")
            f.write("and the policy should be inert. A policy-shaped difference in a phase\n")
            f.write("where the policy cannot act is a finding about the system, not noise:\n")
            f.write("the first thing to check is whether the policy setting is changing\n")
            f.write("something on the read path rather than only the eviction ranking.\n")
        else:
            f.write("The baselines do **not** cluster by policy, so this looks like drift\n")
            f.write("or contamination across the run rather than a policy-linked effect.\n")
            f.write("The ABBA order (lru, 2q, 2q, lru) means a monotonic trend shows up as\n")
            f.write("run1 and run4 disagreeing; compare those two first.\n")
        f.write("\n## What to collect before giving up the rig\n\n")
        f.write("- `sampler.csv` per run: occupancy and eviction rate during the warm-up\n")
        f.write("  passes, to confirm no eviction ran while the reference was taken\n")
        f.write("- `iostat -x 5` on the cache device during one warm pass of each policy\n")
        f.write("- `df`/`du` on /cache-part immediately before each run, for residue\n")
        f.write("- the per-file latency lines in `warm-3.txt`: a bimodal distribution\n")
        f.write("  means some files missed, which makes it a cache-state problem, not a\n")
        f.write("  throughput one\n")
        f.write("- `free -m` before each run, to confirm drop_caches actually took effect\n")
    print("wrote %s/GATE-FAILURE.md" % E2)
    sys.exit(0)

print("=== COMPARISON (gate passed) ===")
pooled_warm = [x for r in runs for x in r["w3"]]
thr_pooled = max(pooled_warm)
print("pooled hit threshold = %.1f ms (max of all four pass-3 warm references, n=%d)"
      % (thr_pooled, len(pooled_warm)))
print()
print("run\tpolicy\thit_rate_pooled\thit_rate_perarm\tthr_perarm")
for r in runs:
    thr_arm = max(r["w3"]) if r["w3"] else 0.0
    hp = sum(1 for x in r["meas"] if x <= thr_pooled) / len(r["meas"]) if r["meas"] else float("nan")
    ha = sum(1 for x in r["meas"] if x <= thr_arm) / len(r["meas"]) if r["meas"] else float("nan")
    r["hit_pooled"], r["hit_arm"] = hp, ha
    print("%d\t%s\t%.3f\t%.3f\t%.1f" % (r["idx"], r["policy"], hp, ha, thr_arm))

def by(pol, key):
    return [key(r) for r in runs if r["policy"] == pol]

print()
print("=== EFFECT SIZE (N=2 per policy; PRE-REGISTRATION s2.4) ===")
print("A difference counts as observed only if the between-policy gap exceeds the")
print("largest within-policy gap. Anything smaller is 'not separable at N=2'.")
print()
for q, label in ((50, "p50"), (95, "p95"), (99, "p99")):
    lru = by("lru", lambda r: pct(r["meas"], q))
    twq = by("2q",  lambda r: pct(r["meas"], q))
    if len(lru) < 2 or len(twq) < 2:
        print("%s: insufficient reps" % label); continue
    within = max(abs(lru[0] - lru[1]), abs(twq[0] - twq[1]))
    med_l, med_t = sum(lru) / 2, sum(twq) / 2
    between = abs(med_t - med_l)
    sep = between > within
    direction = "2q faster" if med_t < med_l else "lru faster"
    print("%s  lru=%s (mean %.1f)  2q=%s (mean %.1f)  between=%.1f  max_within=%.1f  ->  %s"
          % (label, ["%.1f" % x for x in lru], med_l, ["%.1f" % x for x in twq], med_t,
             between, within, (direction if sep else "NOT SEPARABLE at N=2")))

lru_h = by("lru", lambda r: r["hit_pooled"])
twq_h = by("2q",  lambda r: r["hit_pooled"])
if len(lru_h) >= 2 and len(twq_h) >= 2:
    within = max(abs(lru_h[0] - lru_h[1]), abs(twq_h[0] - twq_h[1]))
    between = abs(sum(twq_h) / 2 - sum(lru_h) / 2)
    print("hit_rate(pooled)  lru=%s  2q=%s  between=%.3f  max_within=%.3f  ->  %s"
          % (["%.3f" % x for x in lru_h], ["%.3f" % x for x in twq_h], between, within,
             ("2q higher" if sum(twq_h) > sum(lru_h) else "lru higher") if between > within
             else "NOT SEPARABLE at N=2"))

print()
print("=== ORDER EFFECT (what the crossover is for) ===")
lru_runs = [r for r in runs if r["policy"] == "lru"]
twq_runs = [r for r in runs if r["policy"] == "2q"]
if len(lru_runs) == 2:
    d = abs(pct(lru_runs[0]["meas"], 50) - pct(lru_runs[1]["meas"], 50))
    print("lru run%d vs run%d (first and last): p50 differ by %.1f ms"
          % (lru_runs[0]["idx"], lru_runs[1]["idx"], d))
if len(twq_runs) == 2:
    d = abs(pct(twq_runs[0]["meas"], 50) - pct(twq_runs[1]["meas"], 50))
    print("2q  run%d vs run%d (adjacent):        p50 differ by %.1f ms"
          % (twq_runs[0]["idx"], twq_runs[1]["idx"], d))

print()
print("=== PRE-REGISTERED EXPECTATIONS ===")
def chk(i, ok, detail): print("%-6s %-5s %s" % (i, "PASS" if ok else "FAIL", detail))
chk("E2.1", gate_ok, "G1 and G2 both passed")
chk("E2.5", all(r["errs"] == 0 for r in runs),
    "resident read errors per run = %s" % [r["errs"] for r in runs])
chk("E2.6", all(r["evictions"] > 0 for r in runs),
    "evictions per run = %s" % [int(r["evictions"]) for r in runs])
chk("E2.7", all(r["skipped"] == 0 for r in runs),
    "writes_skipped per run = %s" % [int(r["skipped"]) for r in runs])
lab_ok = all(("lru" in r["labels_end"].split(",")) if r["policy"] == "lru"
             else ("2q" in r["labels_end"] and "lru" not in r["labels_end"].split(","))
             for r in runs)
chk("E2.8", lab_ok, "end-of-run policy labels = %s" % [(r["idx"], r["policy"], r["labels_end"]) for r in runs])
promoted = []
for r in runs:
    if r["policy"] != "2q":
        continue
    n2q = msum(r["metrics"], "stargz_fs_cache_evictions_total")
    has_plain = bool(re.search(r'stargz_fs_cache_evictions_total\{[^}]*policy="2q"[^}]*\}\s+([0-9.eE+]+)', r["metrics"]))
    vals = [float(m.group(1)) for m in re.finditer(
        r'stargz_fs_cache_evictions_total\{[^}]*policy="2q"\}\s+([0-9.eE+]+)', r["metrics"])]
    promoted.append((r["idx"], has_plain, sum(vals)))
chk("E2.9", all(p[1] and p[2] > 0 for p in promoted) if promoted else False,
    "2q arms with a non-zero policy=\"2q\" (not just 2q-unpromoted) series: %s" % promoted)
