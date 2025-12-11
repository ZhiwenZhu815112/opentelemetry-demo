#!/bin/bash

# Setup TLS for the correct domain: enpm818r-group8.click
set -e

DOMAIN="enpm818r-group8.click"
NAMESPACE="otel-demo"
HOSTED_ZONE_ID="Z0742184E2HO21LEATLL"

echo "=== Setting up TLS for $DOMAIN ==="

# Step 1: Delete old certificates
echo "1. Cleaning up old certificates..."
aws acm list-certificates --region us-east-1 --query 'CertificateSummaryList[?DomainName!=`'$DOMAIN'`].CertificateArn' --output text | while read cert; do
    if [ -n "$cert" ]; then
        echo "Deleting certificate: $cert"
        aws acm delete-certificate --certificate-arn "$cert" --region us-east-1 2>/dev/null || true
    fi
done

# Step 2: Create certificate for correct domain
echo "2. Creating certificate for $DOMAIN..."
CERT_ARN=$(aws acm request-certificate \
    --domain-name $DOMAIN \
    --validation-method DNS \
    --region us-east-1 \
    --query 'CertificateArn' \
    --output text)

echo "Certificate ARN: $CERT_ARN"

# Step 3: Wait for validation record
echo "3. Waiting for validation record..."
for i in {1..10}; do
    sleep 10
    VALIDATION_DATA=$(aws acm describe-certificate \
        --certificate-arn $CERT_ARN \
        --region us-east-1 \
        --query 'Certificate.DomainValidationOptions[0]' \
        --output json)
    
    RECORD_NAME=$(echo "$VALIDATION_DATA" | jq -r '.ResourceRecord.Name // empty')
    RECORD_VALUE=$(echo "$VALIDATION_DATA" | jq -r '.ResourceRecord.Value // empty')
    
    if [ -n "$RECORD_NAME" ] && [ "$RECORD_NAME" != "null" ]; then
        echo "✅ Validation record ready!"
        echo "  Name: $RECORD_NAME"
        echo "  Value: $RECORD_VALUE"
        break
    fi
    echo "Attempt $i/10: Waiting for validation record..."
done

# Step 4: Add validation record to Route 53
echo "4. Adding DNS validation record..."
aws route53 change-resource-record-sets \
    --hosted-zone-id $HOSTED_ZONE_ID \
    --change-batch "{
        \"Changes\": [{
            \"Action\": \"UPSERT\",
            \"ResourceRecordSet\": {
                \"Name\": \"$RECORD_NAME\",
                \"Type\": \"CNAME\",
                \"TTL\": 300,
                \"ResourceRecords\": [{
                    \"Value\": \"$RECORD_VALUE\"
                }]
            }
        }]
    }"

echo "✅ DNS validation record created"

# Step 5: Wait for certificate validation
echo "5. Waiting for certificate validation (5-10 minutes)..."
for i in {1..30}; do
    STATUS=$(aws acm describe-certificate --certificate-arn $CERT_ARN --region us-east-1 --query 'Certificate.Status' --output text)
    echo "Attempt $i/30: Certificate status: $STATUS"
    
    if [ "$STATUS" = "ISSUED" ]; then
        echo "✅ Certificate issued!"
        break
    fi
    
    if [ $i -eq 30 ]; then
        echo "❌ Certificate validation timeout"
        exit 1
    fi
    
    sleep 20
done

# Step 6: Update ingress
echo "6. Updating ingress with HTTPS..."
kubectl delete ingress otel-demo-ingress -n $NAMESPACE 2>/dev/null || true
kubectl delete ingress otel-frontend-ingress -n $NAMESPACE 2>/dev/null || true

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: otel-frontend-ingress
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: $CERT_ARN
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  rules:
    - host: $DOMAIN
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-proxy
                port:
                  number: 8080
EOF

# Step 7: Create domain A record
echo "7. Creating domain A record..."
sleep 60

ALB_HOSTNAME=$(kubectl get ingress otel-frontend-ingress -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ALB_ZONE_ID=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$ALB_HOSTNAME'].CanonicalHostedZoneId" --output text)

aws route53 change-resource-record-sets \
    --hosted-zone-id $HOSTED_ZONE_ID \
    --change-batch "{
        \"Changes\": [{
            \"Action\": \"UPSERT\",
            \"ResourceRecordSet\": {
                \"Name\": \"$DOMAIN\",
                \"Type\": \"A\",
                \"AliasTarget\": {
                    \"DNSName\": \"$ALB_HOSTNAME\",
                    \"EvaluateTargetHealth\": false,
                    \"HostedZoneId\": \"$ALB_ZONE_ID\"
                }
            }
        }]
    }"

echo ""
echo "=========================================="
echo "🔒 TLS SETUP COMPLETE!"
echo "=========================================="
echo ""
echo "🌐 Your Secure OpenTelemetry Demo:"
echo "   HTTPS: https://$DOMAIN"
echo "   HTTP:  http://$DOMAIN (redirects to HTTPS)"
echo ""
echo "Wait 2-3 minutes for DNS propagation, then test:"
echo "   curl -I https://$DOMAIN"