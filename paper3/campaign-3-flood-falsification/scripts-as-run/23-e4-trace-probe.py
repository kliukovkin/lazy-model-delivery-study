#!/usr/bin/env python3
"""E4 [P1] -- is the sampled-index trace salvageable at a scale that favours it?

v5's F13 killed the approach at sweep scale: 615 get events out of 1,197,434,
and 92% of admissions vanished between consecutive 30s dumps. Two causes that
scale differently -- the index's one-minute last-access bucket is fixed and
defeats fast reuse at any scale, while the vanishing rate is a consequence of a
140GB sweep against an 80GB budget churning faster than any sampler can watch.

E2's resident phase is the opposite case: 14GB inside an 80GB budget, read
repeatedly, nothing else running. If the approach works anywhere, it works here.
So this measures the two failure modes directly, at 5s, on that workload, and
reports them either way. See PRE-REGISTRATION-v6.md s4.2.

Usage: 23-e4-trace-probe.py <dir-of-idx-*.tsv> <out.trace>
"""
import os, sys, glob, time

src, outp = sys.argv[1], sys.argv[2]
snaps = sorted(glob.glob(os.path.join(src, "idx-*.tsv")),
               key=lambda p: int(os.path.basename(p)[4:-4]))
if len(snaps) < 2:
    print("E4: only %d snapshots; nothing to diff" % len(snaps))
    sys.exit(0)

def load(p):
    """idxdump emits: key \t size \t at \t addedAt \t firstHitAt \t cacheType,
    behind a '#'-prefixed header line."""
    d = {}
    for line in open(p, errors="replace"):
        if line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 5:
            continue
        try:
            d[f[0]] = (int(f[1]), int(f[2]), int(f[3]), int(f[4]))
        except ValueError:
            continue
    return d

events, adds, gets, vanished, carried = [], 0, 0, 0, 0
prev, prev_ts = None, None
for p in snaps:
    ts = int(os.path.basename(p)[4:-4])
    cur = load(p)
    if prev is not None:
        for k, (size, at, added, first) in cur.items():
            if k not in prev:
                events.append((added or ts, "add", k, size)); adds += 1
                if first:
                    events.append((first, "get", k, size)); gets += 1
            else:
                psize, pat, padded, pfirst = prev[k]
                if added != padded:          # re-admitted at the same path
                    events.append((added, "add", k, size)); adds += 1
                elif at != pat:              # last-access bucket moved => a read
                    events.append((at, "get", k, size)); gets += 1
                elif first and not pfirst:   # promoted => a read
                    events.append((first, "get", k, size)); gets += 1
                carried += 1
        vanished += sum(1 for k in prev if k not in cur)
    prev, prev_ts = cur, ts

total = adds + gets
span = int(os.path.basename(snaps[-1])[4:-4]) - int(os.path.basename(snaps[0])[4:-4])
vanish_rate = (vanished / adds) if adds else float("nan")
get_share = (gets / total) if total else float("nan")

print("=== E4 FACTS ===")
print("snapshots=%d interval_span_s=%d" % (len(snaps), span))
print("adds=%d gets=%d total=%d" % (adds, gets, total))
print("carried_over_between_snapshots=%d" % carried)
print("vanished_between_snapshots=%d" % vanished)
print("vanish_rate=%.4f   (E4.1 wants < 0.10)" % vanish_rate)
print("get_share=%.4f     (E4.2 wants > 0.05)" % get_share)
print()
print("=== E4 SCORING ===")
e41 = vanish_rate == vanish_rate and vanish_rate < 0.10
e42 = get_share == get_share and get_share > 0.05
print("E4.1 %s  %.1f%% of admissions vanished between consecutive 5s dumps (v5 at 30s/sweep scale: 92%%)"
      % ("PASS" if e41 else "FAIL", 100 * vanish_rate))
print("E4.2 %s  gets are %.1f%% of events (v5 at sweep scale: 0.05%%)"
      % ("PASS" if e42 else "FAIL", 100 * get_share))

events.sort(key=lambda e: e[0])
with open(outp, "w") as f:
    f.write("# DERIVED-NOT-CAPTURED -- reconstructed by diffing %d index snapshots at ~5s\n" % len(snaps))
    f.write("# The accounting index does not emit a trace: cache/accounting/sim/trace.go\n")
    f.write("# says so at the SUT SHA, and emitting one needs a code change, which is\n")
    f.write("# forbidden on the rig. Resolution is the index's one-minute last-access\n")
    f.write("# bucket, so reuse faster than that is invisible and this UNDERSTATES reuse.\n")
    f.write("# Not valid for any claim about reuse distance or policy ranking.\n")
    f.write("# adds=%d gets=%d vanished=%d vanish_rate=%.4f get_share=%.4f\n"
            % (adds, gets, vanished, vanish_rate, get_share))
    for ts, op, k, size in events:
        f.write("%d %s %s %d\n" % (ts, op, k, size))
print()
print("E4.3 trace written -> %s (%d events)" % (outp, len(events)))
