.PHONY: help init plan apply destroy fmt validate lint security-scan \
	vault-deploy vault-deploy-upgrade vault-deploy-dry-run \
	vault-init vault-configure vault-setup \
	postgresql-deploy vault-dynamic-secrets vault-rotate-db \
	eso-deploy sample-deploy injection-setup \
	observability-deploy configure-audit \
	vault-full-setup test clean

TERRAFORM_DIR := terraform
ENVIRONMENT   := dev

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------

init: ## Initialize Terraform with backend config
	cd $(TERRAFORM_DIR) && terraform init \
		-backend-config=environments/$(ENVIRONMENT)/backend.tfvars

plan: ## Run Terraform plan for the target environment
	cd $(TERRAFORM_DIR) && terraform plan \
		-var-file=environments/$(ENVIRONMENT)/terraform.tfvars \
		-out=tfplan

apply: ## Apply the Terraform plan
	cd $(TERRAFORM_DIR) && terraform apply tfplan

destroy: ## Destroy all Terraform-managed infrastructure
	cd $(TERRAFORM_DIR) && terraform destroy \
		-var-file=environments/$(ENVIRONMENT)/terraform.tfvars

fmt: ## Format all Terraform files
	terraform fmt -recursive $(TERRAFORM_DIR)

validate: ## Validate Terraform configuration
	cd $(TERRAFORM_DIR) && terraform init -backend=false -input=false && \
		terraform validate

lint: ## Run tflint on Terraform code
	cd $(TERRAFORM_DIR) && tflint --recursive

security-scan: ## Run Checkov security scan on Terraform code
	checkov -d $(TERRAFORM_DIR) --framework terraform

# ---------------------------------------------------------------------------
# Vault (Phase 2+)
# ---------------------------------------------------------------------------

vault-deploy: ## Deploy Vault HA cluster to AKS via Helm
	bash vault/scripts/deploy-vault.sh

vault-deploy-upgrade: ## Upgrade existing Vault Helm release
	bash vault/scripts/deploy-vault.sh --upgrade

vault-deploy-dry-run: ## Preview Vault Helm deployment without installing
	bash vault/scripts/deploy-vault.sh --dry-run

vault-init: ## Initialize and unseal Vault cluster
	bash vault/scripts/init-vault.sh

vault-configure: ## Configure Vault paths, policies, and auth methods
	bash vault/scripts/configure-namespaces.sh

vault-setup: vault-deploy vault-init vault-configure ## Full Vault setup: deploy + init + configure

# ---------------------------------------------------------------------------
# Dynamic Secrets (Phase 4)
# ---------------------------------------------------------------------------

postgresql-deploy: ## Deploy in-cluster PostgreSQL via Helm
	bash vault/scripts/deploy-postgresql.sh

vault-dynamic-secrets: ## Configure database and PKI secrets engines
	bash vault/scripts/configure-dynamic-secrets.sh

vault-rotate-db: ## Force-rotate PostgreSQL root credentials
	bash vault/scripts/rotate-db-creds.sh

vault-full-setup: vault-setup postgresql-deploy vault-dynamic-secrets injection-setup observability-deploy configure-audit ## Full setup: all phases

# ---------------------------------------------------------------------------
# Secret Injection (Phase 5)
# ---------------------------------------------------------------------------

eso-deploy: ## Deploy External Secrets Operator and configure Vault auth
	bash vault/scripts/deploy-external-secrets.sh

sample-deploy: ## Deploy sample apps demonstrating both injection patterns
	bash vault/scripts/deploy-sample-apps.sh

injection-setup: eso-deploy sample-deploy ## Full injection setup: ESO + sample apps

# ---------------------------------------------------------------------------
# Observability (Phase 6)
# ---------------------------------------------------------------------------

observability-deploy: ## Deploy monitoring stack (Prometheus, Grafana, Loki)
	bash vault/scripts/deploy-observability.sh

configure-audit: ## Enable Vault file audit backend
	bash vault/scripts/configure-audit-logging.sh

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test: ## Run all bats tests
	bats tests/bats/

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

clean: ## Remove generated Terraform files
	rm -f $(TERRAFORM_DIR)/tfplan
	rm -rf $(TERRAFORM_DIR)/.terraform
