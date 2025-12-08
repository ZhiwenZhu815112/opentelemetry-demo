#!/bin/bash
# Script to seed RDS database from an EKS pod
# RDS is in a private subnet, so we must connect from within the VPC

set -e  # Exit on error

# Check required environment variables
if [ -z "$RDS_ENDPOINT" ] || [ -z "$DB_PASSWORD" ]; then
  echo "Error: RDS_ENDPOINT and DB_PASSWORD must be set"
  echo "Usage: export RDS_ENDPOINT=<endpoint> && export DB_PASSWORD=<password> && ./seed-rds-from-pod.sh"
  exit 1
fi

RDS_PORT=${RDS_PORT:-5432}

echo "=========================================="
echo "Seeding RDS Database from EKS Pod"
echo "=========================================="
echo "RDS Endpoint: ${RDS_ENDPOINT}:${RDS_PORT}"
echo ""

# Step 1: Create a temporary pod
echo "Step 1: Creating temporary PostgreSQL pod..."
kubectl run psql-seeder \
  --image=postgres:15 \
  --restart=Never \
  --env="PGPASSWORD=${DB_PASSWORD}" \
  -- sleep 3600

# Wait for pod to be ready
echo "Waiting for pod to be ready..."
kubectl wait --for=condition=ready pod/psql-seeder --timeout=60s || {
  echo "Error: Pod failed to start"
  kubectl delete pod psql-seeder --ignore-not-found=true
  exit 1
}

# Step 2: Copy init.sql to pod
echo ""
echo "Step 2: Copying init.sql to pod..."
cd ..
kubectl cp src/postgres/init.sql psql-seeder:/tmp/init.sql
cd kubernetes

# Step 3: Create application user
echo ""
echo "Step 3: Creating application user..."
kubectl exec psql-seeder -- psql \
  -h ${RDS_ENDPOINT} \
  -U otelu \
  -d postgres \
  -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'otelu') THEN CREATE USER otelu WITH PASSWORD 'otelp'; END IF; END \$\$;" || echo "User may already exist, continuing..."

# Step 4: Grant privileges
echo ""
echo "Step 4: Granting privileges..."
kubectl exec psql-seeder -- psql \
  -h ${RDS_ENDPOINT} \
  -U otelu \
  -d postgres \
  -c "GRANT ALL PRIVILEGES ON DATABASE otel TO otelu;"

kubectl exec psql-seeder -- psql \
  -h ${RDS_ENDPOINT} \
  -U otelu \
  -d otel \
  -c "GRANT ALL ON SCHEMA public TO otelu;"

# Step 5: Load schema
echo ""
echo "Step 5: Loading database schema and seed data..."
kubectl exec psql-seeder -- psql \
  -h ${RDS_ENDPOINT} \
  -U otelu \
  -d otel \
  -f /tmp/init.sql

# Step 6: Verify
echo ""
echo "Step 6: Verifying schema..."
echo "Accounting schema tables:"
kubectl exec psql-seeder -- psql \
  -h ${RDS_ENDPOINT} \
  -U otelu \
  -d otel \
  -c "\dt accounting.*"

echo ""
echo "Reviews schema tables:"
kubectl exec psql-seeder -- psql \
  -h ${RDS_ENDPOINT} \
  -U otelu \
  -d otel \
  -c "\dt reviews.*"

echo ""
echo "Product reviews count:"
kubectl exec psql-seeder -- psql \
  -h ${RDS_ENDPOINT} \
  -U otelu \
  -d otel \
  -c "SELECT COUNT(*) FROM reviews.productreviews;"

# Step 7: Cleanup
echo ""
echo "Step 7: Cleaning up..."
kubectl delete pod psql-seeder

echo ""
echo "=========================================="
echo "Database seeding completed successfully!"
echo "=========================================="

