# Purpose: bank-data-p1 RG-scoped Waiver policy exemption for the corp-MG
#          Deny-Public-Endpoints (Deny-PublicPaaSEndpoints) StorageDenyPaasPublicIP
#          member (OQ-024, ADR-028 pattern).
# Section: Banking wave B1 - banking network foundation / policy
# Last updated: 2026-07-16
#
# bank-data-p1 sits under the corp MG in the landingzones subscription (OQ-035
# resolution), so it inherits the corp archetype Deny-Public-Endpoints initiative.
# At wave B1 (network-only) exactly ONE member collides with a resource that cannot
# be made both compliant and functional:
#   - Flow-log storage account (StorageDenyPaasPublicIP) - the policy requires
#     publicNetworkAccess Disabled/SecuredByPerimeter, but flow-log delivery needs
#     the SA public endpoint reachable (Network Watcher is not a storage
#     trusted-service bypass). Cannot comply + stay functional -> Waiver exemption.
# Workload waves (B5-B6) assess their own collisions at their pre-clearance; the
# ADLS/Foundry/Search resources deploy public-access-DISABLED and need no exemption.

locals {
  # LITERAL corp-MG Deny-Public-Endpoints assignment id (owned by
  # platform/management-groups; no cross-root output exposes it). Same value the
  # Section 9 spokes carry (live-enumerated 2026-07-10, docs/preclearance/
  # landing-zones.md rows 2-3). COUPLING: keep in lockstep if that assignment is
  # renamed/rescoped (same caveat as ADR-028).
  deny_public_endpoints_assignment_id = "/providers/Microsoft.Management/managementGroups/corp/providers/Microsoft.Authorization/policyAssignments/Deny-Public-Endpoints"

  # Scoped to the StorageDenyPaasPublicIP member only, so the rest of the initiative
  # stays enforced on the network RG. Member id verified against Enterprise-Scale
  # Deny-PublicPaaSEndpoints.json + this tenant's live assignment (Section 9 precedent).
  corp_policy_exemptions = {
    flow-log-storage = {
      resource_group_id               = azurerm_resource_group.network.id
      policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]
      display_name                    = "Flow-log storage public-access waiver (OQ-024)"
      description                     = "Waiver for the VNet flow-log storage account of the bank-data-p1 spoke, which must keep public network access Enabled: Network Watcher is not a storage trusted-service bypass, so flow-log delivery breaks if publicNetworkAccess is Disabled. Scoped to rg-bank-data-p1-network for StorageDenyPaasPublicIP only. See ADR-028 + OQ-024."
    }
  }
}

resource "azurerm_resource_group_policy_exemption" "corp_paas" {
  for_each = var.enable_corp_policy_exemptions ? local.corp_policy_exemptions : {}

  name                            = "exempt-${each.key}-bank-data-p1"
  resource_group_id               = each.value.resource_group_id
  policy_assignment_id            = local.deny_public_endpoints_assignment_id
  policy_definition_reference_ids = each.value.policy_definition_reference_ids
  exemption_category              = "Waiver"

  display_name = each.value.display_name
  description  = each.value.description
}

# 300s async-propagation buffer before the exempted flow-log SA is created
# (ADR-028 / LESSON 35).
resource "time_sleep" "wait_corp_policy_exemptions" {
  for_each = var.enable_corp_policy_exemptions ? toset(["this"]) : toset([])

  create_duration = "300s"

  depends_on = [azurerm_resource_group_policy_exemption.corp_paas]
}
