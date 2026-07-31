# Purpose: bank-app-p1 landing zone - banking application spoke (AKS + ACR + integration
#          tier land here in waves B2-B4). Wave B1 ships the NETWORK FOUNDATION ONLY
#          (LESSON 42 shippable-network-only pattern): VNet, subnets, NSGs, firewall UDR,
#          hub peering, DNS links, VNet flow log. NO workload resources.
# Section: Banking wave B1 - banking network foundation (docs/banking-platform-design.md
#          sections 2.0-2.2; placement per OQ-035 resolution). Wave B4 delta: snet-apim
#          route-table swap + service endpoints (ADR-047, docs/b4-apim-platform-design.md)
# Last updated: 2026-07-18
#
# Architecture:
#   - Spoke VNet (default 10.30.0.0/16, centralus) peered to primary hub VNet
#   - snet-aks-nodes (/24)         - AKS node pools (wave B2, Azure CNI Overlay,
#                                    outbound type userDefinedRouting via the hub firewall)
#   - snet-apim (/24)              - APIM Developer, internal VNet mode (wave B4);
#                                    NSG carries the documented stv2 required rules
#   - snet-private-endpoints (/24) - private endpoints for ACR/Event Hubs/Service Bus etc.
#   - All subnets carry the 0.0.0.0/0 -> primary firewall UDR (see APIM caveat on the
#     route table below) and an NSG
#
# Address space: ARCHITECT-CONFIRMED (B1 amendment ruling). Banking allocation table:
#   10.30.0.0/16 - bank-app-p1 (centralus, THIS root)
#   10.31.0.0/16 - RESERVED bank-app DR (eastus2, design-only, NOT deployed)
#   10.32.0.0/16 - bank-data-p1 (centralus, landing-zones/bank-data-p1)
#   10.33.0.0/16 - RESERVED bank-data DR (eastus2, design-only, NOT deployed)
# Non-overlapping with the estate: hubs 10.0/16 + 10.1/16, identity 10.2.0.0/24,
# spokes 10.10/16, 10.11/16, 10.20/16.

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "bank-app-p1"
      Owner              = "platform-team"
      Workload           = "bank-app-p1"
      DataClassification = "Confidential"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
    },
    var.tags
  )

  # Subnet prefixes computed from spoke_address_space (default 10.30.0.0/16).
  snet_aks_nodes = cidrsubnet(var.spoke_address_space, 8, 0) # /24 (10.30.0.0/24 at default) - AKS node pools (CNI Overlay; ~250 node IPs, ample for POC)
  snet_apim      = cidrsubnet(var.spoke_address_space, 8, 1) # /24 (10.30.1.0/24 at default) - APIM internal mode (min /29 required; /24 matches estate subnet sizing)
  snet_pe        = cidrsubnet(var.spoke_address_space, 8, 2) # /24 (10.30.2.0/24 at default) - private endpoints
}

# ---------------------------------------------------------------------------
# Resource Groups (4 per spoke - network, shared, workload, monitoring;
# estate spoke template shape. Workload waves B2-B4 land into shared/workload.)
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "network" {
  name     = "rg-bank-app-p1-network-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-bank-app-p1-shared-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "workload" {
  name     = "rg-bank-app-p1-workload-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-bank-app-p1-monitoring-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Network Security Groups
# ---------------------------------------------------------------------------

# NSG for the AKS node and private-endpoint subnets. Baseline deny-Internet-inbound
# (belt-and-suspenders; the firewall UDR is the primary control). AKS (private
# cluster, wave B2) needs no inbound Internet rules; intra-VNet and AzureLoadBalancer
# traffic is covered by the default NSG rules.
resource "azurerm_network_security_group" "spoke" {
  name                = "nsg-spoke-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.primary_location

  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
    description                = "Belt-and-suspenders deny; firewall UDR is the primary control."
  }

  tags = local.common_tags
}

# NSG for the APIM subnet. Carries the two REQUIRED inbound rules for APIM stv2
# VNet injection (verified against Microsoft Learn virtual-network-reference,
# 2026-07-15): TCP 3443 from the ApiManagement service tag (management endpoint)
# and TCP 6390 from AzureLoadBalancer (infrastructure load balancer). Internal-mode
# client traffic (443 from VirtualNetwork) is covered by the default AllowVnetInBound
# rule. Wave B4 re-verifies the full recommended set at its pre-clearance.
resource "azurerm_network_security_group" "apim" {
  name                = "nsg-apim-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.primary_location

  security_rule {
    name                       = "Allow-ApiManagement-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
    description                = "Required for APIM stv2 management endpoint (control plane)."
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
    description                = "Required for the Azure infrastructure load balancer on APIM stv2."
  }

  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
    description                = "Belt-and-suspenders deny; internal-mode APIM has no public frontend."
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Route Table - default route forces all spoke traffic through Azure Firewall.
# WAVE B4 CAVEAT RESOLVED (ADR-047, docs/b4-apim-platform-design.md section 5):
# while enable_api_platform is true, snet-apim swaps to the dedicated rt-apim
# (apim.tf) carrying the same 0.0.0.0/0 -> firewall route PLUS the required
# ApiManagement-service-tag -> Internet management return route. This shared table
# stays on the AKS and PE subnets ONLY and deliberately does NOT get the service-tag
# route (it would bypass the firewall for those subnets too).
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "spoke" {
  name                          = "rt-spoke-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name           = azurerm_resource_group.network.name
  location                      = var.primary_location
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.primary_firewall_private_ip
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Spoke VNet
# Module: Azure/avm-res-network-virtualnetwork/azurerm v0.17.1
# Pin matches the estate spokes (corp-a1/corp-a2/online-p1) - consistency beats
# freshness per OQ-017. Interface verified against the committed estate usage.
# ---------------------------------------------------------------------------

module "spoke_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.17.1"

  name          = "vnet-spoke-bank-app-p1-${var.org_prefix}-${var.environment}"
  parent_id     = azurerm_resource_group.network.id # v0.17.1: parent_id (RG resource ID) replaces resource_group_name
  location      = var.primary_location
  address_space = [var.spoke_address_space]

  subnets = {
    aks-nodes = {
      name             = "snet-aks-nodes"
      address_prefixes = [local.snet_aks_nodes]

      # WAVE B2 INHERITANCE (architect ruling, see README): the AKS CNI Overlay pod
      # CIDR MUST be pinned explicitly at cluster create (recommended 192.168.0.0/16),
      # never left to the module default.

      route_table = {
        id = azurerm_route_table.spoke.id
      }

      network_security_group = {
        id = azurerm_network_security_group.spoke.id
      }
    }

    apim = {
      name             = "snet-apim"
      address_prefixes = [local.snet_apim]

      # WAVE B4 (ADR-047): route table swap + service endpoints, both ternary on
      # enable_api_platform. The subnet is an azapi_resource in the pinned 0.17.1
      # module (Microsoft.Network/virtualNetworks/subnets@2024-07-01) - routeTable.id
      # and serviceEndpoints are body properties, so BOTH changes are a single
      # in-place PUT update (NO subnet replace; verified in the module subnet source).
      route_table = {
        id = var.enable_api_platform ? azurerm_route_table.apim["main"].id : azurerm_route_table.spoke.id
      }

      # Microsoft strongly recommends these four on the APIM subnet: the instance's
      # own managed SQL/Storage/EH/KV dependency traffic rides the Azure backbone
      # instead of the forced tunnel (design doc section 5b). Posture note in
      # ADR-047: this exempts APIM PLATFORM dependency traffic from AZFW
      # inspection, not API/workload traffic.
      service_endpoints_with_location = var.enable_api_platform ? [
        { service = "Microsoft.Sql" },
        { service = "Microsoft.Storage" },
        { service = "Microsoft.EventHub" },
        { service = "Microsoft.KeyVault" },
      ] : null

      network_security_group = {
        id = azurerm_network_security_group.apim.id
      }
    }

    private-endpoints = {
      name             = "snet-private-endpoints"
      address_prefixes = [local.snet_pe]

      # Required to allow Private Endpoint NICs in this subnet.
      private_endpoint_network_policies = "Disabled"

      route_table = {
        id = azurerm_route_table.spoke.id
      }

      network_security_group = {
        id = azurerm_network_security_group.spoke.id
      }
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# VNet Peering - spoke <-> primary hub (bidirectional, cross-subscription)
# ---------------------------------------------------------------------------

# Spoke -> Hub (in Landing Zones subscription, default provider)
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-bank-app-p1-to-primary-hub"
  resource_group_name       = azurerm_resource_group.network.name
  virtual_network_name      = module.spoke_vnet.name
  remote_virtual_network_id = var.primary_hub_vnet_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

# Hub -> Spoke return peering (in Connectivity subscription, connectivity alias provider)
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider                  = azurerm.connectivity
  name                      = "peer-primary-hub-to-bank-app-p1"
  resource_group_name       = var.primary_hub_rg_name
  virtual_network_name      = var.primary_hub_vnet_name
  remote_virtual_network_id = module.spoke_vnet.resource_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}
