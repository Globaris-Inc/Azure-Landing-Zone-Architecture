# Purpose: Input variables for the online-p1 landing zone root module (internet-facing spoke).
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-05-14

# ---------------------------------------------------------------------------
# Subscription targeting
# ---------------------------------------------------------------------------

variable "landingzones_subscription_id" {
  description = "Subscription ID for the Landing Zones subscription."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "Subscription ID for the Connectivity platform subscription (hub-to-spoke return peering only)."
  type        = string
}

# ---------------------------------------------------------------------------
# Location + naming
# ---------------------------------------------------------------------------

variable "primary_location" {
  description = "Primary Azure region for online-p1 resources."
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
  description = "CIDR block for the online-p1 spoke VNet. All subnet prefixes are computed from this block."
  type        = string
  default     = "10.20.0.0/16"
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
  description = "Private IP of the primary Azure Firewall. Used as next-hop for non-App-Gateway subnets."
  type        = string
}

# ---------------------------------------------------------------------------
# App Gateway WAF
# ---------------------------------------------------------------------------

variable "appgw_capacity" {
  description = "Fixed instance count for the Application Gateway WAF_v2. Min 1 for POC; increase for production."
  type        = number
  default     = 1
}

variable "waf_mode" {
  description = "WAF mode: Detection (log only) or Prevention (block). Prevention is the production default."
  type        = string
  default     = "Prevention"

  validation {
    condition     = contains(["Detection", "Prevention"], var.waf_mode)
    error_message = "waf_mode must be 'Detection' or 'Prevention'."
  }
}

# ---------------------------------------------------------------------------
# Private DNS (Section 4)
# ---------------------------------------------------------------------------

variable "private_dns_rg_name" {
  description = "Name of the resource group in the Connectivity subscription that holds all Private Link DNS zones. From platform/connectivity output 'private_dns_rg_name'."
  type        = string
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "platform_law_workspace_id" {
  description = "ARM resource ID of the platform Log Analytics workspace."
  type        = string
}

variable "platform_law_customer_id" {
  description = "GUID (customer ID) of the platform Log Analytics workspace. Required for Traffic Analytics in NSG flow logs."
  type        = string
}

variable "platform_action_group_id" {
  description = "ARM resource ID of the platform Monitor Action Group."
  type        = string
}

variable "flow_log_retention_days" {
  description = "Number of days to retain NSG flow log data in the storage account."
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
