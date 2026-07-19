# Purpose: Input variables for the Management platform root module.
# Section: 7 - FinOps: Tagging & Budgets (initial); extended in Section 8.
# Last updated: 2026-07-07

variable "tenant_id" {
  description = "Azure Active Directory tenant ID."
  type        = string
}

variable "management_subscription_id" {
  description = "Subscription ID for the Management platform subscription (sub-management-poc-01)."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "Subscription ID for the Connectivity platform subscription."
  type        = string
}

variable "identity_subscription_id" {
  description = "Subscription ID for the Identity platform subscription."
  type        = string
}

variable "security_subscription_id" {
  description = "Subscription ID for the Security platform subscription."
  type        = string
}

variable "landingzones_subscription_id" {
  description = "Subscription ID for the Landing Zones subscription (corp + online workloads)."
  type        = string
}

variable "primary_location" {
  description = "Primary Azure region for resources that require a location."
  type        = string
  default     = "eastus2"
}

variable "org_prefix" {
  description = "Short organisation identifier used in resource and policy naming (e.g. 'globaris')."
  type        = string
}

variable "environment" {
  description = "Deployment environment label used in resource names and tags (e.g. 'poc')."
  type        = string
  default     = "poc"
}

variable "terraform_sp_object_id" {
  description = "Object ID of the OIDC service principal running Terraform. Granted Storage Blob Data Contributor on the cost-exports Storage Account (keyless, Entra-only auth). Fed by CI as TF_VAR_terraform_sp_object_id (same as platform/security)."
  type        = string
}

# ---------------------------------------------------------------------------
# FinOps - Budgets
# ---------------------------------------------------------------------------

variable "budget_amount_per_subscription" {
  description = "Monthly budget cap in USD applied to each of the five platform/LZ subscriptions."
  type        = number
  default     = 200
}

variable "budget_amount_per_mg" {
  description = "Monthly budget cap in USD applied to management group scope budgets."
  type        = number
  default     = 600
}

variable "budget_alert_thresholds" {
  description = "Percentage thresholds at which budget alert notifications fire."
  type        = list(number)
  default     = [50, 75, 90, 100]
}

variable "budget_alert_contact_emails" {
  description = "Email addresses for budget threshold breach and cost anomaly alert notifications."
  type        = list(string)
}

variable "budget_start_date" {
  description = "Budget and cost export start date in RFC 3339 format. Must be the first of a month (e.g. 2026-05-01T00:00:00Z)."
  type        = string
}

variable "export_end_date" {
  description = "Cost export recurrence period end date in RFC 3339 format."
  type        = string
  default     = "2030-12-01T00:00:00Z"
}

# ---------------------------------------------------------------------------
# Section 8 - Management Platform Monitoring
# ---------------------------------------------------------------------------

variable "platform_law_retention_days" {
  description = "Log Analytics workspace data retention period in days (30-730). Section 8 baseline is 90."
  type        = number
  default     = 90
}

variable "platform_law_daily_quota_gb" {
  description = "Daily ingestion quota in GB for the platform Log Analytics workspace. Null disables the cap."
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Wave B7 - Operations & Monitoring Phase 1 (AMBA-ALZ) - ADR-052
# ---------------------------------------------------------------------------

variable "enable_om_phase1" {
  description = "Master gate for wave B7 (O&M Phase 1 - AMBA-ALZ). When true, deploys the AMBA supporting infrastructure via avm-ptn-monitoring-amba-alz: rg-amba-monitoring-001, the id-amba-prod-001 user-assigned managed identity, and its Monitoring Reader role at the Globaris root MG. That MI is the bring-your-own remediation identity the Deploy-AMBA-* alert policies (assigned in platform/management-groups) attach to the alert resources they deploy. Default false (LESSON 42). Must be set to the SAME value as platform/management-groups var.enable_om_phase1."
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
