
#!/usr/bin/env bash

set -Eeuo pipefail

# AWS configuration
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

# Snapshot configuration
TIMESTAMP="$(date -u +'%Y-%m-%d-%H-%M-%S')"
LOG_FILE="ec2-snapshot-${TIMESTAMP}.log"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
}

list_instances() {
  aws ec2 describe-instances \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
    --output table
}

count_instances() {
  aws ec2 describe-instances \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'length(Reservations[].Instances[])' \
    --output text
}

create_snapshots() {
  local instance_ids instance_id volume_ids volume_id snapshot_id
  local success=0 failed=0

  instance_ids="$(aws ec2 describe-instances \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)"

  if [[ -z "$instance_ids" || "$instance_ids" == "None" ]]; then
    log "No running or stopped EC2 instances found."
    return 0
  fi

  for instance_id in $instance_ids; do
    log "Processing instance: $instance_id"

    volume_ids="$(aws ec2 describe-instances \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --instance-ids "$instance_id" \
      --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' \
      --output text)"

    if [[ -z "$volume_ids" || "$volume_ids" == "None" ]]; then
      log "No EBS volumes found for $instance_id"
      continue
    fi

    for volume_id in $volume_ids; do
      log "Creating snapshot for volume: $volume_id"

      if snapshot_id="$(aws ec2 create-snapshot \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --volume-id "$volume_id" \
        --description "Backup of ${instance_id} at ${TIMESTAMP}" \
        --tag-specifications \
        "ResourceType=snapshot,Tags=[{Key=Name,Value=ec2-${instance_id}-${volume_id}-${TIMESTAMP}},{Key=Backup,Value=EC2-Snapshot},{Key=SourceInstanceId,Value=${instance_id}}]" \
        --query SnapshotId \
        --output text 2>>"$LOG_FILE")"; then

        log "Snapshot request successful: $snapshot_id"
        success=$((success + 1))
      else
        log "ERROR: Snapshot creation failed for $volume_id"
        failed=$((failed + 1))
      fi
    done
  done

  log "Snapshot requests successful: $success"
  log "Snapshot requests failed: $failed"
  log "Log file: $LOG_FILE"

  if (( failed > 0 )); then
    return 1
  fi
}

# Validate AWS credentials
if ! aws sts get-caller-identity \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "ERROR: Invalid AWS credentials/profile."
  exit 1
fi

while getopts ":LCS" option; do
  case "$option" in
    L)
      list_instances
      ;;
    C)
      count_instances
      ;;
    S)
      create_snapshots
      ;;
    *)
      echo "Invalid option. Please provide: L, C, S"
      exit 1
      ;;
  esac
done

if (( OPTIND == 1 )); then
  echo "Usage: $0 [-L] [-C] [-S]"
  echo "  -L  List EC2 instances"
  echo "  -C  Count EC2 instances"
  echo "  -S  Create EBS snapshots"
  exit 1
fi
