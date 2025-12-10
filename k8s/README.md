OpenTelemetry Demo – Secure Deployment Guide

Security Hardening, TLS Enforcement, IAM/IRSA, NetworkPolicies & External Secrets Integration

The following features are implemented:
	•	TLS enforcement using AWS ALB + ACM (HTTPS, redirect 80 - 443)
	•	Least-privilege IAM roles using IRSA for Kubernetes service accounts
	•	NetworkPolicies to restrict lateral pod communication
	•	Encrypted secrets management using AWS Secrets Manager + ExternalSecrets Operator
	•	GuardDuty & Security Hub integration for threat monitoring
	•	Ingress protection with SSL redirection and certificate binding
	•	Complete zero-trust baseline using a default-deny ingress model

This README guides you through deployment, configuration, validation, and troubleshooting of these security enhancements.

Prerequisites

AWS
	•	An active AWS account
	•	AWS CLI configured (aws configure)
	•	IAM permissions for:
	•	EKS
	•	ACM
	•	IAM Policy & Roles
	•	Secrets Manager
	•	ELBv2
	•	A registered domain + validated ACM certificate (in us-east-1)

Kubernetes / EKS
	•	kubectl installed
	•	eksctl installed

"kubectl config current-context"

Tools Installed in the Cluster
	•	AWS Load Balancer Controller
	•	ExternalSecrets Operator
	•	OIDC provider enabled on the EKS cluster

Architecture Diagram

                    ┌────────────────────────────┐
                    │        Public Internet     │
                    └──────────────┬─────────────┘
                                   │
                           HTTPS (443) Only
                                   │
                  ┌────────────────▼────────────────┐
                  │   AWS Application Load Balancer │
                  │   - ACM TLS Certificate         │
                  │   - SSL Redirect (80→443)       │
                  └────────────────┬────────────────┘
                                   │
                            Ingress Controller
                                   │
                   ┌───────────────┴────────────────┐
                   │          EKS Cluster           │
                   │  Namespace: otel-demo          │
                   │  - Deployment Pods             │
                   │  - Jaeger / Grafana / Prom     │
                   └──────────────┬─────────────────┘
                                  │
                        NetworkPolicies (Zero Trust)
   ┌───────────────────────────────────────────────────────────┐
   │ Only allowed traffic flows:                               │
   │   - frontend → backend services                           │
   │   - backend → PostgreSQL                                  │
   │   - all workloads → otel-collector                        │
   │   - default deny all ingress                              │
   └───────────────────────────────────────────────────────────┘


Secrets Flow:
  ExternalSecrets Operator - IAM Role via IRSA - Secrets Manager - K8s Secret

IAM & IRSA Setup

IRSA is used to bind AWS IAM permissions directly to pods.
k8s/network-policies/eso-secretsmanager-policy.json

Attach to service account

eksctl create iamserviceaccount \
  --name external-secrets \
  --namespace otel-demo \
  --cluster otel-demo \
  --attach-policy-arn <ESO_POLICY_ARN> \
  --approve

Secrets Management (AWS Secrets Manager + ExternalSecrets)

aws secretsmanager create-secret \
  --name otel-demo/postgresql-password \
  --secret-string '{"POSTGRES_PASSWORD":"SuperSecureP@ssw0rd"}'
#Set a new password 

Apply the SecretStore

k8s/secrets/secretstore-aws.yaml

Apply 
kubectl apply -f k8s/secrets/secretstore-aws.yaml

Apply ExternalSecret

k8s/secrets/externalsecret-postgresql.yaml

kubectl apply -f k8s/secrets/externalsecret-postgresql.yaml

Ingress and TLS Configuration
  k8s/ingress-frontend.yaml
Key features:
	•	HTTPS listener via ACM certificate
	•	ALB Ingress Controller annotations
	•	HTTP to HTTPS redirection
	•	Public facing ALB

Apply ingress 
kubectl apply -f k8s/ingress-frontend.yaml

Verify
kubectl get ingress -n otel-demo

Test TLS: 
https://your-domain.com

Lock icon should show up. 

Network Policies (Zero Trust Security)
  NetworkPolicies enforce minimal communication between pods.


Files location
 k8s/network-policies/

	•	00-default-deny-ingress.yaml
	•	10-allow-frontend-proxy-from-any.yaml
	•	20-allow-backends-from-frontend.yaml
	•	30-allow-postgresql-from-backends.yaml
	•	40-allow-otel-collector-from-all.yaml

Apply all

kubectl apply -f k8s/network-policies/

Confirm 
kubectl get networkpolicy -n otel-demo

Monitoring & Threat Detection GuardDuty + Security Hub

aws guardduty create-sample-findings --detector-id <ID>
aws securityhub get-findings

Check TLS 

curl -I https://astronomy-shop.com #use your domain. 

return 
HTTP/2 200

Check Secrets 
kubectl exec -it postgresql-pod -- printenv POSTGRES_PASSWORD


File structure: 

k8s/
├── ingress-frontend.yaml
├── network-policies/
│   ├── 00-default-deny-ingress.yaml
│   ├── 10-allow-frontend-proxy-from-any.yaml
│   ├── 20-allow-backends-from-frontend.yaml
│   ├── 30-allow-postgresql-from-backends.yaml
│   └── 40-allow-otel-collector-from-all.yaml
├── secrets/
│   ├── secretstore-aws.yaml
│   ├── externalsecret-postgresql.yaml
│   ├── config-bucket-policy.json
│   └── trust-policy.json
└── lbc-extra-permissions.json