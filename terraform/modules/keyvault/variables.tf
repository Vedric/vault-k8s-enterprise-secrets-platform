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

variable "allowed_subnet_ids" {
  description = "List of subnet IDs allowed to access Key Vault via service endpoints"
  type        = list(string)
}

variable "deployer_ip_addresses" {
  description = "List of deployer public IPs (CIDR notation) allowed through Key Vault firewall"
  type        = list(string)
  default     = []
}

variable "aks_oidc_issuer_url" {
  description = "OIDC issuer URL from the AKS cluster, used for workload identity federation"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
