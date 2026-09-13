#!/usr/bin/env bash
# spike-v7 rig lifecycle, run from the workstation (NOT on the hosts).
#   ./99-aws-lifecycle.sh up        -> launch 2x i4i.2xlarge, write hosts.env
#   ./99-aws-lifecycle.sh ips       -> print current IPs
#   ./99-aws-lifecycle.sh down      -> terminate BOTH, then verify nothing is left
#   ./99-aws-lifecycle.sh verify    -> assert no v5 instance is in a billable state
set -euo pipefail
# NOTE: the IAM principal is REDACTED-IAM-ARN, but on this
# workstation its credentials are stored under a profile NAMED
# "REDACTED-AWS-PROFILE" (~/.zshrc exports it globally). The profile name and
# the IAM user name simply do not match; there is no "REDACTED-IAM-USER" profile.
export AWS_PROFILE="${AWS_PROFILE:-REDACTED-AWS-PROFILE}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-REDACTED-KEYPAIR}"
ITYPE="${ITYPE:-i4i.2xlarge}"
TAGS=(v7-registry v7-node)
HOSTS_ENV="$(cd "$(dirname "$0")/.." && pwd)/hosts.env"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

case "${1:?up|ips|down|verify}" in
up)
  SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=REDACTED-SG-NAME \
            --query 'SecurityGroups[0].GroupId' --output text)
  [ "${SG_ID}" != "None" ] || { echo "SG REDACTED-SG-NAME not found"; exit 1; }
  # self-referencing rule so the two hosts can talk on all ports (idempotent)
  aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol -1 --source-group "${SG_ID}" >/dev/null 2>&1 || true
  AMI=$(aws ec2 describe-images --owners 099720109477 \
        --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  log "AMI=${AMI} SG=${SG_ID}"
  for NAME in "${TAGS[@]}"; do
    # The registry host carries a second, EBS-backed data volume.
    #
    # v5 and v6 both built the 140GB image onto the i4i instance store, which no
    # snapshot can capture: v5's attempt to preserve it therefore needed a 309GB
    # copy onto a fresh volume, that copy died mid-flight, and v6 consequently
    # paid the full ~1h40m rebuild again. Building straight onto EBS makes the
    # snapshot a metadata operation on a volume that already holds the data.
    #
    # Provisioned well above gp3's 125 MB/s baseline because the build writes
    # ~140GB of incompressible ballast and then reads it all back to convert.
    #
    # 1200 GB, not 600: the volume has to hold the build's PEAK, not the
    # artifacts. Live fix G8 caught a 600 GB volume at 93% before the conversion
    # had even started, because the peak is the raw ballast plus a hardlinked
    # copy plus the containerd build backend plus the pushed blobs plus the
    # conversion's own pull and push. v5 and v6 never met this: they built on
    # the 1.7 TB instance store, which is exactly what made their artifacts
    # impossible to snapshot.
    BDM='[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]'
    if [ "${NAME}" = "v7-registry" ]; then
      BDM='[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}},
            {"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":1200,"VolumeType":"gp3","Throughput":750,"Iops":8000,"DeleteOnTermination":true}}]'
    fi
    aws ec2 run-instances --image-id "${AMI}" --instance-type "${ITYPE}" \
      --key-name "${KEY_NAME}" --security-group-ids "${SG_ID}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}},{Key=spike,Value=v7}]" \
      --block-device-mappings "${BDM}" \
      --instance-initiated-shutdown-behavior terminate \
      --user-data "$(printf '#!/bin/bash\nshutdown -h +%d\n' "${WATCHDOG_MIN:-660}")" \
      --query 'Instances[0].InstanceId' --output text
  done
  log "waiting for running state"
  aws ec2 wait instance-running --filters "Name=tag:spike,Values=v7" "Name=instance-state-name,Values=pending,running"
  "$0" ips | tee "${HOSTS_ENV}"
  log "hosts.env written -> ${HOSTS_ENV}"
  ;;
ips)
  aws ec2 describe-instances --filters "Name=tag:spike,Values=v7" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PublicIpAddress,PrivateIpAddress,InstanceId]' \
    --output text | while read -r n pub priv id; do
      case "${n}" in
        v7-registry) echo "REG_PUB=${pub}"; echo "REG_PRIV=${priv}"; echo "REG_ID=${id}";;
        v7-node)     echo "NODE_PUB=${pub}"; echo "NODE_PRIV=${priv}"; echo "NODE_ID=${id}";;
      esac
    done
  ;;
down)
  IDS=$(aws ec2 describe-instances --filters "Name=tag:spike,Values=v7" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -z "${IDS}" ]; then log "nothing to terminate"; else
    log "terminating: ${IDS}"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids ${IDS} --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids ${IDS}
  fi
  "$0" verify
  ;;
verify)
  echo "=== ALL instances in this account/region, any non-terminated state ==="
  aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`]|[0].Value]' \
    --output table
  N=$(aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
        --query 'length(Reservations[].Instances[])' --output text)
  echo "non-terminated instance count = ${N}"
  echo "=== ALL EBS volumes, any state (v7 requires zero) ==="
  aws ec2 describe-volumes --query 'Volumes[].[VolumeId,Size,State,CreateTime]' --output table
  echo "volume count = $(aws ec2 describe-volumes --query 'length(Volumes)' --output text)"
  echo "=== snapshots owned by this account (v7 keeps EXACTLY ONE: the artifact snapshot) ==="
  aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime]' --output table
  echo "snapshot count = $(aws ec2 describe-snapshots --owner-ids self --query 'length(Snapshots)' --output text)"
  echo "=== AMIs owned by this account (v7 requires zero) ==="
  aws ec2 describe-images --owners self --query 'Images[].[ImageId,Name]' --output table
  echo "image count = $(aws ec2 describe-images --owners self --query 'length(Images)' --output text)"
  ;;
esac
