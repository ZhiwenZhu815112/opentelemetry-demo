#!/bin/bash
# Startup script for OpenTelemetry Demo on EKS with RDS
# This script automates the deployment process from README_RDS.md

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
AWS_PROFILE=${AWS_PROFILE:-JulianFTA}
PG_VERSION=${PG_VERSION:-15.14}
NAMESPACE="otel-demo"

# Flags for skipping steps
SKIP_CLUSTER_CREATION=${SKIP_CLUSTER_CREATION:-false}
SKIP_RDS_SEEDING=${SKIP_RDS_SEEDING:-false}

echo "=========================================="
echo "OpenTelemetry Demo - EKS Deployment"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Profile: $AWS_PROFILE"
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
        echo -e "${RED}✗${NC} $1"
        exit 1
    fi
}

# Function to wait for CloudFormation stack
wait_for_stack() {
    local stack_name=$1
    local desired_status=$2
    local timeout=${3:-1800}  # 30 minutes default
    
    echo "Waiting for stack $stack_name to reach $desired_status (timeout: ${timeout}s)..."
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local status=$(aws cloudformation describe-stacks \
            --stack-name $stack_name \
            --query "Stacks[0].StackStatus" \
            --output text \
            --region $AWS_REGION \
            --profile $AWS_PROFILE 2>/dev/null || echo "NOT_FOUND")
        
        if [ "$status" == "$desired_status" ]; then
            echo -e "${GREEN}✓${NC} Stack reached $desired_status"
            return 0
        elif [[ "$status" == *"FAILED"* ]] || [[ "$status" == *"ROLLBACK"* ]]; then
            echo -e "${RED}✗${NC} Stack failed with status: $status"
            return 1
        fi
        
        echo "  Status: $status (${elapsed}/${timeout}s)"
        sleep 30
        elapsed=$((elapsed + 30))
    done
    
    echo -e "${YELLOW}⚠${NC} Timeout waiting for stack"
    return 1
}

# Step 1: AWS Account Setup
print_step "Step 1: AWS Account Setup"

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text)
check_success "Retrieved AWS Account ID: $ACCOUNT_ID"

# Set DB password if not provided
if [ -z "$DB_PASSWORD" ]; then
    echo -e "${YELLOW}⚠${NC} DB_PASSWORD not set. Generating secure password..."
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    echo "Generated password: $DB_PASSWORD"
    echo "⚠️  IMPORTANT: Save this password securely!"
fi

export CLUSTER_NAME
export AWS_REGION
export AWS_PROFILE
export ACCOUNT_ID
export DB_PASSWORD

echo "Configuration:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region: $AWS_REGION"
echo "  Account: $ACCOUNT_ID"
echo "  Profile: $AWS_PROFILE"

# Step 2: Deploy EKS Cluster with CloudFormation
print_step "Step 2: Deploy EKS Cluster with CloudFormation (includes RDS)"

if [ "$SKIP_CLUSTER_CREATION" == "true" ]; then
    echo -e "${YELLOW}⚠${NC} Skipping cluster creation (SKIP_CLUSTER_CREATION=true)"
else
    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name ${CLUSTER_NAME}-stack --region $AWS_REGION --profile $AWS_PROFILE &>/dev/null; then
        echo -e "${YELLOW}⚠${NC} Stack ${CLUSTER_NAME}-stack already exists"
        read -p "Continue with existing stack? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "Creating CloudFormation stack (this takes 15-20 minutes for RDS)..."
        aws cloudformation create-stack \
            --stack-name ${CLUSTER_NAME}-stack \
            --template-body file://eks-infra.yaml \
            --parameters \
                ParameterKey=ClusterName,ParameterValue=${CLUSTER_NAME} \
                ParameterKey=KubernetesVersion,ParameterValue=1.30 \
                ParameterKey=VpcCidr,ParameterValue=10.0.0.0/16 \
                ParameterKey=DBName,ParameterValue=otel \
                ParameterKey=DBUsername,ParameterValue=otelu \
                ParameterKey=DBPassword,ParameterValue=${DB_PASSWORD} \
                ParameterKey=DBEngineVersion,ParameterValue=${PG_VERSION} \
            --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
            --region $AWS_REGION \
            --profile $AWS_PROFILE
        
        check_success "CloudFormation stack creation initiated"
        
        wait_for_stack "${CLUSTER_NAME}-stack" "CREATE_COMPLETE" 1800
    fi
fi

# Step 3: Configure kubectl
print_step "Step 3: Configure kubectl"

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION --profile $AWS_PROFILE
check_success "kubectl configured"

kubectl get nodes
check_success "Connected to cluster"

# Step 4: Governance & RBAC
print_step "Step 4: Governance & Role-Based Access Control (RBAC)"

kubectl apply -f governance.yaml
check_success "Governance resources applied"

# Step 5: Install AWS Load Balancer Controller and Cluster Autoscaler
print_step "Step 5: Install AWS Load Balancer Controller and Cluster Autoscaler"

# Get VPC ID
VPC_ID=$(aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --region $AWS_REGION \
    --profile $AWS_PROFILE \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)
check_success "Retrieved VPC ID: $VPC_ID"

# Install Load Balancer Controller
echo "Installing AWS Load Balancer Controller..."

# Download IAM policy
if [ ! -f iam_policy_latest.json ]; then
    curl -o iam_policy_latest.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
fi

aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy_latest.json --profile $AWS_PROFILE 2>/dev/null || echo "Policy already exists"

# Create service account
eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --approve \
    --region=$AWS_REGION \
    --profile=$AWS_PROFILE 2>/dev/null || echo "Service account already exists"

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region=$AWS_REGION \
    --set vpcId=$VPC_ID \
    --wait --timeout=5m

check_success "AWS Load Balancer Controller installed"

# Install Cluster Autoscaler
echo "Installing Cluster Autoscaler..."

# Create IAM policy
if [ ! -f cluster-autoscaler-policy.json ]; then
    cat <<EOF > cluster-autoscaler-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup",
                "ec2:DescribeLaunchTemplateVersions"
            ],
            "Resource": "*"
        }
    ]
}
EOF
fi

aws iam create-policy --policy-name AmazonEKSClusterAutoscalerPolicy --policy-document file://cluster-autoscaler-policy.json --profile $AWS_PROFILE 2>/dev/null || echo "Policy already exists"

# Create service account
eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=kube-system \
    --name=cluster-autoscaler \
    --role-name AmazonEKSClusterAutoscalerRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy \
    --override-existing-serviceaccounts \
    --approve \
    --region=$AWS_REGION \
    --profile=$AWS_PROFILE 2>/dev/null || echo "Service account already exists"

# Install via Helm
helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
helm repo update

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
    -n kube-system \
    --set autoDiscovery.clusterName=$CLUSTER_NAME \
    --set awsRegion=$AWS_REGION \
    --set rbac.serviceAccount.create=false \
    --set rbac.serviceAccount.name=cluster-autoscaler \
    --wait --timeout=5m

check_success "Cluster Autoscaler installed"

# Step 6: Install EBS CSI Driver
print_step "Step 6: Install EBS CSI Driver"

echo "Installing EBS CSI Driver..."

# Download IAM policy
if [ ! -f ebs-csi-policy.json ]; then
    curl -o ebs-csi-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json
fi

aws iam create-policy \
    --policy-name AmazonEKS_EBS_CSI_Driver_Policy \
    --policy-document file://ebs-csi-policy.json \
    --profile $AWS_PROFILE 2>/dev/null || echo "Policy already exists"

# Create IRSA service account
eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=kube-system \
    --name=ebs-csi-controller-sa \
    --role-name AmazonEKS_EBS_CSI_DriverRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKS_EBS_CSI_Driver_Policy \
    --override-existing-serviceaccounts \
    --approve \
    --region=$AWS_REGION \
    --profile=$AWS_PROFILE 2>/dev/null || echo "Service account already exists"

# Install driver
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver 2>/dev/null || true
helm repo update

helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
    -n kube-system \
    --set controller.serviceAccount.create=false \
    --set controller.serviceAccount.name=ebs-csi-controller-sa \
    --wait --timeout=5m

check_success "EBS CSI Driver installed"

# Step 7: Apply StorageClasses
print_step "Step 7: Apply StorageClasses"

kubectl apply -f storageclasses.yaml
check_success "StorageClasses applied"

kubectl get storageclass

# Step 8: Install Secrets Manager CSI Driver
print_step "Step 8: Install Secrets Manager CSI Driver"

echo "Installing Secrets Store CSI Driver..."

helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts 2>/dev/null || true
helm repo update

helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
    --namespace kube-system \
    --set syncSecret.enabled=true \
    --set enableSecretRotation=true \
    --wait --timeout=5m

check_success "Secrets Store CSI Driver installed"

# Install AWS Provider
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
check_success "AWS Provider installed"

# Wait for provider pods
echo "Waiting for AWS Provider pods to be ready..."
kubectl wait --for=condition=ready pod -l app=secrets-store-csi-driver-provider-aws -n kube-system --timeout=300s || true

# Step 9: Setup Secrets Manager Integration
print_step "Step 9: Setup Secrets Manager Integration"

# Create IAM Policy
if [ ! -f secrets-manager-policy.json ]; then
    cat <<EOF > secrets-manager-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:*:*:secret:otel-demo/rds/*",
        "arn:aws:secretsmanager:*:*:secret:otel-demo/grafana/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["kms:Decrypt"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "secretsmanager.*.amazonaws.com"
        }
      }
    }
  ]
}
EOF
fi

aws iam create-policy \
    --policy-name OtelDemoSecretsManagerPolicy \
    --policy-document file://secrets-manager-policy.json \
    --profile $AWS_PROFILE 2>/dev/null || echo "Policy already exists"

# Create IRSA Service Accounts
eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=otel-demo \
    --name=otel-demo-secrets-sa \
    --role-name OtelDemoSecretsManagerRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoSecretsManagerPolicy \
    --override-existing-serviceaccounts \
    --approve \
    --region=$AWS_REGION \
    --profile=$AWS_PROFILE 2>/dev/null || echo "Service account already exists"

eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=otel-demo \
    --name=grafana-secrets-sa \
    --role-name GrafanaSecretsManagerRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoSecretsManagerPolicy \
    --override-existing-serviceaccounts \
    --approve \
    --region=$AWS_REGION \
    --profile=$AWS_PROFILE 2>/dev/null || echo "Service account already exists"

check_success "IRSA Service Accounts created"

# Create namespace if it doesn't exist
kubectl create namespace otel-demo --dry-run=client -o yaml | kubectl apply -f -

# Create secrets in AWS Secrets Manager
if [ -f create-secrets.sh ]; then
    chmod +x create-secrets.sh
    export DB_PASSWORD
    ./create-secrets.sh
    check_success "Secrets created in AWS Secrets Manager"
else
    echo -e "${YELLOW}⚠${NC} create-secrets.sh not found, skipping secret creation"
fi

# Apply SecretProviderClasses
kubectl apply -f secret-provider-class-db.yaml
kubectl apply -f secret-provider-class-grafana.yaml
check_success "SecretProviderClasses applied"

# Sync secrets (create temporary pods to trigger sync)
if [ -f sync-secrets.sh ]; then
    chmod +x sync-secrets.sh
    ./sync-secrets.sh
else
    echo -e "${YELLOW}⚠${NC} sync-secrets.sh not found, you may need to manually sync secrets"
fi

# Step 10: RDS Database Setup
print_step "Step 10: RDS Database Setup"

# Get RDS endpoint
RDS_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name ${CLUSTER_NAME}-stack \
    --query "Stacks[0].Outputs[?OutputKey=='PostgresEndpoint'].OutputValue" \
    --output text \
    --region $AWS_REGION \
    --profile $AWS_PROFILE)

RDS_PORT=$(aws cloudformation describe-stacks \
    --stack-name ${CLUSTER_NAME}-stack \
    --query "Stacks[0].Outputs[?OutputKey=='PostgresPort'].OutputValue" \
    --output text \
    --region $AWS_REGION \
    --profile $AWS_PROFILE)

if [ -z "$RDS_ENDPOINT" ] || [ "$RDS_ENDPOINT" == "None" ]; then
    echo -e "${RED}✗${NC} Could not retrieve RDS endpoint from CloudFormation"
    exit 1
fi

echo "RDS Endpoint: ${RDS_ENDPOINT}:${RDS_PORT}"
check_success "Retrieved RDS endpoint"

# Verify RDS is available
RDS_STATUS=$(aws rds describe-db-instances \
    --query "DBInstances[?contains(Endpoint.Address, '${RDS_ENDPOINT}')].DBInstanceStatus" \
    --output text \
    --region $AWS_REGION \
    --profile $AWS_PROFILE)

if [ "$RDS_STATUS" != "available" ]; then
    echo -e "${YELLOW}⚠${NC} RDS status: $RDS_STATUS (expected: available)"
else
    check_success "RDS is available"
fi

# Update opentelemetry-demo.yaml with RDS endpoint
if [ -f opentelemetry-demo.yaml ]; then
    sed -i.bak "s/externalName: <RDS_ENDPOINT>/externalName: ${RDS_ENDPOINT}/" opentelemetry-demo.yaml
    check_success "Updated opentelemetry-demo.yaml with RDS endpoint"
fi

# Seed RDS database
if [ "$SKIP_RDS_SEEDING" == "true" ]; then
    echo -e "${YELLOW}⚠${NC} Skipping RDS seeding (SKIP_RDS_SEEDING=true)"
else
    if [ -f seed-rds-from-pod.sh ]; then
        chmod +x seed-rds-from-pod.sh
        export RDS_ENDPOINT
        export RDS_PORT
        ./seed-rds-from-pod.sh
        check_success "RDS database seeded"
    else
        echo -e "${YELLOW}⚠${NC} seed-rds-from-pod.sh not found, skipping RDS seeding"
    fi
fi

# Step 11: Deploy Applications
print_step "Step 11: Deploy Applications"

# Create namespace
kubectl create namespace otel-demo --dry-run=client -o yaml | kubectl apply -f -

# Deploy OpenTelemetry Demo
if [ -f opentelemetry-demo.yaml ]; then
    kubectl apply -n otel-demo -f opentelemetry-demo.yaml
    check_success "OpenTelemetry Demo deployed"
    
    # Verify postgresql service
    sleep 5
    kubectl patch svc postgresql -n otel-demo -p "{\"spec\":{\"externalName\":\"${RDS_ENDPOINT}\"}}" 2>/dev/null || true
    
    echo "Waiting for pods to start..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/part-of=opentelemetry-demo -n otel-demo --timeout=600s || echo "Some pods may still be starting"
    
    kubectl get pods -n otel-demo
    kubectl get pvc -n otel-demo
else
    echo -e "${RED}✗${NC} opentelemetry-demo.yaml not found"
    exit 1
fi

# Step 12: Deploy Ingress
print_step "Step 12: Deploy Ingress (ALB)"

if [ -f final-ingress.yaml ]; then
    kubectl apply -f final-ingress.yaml
    check_success "Ingress deployed"
    
    echo "Waiting for ALB to be created (this may take a few minutes)..."
    sleep 30
    
    ALB_URL=$(kubectl get ingress otel-demo-ingress -n otel-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ALB_URL" ]; then
        echo -e "${GREEN}✓${NC} ALB URL: http://$ALB_URL"
    else
        echo -e "${YELLOW}⚠${NC} ALB URL not yet available. Check with: kubectl get ingress -n otel-demo"
    fi
else
    echo -e "${YELLOW}⚠${NC} final-ingress.yaml not found, skipping ingress deployment"
fi

# Final Summary
echo ""
echo "=========================================="
echo -e "${GREEN}Deployment Complete!${NC}"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Namespace: $NAMESPACE"
echo "  RDS Endpoint: ${RDS_ENDPOINT}:${RDS_PORT}"
if [ -n "$ALB_URL" ]; then
    echo "  ALB URL: http://$ALB_URL"
fi
echo ""
echo "Next steps:"
echo "  1. Check pod status: kubectl get pods -n otel-demo"
echo "  2. Check PVCs: kubectl get pvc -n otel-demo"
echo "  3. Check secrets: kubectl get secrets -n otel-demo | grep -E 'db-credentials|grafana-admin'"
echo "  4. View logs: kubectl logs -n otel-demo deployment/accounting --tail=50"
echo ""
echo "To clean up, run: ./cleanup.sh"
echo ""

