# Purpose: bank-data-p1 policy exemptions:
#          (1) B1 RG-scoped Waiver for the flow-log SA against the corp-MG
#              Deny-Public-Endpoints StorageDenyPaasPublicIP member (OQ-024,
#              ADR-028 pattern);
#          (2) B5 subscription-scoped EXPIRING Waiver for the Databricks managed-RG
#              dbstorage* SA create (ADR-048 collision unit, guarantee half);
#          (3) ADR-070 RG-scoped MITIGATED exemptions on the workload RG that make
#              Terraform the sole writer of diagnostic settings and private-endpoint
#              DNS zone groups, against the two live ALZ DINE assignments.
# Section: Banking wave B1 (flow-log waiver) + wave B5 (dbstorage waiver,
#          docs/b5-data-platform-design.md section 4; ADR-048) + ADR-070 (DINE vs
#          Terraform ownership, decisions 1 and 2)
# Last updated: 2026-07-31 (ADR-070 DINE ownership exemption unit)
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

  # Self-healing expiry for the dbstorage waiver below. ADDED 2026-08-02 after the
  # code-reviewer's class sweep found this armed.
  #
  # THE DEFECT IT CLOSES. `expires_on` was the static literal "2026-08-01T00:00:00Z",
  # chosen because it sat past the ADR-045 EOW teardown. That date PASSED on
  # 2026-08-01, and `enable_data_platform` is true, so Step 8 of the next rebuild
  # would have created this exemption ALREADY EXPIRED. An expired exemption is
  # preserved for record-keeping but is no longer honoured, so it would not have
  # failed at its own PUT - the Databricks managed-RG dbstorage create it exists to
  # protect would have been denied instead, by StorageDenyPaasPublicIP, two files
  # away from the cause. Under the standing "any failure means full teardown" ruling
  # that is a whole rebuild cycle for a stale literal.
  #
  # THE PATTERN IS NOT NEW. modules/finops/main.tf:31-39 already guards the cost
  # export exactly this way, and its own comment records that "this exact class
  # already bit the budgets, commit 7dde32b". The guard was correct and was applied
  # to ONE of the estate's four date sites. This is the same guard, generalised.
  #
  # Behaviour: while the requested literal is still in the future it is used
  # verbatim, so the plan is deterministic and does NOT churn on plantimestamp().
  # Only once it goes stale does it fall back to 90 days from plan time, which
  # keeps the estate deployable instead of failing. Locals are not addresses, so
  # Step 8's plan bar of 76 is unaffected.
  dbx_exemption_requested_expiry = "2026-12-01T00:00:00Z"
  dbx_exemption_expires_on = timecmp(local.dbx_exemption_requested_expiry, plantimestamp()) > 0 ? (
    local.dbx_exemption_requested_expiry
  ) : timeadd(plantimestamp(), "2160h")
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
# by construction. Scoped to the TWO Deny members the PC-1D pre-clearance live
# dump found evaluating the dbstorage PUT (byte-exact reference ids from the
# architect's dump):
#   - StorageDenyPaasPublicIP (publicNetworkAccess not Disabled/SecuredByPerimeter)
#   - Deny-Storage-Public-Access (builtin 4fa4b6c0, allowBlobPublicAccess
#     notEquals false, default Deny)
# and SELF-EXPIRING 2026-08-01 (past the ADR-045 EOW teardown). QA records the
# live dbstorage publicNetworkAccess value post-apply; the exemption may be
# dropped early if the SA lands Disabled-or-equivalent.
# Schema (incl. the expires_on argument name - the ARM property is
# expirationDate) verified against azurerm v4.71.0 docs 2026-07-18.
# ---------------------------------------------------------------------------

resource "azurerm_subscription_policy_exemption" "dbx_managed_storage" {
  for_each = var.enable_data_platform ? { main = "main" } : {}

  name                            = "exempt-dbx-managed-storage-bank-data-p1"
  subscription_id                 = "/subscriptions/${var.landingzones_subscription_id}"
  policy_assignment_id            = local.deny_public_endpoints_assignment_id
  policy_definition_reference_ids = ["StorageDenyPaasPublicIP", "Deny-Storage-Public-Access"]
  exemption_category              = "Waiver"
  expires_on                      = local.dbx_exemption_expires_on

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

# ---------------------------------------------------------------------------
# ADR-070 decisions 1 + 2: Terraform is the SOLE writer of
# microsoft.insights/diagnosticSettings and of
# Microsoft.Network/privateEndpoints/privateDnsZoneGroups on every resource this
# root creates, so the two ALZ DINE assignments that write the same two object
# classes are exempted at the RG that holds them.
#
# Category MITIGATED, not Waiver, and that is load-bearing documentation: the
# policy's INTENT is met, by another mechanism. Resource logs still reach
# law-platform-globaris-poc (the AVM diagnostic_settings inputs in ai.tf and
# datalake.tf) and every private endpoint still resolves through the central
# zones (the module-managed zone groups plus the native three-zone group in
# ai.tf). A Waiver would assert the control is being skipped, which is false.
#
# WHY IT IS NEEDED. Two writers competing for two object classes on the same
# resources. The two halves are NOT equally urgent and the difference is written
# out here so nobody has to re-derive it:
#
#   - Diagnostic settings: a GOVERNANCE AND COST control against a risk that is
#     DORMANT TODAY. The DINE writes a setting named "setByPolicy-LogAnalytics"
#     on the same scopes Terraform writes "diag-*". Two settings on one resource
#     pointing at the SAME workspace means the same rows are ingested and billed
#     twice on the Analytics ingestion meter, which for allLogs on Foundry is a
#     real recurring cost for zero additional insight. That is the whole of the
#     harm, and it is dormant on two independent counts:
#       (a) The assignment's logAnalytics parameter is still the zero-GUID
#           placeholder subscription (read live 2026-07-31, PC-2DINE), so this
#           DINE cannot successfully write anything anywhere. That is OQ-021 and
#           it is still open. The exemption must therefore land BEFORE OQ-021
#           Option A wires the real workspace id, never after (ADR-070 decision 7
#           - the two ship together or neither ships).
#       (b) Nothing in this estate carries a setByPolicy-LogAnalytics setting.
#           PC-1D checked the already-green roots: both hub firewalls and the
#           online-p1 App Gateway each hold exactly ONE diagnostic setting and it
#           is Terraform's.
#
#     IT IS NOT A CREATE BLOCKER, AND THIS FILE PREVIOUSLY CLAIMED OTHERWISE.
#     A DINE-written setting cannot produce the ImportAsExistsError that failed
#     this root twice (runs 30661012325 and 30662610292). Three independent
#     reasons: the pinned azurerm v4.71.0 pre-create check builds
#     NewScopedDiagnosticSettingID(target_resource_id, name) and GETs that EXACT
#     configured name rather than asking whether any setting exists
#     (internal/services/monitor/monitor_diagnostic_setting_resource.go); Azure
#     permits five diagnostic settings per resource, so differently-named
#     settings coexist by design; and the live assignment overrides only
#     logAnalytics, so the deployed name is the default
#     "setByPolicy-LogAnalytics", which collides with none of diag-aif-*,
#     diag-srch-* or diag-stlake-*. What actually blocked the two applies is
#     OQ-067 item B and is NOT established - see the note in ai.tf.
#
#   - Private DNS zone groups: a LIVE race, and the load-bearing half of this
#     unit. Azure supports only ONE zone group per private
#     endpoint, so a policy "deployedByPolicy" group and Terraform's group are
#     mutually exclusive, not duplicative. The DINE group carries ONE zone while
#     the Foundry account needs THREE, so if the policy wins the race the PE
#     resolves incorrectly AND the pending azapi PUT collides. Confirmed live:
#     the DINE deployment template hardcodes the child name "deployedByPolicy"
#     with a single privateDnsZoneConfigs entry, and it carries NO
#     existenceCondition, so it fires on any PE that has no zone group yet -
#     exactly the state a failed apply leaves behind.
#
# LIVE ENUMERATION (2026-07-31, read-only az rest against ARM; ADR-070 decision 4
# read D3 / pre-clearance PC-2DINE). Assignments and reference ids are NOT guessed
# - each was read from the live assignment and its policy SET definition, and both
# assignments ARE set definitions, so policy_definition_reference_ids applies:
#
#   Deploy-Diag-LogsCat @ globaris MG
#     displayName  "Enable category group resource logging for supported
#                   resources to Log Analytics"
#     definition   /providers/Microsoft.Authorization/policySetDefinitions/
#                  f5b29bc4-feca-4cc6-a58a-772dd5e290a5 (built-in, 69 members)
#     effect       initiative default DeployIfNotExists; each member is gated
#                  [if(contains(parameters('resourceTypeList'),'<type>'),
#                  parameters('effect'),'Disabled')] and the default
#                  resourceTypeList contains all 69 types, so every member is
#                  live. diagnosticSettingName default "setByPolicy-LogAnalytics".
#     enforcement  Default
#     members that can fire on what THIS root creates:
#       cognitiveservices-accounts  -> the Foundry account (module.foundry)
#       search-searchservices       -> the AI Search service (module.search)
#
#   Deploy-Private-DNS-Zones @ corp MG
#     displayName  "Configure Azure PaaS services to use private DNS zones"
#     definition   /providers/Microsoft.Management/managementGroups/globaris/
#                  providers/Microsoft.Authorization/policySetDefinitions/
#                  Deploy-Private-DNS-Zones (custom ALZ set, 59 members, all
#                  resolving to DeployIfNotExists)
#     enforcement  Default
#     members that can fire on the private endpoints THIS root creates (matched
#     on the groupId each definition tests, read from the definition policyRule):
#       DINE-Private-DNS-Azure-CognitiveServices -> pe-aif-* (privateLinkServiceId
#                                                   contains
#                                                   Microsoft.CognitiveServices/accounts)
#       DINE-Private-DNS-Azure-CognitiveSearch   -> pe-srch-*  (groupId searchService)
#       DINE-Private-DNS-Azure-Storage-Blob      -> pe-stlake-blob-* (groupId blob)
#       DINE-Private-DNS-Azure-Storage-DFS       -> pe-stlake-dfs-*  (groupId dfs)
#
# DELIBERATELY NOT COVERED, stated so the gap is visible rather than assumed away:
#   - The Databricks workspace diagnostic setting (diag-dbw-*). The
#     Deploy-Diag-LogsCat resourceTypeList does NOT contain
#     microsoft.databricks/workspaces and the initiative has no member for it, so
#     there is no reference id to exempt and inventing one would produce an
#     exemption that silently does nothing. The only Databricks diagnostics policy
#     in the inheritance chain is
#     "Resource logs in Azure Databricks Workspaces should be enabled"
#     (138ff14d-b687-4faa-a81c-898c91a87fa2) inside Deploy-ASC-Monitoring and
#     Deploy-MCSB2-Monitoring, whose allowedValues are AuditIfNotExists and
#     Disabled only - it cannot write. The diag-dbw-* leg of the twice-failed
#     apply is therefore NOT a DINE collision; it belongs to OQ-067 item B and no
#     exemption can fix it.
#   - The data lake storage account. Neither microsoft.storage/storageaccounts nor
#     the flow-log SA type is in the resourceTypeList; its setting is also an
#     azapi resource, which PUTs idempotently with no RequiresImport pre-check.
#   - The shared RG (Fabric capacity) and the network RG (VNet, NSGs, route table,
#     flow-log SA). No member of either assignment can fire on anything in them,
#     so they are left fully enforced.
#
# TRADE-OFF (ADR-070 consequences): any resource placed in the workload RG that
# Terraform does NOT give a diagnostic setting will now have none at all, and any
# private endpoint placed there without a zone group will not get one from policy.
# That is deliberate; the exemption description carries it into the portal.
#
# Provider schema verified against the pinned azurerm v4.71.0 docs
# (website/docs/r/resource_group_policy_exemption.html.markdown at tag v4.71.0,
# 2026-07-31): exemption_category possible values are Waiver and Mitigated, and
# policy_definition_reference_ids applies when the assignment is an assignment of
# a policy SET definition, which both of these are.
# ---------------------------------------------------------------------------

locals {
  # LITERAL assignment ids. Both are owned by platform/management-groups via
  # avm-ptn-alz and no cross-root output exposes them, so the same COUPLING
  # caveat as ADR-028 applies: keep these in lockstep if either assignment is
  # renamed or rescoped. Values read live 2026-07-31 (PC-2DINE).
  deploy_diag_logscat_assignment_id      = "/providers/Microsoft.Management/managementGroups/globaris/providers/Microsoft.Authorization/policyAssignments/Deploy-Diag-LogsCat"
  deploy_private_dns_zones_assignment_id = "/providers/Microsoft.Management/managementGroups/corp/providers/Microsoft.Authorization/policyAssignments/Deploy-Private-DNS-Zones"

  # Static map keys (LESSON 5a): the address identity must never move.
  # Provider limit: description must be <= 512 chars (validate-enforced).
  dine_ownership_exemptions = {
    dine-diag-logscat = {
      resource_group_id               = azurerm_resource_group.workload.id
      policy_assignment_id            = local.deploy_diag_logscat_assignment_id
      policy_definition_reference_ids = ["cognitiveservices-accounts", "search-searchservices"]
      display_name                    = "Terraform owns diagnostic settings in this RG (ADR-070)"
      description                     = "ADR-070 decision 1: Terraform is the sole writer of microsoft.insights/diagnosticSettings on the resources this root creates, so Deploy-Diag-LogsCat is exempted on rg-bank-data-p1-workload. Mitigated, not Waiver: the intent (resource logs to the platform LAW) IS met, by the AVM diagnostic_settings inputs in ai.tf. Scoped to the two members that can fire here. Trade-off: a resource added to this RG without a Terraform diagnostic setting now gets none. See ADR-070, OQ-021 and OQ-067."
    }

    dine-private-dns = {
      resource_group_id    = azurerm_resource_group.workload.id
      policy_assignment_id = local.deploy_private_dns_zones_assignment_id
      policy_definition_reference_ids = [
        "DINE-Private-DNS-Azure-CognitiveServices",
        "DINE-Private-DNS-Azure-CognitiveSearch",
        "DINE-Private-DNS-Azure-Storage-Blob",
        "DINE-Private-DNS-Azure-Storage-DFS",
      ]
      display_name = "Terraform owns PE private DNS zone groups in this RG (ADR-070)"
      description  = "ADR-070 decision 1: Terraform is the sole writer of privateEndpoints/privateDnsZoneGroups on the private endpoints this root creates, so Deploy-Private-DNS-Zones is exempted on rg-bank-data-p1-workload. Azure allows only ONE zone group per private endpoint, so the policy group and Terraform's are mutually exclusive, and the Foundry PE needs three zones where the policy deploys one. Mitigated: every PE here is still wired to the central zones in code. Scoped to the four members that can fire here."
    }
  }
}

resource "azurerm_resource_group_policy_exemption" "dine_ownership" {
  for_each = var.enable_dine_ownership_exemptions ? local.dine_ownership_exemptions : {}

  name                            = "exempt-${each.key}-bank-data-p1"
  resource_group_id               = each.value.resource_group_id
  policy_assignment_id            = each.value.policy_assignment_id
  policy_definition_reference_ids = each.value.policy_definition_reference_ids
  exemption_category              = "Mitigated"

  display_name = each.value.display_name
  description  = each.value.description
}

# SEPARATE 300s propagation buffer - deliberately NOT a member of
# local.corp_policy_exemptions and NOT gated on
# time_sleep.wait_corp_policy_exemptions.
#
# THE STRUCTURAL POINT (ADR-070 decision 2, stated so it is not "simplified" away
# later): time_sleep.wait_corp_policy_exemptions is already in state with its
# triggers satisfied. Adding a member to the map it depends on does NOT re-trigger
# it, because a satisfied time_sleep is not re-created when an upstream resource
# it depends_on gains a new instance. A new exemption folded into that map would
# therefore get ZERO propagation window and the apply would race the policy engine
# it is trying to disarm. A new time_sleep resource has no state, so it always
# waits on first create.
#
# DURATION: 300s, matched to every policy-exemption and RBAC propagation buffer
# already proven in this estate rather than chosen freshly - the flow-log
# exemption sleep above, the subscription-scoped dbstorage exemption sleep above,
# platform/identity's wait_aadds_policy_exemption, and bank-app-p1's
# wait_aks_uai_rbac are all 300s (ADR-028 / LESSON 35). ADR-070 decision 2 names
# 300s explicitly. Wall-clock cost is near zero on this root: the deploy step runs
# at terraform's default parallelism (only platform/security uses
# -parallelism=1), so this sleep overlaps the two that already exist.
#
# ONE-TIME PLAN SIDE EFFECT, recorded here so a plan scan does not mistake it for
# drift. Terraform defers a data source read to APPLY time when the data source
# has a depends_on (including one inherited from its module) and any dependency
# has a pending change. On the FIRST plan that carries this file, this time_sleep
# is a pending create, so the data sources inside module.foundry, module.search
# and module.datalake defer, and anything computed from them reads
# "(known after apply)". Concretely that is the AVM telemetry surface -
# modtm_telemetry.telemetry tags, and the azapi tracing User-Agent headers
# (create_headers / read_headers / update_headers, tracing_tags_header) - so
# expect in-place updates on those attributes IN ADDITION to the known OQ-032
# CreatedDate tag churn. They are additive attributes only: no replacement, no
# destroy, no change to any Azure-side property, and the values resolve
# identically at apply. Once this time_sleep is in state with nothing pending,
# the data sources read at plan time again and the churn does not recur.
resource "time_sleep" "wait_dine_ownership_exemptions" {
  for_each = var.enable_dine_ownership_exemptions ? toset(["this"]) : toset([])

  create_duration = "300s"

  depends_on = [azurerm_resource_group_policy_exemption.dine_ownership]
}
