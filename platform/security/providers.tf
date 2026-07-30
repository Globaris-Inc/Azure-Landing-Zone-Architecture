# Purpose: Provider configuration for the Security platform root module.
# Section: 8 - Standard Platform Components (Security sub) / extended in Section 6
# Last updated: 2026-07-30

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4.0"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8.1"
    }
  }
  backend "azurerm" {}
}

# Default provider targets the Security subscription.
provider "azurerm" {
  subscription_id = var.security_subscription_id

  # OQ-063 / ADR-067: purge the Security Log Analytics workspace on terraform
  # destroy so the greenfield rebuild's Step-3 apply CREATES it fresh instead of
  # RECOVERING the soft-deleted one (the ADR-067 Class-2 "already exists" failure).
  # log_analytics_workspace.permanently_delete_on_destroy defaults FALSE
  # (internal/features/defaults.go), so it must be set explicitly - the same
  # purge-on-destroy intent the repo already uses for Key Vault
  # (purge_soft_delete_on_destroy). Argument verified against the pinned azurerm
  # v4.71.0 features schema (internal/provider/features.go). The security_law
  # module (main.tf) is created through this default provider instance (no
  # providers= override).
  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }
}

# azapi used for Microsoft.SecurityInsights/settings resources (UEBA + Entity
# Analytics) that have no native azurerm equivalent in 4.x.
provider "azapi" {}

provider "modtm" {}
