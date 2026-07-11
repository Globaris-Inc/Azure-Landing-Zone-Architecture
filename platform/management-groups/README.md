# platform/management-groups

Management Group hierarchy root. Calls `avm-ptn-alz` to build the Globaris MG tree
(Platform > Management/Connectivity/Identity/Security, Landing Zones > Corp/Online,
plus Decommissioned and Sandbox) and places all 5 POC subscriptions under their
respective management groups. The architecture is defined in
`lib/globaris.alz_architecture_definition.json`.

Section 2 (Management Group Hierarchy). Apply this root first - management, security,
and connectivity policy assignments scope to the MGs created here.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_alz"></a> [alz](#requirement\_alz) | ~> 0.21.0 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.9.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.71.0 |
| <a name="requirement_modtm"></a> [modtm](#requirement\_modtm) | ~> 0.3.5 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.8.1 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.13.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | 2.9.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_alz_management_groups"></a> [alz\_management\_groups](#module\_alz\_management\_groups) | Azure/avm-ptn-alz/azurerm | 0.19.1 |

## Resources

| Name | Type |
|------|------|
| [azapi_client_config.current](https://registry.terraform.io/providers/azure/azapi/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_connectivity_subscription_id"></a> [connectivity\_subscription\_id](#input\_connectivity\_subscription\_id) | Subscription ID for sub-connectivity-poc-01 - placed under the Connectivity management group. | `string` | n/a | yes |
| <a name="input_identity_subscription_id"></a> [identity\_subscription\_id](#input\_identity\_subscription\_id) | Subscription ID for sub-identity-poc-01 - placed under the Identity management group. | `string` | n/a | yes |
| <a name="input_landingzones_subscription_id"></a> [landingzones\_subscription\_id](#input\_landingzones\_subscription\_id) | Subscription ID for sub-landingzones-poc-01 - placed under the Corp management group. | `string` | n/a | yes |
| <a name="input_management_subscription_id"></a> [management\_subscription\_id](#input\_management\_subscription\_id) | Subscription ID for sub-management-poc-01 - placed under the Management management group. | `string` | n/a | yes |
| <a name="input_security_subscription_id"></a> [security\_subscription\_id](#input\_security\_subscription\_id) | Subscription ID for sub-security-poc-01 - placed under the Security management group. | `string` | n/a | yes |
| <a name="input_primary_location"></a> [primary\_location](#input\_primary\_location) | Primary Azure region for resources that require a location (e.g. policy assignments with remediation). | `string` | `"eastus2"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags to merge into all resources managed by this module. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alz_module_outputs"></a> [alz\_module\_outputs](#output\_alz\_module\_outputs) | Full output object from the avm-ptn-alz module - useful for debugging policy assignments and archetype details. |
| <a name="output_management_group_ids"></a> [management\_group\_ids](#output\_management\_group\_ids) | Map of management group logical name to resource ID for all MGs in the Globaris hierarchy. |
<!-- END_TF_DOCS -->
