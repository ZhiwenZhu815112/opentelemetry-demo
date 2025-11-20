#!/usr/bin/env bash
set -euo pipefail

########################################
# Expect AWS_ACCOUNT_ID and AWS_REGION
# to be provided via environment variables.
########################################

: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID env var is required}"
: "${AWS_REGION:?AWS_REGION env var is required}"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

########################################
# Image version (semantic version style)
# Example: "1.0.0-enpm818r" or "enpm818r-v1"
########################################

IMAGE_VERSION="enpm818r-1.0.0"

########################################
# List of services to push to ECR
# Each will map to an ECR repo:
#   opentelemetry-demo-<service>
########################################

SERVICES=(
  accounting
  ad
  cart
  checkout
  currency
  email
  flagd-ui
  frontend
  frontend-proxy
  fraud-detection
  image-provider
  kafka
  llm
  load-generator
  payment
  product-catalog
  product-reviews
  quote
  recommendation
  shipping
  postgresql
  opensearch
)

########################################
# Helper: get local image name for a service
########################################

get_local_image() {
  local svc="$1"
  case "$svc" in
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
    *)
      echo "Unknown service: $svc" >&2
      return 1
      ;;
  esac
}

########################################
# 1. Create ECR repositories (if needed)
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