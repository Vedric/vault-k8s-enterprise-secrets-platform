# Architecture Overview

This document describes the architecture of the Vault K8s Enterprise Secrets Platform,
covering component interactions, network topology, identity flows, and storage design.

## Component Diagram

```
+------------------------------------------------------------------+
|                        Azure West Europe                         |
+------------------------------------------------------------------+
|                                                                  |
|  +-----------------------------+  +----------------------------+ |
|  | Resource Group              |  | Terraform State            | |
|  | rg-vault-k8s-dev            |  | rg-vault-terraform-state   | |
|  |                             |  |                            | |
|  |  +---VNet (10.0.0.0/16)--+ |  | - Storage Account          | |
|  |  |                       | |  | - Blob Container (tfstate) | |
|  |  | snet-aks (10.0.1.0/24)| |  +----------------------------+ |
|  |  |   AKS Cluster         | |                                  |
|  |  |   (3x B2s nodes)      | |                                  |
|  |  |                       | |                                  |
|  |  | snet-vault             | |                                  |
|  |  |   (10.0.2.0/24)       | |                                  |
|  |  |   (reserved)          | |                                  |
|  |  +-----------+-----------+ |                                  |
|  |              |             |                                  |
|  |  +-----------v-----------+ |                                  |
|  |  | Azure Key Vault       | |                                  |
|  |  | (service endpoint)    | |                                  |
|  |  | - RSA 2048 unseal key | |                                  |
|  |  +-----------------------+ |                                  |
|  |                             |                                  |
|  |  +-----------------------+  |                                  |
|  |  | Log Analytics         |  |                                  |
|  |  | + Container Insights  |  |                                  |
|  |  +-----------------------+  |                                  |
|  +-----------------------------+                                  |
+------------------------------------------------------------------+
```

## Network Topology

### Virtual Network Layout

| Subnet | CIDR | Purpose | Service Endpoints |
|--------|------|---------|-------------------|
| `snet-aks` | 10.0.1.0/24 | AKS node pool and pod IPs (Azure CNI) | Microsoft.KeyVault, Microsoft.Storage |
| `snet-vault` | 10.0.2.0/24 | Reserved for future Vault-specific infrastructure | Microsoft.KeyVault |

### Why Azure CNI?

Azure CNI assigns real VNet IP addresses to every pod. This is critical because:

1. **Key Vault service endpoints** restrict access by source subnet. With overlay networking,
   pod traffic would appear to originate from node IPs only, reducing isolation granularity.
2. **NSG rules** can target specific pod IPs for fine-grained network segmentation.
3. **Subnet sizing**: A /24 provides 251 usable IPs. With 3 nodes and a max of 30 pods/node,
   peak usage is ~93 IPs, leaving headroom for scaling.

### Network Security Groups

Both subnets have NSGs with the following key rules:

| Rule | Direction | Port | Source | Action | Rationale |
|------|-----------|------|--------|--------|-----------|
| AllowVaultAPI | Inbound | 8200 | VirtualNetwork | Allow | Vault API access from within VNet |
| AllowVaultCluster | Inbound | 8201 | VirtualNetwork | Allow | Raft replication between Vault peers |
| DenyInternetInbound | Inbound | * | Internet | Deny | Block all direct internet access |

AKS manages its own outbound rules for pulling images and communicating with the API server.

## Identity and Access Flow

```
                    Workload Identity Federation
+----------+       (OIDC token exchange)        +-----------------+
| Vault Pod| ------------------------------------| Azure Key Vault |
| (in AKS) |       azurerm_user_assigned_       | (auto-unseal)   |
|          |       identity.vault               |                 |
+----------+                                    +-----------------+
     |
     | uses Service Account Token
     | (projected via workload identity webhook)
     v
+--------------------+
| K8s Service Account|
| (vault namespace)  |
| annotated with     |
| azure.workload.    |
| identity/client-id |
+--------------------+
```

### How Workload Identity Works

1. AKS exposes an **OIDC issuer** endpoint (enabled via `oidc_issuer_enabled = true`).
2. A **federated identity credential** links the Kubernetes service account to the Azure
   managed identity (configured in Phase 2).
3. The workload identity webhook injects a projected service account token into the Vault pod.
4. Vault exchanges this token for an Azure AD access token via the OIDC token exchange flow.
5. The Azure AD token authenticates against Key Vault to perform `wrapKey`/`unwrapKey`
   operations for auto-unseal.

This eliminates the need for any static credentials in the Vault configuration.

## Storage Architecture (Raft Integrated Storage)

```
+----------+     +----------+     +----------+
| vault-0  |<--->| vault-1  |<--->| vault-2  |
| (leader) |     | (follower)|    | (follower)|
| PVC 10Gi |     | PVC 10Gi  |    | PVC 10Gi  |
+----------+     +----------+     +----------+
     |                |                |
     v                v                v
 Azure Disk       Azure Disk       Azure Disk
 (Standard LRS)   (Standard LRS)   (Standard LRS)
```

### Raft Consensus

- **Leader election**: Vault uses the Raft consensus protocol. One node is elected leader;
  the other two are followers. All writes go through the leader and are replicated.
- **Quorum**: Requires 2/3 nodes to be available (majority). The cluster survives one node
  failure without data loss.
- **Failover**: If the leader fails, remaining nodes elect a new leader within seconds.
  During election, the cluster is temporarily read-only.
- **Network partition**: A partitioned follower cannot serve requests. If the leader is
  partitioned from both followers, the two followers elect a new leader.

### Why Raft over Consul?

| Factor | Raft | Consul |
|--------|------|--------|
| Operational complexity | Lower (built-in) | Higher (separate cluster) |
| Additional infrastructure | None | 3-5 Consul servers |
| Cost | $0 | ~$50-100/month for Consul nodes |
| Feature parity | Full for secrets management | Adds service mesh capabilities |

For a dedicated secrets management platform, Raft provides everything needed without
the operational overhead of a separate Consul cluster.

## Secret Flow: Vault to Application

### Pattern 1: Vault Agent Sidecar Injection

```
Pod Lifecycle:
1. Pod is created with vault annotations
2. Mutating webhook injects init + sidecar containers
3. Init container authenticates to Vault (K8s auth)
4. Sidecar renders secrets to shared memory volume
5. Application reads secrets from /vault/secrets/
6. Sidecar refreshes secrets before TTL expiry

Pros: Secrets never stored as K8s Secrets (in-memory only)
Cons: Adds a sidecar container per pod (resource overhead)
```

### Pattern 2: External Secrets Operator (ESO)

```
ESO Lifecycle:
1. ExternalSecret CR references a Vault path
2. ESO controller authenticates to Vault
3. ESO creates/updates a native K8s Secret
4. Pod mounts the K8s Secret as a volume or env var
5. ESO periodically refreshes the K8s Secret

Pros: No sidecar needed, works with any workload
Cons: Secrets stored as K8s Secrets (base64, not encrypted at rest by default)
```

### When to Use Which

| Criteria | Vault Agent Sidecar | External Secrets Operator |
|----------|--------------------|-----------------------------|
| Security sensitivity | High (secrets in-memory only) | Medium (K8s Secrets exist on etcd) |
| Resource overhead | Higher (+1 container/pod) | Lower (single operator) |
| Application changes | None (file-based) | None (standard K8s Secret) |
| Secret refresh | Real-time (sidecar watches TTL) | Polling interval (configurable) |
| Kubernetes-native | No (Vault-specific annotations) | Yes (CRDs, GitOps friendly) |
