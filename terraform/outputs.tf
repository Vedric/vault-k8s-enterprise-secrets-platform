# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

output "vnet_id" {
  description = "ID of the virtual network"
  value       = module.networking.vnet_id
}

# -----------------------------------------------------------------------------
# AKS
# -----------------------------------------------------------------------------

output "aks_cluster_name" {
  description = "Name of the AKS cluster"
  value       = module.aks.cluster_name
}

output "aks_kubeconfig_command" {
  description = "Azure CLI command to get AKS credentials"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${module.aks.cluster_name}"
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL for the AKS cluster (needed for workload identity federation)"
  value       = module.aks.oidc_issuer_url
}

# -----------------------------------------------------------------------------
# Key Vault
# -----------------------------------------------------------------------------

output "keyvault_uri" {
  description = "URI of the Azure Key Vault for Vault auto-unseal"
  value       = module.keyvault.vault_uri
}

output "keyvault_unseal_key_name" {
  description = "Name of the Key Vault key used for Vault auto-unseal"
  value       = module.keyvault.unseal_key_name
}

output "vault_identity_client_id" {
  description = "Client ID of the managed identity for Vault to access Key Vault"
  value       = module.keyvault.vault_identity_client_id
}

output "keyvault_name" {
  description = "Name of the Azure Key Vault (for Vault seal configuration)"
  value       = module.keyvault.key_vault_name
}

output "tenant_id" {
  description = "Azure AD tenant ID (for Vault seal configuration)"
  value       = module.keyvault.tenant_id
}
