# Purpose: Outputs for the bank-app-p1 landing zone root module.
# Section: Banking wave B1 - banking network foundation (docs/banking-platform-design.md)
# Last updated: 2026-07-16

output "spoke_vnet_id" {
  description = "ARM resource ID of the bank-app-p1 spoke VNet."
  value       = module.spoke_vnet.resource_id
}

output "spoke_vnet_name" {
  description = "Name of the bank-app-p1 spoke VNet."
  value       = module.spoke_vnet.name
}

output "network_rg_name" {
  description = "Name of the bank-app-p1 network resource group."
  value       = azurerm_resource_group.network.name
}

output "shared_rg_name" {
  description = "Name of the bank-app-p1 shared resource group."
  value       = azurerm_resource_group.shared.name
}

output "workload_rg_name" {
  description = "Name of the bank-app-p1 workload resource group (AKS/ACR/integration tier, waves B2-B4)."
  value       = azurerm_resource_group.workload.name
}

output "monitoring_rg_name" {
  description = "Name of the bank-app-p1 monitoring resource group."
  value       = azurerm_resource_group.monitoring.name
}

output "aks_nodes_subnet_id" {
  description = "ARM resource ID of the AKS node-pool subnet (consumed by the wave B2 AKS cluster)."
  value       = module.spoke_vnet.subnets["aks-nodes"].resource_id
}

output "apim_subnet_id" {
  description = "ARM resource ID of the APIM subnet (consumed by the wave B4 APIM internal VNet injection)."
  value       = module.spoke_vnet.subnets["apim"].resource_id
}

output "private_endpoint_subnet_id" {
  description = "ARM resource ID of the private endpoints subnet."
  value       = module.spoke_vnet.subnets["private-endpoints"].resource_id
}

output "flow_log_storage_account_id" {
  description = "ARM resource ID of the VNet flow-log storage account."
  value       = azurerm_storage_account.flow_logs.id
}
