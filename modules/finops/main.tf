# Purpose: Reusable FinOps resources - subscription budget, daily cost export, VM auto-shutdown.
# Section: 7 - FinOps: Tagging & Budgets
# Last updated: 2026-07-08
#
# DEVIATION: No AVM module exists for Azure Cost Management resources (budgets, exports,
# auto-shutdown schedules). Budget and auto-shutdown use native azurerm resources; the
# cost export uses azapi (see ADR-027 rationale on the resource below).

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.5"
    }
  }
  required_version = ">= 1.9"
}

locals {
  # azurerm v4 validates subscription_id on azurerm_consumption_budget_subscription
  # with commonids.ValidateSubscriptionID (go-azure-helpers), which requires the full
  # 2-segment resource ID "/subscriptions/<uuid>", not a bare GUID (verified against
  # provider source at v4.71.0, 2026-07-07). The azapi cost export needs the same full
  # form as its parent_id. Normalize here so callers may pass either form.
  subscription_resource_id = startswith(var.subscription_id, "/subscriptions/") ? var.subscription_id : "/subscriptions/${var.subscription_id}"

  # Azure rejects an export whose schedule.recurrencePeriod.from is not strictly
  # in the future ("The start date must be in future" - ARM reference for
  # Microsoft.CostManagement/exports, verified 2026-07-08). A static tfvars date
  # inevitably goes stale between authoring and apply (this exact class already
  # bit the budgets, commit 7dde32b), so guard it: use the requested date when it
  # is still in the future, otherwise start the recurrence 24h after plan time.
  # ignore_changes on the export keeps later plans from churning the date.
  requested_export_start  = var.export_start_date != "" ? var.export_start_date : var.budget_start_date
  export_recurrence_start = timecmp(local.requested_export_start, plantimestamp()) > 0 ? local.requested_export_start : timeadd(plantimestamp(), "24h")
}

# ---------------------------------------------------------------------------
# Subscription-scope monthly budget
# ---------------------------------------------------------------------------

# DEVIATION: No AVM module for azurerm_consumption_budget_subscription.
resource "azurerm_consumption_budget_subscription" "this" {
  name            = var.budget_name
  subscription_id = local.subscription_resource_id
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

# DEVIATION: No AVM module for Cost Management exports; azapi_resource used instead of
# azurerm_subscription_cost_management_export.
#
# WHY azapi (ADR-027): the destination storage account is Entra-only
# (shared_access_key_enabled = false, repo-wide keyless pattern). The azurerm ~> 4.71
# export resource drives an older CostManagement API version that hard-rejects
# key-disabled destination SAs at PUT - all export creates failed with 400
# "Key-based authentication is currently disabled on this storage account"
# (deploy run 28911617973). CostManagement API 2023-08-01+ supports a system-assigned
# managed identity on the export, which is Microsoft's supported delivery path for
# keyless SAs; 2025-03-01 is the latest GA version (ARM reference, verified 2026-07-08).
# The service auto-assigns the export MI Storage Blob Data Contributor on the
# destination container when the creating principal holds roleAssignments/write there
# (our CI SP does, via UAA - ADR-021). Fall back to 2023-08-01 if azapi schema
# validation rejects 2025-03-01.
#
# NOTE on export type: FOCUS (FocusCost) is still not exposed by azurerm; ActualCost
# (unblended invoice costs) remains the closest FinOps equivalent to the FOCUS
# BilledCost column. With azapi, FocusCost is a one-line dataset change if the FinOps
# Toolkit export pipeline requires it later.
#
# NOTE on tags: intentionally none - the Microsoft.CostManagement/exports ARM schema
# has no tags property, so the local.common_tags rule cannot apply here.
resource "azapi_resource" "cost_export" {
  # for_each keys must be statically known at plan time. The storage account ID is an
  # apply-time attribute in the caller, so it cannot gate key existence. Creation is
  # controlled by the static var.export_enabled bool alone; the caller is responsible
  # for passing a valid storage account ID + container name whenever export_enabled =
  # true. The (possibly unknown) SA ID still flows into the body below, which is
  # allowed because unknown values are permitted in resource bodies.
  for_each  = var.export_enabled ? { export = true } : {}
  type      = "Microsoft.CostManagement/exports@2025-03-01"
  name      = var.export_name != "" ? var.export_name : "${var.budget_name}-daily-export"
  parent_id = local.subscription_resource_id
  location  = var.export_identity_location

  # System-assigned MI is what enables delivery to the keyless destination SA.
  # location above is required by ARM only when the export carries an identity.
  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      definition = {
        type      = "ActualCost"
        timeframe = "MonthToDate"
        dataSet   = { granularity = "Daily" }
      }
      deliveryInfo = {
        destination = {
          # ARM takes the STORAGE ACCOUNT resource ID + container NAME (not a
          # container ARM ID, unlike the old azurerm resource). rootFolderPath
          # takes no leading slash here.
          resourceId     = var.export_storage_account_id
          container      = var.export_container_name
          rootFolderPath = var.export_root_folder
        }
      }
      format = "Csv"
      schedule = {
        recurrence = "Daily"
        recurrencePeriod = {
          from = local.export_recurrence_start
          to   = var.export_end_date
        }
        status = "Active"
      }
    }
  }

  # The start date is derived from plantimestamp() when the requested date is in
  # the past; without ignore_changes every subsequent plan would try to rewrite
  # it. To intentionally change the recurrence start, taint/replace the export.
  lifecycle {
    ignore_changes = [body.properties.schedule.recurrencePeriod.from]
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
