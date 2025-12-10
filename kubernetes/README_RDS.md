# ============================================
# EKS Deployment Guide with Amazon RDS
# ============================================
# This is the updated deployment guide that includes Amazon RDS PostgreSQL
# instead of running PostgreSQL as a Kubernetes pod.
# 
# Key differences from original README:
# - CloudFormation includes RDS PostgreSQL instance
# - Database is persistent and managed by AWS
# - Kubernetes Service uses ExternalName to point to RDS
# - Additional steps for seeding database schema
# - Persistent storage for stateful workloads (OpenSearch, Prometheus)
# - Secrets managed via AWS Secrets Manager with IRSA
#
# ============================================

## Quick Start: Automated Deployment

# Option 1: Use the automated startup script (Recommended)
# chmod +x startup.sh
# ./startup.sh
#
# The script automates all deployment steps. You can set environment variables to customize:
# export CLUSTER_NAME=otel-demo-cluster
# export AWS_REGION=us-east-1
# export AWS_PROFILE=JulianFTA
# export DB_PASSWORD="YourSecurePassword123!"
# export PG_VERSION="15.14"
# export SKIP_CLUSTER_CREATION=false  # Set to true to skip cluster creation
# export SKIP_RDS_SEEDING=false      # Set to true to skip RDS seeding
#
# Option 2: Follow manual steps below

## Step 1: AWS Account Setup and Environment Variables

export CLUSTER_NAME=otel-demo-cluster
export AWS_REGION=us-east-1
export AWS_PROFILE=JulianFTA
export ACCOUNT_ID=$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text)

# Set RDS database password (minimum 8 characters)
export DB_PASSWORD="YourSecurePassword123!" 

echo "Cluster: $CLUSTER_NAME | Region: $AWS_REGION | Account: $ACCOUNT_ID | Profile: $AWS_PROFILE"

## Step 2: Deploy EKS Cluster with CloudFormation (includes RDS)

# Check available PostgreSQL versions in your region
echo "Checking available PostgreSQL versions..."
aws rds describe-db-engine-versions \
  --engine postgres \
  --query 'DBEngineVersions[?contains(EngineVersion, `15.`)].EngineVersion' \
  --output text \
  --region $AWS_REGION \
  --profile $AWS_PROFILE

# Set PostgreSQL version (use one from the list above)
# Common versions: 15.14, 15.4, 15.3, 15.2, 14.11, 14.10, etc.
export PG_VERSION="15.14"  # ⚠️ Update this to a version available in your region (default: 15.14)

# Alternative: Use the latest available 15.x version automatically
# export PG_VERSION=$(aws rds describe-db-engine-versions \
#   --engine postgres \
#   --query 'DBEngineVersions[?contains(EngineVersion, `15.`)].EngineVersion' \
#   --output text \
#   --region $AWS_REGION \
#   --profile $AWS_PROFILE | tr '\t' '\n' | sort -V | tail -1)

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

# Wait for the Stack state to become CREATE_COMPLETE (takes 15-20 minutes for RDS)

# Check stack status
aws cloudformation describe-stacks \
  --stack-name ${CLUSTER_NAME}-stack \
  --query "Stacks[0].StackStatus" \
  --output text \
  --region $AWS_REGION \
  --profile $AWS_PROFILE

# Wait until status is CREATE_COMPLETE before proceeding

## Step 3: Configure kubectl

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION --profile $AWS_PROFILE

kubectl get nodes

## Step 4: Governance & Role-Based Access Control (RBAC)

kubectl apply -f governance.yaml

kubectl get ns --show-labels

kubectl get role,rolebinding -n dev

## Step 5: Install AWS Load Balancer Controller and Cluster Autoscaler

# Get VPC ID
export VPC_ID=$(aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --region $AWS_REGION \
    --profile $AWS_PROFILE \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)

# Install the AWS Load Balancer Controller

curl -o iam_policy_latest.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy_latest.json --profile $AWS_PROFILE || true

# Create a service account for the AWS Load Balancer Controller (IRSA)

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE

# Install the AWS Load Balancer Controller using Helm

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID

# Install the Cluster Autoscaler

# Create the IAM policy for the Cluster Autoscaler

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

# Create the policy in IAM
aws iam create-policy --policy-name AmazonEKSClusterAutoscalerPolicy --policy-document file://cluster-autoscaler-policy.json --profile $AWS_PROFILE || true

# Create a service account for the Cluster Autoscaler (IRSA)
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --role-name AmazonEKSClusterAutoscalerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE

# Install the Cluster Autoscaler using Helm
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=$CLUSTER_NAME \
  --set awsRegion=$AWS_REGION \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler

## Step 6: Install EBS CSI Driver (Operational Step)

# NOTE: This is a cluster-level operational step, not committed in this repo.
# The EBS CSI Driver must be installed before applying StorageClasses.

helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

#   # Create IAM policy (if not exists)

curl -o ebs-csi-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json


aws iam create-policy \
  --policy-name AmazonEKS_EBS_CSI_Driver_Policy \
  --policy-document file://ebs-csi-policy.json \
  --profile $AWS_PROFILE || echo "Policy exists"

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
  --profile=$AWS_PROFILE

# Install driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  -n kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa

# Verify EBS CSI Driver is installed:
kubectl get pods -n kube-system | grep ebs-csi

## Step 7: Apply StorageClasses

# Apply StorageClasses for persistent storage
# NOTE: We use EBS CSI for all stateful workloads because they only require ReadWriteOnce access.

kubectl apply -f storageclasses.yaml

# Verify StorageClasses
kubectl get storageclass

# Expected output should show:
# - gp3-ssd (default, Delete policy)
# - gp3-ssd-retain (Retain policy)
# - io1-ssd-retain (High IOPS, Retain policy)

## Step 8: Install Secrets Manager CSI Driver
# The Secrets Manager CSI Driver must be installed before deploying applications.

# Install Secrets Store CSI Driver:
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update

helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
--namespace kube-system \
--set syncSecret.enabled=true \
--set enableSecretRotation=true

#   # Install AWS Provider
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml

# Verify CSI Driver is installed:
kubectl get pods -n kube-system | grep csi-secrets

## Step 9: Setup Secrets Manager Integration

# Create IAM Policy for Secrets Manager Access
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

# Create IAM policy
aws iam create-policy \
  --policy-name OtelDemoSecretsManagerPolicy \
  --policy-document file://secrets-manager-policy.json \
  --profile $AWS_PROFILE || echo "Policy may already exist"

# Create IRSA Service Accounts for Secrets Manager
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=otel-demo \
  --name=otel-demo-secrets-sa \
  --role-name OtelDemoSecretsManagerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoSecretsManagerPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=otel-demo \
  --name=grafana-secrets-sa \
  --role-name GrafanaSecretsManagerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoSecretsManagerPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE

# Verify service accounts exist and have correct IRSA annotations
kubectl get sa otel-demo-secrets-sa grafana-secrets-sa -n otel-demo

# Check that annotations have actual account ID (not <ACCOUNT_ID> placeholder)
kubectl get sa otel-demo-secrets-sa -n otel-demo -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
# If you see <ACCOUNT_ID> in the output, run the fix script:
# PowerShell: .\fix-serviceaccount-annotations.sh

# Create Secrets in AWS Secrets Manager
# Make script executable (Linux/Mac)
dos2unix create-secrets.sh
chmod +x create-secrets.sh

# Run the script to create secrets
./create-secrets.sh

# Apply SecretProviderClasses
kubectl apply -f secret-provider-class-db.yaml
kubectl apply -f secret-provider-class-grafana.yaml

# IMPORTANT: Sync secrets from AWS Secrets Manager to Kubernetes
# The AWS Secrets Store CSI driver only creates synced secrets when a pod mounts the SecretProviderClass.
# This step creates temporary pods to trigger the secret sync.

# Option 1: Use the sync script (Linux/Mac/WSL/Git Bash)
# Make script executable
chmod +x sync-secrets.sh
# Run the script
./sync-secrets.sh

# Verify SecretProviderClasses and synced secrets
kubectl get secretproviderclass -n otel-demo
kubectl get secrets -n otel-demo | grep -E "db-credentials|grafana-admin"


## Step 10: RDS Database Setup

# Get RDS endpoint from CloudFormation outputs
export RDS_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name ${CLUSTER_NAME}-stack \
  --query "Stacks[0].Outputs[?OutputKey=='PostgresEndpoint'].OutputValue" \
  --output text \
  --region $AWS_REGION \
  --profile $AWS_PROFILE)

export RDS_PORT=$(aws cloudformation describe-stacks \
  --stack-name ${CLUSTER_NAME}-stack \
  --query "Stacks[0].Outputs[?OutputKey=='PostgresPort'].OutputValue" \
  --output text \
  --region $AWS_REGION \
  --profile $AWS_PROFILE)

echo "RDS Endpoint: ${RDS_ENDPOINT}:${RDS_PORT}"

# Verify RDS is available
aws rds describe-db-instances \
  --query "DBInstances[?contains(Endpoint.Address, '${RDS_ENDPOINT}')].DBInstanceStatus" \
  --output text \
  --region $AWS_REGION \
  --profile $AWS_PROFILE

# Should output: available

# Update Kubernetes Service with RDS endpoint
# Replace <RDS_ENDPOINT> placeholder in opentelemetry-demo.yaml

# On Linux/Mac:
sed -i "s/externalName: <RDS_ENDPOINT>/externalName: ${RDS_ENDPOINT}/" opentelemetry-demo.yaml

# On Windows (PowerShell) - run this instead:
# (Get-Content opentelemetry-demo.yaml) -replace 'externalName: <RDS_ENDPOINT>', "externalName: ${RDS_ENDPOINT}" | Set-Content opentelemetry-demo.yaml

# Verify the replacement worked (Linux/Mac)
grep "externalName:" opentelemetry-demo.yaml | grep -v "<RDS_ENDPOINT>"

# On Windows (PowerShell) - verify with:
# Select-String -Path opentelemetry-demo.yaml -Pattern "externalName:" | Where-Object { $_.Line -notmatch "<RDS_ENDPOINT>" }

# Seed RDS database with schema and initial data
# NOTE: RDS is in a private subnet, so you CANNOT connect from your local machine.
# You MUST connect from within the VPC (from an EKS pod).

# ============================================
# OPTION 1: Use the provided script (Easiest)
# ============================================

# Make script executable (Linux/Mac)
chmod +x seed-rds-from-pod.sh

# Run the script
./seed-rds-from-pod.sh

## Step 11: Deploy Applications

# Verify namespace was created
kubectl get namespace otel-demo

# IMPORTANT: Update the ExternalName service with RDS endpoint before deploying
# The service in opentelemetry-demo.yaml should have the actual RDS endpoint
# If it still shows <RDS_ENDPOINT>, update it first:

# Deploy OpenTelemetry Demo (with RDS configuration)
# This creates all microservices, ConfigMaps, Services, Deployments, and StatefulSets
# StatefulSets (OpenSearch, Prometheus) will automatically create PVCs using the StorageClasses

kubectl apply -n otel-demo -f opentelemetry-demo.yaml

# Wait a few seconds for resources to be created
sleep 5

# Verify the postgresql service is configured correctly
kubectl get svc postgresql -n otel-demo -o yaml | grep -A 2 "externalName:"

# If externalName still shows <RDS_ENDPOINT>, update it:
kubectl patch svc postgresql -n otel-demo -p "{\"spec\":{\"externalName\":\"${RDS_ENDPOINT}\"}}"

# Verify deployment
kubectl get all -n otel-demo

# Check pod status (should see pods starting)
kubectl get pods -n otel-demo

# Verify PVCs are being created for StatefulSets
kubectl get pvc -n otel-demo

# Watch pods until they're all Running (press Ctrl+C to stop)
# kubectl get pods -n otel-demo -w

# Waiting for startup
# NOTE: There should be NO postgresql pod - database is now on RDS

kubectl get pods -n otel-demo --watch ##Only proceed to the next step after all Pods are Running.

# Verify no PostgreSQL pod exists (database is on RDS)
kubectl get pods -n otel-demo | grep postgresql
# Should return nothing

# Verify PostgreSQL service is ExternalName type
kubectl get svc postgresql -n otel-demo -o yaml | grep -A 2 "type:"
# Should show: type: ExternalName

# Verify PVCs are Bound
kubectl get pvc -n otel-demo
# Should show:
# - data-opensearch-0 (Bound, 20Gi, io1-ssd-retain)
# - storage-volume-prometheus-0 (Bound, 10Gi, gp3-ssd-retain)

# Test database connectivity from a pod
# IMPORTANT: Pod must be in the same namespace as the service (otel-demo)
# NOTE: All database credentials come from AWS Secrets Manager via CSI driver
# The synced K8s Secret 'db-credentials' contains the connection string and password

# Option 1: Test using ExternalName service with credentials from Secrets Manager
# This demonstrates that secrets are NOT hardcoded - they come from the synced secret
# Delete existing pod if it exists
kubectl delete pod test-db-connection -n otel-demo --ignore-not-found=true


kubectl run -it --rm test-db-connection   --image=postgres:15   --restart=Never   --namespace=otel-demo   --env="PGPASSWORD=$(kubectl get secret db-credentials -n otel-demo -o jsonpath='{.data.password}' | base64 -d)"   -- psql -h postgresql -U $(kubectl get secret db-credentials -n otel-demo -o jsonpath='{.data.username}' | base64 -d) -d otel -c "SELECT COUNT(*) FROM reviews.productreviews;"

# Option 2: Test using RDS endpoint directly with master password (for admin/testing only)
# Note: In production, applications use the app credentials from Secrets Manager, not the master password
kubectl run -it --rm test-db-connection-direct \
  --image=postgres:15 \
  --restart=Never \
  --namespace=otel-demo \
  --env="PGPASSWORD=${DB_PASSWORD}" \
  -- psql -h ${RDS_ENDPOINT} -U otelu -d otel -c "SELECT 1;"

# Restart services to ensure they connect to RDS
# First, check which deployments exist
kubectl get deployments -n otel-demo

# Restart services that use the database
kubectl rollout restart deployment accounting -n otel-demo
kubectl rollout restart deployment otel-collector -n otel-demo

# Wait for services to restart
kubectl rollout status deployment accounting -n otel-demo
kubectl rollout status deployment otel-collector -n otel-demo

# Check logs for database connection success
# On Linux/Mac:
kubectl logs deployment/accounting -n otel-demo --tail=20 | grep -i "database\|postgres\|connected"
# On Windows PowerShell:
kubectl logs deployment/accounting -n otel-demo --tail=20 | Select-String -Pattern "database|postgres|connected" -CaseSensitive:$false


## Step 12: Deploy Ingress (ALB)

# Deploy the final-ingress.yaml to expose the application via ALB

kubectl apply -f final-ingress.yaml

kubectl get ingress -n otel-demo

# Get ALB URL
kubectl get ingress otel-demo-ingress -n otel-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

## Step 16: Verification and Testing

# Verify all components are working:

# 1. Check all pods are running
kubectl get pods -n otel-demo

# 2. Verify PVCs are Bound
kubectl get pvc -n otel-demo
kubectl get pv

# Expected output should show:
# - data-opensearch-0 (Bound, 20Gi, io1-ssd-retain)
# - storage-volume-prometheus-0 (Bound, 10Gi, gp3-ssd-retain)

# 3. Verify StorageClasses
kubectl get storageclass
# Should show: gp3-ssd (default), gp3-ssd-retain, io1-ssd-retain

# 4. Verify secrets from Secrets Manager
kubectl get secretproviderclass -n otel-demo
kubectl get secrets -n otel-demo | grep -E "db-credentials|grafana-admin"

# 5. Verify service accounts have IRSA annotations
kubectl get sa otel-demo-secrets-sa -n otel-demo -o yaml | grep eks.amazonaws.com/role-arn
kubectl get sa grafana-secrets-sa -n otel-demo -o yaml | grep eks.amazonaws.com/role-arn

# 6. Verify StatefulSets have PVCs
kubectl describe statefulset opensearch -n otel-demo | grep -A 5 "Volume Claims"
kubectl describe statefulset prometheus -n otel-demo | grep -A 5 "Volume Claims"

# 7. Test application connectivity
kubectl logs -n otel-demo deployment/accounting --tail=50 | grep -i "database\|connected"

# 8. Verify no secrets are hardcoded in Git
# Application manifests do not contain hard-coded secrets; all sensitive values are sourced
# from AWS Secrets Manager via CSI + IRSA. The following confirms secrets come from Secrets Manager:
kubectl get secret db-credentials -n otel-demo -o jsonpath='{.metadata.annotations}' | grep -i secrets-store
kubectl get secret grafana-admin -n otel-demo -o jsonpath='{.metadata.annotations}' | grep -i secrets-store

## Step 14: Test Stateful Workload Data Persistence

# This test verifies that stateful workloads retain data across pod restarts
# Capture screenshots/logs of these commands as evidence

# Test OpenSearch data persistence
echo "=== Testing OpenSearch Data Persistence ==="

# 1. Create a test file in OpenSearch data directory
kubectl exec -it opensearch-0 -n otel-demo -- bash -c 'echo "persistence-test-$(date +%s)" > /usr/share/opensearch/data/persistence-check.txt && cat /usr/share/opensearch/data/persistence-check.txt'

# 2. Record the content for verification
export OPENSEARCH_TEST_CONTENT=$(kubectl exec opensearch-0 -n otel-demo -- cat /usr/share/opensearch/data/persistence-check.txt 2>/dev/null)
echo "Test content written: ${OPENSEARCH_TEST_CONTENT}"

# 3. Delete the pod to simulate a restart
kubectl delete pod opensearch-0 -n otel-demo

# 4. Wait for the pod to be recreated and Running
kubectl wait --for=condition=ready pod/opensearch-0 -n otel-demo --timeout=300s

# 5. Verify the test file still exists with the same content
kubectl exec opensearch-0 -n otel-demo -- cat /usr/share/opensearch/data/persistence-check.txt
echo "Expected: ${OPENSEARCH_TEST_CONTENT}"
echo "If the content matches, data persistence is working correctly!"

# Test Prometheus data persistence
echo "=== Testing Prometheus Data Persistence ==="

# 1. Check Prometheus data directory
kubectl exec prometheus-0 -n otel-demo -- ls -la /data

# 2. Create a test marker file
kubectl exec prometheus-0 -n otel-demo -- bash -c 'echo "prometheus-persistence-test-$(date +%s)" > /data/persistence-check.txt && cat /data/persistence-check.txt'

# 3. Record the content
export PROMETHEUS_TEST_CONTENT=$(kubectl exec prometheus-0 -n otel-demo -- cat /data/persistence-check.txt 2>/dev/null)
echo "Prometheus test content written: ${PROMETHEUS_TEST_CONTENT}"

# 4. Delete the pod
kubectl delete pod prometheus-0 -n otel-demo

# 5. Wait for pod to be ready
kubectl wait --for=condition=ready pod/prometheus-0 -n otel-demo --timeout=300s

# 6. Verify data persists
kubectl exec prometheus-0 -n otel-demo -- cat /data/persistence-check.txt
echo "Expected: ${PROMETHEUS_TEST_CONTENT}"
echo "If the content matches, Prometheus data persistence is working correctly!"

# Note: Capture screenshots/logs of these commands as evidence for submission

# Autoscaler Test - Load Test #### Not required for your guys, just for my own reference

kubectl get nodes

kubectl scale deployment load-generator --replicas=20 -n otel-demo

kubectl get pods -n otel-demo | grep Pending

kubectl get nodes -w

kubectl scale deployment load-generator --replicas=1 -n otel-demo

## Cleanup

# IMPORTANT: Delete resources in the correct order to avoid namespace deletion hanging
# The namespace deletion can hang if resources are not deleted in the proper sequence.
# StatefulSets with PVCs, finalizers, and IAM service accounts can block namespace deletion.

# Option 1: Use the automated cleanup script (Recommended)
# chmod +x cleanup.sh
# ./cleanup.sh

# Option 2: Manual cleanup (follow steps below)
# Resources inside the namespace must be deleted BEFORE deleting the namespace
# StatefulSets with PVCs can block namespace deletion if not handled properly

echo "=== Step 1: Delete Ingress (outside namespace) ==="
kubectl delete -f final-ingress.yaml --ignore-not-found=true

echo "=== Step 2: Delete IAM Service Accounts in otel-demo namespace (must be done before namespace deletion) ==="
eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=otel-demo \
  --name=otel-demo-secrets-sa \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE || true

eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=otel-demo \
  --name=grafana-secrets-sa \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE || true

echo "=== Step 3: Delete StatefulSets first (they have PVCs that can block namespace deletion) ==="
# Delete StatefulSets explicitly to release PVCs
kubectl delete statefulset prometheus opensearch -n otel-demo --ignore-not-found=true --wait=false

echo "=== Step 4: Delete all resources in the namespace ==="
kubectl delete -f opentelemetry-demo.yaml --ignore-not-found=true

echo "=== Step 5: Delete SecretProviderClasses (inside namespace) ==="
kubectl delete -f secret-provider-class-db.yaml --ignore-not-found=true
kubectl delete -f secret-provider-class-grafana.yaml --ignore-not-found=true

echo "=== Step 6: Wait for StatefulSet pods to terminate and PVCs to be released ==="

echo "Waiting for StatefulSets to terminate (this may take a minute)..."
kubectl wait --for=delete statefulset/prometheus -n otel-demo --timeout=120s || true
kubectl wait --for=delete statefulset/opensearch -n otel-demo --timeout=120s || true

echo "=== Step 7: Delete PVCs (if they weren't automatically deleted) ==="
# PVCs with Delete policy should be deleted automatically, but Retain policy keeps them
kubectl delete pvc -n otel-demo --all --ignore-not-found=true

echo "=== Step 8: Force delete any remaining pods that might be stuck ==="
# Sometimes pods get stuck in Terminating state
kubectl get pods -n otel-demo | grep Terminating | awk '{print $1}' | xargs -r kubectl delete pod -n otel-demo --force --grace-period=0 || true

echo "=== Step 9: Delete the namespace ==="
kubectl delete ns otel-demo --wait=true --timeout=300s

# If namespace is stuck, you can force delete it (use with caution):
# kubectl get namespace otel-demo -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/otel-demo/finalize -f -

echo "=== Step 10: Delete StorageClasses (cluster-scoped, safe to delete after namespace) ==="
kubectl delete -f storageclasses.yaml --ignore-not-found=true
# Note: PVCs with Retain policy will keep volumes - manually delete PVs if needed
# kubectl get pv | grep otel-demo
# kubectl delete pv <pv-name>

echo "=== Step 11: Uninstall Helm charts (cluster-scoped) ==="
helm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found=true
helm uninstall cluster-autoscaler -n kube-system --ignore-not-found=true

echo "=== Step 12: Delete IAM Service Accounts in kube-system namespace ==="
eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE || true

eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE || true

echo "=== Step 13: Delete IAM Policies ==="
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy --profile $AWS_PROFILE || true

aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy --profile $AWS_PROFILE || true

aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoSecretsManagerPolicy --profile $AWS_PROFILE || true

# ⚠️ WARNING: This will delete the RDS instance and all data!
# If you want to keep RDS, manually delete it from AWS Console or remove it from CloudFormation template first

# Delete CloudFormation stack (includes RDS)
aws cloudformation delete-stack --stack-name ${CLUSTER_NAME}-stack --region $AWS_REGION --profile $AWS_PROFILE

# To delete RDS separately (if you want to keep other resources):
# export RDS_INSTANCE_ID=$(aws cloudformation describe-stack-resources \
#   --stack-name ${CLUSTER_NAME}-stack \
#   --logical-resource-id PostgresDB \
#   --query 'StackResources[0].PhysicalResourceId' \
#   --output text \
#   --profile $AWS_PROFILE)
# aws rds delete-db-instance \
#   --db-instance-identifier ${RDS_INSTANCE_ID} \
#   --skip-final-snapshot \
#   --region $AWS_REGION \
#   --profile $AWS_PROFILE


# ============================================
# PROJECT REQUIREMENTS COMPLIANCE SUMMARY
# ============================================
#
# This deployment guide fully implements the following project requirements:
#
# ✅ Persistent Storage (EBS + StorageClasses + StatefulSets)
#    - EBS CSI driver installed (operational step)
#    - Three StorageClasses defined: gp3-ssd, gp3-ssd-retain, io1-ssd-retain
#    - OpenSearch StatefulSet uses 20Gi PVC with io1-ssd-retain
#    - Prometheus StatefulSet uses 10Gi PVC with gp3-ssd-retain
#    - Data persistence verified across pod restarts (Step 14)
#    - Evidence: kubectl get pvc,pv outputs showing Bound state
#
# ✅ RDS + Secrets via AWS Secrets Manager + IRSA
#    - RDS PostgreSQL created via CloudFormation
#    - Database accessed via ExternalName service
#    - All secrets stored in AWS Secrets Manager (not in Git)
#    - IRSA service accounts for secure secret access
#    - SecretProviderClasses sync secrets to K8s Secrets
#    - Applications use synced secrets (no hardcoded credentials)
#    - Evidence: kubectl get secrets showing db-credentials and grafana-admin from Secrets Manager
#
#
# ✅ No Secrets in Git
#    - Application manifests do not contain hard-coded secrets
#    - All sensitive values sourced from AWS Secrets Manager via CSI + IRSA
#    - Test commands use secrets from synced K8s Secrets, not hardcoded passwords
#    - Evidence: kubectl get secret annotations showing secrets-store.csi.k8s.io/managed: "true"
#
# ============================================
# EVIDENCE COLLECTION FOR SUBMISSION
# ============================================
#
# Capture the following as evidence (screenshots/logs):
#
# 1. Storage Verification:
#    kubectl get storageclass
#    kubectl get pvc,pv -n otel-demo
#    # Should show: data-opensearch-0 (Bound, io1-ssd-retain), storage-volume-prometheus-0 (Bound, gp3-ssd-retain)
#
# 2. Secrets Verification:
#    kubectl get secretproviderclass -n otel-demo
#    kubectl get secrets -n otel-demo | grep -E "db-credentials|grafana-admin"
#    kubectl get sa otel-demo-secrets-sa -n otel-demo -o yaml | grep eks.amazonaws.com/role-arn
#    kubectl get secret db-credentials -n otel-demo -o jsonpath='{.metadata.annotations}' | grep secrets-store
#
# 3. Stateful Persistence Test (Step 14):
#    # Before pod restart
#    kubectl exec opensearch-0 -n otel-demo -- cat /usr/share/opensearch/data/persistence-check.txt
#    # After pod restart
#    kubectl exec opensearch-0 -n otel-demo -- cat /usr/share/opensearch/data/persistence-check.txt
#    # (Content should match - proves data persistence)
#
# 5. Application Connectivity:
#    kubectl logs -n otel-demo deployment/accounting --tail=20 | grep -i "database\|connected"
#
# 6. No Secrets in Git Verification:
#    # Verify secrets come from Secrets Manager
#    kubectl get secret db-credentials -n otel-demo -o jsonpath='{.metadata.annotations}'
#    # Should show secrets-store.csi.k8s.io/managed: "true"
#    # Verify no hardcoded passwords in manifests
#    grep -r "password\|Password\|PASSWORD" opentelemetry-demo.yaml | grep -v "secretKeyRef\|valueFrom" || echo "No hardcoded passwords found"
#
# Note: All commands in Steps 13 and 14 should be captured as evidence for submission.

# End of File #
 