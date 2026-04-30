#!/bin/bash

REGION=$(terraform output -raw aws_region)
CLUSTER=$(terraform output -raw eks_cluster_id)
KEYPATH=~/.ssh/$(terraform output -raw key_pair_name).pem
JUMPHOST=$(terraform output -raw jumphost_public_ip)

ENDPOINT=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
  --query 'cluster.endpoint' --output text)
HOST=$(echo "$ENDPOINT" | sed -e 's|https://||' -e 's|/||g')

echo "Tunneling localhost:9443 → EKS API ($HOST) via jumphost ($JUMPHOST)"
echo "Keep this terminal open. kubectl must point to https://localhost:9443"
ssh -NL 9443:"${HOST}":443 ec2-user@"$JUMPHOST" -i "$KEYPATH"
