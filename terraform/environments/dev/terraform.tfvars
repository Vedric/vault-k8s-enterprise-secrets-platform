project_name    = "vault-k8s"
environment     = "dev"
location        = "westeurope"
subscription_id = ""

aks_node_count     = 3
aks_node_vm_size   = "Standard_B2s"
kubernetes_version = "1.30"

log_retention_days = 30

extra_tags = {
  owner = "platform-engineering"
}
