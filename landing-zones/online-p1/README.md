# landing-zones/online-p1

online-p1 landing zone (internet-facing spoke). Spoke VNet (10.20.0.0/16, eastus2)
peered to the primary hub. Fronts an Azure Static Web App with an Application Gateway
WAF_v2 (OWASP 3.2, Prevention mode). The App Gateway subnet carries no firewall UDR by
design; workload and private-endpoint subnets do.

Section 9 (Landing Zone Spokes). Deviations: native `azurerm_static_web_app` (no AVM
module on the registry as of 2026-05-14); App Gateway HTTP listener only until a TLS
cert is provisioned in the Security Key Vault (Section 12). Apply after
platform/connectivity.

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
| <a name="module_spoke_vnet"></a> [spoke\_vnet](#module\_spoke\_vnet) | Azure/avm-res-network-virtualnetwork/azurerm | 0.17.1 |

## Resources

| Name | Type |
|------|------|
| [azurerm_application_gateway.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway) | resource |
| [azurerm_monitor_diagnostic_setting.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting) | resource |
| [azurerm_network_security_group.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_network_security_group.workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) | resource |
| [azurerm_network_watcher_flow_log.spoke](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_watcher_flow_log) | resource |
| [azurerm_private_dns_zone_virtual_network_link.online_p1_to_sql_zone](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/private_dns_zone_virtual_network_link) | resource |
| [azurerm_public_ip.appgw](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip) | resource |
| [azurerm_resource_group.monitoring](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.shared](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group_policy_exemption.corp_paas](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group_policy_exemption) | resource |
| [azurerm_route_table.workload](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/route_table) | resource |
| [azurerm_static_web_app.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/static_web_app) | resource |
| [azurerm_storage_account.flow_logs](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) | resource |
| [azurerm_virtual_network_peering.hub_to_spoke](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_peering) | resource |
| [azurerm_virtual_network_peering.spoke_to_hub](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_peering) | resource |
| [azurerm_web_application_firewall_policy.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/web_application_firewall_policy) | resource |
| [random_id.flowlog_sa](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [time_sleep.wait_corp_policy_exemptions](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [azurerm_network_watcher.primary](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/network_watcher) | data source |
| [azurerm_private_dns_zone.sql](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/private_dns_zone) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_connectivity_subscription_id"></a> [connectivity\_subscription\_id](#input\_connectivity\_subscription\_id) | Subscription ID for the Connectivity platform subscription (hub-to-spoke return peering only). | `string` | n/a | yes |
| <a name="input_landingzones_subscription_id"></a> [landingzones\_subscription\_id](#input\_landingzones\_subscription\_id) | Subscription ID for the Landing Zones subscription. | `string` | n/a | yes |
| <a name="input_org_prefix"></a> [org\_prefix](#input\_org\_prefix) | Short organisation identifier used in resource naming (e.g. 'globaris'). | `string` | n/a | yes |
| <a name="input_platform_action_group_id"></a> [platform\_action\_group\_id](#input\_platform\_action\_group\_id) | ARM resource ID of the platform Monitor Action Group. | `string` | n/a | yes |
| <a name="input_platform_law_customer_id"></a> [platform\_law\_customer\_id](#input\_platform\_law\_customer\_id) | GUID (customer ID) of the platform Log Analytics workspace. Required for Traffic Analytics in NSG flow logs. | `string` | n/a | yes |
| <a name="input_platform_law_workspace_id"></a> [platform\_law\_workspace\_id](#input\_platform\_law\_workspace\_id) | ARM resource ID of the platform Log Analytics workspace. | `string` | n/a | yes |
| <a name="input_primary_firewall_private_ip"></a> [primary\_firewall\_private\_ip](#input\_primary\_firewall\_private\_ip) | Private IP of the primary Azure Firewall. Used as next-hop for non-App-Gateway subnets. | `string` | n/a | yes |
| <a name="input_primary_hub_rg_name"></a> [primary\_hub\_rg\_name](#input\_primary\_hub\_rg\_name) | Resource group name of the primary hub VNet in the Connectivity subscription. | `string` | n/a | yes |
| <a name="input_primary_hub_vnet_id"></a> [primary\_hub\_vnet\_id](#input\_primary\_hub\_vnet\_id) | ARM resource ID of the primary hub VNet. From platform/connectivity output 'primary\_hub\_vnet\_id'. | `string` | n/a | yes |
| <a name="input_primary_hub_vnet_name"></a> [primary\_hub\_vnet\_name](#input\_primary\_hub\_vnet\_name) | Name of the primary hub VNet. Required for the hub-to-spoke return peering. | `string` | n/a | yes |
| <a name="input_private_dns_rg_name"></a> [private\_dns\_rg\_name](#input\_private\_dns\_rg\_name) | Name of the resource group in the Connectivity subscription that holds all Private Link DNS zones. From platform/connectivity output 'private\_dns\_rg\_name'. | `string` | n/a | yes |
| <a name="input_appgw_capacity"></a> [appgw\_capacity](#input\_appgw\_capacity) | Fixed instance count for the Application Gateway WAF\_v2. Min 1 for POC; increase for production. | `number` | `1` | no |
| <a name="input_enable_corp_policy_exemptions"></a> [enable\_corp\_policy\_exemptions](#input\_enable\_corp\_policy\_exemptions) | Create the RG-scoped Waiver policy exemption for the corp-MG Deny-Public-Endpoints StorageDenyPaasPublicIP member on the flow-log storage account, which cannot be made compliant without breaking flow-log delivery. Default true; set false only if this spoke is moved out from under the corp MG or the governance changes (OQ-024). | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment label used in resource names and tags (e.g. 'poc'). | `string` | `"poc"` | no |
| <a name="input_flow_log_retention_days"></a> [flow\_log\_retention\_days](#input\_flow\_log\_retention\_days) | Number of days to retain NSG flow log data in the storage account. | `number` | `7` | no |
| <a name="input_primary_location"></a> [primary\_location](#input\_primary\_location) | Primary Azure region for online-p1 resources. | `string` | `"eastus2"` | no |
| <a name="input_spoke_address_space"></a> [spoke\_address\_space](#input\_spoke\_address\_space) | CIDR block for the online-p1 spoke VNet. All subnet prefixes are computed from this block. | `string` | `"10.20.0.0/16"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags merged into all resources created by this module. | `map(string)` | `{}` | no |
| <a name="input_waf_mode"></a> [waf\_mode](#input\_waf\_mode) | WAF mode: Detection (log only) or Prevention (block). Prevention is the production default. | `string` | `"Prevention"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_appgw_id"></a> [appgw\_id](#output\_appgw\_id) | ARM resource ID of the Application Gateway. |
| <a name="output_appgw_public_ip"></a> [appgw\_public\_ip](#output\_appgw\_public\_ip) | Public IP address of the Application Gateway WAF\_v2 frontend. Use this to test the online-p1 workload. |
| <a name="output_appgw_subnet_id"></a> [appgw\_subnet\_id](#output\_appgw\_subnet\_id) | ARM resource ID of the Application Gateway subnet. |
| <a name="output_monitoring_rg_name"></a> [monitoring\_rg\_name](#output\_monitoring\_rg\_name) | Name of the online-p1 monitoring resource group. |
| <a name="output_network_rg_name"></a> [network\_rg\_name](#output\_network\_rg\_name) | Name of the online-p1 network resource group. |
| <a name="output_private_endpoint_subnet_id"></a> [private\_endpoint\_subnet\_id](#output\_private\_endpoint\_subnet\_id) | ARM resource ID of the private endpoints subnet. |
| <a name="output_shared_rg_name"></a> [shared\_rg\_name](#output\_shared\_rg\_name) | Name of the online-p1 shared resource group. |
| <a name="output_spoke_vnet_id"></a> [spoke\_vnet\_id](#output\_spoke\_vnet\_id) | ARM resource ID of the online-p1 spoke VNet. Referenced by Section 4 Private DNS zone links. |
| <a name="output_spoke_vnet_name"></a> [spoke\_vnet\_name](#output\_spoke\_vnet\_name) | Name of the online-p1 spoke VNet. |
| <a name="output_static_web_app_api_key"></a> [static\_web\_app\_api\_key](#output\_static\_web\_app\_api\_key) | Deployment API key for the Static Web App. Store in the Security Key Vault after initial apply. |
| <a name="output_static_web_app_default_hostname"></a> [static\_web\_app\_default\_hostname](#output\_static\_web\_app\_default\_hostname) | Default hostname of the Static Web App (*.azurestaticapps.net). Used as the App Gateway backend FQDN. |
| <a name="output_static_web_app_id"></a> [static\_web\_app\_id](#output\_static\_web\_app\_id) | ARM resource ID of the Azure Static Web App. |
| <a name="output_waf_policy_id"></a> [waf\_policy\_id](#output\_waf\_policy\_id) | ARM resource ID of the WAF policy associated with the Application Gateway. |
| <a name="output_workload_rg_name"></a> [workload\_rg\_name](#output\_workload\_rg\_name) | Name of the online-p1 workload resource group. |
<!-- END_TF_DOCS -->
