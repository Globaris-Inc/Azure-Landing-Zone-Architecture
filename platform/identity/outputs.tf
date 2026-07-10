# Purpose: Outputs for the identity / Zero Trust root module.
# Section: 5 — Zero Trust + Conditional Access
# Last updated: 2026-05-26

output "named_location_approved_countries_id" {
  description = "Object ID of the approved-countries named location used by the geo-block CA policy."
  value       = azuread_named_location.approved_countries.id
}

output "ca_policy_ids" {
  description = "Map of Conditional Access policy display-name slug → object ID."
  value = {
    require_mfa_admins         = azuread_conditional_access_policy.require_mfa_admins.id
    block_legacy_auth          = azuread_conditional_access_policy.block_legacy_auth.id
    require_compliant_device   = azuread_conditional_access_policy.require_compliant_device_portal.id
    phishing_resistant_mfa_pim = azuread_conditional_access_policy.phishing_resistant_mfa_pim.id
    geo_block                  = one(azuread_conditional_access_policy.geo_block[*].id) # null when var.enable_geo_block_ca_policy = false (ADR-029)
    signin_frequency_admins    = azuread_conditional_access_policy.signin_frequency_admins.id
    block_high_user_risk       = azuread_conditional_access_policy.block_high_user_risk.id
    mfa_signin_risk            = azuread_conditional_access_policy.mfa_signin_risk.id
  }
}

output "pim_eligible_assignment_ids" {
  description = "Map of PIM eligible assignment key → resource ID. Empty map when pim_privileged_group_object_id is not set."
  value       = { for k, v in azurerm_pim_eligible_role_assignment.this : k => v.id }
}

# ---------------------------------------------------------------------------
# Identity subscription domain-services infrastructure (G1 / Wave 3 / ADR-010)
# All null when identity_mode = "none" (resources not created).
# ---------------------------------------------------------------------------

output "identity_vnet_id" {
  description = "ARM resource ID of the identity VNet. Null when identity_mode = 'none'."
  value       = local.identity_enabled ? module.identity_vnet[0].resource_id : null
}

output "identity_aadds_subnet_id" {
  description = "ARM resource ID of the Entra DS subnet. Null when identity_mode = 'none'."
  value       = local.identity_enabled ? module.identity_vnet[0].subnets["entra-ds"].resource_id : null
}

output "entra_domain_service_id" {
  description = "ARM resource ID of the Microsoft Entra Domain Services managed domain. Null unless identity_mode = 'entra-ds'."
  value       = local.entra_ds_enabled ? azurerm_active_directory_domain_service.this[0].id : null
}

output "identity_recovery_services_vault_id" {
  description = "ARM resource ID of the identity Recovery Services Vault. Null when identity_mode = 'none'."
  value       = local.identity_enabled ? module.identity_recovery_services_vault[0].resource_id : null
}
