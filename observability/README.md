# OpenTelemetry Demo Observability Stack

This directory contains the complete observability setup for the OpenTelemetry Astronomy Shop demo deployed on AWS EKS. The observability stack includes Prometheus for metrics collection, Grafana for visualization, CloudWatch for log aggregation, and comprehensive alerting.

## 📁 Directory Structure

```
observability/
├── cloudwatch/
│   ├── cw-logs-config.md          # CloudWatch Logs configuration guide
│   └── sample-query.md             # Sample CloudWatch Logs Insights queries
├── prometheus/
│   ├── values-prometheus.yaml      # Prometheus Helm values
│   ├── alert-rules.yaml            # Prometheus alert rules
│   └── install-prometheus.sh       # Prometheus installation script
├── grafana/
│   ├── values-grafana.yaml         # Grafana Helm values
│   ├── install-grafana.sh          # Grafana installation script
│   └── dashboards/
│       ├── latency.json            # Latency dashboard
│       ├── error-rate.json         # Error rate dashboard
│       └── resource-util.json      # Resource utilization dashboard
├── runbook/
│   └── alert-runbook.md            # Alert response procedures
└── README.md                        # This file
```

## 🚀 Quick Start

### Prerequisites

1. AWS EKS cluster running the OpenTelemetry Demo
2. `kubectl` configured to access your cluster
3. `helm` v3.x installed
4. Appropriate IAM permissions for CloudWatch Logs

### Installation Order

1. **Install Prometheus:**
   ```bash
   cd observability/prometheus
   chmod +x install-prometheus.sh
   ./install-prometheus.sh
   ```

2. **Install Grafana:**
   ```bash
   cd observability/grafana
   chmod +x install-grafana.sh
   ./install-grafana.sh
   ```

3. **Configure CloudWatch Logs:**
   - Follow instructions in `cloudwatch/cw-logs-config.md`
   - Set up log groups for each microservice
   - Configure Fluent Bit or direct CloudWatch logging

## 📊 Components Overview

### Prometheus

Prometheus collects metrics from:
- **Kubernetes cluster** (via kube-state-metrics and node-exporter)
- **OpenTelemetry Collector** (metrics endpoint on port 8888)
- **Application services** (via service discovery and annotations)

#### How Prometheus Works with OpenTelemetry Collector

1. **Metrics Flow:**
   ```
   Application Services → OpenTelemetry Collector → Prometheus
   ```

2. **Configuration:**
   - Prometheus scrapes the OpenTelemetry Collector's metrics endpoint (`:8888/metrics`)
   - The Collector aggregates metrics from all services and exposes them in Prometheus format
   - Prometheus stores these metrics with labels for service name, namespace, etc.

3. **Service Discovery:**
   - Prometheus uses Kubernetes service discovery to find pods
   - Pods with annotation `prometheus.io/scrape: "true"` are automatically scraped
   - Additional scrape configs in `values-prometheus.yaml` target the Collector

4. **Metrics Available:**
   - Request duration histograms
   - HTTP request counts by status code
   - Custom business metrics from services
   - Resource usage metrics (CPU, memory, network)

#### Accessing Prometheus

```bash
# Port-forward to Prometheus UI
kubectl port-forward -n observability svc/observability-prometheus-kube-prom-prometheus 9090:9090

# Open in browser: http://localhost:9090
```

### Grafana

Grafana provides visualization dashboards for:
- **Latency metrics** (P50, P95, P99)
- **Error rates** (by service and status code)
- **Resource utilization** (CPU, memory, network, disk)

#### How Grafana Loads Dashboards

1. **Dashboard Provisioning:**
   - Dashboards are defined as JSON files in `grafana/dashboards/`
   - Grafana Helm chart automatically imports dashboards via ConfigMap
   - Dashboards are placed in the "OpenTelemetry Demo" folder

2. **Datasource Configuration:**
   - **Prometheus** is configured as the default datasource
   - **CloudWatch** is configured as a secondary datasource for log queries
   - Datasources are configured via `values-grafana.yaml`

3. **Auto-Import Process:**
   - ConfigMap `grafana-dashboards` contains dashboard JSON files
   - Grafana init container copies dashboards to `/var/lib/grafana/dashboards/otel-demo/`
   - Grafana scans this directory on startup and imports dashboards

#### Accessing Grafana

```bash
# Port-forward to Grafana UI
kubectl port-forward -n observability svc/observability-grafana 3000:80

# Open in browser: http://localhost:3000
# Default credentials (retrieve from secret):
# Username: admin
# Password: (run: kubectl get secret grafana-admin-credentials -n observability -o jsonpath='{.data.admin-password}' | base64 -d)
```

### CloudWatch Logs

CloudWatch Logs aggregates logs from all microservices for:
- **Centralized log storage**
- **Log-based queries** using CloudWatch Logs Insights
- **Trace correlation** using trace IDs in logs
- **Log-based metrics** and alarms

#### Where to Find CloudWatch Logs

1. **Log Groups:**
   - Pattern: `/aws/eks/<cluster-name>/otel-demo/<service-name>`
   - Example: `/aws/eks/otel-demo-cluster/otel-demo/frontend`

2. **Access Methods:**
   - **AWS Console:** CloudWatch → Logs → Log groups
   - **AWS CLI:**
     ```bash
     aws logs describe-log-groups --log-group-name-prefix "/aws/eks/otel-demo-cluster"
     ```
   - **CloudWatch Logs Insights:** Query interface in AWS Console

3. **Sample Queries:**
   - See `cloudwatch/sample-query.md` for ready-to-use queries
   - Queries include error detection, latency analysis, and trace correlation

## 🚨 Alerting

### How Alerts Are Triggered

1. **Alert Evaluation:**
   - Prometheus evaluates alert rules every 30 seconds (configurable)
   - Rules are defined in `prometheus/alert-rules.yaml` as PrometheusRule CRDs
   - Prometheus checks if alert conditions are met

2. **Alert States:**
   - **Pending:** Condition met but `for` duration not reached
   - **Firing:** Condition met for required duration
   - **Resolved:** Condition no longer met

3. **Alert Routing:**
   - Prometheus sends alerts to Alertmanager
   - Alertmanager routes alerts based on severity and labels
   - Routes configured in `values-prometheus.yaml`

4. **Notification Channels:**
   - **SNS Integration:** Configured for critical alerts (see `values-prometheus.yaml`)
   - **Webhooks:** Can be configured for custom integrations
   - **Email:** Can be configured via SMTP settings

### Alert Rules

Three main alert categories:

1. **High Latency** (`HighLatency`)
   - P95 latency > 500ms for 5 minutes
   - PromQL: `histogram_quantile(0.95, sum(rate(otel_demo_request_duration_seconds_bucket[5m])) by (le, service_name)) > 0.5`

2. **High Error Rate** (`HighErrorRate`)
   - Error rate > 5% for 5 minutes
   - PromQL: `(sum(rate(otel_demo_http_requests_total{status_code=~"5.."}[5m])) by (service_name) / sum(rate(otel_demo_http_requests_total[5m])) by (service_name)) > 0.05`

3. **Pod CrashLoopBackOff** (`PodCrashLoop`)
   - Pod in CrashLoopBackOff for 2 minutes
   - PromQL: `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", namespace="otel-demo"} == 1`

### Accessing Alertmanager

```bash
# Port-forward to Alertmanager UI
kubectl port-forward -n observability svc/observability-prometheus-kube-prom-alertmanager 9093:9093

# Open in browser: http://localhost:9093
```

## 📈 Dashboards

### Available Dashboards

1. **Latency Dashboard** (`latency.json`)
   - P95/P99 latency trends
   - Average latency by service
   - Latency distribution heatmap
   - Request rate

2. **Error Rate Dashboard** (`error-rate.json`)
   - Error rate percentage by service
   - HTTP status code breakdown
   - Error trends over time
   - Error count statistics

3. **Resource Utilization Dashboard** (`resource-util.json`)
   - CPU usage by pod
   - Memory usage by pod
   - CPU/Memory usage vs limits
   - Network and disk I/O

### Dashboard Features

- **Auto-refresh:** 30-second intervals
- **Time range:** Default 1 hour, adjustable
- **Service filtering:** Template variables for service selection
- **Alert annotations:** Visual markers when alerts fire
- **Threshold indicators:** Color-coded warnings and critical states

## 📝 Sample CloudWatch Query

Here's a sample query to find high-latency requests:

```sql
fields @timestamp, service_name, latency_ms, method, path, trace_id, status_code
| filter latency_ms > 500
| sort latency_ms desc
| limit 50
```

**Sample Output:**

| timestamp | service_name | latency_ms | method | path | trace_id | status_code |
|-----------|--------------|------------|--------|------|----------|-------------|
| 2024-12-07T21:36:20.123Z | checkout | 1250 | POST | /api/checkout | 4bf92f3577b34da6a3ce929d0e0e4736 | 200 |
| 2024-12-07T21:35:15.789Z | product-catalog | 980 | GET | /api/products | 7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f | 200 |
| 2024-12-07T21:34:30.456Z | recommendation | 750 | GET | /api/recommendations | 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d | 200 |

See `cloudwatch/sample-query.md` for more queries.

## 🔧 Configuration

### Prometheus Configuration

- **Values file:** `prometheus/values-prometheus.yaml`
- **Key settings:**
  - Retention: 30 days
  - Scrape interval: 15 seconds
  - Storage: 50Gi PVC
  - Alertmanager: Enabled with SNS integration

### Grafana Configuration

- **Values file:** `grafana/values-grafana.yaml`
- **Key settings:**
  - Admin credentials: Kubernetes secret
  - Datasources: Prometheus (default), CloudWatch
  - Dashboards: Auto-imported from ConfigMap
  - Service type: LoadBalancer (for AWS EKS)

### CloudWatch Configuration

- **Configuration guide:** `cloudwatch/cw-logs-config.md`
- **Log groups:** Per-service log groups
- **Retention:** 30 days (configurable)
- **Format:** Structured JSON with trace IDs

## 📚 Runbook

The runbook (`runbook/alert-runbook.md`) provides step-by-step procedures for:

- **Diagnosing alerts:** kubectl commands, log analysis, trace investigation
- **Resolving issues:** Scaling, restarting, configuration fixes
- **Prevention:** Best practices and recommendations

Each alert type includes:
- What causes the alert
- Diagnosis steps
- Resolution procedures
- Prevention strategies

## 🖼️ Screenshots

_Add screenshots here after deployment:_

### Dashboard Screenshots
- [ ] Latency Dashboard
- [ ] Error Rate Dashboard
- [ ] Resource Utilization Dashboard

### Alert Screenshots
- [ ] High Latency Alert in Alertmanager
- [ ] High Error Rate Alert
- [ ] Pod CrashLoop Alert

### CloudWatch Screenshots
- [ ] CloudWatch Logs Insights query results
- [ ] Log group structure
- [ ] Sample log entries with trace IDs

### Grafana Screenshots
- [ ] Grafana login page
- [ ] Dashboard list
- [ ] Datasource configuration

### Prometheus Screenshots
- [ ] Prometheus targets page
- [ ] Alert rules page
- [ ] Query results

## 🔍 Troubleshooting

### Prometheus Not Scraping

1. Check Prometheus targets:
   ```bash
   # Port-forward and check Status > Targets in Prometheus UI
   kubectl port-forward -n observability svc/observability-prometheus-kube-prom-prometheus 9090:9090
   ```

2. Verify service discovery:
   ```bash
   kubectl get pods -n otel-demo --show-labels
   # Ensure pods have prometheus.io/scrape: "true" annotation
   ```

### Grafana Dashboards Not Showing

1. Check dashboard ConfigMap:
   ```bash
   kubectl get configmap grafana-dashboards -n observability
   kubectl describe configmap grafana-dashboards -n observability
   ```

2. Check Grafana logs:
   ```bash
   kubectl logs -n observability -l app.kubernetes.io/name=grafana
   ```

### CloudWatch Logs Not Appearing

1. Check Fluent Bit pods:
   ```bash
   kubectl get pods -n kube-system -l app=fluent-bit
   kubectl logs -n kube-system -l app=fluent-bit
   ```

2. Verify IAM permissions:
   ```bash
   # Check service account annotations
   kubectl get sa -n kube-system fluent-bit -o yaml
   ```

## 📖 Additional Resources

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Documentation](https://grafana.com/docs/)
- [CloudWatch Logs Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/)
- [OpenTelemetry Collector Documentation](https://opentelemetry.io/docs/collector/)
- [Kubernetes Monitoring Guide](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/)

## 🤝 Contributing

When adding new dashboards or alerts:

1. **Dashboards:** Add JSON files to `grafana/dashboards/`
2. **Alerts:** Add rules to `prometheus/alert-rules.yaml`
3. **Runbook:** Update `runbook/alert-runbook.md` with new procedures
4. **Documentation:** Update this README with new features

## 📄 License

This observability configuration is part of the OpenTelemetry Demo project and follows the same license (Apache 2.0).

---

**Last Updated:** December 2024  
**Maintained by:** ENPM818R Observability Team

