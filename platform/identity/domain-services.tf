# Purpose: Identity subscription domain services — native Microsoft Entra Domain
#          Services + a Recovery Services Vault for future DC/management VMs.
#          (Section 8 — G1 / Gap-Closure Wave 3 / ADR-010)
# Section: 8 — Standard Platform Components (Identity subscription)
# Last updated: 2026-06-28
#
# DEVIATION: there is NO AVM module for Entra Domain Services (the registry returns
# 404 for avm-res-aad-domainservice, confirmed 2026-06-25). This uses the native
# azurerm_active_directory_domain_service resource. It is current (not deprecated)
# in the pinned provider azurerm ~> 4.71.
#
# MANUAL OPERATOR PREREQUISITE (NOT automatable — see README.md): before apply an
# operator must create the "Domain Controller Services" enterprise application /
# service principal and an "AAD DC Administrators" group in the tenant. Terraform
# cannot create the Entra DS publisher SP.

# ---------------------------------------------------------------------------
# Microsoft Entra Domain Services (managed)
#
# Argument shape VERIFIED against the pinned provider (azurerm ~> 4.71.0, resolved
# 4.71.x) via `terraform providers schema -json` on 2026-06-28:
#   - domain_name, sku, location, name, resource_group_name : required (string)
#   - sku = "Standard" : valid (single replica set, lowest cost ~$110/mo)
#   - initial_replica_set { subnet_id } : list block (min 1, max 1); subnet_id REQUIRED
#   - filtered_sync_enabled : top-level OPTIONAL bool (NOT a block — the plan's
#     "filtered_sync" shorthand maps to this attribute name)
#   - notifications { notify_dc_admins, notify_global_admins, additional_recipients }
#     : optional list block (max 1)
#   - security { ntlm_v1_enabled, tls_v1_enabled, sync_ntlm_passwords, ... }
#     : optional list block (max 1)
#   - secure_ldap : optional list block (left unset — disabled; would require a PFX cert)
# ---------------------------------------------------------------------------

resource "azurerm_active_directory_domain_service" "this" {
  provider = azurerm.identity
  count    = local.entra_ds_enabled ? 1 : 0

  name                = "aadds-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.identity_aadds[0].name
  location            = var.identity_location

  domain_name = var.identity_domain_name
  sku         = "Standard" # Single replica set; lowest-cost SKU (ADR-010 cost posture).

  # Sync the whole directory (false = no scoped/filtered sync) for the POC.
  filtered_sync_enabled = false

  initial_replica_set {
    subnet_id = module.identity_vnet[0].subnets["entra-ds"].resource_id
  }

  # Harden the managed domain: disable legacy/insecure protocols. These mirror the
  # Microsoft-recommended secure baseline for a greenfield managed domain.
  security {
    ntlm_v1_enabled         = false
    tls_v1_enabled          = false
    sync_ntlm_passwords     = false
    sync_kerberos_passwords = false
    sync_on_prem_passwords  = false # Cloud-only POC; no on-prem AD Connect sync.
  }

  notifications {
    notify_dc_admins     = true
    notify_global_admins = true
  }

  tags = local.identity_common_tags

  # The managed domain provisions into the Entra DS subnet; ensure the VNet/subnet
  # and its NSG exist first. (count-indexed refs already create implicit deps; the
  # explicit list keeps apply ordering unambiguous.)
  depends_on = [
    module.identity_vnet,
    azurerm_network_security_group.entra_ds,
  ]
}

# ---------------------------------------------------------------------------
# Recovery Services Vault — identity subscription
# Module: Azure/avm-res-recoveryservices-vault/azurerm v1.1.3
# Same module + pin as G4/corp-a1 (avoid version skew). For future DC/management
# VM backups. Gated on identity_mode != "none" (exists for both entra-ds and ad-ds).
# ---------------------------------------------------------------------------

module "identity_recovery_services_vault" {
  source  = "Azure/avm-res-recoveryservices-vault/azurerm"
  version = "1.1.3"

  providers = {
    azurerm = azurerm.identity
  }

  count = local.identity_enabled ? 1 : 0

  name                = "rsv-identity-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.identity_aadds[0].name
  location            = var.identity_location

  sku = "Standard"

  # ZoneRedundant: identity is an in-region primary pillar (cross_region_restore is
  # GeoRedundant-only, so it must stay false). Matches the corp-a1 RSV posture.
  storage_mode_type            = var.identity_rsv_storage_mode_type
  cross_region_restore_enabled = false

  soft_delete_enabled           = true
  immutability                  = "Unlocked"
  public_network_access_enabled = false

  tags = local.identity_common_tags
}
