# Purpose: Input variables for the bootstrap layer.
# Section: 10a — Pipeline & Tooling (bootstrap subset)
# Last updated: 2026-05-05

variable "tenant_id" {
  description = "Azure AD tenant ID. Used by the azuread provider and Key Vault access configuration."
  type        = string
}

variable "management_subscription_id" {
  description = "Subscription ID of the Management subscription. The state backend RG, Key Vault, and Storage Account are created here."
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
  default     = "contoso"

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
  description = "Number of days to retain soft-deleted Key Vault objects (7–90)."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Additional tags merged onto all bootstrap resources. Common tags (Environment, ManagedBy, Section) are always applied."
  type        = map(string)
  default     = {}
}
