# Purpose: Identity subscription network plane — resource groups, identity VNet,
#          Entra DS subnet + NSG (Microsoft-mandated rules), and bidirectional
#          peering to the primary hub. (Section 8 — G1 / Gap-Closure Wave 3 / ADR-010)
# Section: 8 — Standard Platform Components (Identity subscription)
# Last updated: 2026-06-28
#
# All resources here are gated on identity_mode != "none" via the static boolean
# local.identity_enabled (LESSON 5 — gate on a static bool, never on an unknown ID)
# and land in the Identity subscription via the azurerm.identity provider alias.
# The hub-side return peering uses the azurerm.connectivity alias (mirrors the
# landing-zones/corp-a1 spoke pattern).

# ---------------------------------------------------------------------------
# Locals — gating + naming + subnet math
# ---------------------------------------------------------------------------

locals {
  # Static booleans — known at plan time, safe to drive count/for_each.
  identity_enabled = var.identity_mode != "none"
  entra_ds_enabled = var.identity_mode == "entra-ds"

  identity_common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "platform-identity"
      Owner              = "platform-team"
      Workload           = "identity-domain-services"
      DataClassification = "Confidential"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
      IdentityMode       = var.identity_mode
    },
    var.tags
  )

  # Entra DS lives in a dedicated subnet. Microsoft recommends a small dedicated
  # subnet with no NSG-blocking of the managed inbound flows. /27 carved from the
  # identity VNet space (default 10.2.0.0/24 → 10.2.0.0/27).
  snet_entra_ds = cidrsubnet(var.identity_vnet_address_space, 3, 0)
}

# ---------------------------------------------------------------------------
# Resource Groups (Identity subscription)
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "identity_network" {
  provider = azurerm.identity
  count    = local.identity_enabled ? 1 : 0

  name     = "rg-identity-network-${var.org_prefix}-${var.environment}"
  location = var.identity_location
  tags     = local.identity_common_tags
}

resource "azurerm_resource_group" "identity_aadds" {
  provider = azurerm.identity
  count    = local.identity_enabled ? 1 : 0

  name     = "rg-identity-aadds-${var.org_prefix}-${var.environment}"
  location = var.identity_location
  tags     = local.identity_common_tags
}

# ---------------------------------------------------------------------------
# Network Security Group — Entra DS subnet
#
# Rule set verified against the current Microsoft doc "Network considerations for
# Microsoft Entra Domain Services" (learn.microsoft.com, reviewed 2026-06-28):
#   - REQUIRED inbound: TCP 5986 from the AzureActiveDirectoryDomainServices
#     service tag — Entra DS management/synchronisation (PowerShell remoting).
#   - The managed service no longer requires the legacy CorpNetSaw/ports 443/3389
#     inbound rules that older guidance listed; those are intentionally omitted.
#   - TCP 636 (secure LDAP) is added ONLY if/when secure LDAP is enabled — left
#     out here because secure_ldap is disabled in this build (see domain-services.tf).
#   - A low-priority Deny-All-Inbound backstop sits below the allow rule.
# Outbound is left at Azure defaults (Entra DS needs broad managed outbound; do not
# restrict it on the DS subnet).
# UNVERIFIED: exact priority ordering is a local choice; the service-tag source and
# port 5986 are the load-bearing, doc-confirmed values.
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "entra_ds" {
  provider = azurerm.identity
  count    = local.identity_enabled ? 1 : 0

  name                = "nsg-identity-aadds-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.identity_network[0].name
  location            = var.identity_location

  # REQUIRED — Entra DS management traffic (synchronisation / monitoring).
  security_rule {
    name                       = "Allow-AADDS-Management-5986"
    priority                   = 301
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5986"
    source_address_prefix      = "AzureActiveDirectoryDomainServices"
    destination_address_prefix = "*"
    description                = "Microsoft-mandated: Entra DS management/sync (WinRM-HTTPS) from the AADDS service tag."
  }

  # Belt-and-suspenders deny backstop below the managed allow rule.
  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Default-deny backstop; the AADDS service-tag allow rule above takes precedence."
  }

  tags = local.identity_common_tags
}

# ---------------------------------------------------------------------------
# Identity VNet
# Module: Azure/avm-res-network-virtualnetwork/azurerm v0.17.1
# Repo pin (already in state across spokes). Confirmed against the existing
# landing-zones/corp-a1 call. CRITICAL: v0.17.1 takes parent_id (the RG resource
# ID), NOT resource_group_name (OQ-011 remediation lesson).
# ---------------------------------------------------------------------------

module "identity_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.17.1"

  providers = {
    azurerm = azurerm.identity
  }

  count = local.identity_enabled ? 1 : 0

  name          = "vnet-identity-${var.org_prefix}-${var.environment}"
  parent_id     = azurerm_resource_group.identity_network[0].id # v0.17.1: parent_id (RG resource ID)
  location      = var.identity_location
  address_space = [var.identity_vnet_address_space]

  subnets = {
    entra-ds = {
      name             = "snet-aadds"
      address_prefixes = [local.snet_entra_ds]

      network_security_group = {
        id = azurerm_network_security_group.entra_ds[0].id
      }
    }
  }

  tags = local.identity_common_tags
}

# ---------------------------------------------------------------------------
# VNet Peering — identity VNet <-> primary hub (bidirectional, cross-subscription)
# Mirrors the landing-zones/corp-a1 spoke_to_hub / hub_to_spoke pattern.
# ---------------------------------------------------------------------------

# Identity -> Hub (in Identity subscription, identity alias provider)
resource "azurerm_virtual_network_peering" "identity_to_hub" {
  provider = azurerm.identity
  count    = local.identity_enabled ? 1 : 0

  name                      = "peer-identity-to-primary-hub"
  resource_group_name       = azurerm_resource_group.identity_network[0].name
  virtual_network_name      = module.identity_vnet[0].name
  remote_virtual_network_id = var.primary_hub_vnet_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

# Hub -> Identity return peering (in Connectivity subscription, connectivity alias)
resource "azurerm_virtual_network_peering" "hub_to_identity" {
  provider = azurerm.connectivity
  count    = local.identity_enabled ? 1 : 0

  name                      = "peer-primary-hub-to-identity"
  resource_group_name       = var.primary_hub_rg_name
  virtual_network_name      = var.primary_hub_vnet_name
  remote_virtual_network_id = module.identity_vnet[0].resource_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}
