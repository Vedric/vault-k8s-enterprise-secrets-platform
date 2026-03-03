# Policy: team-platform
# Grants the platform engineering team full CRUD access to their
# dedicated secret path and read-only access to shared infrastructure secrets.

# Full access to team-platform secrets
path "secret/data/team-platform/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/team-platform/*" {
  capabilities = ["list", "read", "delete"]
}

# Read-only access to shared infrastructure secrets
path "secret/data/shared/infra/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/shared/infra/*" {
  capabilities = ["list", "read"]
}

# Allow requesting internal TLS certificates
path "pki/issue/internal-cert" {
  capabilities = ["create", "update"]
}

path "pki/cert/ca" {
  capabilities = ["read"]
}
