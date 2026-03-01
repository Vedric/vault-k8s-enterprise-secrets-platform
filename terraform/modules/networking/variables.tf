variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the virtual network"
  type        = list(string)
}

variable "aks_subnet_prefix" {
  description = "CIDR prefix for the AKS subnet"
  type        = string
}

variable "vault_subnet_prefix" {
  description = "CIDR prefix for the Vault internal services subnet"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
