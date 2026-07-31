# Purpose: Connectivity platform root module - dual-hub hub-and-spoke VNets (network
#          fabric). Azure Firewall Premium (IDPS), VPN Gateway, and DNS Private Resolver
#          are flag-gated (default OFF) per ADR-042; their config blocks below stay
#          inert until enable_firewall / enable_vpn_gateway / enable_dns_resolver flip.
# Section: 8 - Standard Platform Components
# Last updated: 2026-07-17 (ADR-042: gate firewalls, VPN gateway, and DNS resolver behind default-false flags - lean B0b hub)
#
# Apply order: Independent of platform/management; run before platform/security
#              (Firewall private IPs are consumed by spoke UDRs in Section 8 Batch 3+).
#
# Resources deployed to: Connectivity subscription (primary + secondary hubs).

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "platform-connectivity"
      Owner              = "platform-team"
      Workload           = "platform-connectivity"
      DataClassification = "Internal"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
    },
    var.tags
  )

  # Subnet prefixes carved from hub_primary_address_space.
  # Concrete CIDRs shown for the default 10.0.0.0/16 base.
  hub_primary_firewall_prefix     = cidrsubnet(var.hub_primary_address_space, 10, 0)  # 10.0.0.0/26
  hub_primary_bastion_prefix      = cidrsubnet(var.hub_primary_address_space, 10, 1)  # 10.0.0.64/26 (AzureBastionSubnet, /26 min)
  hub_primary_gateway_prefix      = cidrsubnet(var.hub_primary_address_space, 11, 8)  # 10.0.1.0/27
  hub_primary_dns_inbound_prefix  = cidrsubnet(var.hub_primary_address_space, 12, 32) # 10.0.2.0/28
  hub_primary_dns_outbound_prefix = cidrsubnet(var.hub_primary_address_space, 12, 33) # 10.0.2.16/28

  # Subnet prefixes carved from hub_secondary_address_space.
  # Concrete CIDRs shown for the default 10.1.0.0/16 base.
  hub_secondary_firewall_prefix = cidrsubnet(var.hub_secondary_address_space, 10, 0) # 10.1.0.0/26
}

# ---------------------------------------------------------------------------
# Resource Groups
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "connectivity_primary" {
  name     = "rg-connectivity-primary-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "connectivity_secondary" {
  name     = "rg-connectivity-secondary-${var.org_prefix}-${var.environment}"
  location = var.secondary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Hub-and-spoke VNets - primary (centralus) + secondary (eastus2) DR hub
# ---------------------------------------------------------------------------
#
# Module: Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet v0.17.1
# Confirmed on registry.terraform.io 2026-05-12.
#
# Primary hub:   fabric + (when flags on) Firewall Premium, VPN GW (VpnGw1AZ), DNS Private Resolver
# Secondary hub: fabric + (when enable_firewall) Firewall Premium only - VPN GW and DNS
#                Resolver are primary-hub-only even when enabled.
# ADR-042: all three appliance flags default false (lean hub); config blocks stay inert.
#
# DEVIATION: Azure Firewall Premium TLS inspection requires a Key Vault certificate
# (Key Vault is created in Section 8 Batch 3 - platform/security). The firewall policy
# is deployed at Premium SKU with IDPS in Alert mode. Wire tls_certificate in
# firewall_policy once the Security KV is available.

module "hub_and_spoke" {
  source  = "Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet/azurerm"
  version = "0.17.1"

  # Shared (cross-hub) settings. The module defaults enabled_resources.ddos_protection_plan
  # to true, which creates a standalone Azure DDoS Network Protection Plan (~$2,944/mo) and
  # wires its id into BOTH hub VNets. Gate creation on var.enable_ddos_standard: when false,
  # module.ddos_protection_plan count = 0 (no plan), local.ddos_protection_plan_id = null,
  # and both hubs' ddos_protection_plan_id fall back to null (DDoS disabled). Default off for POC.
  hub_and_spoke_networks_settings = {
    enabled_resources = {
      ddos_protection_plan = var.enable_ddos_standard
    }
  }

  hub_virtual_networks = {
    primary = {
      location          = var.primary_location
      default_parent_id = azurerm_resource_group.connectivity_primary.id

      enabled_resources = {
        firewall                              = var.enable_firewall # ADR-042: default off; also gates the policy, PIP, AzureFirewallSubnet, and hub route tables in the module
        firewall_policy                       = var.enable_firewall # ADR-042: policy travels with the firewall
        bastion                               = var.enable_bastion  # On-demand (ADR-015 / G6); default off = $0 idle. Module auto-creates the Standard public IP.
        virtual_network_gateway_express_route = false
        virtual_network_gateway_vpn           = var.enable_vpn_gateway  # ADR-042: default off; GatewaySubnet is module-gated with the gateway
        private_dns_zones                     = false                   # Managed in Section 4 (Private Endpoints + DNS)
        private_dns_resolver                  = var.enable_dns_resolver # ADR-042: default off; dns-resolver-outbound subnet stays (free, keeps delegation)
        nat_gateway                           = false
      }

      hub_virtual_network = {
        name          = "vnet-hub-primary-${var.org_prefix}-${var.environment}"
        address_space = [var.hub_primary_address_space]

        subnets = {
          dns-resolver-outbound = {
            name             = "snet-dns-resolver-outbound"
            address_prefixes = [local.hub_primary_dns_outbound_prefix]
            # Azure requires the DNS Private Resolver outbound endpoint subnet to be
            # delegated to Microsoft.Network/dnsResolvers. Creating the outbound endpoint
            # auto-adds this delegation + service-association-link; declaring it here keeps
            # Terraform's desired state in sync so it does not try to strip the delegation
            # on subsequent applies (ARM 400 SubnetMissingRequiredDelegation). The module
            # emits only serviceName; ARM auto-populates the required actions.
            delegations = [{
              name = "Microsoft.Network.dnsResolvers"
              service_delegation = {
                name = "Microsoft.Network/dnsResolvers"
              }
            }]
          }
        }
      }

      firewall = {
        sku_tier              = "Premium"
        subnet_address_prefix = local.hub_primary_firewall_prefix
        # No forced tunneling to on-premises in this POC; management IP not required.
        management_ip_enabled = false
      }

      firewall_policy = {
        sku = "Premium"
        # DEVIATION: tls_certificate omitted - Key Vault created in Section 8 Batch 3.
        # Add tls_certificate.key_vault_secret_id once platform/security is deployed.
        intrusion_detection = {
          mode = "Alert"
        }
      }

      # On-demand Azure Bastion (ADR-015 / gap-closure G6). Honoured only when
      # enabled_resources.bastion (= var.enable_bastion) is true; the config below is
      # otherwise inert. /26 AzureBastionSubnet (module names the subnet automatically)
      # carved from the primary hub space; the module auto-provisions the Standard
      # public IP (no public_ip block required). Secondary hub stays bastion = false.
      bastion = {
        sku                   = "Standard"
        subnet_address_prefix = local.hub_primary_bastion_prefix
      }

      virtual_network_gateways = {
        subnet_address_prefix = local.hub_primary_gateway_prefix
        vpn = {
          sku = "VpnGw1AZ"
        }
      }

      private_dns_resolver = {
        subnet_address_prefix = local.hub_primary_dns_inbound_prefix
        outbound_endpoints = {
          default = {
            subnet_name = "snet-dns-resolver-outbound"
          }
        }
      }
    }

    secondary = {
      location          = var.secondary_location
      default_parent_id = azurerm_resource_group.connectivity_secondary.id

      enabled_resources = {
        firewall                              = var.enable_firewall # ADR-042: one flag covers both hubs - the mesh routes reference both firewalls, so they return as a pair
        firewall_policy                       = var.enable_firewall # ADR-042: policy travels with the firewall
        bastion                               = false
        virtual_network_gateway_express_route = false
        virtual_network_gateway_vpn           = false # Primary VPN only; reduces idle POC cost
        private_dns_zones                     = false
        private_dns_resolver                  = false # DNS queries route back to primary resolver
        nat_gateway                           = false
      }

      hub_virtual_network = {
        name          = "vnet-hub-secondary-${var.org_prefix}-${var.environment}"
        address_space = [var.hub_secondary_address_space]
      }

      firewall = {
        sku_tier              = "Premium"
        subnet_address_prefix = local.hub_secondary_firewall_prefix
        management_ip_enabled = false
      }

      firewall_policy = {
        sku = "Premium"
        intrusion_detection = {
          mode = "Alert"
        }
      }
    }
  }

  tags = local.common_tags
}
