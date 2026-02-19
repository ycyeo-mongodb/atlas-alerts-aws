# =============================================================================
# Outputs
# =============================================================================

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for cluster authentication"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA (disabled)"
  value       = "IRSA disabled - using K8s secrets directly"
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "ecr_repository_url" {
  description = "ECR repository URL for the container image"
  value       = aws_ecr_repository.atlas_alerts.repository_url
}

output "secrets_manager_secret_arn" {
  description = "ARN of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.atlas_credentials.arn
}

output "atlas_alerts_role_arn" {
  description = "IAM role ARN for the atlas-alerts service account (disabled)"
  value       = "IRSA disabled - using K8s secrets directly"
}

# =============================================================================
# Helper Commands
# =============================================================================
output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "docker_login_command" {
  description = "Command to login to ECR"
  value       = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.atlas_alerts.repository_url}"
}

output "next_steps" {
  description = "Next steps after terraform apply"
  value       = <<-EOT

================================================================================
DEPLOYMENT COMPLETE - NEXT STEPS
================================================================================

1. Configure kubectl:
   aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}

2. Login to ECR:
   aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${split("/", aws_ecr_repository.atlas_alerts.repository_url)[0]}

3. Build and push Docker image:
   cd ..
   docker build -t atlas-alerts:latest .
   docker tag atlas-alerts:latest ${aws_ecr_repository.atlas_alerts.repository_url}:latest
   docker push ${aws_ecr_repository.atlas_alerts.repository_url}:latest

4. Deploy to Kubernetes (using K8s secrets directly):
   kubectl apply -f k8s/namespace.yaml
   kubectl apply -f k8s/secret.yaml
   kubectl apply -f k8s/job.yaml

5. Monitor the job:
   kubectl logs -f job/atlas-alerts-creator -n atlas-alerts

================================================================================

EOT
}
