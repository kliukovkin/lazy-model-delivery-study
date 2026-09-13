#!/usr/bin/env bash
# Preserve the built 140GB+14GB registry so future spikes on this lineage do not
# rebuild it. v4 s17: "roughly 60% of the paid time was the one-off 140GB
# artifact build ... a future spike should snapshot the built image to a
# persistent volume or an AMI rather than regenerating it."
#
# It has to be an EBS SNAPSHOT, not an AMI. The registry's blob store lives on
# the i4i instance store (/data on the NVMe), and an AMI captures only EBS
# volumes -- an AMI of this host would come back with an empty registry. So:
# attach a fresh gp3 volume, copy the blob store onto it, snapshot that, and
# delete the volume. The snapshot is the artifact that outlives the rig.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-REDACTED-AWS-PROFILE}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$(cd "${HERE}/.." && pwd)/hosts.env"
RSH="${HERE}/rsh.sh"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

SIZE_B=$("${RSH}" reg 'sudo du -sb /data/registry | awk "{print \$1}"')
SIZE_GB=$(( (SIZE_B + 1073741823) / 1073741824 ))
VOL_GB=$(( SIZE_GB * 115 / 100 + 2 ))
log "registry blob store = ${SIZE_B} bytes (~${SIZE_GB} GiB); provisioning ${VOL_GB} GiB gp3"

AZ=$(aws ec2 describe-instances --instance-ids "${REG_ID}" \
      --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
VOL=$(aws ec2 create-volume --availability-zone "${AZ}" --size "${VOL_GB}" --volume-type gp3 \
      --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=v5-registry-export},{Key=spike,Value=v5}]' \
      --query VolumeId --output text)
log "volume ${VOL} creating"
aws ec2 wait volume-available --volume-ids "${VOL}"
aws ec2 attach-volume --volume-id "${VOL}" --instance-id "${REG_ID}" --device /dev/sdf >/dev/null
aws ec2 wait volume-in-use --volume-ids "${VOL}"
sleep 10

# The attach shows up under a different name than /dev/sdf on nitro; find the
# unmounted, unpartitioned EBS disk of the size we just asked for.
"${RSH}" reg "set -e
  DEV=\$(lsblk -dnb -o NAME,SIZE,TYPE | awk '\$3==\"disk\"' | while read -r n s t; do
          m=\$(cat /sys/block/\$n/device/model 2>/dev/null || true)
          case \"\$m\" in *'Elastic Block Store'*) [ \"\$(lsblk -no MOUNTPOINT /dev/\$n | tr -d ' \n')\" = '' ] && echo \"/dev/\$n \$s\";; esac
        done | sort -k2 -n | tail -1 | awk '{print \$1}')
  echo \"export device = \$DEV\"
  [ -n \"\$DEV\" ] || { echo 'no free EBS disk found'; lsblk; exit 1; }
  sudo mkfs.ext4 -q -F \"\$DEV\"
  sudo mkdir -p /export && sudo mount \"\$DEV\" /export
  sudo mkdir -p /export/registry
  echo 'copying blob store (this is the 140GB build being preserved)'
  sudo tar -C /data/registry -cf - . | sudo tar -C /export/registry -xf -
  sudo sh -c 'cat > /export/README.txt' <<EOF
spike-v5 registry export.
Contains /data/registry from the v5 registry host: the docker registry:2 blob
store holding model-ballast:{B-140g,estargz-140g,B-14g,estargz-14g}.
Restore: attach, mount, and point registry:2 at it with -v <mnt>/registry:/var/lib/registry
EOF
  sync; df -h /export | tail -1; sudo umount /export"

SNAP=$(aws ec2 create-snapshot --volume-id "${VOL}" \
        --description "spike-v5 model-ballast registry (140g+14g, gzip+estargz)" \
        --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=v5-model-ballast-registry},{Key=spike,Value=v5}]' \
        --query SnapshotId --output text)
log "snapshot ${SNAP} started; detaching and deleting the working volume"
aws ec2 wait snapshot-completed --snapshot-ids "${SNAP}"
aws ec2 detach-volume --volume-id "${VOL}" >/dev/null
aws ec2 wait volume-available --volume-ids "${VOL}"
aws ec2 delete-volume --volume-id "${VOL}" >/dev/null
log "working volume ${VOL} deleted"

SNAP_GB=$(aws ec2 describe-snapshots --snapshot-ids "${SNAP}" --query 'Snapshots[0].VolumeSize' --output text)
# us-east-1 standard EBS snapshot storage, $0.05 per GB-month.
COST=$(awk -v g="${SNAP_GB}" 'BEGIN{printf "%.2f", g*0.05}')
{
  echo "snapshot_id=${SNAP}"
  echo "source_volume_gib=${SNAP_GB}"
  echo "registry_bytes=${SIZE_B}"
  echo "region=${AWS_DEFAULT_REGION}"
  echo "created_utc=$(date -u +%FT%TZ)"
  echo "price_model=EBS snapshot standard tier, us-east-1, \$0.05 per GB-month"
  echo "monthly_usd_upper_bound=${COST}   # billed on BLOCKS USED, not volume size, so this is an upper bound"
  echo "delete_with=aws ec2 delete-snapshot --snapshot-id ${SNAP}"
} | tee "$(cd "${HERE}/.." && pwd)/results/REGISTRY-SNAPSHOT.txt"
