# spike-v7 run order

v7 = confirmation that fix round v6 works on the rig where its two P0 defects
appeared, plus the price-of-eviction measurement v5 and v6 both failed to
produce.

## Workstation
1. `99-aws-lifecycle.sh up` — 2× i4i.2xlarge tagged `spike=v7`. The **registry
   also gets a 600 GB gp3 data volume at 750 MB/s**, because the artifacts have
   to be snapshottable: v5 built onto the i4i instance store, could not snapshot
   it, and its 309 GB workaround copy contaminated a measurement and then died.
2. `rsh.sh <reg|node> <cmd>`

## Registry host
1. `00-registry-host-setup.sh` — detects the EBS data volume by model and size
   and mounts it at `/data`; falls back to the instance store with a loud warning
   that artifacts built there cannot be snapshotted.
2. `SIZES_GB="140 14" 02-build-artifacts.sh`

## Workstation — BEFORE any experiment
3. `95-snapshot.sh` — snapshot the data volume, then **restore it, attach it,
   mount it read-only and read a blob back**. A snapshot nobody has read is a
   belief, not a backup. Records the ID and cost in `results/snapshot/`.

## Node host
4. `06-node-bootstrap.sh` — base setup, then re-execs under `sg docker` (a
   process cannot see a group granted after it started: live fix G7), then the
   cluster, all three binary sets and `idxdump`.

## Experiments, in order, each collected before the next begins
5. `ARM=sut 20-e1-restart-confirm.sh`   # E1 [P0] C1 live, six alternating restarts
6. `ARM=prev 20-e1-restart-confirm.sh`  # E1 negative control on 9829d7cf
7. `24-e2-c4-confirm.sh`                # E2 [P0] C4 live: does the budget hold?
8. `25-e3-eviction-price.sh`            # E3 [P0] N=4 crossover, adaptive warm-up
9. `26-e4-pressure.sh`                  # E4 [P1] 90% pre-fill, N=2, both arms

Each of these calls `91-collect-one.sh` when it finishes; the workstation then
pulls the bundle with `92-fetch.sh <name>`. **An experiment that has not been
collected is not finished** — v6 lost E1's observation bundles, E2's samplers and
all of E3's and E4's evidence because its single end-of-session collection never
ran.

## Workstation, after
10. `99-aws-lifecycle.sh down` — terminate, then verify 0 instances, 0 volumes,
    0 AMIs, and **exactly one snapshot**: the artifact snapshot from step 3.

## What changed from v6

- **The registry builds onto EBS**, so the artifacts can be preserved.
- **Snapshot before the experiments, and read it back**, rather than after and on
  trust.
- **Collect after every experiment**, not once at the end.
- **E1 does six alternating restarts.** v6's defect alternated — restart 1 lost
  the index lock race, restart 2 found no incumbent and won — so two restarts
  could show one of each and be read either way.
- **E2 is new**: the direct falsifier for C4, with a second arm at
  `queue_size = 256` so that dropping is guaranteed rather than hoped for.
- **E3 is N=4 per policy**, because v6 established that N=2 cannot separate these
  policies whatever it measures, and uses the adaptive warm-up that v6's gate
  failure motivated.
- **The sampler records `pressure`, `rebuilds` and both lock counters.** In v6 the
  index read 0.947 of budget while the partition hit 100%, and nothing in between
  was recorded.
