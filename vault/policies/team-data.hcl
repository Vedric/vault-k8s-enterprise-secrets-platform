# Policy: team-data
# Grants the data team full CRUD access to their dedicated secret path,
# read-only access to shared infrastructure secrets, and access to
# dynamically generated database credentials.

# Full access to team-data secrets
path "secret/data/team-data/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/team-data/*" {
  capabilities = ["list", "read", "delete"]
}

# Read-only access to shared infrastructure secrets
path "secret/data/shared/infra/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/shared/infra/*" {
  capabilities = ["list", "read"]
}

# Dynamic database credentials (Phase 4)
# Read-only and read-write PostgreSQL credential generation
path "database/creds/team-data-readonly" {
  capabilities = ["read"]
}

path "database/creds/team-data-readwrite" {
  capabilities = ["read"]
}

# Allow requesting internal TLS certificates
path "pki/issue/internal-cert" {
  capabilities = ["create", "update"]
}

path "pki/cert/ca" {
  capabilities = ["read"]
}
