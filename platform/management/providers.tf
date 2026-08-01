# Purpose: Provider configuration for the Management platform root module.
# Section: 7 - FinOps: Tagging & Budgets (initial); extended in Section 8.
# Last updated: 2026-08-01
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
    # Wave B7 (ADR-052): avm-ptn-monitoring-amba-alz 0.4.0 and its AVM sub-modules
    # (resourcegroup, managedidentity) declare modtm for usage telemetry. Required in
    # the provider set even with enable_telemetry = false so terraform init can resolve
    # the module graph. No provider "modtm" block is needed - it self-configures.
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
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
  # for storage data-plane operations instead - same fix as bootstrap/providers.tf for
  # the tfstate SA (LESSONS.md #1). With OAuth, Get Blob/Queue Service Properties
  # authorize via the CONTROL-plane actions Microsoft.Storage/storageAccounts/
  # {blobServices,queueServices}/read, which the CI SP already holds through
  # Contributor on this subscription (bootstrap/identity.tf row 5) - so the refresh
  # does not depend on any data-plane role existing first.
  # Documented alternative (azurerm v4 features guide): features { storage {
  # data_plane_available = false } } skips storage data-plane reads entirely; not used
  # here to keep one repo-wide pattern (storage_use_azuread) for keyless SAs.
  storage_use_azuread = true

  # ADR-073 decision 6 / OQ-063: purge the platform Log Analytics workspace on
  # terraform destroy instead of leaving it soft-deleted for 14 days. Two
  # soft-deleted copies of law-platform-globaris-poc (one eastus2 from before the
  # ADR-069 region flip, one centralus from the last build) already sit in this
  # subscription under the identical ARM resource id; every teardown stranded
  # another, and a soft-deleted workspace makes the next apply RECOVER the old one
  # instead of CREATING it fresh (the ADR-067 Class-2 "already exists" failure).
  # Same purge-on-destroy intent the repo already uses for Key Vault
  # (purge_soft_delete_on_destroy) and for the Security root
  # (platform/security/providers.tf).
  #
  # BLAST RADIUS - read this before adding a second workspace to this root.
  # permanently_delete_on_destroy is a PROVIDER-level feature, not a per-resource
  # argument, so it applies to EVERY azurerm_log_analytics_workspace this root ever
  # creates, including on an accidental destroy of the wrong root, with NO 14-day
  # recovery window. That is intended for the platform workspace and is the trade
  # this makes, but it is a genuine widening of this root's destroy blast radius.
  # Today the root declares exactly one workspace (module.platform_law, the only
  # azurerm_log_analytics_workspace in the resolved module graph). A workspace that
  # needs the soft-delete safety net does not belong in this root.
  #
  # Verified against the pinned azurerm 4.71.0 provider: features ->
  # log_analytics_workspace -> permanently_delete_on_destroy is an Optional bool
  # defaulting false (internal/features/defaults.go) and is read only in
  # resourceLogAnalyticsWorkspaceDelete, where it sets Force on the delete call. It
  # governs the destroy path only - no create/read/update behavior changes and no
  # diff on existing resources.
  features {
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }
}

# azapi authenticates via the same ARM_* OIDC env vars as azurerm - no CI changes needed (ADR-027).
# Wave B7 (LESSON 23): anchor the default azapi provider with the management subscription
# id. The AMBA companion module's role-assignment azapi_resource uses an explicit MG-scope
# parent_id (no client_config derivation), but anchoring keeps every root consistent and
# avoids cross-subscription 404s on any client_config-derived call.
provider "azapi" {
  subscription_id = var.management_subscription_id
}

provider "random" {}
