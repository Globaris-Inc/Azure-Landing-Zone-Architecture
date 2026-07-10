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
# Identity subscription domain-services infrastructure (Section 8 — G1, ADR-010)
# Added: Gap-Closure Wave 3. Gates the Entra DS + identity VNet + RSV build.
# ---------------------------------------------------------------------------

variable "identity_subscription_id" {
  description = "Subscription ID for the Identity platform subscription. The identity VNet, Entra Domain Services, and Recovery Services Vault deploy here (NOT the management sub that anchors the PIM provider)."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "Subscription ID for the Connectivity platform subscription. Used only for the hub-to-identity return VNet peering (azurerm.connectivity alias)."
  type        = string
}

variable "identity_mode" {
  description = <<-EOT
    Selects how the Identity subscription provides directory/domain services (ADR-010).
      "entra-ds" — Microsoft Entra Domain Services (managed), the shipped default.
      "ad-ds"    — self-managed AD DS domain controllers on IaaS. DOCUMENTED-ONLY in this
                   wave: selecting it does NOT yet build DCs (no DC VMs authored). It only
                   keeps the identity VNet + RSV (mode != "none") with no Entra DS resource.
      "none"     — Identity sub left empty (no VNet/DS/RSV). Reverses to the pre-G1 posture.
    Everything new is gated on identity_mode != "none"; the Entra DS resource is additionally
    gated on identity_mode == "entra-ds". Gating uses static booleans (LESSON 5 — never gate
    on an unknown resource ID).
  EOT
  type        = string
  default     = "entra-ds"

  validation {
    condition     = contains(["entra-ds", "ad-ds", "none"], var.identity_mode)
    error_message = "identity_mode must be 'entra-ds', 'ad-ds', or 'none'."
  }
}

variable "identity_domain_name" {
  description = "Fully-qualified DNS domain name for Microsoft Entra Domain Services (e.g. 'aadds.globaris.onmicrosoft.com'). Required when identity_mode = 'entra-ds'. Ties to OQ-003 (POC domain name)."
  type        = string
  default     = ""
}

variable "aadds_import_replica_set_id" {
  description = <<-EOT
    ONE-TIME RECOVERY INPUT (ADR-029). GUID of the managed domain's initial replica
    set, used to build the composite config-driven import ID for the built-but-unstated
    Entra Domain Services resource:
    '<domain resource ID>/initialReplicaSetId/<this GUID>'. Supplied operationally via
    TF_VAR_aadds_import_replica_set_id in CI for the recovery apply only. Leave "" for a
    greenfield deploy (no domain to import): the import block is then a no-op, keeping the
    config portable. Never commit the live GUID to tfvars.
  EOT
  type        = string
  default     = ""
}

variable "identity_vnet_address_space" {
  description = "CIDR block for the identity VNet. Must not overlap the hubs (10.0.0.0/16, 10.1.0.0/16) or the spokes (10.10/16, 10.11/16, 10.20/16). The Entra DS subnet is computed from this block."
  type        = string
  default     = "10.2.0.0/24"
}

variable "identity_location" {
  description = "Azure region for the identity VNet, Entra Domain Services, and RSV. Defaults to the primary region (eastus2) to co-locate with the primary hub it peers to."
  type        = string
  default     = "eastus2"
}

variable "primary_hub_vnet_id" {
  description = "ARM resource ID of the primary hub VNet (eastus2). From platform/connectivity output 'primary_hub_vnet_id'. Used for the identity-to-hub peering."
  type        = string
  default     = ""
}

variable "primary_hub_vnet_name" {
  description = "Name of the primary hub VNet. From platform/connectivity output 'primary_hub_vnet_name'. Required for the hub-to-identity return peering."
  type        = string
  default     = ""
}

variable "primary_hub_rg_name" {
  description = "Resource group name that contains the primary hub VNet (Connectivity subscription). Required for the hub-to-identity return peering."
  type        = string
  default     = ""
}

variable "identity_rsv_storage_mode_type" {
  description = "Storage redundancy mode for the identity Recovery Services Vault. Identity is an in-region primary pillar, so the default is ZoneRedundant (matches corp-a1; corp-a2 is the GeoRedundant DR spoke). Valid: LocallyRedundant, ZoneRedundant, GeoRedundant."
  type        = string
  default     = "ZoneRedundant"

  validation {
    condition     = contains(["LocallyRedundant", "ZoneRedundant", "GeoRedundant"], var.identity_rsv_storage_mode_type)
    error_message = "identity_rsv_storage_mode_type must be one of: LocallyRedundant, ZoneRedundant, GeoRedundant."
  }
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into any Azure resources created by this module."
  type        = map(string)
  default     = {}
}
