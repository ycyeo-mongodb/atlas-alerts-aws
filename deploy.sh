#!/bin/bash
#
# Deploy Atlas Alerts to AWS EKS
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - kubectl configured to connect to your EKS cluster
#   - Docker installed (for building the image)
#
# Usage:
#   ./deploy.sh [build|push|deploy|all|dry-run|delete]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="atlas-alerts"
IMAGE_TAG="latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
success() { echo -e "${GREEN}$1${NC}"; }
warning() { echo -e "${YELLOW}$1${NC}"; }
info() { echo -e "$1"; }

# Build Docker image
build_image() {
    info "Building Docker image: ${IMAGE_NAME}:${IMAGE_TAG}"
    docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$SCRIPT_DIR"
    success "✓ Image built successfully"
}

# Push to ECR (Amazon Elastic Container Registry)
push_to_ecr() {
    if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$AWS_REGION" ]; then
        error "AWS_ACCOUNT_ID and AWS_REGION must be set"
        echo "  export AWS_ACCOUNT_ID=your-account-id"
        echo "  export AWS_REGION=your-region"
        exit 1
    fi

    ECR_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}"
    
    info "Logging into ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    
    info "Creating ECR repository (if not exists)..."
    aws ecr describe-repositories --repository-names "$IMAGE_NAME" --region "$AWS_REGION" 2>/dev/null || \
        aws ecr create-repository --repository-name "$IMAGE_NAME" --region "$AWS_REGION"
    
    info "Tagging and pushing image..."
    docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${ECR_REPO}:${IMAGE_TAG}"
    docker push "${ECR_REPO}:${IMAGE_TAG}"
    
    success "✓ Image pushed to ECR: ${ECR_REPO}:${IMAGE_TAG}"
    
    # Update job.yaml with ECR image
    info "Updating Kubernetes manifests with ECR image..."
    sed -i.bak "s|image: atlas-alerts:latest|image: ${ECR_REPO}:${IMAGE_TAG}|g" "$SCRIPT_DIR/k8s/job.yaml"
    sed -i.bak "s|image: atlas-alerts:latest|image: ${ECR_REPO}:${IMAGE_TAG}|g" "$SCRIPT_DIR/k8s/cronjob.yaml"
    rm -f "$SCRIPT_DIR/k8s/"*.bak
}

# Deploy to Kubernetes
deploy_to_k8s() {
    info "Deploying to Kubernetes..."
    
    # Check kubectl connection
    if ! kubectl cluster-info &>/dev/null; then
        error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi
    
    info "Creating namespace..."
    kubectl apply -f "$SCRIPT_DIR/k8s/namespace.yaml"
    
    info "Creating secrets..."
    kubectl apply -f "$SCRIPT_DIR/k8s/secret.yaml"
    
    info "Creating job..."
    # Delete existing job if any
    kubectl delete job atlas-alerts-creator -n atlas-alerts --ignore-not-found
    kubectl apply -f "$SCRIPT_DIR/k8s/job.yaml"
    
    success "✓ Deployed successfully!"
    echo ""
    info "Monitor the job with:"
    echo "  kubectl logs -f job/atlas-alerts-creator -n atlas-alerts"
    echo ""
    info "Check job status:"
    echo "  kubectl get jobs -n atlas-alerts"
}

# Dry run - just show what would be deployed
dry_run() {
    info "DRY RUN - Showing what would be deployed:"
    echo ""
    echo "=== Namespace ==="
    cat "$SCRIPT_DIR/k8s/namespace.yaml"
    echo ""
    echo "=== Secret (credentials hidden) ==="
    cat "$SCRIPT_DIR/k8s/secret.yaml" | sed 's/: ".*"/: "***HIDDEN***"/g'
    echo ""
    echo "=== Job ==="
    cat "$SCRIPT_DIR/k8s/job.yaml"
}

# Delete deployment
delete_deployment() {
    warning "Deleting Atlas Alerts deployment..."
    kubectl delete namespace atlas-alerts --ignore-not-found
    success "✓ Deleted"
}

# Show usage
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  build     Build Docker image locally"
    echo "  push      Push image to AWS ECR (requires AWS_ACCOUNT_ID, AWS_REGION)"
    echo "  deploy    Deploy to Kubernetes (EKS)"
    echo "  all       Build, push, and deploy"
    echo "  dry-run   Show what would be deployed (no changes)"
    echo "  delete    Remove the deployment from Kubernetes"
    echo ""
    echo "Environment variables:"
    echo "  AWS_ACCOUNT_ID  Your AWS account ID (for ECR)"
    echo "  AWS_REGION      AWS region (e.g., us-east-1)"
}

# Main
case "${1:-}" in
    build)
        build_image
        ;;
    push)
        push_to_ecr
        ;;
    deploy)
        deploy_to_k8s
        ;;
    all)
        build_image
        push_to_ecr
        deploy_to_k8s
        ;;
    dry-run)
        dry_run
        ;;
    delete)
        delete_deployment
        ;;
    *)
        usage
        ;;
esac
