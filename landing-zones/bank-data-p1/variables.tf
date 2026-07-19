# Purpose: Input variables for the bank-data-p1 landing zone root module (banking
#          data + AI spoke - network foundation at wave B1; data platform flags at
#          wave B5).
# Section: Banking wave B1 - banking network foundation (docs/banking-platform-design.md)
#          + wave B5 - data platform (docs/b5-data-platform-design.md; ADR-048)
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
  description = "Primary Azure region for bank-data-p1 resources."
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
  description = "CIDR block for the bank-data-p1 spoke VNet. All subnet prefixes are computed from this block. 10.32.0.0/16 is ARCHITECT-CONFIRMED (B1 amendment ruling): 10.31.0.0/16 is RESERVED for the bank-app DR spoke (centralus, design-only). Full banking allocation table in this root's README and main.tf header."
  type        = string
  default     = "10.32.0.0/16"
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
  description = "Private IP of the primary Azure Firewall. Used as the 0.0.0.0/0 next-hop for all bank-data-p1 subnets."
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
# Wave B5 - data platform flags (docs/b5-data-platform-design.md; ADR-048)
# ---------------------------------------------------------------------------

variable "enable_data_platform" {
  description = "Deploy the wave B5 data platform: Databricks Premium workspace (VNet-injected, NPIP, default storage firewall + access connector), the subscription-scoped expiring dbstorage Waiver exemption + 300s sleep, and the ADLS Gen2 data lake (HNS, PE-only blob+dfs, raw filesystem). Default false (LESSON 42 flag pattern); the reviewed-commit flag supply lives in envs/poc.tfvars. ~$1/day while enabled with no clusters (design doc section 9)."
  type        = bool
  default     = false
}

variable "enable_fabric_capacity" {
  description = "Deploy the Microsoft Fabric F2 capacity (fabric.tf). SEPARATE flag from enable_data_platform because Fabric carries an independent offer-availability risk and the OQ-045 admin-principal dependency: stays false until OQ-045 supplies fabric_admin_members (empty-list ARM acceptance is UNVERIFIED). Deploys ACTIVE at ~$0.36/hr; ruled posture is suspend same-day post-QA (ADR-048)."
  type        = bool
  default     = false

  # Code-enforces the OQ-045 coupling (reviewer finding, B5 batch): the flag must
  # not reach ARM with an empty admin list - empty-list PUT acceptance is
  # UNVERIFIED (design doc section 2) and a capacity without an admin is
  # unmanageable in the Fabric portal. Cross-variable validation requires
  # terraform >= 1.9; this root's required_version floor is >= 1.9 (providers.tf).
  validation {
    condition     = var.enable_fabric_capacity == false || length(var.fabric_admin_members) > 0
    error_message = "enable_fabric_capacity = true requires a non-empty fabric_admin_members list (OQ-045: supply the capacity admin principal via TF_VAR_fabric_admin_members / poc.secret.tfvars). Empty-list ARM acceptance is unverified - the flag stays false until OQ-045 resolves."
  }
}

variable "fabric_location" {
  description = "Azure region for the Fabric capacity ONLY. DEVIATION from the estate primary_location: Fabric CU quota is 0 in eastus2 on this subscription/offer while centralus has availability (portal-verified 2026-07-19, B5 pre-clearance addendum). Fabric capacities are a control-plane/CU-billing surface with no VNet or data-plane coupling to the eastus2 spoke at B5 (no Fabric items exist), so the region split carries no network impact. Region alignment is revisited at wave B-R."
  type        = string
  default     = "centralus"
}

variable "fabric_admin_members" {
  description = "Administrator identities for the Fabric capacity - UPN format for Entra users, object ID for service principals. Supplied via TF_VAR_fabric_admin_members from a GitHub Actions variable (poc.secret.tfvars locally) once OQ-045 resolves; never committed (no personal values in the repo). Default [] is safe only because enable_fabric_capacity gates the resource off until the value arrives."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
