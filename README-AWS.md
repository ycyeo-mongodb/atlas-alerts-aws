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

## How It Works - End-to-End Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            DEPLOYMENT FLOW                                       │
└─────────────────────────────────────────────────────────────────────────────────┘

Step 1: TERRAFORM CREATES INFRASTRUCTURE
┌─────────────────────────────────────────────────────────────────────────────────┐
│  terraform apply                                                                 │
│       │                                                                          │
│       ├──▶ VPC (10.0.0.0/16)                                                    │
│       │       ├── Public Subnets (10.0.101-103.0/24) ──▶ NAT Gateway            │
│       │       └── Private Subnets (10.0.1-3.0/24) ──▶ EKS Worker Nodes          │
│       │                                                                          │
│       ├──▶ EKS Cluster (Kubernetes v1.29)                                       │
│       │       ├── Control Plane (AWS Managed)                                   │
│       │       └── Node Group (2x t3.small EC2 instances)                        │
│       │                                                                          │
│       ├──▶ ECR Repository (stores Docker images)                                │
│       │                                                                          │
│       └──▶ AWS Secrets Manager (stores Atlas credentials)                       │
└─────────────────────────────────────────────────────────────────────────────────┘

Step 2: DOCKER IMAGE BUILD & PUSH
┌─────────────────────────────────────────────────────────────────────────────────┐
│  docker build & push                                                             │
│       │                                                                          │
│       ├──▶ Base Image: python:3.11-slim                                         │
│       ├──▶ Install: MongoDB Atlas CLI 1.14.0                                    │
│       ├──▶ Install: Python dependencies (openpyxl)                              │
│       ├──▶ Copy: create_atlas_alerts.py + atlas_alert_configurations.xlsx       │
│       │                                                                          │
│       └──▶ Push to ECR: <account>.dkr.ecr.<region>.amazonaws.com/atlas-alerts   │
└─────────────────────────────────────────────────────────────────────────────────┘

Step 3: KUBERNETES DEPLOYMENT
┌─────────────────────────────────────────────────────────────────────────────────┐
│  kubectl apply                                                                   │
│       │                                                                          │
│       ├──▶ Namespace: atlas-alerts                                              │
│       │       └── Isolates resources from other workloads                       │
│       │                                                                          │
│       ├──▶ Secret: atlas-api-credentials                                        │
│       │       ├── MONGODB_ATLAS_PUBLIC_API_KEY                                  │
│       │       ├── MONGODB_ATLAS_PRIVATE_API_KEY                                 │
│       │       └── MONGODB_ATLAS_PROJECT_ID                                      │
│       │                                                                          │
│       └──▶ Job: atlas-alerts-creator                                            │
│               ├── Pulls image from ECR                                          │
│               ├── Mounts secrets as environment variables                       │
│               ├── Runs: python3 create_atlas_alerts.py --project-id $PROJECT_ID │
│               └── Auto-deletes after 5 minutes (ttlSecondsAfterFinished: 300)   │
└─────────────────────────────────────────────────────────────────────────────────┘

Step 4: ALERT CREATION EXECUTION
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Inside the Container (Job Pod)                                                  │
│       │                                                                          │
│       ├──▶ Python script reads atlas_alert_configurations.xlsx                  │
│       │       └── Parses 21 alert definitions with Low/High thresholds          │
│       │                                                                          │
│       ├──▶ Generates 33 JSON alert configuration files                          │
│       │       └── Maps Excel names to Atlas API event types & metrics           │
│       │                                                                          │
│       ├──▶ Atlas CLI authenticates via environment variables                    │
│       │       └── Uses MONGODB_ATLAS_PUBLIC_API_KEY + PRIVATE_API_KEY           │
│       │                                                                          │
│       └──▶ Creates alerts via Atlas Admin API                                   │
│               └── POST /api/atlas/v2/groups/{projectId}/alertConfigs            │
└─────────────────────────────────────────────────────────────────────────────────┘

Step 5: RESULT
┌─────────────────────────────────────────────────────────────────────────────────┐
│  MongoDB Atlas Project                                                           │
│       │                                                                          │
│       └──▶ 33 Custom Alert Configurations                                       │
│               ├── Oplog Window (Low: <24h, High: <1h)                           │
│               ├── Disk IOPS (Low: >4000, High: >9000)                           │
│               ├── Replication Lag (Low: >240s, High: >3600s)                    │
│               ├── Host Down, Page Faults, CPU %, Disk Space...                  │
│               └── Backup alerts, Queue alerts, etc.                             │
└─────────────────────────────────────────────────────────────────────────────────┘
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

### Kubernetes Manifests - Detailed Configuration

The Kubernetes manifests in `k8s/` define how the alert automation runs on EKS.

#### File Structure
```
k8s/
├── namespace.yaml              # Namespace isolation
├── job.yaml                    # One-time execution
├── cronjob.yaml               # Scheduled execution (optional)
└── aws-secrets-manager/       # External Secrets Operator (optional)
    ├── secret-store.yaml
    ├── external-secret.yaml
    └── service-account.yaml
```

---

#### `k8s/namespace.yaml` - Namespace Isolation

Creates a dedicated namespace to isolate alert automation resources:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: atlas-alerts
  labels:
    app: atlas-alerts
    purpose: mongodb-atlas-alert-automation
```

**Why use a namespace?**
- Isolates resources from other workloads
- Easier cleanup (`kubectl delete namespace atlas-alerts` removes everything)
- Can apply resource quotas and network policies
- Cleaner organization

---

#### Kubernetes Secret - Storing Atlas Credentials

Before running the Job, you must create a Secret with your Atlas API credentials:

```bash
kubectl create secret generic atlas-api-credentials \
  --namespace=atlas-alerts \
  --from-literal=MONGODB_ATLAS_PUBLIC_API_KEY=your-public-key \
  --from-literal=MONGODB_ATLAS_PRIVATE_API_KEY=your-private-key \
  --from-literal=MONGODB_ATLAS_PROJECT_ID=your-project-id
```

This creates a Secret that looks like:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: atlas-api-credentials
  namespace: atlas-alerts
type: Opaque
data:
  MONGODB_ATLAS_PUBLIC_API_KEY: base64-encoded-value
  MONGODB_ATLAS_PRIVATE_API_KEY: base64-encoded-value
  MONGODB_ATLAS_PROJECT_ID: base64-encoded-value
```

**Security Note:** Kubernetes Secrets are base64 encoded (not encrypted). For production, consider using:
- AWS Secrets Manager with External Secrets Operator
- HashiCorp Vault
- Sealed Secrets

---

#### `k8s/job.yaml` - One-Time Execution

The Job runs the alert creation once and exits:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: atlas-alerts-creator
  namespace: atlas-alerts
  labels:
    app: atlas-alerts
spec:
  # Auto-delete job 5 minutes after completion (cleanup)
  ttlSecondsAfterFinished: 300
  
  # Retry up to 2 times on failure
  backoffLimit: 2
  
  template:
    metadata:
      labels:
        app: atlas-alerts
    spec:
      # Don't restart on failure (Job will retry instead)
      restartPolicy: Never
      
      containers:
        - name: atlas-alerts
          # Image from ECR (update with your ECR URL)
          image: 979559056307.dkr.ecr.ap-southeast-1.amazonaws.com/asean-yc-alerts-demo:latest
          
          # Always pull latest image
          imagePullPolicy: Always
          
          # Environment variables from Secret
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
          
          # Command line arguments passed to Python script
          args:
            - "--project-id"
            - "$(MONGODB_ATLAS_PROJECT_ID)"
          
          # Resource limits (prevent runaway consumption)
          resources:
            requests:
              memory: "128Mi"    # Guaranteed memory
              cpu: "100m"        # 0.1 CPU cores
            limits:
              memory: "256Mi"    # Maximum memory
              cpu: "200m"        # 0.2 CPU cores
```

**Configuration Breakdown:**

| Field | Value | Purpose |
|-------|-------|---------|
| `ttlSecondsAfterFinished` | `300` | Auto-delete Job 5 min after completion |
| `backoffLimit` | `2` | Retry failed Jobs up to 2 times |
| `restartPolicy` | `Never` | Don't restart failed containers |
| `imagePullPolicy` | `Always` | Pull latest image on every run |
| `resources.requests` | 128Mi/100m | Minimum guaranteed resources |
| `resources.limits` | 256Mi/200m | Maximum allowed resources |

**How the Job Works:**
1. Kubernetes scheduler assigns Job to a worker node
2. Kubelet pulls the Docker image from ECR
3. Container starts and reads environment variables (from Secret)
4. Python script executes: `python3 create_atlas_alerts.py --project-id $PROJECT_ID`
5. Script reads Excel, generates JSON, calls Atlas API
6. Container exits with status code (0 = success)
7. Job marked as Complete/Failed
8. After 5 minutes, Job and Pod are automatically deleted

---

#### `k8s/cronjob.yaml` - Scheduled Execution (Optional)

For recurring alert synchronization (e.g., daily):

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: atlas-alerts-sync
  namespace: atlas-alerts
  labels:
    app: atlas-alerts
spec:
  # Run daily at 2 AM UTC
  schedule: "0 2 * * *"
  
  # Keep last 3 successful job records
  successfulJobsHistoryLimit: 3
  
  # Keep last 1 failed job record
  failedJobsHistoryLimit: 1
  
  # Don't start new job if previous is still running
  concurrencyPolicy: Forbid
  
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 86400    # Keep for 24 hours
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: atlas-alerts
              image: <ECR_URL>:latest
              imagePullPolicy: Always
              env:
                # ... same as job.yaml ...
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

**Cron Schedule Examples:**
| Schedule | Meaning |
|----------|---------|
| `0 2 * * *` | Daily at 2:00 AM |
| `0 */6 * * *` | Every 6 hours |
| `0 9 * * 1` | Every Monday at 9:00 AM |
| `*/30 * * * *` | Every 30 minutes |

---

#### How Kubernetes Deployment on EKS Works

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         EKS CLUSTER ARCHITECTURE                                 │
└─────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────┐
│                              AWS Managed                                         │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                        EKS Control Plane                                    │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                     │ │
│  │  │ API Server   │  │ etcd         │  │ Controllers  │                     │ │
│  │  │ (kubectl     │  │ (cluster     │  │ (scheduler,  │                     │ │
│  │  │  endpoint)   │  │  state)      │  │  jobs, etc)  │                     │ │
│  │  └──────┬───────┘  └──────────────┘  └──────────────┘                     │ │
│  └─────────│──────────────────────────────────────────────────────────────────┘ │
│            │                                                                     │
│            │ Kubernetes API (HTTPS/443)                                          │
│            │                                                                     │
│  ┌─────────▼──────────────────────────────────────────────────────────────────┐ │
│  │                        Your VPC (Private Subnets)                          │ │
│  │  ┌────────────────────────────┐  ┌────────────────────────────┐            │ │
│  │  │      Worker Node 1         │  │      Worker Node 2         │            │ │
│  │  │      (t3.small)            │  │      (t3.small)            │            │ │
│  │  │  ┌────────────────────┐    │  │  ┌────────────────────┐    │            │ │
│  │  │  │ kubelet            │    │  │  │ kubelet            │    │            │ │
│  │  │  │ (node agent)       │    │  │  │ (node agent)       │    │            │ │
│  │  │  └─────────┬──────────┘    │  │  └────────────────────┘    │            │ │
│  │  │            │               │  │                            │            │ │
│  │  │  ┌─────────▼──────────┐    │  │                            │            │ │
│  │  │  │ Pod: atlas-alerts  │    │  │                            │            │ │
│  │  │  │ ┌────────────────┐ │    │  │                            │            │ │
│  │  │  │ │ Container      │ │    │  │                            │            │ │
│  │  │  │ │ - Python 3.11  │ │    │  │                            │            │ │
│  │  │  │ │ - Atlas CLI    │ │    │  │                            │            │ │
│  │  │  │ │ - Excel config │─│────│──│── Atlas Admin API ──────▶ │ MongoDB    │ │
│  │  │  │ └────────────────┘ │    │  │                            │ Atlas      │ │
│  │  │  └────────────────────┘    │  │                            │            │ │
│  │  └────────────────────────────┘  └────────────────────────────┘            │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                              ECR Repository                                 │ │
│  │  atlas-alerts:latest (Docker image pulled by kubelet)                      │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Execution Flow:**

1. **You run:** `kubectl apply -f k8s/job.yaml`
2. **API Server** receives the Job manifest
3. **Job Controller** creates a Pod specification
4. **Scheduler** assigns Pod to a worker node (e.g., Node 1)
5. **Kubelet** on Node 1:
   - Pulls image from ECR: `979559056307.dkr.ecr.ap-southeast-1.amazonaws.com/atlas-alerts:latest`
   - Creates container with environment variables from Secret
   - Starts container
6. **Container executes:**
   - `python3 create_atlas_alerts.py --project-id 691a96e4176d4e67872c7edd`
   - Reads Excel configuration
   - Generates JSON alert configs
   - Calls Atlas API via Atlas CLI
7. **Container exits** with code 0 (success) or non-zero (failure)
8. **Job Controller** marks Job as Complete/Failed
9. **TTL Controller** deletes Job after 5 minutes

---

### Terraform Infrastructure - Detailed Configuration

The Terraform files in `terraform/eks/` create all the AWS infrastructure needed to run the alert automation on EKS.

#### File Structure
```
terraform/eks/
├── versions.tf      # Provider version constraints
├── variables.tf     # Input variables (customizable)
├── main.tf          # Main infrastructure definition
├── outputs.tf       # Output values after deployment
└── terraform.tfvars # Your specific values (not committed)
```

---

#### `terraform/eks/versions.tf` - Provider Versions

Specifies which Terraform providers and versions are required:

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

| Provider | Purpose |
|----------|---------|
| `aws` | Creates VPC, EKS, ECR, Secrets Manager |
| `kubernetes` | Manages K8s resources (if needed) |
| `helm` | For installing Helm charts (optional) |
| `tls` | For certificate operations |

---

#### `terraform/eks/variables.tf` - Input Variables

Defines all configurable parameters:

```hcl
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "asean-yc-alerts-demo"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.small"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

# MongoDB Atlas credentials (sensitive)
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

variable "allowed_ip_cidr" {
  description = "CIDR block for allowed IP access (your IP)"
  type        = string
  default     = "0.0.0.0/0"  # CHANGE THIS to your IP!
}
```

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `ap-southeast-1` | AWS region for all resources |
| `cluster_name` | `asean-yc-alerts-demo` | Name for EKS cluster and related resources |
| `cluster_version` | `1.29` | Kubernetes version (EKS supported versions) |
| `vpc_cidr` | `10.0.0.0/16` | VPC IP range (65,536 IPs) |
| `node_instance_type` | `t3.small` | EC2 type (2 vCPU, 2GB RAM) |
| `node_desired_size` | `2` | Number of worker nodes |
| `node_min_size` | `1` | Minimum nodes for autoscaling |
| `node_max_size` | `3` | Maximum nodes for autoscaling |
| `atlas_public_key` | - | Your Atlas API public key |
| `atlas_private_key` | - | Your Atlas API private key (sensitive) |
| `atlas_project_id` | - | Target Atlas project ID |
| `allowed_ip_cidr` | - | Your IP for EKS API access (e.g., `1.2.3.4/32`) |

---

#### `terraform/eks/main.tf` - Infrastructure Definition

This is the main file that creates all AWS resources:

##### 1. VPC Configuration
Creates an isolated network for the EKS cluster:

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr    # 10.0.0.0/16

  # Use 3 Availability Zones for high availability
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  
  # Private subnets - where EKS worker nodes run
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  
  # Public subnets - for NAT Gateway and load balancers
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  # NAT Gateway allows private subnets to access internet
  enable_nat_gateway   = true
  single_nat_gateway   = true    # Cost optimization: use 1 NAT instead of 3
  enable_dns_hostnames = true

  # Tags required for EKS to discover subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
```

**What this creates:**
| Resource | Purpose |
|----------|---------|
| VPC | Isolated network (10.0.0.0/16) |
| 3 Public Subnets | NAT Gateway, external load balancers |
| 3 Private Subnets | EKS worker nodes (no direct internet access) |
| NAT Gateway | Allows private nodes to access internet (for pulling images) |
| Internet Gateway | Allows public subnet internet access |
| Route Tables | Network routing rules |

##### 2. EKS Cluster Configuration
Creates the Kubernetes cluster:

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version    # 1.29

  # Public API endpoint (accessible from your IP)
  cluster_endpoint_public_access = true

  # Place cluster in our VPC's private subnets
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Disable OIDC/IRSA (requires additional IAM permissions)
  enable_irsa = false

  # EKS Add-ons (core Kubernetes components)
  cluster_addons = {
    coredns    = { most_recent = true }    # DNS resolution
    kube-proxy = { most_recent = true }    # Network proxy
    vpc-cni    = { most_recent = true }    # AWS VPC networking
  }

  # Worker node configuration
  eks_managed_node_groups = {
    default = {
      name           = "alerts-nodes"
      instance_types = [var.node_instance_type]    # t3.small

      min_size     = var.node_min_size       # 1
      max_size     = var.node_max_size       # 3
      desired_size = var.node_desired_size   # 2

      ami_type = "AL2_x86_64"    # Amazon Linux 2

      # Shorter IAM role name to avoid 64-char limit
      iam_role_use_name_prefix = false
      iam_role_name           = "alerts-node-role"

      labels = {
        Environment = "demo"
        Application = "atlas-alerts"
      }
    }
  }

  # Security: Restrict API access to your IP only
  cluster_security_group_additional_rules = {
    ingress_https_from_my_ip = {
      description = "Allow HTTPS from my IP"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [var.allowed_ip_cidr]    # Your IP/32
    }
  }
}
```

**What this creates:**
| Resource | Purpose |
|----------|---------|
| EKS Control Plane | Managed Kubernetes API server |
| Node Group | 2x t3.small EC2 instances as workers |
| IAM Roles | Permissions for EKS and worker nodes |
| Security Groups | Network firewall rules |
| EKS Add-ons | CoreDNS, kube-proxy, VPC CNI |

##### 3. ECR Repository
Stores the Docker image:

```hcl
resource "aws_ecr_repository" "atlas_alerts" {
  name                 = "atlas-alerts"
  image_tag_mutability = "MUTABLE"    # Allow tag overwrites

  image_scanning_configuration {
    scan_on_push = true    # Scan for vulnerabilities
  }
}

# Lifecycle policy: Keep only last 5 images
resource "aws_ecr_lifecycle_policy" "atlas_alerts" {
  repository = aws_ecr_repository.atlas_alerts.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
```

##### 4. AWS Secrets Manager
Stores Atlas credentials securely:

```hcl
resource "aws_secretsmanager_secret" "atlas_credentials" {
  name        = "atlas-alerts/credentials"
  description = "MongoDB Atlas API credentials for alert automation"
}

resource "aws_secretsmanager_secret_version" "atlas_credentials" {
  secret_id = aws_secretsmanager_secret.atlas_credentials.id
  secret_string = jsonencode({
    public_key  = var.atlas_public_key
    private_key = var.atlas_private_key
    project_id  = var.atlas_project_id
  })
}
```

---

#### `terraform/eks/outputs.tf` - Output Values

After `terraform apply`, these values are displayed:

```hcl
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  description = "ECR repository URL for the container image"
  value       = aws_ecr_repository.atlas_alerts.repository_url
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "docker_login_command" {
  description = "Command to login to ECR"
  value       = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.atlas_alerts.repository_url}"
}
```

| Output | Example Value |
|--------|---------------|
| `cluster_name` | `asean-yc-alerts-demo` |
| `cluster_endpoint` | `https://ABC123.gr7.ap-southeast-1.eks.amazonaws.com` |
| `ecr_repository_url` | `979559056307.dkr.ecr.ap-southeast-1.amazonaws.com/atlas-alerts` |
| `configure_kubectl` | Command to set up kubectl |
| `docker_login_command` | Command to authenticate Docker with ECR |

---

#### `terraform.tfvars` - Your Configuration (Example)

Create this file with your specific values (not committed to git):

```hcl
# AWS Configuration
aws_region   = "ap-southeast-1"
cluster_name = "my-alerts-cluster"

# Node Configuration
node_instance_type = "t3.small"
node_desired_size  = 2
node_min_size      = 1
node_max_size      = 3

# MongoDB Atlas Credentials
atlas_public_key  = "abcd1234"
atlas_private_key = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
atlas_project_id  = "1234567890abcdef12345678"

# Security: Restrict to your IP
allowed_ip_cidr = "203.0.113.50/32"  # Replace with your IP

# Tags
tags = {
  Project     = "atlas-alerts"
  Environment = "demo"
  Owner       = "your-name"
  ManagedBy   = "terraform"
}
```

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

## Alert Simulator - Testing Your Alerts

After deploying alerts, you can **test them** using the included simulator script.

### What the Simulator Does

It creates conditions that trigger your configured alerts:

| Simulation | What It Does | Alerts Triggered |
|------------|--------------|------------------|
| `cpu` | Runs compute-intensive aggregations | System: CPU (User) % |
| `query-targeting` | Runs queries without indexes | Query Targeting, Index suggestions |
| `connections` | Opens many concurrent connections | Connections % of configured limit |
| `write-load` | Heavy inserts/updates/deletes | Disk write IOPS, latency, Writers queue |
| `read-load` | Heavy reads and scans | Disk read IOPS, latency, Readers queue |

### Setup

```bash
# Install pymongo
pip install pymongo

# Set your connection string in .env.local
echo 'MONGODB_CONNECTION_STRING=mongodb+srv://user:pass@cluster.mongodb.net' >> .env.local
```

### Usage

```bash
# Load connection string from .env.local
source .env.local

# Run query-targeting simulation (easiest to trigger alerts)
python3 simulate_alerts.py \
  --connection-string "$MONGODB_CONNECTION_STRING" \
  --simulation query-targeting \
  --duration 120

# Run CPU load simulation
python3 simulate_alerts.py \
  --connection-string "$MONGODB_CONNECTION_STRING" \
  --simulation cpu \
  --duration 60

# Run ALL simulations
python3 simulate_alerts.py \
  --connection-string "$MONGODB_CONNECTION_STRING" \
  --simulation all \
  --duration 60

# Clean up test data after simulation
python3 simulate_alerts.py \
  --connection-string "$MONGODB_CONNECTION_STRING" \
  --cleanup-only
```

### Where to See Triggered Alerts

1. **Atlas UI**: [cloud.mongodb.com](https://cloud.mongodb.com) → Your Project → **Alerts** → **Open Alerts**
2. **Email**: Sent to Project Owners (check your inbox/spam)

### Alert Notification Settings

The alerts we created are configured to:
- Send **email** to users with `GROUP_OWNER` (Project Owner) role
- Wait **5 minutes** before first notification (`delayMin`)
- Resend every **60 minutes** if condition persists (`intervalMin`)

```json
{
  "typeName": "GROUP",
  "intervalMin": 60,
  "delayMin": 5,
  "emailEnabled": true,
  "roles": ["GROUP_OWNER"]
}
```

---

## License

MIT License - See original repository for details.
