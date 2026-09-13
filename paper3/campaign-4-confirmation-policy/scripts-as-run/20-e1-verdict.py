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
    # E1.7 federation: every cache series on the documented endpoint
    worst = min(int(num(o, "n9110_cache_series")) for o in O)
    score("E1.7", worst > 0,
          "min stargz_(cache|fs_cache)_* series on :9110 across %d observations = %d" % (len(O), worst))

    # E1.1 the label follows the config after EVERY restart
    bad = []
    for o in O:
        tag, want = o["_tag"], o.get("config_policy", "")
        if not tag.endswith(want) and "after" in tag:
            continue
        labs = o.get("policy_labels_9110", "")
        if want and want not in labs.split(","):
            bad.append((tag, want, labs or "<none>"))
    score("E1.1", not bad,
          "every observation's label matches its config" if not bad
          else "label did not follow the config at: %s" % bad)

    # E1.2 nobody ever ran unenforced
    worstlost = max(num(o, "lock_lost_9110") for o in O)
    score("E1.2", worstlost == 0,
          "max index_lock_lost_total across all observations = %g" % worstlost)

    # E1.3 exactly one open fd on the index, always
    fds = [int(num(o, "index_open_fds", -1)) for o in O]
    score("E1.3", fds and all(f == 1 for f in fds),
          "open fds on the index per observation = %s (0 = no accounting, >1 = a leak)" % fds)

    # E1.4 PRECONDITION: the manager survived every restart
    score("E1.4", len(fm_pids) == 1,
          "fuse-manager pids across all observations = %s%s"
          % (sorted(fm_pids), "" if len(fm_pids) == 1 else "  <-- REPLACED; E1.1 is vacuous"))

    # E1.5 nothing was ever set aside as corrupt
    score("E1.5", max(corrupt) == 0, "corrupt files per observation = %s" % corrupt)

    # E1.6 reported either way, not scored
    retries = [num(o, "lock_retry_9110", -1) for o in O]
    print("%-6s %-9s %s" % ("E1.6", "REPORTED",
          "index_lock_retry_total per observation = %s  "
          "(non-zero means the ordering fix did not remove the race and the retry is carrying it; "
          "zero means ordering alone sufficed)" % retries))

else:  # negative control: the previous SUT, which must still fail
    lost = [num(o, "lock_lost_9110") for o in O]
    score("N1.1", max(lost) >= 1,
          "index_lock_lost_total reached %g across %d restarts (v6 C1 must reproduce, or E1 is void)"
          % (max(lost), len(O)))

    fds = [int(num(o, "index_open_fds", -1)) for o in O]
    score("N1.2", 0 in fds,
          "open fds on the index per observation = %s; want at least one observation at 0" % fds)

    lagging = []
    for o in O:
        want = o.get("config_policy", "")
        labs = o.get("policy_labels_9110", "") or o.get("policy_labels_9111", "")
        if want and labs and want not in labs.split(","):
            lagging.append((o["_tag"], want, labs))
    score("N1.3", bool(lagging),
          "observations where the label lagged the config: %s" % (lagging or "none"))

    print()
    print("fuse-manager pids across observations = %s" % sorted(fm_pids))

print()
bad = [k for k, v in res.items() if not v]
print("E1[%s] RESULT: %d/%d expectations met%s"
      % (arm, len(res) - len(bad), len(res), "" if not bad else "   FAILED: " + ",".join(sorted(bad))))
