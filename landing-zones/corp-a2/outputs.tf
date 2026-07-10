# Purpose: Outputs for the corp-a2 landing zone root module (DR spoke).
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-07-10

output "spoke_vnet_id" {
  description = "ARM resource ID of the corp-a2 spoke VNet (centralus DR). Referenced by Section 4 Private DNS zone links."
  value       = module.spoke_vnet.resource_id
}

output "spoke_vnet_name" {
  description = "Name of the corp-a2 spoke VNet."
  value       = module.spoke_vnet.name
}

output "network_rg_name" {
  description = "Name of the corp-a2 network resource group."
  value       = azurerm_resource_group.network.name
}

output "shared_rg_name" {
  description = "Name of the corp-a2 shared resource group."
  value       = azurerm_resource_group.shared.name
}

output "workload_rg_name" {
  description = "Name of the corp-a2 workload resource group."
  value       = azurerm_resource_group.workload.name
}

output "monitoring_rg_name" {
  description = "Name of the corp-a2 monitoring resource group."
  value       = azurerm_resource_group.monitoring.name
}

output "app_service_default_hostname" {
  description = "Default hostname of the corp-a2 (DR) App Service."
  value       = module.app_service.resource_uri
}

output "app_service_id" {
  description = "ARM resource ID of the corp-a2 App Service."
  value       = module.app_service.resource_id
  sensitive   = true
}

output "sql_server_fqdn" {
  description = "Fully qualified domain name of the corp-a2 SQL logical server."
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "sql_server_id" {
  description = "ARM resource ID of the corp-a2 SQL logical server. Referenced when configuring geo-replication from corp-a1."
  value       = azurerm_mssql_server.this.id
}

output "sql_database_id" {
  description = "ARM resource ID of the corp-a2 application SQL database."
  value       = azurerm_mssql_database.app.id
}

output "sql_private_endpoint_id" {
  description = "ARM resource ID of the SQL Private Endpoint."
  value       = azurerm_private_endpoint.sql.id
}

output "recovery_services_vault_id" {
  description = "ARM resource ID of the Recovery Services Vault. Used for ASR replication enrollment in Section 13."
  value       = module.recovery_services_vault.resource_id
}

output "recovery_services_vault_name" {
  description = "Name of the Recovery Services Vault."
  value       = module.recovery_services_vault.resource.name
}

output "private_endpoint_subnet_id" {
  description = "ARM resource ID of the private endpoints subnet."
  value       = module.spoke_vnet.subnets["private-endpoints"].resource_id
}
