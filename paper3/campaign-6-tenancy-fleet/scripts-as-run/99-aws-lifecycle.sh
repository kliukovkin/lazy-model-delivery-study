#!/usr/bin/env bash
# spike-v9 rig lifecycle, run from the WORKSTATION (not on the hosts).
#   ./99-aws-lifecycle.sh up       -> launch registry + 3 node hosts, write hosts.env
#   ./99-aws-lifecycle.sh ips      -> print current IPs
#   ./99-aws-lifecycle.sh attach   -> create a volume from the (FSR-warmed) artifact
#                                     snapshot and attach it to the registry host
#   ./99-aws-lifecycle.sh down     -> terminate everything, disable FSR, verify
#   ./99-aws-lifecycle.sh verify   -> assert nothing v9 is in a billable state
#
# Differences from v8:
#   - FOUR hosts (V9-B needs k=3 nodes), all pinned to ONE subnet/AZ so that
#     (a) inter-host traffic is free and private and (b) the FSR registration,
#     which is per-AZ, actually applies to the volume we create.
#   - The registry launches WITHOUT the artifact volume. FSR takes ~1 h/TiB to
#     optimize; attaching a volume created before that finishes would give us
#     exactly the 14 MB/s lazy load v8 measured. Launch first, set everything
#     else up in parallel, attach when FSR says enabled.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-REDACTED-AWS-PROFILE}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-REDACTED-KEYPAIR}"
ITYPE="${ITYPE:-i4i.2xlarge}"
AZ="${AZ:-us-east-1b}"
SUBNET="${SUBNET:-REDACTED-SUBNET-ID}"
ARTIFACT_SNAPSHOT="${ARTIFACT_SNAPSHOT:-snap-0118cc5716e9e8a54}"
TAGS=(v9-registry v9-node1 v9-node2 v9-node3)
HOSTS_ENV="$(cd "$(dirname "$0")/.." && pwd)/hosts.env"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

case "${1:?up|ips|attach|down|verify|fsr}" in
up)
  SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=REDACTED-SG-NAME \
            --query 'SecurityGroups[0].GroupId' --output text)
  [ "${SG_ID}" != "None" ] || { echo "SG REDACTED-SG-NAME not found"; exit 1; }
  aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol -1 --source-group "${SG_ID}" >/dev/null 2>&1 || true
  AMI=$(aws ec2 describe-images --owners 099720109477 \
        --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  log "AMI=${AMI} SG=${SG_ID} AZ=${AZ} SUBNET=${SUBNET}"
  BDM='[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]'
  for NAME in "${TAGS[@]}"; do
    aws ec2 run-instances --image-id "${AMI}" --instance-type "${ITYPE}" \
      --key-name "${KEY_NAME}" --security-group-ids "${SG_ID}" --subnet-id "${SUBNET}" \
      --associate-public-ip-address \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}},{Key=spike,Value=v9}]" \
      --block-device-mappings "${BDM}" \
      --instance-initiated-shutdown-behavior terminate \
      --user-data "$(printf '#!/bin/bash\nshutdown -h +%d\n' "${WATCHDOG_MIN:-900}")" \
      --query 'Instances[0].InstanceId' --output text
  done
  log "waiting for running state"
  aws ec2 wait instance-running --filters "Name=tag:spike,Values=v9" "Name=instance-state-name,Values=pending,running"
  "$0" ips | tee "${HOSTS_ENV}"
  log "hosts.env written -> ${HOSTS_ENV}"
  ;;
ips)
  aws ec2 describe-instances --filters "Name=tag:spike,Values=v9" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PublicIpAddress,PrivateIpAddress,InstanceId]' \
    --output text | sort | while read -r n pub priv id; do
      case "${n}" in
        v9-registry) echo "REG_PUB=${pub}";   echo "REG_PRIV=${priv}";   echo "REG_ID=${id}";;
        v9-node1)    echo "NODE1_PUB=${pub}"; echo "NODE1_PRIV=${priv}"; echo "NODE1_ID=${id}";;
        v9-node2)    echo "NODE2_PUB=${pub}"; echo "NODE2_PRIV=${priv}"; echo "NODE2_ID=${id}";;
        v9-node3)    echo "NODE3_PUB=${pub}"; echo "NODE3_PRIV=${priv}"; echo "NODE3_ID=${id}";;
      esac
    done
  # node1 doubles as "the" node for the single-node campaigns
  echo "NODE_PUB=$(aws ec2 describe-instances --filters "Name=tag:spike,Values=v9" "Name=tag:Name,Values=v9-node1" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  echo "NODE_PRIV=$(aws ec2 describe-instances --filters "Name=tag:spike,Values=v9" "Name=tag:Name,Values=v9-node1" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  ;;
fsr)
  aws ec2 describe-fast-snapshot-restores \
    --query 'FastSnapshotRestores[].[SnapshotId,AvailabilityZone,State,StateTransitionReason]' --output text
  ;;
attach)
  # FSR is deliberately NOT required. v9 measured that an FSR registration starts
  # with an empty credit bucket -- a 1200 GiB snapshot earns its single credit in
  # ~70 minutes -- so a volume created soon after enabling is not fast-restored at
  # all (FastRestored=None, 61 MB/s at QD1). The replacement is 07b-fetch-blobs.sh,
  # which exploits the fact that a lazy restore is latency-bound and reads the
  # blobs it needs with 64-way range concurrency at ~340 MB/s. Gating the attach
  # on FSR here only blocked the rebuild.
  STATE=$(aws ec2 describe-fast-snapshot-restores --filters "Name=snapshot-id,Values=${ARTIFACT_SNAPSHOT}" "Name=availability-zone,Values=${AZ}" --query 'FastSnapshotRestores[0].State' --output text 2>/dev/null)
  log "FSR state for ${AZ}: ${STATE:-none} (not required)"
  . "${HOSTS_ENV}"
  VOL=$(aws ec2 create-volume --availability-zone "${AZ}" --snapshot-id "${ARTIFACT_SNAPSHOT}" \
        --size 1200 --volume-type gp3 --throughput 750 --iops 8000 \
        --tag-specifications 'ResourceType=volume,Tags=[{Key=spike,Value=v9},{Key=Name,Value=v9-artifacts}]' \
        --query VolumeId --output text)
  log "created ${VOL} from ${ARTIFACT_SNAPSHOT} (FSR ${STATE})"
  aws ec2 wait volume-available --volume-ids "${VOL}"
  aws ec2 attach-volume --volume-id "${VOL}" --instance-id "${REG_ID}" --device /dev/sdf >/dev/null
  aws ec2 wait volume-in-use --volume-ids "${VOL}"
  # DeleteOnTermination so teardown cannot leave a 1200 GB volume behind.
  aws ec2 modify-instance-attribute --instance-id "${REG_ID}" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"DeleteOnTermination\":true}}]"
  echo "ARTIFACT_VOL=${VOL}" | tee -a "${HOSTS_ENV}"
  log "attached ${VOL} -> ${REG_ID} at /dev/sdf, DeleteOnTermination=true"
  ;;
down)
  IDS=$(aws ec2 describe-instances --filters "Name=tag:spike,Values=v9" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -z "${IDS}" ]; then log "nothing to terminate"; else
    log "terminating: ${IDS}"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids ${IDS} --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids ${IDS}
  fi
  log "disabling Fast Snapshot Restore (it bills per hour while enabled)"
  aws ec2 disable-fast-snapshot-restores --source-snapshot-ids "${ARTIFACT_SNAPSHOT}" --availability-zones "${AZ}" \
    --query 'Successful[].[SnapshotId,AvailabilityZone,State]' --output text 2>&1 || true
  # Any volume the instances did not take with them.
  VOLS=$(aws ec2 describe-volumes --filters "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text)
  for v in ${VOLS}; do log "deleting stray volume ${v}"; aws ec2 delete-volume --volume-id "${v}" || true; done
  "$0" verify
  ;;
verify)
  echo "=== ALL instances in this account/region, any non-terminated state ==="
  aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`]|[0].Value]' --output table
  echo "non-terminated instance count = $(aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" --query 'length(Reservations[].Instances[])' --output text)"
  echo "=== ALL EBS volumes, any state (v9 requires zero) ==="
  aws ec2 describe-volumes --query 'Volumes[].[VolumeId,Size,State,CreateTime]' --output table
  echo "volume count = $(aws ec2 describe-volumes --query 'length(Volumes)' --output text)"
  echo "=== snapshots owned by this account (v9 keeps EXACTLY ONE: the v7 artifact snapshot) ==="
  aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime]' --output table
  echo "snapshot count = $(aws ec2 describe-snapshots --owner-ids self --query 'length(Snapshots)' --output text)"
  echo "=== fast snapshot restores (v9 requires none left enabled) ==="
  aws ec2 describe-fast-snapshot-restores --query 'FastSnapshotRestores[].[SnapshotId,AvailabilityZone,State]' --output table
  echo "=== AMIs owned by this account (v9 requires zero) ==="
  aws ec2 describe-images --owners self --query 'Images[].[ImageId,Name]' --output table
  echo "image count = $(aws ec2 describe-images --owners self --query 'length(Images)' --output text)"
  ;;
esac
