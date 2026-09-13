#!/usr/bin/env python3
"""V9-A pod-A reader: continuous RANDOM-ORDER full-file reads, one timestamped
CSV row per read.

New code for v9, not a modification of the harness's lat_probe. lat_probe walks
a fixed list in order and prints ROUND=/FILE=/ms= lines with no wall clock, which
is right for a warm-up convergence check and useless for V9-A: V9-A has to slice
A's latency into "before B", "during B" and "after B", and that slicing needs an
absolute timestamp per read. Random order matters for the same reason -- a fixed
order makes every file's re-reference interval identical to the loop period, and
under LRU that is exactly the variable the experiment is about.

Runs until a stop sentinel appears, or until max_s elapses (a safety net so a
lost orchestrator cannot leave a reader running inside a pod forever).

usage: v9-lat-loop.py <lo> <hi> <max_s> <stop_sentinel_path>
       reads ballast-(lo+1) .. ballast-hi
"""
import errno
import os
import random
import sys
import time

d = "/mnt/models"
lo, hi, max_s, sentinel = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
names = ["ballast-%d.bin" % i for i in range(lo + 1, hi + 1)]

# Header is written once; every row is flushed, because the orchestrator streams
# this straight to a file on the node and a killed reader must still leave every
# read it completed on disk.
print("ts_epoch,iso,loop,file,bytes,ms,errno", flush=True)

t_start = time.time()
loop = 0
rnd = random.Random(1234)          # fixed seed: the order is random but reproducible
while time.time() - t_start < max_s and not os.path.exists(sentinel):
    order = names[:]
    rnd.shuffle(order)
    for n in order:
        if os.path.exists(sentinel):
            break
        p = os.path.join(d, n)
        t0 = time.time()
        nb = 0
        err = ""
        try:
            with open(p, "rb") as f:
                while True:
                    c = f.read(32 << 20)
                    if not c:
                        break
                    nb += len(c)
        except OSError as e:
            err = "%d/%s" % (e.errno, errno.errorcode.get(e.errno, "?"))
        t1 = time.time()
        print("%.6f,%s,%d,%s,%d,%.3f,%s" % (
            t0, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t0)),
            loop, n, nb, (t1 - t0) * 1000.0, err), flush=True)
    loop += 1
