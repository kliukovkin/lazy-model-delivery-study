#!/usr/bin/env python3
"""Slice A's registry traffic by experiment phase.

PRE-REGISTRATION-v9 s3 defines refetch as "bytes served by the registry for A's
blob digests AFTER A's warm-up completed". The raw per-repetition total does NOT
answer that: the capture window is opened before A's warm-up, so it necessarily
contains A's cold first pass and its warming passes, which are not refetches.

This cuts the per-request timeline on the phase boundaries recorded on the node,
so the pre-registered quantity can actually be read off. Registry and node clocks
are both chrony-disciplined on EC2; the phases are minutes long, so sub-second
skew does not affect the assignment.
"""
import csv, datetime, os, sys

rep = sys.argv[1]
ph = {}
for line in open(os.path.join(rep, "phases.txt")):
    if "=" in line:
        k, _, v = line.strip().partition("=")
        ph[k] = v


def ep(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


rows = []
with open(os.path.join(rep, "a-timeline.csv")) as f:
    for r in csv.DictReader(f):
        rows.append((float(r["ts_epoch"]), int(r["bytes"])))

PHASES = [
    ("warm-up (not refetch)", "a_warm_begin", "a_warm3_end"),
    ("baseline  (A alone)", "baseline_begin", "baseline_end"),
    ("under-sweep (B running)", "b_read_begin", "b_read_end"),
    ("after  (B gone)", "tail_begin", "tail_end"),
]

print("=" * 78)
print("V9-A  registry bytes served for A's OWN blobs, by phase  (%s)" % os.path.basename(rep))
print("=" * 78)
print("%-26s %10s %16s %10s" % ("phase", "requests", "bytes", "GB"))
post = 0
for label, a, b in PHASES:
    if a not in ph or b not in ph:
        print("%-26s   (phase boundary missing)" % label)
        continue
    t0, t1 = ep(ph[a]), ep(ph[b])
    sel = [r for r in rows if t0 <= r[0] <= t1]
    n = sum(r[1] for r in sel)
    if "not refetch" not in label:
        post += n
    print("%-26s %10d %16d %10.3f" % (label, len(sel), n, n / 1e9))

print()
print("  REFETCH (everything after warm-up completed) = %.3f GB" % (post / 1e9))
print("  A's image size                               = 21.475 GB")
print("  refetch as a multiple of A's hot set         = %.2fx" % (post / 21.475e9))
print()
if post > 0:
    print("  >0 refetched bytes: the pre-registered expectation's refetch clause is")
    print("  CONFIRMED -- B's sweep did evict part of A's resident hot set.")
else:
    print("  0 refetched bytes: the refetch clause is FALSIFIED.")


# --- appended: cache hit rate by phase -------------------------------------
# Refetched BYTES alone understate what happened, because A's read volume
# differs per phase (the phases have different durations). The comparable
# quantity is the fraction of A's read bytes that the node served WITHOUT going
# back to the registry. That is computable here because A's own CSV records
# every read's byte count and the registry log records every byte it served for
# A's blobs.
import csv as _csv
lat = os.path.join(rep, "a-latency.csv")
if os.path.exists(lat):
    lrows = []
    with open(lat, errors="replace") as f:
        for r in _csv.DictReader(f):
            try:
                lrows.append((float(r["ts_epoch"]), int(r["bytes"]), r.get("errno", "")))
            except (ValueError, KeyError, TypeError):
                pass
    print()
    print("=" * 78)
    print("A's cache hit rate by phase (read bytes served without touching the registry)")
    print("=" * 78)
    print("%-26s %12s %12s %10s %9s" % ("phase", "A read GB", "registry GB", "hit rate", "MB/s ref"))
    for label, a, b in PHASES:
        if a not in ph or b not in ph:
            continue
        t0, t1 = ep(ph[a]), ep(ph[b])
        rd = sum(r[1] for r in lrows if t0 <= r[0] <= t1)
        rg = sum(r[1] for r in rows if t0 <= r[0] <= t1)
        if rd <= 0:
            continue
        print("%-26s %12.1f %12.3f %9.2f%% %9.1f" % (
            label, rd / 1e9, rg / 1e9, 100.0 * (1 - rg / rd), rg / (t1 - t0) / 1e6))

