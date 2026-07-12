# Purpose: Provider and Terraform version constraints for the bootstrap layer.
# Section: 10a - Pipeline & Tooling (bootstrap subset)
# Last updated: 2026-05-05
#
# This root module uses LOCAL state (ADR-005). Do not configure a backend block here.
# Run once manually: terraform init && terraform apply -var-file=terraform.tfvars
# After apply, paste the outputs into envs/poc.backend.hcl.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.8.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13.1"
    }
  }
}

provider "azurerm" {
  subscription_id = var.management_subscription_id

  # The state Storage Account disables shared keys (shared_access_key_enabled =
  # false). Without this, the provider polls the blob data plane with key-based
  # auth and fails with 403 KeyBasedAuthenticationNotPermitted. Use Entra (AAD)
  # auth for storage data-plane operations instead. The deployer holds Storage
  # Blob Data Contributor on the account (see identity.tf).
  storage_use_azuread = true

  features {
    key_vault {
      # Never auto-purge on destroy - purge protection is enabled on the bootstrap KV.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}
