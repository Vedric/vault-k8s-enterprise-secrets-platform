locals {
  common_tags = merge(
    {
      project     = var.project_name
      environment = var.environment
      managed_by  = "terraform"
    },
    var.extra_tags,
  )
  resource_prefix = "${var.project_name}-${var.environment}"
}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.resource_prefix}"
  location = var.location
  tags     = local.common_tags
}

# -----------------------------------------------------------------------------
# Modules
# -----------------------------------------------------------------------------

module "networking" {
  source = "./modules/networking"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  resource_prefix     = local.resource_prefix
  vnet_address_space  = var.vnet_address_space
  aks_subnet_prefix   = var.aks_subnet_prefix
  vault_subnet_prefix = var.vault_subnet_prefix
  tags                = local.common_tags
}

module "monitoring" {
  source = "./modules/monitoring"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  resource_prefix     = local.resource_prefix
  retention_in_days   = var.log_retention_days
  tags                = local.common_tags
}

module "keyvault" {
  source = "./modules/keyvault"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  resource_prefix     = local.resource_prefix
  allowed_subnet_ids = [
    module.networking.aks_subnet_id,
    module.networking.vault_subnet_id,
  ]
  tags = local.common_tags
}

module "aks" {
  source = "./modules/aks"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  resource_prefix     = local.resource_prefix
  aks_subnet_id       = module.networking.aks_subnet_id
  node_count          = var.aks_node_count
  node_vm_size        = var.aks_node_vm_size
  kubernetes_version  = var.kubernetes_version
  log_analytics_id    = module.monitoring.log_analytics_workspace_id
  tags                = local.common_tags
}
