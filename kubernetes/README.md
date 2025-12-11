# OpenTelemetry Demo - Production AWS Deployment

A complete production-ready deployment of the OpenTelemetry Astronomy Shop demo on AWS EKS with enterprise-grade security, observability, and TLS encryption.

## 🏗️ Architecture Overview

This deployment creates a comprehensive observability platform with:

- **EKS Cluster** - Managed Kubernetes with auto-scaling
- **RDS PostgreSQL** - Managed database for persistent data
- **Application Load Balancer** - Internet-facing with TLS termination
- **ACM Certificate** - SSL/TLS encryption for custom domain
- **Route 53** - DNS management and domain routing
- **Zero-Trust Security** - Network policies and secrets management
- **Complete Observability** - Distributed tracing, metrics, and logs

### Infrastructure Components

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS Cloud                            │
├─────────────────────────────────────────────────────────────┤
│  Route 53 DNS                                              │
│  ├── enpm818r-group8.click → ALB                           │
│  └── ACM Certificate (TLS)                                 │
├─────────────────────────────────────────────────────────────┤
│  Application Load Balancer                                 │
│  ├── HTTPS:443 (Primary)                                   │
│  └── HTTP:80 → HTTPS Redirect                              │
├─────────────────────────────────────────────────────────────┤
│  EKS Cluster (otel-demo-cluster)                          │
│  ├── Node Group (4 x t3.medium)                           │
│  ├── AWS Load Balancer Controller                         │
│  ├── Cluster Autoscaler                                   │
│  ├── EBS CSI Driver                                       │
│  └── ExternalSecrets Operator                             │
├─────────────────────────────────────────────────────────────┤
│  OpenTelemetry Demo Application                            │
│  ├── Frontend (Next.js)                                   │
│  ├── Backend Services (Go, Java, Python, .NET, etc.)     │
│  ├── OpenTelemetry Collector                              │
│  ├── Jaeger (Distributed Tracing)                         │
│  ├── Prometheus (Metrics)                                 │
│  └── Grafana (Dashboards)                                 │
├─────────────────────────────────────────────────────────────┤
│  RDS PostgreSQL                                           │
│  ├── Multi-AZ Deployment                                  │
│  ├── Automated Backups                                    │
│  └── Encryption at Rest                                   │
├─────────────────────────────────────────────────────────────┤
│  Security & Networking                                     │
│  ├── VPC with Public/Private Subnets                      │
│  ├── Zero-Trust Network Policies                          │
│  ├── AWS Secrets Manager Integration                      │
│  └── IAM Roles with Least Privilege                       │
└─────────────────────────────────────────────────────────────┘
```

## 📋 Prerequisites

### Required Tools
- AWS CLI v2 configured with appropriate permissions
- kubectl v1.28+
- eksctl v0.150+
- Helm v3.12+
- jq (for JSON processing)

### AWS Permissions
Your AWS user/role needs permissions for:
- EKS (cluster management)
- EC2 (VPC, subnets, security groups)
- RDS (database creation)
- IAM (role and policy management)
- Route 53 (DNS management)
- ACM (certificate management)
- Secrets Manager (optional)
- CloudFormation (stack management)

### Domain Setup (Optional)
- Registered domain with Route 53 hosted zone
- Update `DOMAIN` and `HOSTED_ZONE_ID` in scripts if using custom domain

## 🚀 Quick Start

### 1. Basic Deployment
Deploy the complete OpenTelemetry demo with RDS integration:

```bash
cd kubernetes/
export CLUSTER_NAME="otel-demo-cluster"
export AWS_REGION="us-east-1"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DB_PASSWORD="your-secure-password"
export PG_VERSION="15.14

# Deploy infrastructure and application
bash startup-working.sh
```

**Deployment time**: ~20-25 minutes (RDS creation takes 15-20 minutes)

### 2. Security Hardening 
Add enterprise security features:

```bash
# Add zero-trust network policies and secrets management
bash deploy-security-hardened.sh
```

**Features added**:
- Zero-trust network policies (default deny)
- ExternalSecrets Operator 
- AWS Secrets Manager integration
- Enhanced security annotations

### 3. Production TLS Setup 
Configure HTTPS with custom domain:

```bash
# Setup TLS certificate and domain routing
bash setup-correct-domain.sh
```

**Features added**:
- ACM certificate for custom domain
- Route 53 DNS configuration
- HTTPS with SSL redirect
- Production-ready ingress

## 📁 Project Structure

```
kubernetes/
├── startup-working.sh              # Main deployment script
├── deploy-security-hardened.sh     # Security enhancement script
├── setup-correct-domain.sh         # TLS/domain configuration script
├── cleanup-complete.sh             # Complete cleanup script
├── eks-infra.yaml                  # CloudFormation template
├── governance.yaml                 # RBAC configuration
└── ../k8s/
    ├── network-policies/           # Zero-trust network policies
    │   ├── 00-default-deny-ingress.yaml
    │   ├── 10-allow-frontend-proxy-from-any.yaml
    │   ├── 20-allow-backends-from-frontend.yaml
    │   ├── 30-allow-postgresql-from-backends.yaml
    │   ├── 40-allow-otel-collector-from-all.yaml
    │   └── eso-secretsmanager-policy.json
    └── secrets/                    # Secrets management
        ├── secretstore-aws.yaml
        ├── externalsecret-postgresql.yaml
        └── trust-policy.json
```

## 🔧 Detailed Deployment Guide

### Script 1: startup-working.sh

**Purpose**: Creates complete infrastructure and deploys OpenTelemetry demo

**What it does**:
1. **AWS Setup** - Validates credentials and sets up environment
2. **CloudFormation Stack** - Deploys EKS cluster, VPC, and RDS via `eks-infra.yaml`
3. **kubectl Configuration** - Configures cluster access
4. **RBAC Setup** - Applies governance and role-based access control
5. **AWS Controllers** - Installs Load Balancer Controller and Cluster Autoscaler
6. **Storage** - Configures EBS CSI driver and storage classes
7. **Database** - Retrieves RDS connection details and initializes schema
8. **Application** - Deploys OpenTelemetry demo via Helm chart
9. **Networking** - Creates ALB ingress for external access
10. **Verification** - Validates deployment and provides access information

**Key Resources Created**:
- EKS cluster with 4 t3.medium nodes
- RDS PostgreSQL database (Multi-AZ)
- VPC with public/private subnets
- Application Load Balancer
- IAM roles and policies
- Storage classes and persistent volumes

### Script 2: deploy-security-hardened.sh

**Purpose**: Adds enterprise security features

**What it does**:
1. **ExternalSecrets Operator** - Integrates with AWS Secrets Manager (optional)
2. **Network Policies** - Implements zero-trust networking
3. **Secrets Management** - Configures secure credential handling
4. **Security Verification** - Validates security configuration

**Security Features**:
- Default deny ingress policy
- Granular service-to-service communication rules
- AWS Secrets Manager integration
- Encrypted credential storage

### Script 3: setup-correct-domain.sh

**Purpose**: Configures production TLS and custom domain

**What it does**:
1. **Certificate Management** - Creates and validates ACM certificate
2. **DNS Configuration** - Sets up Route 53 records
3. **HTTPS Ingress** - Updates ALB with TLS termination
4. **SSL Redirect** - Redirects HTTP to HTTPS

**Production Features**:
- Valid SSL certificate from AWS ACM
- Custom domain routing
- Automatic HTTPS redirect
- DNS validation and propagation

## 🌐 Access Your Application

### After Basic Deployment
```bash
# Get ALB URL
kubectl get ingress -n otel-demo

# Access via ALB
http://k8s-oteldemo-otelfron-xxxxxxxxxx.us-east-1.elb.amazonaws.com
```

### After TLS Setup
```bash
# Access via custom domain
https://enpm818r-group8.click
```

### Application Components
- **Frontend**: Main e-commerce interface
- **Jaeger UI**: Distributed tracing at `/jaeger`
- **Grafana**: Metrics dashboards at `/grafana`
- **Prometheus**: Metrics collection at `/prometheus`

## 🔍 Monitoring & Observability

### Key Features Available
- **Distributed Tracing** - End-to-end request tracing with Jaeger
- **Metrics Collection** - Application and infrastructure metrics with Prometheus
- **Dashboards** - Pre-built Grafana dashboards for system monitoring
- **Log Aggregation** - Centralized logging with OpenTelemetry Collector
- **Service Mesh Observability** - Inter-service communication insights

### Monitoring Commands
```bash
# Check pod status
kubectl get pods -n otel-demo

# View application logs
kubectl logs -f deployment/frontend-proxy -n otel-demo

# Check database connectivity
kubectl logs -f deployment/accounting -n otel-demo

# Monitor resource usage
kubectl top pods -n otel-demo
```

## 🛡️ Security Features

### Network Security
- **Zero-Trust Policies** - Default deny with explicit allow rules
- **Service Isolation** - Granular network segmentation
- **Ingress Control** - Controlled external access points

### Secrets Management
- **AWS Secrets Manager** - Centralized credential storage
- **ExternalSecrets Operator** - Kubernetes-native secret synchronization
- **Encrypted Storage** - All secrets encrypted at rest

### Access Control
- **RBAC** - Role-based access control for Kubernetes resources
- **IAM Integration** - AWS IAM roles for service accounts (IRSA)
- **Least Privilege** - Minimal required permissions

## 🧹 Cleanup

### Complete Resource Cleanup
Remove all AWS resources and local configurations:

```bash
# Set environment variables
export CLUSTER_NAME="otel-demo-cluster"
export AWS_REGION="us-east-1"

# Run complete cleanup
bash cleanup-complete.sh
```

**What gets deleted**:
- ✅ Application resources (ALBs, services, pods)
- ✅ Helm releases (OpenTelemetry Demo, controllers)
- ✅ Kubernetes resources (PVCs, namespaces, policies)
- ✅ Service accounts and IAM roles
- ✅ IAM policies
- ✅ ACM certificates
- ✅ Route 53 DNS records
- ✅ AWS Secrets Manager secrets
- ✅ EKS cluster and RDS database
- ✅ VPC and networking (via CloudFormation)
- ✅ Local generated files

**Cleanup time**: ~15-20 minutes (CloudFormation stack deletion)

## 🔧 Troubleshooting

### Common Issues

**DNS Resolution Problems**
```bash
# Flush local DNS cache (macOS)
sudo dscacheutil -flushcache

# Test with external DNS
nslookup enpm818r-group8.click 8.8.8.8

# Add to /etc/hosts temporarily
echo "$(dig enpm818r-group8.click @8.8.8.8 +short | head -1) enpm818r-group8.click" | sudo tee -a /etc/hosts
```

**Pod Issues**
```bash
# Check pod status
kubectl get pods -n otel-demo

# Describe problematic pods
kubectl describe pod <pod-name> -n otel-demo

# Check logs
kubectl logs <pod-name> -n otel-demo --previous
```

**Database Connectivity**
```bash
# Check RDS endpoint
aws rds describe-db-instances --query 'DBInstances[0].Endpoint.Address' --output text

# Test database connection
kubectl exec -it deployment/accounting -n otel-demo -- env | grep POSTGRES
```

### Useful Commands
```bash
# Cluster information
kubectl cluster-info

# Node status
kubectl get nodes -o wide

# Storage status
kubectl get pvc -n otel-demo

# Ingress status
kubectl get ingress -n otel-demo -o wide

# Network policies
kubectl get networkpolicy -n otel-demo
```

## 📊 Cost Optimization

### Resource Sizing
- **EKS Cluster**: 4 x t3.medium nodes (~$120/month)
- **RDS PostgreSQL**: db.t3.micro Multi-AZ (~$25/month)
- **ALB**: ~$20/month
- **Data Transfer**: Variable based on usage

### Cost Reduction Tips
- Use Spot instances for non-production workloads
- Enable cluster autoscaler to scale down during low usage
- Consider Reserved Instances for long-term deployments
- Monitor and optimize resource requests/limits

## 🤝 Contributing

### Development Workflow
1. Fork the repository
2. Create feature branch
3. Test changes with deployment scripts
4. Submit pull request with detailed description

### Testing Changes
```bash
# Test basic deployment
bash startup-working.sh

# Verify security features
bash deploy-security-hardened.sh

# Test TLS configuration
bash setup-correct-domain.sh

# Clean up after testing
bash cleanup-complete.sh
```