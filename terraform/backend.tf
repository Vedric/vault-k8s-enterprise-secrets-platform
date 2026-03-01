# Remote state stored in Azure Blob Storage.
# Backend values are injected via -backend-config=environments/<env>/backend.tfvars
#
# Bootstrap the state backend before first use:
#   az group create --name rg-vault-terraform-state --location westeurope
#   az storage account create --name stvaultk8stfstatedev \
#     --resource-group rg-vault-terraform-state --location westeurope \
#     --sku Standard_LRS --encryption-services blob
#   az storage container create --name tfstate --account-name stvaultk8stfstatedev

terraform {
  backend "azurerm" {}
}
