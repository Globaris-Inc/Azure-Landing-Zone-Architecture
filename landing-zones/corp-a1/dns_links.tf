# Purpose: corp-a1 Private DNS VNet links, SQL PE DNS zone group, and VNet flow logs.
# Section: 4 - Private Endpoints + Private DNS
# Last updated: 2026-07-10
#
# Architecture:
#   - Data source looks up the centralized DNS zone in the Connectivity subscription
#     via the azurerm.connectivity provider alias.
#   - VNet link registers the corp-a1 spoke VNet with the SQL private DNS zone.
#   - DNS zone group on the SQL private endpoint resolves private link FQDNs via
#     the centralized zone.
#   - VNet flow log captures all accepted + rejected flows for the whole spoke
#     VNet (replaces the retired NSG flow log); Traffic Analytics correlates them
#     in the platform Log Analytics workspace.

# ---------------------------------------------------------------------------
# Data source - SQL Private DNS zone (Connectivity subscription)
# ---------------------------------------------------------------------------

data "azurerm_private_dns_zone" "sql" {
  provider            = azurerm.connectivity
  name                = "privatelink.database.windows.net"
  resource_group_name = var.private_dns_rg_name
}

# ---------------------------------------------------------------------------
# Spoke VNet link - register corp-a1 spoke with the SQL zone
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone_virtual_network_link" "corp_a1_to_sql_zone" {
  provider              = azurerm.connectivity
  name                  = "vnetlink-corp-a1-to-sql-${var.org_prefix}-${var.environment}"
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
# azurerm_private_dns_zone_group resource). The data source and VNet link below
# provide the zone ID and registration this depends on.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Storage Account - NSG flow log sink (Standard LRS, minimal retention)
# ---------------------------------------------------------------------------

resource "random_id" "flowlog_sa" {
  byte_length = 4
}

resource "azurerm_storage_account" "flow_logs" {
  name                            = "stflow${var.environment}a1${random_id.flowlog_sa.hex}"
  resource_group_name             = azurerm_resource_group.network.name
  location                        = var.primary_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # public_network_access stays Enabled by design: NSG flow-log delivery requires it
  # (Network Watcher is not a storage trusted-service bypass). The corp-MG
  # StorageDenyPaasPublicIP Deny is admitted via the RG-scoped Waiver exemption in
  # policy_exemptions.tf (OQ-024 / ADR-028). Wait for that exemption to propagate.
  tags = local.common_tags

  depends_on = [time_sleep.wait_corp_policy_exemptions]
}

# ---------------------------------------------------------------------------
# Network Watcher data source (auto-created by Azure per region, per subscription)
# ---------------------------------------------------------------------------

data "azurerm_network_watcher" "primary" {
  name                = "NetworkWatcher_${var.primary_location}"
  resource_group_name = "NetworkWatcherRG"
}

# ---------------------------------------------------------------------------
# VNet flow log - corp-a1 spoke VNet -> platform Log Analytics (Traffic Analytics)
# Migrated from an NSG flow log: Azure retired new NSG flow log creation on
# June 30, 2025. target_resource_id points at the spoke VNet (whole-VNet coverage);
# it replaces the removed network_security_group_id argument.
# ---------------------------------------------------------------------------

resource "azurerm_network_watcher_flow_log" "spoke" {
  name                 = "flowlog-spoke-corp-a1-${var.org_prefix}-${var.environment}"
  network_watcher_name = data.azurerm_network_watcher.primary.name
  resource_group_name  = data.azurerm_network_watcher.primary.resource_group_name
  target_resource_id   = module.spoke_vnet.resource_id
  storage_account_id   = azurerm_storage_account.flow_logs.id
  enabled              = true
  version              = 2

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = var.platform_law_customer_id
    workspace_region      = var.primary_location
    workspace_resource_id = var.platform_law_workspace_id
    interval_in_minutes   = 10
  }

  tags = local.common_tags
}
