# Purpose: bank-app-p1 Private DNS VNet links and VNet flow log.
# Section: Banking wave B1 - banking network foundation (docs/banking-platform-design.md)
# Last updated: 2026-07-16
#
# Architecture:
#   - Zone links registered NOW (B1 network wave, per the design doc B1 scope) for the
#     zones the bank-app-p1 workload waves resolve through: AKS private API server (B2),
#     ACR Private Link (B2), Event Hubs / Service Bus Private Link (B3 - both share
#     privatelink.servicebus.windows.net). All three zones are in the estate's central
#     zone set: platform/connectivity deploys the FULL AVM default zone list
#     (avm-ptn-network-private-link-private-dns-zones 0.23.1), which includes
#     privatelink.{regionName}.azmk8s.io (regionName substituted with the module
#     location = primary region), privatelink.azurecr.io and
#     privatelink.servicebus.windows.net (verified in the pinned module source
#     .terraform/modules/private_dns_zones/variables.tf, 2026-07-15).
#   - Single VNet flow log covering the whole spoke VNet with Traffic Analytics to the
#     platform LAW (NSG flow logs retired 2025-06-30; a VNet supports ONE flow log -
#     estate template fix, WORKLOG 2026-07-10).

# ---------------------------------------------------------------------------
# Private DNS zone lookups + spoke VNet links (Connectivity subscription)
# ---------------------------------------------------------------------------

locals {
  # Static keys (for_each rule); zone names verified against the pinned
  # avm-ptn-network-private-link-private-dns-zones 0.23.1 default zone list.
  private_dns_zone_links = {
    aks        = "privatelink.${var.primary_location}.azmk8s.io"
    acr        = "privatelink.azurecr.io"
    servicebus = "privatelink.servicebus.windows.net"
  }
}

data "azurerm_private_dns_zone" "linked" {
  for_each = local.private_dns_zone_links

  provider            = azurerm.connectivity
  name                = each.value
  resource_group_name = var.private_dns_rg_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "bank_app_p1" {
  for_each = local.private_dns_zone_links

  provider              = azurerm.connectivity
  name                  = "vnetlink-bank-app-p1-to-${each.key}-${var.org_prefix}-${var.environment}"
  resource_group_name   = var.private_dns_rg_name
  private_dns_zone_name = data.azurerm_private_dns_zone.linked[each.key].name
  virtual_network_id    = module.spoke_vnet.resource_id
  registration_enabled  = false

  depends_on = [module.spoke_vnet]
}

# ---------------------------------------------------------------------------
# Storage Account - VNet flow log sink
# ---------------------------------------------------------------------------

resource "random_id" "flowlog_sa" {
  byte_length = 4
}

resource "azurerm_storage_account" "flow_logs" {
  # Final rendered length check (LESSON 27): "stflow" (6) + env "poc" (3) +
  # "bap1" (4) + hex (8) = 21 chars <= 24. Re-check if environment ever exceeds 6 chars.
  name                            = "stflow${var.environment}bap1${random_id.flowlog_sa.hex}"
  resource_group_name             = azurerm_resource_group.network.name
  location                        = var.primary_location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # public_network_access stays Enabled by design (flow-log delivery requires it;
  # Network Watcher is not a storage trusted-service bypass). The corp-MG
  # StorageDenyPaasPublicIP Deny is admitted via the RG-scoped Waiver exemption in
  # policy_exemptions.tf (OQ-024 / ADR-028). Wait for it to propagate (LESSON 35).
  tags = local.common_tags

  depends_on = [time_sleep.wait_corp_policy_exemptions]
}

# ---------------------------------------------------------------------------
# Network Watcher data source (primary region)
# ---------------------------------------------------------------------------

data "azurerm_network_watcher" "primary" {
  name                = "NetworkWatcher_${var.primary_location}"
  resource_group_name = "NetworkWatcherRG"
}

# ---------------------------------------------------------------------------
# VNet flow log - bank-app-p1 spoke VNet -> platform Log Analytics (Traffic Analytics)
# target_resource_id is the spoke VNet (VNet-scoped flow logs; NSG flow logs retired
# 2025-06-30, LESSON 40). Traffic Analytics LAW is region-matched (eastus2, LESSON 43).
# ---------------------------------------------------------------------------

resource "azurerm_network_watcher_flow_log" "spoke" {
  name                 = "flowlog-spoke-bank-app-p1-${var.org_prefix}-${var.environment}"
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
