# Purpose: Input variables for the Security platform root module.
# Section: 8 — Standard Platform Components
# Last updated: 2026-05-14

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
  description = "Log Analytics workspace data retention period in days (30–730) for the RBAC-isolated Security workspace."
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
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
