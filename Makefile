.PHONY: help init plan apply destroy fmt validate lint security-scan \
	vault-init vault-configure test clean

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

vault-init: ## Initialize and unseal Vault cluster
	bash vault/scripts/init-vault.sh

vault-configure: ## Configure Vault paths, policies, and auth methods
	bash vault/scripts/configure-namespaces.sh

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
