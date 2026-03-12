#!/usr/bin/env bash
set -euo pipefail

# deploy-observability.sh -- Deploy monitoring stack (Prometheus, Grafana, Loki)
#
# This script deploys the kube-prometheus-stack and Loki stack into the
# monitoring namespace, provisions the Vault Grafana dashboard, and applies
# PrometheusRule alert definitions.
#
# Prerequisites:
#   - kubectl must be configured for the target AKS cluster
#   - Helm 3.x installed
#   - Vault must be deployed (ServiceMonitor targets the vault service)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROMETHEUS_VALUES="${REPO_ROOT}/helm/prometheus/values.yaml"
LOKI_VALUES="${REPO_ROOT}/helm/loki/values.yaml"
DASHBOARD_FILE="${REPO_ROOT}/monitoring/dashboards/vault-overview.json"
ALERTS_FILE="${REPO_ROOT}/monitoring/alerts/vault-alerts.yaml"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-65.8.1}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-2.10.2}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Deploy the observability stack (Prometheus, Grafana, Loki, Promtail).

Options:
  -n, --namespace      Monitoring namespace (default: monitoring)
  -h, --help           Show this help message

Environment variables:
  MONITORING_NAMESPACE      Kubernetes namespace for monitoring (default: monitoring)
  PROMETHEUS_CHART_VERSION  kube-prometheus-stack chart version (default: 65.8.1)
  LOKI_CHART_VERSION        loki-stack chart version (default: 2.10.2)

Examples:
  $(basename "$0")
  $(basename "$0") --namespace monitoring
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) MONITORING_NAMESPACE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Error: unknown option $1" >&2; usage ;;
  esac
done

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2
  exit 1
}

check_prerequisites() {
  local missing=()
  command -v helm >/dev/null 2>&1    || missing+=("helm")
  command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
  command -v jq >/dev/null 2>&1      || missing+=("jq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
  fi

  if [[ ! -f "${PROMETHEUS_VALUES}" ]]; then
    error "Prometheus values file not found: ${PROMETHEUS_VALUES}"
  fi

  if [[ ! -f "${LOKI_VALUES}" ]]; then
    error "Loki values file not found: ${LOKI_VALUES}"
  fi
}

create_namespace() {
  log "Creating namespace '${MONITORING_NAMESPACE}'..."
  kubectl create namespace "${MONITORING_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
}

add_helm_repos() {
  log "Adding Helm repositories..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community grafana
}

deploy_prometheus_stack() {
  if helm list -n "${MONITORING_NAMESPACE}" -o json | jq -e '.[] | select(.name=="kube-prometheus-stack")' > /dev/null 2>&1; then
    log "kube-prometheus-stack already installed. Skipping."
    return 0
  fi

  log "Installing kube-prometheus-stack (chart v${PROMETHEUS_CHART_VERSION})..."
  helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace "${MONITORING_NAMESPACE}" \
    --version "${PROMETHEUS_CHART_VERSION}" \
    -f "${PROMETHEUS_VALUES}"

  log "kube-prometheus-stack installed."
}

deploy_loki_stack() {
  if helm list -n "${MONITORING_NAMESPACE}" -o json | jq -e '.[] | select(.name=="loki-stack")' > /dev/null 2>&1; then
    log "loki-stack already installed. Skipping."
    return 0
  fi

  log "Installing loki-stack (chart v${LOKI_CHART_VERSION})..."
  helm install loki-stack grafana/loki-stack \
    --namespace "${MONITORING_NAMESPACE}" \
    --version "${LOKI_CHART_VERSION}" \
    -f "${LOKI_VALUES}"

  log "loki-stack installed."
}

provision_dashboard() {
  if [[ ! -f "${DASHBOARD_FILE}" ]]; then
    log "Dashboard file not found. Skipping provisioning."
    return 0
  fi

  log "Provisioning Vault dashboard as ConfigMap..."
  kubectl create configmap vault-grafana-dashboard \
    --namespace "${MONITORING_NAMESPACE}" \
    --from-file=vault-overview.json="${DASHBOARD_FILE}" \
    --dry-run=client -o yaml | \
    kubectl label --local -f - grafana_dashboard=1 -o yaml | \
    kubectl apply -f -

  log "Dashboard ConfigMap created with grafana_dashboard label."
}

apply_alert_rules() {
  if [[ ! -f "${ALERTS_FILE}" ]]; then
    log "Alert rules file not found. Skipping."
    return 0
  fi

  log "Applying PrometheusRule alert definitions..."
  kubectl apply -f "${ALERTS_FILE}"
  log "Alert rules applied."
}

wait_for_pods() {
  log "Waiting for monitoring pods to be ready..."
  local timeout=180
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    local not_ready
    not_ready=$(kubectl get pods -n "${MONITORING_NAMESPACE}" --no-headers 2>/dev/null | \
      grep -cvE "Running|Completed" || echo "0")

    if [[ "${not_ready}" -eq 0 ]]; then
      local total
      total=$(kubectl get pods -n "${MONITORING_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
      if [[ "${total}" -gt 0 ]]; then
        log "All ${total} monitoring pods are ready."
        return 0
      fi
    fi
    log "  Waiting... (${elapsed}s elapsed, ${not_ready} pods not ready)"
    sleep 10
    elapsed=$((elapsed + 10))
  done

  error "Timed out waiting for monitoring pods after ${timeout}s."
}

verify_deployment() {
  log "Verifying deployment..."

  # Check Prometheus
  if kubectl get svc -n "${MONITORING_NAMESPACE}" kube-prometheus-stack-prometheus > /dev/null 2>&1; then
    log "  Prometheus service: OK"
  else
    log "  WARNING: Prometheus service not found."
  fi

  # Check Grafana
  if kubectl get svc -n "${MONITORING_NAMESPACE}" kube-prometheus-stack-grafana > /dev/null 2>&1; then
    log "  Grafana service: OK"
  else
    log "  WARNING: Grafana service not found."
  fi

  # Check Loki
  if kubectl get svc -n "${MONITORING_NAMESPACE}" loki > /dev/null 2>&1; then
    log "  Loki service: OK"
  else
    log "  WARNING: Loki service not found."
  fi

  # Check dashboard ConfigMap
  if kubectl get configmap -n "${MONITORING_NAMESPACE}" vault-grafana-dashboard > /dev/null 2>&1; then
    log "  Vault dashboard ConfigMap: OK"
  else
    log "  WARNING: Vault dashboard ConfigMap not found."
  fi
}

print_summary() {
  echo ""
  log "=== Observability Stack Deployment Complete ==="
  echo ""
  log "Components:"
  log "  Prometheus:    kube-prometheus-stack-prometheus.${MONITORING_NAMESPACE}.svc:9090"
  log "  Grafana:       kube-prometheus-stack-grafana.${MONITORING_NAMESPACE}.svc:80"
  log "  Alertmanager:  kube-prometheus-stack-alertmanager.${MONITORING_NAMESPACE}.svc:9093"
  log "  Loki:          loki.${MONITORING_NAMESPACE}.svc:3100"
  echo ""
  log "Access Grafana:"
  log "  kubectl port-forward -n ${MONITORING_NAMESPACE} svc/kube-prometheus-stack-grafana 3000:80"
  log "  Default credentials: admin / prom-operator"
  echo ""
  log "Next steps:"
  log "  1. Enable Vault audit logging:"
  log "       make configure-audit"
  log ""
  log "  2. Verify Vault metrics in Prometheus targets:"
  log "       kubectl port-forward -n ${MONITORING_NAMESPACE} svc/kube-prometheus-stack-prometheus 9090:9090"
  log "       Open http://localhost:9090/targets and check 'vault' target."
  echo ""
}

main() {
  log "Starting observability stack deployment..."
  check_prerequisites
  create_namespace
  add_helm_repos
  deploy_prometheus_stack
  deploy_loki_stack
  provision_dashboard
  apply_alert_rules
  wait_for_pods
  verify_deployment
  print_summary
}

main
