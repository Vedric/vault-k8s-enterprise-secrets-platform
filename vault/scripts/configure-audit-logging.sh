#!/usr/bin/env bash
set -euo pipefail

# configure-audit-logging.sh -- Enable Vault file audit backend
#
# Enables the file audit device at /vault/audit/vault-audit.log.
# Audit logs are JSON-formatted and collected by Promtail for Loki ingestion.
#
# Prerequisites:
#   - Vault must be initialized and unsealed
#   - VAULT_TOKEN must be set with sys/audit permissions
#   - Audit storage must be enabled in Vault Helm values (auditStorage.enabled: true)

VAULT_K8S_NAMESPACE="${VAULT_K8S_NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
AUDIT_PATH="${AUDIT_PATH:-/vault/audit/vault-audit.log}"
PORT_FORWARD_PID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Enable the Vault file audit backend for compliance logging.

Options:
  -a, --address      Vault address (default: http://127.0.0.1:8200)
  -p, --path         Audit log file path (default: /vault/audit/vault-audit.log)
  -v, --vault-ns     Vault K8s namespace (default: vault)
  -h, --help         Show this help message

Environment variables:
  VAULT_TOKEN          Required -- Vault admin token
  VAULT_ADDR           Vault address (default: http://127.0.0.1:8200)
  VAULT_K8S_NAMESPACE  Kubernetes namespace for Vault (default: vault)
  AUDIT_PATH           Audit log file path (default: /vault/audit/vault-audit.log)

Examples:
  export VAULT_TOKEN="<root-token>"
  $(basename "$0")
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--address) VAULT_ADDR="$2"; shift 2 ;;
    -p|--path) AUDIT_PATH="$2"; shift 2 ;;
    -v|--vault-ns) VAULT_K8S_NAMESPACE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Error: unknown option $1" >&2; usage ;;
  esac
done

export VAULT_ADDR

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

error() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    log "Cleaning up port-forward (PID ${PORT_FORWARD_PID})..."
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

check_prerequisites() {
  local missing=()
  command -v vault >/dev/null 2>&1   || missing+=("vault")
  command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
  command -v jq >/dev/null 2>&1      || missing+=("jq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
  fi

  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    error "VAULT_TOKEN is not set. Export a valid Vault token before running."
  fi
}

start_port_forward() {
  if vault status > /dev/null 2>&1; then
    log "Vault is already reachable at ${VAULT_ADDR}. Skipping port-forward."
    return 0
  fi

  log "Starting port-forward to Vault (${VAULT_K8S_NAMESPACE}/svc/vault -> 8200)..."
  kubectl port-forward -n "${VAULT_K8S_NAMESPACE}" svc/vault 8200:8200 > /dev/null 2>&1 &
  PORT_FORWARD_PID=$!

  local retries=0
  local max_retries=15
  while [[ $retries -lt $max_retries ]]; do
    if vault status > /dev/null 2>&1; then
      log "Port-forward established (PID ${PORT_FORWARD_PID})."
      return 0
    fi
    retries=$((retries + 1))
    sleep 1
  done

  error "Port-forward failed to establish after ${max_retries}s. Is Vault running?"
}

enable_audit_backend() {
  # Idempotent: check if file audit is already enabled
  if vault audit list -format=json 2>/dev/null | jq -e '."file/"' > /dev/null 2>&1; then
    log "File audit backend is already enabled. Skipping."
    return 0
  fi

  log "Enabling file audit backend at ${AUDIT_PATH}..."
  vault audit enable file file_path="${AUDIT_PATH}"
  log "File audit backend enabled."
}

verify_audit_logging() {
  log "Verifying audit logging is active..."

  # Trigger an audit event by reading sys/health
  vault read sys/health > /dev/null 2>&1

  # Verify the audit device is listed
  local audit_type
  audit_type=$(vault audit list -format=json 2>/dev/null | jq -r '."file/".type // empty')
  if [[ "${audit_type}" == "file" ]]; then
    log "Audit backend verified: type=file, path=${AUDIT_PATH}"
  else
    error "Audit backend verification failed. Expected type 'file', got '${audit_type}'."
  fi

  # Check that the audit log file exists in the Vault pod
  local vault_pod
  vault_pod=$(kubectl get pods -n "${VAULT_K8S_NAMESPACE}" \
    -l app.kubernetes.io/name=vault \
    -l component=server \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "${vault_pod}" ]]; then
    if kubectl exec -n "${VAULT_K8S_NAMESPACE}" "${vault_pod}" -- \
      test -f "${AUDIT_PATH}" 2>/dev/null; then
      log "Audit log file exists on ${vault_pod}:${AUDIT_PATH}"
    else
      log "WARNING: Audit log file not yet created on ${vault_pod}. It will be created on the next Vault operation."
    fi
  fi
}

print_summary() {
  echo ""
  log "=== Vault Audit Logging Configured ==="
  echo ""
  log "Audit backend:"
  log "  Type:   file"
  log "  Path:   ${AUDIT_PATH}"
  log "  Format: JSON (one event per line)"
  echo ""
  log "Log pipeline:"
  log "  Vault -> ${AUDIT_PATH} -> Promtail -> Loki -> Grafana"
  echo ""
  log "View audit logs in Grafana:"
  log "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
  log "  Open http://localhost:3000, select Loki datasource, query: {job=\"vault-audit\"}"
  echo ""
  log "View raw audit logs from Vault pod:"
  log "  kubectl exec -n vault vault-0 -- tail -5 ${AUDIT_PATH} | jq ."
  echo ""
}

main() {
  log "Configuring Vault audit logging..."
  check_prerequisites
  start_port_forward
  enable_audit_backend
  verify_audit_logging
  print_summary
}

main
