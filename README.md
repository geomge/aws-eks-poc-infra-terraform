# AWS POC Infrastructure

This Terraform project creates a comprehensive AWS infrastructure setup including:

- **Private VPC** with 3 subnets across different availability zones
- **Jumphost** with public IP for secure access to the VPC
- **EKS Cluster** with 3 worker nodes
- **NAT Gateway** for outbound internet access from private subnets
- **Security Groups** with appropriate rules

## Architecture

```
Internet Gateway
        |
    Public Subnet (10.0.1.0/24)
        |
    NAT Gateway
        |
    ┌─────────────────────────────────────┐
    │           Private VPC               │
    │         (10.0.0.0/16)               │
    │                                     │
    │  Private Subnet 1  Private Subnet 2 │
    │  (10.0.10.0/24)   (10.0.20.0/24)   │
    │                                     │
    │  Private Subnet 3                   │
    │  (10.0.30.0/24)                     │
    │                                     │
    │  EKS Cluster + Nodes                │
    └─────────────────────────────────────┘
```

## Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Terraform** >= 1.0 installed
3. **AWS Account** with sufficient permissions for:
   - VPC creation
   - EC2 instances
   - EKS cluster creation
   - IAM role creation
   - Key pair creation

## Quick Start

1. **Clone and navigate to the project:**
   ```bash
   cd /Users/ggeorge/playground/aws-poc-infra
   ```

2. **Create your terraform.tfvars file:**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. **Edit terraform.tfvars with your values:**
   ```bash
   # Optional: Modify values as needed
   aws_region = "us-west-2"
   project_name = "my-aws-poc"
   
   # Note: AWS Key Pair is automatically generated
   # The keypair will be named: {project_name}-{aws_region}-keypair
   ```

4. **Initialize Terraform:**
   ```bash
   terraform init
   ```

5. **Plan the deployment:**
   ```bash
   terraform plan
   ```

6. **Apply the configuration:**
   ```bash
   terraform apply
   ```

## Configuration

### Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region for resources | `us-west-2` | No |
| `project_name` | Name prefix for all resources | `aws-poc` | No |
| `vpc_cidr` | CIDR block for VPC | `10.0.0.0/16` | No |
| `public_subnet_cidr` | CIDR for public subnet | `10.0.1.0/24` | No |
| `private_subnet_cidrs` | CIDR blocks for private subnets | `["10.0.10.0/24", "10.0.20.0/24", "10.0.30.0/24"]` | No |
| `kubernetes_version` | EKS Kubernetes version | `1.28` | No |
| `node_group_desired_size` | Desired number of EKS nodes | `3` | No |
| `node_instance_type` | EC2 instance type for EKS nodes | `t3.medium` | No |
| `jumphost_instance_type` | EC2 instance type for jumphost | `t3.micro` | No |

**Note**: AWS Key Pair is automatically generated with the name `{project_name}-{aws_region}-keypair`

## Automatic Keypair Generation

This project automatically generates an AWS keypair for secure access to the jumphost:

- **Key Type**: 4096-bit RSA key
- **Naming Convention**: `{project_name}-{aws_region}-keypair`
- **Example**: For project `my-poc` in region `us-west-2`, the keypair will be named `my-poc-us-west-2-keypair`
- **Security**: Private key is marked as sensitive in Terraform outputs
- **No Manual Setup**: No need to create keypairs manually in AWS Console

### Getting Your Private Key

After `terraform apply`, retrieve your private key:

```bash
# Save the private key to your local machine
terraform output -raw private_key_pem > ~/.ssh/my-poc-us-west-2-keypair.pem

# Set correct permissions
chmod 600 ~/.ssh/my-poc-us-west-2-keypair.pem

# Use the generated SSH command from outputs
terraform output ssh_command
```

## Accessing Your Infrastructure

### Connect to Jumphost

After deployment, you can SSH to the jumphost:

1. **Get the private key from Terraform outputs:**
   ```bash
   terraform output -raw private_key_pem > ~/.ssh/my-project-us-west-2-keypair.pem
   chmod 600 ~/.ssh/my-project-us-west-2-keypair.pem
   ```

2. **SSH to the jumphost:**
   ```bash
   # The SSH command will be displayed in terraform outputs
   ssh -i ~/.ssh/my-project-us-west-2-keypair.pem ec2-user@<jumphost-public-ip>
   ```

### Access EKS Cluster

1. **From your local machine:**
   ```bash
   aws eks update-kubeconfig --region us-west-2 --name aws-poc-eks
   kubectl get nodes
   ```

2. **From the jumphost:**
   ```bash
   # SSH to jumphost first (use the generated keypair)
   ssh -i ~/.ssh/my-project-us-west-2-keypair.pem ec2-user@<jumphost-public-ip>
   
   # Configure kubectl
   aws eks update-kubeconfig --region us-west-2 --name aws-poc-eks
   
   # Verify cluster access
   kubectl get nodes
   ```

## Jumphost Features

The jumphost comes pre-installed with:
- AWS CLI v2
- kubectl
- eksctl
- Docker
- Helm
- Bash completion for kubectl

## Security Considerations

- **Private Subnets**: EKS nodes are deployed in private subnets with no direct internet access
- **NAT Gateway**: Provides outbound internet access for private resources
- **Security Groups**: Restrictive rules allowing only necessary traffic
- **Jumphost**: Single point of access with SSH key authentication
- **EKS Endpoint**: Private endpoint only (no public access)
- **Auto-Generated Keypair**: SSH keypair is automatically generated with 4096-bit RSA encryption

## Cost Optimization

- **Instance Types**: Uses t3.micro for jumphost and t3.medium for EKS nodes
- **Auto Scaling**: EKS node group can scale from 1 to 6 nodes based on demand
- **NAT Gateway**: Consider using NAT Instance for lower costs in non-production environments

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Note**: This will delete all resources including the EKS cluster and any data stored in it.

## Troubleshooting

### Common Issues

1. **Insufficient Permissions**: Verify your AWS credentials have the necessary IAM permissions
2. **Resource Limits**: Check AWS service limits for your account
3. **EKS Cluster Not Accessible**: Ensure kubectl is configured with the correct cluster context
4. **SSH Connection Issues**: Ensure the private key has correct permissions (600) and is saved in the right location

### Useful Commands

```bash
# Check Terraform state
terraform show

# List all resources
terraform state list

# Get specific resource details
terraform state show aws_eks_cluster.main

# Refresh state
terraform refresh
```

## Outputs

After successful deployment, Terraform will output:
- VPC and subnet IDs
- Jumphost public/private IPs
- EKS cluster details
- **Generated keypair name** (`key_pair_name`)
- **Private key in PEM format** (`private_key_pem`) - marked as sensitive
- **Public key in OpenSSH format** (`public_key_openssh`)
- SSH command for jumphost access
- kubectl configuration command

## Support

For issues or questions:
1. Check AWS CloudTrail for API call errors
2. Review Terraform logs for deployment issues
3. Verify AWS service status
4. Check IAM permissions and policies

