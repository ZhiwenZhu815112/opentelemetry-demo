#!/bin/bash
# Sync Secrets from AWS Secrets Manager to Kubernetes
# This script creates temporary pods to trigger secret sync for both db-credentials and grafana-admin

set -e

NAMESPACE="otel-demo"

echo "=== Syncing Secrets from AWS Secrets Manager ==="
echo ""

# Function to sync a secret
sync_secret() {
    local SECRET_NAME=$1
    local SECRET_PROVIDER_CLASS=$2
    local SERVICE_ACCOUNT=$3
    
    echo "--- Syncing ${SECRET_NAME} ---"
    
    # Check if secret already exists
    if kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} &>/dev/null; then
        echo "   ✓ Secret '${SECRET_NAME}' already exists!"
        return 0
    fi
    
    # Check if SecretProviderClass exists
    if ! kubectl get secretproviderclass ${SECRET_PROVIDER_CLASS} -n ${NAMESPACE} &>/dev/null; then
        echo "   ✗ ERROR: SecretProviderClass '${SECRET_PROVIDER_CLASS}' not found!"
        echo "   Please apply it first: kubectl apply -f secret-provider-class-*.yaml"
        return 1
    fi
    
    # Check if service account exists
    if ! kubectl get sa ${SERVICE_ACCOUNT} -n ${NAMESPACE} &>/dev/null; then
        echo "   ✗ ERROR: Service account '${SERVICE_ACCOUNT}' not found!"
        echo "   Please apply it first: kubectl apply -f serviceaccounts-secrets.yaml"
        return 1
    fi
    
    # Create temporary pod to trigger secret creation
    POD_NAME="${SECRET_NAME}-sync-init"
    echo "   Creating temporary pod '${POD_NAME}'..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: ${SERVICE_ACCOUNT}
  containers:
  - name: init
    image: busybox:latest
    command: ['sh', '-c', 'echo "Triggering secret sync for ${SECRET_NAME}..." && sleep 10']
    volumeMounts:
    - name: secrets-store
      mountPath: /mnt/secrets-store
      readOnly: true
  volumes:
  - name: secrets-store
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: "${SECRET_PROVIDER_CLASS}"
  restartPolicy: Never
EOF

    # Wait for secret to be created
    echo "   Waiting for secret to sync (15 seconds)..."
    sleep 15
    
    # Check if secret was created
    if kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} &>/dev/null; then
        echo "   ✓ Secret '${SECRET_NAME}' created successfully!"
    else
        echo "   ✗ Secret not created. Checking pod logs..."
        kubectl logs ${POD_NAME} -n ${NAMESPACE} 2>/dev/null || true
        echo ""
        echo "   Troubleshooting:"
        echo "   - Check if AWS Secrets Manager has the required secrets"
        echo "   - Check if service account has IRSA annotation: kubectl get sa ${SERVICE_ACCOUNT} -n ${NAMESPACE} -o yaml | grep role-arn"
        echo "   - Check CSI driver logs: kubectl logs -n kube-system -l app=secrets-store-csi-driver"
        kubectl delete pod ${POD_NAME} -n ${NAMESPACE} --ignore-not-found=true
        return 1
    fi
    
    # Clean up temporary pod
    echo "   Cleaning up temporary pod..."
    kubectl delete pod ${POD_NAME} -n ${NAMESPACE} --ignore-not-found=true
    
    return 0
}

# Sync db-credentials
sync_secret "db-credentials" "db-credentials" "otel-demo-secrets-sa"
echo ""

# Sync grafana-admin
sync_secret "grafana-admin" "grafana-credentials" "grafana-secrets-sa"
echo ""

# Final verification
echo "=== Verification ==="
echo "Checking synced secrets:"
kubectl get secrets -n ${NAMESPACE} | grep -E "db-credentials|grafana-admin" || echo "No secrets found!"

echo ""
echo "=== Done ==="
echo "Secrets have been synced. You can now deploy your applications."


