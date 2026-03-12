#!/usr/bin/env bash
set -euo pipefail

# deploy-postgresql.sh -- Deploy in-cluster PostgreSQL for Vault database secrets engine
#
# This script deploys a lightweight Bitnami PostgreSQL instance in the database
# namespace. The admin password is generated at runtime, stored securely in Vault,
# and never written to disk.
#
# Prerequisites:
#   - Vault must be initialized, unsealed, and reachable
#   - VAULT_TOKEN must be set (root or admin token)
#   - kubectl must be configured for the target AKS cluster
#   - Helm 3.x installed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALUES_FILE="${REPO_ROOT}/helm/postgresql/values.yaml"
NAMESPACE_MANIFEST="${REPO_ROOT}/kubernetes/namespaces/database.yaml"
VAULT_K8S_NAMESPACE="${VAULT_K8S_NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
DB_NAMESPACE="${DB_NAMESPACE:-database}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-postgresql}"
HELM_CHART_VERSION="${HELM_CHART_VERSION:-16.4.3}"
PORT_FORWARD_PID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Deploy in-cluster PostgreSQL for Vault's database secrets engine.

Options:
  -a, --address        Vault address (default: http://127.0.0.1:8200)
  -n, --namespace      Database namespace (default: database)
  -v, --vault-ns       Vault K8s namespace (default: vault)
  -h, --help           Show this help message

Environment variables:
  VAULT_TOKEN          Required -- Vault admin token for storing the password
  VAULT_ADDR           Vault address (default: http://127.0.0.1:8200)
  DB_NAMESPACE         Kubernetes namespace for PostgreSQL (default: database)
  VAULT_K8S_NAMESPACE  Kubernetes namespace for Vault (default: vault)
  HELM_CHART_VERSION   Bitnami PostgreSQL chart version (default: 16.4.3)

Examples:
  export VAULT_TOKEN="<root-token>"
  $(basename "$0")
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--address) VAULT_ADDR="$2"; shift 2 ;;
    -n|--namespace) DB_NAMESPACE="$2"; shift 2 ;;
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
  command -v helm >/dev/null 2>&1    || missing+=("helm")
  command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
  command -v vault >/dev/null 2>&1   || missing+=("vault")
  command -v jq >/dev/null 2>&1      || missing+=("jq")
  command -v openssl >/dev/null 2>&1 || missing+=("openssl")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
  fi

  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    error "VAULT_TOKEN is not set. Export a valid Vault token before running."
  fi

  if [[ ! -f "${VALUES_FILE}" ]]; then
    error "Values file not found: ${VALUES_FILE}"
  fi

  if [[ ! -f "${NAMESPACE_MANIFEST}" ]]; then
    error "Namespace manifest not found: ${NAMESPACE_MANIFEST}"
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

apply_namespace() {
  log "Applying database namespace and network policy..."
  kubectl apply -f "${NAMESPACE_MANIFEST}"
  log "Namespace '${DB_NAMESPACE}' and NetworkPolicy applied."
}

add_helm_repo() {
  log "Adding Bitnami Helm repository..."
  helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
  helm repo update bitnami
}

deploy_postgresql() {
  # Idempotent: skip if already deployed
  if helm list -n "${DB_NAMESPACE}" -o json | jq -e ".[] | select(.name==\"${HELM_RELEASE_NAME}\")" > /dev/null 2>&1; then
    log "PostgreSQL Helm release '${HELM_RELEASE_NAME}' already exists in namespace '${DB_NAMESPACE}'. Skipping install."
    return 0
  fi

  # Generate a secure admin password (never written to disk)
  local pg_password
  pg_password=$(openssl rand -base64 24)

  log "Installing PostgreSQL via Helm (chart v${HELM_CHART_VERSION})..."
  helm install "${HELM_RELEASE_NAME}" bitnami/postgresql \
    --namespace "${DB_NAMESPACE}" \
    --version "${HELM_CHART_VERSION}" \
    -f "${VALUES_FILE}" \
    --set auth.postgresPassword="${pg_password}"

  log "Helm install complete."

  # Store the admin credentials in Vault for later use by the database secrets engine
  store_password_in_vault "${pg_password}"
}

store_password_in_vault() {
  local pg_password="$1"

  log "Storing PostgreSQL admin credentials in Vault..."
  vault kv put secret/shared/infra/postgresql-admin \
    host="postgresql.${DB_NAMESPACE}.svc.cluster.local" \
    port="5432" \
    database="vault_db" \
    username="postgres" \
    password="${pg_password}" \
    note="Managed by deploy-postgresql.sh -- do not edit manually"

  log "Credentials stored at secret/shared/infra/postgresql-admin."
}

wait_for_postgresql() {
  log "Waiting for PostgreSQL pod to be ready..."
  local timeout=120
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local ready
    ready=$(kubectl get pods -n "${DB_NAMESPACE}" \
      -l app.kubernetes.io/name=postgresql \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "${ready}" == "True" ]]; then
      log "PostgreSQL pod is ready."
      return 0
    fi
    log "  Waiting... (${elapsed}s elapsed)"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  error "Timed out waiting for PostgreSQL pod after ${timeout}s."
}

verify_connectivity() {
  log "Verifying PostgreSQL connectivity..."
  local pod_name
  pod_name=$(kubectl get pods -n "${DB_NAMESPACE}" \
    -l app.kubernetes.io/name=postgresql \
    -o jsonpath='{.items[0].metadata.name}')

  if kubectl exec -n "${DB_NAMESPACE}" "${pod_name}" -- \
    pg_isready -U postgres -d vault_db > /dev/null 2>&1; then
    log "PostgreSQL is accepting connections on vault_db."
  else
    error "PostgreSQL connectivity check failed."
  fi
}

print_summary() {
  echo ""
  log "=== PostgreSQL Deployment Complete ==="
  echo ""
  log "PostgreSQL:"
  log "  Namespace:  ${DB_NAMESPACE}"
  log "  Service:    postgresql.${DB_NAMESPACE}.svc.cluster.local:5432"
  log "  Database:   vault_db"
  log "  Credentials: stored in Vault at secret/shared/infra/postgresql-admin"
  echo ""
  log "Next steps:"
  log "  1. Configure Vault dynamic secrets engines:"
  log "       make vault-dynamic-secrets"
  log ""
  log "  2. The admin password will be rotated by Vault after engine configuration."
  log "     Only Vault will know the root password."
  echo ""
}

main() {
  log "Starting PostgreSQL deployment..."
  check_prerequisites
  start_port_forward
  apply_namespace
  add_helm_repo
  deploy_postgresql
  wait_for_postgresql
  verify_connectivity
  print_summary
}

main
