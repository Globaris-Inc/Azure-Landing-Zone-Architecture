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
