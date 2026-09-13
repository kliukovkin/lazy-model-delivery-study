# spike-v5 run order

Kept current deliberately: v4's equivalent went stale (it never mentioned S2b,
S4, S4b or S5, all of which shipped in `scripts-as-run/`), and so did v4's
report Contents list. If a script is added here, add it to this file.

Workstation:
1. `99-aws-lifecycle.sh up`  — launches 2x i4i.2xlarge tagged `spike=v5`, with
   `--instance-initiated-shutdown-behavior terminate` and a `shutdown -h +420`
   watchdog in user-data, so a lost session cannot leave the rig billing.
2. `rsh.sh <reg|node> <cmd>` — run anything on either host.

Registry-host:
1. `00-registry-host-setup.sh`
2. `02-build-artifacts.sh`   # 140g + 14g, gzip then eStargz (backgrounded)

Node-host, with `hosts.env` sourced:
1. `00-node-host-setup.sh`   # detects the instance store by device model, not by name
2. `01-cluster-up.sh`
3. `04-fetch-binaries.sh`    # upstream v0.18.2 -> /data/stargz-bin (the control arm)
4. `04b-build-our-fork.sh`   # our fork @ OUR_SHA -> /data/stargz-bin-ours (the SUT)
5. `05-setup-stargz.sh`      # installs an arm; BINSRC/ARM_LABEL select which
6. `03-calibration.sh start`
7. `10-identity-bundle.sh`
8. `31-v1-sweep.sh`          # V1 [P0]
9. `32-v2-pressure.sh`       # V2 [P0]  -- switches arms internally, restores ours
10. `33-v3-restart-loop.sh`  # V3 [P0]
11. `34-v4-lyingpod-probe.sh`# V4 [P1]  -- switches arms internally
12. `35-v5-eviction-price.sh`# V5 [P1]  -- lru then 2q, restores CACHE_POLICY
13. `03-calibration.sh end`
14. `90-collect.sh`          # tarball everything BEFORE terminate

Workstation, after:
15. `96-registry-snapshot.sh`  # EBS snapshot of the built registry (NOT an AMI --
                               # the blob store is on instance store, which an AMI
                               # cannot capture)
16. `97-derive-trace.py <snapshot-dir> <out.trace>`   # V6, offline
17. `99-aws-lifecycle.sh down` # terminate + verify 0 instances / 0 loose volumes

## Configuration gotcha that cost this run 20 minutes

`[fuse_manager] metrics_address` MUST be set. With `fuse_manager = true` the
filesystem, the C1 accounting index and the C2 eviction engine all live in the
`stargz-fuse-manager` process; `metrics_address` at the top level is served by
`containerd-stargz-grpc`, which has none of them. Without the manager's own
endpoint every `stargz_cache_*` and `stargz_fs_cache_*` series is silently
absent while eviction is in fact running. `sg_metrics` in `lib.sh` scrapes both.
