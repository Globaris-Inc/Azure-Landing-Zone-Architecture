# Pre-clearance: Wave B7 - O&M Phase 1 (AMBA-ALZ), HIGH-BLAST-RADIUS POLICY-ENGINE wave

> **Roots:** `platform/management` (AMBA supporting infra: RG + MI + role) and
> `platform/management-groups` (the AMBA policy layer via avm-ptn-alz - HIGH blast radius).
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-19 (checks this session).
> **Code identity:** banking @ d8a5777 (reviewer full-depth APPROVE: platform/amba library path +
> 2026.06.2 ref real, 6 archetypes, policy_default_values keys match, MI-id byte-match, no
> diagnostics collision). Design/decision: docs/b7-om-phase1-design.md, ADR-052.
>
> ## VERDICT: **GO - CONDITIONAL** on PC-1F..PC-6F below.
> The crux is the TWO-PLAN PROOF (PC-2F). One pre-plan flag (PC-1F) is a DevSecOps convergence
> wiring item that is NOT plan-blocking (default handles it) but IS needed for the alert stream to
> reach a human.

---

## 1. The plan is the first real test (why this wave's plan-scan is the crux)

`validate` did NOT exercise the alz-provider library fetch or architecture resolution - the
`azure/alz` provider materializes `platform/amba @ 2026.06.2` + the custom Globaris library and
resolves the selected architecture (globaris vs globaris-amba) ONLY at PLAN time. So the plan is
the first real proof that: (a) the AMBA library ref fetches, (b) the globaris-amba architecture
resolves, and (c) the flag toggles cleanly between the two architectures. Scan it accordingly.

## 2. THE TWO-PLAN PROOF (PC-2F - the headline gate)

### Plan A - inertness proof (RULED 2026-07-19: satisfied WITHOUT a literal flag-false CI plan)

**Mechanics constraint + ruling.** poc.tfvars commits `enable_om_phase1 = TRUE` (merged @ d8a5777)
and deploy.yml has no per-run var-override, so a normal CI plan is Plan B (flag=true). A literal
flag-false plan would require a temporary poc.tfvars revert-to-false commit -> plan -> re-flip:
two extra commits churning a HIGH-BLAST-RADIUS policy-engine root for redundant evidence.
**RULED: not required.** Plan A's ONLY purpose is to prove the flag-off state does not perturb the
live estate. Two independent proofs already cover it: (1) the reviewer's STATIC code proof -
flag-false selects architecture `globaris` = the exact B0a topology, the AMBA module `for_each =
{}`, `policy_default_values = null`; (2) the CURRENT LIVE ESTATE is B0a-green with no B7 applied =
it IS the flag-false baseline. Therefore **Plan B (flag=true) scanned against the current
B0a-green estate carries Plan A's proof inside it:** if Plan B is pure-adds with ZERO
changes/replaces to any existing object, that simultaneously proves the existing estate is
untouched (= flag-off preserved) AND B7 adds cleanly. The zero-changes-to-existing half of the
Plan B bar below now does DOUBLE DUTY - scan it with that elevated weight (a single change/replace
to an existing object falsifies BOTH B7-add-cleanliness AND flag-off-preservation). A literal
flag-false plan is only warranted if Plan B shows an unexplained change to an existing object AND
the cause cannot be isolated by read - a diagnostic fallback, not a standing gate.
- `platform/management-groups`: flag-false selects the `globaris` architecture = the exact B0a
  topology. Plan MUST be **0 add / 0 change / 0 destroy** (allow only the standing OQ-032
  CreatedDate tag-strip noise class if it appears on management-sub resources - not on MG/policy
  objects).
- `platform/management`: flag-false = no AMBA module instantiated. Plan MUST be **0/0/0** (same
  OQ-032 noise tolerance only).
- **ANY functional diff at flag-false = STOP** - the flag is not inert; do not proceed to Plan B.

### Plan B - `enable_om_phase1 = TRUE` on BOTH roots: PURE ADDS, zero touch to existing policy

- **`platform/management` (apply FIRST - see PC-3F): a HANDFUL of adds.** Expected address class:
  the `avm-ptn-monitoring-amba-alz 0.4.0` module set = `rg-amba-monitoring-001` resource group +
  `id-amba-prod-001` user-assigned managed identity + its Monitoring Reader role assignment at the
  Globaris root MG + module telemetry pair. Order of magnitude **~4-6 adds**. **ZERO changes/
  replaces** to any EXISTING management-sub resource (platform LAW, `azurerm_monitor_action_group.
  platform`, Automation Account, portal dashboard, budgets, workbook). Those are REFERENCED, never
  recreated.
- **`platform/management-groups` (apply SECOND): MANY adds, but ALL adds.** Selecting the
  globaris-amba architecture attaches the AMBA archetypes to the root/platform/landingzones MGs,
  which materializes the AMBA policy content. **Expected order of magnitude: ~150-260 policy-object
  adds** (AMBA is ~130+ policy definitions + ~16 initiatives, plus the Alerting-* / Deploy-AMBA-* /
  Notification ASSIGNMENTS across the Globaris-root, platform-family and landingzones MG scopes).
  **A large add count is EXPECTED and is NOT a red flag by itself** - the scan proves they are all
  `+ create`, not the surprise.
- **ZERO-TOLERANCE STOP items on management-groups (any single one = STOP, LESSON 26):**
  - any `~ change` or `-/+ replace` to an EXISTING alz policy ASSIGNMENT (tag-governance,
    Deny-Public-Endpoints, deny-pub-net-globaris, the b11/b13 staged guardrails, etc.),
  - any change/replace to an EXISTING policy DEFINITION or INITIATIVE,
  - any change/replace/move on an EXISTING management GROUP or its archetype (the 11-MG topology
    is shared between globaris and globaris-amba - it must NOT churn; globaris-amba only ADDS amba
    archetypes to the root),
  - any **Deploy-Diagnostics / diagnostic-settings COLLISION** (an AMBA diag policy replacing or
    conflicting with an existing hand-placed or ALZ diag assignment) - the reviewer verified no
    collision statically, the plan must confirm it live.
- Benign/allowed on management-groups: the pure AMBA-object adds; the standing OQ-032 noise.

**If Plan B shows any zero-tolerance item, STOP before apply** - a policy-engine change/replace at
MG scope is estate-wide blast radius.

## 3. Ordering (PC-3F - hard gate)

Apply **`platform/management` FIRST**, then **`platform/management-groups`**. The Deploy-AMBA-*
DINE assignments in management-groups attach the `id-amba-prod-001` MI (by constructed resource id)
as their bring-your-own remediation identity; the MI MUST exist first or the assignments carry a
dangling identity (remediation would fail with no identity to run as).
- **HARD GATE between the two applies:** after the management apply, verify the MI resource id
  `.../resourceGroups/rg-amba-monitoring-001/providers/Microsoft.ManagedIdentity/
  userAssignedIdentities/id-amba-prod-001` is LIVE (az cli / portal) BEFORE dispatching
  management-groups. A missing MI = do not dispatch.
- Sequential, single-dispatcher; no parallel dispatch (B3 incident class).

## 4. Live checks (this session)

| Check | Result | Disposition |
|---|---|---|
| Root MG id `globaris` | architecture defs `globaris` + `globaris-amba` both in lib/, 11-MG shared topology, globaris-amba ADDS amba archetypes to root | PASS (reviewer-verified; plan confirms resolution) |
| alz provider `azure/alz` + library refs | `platform/amba` ref `2026.06.2` + custom Globaris lib in providers.tf | PASS - fetch materializes at plan (PC-2F/PC-6F watch) |
| Platform action group + LAW live | `azurerm_monitor_action_group.platform` + `module.platform_law` in code, B0a-green; REFERENCED by the convergence wiring, not recreated | PASS - Plan A must show zero touch |
| `enable_om_phase1` present + coupled on BOTH roots (must be SAME value) | both variables.tf carry it; poc.tfvars sets true | PASS - the two-plan proof exercises both |
| `om_operator_notification_email` | var `default = ""`; NOT wired in CI `_tf-root.yml` | See PC-1F - NOT plan-blocking (default empty), but the AMBA email receiver stays unset until DevSecOps wires it |
| MI name / role | `id-amba-prod-001` + Monitoring Reader at Globaris root (reviewer MI-id byte-match) | PASS - PC-3F verifies live post-apply |

## 5. PC-1F - the notification-email CI wiring (FLAG: not plan-blocking, but wire it)

`om_operator_notification_email` has `default = ""`, so a plan with the CI var absent will NOT
fail - it renders an AMBA notification action group with NO email receiver. Consequence: AMBA
alerts fire but reach no human, defeating the ADR-052 section-5 convergence goal. **DevSecOps
should add `TF_VAR_om_operator_notification_email` (from a secret) to `_tf-root.yml` env - the
exact pattern already used for `TF_VAR_aks_admin_group_object_ids` and `TF_VAR_fabric_admin_members`
(both live in `_tf-root.yml` from secrets).** Referenced abstractly, never committed. If the user
wants Sev0/1 on-call/SMS distinct from Sev2/3 email, that is a receiver-config choice at build,
not a blocker. NOT a GO blocker; IS a functional-completeness item - the wave is not truly "done"
(operators paged) until it is wired.

## 6. Watch-items (PC-4F)

- **Remediation-identity RBAC propagation (LESSON 35/49):** the Monitoring Reader role on
  `id-amba-prod-001` must propagate before DINE remediation runs. AMBA remediation is ASYNC anyway
  (remediation tasks run after the assignment evaluates), so this is naturally tolerant - but a
  403 at remediation time is AUTHORIZATION (missing/late role), not a wait-longer bug. QA checks
  the role assignment is live; remediation success is verified async (section 8).
- **Policy-assignment PUT timing:** ~150-260 policy objects PUT in one apply - expect a multi-
  minute apply; assignment PUTs are individually fast but numerous.
- **alz-provider first fetch of platform/amba 2026.06.2:** first materialization - a network/
  availability hiccup fails the PLAN (not the estate); rerun the plan (no state impact). This is
  also PC-6F.

## 7. Duration + GO conditions

Duration: management apply ~2-4 min (RG + MI + role); management-groups plan + apply ~5-15 min
(large policy-object set, no long-create). No resource long-runs.

| # | GO condition |
|---|---|
| **PC-1F** | Notification email: NOT plan-blocking (default ""); DevSecOps SHOULD wire `TF_VAR_om_operator_notification_email` before the plan for the alert stream to reach a human (aks/fabric-admin precedent). Record whether wired or deferred |
| **PC-2F** | THE PROOF (Plan A satisfied via the substitution ruled in section 2): scan Plan B (flag=true, committed) against the current B0a-green estate = PURE ADDS both roots with ZERO change/replace to any existing MG/archetype/definition/initiative/assignment and NO Deploy-Diag collision. The zero-changes-to-existing half doubles as the flag-off-preserved proof (elevated weight). Any breach = STOP; a literal flag-false plan only as a diagnostic fallback if an existing-object change appears and cannot be isolated by read |
| **PC-3F** | Ordering: apply management FIRST, verify `id-amba-prod-001` MI live, THEN apply management-groups. Sequential, single-dispatch |
| **PC-4F** | Watch-items (section 6) acknowledged; remediation is async, a 403 is authorization not propagation |
| **PC-5F** | No regression: existing assignments (tag-gov, deny-public, b11/b13 staged guardrails) and the 11-MG topology unchanged (falls out of PC-2F Plan B zero-tolerance) |
| **PC-6F** | alz-provider plan-time library fetch succeeds; a fetch failure is a plan rerun (no state impact), not an estate event |

## 7a. PC-2F disposition (plan run 29702944518) - GO for the management-groups apply

management plan clean (3 adds = RG + MI + role, 0/0). MG plan `223 add / 1 change / 2 destroy`,
fully characterized and DISPOSITIONED:

- **223 adds = the AMBA policy objects** (definitions/initiatives/assignments from the globaris-amba
  archetype) - inside the previewed ~150-260 range, PURE content adds.
- **2 "destroys"(replaces)** = `module.alz_management_groups.time_sleep.after_policy_definitions`
  + `.after_policy_set_definitions` ONLY - the alz-module's INTERNAL orchestration WAIT resources,
  which re-trigger because the policy-definition/set COUNT changed (AMBA added). **Not policy
  objects.** BENIGN module-internal churn.
- **1 "change"** = `module.alz_management_groups.modtm_telemetry.telemetry[0]` - telemetry noise.
- **THE DOUBLE-DUTY PC-2F BAR IS SATISFIED:** zero change/replace to any EXISTING policy
  ASSIGNMENT / DEFINITION / INITIATIVE / MG / ARCHETYPE (every replace/change address enumerated =
  only the two time_sleeps + telemetry). The 11-MG topology and every existing alz object are
  untouched -> flag-off-preservation proven AND B7 adds cleanly. No Deploy-Diagnostics collision.

**The 70 PolicyRoleAssignmentError diagnostics = ACCEPTED pre-existing class, structurally
unamplifiable by B7 (RULED):**
- They are WARNINGS (the plan SUCCEEDED) - the avm-ptn-alz module's DOCUMENTED known-limitation
  class ("known limitation, do not raise issues; suppress via
  `suppress_warning_policy_role_assignments`"). The B0a management-groups apply (run 28794721094,
  WORKLOG) already emitted "many PolicyRoleAssignmentError blocks... the module's
  known-limitation warnings, not failures" - the same OQ-021/OQ-016 class (built-in policies like
  Deploy-MCSB2-Monitoring / Deploy-Diag whose role assignment the provider cannot auto-generate
  from an unparseable ARM-function param / empty resource id).
- The reviewer verified **ZERO of the 70 are AMBA** (0 Deploy-AMBA-* in the error text): B7's own
  remediation-identity wiring (the BYO `id-amba-prod-001` MI) WORKS - the thing B7 actually
  introduced is clean.
- **Amplification ruling:** B7 added ZERO non-AMBA policies. The globaris-amba architecture =
  globaris + the amba archetypes, sharing the IDENTICAL non-AMBA policy set and 11-MG topology, so
  the non-AMBA role-assignment-error surface is IDENTICAL BY CONSTRUCTION - the provider re-emits
  the full-set evaluation on every plan. A literal pre-B7 count diff would require the
  flag-revert plan already ruled out (churn); the structural identity makes the exact count moot,
  and the items are non-fatal warnings regardless. **Not a B7-introduced regression - proceed.**

**CONSOLIDATED RULING: GO for the management-groups apply.** 223 pure AMBA policy adds;
time_sleep/telemetry churn = benign module-internal; 70 role-assignment diagnostics = pre-existing
OQ-021/known-limitation non-fatal class, B7-clean on its own content. Ordering STANDS (PC-3F):
apply `platform/management` FIRST (the 3-add MI/RG/role), verify `id-amba-prod-001` live, THEN
`platform/management-groups`. PC-1F (email TF_VAR) and the async remediation watch (PC-4F) carry
into QA unchanged.

## 7b. APPLY FAILED (run 29703492492) - ARM param-TYPE mismatch: fix-spec + re-apply reconciliation

**Error (ARM PUT-time, not plan):** `InvalidPolicyParameterType: policy parameter
'ALZMonitorActionGroupEmail' ... Expected: Array. Actual: String` on
`azapi_resource.policy_assignments["globaris/Deploy-AMBA-Notification"]`. Root cause: we wired the
email as a plain STRING (`om_operator_notification_email` type=string ->
`jsonencode({ value = var.om_operator_notification_email })`), but the AMBA Notification-Assets
policy expects an ARRAY of emails. A policy-assignment param TYPE is validated by ARM only at PUT,
never at plan - the plan-passes/apply-fails-on-ARM-param class (extends OQ-016 from allowed-VALUES
to param-TYPE).

**HONEST note (own it):** the code review + this pre-clearance verified the param NAME exists
(`policy_default_values` keys match) but NOT its Array-vs-String TYPE. See the LESSON below.

**Expected shape VERIFIED (AMBA docs, today):** `ALZMonitorActionGroupEmail` = **array of plain
email STRINGS** (`"value": [ "action1@contoso.com" ]`), NOT an array of objects. Siblings are also
arrays - `ALZArmRoleId` (`["Owner"]`), `ALZWebhookServiceUri` (`["https://..."]`), Event Hubs -
but **we supply NONE of them** (only the email); they take their definition defaults (empty
arrays), which are valid and will not 400. So ONLY the email param needs the fix.

**FIX-SPEC (cloud-engineer, minimal):** keep `om_operator_notification_email` as a string
TF_VAR/secret (simple to supply); wrap it as an array in the `policy_default_values` wiring, and
guard the empty-default case so an unwired email yields an EMPTY array (no bogus empty-string
receiver), not `[""]`:
```
# was: value = var.om_operator_notification_email
value = var.om_operator_notification_email == "" ? [] : [var.om_operator_notification_email]
```
(jsonencoded as before). Plain array of strings - NOT objects. Verify no OTHER supplied
`policy_default_value` is array-typed: the AMBA action-group NAME/GUID params are strings (fine);
the only array-typed notification targets are email/armrole/webhook/eventhub, and we supply only
email. If the code supplies any additional notification-target default, apply the same array wrap.

**RE-APPLY RECONCILIATION (partial state: 178 of 223 created, in state):** after the fix, re-apply
= the 178 landed AMBA objects NO-OP (already in state, config unchanged - the fix touches only the
email default value which only `Deploy-AMBA-Notification` consumes), and the failed/unreached ~45
(incl. Deploy-AMBA-Notification) CREATE clean. **Bar:** ~45 adds, 0 destroys, **ZERO `-/+` replace
on any of the 178** (a replace on a landed AMBA object = STOP - would mean the fix perturbed
content it should not). An in-place UPDATE limited to an assignment that legitimately consumes the
corrected email default is acceptable-if-scanned (the default value changed from a broken string
to an array); any replace, or an update to a policy object that does NOT consume that default =
STOP. Ordering unchanged: management (already applied its 3) stays; re-dispatch management-groups
only. Single-dispatch. Confirm `id-amba-prod-001` MI still live (PC-3F) before the re-dispatch.

**LESSON (for landing-zone-kit/LESSONS.md - devsecops/architect):** plan-passes/apply-fails on
policy-assignment param TYPE, not just allowed-VALUES (OQ-016 class extended). Verifying a
`policy_default_values` KEY NAME exists is NOT sufficient - the VALUE must match the policy
definition's parameter TYPE (Array vs String vs Object). ARM validates param type only at PUT.
Pre-clearance/review of any policy-assignment param wiring must check the definition's parameter
`type` (via `az policy [set-]definition show` -> parameters.<name>.type), not just the name. AMBA
notification targets (email/armRole/webhook/eventHub) are all ARRAYS.

## 8. QA feed (before green)

- Plan A/B proof archived (the inertness + pure-adds evidence).
- `rg-amba-monitoring-001` + `id-amba-prod-001` MI + Monitoring Reader role live; the MI is the
  remediation identity on a sampled Deploy-AMBA-* assignment (id match).
- AMBA + Deploy-Diagnostics assignments live at Globaris-root / platform / landingzones scopes;
  compliance evaluation started.
- Async remediation: after a propagation window, confirm a sample AMBA alert rule was DEPLOYED by
  remediation onto an estate resource type (e.g. an Azure Firewall or LAW health alert) and
  targets the AMBA / platform action group.
- Convergence: if PC-1F wired, the AMBA action group email == the operator target (one stream);
  if deferred, record the receiver as unset (functional gap, not a failure of the wave's infra).
- No regression on existing policy objects or the MG topology.

---

# ADDENDUM 2026-07-21: re-land conditions for the 2026-07-22 rebuild

The wave B7 content above LANDED on 2026-07-19 and was then torn down with the rest of the estate. For the
2026-07-22 greenfield rebuild `enable_om_phase1` is held **false** (PC-4R option A, see
`b0a-redeploy.md` section 8): on an empty tenant the two roots are circular, because
`platform/management-groups` would select the `globaris-amba` architecture whose Deploy-AMBA-* DINE
assignments reference `id-amba-prod-001` by constructed resource id, while that identity is created by
`platform/management`, which cannot apply before the MG tree exists.

B7 is therefore re-landed as a **second pass over two already-green platform roots at the END of the
rebuild day**. Conditions **PC-1H..PC-4H** in
**[`docs/preclearance/2026-07-22-full-estate-rebuild.md`](2026-07-22-full-estate-rebuild.md)**.

Summary of what changed versus the gate above:

- **PC-1H:** the flip back to `enable_om_phase1 = true` in `envs/poc.tfvars` (line 315) is a
  cloud-engineer change needing reviewer approval and a merge to `banking` before dispatch. It must NOT be
  merged before the main run, or step 1 of the rebuild reintroduces the circularity. Confirm the run's
  `headSha` is the flipped commit before it writes (LESSON 33).
- **PC-2H** restates PC-3F unchanged: apply `platform/management` FIRST, verify `id-amba-prod-001` is live
  with `az identity show -g rg-amba-monitoring-001 -n id-amba-prod-001`, THEN apply
  `platform/management-groups`.
- **PC-3H replaces the estimates above with the LANDED numbers.** `platform/management` = **3 adds**
  (run `29703260837`), not the 4-6 guessed here. `platform/management-groups` = **approximately 223 adds**
  with a permitted band of roughly 200-260, where the ONLY tolerated non-adds are module-internal
  `time_sleep` / `modtm_telemetry` / `random_uuid` helpers (the 07-19 plan showed exactly 1 change and 2
  destroys of that class). Every zero-tolerance STOP item in section 2 above still stands. Roughly 70
  `PolicyRoleAssignmentError` warnings are expected, non-AMBA, non-fatal.
- **The `InvalidPolicyParameterType` failure of run `29703492492` cannot recur**: the array-wrap plus
  empty-guard fix for `ALZMonitorActionGroupEmail` is live at HEAD (`main.tf` line 66), verified in code
  2026-07-21.
- **PC-1F is closed:** `OM_OPERATOR_NOTIFICATION_EMAIL` exists as a repo Secret (set 2026-07-19) and is
  wired as `TF_VAR_om_operator_notification_email` in `_tf-root.yml`, so the AMBA notification action
  group gets a real receiver.
