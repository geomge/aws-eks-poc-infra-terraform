#!/bin/bash

REGION=$(terraform output -raw aws_region)
CLUSTER=$(terraform output -raw eks_cluster_id)
KEYPATH=~/.ssh/$(terraform output -raw key_pair_name).pem
JUMPHOST=$(terraform output -raw jumphost_public_ip)

ENDPOINT=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
  --query 'cluster.endpoint' --output text)
HOST=$(echo "$ENDPOINT" | sed -e 's|https://||' -e 's|/||g')

SSH_OPTS=(
  -i "$KEYPATH"
  -NL 9443:"${HOST}":443
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=6
  -o ExitOnForwardFailure=yes
  -o TCPKeepAlive=yes
)

echo "Tunneling localhost:9443 → EKS API ($HOST) via jumphost ($JUMPHOST)"
echo "kubectl must point to https://localhost:9443"

if command -v autossh &>/dev/null; then
  echo "autossh detected — tunnel will auto-reconnect on drop"
  autossh -M 0 "${SSH_OPTS[@]}" ec2-user@"$JUMPHOST"
else
  echo "Tip: install autossh for auto-reconnect on drop (brew install autossh)"
  ssh "${SSH_OPTS[@]}" ec2-user@"$JUMPHOST"
fi
