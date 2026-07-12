# Purpose: Input variables for the Security platform root module.
# Section: 8 - Standard Platform Components / extended in Section 6 (Defender + Sentinel)
# Last updated: 2026-05-29

variable "tenant_id" {
  description = "Azure Active Directory tenant ID."
  type        = string
}

variable "security_subscription_id" {
  description = "Subscription ID for the Security platform subscription."
  type        = string
}

variable "primary_location" {
  description = "Primary Azure region for security resources."
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
# Security Log Analytics Workspace
# ---------------------------------------------------------------------------

variable "security_law_retention_days" {
  description = "Log Analytics workspace data retention period in days (30-730) for the RBAC-isolated Security workspace."
  type        = number
  default     = 90
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

variable "terraform_sp_object_id" {
  description = "Object ID of the OIDC service principal running Terraform. Granted Key Vault Administrator on the security Key Vault."
  type        = string
}

# ---------------------------------------------------------------------------
# Defender for Cloud
# ---------------------------------------------------------------------------

variable "security_contact_email" {
  description = "Email address for Defender for Cloud security alerts and recommendations."
  type        = string
}

# ---------------------------------------------------------------------------
# Section 6 - Defender for Cloud extension + regulatory compliance
# ---------------------------------------------------------------------------

variable "root_management_group_id" {
  description = "Full ARM resource ID of the Globaris root management group. Used as the scope for regulatory compliance policy assignments (NIST SP 800-53 R5, CIS Azure Foundations 2.0)."
  type        = string
  default     = "/providers/Microsoft.Management/managementGroups/globaris"
}

variable "enable_regulatory_compliance" {
  description = "If true, assign the NIST SP 800-53 R5 and CIS Azure Foundations 2.0 built-in policy initiatives at the root management group scope. Disable to skip during initial bootstrap if the OIDC SP lacks Policy Contributor at the MG scope."
  type        = bool
  default     = true
}

variable "enable_mdc_event_hub_export" {
  description = "If true, deploy an Event Hub namespace + hub in the Security RG and configure a Defender for Cloud continuous export of alerts/recommendations/assessments to both the Security LA workspace and the Event Hub for SIEM ingestion."
  type        = bool
  default     = true
}

variable "event_hub_namespace_capacity" {
  description = "Throughput units (1-20) for the MDC export Event Hub Namespace. 1 unit = 1 MB/s ingress + 2 MB/s egress (~2.5 GB/day at saturation)."
  type        = number
  default     = 1
  validation {
    condition     = var.event_hub_namespace_capacity >= 1 && var.event_hub_namespace_capacity <= 20
    error_message = "event_hub_namespace_capacity must be between 1 and 20."
  }
}

# ---------------------------------------------------------------------------
# Section 6 - Sentinel data connectors + UEBA
# ---------------------------------------------------------------------------

variable "enable_aad_diagnostics" {
  description = "If true, send Entra ID Sign-in/Audit/RiskyUser/UserRiskEvent/Provisioning logs to the Security LA workspace via azurerm_monitor_aad_diagnostic_setting. Requires the OIDC SP to hold Security Reader (or higher) at the tenant root."
  type        = bool
  default     = true
}

variable "enable_subscription_activity_log" {
  description = "If true, create a diagnostic setting on the Security subscription that streams Activity Log (Administrative, Security, Alert, Policy) to the Security LA workspace. Other subscriptions' activity logs are covered by the per-subscription Azure Activity Sentinel data connector."
  type        = bool
  default     = true
}

variable "enable_ueba" {
  description = "If true, enable Microsoft Sentinel UEBA (User and Entity Behaviour Analytics) and Entity Analytics with AuditLogs, AzureActivity, and SigninLogs as data sources. Requires Sentinel onboarding to be complete."
  type        = bool
  default     = true
}

variable "enable_mde_connector" {
  description = "If true, create the Microsoft Defender for Endpoint (MDATP) Sentinel data connector. Requires a Microsoft Defender for Endpoint tenant license plus Security Administrator consent. Default false: this tenant lacks the MDE license, so the connector create would fail. Left pre-staged for a later enablement pass."
  type        = bool
  default     = false
}

variable "enable_aad_connector" {
  description = "If true, create the Microsoft Entra ID (Azure Active Directory) Sentinel data connector streaming SigninLogs/AuditLogs into the Security LA workspace. Requires the OIDC SP to hold the Security Administrator (or Global Administrator) Entra directory role, which it does not hold in the POC. Default false: the tenant-scoped connector PUT returns 401 Access denied without that role. Same permission class as enable_aad_diagnostics and enable_ueba. Re-enable once the role is granted."
  type        = bool
  default     = false
}

variable "enable_ti_connector" {
  description = "If true, create the Microsoft Threat Intelligence Sentinel data connector ingesting the ThreatIntelligenceIndicator feed into the Security LA workspace. Requires the OIDC SP to hold the Security Administrator (or Global Administrator) Entra directory role, which it does not hold in the POC. Default false: the tenant-scoped connector PUT returns 401 Access denied without that role. Re-enable once the role is granted."
  type        = bool
  default     = false
}

variable "enable_firewall_ti_rule" {
  description = "If true, create the firewall_threat_intel_hit scheduled analytics rule. Default false: it is the only cross-workspace rule and its name-only workspace('law-platform-...') reference does not resolve cross-subscription at rule-create time (400 Could not locate all the workspaces). Re-enable needs a fully-qualified platform LAW reference plus cross-workspace RBAC - see OQ-027."
  type        = bool
  default     = false
}

variable "sentinel_owner_group_object_id" {
  description = "Entra ID group object ID that becomes the default owner for newly-created Sentinel incidents via an automation rule. Leave empty to skip the auto-assign automation rule."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Section 6 - Analytics rules
# ---------------------------------------------------------------------------

variable "analytics_rule_lookback_minutes" {
  description = "Default query lookback window for scheduled analytics rules, in minutes. Most POC rules run every 5-60 minutes; smaller windows reduce duplicate alerts."
  type        = number
  default     = 60
}

variable "analytics_rule_query_frequency_minutes" {
  description = "Default frequency at which scheduled analytics rules execute their queries, in minutes."
  type        = number
  default     = 60
}

# ---------------------------------------------------------------------------
# Section 6 - Watchlists
# ---------------------------------------------------------------------------

variable "vip_user_object_ids" {
  description = "List of Entra ID user object IDs flagged as VIPs. Materialised into the 'VIPUsers' Sentinel watchlist; analytics rules can join SigninLogs against this list to elevate severity on VIP sign-in anomalies."
  type        = list(string)
  default     = []
}

variable "high_value_asset_resource_ids" {
  description = "List of Azure resource IDs flagged as high-value assets (e.g., production SQL, Key Vault). Materialised into the 'HighValueAssets' Sentinel watchlist."
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
