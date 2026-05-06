# Purpose: State backend infrastructure — RG, Key Vault (CMK), Storage Account.
# Section: 10a — Pipeline & Tooling (bootstrap subset)
# Last updated: 2026-05-05
#
# Resources created:
#   - Resource Group (Management sub, eastus2)
#   - User-Assigned Managed Identity (for Storage CMK)
#   - Key Vault with RBAC auth, soft-delete, purge protection (ADR-004)
#   - Key Vault RSA-2048 key (CMK for Storage)
#   - Storage Account (Standard GZRS, CMK, versioning, Entra-ID-only auth)
#   - Storage Container 'tfstate' with time-based immutability policy
#   - Role assignments: deployer → KV Crypto Officer; UAMI → KV Crypto Encryption User
#
# DEVIATION: Storage Account network rules allow public access from var.ip_allow_list
# (GitHub Actions IPs + deployer IP). Section 8 will add a Private Endpoint and disable
# public access entirely. See WORKLOG.md 2026-05-05 for rationale.
#
# DEVIATION: Immutability policy is set with locked = false. A locked policy prevents
# blob overwrites, which would break active Terraform state operations. The policy
# demonstrates WORM capability; flip locked = true only on a decommissioned/archived
# state container.

locals {
  common_tags = merge(
    {
      Environment  = "poc"
      ManagedBy    = "terraform"
      Section      = "10a-bootstrap"
      CostCenter   = "DEMO-9999"
      Owner        = "platform-team"
      BusinessUnit = "Platform Engineering"
      CreatedBy    = "bootstrap"
    },
    var.tags
  )
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Unique suffix — stable across applies, changes only if the random_string
# resource is tainted or destroyed.
# ---------------------------------------------------------------------------

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-tfstate-mgmt-eus2-001"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# User-Assigned Managed Identity (used by Storage Account for CMK)
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "tfstate" {
  name                = "id-tfstate-mgmt-eus2-001"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# Key Vault (RBAC-authorised, soft-delete, purge-protected — ADR-004)
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "tfstate" {
  name                = "kv-tfstate-${random_string.suffix.result}-001"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization  = true
  soft_delete_retention_days = var.kv_soft_delete_retention_days
  purge_protection_enabled   = true

  # Public network access is fine for the bootstrap KV (only used during one-time apply
  # and for Storage CMK — Azure Storage accesses the KV internally via trusted services).
  public_network_access_enabled = true

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Role assignments on the Key Vault
# ---------------------------------------------------------------------------

# Deployer (the principal running terraform apply) needs Crypto Officer to create keys.
resource "azurerm_role_assignment" "deployer_kv_crypto_officer" {
  scope                = azurerm_key_vault.tfstate.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# UAMI needs Crypto Service Encryption User so the Storage Account can unwrap/wrap the CMK.
resource "azurerm_role_assignment" "tfstate_uami_kv_crypto" {
  scope                = azurerm_key_vault.tfstate.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.tfstate.principal_id
}

# Azure RBAC propagation can take 30–60 s. Wait before creating the key and storage CMK.
resource "time_sleep" "wait_for_kv_rbac" {
  depends_on = [
    azurerm_role_assignment.deployer_kv_crypto_officer,
    azurerm_role_assignment.tfstate_uami_kv_crypto,
  ]
  create_duration = "60s"
}

# ---------------------------------------------------------------------------
# CMK Key
# ---------------------------------------------------------------------------

resource "azurerm_key_vault_key" "tfstate" {
  name         = "key-tfstate-cmk-001"
  key_vault_id = azurerm_key_vault.tfstate.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  # Rotate annually in production; for POC demo this is cosmetic only.
  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }
    expire_after         = "P1Y"
    notify_before_expiry = "P30D"
  }

  depends_on = [time_sleep.wait_for_kv_rbac]
  tags       = local.common_tags
}

# ---------------------------------------------------------------------------
# Storage Account (Standard GZRS, CMK, versioning, Entra-ID-only auth)
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "tfstate" {
  name                     = "sttfstate${random_string.suffix.result}001"
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "GZRS"
  account_kind             = "StorageV2"

  # Entra ID (RBAC) auth only — no shared access keys exposed.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true

  # UAMI provides the identity the Storage Account uses to call Key Vault.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.tfstate.id]
  }

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 14
    }

    container_delete_retention_policy {
      days = 14
    }
  }

  # DEVIATION: public network access is temporary.
  # GitHub Actions IPs + deployer home/work IPs provided via var.ip_allow_list.
  # Section 8 will add a Private Endpoint and set default_action = "Deny" with no ip_rules.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = var.ip_allow_list
  }

  tags = local.common_tags
}

# Apply CMK after the storage account exists and the UAMI role is propagated.
resource "azurerm_storage_account_customer_managed_key" "tfstate" {
  storage_account_id        = azurerm_storage_account.tfstate.id
  key_vault_id              = azurerm_key_vault.tfstate.id
  key_name                  = azurerm_key_vault_key.tfstate.name
  user_assigned_identity_id = azurerm_user_assigned_identity.tfstate.id

  depends_on = [time_sleep.wait_for_kv_rbac]
}

# ---------------------------------------------------------------------------
# Storage Container
# ---------------------------------------------------------------------------

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# DEVIATION: locked = false — see file header comment.
resource "azurerm_storage_container_immutability_policy" "tfstate" {
  storage_container_resource_manager_id = azurerm_storage_container.tfstate.resource_manager_id
  immutability_period_in_days           = 7
  locked                                = false
}

# ---------------------------------------------------------------------------
# Storage Blob Data Contributor — OIDC SP (defined in identity.tf)
# Role assignment is in identity.tf to keep all SP-related RBAC co-located.
# ---------------------------------------------------------------------------
