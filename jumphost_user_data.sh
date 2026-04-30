#!/bin/bash

# Update system
yum update -y

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# Install kubectl (version matches the EKS cluster)
curl -LO "https://dl.k8s.io/release/v${kubernetes_version}.0/bin/linux/amd64/kubectl"
chmod +x ./kubectl
mv ./kubectl /usr/local/bin/kubectl

# Install eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
mv /tmp/eksctl /usr/local/bin

# Install Docker
yum install -y docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Create a welcome message
cat > /etc/motd << EOF
Welcome to ${project_name} Jumphost!

This instance is configured with:
- AWS CLI v2
- kubectl
- eksctl
- Docker
- Helm

To connect to the EKS cluster, run:
aws eks update-kubeconfig --region ${aws_region} --name ${project_name}-eks

Then you can use kubectl to manage your cluster.
EOF

# Set up bash completion for kubectl
echo 'source <(kubectl completion bash)' >> /home/ec2-user/.bashrc
echo 'alias k=kubectl' >> /home/ec2-user/.bashrc
echo 'complete -F __start_kubectl k' >> /home/ec2-user/.bashrc

