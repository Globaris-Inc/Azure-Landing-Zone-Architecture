# Purpose: bank-data-p1 Azure Databricks Premium workspace (wave B5) - VNet-injected
#          into the two live delegated subnets (snet-databricks-host / -container,
#          B1), secure cluster connectivity (no_public_ip = true), default storage
#          firewall with a pre-created access connector, deterministic managed-RG
#          name, diagnostics to the platform LAW via a ROOT-LEVEL azapi resource
#          (ADR-076 decision 4, exercising the ADR-071 4a pre-authorization - see
#          the block comment on azapi_resource.dbw_diag_platform_law below). ALL
#          resources gated behind var.enable_data_platform (default false,
#          LESSON 42 flag pattern).
# Section: Banking wave B5 (docs/b5-data-platform-design.md sections 3-4; ADR-048)
# Last updated: 2026-08-10
#
# Module (pin re-verified on the Terraform Registry 2026-07-18, schema read from the
# v0.5.0 tag source - FIRST estate consumption of this module):
#   Azure/avm-res-databricks-workspace/azurerm 0.5.0 (latest; BREAKING at 0.5.0: the
#   workspace moved from azurerm_databricks_workspace to azapi_resource
#   Microsoft.Databricks/workspaces@2026-01-01 - the root's anchored default azapi
#   provider carries the landingzones sub, LESSON 23, providers.tf).
#
# Policy shape (design doc section 4 / ADR-048): the workspace create places a
# dbstorage* SA in the RP-created managed RG; the corp Deny-Public-Endpoints
# StorageDenyPaasPublicIP member (live Deny) evaluates that RP PUT. Ruled as ONE
# defense-in-depth unit: (a) default_storage_firewall_enabled = true deploys the
# managed SA public-access-blocked (posture half), and (b) the subscription-scoped
# expiring Waiver exemption in policy_exemptions.tf admits the create regardless of
# the RP's PUT sequencing, which is not verifiable pre-apply (guarantee half).
# Ordering: exemption -> 300s sleep -> access connector -> workspace (LESSON 35).
#
# HARD DEMO BOUNDARY (design doc section 1): NO clusters, jobs, warehouses, pools,
# notebooks, Unity Catalog config, or databricks provider. The workspace create
# consumes ZERO Microsoft.Compute vCPUs (OQ-043 moot for B5-as-designed).

# ---------------------------------------------------------------------------
# Workspace DBFS root storage account name - deterministic-enough for QA
# (avoids the RP-random dbstorage name). Rendered length (LESSON 27):
# "dbstorage" (9) + 8 hex = 17 chars <= 24, lowercase alphanumeric only.
# ---------------------------------------------------------------------------

resource "random_id" "dbfs_sa" {
  for_each = var.enable_data_platform ? { main = "main" } : {}

  byte_length = 4
}

# ---------------------------------------------------------------------------
# Access connector - pre-created OUTSIDE the managed RG (required by the default
# storage firewall; the RP wires the workspace-storage access itself, so NO manual
# role assignments here). Verified against azurerm v4.71.0 docs 2026-07-18.
# ---------------------------------------------------------------------------

resource "azurerm_databricks_access_connector" "dbx" {
  for_each = var.enable_data_platform ? { main = "main" } : {}

  name                = "dbac-bank-data-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = var.primary_location

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags

  depends_on = [time_sleep.wait_dbx_storage_exemption]
}

# ---------------------------------------------------------------------------
# Databricks Premium workspace - VNet-injected + NPIP + default storage firewall
# ---------------------------------------------------------------------------

module "databricks_workspace" {
  source  = "Azure/avm-res-databricks-workspace/azurerm"
  version = "0.5.0"

  for_each = var.enable_data_platform ? { main = "main" } : {}

  name                = "dbw-bank-data-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = var.primary_location

  # standard SKU is deprecated Oct 2026 (module docs) - premium is RULED, not
  # preferred; also required by the default storage firewall and any future
  # Private Link / CMK (B9).
  sku = "premium"

  # Deterministic managed-RG name so QA/policy checks can target it. NOT
  # pre-created - the RP creates and deny-assigns it at workspace create.
  managed_resource_group_name = "rg-bank-data-p1-dbx-managed-${var.org_prefix}-${var.environment}"

  # VNet injection into the B1 delegated subnets. The two NSG association IDs are
  # required by the 0.5.0 validation whenever virtual_network_id is set; an
  # azurerm subnet/NSG association resource ID equals the subnet resource ID
  # (verified in the v0.5.0 source: validation-only, not rendered into the ARM
  # body). no_public_ip DEFAULTS FALSE in the module - explicitly true here
  # (secure cluster connectivity / NPIP).
  # compute_mode is deliberately NOT set: module default "Hybrid" is the designed
  # classic VNet-injected compute plane (do not set Serverless).
  custom_parameters = {
    virtual_network_id                                   = module.spoke_vnet.resource_id
    public_subnet_name                                   = "snet-databricks-host"
    private_subnet_name                                  = "snet-databricks-container"
    public_subnet_network_security_group_association_id  = module.spoke_vnet.subnets["databricks-host"].resource_id
    private_subnet_network_security_group_association_id = module.spoke_vnet.subnets["databricks-container"].resource_id
    no_public_ip                                         = true
    storage_account_name                                 = "dbstorage${random_id.dbfs_sa[each.key].hex}"
  }

  # The section 4 / ADR-048 collision-unit posture half: the workspace SA deploys
  # with public network access blocked, wired through the pre-created connector.
  default_storage_firewall_enabled = true
  access_connector_id              = azurerm_databricks_access_connector.dbx[each.key].id

  # EXPLICIT true (matches the module default, stated per the design ruling):
  # front-end UI/REST stays reachable for user + QA - no private access path
  # exists this sprint (Bastion off, no VPN). Front/back-end Private Link is the
  # production design target (design doc section 8).
  public_network_access_enabled = true

  # diagnostic_settings is deliberately NOT set (ADR-076 decision 4): the
  # workspace diagnostic setting is the root-level
  # azapi_resource.dbw_diag_platform_law below, replacing the module interface's
  # azurerm_monitor_diagnostic_setting 1:1. Do not re-add the input - two writers
  # for the same setting name would collide.

  tags = local.common_tags

  # Exemption propagation gate (LESSON 35 / ADR-028 unit): the workspace create
  # must not race the subscription-scoped Waiver in policy_exemptions.tf.
  #
  # ADR-070 NOTE - deliberately NOT gated on
  # time_sleep.wait_dine_ownership_exemptions, and the reason is written down so
  # the omission is not read as an oversight. There is nothing to exempt:
  # Deploy-Diag-LogsCat's resourceTypeList has no microsoft.databricks/workspaces
  # entry and the initiative carries no member for that type, so there is no
  # reference id (live enumeration 2026-07-31, PC-2DINE). The only Databricks
  # diagnostics policy above this root is "Resource logs in Azure Databricks
  # Workspaces should be enabled" (138ff14d-b687-4faa-a81c-898c91a87fa2) inside
  # Deploy-ASC-Monitoring and Deploy-MCSB2-Monitoring, whose allowedValues are
  # AuditIfNotExists and Disabled only.
  #
  # diag-dbw-* was one of the three "already exists" failures on runs
  # 30661012325 / 30662610292, and no DINE anywhere can have caused any of the
  # three - the disproof in policy_exemptions.tf is about NAME SCOPING and holds
  # for every resource type, not just this one. That leg was OQ-067 item B; its
  # mechanism is now established as the FM-3 orphan minted by the out-of-band
  # Databricks force-delete (ADR-076 limbs 1-2, attempt 7 run 31348557765), and
  # the setting itself is now the idempotent azapi resource below, so a surviving
  # orphan overwrites instead of colliding - no B1 recovery needed for it.
  depends_on = [time_sleep.wait_dbx_storage_exemption]
}

# ---------------------------------------------------------------------------
# Workspace diagnostic setting - ROOT-LEVEL azapi (ADR-076 decision 4)
# ---------------------------------------------------------------------------
# DEVIATION (ADR-076 decision 4, exercising ADR-071 4a on its fired T3 trigger,
# attempt 7 run 31348557765): this setting's host is the ONE estate host deleted
# out-of-band by design (the teardown Databricks force-delete, ADR-072 C4), so an
# FM-3 orphan record can survive a teardown and is undiscoverable while the host
# is absent (ADR-076 decision 5). The azurerm provider hard-fails the create on
# an existing same-name setting (ImportAsExistsError); azapi PUTs with no
# RequiresImport pre-check, so the create idempotently overwrites any orphan.
# Scoped to THIS setting only - every other setting in the root stays on its
# module's supported interface.
#
# Shape mirrors the estate-proven azapi diagnostic-setting idiom inside
# module.datalake (avm-res-storage-storageaccount 0.7.3 modules/diagnostic_setting
# + Azure/avm-utl-interfaces 0.6.0 locals.diagnostic_settings_v2.tf, read from the
# vendored source 2026-08-10): same type and api-version (the repo-wide
# RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION), same normalization arguments, same
# logAnalyticsDestinationType lifecycle guard. Body parity with the REMOVED
# module-rendered setting (avm-res-databricks-workspace 0.5.0 main.tf lines
# 56-81): same name, same LAW destination, one categoryGroup "allLogs" log entry
# (module default log_groups = ["allLogs"], log_categories = []), NO metrics (the
# module declared but never rendered them), NO logAnalyticsDestinationType. The
# allLogs categoryGroup for Microsoft.Databricks/workspaces is live-proven by this
# estate's own prior applies of the identical rendering (B1 recovery run
# 30671577938 created diag-dbw-* green). Diagnostic settings are an extension
# resource with NO tags property, so common_tags is inapplicable (same as
# azapi_resource.foundry_pe_dns_zone_group in ai.tf). Uses the root's anchored
# default azapi provider (LESSON 23). parent_id orders this after the workspace;
# no DINE exemption gate is needed for this type (see the ADR-070 NOTE above).
resource "azapi_resource" "dbw_diag_platform_law" {
  for_each = var.enable_data_platform ? { main = "main" } : {}

  name      = "diag-dbw-bank-data-p1-${var.org_prefix}-${var.environment}"
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  parent_id = module.databricks_workspace[each.key].resource_id

  body = {
    properties = {
      logAnalyticsDestinationType = null
      logs = [
        {
          category      = null
          categoryGroup = "allLogs"
          enabled       = true
          retentionPolicy = {
            days    = 0
            enabled = false
          }
        }
      ]
      metrics     = null
      workspaceId = var.platform_law_workspace_id
    }
  }

  # The three arguments below are the proven-idiom normalization set: nulls are
  # stripped from the PUT and excluded from drift; Azure-returned extra list
  # items (for example per-category entries materialized from a categoryGroup)
  # never diff; list items pair on their identity keys, not on order.
  # ignore_other_items_in_list / list_unique_id_property require azapi >= 2.9.0
  # (provider CHANGELOG; providers.tf floor raised accordingly).
  ignore_null_property = true
  ignore_other_items_in_list = [
    "properties.logs",
    "properties.metrics",
  ]
  list_unique_id_property = {
    "properties.logs"    = "category, categoryGroup"
    "properties.metrics" = "category"
  }

  # Matches the datalake idiom: the preview api-version is validated by ARM at
  # PUT time, not by the provider's embedded schema.
  schema_validation_enabled = false

  lifecycle {
    # Azure computes and returns a destination type even when none is sent;
    # same guard as the datalake idiom.
    ignore_changes = [body.properties.logAnalyticsDestinationType]
  }
}
