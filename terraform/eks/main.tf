# =============================================================================
# AWS Provider Configuration
# =============================================================================
provider "aws" {
  region = var.aws_region
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# VPC Configuration
# =============================================================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = 1
    "kubernetes.io/cluster/${var.cluster_name}"   = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = 1
    "kubernetes.io/cluster/${var.cluster_name}"   = "shared"
  }

  tags = var.tags
}

# =============================================================================
# EKS Cluster
# =============================================================================
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Disable OIDC provider (requires IAM permissions not available)
  enable_irsa = false

  # Cluster addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  # EKS Managed Node Group
  eks_managed_node_groups = {
    default = {
      name           = "alerts-nodes"
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Use Amazon Linux 2
      ami_type = "AL2_x86_64"

      # Use shorter name prefix to avoid IAM role name length limit
      iam_role_use_name_prefix = false
      iam_role_name           = "alerts-node-role"

      labels = {
        Environment = "demo"
        Application = "atlas-alerts"
      }

      tags = var.tags
    }
  }

  # Restrict access to specific IP (your IP address)
  cluster_security_group_additional_rules = {
    ingress_https_from_my_ip = {
      description = "Allow HTTPS from my IP"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [var.allowed_ip_cidr]
    }
  }

  tags = var.tags
}

# =============================================================================
# AWS Secrets Manager - Store Atlas Credentials
# =============================================================================
resource "aws_secretsmanager_secret" "atlas_credentials" {
  name        = "atlas-alerts/credentials"
  description = "MongoDB Atlas API credentials for alert automation"

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "atlas_credentials" {
  secret_id = aws_secretsmanager_secret.atlas_credentials.id
  secret_string = jsonencode({
    public_key  = var.atlas_public_key
    private_key = var.atlas_private_key
    project_id  = var.atlas_project_id
  })
}

# =============================================================================
# NOTE: IRSA (IAM Roles for Service Accounts) disabled due to IAM permissions
# We'll use Kubernetes secrets directly instead of AWS Secrets Manager
# =============================================================================

# =============================================================================
# ECR Repository for Container Image
# =============================================================================
resource "aws_ecr_repository" "atlas_alerts" {
  name                 = "atlas-alerts"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

# ECR Lifecycle Policy - Keep only last 5 images
resource "aws_ecr_lifecycle_policy" "atlas_alerts" {
  repository = aws_ecr_repository.atlas_alerts.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
