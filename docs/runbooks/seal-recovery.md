# Runbook: Vault Seal Recovery

## Overview

This runbook covers the procedure for recovering a sealed Vault cluster. Vault uses
auto-unseal via Azure Key Vault, so manual unsealing should rarely be needed. However,
if the auto-unseal mechanism fails (e.g., Key Vault access is revoked), all Vault pods
will enter a sealed state and stop serving requests.

## Symptoms

- Vault pods in `CrashLoopBackOff` or `Running` but not `Ready`
- `vault status` returns `Sealed: true`
- Applications receiving `503 Service Unavailable` from Vault
- Alerts firing on Vault health check failures
- Kubernetes events showing liveness probe failures on Vault pods

## Diagnosis

### Step 1: Check Vault Seal Status

```bash
kubectl exec -n vault vault-0 -- vault status
```

Expected output when sealed:

```
Key                      Value
---                      -----
Recovery Seal Type       azurekeyvault
Initialized              true
Sealed                   true    <-- PROBLEM
...
```

### Step 2: Check Pod Logs

```bash
kubectl logs -n vault vault-0 --tail=50
kubectl logs -n vault vault-1 --tail=50
kubectl logs -n vault vault-2 --tail=50
```

Look for errors containing:
- `"error unsealing"` -- Auto-unseal is failing
- `"azure key vault"` or `"keyvault"` -- Key Vault connectivity issues
- `"managed identity"` or `"IMDS"` -- Identity/authentication failures
- `"network"` or `"timeout"` -- Network connectivity problems

### Step 3: Verify Key Vault Access

```bash
# Check if the managed identity can reach Key Vault
az keyvault key show \
  --vault-name <keyvault-name> \
  --name vault-unseal-key

# Check access policies
az keyvault show \
  --name <keyvault-name> \
  --query "properties.accessPolicies"
```

### Step 4: Verify Workload Identity

```bash
# Check service account annotations
kubectl get sa vault -n vault -o yaml | grep azure.workload.identity

# Check federated identity credential
az identity federated-credential list \
  --identity-name <identity-name> \
  --resource-group <resource-group>
```

## Recovery Procedures

### Scenario A: Key Vault Access Restored (Most Common)

If the issue was temporary (network blip, Key Vault throttling):

```bash
# Restart Vault pods one at a time to trigger auto-unseal
kubectl delete pod vault-0 -n vault
# Wait for vault-0 to become Ready
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=120s

kubectl delete pod vault-1 -n vault
kubectl wait --for=condition=Ready pod/vault-1 -n vault --timeout=120s

kubectl delete pod vault-2 -n vault
kubectl wait --for=condition=Ready pod/vault-2 -n vault --timeout=120s
```

### Scenario B: Key Vault Access Policy Missing

```bash
# Re-apply Terraform to restore access policies
cd terraform
terraform plan -var-file=environments/dev/terraform.tfvars
terraform apply -var-file=environments/dev/terraform.tfvars

# Then restart pods as in Scenario A
```

### Scenario C: Managed Identity Deleted or Unbound

```bash
# Re-apply Terraform to recreate the identity and federation
cd terraform
terraform plan -var-file=environments/dev/terraform.tfvars
terraform apply -var-file=environments/dev/terraform.tfvars

# Re-deploy Vault Helm chart to rebind the service account
helm upgrade vault hashicorp/vault \
  -n vault \
  -f helm/vault/values.yaml
```

### Scenario D: Recovery Keys (Last Resort)

If auto-unseal cannot be restored and the cluster must serve requests immediately,
use the recovery keys generated during `vault operator init`:

```bash
# Recovery keys are stored in a secure location (documented during Phase 2 init)
# Use 3 of 5 recovery keys to unseal each node

kubectl exec -n vault vault-0 -- vault operator unseal <recovery-key-1>
kubectl exec -n vault vault-0 -- vault operator unseal <recovery-key-2>
kubectl exec -n vault vault-0 -- vault operator unseal <recovery-key-3>

# Repeat for vault-1 and vault-2
```

> **Warning:** This is a temporary measure. Recovery keys should only be used
> while the root cause of the auto-unseal failure is being resolved. Fix the
> auto-unseal mechanism and restart pods to return to normal operation.

## Post-Recovery Verification

```bash
# Verify all pods are unsealed and ready
kubectl get pods -n vault -l app.kubernetes.io/name=vault

# Verify Raft cluster health
kubectl exec -n vault vault-0 -- vault operator raft list-peers

# Verify a secret can be read
kubectl exec -n vault vault-0 -- vault kv get secret/shared/infra/dns-config

# Verify leader election
kubectl exec -n vault vault-0 -- vault status | grep "HA Mode"
```

## Escalation

If none of the above procedures restore the cluster:

1. Check Azure service health for Key Vault outages in the deployment region
2. Review Azure Activity Log for unauthorized changes to the Key Vault or identity
3. Contact HashiCorp support (if under a support contract)
4. As a last resort, re-initialize Vault from backup (data loss for any secrets
   not backed up -- see disaster recovery documentation)

## Prevention

- Monitor Key Vault access with Azure Monitor alerts
- Set up Vault seal status alerts in Grafana (Phase 6)
- Regularly validate the managed identity federation binding
- Keep recovery keys in a secure, offline location (e.g., hardware security module)
- Test seal recovery procedure quarterly
