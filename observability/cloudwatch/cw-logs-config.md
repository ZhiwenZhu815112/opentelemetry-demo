# CloudWatch Logs Configuration for OpenTelemetry Demo

This document describes how to configure CloudWatch Logs for the OpenTelemetry Astronomy Shop demo running on AWS EKS.

## Overview

CloudWatch Logs integration allows you to:
- Centralize logs from all microservices
- Query logs using CloudWatch Logs Insights
- Correlate logs with traces using trace IDs
- Set up log-based alerts and metrics

## Prerequisites

1. AWS EKS cluster with appropriate IAM permissions
2. CloudWatch Logs agent or Fluent Bit configured
3. IAM role/service account with CloudWatch Logs write permissions

## Configuration Steps

### 1. Enable Structured JSON Logging in Kubernetes Pods

All OpenTelemetry Demo services should output structured JSON logs. The services are already configured to send logs via OpenTelemetry Collector, but we can also configure direct CloudWatch logging.

#### Option A: Using Fluent Bit DaemonSet (Recommended)

Deploy Fluent Bit as a DaemonSet to collect logs from all pods:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: kube-system
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush         1
        Log_Level     info
        Daemon        off
        Parsers_File  parsers.conf

    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  5
        Mem_Buf_Limit     50MB
        Skip_Long_Lines   On

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Kube_URL            https://kubernetes.default.svc:443
        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        Kube_Tag_Prefix     kube.var.log.containers.
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude Off

    [FILTER]
        Name                modify
        Match               kube.*
        Add                 cluster_name ${CLUSTER_NAME}
        Add                 namespace_name ${NAMESPACE}

    [OUTPUT]
        Name                cloudwatch_logs
        Match               kube.*
        region              us-east-1
        log_group_name      /aws/eks/${CLUSTER_NAME}/application
        log_stream_prefix   ${HOST_NAME}-
        auto_create_group   true
```

#### Option B: Direct CloudWatch Logging from Pods

Add environment variables to pod specs to enable CloudWatch logging:

```yaml
env:
  - name: AWS_REGION
    value: "us-east-1"
  - name: AWS_LOG_GROUP
    value: "/aws/eks/otel-demo-cluster/otel-demo"
  - name: LOG_FORMAT
    value: "json"
```

### 2. Create CloudWatch Log Groups per Microservice

Create separate log groups for each microservice for better organization:

```bash
# Frontend service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/frontend

# Checkout service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/checkout

# Cart service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/cart

# Product Catalog service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/product-catalog

# Payment service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/payment

# Shipping service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/shipping

# Currency service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/currency

# Email service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/email

# Ad service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/ad

# Recommendation service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/recommendation

# Product Reviews service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/product-reviews

# Fraud Detection service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/fraud-detection

# Accounting service
aws logs create-log-group --log-group-name /aws/eks/otel-demo-cluster/otel-demo/accounting
```

### 3. Configure Log Retention

Set retention policies for log groups (e.g., 30 days):

```bash
aws logs put-retention-policy --log-group-name /aws/eks/otel-demo-cluster/otel-demo/frontend --retention-in-days 30
```

### 4. IAM Permissions

Ensure your EKS node group or pod service account has the following IAM policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:*:*:log-group:/aws/eks/otel-demo-cluster/*"
    }
  ]
}
```

### 5. Structured Log Format

Ensure services output logs in JSON format with the following structure:

```json
{
  "timestamp": "2024-12-07T21:36:00.123Z",
  "level": "INFO",
  "service_name": "checkout",
  "message": "Processing checkout request",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "user_id": "user-123",
  "request_id": "req-456",
  "latency_ms": 245,
  "status_code": 200,
  "method": "POST",
  "path": "/api/checkout",
  "ip": "10.0.1.5"
}
```

### 6. OpenTelemetry Collector Configuration

Update the OpenTelemetry Collector to export logs to CloudWatch:

```yaml
exporters:
  awscloudwatchlogs:
    region: us-east-1
    log_group_name: /aws/eks/otel-demo-cluster/otel-demo
    log_stream_name: otel-collector
    raw_log: false

service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [awscloudwatchlogs]
```

## Verification

1. Check if logs are being sent to CloudWatch:
   ```bash
   aws logs describe-log-streams --log-group-name /aws/eks/otel-demo-cluster/otel-demo/frontend
   ```

2. View recent log events:
   ```bash
   aws logs tail /aws/eks/otel-demo-cluster/otel-demo/frontend --follow
   ```

3. Test log ingestion by generating traffic:
   ```bash
   kubectl port-forward -n otel-demo svc/frontend 8080:8080
   # Visit http://localhost:8080 and browse the shop
   ```

## Best Practices

1. **Use structured logging**: Always log in JSON format for better querying
2. **Include trace IDs**: Add trace_id and span_id to correlate with traces
3. **Set appropriate retention**: Don't keep logs forever to save costs
4. **Use log groups per service**: Easier to manage and query
5. **Monitor log ingestion**: Set up CloudWatch metrics for log ingestion failures
6. **Use log filters**: Create metric filters for important events

## Troubleshooting

- **No logs appearing**: Check IAM permissions and Fluent Bit pod status
- **High costs**: Review retention policies and log volume
- **Missing trace IDs**: Ensure OpenTelemetry SDK is properly configured
- **Log format issues**: Verify JSON structure matches expected format
