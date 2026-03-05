# Vault K8s Enterprise Secrets Platform

[![Terraform CI/CD](https://github.com/Vedric/vault-k8s-enterprise-secrets-platform/actions/workflows/terraform.yml/badge.svg)](https://github.com/Vedric/vault-k8s-enterprise-secrets-platform/actions/workflows/terraform.yml)
![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-blueviolet)
![Vault](https://img.shields.io/badge/Vault-1.17+-yellow)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.32-blue)

Enterprise-grade HashiCorp Vault secrets management platform on Azure Kubernetes Service (AKS). This project demonstrates a production-ready deployment with HA Raft storage, auto-unseal via Azure Key Vault, path-based multi-tenancy, dynamic secret rotation, and dual secret injection patterns (Vault Agent Sidecar + External Secrets Operator).

## Architecture

```
                        +---------------------------+
                        |     Azure West Europe     |
                        +---------------------------+
                        |                           |
        +---------------+---+   +---+---------------+---+
        |   AKS Cluster     |   | Azure Key Vault       |
        | (2x B2s_v2 nodes) |   | (Auto-Unseal)         |
        |                   |   |                       |
        | +---------------+ |   | - RSA 2048 unseal key |
        | | vault-0 (HA)  | |   | - Managed Identity    |
        | | vault-1 (HA)  |<----+ - Workload Identity   |
        | | vault-2 (HA)  | |   |   Federation          |
        | | (Raft storage)| |   +-----------------------+
        | +-------+-------+ |
        |         |          |   +-----------------------+
        | +-------v--------+ |   | Log Analytics         |
        | | Vault Agent    | |   | + Container Insights  |
        | | Injector       | |   +-----------------------+
        | +----------------+ |
        |                    |
        | +----------------+ |
        | | External       | |
        | | Secrets Op.    | |
        | +-------+--------+ |
        |         |          |
        | +-------v--------+ |
        | | App Namespaces | |
        | | - team-platform| |
        | | - team-appdev  | |
        | | - team-data    | |
        | +----------------+ |
        +--------------------+
```

### Vault Secret Paths (Path-Based Multi-Tenancy)

```
secret/
├── team-platform/     # Infrastructure secrets, TF state encryption keys
├── team-appdev/       # Application credentials, API keys
├── team-data/         # Database credentials (auto-rotated)
└── shared/
    └── infra/         # Shared read-only infrastructure secrets
```

> **Note:** This project uses Vault OSS with path-based multi-tenancy. Vault Enterprise
> namespaces are simulated through KV v2 path prefixes combined with granular HCL policies.
> This approach provides equivalent isolation for most use cases while keeping the
> deployment free of licensing costs. See [docs/multi-tenancy.md](docs/multi-tenancy.md)
> for a detailed comparison.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://www.terraform.io/) | >= 1.5 | Infrastructure provisioning |
| [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/) | >= 2.50 | Azure authentication and resource management |
| [Helm](https://helm.sh/) | >= 3.12 | Kubernetes package management |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | >= 1.32 | Kubernetes cluster interaction |
| [bats-core](https://github.com/bats-core/bats-core) | >= 1.10 | Shell-based test framework |
| [tflint](https://github.com/terraform-linters/tflint) | >= 0.50 | Terraform linting |
| [checkov](https://www.checkov.io/) | >= 3.0 | Infrastructure security scanning |

You also need an Azure subscription with **Contributor** role access.

## Quick Start

```bash
# 1. Authenticate to Azure
az login
az account set --subscription "<your-subscription-id>"

# 2. Bootstrap the Terraform state backend (one-time setup)
az group create --name rg-vault-terraform-state --location westeurope
az storage account create \
  --name stvaultk8stfstatedev \
  --resource-group rg-vault-terraform-state \
  --location westeurope \
  --sku Standard_LRS \
  --encryption-services blob
az storage container create \
  --name tfstate \
  --account-name stvaultk8stfstatedev

# 3. Deploy infrastructure
export TF_VAR_subscription_id=$(az account show --query id -o tsv)
make init
make plan    # Review the plan carefully
make apply

# 4. Connect to AKS
az aks get-credentials \
  --resource-group rg-vault-k8s-dev \
  --name aks-vault-k8s-dev

# 5. Deploy Vault HA cluster (reads Terraform outputs automatically)
make vault-deploy

# 6. Initialize the Vault cluster (first time only)
make vault-init
# ⚠ Store recovery keys and root token securely!

# 7. Verify cluster health
kubectl exec -n vault vault-0 -- vault status
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

## Project Roadmap

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Azure Infrastructure (Terraform: AKS, Key Vault, Networking, Monitoring) | Complete |
| 2 | Vault HA Deployment (Helm, Raft storage, auto-unseal, failover validation) | In Progress |
| 3 | Multi-Tenancy & Auth (KV v2 paths, HCL policies, Kubernetes auth method) | Planned |
| 4 | Dynamic Secrets & Rotation (PostgreSQL credentials, PKI certificates) | Planned |
| 5 | Secret Injection Patterns (Vault Agent Sidecar vs External Secrets Operator) | Planned |
| 6 | Observability & Testing (Audit logs, Loki + Grafana, bats test suite, CI/CD) | Planned |

## Cost Estimation (Dev Environment)

| Component | Monthly Cost (EUR) |
|-----------|--------------------|
| AKS control plane | 0 (free tier) |
| 2x Standard_B2s_v2 nodes | ~65 |
| Azure Key Vault (standard) | < 2 |
| Managed disks (2x 32GB LRS) | ~3.5 |
| Log Analytics workspace | ~5-10 |
| **Total** | **~75-80** |
| **Weekends only (~8h/week)** | **~12-15** |

> Tip: Use `make destroy` to tear down infrastructure when not actively working.
> Recreate with `make init && make plan && make apply` in ~15 minutes.

## Key Design Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Vault Edition | OSS | Free; path-based multi-tenancy provides equivalent isolation for this scope |
| Storage Backend | Raft (integrated) | No external Consul dependency, simpler operations, built-in HA |
| Network Plugin | Azure CNI | Pods get VNet IPs, enabling Key Vault service endpoint access |
| Identity | Workload Identity | Successor to Pod Identity (deprecated); OIDC-based, more secure |
| Key Vault Auth | Access Policies | Simpler for single-purpose KV; RBAC preferred in multi-team enterprise setups |
| Network Policy | Calico | Enables pod-level segmentation between tenant namespaces |
| Secret Injection | Both patterns | Demonstrates Vault Agent (in-memory) vs ESO (K8s Secrets) trade-offs |

## Repository Structure

```
.
├── terraform/              # Infrastructure as Code
│   ├── modules/            # Reusable Terraform modules
│   │   ├── aks/            # Azure Kubernetes Service
│   │   ├── keyvault/       # Azure Key Vault + managed identity
│   │   ├── monitoring/     # Log Analytics + Container Insights
│   │   └── networking/     # VNet, subnets, NSGs
│   └── environments/       # Environment-specific tfvars
├── helm/                   # Helm chart values
│   ├── vault/              # Vault HA configuration
│   └── external-secrets/   # External Secrets Operator
├── vault/                  # Vault configuration
│   ├── policies/           # HCL policy files per team
│   ├── config/             # Auth methods, secrets engines
│   └── scripts/            # Initialization and rotation scripts
├── kubernetes/             # Kubernetes manifests
│   ├── namespaces/         # Team namespace definitions
│   ├── rbac/               # Cluster role bindings
│   ├── external-secrets/   # ExternalSecret CRDs
│   └── workloads/          # Demo applications
├── monitoring/             # Observability configuration
│   ├── dashboards/         # Grafana dashboard JSON
│   └── alerts/             # Alert rules
├── tests/                  # Test suites
│   └── bats/               # Shell-based Vault and Terraform tests
└── docs/                   # Project documentation
    ├── architecture.md     # Detailed architecture
    ├── multi-tenancy.md    # Multi-tenancy design
    └── runbooks/           # Operational procedures
```

## Documentation

- [Architecture Overview](docs/architecture.md)
- [Multi-Tenancy Design](docs/multi-tenancy.md)
- [Seal Recovery Runbook](docs/runbooks/seal-recovery.md)
- [Secret Rotation Runbook](docs/runbooks/secret-rotation.md)

## License

MIT
