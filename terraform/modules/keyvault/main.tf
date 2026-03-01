data "azurerm_client_config" "current" {}

# Random suffix for Key Vault global uniqueness (3-24 chars, alphanumeric only)
resource "random_string" "keyvault_suffix" {
  length  = 4
  special = false
  upper   = false
}

locals {
  # Key Vault names: 3-24 chars, alphanumeric and hyphens only
  keyvault_name = "kv-${var.resource_prefix}-${random_string.keyvault_suffix.result}"
}

# -----------------------------------------------------------------------------
# Managed Identity for Vault auto-unseal
# This identity is bound to Vault pods via workload identity in Phase 2.
# -----------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "vault" {
  name                = "id-vault-${var.resource_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Azure Key Vault
# -----------------------------------------------------------------------------

resource "azurerm_key_vault" "main" {
  name                = local.keyvault_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id

  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  # Use access policies (simpler for single-purpose KV)
  rbac_authorization_enabled = false

  network_acls {
    default_action             = "Deny"
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = var.allowed_subnet_ids
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Access Policies
# -----------------------------------------------------------------------------

# Deployer access — full key and secret management for Terraform operations
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Get",
    "List",
    "Create",
    "Delete",
    "Update",
    "Recover",
    "Purge",
    "GetRotationPolicy",
    "SetRotationPolicy",
  ]

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Recover",
    "Purge",
  ]
}

# Vault managed identity — minimal permissions for auto-unseal only
resource "azurerm_key_vault_access_policy" "vault_unseal" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.vault.principal_id

  key_permissions = [
    "Get",
    "WrapKey",
    "UnwrapKey",
  ]
}

# -----------------------------------------------------------------------------
# Auto-Unseal Key
# RSA 2048 key used by Vault to encrypt/decrypt its master key.
# -----------------------------------------------------------------------------

resource "azurerm_key_vault_key" "vault_unseal" {
  name         = "vault-unseal-key"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "wrapKey",
    "unwrapKey",
  ]

  # Rotate the unseal key annually
  expiration_date = timeadd(timestamp(), "8760h")

  depends_on = [azurerm_key_vault_access_policy.deployer]

  lifecycle {
    ignore_changes = [expiration_date]
  }
}
