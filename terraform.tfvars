# AWS Configuration
aws_region = "ap-south-1"

# Project Configuration
project_name = "csa-gg"

# VPC Configuration
vpc_cidr = "10.0.0.0/16"
public_subnet_cidr = "10.0.1.0/24"
private_subnet_cidrs = ["10.0.10.0/24", "10.0.20.0/24", "10.0.30.0/24"]

# EKS Configuration
# Use a currently supported EKS Kubernetes version
kubernetes_version = "1.35"
node_group_desired_size = 3
node_group_max_size = 4
node_group_min_size = 3
node_instance_type = "t3.medium"

# Jumphost Configuration
jumphost_instance_type = "t3.micro"

