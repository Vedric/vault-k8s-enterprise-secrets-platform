output "vault_uri" {
  description = "URI of the Key Vault"
  value       = azurerm_key_vault.main.vault_uri
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault"
  value       = azurerm_key_vault.main.id
}

output "key_vault_name" {
  description = "Name of the Key Vault"
  value       = azurerm_key_vault.main.name
}

output "unseal_key_name" {
  description = "Name of the Key Vault key used for Vault auto-unseal"
  value       = azurerm_key_vault_key.vault_unseal.name
}

output "vault_identity_id" {
  description = "Resource ID of the Vault managed identity"
  value       = azurerm_user_assigned_identity.vault.id
}

output "vault_identity_client_id" {
  description = "Client ID of the Vault managed identity"
  value       = azurerm_user_assigned_identity.vault.client_id
}

output "vault_identity_principal_id" {
  description = "Principal ID of the Vault managed identity"
  value       = azurerm_user_assigned_identity.vault.principal_id
}
