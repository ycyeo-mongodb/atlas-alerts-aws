# Terraform configuration for AWS Secrets Manager + IAM Role for EKS
# This creates the necessary AWS resources for secure secret management

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "eks_oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider"
  type        = string
}

variable "atlas_public_key" {
  description = "MongoDB Atlas Public API Key"
  type        = string
  sensitive   = true
}

variable "atlas_private_key" {
  description = "MongoDB Atlas Private API Key"
  type        = string
  sensitive   = true
}

variable "atlas_project_id" {
  description = "MongoDB Atlas Project ID"
  type        = string
}

# Create AWS Secrets Manager Secret
resource "aws_secretsmanager_secret" "atlas_credentials" {
  name        = "atlas-alerts/credentials"
  description = "MongoDB Atlas API credentials for alert automation"

  tags = {
    Application = "atlas-alerts"
    ManagedBy   = "terraform"
  }
}

# Store the secret values
resource "aws_secretsmanager_secret_version" "atlas_credentials" {
  secret_id = aws_secretsmanager_secret.atlas_credentials.id
  secret_string = jsonencode({
    public_key  = var.atlas_public_key
    private_key = var.atlas_private_key
    project_id  = var.atlas_project_id
  })
}

# IAM Policy to allow reading the secret
resource "aws_iam_policy" "atlas_secrets_policy" {
  name        = "atlas-alerts-secrets-policy"
  description = "Allow reading Atlas credentials from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = aws_secretsmanager_secret.atlas_credentials.arn
      }
    ]
  })
}

# IAM Role for Kubernetes Service Account (IRSA)
data "aws_iam_policy_document" "atlas_alerts_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(var.eks_oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:sub"
      values   = ["system:serviceaccount:atlas-alerts:atlas-alerts-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.eks_oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [var.eks_oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "atlas_alerts_role" {
  name               = "atlas-alerts-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.atlas_alerts_assume_role.json

  tags = {
    Application = "atlas-alerts"
    ManagedBy   = "terraform"
  }
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "atlas_alerts_policy_attachment" {
  role       = aws_iam_role.atlas_alerts_role.name
  policy_arn = aws_iam_policy.atlas_secrets_policy.arn
}

# Outputs
output "secret_arn" {
  description = "ARN of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.atlas_credentials.arn
}

output "iam_role_arn" {
  description = "ARN of the IAM role for the Kubernetes service account"
  value       = aws_iam_role.atlas_alerts_role.arn
}

output "service_account_annotation" {
  description = "Annotation to add to the Kubernetes service account"
  value       = "eks.amazonaws.com/role-arn: ${aws_iam_role.atlas_alerts_role.arn}"
}
