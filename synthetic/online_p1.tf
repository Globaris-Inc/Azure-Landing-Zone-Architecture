# Purpose: online-p1 synthetic workload — Storage Queue receiver for the public
#          landing-page contact form. Satisfies PROMPT.md §13.1 (online-p1
#          landing page contact form → Storage Queue).
# Section: 13.1 — Workload Targets
# Last updated: 2026-06-02
#
# Architecture:
#   - Dedicated synthetic RG in the primary region.
#   - Storage account with a `contact-form-submissions` queue.
#   - Queue diagnostic settings → Platform LAW so submissions show up in KQL.
#
# DEFERRED (not 13.1 infra scope):
#   - The landing-page HTML + client-side fetch() call (deployed to the Static
#     Web App).
#   - The Azure Function backing the SWA `/api/contact` route (writes the
#     submission onto this queue).
#   These artifacts are application code, owned by a separate CI step that
#   uses the `static_web_app_api_key` output from landing-zones/online-p1.

# ---------------------------------------------------------------------------
# Data sources — existing online-p1 resources from Section 9 (referenced for
# diagnostic settings + future contact-form Function deployment)
# ---------------------------------------------------------------------------

data "azurerm_resource_group" "online_p1_shared" {
  count = local.enabled
  name  = local.online_p1_shared_rg_name
}

# ---------------------------------------------------------------------------
# Synthetic resource group + storage account + queue
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "online_p1_synthetic" {
  count    = local.enabled
  name     = "rg-synthetic-online-p1-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_storage_account" "online_p1_synthetic" {
  count                    = local.enabled
  name                     = "stsynop1${var.org_prefix}${var.environment}${random_string.sa_suffix[0].result}"
  resource_group_name      = azurerm_resource_group.online_p1_synthetic[0].name
  location                 = var.primary_location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"

  # Public access on for the Static Web App Function to reach the queue (the
  # SWA managed Functions run in a Microsoft-hosted pool with no fixed egress
  # IPs). Defender for Storage covers anomaly detection.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false

  shared_access_key_enabled = true

  queue_properties {
    logging {
      delete                = true
      read                  = true
      write                 = true
      version               = "1.0"
      retention_policy_days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_queue" "contact_form" {
  count              = local.enabled
  name               = "contact-form-submissions"
  storage_account_id = azurerm_storage_account.online_p1_synthetic[0].id
}

# ---------------------------------------------------------------------------
# Diagnostic settings — queue plane → Platform LAW for KQL visibility
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "online_p1_queue" {
  count                      = local.enabled == 1 && var.platform_law_workspace_id != "" ? 1 : 0
  name                       = "diag-synthetic-online-p1-queue-to-platform-law"
  target_resource_id         = "${azurerm_storage_account.online_p1_synthetic[0].id}/queueServices/default"
  log_analytics_workspace_id = var.platform_law_workspace_id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  metric {
    category = "Transaction"
    enabled  = true
  }
}
