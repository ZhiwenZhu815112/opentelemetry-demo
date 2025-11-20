#!/usr/bin/env bash
set -euo pipefail

########################################
# Expect AWS_ACCOUNT_ID and AWS_REGION
# to be provided via environment variables.
# (Do NOT hardcode these in the script.)
########################################
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID env var is required}"
: "${AWS_REGION:?AWS_REGION env var is required}"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

########################################
# Image version (semantic version style)
# You can change this tag freely.
########################################
IMAGE_VERSION="enpm818r-1.0.0"

########################################
# Services to push to ECR
# Each maps to an ECR repo:
#   opentelemetry-demo-<service>
########################################
SERVICES=(
  accounting
  ad
  cart
  checkout
  currency
  email
  flagd
  flagd-ui
  frontend
  frontend-proxy
  grafana
  jaeger
  kafka
  llm
  load-generator
  opensearch
  otel-collector
  payment
  postgresql
  product-catalog
  product-reviews
  prometheus
  recommendation
  shipping
  valkey-cart
  quote
)

########################################
# Helper: get local image name for a service
# (Must match what you have locally: `docker images`)
########################################
get_local_image() {
  local svc="$1"
  case "$svc" in
    # Core demo images (built or pulled by compose)
    accounting)        echo "ghcr.io/open-telemetry/demo:latest-accounting" ;;
    ad)                echo "ghcr.io/open-telemetry/demo:latest-ad" ;;
    cart)              echo "ghcr.io/open-telemetry/demo:latest-cart" ;;
    checkout)          echo "ghcr.io/open-telemetry/demo:latest-checkout" ;;
    currency)          echo "ghcr.io/open-telemetry/demo:latest-currency" ;;
    email)             echo "ghcr.io/open-telemetry/demo:latest-email" ;;
    flagd-ui)          echo "ghcr.io/open-telemetry/demo:latest-flagd-ui" ;;
    frontend)          echo "ghcr.io/open-telemetry/demo:latest-frontend" ;;
    frontend-proxy)    echo "ghcr.io/open-telemetry/demo:latest-frontend-proxy" ;;
    fraud-detection)   echo "ghcr.io/open-telemetry/demo:latest-fraud-detection" ;;
    image-provider)    echo "ghcr.io/open-telemetry/demo:latest-image-provider" ;;
    kafka)             echo "ghcr.io/open-telemetry/demo:latest-kafka" ;;
    llm)               echo "ghcr.io/open-telemetry/demo:latest-llm" ;;
    load-generator)    echo "ghcr.io/open-telemetry/demo:latest-load-generator" ;;
    payment)           echo "ghcr.io/open-telemetry/demo:latest-payment" ;;
    product-catalog)   echo "ghcr.io/open-telemetry/demo:latest-product-catalog" ;;
    product-reviews)   echo "ghcr.io/open-telemetry/demo:latest-product-reviews" ;;
    quote)             echo "ghcr.io/open-telemetry/demo:latest-quote" ;;
    recommendation)    echo "ghcr.io/open-telemetry/demo:latest-recommendation" ;;
    shipping)          echo "ghcr.io/open-telemetry/demo:latest-shipping" ;;
    postgresql)        echo "ghcr.io/open-telemetry/demo:latest-postgresql" ;;
    opensearch)        echo "opentelemetry-demo-opensearch:latest" ;;

    # Third-party images referenced by compose
    flagd)             echo "ghcr.io/open-feature/flagd:v0.12.9" ;;
    valkey-cart)       echo "valkey/valkey:9.0.0-alpine3.22" ;;
    jaeger)            echo "jaegertracing/jaeger:2.11.0" ;;
    grafana)           echo "grafana/grafana:12.2.0" ;;
    otel-collector)    echo "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.139.0" ;;
    prometheus)        echo "quay.io/prometheus/prometheus:v3.7.3" ;;

    *)
      echo "Unknown service: $svc" >&2
      return 1
      ;;
  esac
}

########################################
# 1. Create ECR repositories (if needed)
#    scanOnPush enabled for vulnerability scans
########################################
echo "==> Creating ECR repositories with scanOnPush enabled"

for SVC in "${SERVICES[@]}"; do
  REPO_NAME="opentelemetry-demo-${SVC}"
  echo "-> aws ecr create-repository --repository-name ${REPO_NAME}"
  if aws ecr create-repository \
      --region "${AWS_REGION}" \
      --repository-name "${REPO_NAME}" \
      --image-scanning-configuration scanOnPush=true >/dev/null 2>&1; then
    echo "   Created repository: ${REPO_NAME}"
  else
    echo "   Repository ${REPO_NAME} already exists or creation failed, continuing..."
  fi
done

########################################
# 2. Login to ECR
########################################
echo "==> Logging in to ECR: ${ECR_REGISTRY}"

aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

########################################
# 3. Tag and push images
########################################
echo "==> Tagging and pushing images with version: ${IMAGE_VERSION}"

for SVC in "${SERVICES[@]}"; do
  LOCAL_IMAGE="$(get_local_image "$SVC")" || { echo "Skip ${SVC} due to missing local image mapping"; continue; }
  REMOTE_IMAGE="${ECR_REGISTRY}/opentelemetry-demo-${SVC}:${IMAGE_VERSION}"

  echo ""
  echo "------------------------------------------"
  echo "Service:      ${SVC}"
  echo "Local image:  ${LOCAL_IMAGE}"
  echo "Remote image: ${REMOTE_IMAGE}"
  echo "------------------------------------------"

  # Check if local image exists
  if ! docker image inspect "${LOCAL_IMAGE}" >/dev/null 2>&1; then
    echo "!! Local image not found: ${LOCAL_IMAGE}. Skipping this service."
    echo "   Tip: run 'docker pull ${LOCAL_IMAGE}' if it's a third-party image."
    continue
  fi

  # Tag local image to ECR repo
  echo "docker tag ${LOCAL_IMAGE} ${REMOTE_IMAGE}"
  docker tag "${LOCAL_IMAGE}" "${REMOTE_IMAGE}"

  # Push to ECR
  echo "docker push ${REMOTE_IMAGE}"
  docker push "${REMOTE_IMAGE}"
done

echo ""
echo "==> Done. Check ECR console for repositories, tags, and vulnerability scan results."