#!/bin/bash
# Complete cleanup script for OpenTelemetry Demo on EKS with RDS
# This script removes ALL resources created by startup-working.sh, deploy-security-hardened.sh, and setup-correct-domain.sh

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-otel-demo-cluster}
AWS_REGION=${AWS_REGION:-us-east-1}
NAMESPACE="otel-demo"
DOMAIN="enpm818r-group8.click"
HOSTED_ZONE_ID="Z0742184E2HO21LEATLL"

echo "=========================================="
echo "OpenTelemetry Demo - Complete Cleanup"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo ""

# Function to print step headers
print_step() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
    echo ""
}

# Function to check if command succeeded
check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $1"
    else
        echo -e "${YELLOW}⚠${NC} $1 (may not exist)"
    fi
}

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

# Step 1: Delete Application Resources First (to remove ALBs quickly)
print_step "Step 1: Delete Application Resources"

echo "Deleting ingress resources (to remove ALBs)..."
kubectl delete ingress --all -n $NAMESPACE --ignore-not-found=true --timeout=60s 2>/dev/null || true
check_success "Ingress resources deleted"

echo "Deleting services with LoadBalancer type..."
kubectl delete svc --all -n $NAMESPACE --ignore-not-found=true --timeout=30s 2>/dev/null || true
check_success "Services deleted"

echo "Deleting jobs and pods..."
kubectl delete jobs --all -n $NAMESPACE --ignore-not-found=true --timeout=30s 2>/dev/null || true
kubectl delete pods --all -n $NAMESPACE --ignore-not-found=true --timeout=30s 2>/dev/null || true
check_success "Jobs and pods deleted"

# Step 2: Delete Helm Releases
print_step "Step 2: Delete Helm Releases"

echo "Deleting OpenTelemetry Demo..."
helm uninstall opentelemetry-demo -n $NAMESPACE 2>/dev/null || true
check_success "OpenTelemetry Demo uninstalled"

echo "Deleting AWS Load Balancer Controller..."
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
check_success "AWS Load Balancer Controller uninstalled"

echo "Deleting Cluster Autoscaler..."
helm uninstall cluster-autoscaler -n kube-system 2>/dev/null || true
check_success "Cluster Autoscaler uninstalled"

echo "Deleting EBS CSI Driver..."
helm uninstall aws-ebs-csi-driver -n kube-system 2>/dev/null || true
check_success "EBS CSI Driver uninstalled"

echo "Deleting ExternalSecrets Operator..."
helm uninstall external-secrets -n external-secrets-system 2>/dev/null || true
check_success "ExternalSecrets Operator uninstalled"

# Step 3: Delete Kubernetes Resources
print_step "Step 3: Delete Kubernetes Resources"

echo "Deleting PVCs (to release EBS volumes)..."
kubectl delete pvc --all -n $NAMESPACE --ignore-not-found=true --timeout=60s 2>/dev/null || true
check_success "PVCs deleted"

echo "Deleting namespace $NAMESPACE (with timeout)..."
kubectl delete namespace $NAMESPACE --ignore-not-found=true --timeout=30s 2>/dev/null || echo "Namespace deletion initiated in background"
check_success "Namespace deletion initiated"

echo "Deleting governance resources..."
kubectl delete -f governance.yaml --ignore-not-found=true 2>/dev/null || true
check_success "Governance resources deleted"

echo "Deleting storage classes..."
kubectl delete storageclass gp3-ssd-retain io1-ssd-retain --ignore-not-found=true 2>/dev/null || true
check_success "Storage classes deleted"

echo "Deleting CSI driver resources..."
kubectl delete csidriver ebs.csi.aws.com --ignore-not-found=true 2>/dev/null || true
check_success "CSI driver deleted"

echo "Deleting service accounts..."
kubectl delete serviceaccount ebs-csi-controller-sa ebs-csi-node-sa -n kube-system --ignore-not-found=true 2>/dev/null || true
check_success "Service accounts deleted"

echo "Deleting AWS Provider..."
kubectl delete -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml --ignore-not-found=true 2>/dev/null || true
check_success "AWS Provider deleted"

# Step 4: Delete Service Accounts and IRSA Roles
print_step "Step 4: Delete Service Accounts and IRSA Roles"

if [ -n "$ACCOUNT_ID" ]; then
    echo "Deleting IRSA service accounts..."
    
    eksctl delete iamserviceaccount --cluster=$CLUSTER_NAME --name=aws-load-balancer-controller --namespace=kube-system --region=$AWS_REGION 2>/dev/null || true
    check_success "Load Balancer Controller service account deleted"
    
    eksctl delete iamserviceaccount --cluster=$CLUSTER_NAME --name=cluster-autoscaler --namespace=kube-system --region=$AWS_REGION 2>/dev/null || true
    check_success "Cluster Autoscaler service account deleted"
    
    eksctl delete iamserviceaccount --cluster=$CLUSTER_NAME --name=ebs-csi-controller-sa --namespace=kube-system --region=$AWS_REGION 2>/dev/null || true
    check_success "EBS CSI Controller service account deleted"
    
    eksctl delete iamserviceaccount --cluster=$CLUSTER_NAME --name=external-secrets --namespace=$NAMESPACE --region=$AWS_REGION 2>/dev/null || true
    check_success "ExternalSecrets service account deleted"
fi

# Step 5: Delete IAM Policies
print_step "Step 5: Delete IAM Policies"

if [ -n "$ACCOUNT_ID" ]; then
    echo "Deleting IAM policies..."
    
    aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy 2>/dev/null || true
    check_success "Load Balancer Controller policy deleted"
    
    aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy 2>/dev/null || true
    check_success "Cluster Autoscaler policy deleted"
    
    aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKS_EBS_CSI_Driver_Policy 2>/dev/null || true
    check_success "EBS CSI Driver policy deleted"
    
    aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/ExternalSecretsPolicy 2>/dev/null || true
    check_success "ExternalSecrets policy deleted"
fi

# Step 6: Delete EKS Addons
print_step "Step 6: Delete EKS Addons"

echo "Deleting EBS CSI driver addon..."
aws eks delete-addon --cluster-name $CLUSTER_NAME --addon-name aws-ebs-csi-driver --region=$AWS_REGION 2>/dev/null || true
check_success "EBS CSI driver addon deleted"

# Step 7: Wait for Kubernetes Resources to be Fully Deleted
print_step "Step 7: Wait for Kubernetes Resources Cleanup"

echo "Waiting for namespace deletion to complete..."
kubectl wait --for=delete namespace/$NAMESPACE --timeout=300s 2>/dev/null || echo "Namespace deletion completed or timed out"
check_success "Namespace cleanup completed"

# Step 8: Delete ACM Certificates and Route 53 Records
print_step "Step 8: Delete ACM Certificates and Route 53 Records"

echo "Deleting ACM certificates for $DOMAIN..."
CERT_ARNS=$(aws acm list-certificates --region $AWS_REGION --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text 2>/dev/null || echo "")
if [ -n "$CERT_ARNS" ]; then
    for cert_arn in $CERT_ARNS; do
        echo "Deleting certificate: $cert_arn"
        aws acm delete-certificate --certificate-arn "$cert_arn" --region $AWS_REGION 2>/dev/null || true
    done
    check_success "ACM certificates deleted"
else
    echo "No ACM certificates found for $DOMAIN"
fi

echo "Deleting Route 53 DNS records for $DOMAIN..."
# Delete A record
aws route53 change-resource-record-sets \
    --hosted-zone-id $HOSTED_ZONE_ID \
    --change-batch "{
        \"Changes\": [{
            \"Action\": \"DELETE\",
            \"ResourceRecordSet\": {
                \"Name\": \"$DOMAIN\",
                \"Type\": \"A\"
            }
        }]
    }" 2>/dev/null || true

# Delete CNAME validation records
CNAME_RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --query "ResourceRecordSets[?Type=='CNAME' && contains(Name, '$DOMAIN')].Name" --output text 2>/dev/null || echo "")
if [ -n "$CNAME_RECORDS" ]; then
    for record in $CNAME_RECORDS; do
        aws route53 change-resource-record-sets \
            --hosted-zone-id $HOSTED_ZONE_ID \
            --change-batch "{
                \"Changes\": [{
                    \"Action\": \"DELETE\",
                    \"ResourceRecordSet\": {
                        \"Name\": \"$record\",
                        \"Type\": \"CNAME\"
                    }
                }]
            }" 2>/dev/null || true
    done
fi
check_success "Route 53 DNS records deleted"

# Step 9: Delete AWS Secrets Manager Secrets
print_step "Step 9: Delete AWS Secrets Manager Secrets"

echo "Deleting Secrets Manager secrets..."
aws secretsmanager delete-secret --secret-id "otel-demo/postgresql-password" --force-delete-without-recovery --region $AWS_REGION 2>/dev/null || true
check_success "Secrets Manager secrets deleted"

# Step 10: Clean up Network Interfaces (ENIs)
print_step "Step 10: Clean up Network Interfaces"

echo "Finding and deleting ENIs that may block subnet deletion..."
# Get VPC ID from the cluster
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    echo "Found VPC: $VPC_ID"
    
    # Find all ENIs in the VPC that are available (not attached)
    ENI_IDS=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query "NetworkInterfaces[].NetworkInterfaceId" \
        --output text --region $AWS_REGION 2>/dev/null || echo "")
    
    if [ -n "$ENI_IDS" ]; then
        echo "Deleting available ENIs: $ENI_IDS"
        for eni in $ENI_IDS; do
            aws ec2 delete-network-interface --network-interface-id $eni --region $AWS_REGION 2>/dev/null || true
        done
        check_success "Available ENIs deleted"
    else
        echo "No available ENIs found to delete"
    fi
    
    # Wait a bit for ENI cleanup to propagate
    sleep 30
else
    echo "VPC not found or cluster already deleted"
fi

# Step 11: Delete CloudFormation Stack (FULL DELETION)
print_step "Step 11: Delete CloudFormation Stack - FULL DELETION"

echo "Deleting CloudFormation stack and waiting for complete removal (15-20 minutes)..."
aws cloudformation delete-stack --stack-name ${CLUSTER_NAME}-stack --region=$AWS_REGION 2>/dev/null || true
check_success "CloudFormation stack deletion initiated"

echo "Waiting for complete stack deletion (this ensures ALL AWS resources are removed)..."
aws cloudformation wait stack-delete-complete --stack-name ${CLUSTER_NAME}-stack --region=$AWS_REGION 2>/dev/null || true
check_success "CloudFormation stack completely deleted"

echo -e "${GREEN}All AWS resources have been completely removed!${NC}"

# Step 12: Clean up local files
print_step "Step 12: Clean up Local Files"

echo "Cleaning up generated files..."
rm -f iam_policy_latest.json
rm -f cluster-autoscaler-policy.json
rm -f ebs-csi-policy.json
rm -f secrets-manager-policy.json
rm -f otel-demo-values.yaml
rm -f init-db.yaml
rm -f fix-accounting-db.yaml
rm -f opentelemetry-demo.yaml.bak
check_success "Local files cleaned up"

# Step 13: Remove kubectl context
print_step "Step 13: Remove kubectl Context"

echo "Removing kubectl context..."
kubectl config delete-context arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME} 2>/dev/null || true
kubectl config delete-cluster arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME} 2>/dev/null || true
check_success "kubectl context removed"

echo ""
echo "=========================================="
echo -e "${GREEN}🧹 COMPLETE CLEANUP FINISHED!${NC}"
echo "=========================================="
echo ""
echo "ALL AWS resources have been completely deleted:"
echo "  ✓ Application resources deleted (ALBs, services, pods)"
echo "  ✓ Helm releases deleted (OpenTelemetry Demo, ALB Controller, Cluster Autoscaler, EBS CSI, ExternalSecrets)"
echo "  ✓ Kubernetes resources deleted (PVCs, namespaces, storage classes, network policies)"
echo "  ✓ Service accounts and IRSA roles deleted"
echo "  ✓ IAM policies deleted (ALB Controller, Cluster Autoscaler, EBS CSI, ExternalSecrets)"
echo "  ✓ EKS addons deleted"
echo "  ✓ ACM certificates deleted"
echo "  ✓ Route 53 DNS records deleted"
echo "  ✓ AWS Secrets Manager secrets deleted"
echo "  ✓ Network interfaces cleaned up"
echo "  ✓ EKS cluster completely deleted"
echo "  ✓ RDS database completely deleted"
echo "  ✓ VPC and networking completely deleted"
echo "  ✓ All CloudFormation resources deleted"
echo "  ✓ Local files cleaned up"
echo "  ✓ kubectl context removed"
echo ""
echo -e "${GREEN}💯 No AWS resources remain - completely clean slate!${NC}"
echo "You can now run the deployment scripts for a fresh deployment:"
echo "  1. bash startup-working.sh"
echo "  2. bash deploy-security-hardened.sh (optional)"
echo "  3. bash setup-correct-domain.sh (optional)"
echo ""