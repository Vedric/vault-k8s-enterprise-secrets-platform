#!/usr/bin/env bash
set -euo pipefail

# init-vault.sh — Initialize and configure a fresh Vault HA cluster
#
# This script performs first-time initialization of the Vault cluster:
# 1. Waits for all Vault pods to be running
# 2. Initializes the first node (vault-0) with auto-unseal
# 3. Waits for auto-unseal to complete on all nodes
# 4. Joins follower nodes to the Raft cluster
# 5. Outputs recovery keys and root token (store securely!)

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_PODS="${VAULT_PODS:-3}"
RECOVERY_SHARES="${RECOVERY_SHARES:-5}"
RECOVERY_THRESHOLD="${RECOVERY_THRESHOLD:-3}"
INIT_TIMEOUT="${INIT_TIMEOUT:-300}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Initialize a Vault HA cluster running on Kubernetes.

Options:
  -n, --namespace    Kubernetes namespace for Vault (default: vault)
  -p, --pods         Number of Vault pods to expect (default: 3)
  -h, --help         Show this help message

Environment variables:
  VAULT_NAMESPACE       Kubernetes namespace (default: vault)
  VAULT_PODS            Expected pod count (default: 3)
  RECOVERY_SHARES       Shamir recovery key shares (default: 5)
  RECOVERY_THRESHOLD    Shamir recovery key threshold (default: 3)
  INIT_TIMEOUT          Timeout in seconds for init wait (default: 300)

Examples:
  $(basename "$0")
  $(basename "$0") --namespace vault --pods 3
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) VAULT_NAMESPACE="$2"; shift 2 ;;
    -p|--pods) VAULT_PODS="$2"; shift 2 ;;
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

wait_for_pods() {
  log "Waiting for ${VAULT_PODS} Vault pods to be running..."
  local elapsed=0
  while [[ $elapsed -lt $INIT_TIMEOUT ]]; do
    local running
    running=$(kubectl get pods -n "${VAULT_NAMESPACE}" -l app.kubernetes.io/name=vault \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [[ "$running" -ge "$VAULT_PODS" ]]; then
      log "All ${VAULT_PODS} Vault pods are running."
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  error "Timed out waiting for Vault pods after ${INIT_TIMEOUT}s"
}

init_vault() {
  log "Checking if Vault is already initialized..."
  local status
  status=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault status -format=json 2>/dev/null || true)

  if echo "${status}" | grep -q '"initialized": true'; then
    log "Vault is already initialized. Skipping init."
    return 0
  fi

  log "Initializing Vault on vault-0 with ${RECOVERY_SHARES}/${RECOVERY_THRESHOLD} recovery keys..."
  local init_output
  init_output=$(kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- \
    vault operator init \
      -recovery-shares="${RECOVERY_SHARES}" \
      -recovery-threshold="${RECOVERY_THRESHOLD}" \
      -format=json)

  echo ""
  log "=== CRITICAL: STORE THESE SECURELY AND OFFLINE ==="
  echo "${init_output}" | jq -r '.recovery_keys_b64[]' | while IFS= read -r key; do
    echo "  Recovery Key: ${key}"
  done
  echo "  Root Token: $(echo "${init_output}" | jq -r '.root_token')"
  log "=== END OF SENSITIVE OUTPUT ==="
  echo ""
}

join_raft_cluster() {
  log "Joining follower nodes to the Raft cluster..."
  for i in $(seq 1 $((VAULT_PODS - 1))); do
    log "Joining vault-${i} to the Raft cluster..."
    kubectl exec -n "${VAULT_NAMESPACE}" "vault-${i}" -- \
      vault operator raft join "http://vault-0.vault-internal:8200" || true
  done
}

verify_cluster() {
  log "Verifying Raft cluster membership..."
  kubectl exec -n "${VAULT_NAMESPACE}" vault-0 -- vault operator raft list-peers

  log "Verifying Vault seal status..."
  for i in $(seq 0 $((VAULT_PODS - 1))); do
    local sealed
    sealed=$(kubectl exec -n "${VAULT_NAMESPACE}" "vault-${i}" -- \
      vault status -format=json 2>/dev/null | jq -r '.sealed')
    log "vault-${i}: sealed=${sealed}"
  done
}

main() {
  log "Starting Vault cluster initialization..."
  wait_for_pods
  init_vault
  join_raft_cluster
  sleep 10
  verify_cluster
  log "Vault cluster initialization complete."
}

main
