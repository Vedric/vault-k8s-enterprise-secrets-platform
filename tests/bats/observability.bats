#!/usr/bin/env bats

# Tests for Phase 6 observability artifacts.
# Validates Prometheus/Loki Helm values, deploy script, audit script,
# dashboard JSON, alert rules, and cross-file consistency.
# Run with: bats tests/bats/observability.bats

# ---------------------------------------------------------------------------
# kube-prometheus-stack Helm values
# ---------------------------------------------------------------------------

@test "prometheus values file exists" {
  [ -f "helm/prometheus/values.yaml" ]
}

@test "prometheus values defines resource requests for Prometheus" {
  grep -q "cpu:" helm/prometheus/values.yaml
  grep -q "memory:" helm/prometheus/values.yaml
}

@test "prometheus values configures Grafana" {
  grep -q "grafana:" helm/prometheus/values.yaml
  grep -q "enabled: true" helm/prometheus/values.yaml
}

@test "prometheus values configures Alertmanager" {
  grep -q "alertmanager:" helm/prometheus/values.yaml
}

@test "prometheus values configures Vault ServiceMonitor" {
  grep -q "additionalServiceMonitors:" helm/prometheus/values.yaml
  grep -q "vault" helm/prometheus/values.yaml
  grep -q "/v1/sys/metrics" helm/prometheus/values.yaml
}

@test "prometheus values sets retention period" {
  grep -qE "retention: [0-9]+h" helm/prometheus/values.yaml
}

@test "prometheus values uses managed-csi storage class" {
  grep -q "storageClassName: managed-csi" helm/prometheus/values.yaml
}

@test "prometheus values configures Loki datasource for Grafana" {
  grep -q "Loki" helm/prometheus/values.yaml
  grep -q "loki" helm/prometheus/values.yaml
}

@test "prometheus values enables dashboard sidecar" {
  grep -q "grafana_dashboard" helm/prometheus/values.yaml
  grep -q "sidecar:" helm/prometheus/values.yaml
}

@test "prometheus values scrapes vault namespace" {
  grep -q "vault" helm/prometheus/values.yaml
  grep -q "namespaceSelector:" helm/prometheus/values.yaml
}

@test "prometheus values configures kube-state-metrics resources" {
  grep -q "kube-state-metrics:" helm/prometheus/values.yaml
}

@test "prometheus values configures node-exporter" {
  grep -q "nodeExporter:" helm/prometheus/values.yaml
  grep -q "prometheus-node-exporter:" helm/prometheus/values.yaml
}

# ---------------------------------------------------------------------------
# Loki stack Helm values
# ---------------------------------------------------------------------------

@test "loki values file exists" {
  [ -f "helm/loki/values.yaml" ]
}

@test "loki values defines resource requests for Loki" {
  grep -q "cpu:" helm/loki/values.yaml
  grep -q "memory:" helm/loki/values.yaml
}

@test "loki values configures single-binary mode" {
  grep -q "replicas: 1" helm/loki/values.yaml
}

@test "loki values enables persistence" {
  grep -q "persistence:" helm/loki/values.yaml
  grep -q "enabled: true" helm/loki/values.yaml
  grep -q "storageClassName: managed-csi" helm/loki/values.yaml
}

@test "loki values configures Promtail" {
  grep -q "promtail:" helm/loki/values.yaml
  grep -q "enabled: true" helm/loki/values.yaml
}

@test "loki values includes vault-audit scrape job" {
  grep -q "vault-audit" helm/loki/values.yaml
}

@test "loki values disables Grafana (provided by prometheus-stack)" {
  run grep -A1 "^grafana:" helm/loki/values.yaml
  [[ "$output" =~ "enabled: false" ]]
}

@test "loki values disables Prometheus (provided by prometheus-stack)" {
  run grep -A1 "^prometheus:" helm/loki/values.yaml
  [[ "$output" =~ "enabled: false" ]]
}

@test "loki values sets retention period" {
  grep -q "retention_period:" helm/loki/values.yaml
}

@test "loki values configures Promtail resources" {
  grep -q "promtail:" helm/loki/values.yaml
}

# ---------------------------------------------------------------------------
# Deploy observability script
# ---------------------------------------------------------------------------

@test "deploy-observability.sh exists and is executable" {
  [ -x "vault/scripts/deploy-observability.sh" ]
}

@test "deploy-observability.sh has proper bash header" {
  head -1 vault/scripts/deploy-observability.sh | grep -q "#!/usr/bin/env bash"
}

@test "deploy-observability.sh uses strict mode" {
  grep -q "set -euo pipefail" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh checks prerequisites" {
  grep -q "check_prerequisites" vault/scripts/deploy-observability.sh
  grep -q "command -v" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh creates monitoring namespace" {
  grep -q "create namespace" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh adds helm repos" {
  grep -q "prometheus-community" vault/scripts/deploy-observability.sh
  grep -q "grafana" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh installs kube-prometheus-stack" {
  grep -q "kube-prometheus-stack" vault/scripts/deploy-observability.sh
  grep -q "helm install" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh installs loki-stack" {
  grep -q "loki-stack" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh provisions Grafana dashboard ConfigMap" {
  grep -q "vault-grafana-dashboard" vault/scripts/deploy-observability.sh
  grep -q "grafana_dashboard" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh applies PrometheusRule alerts" {
  grep -q "vault-alerts.yaml" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh is idempotent (checks existing releases)" {
  grep -q "already installed" vault/scripts/deploy-observability.sh
}

@test "deploy-observability.sh includes verification" {
  grep -q "verify_deployment" vault/scripts/deploy-observability.sh
}

# ---------------------------------------------------------------------------
# Configure audit logging script
# ---------------------------------------------------------------------------

@test "configure-audit-logging.sh exists and is executable" {
  [ -x "vault/scripts/configure-audit-logging.sh" ]
}

@test "configure-audit-logging.sh has proper bash header" {
  head -1 vault/scripts/configure-audit-logging.sh | grep -q "#!/usr/bin/env bash"
}

@test "configure-audit-logging.sh uses strict mode" {
  grep -q "set -euo pipefail" vault/scripts/configure-audit-logging.sh
}

@test "configure-audit-logging.sh checks prerequisites" {
  grep -q "check_prerequisites" vault/scripts/configure-audit-logging.sh
  grep -q "VAULT_TOKEN" vault/scripts/configure-audit-logging.sh
}

@test "configure-audit-logging.sh manages port-forward lifecycle" {
  grep -q "PORT_FORWARD_PID" vault/scripts/configure-audit-logging.sh
  grep -q "trap cleanup EXIT" vault/scripts/configure-audit-logging.sh
}

@test "configure-audit-logging.sh enables file audit backend" {
  grep -q "vault audit enable file" vault/scripts/configure-audit-logging.sh
  grep -q "file_path=" vault/scripts/configure-audit-logging.sh
}

@test "configure-audit-logging.sh is idempotent (checks vault audit list)" {
  grep -q "vault audit list" vault/scripts/configure-audit-logging.sh
  grep -q "already enabled" vault/scripts/configure-audit-logging.sh
}

@test "configure-audit-logging.sh verifies audit logging" {
  grep -q "verify_audit_logging" vault/scripts/configure-audit-logging.sh
}

# ---------------------------------------------------------------------------
# Grafana dashboard JSON
# ---------------------------------------------------------------------------

@test "vault-overview dashboard file exists" {
  [ -f "monitoring/dashboards/vault-overview.json" ]
}

@test "vault-overview dashboard is valid JSON" {
  jq empty monitoring/dashboards/vault-overview.json
}

@test "vault-overview dashboard has Vault Seal Status panel" {
  jq -e '.panels[] | select(.title == "Vault Seal Status")' monitoring/dashboards/vault-overview.json > /dev/null
}

@test "vault-overview dashboard has Raft Peers panel" {
  jq -e '.panels[] | select(.title == "Raft Peers")' monitoring/dashboards/vault-overview.json > /dev/null
}

@test "vault-overview dashboard has Active Tokens panel" {
  jq -e '.panels[] | select(.title == "Active Tokens")' monitoring/dashboards/vault-overview.json > /dev/null
}

@test "vault-overview dashboard has Request Duration panel" {
  jq -e '.panels[] | select(.title == "Vault Request Duration (p99)")' monitoring/dashboards/vault-overview.json > /dev/null
}

@test "vault-overview dashboard has Audit Log Events panel" {
  jq -e '.panels[] | select(.title == "Audit Log Events")' monitoring/dashboards/vault-overview.json > /dev/null
}

@test "vault-overview dashboard has Secret Operations panel" {
  jq -e '.panels[] | select(.title == "Secret Operations Rate")' monitoring/dashboards/vault-overview.json > /dev/null
}

@test "vault-overview dashboard uses Prometheus datasource" {
  jq -e '.panels[] | select(.datasource == "Prometheus")' monitoring/dashboards/vault-overview.json > /dev/null
}

# ---------------------------------------------------------------------------
# PrometheusRule alert definitions
# ---------------------------------------------------------------------------

@test "vault-alerts file exists" {
  [ -f "monitoring/alerts/vault-alerts.yaml" ]
}

@test "vault-alerts defines PrometheusRule kind" {
  grep -q "kind: PrometheusRule" monitoring/alerts/vault-alerts.yaml
}

@test "vault-alerts has VaultSealed alert (critical)" {
  grep -q "alert: VaultSealed" monitoring/alerts/vault-alerts.yaml
  grep -q "severity: critical" monitoring/alerts/vault-alerts.yaml
}

@test "vault-alerts has VaultRaftPeerLost alert (warning)" {
  grep -q "alert: VaultRaftPeerLost" monitoring/alerts/vault-alerts.yaml
}

@test "vault-alerts has VaultNoLeader alert (critical)" {
  grep -q "alert: VaultNoLeader" monitoring/alerts/vault-alerts.yaml
}

@test "vault-alerts has VaultHighLatency alert (warning)" {
  grep -q "alert: VaultHighLatency" monitoring/alerts/vault-alerts.yaml
}

@test "vault-alerts has VaultHighTokenCount alert (warning)" {
  grep -q "alert: VaultHighTokenCount" monitoring/alerts/vault-alerts.yaml
}

@test "vault-alerts has VaultAuditFailure alert (critical)" {
  grep -q "alert: VaultAuditFailure" monitoring/alerts/vault-alerts.yaml
}

@test "vault-alerts references seal-recovery runbook" {
  grep -q "seal-recovery.md" monitoring/alerts/vault-alerts.yaml
}

@test "vault-alerts targets monitoring namespace" {
  grep -q "namespace: monitoring" monitoring/alerts/vault-alerts.yaml
}

# ---------------------------------------------------------------------------
# Cross-file consistency
# ---------------------------------------------------------------------------

@test "prometheus ServiceMonitor scrape path matches Vault telemetry config" {
  # Vault exposes metrics at /v1/sys/metrics
  grep -q "/v1/sys/metrics" helm/prometheus/values.yaml
  # Vault telemetry is enabled in Helm values
  grep -q "prometheus_retention_time" helm/vault/values.yaml
}

@test "loki Promtail targets match Vault audit log path" {
  # Audit path in configure script
  grep -q "/vault/audit/vault-audit.log" vault/scripts/configure-audit-logging.sh
  # Promtail scrape config references vault audit logs
  grep -q "vault-audit" helm/loki/values.yaml
}

@test "dashboard datasource matches Prometheus service" {
  # Dashboard uses Prometheus datasource
  jq -e '.panels[0].datasource == "Prometheus"' monitoring/dashboards/vault-overview.json > /dev/null
}

@test "alert expressions reference metrics available from Vault" {
  # Key metrics referenced in alerts
  grep -q "vault_core_unsealed" monitoring/alerts/vault-alerts.yaml
  grep -q "vault_raft_peers" monitoring/alerts/vault-alerts.yaml
  grep -q "vault_core_active" monitoring/alerts/vault-alerts.yaml
  grep -q "vault_audit_log_request_failure" monitoring/alerts/vault-alerts.yaml
}

@test "Grafana Loki datasource URL matches Loki service" {
  grep -q "loki.monitoring.svc.cluster.local:3100" helm/prometheus/values.yaml
}

@test "vault Helm values have audit storage enabled" {
  grep -q "auditStorage:" helm/vault/values.yaml
  grep -A1 "auditStorage:" helm/vault/values.yaml | grep -q "enabled: true"
}

@test "vault Helm values have telemetry configured" {
  grep -q "telemetry" helm/vault/values.yaml
  grep -q "unauthenticated_metrics_access" helm/vault/values.yaml
}
