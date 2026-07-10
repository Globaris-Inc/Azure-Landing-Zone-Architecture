# Purpose: corp-a2 RG-scoped Waiver policy exemptions for the corp-MG
#          Deny-Public-Endpoints (Deny-PublicPaaSEndpoints) initiative members that
#          cannot be made compliant without breaking function (OQ-024, ADR-028 pattern).
# Section: 9 - Landing Zone Spokes / 2 - policy
# Last updated: 2026-07-10
#
# Mirrors corp-a1/policy_exemptions.tf (DR spoke). Two resources CANNOT be made both
# compliant and functional, so they fall back to narrowly-scoped Waiver exemptions:
#   1. Flow-log storage account (StorageDenyPaasPublicIP) - the policy requires
#      publicNetworkAccess Disabled/SecuredByPerimeter, but NSG flow-log delivery needs
#      the SA public endpoint reachable (Network Watcher is not a storage trusted-service
#      bypass). Cannot comply + stay functional -> exemption.
#   2. App Service (AsDenyPublicIP) - the VNet-integrated demo workload is reached over
#      its public inbound endpoint; making it private is a design shift flagged to the
#      architect. Interim: exemption.
#
# The snet-integration Deny-Subnet-Without-Nsg collision is fixed COMPLIANTLY in
# main.tf (NSG attached) - no exemption for it.

locals {
  # LITERAL corp-MG Deny-Public-Endpoints assignment id (owned by
  # platform/management-groups; no cross-root output exposes it). Live-enumerated
  # 2026-07-10 (docs/preclearance/landing-zones.md rows 2-3). COUPLING: keep in lockstep
  # if that assignment is renamed/rescoped (same caveat as ADR-028).
  deny_public_endpoints_assignment_id = "/providers/Microsoft.Management/managementGroups/corp/providers/Microsoft.Authorization/policyAssignments/Deny-Public-Endpoints"

  # One member reference per exemption so the other members stay enforced on the same RG
  # (SqlServerDenyPaasPublicIP keeps governing the already-private SQL server in the
  # workload RG). Member ids verified against Enterprise-Scale Deny-PublicPaaSEndpoints.json
  # + this tenant's live assignment.
  corp_policy_exemptions = {
    flow-log-storage = {
      resource_group_id               = azurerm_resource_group.network.id
      policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]
      display_name                    = "Flow-log storage public-access waiver (OQ-024)"
      description                     = "Waiver for the NSG flow-log storage account, which must keep public network access Enabled: Network Watcher is not a storage trusted-service bypass, so flow-log delivery breaks if publicNetworkAccess is Disabled. Scoped to rg-corp-a2-network for StorageDenyPaasPublicIP only. See ADR-028 + OQ-024."
    }
    app-service = {
      resource_group_id               = azurerm_resource_group.workload.id
      policy_definition_reference_ids = ["AsDenyPublicIP"]
      display_name                    = "corp-a2 App Service public-access waiver (OQ-024)"
      description                     = "Waiver for the VNet-integrated App Service reached over its public inbound endpoint. Making it private (private endpoint + privatelink.azurewebsites.net) is a design shift flagged to the architect. Scoped to rg-corp-a2-workload for AsDenyPublicIP only; SqlServerDenyPaasPublicIP stays enforced on this RG. See ADR-028 + OQ-024."
    }
  }
}

resource "azurerm_resource_group_policy_exemption" "corp_paas" {
  for_each = var.enable_corp_policy_exemptions ? local.corp_policy_exemptions : {}

  name                            = "exempt-${each.key}-corp-a2"
  resource_group_id               = each.value.resource_group_id
  policy_assignment_id            = local.deny_public_endpoints_assignment_id
  policy_definition_reference_ids = each.value.policy_definition_reference_ids
  exemption_category              = "Waiver"

  display_name = each.value.display_name
  description  = each.value.description
}

# 300s async-propagation buffer before the exempted resources are created (ADR-028).
resource "time_sleep" "wait_corp_policy_exemptions" {
  for_each = var.enable_corp_policy_exemptions ? toset(["this"]) : toset([])

  create_duration = "300s"

  depends_on = [azurerm_resource_group_policy_exemption.corp_paas]
}
