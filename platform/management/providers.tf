# Purpose: Provider configuration for the Management platform root module.
# Section: 7 — FinOps: Tagging & Budgets (initial); extended in Section 8.
# Last updated: 2026-07-08
#
# azurerm targets the management subscription; azapi (ADR-027) creates the cost
# exports in modules/finops. azurerm_consumption_budget_subscription accepts an
# explicit subscription_id parameter and the azapi export scopes via parent_id,
# allowing cross-subscription budget and export management from one provider pair.
# The OIDC service principal's MG-scope roles enable cross-subscription operations.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.5"
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

  # The cost-exports Storage Account disables shared keys (shared_access_key_enabled =
  # false). Without this, the provider refreshes storage data-plane properties (blob/
  # queue service properties) with key-based auth and fails with 403
  # KeyBasedAuthenticationNotPermitted (deploy run 28894730348). Use Entra (AAD) auth
  # for storage data-plane operations instead — same fix as bootstrap/providers.tf for
  # the tfstate SA (LESSONS.md #1). With OAuth, Get Blob/Queue Service Properties
  # authorize via the CONTROL-plane actions Microsoft.Storage/storageAccounts/
  # {blobServices,queueServices}/read, which the CI SP already holds through
  # Contributor on this subscription (bootstrap/identity.tf row 5) — so the refresh
  # does not depend on any data-plane role existing first.
  # Documented alternative (azurerm v4 features guide): features { storage {
  # data_plane_available = false } } skips storage data-plane reads entirely; not used
  # here to keep one repo-wide pattern (storage_use_azuread) for keyless SAs.
  storage_use_azuread = true

  features {}
}

# azapi authenticates via the same ARM_* OIDC env vars as azurerm - no CI changes needed (ADR-027).
provider "azapi" {}

provider "random" {}
