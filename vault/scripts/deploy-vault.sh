#!/usr/bin/env bash
set -euo pipefail

# deploy-vault.sh -- Deploy Vault HA cluster to AKS using Helm
#
# Reads Terraform outputs to inject Azure-specific values into the Helm chart,
# then installs or upgrades the hashicorp/vault Helm chart.
#
# Prerequisites:
#   - Azure CLI authenticated and subscription selected
#   - kubectl configured for the target AKS cluster
#   - Helm 3.x installed
#   - Terraform state accessible (run from the repo root)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TERRAFORM_DIR="${REPO_ROOT}/terraform"
VALUES_FILE="${REPO_ROOT}/helm/vault/values.yaml"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-vault}"
HELM_CHART_VERSION="${HELM_CHART_VERSION:-0.28.1}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Deploy or upgrade the Vault HA cluster on AKS.

Options:
  -n, --namespace       Kubernetes namespace (default: vault)
  -r, --release-name    Helm release name (default: vault)
  -c, --chart-version   Vault Helm chart version (default: 0.28.1)
  -d, --dry-run         Render templates without installing
  -u, --upgrade         Upgrade existing release instead of installing
  -h, --help            Show this help message

Environment variables:
  VAULT_NAMESPACE       Kubernetes namespace (default: vault)
  HELM_RELEASE_NAME     Helm release name (default: vault)
  HELM_CHART_VERSION    Vault Helm chart version (default: 0.28.1)

Examples:
  $(basename "$0")                    # Fresh install
  $(basename "$0") --upgrade          # Upgrade existing release
  $(basename "$0") --dry-run          # Preview rendered manifests
USAGE
  exit 0
}

DRY_RUN=""
UPGRADE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) VAULT_NAMESPACE="$2"; shift 2 ;;
    -r|--release-name) HELM_RELEASE_NAME="$2"; shift 2 ;;
    -c|--chart-version) HELM_CHART_VERSION="$2"; shift 2 ;;
    -d|--dry-run) DRY_RUN="--dry-run --debug"; shift ;;
    -u|--upgrade) UPGRADE="true"; shift ;;
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
  command -v az >/dev/null 2>&1       || missing+=("az")
  command -v kubectl >/dev/null 2>&1   || missing+=("kubectl")
  command -v helm >/dev/null 2>&1      || missing+=("helm")
  command -v terraform >/dev/null 2>&1 || missing+=("terraform")
  command -v jq >/dev/null 2>&1        || missing+=("jq")

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
  fi

  if [[ ! -f "${VALUES_FILE}" ]]; then
    error "Values file not found: ${VALUES_FILE}"
  fi
}

read_terraform_outputs() {
  log "Reading Terraform outputs..."

  if ! terraform -chdir="${TERRAFORM_DIR}" output -json > /dev/null 2>&1; then
    error "Failed to read Terraform outputs. Ensure 'terraform init' has been run."
  fi

  TENANT_ID=$(terraform -chdir="${TERRAFORM_DIR}" output -raw tenant_id)
  KEYVAULT_NAME=$(terraform -chdir="${TERRAFORM_DIR}" output -raw keyvault_name)
  VAULT_CLIENT_ID=$(terraform -chdir="${TERRAFORM_DIR}" output -raw vault_identity_client_id)
  AKS_CLUSTER_NAME=$(terraform -chdir="${TERRAFORM_DIR}" output -raw aks_cluster_name)
  RESOURCE_GROUP=$(terraform -chdir="${TERRAFORM_DIR}" output -raw resource_group_name)

  local vars=("TENANT_ID" "KEYVAULT_NAME" "VAULT_CLIENT_ID" "AKS_CLUSTER_NAME" "RESOURCE_GROUP")
  for var in "${vars[@]}"; do
    if [[ -z "${!var}" ]]; then
      error "Terraform output '${var}' is empty. Run 'make apply' first."
    fi
  done

  log "Terraform outputs loaded:"
  log "  Tenant ID:       ${TENANT_ID}"
  log "  Key Vault:       ${KEYVAULT_NAME}"
  log "  Vault Client ID: ${VAULT_CLIENT_ID}"
  log "  AKS Cluster:     ${AKS_CLUSTER_NAME}"
  log "  Resource Group:   ${RESOURCE_GROUP}"
}

configure_kubectl() {
  log "Configuring kubectl for AKS cluster ${AKS_CLUSTER_NAME}..."
  az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${AKS_CLUSTER_NAME}" \
    --overwrite-existing
}

add_helm_repo() {
  log "Adding HashiCorp Helm repository..."
  helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
  helm repo update hashicorp
}

deploy_vault() {
  local action="install"
  local helm_cmd="install"
  if [[ "${UPGRADE}" == "true" ]]; then
    action="upgrade"
    helm_cmd="upgrade"
  fi

  log "Running Helm ${action} for Vault (chart v${HELM_CHART_VERSION})..."

  # Use process substitution to inject Terraform values into the Helm values
  # file without writing secrets to disk. The sed delimiter is | to avoid
  # conflicts with / in potential values.
  # shellcheck disable=SC2086
  helm ${helm_cmd} "${HELM_RELEASE_NAME}" hashicorp/vault \
    --namespace "${VAULT_NAMESPACE}" \
    --create-namespace \
    --version "${HELM_CHART_VERSION}" \
    -f <(sed \
      -e "s|REPLACE_WITH_TENANT_ID|${TENANT_ID}|" \
      -e "s|REPLACE_WITH_KEYVAULT_NAME|${KEYVAULT_NAME}|" \
      -e "s|REPLACE_WITH_VAULT_IDENTITY_CLIENT_ID|${VAULT_CLIENT_ID}|" \
      "${VALUES_FILE}") \
    ${DRY_RUN}

  log "Helm ${action} complete."
}

apply_rbac() {
  log "Applying RBAC for Vault auth delegator..."
  kubectl apply -f "${REPO_ROOT}/kubernetes/rbac/vault-auth-clusterrolebinding.yaml"
}

wait_for_pods() {
  if [[ -n "${DRY_RUN}" ]]; then
    log "Dry run mode -- skipping pod readiness check."
    return 0
  fi

  log "Waiting for Vault server pods to be running..."
  local timeout=300
  local elapsed=0
  local expected=3
  while [[ $elapsed -lt $timeout ]]; do
    local running
    running=$(kubectl get pods -n "${VAULT_NAMESPACE}" \
      -l app.kubernetes.io/name=vault,component=server \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [[ "$running" -ge "$expected" ]]; then
      log "All ${expected} Vault server pods are running."
      return 0
    fi
    log "  ${running}/${expected} pods running... (${elapsed}s elapsed)"
    sleep 10
    elapsed=$((elapsed + 10))
  done
  error "Timed out waiting for Vault pods after ${timeout}s"
}

print_next_steps() {
  echo ""
  log "=== Deployment Complete ==="
  echo ""
  log "Next steps:"
  log "  1. Initialize the Vault cluster:"
  log "       make vault-init"
  log ""
  log "  2. Store recovery keys and root token securely"
  log ""
  log "  3. Verify cluster health:"
  log "       kubectl exec -n vault vault-0 -- vault status"
  log "       kubectl exec -n vault vault-0 -- vault operator raft list-peers"
  echo ""
}

main() {
  log "Starting Vault HA deployment..."
  check_prerequisites
  read_terraform_outputs
  configure_kubectl
  add_helm_repo
  deploy_vault
  apply_rbac
  wait_for_pods
  print_next_steps
}

main
