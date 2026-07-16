# Purpose: Input variables for the bank-app-p1 landing zone root module (banking
#          application spoke - network foundation only at wave B1).
# Section: Banking wave B1 - banking network foundation (docs/banking-platform-design.md)
# Last updated: 2026-07-16

# ---------------------------------------------------------------------------
# Subscription targeting
# ---------------------------------------------------------------------------

variable "landingzones_subscription_id" {
  description = "Subscription ID for the Landing Zones subscription (banking spoke placement per OQ-035)."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "Subscription ID for the Connectivity platform subscription (hub-to-spoke return peering and Private DNS zone links only)."
  type        = string
}

# ---------------------------------------------------------------------------
# Location + naming
# ---------------------------------------------------------------------------

variable "primary_location" {
  description = "Primary Azure region for bank-app-p1 resources."
  type        = string
  default     = "eastus2"
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
# Networking
# ---------------------------------------------------------------------------

variable "spoke_address_space" {
  description = "CIDR block for the bank-app-p1 spoke VNet. All subnet prefixes are computed from this block. 10.30.0.0/16 is ARCHITECT-CONFIRMED (B1 amendment ruling); 10.31.0.0/16 is RESERVED for the bank-app DR spoke (centralus, design-only). Full banking allocation table in this root's README and main.tf header."
  type        = string
  default     = "10.30.0.0/16"
}

variable "primary_hub_vnet_id" {
  description = "ARM resource ID of the primary hub VNet. From platform/connectivity output 'primary_hub_vnet_id'."
  type        = string
}

variable "primary_hub_vnet_name" {
  description = "Name of the primary hub VNet. Required for the hub-to-spoke return peering."
  type        = string
}

variable "primary_hub_rg_name" {
  description = "Resource group name of the primary hub VNet in the Connectivity subscription."
  type        = string
}

variable "primary_firewall_private_ip" {
  description = "Private IP of the primary Azure Firewall. Used as the 0.0.0.0/0 next-hop for all bank-app-p1 subnets."
  type        = string
}

# ---------------------------------------------------------------------------
# Private DNS (Section 4 pattern)
# ---------------------------------------------------------------------------

variable "private_dns_rg_name" {
  description = "Name of the resource group in the Connectivity subscription that holds all Private Link DNS zones. From platform/connectivity output 'private_dns_rg_name'."
  type        = string
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "platform_law_workspace_id" {
  description = "ARM resource ID of the platform Log Analytics workspace (eastus2, region-matched to this spoke - LESSON 43)."
  type        = string
}

variable "platform_law_customer_id" {
  description = "GUID (customer ID) of the platform Log Analytics workspace. Required for Traffic Analytics on the VNet flow log."
  type        = string
}

variable "flow_log_retention_days" {
  description = "Number of days to retain VNet flow log data in the storage account."
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# Policy exemptions (OQ-024 / ADR-028)
# ---------------------------------------------------------------------------

variable "enable_corp_policy_exemptions" {
  description = "Create the RG-scoped Waiver policy exemption for the corp-MG Deny-Public-Endpoints StorageDenyPaasPublicIP member on the flow-log storage account, which cannot be made compliant without breaking flow-log delivery. Default true; set false only if this spoke is moved out from under the corp MG or the governance changes (OQ-024)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
