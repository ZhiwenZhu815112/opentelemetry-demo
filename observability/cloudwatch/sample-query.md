# CloudWatch Logs Insights Sample Queries

This document provides sample CloudWatch Logs Insights queries for analyzing OpenTelemetry Demo application logs.

## Prerequisites

- Logs must be in CloudWatch Log Groups
- Log format should be structured JSON
- Log groups should follow the naming pattern: `/aws/eks/otel-demo-cluster/otel-demo/{service-name}`

## Sample Query 1: Service Errors

Find all errors across all services in the last hour:

```sql
fields @timestamp, service_name, level, message, trace_id, status_code
| filter level = "ERROR" or level = "FATAL" or status_code >= 500
| sort @timestamp desc
| limit 100
```

**Sample Output:**

| timestamp | service_name | level | message | trace_id | status_code |
|-----------|--------------|-------|---------|----------|-------------|
| 2024-12-07T21:36:15.123Z | checkout | ERROR | Payment processing failed | 4bf92f3577b34da6a3ce929d0e0e4736 | 500 |
| 2024-12-07T21:35:42.789Z | payment | ERROR | Connection timeout to payment gateway | 7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f | 503 |
| 2024-12-07T21:34:18.456Z | cart | ERROR | Redis connection failed | 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d | 500 |

## Sample Query 2: High Latency Requests

Find requests with latency > 500ms in the last 30 minutes:

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

## Sample Query 3: Error Rate by Service

Calculate error rate percentage per service over the last hour:

```sql
fields @timestamp, service_name, status_code
| filter status_code >= 500
| stats count() as error_count by service_name
| sort error_count desc
```

**Sample Output:**

| service_name | error_count |
|--------------|-------------|
| checkout | 45 |
| payment | 23 |
| cart | 12 |

## Sample Query 4: Trace Correlation

Find all logs for a specific trace ID:

```sql
fields @timestamp, service_name, level, message, span_id, latency_ms, status_code
| filter trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
| sort @timestamp asc
```

**Sample Output:**

| timestamp | service_name | level | message | span_id | latency_ms | status_code |
|-----------|--------------|-------|---------|---------|------------|-------------|
| 2024-12-07T21:36:00.123Z | frontend | INFO | Request received | 00f067aa0ba902b7 | 0 | 200 |
| 2024-12-07T21:36:00.145Z | checkout | INFO | Processing checkout | 1a2b3c4d5e6f7a8b | 245 | 200 |
| 2024-12-07T21:36:00.234Z | cart | INFO | Retrieving cart | 2b3c4d5e6f7a8b9c | 89 | 200 |
| 2024-12-07T21:36:00.389Z | payment | INFO | Processing payment | 3c4d5e6f7a8b9c0d | 155 | 200 |
| 2024-12-07T21:36:00.544Z | shipping | INFO | Calculating shipping | 4d5e6f7a8b9c0d1e | 155 | 200 |

## Sample Query 5: P95 Latency by Service

Calculate 95th percentile latency per service:

```sql
fields @timestamp, service_name, latency_ms
| stats percentile(latency_ms, 95) as p95_latency by service_name
| sort p95_latency desc
```

**Sample Output:**

| service_name | p95_latency |
|--------------|-------------|
| checkout | 850 |
| product-catalog | 420 |
| recommendation | 380 |
| cart | 250 |
| payment | 180 |

## Sample Query 6: Request Volume by Endpoint

Count requests per endpoint in the last hour:

```sql
fields @timestamp, service_name, method, path
| stats count() as request_count by service_name, method, path
| sort request_count desc
| limit 20
```

**Sample Output:**

| service_name | method | path | request_count |
|--------------|--------|------|---------------|
| frontend | GET | / | 1250 |
| product-catalog | GET | /api/products | 980 |
| cart | POST | /api/cart/add | 450 |
| checkout | POST | /api/checkout | 320 |

## Sample Query 7: Failed Payment Transactions

Find all failed payment transactions with details:

```sql
fields @timestamp, service_name, message, trace_id, user_id, amount, error_message
| filter service_name = "payment" and (status_code >= 500 or level = "ERROR")
| sort @timestamp desc
| limit 50
```

**Sample Output:**

| timestamp | service_name | message | trace_id | user_id | amount | error_message |
|-----------|--------------|---------|----------|---------|--------|---------------|
| 2024-12-07T21:36:15.123Z | payment | Payment processing failed | 4bf92f3577b34da6a3ce929d0e0e4736 | user-123 | 99.99 | Connection timeout |
| 2024-12-07T21:35:42.789Z | payment | Payment gateway error | 7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f | user-456 | 149.50 | Invalid credentials |

## Sample Query 8: Service Health Summary

Get a health summary for all services:

```sql
fields @timestamp, service_name, status_code, latency_ms
| stats 
    count() as total_requests,
    sum(case status_code >= 500 then 1 else 0 end) as errors,
    avg(latency_ms) as avg_latency,
    percentile(latency_ms, 95) as p95_latency,
    percentile(latency_ms, 99) as p99_latency
    by service_name
| sort total_requests desc
```

**Sample Output:**

| service_name | total_requests | errors | avg_latency | p95_latency | p99_latency |
|--------------|----------------|--------|-------------|-------------|-------------|
| frontend | 1250 | 5 | 120 | 350 | 580 |
| product-catalog | 980 | 2 | 180 | 420 | 650 |
| checkout | 320 | 8 | 280 | 850 | 1200 |
| cart | 450 | 1 | 95 | 250 | 380 |

## Sample Query 9: User Activity Tracking

Track user activity across services:

```sql
fields @timestamp, service_name, user_id, method, path, status_code, latency_ms
| filter user_id = "user-123"
| sort @timestamp asc
| limit 100
```

## Sample Query 10: Anomaly Detection - Unusual Error Patterns

Find services with sudden spike in errors:

```sql
fields @timestamp, service_name, status_code
| filter status_code >= 500
| stats count() as error_count by bin(5m), service_name
| sort error_count desc
```

## Tips for Using CloudWatch Logs Insights

1. **Time Range**: Always specify a time range to improve query performance
2. **Limit Results**: Use `limit` to avoid overwhelming results
3. **Use Filters Early**: Apply filters early in the query to reduce data scanned
4. **Save Queries**: Save frequently used queries for quick access
5. **Create Dashboards**: Use saved queries to create CloudWatch dashboards
6. **Set Alarms**: Create metric filters from queries to trigger alarms

## Creating Metric Filters from Queries

Convert queries to metric filters for alerting:

```bash
aws logs put-metric-filter \
  --log-group-name /aws/eks/otel-demo-cluster/otel-demo/checkout \
  --filter-name HighErrorRate \
  --filter-pattern "[timestamp, level=ERROR, ...]" \
  --metric-transformations \
    metricName=ErrorCount,metricNamespace=OTelDemo,metricValue=1
```

## Integration with Prometheus

You can export CloudWatch metrics to Prometheus using the CloudWatch Exporter:

```yaml
# prometheus-cloudwatch-exporter config
region: us-east-1
metrics:
  - aws_namespace: OTelDemo
    aws_metric_name: ErrorCount
    aws_dimensions: [ServiceName]
```

