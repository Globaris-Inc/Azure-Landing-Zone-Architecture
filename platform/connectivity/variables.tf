# Purpose: Input variables for the Connectivity platform root module.
# Section: 8 - Standard Platform Components
# Last updated: 2026-06-27 (G6: enable_bastion on-demand flag - ADR-015)

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

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
