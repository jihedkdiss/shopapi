#!/usr/bin/env bash
# Removes everything aws-setup.sh created. The OIDC provider is kept unless KEEP_OIDC=0.
set -uo pipefail
REGION="${AWS_REGION:-eu-west-3}"; NAME=shopapi
export AWS_REGION="$REGION" AWS_PAGER=""
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

IDS=$(aws ec2 describe-instances --filters Name=tag:Name,Values="$NAME" Name=instance-state-name,Values=pending,running,stopped,stopping \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then aws ec2 terminate-instances --instance-ids $IDS >/dev/null; aws ec2 wait instance-terminated --instance-ids $IDS; echo "terminated $IDS"; fi

SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$NAME-web" --query 'SecurityGroups[0].GroupId' --output text)
[ "$SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$SG_ID" && echo "deleted $SG_ID"

aws ecr delete-repository --repository-name "$NAME" --force >/dev/null 2>&1 && echo "deleted ECR repo"

aws iam delete-role-policy --role-name "$NAME-gha-deploy" --policy-name deploy 2>/dev/null
aws iam delete-role --role-name "$NAME-gha-deploy" 2>/dev/null && echo "deleted deploy role"

aws iam remove-role-from-instance-profile --instance-profile-name "$NAME-ec2" --role-name "$NAME-ec2" 2>/dev/null
aws iam delete-instance-profile --instance-profile-name "$NAME-ec2" 2>/dev/null
for p in AmazonSSMManagedInstanceCore AmazonEC2ContainerRegistryReadOnly; do
  aws iam detach-role-policy --role-name "$NAME-ec2" --policy-arn arn:aws:iam::aws:policy/$p 2>/dev/null; done
aws iam delete-role --role-name "$NAME-ec2" 2>/dev/null && echo "deleted instance role"

if [ "${KEEP_OIDC:-1}" = "0" ]; then
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com" && echo "deleted OIDC provider"
fi
