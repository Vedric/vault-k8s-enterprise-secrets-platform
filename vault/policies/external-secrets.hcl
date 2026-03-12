# Policy: external-secrets
# Grants the External Secrets Operator read-only access to all KV v2 paths.
# ESO authenticates via Kubernetes auth with a dedicated service account.
#
# Security model: ESO can read broadly, but Kubernetes RBAC controls which
# namespaces can create ExternalSecret CRs referencing specific paths.
# This prevents unauthorized teams from syncing secrets they should not access.

# Read all KV v2 secret data
path "secret/data/*" {
  capabilities = ["read", "list"]
}

# Read metadata (required for KV v2 operations)
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
