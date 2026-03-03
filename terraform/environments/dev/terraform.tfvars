project_name    = "vault-k8s"
environment     = "dev"
location        = "westeurope"
subscription_id = ""

aks_node_count     = 2
aks_node_vm_size   = "Standard_B2s_v2"
kubernetes_version = "1.32"

log_retention_days = 30

extra_tags = {
  owner = "platform-engineering"
}
