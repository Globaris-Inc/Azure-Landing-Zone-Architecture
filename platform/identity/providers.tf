# Purpose: Zero Trust + Conditional Access — provider configuration.
# Section: 5 — Zero Trust + Conditional Access
# Last updated: 2026-07-08
#
# Three providers are required for this module:
#   azuread — Conditional Access policies, named locations, Identity Protection
#   azurerm — PIM eligible role assignments, role management policies (MG scope)
#   azapi   - inherited by the AVM RSV + VNet modules (Section 8 G1)
#
# Authentication: all providers use OIDC via the same GitHub Actions OIDC SP.
# Graph app roles GRANTED + admin-consented on the SP (2026-07-08, least-privilege
# set actually exercised by this root - not the larger set older revisions listed):
#   Policy.Read.All
#   Policy.ReadWrite.ConditionalAccess
#   Application.Read.All (CA policies with specific-app conditions; Graph 403
#     "Application.Read.All scope is required" without it - run 28953600569)
# Azure RBAC: ADR-021 scoped role set (Contributor + UAA per subscription, Owner/
# RPC/UAA at the org root MG) - NOT tenant-root Owner.

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
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.5"
    }
    # ADR-028: propagation waits for the AADDS policy exemption and the
    # greenfield named-location race. Same pin as bootstrap/ (0.13.1 verified
    # present in that lock file / provider cache, 2026-07-09).
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13.1"
    }
  }
  backend "azurerm" {}
}

# Default azapi provider - MUST be anchored to the identity subscription. The AVM
# RSV module builds its parent_id from data.azapi_client_config.current
# .subscription_id (module main.tf:14), i.e. from THIS provider's subscription,
# not from the azurerm.identity alias mapped into the module. Without this block
# azapi fell back to ARM_SUBSCRIPTION_ID (the management sub) and the RSV PUT hit
# a nonexistent RG there: 404 ResourceGroupNotFound (runs 28950922048, 28953600569).
# The VNet module is immune (takes a full RG resource ID as parent_id) but
# inherits this provider harmlessly.
provider "azapi" {
  subscription_id = var.identity_subscription_id
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

# ---------------------------------------------------------------------------
# Identity-subscription provider alias (Section 8 — G1, ADR-010 / Wave 3)
# ---------------------------------------------------------------------------
# The default azurerm provider is management-anchored (for MG-scope PIM). The G1
# identity-services build (identity VNet, Entra Domain Services, RSV) must land in
# the IDENTITY subscription, so it uses this dedicated identity-anchored alias.
provider "azurerm" {
  alias           = "identity"
  subscription_id = var.identity_subscription_id
  features {}
}

# Connectivity-subscription alias — used ONLY for the hub-to-identity return VNet
# peering (mirrors the spoke pattern in landing-zones/corp-a1). The OIDC SP holds
# Contributor on the Connectivity sub (ADR-021 scoped role set), which covers the
# return peering write.
provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  features {}
}
