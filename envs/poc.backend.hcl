# envs/poc.backend.hcl
# Purpose: Remote state backend configuration for the POC environment.
# Section: 1 (scaffold), values populated during Section 10 (bootstrap).
# Last updated: 2026-05-04
#
# Usage: terraform init -backend-config=../../envs/poc.backend.hcl
#
# The storage account is created by bootstrap/ and must exist before running
# terraform init on any platform or landing-zone root module.
#
# IMPORTANT: Do not hardcode subscription IDs or account keys here.
# ARM_SUBSCRIPTION_ID and ARM_ACCESS_KEY (or managed identity) are expected
# as environment variables set by the GitHub Actions OIDC workflow.

resource_group_name  = "rg-tfstate-poc-eastus2"
storage_account_name = "sttfstatepoceastus2"   # must be globally unique — update after bootstrap
container_name       = "tfstate"

# key is set per-root-module, e.g.:
#   terraform init -backend-config=../../envs/poc.backend.hcl -backend-config="key=platform/connectivity/terraform.tfstate"
