data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# AKS Cluster
# -----------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.resource_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "aks-${var.resource_prefix}"
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # Workload identity and OIDC -- required for Vault-to-Key Vault authentication
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Disable local admin account -- enforce AAD authentication only
  local_account_disabled = true

  # Automatic patch upgrades for security fixes
  automatic_upgrade_channel = "patch"

  default_node_pool {
    name            = "default"
    node_count      = var.node_count
    vm_size         = var.node_vm_size
    vnet_subnet_id  = var.aks_subnet_id
    os_disk_size_gb = 30
    os_disk_type    = "Managed"
    tags            = var.tags

    upgrade_settings {
      max_surge = "1"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    # Azure CNI: pods get real VNet IPs for Key Vault service endpoint access
    network_plugin = "azure"
    # Calico: enables NetworkPolicies for pod-level segmentation between teams
    network_policy = "calico"
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }

  oms_agent {
    log_analytics_workspace_id = var.log_analytics_id
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  lifecycle {
    ignore_changes = [
      # Kubernetes version may be upgraded outside of Terraform
      kubernetes_version,
      default_node_pool[0].upgrade_settings,
    ]
  }
}

# -----------------------------------------------------------------------------
# Role Assignment
# AKS needs Network Contributor on the subnet to manage load balancers
# and route tables for Azure CNI.
# -----------------------------------------------------------------------------

resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = var.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.identity[0].principal_id
}
