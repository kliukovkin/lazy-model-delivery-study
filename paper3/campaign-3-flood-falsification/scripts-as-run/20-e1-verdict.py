#!/usr/bin/env python3
"""E1 verdict: score the observations against PRE-REGISTRATION-v6.md s1.4/s1.5.

Facts are printed first and separately from the pass/fail scoring, which is the
report convention this lineage uses. Every id here exists in the pre-registration
with a falsifier written down before the rig was launched.
"""
import os, sys, glob

out, arm = sys.argv[1], sys.argv[2]

def obs():
    for d in sorted(glob.glob(os.path.join(out, "obs-*"))):
        kv = {}
        for line in open(os.path.join(d, "observation.txt"), errors="replace"):
            if "=" in line and not line.startswith("---"):
                k, _, v = line.strip().partition("=")
                kv[k] = v
        kv["_dir"] = d
        kv["_tag"] = os.path.basename(d)[4:]
        yield kv

O = list(obs())
if not O:
    print("NO OBSERVATIONS -- E1 produced nothing to score")
    sys.exit(0)

print("=== FACTS ===")
cols = ["_tag", "config_policy", "fm_pid", "grpc_pid", "n9110_cache_series",
        "policy_labels_9110", "budget_9110", "lock_lost_9110", "db_holders", "db_corrupt"]
if arm == "prefix":
    cols += ["n9111_cache_series", "policy_labels_9111"]
print("\t".join(c.lstrip("_") for c in cols))
for o in O:
    print("\t".join(str(o.get(c, "-")) for c in cols))

def num(o, k, d=0):
    try: return float(o.get(k, d))
    except (TypeError, ValueError): return d

print()
print("=== SCORING (ids from PRE-REGISTRATION-v6.md) ===")
res = {}
def score(i, ok, detail):
    res[i] = ok
    print("%-6s %-9s %s" % (i, "PASS" if ok else "FAIL", detail))

fm_pids = {o.get("fm_pid", "") for o in O if o.get("fm_pid")}
holders = [int(num(o, "db_holders")) for o in O]
corrupt = [int(num(o, "db_corrupt")) for o in O]

if arm == "sut":
    # E1.1 every cache series readable from the DOCUMENTED endpoint, always
    worst = min(int(num(o, "n9110_cache_series")) for o in O)
    score("E1.1", worst > 0,
          "min stargz_(cache|fs_cache)_* series on :9110 across %d observations = %d" % (len(O), worst))

    # E1.2 the lru->2q restart moves the effective policy label
    after2q = [o for o in O if o["_tag"] in ("2-after-restart-to-2q", "3-after-read-under-2q")]
    labs = ",".join(o.get("policy_labels_9110", "") for o in after2q)
    ok2 = any("2q" in o.get("policy_labels_9110", "") for o in after2q)
    score("E1.2", ok2, "policy labels after the lru->2q restart: [%s]" % labs)

    # E1.3 and back again
    afterlru = [o for o in O if o["_tag"] in ("4-after-restart-to-lru", "5-after-read-under-lru")]
    ok3 = any("lru" in o.get("policy_labels_9110", "").split(",") for o in afterlru)
    score("E1.3", ok3, "policy labels after the 2q->lru restart: [%s]"
          % ",".join(o.get("policy_labels_9110", "") for o in afterlru))

    # E1.4 the lock counter exists and stays at zero
    present = all(int(num(o, "lock_lost_present_9110")) >= 1 for o in O)
    zero = all(num(o, "lock_lost_9110") == 0 for o in O)
    score("E1.4", present and zero,
          "present at every scrape=%s, max value=%g" % (present, max(num(o, "lock_lost_9110") for o in O)))

    # E1.5 exactly one holder of the index
    score("E1.5", holders and max(holders) <= 1 and max(holders) >= 1,
          "db holders per observation = %s" % holders)

    # E1.6 no .corrupt
    score("E1.6", max(corrupt) == 0, "corrupt files per observation = %s" % corrupt)

    # E1.7 PRECONDITION: the manager survived
    score("E1.7", len(fm_pids) == 1,
          "fuse-manager pids seen across all observations = %s%s"
          % (sorted(fm_pids), "" if len(fm_pids) == 1 else "  <-- manager was REPLACED; E1.2 is vacuous"))

    # E1.8 no duplicated runtime collectors
    dup = []
    for o in O:
        t = open(os.path.join(o["_dir"], "observation.txt"), errors="replace").read()
        for line in t.splitlines():
            if line.startswith("go_goroutines_lines="):
                g = line.split("=")[1].split()[0]
                p = line.split("process_open_fds_lines=")[1] if "process_open_fds_lines=" in line else "?"
                if g != "1" or p != "1":
                    dup.append((o["_tag"], g, p))
    score("E1.8", not dup, "duplicated runtime collectors: %s" % (dup or "none"))

    # E1.9 no duplicated families anywhere
    dupfam = []
    for o in O:
        t = open(os.path.join(o["_dir"], "observation.txt"), errors="replace").read()
        dupfam += [l for l in t.splitlines() if l.startswith(("DUP-HELP", "DUP-TYPE"))]
    score("E1.9", not dupfam, "duplicate metric families: %s" % (dupfam or "none"))

else:  # negative control
    # N1.1 the old symptom: nothing on :9110, everything on :9111
    n10 = [int(num(o, "n9110_cache_series")) for o in O]
    n11 = [int(num(o, "n9111_cache_series")) for o in O]
    score("N1.1", max(n10) == 0 and max(n11) > 0,
          "cache series on :9110 = %s ; on :9111 = %s" % (n10, n11))

    # N1.2 the policy label does NOT follow the config across a plain restart
    after2q = [o for o in O if o["_tag"] in ("2-after-restart-to-2q", "3-after-read-under-2q")]
    labs = [o.get("policy_labels_9111", "") for o in after2q]
    score("N1.2", all("2q" not in l for l in labs),
          "policy labels on :9111 after the lru->2q restart = %s (expected to be stuck at lru)" % labs)

    # N1.3 the leak leaves a trace
    score("N1.3", max(corrupt) > 0 or max(holders) > 1,
          "max corrupt=%d, max db holders=%d" % (max(corrupt), max(holders)))

    print()
    print("fuse-manager pids across observations = %s" % sorted(fm_pids))

print()
bad = [k for k, v in res.items() if not v]
print("E1[%s] RESULT: %d/%d expectations met%s"
      % (arm, len(res) - len(bad), len(res), "" if not bad else "   FAILED: " + ",".join(sorted(bad))))
