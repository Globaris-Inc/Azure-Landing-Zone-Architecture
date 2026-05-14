# Purpose: Outputs for the Security platform root module.
# Section: 8 — Standard Platform Components
# Last updated: 2026-05-14

output "security_rg_name" {
  description = "Name of the security resource group."
  value       = azurerm_resource_group.security.name
}

output "security_rg_id" {
  description = "ARM resource ID of the security resource group."
  value       = azurerm_resource_group.security.id
}

output "security_law_workspace_id" {
  description = "ARM resource ID of the Security (Sentinel) Log Analytics workspace."
  value       = module.security_law.resource_id
}

output "security_law_workspace_name" {
  description = "Name of the Security Log Analytics workspace."
  value       = module.security_law.resource.name
}

output "security_law_customer_id" {
  description = "Workspace GUID (customer_id) of the Security Log Analytics workspace. Required for Sentinel data connector configuration."
  value       = module.security_law.resource.workspace_id
}

output "sentinel_workspace_id" {
  description = "ARM resource ID of the Log Analytics workspace with Sentinel onboarded."
  value       = azurerm_sentinel_log_analytics_workspace_onboarding.this.workspace_id
}

output "security_kv_id" {
  description = "ARM resource ID of the security Key Vault. Wire into Firewall Policy tls_certificate after uploading the self-signed CA cert."
  value       = module.security_kv.resource_id
}

output "security_kv_name" {
  description = "Name of the security Key Vault."
  value       = module.security_kv.resource.name
}

output "security_kv_uri" {
  description = "Vault URI of the security Key Vault. Used to construct Key Vault secret references."
  value       = module.security_kv.resource.vault_uri
}
