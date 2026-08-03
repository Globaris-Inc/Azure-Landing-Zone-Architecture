# Purpose: §13.6 cost guardrails - Automation Account + 2 runbooks +
#          weekly schedule + action group + subscription budget that fires
#          the stop-synthetic-compute runbook when the synthetic-layer
#          spend is projected to exceed the daily-equivalent cap.
# Section: 13.6 - Cost Guardrails
# Last updated: 2026-06-06
#
# Architecture:
#   - Automation Account `aa-guardrails-...` (Basic SKU, System-Assigned MI).
#   - PowerShell 7.2 runbooks uploaded as blobs to a new `runbooks/` container
#     on the existing corp-a1 synthetic SA; a container SAS URL is passed to
#     each runbook's publish_content_link.uri (the azurerm resource demands
#     it even when content is supplied separately).
#   - The MI gets Contributor on every synthetic resource group so the stop
#     runbook can stop CAJs / deallocate VMs and the weekly runbook can
#     delete orphan PIPs.
#   - Action Group `ag-guardrails-...` carries an automation_runbook_receiver
#     pointing at the stop-synthetic-compute webhook.
#   - Subscription-scoped budget at var.cost_guardrails_monthly_cap_usd
#     ($150 default = $5/day × 30) with a tag filter Layer=Synthetic and a
#     Forecasted 100% notification routed to the action group.
#
# DEVIATIONS vs PROMPT.md §13.6:
#   - Azure consumption budgets are Monthly minimum (no Daily time_grain).
#     We approximate "$5/day" by setting the monthly cap to 30×$5 = $150 and
#     using a Forecasted 100% threshold, which trips on day 1-2 when the
#     synthetic layer is on pace to exceed the cap.
#   - PROMPT.md asks for "ACI restartPolicy=OnFailure, 4-hour max via Logic
#     App". §13.2/§13.3 use Container Apps Jobs instead of ACI; each CAJ
#     already carries `replica_timeout_in_seconds` (max 33000s for the
#     long-running k6 baseline, ≤900s for the rest), achieving the same
#     "kill-runaway-compute" guarantee without a Logic App.
#   - PROMPT.md asks for the budget to be on the "sandbox sub". ADR-003
#     collapsed the sandbox sub into the Landing Zones sub; the budget is
#     scoped to the LZ subscription with a Layer=Synthetic tag filter so it
#     only watches synthetic-layer spend.

# ---------------------------------------------------------------------------
# Locals - 13.6 sub-gate
# ---------------------------------------------------------------------------

locals {
  cost_guardrails_enabled = local.cost_patterns_enabled

  cost_guardrails_tags = merge(
    local.common_tags,
    {
      Scenario = "cost-guardrails"
    },
  )

  # Synthetic RGs the Automation MI gets Contributor on, so the stop-compute
  # runbook can act across the whole synthetic layer.
  cost_guardrails_target_rg_ids = local.cost_guardrails_enabled == 1 ? [
    azurerm_resource_group.corp_a1_synthetic[0].id,
    azurerm_resource_group.online_p1_synthetic[0].id,
    azurerm_resource_group.cost_patterns[0].id,
    azurerm_resource_group.ungoverned[0].id,
  ] : []
}

# ---------------------------------------------------------------------------
# Automation Account + Managed Identity
# ---------------------------------------------------------------------------

resource "azurerm_automation_account" "guardrails" {
  count               = local.cost_guardrails_enabled
  name                = "aa-guardrails-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.cost_patterns[0].name
  location            = var.primary_location
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = local.cost_guardrails_tags
}

# Contributor on the synthetic RGs (cost_patterns + corp_a1 + online_p1 +
# ungoverned). Red-team RGs get assigned separately so the assignment can
# gate on red_team_signin_enabled (the secondary RG only exists then).
resource "azurerm_role_assignment" "guardrails_contributor" {
  for_each             = local.cost_guardrails_enabled == 1 ? toset(local.cost_guardrails_target_rg_ids) : []
  scope                = each.value
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.guardrails[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "guardrails_contributor_rt_primary" {
  count                = local.cost_guardrails_enabled == 1 && local.red_team_enabled == 1 ? 1 : 0
  scope                = azurerm_resource_group.red_team_primary[0].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.guardrails[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "guardrails_contributor_rt_secondary" {
  count                = local.cost_guardrails_enabled == 1 && local.red_team_signin_enabled == 1 ? 1 : 0
  scope                = azurerm_resource_group.red_team_secondary[0].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.guardrails[0].identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Runbook content upload - blobs in the corp-a1 synthetic SA
# ---------------------------------------------------------------------------

resource "azurerm_storage_container" "runbooks" {
  count                 = local.cost_guardrails_enabled
  name                  = "runbooks"
  storage_account_id    = azurerm_storage_account.corp_a1_synthetic[0].id
  container_access_type = "private"
}

resource "azurerm_storage_blob" "stop_synthetic_compute" {
  count                  = local.cost_guardrails_enabled
  name                   = "stop-synthetic-compute.ps1"
  storage_account_name   = azurerm_storage_account.corp_a1_synthetic[0].name
  storage_container_name = azurerm_storage_container.runbooks[0].name
  type                   = "Block"
  source                 = "${path.module}/runbooks/stop-synthetic-compute.ps1"
  content_md5            = filemd5("${path.module}/runbooks/stop-synthetic-compute.ps1")
}

resource "azurerm_storage_blob" "weekly_cleanup_ephemeral" {
  count                  = local.cost_guardrails_enabled
  name                   = "weekly-cleanup-ephemeral.ps1"
  storage_account_name   = azurerm_storage_account.corp_a1_synthetic[0].name
  storage_container_name = azurerm_storage_container.runbooks[0].name
  type                   = "Block"
  source                 = "${path.module}/runbooks/weekly-cleanup-ephemeral.ps1"
  content_md5            = filemd5("${path.module}/runbooks/weekly-cleanup-ephemeral.ps1")
}

# Read-only SAS for the runbooks container. publish_content_link.uri needs a
# reachable URL; the same SAS works for all blobs in the container.
data "azurerm_storage_account_blob_container_sas" "runbooks" {
  count             = local.cost_guardrails_enabled
  connection_string = azurerm_storage_account.corp_a1_synthetic[0].primary_connection_string
  container_name    = azurerm_storage_container.runbooks[0].name
  https_only        = true

  start  = timestamp()
  expiry = timeadd(timestamp(), "1h")

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = false
  }
}

# ---------------------------------------------------------------------------
# Runbooks
# ---------------------------------------------------------------------------

resource "azurerm_automation_runbook" "stop_synthetic_compute" {
  count                   = local.cost_guardrails_enabled
  name                    = "stop-synthetic-compute"
  resource_group_name     = azurerm_resource_group.cost_patterns[0].name
  location                = var.primary_location
  automation_account_name = azurerm_automation_account.guardrails[0].name
  log_progress            = true
  log_verbose             = true
  runbook_type            = "PowerShell72"
  description             = "Emergency stop of synthetic compute - fired by the §13.6 budget action group webhook."

  publish_content_link {
    uri = "https://${azurerm_storage_account.corp_a1_synthetic[0].name}.blob.core.windows.net/${azurerm_storage_container.runbooks[0].name}/${azurerm_storage_blob.stop_synthetic_compute[0].name}${data.azurerm_storage_account_blob_container_sas.runbooks[0].sas}"
  }

  tags = local.cost_guardrails_tags
}

resource "azurerm_automation_runbook" "weekly_cleanup_ephemeral" {
  count                   = local.cost_guardrails_enabled
  name                    = "weekly-cleanup-ephemeral"
  resource_group_name     = azurerm_resource_group.cost_patterns[0].name
  location                = var.primary_location
  automation_account_name = azurerm_automation_account.guardrails[0].name
  log_progress            = true
  log_verbose             = true
  runbook_type            = "PowerShell72"
  description             = "Weekly Lifecycle=Ephemeral orphan sweep + inventory."

  publish_content_link {
    uri = "https://${azurerm_storage_account.corp_a1_synthetic[0].name}.blob.core.windows.net/${azurerm_storage_container.runbooks[0].name}/${azurerm_storage_blob.weekly_cleanup_ephemeral[0].name}${data.azurerm_storage_account_blob_container_sas.runbooks[0].sas}"
  }

  tags = local.cost_guardrails_tags
}

# ---------------------------------------------------------------------------
# Webhook on the stop-synthetic-compute runbook (called by Action Group)
# ---------------------------------------------------------------------------

resource "azurerm_automation_webhook" "stop_synthetic_compute" {
  count                   = local.cost_guardrails_enabled
  name                    = "wh-stop-synthetic-compute"
  resource_group_name     = azurerm_resource_group.cost_patterns[0].name
  automation_account_name = azurerm_automation_account.guardrails[0].name
  runbook_name            = azurerm_automation_runbook.stop_synthetic_compute[0].name
  expiry_time             = "2030-12-31T23:59:59Z"
}

# ---------------------------------------------------------------------------
# Weekly schedule + job-schedule link for the cleanup runbook
# ---------------------------------------------------------------------------

resource "azurerm_automation_schedule" "weekly_cleanup" {
  count                   = local.cost_guardrails_enabled
  name                    = "sched-weekly-cleanup-ephemeral"
  resource_group_name     = azurerm_resource_group.cost_patterns[0].name
  automation_account_name = azurerm_automation_account.guardrails[0].name
  frequency               = "Week"
  interval                = 1
  timezone                = "UTC"
  week_days               = ["Sunday"]

  # Apply-time + 10 days. The first run is the Sunday following that.
  # ignore_changes keeps subsequent plans clean since timestamp() recomputes.
  start_time = timeadd(timestamp(), "240h")

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "weekly_cleanup" {
  count                   = local.cost_guardrails_enabled
  resource_group_name     = azurerm_resource_group.cost_patterns[0].name
  automation_account_name = azurerm_automation_account.guardrails[0].name
  schedule_name           = azurerm_automation_schedule.weekly_cleanup[0].name
  runbook_name            = azurerm_automation_runbook.weekly_cleanup_ephemeral[0].name
}

# ---------------------------------------------------------------------------
# Action Group - routes Forecasted-100% budget breach to the stop webhook
# ---------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "guardrails" {
  count               = local.cost_guardrails_enabled == 1 && length(var.cost_guardrails_alert_emails) > 0 ? 1 : 0
  name                = "ag-guardrails-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.cost_patterns[0].name
  short_name          = "guardrails"

  dynamic "email_receiver" {
    for_each = toset(var.cost_guardrails_alert_emails)
    content {
      name                    = "email-${replace(replace(email_receiver.value, "@", "-at-"), ".", "-")}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  automation_runbook_receiver {
    name                    = "rb-stop-synthetic-compute"
    automation_account_id   = azurerm_automation_account.guardrails[0].id
    runbook_name            = azurerm_automation_runbook.stop_synthetic_compute[0].name
    webhook_resource_id     = azurerm_automation_webhook.stop_synthetic_compute[0].id
    service_uri             = azurerm_automation_webhook.stop_synthetic_compute[0].uri
    is_global_runbook       = false
    use_common_alert_schema = true
  }

  tags = local.cost_guardrails_tags
}

# ---------------------------------------------------------------------------
# Subscription budget - Layer=Synthetic tag filter, Forecasted 100% trip
# ---------------------------------------------------------------------------

resource "azurerm_consumption_budget_subscription" "synthetic_guardrails" {
  count           = local.cost_guardrails_enabled == 1 && length(var.cost_guardrails_alert_emails) > 0 ? 1 : 0
  name            = "bdgt-synthetic-guardrails-${var.org_prefix}-${var.environment}"
  subscription_id = "/subscriptions/${var.landingzones_subscription_id}"
  amount          = var.cost_guardrails_monthly_cap_usd
  time_grain      = "Monthly"

  time_period {
    # CORRECTED 2026-08-02, same class as cost_patterns.tf: a start_date prior to the
    # current month is rejected by Azure with `400: Start date for monthly time grain
    # should not be prior to current month`, proven live in Step 2 of the 2026-08-02
    # rebuild. Dormant only because `enable_synthetic_workload` is false. See OQ-070.
    start_date = "2026-08-01T00:00:00Z"
    end_date   = "2030-12-01T00:00:00Z"
  }

  filter {
    tag {
      name   = "Layer"
      values = ["Synthetic"]
    }
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.cost_guardrails_alert_emails
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.cost_guardrails_alert_emails
    contact_groups = [azurerm_monitor_action_group.guardrails[0].id]
  }
}
