# Purpose: Input variables for the corp-a2 landing zone root module (DR spoke).
# Section: 9 - Landing Zone Spokes
# Last updated: 2026-07-10

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
  description = "DR Azure region for corp-a2 resources. Must match the secondary hub location. Authoritative value is envs/poc.tfvars (ADR-069); this default only matches it."
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
  description = "CIDR block for the corp-a2 spoke VNet. All subnet prefixes are computed from this block."
  type        = string
  default     = "10.11.0.0/16"
}

variable "secondary_hub_vnet_id" {
  description = "ARM resource ID of the secondary (DR) hub VNet (eastus2). From platform/connectivity output 'secondary_hub_vnet_id'."
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
# Workload - SQL
# ---------------------------------------------------------------------------

variable "enable_sql" {
  description = "Gate for the SQL data tier (logical server, database, and its private endpoint). Default false: Azure SQL provisioning is restricted in the spoke region (eastus2 after ADR-069) for the landingzones subscription (ProvisioningDisabled - a subscription/region restriction surfaced during PUT polling, not a code bug), so the SQL tier is pre-staged but not deployed. ADR-069 does NOT lift this gate: the restriction attaches to the subscription offer, not to the region (ADR-031, LESSON 42). Set true only after a live probe on this subscription in this region succeeds, or a support-request exception is granted. See the DEVIATION note on azurerm_mssql_server.this in main.tf."
  type        = bool
  default     = false
}

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

variable "enable_app_service" {
  description = "Gate for the App Service tier (App Service Plan + Site). Default false: the App Service tier is gated off because the landingzones subscription's DEDICATED App Service compute quota is 0 (ARM ExtendedCode 70007 'Total VMs: 0, required 3' - a Microsoft.Web dedicated-compute offer cap, not the Microsoft.Compute quota). The plan create fails on the quota and the site depends on it, so neither can deploy. Pre-staged: set true when a quota increase is granted (or after a serverless redesign). Same class as enable_sql. See the DEVIATION note on the App Service tier in main.tf and ADR-032."
  type        = bool
  default     = false
}

variable "app_service_sku" {
  description = "SKU name for the App Service Plan."
  type        = string
  default     = "B2"
}

# ---------------------------------------------------------------------------
# Policy exemptions (OQ-024 / ADR-028)
# ---------------------------------------------------------------------------

variable "enable_corp_policy_exemptions" {
  description = "Create the RG-scoped Waiver policy exemptions for the corp-MG Deny-Public-Endpoints initiative members (StorageDenyPaasPublicIP on the flow-log SA, AsDenyPublicIP on the App Service) that cannot be made compliant without breaking function. Default true; set false only if this spoke is moved out from under the corp MG or the governance changes (OQ-024)."
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
