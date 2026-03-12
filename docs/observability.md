# Observability Architecture

## Overview

The observability stack provides three pillars of monitoring for the Vault cluster:

- **Metrics**: Prometheus scrapes Vault telemetry and Kubernetes system metrics
- **Logs**: Vault audit logs flow through Promtail to Loki for centralized querying
- **Alerts**: PrometheusRule definitions trigger on critical Vault health conditions

All components run in the `monitoring` namespace.

## Architecture

```
                                 Grafana
                               /        \
                    Prometheus            Loki
                    (metrics)            (logs)
                        |                  |
                 ServiceMonitor        Promtail
                        |              (DaemonSet)
                        |                  |
        +---------------+--------+    +----+-----+
        |               |        |    |          |
   vault-0          vault-1  vault-2  Pod logs   Audit logs
   :8200/v1/        :8200    :8200    (/var/     (/vault/audit/
   sys/metrics                        log/pods)  vault-audit.log)
```

## Metrics Pipeline

### Prometheus

Deployed via `kube-prometheus-stack`, Prometheus scrapes Vault metrics every 30 seconds.

**Vault telemetry endpoint**: `/v1/sys/metrics?format=prometheus`

Vault exposes metrics with `unauthenticated_metrics_access = true` in the listener telemetry
block, so Prometheus does not need a Vault token to scrape. Key metrics include:

| Metric | Type | Description |
|--------|------|-------------|
| `vault_core_unsealed` | Gauge | 1 if unsealed, 0 if sealed |
| `vault_core_active` | Gauge | 1 if active leader |
| `vault_raft_peers` | Gauge | Number of Raft cluster peers |
| `vault_token_count` | Gauge | Active token count |
| `vault_secret_kv_count` | Counter | KV secret operations |
| `vault_core_handle_request_duration_milliseconds` | Histogram | Request latency |
| `vault_audit_log_request_count` | Counter | Audit log events written |
| `vault_audit_log_request_failure` | Counter | Failed audit writes |

### ServiceMonitor

The Vault ServiceMonitor is defined in the kube-prometheus-stack values:

```yaml
additionalServiceMonitors:
  - name: vault
    namespaceSelector:
      matchNames: [vault]
    endpoints:
      - port: http
        path: /v1/sys/metrics
        params:
          format: [prometheus]
        interval: 30s
```

## Log Pipeline

### Vault Audit Logging

Vault writes JSON-formatted audit events to `/vault/audit/vault-audit.log` on the
audit storage PVC (5Gi, provisioned by the Vault Helm chart).

Enable with:

```bash
make configure-audit
```

Each audit event contains the full request/response including:
- Authentication details (accessor, not token)
- Request path and operation
- Response status
- Timestamp and client IP

Vault blocks all operations if audit logging fails -- this ensures compliance
but means audit backend health is critical.

### Promtail

Promtail runs as a DaemonSet and collects:

1. **Standard pod logs**: All container stdout/stderr from `/var/log/pods/`
2. **Vault audit logs**: Matched by path pattern `vault_vault-*/**/vault-audit.log`

Labels applied to audit logs:
- `job=vault-audit`
- `namespace=vault`
- `pod=vault-*`

### Loki

Loki stores logs in single-binary mode with:
- TSDB index with 24h period
- Filesystem chunk storage
- 72h retention with compactor
- 2Gi PVC on managed-csi

## Grafana Dashboards

### Vault Cluster Overview

The pre-built dashboard (`monitoring/dashboards/vault-overview.json`) is auto-provisioned
via the Grafana sidecar. It includes six panels:

| Panel | Type | Metric/Query |
|-------|------|-------------|
| Vault Seal Status | Stat | `vault_core_unsealed` (green=unsealed, red=sealed) |
| Raft Peers | Stat | `vault_raft_peers` |
| Active Tokens | Stat | `vault_token_count` |
| Secret Operations Rate | Time series | `rate(vault_secret_kv_count[5m])` |
| Request Duration (p99) | Time series | `histogram_quantile(0.99, ...)` |
| Audit Log Events | Time series | `rate(vault_audit_log_request_count[5m])` |

### Access Grafana

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000
# Default credentials: admin / prom-operator
```

Datasources:
- **Prometheus** (default): Vault and Kubernetes metrics
- **Loki**: Container and audit logs

## Alert Rules

Six PrometheusRule alerts are defined in `monitoring/alerts/vault-alerts.yaml`:

| Alert | Severity | Condition | For |
|-------|----------|-----------|-----|
| VaultSealed | Critical | `vault_core_unsealed == 0` | 1m |
| VaultNoLeader | Critical | `vault_core_active == 0` | 2m |
| VaultAuditFailure | Critical | `vault_audit_log_request_failure > 0` | 1m |
| VaultRaftPeerLost | Warning | `vault_raft_peers < 3` | 5m |
| VaultHighLatency | Warning | p99 > 500ms | 10m |
| VaultHighTokenCount | Warning | `vault_token_count > 10000` | 5m |

Runbook references:
- VaultSealed -> [docs/runbooks/seal-recovery.md](runbooks/seal-recovery.md)
- VaultAuditFailure -> Check audit backend storage and Vault logs

## Troubleshooting

### Prometheus not scraping Vault

1. Check ServiceMonitor exists: `kubectl get servicemonitor -n monitoring vault`
2. Verify Vault service labels match: `kubectl get svc -n vault vault --show-labels`
3. Test metrics endpoint: `kubectl exec -n vault vault-0 -- wget -qO- http://localhost:8200/v1/sys/metrics?format=prometheus | head`
4. Check Prometheus targets: port-forward Prometheus and open `/targets`

### Audit logs not appearing in Loki

1. Verify audit backend: `vault audit list`
2. Check log file exists: `kubectl exec -n vault vault-0 -- ls -la /vault/audit/`
3. Check Promtail logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=20`
4. Query Loki: In Grafana, use `{job="vault-audit"}` in Loki explore

### Grafana dashboard shows no data

1. Verify Prometheus datasource: Grafana -> Configuration -> Data Sources -> Test
2. Check Prometheus has Vault target in UP state
3. Ensure Vault is receiving requests (idle cluster has no metrics to display)
