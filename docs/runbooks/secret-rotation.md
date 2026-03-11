# Runbook: Secret Rotation

## Overview

This runbook covers both scheduled and emergency secret rotation procedures for
the platform. The Vault database secrets engine handles automatic rotation for
PostgreSQL credentials. Manual rotation is needed for static secrets (API keys,
certificates) and emergency scenarios.

## Secret Types and Rotation Strategy

| Secret Type | Rotation Method | Frequency | Managed By |
|-------------|----------------|-----------|------------|
| PostgreSQL credentials | Vault database secrets engine (automatic) | 1 hour TTL | Vault |
| TLS certificates | Vault PKI secrets engine (automatic) | 30 days | Vault |
| API keys (Stripe, SendGrid) | Manual rotation via Vault CLI/API | 90 days | Team leads |
| Vault root token | Manual rotation | On demand | Vault admin |
| Azure Key Vault unseal key | Azure Key Vault key rotation | 365 days | Platform team |

## Scheduled Rotation

### Database Credentials (Automatic)

The Vault database secrets engine generates short-lived credentials with a 1-hour TTL.
No manual intervention is needed under normal operation.

> For full architecture details, see [Dynamic Secrets Architecture](../dynamic-secrets.md).
> Initial setup: `vault/scripts/configure-dynamic-secrets.sh` or `make vault-dynamic-secrets`.

**Verification:**

```bash
# Check current lease for team-data database credentials
kubectl exec -n vault vault-0 -- \
  vault list sys/leases/lookup/database/creds/team-data-readonly

# Generate a new credential to verify the engine is working
kubectl exec -n vault vault-0 -- \
  vault read database/creds/team-data-readonly
```

**Troubleshooting:**

```bash
# Check database connection configuration
kubectl exec -n vault vault-0 -- \
  vault read database/config/postgresql

# Verify PostgreSQL is reachable from Vault
kubectl exec -n vault vault-0 -- \
  vault write -f database/rotate-root/postgresql
```

### TLS Certificates (Automatic via PKI)

Internal TLS certificates are issued by the Vault PKI secrets engine with a 30-day TTL.
Applications using the Vault Agent sidecar receive renewed certificates automatically.

**Verification:**

```bash
# Check PKI CA certificate expiry
kubectl exec -n vault vault-0 -- \
  vault read pki/cert/ca

# Issue a test certificate
kubectl exec -n vault vault-0 -- \
  vault write pki/issue/internal-cert \
    common_name="test.internal" \
    ttl="24h"
```

### Static Secrets (Manual -- 90-day cycle)

Static secrets (API keys, third-party credentials) require manual rotation by the
responsible team. The platform enforces a 90-day rotation policy through monitoring.

**Procedure:**

```bash
# 1. Generate new credential from the external provider
# 2. Update the secret in Vault
kubectl exec -n vault vault-0 -- \
  vault kv put secret/team-appdev/api/stripe-key \
    api_key="<new-key>" \
    rotated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    rotated_by="<operator-name>"

# 3. Verify applications pick up the new secret
# For sidecar injection: secrets refresh automatically within the TTL
# For ESO: wait for the sync interval (default 1 minute)

# 4. Revoke the old credential with the external provider
```

## Emergency Rotation

### Scenario: Compromised Database Credentials

**Immediate actions (within 15 minutes):**

```bash
# 1. Rotate the root database credentials immediately
kubectl exec -n vault vault-0 -- \
  vault write -f database/rotate-root/postgresql

# 2. Revoke ALL active leases for the compromised path
kubectl exec -n vault vault-0 -- \
  vault lease revoke -prefix database/creds/team-data-readonly

kubectl exec -n vault vault-0 -- \
  vault lease revoke -prefix database/creds/team-data-readwrite

# 3. Verify applications reconnect with new credentials
# Applications using dynamic secrets will automatically get new credentials
# after their current lease expires or is revoked
```

### Scenario: Compromised API Key

```bash
# 1. Immediately update the secret in Vault
kubectl exec -n vault vault-0 -- \
  vault kv put secret/team-appdev/api/stripe-key \
    api_key="<emergency-replacement-key>" \
    rotated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    rotated_by="<operator-name>" \
    rotation_reason="emergency-compromise"

# 2. Revoke the compromised key with the external provider

# 3. Force-refresh ESO-managed secrets
kubectl annotate externalsecret -n team-appdev stripe-key \
  force-sync="$(date +%s)" --overwrite
```

### Scenario: Compromised Vault Root Token

```bash
# 1. Generate a new root token using recovery keys
kubectl exec -n vault vault-0 -- vault operator generate-root -init

# Follow the prompts with 3 of 5 recovery keys
kubectl exec -n vault vault-0 -- \
  vault operator generate-root \
    -nonce="<nonce-from-init>"

# 2. Revoke the compromised root token
VAULT_TOKEN="<new-root-token>" \
kubectl exec -n vault vault-0 -- \
  vault token revoke "<compromised-root-token>"

# 3. Immediately generate a new root token and store securely
# 4. Revoke the temporary root token used for recovery
```

## Post-Rotation Verification

After any rotation event, verify:

```bash
# 1. Check Vault audit log for the rotation event
kubectl exec -n vault vault-0 -- \
  vault audit list

# 2. Verify applications are healthy
kubectl get pods -n team-platform
kubectl get pods -n team-appdev
kubectl get pods -n team-data

# 3. Check for authentication failures in application logs
kubectl logs -n team-data -l app=sample-app --tail=20

# 4. Verify the new secret is accessible
kubectl exec -n vault vault-0 -- \
  vault kv get -field=rotated_at secret/team-appdev/api/stripe-key
```

## Impact Assessment Checklist

Before rotating any secret, assess the impact:

- [ ] Identify all consumers of the secret (applications, pipelines, external services)
- [ ] Confirm that consumers support credential refresh without restart
- [ ] Check for any hardcoded references to the old secret (should not exist, but verify)
- [ ] Notify affected teams via the appropriate communication channel
- [ ] Schedule rotation during a low-traffic window (if non-emergency)
- [ ] Prepare a rollback plan in case the new credential fails
- [ ] Monitor application health metrics for 30 minutes after rotation
