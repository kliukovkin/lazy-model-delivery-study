# spike-v4 run order

Registry-host (REG_PUB):
1. `00-registry-host-setup.sh`
2. `02-build-artifacts.sh`   # 140g + 14g variant B, eStargz conversions backgrounded

Node-host (NODE_PUB), with `hosts.env` sourced:
1. `00-node-host-setup.sh`
2. `01-cluster-up.sh`
3. `04-fetch-binaries.sh`
4. `05-setup-stargz.sh`      # v0.18.2 under systemd, fuse_manager=true, exports.root set
5. `03-calibration.sh start`
6. `10-identity-bundle.sh`   # snapshot at rest, v0.18.2
7. `20-s1-restart.sh`        # S1 [P0] -- 7 trials
8. `21-s2-enospc.sh`         # S2 [P0] -- 75% pre-fill, N=1
9. `22-s3-main.sh`           # S3 [P1] -- build main, S3a/b/c
10. `10-identity-bundle.sh -main`
11. `03-calibration.sh end`
12. `90-collect.sh`          # tarball everything BEFORE terminate
