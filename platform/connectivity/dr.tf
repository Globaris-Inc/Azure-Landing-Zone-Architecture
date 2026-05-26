# Purpose: Multi-Region DR Topology — inter-hub Global VNet Peering.
# Section: 3 — Multi-Region DR Topology
# Last updated: 2026-05-21
#
# Architecture:
#   - Global VNet Peering between primary hub (eastus2) and secondary hub (centralus)
#     enables hub-to-hub transit so corp-a2 DR spoke can reach corp-a1 resources
#     through the firewall chain without on-premises VPN traversal.
#   - Primary hub: allow_gateway_transit = true so the secondary hub may eventually
#     use the primary VPN GW for on-premises reachability.
#   - Both peerings: allow_forwarded_traffic = true for spoke-to-spoke east-west
#     traffic that is inspected by each region's Firewall before crossing the peering.
#
# DEVIATION — Shared Firewall Policy hierarchy:
#   PROMPT.md §3 requires a parent Firewall Policy in primary with the secondary
#   inheriting as a child (base_policy_id). The hub module
#   (Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet v0.17.1) creates firewall
#   policies internally and does not expose a base_policy_id input. Both hubs
#   currently have independent Premium policies with identical IDPS Alert config.
#   Production path: migrate firewall policies out of the hub module into standalone
#   azurerm_firewall_policy resources, then set base_policy_id on the secondary
#   policy to reference the primary (parent) policy resource.

# ---------------------------------------------------------------------------
# Global VNet Peering — primary hub → secondary hub
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network_peering" "primary_hub_to_secondary_hub" {
  name                      = "peer-primary-hub-to-secondary-hub"
  resource_group_name       = azurerm_resource_group.connectivity_primary.name
  virtual_network_name      = module.hub_and_spoke.virtual_network_resource_names["primary"]
  remote_virtual_network_id = module.hub_and_spoke.virtual_network_resource_ids["secondary"]

  allow_forwarded_traffic = true
  allow_gateway_transit   = true # primary holds the VPN GW; expose it for future secondary use
  use_remote_gateways     = false

  depends_on = [module.hub_and_spoke]
}

# ---------------------------------------------------------------------------
# Global VNet Peering — secondary hub → primary hub
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network_peering" "secondary_hub_to_primary_hub" {
  name                      = "peer-secondary-hub-to-primary-hub"
  resource_group_name       = azurerm_resource_group.connectivity_secondary.name
  virtual_network_name      = module.hub_and_spoke.virtual_network_resource_names["secondary"]
  remote_virtual_network_id = module.hub_and_spoke.virtual_network_resource_ids["primary"]

  allow_forwarded_traffic = true
  allow_gateway_transit   = false
  use_remote_gateways     = false # secondary has no local GW; set true if secondary VPN GW added later

  depends_on = [module.hub_and_spoke]
}
