# Purpose: State backend infrastructure - RG, Key Vault (CMK), Storage Account.
# Section: 10a - Pipeline & Tooling (bootstrap subset)
# Last updated: 2026-07-06
#
# NOTE (ADR-069, 2026-07-30): the state backend STAYS in eastus2 and is deliberately
# NOT co-located with the estate's primary workload region, which ADR-069 moved to
# centralus. The `eus2` token in rg-tfstate-mgmt-eus2-001 and id-tfstate-mgmt-eus2-001
# is therefore historical, and that is accepted with a written reason rather than
# renamed. Why: (a) azurerm_key_vault.tfstate is purge-protected with 90-day
# soft-delete retention, so a purge-protected vault CANNOT be purged and the vault
# name would be blocked for 90 days after a delete - a LESSON 57 class failure that no
# retry recovers; (b) state is a management-plane dependency with no data-plane
# coupling, no latency requirement, no policy scope and no role in the DR story;
# (c) anti-correlation is the better posture - keeping state OUT of the primary
# workload region means a centralus regional event still leaves state readable, so the
# estate can be planned and applied during the incident; (d) moving it means destroying
# the state SA, the CMK vault and the UAMI, rewriting envs/poc.backend.hcl and running
# -migrate-state across eleven roots, on the one layer deliberately excluded from
# teardown. var.primary_location in THIS root is local-state and load-bearing (bootstrap
# is not run through _tf-root.yml, so it never receives -var-file=envs/poc.tfvars);
# it is NOT part of the ADR-069 region surface and must not be flipped.
# See ADR-069 decision 4 / docs/region-flip-centralus-primary.md section 3.3.
#
# Resources created:
#   - Resource Group (Management sub, eastus2)
#   - User-Assigned Managed Identity (for Storage CMK)
#   - Key Vault with RBAC auth, soft-delete, purge protection (ADR-004)
#   - Key Vault RSA-2048 key (CMK for Storage)
#   - Storage Account (Standard GZRS, CMK, versioning, Entra-ID-only auth)
#   - Storage Container 'tfstate' (protected by versioning + 14-day soft-delete)
#   - Role assignments: deployer → KV Crypto Officer; UAMI → KV Crypto Encryption User
#
# DEVIATION: Storage Account network rules allow public access from var.ip_allow_list
# (GitHub Actions IPs + deployer IP). Section 8 will add a Private Endpoint and disable
# public access entirely. See WORKLOG.md 2026-05-05 for rationale.
#
# NOTE (ADR-024, 2026-07-06): a container WORM immutability policy was removed. Even
# UNLOCKED it broke Terraform state operations - the azurerm backend takes a blob
# lease (lock) on every run, which a container time-based retention policy rejects
# with 409 BlobImmutableDueToPolicy, versioning notwithstanding. State protection is
# provided by blob versioning + 14-day blob/container soft-delete + Entra-only access.

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

  # Azure Storage account ip_rules reject a /31 or /32 suffix: a single host must
  # be a bare IPv4, and CIDR ranges must be /0-/30. Strip a trailing /32 so an
  # operator can write the natural "1.2.3.4/32" form in ip_allow_list.
  storage_ip_rules = [for ip in var.ip_allow_list : trimsuffix(ip, "/32")]

  # Instance/sequence for the globally-unique names (state Storage Account, Key
  # Vault). Deterministic org-prefix + sequence, no random suffix. Bump if a name
  # is ever globally taken.
  instance = "01"
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

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
# Key Vault (RBAC-authorised, soft-delete, purge-protected - ADR-004)
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "tfstate" {
  name                = "kv-${var.org_prefix}-tfstate-${local.instance}"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization  = true
  soft_delete_retention_days = var.kv_soft_delete_retention_days
  purge_protection_enabled   = true

  # Public network access is fine for the bootstrap KV (only used during one-time apply
  # and for Storage CMK - Azure Storage accesses the KV internally via trusted services).
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

# Azure RBAC propagation can take 30-60 s. Wait before creating the key and storage CMK.
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
  name                     = "st${var.org_prefix}tfstate${local.instance}"
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "GZRS"
  account_kind             = "StorageV2"

  # Entra ID (RBAC) auth only - no shared access keys exposed.
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
    ip_rules       = local.storage_ip_rules
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

# REMOVED 2026-07-06 (ADR-024): a container-level WORM immutability policy is
# incompatible with the Terraform azurerm backend. Every state operation takes a
# blob lease (lock) and rewrites the state blob; a container time-based retention
# policy rejects the lease/write with HTTP 409 BlobImmutableDueToPolicy - even
# with versioning enabled (versioning protects overwrites, not the lock path).
# It broke the first post-policy state init (platform/connectivity) and would
# have broken every future apply on existing roots too. State immutability is not
# the right protection model here; the SA already provides blob versioning +
# 14-day blob/container soft-delete + Entra-only (no shared-key) access, which is
# the correct, backend-compatible protection. The policy was `locked = false`, so
# it was removable.

# ---------------------------------------------------------------------------
# Storage Blob Data Contributor - OIDC SP (defined in identity.tf)
# Role assignment is in identity.tf to keep all SP-related RBAC co-located.
# ---------------------------------------------------------------------------
