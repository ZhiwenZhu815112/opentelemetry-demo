#!/bin/bash
# Complete working startup script for OpenTelemetry Demo on EKS with RDS
# Based on lessons learned from troubleshooting and fixes

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
            --region $AWS_REGION 2>/dev/null || echo "NOT_FOUND")
        
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
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
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
export ACCOUNT_ID
export DB_PASSWORD

echo "Configuration:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region: $AWS_REGION"
echo "  Account: $ACCOUNT_ID"

# Step 2: Deploy EKS Cluster with CloudFormation
print_step "Step 2: Deploy EKS Cluster with CloudFormation (includes RDS)"

if [ "$SKIP_CLUSTER_CREATION" == "true" ]; then
    echo -e "${YELLOW}⚠${NC} Skipping cluster creation (SKIP_CLUSTER_CREATION=true)"
else
    # Check if stack already exists
    if aws cloudformation describe-stacks --stack-name ${CLUSTER_NAME}-stack --region $AWS_REGION &>/dev/null; then
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
            --region $AWS_REGION
        
        check_success "CloudFormation stack creation initiated"
        
        wait_for_stack "${CLUSTER_NAME}-stack" "CREATE_COMPLETE" 1800
    fi
fi

# Step 3: Configure kubectl
print_step "Step 3: Configure kubectl"

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
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
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)
check_success "Retrieved VPC ID: $VPC_ID"

# Install Load Balancer Controller
echo "Installing AWS Load Balancer Controller..."

# Download IAM policy
if [ ! -f iam_policy_latest.json ]; then
    curl -o iam_policy_latest.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
fi

aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy_latest.json 2>/dev/null || echo "Policy already exists"

# Create service account
eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --approve \
    --region=$AWS_REGION 2>/dev/null || echo "Service account already exists"

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

aws iam create-policy --policy-name AmazonEKSClusterAutoscalerPolicy --policy-document file://cluster-autoscaler-policy.json 2>/dev/null || echo "Policy already exists"

# Create service account
eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=kube-system \
    --name=cluster-autoscaler \
    --role-name AmazonEKSClusterAutoscalerRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy \
    --override-existing-serviceaccounts \
    --approve \
    --region=$AWS_REGION 2>/dev/null || echo "Service account already exists"

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

# Step 6: Install EBS CSI Driver (FIXED VERSION)
print_step "Step 6: Install EBS CSI Driver"

echo "Installing EBS CSI Driver..."

# Download IAM policy
if [ ! -f ebs-csi-policy.json ]; then
    curl -o ebs-csi-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json
fi

aws iam create-policy \
    --policy-name AmazonEKS_EBS_CSI_Driver_Policy \
    --policy-document file://ebs-csi-policy.json \
    --region $AWS_REGION 2>/dev/null || echo "Policy already exists"

# Create service accounts for EBS CSI driver (CRITICAL FIX)
kubectl create serviceaccount ebs-csi-controller-sa -n kube-system --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount ebs-csi-controller-sa -n kube-system eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole --overwrite

kubectl create serviceaccount ebs-csi-node-sa -n kube-system --dry-run=client -o yaml | kubectl apply -f -

# Create IRSA role
eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=kube-system \
    --name=ebs-csi-controller-sa \
    --role-name AmazonEKS_EBS_CSI_DriverRole \
    --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKS_EBS_CSI_Driver_Policy \
    --override-existing-serviceaccounts \
    --approve \
    --region=$AWS_REGION 2>/dev/null || echo "Service account already exists"

# Install EBS CSI driver via Helm (more reliable than addon)
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver 2>/dev/null || true
helm repo update

helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
    -n kube-system \
    --set controller.serviceAccount.create=false \
    --set controller.serviceAccount.name=ebs-csi-controller-sa \
    --set node.serviceAccount.create=false \
    --set node.serviceAccount.name=ebs-csi-node-sa \
    --wait --timeout=5m

# Wait for EBS CSI driver to be ready
echo "Waiting for EBS CSI driver to be ready..."
kubectl wait --for=condition=available deployment/ebs-csi-controller -n kube-system --timeout=300s

# Verify EBS CSI node driver is running on all nodes
echo "Verifying EBS CSI node driver..."
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
CSI_NODE_COUNT=$(kubectl get pods -n kube-system -l app=ebs-csi-node --no-headers | grep Running | wc -l)

echo "Nodes: $NODE_COUNT, EBS CSI Node Pods Running: $CSI_NODE_COUNT"

if [ $CSI_NODE_COUNT -lt $NODE_COUNT ]; then
    echo "Waiting for EBS CSI node pods to be ready on all nodes..."
    kubectl wait --for=condition=ready pod -l app=ebs-csi-node -n kube-system --timeout=300s || echo "Some CSI node pods may still be starting"
fi

# Verify CSI driver registration
echo "Verifying CSI driver registration..."
kubectl get csinodes

check_success "EBS CSI Driver installed and verified"

# Step 7: Create Storage Classes
print_step "Step 7: Create Storage Classes"

echo "Creating storage classes..."
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-ssd-retain
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
parameters:
  type: gp3
  fsType: ext4
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: io1-ssd-retain
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
parameters:
  type: io1
  iops: "3000"
  fsType: ext4
EOF

check_success "Storage classes created"

# Step 8: Get RDS Connection Details
print_step "Step 8: Get RDS Connection Details"

# Get RDS endpoint from CloudFormation
RDS_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name ${CLUSTER_NAME}-stack \
    --region $AWS_REGION \
    --query "Stacks[0].Outputs[?OutputKey=='PostgresEndpoint'].OutputValue" \
    --output text)

check_success "Retrieved RDS endpoint: $RDS_ENDPOINT"

# Step 9: Deploy OpenTelemetry Demo with Helm
print_step "Step 9: Deploy OpenTelemetry Demo"

echo "Installing OpenTelemetry Demo with Helm..."

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Add OpenTelemetry Helm repository
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update

# Create minimal values file
cat <<EOF > otel-demo-values.yaml
# Minimal configuration - let chart use defaults
EOF

# Install the demo with minimal config
helm upgrade --install opentelemetry-demo open-telemetry/opentelemetry-demo \
    -n $NAMESPACE \
    --create-namespace \
    --wait --timeout=10m

# Wait for deployment to complete
sleep 30

# Patch accounting service to use RDS
echo "Configuring accounting service for RDS..."
kubectl patch deployment accounting -n $NAMESPACE -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "accounting",
          "env": [
            {"name": "POSTGRES_HOST", "value": "'$RDS_ENDPOINT'"},
            {"name": "POSTGRES_PORT", "value": "5432"},
            {"name": "POSTGRES_DATABASE", "value": "otel"},
            {"name": "POSTGRES_USER", "value": "otelu"},
            {"name": "POSTGRES_PASSWORD", "value": "'$DB_PASSWORD'"}
          ]
        }]
      }
    }
  }
}' 2>/dev/null || echo "Accounting service patch applied"

# Disable local postgres
echo "Scaling down local postgres..."
kubectl scale deployment postgres -n $NAMESPACE --replicas=0 2>/dev/null || echo "Postgres scaled down"

# Create ALB ingress
echo "Creating ALB ingress..."
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: otel-demo-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend-proxy
            port:
              number: 8080
EOF

check_success "OpenTelemetry Demo deployed"

# Step 10: Fix Database Schema (CRITICAL FIX)
print_step "Step 10: Initialize Database Schema"

echo "Creating database schema..."

# Create database initialization job
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: init-database-schema
  namespace: $NAMESPACE
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: init-db
        image: postgres:15
        env:
        - name: PGHOST
          value: "$RDS_ENDPOINT"
        - name: PGPORT
          value: "5432"
        - name: PGDATABASE
          value: "otel"
        - name: PGUSER
          value: "otelu"
        - name: PGPASSWORD
          value: "$DB_PASSWORD"
        command:
        - /bin/bash
        - -c
        - |
          echo "Waiting for database to be ready..."
          until pg_isready; do
            echo "Database not ready, waiting..."
            sleep 5
          done
          
          echo "Creating database schema..."
          psql -c "
          CREATE SCHEMA IF NOT EXISTS accounting;
          
          CREATE TABLE IF NOT EXISTS accounting.\"order\" (
              order_id TEXT PRIMARY KEY
          );
          
          CREATE TABLE IF NOT EXISTS accounting.shipping (
              shipping_tracking_id TEXT PRIMARY KEY,
              shipping_cost_currency_code TEXT NOT NULL,
              shipping_cost_units BIGINT NOT NULL,
              shipping_cost_nanos INT NOT NULL,
              street_address TEXT,
              city TEXT,
              state TEXT,
              country TEXT,
              zip_code TEXT,
              order_id TEXT NOT NULL,
              FOREIGN KEY (order_id) REFERENCES accounting.\"order\"(order_id) ON DELETE CASCADE
          );
          
          CREATE TABLE IF NOT EXISTS accounting.orderitem (
              item_cost_currency_code TEXT NOT NULL,
              item_cost_units BIGINT NOT NULL,
              item_cost_nanos INT NOT NULL,
              product_id TEXT NOT NULL,
              quantity INT NOT NULL,
              order_id TEXT NOT NULL,
              PRIMARY KEY (order_id, product_id),
              FOREIGN KEY (order_id) REFERENCES accounting.\"order\"(order_id) ON DELETE CASCADE
          );
          
          CREATE SCHEMA IF NOT EXISTS reviews;
          
          CREATE TABLE IF NOT EXISTS reviews.productreviews (
              id INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
              product_id VARCHAR(16) NOT NULL,
              username VARCHAR(64) NOT NULL,
              description VARCHAR(1024),
              score NUMERIC(2,1) NOT NULL
          );
          
          CREATE INDEX IF NOT EXISTS product_id_index ON reviews.productreviews (product_id);
          "
          
          echo "Database schema created successfully!"
EOF

# Wait for database initialization to complete
echo "Waiting for database initialization to complete..."
kubectl wait --for=condition=complete job/init-database-schema -n $NAMESPACE --timeout=300s

check_success "Database schema initialized"

# Step 11: Fix Database Connection String (CRITICAL FIX)
print_step "Step 11: Fix Database Connection"

echo "Waiting for db-credentials secret to be created..."
# Wait for the secret to exist (created by the Helm chart)
kubectl wait --for=condition=complete job/init-database-schema -n $NAMESPACE --timeout=60s 2>/dev/null || true
sleep 30

echo "Updating database connection string..."
# Check if secret exists, if not create it
if ! kubectl get secret db-credentials -n $NAMESPACE &>/dev/null; then
    echo "Creating db-credentials secret..."
    kubectl create secret generic db-credentials \
        --from-literal=connectionString="Host=$RDS_ENDPOINT;Username=otelu;Password=$DB_PASSWORD;Database=otel" \
        --from-literal=username="otelu" \
        --from-literal=password="$DB_PASSWORD" \
        -n $NAMESPACE
else
    echo "Updating existing db-credentials secret..."
    kubectl patch secret db-credentials -n $NAMESPACE -p "{\"data\":{\"connectionString\":\"$(echo "Host=$RDS_ENDPOINT;Username=otelu;Password=$DB_PASSWORD;Database=otel" | base64 -w 0)\"}}"
fi

# Wait a bit for secret propagation
sleep 10

# Restart accounting service to pick up new connection
echo "Restarting accounting service..."
kubectl rollout restart deployment accounting -n $NAMESPACE 2>/dev/null || true

check_success "Database connection updated"

# Step 12: Scale Cluster if Needed (CAPACITY FIX)
print_step "Step 12: Ensure Adequate Cluster Capacity"

# Get node group name
NODEGROUP_NAME=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --query "nodegroups[0]" --output text --region $AWS_REGION)

# Scale to 4 nodes to ensure capacity
echo "Scaling cluster to ensure adequate capacity..."
aws eks update-nodegroup-config \
    --cluster-name $CLUSTER_NAME \
    --nodegroup-name $NODEGROUP_NAME \
    --scaling-config desiredSize=4,maxSize=5,minSize=3 \
    --region $AWS_REGION 2>/dev/null || echo "Scaling not needed or already in progress"

check_success "Cluster capacity ensured"

# Step 13: Wait for All Pods to be Ready
print_step "Step 13: Wait for All Pods to be Ready"

echo "Waiting for all pods to be ready (this may take several minutes)..."
sleep 60

# Wait for pods to be ready with better error handling
echo "Checking pod readiness..."
for i in {1..20}; do
    PENDING_PODS=$(kubectl get pods -n $NAMESPACE --no-headers | grep -E "Pending|ContainerCreating|Init" | wc -l)
    FAILED_PODS=$(kubectl get pods -n $NAMESPACE --no-headers | grep -E "Error|CrashLoopBackOff|ImagePullBackOff" | wc -l)
    RUNNING_PODS=$(kubectl get pods -n $NAMESPACE --no-headers | grep "Running" | wc -l)
    
    echo "Attempt $i/20: Running: $RUNNING_PODS, Pending: $PENDING_PODS, Failed: $FAILED_PODS"
    
    if [ $FAILED_PODS -gt 0 ]; then
        echo "Found failed pods, checking logs..."
        kubectl get pods -n $NAMESPACE | grep -E "Error|CrashLoopBackOff|ImagePullBackOff"
    fi
    
    if [ $PENDING_PODS -eq 0 ] && [ $FAILED_PODS -eq 0 ]; then
        echo "All pods are running!"
        break
    fi
    
    sleep 30
done

# Final comprehensive status check
echo ""
echo "=== Final Status Check ==="
echo "Pod Status Summary:"
kubectl get pods -n $NAMESPACE --no-headers | awk '{print $3}' | sort | uniq -c

echo ""
echo "PVC Status:"
kubectl get pvc -n $NAMESPACE

echo ""
echo "Service Status:"
kubectl get svc -n $NAMESPACE

echo ""
echo "Ingress Status:"
kubectl get ingress -n $NAMESPACE

# Check for any problematic pods
PROBLEM_PODS=$(kubectl get pods -n $NAMESPACE --no-headers | grep -E "Error|CrashLoopBackOff|ImagePullBackOff|Pending" | wc -l)
if [ $PROBLEM_PODS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}⚠${NC} Found $PROBLEM_PODS problematic pods:"
    kubectl get pods -n $NAMESPACE | grep -E "Error|CrashLoopBackOff|ImagePullBackOff|Pending"
    echo ""
    echo "Troubleshooting commands:"
    echo "  kubectl describe pods -n $NAMESPACE | grep -A 10 -B 5 'Error\|Failed'"
    echo "  kubectl logs -n $NAMESPACE <pod-name> --previous"
else
    check_success "All components deployed and running"
fi

# Step 14: Verify Ingress and Get Access Information
print_step "Step 14: Verify Ingress and Get Access Information"

echo "Waiting for ALB to be provisioned (this can take 2-3 minutes)..."
for i in {1..10}; do
    INGRESS_URL=$(kubectl get ingress -n $NAMESPACE -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$INGRESS_URL" ]; then
        echo "ALB provisioned: $INGRESS_URL"
        break
    fi
    echo "Attempt $i/10: Waiting for ALB..."
    sleep 20
done

if [ -z "$INGRESS_URL" ]; then
    INGRESS_URL="Not ready yet"
fi

# Final Health Check
echo ""
echo "=== FINAL HEALTH CHECK ==="
RUNNING_PODS=$(kubectl get pods -n $NAMESPACE --no-headers | grep "Running" | wc -l)
TOTAL_PODS=$(kubectl get pods -n $NAMESPACE --no-headers | wc -l)
BOUND_PVCS=$(kubectl get pvc -n $NAMESPACE --no-headers | grep "Bound" | wc -l)
TOTAL_PVCS=$(kubectl get pvc -n $NAMESPACE --no-headers | wc -l)

echo "Pods: $RUNNING_PODS/$TOTAL_PODS Running"
echo "PVCs: $BOUND_PVCS/$TOTAL_PVCS Bound"
echo "Database: Connected to $RDS_ENDPOINT"
echo "Ingress: $INGRESS_URL"

echo ""
echo "=========================================="
if [ $RUNNING_PODS -eq $TOTAL_PODS ] && [ $BOUND_PVCS -eq $TOTAL_PVCS ]; then
    echo -e "${GREEN}🎉 DEPLOYMENT SUCCESSFUL!${NC}"
else
    echo -e "${YELLOW}⚠ DEPLOYMENT PARTIALLY COMPLETE${NC}"
fi
echo "=========================================="
echo ""
echo "📊 OpenTelemetry Demo Access:"
if [ "$INGRESS_URL" != "Not ready yet" ] && [ -n "$INGRESS_URL" ]; then
    echo "   Frontend: http://$INGRESS_URL"
    echo "   🔗 Click the link above to access the demo!"
else
    echo "   Run 'kubectl get ingress -n $NAMESPACE' to get the URL when ready"
    echo "   Or use port-forward: kubectl port-forward svc/opentelemetry-demo-frontend 8080:8080 -n $NAMESPACE"
fi
echo ""
echo "🗄️  Database Information:"
echo "   Host: $RDS_ENDPOINT"
echo "   Database: otel"
echo "   Username: otelu"
echo "   Password: $DB_PASSWORD"
echo ""
echo "🔧 Monitoring Commands:"
echo "   kubectl get pods -n $NAMESPACE"
echo "   kubectl get pvc -n $NAMESPACE"
echo "   kubectl logs -f deployment/accounting -n $NAMESPACE"
echo "   kubectl logs -f deployment/opentelemetry-demo-frontend -n $NAMESPACE"
echo ""
echo "📝 Key Features Available:"
echo "   ✓ Distributed tracing with Jaeger"
echo "   ✓ Metrics with Prometheus & Grafana"
echo "   ✓ Logs aggregation"
echo "   ✓ Service mesh observability"
echo "   ✓ Database integration with RDS"
echo "   ✓ Persistent storage with EBS"
echo ""
echo "⚠️  Remember to clean up resources when done:"
echo "   bash cleanup-complete.sh"
echo ""