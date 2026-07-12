# Purpose: k6 load generator - three scheduled Container Apps Jobs hitting the
#          corp-a1 REST API stub. Satisfies PROMPT.md §13.2.
# Section: 13.2 - Load Generator
# Last updated: 2026-06-03
#
# Architecture:
#   - Container Apps Environment (Consumption) in the primary region,
#     logs_destination=log-analytics → Platform LAW. k6 console output lands
#     in ContainerAppConsoleLogs_CL where the §6 analytics rules can read it.
#   - Azure File share `k6-scripts` on the existing corp-a1 synthetic SA
#     (reusing avoids a third storage account for three small files).
#   - Three k6 scripts (baseline / spike / anomalous) uploaded as files.
#   - Three Container Apps Jobs with `Schedule` trigger + cron, mounting the
#     scripts share read-only at /scripts.
#
# DEVIATIONS:
#   - PROMPT.md §13.2 header says "k6 in ACI" but the body specifies "Azure
#     Container Apps Jobs / Logic App timer". Going with Container Apps Jobs:
#     simpler than ACI + Logic App, native scheduling, native LAW integration.
#   - The "anomalous geo" scenario runs from the same eastus2 environment as
#     baseline/spike. The geo tag is conveyed via request headers (see
#     k6/anomalous.js). Real cross-region simulation is §13.3's responsibility.
#   - Cron times are UTC. Adjusted to land at ~9am ET / noon ET / 3am ET.

# ---------------------------------------------------------------------------
# Locals - 13.2 sub-gate (CAE requires Platform LAW workspace ID)
# ---------------------------------------------------------------------------

locals {
  k6_enabled = local.enabled == 1 && var.platform_law_workspace_id != "" ? 1 : 0

  # k6 targets the LIVE online-p1 Application Gateway public endpoint (HTTP:80)
  # instead of the gated-off corp-a1 App Service (OQ-030 decision B). k6_enabled
  # implies local.enabled==1, so data.azurerm_public_ip.online_p1_appgw[0] is
  # always present when this URL is non-empty.
  k6_target_base_url = local.k6_enabled == 1 ? "http://${data.azurerm_public_ip.online_p1_appgw[0].ip_address}" : ""

  k6_jobs = {
    baseline = {
      script           = "baseline.js"
      cron             = "0 14 * * 1-5" # 09:00 ET weekdays
      timeout_seconds  = 33000          # 9h10m - covers the full ramp + buffer
      cpu              = 0.25
      memory           = "0.5Gi"
      retry_limit      = 0
      parallelism      = 1
      replica_complete = 1
    }
    spike = {
      script           = "spike.js"
      cron             = "0 17 * * 2,4" # 12:00 ET Tue + Thu
      timeout_seconds  = 1200           # 20m - script is 15m + buffer
      cpu              = 1.0
      memory           = "2.0Gi"
      retry_limit      = 0
      parallelism      = 1
      replica_complete = 1
    }
    anomalous = {
      script           = "anomalous.js"
      cron             = "0 8 * * 0" # 03:00 ET Sun
      timeout_seconds  = 600         # 10m - script is 5m + buffer
      cpu              = 1.0
      memory           = "2.0Gi"
      retry_limit      = 0
      parallelism      = 1
      replica_complete = 1
    }
  }
}

# ---------------------------------------------------------------------------
# Container Apps Environment (Consumption profile)
# ---------------------------------------------------------------------------

resource "azurerm_container_app_environment" "k6" {
  count                      = local.k6_enabled
  name                       = "cae-synthetic-k6-${var.org_prefix}-${var.environment}"
  resource_group_name        = azurerm_resource_group.corp_a1_synthetic[0].name
  location                   = var.primary_location
  log_analytics_workspace_id = var.platform_law_workspace_id

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Azure File share + script uploads - hosted on the existing corp-a1 synthetic
# storage account (shared-key auth already enabled there for the SCM deploy).
# ---------------------------------------------------------------------------

resource "azurerm_storage_share" "k6_scripts" {
  count              = local.k6_enabled
  name               = "k6-scripts"
  storage_account_id = azurerm_storage_account.corp_a1_synthetic[0].id
  quota              = 1 # GB - three small JS files
}

resource "azurerm_storage_share_file" "k6_script" {
  for_each = local.k6_enabled == 1 ? local.k6_jobs : {}

  name              = each.value.script
  storage_share_url = azurerm_storage_share.k6_scripts[0].url
  source            = "${path.module}/k6/${each.value.script}"
  content_md5       = filemd5("${path.module}/k6/${each.value.script}")
  content_type      = "application/javascript"
}

resource "azurerm_container_app_environment_storage" "k6_scripts" {
  count                        = local.k6_enabled
  name                         = "k6-scripts"
  container_app_environment_id = azurerm_container_app_environment.k6[0].id
  account_name                 = azurerm_storage_account.corp_a1_synthetic[0].name
  share_name                   = azurerm_storage_share.k6_scripts[0].name
  access_key                   = azurerm_storage_account.corp_a1_synthetic[0].primary_access_key
  access_mode                  = "ReadOnly"
}

# ---------------------------------------------------------------------------
# Three Container Apps Jobs (one per k6 scenario)
# ---------------------------------------------------------------------------

resource "azurerm_container_app_job" "k6" {
  for_each = local.k6_enabled == 1 ? local.k6_jobs : {}

  name                         = "caj-k6-${each.key}-${var.org_prefix}-${var.environment}"
  resource_group_name          = azurerm_resource_group.corp_a1_synthetic[0].name
  location                     = var.primary_location
  container_app_environment_id = azurerm_container_app_environment.k6[0].id

  replica_timeout_in_seconds = each.value.timeout_seconds
  replica_retry_limit        = each.value.retry_limit

  schedule_trigger_config {
    cron_expression          = each.value.cron
    parallelism              = each.value.parallelism
    replica_completion_count = each.value.replica_complete
  }

  template {
    container {
      name   = "k6"
      image  = "grafana/k6:latest"
      cpu    = each.value.cpu
      memory = each.value.memory

      # ENTRYPOINT in the grafana/k6 image is already ["k6"], so args alone are
      # enough to make this `k6 run /scripts/<scenario>.js`.
      args = ["run", "/scripts/${each.value.script}"]

      env {
        name  = "TARGET_BASE_URL"
        value = local.k6_target_base_url
      }

      env {
        name  = "K6_SCENARIO"
        value = each.key
      }

      volume_mounts {
        name = "scripts"
        path = "/scripts"
      }
    }

    volume {
      name         = "scripts"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.k6_scripts[0].name
    }
  }

  tags = local.common_tags

  depends_on = [azurerm_storage_share_file.k6_script]
}
