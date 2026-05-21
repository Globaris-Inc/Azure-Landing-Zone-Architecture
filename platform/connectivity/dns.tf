# Purpose: Centralised Private DNS zones for Azure Private Link services.
# Section: 4 — Private Endpoints + Private DNS
# Last updated: 2026-05-21
#
# Architecture:
#   - Dedicated RG (rg-dns-*) in the Connectivity subscription holds all zones.
#   - AVM pattern module creates the full set of Azure Private Link DNS zones.
#   - Both hub VNets are linked to every zone so hub-resident resources resolve
#     private endpoints natively.
#   - Each spoke landing zone creates its own per-spoke VNet links
#     (see landing-zones/*/dns_links.tf) using the azurerm.connectivity alias.

# ---------------------------------------------------------------------------
# Resource Group — Private DNS zones
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "dns" {
  name     = "rg-dns-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Private DNS Zones — all Azure Private Link zones
# Module: Azure/avm-ptn-network-private-link-private-dns-zones/azurerm v0.23.1
# Confirmed on registry.terraform.io 2026-05-21
#
# DEVIATION: resource_group_creation_enabled = false because the RG is created
# above with the project's standard naming convention. If the module does not
# support this variable, remove the RG resource above and let the module create
# its own RG (update the private_dns_rg_name output accordingly).
# ---------------------------------------------------------------------------

module "private_dns_zones" {
  source  = "Azure/avm-ptn-network-private-link-private-dns-zones/azurerm"
  version = "0.23.1"

  resource_group_name             = azurerm_resource_group.dns.name
  location                        = var.primary_location
  resource_group_creation_enabled = false

  # Link both hub VNets to every zone on creation. Spoke VNet links are added
  # separately by each landing zone (spoke VNets don't exist at connectivity deploy time).
  virtual_network_link_default_virtual_networks = {
    primary-hub = {
      virtual_network_resource_id = module.hub_and_spoke.virtual_network_resource_ids["primary"]
    }
    secondary-hub = {
      virtual_network_resource_id = module.hub_and_spoke.virtual_network_resource_ids["secondary"]
    }
  }

  tags = local.common_tags

  depends_on = [azurerm_resource_group.dns]
}
