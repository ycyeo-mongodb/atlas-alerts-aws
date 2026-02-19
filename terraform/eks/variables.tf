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

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

# MongoDB Atlas credentials
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
  default     = "104.30.164.13/32"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Project     = "atlas-alerts"
    Environment = "demo"
    Owner       = "yc.yeo"
    ManagedBy   = "terraform"
  }
}
