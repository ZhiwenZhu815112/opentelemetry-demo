#!/bin/bash
# Cleanup script for OpenTelemetry Demo on EKS
# This script deletes resources in the correct order to avoid namespace deletion hanging

set -e

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-otel-demo-cluster}
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_PROFILE=${AWS_PROFILE:-JulianFTA}
NAMESPACE="otel-demo"

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text)

echo "=========================================="
echo "OpenTelemetry Demo Cleanup"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $ACCOUNT_ID"
echo "Namespace: $NAMESPACE"
echo ""

# Function to wait for resource deletion
wait_for_deletion() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local timeout=${4:-120}
    
    echo "Waiting for $resource_type/$resource_name to be deleted (timeout: ${timeout}s)..."
    kubectl wait --for=delete $resource_type/$resource_name -n $namespace --timeout=${timeout}s 2>/dev/null || true
}

echo "=== Step 1: Delete Ingress (outside namespace) ==="
kubectl delete -f final-ingress.yaml --ignore-not-found=true || true
echo ""

echo "=== Step 2: Delete IAM Service Accounts in $NAMESPACE namespace ==="
echo "These must be deleted BEFORE the namespace is deleted"
eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=$NAMESPACE \
  --name=otel-demo-secrets-sa \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE 2>/dev/null || echo "  Service account otel-demo-secrets-sa not found or already deleted"

eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=$NAMESPACE \
  --name=grafana-secrets-sa \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE 2>/dev/null || echo "  Service account grafana-secrets-sa not found or already deleted"
echo ""

echo "=== Step 3: Delete StatefulSets first (they have PVCs that can block namespace deletion) ==="
kubectl delete statefulset prometheus opensearch -n $NAMESPACE --ignore-not-found=true --wait=false
echo "  Waiting for StatefulSets to terminate..."
sleep 10
wait_for_deletion "statefulset" "prometheus" "$NAMESPACE" 120
wait_for_deletion "statefulset" "opensearch" "$NAMESPACE" 120
echo ""

echo "=== Step 4: Delete all resources in the namespace ==="
kubectl delete -f opentelemetry-demo.yaml --ignore-not-found=true || true
echo ""

echo "=== Step 5: Delete SecretProviderClasses (inside namespace) ==="
kubectl delete -f secret-provider-class-db.yaml --ignore-not-found=true || true
kubectl delete -f secret-provider-class-grafana.yaml --ignore-not-found=true || true
echo ""

echo ""

echo "=== Step 7: Wait for all pods to terminate ==="
echo "Waiting for all pods in namespace to terminate..."
timeout=180
elapsed=0
while [ $elapsed -lt $timeout ]; do
    pod_count=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pod_count" -eq 0 ]; then
        echo "  All pods terminated"
        break
    fi
    echo "  Waiting... ($elapsed/${timeout}s) - $pod_count pods remaining"
    sleep 5
    elapsed=$((elapsed + 5))
done
echo ""

echo "=== Step 8: Force delete any stuck pods ==="
# Sometimes pods get stuck in Terminating state
stuck_pods=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | grep Terminating | awk '{print $1}' || true)
if [ -n "$stuck_pods" ]; then
    echo "  Found stuck pods, force deleting..."
    echo "$stuck_pods" | while read pod; do
        kubectl delete pod $pod -n $NAMESPACE --force --grace-period=0 2>/dev/null || true
    done
    sleep 5
else
    echo "  No stuck pods found"
fi
echo ""

echo "=== Step 9: Delete PVCs (if they weren't automatically deleted) ==="
# PVCs with Delete policy should be deleted automatically, but Retain policy keeps them
pvc_count=$(kubectl get pvc -n $NAMESPACE --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$pvc_count" -gt 0 ]; then
    echo "  Deleting $pvc_count PVCs..."
    kubectl delete pvc -n $NAMESPACE --all --ignore-not-found=true
    sleep 5
else
    echo "  No PVCs to delete"
fi
echo ""

echo "=== Step 10: Delete the namespace ==="
if kubectl get namespace $NAMESPACE &>/dev/null; then
    echo "  Deleting namespace $NAMESPACE..."
    kubectl delete ns $NAMESPACE --wait=true --timeout=300s || {
        echo "  WARNING: Namespace deletion timed out or failed"
        echo "  Checking for blocking resources..."
        kubectl get all,pvc,secret,configmap -n $NAMESPACE 2>/dev/null || true
        echo ""
        echo "  If namespace is stuck, you can try force deletion:"
        echo "  kubectl get namespace $NAMESPACE -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/$NAMESPACE/finalize -f -"
    }
else
    echo "  Namespace $NAMESPACE does not exist"
fi
echo ""

echo "=== Step 11: Delete StorageClasses (cluster-scoped) ==="
kubectl delete -f storageclasses.yaml --ignore-not-found=true || true
echo "  Note: If PVCs used Retain policy, PersistentVolumes may still exist"
echo "  Check with: kubectl get pv | grep $NAMESPACE"
echo ""

echo "=== Step 12: Uninstall Helm charts (cluster-scoped) ==="
helm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found=true || true
helm uninstall cluster-autoscaler -n kube-system --ignore-not-found=true || true
echo ""

echo "=== Step 13: Delete IAM Service Accounts in kube-system namespace ==="
eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE 2>/dev/null || echo "  Service account aws-load-balancer-controller not found or already deleted"

eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --region=$AWS_REGION \
  --profile=$AWS_PROFILE 2>/dev/null || echo "  Service account cluster-autoscaler not found or already deleted"
echo ""

echo "=== Step 14: Delete IAM Policies ==="
echo "Deleting IAM policies..."
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy --profile $AWS_PROFILE 2>/dev/null || echo "  Policy AWSLoadBalancerControllerIAMPolicy not found or already deleted"
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy --profile $AWS_PROFILE 2>/dev/null || echo "  Policy AmazonEKSClusterAutoscalerPolicy not found or already deleted"
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/OtelDemoSecretsManagerPolicy --profile $AWS_PROFILE 2>/dev/null || echo "  Policy OtelDemoSecretsManagerPolicy not found or already deleted"
echo ""

echo "=========================================="
echo "Cleanup Complete!"
echo "=========================================="
echo ""
echo "Remaining steps (if needed):"
echo "1. Delete PersistentVolumes manually if they used Retain policy:"
echo "   kubectl get pv | grep $NAMESPACE"
echo "   kubectl delete pv <pv-name>"
echo ""
echo "2. Delete AWS Secrets Manager secrets (if desired):"
echo "   aws secretsmanager list-secrets --filters Key=name,Values=otel-demo --query 'SecretList[].Name' --output table"
echo ""
echo "3. Delete CloudFormation stack (includes RDS - WARNING: deletes all data!):"
echo "   aws cloudformation delete-stack --stack-name ${CLUSTER_NAME}-stack --region $AWS_REGION --profile $AWS_PROFILE"
echo ""

