# Purpose: Input variables for the bootstrap layer.
# Section: 10a - Pipeline & Tooling (bootstrap subset)
# Last updated: 2026-06-29

variable "tenant_id" {
  description = "Azure AD tenant ID. Used by the azuread provider and Key Vault access configuration."
  type        = string
}

variable "management_subscription_id" {
  description = "Subscription ID of the Management subscription. The state backend RG, Key Vault, and Storage Account are created here. Also granted to the OIDC SP (Contributor + User Access Administrator) for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}

# ---------------------------------------------------------------------------
# CI/CD subscription IDs - grant the OIDC SP Contributor + User Access
# Administrator on each of the 5 platform subscriptions (OQ-008 / ADR-021).
# Names match platform/management-groups/variables.tf exactly.
# ---------------------------------------------------------------------------

variable "connectivity_subscription_id" {
  description = "Subscription ID of the Connectivity subscription. Used to grant the OIDC SP Contributor + User Access Administrator for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}

variable "identity_subscription_id" {
  description = "Subscription ID of the Identity subscription. Used to grant the OIDC SP Contributor + User Access Administrator for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}

variable "security_subscription_id" {
  description = "Subscription ID of the Security subscription. Used to grant the OIDC SP Contributor + User Access Administrator for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}

variable "landingzones_subscription_id" {
  description = "Subscription ID of the shared Landing Zones subscription (spokes + synthetic). Used to grant the OIDC SP Contributor + User Access Administrator for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}

variable "primary_location" {
  description = "Primary Azure region for all bootstrap resources."
  type        = string
  default     = "eastus2"
}

variable "org_prefix" {
  description = "Short organisation prefix used in resource names (lower-case, no spaces, max 8 chars)."
  type        = string
  default     = "globaris"

  validation {
    condition     = can(regex("^[a-z0-9]{1,8}$", var.org_prefix))
    error_message = "org_prefix must be lowercase alphanumeric and at most 8 characters."
  }
}

variable "github_org" {
  description = "GitHub organisation name or personal account username that owns the repository. Used to build OIDC federated credential subjects."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the org prefix). Used to build OIDC federated credential subjects."
  type        = string
}

variable "ip_allow_list" {
  description = <<-EOT
    List of public IP addresses or CIDR blocks permitted to access the state Storage Account
    over public network (used until Section 8 adds a Private Endpoint).
    Include your home/office public IP and GitHub Actions runner IP ranges.
    GitHub Actions IP ranges: https://api.github.com/meta (look for 'actions' key).
    Format: ["1.2.3.4", "10.0.0.0/24"]
  EOT
  type        = list(string)

  validation {
    condition     = length(var.ip_allow_list) > 0
    error_message = "ip_allow_list must contain at least one IP address or CIDR block."
  }
}

variable "kv_soft_delete_retention_days" {
  description = "Number of days to retain soft-deleted Key Vault objects (7-90)."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Additional tags merged onto all bootstrap resources. Common tags (Environment, ManagedBy, Section) are always applied."
  type        = map(string)
  default     = {}
}
