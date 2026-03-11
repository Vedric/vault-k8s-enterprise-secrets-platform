#!/usr/bin/env bash
set -euo pipefail

# configure-namespaces.sh — Configure Vault path-based multi-tenancy
#
# This script sets up:
# 1. Kubernetes team namespaces and service accounts
# 2. KV v2 secrets engine at secret/
# 3. Team-specific policies from vault/policies/
# 4. Kubernetes auth method for each team namespace
# 5. Initial shared secrets structure
# 6. Policy isolation verification
#
# Prerequisites:
#   - Vault must be initialized and unsealed
#   - VAULT_TOKEN must be set (root or admin token)
#   - kubectl must be configured to reach the AKS cluster

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
POLICIES_DIR="${SCRIPT_DIR}/../policies"
NAMESPACES_DIR="${REPO_ROOT}/kubernetes/namespaces"
PORT_FORWARD_PID=""

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

Examples:
  export VAULT_TOKEN="<root-token>"
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

# Cleanup port-forward on exit (normal or error)
cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    log "Cleaning up port-forward (PID ${PORT_FORWARD_PID})..."
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

check_tools() {
  local missing=()
  command -v vault >/dev/null 2>&1   || missing+=("vault")
  command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
  command -v jq >/dev/null 2>&1      || missing+=("jq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
  fi
}

check_prerequisites() {
  check_tools

  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    error "VAULT_TOKEN is not set. Export a valid Vault token before running."
  fi
}

start_port_forward() {
  # Check if Vault is already reachable (user may have their own port-forward)
  if vault status > /dev/null 2>&1; then
    log "Vault is already reachable at ${VAULT_ADDR}. Skipping port-forward."
    return 0
  fi

  log "Starting port-forward to Vault (${VAULT_NAMESPACE}/svc/vault -> 8200)..."
  kubectl port-forward -n "${VAULT_NAMESPACE}" svc/vault 8200:8200 > /dev/null 2>&1 &
  PORT_FORWARD_PID=$!

  # Wait for port-forward to be ready
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

apply_team_namespaces() {
  log "Applying team namespaces and service accounts..."

  if [[ ! -d "${NAMESPACES_DIR}" ]]; then
    error "Namespaces directory not found: ${NAMESPACES_DIR}"
  fi

  for team in "${TEAMS[@]}"; do
    local manifest="${NAMESPACES_DIR}/${team}.yaml"
    if [[ ! -f "${manifest}" ]]; then
      error "Namespace manifest not found: ${manifest}"
    fi
    kubectl apply -f "${manifest}"
    log "Namespace and ServiceAccount applied for ${team}."
  done
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

  # Configure the auth method to use the in-cluster API server
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

verify_policy_isolation() {
  log "Verifying policy isolation between teams..."
  local failures=0

  for team in "${TEAMS[@]}"; do
    # Create a token scoped to this team's policy
    local token
    token=$(vault token create -policy="${team}" -ttl=60s -format=json | jq -r '.auth.client_token')

    # The team should be able to write to its own path
    if VAULT_TOKEN="${token}" vault kv put "secret/${team}/test-isolation" verify="true" > /dev/null 2>&1; then
      log "  [PASS] ${team} can write to secret/${team}/"
    else
      log "  [FAIL] ${team} cannot write to its own path secret/${team}/"
      failures=$((failures + 1))
    fi

    # The team should NOT be able to write to other teams' paths
    for other_team in "${TEAMS[@]}"; do
      if [[ "${other_team}" == "${team}" ]]; then
        continue
      fi
      if VAULT_TOKEN="${token}" vault kv put "secret/${other_team}/test-isolation" verify="true" > /dev/null 2>&1; then
        log "  [FAIL] ${team} CAN write to secret/${other_team}/ (policy leak!)"
        failures=$((failures + 1))
      else
        log "  [PASS] ${team} cannot write to secret/${other_team}/"
      fi
    done

    # The team should be able to read shared secrets
    if VAULT_TOKEN="${token}" vault kv get "secret/shared/infra/dns-config" > /dev/null 2>&1; then
      log "  [PASS] ${team} can read shared secrets"
    else
      log "  [FAIL] ${team} cannot read shared secrets"
      failures=$((failures + 1))
    fi

    # Clean up test secret
    vault kv delete "secret/${team}/test-isolation" > /dev/null 2>&1 || true
    vault kv metadata delete "secret/${team}/test-isolation" > /dev/null 2>&1 || true
  done

  if [[ $failures -gt 0 ]]; then
    error "Policy isolation verification FAILED with ${failures} error(s)."
  fi

  log "Policy isolation verification PASSED — all teams are correctly isolated."
}

print_summary() {
  echo ""
  log "=== Multi-Tenancy Configuration Complete ==="
  echo ""
  log "Teams configured:"
  for team in "${TEAMS[@]}"; do
    log "  - ${team}: NS=${team}, SA=vault-sa, Policy=${team}, Role=${team}"
  done
  echo ""
  log "Secrets engines:"
  log "  - KV v2 at secret/"
  echo ""
  log "Shared secrets:"
  log "  - secret/shared/infra/dns-config"
  log "  - secret/shared/infra/registry-endpoint"
  echo ""
  log "Next steps:"
  log "  1. Deploy demo workloads to verify secret injection"
  log "  2. Run bats tests: bats tests/bats/"
  echo ""
}

main() {
  log "Starting Vault multi-tenancy configuration..."
  check_prerequisites
  start_port_forward
  apply_team_namespaces
  enable_secrets_engine
  apply_policies
  configure_kubernetes_auth
  create_shared_secrets
  verify_policy_isolation
  print_summary
}

main
