# Purpose: Input variables for the synthetic workload layer.
# Section: 13 — Synthetic Workload & Telemetry Generation
# Last updated: 2026-06-02

# ---------------------------------------------------------------------------
# Kill switch
# ---------------------------------------------------------------------------

variable "enable_synthetic_workload" {
  description = "Master toggle for the synthetic workload layer. When false, every resource in this root module has count=0 and `terraform apply` destroys all synthetic resources in <5 minutes (PROMPT.md §13.6 kill switch)."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Subscription & global config
# ---------------------------------------------------------------------------

variable "landingzones_subscription_id" {
  description = "Subscription ID of the Landing Zones subscription where synthetic resources are deployed alongside the existing corp-a1 / corp-a2 / online-p1 workloads."
  type        = string
}

variable "primary_location" {
  description = "Primary Azure region (matches corp-a1 + online-p1 landing zones)."
  type        = string
  default     = "eastus2"
}

variable "secondary_location" {
  description = "Secondary / DR region (matches corp-a2 cold standby)."
  type        = string
  default     = "centralus"
}

variable "org_prefix" {
  description = "Short org prefix used in deterministic resource names — must match the value used by landing-zones/* so data-source lookups resolve."
  type        = string
}

variable "environment" {
  description = "Environment short name (e.g. poc) — must match the value used by landing-zones/*."
  type        = string
}

# ---------------------------------------------------------------------------
# Cross-module references (consumed via data sources)
# ---------------------------------------------------------------------------

variable "platform_law_workspace_id" {
  description = "ARM resource ID of the Platform Log Analytics workspace. Diagnostic settings on synthetic resources stream here so Section 6 Sentinel rules can correlate synthetic telemetry with real signals."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# 13.3 — Red-team simulator
# ---------------------------------------------------------------------------

variable "red_team_geo_location" {
  description = "Azure region for the impossible-travel west pole — must be outside the §5 approved_sign_in_countries list (US/CA/GB by default) so the §6 blocked-country detection rule has a valid signal."
  type        = string
  default     = "westeurope"
}

variable "honeypot_user_principal_name" {
  description = "Tenant-resident UPN of the disabled honeypot user (e.g. svc-honeypot@<tenant>.onmicrosoft.com). Must be created manually as a Disabled account — see synthetic/README.md §13.3 pre-reqs. Empty string disables the sign-in / impossible-travel red-team scenarios; the storage / KV / public-IP scenarios still ship."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Extra tags merged into every synthetic resource on top of the locals.common_tags baseline (Layer=Synthetic, Lifecycle=Ephemeral, CostCenter=synthetic-poc)."
  type        = map(string)
  default     = {}
}
