#!/usr/bin/env bats

# Tests for Vault Helm deployment artifacts.
# Run with: bats tests/bats/vault_deploy.bats

@test "helm/vault/values.yaml exists" {
  [ -f "helm/vault/values.yaml" ]
}

@test "vault values.yaml contains HA raft configuration" {
  grep -q "ha:" helm/vault/values.yaml
  grep -q "raft:" helm/vault/values.yaml
}

@test "vault values.yaml has 3 replicas configured" {
  grep -q "replicas: 3" helm/vault/values.yaml
}

@test "vault values.yaml uses pinned image tag" {
  run grep 'tag:' helm/vault/values.yaml
  [ "$status" -eq 0 ]
  [[ "$output" != *"latest"* ]]
}

@test "vault values.yaml contains workload identity annotations" {
  grep -q "azure.workload.identity/client-id" helm/vault/values.yaml
}

@test "vault values.yaml has auto-unseal seal config" {
  grep -q 'seal "azurekeyvault"' helm/vault/values.yaml
}

@test "vault values.yaml does not contain hardcoded Azure GUIDs" {
  run grep -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' helm/vault/values.yaml
  [ "$status" -ne 0 ]
}

@test "deploy script exists and is executable" {
  [ -f "vault/scripts/deploy-vault.sh" ]
  [ -x "vault/scripts/deploy-vault.sh" ]
}

@test "deploy script has proper bash header" {
  run head -1 vault/scripts/deploy-vault.sh
  [[ "$output" == "#!/usr/bin/env bash" ]]
}

@test "deploy script uses strict mode" {
  grep -q "set -euo pipefail" vault/scripts/deploy-vault.sh
}

@test "deploy script pins Helm chart version" {
  grep -q "HELM_CHART_VERSION" vault/scripts/deploy-vault.sh
}

@test "init script exists" {
  [ -f "vault/scripts/init-vault.sh" ]
}

@test "RBAC manifest references vault service account" {
  grep -q "name: vault" kubernetes/rbac/vault-auth-clusterrolebinding.yaml
}

@test "RBAC manifest uses auth-delegator role" {
  grep -q "system:auth-delegator" kubernetes/rbac/vault-auth-clusterrolebinding.yaml
}
