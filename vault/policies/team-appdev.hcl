# Policy: team-appdev
# Grants the application development team full CRUD access to their
# dedicated secret path and read-only access to shared infrastructure secrets.

# Full access to team-appdev secrets
path "secret/data/team-appdev/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/team-appdev/*" {
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
