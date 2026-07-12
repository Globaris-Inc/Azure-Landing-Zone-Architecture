# Purpose: Red-team simulator - 5 Container Apps Jobs producing the security
#          signals listed in PROMPT.md §13.3.
# Section: 13.3 - Synthetic Security Signals
# Last updated: 2026-06-04
#
# Architecture:
#   - Primary CAE (eastus2) is reused from §13.2.
#   - Secondary CAE in `red_team_geo_location` (default westeurope) hosts the
#     impossible-travel west pole - distinct geo IP is the whole point.
#   - One Azure File share `red-team-scripts` on the existing corp-a1 synthetic
#     SA. Both CAEs mount it (cross-region for westeurope - fine for ~5 KB
#     bash files).
#   - Decoy Storage Account (eastus2, public network, Defender for Storage on
#     via §6) holds a small dummy blob. The `storage_anomaly` CAJ's MI has
#     Storage Blob Data Reader → can read → the burst registers as
#     `StorageBlobLogs` rows.
#   - Decoy Key Vault (eastus2, RBAC mode, public network). MI gets only
#     Key Vault Reader (control plane). `az keyvault secret show` always
#     fails 403 - that is the §6 "KV bulk secret access" signal.
#   - All red-team resources + jobs tagged `Purpose = "SecuritySimulation"`
#     merged into local.common_tags so a single KQL filter cleanly separates
#     synthetic noise from real telemetry.
#
# DEVIATIONS vs PROMPT.md:
#   - PROMPT.md says "ACI" for the red-team simulator. Implementing as
#     Container Apps Jobs for consistency with §13.2 (native cron + native LAW
#     shipping). The geographic separation that drives impossible-travel still
#     works - two CAEs in two regions yield two outbound IP pools.
#   - PROMPT.md asks for a dedicated `synthetic-events` LAW custom table via
#     DCE/DCR. Going with `ContainerAppConsoleLogs_CL` plus tag-based KQL
#     filtering - same separation outcome, far less plumbing. The DCR/DCE path
#     is a §13.x refinement once we want strict schema control.
#   - The honeypot Entra user (`svc-honeypot@<tenant>`) is **not** created by
#     Terraform - synthetic doesn't carry the azuread provider, and the user
#     account is a one-off manual artifact (must be created Disabled). See
#     synthetic/README.md for the manual step.

# ---------------------------------------------------------------------------
# Locals - 13.3 sub-gate + scenario catalogue
# ---------------------------------------------------------------------------

locals {
  # Red-team requires the Platform LAW (Container Apps Environment needs it)
  # - same precondition as 13.2.
  red_team_enabled = local.k6_enabled

  # Sign-in scenarios need a honeypot UPN. Without one the failed-signin-burst
  # and impossible-travel jobs are skipped; the other three still ship.
  red_team_signin_enabled = local.red_team_enabled == 1 && var.honeypot_user_principal_name != "" ? 1 : 0

  red_team_signin_jobs = {
    failed_signin_burst = {
      script          = "failed_signin_burst.sh"
      cron            = "15 */4 * * *" # every 4h at :15
      cae             = "primary"
      timeout_seconds = 900
      cpu             = 0.25
      memory          = "0.5Gi"
      env = {
        ATTEMPTS = "12"
      }
    }
    impossible_travel_east = {
      script          = "impossible_travel.sh"
      cron            = "0 */6 * * *" # every 6h on the hour
      cae             = "primary"
      timeout_seconds = 300
      cpu             = 0.25
      memory          = "0.5Gi"
      env = {
        POLE_LABEL = "east"
      }
    }
    impossible_travel_west = {
      script          = "impossible_travel.sh"
      cron            = "5 */6 * * *" # every 6h at :05 - 5 minutes after east pole
      cae             = "secondary"
      timeout_seconds = 300
      cpu             = 0.25
      memory          = "0.5Gi"
      env = {
        POLE_LABEL = "west"
      }
    }
  }

  red_team_infra_jobs = {
    resource_anomaly = {
      script          = "resource_anomaly.sh"
      cron            = "30 */6 * * *" # every 6h at :30
      cae             = "primary"
      timeout_seconds = 900
      cpu             = 0.25
      memory          = "0.5Gi"
      env             = {} # SUBSCRIPTION_ID / TARGET_RG / LOCATION injected from refs below
    }
    storage_anomaly = {
      script          = "storage_anomaly.sh"
      cron            = "45 */6 * * *" # every 6h at :45
      cae             = "primary"
      timeout_seconds = 600
      cpu             = 0.5
      memory          = "1.0Gi"
      env = {
        ATTEMPTS = "500"
      }
    }
    kv_probing = {
      script          = "kv_probing.sh"
      cron            = "55 */6 * * *" # every 6h at :55
      cae             = "primary"
      timeout_seconds = 600
      cpu             = 0.25
      memory          = "0.5Gi"
      env = {
        ATTEMPTS = "25"
      }
    }
  }

  red_team_jobs = local.red_team_enabled == 1 ? merge(
    local.red_team_infra_jobs,
    local.red_team_signin_enabled == 1 ? local.red_team_signin_jobs : {},
  ) : {}

  red_team_tags = merge(
    local.common_tags,
    {
      Purpose  = "SecuritySimulation"
      Scenario = "red-team"
    },
  )

  red_team_image = "mcr.microsoft.com/azure-cli:2.66.0"
}

# ---------------------------------------------------------------------------
# Subscription ref - scripts call az login --identity, then az account set
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Resource groups
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "red_team_primary" {
  count    = local.red_team_enabled
  name     = "rg-synthetic-red-team-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.red_team_tags
}

resource "azurerm_resource_group" "red_team_secondary" {
  count    = local.red_team_signin_enabled # only needed for the west pole
  name     = "rg-synthetic-red-team-${var.org_prefix}-${var.environment}-secondary"
  location = var.red_team_geo_location
  tags     = local.red_team_tags
}

# ---------------------------------------------------------------------------
# Decoy storage account (mass-blob-download target)
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "red_team_decoy" {
  count = local.red_team_enabled
  # Role token kept to 2 chars ("rt" = red-team) so the rendered name stays
  # within the 24-char storage limit: stsyn(5) + rt(2) + globaris(8) + poc(3) +
  # 6-char suffix = 24. Matches the corp_a1 "a1" token convention.
  name                     = "stsynrt${var.org_prefix}${var.environment}${random_string.sa_suffix[0].result}"
  resource_group_name      = azurerm_resource_group.red_team_primary[0].name
  location                 = var.primary_location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"

  # Public access on so the MI can reach the blob over its outbound IP.
  # Defender for Storage (Section 6) covers the anomaly detection layer.
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false

  # Shared keys enabled so Terraform's azurerm_storage_blob upload works through
  # the provider's shared-key path. The MI-driven storage_anomaly script reads
  # via Entra (Storage Blob Data Reader) - Entra is the auth path that lands
  # in StorageBlobLogs as the §6 detection signal.
  shared_access_key_enabled = true

  blob_properties {
    versioning_enabled = false
  }

  tags = local.red_team_tags

  # Wait for the OQ-029 Waiver exemption to propagate before creating this public
  # decoy SA, else the Deny-Public-Endpoints PUT races propagation and is denied
  # (ADR-028 race). No-op ordering when the exemptions are disabled.
  depends_on = [time_sleep.wait_synthetic_policy_exemptions]
}

resource "azurerm_storage_container" "decoy" {
  count                 = local.red_team_enabled
  name                  = "decoy"
  storage_account_id    = azurerm_storage_account.red_team_decoy[0].id
  container_access_type = "private"
}

resource "azurerm_storage_blob" "decoy_target" {
  count                  = local.red_team_enabled
  name                   = "decoy-target.bin"
  storage_account_name   = azurerm_storage_account.red_team_decoy[0].name
  storage_container_name = azurerm_storage_container.decoy[0].name
  type                   = "Block"
  source_content         = "synthetic decoy payload - section 13.3 - not real data"
}

# ---------------------------------------------------------------------------
# Decoy Key Vault (failed Get-Secret target)
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "red_team_decoy" {
  count                      = local.red_team_enabled
  name                       = "kv-rt-${var.org_prefix}-${random_string.sa_suffix[0].result}"
  resource_group_name        = azurerm_resource_group.red_team_primary[0].name
  location                   = var.primary_location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  rbac_authorization_enabled    = true
  public_network_access_enabled = true

  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow"
  }

  tags = local.red_team_tags

  # Wait for the OQ-029 Waiver exemption to propagate before creating this public
  # decoy KV, else the Deny-Public-Endpoints PUT races propagation and is denied
  # (ADR-028 race). No-op ordering when the exemptions are disabled.
  depends_on = [time_sleep.wait_synthetic_policy_exemptions]
}

# Diagnostic settings - KV → Platform LAW so probing attempts surface in KQL.
resource "azurerm_monitor_diagnostic_setting" "red_team_kv" {
  count                      = local.red_team_enabled
  name                       = "diag-rt-kv-to-platform-law"
  target_resource_id         = azurerm_key_vault.red_team_decoy[0].id
  log_analytics_workspace_id = var.platform_law_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Diagnostic settings - Decoy SA blob plane → Platform LAW for mass-download visibility.
resource "azurerm_monitor_diagnostic_setting" "red_team_decoy_blob" {
  count                      = local.red_team_enabled
  name                       = "diag-rt-decoy-blob-to-platform-law"
  target_resource_id         = "${azurerm_storage_account.red_team_decoy[0].id}/blobServices/default"
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

# ---------------------------------------------------------------------------
# Secondary CAE in red_team_geo_location (impossible-travel west pole)
# ---------------------------------------------------------------------------

resource "azurerm_container_app_environment" "red_team_secondary" {
  count                      = local.red_team_signin_enabled
  name                       = "cae-rt-secondary-${var.org_prefix}-${var.environment}"
  resource_group_name        = azurerm_resource_group.red_team_secondary[0].name
  location                   = var.red_team_geo_location
  log_analytics_workspace_id = var.platform_law_workspace_id

  tags = local.red_team_tags
}

# ---------------------------------------------------------------------------
# Red-team scripts share + uploads - reuses corp-a1 synthetic SA (eastus2)
# ---------------------------------------------------------------------------

resource "azurerm_storage_share" "red_team_scripts" {
  count              = local.red_team_enabled
  name               = "red-team-scripts"
  storage_account_id = azurerm_storage_account.corp_a1_synthetic[0].id
  quota              = 1
}

resource "azurerm_storage_share_file" "red_team_script" {
  for_each = local.red_team_enabled == 1 ? toset([
    "failed_signin_burst.sh",
    "impossible_travel.sh",
    "resource_anomaly.sh",
    "storage_anomaly.sh",
    "kv_probing.sh",
  ]) : []

  name              = each.value
  storage_share_url = azurerm_storage_share.red_team_scripts[0].url
  source            = "${path.module}/red_team/scripts/${each.value}"
  content_md5       = filemd5("${path.module}/red_team/scripts/${each.value}")
  content_type      = "application/x-sh"
}

# CAE → share link (primary). The k6 CAE from §13.2 gets a second
# environment_storage pointing at the red-team scripts share.
resource "azurerm_container_app_environment_storage" "red_team_scripts_primary" {
  count                        = local.red_team_enabled
  name                         = "red-team-scripts"
  container_app_environment_id = azurerm_container_app_environment.k6[0].id
  account_name                 = azurerm_storage_account.corp_a1_synthetic[0].name
  share_name                   = azurerm_storage_share.red_team_scripts[0].name
  access_key                   = azurerm_storage_account.corp_a1_synthetic[0].primary_access_key
  access_mode                  = "ReadOnly"
}

# CAE → share link (secondary). Cross-region access - Azure Files over HTTPS
# handles it; the ~5 KB script latency penalty per job start is negligible.
resource "azurerm_container_app_environment_storage" "red_team_scripts_secondary" {
  count                        = local.red_team_signin_enabled
  name                         = "red-team-scripts"
  container_app_environment_id = azurerm_container_app_environment.red_team_secondary[0].id
  account_name                 = azurerm_storage_account.corp_a1_synthetic[0].name
  share_name                   = azurerm_storage_share.red_team_scripts[0].name
  access_key                   = azurerm_storage_account.corp_a1_synthetic[0].primary_access_key
  access_mode                  = "ReadOnly"
}

# ---------------------------------------------------------------------------
# Container Apps Jobs - one per scenario
# ---------------------------------------------------------------------------

resource "azurerm_container_app_job" "red_team" {
  for_each = local.red_team_jobs

  name                = "caj-rt-${replace(each.key, "_", "-")}-${var.org_prefix}-${var.environment}"
  resource_group_name = each.value.cae == "secondary" ? azurerm_resource_group.red_team_secondary[0].name : azurerm_resource_group.red_team_primary[0].name
  location            = each.value.cae == "secondary" ? var.red_team_geo_location : var.primary_location

  container_app_environment_id = each.value.cae == "secondary" ? azurerm_container_app_environment.red_team_secondary[0].id : azurerm_container_app_environment.k6[0].id

  replica_timeout_in_seconds = each.value.timeout_seconds
  replica_retry_limit        = 0

  schedule_trigger_config {
    cron_expression          = each.value.cron
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type = "SystemAssigned"
  }

  template {
    container {
      name    = "rt-${replace(each.key, "_", "-")}"
      image   = local.red_team_image
      cpu     = each.value.cpu
      memory  = each.value.memory
      command = ["/bin/bash"]
      args    = ["/scripts/${each.value.script}"]

      env {
        name  = "SCENARIO"
        value = replace(each.key, "_", "-")
      }

      env {
        name  = "TENANT_ID"
        value = data.azurerm_client_config.current.tenant_id
      }

      env {
        name  = "SUBSCRIPTION_ID"
        value = var.landingzones_subscription_id
      }

      env {
        name  = "HONEYPOT_UPN"
        value = var.honeypot_user_principal_name
      }

      env {
        name  = "TARGET_RG"
        value = azurerm_resource_group.red_team_primary[0].name
      }

      env {
        name  = "LOCATION"
        value = var.primary_location
      }

      env {
        name  = "DECOY_STORAGE_ACCOUNT"
        value = azurerm_storage_account.red_team_decoy[0].name
      }

      env {
        name  = "DECOY_CONTAINER"
        value = azurerm_storage_container.decoy[0].name
      }

      env {
        name  = "DECOY_BLOB"
        value = azurerm_storage_blob.decoy_target[0].name
      }

      env {
        name  = "DECOY_KEY_VAULT_NAME"
        value = azurerm_key_vault.red_team_decoy[0].name
      }

      dynamic "env" {
        for_each = each.value.env
        content {
          name  = env.key
          value = env.value
        }
      }

      volume_mounts {
        name = "red-team-scripts"
        path = "/scripts"
      }
    }

    volume {
      name         = "red-team-scripts"
      storage_type = "AzureFile"
      storage_name = each.value.cae == "secondary" ? azurerm_container_app_environment_storage.red_team_scripts_secondary[0].name : azurerm_container_app_environment_storage.red_team_scripts_primary[0].name
    }
  }

  tags = local.red_team_tags

  depends_on = [azurerm_storage_share_file.red_team_script]
}

# ---------------------------------------------------------------------------
# Role assignments - narrow MI privileges per scenario
# ---------------------------------------------------------------------------

# resource_anomaly: create + delete public IPs in the red-team primary RG.
resource "azurerm_role_assignment" "rt_resource_anomaly_net_contrib" {
  count                = local.red_team_enabled
  scope                = azurerm_resource_group.red_team_primary[0].id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_container_app_job.red_team["resource_anomaly"].identity[0].principal_id
}

# storage_anomaly: read blobs from the decoy SA.
resource "azurerm_role_assignment" "rt_storage_anomaly_blob_reader" {
  count                = local.red_team_enabled
  scope                = azurerm_storage_account.red_team_decoy[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_container_app_job.red_team["storage_anomaly"].identity[0].principal_id
}

# kv_probing: control-plane Reader only - secret GETs always fail authorization,
# which is the §6 "KV bulk secret access denied" signal source.
resource "azurerm_role_assignment" "rt_kv_probing_kv_reader" {
  count                = local.red_team_enabled
  scope                = azurerm_key_vault.red_team_decoy[0].id
  role_definition_name = "Key Vault Reader"
  principal_id         = azurerm_container_app_job.red_team["kv_probing"].identity[0].principal_id
}
