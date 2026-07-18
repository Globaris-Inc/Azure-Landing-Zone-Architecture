# Purpose: Input variables for the Connectivity platform root module.
# Section: 8 - Standard Platform Components (+ Banking wave B2 AKS egress rules, ADR-044)
# Last updated: 2026-07-18 (ADR-044: aks_egress_source_prefixes for the AKS rule collection group)

variable "tenant_id" {
  description = "Azure Active Directory tenant ID."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "Subscription ID for the Connectivity platform subscription."
  type        = string
}

variable "primary_location" {
  description = "Primary Azure region for the primary hub VNet and firewall."
  type        = string
  default     = "eastus2"
}

variable "secondary_location" {
  description = "Secondary / DR Azure region for the secondary hub VNet and firewall."
  type        = string
  default     = "centralus"
}

variable "org_prefix" {
  description = "Short organisation identifier used in resource naming (e.g. 'globaris')."
  type        = string
}

variable "environment" {
  description = "Deployment environment label used in resource names and tags (e.g. 'poc')."
  type        = string
  default     = "poc"
}

# ---------------------------------------------------------------------------
# Network addressing
# ---------------------------------------------------------------------------

variable "hub_primary_address_space" {
  description = "CIDR block for the primary hub VNet. All primary hub subnet prefixes are computed from this block."
  type        = string
  default     = "10.0.0.0/16"
}

variable "hub_secondary_address_space" {
  description = "CIDR block for the secondary (DR) hub VNet. All secondary hub subnet prefixes are computed from this block."
  type        = string
  default     = "10.1.0.0/16"
}

# ---------------------------------------------------------------------------
# Feature flags
# ---------------------------------------------------------------------------

variable "enable_ddos_standard" {
  description = "Enable Azure DDoS Network Protection (Standard) on hub VNets. Disabled by default - DDoS Standard costs ~$2,944/mo and is not required for the POC."
  type        = bool
  default     = false
}

variable "enable_bastion" {
  description = "Deploy Azure Bastion (Standard SKU) in the PRIMARY hub on demand. Default false so idle cost is $0; operators set true + apply (deploy.yml) to bring Bastion up for no-public-IP management access, false + apply to remove it (~+$140/mo while enabled). Secondary hub never gets Bastion. See ADR-015 / gap-closure G6."
  type        = bool
  default     = false
}

variable "enable_firewall" {
  description = "Deploy the Azure Firewall Premium pair (one per hub) plus their firewall policies, public IPs, AzureFirewallSubnets, and the module-gated hub route tables. Default false per ADR-042 (paid appliances deferred until a workload wave needs real spoke egress, e.g. B2 AKS UDR); ~$2.55k/mo for the Premium pair + PIPs while enabled."
  type        = bool
  default     = false
}

variable "aks_egress_source_prefixes" {
  description = "Source address prefixes for the AKS egress rules in rcg-aks-egress-primary (firewall_rules_aks.tf, ADR-044). Defaults to the bank-app-p1 snet-aks-nodes carve (10.30.0.0/24 - see the banking allocation table in envs/poc.tfvars). Only honoured while enable_firewall is true."
  type        = list(string)
  default     = ["10.30.0.0/24"]
}

variable "enable_vpn_gateway" {
  description = "Deploy the VpnGw1AZ active-active VPN Gateway (and its GatewaySubnet) in the PRIMARY hub. Default false per ADR-042 - no S2S/P2S consumer exists in the POC; ~$260/mo while enabled."
  type        = bool
  default     = false
}

variable "enable_dns_resolver" {
  description = "Deploy the DNS Private Resolver (inbound + outbound endpoints) in the PRIMARY hub. Default false per ADR-042 - spokes resolve private-endpoint zones via VNet links + Azure-provided DNS; ~$365/mo while enabled."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
