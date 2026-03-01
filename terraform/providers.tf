provider "azurerm" {
  features {
    key_vault {
      # Prevent accidental permanent deletion of Key Vault
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      # Allow clean terraform destroy without manual resource cleanup
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

provider "azuread" {}
