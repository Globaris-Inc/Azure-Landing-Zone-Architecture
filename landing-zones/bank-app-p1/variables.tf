# Purpose: Input variables for the bank-app-p1 landing zone root module (banking
#          application spoke - B1 network foundation + B2 Kubernetes platform inputs).
# Section: Banking waves B1-B2 (docs/banking-platform-design.md,
#          docs/b2-aks-platform-design.md)
# Last updated: 2026-07-18

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
# Kubernetes platform (wave B2 - ADR-043 / ADR-044)
# ---------------------------------------------------------------------------

variable "enable_kubernetes_platform" {
  description = "Deploy the wave B2 Kubernetes platform: private AKS cluster (Standard tier, 3x D2s_v4 across zones 1-3, CNI Overlay, Entra-only auth, outbound_type userDefinedRouting) plus the Premium ACR with private endpoint (ADR-043). Default false per the LESSON 42 shippable-network-only flag pattern. ORDERING (ADR-044): flip only after platform/connectivity is applied with enable_firewall = true and the primary firewall private IP is confirmed as 10.0.0.4 - AKS nodes cannot bootstrap through a blackholed default route."
  type        = bool
  default     = false
}

variable "aks_admin_group_object_ids" {
  description = "Entra ID group object IDs granted the cluster admin role via the AKS aad_profile (Azure RBAC enabled, local accounts disabled - ADR-043). REQUIRED when enable_kubernetes_platform is true; no default on purpose. The value arrives via TF_VAR_aks_admin_group_object_ids from the repo secret in CI (poc.secret.tfvars locally) - never commit the GUIDs."
  type        = list(string)
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
