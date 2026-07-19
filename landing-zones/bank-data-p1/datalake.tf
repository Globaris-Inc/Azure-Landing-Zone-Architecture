# Purpose: bank-data-p1 ADLS Gen2 data lake (wave B5) - StorageV2 ZRS with
#          hierarchical namespace, PE-only (blob + dfs into snet-private-endpoints
#          on the live central zones), AAD-only data plane, one 'raw' filesystem,
#          storage-account-scope metrics to the platform LAW. Compliant BY DESIGN
#          with BOTH corp storage policy members (public access Disabled) - ZERO
#          policy exemption for this SA. Gated behind var.enable_data_platform
#          (default false, LESSON 42 flag pattern).
# Section: Banking wave B5 (docs/b5-data-platform-design.md section 7.1; ADR-048)
# Last updated: 2026-07-18
#
# Module (pin re-verified on the Terraform Registry 2026-07-18, schema read from the
# v0.7.3 tag sources - FIRST estate consumption of this module):
#   Azure/avm-res-storage-storageaccount/azurerm 0.7.3 (latest; azapi-shaped root -
#   takes parent_id = the RG resource ID, vnet-module precedent; the root's anchored
#   default azapi provider carries the landingzones sub, LESSON 23).
#
# Secure module DEFAULTS verified in the v0.7.3 source and STATED EXPLICITLY below
# per the design ruling: public_network_access_enabled false, shared_access_key_enabled
# false, network_rules default_action Deny (+ bypass AzureServices), min_tls_version
# TLS1_2, allow_nested_items_to_be_public false, Standard_ZRS.
# CMK deliberately OMITTED (B9 extension wave, ADR-046 precedent).
#
# Boundary note: Databricks does NOT consume this SA at B5 (no UC external locations,
# no mounts - design doc section 1). It is the lakehouse landing zone of the platform
# story and the B6 RAG source.

# ---------------------------------------------------------------------------
# Data lake SA name - rendered length (LESSON 27): "stlake" (6) + env "poc" (3) +
# "bdp1" (4) + 8 hex = 21 chars <= 24, lowercase alphanumeric only (flow-log SA
# naming precedent). Re-check if environment ever exceeds 6 chars.
# ---------------------------------------------------------------------------

resource "random_id" "datalake_sa" {
  for_each = var.enable_data_platform ? { main = "main" } : {}

  byte_length = 4
}

# ---------------------------------------------------------------------------
# ADLS Gen2 storage account + raw filesystem + blob/dfs private endpoints
# ---------------------------------------------------------------------------

module "datalake" {
  source  = "Azure/avm-res-storage-storageaccount/azurerm"
  version = "0.7.3"

  for_each = var.enable_data_platform ? { main = "main" } : {}

  name      = "stlake${var.environment}bdp1${random_id.datalake_sa[each.key].hex}"
  parent_id = azurerm_resource_group.workload.id
  location  = var.primary_location

  # ADLS Gen2: hierarchical namespace on (ForceNew - set at create).
  is_hns_enabled = true

  # Explicit statement of the 0.7.3 defaults (design doc section 7.1). NOTE:
  # account_sku_name WINS over the deprecated account_tier/account_replication_type
  # pair in 0.7.3, so the SKU is pinned via account_sku_name. ZRS gives the zone
  # story at near-zero GB cost.
  account_kind     = "StorageV2"
  account_sku_name = "Standard_ZRS"

  # Deny-by-design posture: compliant with the corp StorageDenyPaasPublicIP Deny
  # member AND the Audit member with NO exemption; AAD-only data plane matches the
  # B2/B3 estate bar (shared key off).
  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  network_rules = {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  # Minimal QA data-plane surface (design doc section 7.1).
  storage_data_lake_gen2_filesystems = {
    raw = {
      name = "raw"
    }
  }

  # Blob + dfs PEs into snet-private-endpoints; module-managed zone groups against
  # the central privatelink.blob/dfs zones (looked up in dns_links.tf, spoke-linked
  # since B1) - the estate's proven SQL/ACR/EH/SB zone-group pattern. The zone
  # groups write one A record into EACH zone (QA verifies both).
  private_endpoints_manage_dns_zone_group = true

  private_endpoints = {
    blob = {
      name                            = "pe-stlake-blob-bank-data-p1-${var.org_prefix}-${var.environment}"
      subnet_resource_id              = module.spoke_vnet.subnets["private-endpoints"].resource_id
      subresource_name                = "blob"
      private_dns_zone_resource_ids   = [data.azurerm_private_dns_zone.linked["blob"].id]
      private_service_connection_name = "psc-stlake-blob-bank-data-p1"
      tags                            = local.common_tags
    }
    dfs = {
      name                            = "pe-stlake-dfs-bank-data-p1-${var.org_prefix}-${var.environment}"
      subnet_resource_id              = module.spoke_vnet.subnets["private-endpoints"].resource_id
      subresource_name                = "dfs"
      private_dns_zone_resource_ids   = [data.azurerm_private_dns_zone.linked["dfs"].id]
      private_service_connection_name = "psc-stlake-dfs-bank-data-p1"
      tags                            = local.common_tags
    }
  }

  # Storage-account-scope diagnostics are METRICS-ONLY by Azure API constraint
  # (the 0.7.3 variable rejects logs entries at this scope - verified in the tag
  # source); note the per-service variable NAME (diagnostic_settings_storage_account,
  # not diagnostic_settings).
  diagnostic_settings_storage_account = {
    platform_law = {
      name                  = "diag-stlake-bank-data-p1-${var.org_prefix}-${var.environment}"
      workspace_resource_id = var.platform_law_workspace_id
      metrics = [
        {
          category = "AllMetrics"
        }
      ]
    }
  }

  tags = local.common_tags
}
