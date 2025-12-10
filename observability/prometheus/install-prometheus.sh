#!/bin/bash
# Install Prometheus Stack using Helm
# This script installs kube-prometheus-stack with custom configuration for OpenTelemetry Demo

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="observability"
RELEASE_NAME="observability-prometheus"
CHART_NAME="kube-prometheus-stack"
REPO_NAME="prometheus-community"
REPO_URL="https://prometheus-community.github.io/helm-charts"
VALUES_FILE="values-prometheus.yaml"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installing Prometheus Stack${NC}"
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

# Add Prometheus Helm repository
echo -e "${YELLOW}Adding Prometheus Helm repository...${NC}"
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

# Install or upgrade Prometheus
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

# Apply alert rules
echo -e "${YELLOW}Applying Prometheus alert rules...${NC}"
kubectl apply -f alert-rules.yaml

# Wait for Prometheus to be ready
echo -e "${YELLOW}Waiting for Prometheus to be ready...${NC}"
kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/name=prometheus \
    -n ${NAMESPACE} \
    --timeout=5m

# Get Prometheus service URL
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Prometheus Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Access Prometheus UI:${NC}"
echo "  kubectl port-forward -n ${NAMESPACE} svc/${RELEASE_NAME}-kube-prom-prometheus 9090:9090"
echo "  Then open: http://localhost:9090"
echo ""
echo -e "${YELLOW}Access Alertmanager UI:${NC}"
echo "  kubectl port-forward -n ${NAMESPACE} svc/${RELEASE_NAME}-kube-prom-alertmanager 9093:9093"
echo "  Then open: http://localhost:9093"
echo ""
echo -e "${YELLOW}Check Prometheus status:${NC}"
echo "  kubectl get pods -n ${NAMESPACE}"
echo ""
echo -e "${YELLOW}View alert rules:${NC}"
echo "  kubectl get prometheusrule -n ${NAMESPACE}"
echo ""
echo -e "${YELLOW}View Prometheus targets:${NC}"
echo "  Open Prometheus UI and navigate to Status > Targets"
echo ""

# Verify installation
echo -e "${YELLOW}Verifying installation...${NC}"
PROMETHEUS_READY=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotReady")
ALERTMANAGER_READY=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotReady")

if [ "$PROMETHEUS_READY" = "Running" ]; then
    echo -e "${GREEN}✓ Prometheus is running${NC}"
else
    echo -e "${RED}✗ Prometheus is not ready (Status: ${PROMETHEUS_READY})${NC}"
fi

if [ "$ALERTMANAGER_READY" = "Running" ]; then
    echo -e "${GREEN}✓ Alertmanager is running${NC}"
else
    echo -e "${RED}✗ Alertmanager is not ready (Status: ${ALERTMANAGER_READY})${NC}"
fi

echo ""
echo -e "${GREEN}Installation script completed!${NC}"



