# Purpose: Input variables for the corp-a2 landing zone root module (DR spoke).
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-05-14

# ---------------------------------------------------------------------------
# Subscription targeting
# ---------------------------------------------------------------------------

variable "landingzones_subscription_id" {
  description = "Subscription ID for the Landing Zones subscription. All corp-a2 spoke resources deploy here."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "Subscription ID for the Connectivity platform subscription. Used only for the hub-to-spoke return VNet peering."
  type        = string
}

# ---------------------------------------------------------------------------
# Location + naming
# ---------------------------------------------------------------------------

variable "secondary_location" {
  description = "DR Azure region for corp-a2 resources. Must match the secondary hub location."
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
# Networking
# ---------------------------------------------------------------------------

variable "spoke_address_space" {
  description = "CIDR block for the corp-a2 spoke VNet. All subnet prefixes are computed from this block."
  type        = string
  default     = "10.11.0.0/16"
}

variable "secondary_hub_vnet_id" {
  description = "ARM resource ID of the secondary (DR) hub VNet (centralus). From platform/connectivity output 'secondary_hub_vnet_id'."
  type        = string
}

variable "secondary_hub_vnet_name" {
  description = "Name of the secondary (DR) hub VNet. From platform/connectivity output 'secondary_hub_vnet_name'."
  type        = string
}

variable "secondary_hub_rg_name" {
  description = "Resource group name of the secondary hub VNet in the Connectivity subscription. Required for the hub-to-spoke return peering."
  type        = string
}

variable "secondary_firewall_private_ip" {
  description = "Private IP address of the secondary (DR) Azure Firewall. Used as the next-hop in the corp-a2 spoke UDR."
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
  description = "Display name or UPN of the Entra ID SQL administrator."
  type        = string
}

# ---------------------------------------------------------------------------
# Disaster Recovery
# ---------------------------------------------------------------------------

variable "rsv_geo_redundant" {
  description = "Enable geo-redundant storage for the Recovery Services Vault. Set false to reduce cost during development."
  type        = bool
  default     = true
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
# App Service
# ---------------------------------------------------------------------------

variable "app_service_sku" {
  description = "SKU name for the App Service Plan."
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
