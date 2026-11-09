#!/usr/bin/env bash
# Live review helper: proves each client check from the stack outputs.
# Usage: scripts/demo.sh <check> [stack-name]
#   checks: outputs | balance | health | load | stop-load | scale | kill-one | kill-az | private | egress | token
set -euo pipefail                                         # stop on errors and unset variables

CHECK="${1:-outputs}"                                     # which proof to run
STACK="${2:-${STACK_NAME:-onward-logistics-lab}}"         # stack name (arg, env var, or default)
REGION="${AWS_REGION:-$(aws configure get region)}"       # region (env var or CLI default)

# out <Key>: read one output value from the stack.
out() {
  aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

ALB="$(out AlbDnsName)"                                   # public URL of the ALB
ASG="$(out AsgName)"                                      # Auto Scaling Group name
TG="$(out TargetGroupArn)"                                # target group ARN

# instances: table of ASG members with AZ, lifecycle state and health.
instances() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --region "$REGION" \
    --query "AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]" --output table
}

case "$CHECK" in
  outputs)   # 1. Single public address
    aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query "Stacks[0].Outputs" --output table ;;
  balance)   # 2. Requests shared across servers
    for i in $(seq 1 20); do curl -s "$ALB/whoami" | python -c "import json,sys;d=json.load(sys.stdin);print(d['instance_id'],d['availability_zone'])"; done | sort | uniq -c ;;
  health)    # Target group health view
    aws elbv2 describe-target-health --target-group-arn "$TG" --region "$REGION" \
      --query "TargetHealthDescriptions[].[Target.Id,Target.AvailabilityZone,TargetHealth.State]" --output table ;;
  load)      # 3. Spike: stress-ng on every ASG instance through SSM Run Command (5 min)
    aws ssm send-command --region "$REGION" --document-name "AWS-RunShellScript" \
      --targets "Key=tag:aws:autoscaling:groupName,Values=$ASG" \
      --parameters 'commands=["dnf -y install stress-ng","nice -n 19 stress-ng --cpu 0 --timeout 300s"]' \
      --comment "Onward sales day spike" --query "Command.CommandId" --output text ;;
  stop-load)
    aws ssm send-command --region "$REGION" --document-name "AWS-RunShellScript" \
      --targets "Key=tag:aws:autoscaling:groupName,Values=$ASG" \
      --parameters 'commands=["pkill stress-ng || true"]' --query "Command.CommandId" --output text ;;
  scale)     # 3. Watch capacity and recent scaling activity
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --region "$REGION" \
      --query "AutoScalingGroups[0].[MinSize,DesiredCapacity,MaxSize]" --output text
    instances
    aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" --region "$REGION" \
      --max-items 6 --query "Activities[].[StartTime,StatusCode,Description]" --output table ;;
  kill-one)  # 4. Failed server replaced automatically
    ID="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --region "$REGION" \
      --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text)"
    echo "Terminating $ID"
    aws ec2 terminate-instances --instance-ids "$ID" --region "$REGION" --output table ;;
  kill-az)   # 5. Simulate AZ loss: terminate every instance in the first AZ
    AZ="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --region "$REGION" \
      --query "AutoScalingGroups[0].Instances[0].AvailabilityZone" --output text)"
    IDS="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --region "$REGION" \
      --query "AutoScalingGroups[0].Instances[?AvailabilityZone=='$AZ'].InstanceId" --output text)"
    echo "Terminating all instances in $AZ: $IDS"
    aws ec2 terminate-instances --instance-ids $IDS --region "$REGION" --output table
    echo "Now keep refreshing $ALB, it is served from the other AZ." ;;
  private)   # 6a. No public IPs, no CIDR ingress, no port 22
    aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" "Name=instance-state-name,Values=running" \
      --query "Reservations[].Instances[].[InstanceId,SubnetId,PrivateIpAddress,PublicIpAddress||'NONE']" --output table
    SG="$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" \
      --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)"
    aws ec2 describe-security-group-rules --region "$REGION" --filters "Name=group-id,Values=$SG" \
      --query "SecurityGroupRules[].[IsEgress,IpProtocol,FromPort,ToPort,CidrIpv4||ReferencedGroupInfo.GroupId]" --output table ;;
  egress)    # 6b. Servers can still download updates (through the Regional NAT)
    aws ec2 describe-route-tables --route-table-ids "$(out PrivateRouteTableId)" --region "$REGION" \
      --query "RouteTables[0].Routes[].[DestinationCidrBlock,NatGatewayId||GatewayId]" --output table
    ID="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --region "$REGION" \
      --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text)"
    CMD="$(aws ssm send-command --region "$REGION" --instance-ids "$ID" --document-name "AWS-RunShellScript" \
      --parameters 'commands=["curl -sI https://aws.amazon.com | head -1","dnf -q check-update | tail -3; echo dnf exit $?"]' \
      --query "Command.CommandId" --output text)"
    sleep 6
    aws ssm get-command-invocation --command-id "$CMD" --instance-id "$ID" --region "$REGION" \
      --query "StandardOutputContent" --output text ;;
  token)     # Load token for the web "Generate load" button (do not commit it)
    aws secretsmanager get-secret-value --secret-id "$(out TokenSecretArn)" --region "$REGION" \
      --query SecretString --output text ;;
  *)
    sed -n '2,5p' "$0"; exit 1 ;;
esac
