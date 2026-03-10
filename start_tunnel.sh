ENDPOINT=$(aws eks describe-cluster --region ap-south-1 --name csa-gg-eks --query 'cluster.endpoint' --output text)
HOST=$(echo "$ENDPOINT" | sed -e 's|https://||' -e 's|/||g')

# Start tunnel (keep this terminal open)
ssh -i ~/.ssh/$(terraform output -raw key_pair_name).pem -NL 9443:${HOST}:443 ec2-user@$(terraform output -raw jumphost_public_ip)