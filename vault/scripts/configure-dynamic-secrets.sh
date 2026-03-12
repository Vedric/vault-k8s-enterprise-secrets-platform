#!/usr/bin/env bash
set -euo pipefail

# configure-dynamic-secrets.sh -- Configure Vault database and PKI secrets engines
#
# This script sets up:
# 1. Database secrets engine with PostgreSQL connection
# 2. Dynamic roles: team-data-readonly (SELECT) and team-data-readwrite (full DML)
# 3. Root password rotation (Vault takes exclusive control)
# 4. PKI secrets engine as internal CA
# 5. Certificate role: internal-cert for short-lived TLS certs
#
# Prerequisites:
#   - Vault must be initialized and unsealed
#   - VAULT_TOKEN must be set (root or admin token)
#   - PostgreSQL must be deployed (run deploy-postgresql.sh first)
#   - Admin credentials stored at secret/shared/infra/postgresql-admin

VAULT_K8S_NAMESPACE="${VAULT_K8S_NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
DB_NAMESPACE="${DB_NAMESPACE:-database}"
PORT_FORWARD_PID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Configure Vault database and PKI secrets engines for dynamic credential
generation.

Options:
  -a, --address      Vault address (default: http://127.0.0.1:8200)
  -v, --vault-ns     Vault K8s namespace (default: vault)
  -h, --help         Show this help message

Prerequisites:
  - Vault must be initialized and unsealed
  - VAULT_TOKEN must be set (root or admin token)
  - PostgreSQL must be deployed (run deploy-postgresql.sh first)

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

# ---------------------------------------------------------------------------
# Database Secrets Engine
# ---------------------------------------------------------------------------

configure_database_engine() {
  log "--- Configuring Database Secrets Engine ---"

  # Enable the database secrets engine (idempotent)
  if vault secrets list -format=json | jq -e '."database/"' > /dev/null 2>&1; then
    log "Database secrets engine already enabled. Skipping."
  else
    vault secrets enable database
    log "Database secrets engine enabled."
  fi

  # Read the stored admin credentials from Vault
  log "Reading PostgreSQL admin credentials from Vault..."
  local pg_creds
  pg_creds=$(vault kv get -format=json secret/shared/infra/postgresql-admin)

  local pg_host pg_port pg_database pg_username pg_password
  pg_host=$(echo "${pg_creds}" | jq -r '.data.data.host')
  pg_port=$(echo "${pg_creds}" | jq -r '.data.data.port')
  pg_database=$(echo "${pg_creds}" | jq -r '.data.data.database')
  pg_username=$(echo "${pg_creds}" | jq -r '.data.data.username')
  pg_password=$(echo "${pg_creds}" | jq -r '.data.data.password')

  if [[ -z "${pg_host}" || "${pg_host}" == "null" ]]; then
    error "PostgreSQL credentials not found in Vault. Run deploy-postgresql.sh first."
  fi

  # Configure the PostgreSQL connection
  log "Configuring PostgreSQL connection..."
  vault write database/config/postgresql \
    plugin_name=postgresql-database-plugin \
    allowed_roles="team-data-readonly,team-data-readwrite" \
    connection_url="postgresql://{{username}}:{{password}}@${pg_host}:${pg_port}/${pg_database}?sslmode=disable" \
    username="${pg_username}" \
    password="${pg_password}"

  log "PostgreSQL connection configured."

  # Create the readonly role
  log "Creating role 'team-data-readonly' (SELECT only, 1h TTL)..."
  vault write database/roles/team-data-readonly \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

  # Create the readwrite role
  log "Creating role 'team-data-readwrite' (full DML, 1h TTL)..."
  vault write database/roles/team-data-readwrite \
    db_name=postgresql \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

  # Rotate root credentials so only Vault knows the password
  log "Rotating PostgreSQL root credentials (Vault takes exclusive control)..."
  vault write -f database/rotate-root/postgresql

  # Update the Vault KV entry to reflect that the password is now Vault-managed
  vault kv patch secret/shared/infra/postgresql-admin \
    note="Root password rotated by Vault -- original password is no longer valid"

  log "Database secrets engine fully configured."
}

# ---------------------------------------------------------------------------
# PKI Secrets Engine
# ---------------------------------------------------------------------------

configure_pki_engine() {
  log "--- Configuring PKI Secrets Engine ---"

  # Enable the PKI secrets engine (idempotent)
  if vault secrets list -format=json | jq -e '."pki/"' > /dev/null 2>&1; then
    log "PKI secrets engine already enabled. Skipping."
  else
    vault secrets enable pki
    log "PKI secrets engine enabled."
  fi

  # Tune the max lease TTL to 10 years (87600h)
  vault secrets tune -max-lease-ttl=87600h pki

  # Generate internal root CA
  log "Generating internal root CA (10-year TTL)..."
  local ca_output
  ca_output=$(vault write -format=json pki/root/generate/internal \
    common_name="Vault K8s Internal CA" \
    ttl=87600h \
    key_bits=2048)

  local ca_serial
  ca_serial=$(echo "${ca_output}" | jq -r '.data.serial_number')
  log "Root CA generated (serial: ${ca_serial})."

  # Configure issuing and CRL URLs
  vault write pki/config/urls \
    issuing_certificates="http://vault.vault.svc.cluster.local:8200/v1/pki/ca" \
    crl_distribution_points="http://vault.vault.svc.cluster.local:8200/v1/pki/crl"

  # Create the internal-cert role (matches policy path pki/issue/internal-cert)
  log "Creating PKI role 'internal-cert' (30-day max TTL)..."
  vault write pki/roles/internal-cert \
    allowed_domains="internal" \
    allow_subdomains=true \
    max_ttl=720h \
    enforce_hostnames=true \
    key_type=rsa \
    key_bits=2048 \
    require_cn=true

  log "PKI secrets engine fully configured."
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify_database_engine() {
  log "--- Verifying Database Secrets Engine ---"

  # Test readonly credential generation
  log "Generating test readonly credential..."
  local readonly_creds
  readonly_creds=$(vault read -format=json database/creds/team-data-readonly)
  local readonly_user readonly_lease
  readonly_user=$(echo "${readonly_creds}" | jq -r '.data.username')
  readonly_lease=$(echo "${readonly_creds}" | jq -r '.lease_id')
  log "  [PASS] Readonly credential generated: user=${readonly_user}"

  # Revoke the test lease
  vault lease revoke "${readonly_lease}"
  log "  Test lease revoked."

  # Test readwrite credential generation
  log "Generating test readwrite credential..."
  local readwrite_creds
  readwrite_creds=$(vault read -format=json database/creds/team-data-readwrite)
  local readwrite_user readwrite_lease
  readwrite_user=$(echo "${readwrite_creds}" | jq -r '.data.username')
  readwrite_lease=$(echo "${readwrite_creds}" | jq -r '.lease_id')
  log "  [PASS] Readwrite credential generated: user=${readwrite_user}"

  vault lease revoke "${readwrite_lease}"
  log "  Test lease revoked."

  log "Database secrets engine verification PASSED."
}

verify_pki_engine() {
  log "--- Verifying PKI Secrets Engine ---"

  # Issue a test certificate
  log "Issuing test certificate for test.internal..."
  local cert_output
  cert_output=$(vault write -format=json pki/issue/internal-cert \
    common_name="test.internal" \
    ttl="1h")

  local cert_serial cert_expiry
  cert_serial=$(echo "${cert_output}" | jq -r '.data.serial_number')
  cert_expiry=$(echo "${cert_output}" | jq -r '.data.expiration')
  log "  [PASS] Certificate issued: serial=${cert_serial}, expires=${cert_expiry}"

  # Verify CA is readable
  if vault read pki/cert/ca > /dev/null 2>&1; then
    log "  [PASS] CA certificate is readable."
  else
    error "  [FAIL] CA certificate is not readable."
  fi

  log "PKI secrets engine verification PASSED."
}

print_summary() {
  echo ""
  log "=== Dynamic Secrets Configuration Complete ==="
  echo ""
  log "Database secrets engine:"
  log "  Connection:    postgresql (postgresql.${DB_NAMESPACE}.svc.cluster.local:5432)"
  log "  Roles:         team-data-readonly (SELECT, 1h TTL)"
  log "                 team-data-readwrite (DML, 1h TTL)"
  log "  Root password: rotated -- only Vault knows it"
  echo ""
  log "PKI secrets engine:"
  log "  CA:            Vault K8s Internal CA (10-year TTL)"
  log "  Role:          internal-cert (*.internal, 30-day max TTL)"
  echo ""
  log "Usage:"
  log "  vault read database/creds/team-data-readonly"
  log "  vault read database/creds/team-data-readwrite"
  log "  vault write pki/issue/internal-cert common_name=\"app.internal\" ttl=\"24h\""
  echo ""
  log "Next steps:"
  log "  1. Run tests: bats tests/bats/"
  log "  2. Deploy workloads that consume dynamic credentials"
  echo ""
}

main() {
  log "Starting dynamic secrets configuration..."
  check_prerequisites
  start_port_forward
  configure_database_engine
  configure_pki_engine
  verify_database_engine
  verify_pki_engine
  print_summary
}

main
