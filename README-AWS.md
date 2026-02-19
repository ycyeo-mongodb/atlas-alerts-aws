# MongoDB Atlas Alert Automation - AWS EKS Deployment

This repository extends the [original Atlas Alert Automation tool](https://github.com/tzehon/research/tree/main/atlas-alerts-creation) with **AWS EKS deployment capabilities**. It enables you to run the alert automation as a Kubernetes Job on AWS, providing a scalable and secure way to manage MongoDB Atlas alerts across multiple projects.

## What's Different from the Original Repository

The original repository (`tzehon/research/atlas-alerts-creation`) provides:
- Python script to create Atlas alerts from Excel configuration
- Local execution via `run_alerts.sh` bash wrapper
- Manual authentication via `atlas auth login`

**This fork adds AWS deployment infrastructure:**

| Component | Original | This Fork (AWS) |
|-----------|----------|-----------------|
| Execution Environment | Local machine | AWS EKS Kubernetes cluster |
| Authentication | Interactive `atlas auth login` | API Keys via K8s Secrets |
| Container Support | None | Dockerfile included |
| Infrastructure | None | Terraform for EKS, VPC, ECR |
| Kubernetes Manifests | None | Job, CronJob, Namespace, Secrets |
| Scalability | Single machine | Multi-project via K8s Jobs |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS Cloud                                       │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         VPC (10.0.0.0/16)                              │ │
│  │  ┌─────────────────┐     ┌─────────────────────────────────────────┐  │ │
│  │  │  Public Subnets │     │           Private Subnets               │  │ │
│  │  │  (NAT Gateway)  │     │  ┌───────────────────────────────────┐  │  │ │
│  │  └────────┬────────┘     │  │         EKS Cluster               │  │  │ │
│  │           │              │  │  ┌─────────────────────────────┐  │  │  │ │
│  │           │              │  │  │    atlas-alerts namespace   │  │  │  │ │
│  │           │              │  │  │  ┌───────┐    ┌──────────┐  │  │  │  │ │
│  │           │              │  │  │  │Secret │───▶│   Job    │  │  │  │  │ │
│  │           │              │  │  │  │(creds)│    │(Python + │  │  │  │  │ │
│  │           │              │  │  │  └───────┘    │Atlas CLI)│  │  │  │  │ │
│  │           │              │  │  │               └────┬─────┘  │  │  │  │ │
│  │           │              │  │  └────────────────────│────────┘  │  │  │ │
│  │           │              │  └───────────────────────│───────────┘  │  │ │
│  │           └──────────────┼─────────────────────────│───────────────┘  │ │
│  └──────────────────────────┼─────────────────────────│──────────────────┘ │
│                             │                         │                     │
│  ┌──────────────────────────┴──────┐                  │                     │
│  │  ECR Repository                 │                  │                     │
│  │  (atlas-alerts container image) │                  │                     │
│  └─────────────────────────────────┘                  │                     │
└───────────────────────────────────────────────────────│─────────────────────┘
                                                        │
                                                        │ Atlas Admin API
                                                        ▼
                                          ┌─────────────────────────┐
                                          │     MongoDB Atlas       │
                                          │  ┌───────────────────┐  │
                                          │  │   33 Custom       │  │
                                          │  │   Alert Configs   │  │
                                          │  └───────────────────┘  │
                                          └─────────────────────────┘
```

---

## Files Added for AWS Deployment

### Docker Configuration

#### `Dockerfile`
Containerizes the Python application with Atlas CLI:

```dockerfile
FROM python:3.11-slim

# Install curl for Atlas CLI download
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install MongoDB Atlas CLI (direct download)
RUN curl -L https://fastdl.mongodb.org/mongocli/mongodb-atlas-cli_1.14.0_linux_x86_64.tar.gz -o /tmp/atlas-cli.tar.gz \
    && tar -xzf /tmp/atlas-cli.tar.gz -C /tmp \
    && mv /tmp/mongodb-atlas-cli_1.14.0_linux_x86_64/bin/atlas /usr/local/bin/atlas \
    && chmod +x /usr/local/bin/atlas \
    && rm -rf /tmp/atlas-cli.tar.gz /tmp/mongodb-atlas-cli_*

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY create_atlas_alerts.py .
COPY atlas_alert_configurations.xlsx .

RUN mkdir -p /app/alerts /app/logs

ENTRYPOINT ["python3", "create_atlas_alerts.py"]
CMD ["--help"]
```

**Key Points:**
- Uses Python 3.11 slim base image (~150MB)
- Downloads Atlas CLI directly (avoids GPG signing issues)
- Embeds the Excel configuration file
- Credentials passed via environment variables at runtime

---

### Kubernetes Manifests

#### `k8s/namespace.yaml`
Creates isolated namespace for the alert automation:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: atlas-alerts
  labels:
    app: atlas-alerts
    purpose: mongodb-atlas-alert-automation
```

#### `k8s/job.yaml`
Kubernetes Job that runs the alert creation once:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: atlas-alerts-creator
  namespace: atlas-alerts
spec:
  ttlSecondsAfterFinished: 300    # Auto-cleanup after 5 minutes
  backoffLimit: 2                  # Retry twice on failure
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: atlas-alerts
          image: <ECR_URL>/asean-yc-alerts-demo:latest
          imagePullPolicy: Always
          env:
            - name: MONGODB_ATLAS_PUBLIC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: atlas-api-credentials
                  key: MONGODB_ATLAS_PUBLIC_API_KEY
            - name: MONGODB_ATLAS_PRIVATE_API_KEY
              valueFrom:
                secretKeyRef:
                  name: atlas-api-credentials
                  key: MONGODB_ATLAS_PRIVATE_API_KEY
            - name: MONGODB_ATLAS_PROJECT_ID
              valueFrom:
                secretKeyRef:
                  name: atlas-api-credentials
                  key: MONGODB_ATLAS_PROJECT_ID
          args:
            - "--project-id"
            - "$(MONGODB_ATLAS_PROJECT_ID)"
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
```

**Key Points:**
- Credentials loaded from Kubernetes Secret (not hardcoded)
- Auto-deletes 5 minutes after completion
- Resource limits prevent runaway consumption
- Passes project ID as argument to Python script

#### `k8s/cronjob.yaml` (Optional)
For scheduled alert synchronization:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: atlas-alerts-sync
  namespace: atlas-alerts
spec:
  schedule: "0 2 * * *"    # Run daily at 2 AM UTC
  jobTemplate:
    # ... same as job.yaml template ...
```

---

### Terraform Infrastructure

#### `terraform/eks/versions.tf`
Specifies provider versions:

```hcl
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0"  }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.23" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.11" }
    tls        = { source = "hashicorp/tls",        version = "~> 4.0"  }
  }
}
```

#### `terraform/eks/variables.tf`
Input variables for customization:

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `ap-southeast-1` | AWS region for deployment |
| `cluster_name` | `asean-yc-alerts-demo` | EKS cluster name |
| `cluster_version` | `1.29` | Kubernetes version |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `node_instance_type` | `t3.small` | EC2 instance type |
| `node_desired_size` | `2` | Number of worker nodes |
| `atlas_public_key` | - | MongoDB Atlas API public key |
| `atlas_private_key` | - | MongoDB Atlas API private key |
| `atlas_project_id` | - | Target Atlas project ID |
| `allowed_ip_cidr` | - | Your IP for cluster access |

#### `terraform/eks/main.tf`
Creates AWS infrastructure:

**VPC Module:**
```hcl
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
}
```

**EKS Cluster:**
```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }

  # Restrict API access to your IP
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
}
```

**ECR Repository:**
```hcl
resource "aws_ecr_repository" "atlas_alerts" {
  name                 = "atlas-alerts"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
```

**AWS Secrets Manager (for reference):**
```hcl
resource "aws_secretsmanager_secret" "atlas_credentials" {
  name        = "atlas-alerts/credentials"
  description = "MongoDB Atlas API credentials"
}
```

#### `terraform/eks/outputs.tf`
Outputs useful information after deployment:

| Output | Description |
|--------|-------------|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | Kubernetes API endpoint |
| `ecr_repository_url` | ECR URL for Docker push |
| `configure_kubectl` | Command to configure kubectl |
| `docker_login_command` | Command to login to ECR |

---

## Deployment Guide

### Prerequisites

- AWS CLI configured with appropriate permissions
- Docker Desktop running
- Terraform >= 1.0 installed
- kubectl installed
- MongoDB Atlas API Key with Project Owner role

### Step 1: Clone and Configure

```bash
git clone https://github.com/ycyeo-mongodb/atlas-alerts-aws.git
cd atlas-alerts-aws
```

Create `terraform/eks/terraform.tfvars`:
```hcl
aws_region         = "ap-southeast-1"
cluster_name       = "my-alerts-cluster"
node_instance_type = "t3.small"
node_desired_size  = 2

atlas_public_key   = "your-public-key"
atlas_private_key  = "your-private-key"
atlas_project_id   = "your-project-id"

allowed_ip_cidr    = "YOUR_IP/32"  # Get from: curl ifconfig.me
```

### Step 2: Deploy Infrastructure

```bash
cd terraform/eks
terraform init
terraform plan
terraform apply
```

This creates:
- VPC with public/private subnets
- EKS cluster with 2 worker nodes
- ECR repository for container images
- AWS Secrets Manager secret

### Step 3: Build and Push Docker Image

```bash
# Configure kubectl
aws eks update-kubeconfig --region ap-southeast-1 --name my-alerts-cluster

# Login to ECR
aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com

# Build image (from project root)
cd ../..
docker build --platform linux/amd64 -t atlas-alerts:latest .

# Tag and push
docker tag atlas-alerts:latest <ECR_URL>:latest
docker push <ECR_URL>:latest
```

### Step 4: Deploy to Kubernetes

```bash
# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create secret with Atlas credentials
kubectl create secret generic atlas-api-credentials \
  --namespace=atlas-alerts \
  --from-literal=MONGODB_ATLAS_PUBLIC_API_KEY=your-public-key \
  --from-literal=MONGODB_ATLAS_PRIVATE_API_KEY=your-private-key \
  --from-literal=MONGODB_ATLAS_PROJECT_ID=your-project-id

# Run the job
kubectl apply -f k8s/job.yaml

# Watch logs
kubectl logs -f job/atlas-alerts-creator -n atlas-alerts
```

### Step 5: Verify in Atlas

1. Go to [MongoDB Atlas](https://cloud.mongodb.com)
2. Navigate to your project → **Alerts** → **Alert Settings**
3. Verify the 33 custom alerts are configured

---

## Important: Atlas API Access List

The EKS worker nodes have public IPs that must be added to your Atlas API Key's access list:

1. Check the node IP from job logs (error will show the IP)
2. Go to Atlas → **Access Manager** → **API Keys**
3. Edit your API key → **Add Access List Entry**
4. Add the EKS node's public IP (e.g., `13.251.226.242/32`)

---

## Re-running the Job

To update alerts after modifying the Excel configuration:

```bash
# Delete existing job
kubectl delete job atlas-alerts-creator -n atlas-alerts

# Rebuild and push image (if Excel changed)
docker build --platform linux/amd64 -t atlas-alerts:latest .
docker push <ECR_URL>:latest

# Re-run
kubectl apply -f k8s/job.yaml
```

---

## Cleanup

```bash
# Delete Kubernetes resources
kubectl delete namespace atlas-alerts

# Destroy infrastructure
cd terraform/eks
terraform destroy
```

---

## Cost Estimate

| Resource | Estimated Monthly Cost |
|----------|------------------------|
| EKS Cluster | ~$73 |
| NAT Gateway | ~$32 |
| EC2 Nodes (2x t3.small) | ~$30 |
| ECR Storage | ~$1 |
| **Total** | **~$136/month** |

For cost optimization:
- Use `t3.micro` nodes for minimal workloads
- Run job on-demand instead of keeping cluster running
- Consider AWS Fargate for serverless execution

---

## Security Considerations

1. **API Keys in Secrets**: Atlas credentials stored in Kubernetes Secrets (base64 encoded)
2. **Network Restriction**: EKS API restricted to specific IP via security group
3. **ECR Scanning**: Container images scanned on push
4. **No Hardcoded Credentials**: All sensitive values passed via environment variables

For production:
- Enable AWS Secrets Manager integration via External Secrets Operator
- Use IAM Roles for Service Accounts (IRSA) for fine-grained permissions
- Enable EKS audit logging
- Use private EKS endpoint

---

## Troubleshooting

### Job Fails with 403 Forbidden
```
Error: ORG_REQUIRES_ACCESS_LIST
```
**Fix**: Add EKS node IP to Atlas API Key access list (see above)

### Cannot Pull Image from ECR
```
Error: ImagePullBackOff
```
**Fix**: Ensure ECR repository exists and image is pushed:
```bash
aws ecr describe-images --repository-name atlas-alerts --region ap-southeast-1
```

### kubectl Authentication Error
```
error: You must be logged in to the server
```
**Fix**: Update kubeconfig and verify AWS credentials:
```bash
aws eks update-kubeconfig --region ap-southeast-1 --name your-cluster
aws sts get-caller-identity
```

---

## Original Repository

This is a fork of [tzehon/research/atlas-alerts-creation](https://github.com/tzehon/research/tree/main/atlas-alerts-creation).

See the [original README](./README.md) for:
- Excel configuration format
- Alert mapping reference
- Local execution instructions
- Adding new alert types

---

## License

MIT License - See original repository for details.
