# Purpose: Synthetic-RG-scoped Waiver policy exemptions for the corp-MG
#          Deny-Public-Endpoints (Deny-PublicPaaSEndpoints) initiative members that
#          collide with the intentionally-public synthetic honeypot resources
#          (OQ-029, ADR-028 pattern). devsecops lane - do not add resource/module
#          logic here; that is corp_a1.tf / online_p1.tf / cost_patterns.tf /
#          red_team.tf (cloud-engineer lane).
# Section: 13 - Synthetic Workload & Telemetry Generation / 2 - policy
# Last updated: 2026-07-10
#
# The synthetic layer intentionally deploys public-network PaaS resources as
# security-signal honeypots (README - "public by design", Defender for Storage /
# Defender for Key Vault provide the detection layer). These collide with the
# corp-MG Deny-Public-Endpoints initiative (same assignment the landing-zones
# Waivers already work around - OQ-024, ADR-028), which the synthetic RGs also
# inherit. USER DECISION (OQ-029): use RG-scoped Waiver exemptions, not
# private-network resources - disabling public access would break the App-Service
# SAS fetch, the SWA-Function queue write, the storage-anomaly MI read path, the
# Container Apps file-share mount, and the whole point of the public decoy
# red-team resources.
#
# Live-verified 2026-07-10 (az policy set-definition show Deny-PublicPaaSEndpoints,
# management group globaris) which two initiative members are Deny (default effect)
# and actually collide:
#   - StorageDenyPaasPublicIP checks Microsoft.Storage/storageAccounts/publicNetworkAccess.
#     Default effect Deny. All four synthetic public storage accounts
#     (corp_a1_synthetic, online_p1_synthetic, cost_pattern_hot, red_team_decoy) set
#     public_network_access_enabled = true -> denied without exemption.
#   - KeyVaultDenyPaasPublicIP checks Microsoft.KeyVault/vaults/publicNetworkAccess.
#     Default effect Deny. The red-team decoy Key Vault sets
#     public_network_access_enabled = true -> denied without exemption.
#
# NOT exempted (verified NOT a collision, narrowest blast radius): the initiative
# also carries Deny-Storage-Public-Access, which checks the SEPARATE
# allowBlobPublicAccess field (anonymous container/blob access), not network-level
# access. Every synthetic storage account already sets
# allow_nested_items_to_be_public = false, so that member is not denying anything
# here and stays fully enforced. SqlServerDenyPaasPublicIP and every other member of
# the initiative also stay fully enforced on these RGs - only the two member
# references above are named in each exemption's policy_definition_reference_ids.

locals {
  # ALZ Deny-Public-Endpoints initiative assignment at the corp MG. LITERAL string:
  # the assignment is owned by platform/management-groups (avm-ptn-alz) and no
  # cross-root output exposes it. Live-verified 2026-07-10 (az policy assignment show)
  # - same assignment id already referenced by the landing-zones Waivers
  # (landing-zones/corp-a1/policy_exemptions.tf, landing-zones/online-p1/policy_exemptions.tf).
  # COUPLING: if that root renames or rescopes Deny-Public-Endpoints at the corp MG,
  # update this string in lockstep (same coupling caveat as ADR-028).
  deny_public_endpoints_assignment_id = "/providers/Microsoft.Management/managementGroups/corp/providers/Microsoft.Authorization/policyAssignments/Deny-Public-Endpoints"

  # Built conditionally per synthetic sub-layer so an exemption is only planned when
  # the RG it targets is actually created (each sub-layer has its own enable local -
  # see main.tf/cost_patterns.tf/red_team.tf). No expires_on, matching the ADR-028
  # convention: the exemption's lifecycle is already tied to the resource's existence
  # via the same enable gating, and `enable_synthetic_workload = false` (the kill
  # switch) destroys the exemption together with the resource it protects.
  synthetic_policy_exemptions = merge(
    local.enabled == 1 ? {
      corp-a1-storage = {
        resource_group_id               = azurerm_resource_group.corp_a1_synthetic[0].id
        policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]
        display_name                    = "corp-a1 synthetic storage public-access waiver (OQ-029)"
        description                     = "Waiver for the public synthetic shared storage account, which must keep public network access enabled so the k6 (13.2) and red-team (13.3) Container Apps environments can mount its Azure File shares. Scoped to rg-synthetic-corp-a1-* for StorageDenyPaasPublicIP only. See OQ-029, ADR-028 pattern."
      }
    } : {},
    local.enabled == 1 ? {
      online-p1-storage = {
        resource_group_id               = azurerm_resource_group.online_p1_synthetic[0].id
        policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]
        display_name                    = "online-p1 synthetic storage public-access waiver (OQ-029)"
        description                     = "Waiver for the public synthetic queue storage account backing the SWA-Function contact-form write path, which must stay publicly reachable for the Function's outbound write. Scoped to rg-synthetic-online-p1-* for StorageDenyPaasPublicIP only. See OQ-029, ADR-028 pattern."
      }
    } : {},
    local.cost_patterns_enabled == 1 ? {
      cost-patterns-storage = {
        resource_group_id               = azurerm_resource_group.cost_patterns[0].id
        policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]
        display_name                    = "cost-pattern synthetic storage public-access waiver (OQ-029)"
        description                     = "Waiver for the deliberately public, idle cost-pattern storage account (Optimization=Candidate demo signal). Public by design, part of the anti-pattern set the layer demonstrates. Scoped to rg-synthetic-cost-patterns-* for StorageDenyPaasPublicIP only. See OQ-029, ADR-028 pattern."
      }
    } : {},
    local.red_team_enabled == 1 ? {
      red-team-storage = {
        resource_group_id               = azurerm_resource_group.red_team_primary[0].id
        policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]
        display_name                    = "red-team decoy storage public-access waiver (OQ-029)"
        description                     = "Waiver for the decoy mass-blob-download honeypot storage account - public by design so the red-team MI can reach it over its outbound IP; Defender for Storage covers the detection layer. Scoped to rg-synthetic-red-team-* for StorageDenyPaasPublicIP only. See OQ-029, ADR-028 pattern."
      }
      red-team-keyvault = {
        resource_group_id               = azurerm_resource_group.red_team_primary[0].id
        policy_definition_reference_ids = ["KeyVaultDenyPaasPublicIP"]
        display_name                    = "red-team decoy Key Vault public-access waiver (OQ-029)"
        description                     = "Waiver for the decoy failed-Get-Secret honeypot Key Vault - public by design so red-team probe traffic is reachable and generates the intended failed-access signal; Defender for Key Vault covers the detection layer. Scoped to rg-synthetic-red-team-* for KeyVaultDenyPaasPublicIP only. See OQ-029, ADR-028 pattern."
      }
    } : {}
  )
}

resource "azurerm_resource_group_policy_exemption" "synthetic_paas" {
  for_each = var.enable_synthetic_policy_exemptions ? local.synthetic_policy_exemptions : {}

  name                            = "exempt-${each.key}-synthetic"
  resource_group_id               = each.value.resource_group_id
  policy_assignment_id            = local.deny_public_endpoints_assignment_id
  policy_definition_reference_ids = each.value.policy_definition_reference_ids
  exemption_category              = "Waiver"

  display_name = each.value.display_name
  description  = each.value.description
}

# Policy exemptions propagate to the policy-engine caches asynchronously; a resource
# PUT that races ahead of propagation is still denied (ADR-028 precedent - the same
# race cost the AADDS managed-domain create a multi-hour failed cycle). 300s buffer
# before the exempted resources (the four public storage accounts + the decoy Key
# Vault) are created.
#
# WIRED: all five target resources (corp_a1_synthetic SA, online_p1_synthetic SA,
# cost_pattern_hot SA, red_team_decoy SA, red_team_decoy KV, in corp_a1.tf,
# online_p1.tf, cost_patterns.tf, and red_team.tf respectively) carry
# `depends_on = [time_sleep.wait_synthetic_policy_exemptions]`, so the 300s
# propagation buffer is active and in place ahead of every create this batch
# protects.
resource "time_sleep" "wait_synthetic_policy_exemptions" {
  for_each = var.enable_synthetic_policy_exemptions ? toset(["this"]) : toset([])

  create_duration = "300s"

  depends_on = [azurerm_resource_group_policy_exemption.synthetic_paas]
}
