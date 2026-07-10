# Purpose: Outputs for the corp-a1 landing zone root module.
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-07-10

output "spoke_vnet_id" {
  description = "ARM resource ID of the corp-a1 spoke VNet. Referenced by Section 4 (Private DNS zone links) and Section 3 (DR topology)."
  value       = module.spoke_vnet.resource_id
}

output "spoke_vnet_name" {
  description = "Name of the corp-a1 spoke VNet."
  value       = module.spoke_vnet.name
}

output "network_rg_name" {
  description = "Name of the corp-a1 network resource group."
  value       = azurerm_resource_group.network.name
}

output "shared_rg_name" {
  description = "Name of the corp-a1 shared resource group."
  value       = azurerm_resource_group.shared.name
}

output "workload_rg_name" {
  description = "Name of the corp-a1 workload resource group."
  value       = azurerm_resource_group.workload.name
}

output "monitoring_rg_name" {
  description = "Name of the corp-a1 monitoring resource group."
  value       = azurerm_resource_group.monitoring.name
}

output "app_service_default_hostname" {
  description = "Default hostname of the corp-a1 App Service. Used as App Gateway backend target in online-p1 and for smoke-test validation."
  value       = module.app_service.resource_uri
}

output "app_service_id" {
  description = "ARM resource ID of the corp-a1 App Service."
  value       = module.app_service.resource_id
  sensitive   = true
}

output "sql_server_fqdn" {
  description = "Fully qualified domain name of the corp-a1 SQL logical server (resolves via Private Endpoint after Section 4). Null when the SQL tier is gated off (var.enable_sql = false)."
  value       = one(azurerm_mssql_server.this[*].fully_qualified_domain_name)
}

output "sql_server_id" {
  description = "ARM resource ID of the corp-a1 SQL logical server. Null when the SQL tier is gated off (var.enable_sql = false)."
  value       = one(azurerm_mssql_server.this[*].id)
}

output "sql_database_id" {
  description = "ARM resource ID of the corp-a1 application SQL database. Null when the SQL tier is gated off (var.enable_sql = false)."
  value       = one(azurerm_mssql_database.app[*].id)
}

output "sql_private_endpoint_id" {
  description = "ARM resource ID of the SQL Private Endpoint. Referenced by Section 4 to add the DNS zone group. Null when the SQL tier is gated off (var.enable_sql = false)."
  value       = one(azurerm_private_endpoint.sql[*].id)
}

output "sql_private_endpoint_nic_ip" {
  description = "Private IP address allocated to the SQL Private Endpoint NIC. Null when the SQL tier is gated off (var.enable_sql = false)."
  value       = one(azurerm_private_endpoint.sql[*].private_service_connection[0].private_ip_address)
}

output "recovery_services_vault_id" {
  description = "ARM resource ID of the Recovery Services Vault. Used for ASR replication enrollment in Section 13."
  value       = module.recovery_services_vault.resource_id
}

output "recovery_services_vault_name" {
  description = "Name of the Recovery Services Vault."
  value       = module.recovery_services_vault.resource.name
}

output "integration_subnet_id" {
  description = "ARM resource ID of the App Service VNet integration subnet."
  value       = module.spoke_vnet.subnets["integration"].resource_id
}

output "private_endpoint_subnet_id" {
  description = "ARM resource ID of the private endpoints subnet."
  value       = module.spoke_vnet.subnets["private-endpoints"].resource_id
}
