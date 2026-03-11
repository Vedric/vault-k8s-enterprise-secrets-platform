# Dynamic Secrets Architecture

## Overview

Phase 4 adds two Vault secrets engines that generate short-lived, automatically
rotated credentials -- eliminating long-lived static secrets for database access
and internal TLS.

| Engine | Mount | Purpose |
|--------|-------|---------|
| Database | `database/` | Dynamic PostgreSQL credentials with automatic revocation |
| PKI | `pki/` | Internal CA for short-lived TLS certificates |

## Architecture

```
                         ┌─────────────────────┐
                         │   Application Pod    │
                         │   (team-data NS)     │
                         └──────┬───────────────┘
                                │ 1. Request credential
                                │    (K8s auth → team-data policy)
                                ▼
                         ┌─────────────────────┐
                         │       Vault          │
                         │   database engine    │
                         └──────┬───────────────┘
                                │ 2. CREATE ROLE with password
                                │    (TTL: 1h)
                                ▼
                         ┌─────────────────────┐
                         │     PostgreSQL       │
                         │   (database NS)      │
                         └─────────────────────┘
                                │
                         3. On TTL expiry: DROP ROLE
                            (automatic revocation)
```

## Database Secrets Engine

### Connection

- **Host**: `postgresql.database.svc.cluster.local:5432`
- **Database**: `vault_db`
- **Plugin**: `postgresql-database-plugin` (built into Vault 1.17.6)
- **SSL**: Disabled (in-cluster traffic only, NetworkPolicy enforced)

### Dynamic Roles

| Role | SQL Grants | Default TTL | Max TTL |
|------|-----------|-------------|---------|
| `team-data-readonly` | `SELECT` on all tables in `public` schema | 1 hour | 24 hours |
| `team-data-readwrite` | `SELECT`, `INSERT`, `UPDATE`, `DELETE` on all tables in `public` schema | 1 hour | 24 hours |

### Credential Lifecycle

1. **Request**: Application (or operator) calls `vault read database/creds/team-data-readonly`
2. **Create**: Vault connects to PostgreSQL and creates a temporary role with a random password
3. **Use**: Application uses the credential for the TTL duration
4. **Revoke**: When the lease expires (or is manually revoked), Vault drops the PostgreSQL role
5. **Rotate root**: After initial setup, `vault write -f database/rotate-root/postgresql` rotates
   the admin password so only Vault knows it

### Usage

```bash
# Generate a readonly credential (1h TTL)
vault read database/creds/team-data-readonly

# Generate a readwrite credential (1h TTL)
vault read database/creds/team-data-readwrite

# Manually revoke all active leases
vault lease revoke -prefix database/creds/team-data-readonly
vault lease revoke -prefix database/creds/team-data-readwrite

# Emergency root password rotation
make vault-rotate-db
```

### Access Control

Only `team-data` policy grants access to `database/creds/*`. Other teams
(`team-platform`, `team-appdev`) cannot generate database credentials.

## PKI Secrets Engine

### Certificate Authority

- **CN**: `Vault K8s Internal CA`
- **Type**: Internal root CA (no intermediate -- dev scope)
- **TTL**: 10 years (87,600 hours)
- **Key**: RSA 2048-bit

### Certificate Role

| Role | Allowed Domains | Subdomains | Max TTL | Key Type |
|------|----------------|------------|---------|----------|
| `internal-cert` | `internal` | Yes | 30 days (720h) | RSA 2048 |

### Usage

```bash
# Issue a certificate for an internal service
vault write pki/issue/internal-cert \
  common_name="myapp.internal" \
  ttl="24h"

# Read the CA certificate
vault read pki/cert/ca
```

### Access Control

All three team policies (`team-platform`, `team-appdev`, `team-data`) can issue
certificates via `pki/issue/internal-cert` and read the CA at `pki/cert/ca`.

## Network Security

PostgreSQL access is restricted by a Kubernetes NetworkPolicy in the `database`
namespace:

- **Allowed ingress**: Only from `vault` namespace (secrets engine) and `team-data`
  namespace (application access) on TCP port 5432
- **All other namespaces**: Blocked

## Setup

```bash
# Deploy PostgreSQL (generates + stores admin password in Vault)
make postgresql-deploy

# Configure database and PKI engines
make vault-dynamic-secrets

# Or run everything from scratch
make vault-full-setup
```

## Reference Configuration

Declarative configuration references are stored in `vault/config/secrets-engines/`:

- `database.json` -- Database engine connection, roles, and TTL settings
- `pki.json` -- PKI CA configuration, URLs, and role settings

These files document the intended state. The actual configuration is applied by
`vault/scripts/configure-dynamic-secrets.sh`.

## Troubleshooting

### Dynamic credential generation fails

```bash
# Check if the database engine is enabled
vault secrets list | grep database

# Check the connection configuration
vault read database/config/postgresql

# Verify PostgreSQL is reachable from Vault
kubectl exec -n vault vault-0 -- \
  nc -zv postgresql.database.svc.cluster.local 5432
```

### Certificate issuance fails

```bash
# Check if the PKI engine is enabled
vault secrets list | grep pki

# Verify the CA exists
vault read pki/cert/ca

# Check the role configuration
vault read pki/roles/internal-cert
```

### Lease limit reached

```bash
# List active leases
vault list sys/leases/lookup/database/creds/team-data-readonly

# Revoke expired leases
vault lease revoke -prefix database/creds/
```
