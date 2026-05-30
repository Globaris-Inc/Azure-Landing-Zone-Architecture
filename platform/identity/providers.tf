# Purpose: Zero Trust + Conditional Access — provider configuration.
# Section: 5 — Zero Trust + Conditional Access
# Last updated: 2026-05-26
#
# Two providers are required for this module:
#   azuread — Conditional Access policies, named locations, Identity Protection
#   azurerm — PIM eligible role assignments, role management policies (MG scope)
#
# Authentication: both providers use OIDC via the same GitHub Actions OIDC SP.
# The SP must have the following Entra ID API permissions (Application):
#   Policy.ReadWrite.ConditionalAccess
#   Policy.ReadWrite.AuthenticationMethod
#   Directory.ReadWrite.All (for named locations)
# And Azure RBAC: Owner at Tenant Root MG (already configured in bootstrap).
#
# UNVERIFIED: azuread provider latest 3.x patch version. Run `terraform init` to
# resolve the latest available 3.x version from the Terraform Registry.

terraform {
  required_version = ">= 1.9"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
  }
  backend "azurerm" {}
}

# azuread provider authenticates via OIDC automatically when ARM_USE_OIDC=true,
# ARM_CLIENT_ID, and ARM_TENANT_ID environment variables are present.
provider "azuread" {
  tenant_id = var.tenant_id
}

# azurerm provider uses management subscription as the authentication anchor;
# PIM and role management policy resources operate at MG scope regardless.
provider "azurerm" {
  subscription_id = var.management_subscription_id
  features {}
}
