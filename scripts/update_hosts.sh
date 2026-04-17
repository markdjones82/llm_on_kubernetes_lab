#!/usr/bin/env bash
set -euo pipefail

# Usage: ./update_hosts.sh [env] [region]
# Example: ./update_hosts.sh poc us-east-1
ENV=${1:-poc}
REGION=${2:-us-east-1}

# Find running instances for this env and collect InstanceId, PrivateIpAddress, Name tag
mapfile -t rows < <(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:env,Values=$ENV" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,Tags[?Key==`Name`].Value|[0]]' --output text)

if [ ${#rows[@]} -eq 0 ]; then
  echo "No running instances found for env=$ENV in $REGION"
  exit 1
fi

instance_ids=()
commands=()
for row in "${rows[@]}"; do
  # row format: <InstanceId> <PrivateIpAddress> <Name>
  read -r instance_id ip name <<<"$row"
  if [ -z "$name" ] || [ "$name" = "None" ]; then
    name="$instance_id"
  fi
  instance_ids+=("$instance_id")
  # build idempotent append command for /etc/hosts
  commands+=("grep -qF '$ip $name' /etc/hosts || echo '$ip $name' >> /etc/hosts")
done

# Join instance ids
targets=$(printf "%s " "${instance_ids[@]}")

# Build combined shell script to run via SSM
ssm_script="#!/bin/bash\nset -euo pipefail\n"
for cmd in "${commands[@]}"; do
  ssm_script+="$cmd\n"
done

# Send SSM command to all instances (they must have SSM agent + IAM role)
aws ssm send-command \
  --region "$REGION" \
  --instance-ids ${targets} \
  --document-name "AWS-RunShellScript" \
  --comment "Update /etc/hosts with lab hostnames" \
  --parameters commands="$ssm_script" \
  --output json

echo "SSM command sent to instances: ${instance_ids[*]}"
