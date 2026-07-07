# Purpose: Input variables for the reusable FinOps child module.
# Section: 7 — FinOps: Tagging & Budgets
# Last updated: 2026-07-07
#
# This module creates per-subscription FinOps resources: subscription budget,
# daily cost export to a shared storage container, and optional VM auto-shutdown
# schedules. Call once per target subscription from platform/management.

variable "budget_name" {
  description = "Name for the subscription consumption budget resource."
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID this budget and cost export target."
  type        = string
}

variable "budget_amount" {
  description = "Monthly budget cap in USD."
  type        = number
}

variable "budget_start_date" {
  description = "Budget start date in RFC 3339 format. Must be the first day of a month (e.g. 2026-05-01T00:00:00Z)."
  type        = string
}

variable "budget_alert_thresholds" {
  description = "Percentage thresholds at which budget alert notifications fire."
  type        = list(number)
  default     = [50, 75, 90, 100]
}

variable "budget_alert_contact_emails" {
  description = "Email addresses to notify when a budget threshold is crossed."
  type        = list(string)
}

variable "export_enabled" {
  description = "Whether to create a daily ActualCost export for this subscription. This bool is the sole (statically-known) gate on export creation; when true the caller must supply a valid export_container_arm_id."
  type        = bool
  default     = true
}

variable "export_name" {
  description = "Name for the daily cost export resource. Defaults to '<budget_name>-daily-export'."
  type        = string
  default     = ""
}

variable "export_container_arm_id" {
  description = "ARM resource ID of the storage container that receives daily exports. May be unknown at plan time (it is built from storage-account/container attributes in the caller). Must be non-empty and valid whenever export_enabled = true; it no longer gates export creation (export_enabled does)."
  type        = string
  default     = ""
}

variable "export_root_folder" {
  description = "Folder prefix inside the export storage container (no leading slash)."
  type        = string
  default     = "exports"
}

variable "export_start_date" {
  description = "Cost export recurrence start date in RFC 3339 format. Defaults to budget_start_date if empty."
  type        = string
  default     = ""
}

variable "export_end_date" {
  description = "Cost export recurrence end date in RFC 3339 format."
  type        = string
  default     = "2030-12-01T00:00:00Z"
}

variable "vm_shutdown_schedules" {
  description = "Map of VMs to configure auto-shutdown on. Key = logical VM name. Called with empty map until VMs exist (Section 8)."
  type = map(object({
    virtual_machine_id    = string
    location              = string
    daily_recurrence_time = string # HHMM 24-hour format, e.g. "1900" for 7:00 PM
    timezone              = string # Windows timezone name, e.g. "Eastern Standard Time"
    enabled               = bool
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to all taggable resources created by this module."
  type        = map(string)
  default     = {}
}
