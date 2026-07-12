# Purpose: Outputs for the online-p1 landing zone root module.
# Section: 9 - Landing Zone Spokes
# Last updated: 2026-05-14

output "spoke_vnet_id" {
  description = "ARM resource ID of the online-p1 spoke VNet. Referenced by Section 4 Private DNS zone links."
  value       = module.spoke_vnet.resource_id
}

output "spoke_vnet_name" {
  description = "Name of the online-p1 spoke VNet."
  value       = module.spoke_vnet.name
}

output "network_rg_name" {
  description = "Name of the online-p1 network resource group."
  value       = azurerm_resource_group.network.name
}

output "shared_rg_name" {
  description = "Name of the online-p1 shared resource group."
  value       = azurerm_resource_group.shared.name
}

output "workload_rg_name" {
  description = "Name of the online-p1 workload resource group."
  value       = azurerm_resource_group.workload.name
}

output "monitoring_rg_name" {
  description = "Name of the online-p1 monitoring resource group."
  value       = azurerm_resource_group.monitoring.name
}

output "appgw_public_ip" {
  description = "Public IP address of the Application Gateway WAF_v2 frontend. Use this to test the online-p1 workload."
  value       = azurerm_public_ip.appgw.ip_address
}

output "appgw_id" {
  description = "ARM resource ID of the Application Gateway."
  value       = azurerm_application_gateway.this.id
}

output "waf_policy_id" {
  description = "ARM resource ID of the WAF policy associated with the Application Gateway."
  value       = azurerm_web_application_firewall_policy.this.id
}

output "static_web_app_default_hostname" {
  description = "Default hostname of the Static Web App (*.azurestaticapps.net). Used as the App Gateway backend FQDN."
  value       = azurerm_static_web_app.this.default_host_name
}

output "static_web_app_id" {
  description = "ARM resource ID of the Azure Static Web App."
  value       = azurerm_static_web_app.this.id
}

output "static_web_app_api_key" {
  description = "Deployment API key for the Static Web App. Store in the Security Key Vault after initial apply."
  value       = azurerm_static_web_app.this.api_key
  sensitive   = true
}

output "appgw_subnet_id" {
  description = "ARM resource ID of the Application Gateway subnet."
  value       = module.spoke_vnet.subnets["appgateway"].resource_id
}

output "private_endpoint_subnet_id" {
  description = "ARM resource ID of the private endpoints subnet."
  value       = module.spoke_vnet.subnets["private-endpoints"].resource_id
}
