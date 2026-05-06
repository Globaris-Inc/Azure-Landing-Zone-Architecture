# Purpose: Outputs from the bootstrap layer — paste these into envs/poc.backend.hcl
#          and the GitHub repository variables after running terraform apply.
# Section: 10a — Pipeline & Tooling (bootstrap subset)
# Last updated: 2026-05-05

# ---------------------------------------------------------------------------
# State backend — paste into envs/poc.backend.hcl
# ---------------------------------------------------------------------------

output "resource_group_name" {
  description = "Name of the resource group hosting the Terraform state backend. Paste into envs/poc.backend.hcl as resource_group_name."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "Name of the Terraform state Storage Account. Paste into envs/poc.backend.hcl as storage_account_name."
  value       = azurerm_storage_account.tfstate.name
}

output "storage_container_name" {
  description = "Name of the Terraform state container (always 'tfstate'). Paste into envs/poc.backend.hcl as container_name."
  value       = azurerm_storage_container.tfstate.name
}

output "key_vault_name" {
  description = "Name of the bootstrap Key Vault holding the state SA CMK. Reference in Section 8 when wiring diagnostic settings."
  value       = azurerm_key_vault.tfstate.name
}

output "key_vault_id" {
  description = "Resource ID of the bootstrap Key Vault. Used by azurerm_storage_account_customer_managed_key in other modules if needed."
  value       = azurerm_key_vault.tfstate.id
}

# ---------------------------------------------------------------------------
# OIDC / GitHub Actions — set these as GitHub repository variables (not secrets)
# ---------------------------------------------------------------------------

output "oidc_client_id" {
  description = "Application (client) ID of the OIDC app registration. Set as GitHub repository variable AZURE_CLIENT_ID."
  value       = azuread_application.oidc.client_id
}

output "oidc_tenant_id" {
  description = "Azure AD tenant ID. Set as GitHub repository variable AZURE_TENANT_ID."
  value       = var.tenant_id
}

output "oidc_sp_object_id" {
  description = "Object ID of the OIDC service principal. Useful for auditing role assignments."
  value       = azuread_service_principal.oidc.object_id
}

output "management_subscription_id" {
  description = "Management subscription ID. Set as GitHub repository variable AZURE_SUBSCRIPTION_ID (default subscription for plan/apply workflows)."
  value       = var.management_subscription_id
}
