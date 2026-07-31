# Purpose: bank-app-p1 policy exemptions:
#          (1) B1 RG-scoped Waiver for the flow-log SA against the corp-MG
#              Deny-Public-Endpoints (Deny-PublicPaaSEndpoints)
#              StorageDenyPaasPublicIP member (OQ-024, ADR-028 pattern);
#          (2) ADR-070 RG-scoped MITIGATED exemptions on the shared RG that make
#              Terraform the sole writer of diagnostic settings and
#              private-endpoint DNS zone groups, against the two live ALZ DINE
#              assignments.
# Section: Banking wave B1 - banking network foundation / policy + ADR-070 (DINE
#          vs Terraform ownership, decisions 1, 2 and 6 - the Step 9 gate)
# Last updated: 2026-07-31 (ADR-070 DINE ownership exemption unit)
#
# bank-app-p1 sits under the corp MG in the landingzones subscription (OQ-035
# resolution), so it inherits the corp archetype Deny-Public-Endpoints initiative.
# At wave B1 (network-only) exactly ONE member collides with a resource that cannot
# be made both compliant and functional:
#   - Flow-log storage account (StorageDenyPaasPublicIP) - the policy requires
#     publicNetworkAccess Disabled/SecuredByPerimeter, but flow-log delivery needs
#     the SA public endpoint reachable (Network Watcher is not a storage
#     trusted-service bypass). Cannot comply + stay functional -> Waiver exemption.
# Workload waves (B2-B4) assess their own collisions at their pre-clearance; nothing
# else is exempted here.

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
      description                     = "Waiver for the VNet flow-log storage account of the bank-app-p1 spoke, which must keep public network access Enabled: Network Watcher is not a storage trusted-service bypass, so flow-log delivery breaks if publicNetworkAccess is Disabled. Scoped to rg-bank-app-p1-network for StorageDenyPaasPublicIP only. See ADR-028 + OQ-024."
    }
  }
}

resource "azurerm_resource_group_policy_exemption" "corp_paas" {
  for_each = var.enable_corp_policy_exemptions ? local.corp_policy_exemptions : {}

  name                            = "exempt-${each.key}-bank-app-p1"
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
# ADR-070 decisions 1, 2 and 6: Terraform is the SOLE writer of
# microsoft.insights/diagnosticSettings and of
# Microsoft.Network/privateEndpoints/privateDnsZoneGroups on every resource this
# root creates. This root is decision 6, the Step 9 gate. It declares FIVE
# azurerm diagnostic settings (diag-acr-*, diag-aks-*, diag-apim-*, diag-sbns-*
# through the AVM diagnostic_settings inputs, plus the native diag-evhns-* in
# messaging.tf) and creates THREE private endpoints, and the APIM create alone
# runs 60 to 180 minutes, so the coverage below is exhaustive rather than
# minimal: a failure after a ninety-minute provision is the most expensive one
# available in this run.
#
# WHAT THE TWO HALVES ACTUALLY BUY, stated separately because they are not
# equally urgent and the distinction was got wrong once already:
#
#   - Private DNS zone groups: a LIVE race. Azure supports only ONE zone group
#     per private endpoint, so a "deployedByPolicy" group and the module-managed
#     group are mutually exclusive, not duplicative, and the DINE carries no
#     existenceCondition so it fires on any PE that has no group yet.
#
#   - Diagnostic settings: a GOVERNANCE AND COST control against a DORMANT risk,
#     NOT a create blocker. A DINE-written setting cannot produce the
#     "already exists" failure that stopped bank-data-p1 twice: the pinned
#     azurerm v4.71.0 pre-create check GETs the EXACT configured name
#     (NewScopedDiagnosticSettingID(target_resource_id, name) in
#     internal/services/monitor/monitor_diagnostic_setting_resource.go), Azure
#     permits five settings per resource so differently-named settings coexist,
#     and the live assignment overrides only logAnalytics so the deployed name is
#     the default "setByPolicy-LogAnalytics" - which collides with none of the
#     five names above. The real harm is duplicate ingestion billed twice on the
#     Analytics meter, which for AKS and APIM allLogs would be the largest such
#     bill in the estate. It is dormant on two counts: the assignment's
#     logAnalytics parameter is still the zero-GUID placeholder (OQ-021, read
#     live 2026-07-31), so the DINE cannot write anything at all; and no
#     setByPolicy-LogAnalytics setting exists anywhere in this estate (PC-1D).
#     The exemption must land BEFORE OQ-021 Option A wires the real workspace id,
#     never after (ADR-070 decision 7).
#
# Category MITIGATED, not Waiver, and that is load-bearing documentation: the
# policy's INTENT is met, by another mechanism. Resource logs still reach
# law-platform-globaris-poc (the AVM diagnostic_settings inputs in acr.tf,
# aks.tf, apim.tf and messaging.tf plus the native setting in messaging.tf) and
# every private endpoint is still wired to the central zones in code.
#
# LIVE ENUMERATION (2026-07-31, read-only az rest against ARM; ADR-070 decision 4
# read D3 / pre-clearance PC-2DINE). Reference ids are NOT guessed - each was read
# from the live assignment and its policy SET definition, and both assignments ARE
# set definitions, so policy_definition_reference_ids applies:
#
#   Deploy-Diag-LogsCat @ globaris MG, enforcementMode Default
#     built-in set f5b29bc4-feca-4cc6-a58a-772dd5e290a5, effect default
#     DeployIfNotExists, resourceTypeList default contains all 69 member types,
#     diagnosticSettingName default "setByPolicy-LogAnalytics".
#     Members that can fire on what THIS root creates:
#       containerregistry-registries -> the Premium ACR   (diag-acr-*)
#       apimanagement-service        -> the APIM instance (diag-apim-*)
#       servicebus-namespaces        -> the SB namespace  (diag-sbns-*)
#       eventhub-namespaces          -> the EH namespace  (diag-evhns-*)
#
#   Deploy-Private-DNS-Zones @ corp MG, enforcementMode Default
#     custom ALZ set at the globaris MG, 59 members, all DeployIfNotExists, each
#     deploying a single-zone child literally named "deployedByPolicy" with NO
#     existenceCondition (so it fires on any PE that has no zone group yet).
#     Members that can fire on the private endpoints THIS root creates, matched
#     on the groupId each definition tests:
#       DINE-Private-DNS-Azure-ACR                -> pe-acr-*   (groupId registry)
#       DINE-Private-DNS-Azure-EventHubNamespace  -> pe-evhns-* (groupId namespace)
#       DINE-Private-DNS-Azure-ServiceBusNamespace-> pe-sbns-*  (groupId namespace)
#     BOTH namespace members are listed on purpose: the two definitions test only
#     groupId "namespace", not the target resource type, so each one evaluates
#     against BOTH the Event Hubs and the Service Bus private endpoint. Exempting
#     only the "matching" one would leave the other live on both PEs.
#
# DELIBERATELY NOT COVERED, stated so the gap is visible rather than assumed away:
#   - The AKS control-plane diagnostic setting (diag-aks-*) and the workload RG
#     that holds the cluster. Deploy-Diag-LogsCat's resourceTypeList has no
#     microsoft.containerservice/managedclusters entry and the initiative carries
#     no member for that type, so there is no reference id to exempt and
#     inventing one would produce an exemption that silently does nothing. The
#     only AKS diagnostics policy above this root is "Resource logs in Azure
#     Kubernetes Service should be enabled"
#     (245fc9df-fa96-4414-9a0b-3738c2f7341c) inside Deploy-ASC-Monitoring and
#     Deploy-MCSB2-Monitoring, whose allowedValues are AuditIfNotExists and
#     Disabled only - it cannot write. AKS therefore has no DINE competitor for
#     its diagnostic setting, and the workload RG needs no exemption at all.
#   - The network RG (VNet, NSGs, both route tables, flow-log SA). No member of
#     either assignment can fire on anything in it, so it stays fully enforced
#     apart from the pre-existing OQ-024 flow-log Waiver above.
#   - The scoped APIM private DNS zone, its apex A record and its VNet links.
#     Those live in the CONNECTIVITY subscription's rg-dns via the
#     azurerm.connectivity provider, outside both RGs exempted here, and they are
#     zones rather than private-endpoint zone groups.
#
# TRADE-OFF (ADR-070 consequences): any resource placed in the shared RG that
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
      resource_group_id    = azurerm_resource_group.shared.id
      policy_assignment_id = local.deploy_diag_logscat_assignment_id
      policy_definition_reference_ids = [
        "containerregistry-registries",
        "apimanagement-service",
        "servicebus-namespaces",
        "eventhub-namespaces",
      ]
      display_name = "Terraform owns diagnostic settings in this RG (ADR-070)"
      description  = "ADR-070 decision 1: Terraform is the sole writer of microsoft.insights/diagnosticSettings on the resources this root creates, so Deploy-Diag-LogsCat is exempted on rg-bank-app-p1-shared. Mitigated, not Waiver: the intent (resource logs to the platform LAW) IS met, by the diagnostic_settings inputs in acr.tf, apim.tf and messaging.tf. Scoped to the four members that can fire here. Trade-off: a resource added to this RG without a Terraform diagnostic setting now gets none. See ADR-070, OQ-021 and OQ-067."
    }

    dine-private-dns = {
      resource_group_id    = azurerm_resource_group.shared.id
      policy_assignment_id = local.deploy_private_dns_zones_assignment_id
      policy_definition_reference_ids = [
        "DINE-Private-DNS-Azure-ACR",
        "DINE-Private-DNS-Azure-EventHubNamespace",
        "DINE-Private-DNS-Azure-ServiceBusNamespace",
      ]
      display_name = "Terraform owns PE private DNS zone groups in this RG (ADR-070)"
      description  = "ADR-070 decision 1: Terraform is the sole writer of privateEndpoints/privateDnsZoneGroups on the private endpoints this root creates, so Deploy-Private-DNS-Zones is exempted on rg-bank-app-p1-shared. Azure allows only ONE zone group per private endpoint, so a deployedByPolicy group and the module-managed group are mutually exclusive. Mitigated: pe-acr, pe-evhns and pe-sbns are all still wired to the central zones in code. Both namespace members are listed because each tests groupId namespace only."
    }
  }
}

resource "azurerm_resource_group_policy_exemption" "dine_ownership" {
  for_each = var.enable_dine_ownership_exemptions ? local.dine_ownership_exemptions : {}

  name                            = "exempt-${each.key}-bank-app-p1"
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
# exemption sleep above, bank-data-p1's two exemption sleeps, platform/identity's
# wait_aadds_policy_exemption and this root's own wait_aks_uai_rbac are all 300s
# (ADR-028 / LESSON 35). ADR-070 decision 2 names 300s explicitly. Wall-clock cost
# is near zero on this root: the deploy step runs at terraform's default
# parallelism (only platform/security uses -parallelism=1), so this sleep overlaps
# wait_corp_policy_exemptions and wait_aks_uai_rbac, and all three are dwarfed by
# the APIM create.
#
# PLAN SIDE EFFECT, recorded here so a plan scan does not mistake it for drift.
# Terraform defers a data source read to APPLY time when the data source has a
# depends_on (including one inherited from its module) and any dependency has a
# pending change, so on any plan where this time_sleep is pending, the data
# sources inside module.acr, module.apim, module.event_hubs and
# module.service_bus defer and anything computed from them reads
# "(known after apply)" - the AVM telemetry surface (modtm_telemetry tags) and
# the azapi tracing User-Agent headers. On Step 9 this is invisible: every one of
# those modules is a CREATE, so those attributes are unknown at plan regardless.
# It is additive attributes only - no replacement, no destroy, no Azure-side
# property change - and it does not recur once this time_sleep is in state.
#
# NOT wired to module.aks: see the ADR-070 note in aks.tf. There is no DINE that
# can write the AKS diagnostic setting, so an edge there would buy nothing and
# would defer the cluster module's data sources for no reason.
resource "time_sleep" "wait_dine_ownership_exemptions" {
  for_each = var.enable_dine_ownership_exemptions ? toset(["this"]) : toset([])

  create_duration = "300s"

  depends_on = [azurerm_resource_group_policy_exemption.dine_ownership]
}
