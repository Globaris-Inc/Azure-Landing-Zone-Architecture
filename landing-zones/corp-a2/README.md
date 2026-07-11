# landing-zones/corp-a2

corp-a2 landing zone (DR spoke). Spoke VNet (10.11.0.0/16, centralus) peered to the
secondary DR hub, traffic forced through the secondary Azure Firewall via UDR. Mirrors
the corp-a1 workload tier (Linux App Service + Entra-only Azure SQL over a Private
Endpoint) and adds a Recovery Services Vault (Standard, GeoRedundant) for Azure Site
Recovery replication.

Section 9 (Landing Zone Spokes) with DR topology (Section 3). Apply after
platform/connectivity (secondary hub) and alongside corp-a1 for optional SQL
geo-replication.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.5 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.71.0 |
| <a name="requirement_modtm"></a> [modtm](#requirement\_modtm) | ~> 0.3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.8.1 |
| <a name="requirement_time"></a> [time](#requirement\_time) | ~> 0.13.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.71.0 |
| <a name="provider_azurerm.connectivity"></a> [azurerm.connectivity](#provider\_azurerm.connectivity) | 4.71.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.1 |
| <a name="provider_time"></a> [time](#provider\_time) | 0.13.1 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_app_service"></a> [app\_service](#module\_app\_service) | Azure/avm-res-web-site/azurerm | 0.22.0 |
| <a name="module_app_service_plan"></a> [app\_service\_plan](#module\_app\_service\_plan) | Azure/avm-res-web-serverfarm/azurerm | 2.0.4 |
| <a name="module_recovery_services_vault"></a> [recovery\_services\_vault](#module\_recovery\_services\_vault) | Azure/avm-res-recoveryservices-vault/azurerm | 1.1.3 |
| <a name="module_spoke_vnet"></a> [spoke\_vnet](#module\_spoke\_vnet) | Azure/avm-res-network-virtualnetwork/azurerm | 0.17.1 |

## Resources

| Name | Type |
|------|------|
| [azurerm_mssql_database.app](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_database) | resource |
| [azurerm_mssql_server.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_server) | resource |
| [azurerm_network_security_group.spoke](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_network_watcher_flow_log.spoke](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_watcher_flow_log) | resource |
| [azurerm_private_dns_zone_virtual_network_link.corp_a2_to_sql_zone](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_private_endpoint.sql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_endpoint) | resource |
| [azurerm_resource_group.monitoring](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.shared](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group_policy_exemption.corp_paas](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group_policy_exemption) | resource |
| [azurerm_route_table.spoke](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/route_table) | resource |
| [azurerm_storage_account.flow_logs](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_virtual_network_peering.hub_to_spoke](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_peering) | resource |
| [azurerm_virtual_network_peering.spoke_to_hub](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_peering) | resource |
| [random_id.flowlog_sa](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [random_id.sql_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [time_sleep.wait_corp_policy_exemptions](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_network_watcher.secondary](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/network_watcher) | data source |
| [azurerm_private_dns_zone.sql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/private_dns_zone) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_connectivity_subscription_id"></a> [connectivity\_subscription\_id](#input\_connectivity\_subscription\_id) | Subscription ID for the Connectivity platform subscription. Used only for the hub-to-spoke return VNet peering. | `string` | n/a | yes |
| <a name="input_landingzones_subscription_id"></a> [landingzones\_subscription\_id](#input\_landingzones\_subscription\_id) | Subscription ID for the Landing Zones subscription. All corp-a2 spoke resources deploy here. | `string` | n/a | yes |
| <a name="input_org_prefix"></a> [org\_prefix](#input\_org\_prefix) | Short organisation identifier used in resource naming (e.g. 'globaris'). | `string` | n/a | yes |
| <a name="input_platform_action_group_id"></a> [platform\_action\_group\_id](#input\_platform\_action\_group\_id) | ARM resource ID of the platform Monitor Action Group. | `string` | n/a | yes |
| <a name="input_platform_law_customer_id"></a> [platform\_law\_customer\_id](#input\_platform\_law\_customer\_id) | GUID (customer ID) of the platform Log Analytics workspace. Required for Traffic Analytics in NSG flow logs. | `string` | n/a | yes |
| <a name="input_platform_law_workspace_id"></a> [platform\_law\_workspace\_id](#input\_platform\_law\_workspace\_id) | ARM resource ID of the platform Log Analytics workspace. Diagnostic settings for App Service and SQL stream here. | `string` | n/a | yes |
| <a name="input_private_dns_rg_name"></a> [private\_dns\_rg\_name](#input\_private\_dns\_rg\_name) | Name of the resource group in the Connectivity subscription that holds all Private Link DNS zones. From platform/connectivity output 'private\_dns\_rg\_name'. | `string` | n/a | yes |
| <a name="input_secondary_firewall_private_ip"></a> [secondary\_firewall\_private\_ip](#input\_secondary\_firewall\_private\_ip) | Private IP address of the secondary (DR) Azure Firewall. Used as the next-hop in the corp-a2 spoke UDR. | `string` | n/a | yes |
| <a name="input_secondary_hub_rg_name"></a> [secondary\_hub\_rg\_name](#input\_secondary\_hub\_rg\_name) | Resource group name of the secondary hub VNet in the Connectivity subscription. Required for the hub-to-spoke return peering. | `string` | n/a | yes |
| <a name="input_secondary_hub_vnet_id"></a> [secondary\_hub\_vnet\_id](#input\_secondary\_hub\_vnet\_id) | ARM resource ID of the secondary (DR) hub VNet (centralus). From platform/connectivity output 'secondary\_hub\_vnet\_id'. | `string` | n/a | yes |
| <a name="input_secondary_hub_vnet_name"></a> [secondary\_hub\_vnet\_name](#input\_secondary\_hub\_vnet\_name) | Name of the secondary (DR) hub VNet. From platform/connectivity output 'secondary\_hub\_vnet\_name'. | `string` | n/a | yes |
| <a name="input_sql_aad_admin_login"></a> [sql\_aad\_admin\_login](#input\_sql\_aad\_admin\_login) | Display name or UPN of the Entra ID SQL administrator. | `string` | n/a | yes |
| <a name="input_sql_aad_admin_object_id"></a> [sql\_aad\_admin\_object\_id](#input\_sql\_aad\_admin\_object\_id) | Object ID of the Entra ID group or user to set as the SQL Server Azure AD administrator. | `string` | n/a | yes |
| <a name="input_app_service_sku"></a> [app\_service\_sku](#input\_app\_service\_sku) | SKU name for the App Service Plan. | `string` | `"B2"` | no |
| <a name="input_enable_app_service"></a> [enable\_app\_service](#input\_enable\_app\_service) | Gate for the App Service tier (App Service Plan + Site). Default false: the App Service tier is gated off because the landingzones subscription's DEDICATED App Service compute quota is 0 (ARM ExtendedCode 70007 'Total VMs: 0, required 3' - a Microsoft.Web dedicated-compute offer cap, not the Microsoft.Compute quota). The plan create fails on the quota and the site depends on it, so neither can deploy. Pre-staged: set true when a quota increase is granted (or after a serverless redesign). Same class as enable\_sql. See the DEVIATION note on the App Service tier in main.tf and ADR-032. | `bool` | `false` | no |
| <a name="input_enable_corp_policy_exemptions"></a> [enable\_corp\_policy\_exemptions](#input\_enable\_corp\_policy\_exemptions) | Create the RG-scoped Waiver policy exemptions for the corp-MG Deny-Public-Endpoints initiative members (StorageDenyPaasPublicIP on the flow-log SA, AsDenyPublicIP on the App Service) that cannot be made compliant without breaking function. Default true; set false only if this spoke is moved out from under the corp MG or the governance changes (OQ-024). | `bool` | `true` | no |
| <a name="input_enable_sql"></a> [enable\_sql](#input\_enable\_sql) | Gate for the SQL data tier (logical server, database, and its private endpoint). Default false: Azure SQL provisioning is restricted in the spoke region (centralus) for the landingzones subscription (ProvisioningDisabled - a subscription/region restriction surfaced during PUT polling, not a code bug), so the SQL tier is pre-staged but not deployed. Set true once a region/subscription that permits Azure SQL is available or a support-request exception is granted. See the DEVIATION note on azurerm\_mssql\_server.this in main.tf. | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment label used in resource names and tags (e.g. 'poc'). | `string` | `"poc"` | no |
| <a name="input_flow_log_retention_days"></a> [flow\_log\_retention\_days](#input\_flow\_log\_retention\_days) | Number of days to retain NSG flow log data in the storage account. | `number` | `7` | no |
| <a name="input_rsv_geo_redundant"></a> [rsv\_geo\_redundant](#input\_rsv\_geo\_redundant) | Enable geo-redundant storage for the Recovery Services Vault. Set false to reduce cost during development. | `bool` | `true` | no |
| <a name="input_secondary_location"></a> [secondary\_location](#input\_secondary\_location) | DR Azure region for corp-a2 resources. Must match the secondary hub location. | `string` | `"centralus"` | no |
| <a name="input_spoke_address_space"></a> [spoke\_address\_space](#input\_spoke\_address\_space) | CIDR block for the corp-a2 spoke VNet. All subnet prefixes are computed from this block. | `string` | `"10.11.0.0/16"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags merged into all resources created by this module. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_app_service_default_hostname"></a> [app\_service\_default\_hostname](#output\_app\_service\_default\_hostname) | Default hostname of the corp-a2 (DR) App Service. Null when the App Service tier is gated off (var.enable\_app\_service = false). |
| <a name="output_app_service_id"></a> [app\_service\_id](#output\_app\_service\_id) | ARM resource ID of the corp-a2 App Service. Null when the App Service tier is gated off (var.enable\_app\_service = false). |
| <a name="output_monitoring_rg_name"></a> [monitoring\_rg\_name](#output\_monitoring\_rg\_name) | Name of the corp-a2 monitoring resource group. |
| <a name="output_network_rg_name"></a> [network\_rg\_name](#output\_network\_rg\_name) | Name of the corp-a2 network resource group. |
| <a name="output_private_endpoint_subnet_id"></a> [private\_endpoint\_subnet\_id](#output\_private\_endpoint\_subnet\_id) | ARM resource ID of the private endpoints subnet. |
| <a name="output_recovery_services_vault_id"></a> [recovery\_services\_vault\_id](#output\_recovery\_services\_vault\_id) | ARM resource ID of the Recovery Services Vault. Used for ASR replication enrollment in Section 13. |
| <a name="output_recovery_services_vault_name"></a> [recovery\_services\_vault\_name](#output\_recovery\_services\_vault\_name) | Name of the Recovery Services Vault. |
| <a name="output_shared_rg_name"></a> [shared\_rg\_name](#output\_shared\_rg\_name) | Name of the corp-a2 shared resource group. |
| <a name="output_spoke_vnet_id"></a> [spoke\_vnet\_id](#output\_spoke\_vnet\_id) | ARM resource ID of the corp-a2 spoke VNet (centralus DR). Referenced by Section 4 Private DNS zone links. |
| <a name="output_spoke_vnet_name"></a> [spoke\_vnet\_name](#output\_spoke\_vnet\_name) | Name of the corp-a2 spoke VNet. |
| <a name="output_sql_database_id"></a> [sql\_database\_id](#output\_sql\_database\_id) | ARM resource ID of the corp-a2 application SQL database. Null when the SQL tier is gated off (var.enable\_sql = false). |
| <a name="output_sql_private_endpoint_id"></a> [sql\_private\_endpoint\_id](#output\_sql\_private\_endpoint\_id) | ARM resource ID of the SQL Private Endpoint. Null when the SQL tier is gated off (var.enable\_sql = false). |
| <a name="output_sql_server_fqdn"></a> [sql\_server\_fqdn](#output\_sql\_server\_fqdn) | Fully qualified domain name of the corp-a2 SQL logical server. Null when the SQL tier is gated off (var.enable\_sql = false). |
| <a name="output_sql_server_id"></a> [sql\_server\_id](#output\_sql\_server\_id) | ARM resource ID of the corp-a2 SQL logical server. Referenced when configuring geo-replication from corp-a1. Null when the SQL tier is gated off (var.enable\_sql = false). |
| <a name="output_workload_rg_name"></a> [workload\_rg\_name](#output\_workload\_rg\_name) | Name of the corp-a2 workload resource group. |
<!-- END_TF_DOCS -->
