# Purpose: Input variables for Management Group hierarchy root module.
# Section: 2 - Management Group Hierarchy
# Last updated: 2026-05-06

variable "connectivity_subscription_id" {
  description = "Subscription ID for sub-connectivity-poc-01 - placed under the Connectivity management group."
  type        = string
}

variable "management_subscription_id" {
  description = "Subscription ID for sub-management-poc-01 - placed under the Management management group."
  type        = string
}

variable "identity_subscription_id" {
  description = "Subscription ID for sub-identity-poc-01 - placed under the Identity management group."
  type        = string
}

variable "security_subscription_id" {
  description = "Subscription ID for sub-security-poc-01 - placed under the Security management group."
  type        = string
}

variable "landingzones_subscription_id" {
  description = "Subscription ID for sub-landingzones-poc-01 - placed under the Corp management group."
  type        = string
}

variable "primary_location" {
  description = "Primary Azure region for resources that require a location (e.g. policy assignments with remediation)."
  type        = string
  default     = "eastus2"
}

variable "tags" {
  description = "Additional tags to merge into all resources managed by this module."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Wave B7 - Operations & Monitoring Phase 1 (AMBA-ALZ) - ADR-052
# ---------------------------------------------------------------------------

variable "enable_om_phase1" {
  description = "Master gate for wave B7 (O&M Phase 1 - AMBA-ALZ). When true, selects the globaris-amba architecture, which attaches the AMBA alerting archetypes (Deploy-AMBA-* DINE assignments + Alerting-* initiatives) at the Globaris root, platform-family, and landingzones management groups. Default false keeps the estate identical to the B0a-green globaris architecture (LESSON 42 - inert-but-mergeable). Must be set to the SAME value in platform/management (which deploys the companion AMBA identity/RG)."
  type        = bool
  default     = false
}

variable "om_operator_notification_email" {
  description = "Operator / on-call notification address that the AMBA notification action group (Deploy-AMBA-Notification) routes to. Converges the AMBA alert stream onto the SAME operator target as the platform action group (ADR-052 section 5). Supplied via TF_VAR_om_operator_notification_email in CI or poc.secret.tfvars locally - NEVER committed. Empty string leaves the AMBA action group email unset."
  type        = string
  default     = ""
}
