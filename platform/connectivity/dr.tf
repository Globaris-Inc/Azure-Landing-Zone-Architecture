# Purpose: Multi-Region DR Topology - inter-hub connectivity notes.
# Section: 3 - Multi-Region DR Topology
# Last updated: 2026-07-17 (ADR-042 note: mesh is firewall-independent; hub route tables absent while gated)
#
# Architecture:
#   - Hub-to-hub transit between primary (eastus2) and secondary (centralus)
#     enables the corp-a2 DR spoke to reach corp-a1 resources through the firewall
#     chain without on-premises VPN traversal.
#   - ADR-042: the mesh peering is firewall-independent and deploys regardless of
#     enable_firewall; the module-gated hub route tables (rt-hub-fw/rt-hub-std) are
#     ABSENT while enable_firewall = false, so nothing may assume they exist.
#
# Hub-to-hub peering ownership - module native mesh (no standalone peerings here):
#   The Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet v0.17.1 module AUTO-MESHES
#   every hub in hub_virtual_networks whose mesh_peering_enabled is true (the default).
#   With two hubs keyed primary/secondary it already creates both directions of the
#   hub-to-hub peering (vnet-hub-primary-...-to-vnet-hub-secondary-... and the reverse).
#   We previously ALSO declared azurerm_virtual_network_peering resources here, which
#   made Azure reject the second peering to the same remote VNet
#   (400 AnotherPeeringAlreadyReferencesRemoteVnet). Those standalone resources have
#   been removed; the module's mesh peering is the single owner.
#
#   The module hard-codes the mesh peering flags (see
#   modules/hub-virtual-network-mesh/locals.peering.tf lines 8-11 in v0.17.1):
#     allow_virtual_network_access = true
#     allow_forwarded_traffic      = true   # both directions - spoke-to-spoke east-west
#                                            #   inspected by each region's Firewall
#     allow_gateway_transit        = true   # both directions - satisfies the primary-side
#                                            #   requirement so the secondary may later use
#                                            #   the primary VPN GW; true on the secondary is
#                                            #   a no-op (secondary has no gateway to transit)
#     use_remote_gateways          = false  # neither hub uses the remote gateway yet
#   These are not exposed as per-hub inputs; only mesh_peering_enabled (toggle) and
#   peering_names (name override) are configurable. The fixed values above are a superset
#   of the DR requirement, so the module mesh is used as-is.
#
#   Note vs the prior standalone config: that config set the secondary side
#   allow_gateway_transit = false. The module sets it true on both sides. This is a benign
#   difference - allow_gateway_transit advertises the LOCAL gateway to the peer, and the
#   secondary hub has no VPN/ER gateway, so the flag has no effect until one is added.
#
#   Future - to let the secondary actually use the primary VPN GW: the mesh module cannot
#   set use_remote_gateways = true on the secondary→primary peering. That would require
#   either a module enhancement or reverting the secondary to a standalone
#   azurerm_virtual_network_peering with mesh_peering_enabled = false on the secondary hub.
#
# DEVIATION - Shared Firewall Policy hierarchy:
#   PROMPT.md §3 requires a parent Firewall Policy in primary with the secondary
#   inheriting as a child (base_policy_id). The hub module
#   (Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet v0.17.1) creates firewall
#   policies internally and does not expose a base_policy_id input. Both hubs
#   currently have independent Premium policies with identical IDPS Alert config.
#   Production path: migrate firewall policies out of the hub module into standalone
#   azurerm_firewall_policy resources, then set base_policy_id on the secondary
#   policy to reference the primary (parent) policy resource.
