#!/usr/bin/env bash
# One-time AWS setup for the shopapi pipeline (instructor runs this, not participants).
# Creates: GitHub OIDC provider, ECR repo, deploy role for GitHub, EC2 instance role,
# security group (port 80 only, no SSH), and one hardened EC2 instance running Docker.
# Usage: GH_REPO=<owner>/shopapi ./deploy/aws-setup.sh      (uses your current AWS profile)
set -euo pipefail

GH_REPO="${GH_REPO:?set GH_REPO=<owner>/shopapi}"
REGION="${AWS_REGION:-eu-west-3}"
NAME=shopapi
export AWS_REGION="$REGION" AWS_PAGER=""

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
OIDC_ARN="arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
echo "Account $ACCOUNT, region $REGION, repo $GH_REPO"

# 1. GitHub OIDC identity provider (one per account)
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  echo "created OIDC provider"
fi

# 2. ECR repository: immutable tags, scan on push
aws ecr describe-repositories --repository-names "$NAME" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$NAME" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true >/dev/null
REPO_ARN="arn:aws:ecr:$REGION:$ACCOUNT:repository/$NAME"

# 3. EC2 instance role: SSM agent + pull from ECR. Nothing else.
if ! aws iam get-role --role-name "$NAME-ec2" >/dev/null 2>&1; then
  aws iam create-role --role-name "$NAME-ec2" --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$NAME-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam attach-role-policy --role-name "$NAME-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
  aws iam create-instance-profile --instance-profile-name "$NAME-ec2" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$NAME-ec2" --role-name "$NAME-ec2"
  echo "created instance role; waiting for IAM to propagate"; sleep 15
fi

# 4. Security group: HTTP in from anywhere (the app + ZAP), no SSH.
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$NAME-web" Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$NAME-web" --description "shopapi HTTP only, no SSH" --vpc-id "$VPC_ID" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description="public HTTP"}]' >/dev/null
fi

# 5. EC2 instance: Amazon Linux 2023, IMDSv2 required, Docker, /opt/deploy.sh
INSTANCE_ID=$(aws ec2 describe-instances --filters Name=tag:Name,Values="$NAME" Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$INSTANCE_ID" = "None" ]; then
  AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
  USERDATA=$(cat <<EOF
#!/bin/bash
dnf install -y docker
systemctl enable --now docker
cat > /opt/deploy.sh <<'SCRIPT'
#!/bin/bash
# Pull one exact image tag from ECR and (re)start the container.
set -euo pipefail
TAG="\$1"
REGISTRY="$REGISTRY"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "\$REGISTRY"
docker pull "\$REGISTRY/$NAME:\$TAG"
docker rm -f $NAME 2>/dev/null || true
docker run -d --name $NAME --restart unless-stopped -p 80:3000 \\
  --read-only --cap-drop ALL --security-opt no-new-privileges -e APP_VERSION="\$TAG" "\$REGISTRY/$NAME:\$TAG"
sleep 3
curl -fsS http://localhost/health && echo " deployed \$TAG"
SCRIPT
chmod 755 /opt/deploy.sh
EOF
)
  INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro \
    --iam-instance-profile Name="$NAME-ec2" --security-group-ids "$SG_ID" \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=true}' \
    --user-data "$USERDATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "launched $INSTANCE_ID"
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
fi
INSTANCE_ARN="arn:aws:ec2:$REGION:$ACCOUNT:instance/$INSTANCE_ID"

# 6. Deploy role for GitHub Actions: only this repo's main branch can assume it.
TRUST=$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Federated":"$OIDC_ARN"},
 "Action":"sts:AssumeRoleWithWebIdentity",
 "Condition":{"StringEquals":{
   "token.actions.githubusercontent.com:aud":"sts.amazonaws.com",
   "token.actions.githubusercontent.com:sub":"repo:$GH_REPO:ref:refs/heads/main"}}}]}
EOF
)
POLICY=$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart",
   "ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage"],"Resource":"$REPO_ARN"},
 {"Effect":"Allow","Action":"ssm:SendCommand","Resource":["$INSTANCE_ARN",
   "arn:aws:ssm:$REGION::document/AWS-RunShellScript"]},
 {"Effect":"Allow","Action":["ssm:GetCommandInvocation","ssm:ListCommandInvocations"],"Resource":"*"}]}
EOF
)
if aws iam get-role --role-name "$NAME-gha-deploy" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$NAME-gha-deploy" --policy-document "$TRUST"
else
  aws iam create-role --role-name "$NAME-gha-deploy" --assume-role-policy-document "$TRUST" >/dev/null
fi
aws iam put-role-policy --role-name "$NAME-gha-deploy" --policy-name deploy --policy-document "$POLICY"
ROLE_ARN=$(aws iam get-role --role-name "$NAME-gha-deploy" --query Role.Arn --output text)
APP_HOST=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicDnsName' --output text)

echo
echo "Set these as GitHub repository variables (Settings > Secrets and variables > Actions > Variables):"
echo "  AWS_ROLE_ARN    = $ROLE_ARN"
echo "  EC2_INSTANCE_ID = $INSTANCE_ID"
echo "  APP_HOST        = $APP_HOST"
echo
echo "Or with the gh CLI:"
echo "  gh variable set AWS_ROLE_ARN -R $GH_REPO -b $ROLE_ARN"
echo "  gh variable set EC2_INSTANCE_ID -R $GH_REPO -b $INSTANCE_ID"
echo "  gh variable set APP_HOST -R $GH_REPO -b $APP_HOST"
