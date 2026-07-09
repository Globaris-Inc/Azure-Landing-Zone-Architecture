# Purpose: Identity subscription domain services — native Microsoft Entra Domain
#          Services + a Recovery Services Vault for future DC/management VMs.
#          (Section 8 — G1 / Gap-Closure Wave 3 / ADR-010)
# Section: 8 — Standard Platform Components (Identity subscription)
# Last updated: 2026-07-08
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

# Microsoft.AAD RP registration - identity subscription. Verified NotRegistered live
# on 2026-07-08 (pre-deploy constraint sweep), and Microsoft.AAD is in NONE of the
# azurerm v4.71.0 auto-register sets (internal/resourceproviders/required.go at the
# v4.71.0 tag: absent from Core/Extended/All/Legacy), so without this the managed
# domain create fails with the RP-not-registered 400 class (same class as
# Microsoft.CostManagementExports, run 28909509585). The CI SP holds Contributor on
# the identity sub, which includes */register/action. Create blocks until the RP
# reports Registered (2h timeout).
resource "azurerm_resource_provider_registration" "aad" {
  provider = azurerm.identity
  count    = local.entra_ds_enabled ? 1 : 0

  name = "Microsoft.AAD"
}

# ---------------------------------------------------------------------------
# ADR-028: Resource-group-scoped policy exemption for Entra DS vs Deny-Public-IP
#
# The managed domain's Standard SKU public IP is a MANDATORY service-created
# resource (MS Learn: entra/identity/domain-services/network-considerations),
# written by the Entra DS service principal - not our CI SP. The `Deny-Public-IP`
# assignment at the identity MG (ALZ identity-archetype default) blocks that write
# regardless of caller, terminally failing the domain create
# (ResourceActionsBlockedByPolicy, run 28978396902). A Waiver exemption scoped to
# ONLY the AADDS RG unblocks the service-created PIP while leaving Deny-Public-IP
# fully enforced elsewhere in the identity MG. No expires_on: the PIP is required
# for the lifetime of the managed domain. See ADR-028.
#
# The policy_assignment_id is a LITERAL string. The `Deny-Public-IP` assignment is
# owned by the platform/management-groups root (deployed via avm-ptn-alz); there is
# no cross-root Terraform output exposing it, so we cannot reference it by symbol.
# COUPLING: this hard-codes the ALZ assignment NAME `Deny-Public-IP` at the
# `identity` MG. If the management-groups root renames or rescopes that assignment,
# this string must be updated in lockstep. See ADR-028.
resource "azurerm_resource_group_policy_exemption" "aadds_deny_public_ip" {
  provider = azurerm.identity
  count    = local.entra_ds_enabled ? 1 : 0

  name                 = "exempt-deny-public-ip-aadds"
  resource_group_id    = azurerm_resource_group.identity_aadds[0].id
  policy_assignment_id = "/providers/Microsoft.Management/managementGroups/identity/providers/Microsoft.Authorization/policyAssignments/Deny-Public-IP"
  exemption_category   = "Waiver"

  display_name = "Entra DS service PIP waiver (ADR-028)"
  description  = "Waiver for the mandatory Standard SKU public IP that the Entra Domain Services managed service creates in this RG. Scoped to rg-identity-aadds only; Deny-Public-IP stays enforced elsewhere in the identity MG. See ADR-028."
}

# Exemptions propagate to the policy-engine caches asynchronously. The managed
# domain deploys its network resources (incl. the service PIP) within the first
# minutes of provisioning; a lost race costs another multi-hour failed cycle.
# 300s propagation buffer before the domain create. (ADR-028)
resource "time_sleep" "wait_aadds_policy_exemption" {
  count = local.entra_ds_enabled ? 1 : 0

  create_duration = "300s"

  depends_on = [azurerm_resource_group_policy_exemption.aadds_deny_public_ip]
}

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

  # Harden the managed domain: disable legacy/insecure protocols. Mirrors the
  # Microsoft secure baseline (secure-your-domain doc) for a greenfield managed
  # domain - EXCEPT Kerberos hash sync, which the API requires Enabled: run
  # 28950922048 failed 400 "The property 'SyncKerberosPasswords' cannot have the
  # value 'Disabled'" (the managed domain issues Kerberos tickets from those
  # hashes; disabling would break all Kerberos auth). Disabling NTLM sync IS
  # documented-supported hardening (secure-your-domain doc); on-prem sync off is
  # justified independently: cloud-only tenant, nothing to sync.
  security {
    ntlm_v1_enabled         = false
    tls_v1_enabled          = false
    sync_ntlm_passwords     = false # Supported hardening; breaks LDAP simple binds (none used here).
    sync_kerberos_passwords = true  # API-mandated Enabled; see header note above.
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
  # ADR-028: block the domain create until the AADDS RG policy exemption exists
  # AND its 300s propagation buffer has elapsed, so the service-created PIP is not
  # denied. Un-indexed resource references match this list's existing convention
  # for count-gated deps (the RP registration below is also count-gated); both the
  # sleep and this domain share the same entra_ds_enabled gate.
  depends_on = [
    module.identity_vnet,
    azurerm_network_security_group.entra_ds,
    azurerm_resource_provider_registration.aad,
    time_sleep.wait_aadds_policy_exemption,
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
