# Purpose: Reusable FinOps resources — subscription budget, daily cost export, VM auto-shutdown.
# Section: 7 — FinOps: Tagging & Budgets
# Last updated: 2026-07-07
#
# DEVIATION: No AVM module exists for Azure Cost Management resources (budgets, exports,
# auto-shutdown schedules). All resources use native azurerm provider resources.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
  }
  required_version = ">= 1.9"
}

# ---------------------------------------------------------------------------
# Subscription-scope monthly budget
# ---------------------------------------------------------------------------

# DEVIATION: No AVM module for azurerm_consumption_budget_subscription.
resource "azurerm_consumption_budget_subscription" "this" {
  name            = var.budget_name
  subscription_id = var.subscription_id
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  dynamic "notification" {
    # String keys required for for_each; tonumber converts back for threshold.
    for_each = { for t in var.budget_alert_thresholds : tostring(t) => t }
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThan"
      contact_emails = var.budget_alert_contact_emails
    }
  }
}

# ---------------------------------------------------------------------------
# Daily ActualCost export to shared storage container
# ---------------------------------------------------------------------------

# DEVIATION: FOCUS export type is not yet available in the azurerm provider
# (registry.terraform.io/providers/hashicorp/azurerm, confirmed 2026-05-12).
# azurerm supports: ActualCost | AmortizedCost | Usage.
# Using ActualCost (unblended invoice costs) as the closest FinOps equivalent
# to the FOCUS BilledCost column. Migrate to azapi_resource when azurerm adds
# the FOCUS export type, or when the FinOps Toolkit export pipeline requires it.
resource "azurerm_subscription_cost_management_export" "this" {
  # for_each keys must be statically known at plan time. The container ARM ID is
  # built from storage-account/container attributes in the caller and is therefore
  # unknown until apply, so it cannot gate key existence. Creation is controlled by
  # the static var.export_enabled bool alone; the caller is responsible for passing a
  # valid container ARM ID whenever export_enabled = true. The (possibly unknown)
  # container ID still flows into export_data_storage_location.container_id below,
  # which is allowed because unknown values are permitted in resource bodies.
  for_each = var.export_enabled ? { export = true } : {}

  name            = var.export_name != "" ? var.export_name : "${var.budget_name}-daily-export"
  subscription_id = var.subscription_id

  recurrence_type              = "Daily"
  recurrence_period_start_date = var.export_start_date != "" ? var.export_start_date : var.budget_start_date
  recurrence_period_end_date   = var.export_end_date

  export_data_storage_location {
    container_id     = var.export_container_arm_id
    root_folder_path = "/${var.export_root_folder}"
  }

  export_data_options {
    type       = "ActualCost"
    time_frame = "MonthToDate"
  }
}

# ---------------------------------------------------------------------------
# VM auto-shutdown schedules
# ---------------------------------------------------------------------------

# DEVIATION: No AVM module for azurerm_dev_test_global_vm_shutdown_schedule.
# Despite the "DevTest" namespace, this resource applies to standard Azure VMs,
# not DevTest Lab VMs. It is the only native azurerm resource for VM auto-shutdown.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  for_each = var.vm_shutdown_schedules

  virtual_machine_id    = each.value.virtual_machine_id
  location              = each.value.location
  enabled               = each.value.enabled
  daily_recurrence_time = each.value.daily_recurrence_time
  timezone              = each.value.timezone

  notification_settings {
    enabled = false
  }

  tags = var.tags
}
