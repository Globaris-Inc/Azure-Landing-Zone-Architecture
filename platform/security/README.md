# platform/security

Security platform root. RBAC-isolated Security Log Analytics workspace, Microsoft
Sentinel, a Key Vault for security secrets, and Defender for Cloud plans. Deploys to
the Security subscription; the security workspace is intentionally isolated from the
platform LA workspace.

Sections 6 (Defender for Cloud + Sentinel) and 8 (Standard Platform Components).
Apply order: after platform/management, and after platform/connectivity if the
Firewall TLS cert is wired to this Key Vault.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.4.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.71.0 |
| <a name="requirement_modtm"></a> [modtm](#requirement\_modtm) | ~> 0.3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.8.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | 2.4.0 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.71.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.1 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_security_kv"></a> [security\_kv](#module\_security\_kv) | Azure/avm-res-keyvault-vault/azurerm | 0.10.2 |
| <a name="module_security_law"></a> [security\_law](#module\_security\_law) | Azure/avm-res-operationalinsights-workspace/azurerm | 0.5.1 |

## Resources

| Name | Type |
|------|------|
| [azapi_resource.entity_analytics](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource) | resource |
| [azapi_resource.ueba](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource) | resource |
| [azurerm_application_insights_workbook.sentinel](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights_workbook) | resource |
| [azurerm_eventhub.mdc_export](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventhub) | resource |
| [azurerm_eventhub_authorization_rule.mdc_export](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventhub_authorization_rule) | resource |
| [azurerm_eventhub_namespace.mdc_export](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventhub_namespace) | resource |
| [azurerm_management_group_policy_assignment.regulatory_compliance](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_group_policy_assignment) | resource |
| [azurerm_monitor_aad_diagnostic_setting.security_law](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_aad_diagnostic_setting) | resource |
| [azurerm_monitor_diagnostic_setting.security_sub_activity](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_resource_group.security](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_security_center_automation.mdc_export](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/security_center_automation) | resource |
| [azurerm_security_center_contact.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/security_center_contact) | resource |
| [azurerm_security_center_subscription_pricing.extended](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/security_center_subscription_pricing) | resource |
| [azurerm_security_center_subscription_pricing.servers](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/security_center_subscription_pricing) | resource |
| [azurerm_security_center_subscription_pricing.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/security_center_subscription_pricing) | resource |
| [azurerm_sentinel_alert_rule_ms_security_incident.mdc_high](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_alert_rule_ms_security_incident) | resource |
| [azurerm_sentinel_alert_rule_scheduled.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_alert_rule_scheduled) | resource |
| [azurerm_sentinel_automation_rule.auto_assign](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_automation_rule) | resource |
| [azurerm_sentinel_automation_rule.ti_enrichment_tag](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_automation_rule) | resource |
| [azurerm_sentinel_data_connector_azure_active_directory.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_data_connector_azure_active_directory) | resource |
| [azurerm_sentinel_data_connector_azure_security_center.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_data_connector_azure_security_center) | resource |
| [azurerm_sentinel_data_connector_microsoft_defender_advanced_threat_protection.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_data_connector_microsoft_defender_advanced_threat_protection) | resource |
| [azurerm_sentinel_data_connector_threat_intelligence.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_data_connector_threat_intelligence) | resource |
| [azurerm_sentinel_log_analytics_workspace_onboarding.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_log_analytics_workspace_onboarding) | resource |
| [azurerm_sentinel_watchlist.high_value_assets](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_watchlist) | resource |
| [azurerm_sentinel_watchlist.vip_users](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_watchlist) | resource |
| [azurerm_sentinel_watchlist_item.high_value_assets](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_watchlist_item) | resource |
| [azurerm_sentinel_watchlist_item.vip_users](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/sentinel_watchlist_item) | resource |
| [random_id.mdc_eh_namespace](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_id.security_kv](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_uuid.workbooks](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/uuid) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_org_prefix"></a> [org\_prefix](#input\_org\_prefix) | Short organisation identifier used in resource naming (e.g. 'globaris'). | `string` | n/a | yes |
| <a name="input_security_contact_email"></a> [security\_contact\_email](#input\_security\_contact\_email) | Email address for Defender for Cloud security alerts and recommendations. | `string` | n/a | yes |
| <a name="input_security_subscription_id"></a> [security\_subscription\_id](#input\_security\_subscription\_id) | Subscription ID for the Security platform subscription. | `string` | n/a | yes |
| <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id) | Azure Active Directory tenant ID. | `string` | n/a | yes |
| <a name="input_terraform_sp_object_id"></a> [terraform\_sp\_object\_id](#input\_terraform\_sp\_object\_id) | Object ID of the OIDC service principal running Terraform. Granted Key Vault Administrator on the security Key Vault. | `string` | n/a | yes |
| <a name="input_analytics_rule_lookback_minutes"></a> [analytics\_rule\_lookback\_minutes](#input\_analytics\_rule\_lookback\_minutes) | Default query lookback window for scheduled analytics rules, in minutes. Most POC rules run every 5-60 minutes; smaller windows reduce duplicate alerts. | `number` | `60` | no |
| <a name="input_analytics_rule_query_frequency_minutes"></a> [analytics\_rule\_query\_frequency\_minutes](#input\_analytics\_rule\_query\_frequency\_minutes) | Default frequency at which scheduled analytics rules execute their queries, in minutes. | `number` | `60` | no |
| <a name="input_enable_aad_connector"></a> [enable\_aad\_connector](#input\_enable\_aad\_connector) | If true, create the Microsoft Entra ID (Azure Active Directory) Sentinel data connector streaming SigninLogs/AuditLogs into the Security LA workspace. Requires the OIDC SP to hold the Security Administrator (or Global Administrator) Entra directory role, which it does not hold in the POC. Default false: the tenant-scoped connector PUT returns 401 Access denied without that role. Same permission class as enable\_aad\_diagnostics and enable\_ueba. Re-enable once the role is granted. | `bool` | `false` | no |
| <a name="input_enable_aad_diagnostics"></a> [enable\_aad\_diagnostics](#input\_enable\_aad\_diagnostics) | If true, send Entra ID Sign-in/Audit/RiskyUser/UserRiskEvent/Provisioning logs to the Security LA workspace via azurerm\_monitor\_aad\_diagnostic\_setting. Requires the OIDC SP to hold Security Reader (or higher) at the tenant root. | `bool` | `true` | no |
| <a name="input_enable_firewall_ti_rule"></a> [enable\_firewall\_ti\_rule](#input\_enable\_firewall\_ti\_rule) | If true, create the firewall\_threat\_intel\_hit scheduled analytics rule. Default false: it is the only cross-workspace rule and its name-only workspace('law-platform-...') reference does not resolve cross-subscription at rule-create time (400 Could not locate all the workspaces). Re-enable needs a fully-qualified platform LAW reference plus cross-workspace RBAC - see OQ-027. | `bool` | `false` | no |
| <a name="input_enable_mdc_event_hub_export"></a> [enable\_mdc\_event\_hub\_export](#input\_enable\_mdc\_event\_hub\_export) | If true, deploy an Event Hub namespace + hub in the Security RG and configure a Defender for Cloud continuous export of alerts/recommendations/assessments to both the Security LA workspace and the Event Hub for SIEM ingestion. | `bool` | `true` | no |
| <a name="input_enable_mde_connector"></a> [enable\_mde\_connector](#input\_enable\_mde\_connector) | If true, create the Microsoft Defender for Endpoint (MDATP) Sentinel data connector. Requires a Microsoft Defender for Endpoint tenant license plus Security Administrator consent. Default false: this tenant lacks the MDE license, so the connector create would fail. Left pre-staged for a later enablement pass. | `bool` | `false` | no |
| <a name="input_enable_regulatory_compliance"></a> [enable\_regulatory\_compliance](#input\_enable\_regulatory\_compliance) | If true, assign the NIST SP 800-53 R5 and CIS Azure Foundations 2.0 built-in policy initiatives at the root management group scope. Disable to skip during initial bootstrap if the OIDC SP lacks Policy Contributor at the MG scope. | `bool` | `true` | no |
| <a name="input_enable_subscription_activity_log"></a> [enable\_subscription\_activity\_log](#input\_enable\_subscription\_activity\_log) | If true, create a diagnostic setting on the Security subscription that streams Activity Log (Administrative, Security, Alert, Policy) to the Security LA workspace. Other subscriptions' activity logs are covered by the per-subscription Azure Activity Sentinel data connector. | `bool` | `true` | no |
| <a name="input_enable_ti_connector"></a> [enable\_ti\_connector](#input\_enable\_ti\_connector) | If true, create the Microsoft Threat Intelligence Sentinel data connector ingesting the ThreatIntelligenceIndicator feed into the Security LA workspace. Requires the OIDC SP to hold the Security Administrator (or Global Administrator) Entra directory role, which it does not hold in the POC. Default false: the tenant-scoped connector PUT returns 401 Access denied without that role. Re-enable once the role is granted. | `bool` | `false` | no |
| <a name="input_enable_ueba"></a> [enable\_ueba](#input\_enable\_ueba) | If true, enable Microsoft Sentinel UEBA (User and Entity Behaviour Analytics) and Entity Analytics with AuditLogs, AzureActivity, and SigninLogs as data sources. Requires Sentinel onboarding to be complete. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment label used in resource names and tags (e.g. 'poc'). | `string` | `"poc"` | no |
| <a name="input_event_hub_namespace_capacity"></a> [event\_hub\_namespace\_capacity](#input\_event\_hub\_namespace\_capacity) | Throughput units (1-20) for the MDC export Event Hub Namespace. 1 unit = 1 MB/s ingress + 2 MB/s egress (~2.5 GB/day at saturation). | `number` | `1` | no |
| <a name="input_high_value_asset_resource_ids"></a> [high\_value\_asset\_resource\_ids](#input\_high\_value\_asset\_resource\_ids) | List of Azure resource IDs flagged as high-value assets (e.g., production SQL, Key Vault). Materialised into the 'HighValueAssets' Sentinel watchlist. | `list(string)` | `[]` | no |
| <a name="input_primary_location"></a> [primary\_location](#input\_primary\_location) | Primary Azure region for security resources. | `string` | `"eastus2"` | no |
| <a name="input_root_management_group_id"></a> [root\_management\_group\_id](#input\_root\_management\_group\_id) | Full ARM resource ID of the Globaris root management group. Used as the scope for regulatory compliance policy assignments (NIST SP 800-53 R5, CIS Azure Foundations 2.0). | `string` | `"/providers/Microsoft.Management/managementGroups/globaris"` | no |
| <a name="input_security_law_retention_days"></a> [security\_law\_retention\_days](#input\_security\_law\_retention\_days) | Log Analytics workspace data retention period in days (30-730) for the RBAC-isolated Security workspace. | `number` | `90` | no |
| <a name="input_sentinel_owner_group_object_id"></a> [sentinel\_owner\_group\_object\_id](#input\_sentinel\_owner\_group\_object\_id) | Entra ID group object ID that becomes the default owner for newly-created Sentinel incidents via an automation rule. Leave empty to skip the auto-assign automation rule. | `string` | `""` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags merged into all resources created by this module. | `map(string)` | `{}` | no |
| <a name="input_vip_user_object_ids"></a> [vip\_user\_object\_ids](#input\_vip\_user\_object\_ids) | List of Entra ID user object IDs flagged as VIPs. Materialised into the 'VIPUsers' Sentinel watchlist; analytics rules can join SigninLogs against this list to elevate severity on VIP sign-in anomalies. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_defender_extended_plan_ids"></a> [defender\_extended\_plan\_ids](#output\_defender\_extended\_plan\_ids) | Map of additional Defender for Cloud plans enabled on the Security subscription (resource\_type → ARM ID). |
| <a name="output_entity_analytics_setting_id"></a> [entity\_analytics\_setting\_id](#output\_entity\_analytics\_setting\_id) | ARM resource ID of the Microsoft Sentinel Entity Analytics setting. |
| <a name="output_mdc_export_automation_id"></a> [mdc\_export\_automation\_id](#output\_mdc\_export\_automation\_id) | ARM resource ID of the Defender for Cloud continuous-export automation resource. |
| <a name="output_mdc_export_event_hub_authorization_rule_id"></a> [mdc\_export\_event\_hub\_authorization\_rule\_id](#output\_mdc\_export\_event\_hub\_authorization\_rule\_id) | ARM resource ID of the publisher authorization rule. Consume to retrieve the SAS connection string used by downstream SIEMs. |
| <a name="output_mdc_export_event_hub_id"></a> [mdc\_export\_event\_hub\_id](#output\_mdc\_export\_event\_hub\_id) | ARM resource ID of the Event Hub that MDC publishes alerts/recommendations to. |
| <a name="output_mdc_export_event_hub_namespace_id"></a> [mdc\_export\_event\_hub\_namespace\_id](#output\_mdc\_export\_event\_hub\_namespace\_id) | ARM resource ID of the Event Hub namespace receiving Defender for Cloud continuous export. Null when export is disabled. |
| <a name="output_regulatory_compliance_assignment_ids"></a> [regulatory\_compliance\_assignment\_ids](#output\_regulatory\_compliance\_assignment\_ids) | Map of regulatory compliance policy assignment ARM IDs keyed by framework slug (nist\_sp\_800\_53\_r5, cis\_azure\_2\_0\_0). |
| <a name="output_security_kv_id"></a> [security\_kv\_id](#output\_security\_kv\_id) | ARM resource ID of the security Key Vault. Wire into Firewall Policy tls\_certificate after uploading the self-signed CA cert. |
| <a name="output_security_kv_name"></a> [security\_kv\_name](#output\_security\_kv\_name) | Name of the security Key Vault. |
| <a name="output_security_kv_uri"></a> [security\_kv\_uri](#output\_security\_kv\_uri) | Vault URI of the security Key Vault. Used to construct Key Vault secret references. |
| <a name="output_security_law_customer_id"></a> [security\_law\_customer\_id](#output\_security\_law\_customer\_id) | Workspace GUID (customer\_id) of the Security Log Analytics workspace. Required for Sentinel data connector configuration. |
| <a name="output_security_law_workspace_id"></a> [security\_law\_workspace\_id](#output\_security\_law\_workspace\_id) | ARM resource ID of the Security (Sentinel) Log Analytics workspace. |
| <a name="output_security_law_workspace_name"></a> [security\_law\_workspace\_name](#output\_security\_law\_workspace\_name) | Name of the Security Log Analytics workspace. |
| <a name="output_security_rg_id"></a> [security\_rg\_id](#output\_security\_rg\_id) | ARM resource ID of the security resource group. |
| <a name="output_security_rg_name"></a> [security\_rg\_name](#output\_security\_rg\_name) | Name of the security resource group. |
| <a name="output_sentinel_analytics_rule_ids"></a> [sentinel\_analytics\_rule\_ids](#output\_sentinel\_analytics\_rule\_ids) | Map of scheduled analytics rule ARM IDs keyed by logical rule name. |
| <a name="output_sentinel_automation_rule_ids"></a> [sentinel\_automation\_rule\_ids](#output\_sentinel\_automation\_rule\_ids) | Map of Sentinel automation rule ARM IDs (auto\_assign and ti\_enrichment\_tag). |
| <a name="output_sentinel_data_connector_ids"></a> [sentinel\_data\_connector\_ids](#output\_sentinel\_data\_connector\_ids) | Map of Sentinel data connector ARM IDs keyed by short name. |
| <a name="output_sentinel_mdc_incident_rule_id"></a> [sentinel\_mdc\_incident\_rule\_id](#output\_sentinel\_mdc\_incident\_rule\_id) | ARM resource ID of the Microsoft Security incident-creation rule for Defender for Cloud high-severity alerts. |
| <a name="output_sentinel_watchlist_ids"></a> [sentinel\_watchlist\_ids](#output\_sentinel\_watchlist\_ids) | Map of Sentinel watchlist ARM IDs (vip\_users, high\_value\_assets). |
| <a name="output_sentinel_workbook_ids"></a> [sentinel\_workbook\_ids](#output\_sentinel\_workbook\_ids) | Map of Sentinel workbook ARM IDs keyed by short workbook name. |
| <a name="output_sentinel_workspace_id"></a> [sentinel\_workspace\_id](#output\_sentinel\_workspace\_id) | ARM resource ID of the Log Analytics workspace with Sentinel onboarded. |
| <a name="output_ueba_setting_id"></a> [ueba\_setting\_id](#output\_ueba\_setting\_id) | ARM resource ID of the Microsoft Sentinel UEBA setting (azapi). Null when enable\_ueba=false. |
<!-- END_TF_DOCS -->
