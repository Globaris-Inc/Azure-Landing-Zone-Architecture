# Purpose: Input variables for the corp-a1 landing zone root module.
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-05-14

# ---------------------------------------------------------------------------
# Subscription targeting
# ---------------------------------------------------------------------------

variable "landingzones_subscription_id" {
  description = "Subscription ID for the Landing Zones subscription. All corp-a1 spoke resources deploy here."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "Subscription ID for the Connectivity platform subscription. Used only for the hub-to-spoke return VNet peering."
  type        = string
}

# ---------------------------------------------------------------------------
# Location + naming
# ---------------------------------------------------------------------------

variable "primary_location" {
  description = "Primary Azure region for corp-a1 resources."
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
  description = "CIDR block for the corp-a1 spoke VNet. All subnet prefixes are computed from this block."
  type        = string
  default     = "10.10.0.0/16"
}

variable "primary_hub_vnet_id" {
  description = "ARM resource ID of the primary hub VNet (eastus2). From platform/connectivity output 'primary_hub_vnet_id'."
  type        = string
}

variable "primary_hub_vnet_name" {
  description = "Name of the primary hub VNet. From platform/connectivity output 'primary_hub_vnet_name'. Required for the hub-to-spoke return peering."
  type        = string
}

variable "primary_hub_rg_name" {
  description = "Resource group name that contains the primary hub VNet. Required for the hub-to-spoke return peering in the Connectivity subscription."
  type        = string
}

variable "primary_firewall_private_ip" {
  description = "Private IP address of the primary Azure Firewall Premium. Used as the next-hop in the spoke default route table."
  type        = string
}

# ---------------------------------------------------------------------------
# Workload — SQL
# ---------------------------------------------------------------------------

variable "sql_aad_admin_object_id" {
  description = "Object ID of the Entra ID group or user to set as the SQL Server Azure AD administrator."
  type        = string
}

variable "sql_aad_admin_login" {
  description = "Display name or UPN of the Entra ID SQL administrator (used as login value in the azuread_administrator block)."
  type        = string
}

# ---------------------------------------------------------------------------
# Backup / Disaster Recovery (Recovery Services Vault)
# ---------------------------------------------------------------------------

variable "rsv_storage_mode_type" {
  description = "Storage redundancy mode for the corp-a1 Recovery Services Vault. corp-a1 is the in-region primary spoke, so the default is ZoneRedundant (cross-region restore is GeoRedundant-only and stays disabled). Valid Azure values: LocallyRedundant, ZoneRedundant, GeoRedundant."
  type        = string
  default     = "ZoneRedundant"

  validation {
    condition     = contains(["LocallyRedundant", "ZoneRedundant", "GeoRedundant"], var.rsv_storage_mode_type)
    error_message = "rsv_storage_mode_type must be one of: LocallyRedundant, ZoneRedundant, GeoRedundant."
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
  description = "ARM resource ID of the platform Log Analytics workspace. Diagnostic settings for App Service and SQL stream here."
  type        = string
}

variable "platform_law_customer_id" {
  description = "GUID (customer ID) of the platform Log Analytics workspace. Required for Traffic Analytics in NSG flow logs (distinct from the ARM resource ID)."
  type        = string
}

variable "platform_action_group_id" {
  description = "ARM resource ID of the platform Monitor Action Group. Used for alert rules."
  type        = string
}

variable "flow_log_retention_days" {
  description = "Number of days to retain NSG flow log data in the storage account."
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# App Service
# ---------------------------------------------------------------------------

variable "app_service_sku" {
  description = "SKU name for the App Service Plan. B2 provides 2 vCores / 3.5 GB RAM at ~$70/mo on Linux."
  type        = string
  default     = "B2"
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
