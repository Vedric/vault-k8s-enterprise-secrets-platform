#!/usr/bin/env bash
set -euo pipefail

# configure-namespaces.sh — Configure Vault path-based multi-tenancy
#
# This script sets up:
# 1. KV v2 secrets engine at secret/
# 2. Team-specific policies from vault/policies/
# 3. Kubernetes auth method for each team namespace
# 4. Initial shared secrets structure

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="${SCRIPT_DIR}/../policies"

TEAMS=("team-platform" "team-appdev" "team-data")

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Configure Vault path-based multi-tenancy with per-team policies
and Kubernetes auth method bindings.

Options:
  -a, --address      Vault address (default: http://127.0.0.1:8200)
  -n, --namespace    Kubernetes namespace for Vault (default: vault)
  -h, --help         Show this help message

Prerequisites:
  - Vault must be initialized and unsealed
  - VAULT_TOKEN must be set (root or admin token)
  - kubectl must be configured to reach the AKS cluster
  - Port-forward active: kubectl port-forward -n vault svc/vault 8200:8200

Examples:
  export VAULT_TOKEN="<root-token>"
  kubectl port-forward -n vault svc/vault 8200:8200 &
  $(basename "$0")
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--address) VAULT_ADDR="$2"; shift 2 ;;
    -n|--namespace) VAULT_NAMESPACE="$2"; shift 2 ;;
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

check_prerequisites() {
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    error "VAULT_TOKEN is not set. Export a valid Vault token before running."
  fi

  if ! vault status > /dev/null 2>&1; then
    error "Cannot reach Vault at ${VAULT_ADDR}. Ensure port-forward is active."
  fi
}

enable_secrets_engine() {
  log "Enabling KV v2 secrets engine at secret/..."
  if vault secrets list -format=json | jq -e '."secret/"' > /dev/null 2>&1; then
    log "KV v2 secrets engine already enabled at secret/. Skipping."
  else
    vault secrets enable -path=secret kv-v2
    log "KV v2 secrets engine enabled."
  fi
}

apply_policies() {
  log "Applying team policies..."
  for team in "${TEAMS[@]}"; do
    local policy_file="${POLICIES_DIR}/${team}.hcl"
    if [[ ! -f "${policy_file}" ]]; then
      error "Policy file not found: ${policy_file}"
    fi
    vault policy write "${team}" "${policy_file}"
    log "Policy '${team}' applied from ${policy_file}"
  done
}

configure_kubernetes_auth() {
  log "Configuring Kubernetes auth method..."

  if vault auth list -format=json | jq -e '."kubernetes/"' > /dev/null 2>&1; then
    log "Kubernetes auth method already enabled. Skipping enable."
  else
    vault auth enable kubernetes
    log "Kubernetes auth method enabled."
  fi

  # Configure the auth method to use the AKS API server
  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc.cluster.local:443"

  # Create roles for each team
  for team in "${TEAMS[@]}"; do
    log "Creating Kubernetes auth role for ${team}..."
    vault write "auth/kubernetes/role/${team}" \
      bound_service_account_names="vault-sa" \
      bound_service_account_namespaces="${team}" \
      policies="${team}" \
      ttl="1h" \
      max_ttl="24h"
    log "Role '${team}' created: SA=vault-sa, NS=${team}, TTL=1h"
  done
}

create_shared_secrets() {
  log "Creating shared infrastructure secrets structure..."
  vault kv put secret/shared/infra/dns-config \
    internal_domain="cluster.local" \
    external_domain="example.com" \
    note="Placeholder values — update with real configuration"

  vault kv put secret/shared/infra/registry-endpoint \
    registry_url="ghcr.io" \
    note="Placeholder values — update with real configuration"

  log "Shared secrets structure created."
}

main() {
  log "Starting Vault multi-tenancy configuration..."
  check_prerequisites
  enable_secrets_engine
  apply_policies
  configure_kubernetes_auth
  create_shared_secrets
  log "Multi-tenancy configuration complete."
  log ""
  log "Next steps:"
  log "  1. Create service accounts in each team namespace:"
  log "     kubectl create sa vault-sa -n team-platform"
  log "     kubectl create sa vault-sa -n team-appdev"
  log "     kubectl create sa vault-sa -n team-data"
  log "  2. Deploy demo workloads to verify access"
  log "  3. Run bats tests: bats tests/bats/"
}

main
