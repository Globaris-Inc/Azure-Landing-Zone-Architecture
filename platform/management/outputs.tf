# Purpose: Outputs for the Management platform root module.
# Section: 7 — FinOps: Tagging & Budgets
# Last updated: 2026-07-08

output "resource_group_name" {
  description = "Name of the FinOps resource group in the management subscription."
  value       = azurerm_resource_group.finops.name
}

output "resource_group_id" {
  description = "ARM resource ID of the FinOps resource group."
  value       = azurerm_resource_group.finops.id
}

output "cost_export_storage_account_name" {
  description = "Name of the storage account that receives daily cost exports from all subscriptions."
  value       = azurerm_storage_account.cost_exports.name
}

output "cost_export_storage_account_id" {
  description = "ARM resource ID of the cost export storage account."
  value       = azurerm_storage_account.cost_exports.id
}

output "tag_governance_initiative_id" {
  description = "ARM resource ID of the custom tag governance policy set definition."
  value       = azurerm_policy_set_definition.tag_governance.id
}

output "tag_governance_assignment_id" {
  description = "ARM resource ID of the tag governance policy assignment at the Globaris root MG."
  value       = azurerm_management_group_policy_assignment.tag_governance.id
}

output "tag_policy_remediation_principal_id" {
  description = "Object ID of the system-assigned managed identity on the tag governance policy assignment. Used for remediation tasks."
  value       = azurerm_management_group_policy_assignment.tag_governance.identity[0].principal_id
}

output "subscription_budget_ids" {
  description = "Map of subscription budget ARM resource IDs keyed by logical subscription name."
  value       = { for k, v in module.finops : k => v.budget_id }
}

output "mg_budget_ids" {
  description = "Map of management group budget ARM resource IDs keyed by MG name (globaris, platform, landingzones)."
  value       = { for k, v in azurerm_consumption_budget_management_group.this : k => v.id }
}

output "cost_anomaly_alert_id" {
  description = "ARM resource ID of the cost anomaly alert on the management subscription."
  value       = azurerm_cost_anomaly_alert.management.id
}

output "carbon_optimization_workbook_id" {
  description = "ARM resource ID of the Carbon Optimization Azure Monitor workbook."
  value       = azurerm_application_insights_workbook.carbon_optimization.id
}

# ---------------------------------------------------------------------------
# Section 8 — Management sub monitoring outputs
# ---------------------------------------------------------------------------

output "platform_management_rg_name" {
  description = "Name of the management platform resource group (holds LA workspace, Automation Account, etc.)."
  value       = azurerm_resource_group.management.name
}

output "platform_management_rg_id" {
  description = "ARM resource ID of the management platform resource group."
  value       = azurerm_resource_group.management.id
}

output "platform_law_workspace_id" {
  description = "ARM resource ID of the platform Log Analytics workspace. Used by Sentinel (Section 8 Batch 3) and Defender (Section 6)."
  value       = module.platform_law.resource_id
}

output "platform_law_workspace_name" {
  description = "Name of the platform Log Analytics workspace."
  # nonsensitive() is safe: sensitivity is inherited from the AVM module's whole-object
  # `resource` output (sensitive because it contains the workspace shared keys). The name
  # attribute itself is not sensitive in the azurerm schema and is already exposed
  # non-sensitively as the last segment of platform_law_workspace_id.
  value = nonsensitive(module.platform_law.resource.name)
}

output "platform_law_customer_id" {
  description = "Workspace GUID (customer_id) of the platform Log Analytics workspace. Required for Sentinel onboarding. Marked sensitive (inherited from the AVM resource object); retrieve with `terraform output -raw platform_law_customer_id`."
  value       = module.platform_law.resource.workspace_id
  sensitive   = true
}

output "automation_account_id" {
  description = "ARM resource ID of the platform Automation Account."
  value       = azurerm_automation_account.platform.id
}

output "automation_account_name" {
  description = "Name of the platform Automation Account."
  value       = azurerm_automation_account.platform.name
}

output "automation_account_principal_id" {
  description = "Object ID of the system-assigned managed identity on the Automation Account."
  value       = azurerm_automation_account.platform.identity[0].principal_id
}

output "platform_action_group_id" {
  description = "ARM resource ID of the platform Monitor Action Group."
  value       = azurerm_monitor_action_group.platform.id
}

output "platform_action_group_name" {
  description = "Name of the platform Monitor Action Group."
  value       = azurerm_monitor_action_group.platform.name
}

output "platform_overview_workbook_id" {
  description = "ARM resource ID of the Platform Overview Azure Monitor workbook."
  value       = azurerm_application_insights_workbook.platform_overview.id
}

output "platform_dashboard_id" {
  description = "ARM resource ID of the shared platform portal dashboard."
  value       = azurerm_portal_dashboard.platform.id
}
