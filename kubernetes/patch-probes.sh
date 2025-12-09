#!/bin/bash

# Define the list of services to patch
SERVICES=("frontend" "cart" "checkout" "currency" "product-catalog" "recommendation" "shipping" "ad" "email" "payment")

# Loop through each service and apply the patch
for SERVICE in "${SERVICES[@]}"; do
  echo "Applying probes to service: $SERVICE..."

  # Create a temporary patch file for this specific service
  cat <<EOF > probe-patch.yaml
spec:
  template:
    spec:
      containers:
      - name: $SERVICE
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 20
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
EOF

  # Apply the patch
  kubectl patch deployment $SERVICE -n otel-demo --patch "$(cat probe-patch.yaml)"
  
  echo "✅ Patched $SERVICE successfully."
done

# Cleanup
rm probe-patch.yaml
echo "🎉 All services updated!"