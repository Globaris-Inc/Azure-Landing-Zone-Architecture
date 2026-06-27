# Purpose: corp-a2 Private DNS VNet links, SQL PE DNS zone group, and NSG flow logs.
# Section: 4 — Private Endpoints + Private DNS
# Last updated: 2026-05-21
#
# Architecture:
#   - Data source looks up the centralized SQL DNS zone in the Connectivity
#     subscription via the azurerm.connectivity alias.
#   - VNet link registers the corp-a2 (DR) spoke VNet with the SQL zone.
#   - DNS zone group on the corp-a2 SQL private endpoint resolves private FQDNs.
#   - NSG flow logs flow to the platform LA workspace (Traffic Analytics).
#
# NOTE: corp-a2 is in centralus (secondary region). The Network Watcher and
# storage account are created in centralus.

# ---------------------------------------------------------------------------
# Data source — SQL Private DNS zone (Connectivity subscription)
# ---------------------------------------------------------------------------

data "azurerm_private_dns_zone" "sql" {
  provider            = azurerm.connectivity
  name                = "privatelink.database.windows.net"
  resource_group_name = var.private_dns_rg_name
}

# ---------------------------------------------------------------------------
# Spoke VNet link — register corp-a2 spoke with the SQL zone
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
# SQL Private Endpoint — DNS zone group
# Registered via the private_dns_zone_group nested block on
# azurerm_private_endpoint.sql in main.tf (azurerm has no standalone
# azurerm_private_dns_zone_group resource).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Storage Account — NSG flow log sink (Standard LRS)
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

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Network Watcher data source (secondary region — centralus)
# ---------------------------------------------------------------------------

data "azurerm_network_watcher" "secondary" {
  name                = "NetworkWatcher_${var.secondary_location}"
  resource_group_name = "NetworkWatcherRG"
}

# ---------------------------------------------------------------------------
# NSG flow log — corp-a2 spoke NSG → platform Log Analytics (Traffic Analytics)
# ---------------------------------------------------------------------------

resource "azurerm_network_watcher_flow_log" "spoke" {
  name                      = "flowlog-spoke-corp-a2-${var.org_prefix}-${var.environment}"
  network_watcher_name      = data.azurerm_network_watcher.secondary.name
  resource_group_name       = data.azurerm_network_watcher.secondary.resource_group_name
  network_security_group_id = azurerm_network_security_group.spoke.id
  storage_account_id        = azurerm_storage_account.flow_logs.id
  enabled                   = true
  version                   = 2

  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = var.platform_law_customer_id
    workspace_region      = var.secondary_location
    workspace_resource_id = var.platform_law_workspace_id
    interval_in_minutes   = 10
  }

  tags = local.common_tags
}
