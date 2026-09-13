# E2 gate failure

No policy comparison was computed. PRE-REGISTRATION-v6.md s2.3 makes
that binding: the arms do not share a baseline, so a latency difference
between them is confounded with whatever moved the baseline.

## Facts

Warm reference (pass 3) and measurement, per arm-run:

| run | policy | warm pass2 p50 | warm pass3 p50 | n | under-sweep p50 |
| --- | --- | --- | --- | --- | --- |
| 1 | lru | 588.6 ms | 604.1 ms | 28 | 539.1 ms |
| 2 | 2q | 590.5 ms | 603.6 ms | 28 | 532.1 ms |
| 3 | 2q | 706.0 ms | 620.6 ms | 28 | 644.1 ms |
| 4 | lru | 577.5 ms | 610.2 ms | 28 | 535.2 ms |

The under-sweep column is recorded as a fact. It is **not** a result:
comparing it across arms is exactly what the gate forbids.

Tolerance on both gates was 5%.

## Which kind of failure this is

The baselines do **not** cluster by policy, so this looks like drift
or contamination across the run rather than a policy-linked effect.
The ABBA order (lru, 2q, 2q, lru) means a monotonic trend shows up as
run1 and run4 disagreeing; compare those two first.

## What to collect before giving up the rig

- `sampler.csv` per run: occupancy and eviction rate during the warm-up
  passes, to confirm no eviction ran while the reference was taken
- `iostat -x 5` on the cache device during one warm pass of each policy
- `df`/`du` on /cache-part immediately before each run, for residue
- the per-file latency lines in `warm-3.txt`: a bimodal distribution
  means some files missed, which makes it a cache-state problem, not a
  throughput one
- `free -m` before each run, to confirm drop_caches actually took effect
