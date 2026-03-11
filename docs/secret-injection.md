# Secret Injection Patterns

## Overview

Phase 5 implements two complementary patterns for delivering Vault secrets to
Kubernetes workloads. Both patterns are deployed side-by-side in the `team-appdev`
namespace, consuming the same secret to demonstrate the trade-offs.

| Pattern | Component | Secret Storage | Refresh |
|---------|-----------|---------------|---------|
| Vault Agent Sidecar | Injector mutating webhook | In-memory (`/vault/secrets/`) | Automatic (agent polls Vault) |
| External Secrets Operator | ESO controller + ClusterSecretStore | K8s Secret (etcd) | Configurable interval (default: 1m) |

## Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │              Vault (vault NS)               │
                    │  KV v2: secret/team-appdev/api/stripe-key  │
                    └──────┬──────────────────┬──────────────────┘
                           │                  │
          Pattern 1        │                  │        Pattern 2
     (Vault Agent Sidecar) │                  │   (External Secrets Operator)
                           │                  │
                    ┌──────▼──────┐    ┌──────▼──────────────┐
                    │ Vault Agent │    │ ESO Controller       │
                    │ (sidecar)   │    │ (external-secrets NS)│
                    └──────┬──────┘    └──────┬──────────────┘
                           │                  │
                    ┌──────▼──────┐    ┌──────▼──────────────┐
                    │ /vault/     │    │ K8s Secret           │
                    │ secrets/    │    │ sample-app-eso-      │
                    │ config      │    │ secrets               │
                    │ (in-memory) │    │ (in etcd)            │
                    └──────┬──────┘    └──────┬──────────────┘
                           │                  │
                    ┌──────▼──────┐    ┌──────▼──────────────┐
                    │ sample-app- │    │ sample-app-eso       │
                    │ sidecar     │    │ (envFrom secretRef)  │
                    │ (file read) │    │                      │
                    └─────────────┘    └─────────────────────┘
```

## Pattern 1: Vault Agent Sidecar

### How It Works

The Vault Agent Injector runs as a mutating admission webhook. When a pod has
the annotation `vault.hashicorp.com/agent-inject: "true"`, the webhook injects
a sidecar container that:

1. Authenticates to Vault via Kubernetes auth (using the pod's service account)
2. Fetches the specified secrets
3. Renders them to shared memory at `/vault/secrets/`
4. Continuously polls for updates

### Annotations

```yaml
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "team-appdev"
  vault.hashicorp.com/agent-inject-secret-config: "secret/data/team-appdev/api/stripe-key"
  vault.hashicorp.com/agent-inject-template-config: |
    {{- with secret "secret/data/team-appdev/api/stripe-key" -}}
    STRIPE_API_KEY={{ .Data.data.api_key }}
    {{- end }}
```

### Security Properties

- Secrets never stored in etcd (in-memory only via tmpfs)
- Each pod authenticates independently with its own service account
- Secret access is governed by Vault policies bound to the K8s auth role
- Sidecar process is isolated from the application container

### Trade-offs

- Adds resource overhead per pod (~75m CPU / 64Mi RAM for the sidecar)
- Application must read secrets from a file, not environment variables
- Requires the Vault Agent Injector to be running in the cluster

## Pattern 2: External Secrets Operator

### How It Works

ESO runs as a controller that watches `ExternalSecret` custom resources. When
an ExternalSecret is created:

1. ESO authenticates to Vault via the `ClusterSecretStore` (K8s auth with the
   `external-secrets` service account)
2. Fetches the referenced secret from Vault
3. Creates or updates a native Kubernetes Secret
4. Re-syncs on the configured refresh interval

### ClusterSecretStore

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
```

### ExternalSecret

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: sample-app-secrets
  namespace: team-appdev
spec:
  refreshInterval: "1m"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: sample-app-eso-secrets
  data:
    - secretKey: STRIPE_API_KEY
      remoteRef:
        key: team-appdev/api/stripe-key
        property: api_key
```

### Security Properties

- Secrets are stored as native K8s Secrets (in etcd, encrypted at rest if configured)
- Access control has two layers: Vault policy (ESO read-only) + K8s RBAC (who can
  create ExternalSecret CRs in each namespace)
- No sidecar per pod -- single controller for all ExternalSecrets
- GitOps-friendly: ExternalSecret CRs can be committed to the repo

### Trade-offs

- Secrets pass through etcd (less secure than in-memory sidecar approach)
- Single ESO controller is a potential bottleneck at scale
- Refresh interval introduces eventual consistency (1-minute delay by default)

## Comparison

| Aspect | Vault Agent Sidecar | External Secrets Operator |
|--------|-------------------|--------------------------|
| Secret storage | In-memory (tmpfs) | K8s Secret (etcd) |
| Per-pod overhead | ~75m CPU / 64Mi RAM | None |
| Auth model | Pod SA → Vault role | ESO SA → Vault role |
| Refresh | Continuous polling | Configurable interval |
| Secret format | File at `/vault/secrets/` | K8s Secret (env vars / volume) |
| GitOps support | Annotations on pods | ExternalSecret CRs |
| Best for | High-security workloads | Standard workloads, GitOps pipelines |

## ESO Authentication Model

The `external-secrets` Vault policy grants read-only access to all `secret/data/*`
and `secret/metadata/*` paths. This broad access is secure because:

1. **K8s RBAC** controls which namespaces can deploy ExternalSecret CRs
2. Each ExternalSecret specifies the exact secret path to sync
3. Teams cannot create ExternalSecret CRs in other teams' namespaces
4. ESO only reads -- it cannot modify or delete Vault secrets

## Setup

```bash
# Deploy ESO and configure Vault auth binding
make eso-deploy

# Deploy sample apps demonstrating both patterns
make sample-deploy

# Or run both in sequence
make injection-setup
```

## Troubleshooting

### Sidecar not injecting secrets

```bash
# Check the injector is running
kubectl get pods -n vault -l app.kubernetes.io/name=vault-agent-injector

# Check pod annotations are correct
kubectl get pod -n team-appdev -l app=sample-app-sidecar -o yaml | grep vault.hashicorp

# Check sidecar logs
kubectl logs -n team-appdev -l app=sample-app-sidecar -c vault-agent
```

### ESO not syncing secrets

```bash
# Check ClusterSecretStore health
kubectl get clustersecretstore vault-backend -o yaml

# Check ExternalSecret status
kubectl get externalsecret -n team-appdev sample-app-secrets -o yaml

# Check ESO operator logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

### Secret not appearing in pod

```bash
# For sidecar: check the rendered file
kubectl exec -n team-appdev -l app=sample-app-sidecar -c app -- cat /vault/secrets/config

# For ESO: check the K8s Secret
kubectl get secret -n team-appdev sample-app-eso-secrets -o jsonpath='{.data}' | jq .
```
