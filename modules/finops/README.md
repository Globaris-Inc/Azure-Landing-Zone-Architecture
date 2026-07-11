# finops

Reusable FinOps child module - provisions a per-subscription consumption budget,
a daily ActualCost export to shared storage, and optional VM auto-shutdown schedules.
Called once per target subscription from `platform/management`.

Section 7 (FinOps: Tagging & Budgets). See module header comments in `main.tf` for the
azapi/ADR-027 rationale behind the cost-export deviation.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.5 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.71.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | ~> 2.5 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | ~> 4.71.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azapi_resource.cost_export](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource) | resource |
| [azurerm_consumption_budget_subscription.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/consumption_budget_subscription) | resource |
| [azurerm_dev_test_global_vm_shutdown_schedule.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/dev_test_global_vm_shutdown_schedule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_budget_alert_contact_emails"></a> [budget\_alert\_contact\_emails](#input\_budget\_alert\_contact\_emails) | Email addresses to notify when a budget threshold is crossed. | `list(string)` | n/a | yes |
| <a name="input_budget_amount"></a> [budget\_amount](#input\_budget\_amount) | Monthly budget cap in USD. | `number` | n/a | yes |
| <a name="input_budget_name"></a> [budget\_name](#input\_budget\_name) | Name for the subscription consumption budget resource. | `string` | n/a | yes |
| <a name="input_budget_start_date"></a> [budget\_start\_date](#input\_budget\_start\_date) | Budget start date in RFC 3339 format. Must be the first day of a month (e.g. 2026-05-01T00:00:00Z). | `string` | n/a | yes |
| <a name="input_subscription_id"></a> [subscription\_id](#input\_subscription\_id) | Azure subscription this budget and cost export target. Accepts either a bare subscription GUID or the full resource ID (/subscriptions/<uuid>); the module normalizes to the full resource ID required by azurerm v4. | `string` | n/a | yes |
| <a name="input_budget_alert_thresholds"></a> [budget\_alert\_thresholds](#input\_budget\_alert\_thresholds) | Percentage thresholds at which budget alert notifications fire. | `list(number)` | <pre>[<br/>  50,<br/>  75,<br/>  90,<br/>  100<br/>]</pre> | no |
| <a name="input_export_container_name"></a> [export\_container\_name](#input\_export\_container\_name) | Name of the blob container inside export\_storage\_account\_id that receives daily exports (container name only, not an ARM ID). Required when export\_enabled = true. | `string` | `""` | no |
| <a name="input_export_enabled"></a> [export\_enabled](#input\_export\_enabled) | Whether to create a daily ActualCost export for this subscription. This bool is the sole (statically-known) gate on export creation; when true the caller must supply a valid export\_storage\_account\_id, export\_container\_name, and export\_identity\_location. | `bool` | `true` | no |
| <a name="input_export_end_date"></a> [export\_end\_date](#input\_export\_end\_date) | Cost export recurrence end date in RFC 3339 format. | `string` | `"2030-12-01T00:00:00Z"` | no |
| <a name="input_export_identity_location"></a> [export\_identity\_location](#input\_export\_identity\_location) | Azure region for the export resource's system-assigned managed identity (ARM requires location only when the export carries an identity). Required when export\_enabled = true. | `string` | `""` | no |
| <a name="input_export_name"></a> [export\_name](#input\_export\_name) | Name for the daily cost export resource. Defaults to '<budget\_name>-daily-export'. | `string` | `""` | no |
| <a name="input_export_root_folder"></a> [export\_root\_folder](#input\_export\_root\_folder) | Folder prefix inside the export storage container. No leading slash - the value is passed verbatim as deliveryInfo.destination.rootFolderPath in the ARM body. | `string` | `"exports"` | no |
| <a name="input_export_start_date"></a> [export\_start\_date](#input\_export\_start\_date) | Cost export recurrence start date in RFC 3339 format. Defaults to budget\_start\_date if empty. | `string` | `""` | no |
| <a name="input_export_storage_account_id"></a> [export\_storage\_account\_id](#input\_export\_storage\_account\_id) | ARM resource ID of the storage account that receives daily exports. May be unknown at plan time. Must be non-empty and valid whenever export\_enabled = true; it does not gate export creation (export\_enabled does). | `string` | `""` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to all taggable resources created by this module. | `map(string)` | `{}` | no |
| <a name="input_vm_shutdown_schedules"></a> [vm\_shutdown\_schedules](#input\_vm\_shutdown\_schedules) | Map of VMs to configure auto-shutdown on. Key = logical VM name. Called with empty map until VMs exist (Section 8). | <pre>map(object({<br/>    virtual_machine_id    = string<br/>    location              = string<br/>    daily_recurrence_time = string # HHMM 24-hour format, e.g. "1900" for 7:00 PM<br/>    timezone              = string # Windows timezone name, e.g. "Eastern Standard Time"<br/>    enabled               = bool<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_budget_id"></a> [budget\_id](#output\_budget\_id) | ARM resource ID of the subscription consumption budget. |
| <a name="output_export_ids"></a> [export\_ids](#output\_export\_ids) | Map of cost export ARM resource IDs. Key is 'export' when enabled, empty map when disabled. |
| <a name="output_vm_shutdown_schedule_ids"></a> [vm\_shutdown\_schedule\_ids](#output\_vm\_shutdown\_schedule\_ids) | Map of VM auto-shutdown schedule resource IDs keyed by logical VM name. |
<!-- END_TF_DOCS -->
