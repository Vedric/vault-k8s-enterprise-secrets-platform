#!/usr/bin/env bash
set -euo pipefail

# rotate-db-creds.sh — Force-rotate database root credentials
#
# This script forces an immediate rotation of the PostgreSQL root password
# used by the Vault database secrets engine. Use this for:
# - Emergency credential rotation after a suspected compromise
# - Scheduled root credential rotation (recommended: monthly)
#
# Dynamic credentials (team-data-readonly, team-data-readwrite) are
# automatically rotated by Vault based on their TTL (default: 1h).
# This script only rotates the ROOT credentials.

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
DB_CONNECTION_NAME="${DB_CONNECTION_NAME:-postgresql}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Force-rotate the root credentials for the Vault database secrets engine.

Options:
  -a, --address      Vault address (default: http://127.0.0.1:8200)
  -c, --connection   Database connection name (default: postgresql)
  -h, --help         Show this help message

Prerequisites:
  - Vault must be initialized and unsealed
  - VAULT_TOKEN must be set with database admin permissions
  - Database secrets engine must be configured (Phase 4)

Examples:
  export VAULT_TOKEN="<admin-token>"
  $(basename "$0")
  $(basename "$0") --connection postgresql
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--address) VAULT_ADDR="$2"; shift 2 ;;
    -c|--connection) DB_CONNECTION_NAME="$2"; shift 2 ;;
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

main() {
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    error "VAULT_TOKEN is not set."
  fi

  log "Rotating root credentials for database connection '${DB_CONNECTION_NAME}'..."

  if ! vault write -f "database/rotate-root/${DB_CONNECTION_NAME}"; then
    error "Failed to rotate root credentials. Check Vault logs for details."
  fi

  log "Root credentials rotated successfully."
  log ""
  log "Active dynamic leases are NOT affected by root rotation."
  log "New dynamic credentials will use the updated root password."
  log ""
  log "To revoke all active leases (use with caution):"
  log "  vault lease revoke -prefix database/creds/team-data-readonly"
  log "  vault lease revoke -prefix database/creds/team-data-readwrite"
}

main
