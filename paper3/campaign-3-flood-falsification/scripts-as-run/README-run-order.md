# spike-v6 run order

v6 = confirmation of the F12/F2/F3/F10 fix round on the rig where those symptoms
appeared, plus the clean repeat of v5's V5 that its confounded baselines made
impossible to quote.

Kept current deliberately, as v5's was: if a script is added, it goes in here.

## Workstation
1. `99-aws-lifecycle.sh up` — 2× i4i.2xlarge tagged `spike=v6`,
   `--instance-initiated-shutdown-behavior terminate`, `shutdown -h +660`
   watchdog in user-data (v6 runs longer than v5's 7 h 29 m).
2. `rsh.sh <reg|node> <cmd>`.

## Registry host
1. `00-registry-host-setup.sh`
2. `SIZES_GB="140 14" 02-build-artifacts.sh` — **both sizes**. The explicit
   assignment is belt-and-braces: v5's F6 was this script defaulting to `140`
   alone while `env.sh` said `140 14`, and it does not source `env.sh`. The
   default here is now `140 14` too.

## Node host, with `hosts.env` sourced
1. `00-node-host-setup.sh`
2. `EVICTION_MODE=kind-default 01-cluster-up.sh` — v5's F8: with production-like
   `evictionHard` (`nodefs.available: 10%`) a 90% pre-fill puts free space under
   the threshold and kubelet kills the pod before a single read. Four v5 trials
   died this way and the fix was applied by hand and never scripted. E3 asserts
   it against the running kubelet's `configz`, not against the file.
3. `04-fetch-binaries.sh` — upstream v0.18.2 → `/data/stargz-bin` (vanilla control)
4. `OUR_SHA=9829d7cf OURBIN=/data/stargz-bin-ours 04b-build-our-fork.sh` — the SUT
5. `OUR_SHA=f6547d99 OURBIN=/data/stargz-bin-prefix 04b-build-our-fork.sh` — E1's
   negative control, i.e. our own code immediately before the fix round
6. `(cd idxdump && go build -o /data/idxdump .)`
7. `03-calibration.sh start`
8. `10-identity-bundle.sh`
9. `ARM=sut 20-e1-restart-confirm.sh`      # E1 [P0]
10. `ARM=prefix 20-e1-restart-confirm.sh`  # E1 [P0] negative control
11. `21-e2-eviction-price.sh`              # E2 [P0] ABBA crossover, gated
12. `22-e3-pressure.sh`                    # E3 [P1] 90%, N=2, both arms
13. `23-e4-trace-probe.py results/e2/run1-lru/idx5s results/e4/derived.trace`  # E4 [P1]
14. `03-calibration.sh end`
15. `90-collect.sh`                        # tarball BEFORE terminate

## Workstation, after
16. `99-aws-lifecycle.sh down` — terminate, then verify **0 instances, 0 volumes,
    0 snapshots, 0 AMIs**. v6 keeps nothing alive; the task requires it.

## What changed from v5, and why

- **`[fuse_manager] metrics_address` is unset by default** (`env.sh`). v5 had to
  set it and its run-order README recorded the 20 minutes that cost. Leaving it
  unset is what makes E1.1 a test rather than a formality — if the F2 federation
  works, the documented endpoint carries everything on its own.
- **`sg_metrics` reads the documented endpoint only.** v5 scraped `:9110` and
  `:9111` and concatenated, which cannot distinguish a working federation from
  reading the manager directly. `sg_metrics_manager` still exists, and only E1's
  negative control uses it.
- **E2 changes the policy with a plain `systemctl restart`** and asserts the
  label, instead of v5's kill-and-replace-the-manager workaround. The workaround
  existed because of F12; keeping it would hide a regression. If the plain
  restart turns out not to work, the script records that as a finding and only
  then falls back.
- **Nothing runs in parallel with a measurement** (v5's F11 contaminated a V5
  attempt with a background registry copy). E4's index sampling is the one
  background job, it runs only during E2's cheap warm-up passes, and it stops
  before the reference pass.
