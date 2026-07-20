# Pre-Clearance - teardown re-dispatch (mode=az-sweep, remove_mg_hierarchy=true)

> **Owner:** Cloud Solutions Architect (mandatory pre-clearance gate; this is a RETRY of a failed
> operation - teardown run 29712487341 - so pre-clearance is required before dispatch per the user's
> hard bar).
> **Scope:** clear the remnants left by run 29712487341 with a single re-dispatch of `teardown.yml`
> (`target=all`, `mode=az-sweep`, `confirm=destroy`, `remove_mg_hierarchy=true`,
> `include_bootstrap=false`). Docs only - no Terraform, no workflow edits in this lane.
> **Reads:** docs/teardown-redesign.md sections 9-10, DECISIONS.md ADR-054 amendment, the 4 teardown
> scripts, .github/workflows/teardown.yml.
> **Last updated:** 2026-07-20

---

## OUTCOME - attempt 4, run 29753193590: the section-11 `show` fix was the WRONG oracle (principal-dependent); corrected to the `az account management-group list` snapshot

Attempt 4 applied the section-11 per-MG `az account management-group show` existence gate (DISARM +
VERIFY) and re-dispatched mode=az-sweep, remove_mg_hierarchy=true against the already-empty estate.
It FAILED at Phase 0 DISARM, Phase 2 az-sweep step 4, AND Phase 3 VERIFY (VERIFY 1 + VERIFY 4) - four
sites - even though the estate was, and remains, fully torn down.

- **Root cause (principal-dependent oracle).** The teardown runs as the SCOPED OIDC SP, whose MG-read
  grants were scoped to the globaris subtree (identity.tf) and were DELETED with it. For the SP, a
  `show` on a DELETED globaris-tree MG returns HTTP-403 `AuthorizationFailed` (no grant left over that
  scope), NOT the 404 `ManagementGroupNotFound` section 11 assumed. `is_auth_error` matches the 403,
  so the point-11 gate failed loud on benign already-gone MGs. Section 11 looked correct only because
  in run 29749656053 DISARM ran while the MGs were still live (a `show` there succeeded).
- **Empirical proof (probe run 29756715840, run AS THE SP - a read-only diagnostic in the
  production-destroy environment; cited by run number, no GUIDs):**
  - `az account management-group list -o table` -> SUCCEEDS for the SP, returns ONLY the tenant root
    (all deleted globaris-tree MGs ABSENT).
  - `az account management-group list --query "[].name" -o tsv` -> only the tenant-root name.
  - `az account management-group show --name globaris` -> 403 `AuthorizationFailed` (root cause
    reproduced).
  - `az account management-group show --name <tenant-root>` -> SUCCEEDS (`show` works for the SP only
    at a scope it still holds a grant over).
  - The SP's surviving grant is Management Group Contributor at the tenant root (identity.tf; tenant
    root is never deleted), carrying `managementGroups/read` + `Microsoft.Authorization/*/read`, so a
    `list` over the readable tenant-root collection is always available; a deleted MG is simply absent
    from it.
- **Corrected oracle (ADR-054 point 12; teardown-redesign section 12 + corrected 10.2 / 10.3 / 10.4).**
  Replace the per-MG `show` with a ONE-TIME `az account management-group list` snapshot at ALL FOUR
  sites (DISARM per-MG loop, VERIFY 1 loop, VERIFY 4 gone-assertion, az-sweep step 4). MG existence =
  name membership in the snapshot. AUTH-FAIL-LOUD moves to the LIST call: a non-zero `is_auth_error`
  list is a genuine dead token -> fail loud; a successful list is authoritative ground truth.
  `is_auth_error` is UNCHANGED; the per-MG `show` is removed everywhere. The throwaway probe workflow
  `.github/workflows/_probe-sp-mg.yml` MUST be DELETED in this fix round.
- **Attempt-5 expectation.** Re-dispatch the same inputs after the snapshot-oracle fix lands in
  teardown-disarm.sh, teardown-verify.sh (VERIFY 1 + VERIFY 4), and teardown-az-sweep.sh step 4: the
  snapshot returns only the tenant root -> DISARM and VERIFY 1 skip every globaris-tree scope, step 4
  no-ops, VERIFY 4 confirms the target MG names absent, VERIFY 2/3/5 succeed with zero rows -> **Phase
  3 GREEN**. STOP only if the ONE `az account management-group list` fails `is_auth_error` (a genuine
  dead token - diagnose, do not blind re-dispatch); a deleted-scope 403 can no longer occur because no
  per-scope `show` is made. The fix is a focused DevSecOps change to three scripts (+ deleting the
  probe workflow) plus a focused code-review re-approval before attempt 5.

---

## OUTCOME - run 29749656053 (prior dispatch): teardown SUCCEEDED; workflow-red is a VERIFY 1 false-positive

The dispatch ran (mode=az-sweep, remove_mg_hierarchy=true, feature/teardown-redesign) with C1(a)
applied (`--force-deletion` in step 1). The pre-clearance's central hypothesis PASSED:

- **Phase 0 DISARM: success** (cleared every MG-scope policy assignment while MGs still existed).
- **Phase 2 AZ SWEEP: success in about 10 minutes** - the section-3 PASS bars all met: NO AADSTS /
  "valid time range" / token / az_relogin error anywhere (3.a PASS), the reconcile completed under the
  30-minute ceiling (3.b PASS), the fresh OIDC assertion minted inside the job (3.c PASS). C1 held -
  `--force-deletion` cleared the Databricks managed RG (2.3 closed).
- **Live estate after the run:** Databricks workspace gone, both landingzones workload RGs gone,
  rg-amba-monitoring-001 gone, all 11 globaris-tree MGs deleted (only tenant root remains), 0 policy
  assignments at every scope. Genuinely, fully torn down (live-verified).
- **Phase 3 VERIFY:** VERIFY 2/3/4/5 clean/consistent-with-clean; ONLY VERIFY 1 failed.

**The failure is a benign VERIFY 1 false-positive, NOT the section-4.2 auth-class STOP.** VERIFY 1
runs `az policy assignment list --scope <mg>` on the 11 MGs Phase 2 had just deleted; ARM returns a
403 `AuthorizationFailed ... or the scope is invalid ... refresh your credentials`, which
`is_auth_error` matches (via the "credentials" tail) and VERIFY 1 wrongly treated as a dead token. It
is a deleted-scope response, not an auth-durability failure. The token-durability mechanism this
pre-clearance existed to test did NOT fail - it worked. Full disposition + fix ruling: ADR-054
point 11 and docs/teardown-redesign.md section 11 (fix = MG-existence gate in VERIFY 1 AND DISARM).

**This does NOT trigger the section-4.2 "diagnose before attempt 4" auth-STOP** (that STOP is for the
durability fix NOT holding; it held). It IS routed to the architect per the mandate, and the
disposition is issued (above). Architect recommendation on the 4-attempt bar: do NOT count this as a
teardown failure (estate fully torn down and live-verified; a new benign verify-gate class distinct
from attempts 1-2). The user decides. See section 11.4 of the redesign doc for the reasoned
recommendation and the candid counter-argument.

### Attempt-4 bar (post-fix confirmation run) - SUPERSEDED: the `show` gate this described failed on attempt 4

> **SUPERSEDED - see the top OUTCOME block (attempt 4, run 29753193590).** This subsection assumed the
> section-11 `show` gate would make attempt 4 green ("every MG `show` returns NotFound"). Attempt 4
> proved that FALSE for the scoped SP - a `show` on a deleted MG returns a 403, not a 404 - so the
> `show` gate failed loud at four sites. The corrected oracle is the `az account management-group list`
> snapshot (ADR-054 point 12); the confirmation run is now ATTEMPT 5. Retained for the audit trail; the
> original (now-wrong) text follows.

Attempt 4 re-dispatches the SAME inputs after the MG-existence-gate fix lands in teardown-disarm.sh
AND teardown-verify.sh (both loops - fixing only VERIFY leaves attempt 4 failing at Phase 0 DISARM,
which on an already-empty estate hits the identical deleted-scope 403). It runs against an
already-empty estate, so DISARM and Phase 2 are near-no-ops.

- **PASS (the required outcome):** every MG `show` returns NotFound -> DISARM and VERIFY 1 skip each
  scope cleanly; Phase 2 step-4 (already gated) skips gone MGs; RG/KV/Databricks lists over the
  still-present subscriptions succeed with zero rows; VERIFY 4 confirms every MG gone -> **Phase 3
  GREEN**. This green run is the confirmation the design's "green Phase 3 IS success" bar demands.
- **STOP:** any auth-classified fail at DISARM / Phase 2 / VERIFY that is NOT a deleted-MG `show`
  NotFound (i.e. a genuine dead token or transport error) - that would be a real auth-durability
  regression; diagnose, do not blind re-dispatch.
- The fix requires a focused DevSecOps change to two scripts + a code-review re-approval before
  attempt 4 (mirrors the C1(a) surgical-change-plus-focused-review pattern from section 6).

---

**One-line verdict (original dispatch): GO-CONDITIONAL.** The token-durability fix (ADR-054 amendment) is code-review
APPROVED and sound to LIVE-test, but a current-docs sweep found a stale design premise that will very
likely fail this run as-is: **an Azure Databricks workspace delete no longer self-cleans its managed
resource group** (retention is now the default; force deletion is required). Condition **C1** below must
be closed before dispatch, or this run reproduces a red Phase 3 on the Databricks managed RG. All other
mechanics clear.

---

## 0. What is being re-dispatched, and why pre-clearance applies

This is the FIRST LIVE test of the OIDC token-durability fix (ADR-054 amendment). The code review that
approved it was **STATIC ONLY** - three runtime classes could not be proven statically and are proven
only by this dispatch (section 3). Two additional mechanisms in this dispatch have ALSO never executed
live in this estate: the `remove_mg_hierarchy=true` MG-teardown path (last run died on the token before
step 4 ever effectively ran) and the Databricks managed-RG cascade (section 2.3). Treat this as a
live-test dispatch with loud fail bars, not a routine re-run.

Remnants to clear (from run 29712487341 Phase 3 VERIFY, the 03:44 snapshot - see the staleness warning
in section 1):
- RG `rg-amba-monitoring-001` (management sub).
- RG `rg-bank-data-p1-workload-globaris-poc` and RG `rg-bank-data-p1-dbx-managed-globaris-poc`
  (landingzones sub) - the second is the Databricks-managed RG.
- 1 Databricks workspace `dbw-bank-data-p1-globaris-poc` (landingzones sub).
- The full 12-MG hierarchy (globaris + platform + landingzones + decommissioned + sandbox + connectivity
  + identity + management + security + corp + online), all still live.
- MG-scope policy assignments were already cleared by Phase 0 DISARM last run; DISARM re-runs
  idempotently this run and re-certifies each scope (or fails loud if a dead token prevents certifying).

---

## 1. Live-state confirmation the OPERATOR runs BEFORE dispatch (do not trust the 03:44 snapshot)

The remnant list above is from a snapshot taken hours ago; the Databricks managed RG in particular may
have partially converted or self-progressed. Dispatch against ground truth. Run these READ-ONLY checks
(operator's own credentials, subs referenced abstractly - fill in the real IDs from the portal / az):

| # | Check | Command (fill in sub IDs) | Expected |
|---|-------|---------------------------|----------|
| L-1 | Databricks workspace still present | `az databricks workspace list --subscription <landingzones> -o table` | 1 workspace (`dbw-bank-data-p1-*`), OR already gone |
| L-2 | Workload + managed RGs present, and managed-RG STATE | `az group list --subscription <landingzones> --query "[?contains(name,'globaris')].name" -o tsv` and, if the managed RG is present, `az group show -n rg-bank-data-p1-dbx-managed-globaris-poc --subscription <landingzones> --query "managedBy"` | note whether the managed RG still shows `managedBy` a Databricks workspace (still a managed RG, deny-assignment live) vs is now a plain RG (converted - see 2.3) |
| L-3 | AMBA RG present | `az group list --subscription <management> --query "[?contains(name,'amba-monitoring')].name" -o tsv` | `rg-amba-monitoring-001`, OR already gone |
| L-4 | MG tree still live | `az account management-group list -o table` | the globaris tree present (confirm count) |
| L-5 | Policy assignments still 0 (spot-check a few scopes) | `az policy assignment list --scope /providers/Microsoft.Management/managementGroups/<globaris|landingzones|management> --query "length(@)" -o tsv` (prefix `MSYS_NO_PATHCONV=1` on Windows Git Bash) | `0` at each - confirms DISARM's prior clear held |
| L-6 | Soft-deleted KV inventory (redeploy-recover note, not a blocker) | `az keyvault list-deleted --subscription <security> --query "[].[name,properties.purgeProtectionEnabled]" -o tsv` | `kv-sec-globaris-*` listed with `true` (purge-protected) |

If L-1/L-2/L-3/L-4 show fewer remnants than expected (partial self-progress), that is fine - the sweep is
idempotent. If they show MORE (something re-remediated), STOP and re-diagnose before dispatch: it would
mean DINE is still armed (a DISARM regression), which is a different failure class.

---

## 2. Known-issues / tenant-prereq sweep for THIS dispatch

### 2.1 OIDC id-token reaches the az-sweep job - CONFIRMED

`teardown.yml` sets `permissions: id-token: write` at WORKFLOW level (top of file), and the `az-sweep`
job does not override `permissions`, so it inherits the grant. GitHub therefore injects
`ACTIONS_ID_TOKEN_REQUEST_URL` / `ACTIONS_ID_TOKEN_REQUEST_TOKEN` into the job, which is exactly what
`az_relogin` needs. Strong PASS-predictor: the job-start `azure/login@v2` step ALSO consumes an id-token,
so if that step succeeds the id-token machinery is present in the job. `az_relogin` additionally guards
this itself - if the two env vars are missing it prints `::error::az_relogin: ... missing 'permissions:
id-token: write'` and returns non-zero (fail loud), never a silent skip.

Federation-subject note (correctness): the az-sweep job runs in the `production-destroy` GitHub
Environment, which is the only federated-credential trust configured for this class of op. A fresh
assertion minted by `az_relogin` inside the job carries the SAME subject claim
(`...:environment:production-destroy`) and the SAME audience (`api://AzureADTokenExchange`) as the
job-start login, so it matches the same federated credential. If job-start `azure/login` works, the
re-login targets an identical, already-proven trust.

### 2.2 AZURE_CLIENT_ID / TENANT_ID / SUBSCRIPTION_ID wiring - CONFIRMED

The az-sweep step exports `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` from
`vars.*` (repo Variables), plus the 5 `*_SUBSCRIPTION_ID` secrets and `REMOVE_MG_HIERARCHY`. `az_relogin`
also fails loud if any of the three Variables are empty. These three Variables are already in use by
every `azure/login` step in the repo, so they are present. No client secret is passed (identity via
Variables + federation only) - correct per secrets hygiene.

### 2.3 Databricks workspace-delete cascade - STALE PREMISE, this run's top risk (verified against current MS docs, dated 2026-07-08)

The design (ADR-054 F2, teardown-redesign section 6) assumes: delete the WORKSPACE and the managed RG
self-cleans. **Current Microsoft docs contradict this.** Per the Delete-a-workspace doc (ms.date
2026-07-08):

- "When you delete an Azure Databricks workspace, most compute resources such as VMs and disks are
  automatically cleaned up. **However, the DBFS storage account and access connector in the managed
  resource group are retained unless you force delete them.**"
- For a Unity-Catalog-enabled workspace (UC is on by default for recently created workspaces):
  "Azure Databricks **converts the managed resource group into a regular resource group**, and the
  storage container ... is retained alongside the access connector in that resource group."
- The documented way to get full cleanup is `az databricks workspace delete --force-deletion ...` (flag
  confirmed present in the current CLI), or `az group delete ... --force-deletion-types
  Microsoft.Databricks/workspaces`.

**Consequence as-is (teardown-az-sweep.sh step 1 uses `az databricks workspace delete --yes --no-wait`
WITHOUT `--force-deletion`):** the workspace delete leaves `rg-bank-data-p1-dbx-managed-globaris-poc`
behind (converted to a regular RG, retaining the storage account + access connector). Step 2 EXCLUDES
that RG from the naming-pattern sweep (it was captured as a managed RG in step 1), so nothing deletes it
this run. Step 5 reconcile then burns the full 30-min ceiling waiting for an RG that will not disappear,
and **Phase 3 VERIFY fails loud on it** (it matches the `contains(name,'globaris')` pattern). Result: a
red run - and, because this is a stale-premise design gap rather than a transient straggler, a plain
re-dispatch of the SAME script would repeat it (see 2.3.1). This is exactly the kind of "clean fail"
that counts against the 4-failure bar, so it must be closed BEFORE dispatch - condition **C1**.

#### 2.3.1 Why re-dispatch alone is not a reliable fix here

On a second dispatch the workspace would already be gone, so step 1 would not re-capture the managed RG,
step 2 would then NOT exclude it and WOULD attempt a plain `az group delete`. That MIGHT succeed IF the
conversion to a regular RG has dropped the RP deny-assignment - but that is unverified for this estate
and is precisely the kind of "hope the second run catches it" behaviour the zero-manual, single-dispatch
acceptance bar (and the 4-fail bar) forbid us to rely on. Close it deterministically instead.

#### C1 (MANDATORY before dispatch) - close the Databricks managed-RG retention gap. Pick one:

- **C1(a) - preferred, durable, zero-manual (DevSecOps + focused re-review):** add `--force-deletion` to
  the `az databricks workspace delete` call in `scripts/teardown-az-sweep.sh` step 1. In a teardown this
  is exactly the intended behaviour (all workspace-catalog data is being destroyed anyway). Confirm the
  CLI accepts `--force-deletion` together with `--no-wait`; if it rejects the pair, drop `--no-wait` for
  THIS single call only (one workspace submission is short enough - the ~55-min blocker that caused the
  original incident was the in-session poll, which is unaffected). This is a surgical change to code that
  was just approved, so it needs one focused re-review, not a full cycle.
- **C1(b) - interim if there is no time for a code change before the needed dispatch (operator-manual,
  breaks zero-manual for one command):** BEFORE dispatch, run
  `az databricks workspace delete --force-deletion --yes --name dbw-bank-data-p1-globaris-poc
  --resource-group rg-bank-data-p1-workload-globaris-poc --subscription <landingzones>` and let the
  managed RG empty/delete. Then dispatch: step 1 finds no workspace, and step 2 + reconcile handle any
  residual RGs by naming pattern.

C1(a) is the right long-term fix (it also protects Wednesday's redeploy teardown and any future
Databricks root). Record whichever is used.

### 2.4 Key Vault purge-protection - NOT a teardown blocker (redeploy-recover)

`kv-sec-globaris-*` are purge-protected (confirmed last VERIFY). Teardown soft-deletes them; they cannot
be purged until retention expires. This is a redeploy concern, not a teardown STOP. teardown-az-sweep.sh
step 3 records purge-protected vaults for the recover path; VERIFY 5 lists them informationally (a
soft-deleted, purge-protected KV is NOT counted as a remnant). Wednesday's redeploy of `platform/security`
must set `recover_soft_deleted_key_vaults=true` (LESSON 56) or use fresh names. No action this run beyond
capturing the VERIFY 5 list.

### 2.5 MG-delete preconditions (remove_mg_hierarchy=true) - first live test, watch-item

The hard, documented preconditions for `az account management-group delete` are: **no child MGs and no
subscriptions** under the MG. teardown-az-sweep.sh step 4 satisfies both - it walks `MG_DELETE_ORDER`
bottom-up (every leaf before its parent) and re-parents each MG's subscriptions to the tenant root before
deleting the MG. Policy ASSIGNMENTS and the DINE identity ROLE ASSIGNMENTS are cleared by Phase 0 DISARM.

Watch-item (MEDIUM): in `mode=az-sweep`, Phase 1 terraform is skipped, so custom policy DEFINITIONS /
policySet (initiative) DEFINITIONS / any custom role DEFINITIONS defined AT MG scopes are NOT removed by
terraform this run. If MG delete additionally rejects an MG that still holds definitions, step 4 exits 1
LOUD on that MG (the script fails loud on every MG op error - it does not warn-and-continue), which is a
clean, diagnosable STOP, not a silent pass. Recovery if hit: delete the residual definitions at that MG
scope (`az policy definition delete` / `az policy set-definition delete` / `az role definition delete`
`--management-group <mg>`) then re-dispatch. Because MG teardown has never run live in this estate, treat
step 4 as a first-live-test alongside the token fix (section 3).

Subscription safety is preserved: subs are only re-parented to the tenant root, never deleted (design
section 5) - Wednesday's fresh `management-groups` apply re-places them.

---

## 3. The reviewer's static-only caveat - three runtime classes, with PASS/STOP bars

The review proved the code STATICALLY. These three classes are proven only by THIS live dispatch. Each
has an explicit PASS bar and STOP bar.

### 3.a Does `az_relogin` actually prevent AADSTS700024 across the ~10-20 min (or force-deletion, longer) Databricks managed-RG cascade?

- **PASS:** Phase 2 log shows NO `AADSTS700024` / "valid time range" / "not within" anywhere; the
  reconcile loop (`wait_for_rgs_gone`) logs successive iterations each beginning with a successful
  `az_relogin`, and the submitted RGs progressively report gone. The single access token never has to
  survive longer than one submission or one poll iteration.
- **STOP (true failure - counts against the 4-fail bar):** any `::error::` from `az_relogin` (failed
  re-login) or an `is_auth_error`-classified failure at any step - the script exits non-zero and the run
  goes red on an AUTH class. This means the durability mechanism itself did not hold; do NOT blind
  re-dispatch. Capture the exact failing call and stderr and issue a single consolidated fix-spec
  (LESSON 59) before any further attempt.

### 3.b Does the 30-min reconcile ceiling behave under real deletion latency?

- **PASS:** `wait_for_rgs_gone` returns 0 ("all RG(s) confirmed gone") within the ceiling, and Phase 3 is
  green. Acceptable-PASS variant: it returns 1 ("still present after the 1800s ceiling") for a genuinely
  still-deleting RG and Phase 3 flags ONLY that RG - this is a STRAGGLER, handled by an idempotent
  re-dispatch (section 4), NOT a failure. NOTE: per C1, the Databricks managed RG must NOT be allowed to
  masquerade as this straggler - with C1 applied it will actually delete; without C1 it will sit at the
  ceiling forever and that is a design fail, not a straggler.
- **STOP (true failure):** `wait_for_rgs_gone` returns 2 - a re-login failed or an existence check came
  back auth-classified MID-wait. The script exits 1 loud. This is the 3.a auth class surfacing inside the
  wait; same disposition - diagnose, do not blind re-dispatch.

### 3.c Does a fresh OIDC assertion mint correctly inside the running job?

- **PASS:** the first `az_relogin` call (first reconcile iteration, or first mid-job re-auth) completes
  the curl id-token request + `az login --federated-token` + `az account set` round-trip with return 0,
  and az calls after it succeed. This proves `ACTIONS_ID_TOKEN_REQUEST_*` availability and the
  mint-and-exchange path end to end.
- **STOP (config failure - do NOT re-dispatch until fixed):** `az_relogin` prints
  `::error::az_relogin: ACTIONS_ID_TOKEN_REQUEST_URL / ... not set` (id-token permission not reaching the
  job) or `... AZURE_CLIENT_ID / ... not set` (Variables not wired). These are deterministic config
  faults, not transient - a re-dispatch reproduces them exactly. Fix the workflow permission / repo
  Variable first.

---

## 4. Consolidated PASS / STOP bars and the idempotent re-dispatch contract

### 4.1 The run PASSED (teardown complete E2E) when:

- Phase 0 DISARM exits 0 ("all MG-scope policy assignments cleared") - or legitimately reports each scope
  already clean - with NO auth-classified fail.
- Phase 2 AZ SWEEP submits every delete, the reconcile loop confirms the submitted RGs gone (or a genuine
  straggler per 4.3), and the MG hierarchy step deletes all 12 MGs bottom-up.
- **Phase 3 VERIFY is GREEN** ("VERIFY PASSED - zero estate remnants"): 0 MG-scope policy assignments,
  0 `*globaris*` / `*amba-monitoring*` RGs in all 5 subs, 0 Databricks workspaces, the full MG tree gone
  (remove_mg_hierarchy=true), the 5 subs re-parented under the tenant root, and the soft-deleted
  purge-protected KVs listed informationally.

A GREEN Phase 3 IS the definition of success. It cannot be faked by a dead token - VERIFY fails loud on
any auth-classified list call (it never reads a dead token as "0 / clean / gone").

### 4.2 STOP - do NOT retry, escalate/diagnose first (a THIRD clean fail is serious):

- ANY auth class: `az_relogin` `::error::`, any `is_auth_error` hit, `wait_for_rgs_gone` return 2, or a
  VERIFY `::error::` naming an auth/transport failure. The durability fix did not hold - this is the
  central hypothesis under test and a failure here must be fully diagnosed, not re-run.
- Config faults from 3.c (id-token permission / Variables not reaching the job).
- The Databricks managed RG standing at the reconcile ceiling WITHOUT C1 applied (2.3) - a design gap, not
  a straggler; re-dispatching the unfixed script will not fix it.
- A DISARM regression (L-5 shows assignments re-appearing / DINE re-remediating) - a different failure
  class that means resources may resurrect mid-sweep.

The user's hard bar: 4 straight failures moves the project off Claude Code. This teardown has already
failed twice on the redesigned workflow. This dispatch is attempt 3. Do not spend attempts 3 AND 4 on the
same undiagnosed cause - each retry must NARROW the failure class (LESSON 59). If attempt 3 fails on an
auth class, diagnose to root cause and issue ONE consolidated fix before attempt 4.

### 4.3 Idempotent re-dispatch contract (a straggler is NOT a failure):

If Phase 3 flags ONLY a genuinely still-deleting resource - a slow RG delete that exceeded the 30-min
ceiling (return 1 from the reconcile), with NO auth-classified error anywhere in the run - that is a
STRAGGLER, expected behaviour, and the documented remedy is a plain idempotent RE-DISPATCH of the same
workflow (same inputs). This does NOT count as one of the failures against the 4-fail bar. Distinguish it
from 4.2 by this test: **was there any auth/token/transport error, config fault, or a resource that
CANNOT progress on its own (the C1 Databricks case)?** If no to all, it is a straggler - re-dispatch. If
yes to any, it is a real failure - STOP and diagnose.

---

## 5. Verdict and conditions

### Verdict: GO-CONDITIONAL

The token-durability fix is APPROVED and sound to live-test, the DISARM/RG-sweep/KV/MG mechanics are
correct, the OIDC id-token and Variables reach the job, and Phase 3 is a trustworthy loud gate. Dispatch
is cleared to proceed once the conditions below are met.

**Conditions (all must hold at dispatch time):**

1. **C1 (MANDATORY) - close the Databricks managed-RG retention gap** (section 2.3): apply C1(a) (add
   `--force-deletion`, preferred, needs a focused re-review) OR C1(b) (operator force-deletes the
   workspace manually before dispatch). Without this, Phase 3 fails on
   `rg-bank-data-p1-dbx-managed-globaris-poc` and re-dispatch does not reliably fix it.
2. **C2 (MANDATORY) - run the section 1 live-state confirmation** (L-1..L-6) so dispatch runs against
   ground truth, not the 03:44 snapshot. If remnants have GROWN, STOP (possible DISARM regression).
3. **C3 (CONFIRM) - the three repo Variables** `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
   `AZURE_SUBSCRIPTION_ID` are set (they are, since every `azure/login` uses them) - this is the
   deterministic guard behind 3.c.
4. **C4 (ACKNOWLEDGE) - three first-live-test surfaces** carry non-zero runtime risk: the token
   durability (3.a-3.c), the MG-hierarchy delete path (2.5), and the Databricks cascade (2.3, mitigated
   by C1). Watch the Phase 2 log live for the first `az_relogin` round-trip and the first MG delete.

**Dispatch inputs when cleared:** `target=all`, `mode=az-sweep`, `confirm=destroy`,
`remove_mg_hierarchy=true`, `include_bootstrap=false`.

---

## 6. Hand-off

- **C1(a)** (add `--force-deletion` to teardown-az-sweep.sh step 1, confirm `--force-deletion --no-wait`
  compatibility) is a **DevSecOps** change plus a **focused code-review** re-approval. This is the one
  code change that turns this from a likely third red run into a clean E2E. Recommend it be done before
  dispatch.
- If there is no time for C1(a), **C1(b)** (manual `--force-deletion` workspace delete before dispatch)
  is the **operator** interim - acceptable for this run, but log it as a manual step and still land
  C1(a) before Wednesday's redeploy teardown.
- **C2** live-state checks and the dispatch itself are the **operator** lane.
- The MG-definition residual watch-item (2.5) and any auth-class STOP (4.2) route back to the
  **Architect** for a consolidated disposition before any attempt 4.

Pick up next: **DevSecOps** for C1(a) + the focused re-review, then the **operator** to run C2 and
dispatch. Report the Phase 3 result and the first `az_relogin` outcome back to the Architect.
