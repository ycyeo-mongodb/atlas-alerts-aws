# EKS Cluster Terraform Configuration

This Terraform configuration creates an EKS cluster with all the necessary infrastructure for deploying the MongoDB Atlas Alerts automation.

## What Gets Created

| Resource | Description |
|----------|-------------|
| **VPC** | New VPC with public/private subnets across 3 AZs |
| **EKS Cluster** | Kubernetes cluster (v1.29) |
| **Node Group** | 2x t3.small worker nodes |
| **ECR Repository** | Container registry for the alert image |
| **Secrets Manager** | Stores MongoDB Atlas API credentials |
| **IAM Role (IRSA)** | Allows pods to access Secrets Manager |

## Prerequisites

- Terraform >= 1.0
- AWS CLI configured with appropriate credentials
- Docker (for building and pushing the image)

## Usage

### 1. Initialize Terraform

```bash
cd terraform/eks
terraform init
```

### 2. Review the Plan

```bash
terraform plan
```

### 3. Apply the Configuration

```bash
terraform apply
```

This will take approximately 15-20 minutes to create the EKS cluster.

### 4. Configure kubectl

After `terraform apply` completes, run:

```bash
aws eks update-kubeconfig --region ap-southeast-1 --name asean-yc-alerts-demo
```

### 5. Follow the Next Steps

The `terraform apply` output will show detailed next steps for:
- Building and pushing the Docker image
- Installing External Secrets Operator
- Deploying the Kubernetes resources

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Warning:** This will delete the EKS cluster and all associated resources.

## Cost Estimate

| Resource | Estimated Monthly Cost |
|----------|----------------------|
| EKS Cluster | ~$72 |
| 2x t3.small nodes | ~$30 |
| NAT Gateway | ~$32 |
| ECR | ~$0 (minimal storage) |
| Secrets Manager | ~$0.40 |
| **Total** | **~$135/month** |

For demo purposes, destroy the cluster when not in use to avoid costs.
