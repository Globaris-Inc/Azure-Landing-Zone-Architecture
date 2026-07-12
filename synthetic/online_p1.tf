# Purpose: online-p1 synthetic workload - Storage Queue receiver for the public
#          landing-page contact form. Satisfies PROMPT.md §13.1 (online-p1
#          landing page contact form → Storage Queue).
# Section: 13.1 - Workload Targets
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
# Data sources - existing online-p1 resources from Section 9 (referenced for
# diagnostic settings + future contact-form Function deployment)
# ---------------------------------------------------------------------------

data "azurerm_resource_group" "online_p1_shared" {
  count = local.enabled
  name  = local.online_p1_shared_rg_name
}

# Live online-p1 Application Gateway WAF_v2 public IP (internet-facing front
# door of the online-p1 spoke). This is the k6 load-test / synthetic app-traffic
# target after retargeting off the gated-off corp-a1 App Service (OQ-030
# decision B). The App Gateway listener is HTTP:80 and its access + WAF logs
# already flow to the platform LAW, so k6 traffic surfaces there as the
# app-traffic signal. Resolved by deterministic name, consistent with the other
# cross-root lookups in this root (no remote_state).
data "azurerm_public_ip" "online_p1_appgw" {
  count               = local.enabled
  name                = local.online_p1_appgw_pip_name
  resource_group_name = local.online_p1_network_rg_name
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
  count = local.enabled
  # Role token kept to 2 chars ("o1" = online-p1) so the rendered name stays
  # within the 24-char storage limit: stsyn(5) + o1(2) + globaris(8) + poc(3) +
  # 6-char suffix = 24. Matches the corp_a1 "a1" token convention.
  name                     = "stsyno1${var.org_prefix}${var.environment}${random_string.sa_suffix[0].result}"
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

  # Wait for the OQ-029 Waiver exemption to propagate before creating this public
  # SA, else the Deny-Public-Endpoints PUT races propagation and is denied
  # (ADR-028 race). No-op ordering when the exemptions are disabled.
  depends_on = [time_sleep.wait_synthetic_policy_exemptions]
}

resource "azurerm_storage_queue" "contact_form" {
  count              = local.enabled
  name               = "contact-form-submissions"
  storage_account_id = azurerm_storage_account.online_p1_synthetic[0].id
}

# ---------------------------------------------------------------------------
# Diagnostic settings - queue plane → Platform LAW for KQL visibility
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
