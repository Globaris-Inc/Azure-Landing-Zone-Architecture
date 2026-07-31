# Purpose: Outputs for the Connectivity platform root module.
# Section: 8 - Standard Platform Components
# Last updated: 2026-07-17 (ADR-042: try() on firewall/gateway/resolver outputs - null while flags off; fix primary_vpn_gateway_id key to "primary-vpn")

output "connectivity_primary_rg_name" {
  description = "Name of the primary connectivity resource group."
  value       = azurerm_resource_group.connectivity_primary.name
}

output "connectivity_primary_rg_id" {
  description = "ARM resource ID of the primary connectivity resource group."
  value       = azurerm_resource_group.connectivity_primary.id
}

output "connectivity_secondary_rg_name" {
  description = "Name of the secondary (DR) connectivity resource group."
  value       = azurerm_resource_group.connectivity_secondary.name
}

output "connectivity_secondary_rg_id" {
  description = "ARM resource ID of the secondary (DR) connectivity resource group."
  value       = azurerm_resource_group.connectivity_secondary.id
}

output "primary_hub_vnet_id" {
  description = "ARM resource ID of the primary hub VNet (centralus). Consumed by spoke peering in Section 9."
  value       = module.hub_and_spoke.virtual_network_resource_ids["primary"]
}

output "primary_hub_vnet_name" {
  description = "Name of the primary hub VNet."
  value       = module.hub_and_spoke.virtual_network_resource_names["primary"]
}

output "secondary_hub_vnet_id" {
  description = "ARM resource ID of the secondary (DR) hub VNet (eastus2)."
  value       = module.hub_and_spoke.virtual_network_resource_ids["secondary"]
}

output "secondary_hub_vnet_name" {
  description = "Name of the secondary (DR) hub VNet."
  value       = module.hub_and_spoke.virtual_network_resource_names["secondary"]
}

output "primary_firewall_id" {
  description = "ARM resource ID of the primary Azure Firewall Premium; null while the ADR-042 enable_firewall flag is off."
  value       = try(module.hub_and_spoke.firewall_resource_ids["primary"], null)
}

output "primary_firewall_private_ip" {
  description = "Private IP address of the primary Azure Firewall, used as next-hop in spoke UDRs; null while the ADR-042 enable_firewall flag is off (the repo Secret carries the 10.0.0.4 contract, not this output)."
  value       = try(module.hub_and_spoke.firewall_private_ip_addresses["primary"], null)
}

output "secondary_firewall_id" {
  description = "ARM resource ID of the secondary Azure Firewall Premium; null while the ADR-042 enable_firewall flag is off."
  value       = try(module.hub_and_spoke.firewall_resource_ids["secondary"], null)
}

output "secondary_firewall_private_ip" {
  description = "Private IP address of the secondary Azure Firewall, used as next-hop in DR spoke UDRs; null while the ADR-042 enable_firewall flag is off (the repo Secret carries the 10.1.0.4 contract, not this output)."
  value       = try(module.hub_and_spoke.firewall_private_ip_addresses["secondary"], null)
}

output "primary_vpn_gateway_id" {
  description = "ARM resource ID of the primary hub VPN Gateway; null while the ADR-042 enable_vpn_gateway flag is off."
  # Module keys this map by gateway key "<hub_key>-vpn" (module outputs.tf lines 141-144,
  # v0.17.1), not by a nested ["primary"]["vpn"] path - the prior UNVERIFIED lookup could
  # never resolve and would have been silently null even with the gateway deployed.
  value = try(module.hub_and_spoke.virtual_network_gateway_resource_ids["primary-vpn"], null)
}

output "primary_bastion_id" {
  description = "ARM resource ID of the primary hub Azure Bastion when deployed on demand (var.enable_bastion = true); null when Bastion is off. See ADR-015 / G6."
  # The module's bastion_host_resource_ids map only contains the 'primary' key while
  # enabled_resources.bastion is true, so try(...) yields null when the flag is off.
  value = try(module.hub_and_spoke.bastion_host_resource_ids["primary"], null)
}

output "primary_bastion_dns_name" {
  description = "DNS name of the primary hub Azure Bastion when deployed on demand (var.enable_bastion = true); null when Bastion is off."
  value       = try(module.hub_and_spoke.bastion_host_dns_names["primary"], null)
}

output "primary_dns_resolver_inbound_ips" {
  description = "IP address(es) of the primary hub DNS Private Resolver inbound endpoint, for use as DNS server in spoke VNets; null while the ADR-042 enable_dns_resolver flag is off."
  value       = try(module.hub_and_spoke.dns_resolver_inbound_endpoint_ip_addresses["primary"], null)
}

# ---------------------------------------------------------------------------
# Section 4 - Private DNS outputs consumed by landing zone dns_links.tf files
# ---------------------------------------------------------------------------

output "private_dns_rg_name" {
  description = "Name of the resource group holding all Private Link DNS zones. Passed to spoke landing zones so they can look up zone IDs via data sources."
  value       = azurerm_resource_group.dns.name
}

output "private_dns_zone_ids" {
  description = "Map of private DNS zone name → ARM resource ID. Populated after dns.tf apply. Consumed by spoke landing zones for private_dns_zone_group blocks."
  value       = module.private_dns_zones.private_dns_zone_resource_ids
}
