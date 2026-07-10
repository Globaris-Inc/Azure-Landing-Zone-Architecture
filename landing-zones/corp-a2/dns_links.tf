# Purpose: corp-a2 Private DNS VNet links, SQL PE DNS zone group, and VNet flow logs.
# Section: 4 - Private Endpoints + Private DNS
# Last updated: 2026-07-10
#
# Architecture:
#   - Data source looks up the centralized SQL DNS zone in the Connectivity
#     subscription via the azurerm.connectivity alias.
#   - VNet link registers the corp-a2 (DR) spoke VNet with the SQL zone.
#   - DNS zone group on the corp-a2 SQL private endpoint resolves private FQDNs.
#   - VNet flow log (whole spoke VNet) delivers raw logs to a centralus storage
#     account; replaces the retired NSG flow log. Traffic Analytics is disabled
#     on this DR spoke (no region-matched LAW - see the flow log resource note).
#
# NOTE: corp-a2 is in centralus (secondary region). The Network Watcher and
# storage account are created in centralus.

# ---------------------------------------------------------------------------
# Data source - SQL Private DNS zone (Connectivity subscription)
# ---------------------------------------------------------------------------

data "azurerm_private_dns_zone" "sql" {
  provider            = azurerm.connectivity
  name                = "privatelink.database.windows.net"
  resource_group_name = var.private_dns_rg_name
}

# ---------------------------------------------------------------------------
# Spoke VNet link - register corp-a2 spoke with the SQL zone
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone_virtual_network_link" "corp_a2_to_sql_zone" {
  provider              = azurerm.connectivity
  name                  = "vnetlink-corp-a2-to-sql-${var.org_prefix}-${var.environment}"
  resource_group_name   = var.private_dns_rg_name
  private_dns_zone_name = data.azurerm_private_dns_zone.sql.name
  virtual_network_id    = module.spoke_vnet.resource_id
  registration_enabled  = false

  depends_on = [module.spoke_vnet]
}

# ---------------------------------------------------------------------------
# SQL Private Endpoint - DNS zone group
# Registered via the private_dns_zone_group nested block on
# azurerm_private_endpoint.sql in main.tf (azurerm has no standalone
# azurerm_private_dns_zone_group resource).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Storage Account - NSG flow log sink (Standard LRS)
# ---------------------------------------------------------------------------

resource "random_id" "flowlog_sa" {
  byte_length = 4
}

resource "azurerm_storage_account" "flow_logs" {
  name                            = "stflow${var.environment}a2${random_id.flowlog_sa.hex}"
  resource_group_name             = azurerm_resource_group.network.name
  location                        = var.secondary_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # public_network_access stays Enabled by design (NSG flow-log delivery requires it).
  # The corp-MG StorageDenyPaasPublicIP Deny is admitted via the RG-scoped Waiver
  # exemption in policy_exemptions.tf (OQ-024 / ADR-028). Wait for it to propagate.
  tags = local.common_tags

  depends_on = [time_sleep.wait_corp_policy_exemptions]
}

# ---------------------------------------------------------------------------
# Network Watcher data source (secondary region - centralus)
# ---------------------------------------------------------------------------

data "azurerm_network_watcher" "secondary" {
  name                = "NetworkWatcher_${var.secondary_location}"
  resource_group_name = "NetworkWatcherRG"
}

# ---------------------------------------------------------------------------
# VNet flow log - corp-a2 spoke VNet -> flow-log storage account (raw logs).
# Traffic Analytics is DISABLED on this DR (centralus) spoke - it needs a
# region-matched Log Analytics workspace and the only LAW is in eastus2
# (InvalidTAWorkspaceRegion); see the resource comment below. Migrated from an
# NSG flow log: Azure retired new NSG flow log creation on June 30, 2025.
# target_resource_id points at the spoke VNet (whole-VNet coverage); it replaces
# the removed network_security_group_id argument.
# ---------------------------------------------------------------------------

resource "azurerm_network_watcher_flow_log" "spoke" {
  name                 = "flowlog-spoke-corp-a2-${var.org_prefix}-${var.environment}"
  network_watcher_name = data.azurerm_network_watcher.secondary.name
  resource_group_name  = data.azurerm_network_watcher.secondary.resource_group_name
  target_resource_id   = module.spoke_vnet.resource_id
  storage_account_id   = azurerm_storage_account.flow_logs.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  # Traffic Analytics is intentionally DISABLED on the corp-a2 DR (centralus)
  # spoke. TA requires the flow log and its Log Analytics workspace to be
  # region-matched (or a supported pairing); the only platform LAW is in
  # eastus2, and there is no centralus LAW. Enabling TA here returns
  # 400 InvalidTAWorkspaceRegion (workspace located in eastus2, flow log in
  # centralus). The flow log still delivers raw logs to
  # azurerm_storage_account.flow_logs; only the TA enrichment is dropped.
  # Re-enable the traffic_analytics block if a centralus LAW is provisioned.
  # traffic_analytics is an optional block in the azurerm 4.71
  # azurerm_network_watcher_flow_log schema, so omitting it is valid.

  tags = local.common_tags
}
