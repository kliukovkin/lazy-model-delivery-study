#!/usr/bin/env python3
"""Derive a simulator-format access trace from a series of index snapshots.

THIS IS NOT A CAPTURED ACCESS LOG. At f6547d99 the accounting index does not
emit one (cache/accounting/sim/trace.go:78 says so; C2-REPORT s8.1 lists
producing one as the first thing this spike should motivate). This
reconstructs an approximation by diffing consecutive read-only dumps of the
bolt index, and it inherits two hard limits from the index itself:

  * last access is recorded at a one-minute bucket, so any reuse faster than
    that is invisible -- every read of a chunk inside one bucket collapses to
    at most one 'get';
  * a chunk added and evicted between two snapshots is never seen at all.

Both make the derived trace UNDERSTATE reuse. It is therefore usable for
relative policy comparison in the simulator and not usable for any claim about
reuse distance. Output is labelled DERIVED-NOT-CAPTURED in the header.

usage: 97-derive-trace.py <snapshot-dir> <out.trace>
"""
import os
import sys


def load(path):
    """key -> (size, at, addedAt, firstHitAt, cacheType)"""
    out = {}
    with open(path, errors="replace") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) != 6:
                continue
            try:
                out[f[0]] = tuple(int(x) for x in f[1:])
            except ValueError:
                continue
    return out


def main():
    snapdir, outp = sys.argv[1], sys.argv[2]
    snaps = sorted(
        (int(n.split("-")[1].split(".")[0]), os.path.join(snapdir, n))
        for n in os.listdir(snapdir)
        if n.startswith("idx-") and n.endswith(".tsv")
    )
    if not snaps:
        sys.exit("no snapshots in %s" % snapdir)

    events = []          # (at, op, key, size)
    prev = {}
    stats = {"add": 0, "get": 0, "evicted": 0, "snapshots": len(snaps)}
    for _, path in snaps:
        cur = load(path)
        for key, (size, at, added, first, _ct) in cur.items():
            was = prev.get(key)
            if was is None or was[2] != added:
                # New, or re-added at this path (addedAt moved): an admission.
                events.append((added, "add", key, size))
                stats["add"] += 1
            elif at != was[1]:
                # Last access moved: at least one read happened in between.
                # "At least one" is the whole limitation -- see the docstring.
                events.append((at, "get", key, size))
                stats["get"] += 1
        stats["evicted"] += len(set(prev) - set(cur))
        prev = cur

    events.sort(key=lambda e: e[0])
    with open(outp, "w") as fh:
        fh.write("# DERIVED-NOT-CAPTURED -- reconstructed by diffing %d index snapshots\n"
                 % stats["snapshots"])
        fh.write("# resolution is the index's one-minute last-access bucket; reuse faster\n")
        fh.write("# than that is invisible, so this UNDERSTATES reuse. Not valid for any\n")
        fh.write("# claim about reuse distance. See PRE-REGISTRATION-v5.md s0b.\n")
        fh.write("# adds=%d gets=%d disappeared_between_snapshots=%d\n"
                 % (stats["add"], stats["get"], stats["evicted"]))
        for at, op, key, size in events:
            fh.write("%d %s %s %d\n" % (at, op, key, size))
    print("wrote %s: %d events (%d add, %d get) from %d snapshots; %d keys vanished between snapshots"
          % (outp, len(events), stats["add"], stats["get"], stats["snapshots"], stats["evicted"]))


if __name__ == "__main__":
    main()
