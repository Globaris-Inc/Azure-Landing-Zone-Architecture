# 2026-07-22 Full-Estate Rebuild - Operator Runbook

> **Owner:** devsecops-engineer. **Audience:** the operator dispatching Wednesday's rebuild, at the
> keyboard, under time pressure. **This is PC-7X** from the pre-clearance gate below - it turns that
> gate's section 3 order into copy-pasteable commands. Where this runbook and the gate disagree, the
> gate is the source of truth and this document has a bug; flag it, do not silently follow this doc.
>
> **What this run is (user framing):** a PROCESS VALIDATION that the full estate can be stood up as a
> real production environment. Cost is not a gating input today. Correctness of sequence and honest
> gate-reading are what this run is actually testing.

**Governing documents (read by this runbook's author, referenced not duplicated below):**

| Doc | What it carries |
|---|---|
| `docs/preclearance/2026-07-22-full-estate-rebuild.md` | The gate. Section 3 is the 14-step order this runbook executes. PC-1X..PC-8X, PC-1C..7C, PC-1S..9S, PC-1H..4H. |
| `DECISIONS.md` ADR-060 | Sequential single-target dispatch is mandatory; `target=all` is not an apply path. |
| `DECISIONS.md` ADR-061 | Cross-root Secret determinism contract (what PC-2X / PC-3X actually are). |
| `DECISIONS.md` ADR-059 | Import-block fix that unblocked identity Pass 1 (closed as of today). |
| `DECISIONS.md` ADR-070, `OPEN-QUESTIONS.md` OQ-067 | Diagnostic-setting and private-endpoint DNS zone group DINE/Terraform ownership; the two-applies pattern in Steps 5-9 below (matrix 3d rows S6/S7). |
| `docs/preclearance/b0a-redeploy.md` | PC-1R..PC-7R for management-groups / management / security, refresh addendum. |
| `docs/preclearance/platform-identity.md` | PC-1G..PC-8G plus the A10 addendum for identity's two-pass. |
| `docs/identity-two-pass-dispatch-runbook.md` | The full identity dispatch procedure. Step 10/11 below hand off to it; do not re-derive it from here. |
| `.github/workflows/deploy.yml`, `_tf-root.yml` | Verified source for every input name used below. |

---

## 0. The two rules you cannot break

**RULE 1. A plan is green only by EXIT STATUS and the absence of `Error:`, never by the tally.**
Check, in this order, every single time:
1. The Terraform Plan job step shows a green check (the step itself did not fail).
2. Open the raw log and search for the literal string `Error:`. Expect zero hits.
3. Only after both of those pass, read the `Plan: N to add, 0 to change, 0 to destroy` line for the
   shape check.

A tally is not proof of success. Verified live today: run `29851615122` printed `Error: Invalid import
id argument`, and then, **29 milliseconds later in the same log stream**, a complete `Plan: 25 to add, 0
to change, 0 to destroy.` summary, followed by the non-zero exit. Terraform renders the hypothetical plan
for context even after a resource has already errored the run out. If you scan for the tally and stop
reading, you will call a failed plan a pass. This rule is restated at every gate below on purpose. Do not
skip step 1 or 2 because step 3 looks fine.

**RULE 2. One root, one dispatch, one at a time. `target=all` is not usable for apply today.**
`deploy.yml` sets `manage_runner_ip: ${{ inputs.target != 'all' }}`. The Terraform state storage account
is `default_action=Deny` with a single operator IP rule, so on `target=all` nothing opens the firewall
and every root 403s at `terraform init`. This is not a style preference, it is a guaranteed failure
(ADR-060). Beyond that: `_tf-root.yml` restores the state SA firewall to Deny on **every** run's exit,
including a failed one, so two runs in flight at once (even against two different roots) will have one
silently cut the other off mid-init (LESSON 31). Dispatch a run. Wait for it to reach a terminal state
(success or failure). Only then dispatch the next one. `target=all` still appears in the workflow
dropdown; it is valid **only** for `action=plan` reconnaissance (that is how the ADR-059 defect was
found yesterday) and is never used for `action=apply` in the sequence below.

**Stakes, stated plainly:** the project has a standing rule that four consecutive failures move the
project off this tooling. That bar is project-level, not per-root. Treat any STOP below as a reason to
stop and re-diagnose, not a reason to blind-retry a third time on the same failure.

---

## 1. The day at a glance (pacing)

Every dispatch below is sequential (Rule 2), so these durations sum, they do not overlap.

| # | Step | Root / phase | Est. duration | Running total (low) |
|---|---|---|---|---|
| 1 | management-groups | plan + apply | ~5 min | 5 min |
| 2 | management | plan + apply, then PC-2X | ~10 min | 15 min |
| 3 | security | plan + apply | ~25-45 min (ADR-067 `-parallelism=1`) | 40 min |
| 4 | connectivity | plan + apply, then PC-3X + PC-4C | ~45-70 min | 85 min |
| 5 | corp-a1 | plan + apply | ~10-15 min | 95 min |
| 6 | corp-a2 | plan + apply | ~10-15 min | 105 min |
| 7 | online-p1 | plan + apply | ~20-30 min | 125 min |
| 8 | bank-data-p1 | plan + apply | ~30-45 min | 155 min |
| 9 | bank-app-p1 Pass 1 | plan + apply | ~60-180 min | 215 min |
| 10 | identity Pass 1 | plan + apply | ~60-180 min | 275 min |
| 11 | identity Pass 2 | plan + apply | ~5 min | 280 min |
| 12 | bank-app-p1 Pass 2 | plan + apply | ~5 min | 285 min |
| 13 | management (B7 re-land) | plan + apply, then PC-2H | ~5 min | 290 min |
| 14 | management-groups (B7 re-land) | plan + apply | ~10-20 min | 300-310 min |

**Low-end total: about 5h0m. High-end total (every step at its own stated maximum): about 10h30m.**
(Recomputed 2026-07-30 when Step 3 moved to 25-45 min: the running-total column was not re-added at
the time and every row below Step 3 was 10 minutes light, with the stated totals 10 and 30 minutes
short respectively. The column is the LOW end of each range, cumulative.) The
gate's own "budget 6 to 9 hours" sits between these because it assumes the two long poles land nearer
their typical case than their worst case, not because the arithmetic is different. Plan the day assuming
6 to 9 hours is realistic and be mentally ready for a 10th hour if both long poles run long the same day.

**The two long poles are step 9 (bank-app-p1, APIM Developer create, observed as long as ~3h) and step
10 (identity Pass 1, AADDS domain create-wait, 1 to 3h by design).** Both are unattended CI waits once
dispatched: you cannot speed them up, cancelling either is actively harmful (see the STOP matrix), and
you cannot dispatch anything else while either is running (Rule 2). These are the two windows to plan
breaks, food, or non-Azure work around, not to work around technically.

---

## 2. Pre-dispatch checklist

Do all of this before the Step 1 dispatch. Command convention used throughout this document: every `gh
workflow run` targets `-R Globaris-Inc/Azure-Architecture --ref banking` (ADR-056; never dispatch from
`main`, it lacks the ADR-055/059/060 wiring this whole day depends on). Subscription IDs are written
below as `<management-sub>`, `<connectivity-sub>`, `<identity-sub>`, `<security-sub>`,
`<landingzones-sub>`; get them from `az account list --query "[].{name:name, id:id}" -o table` or the
repo Secrets page, matching the display name to the role. `resource_address`, `lock_id`, and
`enable_conditional_access_override` are workflow inputs too, but each defaults to blank and is omitted
below whenever it should stay blank. They are spelled out explicitly only where they matter: the identity
Pass 1/Pass 2 override (Steps 10-11) and the recovery-only actions in Appendix B.

### 2a. Blocking user-action items (from the gate's section 7a, today's critical path)

| ID | Action | Command | Verify it took effect |
|---|---|---|---|
| **PC-1S** | **ALREADY SATISFIED 2026-07-22 via CI - no action.** The surviving exemption was removed by the pipeline, not by hand: ADR-062 sub-step 6d deleted `exempt-dbx-managed-storage-bank-data-p1` during teardown run 29880338547, and VERIFY 6d plus VERIFY 9 confirmed zero OWNED subscription-scoped policy objects across all 5 subscriptions. | none | Optional re-confirm: `az policy exemption list --subscription <landingzones-sub> --query "[].name" -o tsv` -> expect empty output |
| **PC-4S** | Confirm the soft-deleted APIM instance is gone (blocks Step 9) | `az rest --method get --url "https://management.azure.com/subscriptions/<landingzones-sub>/providers/Microsoft.ApiManagement/deletedservices?api-version=2024-05-01" --query "value[].name" -o tsv` | Expect empty output. The scheduled auto-purge was 2026-07-21 22:53 UTC, before this runbook is used, so this should already read empty. If it is NOT empty: `az apim deletedservice purge --service-name apim-bank-app-p1-globaris-poc --location eastus2`, then re-run the check above |
| **PC-5X** | Confirm the `bank-app-p1` ACR kubelet-binding gate (PC-2S code fix) is merged to `banking` (blocks Step 9 AND Step 12) | `git fetch origin banking` then `git grep -n "enable_acr_kubelet_binding" origin/banking -- landing-zones/bank-app-p1/` | Expect exactly 3 hits: the variable declaration in `variables.tf`, the data source `for_each` gate in `acr.tf`, the `role_assignments` conditional in `acr.tf`. Fewer than 3 hits means the fix is not fully merged, STOP before Step 9 |
| **PC-6X** | Do NOT open the state SA firewall manually and do NOT dispatch `target=all` for apply, ever, today | posture only, no command to run | Before starting, confirm the SA is at its expected resting state: `az storage account show --name stglobaristfstate01 --resource-group rg-tfstate-mgmt-eus2-001 --subscription <management-sub> --query "networkRuleSet.defaultAction" -o tsv` -> expect `Deny`. If it reads `Allow`, someone left it open; restore it (`az storage account update --name stglobaristfstate01 --resource-group rg-tfstate-mgmt-eus2-001 --subscription <management-sub> --default-action Deny`) before dispatching anything |

**Do not confuse PC-5X (the code gating change, needed before Step 9) with the separate tfvars flip
needed before Step 12.** They are two different PRs at two different points in the day. See Step 12
below. Flipping the tfvars value early would reproduce the exact greenfield-unplannable bug PC-2S exists
to fix. **The PC-5X check above only proves the code gate exists. It cannot see whether the SECOND PR
(the tfvars flip) has already landed too.** Both grep counts in the PC-5X row stay nonzero regardless of
`envs/poc.tfvars` content, so that check alone would pass cleanly even if the flip merged early. Check
the other direction explicitly, here and again at Step 9's own pre-flight:
```bash
git fetch origin banking
git grep -n "enable_acr_kubelet_binding = true" origin/banking -- envs/poc.tfvars || echo "CLEAR - tfvars flip not yet merged"
```
Expect the literal `CLEAR` message. If it instead prints a matching line, the tfvars flip PR merged
early: **STOP, do not dispatch Step 9** until either the flip is reverted on `banking` or Step 9 has
already gone green (at which point the flip is exactly what Step 12 needs and is no longer a hazard).

### 2b. Carried forward from the B0a gate: confirm, do not assume

**This is a gap in the source gate, flagged rather than papered over.** The full-estate gate's own
pre-dispatch checklist (its section 7a) lists only PC-1S / PC-4S / PC-5X / PC-6X. It does not restate the
four conditions from `docs/preclearance/b0a-redeploy.md`'s 2026-07-21 refresh addendum (PC-1R..PC-4R)
that gate Steps 1 through 3, even though that document is explicitly named as still-governing ("those
verdicts stand"). It is not clear from either document whether PC-1R/2R/3R's cleanup was actually
executed on 2026-07-21 or whether it is still outstanding for tomorrow. The checks below are cheap
(a handful of read-only queries) and are here so Steps 1 through 3 do not fail on a precondition this
runbook would otherwise have silently assumed away. One of the four (PC-4R) is independently confirmed
already, no action needed there.

| ID | What to confirm | Command | Expected |
|---|---|---|---|
| **PC-1R** | The 12 subscription-scoped teardown survivors are gone (5 budgets, 5 cost exports, 1 anomaly scheduled action, 1 subscription diagnostic setting) | Budgets, per sub: `az rest --method get --url "https://management.azure.com/subscriptions/<sub-id>/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" --query "value[].name" -o tsv`. Exports, per sub: same path with `Microsoft.CostManagement/exports?api-version=2025-03-01`. Anomaly action, management sub only: `Microsoft.CostManagement/scheduledActions?api-version=2023-11-01`. Diagnostic setting, security sub only: `az monitor diagnostic-settings subscription list --subscription <security-sub> --query "value[].name" -o tsv` | All empty. If anything is present, delete it using the exact commands in `docs/preclearance/b0a-redeploy.md` section UA-1 before Step 1 |
| **PC-2R** | The 8 Defender for Cloud pricing plans that this estate configures are reset to `Free` in the security subscription | `az rest --method get --url "https://management.azure.com/subscriptions/<security-sub>/providers/Microsoft.Security/pricings?api-version=2024-01-01" --query "value[].{plan:name,tier:properties.pricingTier}" -o table` | `VirtualMachines`, `StorageAccounts`, `AppServices`, `SqlServers`, `SqlServerVirtualMachines`, `Containers`, `OpenSourceRelationalDatabases`, `CloudPosture` all read `Free`. If any read `Standard`, reset with `az security pricing create -n <plan> --tier Free --subscription <security-sub>` before Step 3. Do not touch `KeyVaults`, `Arm`, `Dns`, `KubernetesService`, `ContainerRegistry`, `CosmosDbs`, `Api`, `AI`, `Discovery`, `FoundationalCspm` |
| **PC-3R** | `Microsoft.CostManagementExports` is unregistered in the management subscription | `az provider show --namespace Microsoft.CostManagementExports --subscription <management-sub> --query registrationState -o tsv` | `NotRegistered` (or `Unregistering`, wait for it). If `Registered`: `az provider unregister --namespace Microsoft.CostManagementExports --subscription <management-sub>` before Step 2, and do this AFTER PC-1R so the RP has no dependent resources |
| **PC-4R** | `enable_om_phase1 = false` is live on `banking` for the main run | **Already confirmed today.** `envs/poc.tfvars` line 315 on `origin/banking` reads `enable_om_phase1 = false`. No action needed. Optional reconfirm: `git show origin/banking:envs/poc.tfvars` then check the `enable_om_phase1` line by eye |

If PC-1R/2R/3R turn out to already be clean, this whole subsection costs about five minutes of read-only
queries. If they are not clean, this is the difference between Step 1-3 failing on a PUT-time guard that
`plan` cannot see, and catching it before you dispatch anything.

### 2c. Already satisfied, no action needed (confidence list, from the gate)

MG tree empty. State blobs present and unlocked (no stale lease). State SA posture correct otherwise. CI
SP RBAC sufficient at every scope this run needs (no Owner grant exists or is needed, ADR-021). All 21
resource provider namespaces registered in both subscriptions that need them. Both Network Watchers
live. Cross-root Secret `TF_VAR_*` coverage complete for all six B0b/spoke roots (ADR-061). Connectivity
dry-plan clean today (run `29851422904`, 696/0/0, exit 0, no `Error:`) and still valid at HEAD (only
`platform/identity/domain-services.tf` changed since). Local `banking` at parity with `origin/banking`.

### 2d. The watch pattern (used after every dispatch below, not repeated per step)

```bash
gh run list --workflow=deploy.yml -R Globaris-Inc/Azure-Architecture --limit 1
gh run watch <run-id> -R Globaris-Inc/Azure-Architecture
```

`action=apply` runs inside the `production` GitHub Environment and pauses for a manual reviewer
approval. After dispatching an apply, open the run (Actions tab, or the URL from `gh run list`) and
approve the pending deployment, or it will sit waiting indefinitely.

---

## 3. STOP / rollback matrix

Every disposition below is carried forward from an existing gate or lesson, not invented for this
document.

### 3a. Universal (any step, always)

| Code | Symptom | Disposition |
|---|---|---|
| U1 | Any `-/+ replace` or any destroy in ANY plan | **STOP. No exceptions, no console judgement calls.** Every root today runs from empty state; a replace or destroy means state is not actually empty or something drifted. Diagnose before applying (LESSON 26). |
| U2 | Stale state lock at init or plan | `gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="<the stuck root>" -f action="force-unlock" -f lock_id="<ID>"`. Get the lock ID from the failed run's "Error acquiring the state lock" log block, field `ID:` (LESSON 51). Then re-plan. |
| U3 | `terraform init` 403 `AuthorizationFailure` against the state SA | Known flap class from firewall-propagation timing. The workflow already retries init automatically. One rerun of the same dispatch. If it recurs a SECOND time on the same root, stop and treat it as structural, do not keep retrying. |
| U4 | You are tempted to dispatch `target=all` with `action=apply`, or to dispatch a second run while one is in flight | Do not. See Rule 2. There is no time-saving version of this that works; it is a guaranteed 403 or a cross-run firewall race. |
| U5 | Any second identical failure on the same root after one clean retry | HARD STOP. Do not attempt a third time. Escalate for a real fix-spec (LESSON 59: one consolidated fix-spec per failure set, never sprayed single fixes). This counts toward the project's 4-failure bar. |
| U6 | `alz`-provider `PolicyRoleAssignmentError` warnings, or `CreatedDate` tag-drift `~ change` noise on a later plan | Not a stop. Pre-existing OQ-021 and OQ-032 classes, non-fatal, cosmetic. Do not chase them. |

### 3b. Steps 1-3 (management-groups, management, security)

| Code | Symptom | Disposition |
|---|---|---|
| B1 | `already exists ... needs to be imported` on a budget, cost export, anomaly alert, or subscription diagnostic setting | PC-1R did not actually land. Stop, delete the specific survivor (b0a-redeploy.md UA-1), rerun the same root. Do not import. |
| B2 | Defender pricing error "the pricing tier of this subscription is not Free" | PC-2R did not land. Stop, reset that plan to Free, rerun. Do not import blindly. |
| B3 | `azurerm_resource_provider_registration` requires-import on `Microsoft.CostManagementExports` | PC-3R did not land. Stop, unregister, wait for `NotRegistered`, rerun. |
| B4 | Management-groups plan shows a count in the 700s, or any address referencing `rg-amba-monitoring-001` / `id-amba-prod-001` | PC-4R did not actually land (the `globaris-amba` architecture got selected instead of `globaris`). Stop. Confirm `enable_om_phase1 = false` is really on the dispatched ref before retrying. |
| B5 | MG or subscription-placement eventual-consistency error immediately after MG create | Single rerun of the same root; the module sequences internally and this clears on retry. |
| B6 | Sentinel onboarding 409 "already onboarded" (security root), OR any "already exists / needs to be imported" on **any** `Microsoft.SecurityInsights` child | **STOP. Do not import.** This means PC-1SEC did not actually hold and the workspace came back from soft delete (or was never purged). Complete the LAW purge via a CI teardown, then restart from Step 1. ~~Config-driven IMPORT of the onboarding resource, then remove the import block once adopted.~~ **[CORRECTED 2026-07-30: the import disposition was superseded 2026-07-29 by the full-teardown-and-restart ruling and by ADR-067. There is no import-and-continue and no partial-state reconciliation. An operator following the old text would import into a state ADR-067 says must be rebuilt.]** |
| B7 | Sentinel **automation rule** 400 "workspace not onboarded" | **STOP. Not transient.** ADR-033 diagnosed this as timing; ADR-067 proved it was a missing `depends_on`, and that edge is now in the code. Confirm the dispatched `headSha` actually carries it (LESSON 33) rather than rerunning. ~~Eventual-consistency / Defender RP propagation lag against a soft-delete-recovered LAW. Wait, then exactly one rerun.~~ **[CORRECTED 2026-07-30: the struck disposition was the ADR-033 misdiagnosis. For the two automation rules it was never transient, and rerunning masked it across multiple rebuilds.]** |
| B7b | Sentinel **data connector** 400 "workspace not onboarded", or MDC automation 400 "workspace resource id could not be found" | Genuine Defender RP propagation lag. Wait, then exactly one rerun. **[SPLIT from B7 on 2026-07-30: the old single row, struck in B7 above, applied this disposition to the automation rules too, which ADR-067 showed is wrong. It remains correct for these two symptoms.]** |

### 3c. Step 4 (connectivity)

| Code | Symptom | Disposition |
|---|---|---|
| C1 | PC-3C check (before dispatch) shows `Default` instead of `DoNotEnforce` for `Enable-DDoS-VNET` at either MG | STOP before dispatching Step 4. The hub VNet PUTs will 403 `LinkedAuthorizationFailed` exactly as in the ADR-026 incident. Re-verify Step 1 actually applied the policy override; do not dispatch connectivity until both scopes read `DoNotEnforce`. |
| C2 | PC-3X check (after apply) shows a firewall private IP that is not `10.0.0.4` / `10.1.0.4` | The subnet carve drifted from the documented contract. STOP before any spoke dispatch. Re-set the affected Secret from the live value (see Step 4 below for the exact command), then re-run PC-3X to confirm before proceeding to Step 5. |
| C3 | PC-4C check (after apply) does not show all 89 zones, or is missing one of the 11 zones the spokes look up | Missing zone is a spoke PLAN failure waiting to happen, not yet an apply failure. Cheaper to catch here. Diagnose the connectivity apply before dispatching any spoke. |

### 3d. Steps 5-9 (the five spokes)

| Code | Symptom | Disposition |
|---|---|---|
| S1 | Flow-log storage account 403 `RequestDisallowedByPolicy` | The 300s `time_sleep` plus `depends_on` unit is supposed to prevent this. One rerun of the same root. A second failure is a design question, not a wait, stop and escalate. |
| S2 | Databricks managed-RG `dbstorage` denied at create (bank-data-p1, Step 8) | Confirm the subscription-scoped exemption exists (PC-1S must have landed) and its 300s sleep completed, then exactly one retry. A second failure is a design question. |
| S3 | APIM create running past 90 minutes (bank-app-p1, Step 9) | **Do not cancel.** The provider's own timeout is 3 hours; cancelling early leaves a soft-deleted APIM instance behind and reproduces the exact PC-4S condition for the NEXT rebuild. Let it run to either success or its own timeout. |
| S4 | AKS node bootstrap failing (bank-app-p1, Step 9) | Before touching anything else, confirm the primary firewall private IP is `10.0.0.4` (re-run PC-3X) and that the `rcg-aks-egress-primary` collection group is live on the primary firewall policy. Nodes cannot bootstrap through a blackholed default route (ADR-044). |
| S5 | Any spoke plan is missing an expected class from its table in Step 5-9 below, even though the tally looks plausible | Treat as a shape failure per Rule 1, not a pass. Investigate before applying. |
| S6 | Spoke apply fails `already exists ... needs to be imported` on an `azurerm_monitor_diagnostic_setting`, while that resource is absent from Terraform state | This is matrix **B1**: delete the specific survivor, re-dispatch the same `apply`, do not import. Cause NOT confirmed to be ALZ DINE - ruled out for at least the AKS case (no covering DINE policy exists), open as OQ-067 item B. Observed on bank-data-p1 and bank-app-p1 (two applies each, second one clean, all provisioned Azure-side work banked). NOT the ADR-067 teardown/state class - see ADR-070 decision 4. |
| S7 | Spoke apply fails `already exists` on a private-endpoint DNS zone group, while that resource is absent from Terraform state | Confirmed DINE: `Deploy-Private-DNS-Zones` carries no `existenceCondition`, so it can win the race and create the zone group before Terraform does, and Azure allows only one zone group per private endpoint. Same disposition as S6: matrix **B1**, delete the policy-created survivor, re-dispatch, do not import. See ADR-070 decision 2 (the RG-scoped `Mitigated` exemption fix) and the PC-8S correction above. |

### 3e. Steps 10-11 (identity)

Full matrix: `docs/identity-two-pass-dispatch-runbook.md` section 9. The two items worth restating here
because they are the most consequential:

| Code | Symptom | Disposition |
|---|---|---|
| I1 | Any `azuread_*` address appears in the Pass 1 (Step 10) plan | STOP, do not apply. The umbrella gate did not take. |
| I2 | A SECOND identical `AADSTS700024` on a retry of the same pass | HARD STOP. Do not burn a third multi-hour attempt. This is the item most likely to hit the project's 4-failure bar if mishandled; escalate instead of retrying. |

### 3f. Steps 13-14 (B7 AMBA re-land)

| Code | Symptom | Disposition |
|---|---|---|
| H1 | `id-amba-prod-001` is not live after Step 13's apply | Do NOT dispatch Step 14. The Deploy-AMBA-* DINE assignments reference this identity by constructed resource id; a missing identity means dangling remediation with nothing to run as. |
| H2 | Step 13 plan shows anything other than exactly 3 adds, or any change/replace on the platform LAW, action group, Automation Account, dashboard, budgets, or workbook | STOP. Those objects are referenced, never recreated. Only OQ-032 `CreatedDate` tag-strip noise is tolerated. |
| H3 | Step 14 plan count is outside roughly 200-260 adds, or shows any change/replace on an existing policy ASSIGNMENT, DEFINITION, INITIATIVE, or MANAGEMENT GROUP | STOP. Zero tolerance, no exceptions on this list specifically (the 11-MG topology and existing assignments must not churn between the `globaris` and `globaris-amba` architectures). |

---

## 4. QA handoff

**Apply-success is not green.** The deploy-side rule (LESSON 60, made symmetric with the teardown-side
independent-QA rule in ADR-058) is that a root is not marked complete until a qa-engineer pass validates
live Azure state against that root's documented intent, as a separate actor from whoever ran the apply.

**What this runbook's in-run gates are, and are not:** PC-2X, PC-3X, PC-4C, and PC-2H below are fast,
narrow, operator-executable checks whose only job is to keep the sequence from failing forward (a wrong
Secret, a missing zone, a missing identity). They are necessary. They are not a substitute for the full
QA pass, and passing them does not mark anything green.

**When QA runs:** per root, after that root's apply is green, before it is marked complete in
`WORKLOG.md`. It does not block the next sequential dispatch in this runbook (the narrow in-run gates
already cover what would otherwise stall the day). A full-estate QA pass, covering all ten roots plus
the B7 re-land, is required before the day's actual goal (process validation that this estate stands up
as a real production environment) can be called proven.

**Where each root's acceptance criteria live** (this runbook does not restate them; authoring a QA
checklist is the qa-engineer's lane, not devsecops'):
- Identity: `docs/identity-two-pass-dispatch-runbook.md` section 10, already fully itemized.
- Connectivity and the five spokes: each wave's design doc plus the shape tables in Step 4-9 below,
  which is where the actual observed counts should be recorded as the new precedent (PC-9S explicitly
  says the operator's recorded actuals become the reference bars for the next rebuild).
- management-groups / management / security: the B0a gate's own "QA feed" note (verify the five
  `azapi`-created cost exports at their create-time API version `2025-03-01`, not an older one, or they
  read as falsely absent).
- The B7 re-land: PC-3H's exact adds/zero-destroy bars above double as the QA acceptance criteria.

---

## 5. THE RUN

### STEP 0 - prove the estate is actually empty (added 2026-07-30, BLOCKING)

**Do not skip this because a previous session reported greenfield.** On 2026-07-30 this step was added
precisely because "the estate is greenfield" was believed and was false: the 2026-07-29 dispatch got
through Steps 1 and 2, failed at Step 3 (run `30499221661`), and was never torn back down. The MG tree
and three populated resource groups were still live while the record said empty.

- **0a. PC-1Y (whole-run gate), BOTH halves.** Dispatch `teardown-probe.yml` (read-only) and read the
  orphan map and state-blob inventory. Then confirm each half directly, because passing only the first
  is what stalled the 2026-07-30 dispatch:
  - **Live Azure is empty:** `az account management-group list` shows only the Tenant Root Group, and
    no estate resource groups exist in any of the 5 subscriptions.
  - **The state backend is empty too:**

```bash
az storage blob list --account-name stglobaristfstate01 --container-name tfstate \
  --auth-mode login --query "sort_by([].{name:name,bytes:properties.contentLength}, &name)" -o table
```

  Every blob must sit at the empty baseline, roughly 150-250 bytes (observed floor 181). A materially
  larger blob against an empty estate is **FM-2** and a STOP: the plan will refresh phantom resources,
  and per ADR-062 the scoped principal gets 403 rather than 404 on a deleted MG scope, so those
  refreshes are hard errors. Reset it through the teardown (ADR-068 Phase 4), never by hand. A blob
  that is ABSENT or under 100 bytes is the opposite class, **FM-1** (OQ-053): state lost while
  resources may be live. Also a STOP, but do NOT reset it - investigate provenance first.
- **0b. PC-1SEC (gates Step 3).** Prove the Security LAW is not in soft delete:

```bash
az monitor log-analytics workspace list-deleted-workspaces --subscription <security-sub> \
  --query "[?name=='law-security-globaris-poc'].[name,location,id]" -o tsv
```

  Expect EMPTY. **An empty result is NOT sufficient on its own.** On 2026-07-30 this exact query
  returned EMPTY while the workspace was sitting LIVE in `rg-security-globaris-poc`, left by the failed
  Step 3 of the 2026-07-29 dispatch (run `30499221661`), which would have read as a clean PASS. Evidence
  and the full resource inventory are in the 2026-07-30 QA session entry in `WORKLOG.md`. So also
  confirm the workspace is not sitting live:

```bash
az resource list -g rg-security-globaris-poc --subscription <security-sub> -o table
```

  Expect the resource group not to exist at all. A live `law-security-globaris-poc` collides on create
  exactly like a recovered one, and the soft-delete query alone reads as a clean PASS.
- **0c. If 0a shows remnants, or 0b returns a row, or the security RG exists:** dispatch the teardown
  and require Phase 3 VERIFY green, then re-run 0a and 0b and require clean.

```bash
gh workflow run teardown.yml -R Globaris-Inc/Azure-Architecture --ref banking \
  -f target=all -f mode=az-sweep -f include_bootstrap=false \
  -f remove_mg_hierarchy=true -f confirm=destroy
```

  The ref must be at or after `2ca1fc5` (the ADR-066 / LAW-purge merge). `mode=az-sweep` is correct
  when Terraform state is partial: it deletes by API rather than destroying only what state knows about.

  **`remove_mg_hierarchy=true` is NOT optional here, and leaving it off is a silent trap.** It defaults
  to `false`. At `mode=az-sweep` every Phase 1 per-root `terraform destroy` is skipped, including
  `platform/management-groups`, so this flag is the ONLY thing that re-parents the 5 subscriptions to
  tenant root and deletes the `globaris` MG tree. Worse, `scripts/teardown-verify.sh` gates VERIFY 4
  (the MG-hierarchy-gone check) on this same flag: with it false, VERIFY prints "MG hierarchy check
  skipped" and **the run still reports green with the whole tree standing**. An operator who trusts that
  green and proceeds to Step 1 hits the same live-object-versus-empty-state collision at MG scope that
  Step 0 exists to prevent. Set it explicitly, every time, for a full-estate teardown.
- **0d. qa greenfield confirmation** (the standing ADR-058 gate).

Only when 0a-0d are all clean: Step 1.

---

### STEP 1 - `platform/management-groups`

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management-groups" -f action="plan"
```
Scan per Rule 1. Expected: **pure adds, 0 change, 0 destroy, 0 replace, 0 import, roughly 537 adds**
(2026-07-16 `globaris`-architecture precedent). STOP conditions: see matrix U1, B4.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management-groups" -f action="apply"
```
Approve the `production` environment gate. Duration ~5 min. Tolerated noise: roughly 70
`PolicyRoleAssignmentError` warnings (OQ-021 class, non-fatal, matrix U6).

**Gate before Step 4 (not blocking Steps 2-3): PC-3C.** Confirm the DDoS policy override actually landed
at both scopes it needs to cover:
```bash
for MG in connectivity landingzones; do
  az policy assignment show --name Enable-DDoS-VNET \
    --scope "/providers/Microsoft.Management/managementGroups/$MG" \
    --query "{scope:'$MG', mode:enforcementMode}" -o tsv
done
```
Both must read `DoNotEnforce`. If either reads `Default`, matrix C1.

---

### STEP 2 - `platform/management`

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management" -f action="plan"
```
Scan per Rule 1. Expected: **pure adds, 0 change, 0 destroy, 0 replace, 0 import, roughly 36 adds.**
Confirm the platform Log Analytics workspace appears as an ADD (this is the documented soft-delete
recovery PUT, not a fresh workspace). STOP conditions: matrix U1, B1, B2 (indirectly, if the plan
surfaces an import guard on a survivor), B4.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management" -f action="apply"
```
Approve `production`. Duration ~10 min.

**Mandatory in-run gate, immediately after this apply: PC-2X.** Re-set
`PLATFORM_LAW_CUSTOMER_ID` unconditionally. This value is not name-derived, so it cannot be verified,
only re-set (ADR-061). The consumers are four of the five spokes (Steps 5-9, Traffic Analytics): corp-a1,
online-p1, bank-app-p1, and bank-data-p1. corp-a2 declares the variable but never reads it anywhere in
its own root, because Traffic Analytics is deliberately omitted from its DR flow log (no centralus LAW,
LESSON 43); it still needs the value SUPPLIED regardless, since a no-default variable hard-fails if
unset, so this does not change what gets dispatched or when. `platform/security` is not a consumer at
all: Step 3 wires its own `security_law_customer_id` output for Sentinel, from its own Log Analytics
workspace, never this one (verified against `platform/security/sentinel.tf` and `outputs.tf`; an earlier
draft of this runbook, inherited from the source gate, said otherwise). Doing the re-set right here,
immediately after Step 2 and before Step 3, is still the correct and conservative placement even though
Step 3 does not need it at all: a repo Secret is write-only so there is no way to verify its current
value (LESSON 32), and refreshing it the moment the producing root allows means it is unquestionably
ready by the time the four spokes that actually read it need it, with nothing left to remember later in
a long day.
```bash
az monitor log-analytics workspace show \
  --resource-group rg-management-globaris-poc \
  --workspace-name law-platform-globaris-poc \
  --subscription <management-sub> \
  --query customerId -o tsv | gh secret set PLATFORM_LAW_CUSTOMER_ID -R Globaris-Inc/Azure-Architecture
```
Do not skip this because "it was probably unchanged". Repo Secrets are write-only; there is no way to
check the old value, only to overwrite it (LESSON 32).

---

### STEP 3 - `platform/security`

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/security" -f action="plan"
```
Scan per Rule 1. Expected: **pure adds, 0 change, 0 destroy, 0 replace, 0 import, roughly 48 adds.**
Additional checks: zero pricing resources named `KeyVaults`, `Arm`, `Dns`, `KubernetesService`, or
`ContainerRegistry` (ADR-040); exactly 8 pricing adds; Key Vault and Event Hub namespace both carry NEW
random suffixes; the `diag-activity-to-security-law` subscription diagnostic setting present as a clean
add. STOP conditions: matrix U1, B2, B3, B6, **B7** (B7 added 2026-07-30 when it was promoted from
"wait then one rerun" to a hard STOP; B7b remains the retryable connector/MDC class).

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/security" -f action="apply"
```
Approve `production`. **Budget 25-45 min** (was "~15 min"; corrected 2026-07-30). ADR-067 wires
`-parallelism=1` into this root's apply step only, which serialises the graph and lengthens the run by
design. **A Step 3 still running at minute 20 is NOT hung - do not cancel it.**

---

### STEP 4 - `platform/connectivity`

This is the first genuinely large apply of the day (696 resources, both Premium firewalls). Do not
shortcut it with `target=all` to save time, it will not work (Rule 2) and there is no partial-credit
version of the firewall flip.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/connectivity" -f action="plan"
```
Scan per Rule 1. **Bar: EXACTLY 696 to add, 0 to change, 0 to destroy.** This is not an estimate, it is
today's verified dry-plan (run `29851422904`, still valid at HEAD since only
`platform/identity/domain-services.tf` changed after it). Any deviation is a STOP requiring a fresh
disposition, not a judgement call. STOP conditions: matrix U1, C1 (should already be clear from Step 1's
gate, but if this plan itself surfaces a DDoS-policy-shaped failure, re-check C1 before retrying).

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/connectivity" -f action="apply"
```
Approve `production`. Duration ~45-70 min. This is a long pole; do not dispatch anything else while it
runs (Rule 2).

**Mandatory in-run gates, immediately after this apply, before ANY of Steps 5-9: PC-3X and PC-4C.**

PC-3X, firewall private IPs (the one place a "deterministic" value could actually drift):
```bash
az network firewall list --subscription <connectivity-sub> \
  --query "[].{name:name, rg:resourceGroup, ip:ipConfigurations[0].privateIPAddress}" -o table
```
Expect the firewall in `rg-connectivity-primary-globaris-poc` at `10.0.0.4` and the one in
`rg-connectivity-secondary-globaris-poc` at `10.1.0.4`. If either is wrong, matrix C2. Remediation, using
the correct name read from the table above:
```bash
az network firewall show --name <name-from-table> --resource-group <matching-rg> --subscription <connectivity-sub> \
  --query "ipConfigurations[0].privateIPAddress" -o tsv | gh secret set PRIMARY_FIREWALL_PRIVATE_IP -R Globaris-Inc/Azure-Architecture
```
(swap `PRIMARY_FIREWALL_PRIVATE_IP` for `SECONDARY_FIREWALL_PRIVATE_IP` and the secondary RG as needed).

PC-4C, the 11 zones the spokes look up by data source:
```bash
az network private-dns zone list -g rg-dns-globaris-poc --subscription <connectivity-sub> \
  --query "length(@)" -o tsv     # expect 89
az network private-dns zone list -g rg-dns-globaris-poc --subscription <connectivity-sub> \
  --query "[?contains(name,'azmk8s') || contains(name,'azurecr') || contains(name,'servicebus') || contains(name,'database') || contains(name,'dfs') || contains(name,'azuredatabricks') || contains(name,'openai') || contains(name,'cognitiveservices') || contains(name,'search.windows') || contains(name,'services.ai') || contains(name,'blob.core')].name" -o tsv
```
If anything is missing, matrix C3.

---

### STEPS 5-9 - the five landing-zone spokes

**Read this before dispatching any of them.** Unlike Steps 1-4, these five roots were dry-planned for the
first time against a genuinely empty estate during the 2026-07-31 rebuild (their private DNS zone data
sources 404 until connectivity is live, so no clean precedent plan existed before that). **The magnitudes
in the table below are now the verified `Plan: N to add` tally actually observed for each spoke** -
previously this table carried only derived estimates.

**State the unit, or the bar cannot gate anything.** The number in the table is the RAW Terraform plan
tally - the same `N` in `Plan: N to add, 0 to change, 0 to destroy` - and that tally **includes AVM
module telemetry pseudo-resources** (`modtm_telemetry` and `random_uuid.telemetry`), not just real Azure
infrastructure. Without saying so, a bar is ambiguous and a correct plan can look like a false STOP:
bank-data-p1's first observed count (73) read as a 13-over STOP against the table's prior `~50-60`
estimate until the unit was made explicit - 73 = **49 real resources + 24 telemetry** (12
`modtm_telemetry` + 12 `random_uuid.telemetry`; the `datalake` module alone contributes 10 telemetry
resources across five `diagnostic_setting_*` sub-modules while producing exactly one real diagnostic
setting). corp-a1 and online-p1 measured UNDER their prior estimate ranges, for the opposite and
unrelated reason: gated-off optional features (flags left `false` in `envs/poc.tfvars`), not a missing
unit. Treat the SHAPE rules (pure creates, 0 change, 0 destroy, 0 replace, the listed classes present) as
the real bar per Rule 1, always; the magnitude below remains a sanity check, never a hard gate on its
own, and telemetry counts are read-only noise you cannot influence by editing the root.

They may be dispatched in any order relative to each other (Steps 5-9 do not depend on one another), but
each individually needs Step 4 done (all five) and Step 3 done (all five, for the platform LAW). Step 9
(bank-app-p1) additionally needs firewall passage live for its force-tunneled traffic mid-provision
(ADR-047) and AKS cannot bootstrap through a blackholed default route (ADR-044), both already satisfied
by Step 4. The order below (shortest first, longest last) is the gate's own recommendation so the four
short spokes prove the shared spoke contract before you commit to the long one.

**Expect TWO applies on any root that creates `azurerm_monitor_diagnostic_setting` resources (ADR-070,
OQ-067 item B).** Established live across bank-data-p1 and bank-app-p1: the first apply fails with
`already exists` on some of those settings while they are absent from Terraform state. **The cause is
NOT confirmed to be ALZ DINE** - do not restate that as the explanation. The AKS diagnostic setting hit
the identical failure in bank-app-p1's Step 9 even though AKS has no covering DINE diagnostics policy
in this tenant at all, which rules DINE out for at least that case. OQ-067 item B leaves two open
candidates (an orphaned object from a lost PUT acknowledgement, or a `RequiresImport` false positive on
the azurerm provider's pre-check GET - a reported class on that provider) and the discriminating read is
not yet done. **The disposition does not depend on resolving it**: this is runbook matrix **B1** (delete
the specific survivor, rerun, never import) - it is **NOT** the ADR-067 teardown/state class, and it does
not mean the root is broken. Delete the orphaned diagnostic setting(s), re-dispatch the same `apply`, and
expect it to go green quickly the second time. Observed: bank-data-p1 (3 settings; first two attempts
`30661012325` / `30662610292` failed, recovered by `30671577938` in 3m36s) and bank-app-p1 (5 settings,
run `30672301220` failed the same way at 33m50s, all provisioned Azure-side work banked and not
repeated by the retry). See ADR-070 decision 4 and OQ-067 item B for the live investigation, and matrix
3d row S6.

**Correction: `Deploy-Private-DNS-Zones` DINE can block a spoke CREATE, not just cause post-apply
drift (ADR-070, correcting `docs/preclearance/2026-07-22-full-estate-rebuild.md` PC-8S).** Unlike the
diagnostic-setting class above, this one IS confirmed DINE: the assignment carries **no
`existenceCondition`**, so it fires on any private endpoint that lacks a zone group, and Azure permits
only **one** private DNS zone group per private endpoint. That document's PC-8S row previously read this
policy as "post-apply drift only, never a create blocker" - the architect established that is false. A
private endpoint whose zone group Terraform has not yet created (exactly the state a failed apply leaves
behind) is exactly the case this policy can block. This bites hardest on the Foundry account private
endpoint in bank-data-p1, whose three-zone group is authored natively rather than by a module. If a
spoke apply fails on a private-endpoint DNS zone group collision, treat it as a live create-blocker, not
a QA-only finding - see matrix 3d row S7.

| Spoke | Key classes that must appear | Verified `Plan: N to add` (raw tally, INCLUDES telemetry - sanity check only, not the Rule-1 bar) |
|---|---|---|
| corp-a1 | 4 RGs; spoke VNet 3 subnets (`snet-integration` carries NSG + route table); route table default route to `10.0.0.4`; 2 peerings; RSV ZoneRedundant; flow-log SA + Traffic Analytics; 1 DNS zone VNet link; 2 policy exemptions + 1 `time_sleep` | 24 (run recorded 2026-07-31, 0 change / 0 destroy) |
| corp-a2 | same shape, secondary region; RSV GeoRedundant; route to `10.1.0.4`; Traffic Analytics DISABLED on the DR flow log (no centralus LAW) | 24 (run recorded 2026-07-31, 0 change / 0 destroy) |
| online-p1 | 4 RGs; spoke VNet 3 subnets, all with NSGs; route table on workload/PE subnets ONLY, never the App Gateway subnet; 2 peerings; Standard zonal public IP; WAF policy (OWASP 3.2, Prevention); App Gateway WAF_v2 capacity 1; Static Web App Standard; flow-log SA + 2 flow logs | 26 (run recorded 2026-07-31, 0 change / 0 destroy) |
| bank-data-p1 | 4 RGs; spoke VNet with 2 Databricks-delegated subnets; 2 peerings; 7 private DNS zone links; **subscription-scoped dbstorage exemption + 300s sleep as a fresh CREATE** (PC-1S must have landed); Databricks workspace + access connector; ADLS Gen2 + PEs; Fabric F2 capacity; Foundry account + gpt-5.4-nano deployment + PE; AI Search basic + PE | 73 = 49 real + 24 telemetry (Step 8 plan, 2026-07-31; that apply then hit S6 on 3 diagnostic settings, recovered by retry run `30671577938` in 3m36s) |
| bank-app-p1 Pass 1 | 4 RGs; spoke VNet (`snet-aks-nodes` / `snet-apim` / `snet-private-endpoints`); UDR; dedicated `snet-apim` route table; 2 peerings; 3 private DNS zone links; control-plane UAI + 2 role assignments + 300s RBAC sleep; AKS cluster; Premium ACR + PE **with NO `kubelet_acr_pull` role assignment** (flag is false this pass, by design); Service Bus Premium + PE; Event Hubs Standard + PE; APIM Developer_1 + scoped gateway-FQDN zone | 67 (first measurement, 0 change / 0 destroy / 0 replace / 0 import, taken AFTER the ADR-070 exemptions merged) |

**Pre-flight immediately before dispatching corp-a1, corp-a2, or online-p1:** none beyond Step 4's gates.

**Pre-flight immediately before dispatching bank-data-p1 (Step 8):** re-confirm PC-1S actually took.
```bash
az policy exemption list --subscription <landingzones-sub> --query "[].name" -o tsv
```
Expect empty (or at least, `exempt-dbx-managed-storage-bank-data-p1` absent). If present, matrix S2 will
fire at apply; delete it now instead.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-data-p1" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-data-p1" -f action="apply"
```

**Pre-flight immediately before dispatching bank-app-p1 Pass 1 (Step 9):** re-confirm PC-4S and PC-5X,
both from section 2a, since hours will have passed since the morning check. This is also the last chance
to catch the Step 12 tfvars flip having landed too early, which the PC-5X check by itself cannot see
(that check only proves the code gate exists, not that `envs/poc.tfvars` is still leaving it off).
```bash
az rest --method get --url "https://management.azure.com/subscriptions/<landingzones-sub>/providers/Microsoft.ApiManagement/deletedservices?api-version=2024-05-01" --query "value[].name" -o tsv
git fetch origin banking
git grep -c "enable_acr_kubelet_binding" origin/banking -- landing-zones/bank-app-p1/variables.tf landing-zones/bank-app-p1/acr.tf
git grep -n "enable_acr_kubelet_binding = true" origin/banking -- envs/poc.tfvars || echo "CLEAR - tfvars flip not yet merged"
```
First expect empty (PC-4S, the soft-deleted APIM is gone). Second expect a nonzero count in both files
(PC-5X, the code gate is present). Third expect the literal `CLEAR` message, not a matched line (the
tfvars flip has not landed yet). If the third check prints a matching line instead of `CLEAR`: **STOP,
do not dispatch Step 9.** The AKS-lookup data source would now attempt a real lookup of a cluster that
does not exist yet and 404 at plan, the exact defect PC-2S exists to prevent (Rule 1 catches it before
any bad apply, but it is an avoidable failure on a day with a four-failure project bar). Revert the
tfvars line on `banking` before dispatching. If either of the first two checks fails instead, matrix S3
territory is about to open with no way back except a fresh PC-4S purge or a merge you should do first.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-app-p1" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-app-p1" -f action="apply"
```
Approve `production`. Duration ~60-180 min. Long pole. Do not cancel past 90 minutes (matrix S3). Watch
for AKS bootstrap issues (matrix S4).

(corp-a1 / corp-a2 / online-p1 use the identical two-line plan-then-apply pattern, substituting
`landing-zones/corp-a1`, `landing-zones/corp-a2`, `landing-zones/online-p1` for the target.)

---

### STEP 10 - `platform/identity` Pass 1

**Full procedure: `docs/identity-two-pass-dispatch-runbook.md` sections 3 through 6.** This runbook does
not duplicate it. What changed since that document was written, so you are not reading it cold: the
blocker it flagged in its own section 0 / A10 addendum (the import block's `id` argument being
unplannable on greenfield, ADR-059) is now CLOSED. The `.tf` fix merged, the
`AADDS_IMPORT_REPLICA_SET_ID` Secret was cleared to empty, and an exploratory plan run today
(`29859999792`) confirmed a clean Pass 1: **26 to add, 0 to change, 0 to destroy, exit status zero, zero
`Error:` diagnostics.** Treat 26 as the new expected magnitude for Pass 1 (in addition to the
runbook's own shape rule: zero `azuread_*` addresses, zero destroy/replace).

Pre-flight: confirm Steps 1 and 4 are both green (identity's VNet peers to the primary hub, and the
ADR-028 exemption references the identity-MG `Deny-Public-IP` assignment by literal id). Serial ordering
today makes this automatic, just do not dispatch identity out of the 1-14 order.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="plan" -f enable_conditional_access_override="false"
```
Scan per Rule 1, then the identity-specific shape rule: zero `azuread_*` addresses, zero destroy/replace,
roughly 26 adds. STOP conditions: matrix I1, plus the full matrix in the identity runbook section 9.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="apply" -f enable_conditional_access_override="false"
```
Approve `production`. Duration ~60-180 min, dominated by the AADDS create-wait. Long pole, do not
dispatch anything else while it runs.

**If the create-wait times out:** this is a documented, expected failure mode, not an automatic STOP.
Go to the identity runbook section 6 for the untaint-vs-import recovery decision tree. Do not improvise
a third option. A SECOND identical `AADSTS700024` after one recovery attempt is a hard STOP (matrix I2).

---

### STEP 11 - `platform/identity` Pass 2

Only after Step 10 (or its recovery) lands green.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="plan" -f enable_conditional_access_override="true"
```
Scan per Rule 1, then: the AADDS domain plans as 0 change / 0 replace (a `-/+ replace` here is a STOP,
see the identity runbook section 9); **exactly ten pure adds** (the named location, its `time_sleep`,
and all 8 Conditional Access policies CA-001 through CA-008 including `geo_block`/CA-005, which IS
correctly present, not a bug); zero change/replace to the VNet, subnet, NSG, RSV, exemption, or peering.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="apply" -f enable_conditional_access_override="true"
```
Approve `production`. Duration ~5 min (a domain Read plus nine fast Graph writes under a freshly-minted
token, this is the entire point of the two-pass split).

---

### STEP 12 - `landing-zones/bank-app-p1` Pass 2

**This needs a separate, later PR from PC-5X.** PC-5X (already required before Step 9) is the code gate
that makes Pass 1 plannable with the binding OFF. This step needs a second, one-line tfvars change that
turns the binding ON, and it must not land before Step 9 is green.

**Checkpoint, after Step 9 is green:** the cloud-engineer raises a one-line PR adding
`enable_acr_kubelet_binding = true` to `envs/poc.tfvars`, reviewer approves, user merges to `banking`.
Confirm it actually landed before dispatching:
```bash
git fetch origin banking && git grep -n "enable_acr_kubelet_binding" origin/banking -- envs/poc.tfvars
```
Expect one line, `enable_acr_kubelet_binding = true`. If it is absent, the plan below will show 0 adds
instead of 1 (the binding stays gated off); if the file line is missing entirely do not dispatch yet.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-app-p1" -f action="plan"
```
Scan per Rule 1. **Bar: exactly 1 to add (the `kubelet_acr_pull` role assignment), 0 to change, 0 to
destroy.** Anything else, especially anything touching the AKS cluster or ACR registry itself, is a STOP
per matrix U1; it likely means the cluster's live state does not match what the data source expects.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-app-p1" -f action="apply"
```
Approve `production`. Duration ~5 min.

---

## CHECKPOINT before Steps 13-14: do not merge the B7 flag flip early

**Do not merge the `enable_om_phase1 = true` tfvars PR until Steps 1 through 12 above are fully green.**
If it lands on `banking` early, Step 1 (already run) would have selected the `globaris-amba` architecture
instead of `globaris` and reintroduced the exact circularity PC-4R exists to avoid. It is safe only now,
after the whole main estate is up.

The cloud-engineer raises the one-line PR (`envs/poc.tfvars` line 315, `false` to `true`), with the
surrounding comment block updated to record that `false` was the greenfield-ordering workaround and
`true` is the steady state. Reviewer approves, user merges.

**Before dispatching Step 13, confirm the merge actually landed on the ref you are about to run**
(LESSON 33, verify headSha before letting a dispatch write):
```bash
git fetch origin banking && git grep -n "enable_om_phase1" origin/banking -- envs/poc.tfvars
```
Expect `enable_om_phase1 = true`.

---

### STEP 13 - `platform/management` (B7 re-land)

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management" -f action="plan"
```
Scan per Rule 1. **Bar: exactly 3 to add** (`rg-amba-monitoring-001`, `id-amba-prod-001`, its Monitoring
Reader role assignment at the Globaris root MG). **Zero destroys, zero replaces** on the platform LAW,
action group, Automation Account, dashboard, budgets, or workbook, all of which are referenced, never
recreated. Only OQ-032 `CreatedDate` tag-strip noise is tolerated. STOP conditions: matrix H2.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management" -f action="apply"
```
Approve `production`. Duration ~5 min.

**Mandatory in-run gate before Step 14: PC-2H.** Verify the AMBA managed identity is actually live before
touching management-groups. A missing identity means Step 14's DINE assignments would carry a dangling
remediation identity.
```bash
az identity show -g rg-amba-monitoring-001 -n id-amba-prod-001 --subscription <management-sub> \
  --query "{id:id, principalId:principalId}" -o json
```
If this fails or returns nothing, matrix H1, do not dispatch Step 14.

---

### STEP 14 - `platform/management-groups` (B7 re-land)

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management-groups" -f action="plan"
```
Scan per Rule 1. **Bar: approximately 223 adds, accept a band of roughly 200-260** (the architecture
flips from `globaris` to `globaris-amba`, landing the AMBA policy/initiative/assignment set on top of
the already-live 11-MG topology; the pinned AMBA library ref means a large drift outside this band is
itself the finding). Permitted non-adds: module-internal helpers only (`time_sleep`, `modtm_telemetry`,
`random_uuid`). **Zero tolerance, no exceptions:** any change or replace on an existing policy
ASSIGNMENT, DEFINITION, INITIATIVE, or MANAGEMENT GROUP. Expected non-fatal noise: roughly 70
`PolicyRoleAssignmentError` warnings (matrix U6). STOP conditions: matrix H3.

```bash
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management-groups" -f action="apply"
```
Approve `production`. Duration ~10-20 min.

**This is the last step. The 14-step sequence is complete once this apply is green.**

---

## 6. End of day (explicitly not part of today's dispatch work)

- Kick off the full-estate QA pass (section 4). Do not mark any root complete in `WORKLOG.md` until it
  has run.
- Record every spoke's actual `Plan: N to add` count (Steps 5-9) in `WORKLOG.md` as the new reference
  bars for the next rebuild (PC-9S).
- Update `WORKLOG.md` with the actual run IDs for the day, one line per step, per the standing CLAUDE.md
  convention.
- **Do NOT revoke anything today.** The ADR-041 temporary tenant-root grants (User Access Administrator
  and Cost Management Contributor at Tenant Root Group) stay attached through today's work. Revocation
  happens strictly after a verified-clean pass, by query not assumption, as its own later action
  (LESSON 57). Same for any temporary directory roles granted during identity recovery, if recovery was
  used, track them from the day they were granted.
- No teardown activity of any kind is part of this runbook.

---

## Appendix A: full dispatch command list, in order

For copy-paste convenience only; the authoritative version of each command, with its gate and STOP
conditions, is in section 5 above. Every command targets `-R Globaris-Inc/Azure-Architecture --ref
banking`.

```bash
# 1. management-groups
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management-groups" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management-groups" -f action="apply"

# 2. management
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management" -f action="apply"
# then PC-2X (re-set PLATFORM_LAW_CUSTOMER_ID, see Step 2)

# 3. security
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/security" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/security" -f action="apply"

# 4. connectivity
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/connectivity" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/connectivity" -f action="apply"
# then PC-3X and PC-4C (see Step 4)

# 5-9. the five spokes (any relative order; bank-app-p1 needs its own pre-flight, see Step 9)
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/corp-a1" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/corp-a1" -f action="apply"

gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/corp-a2" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/corp-a2" -f action="apply"

gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/online-p1" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/online-p1" -f action="apply"

gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-data-p1" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-data-p1" -f action="apply"

gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-app-p1" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-app-p1" -f action="apply"

# 10. identity Pass 1
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="plan" -f enable_conditional_access_override="false"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="apply" -f enable_conditional_access_override="false"

# 11. identity Pass 2
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="plan" -f enable_conditional_access_override="true"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="apply" -f enable_conditional_access_override="true"

# 12. bank-app-p1 Pass 2 (only after the tfvars flip PR merges, see Step 12)
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-app-p1" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="landing-zones/bank-app-p1" -f action="apply"

# --- CHECKPOINT: merge enable_om_phase1=true now, not before ---

# 13. management (B7 re-land)
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management" -f action="apply"
# then PC-2H (verify id-amba-prod-001 is live, see Step 13)

# 14. management-groups (B7 re-land)
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management-groups" -f action="plan"
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/management-groups" -f action="apply"
```

## Appendix B: recovery command shapes (used only if the STOP matrix sends you here)

```bash
# force-unlock a stuck state lease (matrix U2)
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="<root>" -f action="force-unlock" -f lock_id="<ID from the failed run's Lock Info block>"

# untaint the AADDS domain after a Pass 1 create-wait timeout (identity runbook section 6a)
gh workflow run deploy.yml -R Globaris-Inc/Azure-Architecture --ref banking -f target="platform/identity" -f action="untaint" -f resource_address="azurerm_active_directory_domain_service.this[0]" -f enable_conditional_access_override="false"
```
