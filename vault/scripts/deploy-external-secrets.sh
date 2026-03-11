#!/usr/bin/env bash
set -euo pipefail

# deploy-external-secrets.sh — Deploy External Secrets Operator and configure Vault auth
#
# This script:
# 1. Installs ESO via Helm in the external-secrets namespace
# 2. Applies the external-secrets Vault policy
# 3. Creates a Kubernetes auth role for the ESO service account
# 4. Applies the ClusterSecretStore pointing to Vault
#
# Prerequisites:
#   - Vault must be initialized, unsealed, and reachable
#   - VAULT_TOKEN must be set (root or admin token)
#   - kubectl configured for the target AKS cluster
#   - Kubernetes auth method already enabled (Phase 3)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALUES_FILE="${REPO_ROOT}/helm/external-secrets/values.yaml"
CLUSTER_STORE_MANIFEST="${REPO_ROOT}/kubernetes/external-secrets/cluster-secret-store.yaml"
POLICIES_DIR="${SCRIPT_DIR}/../policies"
VAULT_K8S_NAMESPACE="${VAULT_K8S_NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-external-secrets}"
HELM_CHART_VERSION="${HELM_CHART_VERSION:-0.10.7}"
PORT_FORWARD_PID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Deploy External Secrets Operator and configure Vault auth binding.

Options:
  -a, --address      Vault address (default: http://127.0.0.1:8200)
  -v, --vault-ns     Vault K8s namespace (default: vault)
  -h, --help         Show this help message

Environment variables:
  VAULT_TOKEN          Required — Vault admin token
  VAULT_ADDR           Vault address (default: http://127.0.0.1:8200)
  ESO_NAMESPACE        ESO K8s namespace (default: external-secrets)
  HELM_CHART_VERSION   ESO Helm chart version (default: 0.10.7)

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
  command -v helm >/dev/null 2>&1    || missing+=("helm")
  command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
  command -v vault >/dev/null 2>&1   || missing+=("vault")
  command -v jq >/dev/null 2>&1      || missing+=("jq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
  fi

  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    error "VAULT_TOKEN is not set. Export a valid Vault token before running."
  fi

  if [[ ! -f "${VALUES_FILE}" ]]; then
    error "Values file not found: ${VALUES_FILE}"
  fi

  if [[ ! -f "${CLUSTER_STORE_MANIFEST}" ]]; then
    error "ClusterSecretStore manifest not found: ${CLUSTER_STORE_MANIFEST}"
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

add_helm_repo() {
  log "Adding External Secrets Helm repository..."
  helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
  helm repo update external-secrets
}

deploy_eso() {
  if helm list -n "${ESO_NAMESPACE}" -o json | jq -e ".[] | select(.name==\"${HELM_RELEASE_NAME}\")" > /dev/null 2>&1; then
    log "ESO Helm release '${HELM_RELEASE_NAME}' already exists. Skipping install."
    return 0
  fi

  log "Installing External Secrets Operator via Helm (chart v${HELM_CHART_VERSION})..."
  helm install "${HELM_RELEASE_NAME}" external-secrets/external-secrets \
    --namespace "${ESO_NAMESPACE}" \
    --create-namespace \
    --version "${HELM_CHART_VERSION}" \
    -f "${VALUES_FILE}"

  log "Helm install complete."
}

wait_for_eso() {
  log "Waiting for ESO pods to be ready..."
  local timeout=120
  local elapsed=0
  local expected_pods=3  # operator + webhook + cert-controller

  while [[ $elapsed -lt $timeout ]]; do
    local ready
    ready=$(kubectl get pods -n "${ESO_NAMESPACE}" \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [[ "$ready" -ge "$expected_pods" ]]; then
      log "All ${expected_pods} ESO pods are running."
      return 0
    fi
    log "  ${ready}/${expected_pods} pods running... (${elapsed}s elapsed)"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  error "Timed out waiting for ESO pods after ${timeout}s."
}

configure_vault_auth() {
  log "Applying external-secrets Vault policy..."
  local policy_file="${POLICIES_DIR}/external-secrets.hcl"
  if [[ ! -f "${policy_file}" ]]; then
    error "Policy file not found: ${policy_file}"
  fi
  vault policy write external-secrets "${policy_file}"
  log "Policy 'external-secrets' applied."

  log "Creating Kubernetes auth role for ESO..."
  vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces="${ESO_NAMESPACE}" \
    policies=external-secrets \
    ttl="1h" \
    max_ttl="24h"
  log "Role 'external-secrets' created: SA=external-secrets, NS=${ESO_NAMESPACE}"
}

apply_cluster_secret_store() {
  log "Applying ClusterSecretStore manifest..."
  kubectl apply -f "${CLUSTER_STORE_MANIFEST}"
  log "ClusterSecretStore 'vault-backend' applied."
}

verify_eso() {
  log "Verifying ClusterSecretStore health..."

  # Give ESO a moment to reconcile the store
  local retries=0
  local max_retries=12
  while [[ $retries -lt $max_retries ]]; do
    local status
    status=$(kubectl get clustersecretstore vault-backend -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "${status}" == "True" ]]; then
      log "  [PASS] ClusterSecretStore 'vault-backend' is Ready."
      return 0
    fi
    retries=$((retries + 1))
    sleep 5
  done

  # Not fatal — the store may need Vault to be fully configured
  log "  [WARN] ClusterSecretStore is not yet Ready (may need Vault K8s auth)."
  log "  Check: kubectl get clustersecretstore vault-backend -o yaml"
}

print_summary() {
  echo ""
  log "=== External Secrets Operator Deployment Complete ==="
  echo ""
  log "ESO:"
  log "  Namespace:         ${ESO_NAMESPACE}"
  log "  Chart version:     ${HELM_CHART_VERSION}"
  log "  Pods:              operator + webhook + cert-controller"
  echo ""
  log "Vault integration:"
  log "  Policy:            external-secrets (read-only on secret/*)"
  log "  Auth role:         external-secrets (SA=external-secrets, NS=${ESO_NAMESPACE})"
  log "  ClusterSecretStore: vault-backend"
  echo ""
  log "Next steps:"
  log "  1. Deploy sample apps to see both injection patterns:"
  log "       make sample-deploy"
  echo ""
}

main() {
  log "Starting External Secrets Operator deployment..."
  check_prerequisites
  start_port_forward
  add_helm_repo
  deploy_eso
  wait_for_eso
  configure_vault_auth
  apply_cluster_secret_store
  verify_eso
  print_summary
}

main
