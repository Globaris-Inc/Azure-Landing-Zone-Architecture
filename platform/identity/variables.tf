# Purpose: Input variables for the identity / Zero Trust root module.
# Section: 5 — Zero Trust + Conditional Access
# Last updated: 2026-05-26

# ---------------------------------------------------------------------------
# Tenant + subscription targeting
# ---------------------------------------------------------------------------

variable "tenant_id" {
  description = "Azure Active Directory tenant ID."
  type        = string
}

variable "management_subscription_id" {
  description = "Management subscription ID. Used as the azurerm provider authentication anchor for MG-scope PIM resources."
  type        = string
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

variable "org_prefix" {
  description = "Short organisation identifier used in CA policy display names (e.g. 'globaris')."
  type        = string
}

variable "environment" {
  description = "Deployment environment label (e.g. 'poc')."
  type        = string
  default     = "poc"
}

# ---------------------------------------------------------------------------
# Conditional Access — behaviour
# ---------------------------------------------------------------------------

variable "ca_policy_state" {
  description = <<-EOT
    Operational state for all Conditional Access policies.
    Use "enabledForReportingButNotEnforced" (report-only) until policies are
    reviewed and validated in the tenant. Switch to "enabled" to enforce.
    Options: "enabled" | "disabled" | "enabledForReportingButNotEnforced"
  EOT
  type        = string
  default     = "enabledForReportingButNotEnforced"

  validation {
    condition     = contains(["enabled", "disabled", "enabledForReportingButNotEnforced"], var.ca_policy_state)
    error_message = "ca_policy_state must be 'enabled', 'disabled', or 'enabledForReportingButNotEnforced'."
  }
}

variable "approved_sign_in_countries" {
  description = "ISO 3166-1 alpha-2 country codes from which sign-ins are allowed. All other countries are blocked by CA-005."
  type        = list(string)
  default     = ["US", "CA", "GB"]
}

variable "break_glass_group_object_id" {
  description = <<-EOT
    Object ID of an Entra ID group containing break-glass / emergency-access accounts.
    These accounts are excluded from all Conditional Access policies to prevent
    complete lockout. Leave empty ("") to skip the exclusion — NOT recommended for
    production.
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# PIM — Privileged Identity Management
# ---------------------------------------------------------------------------

variable "pim_privileged_group_object_id" {
  description = <<-EOT
    Object ID of the Entra ID security group whose members receive eligible role
    assignments via PIM (Owner at root MG, Contributor at Landing Zones MG, etc.).
    Leave empty ("") to skip all PIM eligible assignment resources — useful for
    initial bootstrap when the group doesn't exist yet.
  EOT
  type        = string
  default     = ""
}

variable "pim_approver_group_object_id" {
  description = <<-EOT
    Object ID of the Entra ID group that approves PIM activation requests.
    Leave empty ("") to configure PIM without an approval stage (self-approve with MFA).
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into any Azure resources created by this module."
  type        = map(string)
  default     = {}
}
