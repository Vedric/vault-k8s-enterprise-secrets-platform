#!/usr/bin/env bash
set -euo pipefail

# deploy-sample-apps.sh -- Deploy sample apps demonstrating both injection patterns
#
# This script:
# 1. Seeds a demo secret in Vault for the sample apps to consume
# 2. Verifies the Vault Agent Injector is running
# 3. Deploys both sample applications (sidecar + ESO patterns)
# 4. Verifies secret injection is working for both patterns
#
# Prerequisites:
#   - Vault must be initialized, unsealed, and reachable
#   - VAULT_TOKEN must be set (root or admin token)
#   - External Secrets Operator must be deployed (run deploy-external-secrets.sh first)
#   - team-appdev namespace must exist with vault-sa service account (Phase 3)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKLOADS_MANIFEST="${REPO_ROOT}/kubernetes/workloads/sample-deployment.yaml"
VAULT_K8S_NAMESPACE="${VAULT_K8S_NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
DEMO_SECRET_PATH="secret/team-appdev/api/stripe-key"
APP_NAMESPACE="team-appdev"
PORT_FORWARD_PID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Deploy sample apps demonstrating Vault Agent Sidecar and External
Secrets Operator injection patterns.

Options:
  -a, --address      Vault address (default: http://127.0.0.1:8200)
  -v, --vault-ns     Vault K8s namespace (default: vault)
  -h, --help         Show this help message

Prerequisites:
  - Vault must be initialized and unsealed
  - VAULT_TOKEN must be set (root or admin token)
  - ESO must be deployed (run deploy-external-secrets.sh first)
  - team-appdev namespace must exist (Phase 3)

Examples:
  export VAULT_TOKEN="<root-token>"
  $(basename "$0")
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--address) VAULT_ADDR="$2"; shift 2 ;;
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

  if [[ ! -f "${WORKLOADS_MANIFEST}" ]]; then
    error "Workloads manifest not found: ${WORKLOADS_MANIFEST}"
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

seed_demo_secret() {
  log "Seeding demo secret at ${DEMO_SECRET_PATH}..."

  if vault kv get "${DEMO_SECRET_PATH}" > /dev/null 2>&1; then
    log "Demo secret already exists at ${DEMO_SECRET_PATH}. Skipping."
    return 0
  fi

  vault kv put "${DEMO_SECRET_PATH}" \
    api_key="sk_test_placeholder_replace_with_real_key" \
    note="Demo secret for Phase 5 injection pattern comparison"

  log "Demo secret seeded."
}

check_injector() {
  log "Verifying Vault Agent Injector is running..."
  local injector_ready
  injector_ready=$(kubectl get pods -n "${VAULT_K8S_NAMESPACE}" \
    -l app.kubernetes.io/name=vault-agent-injector \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

  if [[ "${injector_ready}" == "True" ]]; then
    log "Vault Agent Injector is ready."
  else
    error "Vault Agent Injector is not ready. Deploy Vault first (make vault-deploy)."
  fi
}

deploy_workloads() {
  log "Deploying sample applications..."
  kubectl apply -f "${WORKLOADS_MANIFEST}"
  log "Sample workloads applied to ${APP_NAMESPACE}."
}

wait_for_sidecar_app() {
  log "Waiting for sample-app-sidecar to be ready..."
  local timeout=120
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local ready
    ready=$(kubectl get deployment sample-app-sidecar -n "${APP_NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${ready}" -ge 1 ]]; then
      log "sample-app-sidecar is ready."
      return 0
    fi
    log "  Waiting for sample-app-sidecar... (${elapsed}s elapsed)"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  error "Timed out waiting for sample-app-sidecar after ${timeout}s."
}

wait_for_eso_app() {
  log "Waiting for sample-app-eso to be ready..."
  local timeout=120
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local ready
    ready=$(kubectl get deployment sample-app-eso -n "${APP_NAMESPACE}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${ready}" -ge 1 ]]; then
      log "sample-app-eso is ready."
      return 0
    fi
    log "  Waiting for sample-app-eso... (${elapsed}s elapsed)"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  error "Timed out waiting for sample-app-eso after ${timeout}s."
}

verify_sidecar_injection() {
  log "--- Verifying Vault Agent Sidecar Injection ---"

  local pod_name
  pod_name=$(kubectl get pods -n "${APP_NAMESPACE}" \
    -l app=sample-app-sidecar \
    -o jsonpath='{.items[0].metadata.name}')

  # Check that the secrets file exists and contains the expected key
  local secret_content
  secret_content=$(kubectl exec -n "${APP_NAMESPACE}" "${pod_name}" -c app -- \
    cat /vault/secrets/config 2>/dev/null || echo "")

  if [[ "${secret_content}" == *"STRIPE_API_KEY"* ]]; then
    log "  [PASS] Sidecar injection verified: /vault/secrets/config contains STRIPE_API_KEY"
  else
    log "  [FAIL] Secret not found at /vault/secrets/config"
    log "  Check pod logs: kubectl logs -n ${APP_NAMESPACE} ${pod_name} -c vault-agent"
    return 1
  fi
}

verify_eso_sync() {
  log "--- Verifying External Secrets Operator Sync ---"

  # Wait for the ExternalSecret to sync
  local retries=0
  local max_retries=12
  while [[ $retries -lt $max_retries ]]; do
    local sync_status
    sync_status=$(kubectl get externalsecret sample-app-secrets -n "${APP_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "${sync_status}" == "True" ]]; then
      break
    fi
    retries=$((retries + 1))
    sleep 5
  done

  # Check that the K8s Secret was created
  if kubectl get secret sample-app-eso-secrets -n "${APP_NAMESPACE}" > /dev/null 2>&1; then
    local key_exists
    key_exists=$(kubectl get secret sample-app-eso-secrets -n "${APP_NAMESPACE}" \
      -o jsonpath='{.data.STRIPE_API_KEY}' 2>/dev/null || echo "")
    if [[ -n "${key_exists}" ]]; then
      log "  [PASS] ESO sync verified: K8s Secret 'sample-app-eso-secrets' contains STRIPE_API_KEY"
    else
      log "  [FAIL] K8s Secret exists but missing STRIPE_API_KEY key"
      return 1
    fi
  else
    log "  [FAIL] K8s Secret 'sample-app-eso-secrets' not found in ${APP_NAMESPACE}"
    log "  Check: kubectl get externalsecret sample-app-secrets -n ${APP_NAMESPACE} -o yaml"
    return 1
  fi
}

print_summary() {
  echo ""
  log "=== Sample Applications Deployed ==="
  echo ""
  log "Pattern 1 -- Vault Agent Sidecar:"
  log "  Deployment:  sample-app-sidecar (${APP_NAMESPACE})"
  log "  Secret:      /vault/secrets/config (in-memory, never in etcd)"
  log "  Refresh:     Vault Agent polls automatically"
  echo ""
  log "Pattern 2 -- External Secrets Operator:"
  log "  Deployment:  sample-app-eso (${APP_NAMESPACE})"
  log "  Secret:      K8s Secret 'sample-app-eso-secrets' (synced from Vault)"
  log "  Refresh:     Every 1 minute (ESO refresh interval)"
  echo ""
  log "Inspect:"
  log "  kubectl logs -n ${APP_NAMESPACE} -l app=sample-app-sidecar -c app"
  log "  kubectl logs -n ${APP_NAMESPACE} -l app=sample-app-eso"
  echo ""
  log "Next steps:"
  log "  1. Run tests: bats tests/bats/"
  log "  2. Compare both patterns in docs/secret-injection.md"
  echo ""
}

main() {
  log "Starting sample apps deployment..."
  check_prerequisites
  start_port_forward
  seed_demo_secret
  check_injector
  deploy_workloads
  wait_for_sidecar_app
  wait_for_eso_app
  verify_sidecar_injection
  verify_eso_sync
  print_summary
}

main
