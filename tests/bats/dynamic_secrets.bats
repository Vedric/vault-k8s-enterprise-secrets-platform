#!/usr/bin/env bats

# Tests for Phase 4 dynamic secrets artifacts.
# Validates PostgreSQL Helm values, database namespace, deploy script,
# configure script, reference configs, and cross-file consistency.
# Run with: bats tests/bats/dynamic_secrets.bats

# ---------------------------------------------------------------------------
# PostgreSQL Helm values
# ---------------------------------------------------------------------------

@test "postgresql values file exists" {
  [ -f "helm/postgresql/values.yaml" ]
}

@test "postgresql values pins image tag (no latest)" {
  run grep 'tag:' helm/postgresql/values.yaml
  [[ "$output" != *"latest"* ]]
  [[ "$output" =~ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "postgresql values does not contain hardcoded passwords" {
  run grep -iE 'postgresPassword:\s*".+"' helm/postgresql/values.yaml
  [ "$status" -ne 0 ]
}

@test "postgresql values defines resource requests and limits" {
  grep -q "requests:" helm/postgresql/values.yaml
  grep -q "limits:" helm/postgresql/values.yaml
  grep -q "cpu:" helm/postgresql/values.yaml
  grep -q "memory:" helm/postgresql/values.yaml
}

@test "postgresql values uses managed-csi storage class" {
  grep -q "storageClass: managed-csi" helm/postgresql/values.yaml
}

@test "postgresql values sets vault_db database" {
  grep -q "database: vault_db" helm/postgresql/values.yaml
}

@test "postgresql values runs as non-root" {
  grep -q "runAsNonRoot: true" helm/postgresql/values.yaml
}

# ---------------------------------------------------------------------------
# Database namespace manifest
# ---------------------------------------------------------------------------

@test "database namespace manifest exists" {
  [ -f "kubernetes/namespaces/database.yaml" ]
}

@test "database manifest defines Namespace kind" {
  grep -q "kind: Namespace" kubernetes/namespaces/database.yaml
}

@test "database manifest defines NetworkPolicy kind" {
  grep -q "kind: NetworkPolicy" kubernetes/namespaces/database.yaml
}

@test "database network policy restricts to port 5432" {
  grep -q "port: 5432" kubernetes/namespaces/database.yaml
}

@test "database network policy allows ingress from vault namespace" {
  grep -q "kubernetes.io/metadata.name: vault" kubernetes/namespaces/database.yaml
}

@test "database network policy allows ingress from team-data namespace" {
  grep -q "kubernetes.io/metadata.name: team-data" kubernetes/namespaces/database.yaml
}

# ---------------------------------------------------------------------------
# Deploy script (deploy-postgresql.sh)
# ---------------------------------------------------------------------------

@test "deploy-postgresql script exists" {
  [ -f "vault/scripts/deploy-postgresql.sh" ]
}

@test "deploy-postgresql script has proper bash header" {
  run head -1 vault/scripts/deploy-postgresql.sh
  [[ "$output" == "#!/usr/bin/env bash" ]]
}

@test "deploy-postgresql script uses strict mode" {
  grep -q "set -euo pipefail" vault/scripts/deploy-postgresql.sh
}

@test "deploy-postgresql script checks tool prerequisites" {
  grep -q 'command -v helm' vault/scripts/deploy-postgresql.sh
  grep -q 'command -v kubectl' vault/scripts/deploy-postgresql.sh
  grep -q 'command -v vault' vault/scripts/deploy-postgresql.sh
  grep -q 'command -v openssl' vault/scripts/deploy-postgresql.sh
}

@test "deploy-postgresql script generates password with openssl" {
  grep -q "openssl rand" vault/scripts/deploy-postgresql.sh
}

@test "deploy-postgresql script stores credentials in vault" {
  grep -q "vault kv put secret/shared/infra/postgresql-admin" vault/scripts/deploy-postgresql.sh
}

@test "deploy-postgresql script does not contain hardcoded passwords" {
  run grep -E 'password="[a-zA-Z0-9]+"' vault/scripts/deploy-postgresql.sh
  [ "$status" -ne 0 ]
}

@test "deploy-postgresql script manages port-forward lifecycle" {
  grep -q "PORT_FORWARD_PID" vault/scripts/deploy-postgresql.sh
  grep -q "trap cleanup EXIT" vault/scripts/deploy-postgresql.sh
}

@test "deploy-postgresql script is idempotent (checks existing release)" {
  grep -q "helm list" vault/scripts/deploy-postgresql.sh
}

@test "deploy-postgresql script waits for pod readiness" {
  grep -q "wait_for_postgresql" vault/scripts/deploy-postgresql.sh
}

@test "deploy-postgresql script verifies connectivity" {
  grep -q "pg_isready" vault/scripts/deploy-postgresql.sh
}

# ---------------------------------------------------------------------------
# Configure script (configure-dynamic-secrets.sh)
# ---------------------------------------------------------------------------

@test "configure-dynamic-secrets script exists" {
  [ -f "vault/scripts/configure-dynamic-secrets.sh" ]
}

@test "configure-dynamic-secrets script has proper bash header" {
  run head -1 vault/scripts/configure-dynamic-secrets.sh
  [[ "$output" == "#!/usr/bin/env bash" ]]
}

@test "configure-dynamic-secrets script uses strict mode" {
  grep -q "set -euo pipefail" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script checks tool prerequisites" {
  grep -q 'command -v vault' vault/scripts/configure-dynamic-secrets.sh
  grep -q 'command -v kubectl' vault/scripts/configure-dynamic-secrets.sh
  grep -q 'command -v jq' vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script manages port-forward lifecycle" {
  grep -q "PORT_FORWARD_PID" vault/scripts/configure-dynamic-secrets.sh
  grep -q "trap cleanup EXIT" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script enables database secrets engine" {
  grep -q "vault secrets enable database" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script configures postgresql connection" {
  grep -q "database/config/postgresql" vault/scripts/configure-dynamic-secrets.sh
  grep -q "postgresql-database-plugin" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script creates readonly role" {
  grep -q "database/roles/team-data-readonly" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script creates readwrite role" {
  grep -q "database/roles/team-data-readwrite" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script rotates root password" {
  grep -q "database/rotate-root/postgresql" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script enables pki secrets engine" {
  grep -q "vault secrets enable pki" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script generates root CA" {
  grep -q "pki/root/generate/internal" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script creates internal-cert role" {
  grep -q "pki/roles/internal-cert" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script reads admin password from vault" {
  grep -q "secret/shared/infra/postgresql-admin" vault/scripts/configure-dynamic-secrets.sh
}

@test "configure-dynamic-secrets script includes verification" {
  grep -q "verify_database_engine" vault/scripts/configure-dynamic-secrets.sh
  grep -q "verify_pki_engine" vault/scripts/configure-dynamic-secrets.sh
}

# ---------------------------------------------------------------------------
# Reference config files
# ---------------------------------------------------------------------------

@test "database engine reference config exists and is valid JSON" {
  [ -f "vault/config/secrets-engines/database.json" ]
  run jq empty vault/config/secrets-engines/database.json
  [ "$status" -eq 0 ]
}

@test "pki engine reference config exists and is valid JSON" {
  [ -f "vault/config/secrets-engines/pki.json" ]
  run jq empty vault/config/secrets-engines/pki.json
  [ "$status" -eq 0 ]
}

@test "database config references correct roles" {
  jq -e '.roles["team-data-readonly"]' vault/config/secrets-engines/database.json > /dev/null
  jq -e '.roles["team-data-readwrite"]' vault/config/secrets-engines/database.json > /dev/null
}

@test "pki config references internal-cert role" {
  jq -e '.roles["internal-cert"]' vault/config/secrets-engines/pki.json > /dev/null
}

# ---------------------------------------------------------------------------
# Rotation script
# ---------------------------------------------------------------------------

@test "rotation script exists" {
  [ -f "vault/scripts/rotate-db-creds.sh" ]
}

@test "rotation script has proper bash header and strict mode" {
  run head -1 vault/scripts/rotate-db-creds.sh
  [[ "$output" == "#!/usr/bin/env bash" ]]
  grep -q "set -euo pipefail" vault/scripts/rotate-db-creds.sh
}

@test "rotation script uses same connection name as configure script" {
  grep -q "postgresql" vault/scripts/rotate-db-creds.sh
  grep -q "postgresql" vault/scripts/configure-dynamic-secrets.sh
}

# ---------------------------------------------------------------------------
# Cross-file consistency
# ---------------------------------------------------------------------------

@test "team-data policy references both database credential paths" {
  grep -q "database/creds/team-data-readonly" vault/policies/team-data.hcl
  grep -q "database/creds/team-data-readwrite" vault/policies/team-data.hcl
}

@test "all team policies reference pki/issue/internal-cert" {
  for team in team-platform team-appdev team-data; do
    grep -q "pki/issue/internal-cert" "vault/policies/${team}.hcl"
  done
}

@test "all team policies reference pki/cert/ca" {
  for team in team-platform team-appdev team-data; do
    grep -q "pki/cert/ca" "vault/policies/${team}.hcl"
  done
}

@test "database role names in config match policy paths" {
  # Config references team-data-readonly and team-data-readwrite
  jq -e '.roles["team-data-readonly"]' vault/config/secrets-engines/database.json > /dev/null
  jq -e '.roles["team-data-readwrite"]' vault/config/secrets-engines/database.json > /dev/null
  # Policy allows reading those exact paths
  grep -q "database/creds/team-data-readonly" vault/policies/team-data.hcl
  grep -q "database/creds/team-data-readwrite" vault/policies/team-data.hcl
}

@test "pki role name in config matches policy path" {
  jq -e '.roles["internal-cert"]' vault/config/secrets-engines/pki.json > /dev/null
  grep -q "pki/issue/internal-cert" vault/policies/team-data.hcl
}
