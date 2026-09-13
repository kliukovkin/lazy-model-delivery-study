#!/usr/bin/env python3
"""V9-B analysis: budgets, per-node times, and registry-side amplification.

Every threshold here is the one PRE-REGISTRATION-v9 s4 fixed before the rig ran:
  clause (i)   every node: du <= budget, 0 read errors
  clause (ii)  aggregate egress within +-15% of k x the IN-SESSION k=1 egress
  clause (iii) per-node completion >= that node's OWN k=1 time

"Aggregate registry egress" is the registry host's /proc/net/dev tx delta. The
access log's summed response bytes is a cross-check; if they disagree by more
than 5% the NIC counter wins and the disagreement is printed rather than hidden.

Rule 0.2 applies: node A's time is never compared with node B's. Only each node
against itself.
"""
import os, re, sys

root = sys.argv[1] if len(sys.argv) > 1 else "../results/v9b"
TOL_LINEAR = 0.15
TOL_CROSSCHECK = 0.05


def kv(p):
    d = {}
    if os.path.exists(p):
        for line in open(p, errors="replace"):
            if "=" in line:
                k, _, v = line.strip().partition("=")
                d[k.strip()] = v.strip()
    return d


def readres(p):
    if not os.path.exists(p):
        return None
    for line in open(p, errors="replace"):
        m = re.search(r"attempted=(\d+) ok=(\d+) err=(\d+) bytes=(\d+)", line)
        if m:
            return tuple(int(x) for x in m.groups())
    return None


def metric(p, name):
    if not os.path.exists(p):
        return 0.0
    s = 0.0
    for line in open(p, errors="replace"):
        if line.startswith(name + "{") or line.split(" ")[0] == name:
            try:
                s += float(line.rsplit(" ", 1)[1])
            except (ValueError, IndexError):
                pass
    return s


rounds = {}
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    if not os.path.isdir(d):
        continue
    m = re.match(r"(.+)-(node\d|registry)$", name)
    if not m:
        continue
    rounds.setdefault(m.group(1), {})[m.group(2)] = d

print("=" * 92)
print("V9-B  multi-node registry amplification")
print("=" * 92)
cp = os.path.join(root, "ceilings.txt")
if os.path.exists(cp):
    print("\nregistry ceilings (measured, not assumed):")
    for line in open(cp):
        print("  " + line.rstrip())

node_times = {}   # node -> {round: seconds}
node_k = {}       # round -> k

print()
print("%-14s %-7s %8s %10s %7s %7s %10s %12s %10s" % (
    "round", "node", "k", "read_s", "ok", "err", "du_GB", "evictions", "df_used_GB"))
for rnd in sorted(rounds):
    parts = rounds[rnd]
    nodes = sorted(n for n in parts if n.startswith("node"))
    node_k[rnd] = len(nodes)
    for n in nodes:
        d = parts[n]
        mm = kv(os.path.join(d, "meta.txt"))
        rr = readres(os.path.join(d, "full-read.txt")) or (0, 0, 0, 0)
        du = dfu = 0.0
        p = os.path.join(d, "du-after.txt")
        if os.path.exists(p):
            f = open(p).read().split()
            if len(f) >= 3:
                du = (int(f[0]) + int(f[1])) / 1e9
        p = os.path.join(d, "df-after.txt")
        if os.path.exists(p):
            f = open(p).read().split()
            if len(f) >= 3:
                dfu = int(f[2]) / 1e9
        t = mm.get("read_s", "nan")
        try:
            node_times.setdefault(n, {})[rnd] = float(t)
        except ValueError:
            pass
        print("%-14s %-7s %8d %10s %7d %7d %10.1f %12.0f %10.1f" % (
            rnd, n, len(nodes), t, rr[1], rr[2], du,
            metric(os.path.join(d, "metrics-after.txt"), "stargz_fs_cache_evictions_total"), dfu))

# ---- clause (i) ------------------------------------------------------------
print()
print("-" * 92)
print("clause (i): every node's budget holds, zero read errors")
print("-" * 92)
bad = []
for rnd in sorted(rounds):
    for n, d in sorted(rounds[rnd].items()):
        if not n.startswith("node"):
            continue
        mm = kv(os.path.join(d, "meta.txt"))
        budget = float(mm.get("budget_bytes", 80e9))
        rr = readres(os.path.join(d, "full-read.txt")) or (0, 0, 0, 0)
        p = os.path.join(d, "du-after.txt")
        du = 0.0
        if os.path.exists(p):
            f = open(p).read().split()
            if len(f) >= 2:
                du = int(f[0]) + int(f[1])
        if rr[2] > 0:
            bad.append("%s/%s: %d READ ERRORS" % (rnd, n, rr[2]))
        if du > budget:
            bad.append("%s/%s: du %.1f GB EXCEEDS budget %.1f GB" % (rnd, n, du / 1e9, budget / 1e9))
print("  FAIL" if bad else "  PASS -- no node exceeded its budget and no node saw a read error")
for b in bad:
    print("    " + b)

# ---- clause (ii) -----------------------------------------------------------
print()
print("-" * 92)
print("clause (ii): aggregate registry egress linear in k (+-15%% of k x in-session k=1)")
print("-" * 92)
egress = {}
for rnd in sorted(rounds):
    reg = rounds[rnd].get("registry")
    if not reg:
        continue
    e = kv(os.path.join(reg, "egress.txt"))
    tx = float(e.get("tx_delta_bytes", 0))
    log_bytes = 0.0
    bp = os.path.join(reg, "registry-blobs.txt")
    if os.path.exists(bp):
        for line in open(bp):
            if line.startswith("total_response_bytes="):
                log_bytes = float(line.split("=")[1])
    egress[rnd] = (tx, log_bytes, int(e.get("k", node_k.get(rnd, 0))), float(e.get("fanout_skew_s", 0)),
                   float(e.get("window_s", 0)))
    print("  %-14s k=%d  NIC tx %8.2f GB   access-log %8.2f GB   skew %5.3f s   window %7.1f s" % (
        rnd, egress[rnd][2], tx / 1e9, log_bytes / 1e9, egress[rnd][3], egress[rnd][4]))
    if tx > 0 and log_bytes > 0:
        diff = abs(tx - log_bytes) / tx
        if diff > TOL_CROSSCHECK:
            print("    NOTE: NIC and access log disagree by %.1f%% (>%.0f%%). The NIC counter is"
                  % (100 * diff, 100 * TOL_CROSSCHECK))
            print("          authoritative per the pre-registration; both are reported.")

base = [r for r in egress if egress[r][2] == 1]
multi = [r for r in egress if egress[r][2] > 1]
if base and multi:
    b = egress[base[0]][0]
    print()
    print("  in-session k=1 baseline egress: %.2f GB  (%s)" % (b / 1e9, base[0]))
    for r in sorted(multi):
        tx, _, k, _, _ = egress[r]
        exp = k * b
        dev = (tx - exp) / exp if exp else 0
        verdict = "LINEAR" if abs(dev) <= TOL_LINEAR else "NOT LINEAR"
        print("  %-14s k=%d  observed %.2f GB vs %d x %.2f = %.2f GB  ->  %+.1f%%  %s" % (
            r, k, tx / 1e9, k, b / 1e9, exp / 1e9, 100 * dev, verdict))
else:
    print("  (need both a k=1 and a k>1 round to evaluate linearity)")

# ---- clause (iii) ----------------------------------------------------------
print()
print("-" * 92)
print("clause (iii): per-node completion vs that node's OWN k=1 time")
print("-" * 92)
print("  (rule 0.2: nodes are separate instances and are never compared with each other)")
for n in sorted(node_times):
    ts = node_times[n]
    b = [r for r in ts if node_k.get(r) == 1]
    if not b:
        print("  %s: no own k=1 baseline -- clause (iii) not evaluated for this node" % n)
        continue
    bt = ts[b[0]]
    print("  %s: k=1 %.1f s" % (n, bt))
    for r in sorted(ts):
        if node_k.get(r) == 1:
            continue
        print("      %-14s k=%d  %.1f s  (%+.1f%% vs own k=1)  %s" % (
            r, node_k.get(r, 0), ts[r], 100 * (ts[r] - bt) / bt,
            "as expected (>=)" if ts[r] >= bt else "FASTER than k=1 -- falsifies (iii)"))

# ---- saturation ------------------------------------------------------------
print()
print("-" * 92)
print("registry throughput during each round, against the measured ceilings")
print("-" * 92)
nic_gbps = None
if os.path.exists(cp):
    v = [float(l.split("=")[1]) for l in open(cp) if l.startswith("iperf3_gbps_to_") and "NA" not in l]
    if v:
        nic_gbps = sum(v) / len(v)
for r in sorted(egress):
    tx, _, k, _, w = egress[r]
    if w > 0:
        gbps = tx * 8 / w / 1e9
        s = "  %-14s k=%d  mean egress %.2f Gb/s (%.0f MB/s)" % (r, k, gbps, tx / w / 1e6)
        if nic_gbps:
            s += "  = %.0f%% of the %.2f Gb/s NIC ceiling" % (100 * gbps / nic_gbps, nic_gbps)
        print(s)
