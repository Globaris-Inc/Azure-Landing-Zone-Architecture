# Purpose: bank-data-p1 policy exemptions for the corp-MG Deny-Public-Endpoints
#          (Deny-PublicPaaSEndpoints) StorageDenyPaasPublicIP member:
#          (1) B1 RG-scoped Waiver for the flow-log SA (OQ-024, ADR-028 pattern);
#          (2) B5 subscription-scoped EXPIRING Waiver for the Databricks managed-RG
#              dbstorage* SA create (ADR-048 collision unit, guarantee half).
# Section: Banking wave B1 (flow-log waiver) + wave B5 (dbstorage waiver,
#          docs/b5-data-platform-design.md section 4; ADR-048)
# Last updated: 2026-07-18
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

# ---------------------------------------------------------------------------
# Wave B5: subscription-scoped expiring Waiver for the Databricks managed-RG
# dbstorage* storage account (ADR-048 / design doc section 4 - the collision
# unit's GUARANTEE half; the posture half is default_storage_firewall_enabled
# in databricks.tf). Why SUBSCRIPTION scope: the RP-created managed RG does not
# exist until the workspace create is already in flight, so an RG-scoped
# exemption (the OQ-024 shape) cannot exist before the PUT it must admit - racy
# by construction. Scoped to the single StorageDenyPaasPublicIP member only and
# SELF-EXPIRING 2026-08-01 (past the ADR-045 EOW teardown). QA records the live
# dbstorage publicNetworkAccess value post-apply; the exemption may be dropped
# early if the SA lands Disabled-or-equivalent.
# Schema (incl. the expires_on argument name - the ARM property is
# expirationDate) verified against azurerm v4.71.0 docs 2026-07-18.
# ---------------------------------------------------------------------------

resource "azurerm_subscription_policy_exemption" "dbx_managed_storage" {
  for_each = var.enable_data_platform ? { main = "main" } : {}

  name                            = "exempt-dbx-managed-storage-bank-data-p1"
  subscription_id                 = "/subscriptions/${var.landingzones_subscription_id}"
  policy_assignment_id            = local.deny_public_endpoints_assignment_id
  policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]
  exemption_category              = "Waiver"
  expires_on                      = "2026-08-01T00:00:00Z"

  display_name = "Databricks managed-RG dbstorage create waiver (ADR-048)"
  # Provider limit: description must be <= 512 chars (validate-enforced).
  description = "Wave B5 guarantee half of the ADR-048 dbstorage collision unit: the Databricks RP creates the workspace DBFS storage account in its managed RG at workspace create, and the RP PUT sequencing vs the corp StorageDenyPaasPublicIP Deny is not verifiable pre-apply. Subscription-scoped because the managed RG does not exist until the create is in flight. Single-member scope; self-expires 2026-08-01. Posture half: default storage firewall keeps the SA private. See docs/b5-data-platform-design.md section 4."
}

# 300s async-propagation buffer before the access connector + workspace create
# (ADR-028 / LESSON 35 unit; databricks.tf depends_on this sleep).
resource "time_sleep" "wait_dbx_storage_exemption" {
  for_each = var.enable_data_platform ? toset(["this"]) : toset([])

  create_duration = "300s"

  depends_on = [azurerm_subscription_policy_exemption.dbx_managed_storage]
}
