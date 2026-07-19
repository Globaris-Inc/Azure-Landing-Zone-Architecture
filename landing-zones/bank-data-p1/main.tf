# Purpose: bank-data-p1 landing zone - banking data + AI spoke (Databricks + ADLS Gen2
#          wave B5; Foundry/AI Search/Document Intelligence wave B6). Wave B1 ships the
#          NETWORK FOUNDATION ONLY (LESSON 42 shippable-network-only pattern): VNet,
#          subnets, NSGs, firewall UDR, hub peering, DNS links, VNet flow log. NO
#          workload resources.
# Section: Banking wave B1 - banking network foundation (docs/banking-platform-design.md
#          sections 2.0, 2.3-2.4; placement per OQ-035 resolution)
# Last updated: 2026-07-18 (wave B5: NSG drift guard on nsg-databricks, ADR-048;
#          workload resources live in databricks.tf / datalake.tf / fabric.tf)
#
# Architecture:
#   - Spoke VNet (default 10.32.0.0/16, eastus2) peered to primary hub VNet
#   - snet-databricks-host (/24)      - Databricks host ("public") subnet, delegated to
#                                       Microsoft.Databricks/workspaces (wave B5 VNet injection)
#   - snet-databricks-container (/24) - Databricks container ("private") subnet, same delegation
#   - snet-private-endpoints (/24)    - private endpoints (ADLS blob/dfs, Databricks
#                                       front/back-end, Foundry, AI Search etc.)
#   - All subnets carry the 0.0.0.0/0 -> primary firewall UDR and an NSG
#
# Databricks VNet-injection subnet requirements (verified against Microsoft Learn
# /azure/databricks/security/network/classic/vnet-inject, 2026-07-15):
#   - Two DEDICATED subnets (host + container), minimum /26 each (these are /24),
#     not shared with any other resource or workspace.
#   - Both subnets delegated to Microsoft.Databricks/workspaces; the delegation lets
#     the service maintain its required NSG rules via a Network Intent Policy.
#   - An NSG must be attached to BOTH subnets. Azure Databricks auto-provisions and
#     manages its required rules (Microsoft.Databricks-workspaces_UseOnly_*) at
#     workspace creation (wave B5); only the estate baseline deny-Internet-inbound
#     rule is authored here, which does not conflict (LESSON 45 class checked: no
#     custom Deny-All that would shadow required intra-VNet allows).
#   - Egress via UDR (secure cluster connectivity + firewall) is supported; the
#     required firewall allowances for the Databricks control plane ship at wave
#     B5 as rcg-dbx-egress-primary (service-tag-only rules) in
#     platform/connectivity/firewall_rules_databricks.tf (ADR-048 - the B1-parked
#     caveat CLOSES there).
#
# Address space: ARCHITECT-CONFIRMED (B1 amendment ruling). Banking allocation table:
#   10.30.0.0/16 - bank-app-p1 (eastus2, landing-zones/bank-app-p1)
#   10.31.0.0/16 - RESERVED bank-app DR (centralus, design-only, NOT deployed)
#   10.32.0.0/16 - bank-data-p1 (eastus2, THIS root)
#   10.33.0.0/16 - RESERVED bank-data DR (centralus, design-only, NOT deployed)
# Non-overlapping with the estate: hubs 10.0/16 + 10.1/16, identity 10.2.0.0/24,
# spokes 10.10/16, 10.11/16, 10.20/16.

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "bank-data-p1"
      Owner              = "platform-team"
      Workload           = "bank-data-p1"
      DataClassification = "Confidential"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
    },
    var.tags
  )

  # Subnet prefixes computed from spoke_address_space (default 10.32.0.0/16).
  snet_dbx_host      = cidrsubnet(var.spoke_address_space, 8, 0) # /24 (10.32.0.0/24 at default) - Databricks host subnet (min /26 required; /24 matches estate sizing)
  snet_dbx_container = cidrsubnet(var.spoke_address_space, 8, 1) # /24 (10.32.1.0/24 at default) - Databricks container subnet
  snet_pe            = cidrsubnet(var.spoke_address_space, 8, 2) # /24 (10.32.2.0/24 at default) - private endpoints
}

# ---------------------------------------------------------------------------
# Resource Groups (4 per spoke - network, shared, workload, monitoring;
# estate spoke template shape. Workload waves B5-B6 land into shared/workload.)
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "network" {
  name     = "rg-bank-data-p1-network-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-bank-data-p1-shared-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "workload" {
  name     = "rg-bank-data-p1-workload-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-bank-data-p1-monitoring-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Network Security Groups
# ---------------------------------------------------------------------------

# NSG for the private-endpoint subnet. Baseline deny-Internet-inbound
# (belt-and-suspenders; the firewall UDR is the primary control).
resource "azurerm_network_security_group" "spoke" {
  name                = "nsg-spoke-bank-data-p1-${var.org_prefix}-${var.environment}"
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

# Dedicated NSG for BOTH Databricks subnets (host + container). Databricks
# recommends a workspace-dedicated NSG; the service injects and owns its required
# rules (Microsoft.Databricks-workspaces_UseOnly_*) via the subnet delegation's
# Network Intent Policy at workspace creation (wave B5). Do NOT author or modify
# those rules here. Only the estate baseline deny-Internet-inbound is set; worker
# to worker traffic rides the default AllowVnetInBound/OutBound rules.
resource "azurerm_network_security_group" "databricks" {
  name                = "nsg-databricks-bank-data-p1-${var.org_prefix}-${var.environment}"
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
    description                = "Belt-and-suspenders deny; secure cluster connectivity (NPIP) needs no inbound from Internet."
  }

  tags = local.common_tags

  # Wave B5 NSG drift guard (ADR-048 / design doc section 3.4): at workspace
  # create the Databricks RP injects its required rules
  # (Microsoft.Databricks-workspaces_UseOnly_*) into THIS NSG via the subnet
  # delegation's Network Intent Policy. Inline security_rule blocks are
  # authoritative, so without this guard every later apply would try to strip
  # the RP rules - a permanent fight with the intent policy. The one authored
  # baseline rule above is static; ignoring rule drift here is the correct
  # steady state. The spoke NSG is untouched.
  lifecycle {
    ignore_changes = [security_rule]
  }
}

# ---------------------------------------------------------------------------
# Route Table - default route forces all spoke traffic through Azure Firewall.
# Applied to ALL subnets. Databricks egress-with-UDR (secure cluster connectivity)
# is supported; the firewall network/application allowances for the Databricks
# control plane (and any service-tag route requirements) are verified at the wave
# B5 pre-clearance BEFORE the workspace apply.
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "spoke" {
  name                          = "rt-spoke-bank-data-p1-${var.org_prefix}-${var.environment}"
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
# freshness per OQ-017. Interface verified against the committed estate usage
# (delegations shape proven on corp-a1 snet-integration, Microsoft.Web/serverFarms).
# ---------------------------------------------------------------------------

module "spoke_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.17.1"

  name          = "vnet-spoke-bank-data-p1-${var.org_prefix}-${var.environment}"
  parent_id     = azurerm_resource_group.network.id # v0.17.1: parent_id (RG resource ID) replaces resource_group_name
  location      = var.primary_location
  address_space = [var.spoke_address_space]

  subnets = {
    databricks-host = {
      name             = "snet-databricks-host"
      address_prefixes = [local.snet_dbx_host]

      # Delegation required for Databricks VNet injection; ARM populates the
      # delegated actions (join/prepareNetworkPolicies/unprepareNetworkPolicies)
      # for the service. Same delegation shape as corp-a1 snet-integration.
      delegations = [{
        name = "delegation-databricks"
        service_delegation = {
          name = "Microsoft.Databricks/workspaces"
        }
      }]

      route_table = {
        id = azurerm_route_table.spoke.id
      }

      network_security_group = {
        id = azurerm_network_security_group.databricks.id
      }
    }

    databricks-container = {
      name             = "snet-databricks-container"
      address_prefixes = [local.snet_dbx_container]

      delegations = [{
        name = "delegation-databricks"
        service_delegation = {
          name = "Microsoft.Databricks/workspaces"
        }
      }]

      route_table = {
        id = azurerm_route_table.spoke.id
      }

      network_security_group = {
        id = azurerm_network_security_group.databricks.id
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
  name                      = "peer-bank-data-p1-to-primary-hub"
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
  name                      = "peer-primary-hub-to-bank-data-p1"
  resource_group_name       = var.primary_hub_rg_name
  virtual_network_name      = var.primary_hub_vnet_name
  remote_virtual_network_id = module.spoke_vnet.resource_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}
