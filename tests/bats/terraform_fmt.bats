#!/usr/bin/env bats

# Tests for Terraform formatting compliance.
# Run with: bats tests/bats/terraform_fmt.bats

@test "all terraform files are properly formatted" {
  run terraform fmt -check -recursive terraform/
  [ "$status" -eq 0 ]
}
