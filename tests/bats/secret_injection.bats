#!/usr/bin/env bats

# Tests for Phase 5 secret injection pattern artifacts.
# Validates ESO Helm values, ClusterSecretStore, policies, sample workloads,
# deploy scripts, and cross-file consistency.
# Run with: bats tests/bats/secret_injection.bats

# ---------------------------------------------------------------------------
# ESO Helm values
# ---------------------------------------------------------------------------

@test "eso helm values file exists" {
  [ -f "helm/external-secrets/values.yaml" ]
}

@test "eso helm values defines resource requests and limits" {
  grep -q "requests:" helm/external-secrets/values.yaml
  grep -q "limits:" helm/external-secrets/values.yaml
}

@test "eso helm values sets service account name" {
  grep -q 'name: external-secrets' helm/external-secrets/values.yaml
}

@test "eso helm values configures webhook" {
  grep -q "webhook:" helm/external-secrets/values.yaml
}

@test "eso helm values configures cert controller" {
  grep -q "certController:" helm/external-secrets/values.yaml
}

# ---------------------------------------------------------------------------
# ClusterSecretStore manifest
# ---------------------------------------------------------------------------

@test "cluster secret store manifest exists" {
  [ -f "kubernetes/external-secrets/cluster-secret-store.yaml" ]
}

@test "cluster secret store is correct kind" {
  grep -q "kind: ClusterSecretStore" kubernetes/external-secrets/cluster-secret-store.yaml
}

@test "cluster secret store points to vault server" {
  grep -q "http://vault.vault.svc.cluster.local:8200" kubernetes/external-secrets/cluster-secret-store.yaml
}

@test "cluster secret store uses kv v2" {
  grep -q 'version: "v2"' kubernetes/external-secrets/cluster-secret-store.yaml
}

@test "cluster secret store uses kubernetes auth" {
  grep -q 'role: "external-secrets"' kubernetes/external-secrets/cluster-secret-store.yaml
  grep -q 'name: "external-secrets"' kubernetes/external-secrets/cluster-secret-store.yaml
  grep -q 'namespace: "external-secrets"' kubernetes/external-secrets/cluster-secret-store.yaml
}

# ---------------------------------------------------------------------------
# External-secrets policy
# ---------------------------------------------------------------------------

@test "external-secrets policy file exists" {
  [ -f "vault/policies/external-secrets.hcl" ]
}

@test "external-secrets policy grants read on secret/data" {
  grep -q 'secret/data/\*' vault/policies/external-secrets.hcl
  grep -q '"read"' vault/policies/external-secrets.hcl
}

@test "external-secrets policy grants read on secret/metadata" {
  grep -q 'secret/metadata/\*' vault/policies/external-secrets.hcl
}

# ---------------------------------------------------------------------------
# Sample deployment manifest
# ---------------------------------------------------------------------------

@test "sample deployment manifest exists" {
  [ -f "kubernetes/workloads/sample-deployment.yaml" ]
}

@test "sidecar deployment has vault agent annotations" {
  grep -q 'vault.hashicorp.com/agent-inject: "true"' kubernetes/workloads/sample-deployment.yaml
  grep -q 'vault.hashicorp.com/role: "team-appdev"' kubernetes/workloads/sample-deployment.yaml
}

@test "sidecar deployment references correct secret path" {
  grep -q 'secret/data/team-appdev/api/stripe-key' kubernetes/workloads/sample-deployment.yaml
}

@test "sidecar deployment renders STRIPE_API_KEY" {
  grep -q 'STRIPE_API_KEY' kubernetes/workloads/sample-deployment.yaml
}

@test "external secret resource exists in manifest" {
  grep -q "kind: ExternalSecret" kubernetes/workloads/sample-deployment.yaml
}

@test "external secret references vault-backend store" {
  grep -q "name: vault-backend" kubernetes/workloads/sample-deployment.yaml
  grep -q "kind: ClusterSecretStore" kubernetes/workloads/sample-deployment.yaml
}

@test "external secret targets correct secret path" {
  grep -q "team-appdev/api/stripe-key" kubernetes/workloads/sample-deployment.yaml
}

@test "external secret creates k8s secret named sample-app-eso-secrets" {
  grep -q "name: sample-app-eso-secrets" kubernetes/workloads/sample-deployment.yaml
}

@test "both deployments use pinned busybox image" {
  run grep -c "busybox:1.36" kubernetes/workloads/sample-deployment.yaml
  [ "$output" -eq 2 ]
}

@test "both deployments define resource requests and limits" {
  run grep -c "requests:" kubernetes/workloads/sample-deployment.yaml
  [ "$output" -ge 2 ]
  run grep -c "limits:" kubernetes/workloads/sample-deployment.yaml
  [ "$output" -ge 2 ]
}

@test "both deployments are in team-appdev namespace" {
  run grep -c "namespace: team-appdev" kubernetes/workloads/sample-deployment.yaml
  [ "$output" -ge 3 ]
}

# ---------------------------------------------------------------------------
# Deploy ESO script
# ---------------------------------------------------------------------------

@test "deploy-external-secrets script exists" {
  [ -f "vault/scripts/deploy-external-secrets.sh" ]
}

@test "deploy-external-secrets script has proper bash header" {
  run head -1 vault/scripts/deploy-external-secrets.sh
  [[ "$output" == "#!/usr/bin/env bash" ]]
}

@test "deploy-external-secrets script uses strict mode" {
  grep -q "set -euo pipefail" vault/scripts/deploy-external-secrets.sh
}

@test "deploy-external-secrets script checks tool prerequisites" {
  grep -q 'command -v helm' vault/scripts/deploy-external-secrets.sh
  grep -q 'command -v kubectl' vault/scripts/deploy-external-secrets.sh
  grep -q 'command -v vault' vault/scripts/deploy-external-secrets.sh
  grep -q 'command -v jq' vault/scripts/deploy-external-secrets.sh
}

@test "deploy-external-secrets script manages port-forward lifecycle" {
  grep -q "PORT_FORWARD_PID" vault/scripts/deploy-external-secrets.sh
  grep -q "trap cleanup EXIT" vault/scripts/deploy-external-secrets.sh
}

@test "deploy-external-secrets script is idempotent" {
  grep -q "helm list" vault/scripts/deploy-external-secrets.sh
}

@test "deploy-external-secrets script applies vault policy" {
  grep -q "vault policy write external-secrets" vault/scripts/deploy-external-secrets.sh
}

@test "deploy-external-secrets script creates vault auth role" {
  grep -q "auth/kubernetes/role/external-secrets" vault/scripts/deploy-external-secrets.sh
}

@test "deploy-external-secrets script applies cluster secret store" {
  grep -q "cluster-secret-store.yaml" vault/scripts/deploy-external-secrets.sh
}

# ---------------------------------------------------------------------------
# Deploy sample apps script
# ---------------------------------------------------------------------------

@test "deploy-sample-apps script exists" {
  [ -f "vault/scripts/deploy-sample-apps.sh" ]
}

@test "deploy-sample-apps script has proper bash header" {
  run head -1 vault/scripts/deploy-sample-apps.sh
  [[ "$output" == "#!/usr/bin/env bash" ]]
}

@test "deploy-sample-apps script uses strict mode" {
  grep -q "set -euo pipefail" vault/scripts/deploy-sample-apps.sh
}

@test "deploy-sample-apps script seeds demo secret" {
  grep -q "vault kv put" vault/scripts/deploy-sample-apps.sh
  grep -q "team-appdev/api/stripe-key" vault/scripts/deploy-sample-apps.sh
}

@test "deploy-sample-apps script checks injector readiness" {
  grep -q "vault-agent-injector" vault/scripts/deploy-sample-apps.sh
}

@test "deploy-sample-apps script applies workloads manifest" {
  grep -q "kubectl apply" vault/scripts/deploy-sample-apps.sh
  grep -q "sample-deployment.yaml" vault/scripts/deploy-sample-apps.sh
}

@test "deploy-sample-apps script verifies both patterns" {
  grep -q "verify_sidecar_injection" vault/scripts/deploy-sample-apps.sh
  grep -q "verify_eso_sync" vault/scripts/deploy-sample-apps.sh
}

# ---------------------------------------------------------------------------
# Cross-file consistency
# ---------------------------------------------------------------------------

@test "cluster secret store role matches deploy script auth role" {
  grep -q 'role: "external-secrets"' kubernetes/external-secrets/cluster-secret-store.yaml
  grep -q "auth/kubernetes/role/external-secrets" vault/scripts/deploy-external-secrets.sh
}

@test "cluster secret store SA matches helm values SA" {
  grep -q 'name: "external-secrets"' kubernetes/external-secrets/cluster-secret-store.yaml
  grep -q "name: external-secrets" helm/external-secrets/values.yaml
}

@test "external secret store ref matches cluster secret store name" {
  grep -q "name: vault-backend" kubernetes/external-secrets/cluster-secret-store.yaml
  grep -q "name: vault-backend" kubernetes/workloads/sample-deployment.yaml
}

@test "both patterns reference the same secret path" {
  grep -q "team-appdev/api/stripe-key" kubernetes/workloads/sample-deployment.yaml
  grep -q "team-appdev/api/stripe-key" vault/scripts/deploy-sample-apps.sh
}

@test "sidecar uses vault-sa service account matching namespace manifest" {
  grep -q "serviceAccountName: vault-sa" kubernetes/workloads/sample-deployment.yaml
  grep -q "name: vault-sa" kubernetes/namespaces/team-appdev.yaml
}
