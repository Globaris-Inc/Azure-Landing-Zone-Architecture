# Pre-clearance: platform/security (first apply)

> Artifact of the deploy pre-clearance gate (see `docs/deploy-preclearance.md`).
> Prepared by: architect. Date: 2026-07-09. Status: BLOCKED on prerequisites 1-3 below.
> Evidence: live az CLI enumeration 2026-07-09 (policy assignments, RP states, set-definition effects).

## What this root creates (security sub, security MG under platform MG)

RG, LAW (AVM), Key Vault (AVM), Sentinel onboarding + 4 data connectors + analytics rules +
watchlists + automation rules + UEBA (azapi), Defender pricing plans + contact + MDC export
automation, Event Hub namespace/hub/auth rule, Entra tenant diagnostic setting
(`azurerm_monitor_aad_diagnostic_setting`), subscription activity-log diagnostics, NIST + CIS
initiative assignments at the globaris MG, workbook.

## Policy collisions (verified live)

| Assignment | Scope | Effect / mode | Fires on | Verdict |
|---|---|---|---|---|
| `Enforce-GR-KeyVault` (Enforce-Guardrails-KeyVault_20260203) | platform MG | Default, member effects: purge protection **Deny**, soft delete **Deny**, firewall **Audit**, secret/key expiry Audit | security_kv | PASS: `purge_protection_enabled = true`; the `network_acls.default_action = "Allow"` is only AUDITED (effectKvFirewallEnabled default = Audit, verified live). No secrets/keys are created by this root, so expiry members are moot |
| `Enforce-GR-EventHub0` and the other Enforce-Guardrails-* at platform MG | platform MG | **DoNotEnforce** | EH namespace etc. | PASS (not enforced) |
| `deny-pub-net-globaris` (our initiative) | landingzones MG only | Audit | n/a | Not assigned at platform; no effect here |
| `Deploy-Diag-LogsCat`, `Deploy-MDFC-*`, `Deploy-AzActivity-Log` | globaris MG | DINE / Default | LAW, EH, KV diagnostics | Noise only; DINE failures never block creates |
| NIST/CIS assignment PUT risk | (this root ASSIGNS at globaris MG) | - | - | CLEARED by OQ-016: both set-definition GUIDs verified live, 0 required-no-default params; CI SP holds Resource Policy Contributor at globaris |

No Deny-class collision fires on this root. The policy lane is clean.

## Prerequisites (the actual blockers)

1. **Entra directory role for tenant-scope writes.** Two resources need a standing Entra role the CI
   SP does NOT have:
   - `azurerm_monitor_aad_diagnostic_setting` (microsoft.aadiam tenant diagnostics): MS Learn
     (howto-configure-diagnostic-settings) requires at least **Security Administrator**.
   - UEBA enablement (`azapi_resource.ueba` on the Sentinel settings API): MS Learn (enable-entity-
     behavior-analytics) requires **Security Administrator or Global Administrator**.
   Action: time-boxed **Security Administrator** grant to the CI SP (operator, same pattern as the
   identity roles), removed after the apply. Alternative: set `enable_aad_diagnostics = false` and
   `enable_ueba = false` for the first apply and add them in a later pass.
   Verify: `az rest --method GET --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId eq '<sp-object-id>'"`.
2. **Licenses for data connectors.**
   - AAD data connector: needs Entra ID P1/P2. COVERED by the P2 trial while it lasts; the connector
     persists after expiry but the tenant falls out of compliance.
   - `azurerm_sentinel_data_connector_microsoft_defender_advanced_threat_protection`: needs a
     **Microsoft Defender for Endpoint** tenant license, which this tenant does NOT have. Expect the
     connector create to fail. Action: gate or drop it (decision for the user), or accept the single
     failed resource and remove it from config.
3. **Repo Secret `SECURITY_CONTACT_EMAIL`** (feeds required `security_contact_email`): NOT set yet
   (deferred-secrets list). Set before apply. Optional skip-semantics vars can stay empty:
   `sentinel_owner_group_object_id`, `vip_user_object_ids`, `high_value_asset_resource_ids`.
4. **RP registration (security sub): all NotRegistered as of 2026-07-09** - Microsoft.SecurityInsights,
   Microsoft.OperationsManagement, Microsoft.EventHub, Microsoft.Security. All four ARE in azurerm
   v4's default `legacy` auto-register set (verified in required.go at v4.71.0) and this root's default
   provider anchors to the security sub, so the provider registers them at apply start. Expect the
   FIRST apply to spend extra minutes on registration. No code change needed. Fallback if any
   registration races: rerun.
5. Defender pricing / contact writes: covered by the SP's Owner at the org root MG. PASS.

## Ordered actions before first apply

1. Set `SECURITY_CONTACT_EMAIL` repo Secret (operator).
2. Decide the MDATP connector (drop/gate vs accept-fail) - surfaced to user.
3. Grant time-boxed Security Administrator to the CI SP (operator) OR flip the two toggles off.
4. CI plan -> review -> apply. 5. Remove the directory role after apply (if granted).

## Apply-time findings - run 29133588369 (partial apply) and go/no-go for RETRY

> Added by: architect. Date: 2026-07-10. Status of retry: GO after the code fixes below land (ADR-033 gates
> + the mdc_export action-type fix). See ADR-033.
> What already landed and persists in state (retry will treat as no-op refresh): LAW, Key Vault, Event Hub
> namespace/hub/auth rule, Defender pricing plans that succeeded, regulatory compliance assignments, security
> contact, and the Sentinel workspace onboarding (`azurerm_sentinel_log_analytics_workspace_onboarding.this`).
> The workspace is therefore ALREADY onboarded going into the retry - this is central to the Class B 400
> assessment below.

Five failures across three classes.

### CLASS A - code bug (fix required before retry): mdc_export action type

`azurerm_security_center_automation.mdc_export` at `platform/security/defender.tf:176` sets the first action
block `type = "LogAnalytics"`. The provider rejects it: valid values are `EventHub`, `LogicApp`, `Workspace`
(plus lowercase aliases). VERIFIED 2026-07-10 against the current azurerm docs for
`azurerm_security_center_automation` (provider source `website/docs/r/security_center_automation.html.markdown`):
for a Log Analytics workspace destination the correct value is **`Workspace`** (`resource_id` stays the LAW
resource ID). This is a deterministic code bug, not transient - it fails every apply until fixed. Fix: change
`type = "LogAnalytics"` to `type = "Workspace"`. Verdict: MUST FIX before retry.

### CLASS B - tenant permission / Sentinel

- **dc-aad** (`azurerm_sentinel_data_connector_azure_active_directory.this`): 401 Access denied. Tenant-scoped
  connector; needs Security Administrator (or Global Admin) in Entra - the SAME class already gated for
  `enable_aad_diagnostics` and `enable_ueba`. The CI SP does not hold it. DECISION: gate off behind new
  `enable_aad_connector` (default false). See **ADR-033**. A 401 is authorization, not propagation - a rerun
  cannot clear it.
- **dc-ti** (`azurerm_sentinel_data_connector_threat_intelligence.this`): 401 Access denied. Same tenant-scope
  permission class as dc-aad (contrast the sub-scoped dc-mdc connector, which SUCCEEDED under the SP's
  Contributor). ASSESSMENT: this is a standing directory-role gap, NOT eventual-consistency - a 401 is
  authorization, and a rerun will fail identically. RECOMMENDATION: gate off behind new `enable_ti_connector`
  (default false), not rerun-as-is. See **ADR-033**.
- **firewall_threat_intel_hit** (`azurerm_sentinel_alert_rule_scheduled.this["firewall_threat_intel_hit"]`):
  400 "Could not locate all the workspaces in your query". This is a cross-workspace KQL resolution failure on
  `workspace('law-platform-globaris-poc')`, NOT a permission failure and NOT a dc-ti dependency (the rule
  reads Azure Firewall threat-intel block logs from the platform LAW; it does not read the
  ThreatIntelligenceIndicator table dc-ti populates). ASSESSMENT: most likely validation/propagation timing.
  Because the platform LAW exists (platform/management is green) and the SP has read access to it via
  Contributor, and because the Sentinel workspace onboarding ALREADY landed in this partial apply and
  persists, the retry starts from a fully-onboarded, resolvable state. RECOMMENDATION: rerun-as-is, do NOT
  gate. CONTINGENCY: if it fails a SECOND time with the same "Could not locate all the workspaces" error, the
  cause is name-only cross-workspace resolution, not timing - switch the KQL to the fully-qualified platform
  LAW ARM resource ID (needs the platform LAW ID threaded into this root). Do not blind-retry more than once.
- **ti_enrichment_tag** (`azurerm_sentinel_automation_rule.ti_enrichment_tag`): 400 "Workspace not onboarded
  to Microsoft Sentinel". Classic onboarding-propagation lag: the automation rule create raced ahead of
  Sentinel's control plane finishing onboarding in the FIRST apply. Not a dc-ti dependency (it only tags
  incidents by severity). ASSESSMENT: onboarding succeeded and persists in state, so on the retry the
  workspace has been onboarded since the prior run and is fully settled. RECOMMENDATION: rerun-as-is, do NOT
  gate - high confidence it creates cleanly on the retry.

Net Class B: gate dc-aad and dc-ti (ADR-033); rerun the two rules unchanged. Neither rule depends on the TI
connector's data, so gating dc-ti does not force gating them.

### CLASS C - transient concurrency (no code change): Defender pricing plans

Five `azurerm_security_center_subscription_pricing` plans (AppServices, SqlServerVirtualMachines, CloudPosture,
Dns, VirtualMachines) failed 409 "Another update operation is in progress. Please retry in a few minutes."
CONFIRMED transient: the Defender subscription-pricing controller serialises writes at the subscription level,
so the parallel PUTs Terraform issues from `for_each` collide. A rerun clears it - the plans that already
landed become no-op refreshes, leaving fewer concurrent writes. No code change. Optional de-risk if 409s
recur on the retry: run this root's apply with reduced parallelism (for example `terraform apply
-parallelism=2`) so the pricing PUTs do not contend. Operator/CI apply-arg only, not a code change.

### Retry verdict: GO

Land the Class A fix and the ADR-033 gates (Class B), then rerun. Class C clears on rerun (optional reduced
parallelism). No new policy collision is introduced: the changes gate resources off and correct one argument
value; they add no new resource and no new policy interaction, so the policy matrix above still holds. This
retry does not touch the tenant-permission blocker - dc-aad, dc-ti, enable_aad_diagnostics, and enable_ueba
all stay off until the time-boxed Security Administrator grant is arranged, at which point all four flip on in
one later pass.
