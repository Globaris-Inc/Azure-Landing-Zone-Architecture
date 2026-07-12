# Purpose: corp-a1 landing zone - Recovery Services Vault for Azure Backup /
#          Azure Site Recovery (parity with corp-a2; ADR-012 / gap-closure Wave 2 G4).
# Section: 9 - Landing Zone Spokes
# Last updated: 2026-06-25
#
# Architecture:
#   - Recovery Services Vault (Standard) in the corp-a1 shared RG (rg-corp-a1-shared-*).
#   - Storage mode ZoneRedundant: corp-a1 is the in-region primary spoke, so backup
#     data is kept zone-redundant within eastus2 (corp-a2, the DR spoke, stays
#     GeoRedundant - do not change corp-a2). Cross-region restore is a GeoRedundant-only
#     capability and is therefore disabled here.
#   - The vault is created bare here; backup/ASR policies and item enrolment are
#     configured later (Section 13) once source VMs exist - mirroring corp-a2, which
#     defines no backup policy at vault-creation time.

# ---------------------------------------------------------------------------
# Recovery Services Vault
# Module: Azure/avm-res-recoveryservices-vault/azurerm v1.1.3
# Pinned to match corp-a2 (avoid cross-spoke version skew; a joint uplift to a
# newer pin across both spokes is a separate change per the gap-closure plan).
# Module + pin confirmed against the existing corp-a2 call (landing-zones/corp-a2/main.tf).
# ---------------------------------------------------------------------------

module "recovery_services_vault" {
  source  = "Azure/avm-res-recoveryservices-vault/azurerm"
  version = "1.1.3"

  name                = "rsv-corp-a1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.primary_location

  # Standard SKU; RS0 is legacy (pre-2017 vaults only).
  sku = "Standard"

  # ZoneRedundant keeps backup data resilient across availability zones within the
  # primary region. cross_region_restore is GeoRedundant-only, so it must be false.
  # Verified: the module's storage_mode_type validation (variables.tf) accepts
  # "ZoneRedundant" in v1.1.3 (regex ^(GeoRedundant|LocallyRedundant|ZoneRedundant)$),
  # confirmed against the downloaded module source on init 2026-06-25.
  storage_mode_type            = var.rsv_storage_mode_type
  cross_region_restore_enabled = false

  soft_delete_enabled           = true
  immutability                  = "Unlocked"
  public_network_access_enabled = false

  tags = local.common_tags
}
