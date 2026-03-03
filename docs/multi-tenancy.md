# Multi-Tenancy Design

This document explains how the platform implements multi-tenancy using Vault OSS
with path-based isolation, and compares this approach to Vault Enterprise namespaces.

## Overview

The platform serves three teams, each with isolated secret paths and granular access
policies. Isolation is enforced through a combination of:

1. **KV v2 path prefixes** scoped per team
2. **HCL policies** restricting each team to their own paths
3. **Kubernetes auth method** mapping service accounts to Vault roles/policies
4. **Kubernetes NetworkPolicies** (Calico) for pod-level network segmentation

## Team Structure

| Team | Namespace (K8s) | Vault Path | Use Case |
|------|-----------------|------------|----------|
| Platform | `team-platform` | `secret/team-platform/*` | Infrastructure secrets, TF encryption keys |
| AppDev | `team-appdev` | `secret/team-appdev/*` | Application credentials, API keys, feature flags |
| Data | `team-data` | `secret/team-data/*` | Database credentials (auto-rotated), analytics keys |

All teams also have **read-only** access to `secret/shared/infra/*` for shared
infrastructure configuration (e.g., DNS settings, registry endpoints).

## Vault Path Layout

```
secret/                         # KV v2 secrets engine mount
├── team-platform/              # Platform team secrets
│   ├── terraform/
│   │   └── state-encryption    # Terraform state encryption key
│   ├── registry/
│   │   └── pull-credentials    # Container registry credentials
│   └── certificates/
│       └── wildcard-tls        # Wildcard TLS certificate
├── team-appdev/                # Application development team secrets
│   ├── api/
│   │   ├── stripe-key          # Payment provider API key
│   │   └── sendgrid-key        # Email service API key
│   └── config/
│       └── feature-flags       # Feature flag configuration
├── team-data/                  # Data team secrets
│   ├── databases/
│   │   ├── analytics-ro        # Read-only DB credentials (dynamic)
│   │   └── analytics-rw        # Read-write DB credentials (dynamic)
│   └── pipelines/
│       └── airflow-fernet      # Airflow Fernet encryption key
└── shared/
    └── infra/                  # Shared read-only secrets
        ├── dns-config          # Internal DNS configuration
        └── registry-endpoint   # Container registry URL
```

## Policy Structure

### RBAC Matrix

| Path | team-platform | team-appdev | team-data | vault-admin |
|------|:------------:|:-----------:|:---------:|:-----------:|
| `secret/data/team-platform/*` | CRUD | - | - | CRUD |
| `secret/data/team-appdev/*` | - | CRUD | - | CRUD |
| `secret/data/team-data/*` | - | - | CRUD | CRUD |
| `secret/data/shared/infra/*` | Read | Read | Read | CRUD |
| `database/creds/team-data-*` | - | - | Read | CRUD |
| `pki/issue/internal-cert` | Read | Read | Read | CRUD |
| `sys/*` | - | - | - | CRUD |

### Policy Files

Each team has a dedicated HCL policy file in `vault/policies/`:

- **team-platform.hcl**: Full CRUD on `secret/data/team-platform/*` and metadata,
  read access to `secret/data/shared/infra/*`
- **team-appdev.hcl**: Full CRUD on `secret/data/team-appdev/*` and metadata,
  read access to `secret/data/shared/infra/*`
- **team-data.hcl**: Full CRUD on `secret/data/team-data/*` and metadata,
  read access to `secret/data/shared/infra/*`, read on `database/creds/team-data-*`

### Kubernetes Auth Mapping

```
Kubernetes Service Account          Vault Role              Vault Policy
─────────────────────────          ──────────              ────────────
team-platform/vault-sa       →    role-team-platform   →   team-platform
team-appdev/vault-sa         →    role-team-appdev     →   team-appdev
team-data/vault-sa           →    role-team-data       →   team-data
```

Each Kubernetes namespace has a dedicated service account. The Vault Kubernetes auth
method maps these service accounts to Vault roles, which are bound to the corresponding
policies. A service account in `team-appdev` can only authenticate as `role-team-appdev`,
which grants only the `team-appdev` policy.

## OSS vs Enterprise: Honest Comparison

| Feature | Vault OSS (This Project) | Vault Enterprise |
|---------|--------------------------|------------------|
| Isolation mechanism | Path prefixes + HCL policies | Native namespaces (full isolation) |
| Secrets engine per tenant | Shared mount, different paths | Dedicated mount per namespace |
| Auth method per tenant | Shared auth method, different roles | Dedicated auth method per namespace |
| Policy administration | Single policy namespace | Per-namespace policy delegation |
| Audit logging | Single audit log (filter by path) | Per-namespace audit logs |
| Quotas | Not available | Rate limiting per namespace |
| Performance standby | Not available | Available |
| Sentinel policies | Not available | Available |

### What This Means in Practice

The path-based approach works well for the following reasons:

1. **Isolation is policy-enforced**, not infrastructure-enforced. A misconfigured policy
   could theoretically leak across teams. In Enterprise, namespaces provide hard boundaries.
2. **Audit filtering** requires log post-processing to separate team activity. Enterprise
   provides per-namespace audit devices.
3. **Delegation is limited**: In OSS, a central Vault admin manages all policies. Enterprise
   allows namespace admins to self-manage within their namespace.

For most organizations with 3-10 teams and a dedicated platform team managing Vault,
path-based multi-tenancy is sufficient and saves the Enterprise licensing cost.

## Network Segmentation

In addition to Vault-level isolation, Kubernetes NetworkPolicies (Calico) restrict
pod-to-pod communication:

```yaml
# Each team namespace has a default-deny ingress policy
# Only pods with the correct labels can communicate
# Vault namespace allows ingress from all team namespaces (for API access)
```

This provides defense-in-depth: even if a pod is compromised, it cannot reach
pods in other team namespaces at the network layer.
