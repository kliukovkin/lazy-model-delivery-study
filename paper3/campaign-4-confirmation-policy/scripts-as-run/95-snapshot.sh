#!/usr/bin/env bash
# v7 rule 2: snapshot the built artifacts BEFORE any experiment runs, and verify
# the snapshot is readable before relying on it.
#
# v5 and v6 each paid ~1h40m to build a 140GB image, and neither preserved it.
# v5's attempt failed because the artifacts were on the i4i instance store, which
# no snapshot can capture, so preserving them needed a 309GB copy; that copy was
# launched in parallel with a measurement, contaminated it (F11), and then died
# when its shell exited. v7 builds onto EBS so the snapshot is a metadata
# operation, takes it before the experiments rather than after, and reads it back.
#
# Run from the WORKSTATION.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-REDACTED-AWS-PROFILE}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_PAGER=""
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/../hosts.env"
OUT="${HERE}/../results/snapshot"; mkdir -p "${OUT}"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
rsh() { "${HERE}/rsh.sh" "$@"; }

# ---------------------------------------------------------------- 1. identify
VOL=$(aws ec2 describe-instances --instance-ids "${REG_ID}" \
  --query "Reservations[].Instances[].BlockDeviceMappings[?DeviceName=='/dev/sdf'].Ebs.VolumeId" \
  --output text | head -1)
[ -n "${VOL}" ] && [ "${VOL}" != "None" ] || { log "FATAL: the registry has no /dev/sdf data volume; artifacts are not snapshottable"; exit 1; }
log "registry data volume = ${VOL}"

# Quiesce: nothing should be writing while the snapshot point is taken. The
# snapshot itself is crash-consistent, but a filesystem sync costs nothing and
# removes the only ambiguity worth removing.
log "syncing the registry filesystem"
rsh reg 'sync; sudo fsfreeze --freeze /data 2>/dev/null && sleep 2 && sudo fsfreeze --unfreeze /data 2>/dev/null || true; df -h /data | tail -1'

# ---------------------------------------------------------------- 2. snapshot
DESC="stargz-spike-v7 artifacts: model-ballast estargz-140g + estargz-14g + predictor"
SNAP=$(aws ec2 create-snapshot --volume-id "${VOL}" --description "${DESC}" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=v7-artifacts},{Key=spike,Value=v7}]" \
  --query 'SnapshotId' --output text)
log "snapshot ${SNAP} started; waiting for completion (this is the slow part)"
aws ec2 wait snapshot-completed --snapshot-ids "${SNAP}"
aws ec2 describe-snapshots --snapshot-ids "${SNAP}" \
  --query 'Snapshots[].{ID:SnapshotId,State:State,SizeGiB:VolumeSize,Started:StartTime,Progress:Progress}' \
  --output table | tee "${OUT}/snapshot.txt"

# ---------------------------------------------------------------- 3. verify it
# A snapshot nobody has read is a belief, not a backup. Restore it to a volume,
# attach it, mount it read-only and read the artifacts back.
AZ=$(aws ec2 describe-instances --instance-ids "${REG_ID}" \
  --query 'Reservations[].Instances[].Placement.AvailabilityZone' --output text)
log "restoring ${SNAP} into a verification volume in ${AZ}"
VVOL=$(aws ec2 create-volume --snapshot-id "${SNAP}" --availability-zone "${AZ}" \
  --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=v7-snapshot-verify},{Key=spike,Value=v7}]" \
  --query 'VolumeId' --output text)
cleanup() {
  log "cleaning up the verification volume ${VVOL}"
  rsh reg 'sudo umount /mnt/verify 2>/dev/null || true' || true
  aws ec2 detach-volume --volume-id "${VVOL}" >/dev/null 2>&1 || true
  aws ec2 wait volume-available --volume-ids "${VVOL}" 2>/dev/null || true
  aws ec2 delete-volume --volume-id "${VVOL}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
aws ec2 wait volume-available --volume-ids "${VVOL}"
aws ec2 attach-volume --volume-id "${VVOL}" --instance-id "${REG_ID}" --device /dev/sdg >/dev/null
aws ec2 wait volume-in-use --volume-ids "${VVOL}"
sleep 8

log "mounting the restored volume read-only and reading the artifacts back"
rsh reg 'set -e
  # Find the newly attached device: EBS, not root, not the one already mounted.
  root=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)
  inuse=$(lsblk -no PKNAME "$(findmnt -no SOURCE /data)" 2>/dev/null | head -1)
  dev=""
  for d in /sys/block/nvme*n1; do
    b=$(basename "$d"); [ "$b" = "$root" ] && continue; [ "$b" = "$inuse" ] && continue
    m=$(cat "$d/device/model" 2>/dev/null || true)
    case "$m" in *"Elastic Block Store"*) dev="/dev/$b"; break;; esac
  done
  [ -n "$dev" ] || { echo "FATAL: could not find the restored volume"; lsblk; exit 1; }
  echo "restored volume = $dev"
  sudo mkdir -p /mnt/verify
  # nouuid: the restore is a block-for-block clone, so its filesystem UUID
  # collides with the original that is still mounted.
  sudo mount -o ro,noload "$dev" /mnt/verify 2>/dev/null || sudo mount -o ro "$dev" /mnt/verify
  echo "--- artifacts present on the restored snapshot ---"
  du -sh /mnt/verify/bench/artifacts 2>/dev/null || true
  ls /mnt/verify/bench/artifacts 2>/dev/null
  echo "--- registry blob store ---"
  du -sh /mnt/verify/registry 2>/dev/null || true
  echo "--- reading a blob back, end to end ---"
  n=$(find /mnt/verify/registry -type f -name data 2>/dev/null | head -1)
  if [ -n "$n" ]; then
    sz=$(stat -c %s "$n"); sum=$(sha256sum "$n" | cut -c1-16)
    echo "read blob $n size=$sz sha256_prefix=$sum"
  else
    echo "WARNING: no registry blob found on the restored volume"
  fi
' | tee "${OUT}/verification.txt"

# ---------------------------------------------------------------- 4. record it
SIZE=$(aws ec2 describe-snapshots --snapshot-ids "${SNAP}" --query 'Snapshots[0].VolumeSize' --output text)
{
  echo "snapshot_id=${SNAP}"
  echo "source_volume=${VOL}"
  echo "availability_zone=${AZ}"
  echo "volume_size_gib=${SIZE}"
  echo "taken_utc=$(date -u +%FT%TZ)"
  echo "description=${DESC}"
  echo "# Cost: EBS snapshots are billed on CHANGED BLOCKS actually stored, not"
  echo "# on the volume size, at \$0.05/GiB-month in us-east-1. The volume is"
  echo "# ${SIZE} GiB but holds roughly 310 GiB of artifacts, so expect on the"
  echo "# order of \$15/month. Confirm against the first bill rather than this"
  echo "# estimate; delete the snapshot when this lineage stops being re-run."
  echo "# Restore with: aws ec2 create-volume --snapshot-id ${SNAP} --availability-zone <az>"
} | tee "${OUT}/SNAPSHOT-ID.txt"
log "snapshot verified and recorded -> ${OUT}/SNAPSHOT-ID.txt"
