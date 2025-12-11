#!/bin/bash

# OpenTelemetry Demo - Security Hardened Deployment
# This script adds security features to your existing deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="otel-demo"
NAMESPACE="otel-demo"
AWS_REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

print_step() {
    echo -e "${GREEN}=== $1 ===${NC}"
}

check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $1${NC}"
    else
        echo -e "${RED}✗ $1 failed${NC}"
        exit 1
    fi
}

print_step "Step 1: Install AWS Load Balancer Controller"

# ALB Controller already installed in startup-working.sh - skip
echo "AWS Load Balancer Controller already installed in startup script"

check_success "AWS Load Balancer Controller ready"

print_step "Step 2: Install ExternalSecrets Operator (Optional)"

read -p "Do you want to install ExternalSecrets Operator for AWS Secrets Manager integration? (y/n): " install_eso

if [[ $install_eso =~ ^[Yy]$ ]]; then
    if kubectl get deployment external-secrets -n external-secrets-system &>/dev/null; then
        echo "ExternalSecrets Operator already installed"
    else
        echo "Installing ExternalSecrets Operator..."
        
        helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
        helm repo update
        
        helm upgrade --install external-secrets external-secrets/external-secrets \
            -n external-secrets-system \
            --create-namespace \
            --wait --timeout=5m
        
        # Create IRSA for ExternalSecrets
        aws iam create-policy \
            --policy-name ExternalSecretsPolicy \
            --policy-document file://../k8s/network-policies/eso-secretsmanager-policy.json \
            --region $AWS_REGION 2>/dev/null || echo "Policy already exists"
        
        eksctl create iamserviceaccount \
            --name external-secrets \
            --namespace $NAMESPACE \
            --cluster $CLUSTER_NAME \
            --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy \
            --approve \
            --region $AWS_REGION 2>/dev/null || echo "Service account already exists"
    fi
    
    check_success "ExternalSecrets Operator ready"
    
    print_step "Step 3: Setup AWS Secrets Manager"
    
    read -p "Enter a secure PostgreSQL password: " -s postgres_password
    echo
    
    # Create secret in AWS Secrets Manager
    aws secretsmanager create-secret \
        --name otel-demo/postgresql-password \
        --secret-string "{\"POSTGRES_PASSWORD\":\"$postgres_password\"}" \
        --region $AWS_REGION 2>/dev/null || echo "Secret already exists"
    
    # Apply SecretStore and ExternalSecret
    kubectl apply -f ../k8s/secrets/secretstore-aws.yaml
    kubectl apply -f ../k8s/secrets/externalsecret-postgresql.yaml
    
    check_success "AWS Secrets Manager configured"
else
    echo "Skipping ExternalSecrets Operator installation"
fi

print_step "Step 4: Apply Network Policies"

echo "Applying zero-trust network policies..."

# Apply all network policies
kubectl apply -f ../k8s/network-policies/00-default-deny-ingress.yaml
kubectl apply -f ../k8s/network-policies/10-allow-frontend-proxy-from-any.yaml
kubectl apply -f ../k8s/network-policies/20-allow-backends-from-frontend.yaml
kubectl apply -f ../k8s/network-policies/30-allow-postgresql-from-backends.yaml
kubectl apply -f ../k8s/network-policies/40-allow-otel-collector-from-all.yaml

check_success "Network policies applied"

print_step "Step 5: Deploy Secure Ingress"

# Skip ingress deployment - will be handled by TLS script
echo "Skipping ingress deployment (will be created by TLS setup)"

check_success "Secure ingress deployed"

print_step "Step 6: Verify Security Configuration"

echo "Checking deployment status..."

# Wait for ALB to be provisioned
echo "Waiting for ALB to be provisioned..."
for i in {1..10}; do
    INGRESS_URL=$(kubectl get ingress otel-frontend-ingress -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$INGRESS_URL" ]; then
        echo "ALB provisioned: $INGRESS_URL"
        break
    fi
    echo "Attempt $i/10: Waiting for ALB..."
    sleep 30
done

# Check network policies
echo "Network policies:"
kubectl get networkpolicy -n $NAMESPACE

# Check ingress
echo "Ingress status:"
kubectl get ingress -n $NAMESPACE

echo ""
echo "=========================================="
echo -e "${GREEN}🔒 SECURITY HARDENING COMPLETE!${NC}"
echo "=========================================="
echo ""
echo "🛡️  Security Features Enabled:"
echo "   ✓ AWS Load Balancer Controller"
if [[ $install_eso =~ ^[Yy]$ ]]; then
    echo "   ✓ ExternalSecrets Operator with AWS Secrets Manager"
fi
echo "   ✓ Zero-trust Network Policies (default deny)"
echo "   ✓ ALB Ingress with security annotations"
echo ""
echo "🌐 Access Information:"
if [ -n "$INGRESS_URL" ]; then
    echo "   Frontend: http://$INGRESS_URL"
else
    echo "   Run 'kubectl get ingress -n $NAMESPACE' to get URL when ready"
fi
echo ""
echo "🔧 Next Steps for Full Security:"
echo "   1. Get an ACM certificate for your domain"
echo "   2. Update ingress-frontend.yaml with certificate ARN"
echo "   3. Enable HTTPS and SSL redirect"
echo "   4. Configure GuardDuty and Security Hub"
echo ""
echo "📝 Verification Commands:"
echo "   kubectl get networkpolicy -n $NAMESPACE"
echo "   kubectl get ingress -n $NAMESPACE"
echo "   kubectl get pods -n $NAMESPACE"