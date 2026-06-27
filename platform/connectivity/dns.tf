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
# v0.23.1 uses an existing RG via parent_id (the RG resource ID); there is no
# resource_group_creation_enabled toggle — the module always links to the RG
# referenced by parent_id, which is exactly the RG created above.
# ---------------------------------------------------------------------------

module "private_dns_zones" {
  source  = "Azure/avm-ptn-network-private-link-private-dns-zones/azurerm"
  version = "0.23.1"

  parent_id = azurerm_resource_group.dns.id # v0.23.1: parent_id (existing RG resource ID) replaces resource_group_name
  location  = var.primary_location

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
