#!/usr/bin/env bats

# Tests for Terraform configuration validity.
# Run with: bats tests/bats/terraform_validate.bats

TERRAFORM_DIR="terraform"

setup() {
  cd "$TERRAFORM_DIR" || exit 1
}

@test "terraform init succeeds without backend" {
  run terraform init -backend=false -input=false
  [ "$status" -eq 0 ]
}

@test "terraform validate passes" {
  terraform init -backend=false -input=false > /dev/null 2>&1
  run terraform validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Success"* ]]
}

@test "all module directories contain main.tf" {
  for module_dir in modules/*/; do
    [ -f "${module_dir}main.tf" ]
  done
}

@test "all module directories contain variables.tf" {
  for module_dir in modules/*/; do
    [ -f "${module_dir}variables.tf" ]
  done
}

@test "all module directories contain outputs.tf" {
  for module_dir in modules/*/; do
    [ -f "${module_dir}outputs.tf" ]
  done
}

@test "dev environment tfvars file exists" {
  [ -f "environments/dev/terraform.tfvars" ]
}

@test "dev environment backend config exists" {
  [ -f "environments/dev/backend.tfvars" ]
}

@test "subscription_id is not hardcoded in tfvars" {
  # Ensure no real subscription ID is committed
  local sub_value
  sub_value=$(grep 'subscription_id' environments/dev/terraform.tfvars | grep -v '^#' | cut -d'"' -f2)
  [ -z "$sub_value" ]
}
