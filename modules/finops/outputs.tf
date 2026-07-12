# Purpose: Outputs for the reusable FinOps child module.
# Section: 7 - FinOps: Tagging & Budgets
# Last updated: 2026-07-08

output "budget_id" {
  description = "ARM resource ID of the subscription consumption budget."
  value       = azurerm_consumption_budget_subscription.this.id
}

output "export_ids" {
  description = "Map of cost export ARM resource IDs. Key is 'export' when enabled, empty map when disabled."
  value       = { for k, v in azapi_resource.cost_export : k => v.id }
}

output "vm_shutdown_schedule_ids" {
  description = "Map of VM auto-shutdown schedule resource IDs keyed by logical VM name."
  value       = { for k, v in azurerm_dev_test_global_vm_shutdown_schedule.this : k => v.id }
}
