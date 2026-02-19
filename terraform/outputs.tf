# Additional outputs for reference

output "next_steps" {
  description = "Instructions for completing the setup"
  value       = <<-EOT
    
    ============================================================
    NEXT STEPS
    ============================================================
    
    1. Install External Secrets Operator in your EKS cluster:
       
       helm repo add external-secrets https://charts.external-secrets.io
       helm install external-secrets external-secrets/external-secrets \
         -n external-secrets --create-namespace
    
    2. Update the service account annotation in:
       k8s/aws-secrets-manager/service-account.yaml
       
       Replace ACCOUNT_ID with: ${aws_iam_role.atlas_alerts_role.arn}
    
    3. Update the region in:
       k8s/aws-secrets-manager/secret-store.yaml
       
       Set region to: ${var.aws_region}
    
    4. Deploy to Kubernetes:
       kubectl apply -f k8s/namespace.yaml
       kubectl apply -f k8s/aws-secrets-manager/
       kubectl apply -f k8s/job-with-aws-secrets.yaml
    
    ============================================================
    
  EOT
}
