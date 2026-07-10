# Purpose: corp-a1 RG-scoped Waiver policy exemptions for the corp-MG
#          Deny-Public-Endpoints (Deny-PublicPaaSEndpoints) initiative members that
#          cannot be made compliant without breaking function (OQ-024, ADR-028 pattern).
# Section: 9 - Landing Zone Spokes / 2 - policy
# Last updated: 2026-07-10
#
# Two resources here CANNOT be made both compliant and functional, so they fall back
# to narrowly-scoped Waiver exemptions (the OQ-024 "compliance-first, exemption
# fallback" decision):
#   1. Flow-log storage account (StorageDenyPaasPublicIP) - the policy requires
#      publicNetworkAccess in [Disabled, SecuredByPerimeter] (live-verified, matrix
#      row 2). NSG flow-log delivery REQUIRES the SA public endpoint reachable:
#      Network Watcher is NOT on the storage trusted-service bypass list, so a
#      firewall/networkAcls-Deny + trusted-services bypass does NOT admit flow-log
#      writes, and publicNetworkAccess=Disabled breaks delivery entirely
#      (learn.microsoft.com/azure/network-watcher/nsg-flow-logs-manage; GitHub
#      Azure/Enterprise-Scale #724). Cannot comply + stay functional -> exemption.
#   2. App Service (AsDenyPublicIP) - the VNet-integrated demo workload is reached over
#      its public inbound endpoint. Complying (public_network_access_enabled=false)
#      makes it unreachable unless a Microsoft.Web/sites private endpoint +
#      privatelink.azurewebsites.net zone + VNet link are added - net-new
#      infrastructure and a corp-posture design shift flagged to the architect.
#      Interim: exemption.
#
# The snet-integration Deny-Subnet-Without-Nsg collision (matrix row 4) is fixed
# COMPLIANTLY in main.tf (NSG attached) - no exemption for it.

locals {
  # ALZ Deny-Public-Endpoints initiative assignment at the corp MG. LITERAL string:
  # the assignment is owned by platform/management-groups (avm-ptn-alz) and no
  # cross-root output exposes it. Live-enumerated 2026-07-10 (architect pre-clearance
  # docs/preclearance/landing-zones.md rows 2-3). COUPLING: if that root renames or
  # rescopes Deny-Public-Endpoints at the corp MG, update this string in lockstep
  # (same coupling caveat as ADR-028).
  deny_public_endpoints_assignment_id = "/providers/Microsoft.Management/managementGroups/corp/providers/Microsoft.Authorization/policyAssignments/Deny-Public-Endpoints"

  # Each exemption targets ONE member reference of the initiative so the other members
  # stay fully enforced on the same RG - notably SqlServerDenyPaasPublicIP, which keeps
  # governing the (already-private) SQL server in the workload RG. Member reference ids
  # (StorageDenyPaasPublicIP / AsDenyPublicIP) verified against the Enterprise-Scale
  # Deny-PublicPaaSEndpoints.json source and this tenant's live assignment.
  corp_policy_exemptions = {
    flow-log-storage = {
      resource_group_id               = azurerm_resource_group.network.id
      policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]
      display_name                    = "Flow-log storage public-access waiver (OQ-024)"
      description                     = "Waiver for the NSG flow-log storage account, which must keep public network access Enabled: Network Watcher is not a storage trusted-service bypass, so flow-log delivery breaks if publicNetworkAccess is Disabled. Scoped to rg-corp-a1-network for StorageDenyPaasPublicIP only. See ADR-028 + OQ-024."
    }
    app-service = {
      resource_group_id               = azurerm_resource_group.workload.id
      policy_definition_reference_ids = ["AsDenyPublicIP"]
      display_name                    = "corp-a1 App Service public-access waiver (OQ-024)"
      description                     = "Waiver for the VNet-integrated App Service reached over its public inbound endpoint. Making it private (private endpoint + privatelink.azurewebsites.net) is a design shift flagged to the architect. Scoped to rg-corp-a1-workload for AsDenyPublicIP only; SqlServerDenyPaasPublicIP stays enforced on this RG. See ADR-028 + OQ-024."
    }
  }
}

resource "azurerm_resource_group_policy_exemption" "corp_paas" {
  for_each = var.enable_corp_policy_exemptions ? local.corp_policy_exemptions : {}

  name                            = "exempt-${each.key}-corp-a1"
  resource_group_id               = each.value.resource_group_id
  policy_assignment_id            = local.deny_public_endpoints_assignment_id
  policy_definition_reference_ids = each.value.policy_definition_reference_ids
  exemption_category              = "Waiver"

  display_name = each.value.display_name
  description  = each.value.description
}

# Policy exemptions propagate to the policy-engine caches asynchronously; a resource
# PUT that races ahead of propagation is still denied. 300s buffer before the exempted
# resources (flow-log SA, App Service) are created (ADR-028 precedent).
resource "time_sleep" "wait_corp_policy_exemptions" {
  for_each = var.enable_corp_policy_exemptions ? toset(["this"]) : toset([])

  create_duration = "300s"

  depends_on = [azurerm_resource_group_policy_exemption.corp_paas]
}
