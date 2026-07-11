# platform/management

Management platform root. FinOps governance for the estate - tag policy, budgets,
daily cost exports, anomaly alerts, and the Carbon Optimization workbook. Deploys to
the Management subscription (primary) plus cross-subscription budget/export resources
for all 5 subscriptions via explicit subscription_id params. Consumes the reusable
`modules/finops` child module.

Section 7 (FinOps: Tagging & Budgets). Apply order: depends on
platform/management-groups (policy assignments scope to MGs). See ADR-027 for the
azapi cost-export deviation.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.5 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.71.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.8.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.71.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.1 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_finops"></a> [finops](#module\_finops) | ../../modules/finops | n/a |
| <a name="module_platform_law"></a> [platform\_law](#module\_platform\_law) | Azure/avm-res-operationalinsights-workspace/azurerm | 0.5.1 |

## Resources

| Name | Type |
|------|------|
| [azurerm_application_insights_workbook.carbon_optimization](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights_workbook) | resource |
| [azurerm_application_insights_workbook.platform_overview](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights_workbook) | resource |
| [azurerm_automation_account.platform](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/automation_account) | resource |
| [azurerm_consumption_budget_management_group.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/consumption_budget_management_group) | resource |
| [azurerm_cost_anomaly_alert.management](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cost_anomaly_alert) | resource |
| [azurerm_management_group_policy_assignment.deny_public_network_access](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_group_policy_assignment) | resource |
| [azurerm_management_group_policy_assignment.tag_governance](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_group_policy_assignment) | resource |
| [azurerm_monitor_action_group.platform](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_action_group) | resource |
| [azurerm_monitor_diagnostic_setting.automation_account](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_policy_set_definition.deny_public_network_access](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/policy_set_definition) | resource |
| [azurerm_policy_set_definition.tag_governance](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/policy_set_definition) | resource |
| [azurerm_portal_dashboard.platform](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/portal_dashboard) | resource |
| [azurerm_resource_group.finops](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.management](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_provider_registration.cost_management_exports](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_provider_registration) | resource |
| [azurerm_role_assignment.tag_policy_remediation](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.terraform_sp_cost_exports_blob](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.cost_exports](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_storage_container.cost_exports](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [random_id.finops_sa](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_budget_alert_contact_emails"></a> [budget\_alert\_contact\_emails](#input\_budget\_alert\_contact\_emails) | Email addresses for budget threshold breach and cost anomaly alert notifications. | `list(string)` | n/a | yes |
| <a name="input_budget_start_date"></a> [budget\_start\_date](#input\_budget\_start\_date) | Budget and cost export start date in RFC 3339 format. Must be the first of a month (e.g. 2026-05-01T00:00:00Z). | `string` | n/a | yes |
| <a name="input_connectivity_subscription_id"></a> [connectivity\_subscription\_id](#input\_connectivity\_subscription\_id) | Subscription ID for the Connectivity platform subscription. | `string` | n/a | yes |
| <a name="input_identity_subscription_id"></a> [identity\_subscription\_id](#input\_identity\_subscription\_id) | Subscription ID for the Identity platform subscription. | `string` | n/a | yes |
| <a name="input_landingzones_subscription_id"></a> [landingzones\_subscription\_id](#input\_landingzones\_subscription\_id) | Subscription ID for the Landing Zones subscription (corp + online workloads). | `string` | n/a | yes |
| <a name="input_management_subscription_id"></a> [management\_subscription\_id](#input\_management\_subscription\_id) | Subscription ID for the Management platform subscription (sub-management-poc-01). | `string` | n/a | yes |
| <a name="input_org_prefix"></a> [org\_prefix](#input\_org\_prefix) | Short organisation identifier used in resource and policy naming (e.g. 'globaris'). | `string` | n/a | yes |
| <a name="input_security_subscription_id"></a> [security\_subscription\_id](#input\_security\_subscription\_id) | Subscription ID for the Security platform subscription. | `string` | n/a | yes |
| <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id) | Azure Active Directory tenant ID. | `string` | n/a | yes |
| <a name="input_terraform_sp_object_id"></a> [terraform\_sp\_object\_id](#input\_terraform\_sp\_object\_id) | Object ID of the OIDC service principal running Terraform. Granted Storage Blob Data Contributor on the cost-exports Storage Account (keyless, Entra-only auth). Fed by CI as TF\_VAR\_terraform\_sp\_object\_id (same as platform/security). | `string` | n/a | yes |
| <a name="input_budget_alert_thresholds"></a> [budget\_alert\_thresholds](#input\_budget\_alert\_thresholds) | Percentage thresholds at which budget alert notifications fire. | `list(number)` | <pre>[<br/>  50,<br/>  75,<br/>  90,<br/>  100<br/>]</pre> | no |
| <a name="input_budget_amount_per_mg"></a> [budget\_amount\_per\_mg](#input\_budget\_amount\_per\_mg) | Monthly budget cap in USD applied to management group scope budgets. | `number` | `600` | no |
| <a name="input_budget_amount_per_subscription"></a> [budget\_amount\_per\_subscription](#input\_budget\_amount\_per\_subscription) | Monthly budget cap in USD applied to each of the five platform/LZ subscriptions. | `number` | `200` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment label used in resource names and tags (e.g. 'poc'). | `string` | `"poc"` | no |
| <a name="input_export_end_date"></a> [export\_end\_date](#input\_export\_end\_date) | Cost export recurrence period end date in RFC 3339 format. | `string` | `"2030-12-01T00:00:00Z"` | no |
| <a name="input_platform_law_daily_quota_gb"></a> [platform\_law\_daily\_quota\_gb](#input\_platform\_law\_daily\_quota\_gb) | Daily ingestion quota in GB for the platform Log Analytics workspace. Null disables the cap. | `number` | `null` | no |
| <a name="input_platform_law_retention_days"></a> [platform\_law\_retention\_days](#input\_platform\_law\_retention\_days) | Log Analytics workspace data retention period in days (30-730). Section 8 baseline is 90. | `number` | `90` | no |
| <a name="input_primary_location"></a> [primary\_location](#input\_primary\_location) | Primary Azure region for resources that require a location. | `string` | `"eastus2"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags merged into all resources created by this module. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_automation_account_id"></a> [automation\_account\_id](#output\_automation\_account\_id) | ARM resource ID of the platform Automation Account. |
| <a name="output_automation_account_name"></a> [automation\_account\_name](#output\_automation\_account\_name) | Name of the platform Automation Account. |
| <a name="output_automation_account_principal_id"></a> [automation\_account\_principal\_id](#output\_automation\_account\_principal\_id) | Object ID of the system-assigned managed identity on the Automation Account. |
| <a name="output_carbon_optimization_workbook_id"></a> [carbon\_optimization\_workbook\_id](#output\_carbon\_optimization\_workbook\_id) | ARM resource ID of the Carbon Optimization Azure Monitor workbook. |
| <a name="output_cost_anomaly_alert_id"></a> [cost\_anomaly\_alert\_id](#output\_cost\_anomaly\_alert\_id) | ARM resource ID of the cost anomaly alert on the management subscription. |
| <a name="output_cost_export_storage_account_id"></a> [cost\_export\_storage\_account\_id](#output\_cost\_export\_storage\_account\_id) | ARM resource ID of the cost export storage account. |
| <a name="output_cost_export_storage_account_name"></a> [cost\_export\_storage\_account\_name](#output\_cost\_export\_storage\_account\_name) | Name of the storage account that receives daily cost exports from all subscriptions. |
| <a name="output_mg_budget_ids"></a> [mg\_budget\_ids](#output\_mg\_budget\_ids) | Map of management group budget ARM resource IDs keyed by MG name (globaris, platform, landingzones). |
| <a name="output_platform_action_group_id"></a> [platform\_action\_group\_id](#output\_platform\_action\_group\_id) | ARM resource ID of the platform Monitor Action Group. |
| <a name="output_platform_action_group_name"></a> [platform\_action\_group\_name](#output\_platform\_action\_group\_name) | Name of the platform Monitor Action Group. |
| <a name="output_platform_dashboard_id"></a> [platform\_dashboard\_id](#output\_platform\_dashboard\_id) | ARM resource ID of the shared platform portal dashboard. |
| <a name="output_platform_law_customer_id"></a> [platform\_law\_customer\_id](#output\_platform\_law\_customer\_id) | Workspace GUID (customer\_id) of the platform Log Analytics workspace. Required for Sentinel onboarding. Marked sensitive (inherited from the AVM resource object); retrieve with `terraform output -raw platform_law_customer_id`. |
| <a name="output_platform_law_workspace_id"></a> [platform\_law\_workspace\_id](#output\_platform\_law\_workspace\_id) | ARM resource ID of the platform Log Analytics workspace. Used by Sentinel (Section 8 Batch 3) and Defender (Section 6). |
| <a name="output_platform_law_workspace_name"></a> [platform\_law\_workspace\_name](#output\_platform\_law\_workspace\_name) | Name of the platform Log Analytics workspace. |
| <a name="output_platform_management_rg_id"></a> [platform\_management\_rg\_id](#output\_platform\_management\_rg\_id) | ARM resource ID of the management platform resource group. |
| <a name="output_platform_management_rg_name"></a> [platform\_management\_rg\_name](#output\_platform\_management\_rg\_name) | Name of the management platform resource group (holds LA workspace, Automation Account, etc.). |
| <a name="output_platform_overview_workbook_id"></a> [platform\_overview\_workbook\_id](#output\_platform\_overview\_workbook\_id) | ARM resource ID of the Platform Overview Azure Monitor workbook. |
| <a name="output_resource_group_id"></a> [resource\_group\_id](#output\_resource\_group\_id) | ARM resource ID of the FinOps resource group. |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Name of the FinOps resource group in the management subscription. |
| <a name="output_subscription_budget_ids"></a> [subscription\_budget\_ids](#output\_subscription\_budget\_ids) | Map of subscription budget ARM resource IDs keyed by logical subscription name. |
| <a name="output_tag_governance_assignment_id"></a> [tag\_governance\_assignment\_id](#output\_tag\_governance\_assignment\_id) | ARM resource ID of the tag governance policy assignment at the Globaris root MG. |
| <a name="output_tag_governance_initiative_id"></a> [tag\_governance\_initiative\_id](#output\_tag\_governance\_initiative\_id) | ARM resource ID of the custom tag governance policy set definition. |
| <a name="output_tag_policy_remediation_principal_id"></a> [tag\_policy\_remediation\_principal\_id](#output\_tag\_policy\_remediation\_principal\_id) | Object ID of the system-assigned managed identity on the tag governance policy assignment. Used for remediation tasks. |
<!-- END_TF_DOCS -->
