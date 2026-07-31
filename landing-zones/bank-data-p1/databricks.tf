# Purpose: bank-data-p1 Azure Databricks Premium workspace (wave B5) - VNet-injected
#          into the two live delegated subnets (snet-databricks-host / -container,
#          B1), secure cluster connectivity (no_public_ip = true), default storage
#          firewall with a pre-created access connector, deterministic managed-RG
#          name, diagnostics to the platform LAW. ALL resources gated behind
#          var.enable_data_platform (default false, LESSON 42 flag pattern).
# Section: Banking wave B5 (docs/b5-data-platform-design.md sections 3-4; ADR-048)
# Last updated: 2026-07-18
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

  # Module renders log category groups only (metric categories are declared but
  # not rendered - verified in the v0.5.0 source); defaults to allLogs.
  diagnostic_settings = {
    platform_law = {
      name                  = "diag-dbw-bank-data-p1-${var.org_prefix}-${var.environment}"
      workspace_resource_id = var.platform_law_workspace_id
    }
  }

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
  # for every resource type, not just this one. That leg is OQ-067 item B, its
  # cause is NOT established, no exemption fixes it, and its recovery is the
  # runbook B1 delete-then-retry before the next dispatch.
  depends_on = [time_sleep.wait_dbx_storage_exemption]
}
