# AWS POC Infrastructure

Private EKS cluster in `ap-south-1` spread across 3 AZs, with a jumphost for SSH-tunnelled kubectl access from a non-static-IP laptop.

## Architecture

```
Internet
    │
    ▼
Internet Gateway
    │
Public Subnet (10.0.1.0/24) — ap-south-1a
    ├── Jumphost EC2 (public IP, SSH access)
    └── NAT Gateway (EIP)
          │
          ▼ (default route for all private subnets)
┌─────────────────────────────────────────────────────┐
│                 Private VPC (10.0.0.0/16)           │
│                                                     │
│  Private Subnet 1 (10.0.10.0/24) — ap-south-1a     │
│  Private Subnet 2 (10.0.20.0/24) — ap-south-1b     │
│  Private Subnet 3 (10.0.30.0/24) — ap-south-1c     │
│                                                     │
│  EKS Cluster (private endpoint only)                │
│  EKS Managed Node Group (1 node per subnet)         │
└─────────────────────────────────────────────────────┘
```

Local kubectl traffic flows: `laptop → SSH tunnel → jumphost → EKS API (private IP)`.

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.0
- IAM permissions: VPC, EC2, EKS, IAM role creation

## Deploy

```bash
# 1. Initialise (only needed once, or after .terraform is deleted)
terraform init

# 2. Preview
terraform plan

# 3. Apply (~15 min for EKS cluster + node group)
terraform apply
```

> **`terraform.tfvars` is already configured** for `ap-south-1` with project name `csa-gg`.
> Edit it only if you need to change the region, node count, or instance types.

## Post-Apply: Save Your SSH Key

Run this immediately after apply — the key is only in Terraform state:

```bash
bash get_private_key.sh
```

This saves `~/.ssh/{key_pair_name}.pem` with `chmod 600`. Verify:

```bash
terraform output key_pair_name   # shows the key filename
ls -la ~/.ssh/csa-gg-ap-south-1-keypair.pem
```

## Access the Jumphost

```bash
# Use the exact command from Terraform outputs
terraform output -raw ssh_command | bash

# Or manually:
ssh -i ~/.ssh/csa-gg-ap-south-1-keypair.pem ec2-user@<jumphost_public_ip>
```

The jumphost comes pre-installed with: AWS CLI v2, kubectl (matching cluster version), eksctl, Docker, Helm.

From the jumphost, kubectl works directly (it's inside the VPC):

```bash
aws eks update-kubeconfig --region ap-south-1 --name csa-gg-eks
kubectl get nodes
```

## Access EKS from Your Laptop (SSH Tunnel)

The EKS API endpoint is **private only** (`endpoint_public_access = false`). Kubectl on your laptop requires an SSH tunnel through the jumphost.

### Step 1 — Start the tunnel (keep this terminal open)

```bash
bash start_tunnel.sh
```

This resolves the EKS endpoint automatically via `terraform output` and forwards `localhost:9443` to the EKS API.

### Step 2 — Configure kubectl (one-time after each apply)

```bash
# Add the cluster to your kubeconfig
aws eks update-kubeconfig --region ap-south-1 --name csa-gg-eks

# Point the cluster to the tunnel instead of the public endpoint
CLUSTER_ARN=$(terraform output -raw eks_cluster_arn)
kubectl config set-cluster "$CLUSTER_ARN" \
  --server=https://localhost:9443 \
  --insecure-skip-tls-verify=true
```

### Step 3 — Use kubectl

```bash
kubectl get nodes
kubectl get pods -A
```

### Stop the tunnel

```bash
# Ctrl+C in the tunnel terminal, or:
pkill -f "9443:"
```

## Configuration

| Variable | Description | Default (tfvars) |
|----------|-------------|-----------------|
| `aws_region` | AWS region | `ap-south-1` |
| `project_name` | Prefix for all resource names | `csa-gg` |
| `vpc_cidr` | VPC CIDR | `10.0.0.0/16` |
| `kubernetes_version` | EKS Kubernetes version | `1.30` |
| `node_group_desired_size` | Node count (desired) | `3` |
| `node_group_min_size` | Node count (min) | `3` |
| `node_group_max_size` | Node count (max) | `4` |
| `node_instance_type` | EKS node EC2 type | `t3.medium` |
| `jumphost_instance_type` | Jumphost EC2 type | `t3.micro` |

Key pair name follows the pattern: `{project_name}-{aws_region}-keypair`

## Outputs

```bash
terraform output                          # all outputs
terraform output -raw jumphost_public_ip  # jumphost IP
terraform output -raw eks_cluster_id      # cluster name
terraform output -raw nat_gateway_ip      # NAT EIP
terraform output -raw ssh_command         # ready-to-run SSH command
terraform output -raw kubectl_config_command  # aws eks update-kubeconfig command
```

## Teardown

```bash
terraform destroy
```

All resources are destroyed including the EKS cluster, nodes, NAT gateway, and VPC.
The SSH key in `~/.ssh/` is local and must be deleted manually if needed.

## Troubleshooting

### kubectl on jumphost: connection refused on localhost:8080

kubectl has no kubeconfig yet. Run:

```bash
aws eks update-kubeconfig --region ap-south-1 --name csa-gg-eks
kubectl get nodes
```

If `aws eks update-kubeconfig` fails with a credentials error, the jumphost has no IAM instance profile and cannot call AWS APIs on its own. Temporarily configure credentials:

```bash
aws configure
# Access Key ID, Secret Access Key, region: ap-south-1, format: json
aws eks update-kubeconfig --region ap-south-1 --name csa-gg-eks
```

> **Note:** Manually configuring credentials on the jumphost is a workaround. The permanent fix is to attach an IAM instance profile to the jumphost EC2 instance in Terraform.

### Nodes not Ready after apply
- Wait ~5 min after node group creation for nodes to bootstrap
- Check from jumphost: `kubectl describe node <name>` for events
- Verify NAT gateway exists: `terraform output nat_gateway_ip`

### kubectl: connection refused on localhost:9443
- The tunnel is not running. Run `bash start_tunnel.sh` in a separate terminal
- Check the tunnel is up: `lsof -i :9443`

### SSH tunnel fails immediately
- Confirm the key is saved: `ls ~/.ssh/csa-gg-ap-south-1-keypair.pem`
- Confirm the jumphost is reachable: `terraform output -raw jumphost_public_ip`
- Re-run `bash get_private_key.sh` if the key file is missing

### Image pull errors on pods
- Confirm NAT gateway is present: `terraform output nat_gateway_ip` should show an IP
- Check node internet access from jumphost:
  ```bash
  kubectl debug node/<node-name> -it --image=busybox -- wget -qO- http://example.com
  ```

### Useful commands

```bash
terraform show                         # full state dump
terraform state list                   # list all resources
terraform state show aws_eks_cluster.main  # inspect EKS cluster resource
```
