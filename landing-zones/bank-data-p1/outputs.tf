# Purpose: Outputs for the bank-data-p1 landing zone root module.
# Section: Banking wave B1 - banking network foundation (docs/banking-platform-design.md)
# Last updated: 2026-07-16

output "spoke_vnet_id" {
  description = "ARM resource ID of the bank-data-p1 spoke VNet."
  value       = module.spoke_vnet.resource_id
}

output "spoke_vnet_name" {
  description = "Name of the bank-data-p1 spoke VNet."
  value       = module.spoke_vnet.name
}

output "network_rg_name" {
  description = "Name of the bank-data-p1 network resource group."
  value       = azurerm_resource_group.network.name
}

output "shared_rg_name" {
  description = "Name of the bank-data-p1 shared resource group."
  value       = azurerm_resource_group.shared.name
}

output "workload_rg_name" {
  description = "Name of the bank-data-p1 workload resource group (Databricks/ADLS/AI tier, waves B5-B6)."
  value       = azurerm_resource_group.workload.name
}

output "monitoring_rg_name" {
  description = "Name of the bank-data-p1 monitoring resource group."
  value       = azurerm_resource_group.monitoring.name
}

output "databricks_host_subnet_id" {
  description = "ARM resource ID of the Databricks host (public) subnet, delegated to Microsoft.Databricks/workspaces. Consumed by the wave B5 workspace VNet injection."
  value       = module.spoke_vnet.subnets["databricks-host"].resource_id
}

output "databricks_container_subnet_id" {
  description = "ARM resource ID of the Databricks container (private) subnet, delegated to Microsoft.Databricks/workspaces. Consumed by the wave B5 workspace VNet injection."
  value       = module.spoke_vnet.subnets["databricks-container"].resource_id
}

output "databricks_nsg_id" {
  description = "ARM resource ID of the NSG attached to both Databricks subnets. The wave B5 workspace custom_parameters reference the subnet NSG associations; the service injects its managed rules into this NSG."
  value       = azurerm_network_security_group.databricks.id
}

output "private_endpoint_subnet_id" {
  description = "ARM resource ID of the private endpoints subnet."
  value       = module.spoke_vnet.subnets["private-endpoints"].resource_id
}

output "flow_log_storage_account_id" {
  description = "ARM resource ID of the VNet flow-log storage account."
  value       = azurerm_storage_account.flow_logs.id
}
