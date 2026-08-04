# Purpose: Security platform root module - RBAC-isolated Security LA workspace,
#          Microsoft Sentinel, Key Vault for security secrets, Defender for Cloud plans.
# Section: 8 - Standard Platform Components
# Last updated: 2026-08-03
#
# Apply order: After platform/management (platform LA workspace ID not required here;
#              security workspace is intentionally isolated). After platform/connectivity
#              if Firewall TLS cert is wired to this Key Vault.
#
# Resources deployed to: Security subscription.

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "platform-security"
      Owner              = "platform-team"
      Workload           = "platform-security"
      DataClassification = "Confidential"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
    },
    var.tags
  )

  # Defender for Cloud resource types enabled on the Security subscription.
  # VirtualMachines uses subplan "P2" (Defender for Servers Plan 2 - includes MDE + VA).
  # Other types are added directly below via for_each.
  #
  # Map of resource_type => subplan. The subplan is pinned to the exact value
  # Azure assigned and the provider already holds in state (verified 2026-07-10):
  # leaving subplan unset made config null vs state <value> on a ForceNew field,
  # which forced a destroy/recreate of all three plans (ref ADR-035).
  #
  # KeyVaults and Arm were REMOVED for the post-teardown redeploy (ADR-040,
  # inverts ADR-034's hold-as-latent-debt logic): the 2026-07-11 teardown reset
  # every plan in the security sub to Free, so re-applying them Standard would
  # be NEW enablement of plans Microsoft blocked for new enablement on
  # 2026-07-05 - a deterministic 400 at PUT. ADR-034's hold only applied while
  # they were live-Standard and in state. Do not re-add them; their successor
  # coverage is tracked in ADR-040 / OQ-028.
  defender_basic_plans = {
    StorageAccounts = "DefenderForStorageV2"
  }
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "security" {
  name     = "rg-security-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Security Log Analytics Workspace - RBAC-isolated from platform workspace
# ---------------------------------------------------------------------------
#
# This workspace is separate from the platform LA workspace in platform/management.
# Access is restricted to security team roles (Microsoft Sentinel Reader/Contributor)
# via workspace-level Azure RBAC. No cross-workspace query access from platform team.

module "security_law" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "0.5.1"

  name                = "law-security-${var.org_prefix}-${var.environment}-${var.security_law_generation}" # ADR-075: generation token re-identifies the workspace; the unsuffixed name is burned
  resource_group_name = azurerm_resource_group.security.name
  location            = var.primary_location

  log_analytics_workspace_sku               = "PerGB2018"
  log_analytics_workspace_retention_in_days = var.security_law_retention_days

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Microsoft Sentinel - onboarded to the Security LA workspace
# ---------------------------------------------------------------------------

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "this" {
  workspace_id = module.security_law.resource_id
}

# ---------------------------------------------------------------------------
# Security Key Vault - secrets for security operations + future Firewall TLS cert
# ---------------------------------------------------------------------------

# Globally-unique suffix for the Key Vault name (3-24 chars, alphanumeric + hyphens).
resource "random_id" "security_kv" {
  byte_length = 4
}

# DEVIATION: Public network access enabled during the POC build.
# Section 4 (Private Endpoints + Private DNS) adds a Private Endpoint to this Key Vault
# and sets public_network_access_enabled = false at that point.
# network_acls.default_action is set to "Allow" temporarily for the same reason.
module "security_kv" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "0.10.2"

  name                = "kv-sec-${var.org_prefix}-${random_id.security_kv.hex}"
  resource_group_name = azurerm_resource_group.security.name
  location            = var.primary_location
  tenant_id           = var.tenant_id

  sku_name                      = "standard"
  soft_delete_retention_days    = 90
  purge_protection_enabled      = true
  public_network_access_enabled = true

  network_acls = {
    bypass         = "AzureServices"
    default_action = "Allow"
  }

  role_assignments = {
    terraform_sp = {
      role_definition_id_or_name = "Key Vault Administrator"
      principal_id               = var.terraform_sp_object_id
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Defender for Cloud - subscription-level plans on the Security subscription
# ---------------------------------------------------------------------------
#
# DEVIATION: No AVM module for azurerm_security_center_subscription_pricing.
# Plans are enabled per-subscription. In a full ALZ deployment these would be
# enforced via DINE policies at the Globaris root MG scope - tracked as a
# Section 12 hardening item.

resource "azurerm_security_center_subscription_pricing" "servers" {
  tier          = "Standard"
  resource_type = "VirtualMachines"
  subplan       = "P2"
}

resource "azurerm_security_center_subscription_pricing" "this" {
  for_each      = local.defender_basic_plans
  tier          = "Standard"
  resource_type = each.key
  subplan       = each.value
}

# ---------------------------------------------------------------------------
# Defender for Cloud - security contact
# ---------------------------------------------------------------------------

resource "azurerm_security_center_contact" "this" {
  name  = "security-contact-${var.org_prefix}"
  email = var.security_contact_email

  alert_notifications = true
  alerts_to_admins    = true
}
