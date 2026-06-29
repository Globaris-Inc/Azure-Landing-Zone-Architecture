# Purpose: Outputs for the Security platform root module.
# Section: 8 — Standard Platform Components / extended in Section 6
# Last updated: 2026-05-29

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
  value       = module.security_kv.name # avm-res-keyvault-vault exposes `name`, not `resource.name`
}

output "security_kv_uri" {
  description = "Vault URI of the security Key Vault. Used to construct Key Vault secret references."
  value       = module.security_kv.uri # avm-res-keyvault-vault exposes `uri`, not `resource.vault_uri`
}

# ---------------------------------------------------------------------------
# Section 6 — Defender for Cloud extension + MDC export
# ---------------------------------------------------------------------------

output "defender_extended_plan_ids" {
  description = "Map of additional Defender for Cloud plans enabled on the Security subscription (resource_type → ARM ID)."
  value       = { for k, v in azurerm_security_center_subscription_pricing.extended : k => v.id }
}

output "mdc_export_event_hub_namespace_id" {
  description = "ARM resource ID of the Event Hub namespace receiving Defender for Cloud continuous export. Null when export is disabled."
  value       = try(azurerm_eventhub_namespace.mdc_export[0].id, null)
}

output "mdc_export_event_hub_id" {
  description = "ARM resource ID of the Event Hub that MDC publishes alerts/recommendations to."
  value       = try(azurerm_eventhub.mdc_export[0].id, null)
}

output "mdc_export_event_hub_authorization_rule_id" {
  description = "ARM resource ID of the publisher authorization rule. Consume to retrieve the SAS connection string used by downstream SIEMs."
  value       = try(azurerm_eventhub_authorization_rule.mdc_export[0].id, null)
}

output "mdc_export_automation_id" {
  description = "ARM resource ID of the Defender for Cloud continuous-export automation resource."
  value       = try(azurerm_security_center_automation.mdc_export[0].id, null)
}

output "regulatory_compliance_assignment_ids" {
  description = "Map of regulatory compliance policy assignment ARM IDs keyed by framework slug (nist_sp_800_53_r5, cis_azure_2_0_0)."
  value       = { for k, v in azurerm_management_group_policy_assignment.regulatory_compliance : k => v.id }
}

# ---------------------------------------------------------------------------
# Section 6 — Sentinel
# ---------------------------------------------------------------------------

output "sentinel_data_connector_ids" {
  description = "Map of Sentinel data connector ARM IDs keyed by short name."
  value = {
    aad = azurerm_sentinel_data_connector_azure_active_directory.this.id
    mdc = azurerm_sentinel_data_connector_azure_security_center.this.id
    mde = azurerm_sentinel_data_connector_microsoft_defender_advanced_threat_protection.this.id
    ti  = azurerm_sentinel_data_connector_threat_intelligence.this.id
  }
}

output "sentinel_analytics_rule_ids" {
  description = "Map of scheduled analytics rule ARM IDs keyed by logical rule name."
  value       = { for k, v in azurerm_sentinel_alert_rule_scheduled.this : k => v.id }
}

output "sentinel_mdc_incident_rule_id" {
  description = "ARM resource ID of the Microsoft Security incident-creation rule for Defender for Cloud high-severity alerts."
  value       = azurerm_sentinel_alert_rule_ms_security_incident.mdc_high.id
}

output "sentinel_automation_rule_ids" {
  description = "Map of Sentinel automation rule ARM IDs (auto_assign and ti_enrichment_tag)."
  value = {
    auto_assign       = try(azurerm_sentinel_automation_rule.auto_assign[0].id, null)
    ti_enrichment_tag = azurerm_sentinel_automation_rule.ti_enrichment_tag.id
  }
}

output "sentinel_watchlist_ids" {
  description = "Map of Sentinel watchlist ARM IDs (vip_users, high_value_assets)."
  value = {
    vip_users         = try(azurerm_sentinel_watchlist.vip_users[0].id, null)
    high_value_assets = try(azurerm_sentinel_watchlist.high_value_assets[0].id, null)
  }
}

output "sentinel_workbook_ids" {
  description = "Map of Sentinel workbook ARM IDs keyed by short workbook name."
  value       = { for k, v in azurerm_application_insights_workbook.sentinel : k => v.id }
}

output "ueba_setting_id" {
  description = "ARM resource ID of the Microsoft Sentinel UEBA setting (azapi). Null when enable_ueba=false."
  value       = try(azapi_resource.ueba[0].id, null)
}

output "entity_analytics_setting_id" {
  description = "ARM resource ID of the Microsoft Sentinel Entity Analytics setting."
  value       = try(azapi_resource.entity_analytics[0].id, null)
}
