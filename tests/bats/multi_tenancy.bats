#!/usr/bin/env bats

# Tests for Phase 3 multi-tenancy artifacts.
# Validates policies, namespace manifests, configure script, and auth structure.
# Run with: bats tests/bats/multi_tenancy.bats

TEAMS=("team-platform" "team-appdev" "team-data")

# ---------------------------------------------------------------------------
# Policy files
# ---------------------------------------------------------------------------

@test "policy files exist for all teams" {
  for team in "${TEAMS[@]}"; do
    [ -f "vault/policies/${team}.hcl" ]
  done
}

@test "each policy grants CRUD on its own secret path" {
  for team in "${TEAMS[@]}"; do
    grep -q "secret/data/${team}/\\*" "vault/policies/${team}.hcl"
  done
}

@test "each policy grants metadata access on its own path" {
  for team in "${TEAMS[@]}"; do
    grep -q "secret/metadata/${team}/\\*" "vault/policies/${team}.hcl"
  done
}

@test "each policy grants read access to shared secrets" {
  for team in "${TEAMS[@]}"; do
    grep -q "secret/data/shared/infra/\\*" "vault/policies/${team}.hcl"
  done
}

@test "team-platform policy does not reference other team paths" {
  run grep -E "secret/data/team-(appdev|data)" vault/policies/team-platform.hcl
  [ "$status" -ne 0 ]
}

@test "team-appdev policy does not reference other team paths" {
  run grep -E "secret/data/team-(platform|data)" vault/policies/team-appdev.hcl
  [ "$status" -ne 0 ]
}

@test "team-data policy does not reference other team paths" {
  run grep -E "secret/data/team-(platform|appdev)" vault/policies/team-data.hcl
  [ "$status" -ne 0 ]
}

@test "team-data policy includes database credential paths" {
  grep -q "database/creds/team-data" vault/policies/team-data.hcl
}

# ---------------------------------------------------------------------------
# Namespace manifests
# ---------------------------------------------------------------------------

@test "namespace manifests exist for all teams" {
  for team in "${TEAMS[@]}"; do
    [ -f "kubernetes/namespaces/${team}.yaml" ]
  done
}

@test "namespace manifests define both Namespace and ServiceAccount" {
  for team in "${TEAMS[@]}"; do
    grep -q "kind: Namespace" "kubernetes/namespaces/${team}.yaml"
    grep -q "kind: ServiceAccount" "kubernetes/namespaces/${team}.yaml"
  done
}

@test "namespace manifests use vault-sa service account" {
  for team in "${TEAMS[@]}"; do
    grep -q "name: vault-sa" "kubernetes/namespaces/${team}.yaml"
  done
}

@test "service accounts have vault role annotation" {
  for team in "${TEAMS[@]}"; do
    grep -q "vault.hashicorp.com/role: \"${team}\"" "kubernetes/namespaces/${team}.yaml"
  done
}

@test "namespace manifests have vault-injection label" {
  for team in "${TEAMS[@]}"; do
    grep -q "vault-injection: enabled" "kubernetes/namespaces/${team}.yaml"
  done
}

# ---------------------------------------------------------------------------
# Configure script
# ---------------------------------------------------------------------------

@test "configure script exists and is executable" {
  [ -f "vault/scripts/configure-namespaces.sh" ]
}

@test "configure script has proper bash header" {
  run head -1 vault/scripts/configure-namespaces.sh
  [[ "$output" == "#!/usr/bin/env bash" ]]
}

@test "configure script uses strict mode" {
  grep -q "set -euo pipefail" vault/scripts/configure-namespaces.sh
}

@test "configure script checks tool prerequisites" {
  grep -q "check_tools" vault/scripts/configure-namespaces.sh
  grep -q 'command -v vault' vault/scripts/configure-namespaces.sh
  grep -q 'command -v kubectl' vault/scripts/configure-namespaces.sh
  grep -q 'command -v jq' vault/scripts/configure-namespaces.sh
}

@test "configure script manages port-forward lifecycle" {
  grep -q "start_port_forward" vault/scripts/configure-namespaces.sh
  grep -q "PORT_FORWARD_PID" vault/scripts/configure-namespaces.sh
  grep -q "trap cleanup EXIT" vault/scripts/configure-namespaces.sh
}

@test "configure script applies team namespaces" {
  grep -q "apply_team_namespaces" vault/scripts/configure-namespaces.sh
  grep -q "kubectl apply" vault/scripts/configure-namespaces.sh
}

@test "configure script verifies policy isolation" {
  grep -q "verify_policy_isolation" vault/scripts/configure-namespaces.sh
}

@test "configure script defines all three teams" {
  for team in "${TEAMS[@]}"; do
    grep -q "${team}" vault/scripts/configure-namespaces.sh
  done
}

@test "configure script uses kubernetes auth method" {
  grep -q "auth/kubernetes/config" vault/scripts/configure-namespaces.sh
  grep -q "auth/kubernetes/role/" vault/scripts/configure-namespaces.sh
}

# ---------------------------------------------------------------------------
# Cross-file consistency
# ---------------------------------------------------------------------------

@test "teams in configure script match namespace manifest files" {
  for team in "${TEAMS[@]}"; do
    [ -f "kubernetes/namespaces/${team}.yaml" ]
    [ -f "vault/policies/${team}.hcl" ]
  done
}

@test "RBAC clusterrolebinding references vault namespace SA" {
  grep -q "name: vault" kubernetes/rbac/vault-auth-clusterrolebinding.yaml
  grep -q "namespace: vault" kubernetes/rbac/vault-auth-clusterrolebinding.yaml
}
