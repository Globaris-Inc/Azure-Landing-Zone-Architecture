# Purpose: Shared synthetic resource group + storage account for the workload
#          layer. Hosts the Azure File shares that k6 (13.2) and the red-team
#          simulator (13.3) mount for their scripts, and the blob/queue targets
#          the other sub-layers reuse.
# Section: 13.1 - Workload Targets
# Last updated: 2026-07-10
#
# Architecture:
#   - A dedicated synthetic resource group in the primary region.
#   - A general-purpose v2 storage account (public network, shared-key auth) that
#     the k6 and red-team file shares live on.
#
# RETARGET (OQ-030 decision B, 2026-07-10):
#   The original design deployed an Express REST API stub onto the corp-a1 App
#   Service and pointed k6 at it. That App Service was gated off at deploy time
#   (enable_app_service=false, ADR-032; the LZ-sub dedicated-compute quota ticket
#   is still open), so data.azurerm_linux_web_app.corp_a1 was a dead reference
#   that failed at plan with a 404. Per the user decision we do NOT re-enable
#   corp-a1 and do NOT gate the layer: the k6 load test is retargeted at the LIVE
#   online-p1 Application Gateway public endpoint (see online_p1.tf +
#   data.azurerm_public_ip.online_p1_appgw and k6.tf TARGET_BASE_URL). The
#   corp-a1 App Service data source, the zip-staging container, the archive_file
#   package, the container SAS, and the `az webapp deploy` null_resource are
#   removed because there is no App Service to deploy to and online-p1 already
#   serves a live app. The storage account below stays because k6 and the
#   red-team simulator mount file shares on it.

# ---------------------------------------------------------------------------
# Synthetic resource group - holds the shared storage account below (and, via
# other files, the k6 Container Apps environment/jobs and red-team shares).
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "corp_a1_synthetic" {
  count    = local.enabled
  name     = "rg-synthetic-corp-a1-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Storage account - Azure File shares for the k6 (13.2) and red-team (13.3)
# scripts mount onto this account. Shared-key auth is enabled so the Container
# Apps environment-storage links can use the account key.
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "corp_a1_synthetic" {
  count                    = local.enabled
  name                     = "stsyna1${var.org_prefix}${var.environment}${random_string.sa_suffix[0].result}"
  resource_group_name      = azurerm_resource_group.corp_a1_synthetic[0].name
  location                 = var.primary_location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"

  # Public access stays on so the Container Apps environments can mount the file
  # shares. Defender for Storage (Section 6) covers anomaly detection.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false

  # Shared keys enabled so the Container Apps environment-storage links can
  # authenticate to the file shares with the account key.
  shared_access_key_enabled = true

  blob_properties {
    versioning_enabled = true
  }

  tags = local.common_tags

  # Wait for the OQ-029 Waiver exemption to propagate before creating this public
  # SA, else the Deny-Public-Endpoints PUT races propagation and is denied
  # (ADR-028 race). No-op ordering when the exemptions are disabled.
  depends_on = [time_sleep.wait_synthetic_policy_exemptions]
}
