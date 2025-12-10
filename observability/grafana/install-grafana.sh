#!/bin/bash
# Install Grafana using Helm
# This script installs Grafana with Prometheus and CloudWatch datasources,
# and auto-imports dashboards for OpenTelemetry Demo

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="observability"
RELEASE_NAME="observability-grafana"
CHART_NAME="grafana"
REPO_NAME="grafana"
REPO_URL="https://grafana.github.io/helm-charts"
VALUES_FILE="values-grafana.yaml"
SECRET_NAME="grafana-admin-credentials"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installing Grafana${NC}"
echo -e "${GREEN}========================================${NC}"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed or not in PATH${NC}"
    exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo -e "${RED}Error: helm is not installed or not in PATH${NC}"
    exit 1
fi

# Check if we can connect to cluster
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
    echo -e "${YELLOW}Please ensure kubectl is configured correctly${NC}"
    exit 1
fi

# Create namespace if it doesn't exist
echo -e "${YELLOW}Creating namespace ${NAMESPACE}...${NC}"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Create admin credentials secret if it doesn't exist
echo -e "${YELLOW}Creating Grafana admin credentials secret...${NC}"
if ! kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} &> /dev/null; then
    # Generate random password
    ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    ADMIN_USER="admin"
    
    kubectl create secret generic ${SECRET_NAME} \
        --from-literal=admin-user=${ADMIN_USER} \
        --from-literal=admin-password=${ADMIN_PASSWORD} \
        -n ${NAMESPACE}
    
    echo -e "${GREEN}Admin credentials created:${NC}"
    echo -e "${YELLOW}  Username: ${ADMIN_USER}${NC}"
    echo -e "${YELLOW}  Password: ${ADMIN_PASSWORD}${NC}"
    echo -e "${YELLOW}  (Save this password - it won't be shown again!)${NC}"
    echo ""
else
    echo -e "${YELLOW}Secret ${SECRET_NAME} already exists, using existing credentials${NC}"
fi

# Create ConfigMap for dashboards
echo -e "${YELLOW}Creating dashboard ConfigMap...${NC}"
kubectl create configmap grafana-dashboards \
    --from-file=dashboards/latency.json \
    --from-file=dashboards/error-rate.json \
    --from-file=dashboards/resource-util.json \
    -n ${NAMESPACE} \
    --dry-run=client -o yaml | kubectl apply -f -

# Add Grafana Helm repository
echo -e "${YELLOW}Adding Grafana Helm repository...${NC}"
helm repo add ${REPO_NAME} ${REPO_URL}
helm repo update

# Check if release already exists
if helm list -n ${NAMESPACE} | grep -q ${RELEASE_NAME}; then
    echo -e "${YELLOW}Release ${RELEASE_NAME} already exists. Upgrading...${NC}"
    UPGRADE=true
else
    echo -e "${YELLOW}Installing new release ${RELEASE_NAME}...${NC}"
    UPGRADE=false
fi

# Install or upgrade Grafana
if [ "$UPGRADE" = true ]; then
    helm upgrade ${RELEASE_NAME} ${REPO_NAME}/${CHART_NAME} \
        --namespace ${NAMESPACE} \
        --values ${VALUES_FILE} \
        --wait \
        --timeout 10m
else
    helm install ${RELEASE_NAME} ${REPO_NAME}/${CHART_NAME} \
        --namespace ${NAMESPACE} \
        --values ${VALUES_FILE} \
        --wait \
        --timeout 10m \
        --create-namespace
fi

# Wait for Grafana to be ready
echo -e "${YELLOW}Waiting for Grafana to be ready...${NC}"
kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/name=grafana \
    -n ${NAMESPACE} \
    --timeout=5m

# Get Grafana service URL
GRAFANA_SERVICE=$(kubectl get svc -n ${NAMESPACE} -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
GRAFANA_PORT=$(kubectl get svc -n ${NAMESPACE} -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.ports[0].port}' 2>/dev/null || echo "80")

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Grafana Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Access Grafana UI:${NC}"
echo "  kubectl port-forward -n ${NAMESPACE} svc/${GRAFANA_SERVICE} 3000:${GRAFANA_PORT}"
echo "  Then open: http://localhost:3000"
echo ""
echo -e "${YELLOW}Admin Credentials:${NC}"
if [ -n "${ADMIN_PASSWORD}" ]; then
    echo "  Username: ${ADMIN_USER}"
    echo "  Password: ${ADMIN_PASSWORD}"
else
    echo "  Username: admin"
    echo "  Password: (retrieve from secret: kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.admin-password}' | base64 -d)"
fi
echo ""
echo -e "${YELLOW}Check Grafana status:${NC}"
echo "  kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=grafana"
echo ""
echo -e "${YELLOW}View dashboards:${NC}"
echo "  Open Grafana UI and navigate to Dashboards > OpenTelemetry Demo"
echo ""

# Verify installation
echo -e "${YELLOW}Verifying installation...${NC}"
GRAFANA_READY=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotReady")

if [ "$GRAFANA_READY" = "Running" ]; then
    echo -e "${GREEN}✓ Grafana is running${NC}"
else
    echo -e "${RED}✗ Grafana is not ready (Status: ${GRAFANA_READY})${NC}"
fi

# Check if LoadBalancer is provisioned
if kubectl get svc -n ${NAMESPACE} -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.type}' 2>/dev/null | grep -q "LoadBalancer"; then
    EXTERNAL_IP=$(kubectl get svc -n ${NAMESPACE} -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")
    if [ "$EXTERNAL_IP" != "pending" ] && [ -n "$EXTERNAL_IP" ]; then
        echo -e "${GREEN}✓ LoadBalancer provisioned: ${EXTERNAL_IP}${NC}"
    else
        echo -e "${YELLOW}⏳ LoadBalancer is provisioning (this may take a few minutes)${NC}"
    fi
fi

echo ""
echo -e "${GREEN}Installation script completed!${NC}"



