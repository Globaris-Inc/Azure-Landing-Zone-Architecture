# platform/connectivity

Connectivity platform root. Deploys the dual-hub hub-and-spoke topology to the
Connectivity subscription (primary + secondary hubs): hub VNets, Azure Firewall
Premium with IDPS, VPN Gateway, and DNS Private Resolver. The
`dns-resolver-outbound` subnet is delegated to `Microsoft.Network/dnsResolvers`.

Section 8 (Standard Platform Components), with DR topology (Section 3) and Private
DNS (Section 4) wiring. Apply order: independent of platform/management; run before
platform/security (Firewall private IPs feed spoke UDRs).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.5 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | ~> 4.71.0 |
| <a name="requirement_modtm"></a> [modtm](#requirement\_modtm) | ~> 0.3.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.8.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.71.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_hub_and_spoke"></a> [hub\_and\_spoke](#module\_hub\_and\_spoke) | Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet/azurerm | 0.17.1 |
| <a name="module_private_dns_zones"></a> [private\_dns\_zones](#module\_private\_dns\_zones) | Azure/avm-ptn-network-private-link-private-dns-zones/azurerm | 0.23.1 |

## Resources

| Name | Type |
|------|------|
| [azurerm_resource_group.connectivity_primary](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.connectivity_secondary](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |
| [azurerm_resource_group.dns](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_connectivity_subscription_id"></a> [connectivity\_subscription\_id](#input\_connectivity\_subscription\_id) | Subscription ID for the Connectivity platform subscription. | `string` | n/a | yes |
| <a name="input_org_prefix"></a> [org\_prefix](#input\_org\_prefix) | Short organisation identifier used in resource naming (e.g. 'globaris'). | `string` | n/a | yes |
| <a name="input_tenant_id"></a> [tenant\_id](#input\_tenant\_id) | Azure Active Directory tenant ID. | `string` | n/a | yes |
| <a name="input_enable_bastion"></a> [enable\_bastion](#input\_enable\_bastion) | Deploy Azure Bastion (Standard SKU) in the PRIMARY hub on demand. Default false so idle cost is $0; operators set true + apply (deploy.yml) to bring Bastion up for no-public-IP management access, false + apply to remove it (~+$140/mo while enabled). Secondary hub never gets Bastion. See ADR-015 / gap-closure G6. | `bool` | `false` | no |
| <a name="input_enable_ddos_standard"></a> [enable\_ddos\_standard](#input\_enable\_ddos\_standard) | Enable Azure DDoS Network Protection (Standard) on hub VNets. Disabled by default - DDoS Standard costs ~$2,944/mo and is not required for the POC. | `bool` | `false` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment label used in resource names and tags (e.g. 'poc'). | `string` | `"poc"` | no |
| <a name="input_hub_primary_address_space"></a> [hub\_primary\_address\_space](#input\_hub\_primary\_address\_space) | CIDR block for the primary hub VNet. All primary hub subnet prefixes are computed from this block. | `string` | `"10.0.0.0/16"` | no |
| <a name="input_hub_secondary_address_space"></a> [hub\_secondary\_address\_space](#input\_hub\_secondary\_address\_space) | CIDR block for the secondary (DR) hub VNet. All secondary hub subnet prefixes are computed from this block. | `string` | `"10.1.0.0/16"` | no |
| <a name="input_primary_location"></a> [primary\_location](#input\_primary\_location) | Primary Azure region for the primary hub VNet and firewall. | `string` | `"eastus2"` | no |
| <a name="input_secondary_location"></a> [secondary\_location](#input\_secondary\_location) | Secondary / DR Azure region for the secondary hub VNet and firewall. | `string` | `"centralus"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags merged into all resources created by this module. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_connectivity_primary_rg_id"></a> [connectivity\_primary\_rg\_id](#output\_connectivity\_primary\_rg\_id) | ARM resource ID of the primary connectivity resource group. |
| <a name="output_connectivity_primary_rg_name"></a> [connectivity\_primary\_rg\_name](#output\_connectivity\_primary\_rg\_name) | Name of the primary connectivity resource group. |
| <a name="output_connectivity_secondary_rg_id"></a> [connectivity\_secondary\_rg\_id](#output\_connectivity\_secondary\_rg\_id) | ARM resource ID of the secondary (DR) connectivity resource group. |
| <a name="output_connectivity_secondary_rg_name"></a> [connectivity\_secondary\_rg\_name](#output\_connectivity\_secondary\_rg\_name) | Name of the secondary (DR) connectivity resource group. |
| <a name="output_primary_bastion_dns_name"></a> [primary\_bastion\_dns\_name](#output\_primary\_bastion\_dns\_name) | DNS name of the primary hub Azure Bastion when deployed on demand (var.enable\_bastion = true); null when Bastion is off. |
| <a name="output_primary_bastion_id"></a> [primary\_bastion\_id](#output\_primary\_bastion\_id) | ARM resource ID of the primary hub Azure Bastion when deployed on demand (var.enable\_bastion = true); null when Bastion is off. See ADR-015 / G6. |
| <a name="output_primary_dns_resolver_inbound_ips"></a> [primary\_dns\_resolver\_inbound\_ips](#output\_primary\_dns\_resolver\_inbound\_ips) | IP address(es) of the primary hub DNS Private Resolver inbound endpoint. Configure as DNS server in spoke VNets. |
| <a name="output_primary_firewall_id"></a> [primary\_firewall\_id](#output\_primary\_firewall\_id) | ARM resource ID of the primary Azure Firewall Premium. |
| <a name="output_primary_firewall_private_ip"></a> [primary\_firewall\_private\_ip](#output\_primary\_firewall\_private\_ip) | Private IP address of the primary Azure Firewall. Used as next-hop in spoke UDRs. |
| <a name="output_primary_hub_vnet_id"></a> [primary\_hub\_vnet\_id](#output\_primary\_hub\_vnet\_id) | ARM resource ID of the primary hub VNet (eastus2). Consumed by spoke peering in Section 9. |
| <a name="output_primary_hub_vnet_name"></a> [primary\_hub\_vnet\_name](#output\_primary\_hub\_vnet\_name) | Name of the primary hub VNet. |
| <a name="output_primary_vpn_gateway_id"></a> [primary\_vpn\_gateway\_id](#output\_primary\_vpn\_gateway\_id) | ARM resource ID of the primary hub VPN Gateway. |
| <a name="output_private_dns_rg_name"></a> [private\_dns\_rg\_name](#output\_private\_dns\_rg\_name) | Name of the resource group holding all Private Link DNS zones. Passed to spoke landing zones so they can look up zone IDs via data sources. |
| <a name="output_private_dns_zone_ids"></a> [private\_dns\_zone\_ids](#output\_private\_dns\_zone\_ids) | Map of private DNS zone name → ARM resource ID. Populated after dns.tf apply. Consumed by spoke landing zones for private\_dns\_zone\_group blocks. |
| <a name="output_secondary_firewall_id"></a> [secondary\_firewall\_id](#output\_secondary\_firewall\_id) | ARM resource ID of the secondary Azure Firewall Premium. |
| <a name="output_secondary_firewall_private_ip"></a> [secondary\_firewall\_private\_ip](#output\_secondary\_firewall\_private\_ip) | Private IP address of the secondary Azure Firewall. Used as next-hop in DR spoke UDRs. |
| <a name="output_secondary_hub_vnet_id"></a> [secondary\_hub\_vnet\_id](#output\_secondary\_hub\_vnet\_id) | ARM resource ID of the secondary (DR) hub VNet (centralus). |
| <a name="output_secondary_hub_vnet_name"></a> [secondary\_hub\_vnet\_name](#output\_secondary\_hub\_vnet\_name) | Name of the secondary (DR) hub VNet. |
<!-- END_TF_DOCS -->
