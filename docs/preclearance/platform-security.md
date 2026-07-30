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

## Apply-time findings - run 29134695521 (run 2, ADR-033 fixes applied) and go/no-go for a 3rd apply

> Added by: architect. Date: 2026-07-10. Status of 3rd apply: GO after the fixes below (ADR-034 gate + Dns
> removal + SqlServerVirtualMachines import + reduced pricing parallelism). See ADR-034, OQ-027, OQ-028.
> What run 2 fixed: the dc-aad/dc-ti 401s are gone (both gated off), the mdc_export action type=Workspace was
> accepted, and the ti_enrichment_tag automation-rule 400 "not onboarded" cleared (onboarding propagated from
> the run-1 partial apply, as predicted). Four issues remained.

Live ground truth (`az security pricing list`, security sub, 2026-07-10):
- Standard (live, in state): SqlServers, StorageAccounts, KeyVaults, Arm, OpenSourceRelationalDatabases,
  Containers, CloudPosture, plus auto-derived Discovery and FoundationalCspm (not managed by this root).
- Standard (live) but NOT in state: SqlServerVirtualMachines (run-1 raced PUT landed in Azure, state write did
  not persist) -> needs import.
- Free (not applied): VirtualMachines (the `servers` P2 resource, main.tf), AppServices (extended), Dns
  (extended, deprecated), and the rest (KubernetesService, ContainerRegistry, CosmosDbs, Api, AI - none in
  config).

### Issue 1 - firewall_threat_intel_hit, SECOND failure (cross-workspace resolution): GATE OFF

400 "Could not locate all the workspaces in your query" again - the ADR-033 contingency. Root cause confirmed:
the rule's KQL uses a name-only cross-subscription reference `workspace('law-platform-<org>-<env>')` (platform
LAW is in the management sub; the rule is created in the security sub), which does not resolve at rule-create
time. It is the only cross-workspace rule; the other 10 create fine. DECISION (ADR-034): gate it off behind new
`enable_firewall_ti_rule` (default false) by filtering the one map key out of the scheduled-rule `for_each`;
keep the entry pre-staged. Re-enable needs a fully-qualified reference + cross-workspace RBAC (OQ-027), not just
a flag flip. Cloud-engineer lane.

### Issue 2 - Dns Defender plan deprecated: REMOVE + deprecation audit

400 "The 'Dns' plan is deprecated and can no longer be enabled." Confirmed removal is the fix: Dns is live-Free
and never entered state, so dropping it from `defender_extended_plans` (defender.tf) is a no-op against live and
state. Process gap: the Defender-plan list was not re-audited against the release notes before run 1.
Deprecation audit done now (VERIFIED 2026-07-10 vs Defender for Cloud release notes, "Plan enablement API now
blocks onboarding to five deprecated Defender plans," July 5 2026). The five blocked plans: KubernetesService,
ContainerRegistry, KeyVaults, Dns, Arm. Mapping to this root:
- `Dns` (extended) - deprecated + Free-live -> REMOVE (this issue).
- `KeyVaults` and `Arm` (defender_basic_plans, main.tf) - ALSO deprecated, but live-Standard + in state; the
  block is new-enablement only, so they do NOT block the 3rd apply. Held as latent debt (ADR-034, OQ-028); do
  not remove (removing = posture downgrade), do not re-PUT. Add code comments marking them deprecated.
- `KubernetesService`, `ContainerRegistry` - deprecated but NOT used (we use `Containers`). No action.
- All other plans in config (AppServices, SqlServers, SqlServerVirtualMachines, Containers,
  OpenSourceRelationalDatabases, CloudPosture, VirtualMachines, StorageAccounts) - current/supported.
Cloud-engineer lane (Dns removal + comments). New standing pre-clearance step: re-audit the Defender pricing
plan list against the current release notes for any root that sets plans.

### Issue 3 - SqlServerVirtualMachines state drift: IMPORT

`azurerm_security_center_subscription_pricing.extended["SqlServerVirtualMachines"]` failed "already exists -
needs to be imported." It is live-Standard but absent from state. SqlServerVirtualMachines is NOT deprecated, so
import-then-apply is clean (no PUT block). Import target:
- Address: `azurerm_security_center_subscription_pricing.extended["SqlServerVirtualMachines"]`
- ID: `/subscriptions/<SECURITY-SUB>/providers/Microsoft.Security/pricings/SqlServerVirtualMachines`
Drift scan for other plans: run 2 flagged ONLY SqlServerVirtualMachines as "already exists," which confirms the
other live-Standard plans are reconciled in state (independent pricing resources would each surface their own
"already exists" error otherwise). Guard for the 3rd apply: devsecops runs `terraform plan` first and confirms
NO pricing resource other than VirtualMachines/AppServices shows "to create/replace." If any deprecated plan
(KeyVaults/Arm) unexpectedly shows "to create" (drift), it must be IMPORTED, never re-created - a re-PUT would
hit the deprecation block. Devsecops lane (state op via the workflow, before apply).

### Issue 4 - AppServices + VirtualMachines 409 Conflict: SERIALIZE the pricing writes

Both are Free-live; their parallel pricing PUTs collided on the sub-level pricing controller and never landed.
After removing Dns (no write) and importing SqlServerVirtualMachines (becomes no-op), the remaining pricing
writes on the 3rd apply are exactly two: VirtualMachines (`servers`, P2) and AppServices (`extended`).
ASSESSMENT: two concurrent PUTs to the same subscription pricing controller CAN still 409 - the controller
serializes all pricing writes at the sub level, so "only two writes" is lower risk but not zero.
RECOMMENDATION: do NOT gamble on a plain rerun given the failure budget. Serialize the pricing writes on the
security apply. Preferred: devsecops runs this root's apply step with `-parallelism=1` (the retry plan is tiny -
a handful of creates - so full serialization costs almost nothing and removes the 409 risk entirely).
`-parallelism=2` is NOT sufficient because two in-flight pricing PUTs still contend. Devsecops lane (apply-arg /
workflow). Alternative durable code fix (cloud-engineer, optional): add
`depends_on = [azurerm_security_center_subscription_pricing.servers]` to the `extended` resource to chain
AppServices behind VirtualMachines; leave global parallelism unchanged.

### 3rd-apply verdict: GO

Land the ADR-034 changes (gate firewall_threat_intel_hit, remove Dns, comment KeyVaults/Arm) in the
cloud-engineer lane; run the SqlServerVirtualMachines import and apply with reduced parallelism in the devsecops
lane. No new policy collision: the changes gate one rule off, drop one plan, and correct state - no new resource
and no new policy interaction, so the policy matrix at the top still holds. KeyVaults + Arm stay live-Standard
and are non-blocking (new-enablement block only). Tenant-permission gates (dc-aad, dc-ti, enable_aad_diagnostics,
enable_ueba) remain off pending the Security Administrator grant.

## Plan-scan finding - run 29135838771 (clean plan, pre-apply guard) and go/no-go

> Added by: architect. Date: 2026-07-10. Status: HOLD, then GO after the ADR-035 subplan-pinning + import block
> land and a re-plan shows 0 to destroy. The ADR-034 step-6 plan-scan guard caught a posture-degrading landmine
> on a clean plan BEFORE apply - working exactly as designed. See ADR-035.

The clean plan reported `6 to add, 9 to change, 3 to destroy`. The three destroys were FORCED REPLACEMENTS of
the basic Defender plans:
```
azurerm_security_center_subscription_pricing.this["Arm"]            -/+ subplan "PerSubscription"      -> null # ForceNew
azurerm_security_center_subscription_pricing.this["KeyVaults"]      -/+ subplan "PerKeyVault"          -> null # ForceNew
azurerm_security_center_subscription_pricing.this["StorageAccounts"] -/+ subplan "DefenderForStorageV2" -> null # ForceNew
```

Root cause: `this` (main.tf) sets only `resource_type`, never `subplan`. Azure auto-assigned default subplans on
the original apply and the provider stored them; config `subplan = null` vs state value on a ForceNew field
forces destroy+recreate. Post 2026-07-05, the KeyVaults and Arm recreate PUTs are blocked (deprecated), so the
recreate would leave both at Free (Defender for Key Vault + Resource Manager protection OFF, a posture
regression) and fail the apply. StorageAccounts is not deprecated so it would recreate successfully, but
destroy/recreate of a live plan is still unwanted churn. Not seen in run-1/run-2 because those failed earlier
(connectors / Dns) before reaching these replacements.

The rest of the plan is benign: `mdc_export` in-place (the type=Workspace fix), Key Vault / LAW tag drift
in-place, and the legit creates (AppServices, SqlServerVirtualMachines, VirtualMachines/servers). The `extended`
plans do NOT replace (subplan-less resource types, no drift).

FIX (ADR-035):
- Pin the three basic-plan subplans to their exact state values so config matches state and the ForceNew diff
  disappears. Cloud-engineer lane.
- Import the drifted SqlServerVirtualMachines plan via a config-driven import block (interpolated id, no
  hardcoded GUID - proven by the ADR-029 import precedent). Cloud-engineer lane (import block in code; no
  separate devsecops import action needed).

### Go/no-go: HOLD until re-plan is clean, then GO

Do NOT apply the current plan (it destroys the two deprecated plans). After ADR-035 lands, devsecops re-plans
and confirms `0 to destroy` and no `-/+` on the three basic plans. Expected post-fix plan: 2 pricing creates
(AppServices, VirtualMachines/servers) + the SqlServerVirtualMachines import + benign in-place changes, 0
destroy. Keep the `-parallelism=1` recommendation for the apply (the 2 remaining pricing creates still contend
on the sub-level controller). Watch item (non-blocking): pinning DefenderForStorageV2 may surface an in-place
StorageAccounts `extension` diff; benign, do not block on it.

## Clean-empty-state apply findings - run 30499221661 (greenfield rebuild) and recovery disposition

> Added by: architect. Date: 2026-07-29. Status: PARTIAL state. RECOVERY DISPOSITION SUPERSEDED 2026-07-29 - the IMPORT-AND-CONTINUE ruling in this section was replaced by full teardown-and-restart with the Security LAW purged (OQ-063); see the "Recovery path ruling" section below. See ADR-067.
> This is the FIRST apply of this root from a genuinely EMPTY state (181-byte reset). Every prior apply
> (runs 29133-29136xxx, ADR-033/034/035) was incremental over a state that already held the Sentinel
> onboarding, which masked two defects that only a clean apply exposes.

Three interacting classes failed. Root causes and dispositions (full reasoning in ADR-067):

### Class 2 - the paradox: ~11 Sentinel resources "already exist" while the workspace reads "not onboarded"

The STATE was emptied; AZURE was not. The prior teardown SOFT-DELETED the Security LAW (14-day window) instead
of purging it. The AVM LAW module PUT RECOVERED the soft-deleted `law-security-globaris-poc` (same name/RG)
rather than creating fresh (azurerm issue #26644; MS Learn "Delete and recover a Log Analytics workspace").
Recovery restores workspace config and analytics rules, so the 10 scheduled alert rules + the `dc-mdc` data
connector came back as live Microsoft.SecurityInsights child objects that are ABSENT from the emptied state ->
the provider's pre-create GET returns `ImportAsExistsError`. The workspace itself did not error "already
exists" because a soft-deleted workspace GETs 404 (the PUT recovers it and reports success). In-repo precedent:
WORKLOG 2026-07-13 (recovered security LAW watch-item, runs 29471713790/29471965746).

DISPOSITION [SUPERSEDED 2026-07-29 - see the "Recovery path ruling" section below; recovery is now full teardown-and-restart with the Security LAW purged (OQ-063), NOT import-and-continue]: the original ruling was to import the recovered orphans (config-driven `import` blocks, interpolated ids) and continue, and NOT tear down security. That path is no longer used.

### Class 3 - automation rules race onboarding (missing depends_on)

`azurerm_sentinel_automation_rule.auto_assign` and `.ti_enrichment_tag` (sentinel.tf 482-529) reference the
workspace id but lack `depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]` (every other
Sentinel child in the file has it). They ran in parallel with the onboarding PUT; the automation-rule endpoint
gate-checks onboarding even on the existence GET, so it 400'd "not onboarded" before the racing onboarding
settled. Same failure ADR-033 saw for `ti_enrichment_tag` on run 29133588369 and wrongly dismissed as
transient. FIX: add the depends_on to both (Cloud Engineer). On the immediate re-apply this is sufficient
(onboarding is already in state from the partial apply and re-applies as a no-op).

### Class 1 - CloudPosture 409 (serialization that never serialized)

`azurerm_security_center_subscription_pricing.extended`'s `depends_on = [.servers]` gates the whole extended
set behind `servers` but does NOT serialize the six extended instances among themselves - they run concurrently
up to `-parallelism`, and the sub-level pricing controller 409s on concurrent PUTs (CloudPosture lost the
race). The depends_on(servers) edge was only ever validated on the 2026-07-10 INCREMENTAL apply (2 pending
pricing writes). A clean state makes all ~8 pricing plans creates, exposing the six-way concurrency. ADR-034's
real control was `-parallelism=1`, which the single-target rebuild dispatch did not pass. FIX: wire
`-parallelism=1` into this root's apply step (DevSecOps); correct the false code comment (Cloud Engineer).

### Recovery path ruling: FULL TEARDOWN-AND-RESTART with the Security LAW purged (SUPERSEDES the earlier import-and-continue ruling, 2026-07-29)

> The original ruling here was import-and-continue. It was SUPERSEDED on 2026-07-29 by the user's process
> change: when ANY layer fails, the estate is FULLY torn down and the rebuild RESTARTS from Step 1. There is no
> import-and-continue and no partial-state reconciliation. See ADR-067 addendum.

- Recovery is a FULL estate teardown followed by a clean rebuild from Step 1. The security root is NOT
  import-reconciled and NO import blocks are added.
- Class 2 (the ~11 "already exists" orphans) is closed by the teardown PURGING the soft-deleted Security LAW
  BEFORE the restart, so Step 3 of the restart creates a genuinely fresh workspace with no orphans. Tracked as
  OQ-063 and implemented in the ADR-066 all-layers-green teardown workstream (ADR-066 on branch
  `docs/adr-teardown-all-layers-green`, commit 0dac862). The LAW-purge MUST land before the restart reaches
  Step 3, or the Class 2 "already exists" reproduces exactly.
- The naive "teardown JUST platform/security then re-apply" is still wrong for its own reasons (orphans are not
  in the partial state, and it traps the purge-protected KV; LESSON 55-57). The full-estate teardown routes
  around both: the LAW-purge removes the soft-deleted workspace so the orphan-recovery loop cannot occur, and
  the KV is handled by the teardown workstream.

### Code fixes carried into the rebuild (these STAND; already code-reviewed, preflight-clean)

- Class 3: `depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]` added to BOTH automation
  rules (`auto_assign`, `ti_enrichment_tag`) in sentinel.tf.
- Class 1: `-parallelism=1` wired into the security root apply step (DevSecOps), and the false
  "one PUT in flight" serialization comment on `azurerm_security_center_subscription_pricing.extended`
  corrected (Cloud Engineer).

### Ordered actions

1. Teardown lane (OQ-063 / ADR-066 workstream): the full teardown PURGES the Security LAW (and audits the
   security KV soft-delete, given purge protection) so the restart's Step 3 starts clean.
2. Rebuild restarts from Step 1. Step 3 (platform/security) re-applies from a truly empty workspace with the
   Class 1 + Class 3 code fixes in place. No import blocks, no partial-state ops.
3. DevSecOps confirms the security apply uses `-parallelism=1` and the pre-apply plan is 0 destroy with no
   `-/+` replace on any pricing plan; any Sentinel resource showing "already exists" means the LAW purge did
   not run - STOP and complete the purge before proceeding.
