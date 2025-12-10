#!/bin/bash
# create-secrets.sh - Creates secrets in AWS Secrets Manager for OpenTelemetry Demo

set -e

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-otel-demo-cluster}
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_PROFILE=${AWS_PROFILE:-JulianFTA}
DB_MASTER_PASSWORD=${DB_PASSWORD}
DB_APP_PASSWORD=${DB_PASSWORD}


# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $AWS_PROFILE --query Account --output text)

echo "=========================================="
echo "Creating Secrets in AWS Secrets Manager"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Account: $ACCOUNT_ID"
echo "Profile: $AWS_PROFILE"
echo ""

# Check if passwords are provided, otherwise generate them
if [ -z "$DB_MASTER_PASSWORD" ]; then
  echo "⚠️  DB_MASTER_PASSWORD not set. Generating secure password..."
  DB_MASTER_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
fi

if [ -z "$DB_APP_PASSWORD" ]; then
  echo "⚠️  DB_APP_PASSWORD not set. Generating secure password..."
  DB_APP_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
fi

if [ -z "$GRAFANA_PASSWORD" ]; then
  echo "⚠️  GRAFANA_PASSWORD not set. Generating secure password..."
  GRAFANA_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
fi

echo "Creating secrets..."

# Function to create or update secret
create_or_update_secret() {
  local secret_name=$1
  local description=$2
  local secret_string=$3
  
  if aws secretsmanager describe-secret --secret-id "$secret_name" --region $AWS_REGION --profile $AWS_PROFILE &>/dev/null; then
    echo "  Updating existing secret: $secret_name"
    aws secretsmanager update-secret \
      --secret-id "$secret_name" \
      --secret-string "$secret_string" \
      --region $AWS_REGION \
      --profile $AWS_PROFILE > /dev/null
  else
    echo "  Creating new secret: $secret_name"
    aws secretsmanager create-secret \
      --name "$secret_name" \
      --description "$description" \
      --secret-string "$secret_string" \
      --region $AWS_REGION \
      --profile $AWS_PROFILE \
      --tags Key=Environment,Value=demo Key=Cluster,Value=$CLUSTER_NAME > /dev/null
  fi
}

# 1. RDS Master Password
create_or_update_secret \
  "otel-demo/rds/master-password" \
  "RDS PostgreSQL master password" \
  "{\"password\":\"${DB_MASTER_PASSWORD}\"}"

# 2. RDS Application User Credentials
create_or_update_secret \
  "otel-demo/rds/app-credentials" \
  "RDS PostgreSQL application user credentials" \
  "{\"username\":\"otelu\",\"password\":\"${DB_APP_PASSWORD}\"}"

# 3. Grafana Admin Credentials
create_or_update_secret \
  "otel-demo/grafana/admin-credentials" \
  "Grafana admin user credentials" \
  "{\"username\":\"admin\",\"password\":\"${GRAFANA_PASSWORD}\"}"

# 4. Database Connection String (constructed from app credentials)
CONNECTION_STRING="Host=postgresql;Username=otelu;Password=${DB_APP_PASSWORD};Database=otel"
create_or_update_secret \
  "otel-demo/rds/connection-string" \
  "RDS PostgreSQL connection string" \
  "{\"connectionString\":\"${CONNECTION_STRING}\"}"

echo ""
echo "✅ Secrets created/updated successfully!"
echo ""
echo "=========================================="
echo "IMPORTANT: Save these passwords securely"
echo "=========================================="
echo "DB Master Password: ${DB_MASTER_PASSWORD}"
echo "DB App Password: ${DB_APP_PASSWORD}"
echo "Grafana Password: ${GRAFANA_PASSWORD}"
echo ""
echo "Secret ARNs:"
aws secretsmanager list-secrets \
  --filters Key=tag-key,Values=Cluster Key=tag-value,Values=$CLUSTER_NAME \
  --query "SecretList[?contains(Name, 'otel-demo')].{Name:Name,ARN:ARN}" \
  --output table \
  --region $AWS_REGION \
  --profile $AWS_PROFILE

echo ""
echo "Next steps:"
echo "1. Use these passwords when creating/updating your RDS instance"
echo "2. Install AWS Secrets Manager CSI Driver"
echo "3. Create IAM service accounts with proper permissions"
echo "4. Update Kubernetes manifests to use secrets"
