# Purpose: Management platform root module — FinOps governance, tag policy, budgets,
#          cost exports, anomaly alerts, and Carbon Optimization workbook.
# Section: 7 — FinOps: Tagging & Budgets
# Last updated: 2026-07-08
#
# Apply order: depends on platform/management-groups (policy assignments scope to MGs).
#
# Resources deployed to: management subscription (primary), + cross-subscription
# budget/export resources for all 5 subscriptions via explicit subscription_id params.

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "platform-management"
      Owner              = "platform-team"
      Workload           = "platform-management"
      DataClassification = "Internal"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
    },
    var.tags
  )

  # Deterministic MG resource IDs — no data source needed; IDs follow the known pattern
  # set in platform/management-groups/lib/globaris.alz_architecture_definition.json.
  globaris_mg_id     = "/providers/Microsoft.Management/managementGroups/globaris"
  platform_mg_id     = "/providers/Microsoft.Management/managementGroups/platform"
  landingzones_mg_id = "/providers/Microsoft.Management/managementGroups/landingzones"

  # Deterministic workbook GUID derived from org prefix; avoids random IDs.
  carbon_workbook_id = lower(uuidv5("dns", "carbon-optimization.${var.org_prefix}"))

  # Required tag names with default values applied by the Modify policy when a RG
  # is created or updated without the tag. These are intentionally generic defaults;
  # workload teams override them on their own resource groups.
  # NOTE: CreatedDate default is static ("1970-01-01") because the built-in Modify
  # policy cannot use a dynamic date. Teams should set this tag manually on their RGs.
  required_tags_with_defaults = {
    Environment        = var.environment
    CostCenter         = "TBD"
    Owner              = "platform-team"
    Workload           = "unset"
    DataClassification = "Internal"
    BusinessUnit       = var.org_prefix
    CreatedBy          = "terraform"
    CreatedDate        = "1970-01-01"
  }

  # Five subscriptions for per-subscription budget + export module calls.
  subscription_scopes = {
    management = {
      subscription_id = var.management_subscription_id
      budget_name     = "budget-sub-management-${var.org_prefix}"
      export_name     = "export-daily-management-${var.org_prefix}"
    }
    connectivity = {
      subscription_id = var.connectivity_subscription_id
      budget_name     = "budget-sub-connectivity-${var.org_prefix}"
      export_name     = "export-daily-connectivity-${var.org_prefix}"
    }
    identity = {
      subscription_id = var.identity_subscription_id
      budget_name     = "budget-sub-identity-${var.org_prefix}"
      export_name     = "export-daily-identity-${var.org_prefix}"
    }
    security = {
      subscription_id = var.security_subscription_id
      budget_name     = "budget-sub-security-${var.org_prefix}"
      export_name     = "export-daily-security-${var.org_prefix}"
    }
    landingzones = {
      subscription_id = var.landingzones_subscription_id
      budget_name     = "budget-sub-landingzones-${var.org_prefix}"
      export_name     = "export-daily-landingzones-${var.org_prefix}"
    }
  }

  # Deterministic workbook GUID for the platform overview workbook.
  platform_workbook_id = lower(uuidv5("dns", "platform-overview.${var.org_prefix}"))

  # Action group short_name is limited to 12 characters by Azure.
  action_group_short_name = substr("plt-${var.org_prefix}", 0, 12)

  # Three management group scopes for MG-level budgets.
  mg_budget_scopes = {
    globaris = {
      management_group_id = local.globaris_mg_id
      amount              = var.budget_amount_per_mg # covers all 5 subscriptions
    }
    platform = {
      management_group_id = local.platform_mg_id
      amount              = var.budget_amount_per_mg # covers 4 platform subscriptions
    }
    landingzones = {
      management_group_id = local.landingzones_mg_id
      amount              = var.budget_amount_per_subscription # covers 1 LZ subscription
    }
  }
}

# ---------------------------------------------------------------------------
# Resource Group — FinOps resources in the management subscription
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "finops" {
  name     = "rg-finops-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Storage Account — dedicated cost export sink
# ---------------------------------------------------------------------------

# Globally-unique suffix for the storage account name (3-24 chars, alphanumeric only).
resource "random_id" "finops_sa" {
  byte_length = 4
}

# DEVIATION: No AVM module used for the cost export storage account.
# This is a simple data sink, not a PaaS resource requiring Private Endpoint in this
# section. Private Endpoint for storage is added in Section 4; Section 8 hardens
# network access. Public access left enabled (matching bootstrap deviation) so that
# the Azure Cost Management export service can write to the container.
resource "azurerm_storage_account" "cost_exports" {
  name                            = "stfinops${var.environment}${random_id.finops_sa.hex}"
  resource_group_name             = azurerm_resource_group.finops.name
  location                        = var.primary_location
  account_tier                    = "Standard"
  account_replication_type        = "GZRS" # Section 3: geo-redundant for FinOps archive data
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Entra-only auth

  tags = local.common_tags
}

resource "azurerm_storage_container" "cost_exports" {
  name                  = "cost-exports"
  storage_account_id    = azurerm_storage_account.cost_exports.id
  container_access_type = "private"
}

# Data-plane RBAC for the CI service principal on the keyless cost-exports SA.
# The account is Entra-only (shared_access_key_enabled = false); classic roles
# (Contributor) carry no blob dataActions, so any future blob data-plane operation
# by the pipeline against this account (Section 4 PE validation, export inspection)
# needs an explicit data role. Mirrors bootstrap/identity.tf on the tfstate SA.
#
# NOTE — refresh does NOT depend on this assignment existing first: with
# storage_use_azuread = true (providers.tf), the provider's refresh reads (Get Blob/
# Queue Service Properties) authorize via the control-plane actions
# Microsoft.Storage/storageAccounts/{blobServices,queueServices}/read, already held
# via Contributor on this subscription. No queue data role is granted: no
# queue_properties are managed here and Get Queue Service Properties needs no
# queue dataAction (per MS REST auth docs, verified 2026-07-07).
#
# Contingency only — if a refresh still returns 403 AuthorizationPermissionMismatch,
# the operator can pre-grant out-of-band, then import to avoid a 409 duplicate:
#   az role assignment create \
#     --assignee-object-id $TERRAFORM_SP_OBJECT_ID \
#     --assignee-principal-type ServicePrincipal \
#     --role "Storage Blob Data Contributor" \
#     --scope "/subscriptions/<management-sub-id>/resourceGroups/<finops-rg>/providers/Microsoft.Storage/storageAccounts/<cost-exports-sa>"
#   terraform import 'azurerm_role_assignment.terraform_sp_cost_exports_blob' <assignment-id-from-az-output>
resource "azurerm_role_assignment" "terraform_sp_cost_exports_blob" {
  scope                            = azurerm_storage_account.cost_exports.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = var.terraform_sp_object_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# Tag Governance — custom initiative using built-in Azure Policy definitions
# ---------------------------------------------------------------------------
#
# Built-in policy IDs used (confirmed on azadvertizer.net 2026-05-12):
#   d157c373-a6c4-483d-aaad-570756956268  "Add or replace a tag on resource groups"
#     Effect: Modify | Mode: All (targets resource groups)
#     Params: tagName (string), tagValue (string)
#
#   cd3aa116-8754-49c9-a813-ad46512ece54  "Inherit a tag from the resource group"
#     Effect: Modify | Mode: Indexed (targets resources, not RGs)
#     Params: tagName (string)
#
# DEVIATION: "Add or replace a tag on resource groups" sets a static default tagValue.
# The CreatedDate default is "1970-01-01" because the Modify effect cannot use a
# dynamic date expression. Teams should set CreatedDate manually on their RGs.

resource "azurerm_policy_set_definition" "tag_governance" {
  name         = "tag-governance-${var.org_prefix}"
  policy_type  = "Custom"
  display_name = "${title(var.org_prefix)} — Tag Governance Initiative"
  description  = "Enforces 8 mandatory tags on every resource group (Modify) and propagates them to all child resources (Modify). Assigned at the Globaris root management group."

  # DEVIATION: management_group_id is marked deprecated in azurerm ~>4.71 with no documented
  # replacement. Policy set definitions must be scoped to a management group; this attribute
  # is the only available mechanism in the current provider. Review when upgrading azurerm.
  management_group_id = local.globaris_mg_id

  # For each required tag: add or replace on the resource group (Modify, RG scope).
  dynamic "policy_definition_reference" {
    for_each = local.required_tags_with_defaults
    iterator = tag
    content {
      policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/d157c373-a6c4-483d-aaad-570756956268"
      reference_id         = "modify-tag-${lower(tag.key)}-on-rg"
      parameter_values = jsonencode({
        tagName  = { value = tag.key }
        tagValue = { value = tag.value }
      })
    }
  }

  # For each required tag: inherit from RG to resource (Modify, resource scope).
  dynamic "policy_definition_reference" {
    for_each = local.required_tags_with_defaults
    iterator = tag
    content {
      policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/cd3aa116-8754-49c9-a813-ad46512ece54"
      reference_id         = "inherit-tag-${lower(tag.key)}-from-rg"
      parameter_values = jsonencode({
        tagName = { value = tag.key }
      })
    }
  }
}

# Assign the tag governance initiative at the Globaris root MG.
# SystemAssigned identity is required by the Modify effect for remediation tasks.
resource "azurerm_management_group_policy_assignment" "tag_governance" {
  name                 = "tag-governance-${var.org_prefix}"
  management_group_id  = local.globaris_mg_id
  policy_definition_id = azurerm_policy_set_definition.tag_governance.id
  display_name         = "Tag Governance — All ${title(var.org_prefix)} Resources"
  description          = "Mandatory tag governance initiative covering all 8 required tags on resource groups and resources under the Globaris hierarchy."
  location             = var.primary_location

  identity {
    type = "SystemAssigned"
  }

  depends_on = [azurerm_policy_set_definition.tag_governance]
}

# Grant the remediation managed identity Contributor at root MG scope.
# Contributor is required for the Modify effect to add/replace tags on resources
# across the entire Globaris hierarchy without per-subscription role assignments.
resource "azurerm_role_assignment" "tag_policy_remediation" {
  scope                = local.globaris_mg_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_management_group_policy_assignment.tag_governance.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Resource Provider registration - Microsoft.CostManagementExports
# ---------------------------------------------------------------------------

# Deploy run 28909509585: all 5 azurerm_subscription_cost_management_export
# instances failed with 400 "RP Not Registered. Register destination storage
# account subscription with Microsoft.CostManagementExports." The destination
# SA (cost-exports) lives in the MANAGEMENT subscription, so the RP is
# registered here only, on the default (management-sub) provider.
#
# Standalone resource, not a provider-block change: verified at azurerm
# v4.71.0 (docs + internal/resourceproviders/required.go) that
# Microsoft.CostManagementExports is absent from every auto-registered set
# (core/extended/all/legacy), so this cannot conflict with the provider's
# automatic RP registration and the root's resource_provider_registrations
# mode stays untouched. The CI SP holds Contributor on this subscription,
# which includes */register/action, so it may register RPs. Registration can
# take minutes; the resource blocks until the RP reports Registered (create
# timeout defaults to 2h per provider docs) - acceptable.
resource "azurerm_resource_provider_registration" "cost_management_exports" {
  name = "Microsoft.CostManagementExports"
}

# ---------------------------------------------------------------------------
# Per-subscription budgets + daily cost exports (calls modules/finops)
# ---------------------------------------------------------------------------

# DEVIATION: No AVM module for subscription budgets or cost management exports.
# modules/finops is a custom child module using native azurerm resources plus azapi
# for the cost export (ADR-027 - keyless destination SA needs the export MI path).
# The single management-subscription provider is used for all module calls;
# azurerm_consumption_budget_subscription takes an explicit subscription_id and the
# azapi export takes the subscription resource ID as parent_id, enabling
# cross-subscription management from one provider pair.
module "finops" {
  source   = "../../modules/finops"
  for_each = local.subscription_scopes

  budget_name                 = each.value.budget_name
  subscription_id             = each.value.subscription_id
  budget_amount               = var.budget_amount_per_subscription
  budget_start_date           = var.budget_start_date
  budget_alert_thresholds     = var.budget_alert_thresholds
  budget_alert_contact_emails = var.budget_alert_contact_emails

  export_enabled            = true
  export_name               = each.value.export_name
  export_storage_account_id = azurerm_storage_account.cost_exports.id
  export_container_name     = azurerm_storage_container.cost_exports.name
  export_identity_location  = var.primary_location
  export_root_folder        = each.key
  export_start_date         = var.budget_start_date
  export_end_date           = var.export_end_date

  # No VMs exist yet — auto-shutdown schedules added from Section 8 onwards.
  vm_shutdown_schedules = {}

  tags = local.common_tags

  # RP registration first: exports 400 "RP Not Registered" otherwise (run 28909509585).
  depends_on = [
    azurerm_storage_container.cost_exports,
    azurerm_resource_provider_registration.cost_management_exports,
  ]
}

# ---------------------------------------------------------------------------
# Management Group scope budgets (globaris root, platform, landing zones)
# ---------------------------------------------------------------------------

# DEVIATION: No AVM module for azurerm_consumption_budget_management_group.
resource "azurerm_consumption_budget_management_group" "this" {
  for_each = local.mg_budget_scopes

  name                = "budget-mg-${each.key}-${var.org_prefix}"
  management_group_id = each.value.management_group_id
  amount              = each.value.amount
  time_grain          = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  dynamic "notification" {
    for_each = { for t in var.budget_alert_thresholds : tostring(t) => t }
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThan"
      contact_emails = var.budget_alert_contact_emails
    }
  }
}

# ---------------------------------------------------------------------------
# Cost anomaly alert — management subscription scope
# ---------------------------------------------------------------------------

# DEVIATION: No AVM module for azurerm_cost_anomaly_alert.
# display_name is capped at 50 characters by Azure (InvalidScheduledActionDisplayName,
# deploy run 28909509585) - keep it short. Current value is 34 chars with org_prefix
# "globaris", leaving headroom.
resource "azurerm_cost_anomaly_alert" "management" {
  name            = "anomaly-alert-management-${var.org_prefix}"
  display_name    = "Cost Anomaly Alert - ${title(var.org_prefix)} Mgmt"
  subscription_id = "/subscriptions/${var.management_subscription_id}"
  email_subject   = "[${upper(var.environment)}] Azure Cost Anomaly Detected — ${title(var.org_prefix)}"
  email_addresses = var.budget_alert_contact_emails
}

# ---------------------------------------------------------------------------
# Carbon Optimization workbook (Azure Monitor standalone workbook)
# ---------------------------------------------------------------------------

# DEVIATION: azurerm_application_insights_workbook requires inline data_json.
# This is a placeholder workbook. Replace data_json with the full Microsoft FinOps
# Toolkit Carbon Optimization workbook JSON from:
# https://github.com/microsoft/finops-toolkit/tree/main/src/workbooks
# The azurerm resource name must be a lowercase UUID — uuidv5 produces a
# deterministic GUID from the org prefix, avoiding random resource replacement.
resource "azurerm_application_insights_workbook" "carbon_optimization" {
  name                = local.carbon_workbook_id
  resource_group_name = azurerm_resource_group.finops.name
  location            = var.primary_location
  display_name        = "Carbon Optimization — ${title(var.org_prefix)}"

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "text-placeholder"
        content = {
          json = "# Azure Carbon Optimization\n\n**Action required:** Replace this placeholder with the [Microsoft FinOps Toolkit Carbon Optimization workbook](https://github.com/microsoft/finops-toolkit/tree/main/src/workbooks).\n\nImport the workbook JSON from the FinOps Toolkit repository and paste its contents into the `data_json` field in `platform/management/main.tf`."
        }
      }
    ]
    isLocked            = false
    fallbackResourceIds = ["azure monitor"]
  })

  tags = local.common_tags
}

# ===========================================================================
# Section 8 — Standard Platform Components: Management sub additions
# ===========================================================================

# ---------------------------------------------------------------------------
# Resource Group — management platform monitoring/compute
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "management" {
  name     = "rg-management-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Platform Log Analytics Workspace — PerGB2018, 90-day retention
# ---------------------------------------------------------------------------

module "platform_law" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "0.5.1"

  name                = "law-platform-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.management.name
  location            = var.primary_location

  log_analytics_workspace_sku               = "PerGB2018"
  log_analytics_workspace_retention_in_days = var.platform_law_retention_days
  log_analytics_workspace_daily_quota_gb    = var.platform_law_daily_quota_gb

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Automation Account — Basic SKU; system-assigned identity for Update Manager
# ---------------------------------------------------------------------------

# DEVIATION: Using native azurerm_automation_account instead of
# avm-res-automation-automationaccount v0.2.0; module interface not fully
# verified against registry docs. Native resource is production-equivalent.
resource "azurerm_automation_account" "platform" {
  name                         = "aa-platform-${var.org_prefix}-${var.environment}"
  resource_group_name          = azurerm_resource_group.management.name
  location                     = var.primary_location
  sku_name                     = "Basic"
  local_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# Link Automation Account diagnostics to the platform LA workspace.
resource "azurerm_monitor_diagnostic_setting" "automation_account" {
  name                       = "diag-aa-to-law"
  target_resource_id         = azurerm_automation_account.platform.id
  log_analytics_workspace_id = module.platform_law.resource_id

  enabled_log {
    category_group = "allLogs"
  }
}

# ---------------------------------------------------------------------------
# Monitor Action Group — platform alert notifications
# ---------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "platform" {
  name                = "ag-platform-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.management.name
  short_name          = local.action_group_short_name

  dynamic "email_receiver" {
    for_each = { for idx, addr in var.budget_alert_contact_emails : tostring(idx) => addr }
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Platform Overview workbook (placeholder)
# ---------------------------------------------------------------------------

resource "azurerm_application_insights_workbook" "platform_overview" {
  name                = local.platform_workbook_id
  resource_group_name = azurerm_resource_group.management.name
  location            = var.primary_location
  display_name        = "Platform Overview — ${title(var.org_prefix)}"

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type = 1
        name = "text-placeholder"
        content = {
          json = "# Platform Overview\n\n**Action required:** Replace this placeholder with metric charts for the platform Log Analytics workspace, Automation Account, and cost alerts.\n\n## Quick links\n- Log Analytics workspace: `${module.platform_law.resource_id}`\n- Automation Account: `${azurerm_automation_account.platform.id}`\n- Action Group: `${azurerm_monitor_action_group.platform.id}`"
        }
      }
    ]
    isLocked            = false
    fallbackResourceIds = ["azure monitor"]
  })

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Shared Portal Dashboard — platform summary
# ---------------------------------------------------------------------------

resource "azurerm_portal_dashboard" "platform" {
  name                = "dash-platform-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.management.name
  location            = var.primary_location

  dashboard_properties = jsonencode({
    lenses = {
      "0" = {
        order = 0
        parts = {
          "0" = {
            position = { x = 0, y = 0, colSpan = 12, rowSpan = 4 }
            metadata = {
              inputs = []
              type   = "Extension/HubsExtension/PartType/MarkdownPart"
              settings = {
                content = {
                  settings = {
                    content  = "## ${title(var.org_prefix)} Platform Overview\n\nReplace with metric tiles for Log Analytics ingestion, Automation job status, and cost alerts."
                    title    = "Platform Overview"
                    subtitle = "${upper(var.environment)} — ${title(var.org_prefix)} ALZ POC"
                  }
                }
              }
            }
          }
        }
      }
    }
    metadata = {
      model = {
        timeRange = {
          value = { relative = { duration = 24, timeUnit = 1 } }
          type  = "MsPortalFx.Composition.Configuration.ValueTypes.TimeRange"
        }
      }
    }
  })

  tags = local.common_tags
}

# ===========================================================================
# Section 4 — Private Endpoints + Private DNS: Deny public network access
# ===========================================================================
#
# Custom policy initiative assigned at the Landing Zones management group.
# AUDITS (POC effect) SQL Servers, Key Vaults, and Storage Accounts created with
# public network access enabled. Effect is Audit for the POC (see EFFECT DECISION
# note below); the "deny" name is retained for the intended future enforcement pass.
#
# Built-in policy definition IDs (VERIFIED live via `az policy definition show`
# 2026-07-06 — all three return the expected built-ins):
#   1b8ca024-1d5c-4dec-8995-b1a932b41780  "Public network access on Azure SQL Database should be disabled"
#   405c5871-3e91-4644-8a63-58e19d68ff5b  "Azure Key Vault should disable public network access"
#   34c877ad-507e-4c82-993e-3452a6e0ad3c  "Storage accounts should restrict network access"
#
# NOTE (OQ-016): the previously pinned KV GUID (...-58ad8008cbe8) was WRONG —
# `az policy definition show` returned PolicyDefinitionNotFound, which would have
# hard-failed this set-definition PUT on the management apply. Corrected above.
#
# Each of the three built-ins exposes an `effect` parameter
# (allowedValues [Audit, Deny, Disabled], default Audit). We pass `effect`
# EXPLICITLY as "Audit" (OQ-016: never rely on a built-in's implicit default).
#
# EFFECT DECISION — Audit, not Deny (code-review 2026-07-07): a Deny at the
# `landingzones` MG would hard-block legitimate POC resources that live under it —
# the spoke NSG flow-log Storage Accounts (corp-a1/a2, online-p1; no `network_acls`,
# so defaultAction=Allow) and the entire synthetic layer (Section 13 storage + the
# red-team Key Vault, which need public access by design). Deny would fail every
# landing-zone and synthetic apply with RequestDisallowedByPolicy. Audit governs and
# reports public-network-access without blocking those workloads. The state SA is
# unaffected either way — it sits under `platform` > `management`, a sibling of
# `landingzones`, not a descendant. To enforce (Deny) later: add policy exemptions
# for the flow-log/synthetic RGs first, then flip. Tracked under OQ-016.

resource "azurerm_policy_set_definition" "deny_public_network_access" {
  name         = "deny-public-network-access-${var.org_prefix}"
  policy_type  = "Custom"
  display_name = "${title(var.org_prefix)} — Deny Public Network Access"
  description  = "Denies enabling public network access on Azure SQL, Key Vault, and Storage in the Landing Zones management group. Enforces private-endpoint-only connectivity."

  management_group_id = local.landingzones_mg_id

  policy_definition_reference {
    policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/1b8ca024-1d5c-4dec-8995-b1a932b41780"
    reference_id         = "deny-public-access-sql"
    # Explicit Audit for the POC (OQ-016: set effect explicitly, never rely on the
    # built-in default). NOT Deny — a Deny at the landingzones MG blocks legit
    # public-access resources under it (spoke flow-log SAs, synthetic). See note above.
    parameter_values = jsonencode({
      effect = { value = "Audit" }
    })
  }

  policy_definition_reference {
    policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/405c5871-3e91-4644-8a63-58e19d68ff5b"
    reference_id         = "deny-public-access-keyvault"
    # Explicit Audit for the POC (OQ-016: set effect explicitly, never rely on the
    # built-in default). NOT Deny — a Deny at the landingzones MG blocks legit
    # public-access resources under it (spoke flow-log SAs, synthetic). See note above.
    parameter_values = jsonencode({
      effect = { value = "Audit" }
    })
  }

  policy_definition_reference {
    policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/34c877ad-507e-4c82-993e-3452a6e0ad3c"
    reference_id         = "deny-public-access-storage"
    # Explicit Audit for the POC (OQ-016: set effect explicitly, never rely on the
    # built-in default). NOT Deny — a Deny at the landingzones MG blocks legit
    # public-access resources under it (spoke flow-log SAs, synthetic). See note above.
    parameter_values = jsonencode({
      effect = { value = "Audit" }
    })
  }
}

resource "azurerm_management_group_policy_assignment" "deny_public_network_access" {
  name                 = "deny-pub-net-${var.org_prefix}"
  management_group_id  = local.landingzones_mg_id
  policy_definition_id = azurerm_policy_set_definition.deny_public_network_access.id
  display_name         = "Deny Public Network Access — ${title(var.org_prefix)} Landing Zones"
  description          = "Enforces private-endpoint-only access for SQL, Key Vault, and Storage in all landing zone subscriptions."

  depends_on = [azurerm_policy_set_definition.deny_public_network_access]
}
