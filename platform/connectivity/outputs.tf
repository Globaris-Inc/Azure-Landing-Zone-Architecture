# Purpose: Outputs for the Connectivity platform root module.
# Section: 8 — Standard Platform Components
# Last updated: 2026-05-14

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
  description = "ARM resource ID of the primary hub VNet (eastus2). Consumed by spoke peering in Section 9."
  value       = module.hub_and_spoke.virtual_network_resource_ids["primary"]
}

output "primary_hub_vnet_name" {
  description = "Name of the primary hub VNet."
  value       = module.hub_and_spoke.virtual_network_resource_names["primary"]
}

output "secondary_hub_vnet_id" {
  description = "ARM resource ID of the secondary (DR) hub VNet (centralus)."
  value       = module.hub_and_spoke.virtual_network_resource_ids["secondary"]
}

output "secondary_hub_vnet_name" {
  description = "Name of the secondary (DR) hub VNet."
  value       = module.hub_and_spoke.virtual_network_resource_names["secondary"]
}

output "primary_firewall_id" {
  description = "ARM resource ID of the primary Azure Firewall Premium."
  value       = module.hub_and_spoke.firewall_resource_ids["primary"]
}

output "primary_firewall_private_ip" {
  description = "Private IP address of the primary Azure Firewall. Used as next-hop in spoke UDRs."
  value       = module.hub_and_spoke.firewall_private_ip_addresses["primary"]
}

output "secondary_firewall_id" {
  description = "ARM resource ID of the secondary Azure Firewall Premium."
  value       = module.hub_and_spoke.firewall_resource_ids["secondary"]
}

output "secondary_firewall_private_ip" {
  description = "Private IP address of the secondary Azure Firewall. Used as next-hop in DR spoke UDRs."
  value       = module.hub_and_spoke.firewall_private_ip_addresses["secondary"]
}

output "primary_vpn_gateway_id" {
  description = "ARM resource ID of the primary hub VPN Gateway."
  # UNVERIFIED: exact nested key path within virtual_network_gateway_resource_ids["primary"].
  # Verify by running: terraform output -json primary_vpn_gateway_id after first apply.
  value = try(module.hub_and_spoke.virtual_network_gateway_resource_ids["primary"]["vpn"], null)
}

output "primary_dns_resolver_inbound_ips" {
  description = "IP address(es) of the primary hub DNS Private Resolver inbound endpoint. Configure as DNS server in spoke VNets."
  value       = module.hub_and_spoke.dns_resolver_inbound_endpoint_ip_addresses["primary"]
}
