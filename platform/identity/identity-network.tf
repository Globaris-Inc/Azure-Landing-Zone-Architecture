# Purpose: Identity subscription network plane — resource groups, identity VNet
#          (DNS servers derived from the AADDS subnet CIDR), Entra DS subnet + NSG
#          (Microsoft-mandated rules), and bidirectional peering to the primary
#          hub. (Section 8 — G1 / Gap-Closure Wave 3 / ADR-010, ADR-029)
# Section: 8 — Standard Platform Components (Identity subscription)
# Last updated: 2026-07-10
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
  # identity VNet space (default 10.2.0.0/24 → 10.2.0.0/27). This CIDR is also the
  # source of truth for the AADDS DC DNS IPs below.
  snet_entra_ds = cidrsubnet(var.identity_vnet_address_space, 3, 0)

  # Identity VNet DNS servers (ADR-029). When entra-ds is the identity mode, these are
  # DERIVED from the AADDS subnet CIDR (local.snet_entra_ds) rather than hardcoded:
  # Entra DS places its two managed domain controllers on the first two usable host
  # addresses of the DS subnet. Azure reserves the first four addresses of any subnet
  # (.0 network, .1-.3 gateway/DNS/reserved), so the DCs land on host offsets 4 and 5 -
  # e.g. for 10.2.0.0/27 that is 10.2.0.4 and 10.2.0.5. sort() gives a deterministic
  # ascending order so the value is stable across plans, and the wiring self-adjusts if
  # the VNet/subnet address space ever changes. The derivation reads ONLY static inputs
  # (the subnet CIDR + the static gate local), never a domain output, so there is no
  # VNet -> domain -> VNet dependency cycle. The derived fallback is gated on
  # local.entra_ds_enabled: for any other identity mode (e.g. the ad-ds stub) there are
  # no managed DCs at .4/.5, so we fall back to an empty list -> module dns_servers = null
  # -> Azure-default DNS. An operator can still override via var.identity_vnet_dns_servers
  # in ANY mode: a non-empty list always wins.
  identity_vnet_dns_servers = length(var.identity_vnet_dns_servers) > 0 ? var.identity_vnet_dns_servers : (
    local.entra_ds_enabled ? sort([
      cidrhost(local.snet_entra_ds, 4),
      cidrhost(local.snet_entra_ds, 5),
    ]) : []
  )
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
# Rule set verified against the current Microsoft docs "Network considerations for
# Microsoft Entra Domain Services" and "AADDS104 - Network error" (learn.microsoft.com,
# reviewed 2026-07-10 for ADR-029):
#   - REQUIRED inbound: TCP 5986 from the AzureActiveDirectoryDomainServices
#     service tag — Entra DS management/synchronisation (PowerShell remoting). This
#     equals Microsoft's own default `AllowPSRemoting` @301.
#   - The managed service no longer requires the legacy CorpNetSaw/ports 443/3389
#     inbound rules that older guidance listed; those are intentionally omitted.
#   - TCP 636 (secure LDAP) is added ONLY if/when secure LDAP is enabled — left
#     out here because secure_ldap is disabled in this build (see domain-services.tf).
#   - There is DELIBERATELY no custom deny-all inbound rule (ADR-029). Azure's
#     undeletable default rules AllowVnetInBound @65000, AllowAzureLoadBalancerInBound
#     @65001, and DenyAllInBound @65500 must remain in effect - Domain Services relies
#     on the first two for DC replication and the load-balancer health path, and a
#     custom low-priority deny-all overrides them and breaks AADDS (AADDS104). See the
#     inline comment on the rule set below and ADR-029.
# Outbound is left at Azure defaults (Entra DS needs broad managed outbound; do not
# restrict it on the DS subnet).
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

  # NO custom blanket deny-all inbound rule here - INTENTIONAL (ADR-029). A prior
  # `Deny-All-Inbound` @4000 rule sat numerically above Azure's undeletable default
  # rules `AllowVnetInBound` @65000 and `AllowAzureLoadBalancerInBound` @65001, so it
  # won evaluation and blocked the two flows Microsoft REQUIRES for the managed domain:
  # intra-VNet DC replication (AllowVnetInBound) and the internal load-balancer
  # management / health-probe path from 168.63.129.16 (AllowAzureLoadBalancerInBound).
  # That triggered the CRITICAL AADDS104 network-error alert and stranded the 2nd DC
  # (run 29055619749). MS Learn is explicit: alert-nsg says "delete any custom rules
  # that block required traffic", and network-considerations says "Domain Services also
  # relies on the Default Security rules AllowVnetInBound and AllowAzureLoadBalancerInBound"
  # and "Don't create or use an existing network security group with your own custom rules".
  # With no custom deny, Azure's defaults govern: AllowVnetInBound @65000,
  # AllowAzureLoadBalancerInBound @65001, DenyAllInBound @65500. Internet inbound is still
  # denied by the default @65500, so no protection is lost. DO NOT re-add a low-priority
  # deny-all "hardening" rule - it re-breaks AADDS. See ADR-029.

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

  # AADDS requires the identity VNet's DNS servers to point at the managed domain's
  # two domain-controller IPs; otherwise clients on the VNet cannot locate the
  # managed domain and it appears broken (a MANDATORY AADDS post-deploy step - MS
  # Learn: entra/identity/domain-services, "Update DNS settings for the Azure
  # virtual network"). ADR-029: we feed these through the module's OWN dns_servers
  # input, and the value comes from local.identity_vnet_dns_servers which is DERIVED
  # from the AADDS subnet CIDR (cidrhost offsets 4/5 of local.snet_entra_ds), NOT a
  # reference to the domain output - so there is NO VNet -> domain -> VNet dependency
  # cycle. Because the module writes real dhcpOptions.dnsServers into its VNet body,
  # there is a single writer of this field - no second resource re-asserting an
  # explicit `dhcpOptions: null` to fight it (azapi ignore_null_property defaults
  # false, so passing null here would re-null the field every apply and revert DNS to
  # default). The live/state order is descending (10.2.0.5, 10.2.0.4) whereas sort()
  # yields ascending (10.2.0.4, 10.2.0.5), so the next apply produces a ONE-TIME
  # cosmetic in-place reorder of dnsServers, then 0 changes forever after. DNS
  # resolver order is not functionally significant here so this is acceptable.
  dns_servers = length(local.identity_vnet_dns_servers) > 0 ? {
    dns_servers = local.identity_vnet_dns_servers
  } : null

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
