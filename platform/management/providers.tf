# Purpose: Provider configuration for the Management platform root module.
# Section: 7 — FinOps: Tagging & Budgets (initial); extended in Section 8.
# Last updated: 2026-05-12
#
# Single azurerm provider targets the management subscription.
# azurerm_consumption_budget_subscription and azurerm_subscription_cost_management_export
# both accept an explicit subscription_id parameter, allowing cross-subscription
# budget and export management from one provider. The OIDC service principal has
# Owner at the tenant root management group, enabling cross-subscription operations.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8.1"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.management_subscription_id
  features {}
}

provider "random" {}
