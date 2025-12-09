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
#
# ============================================

## AWS account info: ## Set environment variables in terminal

export CLUSTER_NAME=otel-demo-cluster
export AWS_REGION=us-east-1
export AWS_PROFILE=JulianFTA
export ACCOUNT_ID=$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text)

# Set RDS database password (minimum 8 characters)
export DB_PASSWORD="YourSecurePassword123!"  # ⚠️ CHANGE THIS to a secure password!

echo "Cluster: $CLUSTER_NAME | Region: $AWS_REGION | Account: $ACCOUNT_ID | Profile: $AWS_PROFILE"

### Instructions to deploy EKS cluster with CloudFormation (includes RDS) ###

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

##Wait for the Stack state to become CREATE_COMPLETE (takes 15-20 minutes for RDS)

# Check stack status
aws cloudformation describe-stacks \
  --stack-name ${CLUSTER_NAME}-stack \
  --query "Stacks[0].StackStatus" \
  --output text \
  --region $AWS_REGION \
  --profile $AWS_PROFILE

# Wait until status is CREATE_COMPLETE before proceeding

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION --profile $AWS_PROFILE

kubectl get nodes

# Governance & Role-Based Access Control (RBAC)

kubectl apply -f governance.yaml

kubectl get ns --show-labels

kubectl get role,rolebinding -n dev

#Configuring IAM Permissions and Controllers
#Here we will install the Load Balancer Controller and Cluster Autoscaler.


# get VPC ID
export VPC_ID=$(aws eks describe-cluster \
    --name $CLUSTER_NAME \
    --region $AWS_REGION \
    --profile $AWS_PROFILE \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)

#Install the AWS Load Balancer Controller

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

#create the IAM policy for the Cluster Autoscaler

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

#Create the policy in IAM
aws iam create-policy --policy-name AmazonEKSClusterAutoscalerPolicy --policy-document file://cluster-autoscaler-policy.json --profile $AWS_PROFILE || true

#Create a service account for the Cluster Autoscaler (IRSA)
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

#Install the Cluster Autoscaler using Helm
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=$CLUSTER_NAME \
  --set awsRegion=$AWS_REGION \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler


# ============================================
# RDS DATABASE SETUP
# ============================================

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


#Deploy Applications (Namespaces & Apps)

#Create Namespace
kubectl create namespace otel-demo

# Verify namespace was created
kubectl get namespace otel-demo

# IMPORTANT: Update the ExternalName service with RDS endpoint before deploying
# The service in opentelemetry-demo.yaml should have the actual RDS endpoint
# If it still shows <RDS_ENDPOINT>, update it first:

# Get RDS endpoint (if not already set)
export RDS_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name ${CLUSTER_NAME}-stack \
  --query "Stacks[0].Outputs[?OutputKey=='PostgresEndpoint'].OutputValue" \
  --output text \
  --region $AWS_REGION \
  --profile $AWS_PROFILE)

echo "RDS Endpoint: ${RDS_ENDPOINT}"

# Option 1: Update YAML file before deploying (Linux/Mac)
# sed -i "s/externalName: <RDS_ENDPOINT>/externalName: ${RDS_ENDPOINT}/" opentelemetry-demo.yaml

# Option 1: Update YAML file before deploying (Windows PowerShell)
# (Get-Content opentelemetry-demo.yaml) -replace 'externalName: <RDS_ENDPOINT>', "externalName: ${RDS_ENDPOINT}" | Set-Content opentelemetry-demo.yaml

#Deploy OpenTelemetry Demo (with RDS configuration)
# This creates all microservices, ConfigMaps, Services, and Deployments

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

# Watch pods until they're all Running (press Ctrl+C to stop)
# kubectl get pods -n otel-demo -w

#Waiting for startup
# NOTE: There should be NO postgresql pod - database is now on RDS

kubectl get pods -n otel-demo --watch ##Only proceed to the next step after all Pods are Running.

# Verify no PostgreSQL pod exists (database is on RDS)
kubectl get pods -n otel-demo | grep postgresql
# Should return nothing

# Verify PostgreSQL service is ExternalName type
kubectl get svc postgresql -n otel-demo -o yaml | grep -A 2 "type:"
# Should show: type: ExternalName

# Test database connectivity from a pod
# IMPORTANT: Pod must be in the same namespace as the service (otel-demo)

# Option 1: Test using ExternalName service (requires service to be applied)
kubectl run -it --rm test-db-connection \
  --image=postgres:15 \
  --restart=Never \
  --namespace=otel-demo \
  --env="PGPASSWORD=otelp" \
  -- psql -h postgresql -U otelu -d otel -c "SELECT 1;"

# Option 2: Test using RDS endpoint directly (always works, doesn't need service)
kubectl run -it --rm test-db-connection-direct \
  --image=postgres:15 \
  --restart=Never \
  --namespace=otel-demo \
  --env="PGPASSWORD=${DB_PASSWORD}" \
  -- psql -h ${RDS_ENDPOINT} -U otelu -d otel -c "SELECT 1;"

# Option 3: Test DNS resolution first
kubectl run -it --rm test-dns \
  --image=busybox \
  --restart=Never \
  --namespace=otel-demo \
  -- nslookup postgresql.otel-demo.svc.cluster.local

# Restart services to ensure they connect to RDS
# First, check which deployments exist
kubectl get deployments -n otel-demo

# Restart services that use the database
kubectl rollout restart deployment accounting -n otel-demo
kubectl rollout restart deployment otel-collector -n otel-demo

# Note: If product-reviews deployment exists, restart it too:
# kubectl rollout restart deployment product-reviews -n otel-demo

# Wait for services to restart
kubectl rollout status deployment accounting -n otel-demo
kubectl rollout status deployment otel-collector -n otel-demo

# Check logs for database connection success
# On Linux/Mac:
kubectl logs deployment/accounting -n otel-demo --tail=20 | grep -i "database\|postgres\|connected"
# On Windows PowerShell:
kubectl logs deployment/accounting -n otel-demo --tail=20 | Select-String -Pattern "database|postgres|connected" -CaseSensitive:$false

# If product-reviews exists, check its logs:
# kubectl logs deployment/product-reviews -n otel-demo --tail=20 | grep -i "database\|postgres\|connected"

#deploy the final-ingress.yaml to expose the application via ALB

kubectl apply -f final-ingress.yaml

kubectl get ingress -n otel-demo

# Get ALB URL
kubectl get ingress otel-demo-ingress -n otel-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# ============================================
# TROUBLESHOOTING: Products Not Showing
# ============================================
# If products aren't showing on the webpage, check the following:

# 1. Verify all pods are running
kubectl get pods -n otel-demo

# 2. Check product-catalog service (products come from ConfigMap, not database)
kubectl get pods -n otel-demo -l app.kubernetes.io/name=product-catalog
kubectl logs -n otel-demo -l app.kubernetes.io/name=product-catalog --tail=50

# 3. Check frontend service
kubectl get pods -n otel-demo -l app.kubernetes.io/name=frontend
kubectl logs -n otel-demo -l app.kubernetes.io/name=frontend --tail=50

# 4. Verify ConfigMap exists (products are stored here)
kubectl get configmap product-catalog-products -n otel-demo

# 5. Check if product-catalog service is accessible
kubectl get svc product-catalog -n otel-demo

# 6. Test product-catalog from within cluster
# kubectl run -it --rm test-product-catalog --image=curlimages/curl --restart=Never -n otel-demo -- curl http://product-catalog:8080

# 7. Check postgresql service configuration (for database-dependent services)
kubectl get svc postgresql -n otel-demo
kubectl get svc postgresql -n otel-demo -o jsonpath='{.spec.externalName}{"\n"}'

# 8. Check accounting service logs (uses database)
kubectl logs -n otel-demo -l app.kubernetes.io/name=accounting --tail=50 | Select-String -Pattern "error|database|postgres" -CaseSensitive:$false

# 9. Run the troubleshooting script (Windows PowerShell)
# .\troubleshoot-rds.ps1

# Autoscaler Test - Load Test #### Not required for your guys, just for my own reference

kubectl get nodes

kubectl scale deployment load-generator --replicas=20 -n otel-demo

kubectl get pods -n otel-demo | grep Pending

kubectl get nodes -w

kubectl scale deployment load-generator --replicas=1 -n otel-demo


######## Cleanup ########

# Delete Kubernetes resources
kubectl delete -f final-ingress.yaml

kubectl delete -f opentelemetry-demo.yaml

kubectl delete ns otel-demo

# Uninstall Helm charts
helm uninstall aws-load-balancer-controller -n kube-system

helm uninstall cluster-autoscaler -n kube-system

# Delete IAM service accounts
eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE

eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE

# Delete IAM policies
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy --profile $AWS_PROFILE

aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy --profile $AWS_PROFILE

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


# End of File #

