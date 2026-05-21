# Purpose: online-p1 Private DNS VNet links and NSG flow logs.
# Section: 4 — Private Endpoints + Private DNS
# Last updated: 2026-05-21
#
# Architecture:
#   - No private endpoints in online-p1 scope (Static Web App uses public endpoint);
#     VNet link still registers the spoke so it can resolve any future PEs via the
#     central DNS zones.
#   - Two NSG flow logs: one for the App Gateway NSG and one for the workload NSG.
#     Traffic Analytics enabled for both.

# ---------------------------------------------------------------------------
# Data source — SQL Private DNS zone (used for general spoke registration)
# ---------------------------------------------------------------------------

data "azurerm_private_dns_zone" "sql" {
  provider            = azurerm.connectivity
  name                = "privatelink.database.windows.net"
  resource_group_name = var.private_dns_rg_name
}

# ---------------------------------------------------------------------------
# Spoke VNet link — register online-p1 spoke with the SQL zone
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone_virtual_network_link" "online_p1_to_sql_zone" {
  provider              = azurerm.connectivity
  name                  = "vnetlink-online-p1-to-sql-${var.org_prefix}-${var.environment}"
  resource_group_name   = var.private_dns_rg_name
  private_dns_zone_name = data.azurerm_private_dns_zone.sql.name
  virtual_network_id    = module.spoke_vnet.resource_id
  registration_enabled  = false

  depends_on = [module.spoke_vnet]
}

# ---------------------------------------------------------------------------
# Storage Account — NSG flow log sink for both App Gateway and workload NSGs
# ---------------------------------------------------------------------------

resource "random_id" "flowlog_sa" {
  byte_length = 4
}

resource "azurerm_storage_account" "flow_logs" {
  name                            = "stflowp1${var.environment}${random_id.flowlog_sa.hex}"
  resource_group_name             = azurerm_resource_group.network.name
  location                        = var.primary_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Network Watcher data source (primary region — eastus2)
# ---------------------------------------------------------------------------

data "azurerm_network_watcher" "primary" {
  name                = "NetworkWatcher_${var.primary_location}"
  resource_group_name = "NetworkWatcherRG"
}

# ---------------------------------------------------------------------------
# NSG flow log — App Gateway NSG (internet-facing; captures inbound traffic)
# ---------------------------------------------------------------------------

resource "azurerm_network_watcher_flow_log" "appgw" {
  name                      = "flowlog-appgw-online-p1-${var.org_prefix}-${var.environment}"
  network_watcher_name      = data.azurerm_network_watcher.primary.name
  resource_group_name       = data.azurerm_network_watcher.primary.resource_group_name
  network_security_group_id = azurerm_network_security_group.appgw.id
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
    workspace_region      = var.primary_location
    workspace_resource_id = var.platform_law_workspace_id
    interval_in_minutes   = 10
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# NSG flow log — Workload NSG (internal spoke traffic)
# ---------------------------------------------------------------------------

resource "azurerm_network_watcher_flow_log" "workload" {
  name                      = "flowlog-workload-online-p1-${var.org_prefix}-${var.environment}"
  network_watcher_name      = data.azurerm_network_watcher.primary.name
  resource_group_name       = data.azurerm_network_watcher.primary.resource_group_name
  network_security_group_id = azurerm_network_security_group.workload.id
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
    workspace_region      = var.primary_location
    workspace_resource_id = var.platform_law_workspace_id
    interval_in_minutes   = 10
  }

  tags = local.common_tags
}
