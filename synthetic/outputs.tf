# Purpose: Outputs from the synthetic workload root module.
# Section: 13.1 — Workload Targets
# Last updated: 2026-06-02

output "enabled" {
  description = "Resolved value of the kill switch — true when synthetic resources are deployed, false when the entire layer is empty."
  value       = var.enable_synthetic_workload
}

# ---------------------------------------------------------------------------
# corp-a1
# ---------------------------------------------------------------------------

output "corp_a1_api_default_hostname" {
  description = "Default hostname of the corp-a1 App Service that hosts the REST API stub. Append /api/products, /api/login, /api/checkout to exercise the endpoints. Empty string when synthetic workload is disabled."
  value       = local.enabled == 1 ? data.azurerm_linux_web_app.corp_a1[0].default_hostname : ""
}

output "corp_a1_synthetic_storage_account_name" {
  description = "Name of the synthetic storage account holding the corp-a1 code artifact. Empty string when synthetic workload is disabled."
  value       = local.enabled == 1 ? azurerm_storage_account.corp_a1_synthetic[0].name : ""
}

output "corp_a1_synthetic_storage_account_id" {
  description = "ARM resource ID of the corp-a1 synthetic storage account. Empty string when synthetic workload is disabled."
  value       = local.enabled == 1 ? azurerm_storage_account.corp_a1_synthetic[0].id : ""
}

# ---------------------------------------------------------------------------
# online-p1
# ---------------------------------------------------------------------------

output "online_p1_contact_queue_name" {
  description = "Name of the Storage Queue receiving online-p1 contact-form submissions."
  value       = local.enabled == 1 ? azurerm_storage_queue.contact_form[0].name : ""
}

output "online_p1_contact_queue_url" {
  description = "Fully qualified URL of the contact-form Storage Queue. Use this as the destination for the Azure Function inside the Static Web App. Empty string when synthetic workload is disabled."
  value       = local.enabled == 1 ? "https://${azurerm_storage_account.online_p1_synthetic[0].name}.queue.core.windows.net/${azurerm_storage_queue.contact_form[0].name}" : ""
}

output "online_p1_synthetic_storage_account_name" {
  description = "Name of the synthetic storage account that hosts the contact-form queue. Empty string when synthetic workload is disabled."
  value       = local.enabled == 1 ? azurerm_storage_account.online_p1_synthetic[0].name : ""
}

# ---------------------------------------------------------------------------
# 13.2 — k6 load generator
# ---------------------------------------------------------------------------

output "k6_container_app_environment_id" {
  description = "ARM resource ID of the Container Apps Environment hosting the k6 jobs. Empty string when synthetic workload is disabled or when platform_law_workspace_id is unset."
  value       = local.k6_enabled == 1 ? azurerm_container_app_environment.k6[0].id : ""
}

output "k6_job_ids" {
  description = "Map of k6 scenario name (baseline / spike / anomalous) → Container Apps Job ARM resource ID. Empty map when synthetic workload is disabled."
  value       = local.k6_enabled == 1 ? { for k, v in azurerm_container_app_job.k6 : k => v.id } : {}
}

output "k6_job_names" {
  description = "Map of k6 scenario name → Container Apps Job resource name. Use these with `az containerapp job start --name <name>` to fire a scenario manually for demo. Empty map when synthetic workload is disabled."
  value       = local.k6_enabled == 1 ? { for k, v in azurerm_container_app_job.k6 : k => v.name } : {}
}

# ---------------------------------------------------------------------------
# 13.3 — Red-team simulator
# ---------------------------------------------------------------------------

output "red_team_primary_rg_name" {
  description = "Resource group name hosting the eastus2 red-team simulator resources (decoy SA, decoy KV, primary CAJs)."
  value       = local.red_team_enabled == 1 ? azurerm_resource_group.red_team_primary[0].name : ""
}

output "red_team_secondary_rg_name" {
  description = "Resource group name hosting the impossible-travel west-pole CAE. Empty when the sign-in scenarios are disabled (honeypot_user_principal_name not set)."
  value       = local.red_team_signin_enabled == 1 ? azurerm_resource_group.red_team_secondary[0].name : ""
}

output "red_team_decoy_storage_account_name" {
  description = "Decoy storage account that holds the mass-blob-download target. Tagged Purpose=SecuritySimulation."
  value       = local.red_team_enabled == 1 ? azurerm_storage_account.red_team_decoy[0].name : ""
}

output "red_team_decoy_key_vault_name" {
  description = "Decoy Key Vault probed by the kv_probing CAJ. RBAC mode; MI has only Key Vault Reader so GetSecret always fails."
  value       = local.red_team_enabled == 1 ? azurerm_key_vault.red_team_decoy[0].name : ""
}

output "red_team_job_names" {
  description = "Map of red-team scenario name → Container Apps Job resource name. Use these with `az containerapp job start --name <name>` to fire a scenario manually for demo. Empty map when synthetic workload is disabled."
  value       = local.red_team_enabled == 1 ? { for k, v in azurerm_container_app_job.red_team : k => v.name } : {}
}

output "red_team_job_principal_ids" {
  description = "Map of red-team scenario name → System-Assigned MI principal ID. Surfaces the identity each scenario runs as for RBAC audit purposes."
  value       = local.red_team_enabled == 1 ? { for k, v in azurerm_container_app_job.red_team : k => v.identity[0].principal_id } : {}
}

# ---------------------------------------------------------------------------
# 13.4 — Cost-generating patterns
# ---------------------------------------------------------------------------

output "cost_patterns_rg_name" {
  description = "Governed resource group holding the cost-pattern anti-patterns (VM, disk, hot SA, budget)."
  value       = local.cost_patterns_enabled == 1 ? azurerm_resource_group.cost_patterns[0].name : ""
}

output "ungoverned_rg_name" {
  description = "Intentionally untagged resource group. The §7 Modify policy at MG scope adds default FinOps tags out-of-band — the policy-evaluation entry in AzureActivity is the demo signal."
  value       = local.cost_patterns_enabled == 1 ? azurerm_resource_group.ungoverned[0].name : ""
}

output "oversized_vm_id" {
  description = "ARM resource ID of the oversized idle VM (Optimization=Candidate tag). Driver for Azure Advisor's right-size recommendation."
  value       = local.cost_patterns_enabled == 1 ? azurerm_linux_virtual_machine.oversized_idle[0].id : ""
}

output "oversized_vm_size" {
  description = "VM SKU actually deployed for the oversized-idle pattern. Echoes var.cost_pattern_vm_size."
  value       = local.cost_patterns_enabled == 1 ? azurerm_linux_virtual_machine.oversized_idle[0].size : ""
}

output "oversized_vm_ssh_private_key_pem" {
  description = "Ephemeral RSA private key for break-glass SSH access to the oversized idle VM. Sensitive — pull from state with `terraform output -raw oversized_vm_ssh_private_key_pem`."
  value       = local.cost_patterns_enabled == 1 ? tls_private_key.oversized_vm[0].private_key_pem : ""
  sensitive   = true
}

output "unattached_disk_id" {
  description = "ARM resource ID of the unattached 32 GB Premium SSD. Driver for Azure Advisor's delete-unattached-disk recommendation."
  value       = local.cost_patterns_enabled == 1 ? azurerm_managed_disk.unattached[0].id : ""
}

output "cost_pattern_hot_storage_account_name" {
  description = "Name of the Hot-tier storage account hosting the stale-blob anti-pattern. Driver for Azure Advisor's lifecycle-management recommendation once the 7-day no-access window elapses."
  value       = local.cost_patterns_enabled == 1 ? azurerm_storage_account.cost_pattern_hot[0].name : ""
}

output "cost_pattern_budget_id" {
  description = "ARM resource ID of the deliberately-low RG budget. Empty when var.cost_pattern_budget_alert_emails is unset (the budget resource requires at least one notification target)."
  value       = local.cost_patterns_enabled == 1 && length(var.cost_pattern_budget_alert_emails) > 0 ? azurerm_consumption_budget_resource_group.sandbox_overrun[0].id : ""
}
