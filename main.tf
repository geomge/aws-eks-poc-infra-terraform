terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
  backend "s3" {
    bucket = "csa-gg-bucket"
    key    = "aws-poc-infra/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" {
  region = var.aws_region
  
  # Default tags applied to all resources that support them
  # Exceptions: IAM roles, policies, and some data sources don't support default tags
  default_tags {
    tags = local.org_tags
  }
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# Generate private key
resource "tls_private_key" "main" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create AWS key pair
resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-${var.aws_region}-keypair"
  public_key = tls_private_key.main.public_key_openssh

  tags = {
    Name = "${var.project_name}-keypair"
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Public Subnet for Jumphost
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
    "kubernetes.io/role/elb" = "1"
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-subnet-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Route Table Association for Public Subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  # Explicit dependency ensures the EIP is fully released before the IGW is detached.
  # Without this, "terraform destroy" can fail with DependencyViolation ("mapped public address").
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "${var.project_name}-nat-gateway"
  }

  depends_on = [aws_internet_gateway.main]
}

# Route Table for Private Subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

# Route Table Associations for Private Subnets
resource "aws_route_table_association" "private" {
  count = 3

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# EKS control plane creates ENIs in the private subnets that are owned by AWS (not the caller).
# After cluster deletion AWS cleans them up asynchronously, which takes ~60-90 seconds.
# Without this delay, "terraform destroy" tries to delete subnets before the ENIs are gone
# and fails with AuthFailure (the ENIs cannot be removed by the caller's credentials).
#
# Dependency chain exploits Terraform's destroy-order inversion:
#   Create:  subnets → time_sleep → eks_cluster
#   Destroy: eks_cluster → time_sleep (90s wait) → subnets
resource "time_sleep" "wait_for_cluster_eni_cleanup" {
  depends_on       = [aws_subnet.private, aws_subnet.public]
  destroy_duration = "90s"
}

# Security Group for Jumphost
resource "aws_security_group" "jumphost" {
  name_prefix = "${var.project_name}-jumphost-"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-jumphost-sg"
  }
}

# Security Group for EKS Cluster (control plane ENIs)
resource "aws_security_group" "eks_cluster" {
  name_prefix = "${var.project_name}-eks-cluster-"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-eks-cluster-sg"
  }
}

# Security Group for EKS Nodes
resource "aws_security_group" "eks_nodes" {
  name_prefix = "${var.project_name}-eks-nodes-"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-eks-nodes-sg"
  }
}

# All SG rules are managed as standalone aws_security_group_rule resources.
# Mixing inline ingress/egress blocks with standalone rules causes Terraform state
# drift where standalone-rule-managed entries appear as phantom inline rules on refresh.

# Jumphost rules
resource "aws_security_group_rule" "jumphost_ingress_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = aws_security_group.jumphost.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "SSH from internet"
}

resource "aws_security_group_rule" "jumphost_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.jumphost.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# EKS cluster rules
resource "aws_security_group_rule" "cluster_ingress_self" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_cluster.id
  self              = true
}

resource "aws_security_group_rule" "cluster_ingress_from_jumphost" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.jumphost.id
  description              = "Jumphost to API server (443)"
}

resource "aws_security_group_rule" "cluster_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_cluster.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# EKS node rules
resource "aws_security_group_rule" "nodes_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_nodes.id
  self              = true
  description       = "All protocols between nodes (VPC CNI, CoreDNS, etc.)"
}

resource "aws_security_group_rule" "nodes_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks       = ["0.0.0.0/0"]
}

# Cross-referencing rules between cluster and node SGs (separate to avoid cycle).
resource "aws_security_group_rule" "cluster_ingress_from_nodes" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  description              = "Nodes to API server (443)"
}

resource "aws_security_group_rule" "nodes_ingress_kubelet_from_cluster" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  description              = "Control plane to kubelet (10250)"
}

resource "aws_security_group_rule" "nodes_ingress_webhooks_from_cluster" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  description              = "Control plane to node webhooks (443)"
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })

  tags = merge({ Name = "${var.project_name}-eks-cluster-role" }, local.org_tags)
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Node Group IAM Role
resource "aws_iam_role" "eks_node_group" {
  name = "${var.project_name}-eks-node-group-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })

  tags = merge({ Name = "${var.project_name}-eks-node-group-role" }, local.org_tags)
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  # extraVolumeTags are passed as TagSpecifications on every ec2:CreateVolume call
  # the driver makes. Required because the org SCP denies CreateVolume unless these
  # tags are present on the request.
  configuration_values = jsonencode({
    controller = {
      extraVolumeTags = local.org_tags
    }
  })

  # Wait for node group rolling replacement to complete after launch template changes
  # before the addon is considered ready. This ensures CSI controller pods land on
  # nodes that already have the correct IMDS hop limit.
  depends_on = [
    aws_iam_role_policy_attachment.eks_ebs_csi_policy,
    aws_eks_node_group.main,
  ]
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    time_sleep.wait_for_cluster_eni_cleanup,
  ]

  tags = {
    Name = "${var.project_name}-eks"
  }
}

# EKS Node Group
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = aws_subnet.private[*].id
  version         = var.kubernetes_version

  scaling_config {
    desired_size = var.node_group_desired_size
    max_size     = var.node_group_max_size
    min_size     = var.node_group_min_size
  }

  # Use Launch Template to ensure underlying EC2 instances/volumes are tagged
  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]

  tags = {
    Name = "${var.project_name}-node-group"
  }
}

# Launch template to tag underlying EC2 instances and EBS volumes
resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "${var.project_name}-eks-ng-"
  update_default_version = true

  instance_type = var.node_instance_type

  # Hop limit 2 lets pods reach IMDS (169.254.169.254) through the extra network
  # namespace hop. Default of 1 causes CSI controller pods to fail credential lookup.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Include the EKS-managed cluster SG so the control plane can reach nodes.
  # Without this, EKS does not auto-attach the cluster SG when vpc_security_group_ids is set.
  vpc_security_group_ids = [
    aws_security_group.eks_nodes.id,
    aws_eks_cluster.main.vpc_config[0].cluster_security_group_id,
  ]

  tag_specifications {
    resource_type = "instance"
    tags          = merge({ Name = "${var.project_name}-eks-node" }, local.org_tags)
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge({ Name = "${var.project_name}-eks-node-volume" }, local.org_tags)
  }

  tags = {
    Name = "${var.project_name}-eks-ng-lt"
  }
}

# Jumphost EC2 Instance
resource "aws_instance" "jumphost" {
  #ami                    = data.aws_ami.amazon_linux.id
  ami                    = "ami-04c42dcc70346f4f7"
  instance_type          = var.jumphost_instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.jumphost.id]

  # Ensures the jumphost (and its dynamic public IP) is fully terminated before the IGW
  # is detached from the VPC, preventing a DependencyViolation on destroy.
  depends_on = [aws_internet_gateway.main]

  user_data = base64encode(templatefile("${path.module}/jumphost_user_data.sh", {
    project_name       = var.project_name
    aws_region         = var.aws_region
    kubernetes_version = var.kubernetes_version
  }))

  tags = {
    Name = "${var.project_name}-jumphost"
  }
}

# Data source for Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
