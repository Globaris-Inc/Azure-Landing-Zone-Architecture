# Purpose: corp-a1 synthetic workload — Express REST API stub deployed onto the
#          App Service provisioned in Section 9. Satisfies PROMPT.md §13.1
#          (workload targets: /api/products, /api/login, /api/checkout).
# Section: 13.1 — Workload Targets
# Last updated: 2026-06-02
#
# Architecture:
#   - Data sources resolve the existing corp-a1 workload RG + App Service by
#     deterministic name (matches landing-zones/corp-a1 naming).
#   - A dedicated synthetic resource group hosts the code-staging storage account.
#   - `archive_file` packages synthetic/apps/corp-a1-api/ into a zip.
#   - `azurerm_storage_blob` uploads the zip.
#   - A read-only SAS URL is minted on the container.
#   - `null_resource` shells out to `az webapp deploy` to land the zip on the
#     App Service whenever the zip checksum changes.
#
# DEVIATIONS:
#   - Imperative `az` deploy via null_resource: Terraform has no first-class
#     resource for "deploy a zip to an existing App Service" without taking
#     ownership of source_control / app_settings (both already owned by the
#     corp-a1 AVM module). The az invocation only touches /home/site/wwwroot
#     and the existing `WEBSITE_RUN_FROM_PACKAGE=1` app setting (owned by
#     corp-a1) makes that zip the source of truth at runtime. Production path:
#     replace with a GitHub Actions deploy job downstream of `apply-synthetic`.
#   - SQL connectivity not wired: the REST API stub returns in-memory data so
#     /api/products has something to demo. Wiring the SQL Private Endpoint +
#     System-Assigned Managed Identity → DB role grant is deferred to 13.x
#     refinement once the demo flow is locked in.

# ---------------------------------------------------------------------------
# Data sources — existing corp-a1 resources from Section 9
# ---------------------------------------------------------------------------

data "azurerm_resource_group" "corp_a1_workload" {
  count = local.enabled
  name  = local.corp_a1_workload_rg_name
}

data "azurerm_linux_web_app" "corp_a1" {
  count               = local.enabled
  name                = local.corp_a1_app_service_name
  resource_group_name = data.azurerm_resource_group.corp_a1_workload[0].name
}

# ---------------------------------------------------------------------------
# Synthetic resource group — holds code-staging storage and (in 13.3/13.4)
# the red-team simulator and cost-pattern targets.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "corp_a1_synthetic" {
  count    = local.enabled
  name     = "rg-synthetic-corp-a1-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Storage account — code zip staging + (later) blob-anomaly target for 13.3
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

  # Public access stays on — the App Service fetches the deployment zip via SAS URL
  # over the internet. Defender for Storage (Section 6) covers anomaly detection.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false

  # Shared keys enabled so Terraform can mint a container SAS for the SCM deploy
  # call. Entra-only auth would force us to use a User-Assigned MI + the data
  # plane, which is heavier than this POC's scope.
  shared_access_key_enabled = true

  blob_properties {
    versioning_enabled = true
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "corp_a1_code" {
  count                 = local.enabled
  name                  = "code"
  storage_account_id    = azurerm_storage_account.corp_a1_synthetic[0].id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Build + upload the deployment zip
# ---------------------------------------------------------------------------

data "archive_file" "corp_a1_api" {
  count       = local.enabled
  type        = "zip"
  source_dir  = "${path.module}/apps/corp-a1-api"
  output_path = "${path.module}/.build/corp-a1-api.zip"
}

resource "azurerm_storage_blob" "corp_a1_api" {
  count                  = local.enabled
  name                   = "corp-a1-api-${data.archive_file.corp_a1_api[0].output_md5}.zip"
  storage_account_name   = azurerm_storage_account.corp_a1_synthetic[0].name
  storage_container_name = azurerm_storage_container.corp_a1_code[0].name
  type                   = "Block"
  content_md5            = data.archive_file.corp_a1_api[0].output_md5
  source                 = data.archive_file.corp_a1_api[0].output_path
}

# Read-only SAS URL — App Service Kudu fetches the zip from this URL.
# 1-hour validity is enough for the `az webapp deploy` call to complete.
#
# Note: start/expiry recompute on every plan via timestamp(). The data source
# re-reads silently (no apply-time diff) and the null_resource only re-runs
# when its `triggers` (zip md5) change, so plan noise is bounded.
data "azurerm_storage_account_blob_container_sas" "corp_a1_code" {
  count             = local.enabled
  connection_string = azurerm_storage_account.corp_a1_synthetic[0].primary_connection_string
  container_name    = azurerm_storage_container.corp_a1_code[0].name
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
# Deploy the zip onto the existing App Service
#
# Triggers re-execution only when the zip content changes (md5 hash). The
# `WEBSITE_RUN_FROM_PACKAGE=1` app setting owned by the corp-a1 module makes
# the deployed zip the runtime source of truth.
# ---------------------------------------------------------------------------

resource "null_resource" "corp_a1_deploy" {
  count = local.enabled

  triggers = {
    zip_md5     = data.archive_file.corp_a1_api[0].output_md5
    app_service = data.azurerm_linux_web_app.corp_a1[0].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      az webapp deploy \
        --resource-group "${data.azurerm_resource_group.corp_a1_workload[0].name}" \
        --name "${data.azurerm_linux_web_app.corp_a1[0].name}" \
        --src-url "https://${azurerm_storage_account.corp_a1_synthetic[0].name}.blob.core.windows.net/${azurerm_storage_container.corp_a1_code[0].name}/${azurerm_storage_blob.corp_a1_api[0].name}${data.azurerm_storage_account_blob_container_sas.corp_a1_code[0].sas}" \
        --type zip \
        --async false
    EOT
  }

  depends_on = [azurerm_storage_blob.corp_a1_api]
}
