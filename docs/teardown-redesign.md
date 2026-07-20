# Reliable end-to-end teardown - redesign fix-spec (zero manual deletion)

> **Status:** DESIGN + fix-spec for DevSecOps to implement. User hard requirement (2026-07-19):
> teardown MUST be a reliable end-to-end CI/CD process with ZERO manual deletion. Today's teardown
> failed E2E and forced manual work. Wednesday needs a working teardown.
> **Owner:** Cloud Solutions Architect. Decision: ADR-054. Implementer: DevSecOps.
> **No Terraform/workflow written here - this is the contract.**
>
> **AMENDED 2026-07-20** (teardown run 29712487341): the four-phase shape below is unchanged and
> correct, but Phase 2 failed silently on an OIDC token-lifetime edge - see **section 9** (locked
> rulings on token durability, async-delete / verify reconciliation, and auth-fail-loud) and
> **section 10** (the exact DevSecOps fix-spec per script). Read sections 9 and 10 as overriding
> the Phase 2 mechanics wherever they differ from section 3.

---

## 1. Root-cause diagnosis (what failed today)

| # | Failure | Root cause |
|---|---|---|
| F1 | **Workflow destroyed NOTHING** | `needs: [..., synthetic]` on every spoke + `if: ${{ !failure() ... }}`. `synthetic` is a real root (synthetic/*.tf define real resources - RGs, red-team ACA jobs, cost-pattern VM/storage - gated behind `var.enable_synthetic_workload`, currently false), so its destroy against empty/absent state FAILED, which put the run into `failure()` state, so `!failure()` evaluated FALSE on EVERY downstream job -> all skipped. One empty-state root cascade-skipped the entire teardown. Fix note (reviewer BLOCK, 2026-07-19): the original fix-spec below said to DELETE the `synthetic` job - that was corrected to HARDEN it instead (same `!cancelled()` + state-empty resilience fix as every other root), since `synthetic` is a real root that must retire its own Terraform state via a real destroy, not just have its RGs caught by the naming-pattern az-sweep (which would leave state drifted). |
| F2 | terraform-destroy alone can't finish some resources | Databricks MANAGED RG carries an RP deny-assignment (cannot `az group delete` directly - must delete the WORKSPACE, and per the 2026-07-20 amendment that delete must pass `--force-deletion` to cascade the managed RG - a plain delete now RETAINS it); APIM/AKS are slow deletes; KV purge-protection blocks re-create by name. |
| F3 | **Policy layer keeps RE-REMEDIATING** | MG-scope DINE policy ASSIGNMENTS (base ALZ Deploy-* + the 223 AMBA objects) stay live during resource deletion and RE-CREATE resources (rg-amba-monitoring-001 was re-remediated). Resource deletion races live remediation and loses. |
| F4 | terraform-destroy can no longer help | State was cleaned to EMPTY (for a fresh redeploy), so `terraform destroy` sees nothing and cannot finish the CURRENT half-destroyed estate. No fallback existed. |

---

## 2. Design principles (ADR-054)

1. **No empty/undeployed root may ever fail-and-cascade.** Ordering `needs` is for correctness
   (reverse-dependency), NOT for gating continuation. A predecessor that no-ops or fails must not
   skip successors.
2. **Disarm the policy layer FIRST.** Remove all MG-scope policy ASSIGNMENTS before (and
   independent of) resource deletion, so DINE remediation stops and nothing re-creates mid-sweep.
3. **Two modes, one workflow:** terraform-destroy PRIMARY (state intact) + an `az` SWEEP FALLBACK
   (state empty/gone). DISARM and VERIFY run in BOTH modes.
4. **Idempotent + resilient:** every step succeeds whether its target exists or not (deleting an
   absent thing = success). This is what makes E2E reliable.
5. **Loud completion verification:** the run FAILS if any remnant remains - never a silent
   half-teardown.

---

## 3. THE WORKFLOW (four phases; DevSecOps implements)

New inputs on `teardown.yml`: `confirm` (unchanged, must equal `destroy`), `mode` (choice:
`terraform` = state intact / primary; `az-sweep` = state gone / fallback; default `terraform`),
`include_bootstrap` (unchanged), `remove_mg_hierarchy` (bool, **default false** - section 5;
implemented as false rather than true, a deliberate safety call: a checked-in default that
silently deletes the whole MG tree on a plain dispatch is too much blast radius for a default -
the runbook passes `remove_mg_hierarchy=true` explicitly at dispatch time for a full-estate
teardown).

**Guard:** `mode=az-sweep` requires `target=all`. Phase 0/2/3 only run for `target=all` and
Phase 1 only runs for `mode=terraform`, so `mode=az-sweep` with a single-root `target` would run
NOTHING and still report green - the guard job rejects this combination before any login
(reviewer BLOCK, 2026-07-19).

### Phase 0 - DISARM (az, runs ALWAYS, first, both modes)

A single job after `guard`, `az`-based (works with or without state):
- Enumerate every MG scope: `globaris` root + all descendants (platform, landingzones,
  decommissioned, sandbox + children connectivity/identity/management/security/corp/online).
- For each scope: `az policy assignment list --scope <mg> --query [].name` then
  `az policy assignment delete --name <n> --scope <mg>` for ALL assignments (base ALZ + the 223
  AMBA). Idempotent (already-gone = no-op).
- Also delete the AMBA remediation identity's role assignments if present (belt: stops any
  in-flight remediation from having rights). The identity itself dies with rg-amba-monitoring-001.
- Result: DINE is disarmed - nothing re-remediates during Phases 1-2. This directly fixes F3 and
  is the SINGLE most important reordering.

### Phase 1 - DESTROY (terraform primary; skipped when mode=az-sweep)

Reverse-dependency-order terraform-destroy per root (INCLUDING `synthetic`), with the F1 fix:
- **`needs` for ORDERING only; `if: ${{ !cancelled() && (mode == 'terraform') && (target == 'all' || target == '<root>') }}`** - NOTE: `!cancelled()` NOT `!failure()`, so a failed/no-op predecessor does NOT skip successors.
- **`synthetic` stays a real Phase-1 job, hardened not deleted** (reviewer BLOCK correction,
  2026-07-19): `synthetic/*.tf` define real resources (RGs, red-team ACA jobs, cost-pattern
  VM/storage) gated behind `var.enable_synthetic_workload` (currently false) - it is a real
  root, not a placeholder. The original diagnosis correctly identified that a never-deployed
  root's failed destroy must not cascade-skip the run (F1), but the fix is the resilience fix
  below (same `!cancelled()` + state-empty no-op as every other root), NOT removing the job -
  deleting it would mean a future populated `synthetic` root (flag flipped true and applied)
  never gets a real `terraform destroy`, leaving its Terraform state drifted against whatever
  the Phase-2 naming-pattern az-sweep catches out-of-band. `synthetic` destroys FIRST (before
  the 5 spokes), mirroring `deploy.yml`, which applies it LAST.
- **`_tf-root.yml` destroy resilience (the core F1 fix):** a pre-step runs `terraform init` then
  `terraform state list`; if it errors (no state) or returns empty, echo "no state - nothing to
  destroy" and EXIT 0 (skip `terraform destroy`). An empty root can then NEVER fail. Applies to
  every root, so a partially-deployed estate (including an inert `synthetic`) tears down cleanly.
- Order (reverse of deploy): synthetic -> spokes (corp-a1/a2, online-p1, bank-app-p1,
  bank-data-p1) -> {connectivity, security} -> identity -> management -> management-groups.
  management-groups LAST (its assignments are already gone from Phase 0; terraform destroy now
  removes the policy DEFS + MG hierarchy from state cleanly, or the `remove_mg_hierarchy` az step
  does it in Phase 2).
- **F2 handling inside terraform-destroy:**
  - Databricks: `terraform destroy` deletes the WORKSPACE resource (the deny-assignment blocks
    direct RG delete but not workspace-triggered cleanup). NOTE the 2026-07-20 amendment: a plain
    workspace delete no longer self-cleans the managed RG - so if the terraform provider destroy
    leaves the managed RG behind, the Phase 2 az-sweep remnant-catch (with `--force-deletion`,
    section 6 / 10.3) and Phase 3 VERIFY are the backstop that finish and confirm it.
  - APIM: the root provider `features { api_management { purge_soft_delete_on_destroy = true,
    recover_soft_deleted = ... } }` (already added at B4/ADR-047) purges on destroy. Confirm
    present; adequate timeout (the 360-min CI ceiling covers APIM/AKS slow deletes).
  - KV: `features { key_vault { purge_soft_deleted_..._on_destroy } }` - soft-delete on destroy;
    purge-protected KVs cannot be purged until retention expires (section 6).

### Phase 2 - AZ SWEEP (fallback for state-gone; ALSO a remnant-cleanup pass after Phase 1)

Runs when `mode == az-sweep` (state gone), AND as a remnant-catch after Phase 1 in `terraform`
mode. `az`-based, idempotent:
- Delete any remaining workload/orphaned resource groups by naming pattern (rg-bank-*, rg-corp-*,
  rg-online-*, rg-connectivity-*, rg-identity-*, rg-*-monitoring-*, **rg-amba-monitoring-001**,
  etc.) across the workload/platform subs: `az group list` filter -> `az group delete --yes
  --no-wait` then a wait-loop.
- Databricks (state-gone case): `az databricks workspace delete --force-deletion` on any surviving
  workspace (the `--force-deletion` flag is what cascades the managed RG - see the 2026-07-20
  amendment / section 6: a plain delete now RETAINS it); then verify the managed RGs are gone (the
  reconcile loop waits, Phase 3 VERIFY confirms).
- KV: `az keyvault list` -> `az keyvault delete`; `az keyvault purge` for NON-purge-protected;
  purge-protected recorded for the redeploy recover path (section 6).
- **MG hierarchy removal (if `remove_mg_hierarchy` - section 5):** bottom-up - for each leaf MG,
  `az account management-group subscription remove` to move its subs to the tenant root, then
  `az account management-group delete` the now-empty MG; repeat up the tree to `globaris`. Subs are
  preserved (moved to tenant root), only the MG containers are deleted.

### Phase 3 - VERIFY (az, runs ALWAYS, last, both modes) - FAIL LOUDLY on any remnant

Assert zero remnants; the job FAILS (non-zero) if any check finds something:
- No MG-scope policy assignments remain (all scopes enumerated in Phase 0 return empty).
- No workload/platform/orphaned RGs remain (the Phase-2 patterns return empty), incl.
  rg-amba-monitoring-001.
- Databricks managed RGs gone.
- If `remove_mg_hierarchy`: the globaris MG tree is gone (only tenant root remains) and the reused
  subs sit under the tenant root.
- KVs soft-deleted (list soft-deleted vaults for the redeploy recover note).
A green Phase 3 is the definition of "teardown succeeded E2E." No manual step is ever required for
the default (non-bootstrap) scope.

---

## 4. The empty-state no-cascade fix (F1) - explicit

The single highest-value change, stated precisely for the implementer (corrected 2026-07-19 -
reviewer BLOCK: `synthetic` is a real root and stays in the graph, hardened not removed):
1. Change every root job `if:` from `!failure()` to `!cancelled()` (predecessor failure must not
   skip successors; `needs` still enforces ordering). This applies to EVERY root, including
   `synthetic` - it is NOT deleted from the graph.
2. Add the `_tf-root.yml` destroy pre-step: `terraform state list` empty/error -> exit 0 skip.
   This is what makes a currently-inert `synthetic` (or any other undeployed/emptied root) safe
   to keep in the graph - its destroy simply no-ops instead of failing.
3. `needs` is for ordering only, never for gating on a predecessor's success (see the
   `disarm`-is-a-genuine-prerequisite exception in `teardown.yml`, which IS gated on success -
   that is a real causal dependency, not the F1 anti-pattern).
Any one of these alone helps; all three together make an empty/partial estate (including an
undeployed `synthetic`) tear down reliably without needing to remove any root from the graph.

---

## 5. RULING - MG hierarchy for the Wednesday redeploy: FULL TEARDOWN

The subs are REUSED Wednesday; a fresh `management-groups` apply runs against EMPTY state.

**Ruled: FULL MG-hierarchy teardown** - dispatch Phase 2 with `remove_mg_hierarchy=true`
explicitly (the input DEFAULTS to false in the workflow - a safety call, section 3 - so this run
needs the override set at dispatch time), because a fresh avm-ptn-alz apply against empty state
will try to CREATE the MG tree + sub placements + policy objects, and a LIVE hierarchy causes
"already exists" collisions on MGs/assignments (empty state has no record to reconcile against).
Removing the hierarchy (subs moved to tenant root, MGs deleted bottom-up) lets Wednesday's apply
build the tree from nothing - clean and collision-free.

- **Rejected - `terraform import`** the live hierarchy into fresh state before apply: importing a
  full ALZ tree (11 MGs + placements + hundreds of policy defs/assignments) is heavy, fragile, and
  slow - the wrong tool for a routine redeploy.
- **Rejected - idempotent reconcile** (apply avm-ptn-alz over the live hierarchy with empty state):
  the alz provider does not adopt pre-existing MGs into empty state; it collides on create.
- Sub safety: moving subs to the tenant root MG is non-destructive (subs + their resources are
  untouched; only the MG container membership changes). Wednesday's apply re-places them.

The MG hierarchy removal is the LAST teardown step (after all resources + policy assignments gone),
so nothing references the MGs when they are deleted.

---

## 6. Databricks / KV / APIM handling (F2) - consolidated

- **Databricks managed RG:** never `az group delete` it directly (RP deny-assignment). Delete the
  WORKSPACE (terraform destroy, or `az databricks workspace delete`). CORRECTION (2026-07-20, from
  the re-dispatch pre-clearance C1): a plain workspace delete NO LONGER self-cleans the managed RG.
  Per the current Microsoft "Delete a workspace" doc (ms.date 2026-07-08) the managed RG - plus its
  DBFS storage account and access connector - is RETAINED unless the delete passes `--force-deletion`,
  and for a Unity-Catalog-enabled workspace Azure converts the managed RG into a regular RG and keeps
  its contents. So the az-sweep path (section 10.3 step 1) MUST use `az databricks workspace delete
  --force-deletion` to cascade the managed RG; Phase 3 VERIFY then confirms it is gone. (Open item:
  DevSecOps is confirming `--force-deletion` combines with `--no-wait`; if it does not, that is a
  submit-vs-wait sequencing ruling back to the architect - the reconcile loop, section 9.3, would
  own the managed-RG wait instead.)
- **KV purge-protection:** teardown soft-deletes KVs; purge-protected ones cannot be purged until
  retention expires. Wednesday's redeploy must RECOVER them (`recover_soft_deleted_key_vaults`
  feature, already used per the B0a caveat) OR use fresh names. Record the soft-deleted vault list
  in Phase 3 so the redeploy knows what to recover. The bootstrap state-backend KV (if any) is
  PRESERVED (out of the default teardown scope).
- **APIM / AKS slow deletes:** provider `features` purge flags (APIM added at B4) + the 360-min CI
  ceiling. No special handling beyond adequate timeout; the resilience pre-step means a slow delete
  that times out can be re-run and continues.

---

## 7. Finishing TODAY's half-destroy (immediate use of the fix)

Current remnants (state already emptied - so `mode=az-sweep`): MG policy assignments (globaris=22,
landingzones=63, + platform/corp/online/etc), rg-amba-monitoring-001 (re-remediated), the 2
Databricks managed RGs (finishing on their own). Run the redesigned workflow with `mode=az-sweep`,
`remove_mg_hierarchy=true`: Phase 0 disarms the assignments (stops the re-remediation loop that
recreated rg-amba-monitoring-001), Phase 2 sweeps the orphaned RGs + removes the MG hierarchy,
Phase 3 verifies zero remnants. No manual deletion.

---

## 8. Acceptance criteria (the user's bar)

- A single `teardown.yml` dispatch (target=all) tears the estate down E2E with ZERO manual steps
  for the default scope, whether state is intact (`terraform`) or gone (`az-sweep`).
- No empty/undeployed root can cascade-skip or fail the run.
- Policy remediation is disarmed before resource deletion (no re-creation races).
- Phase 3 verification is green (loud failure on any remnant).
- Wednesday's fresh redeploy meets a clean slate (no MG-hierarchy collision, KV recover path
  documented).

---

## 9. AMENDMENT 2026-07-20 - Phase 2 silent no-op on OIDC token expiry (run 29712487341)

### 9.1 What failed (facts)

Dispatch: mode=az-sweep, remove_mg_hierarchy=true, on `banking`. Phase 0 DISARM succeeded (VERIFY 1
later confirmed 0 policy assignments at every MG scope). Phase 1 was correctly skipped (az-sweep,
state gone). Phase 3 VERIFY correctly FAILED LOUD on the remnants. But **Phase 2 AZ SWEEP exited 0
having deleted nothing.**

Root cause = OIDC client-assertion expiry mid-job (the deferred OQ-022 class):

- `azure/login`'s GitHub OIDC federated assertion is valid only for GitHub's ~5-minute window
  (this run: 02:34:44 -> 02:39:44). It is a one-time, short-lived credential.
- Phase 2 step 1 ran `az databricks workspace delete` SYNCHRONOUSLY (no `--no-wait`) plus a 600s
  in-session `wait_for_rg_gone` poll. That drove the single job to ~55 minutes.
- When the initial Azure access token expired (~55 min in), az tried to REFRESH it using the
  long-dead 5-minute assertion, so from ~03:29 every az call died with
  `AADSTS700024: Client assertion is not within its valid time range`.
- The workspace delete never even submitted. Nothing downstream ran.

Three swallow-the-error bugs converted that auth death into a silent exit 0:

1. The Databricks workspace delete was synchronous (the ~55-min blocker that outlived the token).
2. `az account management-group show ... 2>/dev/null` returning non-zero on a dead token was
   mis-read as "MG already gone - skipping" for all 12 MGs (a dead-token error is indistinguishable
   from NotFound at that call site).
3. The `|| true`-guarded `az group list` / `az keyvault list` calls, run after the token died,
   returned empty -> the RG and KV sweeps found "nothing" and swept nothing.

Remnants left standing (Phase 3 output): rg-amba-monitoring-001; the bank-data workload RG + its
Databricks managed RG; one Databricks workspace; the full 12-MG hierarchy intact.

### 9.2 LOCKED DECISION 1 - token durability

The fix is a short submission pass PLUS an on-demand re-login primitive; never rely on az's own
token refresh (structurally impossible once the one-time 5-minute assertion is consumed).

- **(a) `--no-wait` submission pass.** Phase 2 fires EVERY delete asynchronously (Databricks
  workspace, RGs, KV) - a submission-only pass that completes well inside one fresh access token. No
  operation long-polls in-session on the token that submitted it. This alone removes the ~55-min
  single-step blocker.
- **(b) `az_relogin` primitive.** A shared shell helper mints a BRAND-NEW GitHub OIDC assertion on
  demand: request a fresh id-token from `$ACTIONS_ID_TOKEN_REQUEST_URL` (bearer
  `$ACTIONS_ID_TOKEN_REQUEST_TOKEN`, audience `api://AzureADTokenExchange`), extract `.value`, then
  `az login --service-principal --username $AZURE_CLIENT_ID --tenant $AZURE_TENANT_ID
  --federated-token <token>`. GitHub serves fresh assertions for the entire job, so this bypasses
  az's broken refresh. If a re-login itself fails, that is a FAIL-LOUD condition (never continue).
- **(c) relogin-then-poll loop.** Any bounded wait calls `az_relogin` at the START of each
  iteration, so a poll can never outlive its token.

Rejected: `azure/login` at job start alone (does not survive a single step longer than the token
lifetime); leaning on az token refresh (the assertion is a consumed one-time credential).

### 9.3 LOCKED DECISION 2 - async-delete vs immediate-verify reconciliation

**The wait lives in Phase 2; VERIFY stays an instant, unwaited truth-gate.**

- After the `--no-wait` submission pass, Phase 2 runs ONE bounded reconciliation loop
  (`az_relogin` each iteration, per 9.2c) that waits for EXACTLY the RGs it submitted for deletion
  plus the Databricks managed RGs to report gone, up to a bounded ceiling of **30 minutes** (far
  under the 360-min job ceiling). MG re-parent + bottom-up MG delete are fast control-plane ops and
  stay in the submission pass - no reconcile wait is needed for MGs.
- Phase 3 VERIFY then asserts remnants=0 IMMEDIATELY, no wait, and fails loud on anything found.
- The idempotent contract still holds as a SAFETY NET for the pathological over-ceiling straggler:
  an operator RE-DISPATCHES the same workflow (safe, idempotent) and it catches the remainder. The
  workflow does NOT auto-retry - auto-retry could wait out / mask a genuinely stuck delete.

Rejected: putting the wait inside VERIFY (muddies the auditor's "truth at this instant" contract and
could silently wait out a stuck delete); an in-workflow auto-retry loop (masks stuck resources,
complicates the graph). Decisive rule: patience belongs to the ACTOR (Phase 2), instant judgment to
the AUDITOR (Phase 3).

### 9.4 LOCKED DECISION 3 - auth-error-must-fail-loud

**No teardown step may ever treat an auth / token / transport failure as "resource absent / already
gone / nothing to do".** Every existence check and list call must DISTINGUISH:

- a genuine NotFound (resource absent) -> idempotent no-op, success; from
- an auth or transport error -> FAIL LOUD (non-zero, `::error::`), NEVER a skip / already-gone /
  empty-so-nothing-to-do branch.

Mechanism (locked): stop blanket-swallowing with `2>/dev/null`. Capture stderr, and classify it with
a shared `is_auth_error` helper matching (case-insensitive) `AADSTS`, `valid time range`,
`not within`, `AuthenticationFailed`, `ExpiredAuthenticationToken`, `token`, `credential`, `401`,
`403`, and `az login` prompts. A failed (non-zero) list call is explicitly distinct from a
successful list that returned zero rows: only the latter is "nothing to sweep." This rule binds ALL
three scripts, VERIFY included - a dead token inside VERIFY would otherwise falsely certify "clean,"
which is the worst possible failure for the truth-gate.

---

## 10. FIX-SPEC FOR DEVSECOPS (exact required behavior - no code here)

Implement per the locked decisions in section 9. Behavioral contract only; DevSecOps writes the
shell / YAML.

### 10.1 `scripts/teardown-common.sh` (shared primitives - new)

- **Add `az_relogin`:** mint a fresh GitHub OIDC id-token from `$ACTIONS_ID_TOKEN_REQUEST_URL`
  (bearer `$ACTIONS_ID_TOKEN_REQUEST_TOKEN`, audience `api://AzureADTokenExchange`), then
  `az login --service-principal --username "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID"
  --federated-token <value>` (add `--subscription "$AZURE_SUBSCRIPTION_ID"` context as needed). On
  any failure (no id-token returned, `az login` non-zero) it must `::error::` and return non-zero -
  callers treat a failed re-login as FAIL LOUD, never continue.
- **Add `is_auth_error "<text>"`:** return 0 (true) when the text matches, case-insensitive, any of
  `AADSTS` / `valid time range` / `not within` / `AuthenticationFailed` /
  `ExpiredAuthenticationToken` / `token` / `credential` / `401` / `403` / `az login`. Used to
  classify captured stderr everywhere the old code swallowed it.
- **Add a `wait_for_rgs_gone` reconcile helper** (or refactor the existing `wait_for_rg_gone`):
  accepts the list of (sub, rg) pairs to wait on; on each iteration FIRST calls `az_relogin`, THEN
  checks each RG with `az group exists`; loops until all are gone or the 30-min ceiling; on ceiling
  it returns non-zero (Phase 3 will then fail loud on the remnant) - never a silent success.

### 10.2 `scripts/teardown-disarm.sh` (Phase 0)

DISARM is short and ran fine on run 29712487341, but it is subject to the SAME swallow bug and MUST
be hardened - the auth-fail-loud rule (section 9.4) binds all three scripts. Its policy-assignment
list is exactly the "empty read mis-interpreted as done" pattern that sank Phase 2.

- **Policy-assignment list calls:** replace the `az policy assignment list --scope ... 2>/dev/null
  || true` pattern (used both for the DINE identity rows and for `assignment_names`) with a
  separate-stderr capture. A non-zero list call that `is_auth_error` (or any non-zero) is FAIL LOUD
  (`::error::`, exit 1) - it must NEVER fall through to the "No policy assignments at scope ...
  (already disarmed, or scope no longer exists)" branch. A dead token read as "already disarmed"
  would leave the MG-scope DINE assignments live and re-open the F3 resurrection loop that this
  whole redesign exists to close, while the run reports green.
- **Role-assignment list / delete (`az role assignment list` / `delete`):** same treatment -
  distinguish a genuine absent/NotFound (idempotent no-op) from an auth-classified failure (fail
  loud). Only a successful zero-row list means "no role assignment to remove."
- The existing `fail=1`-on-real-delete-failure logic stays; this adds the missing coverage on the
  LIST side (a failed list currently produces an empty array read as "already disarmed").
- DISARM stays a short job with a single job-start `azure/login`; no `az_relogin` loop is needed
  here (it does not long-poll), but it MUST import `is_auth_error` from teardown-common.sh (10.1).

### 10.3 `scripts/teardown-az-sweep.sh` (Phase 2)

- **Step 1 Databricks:** the workspace delete MUST pass `--force-deletion` - a plain delete no
  longer self-cleans the managed RG (section 6 / amendment point 10; MS "Delete a workspace" doc,
  ms.date 2026-07-08). Intended invocation: `az databricks workspace delete --force-deletion
  --no-wait`. Do NOT `wait_for_rg_gone` in-line here (the managed RG is reconciled in the final
  wait step). Capture each workspace's managed-RG name into a list for the reconcile step. Capture
  stderr on the `az databricks workspace list` call and on the delete: an auth-classified error is
  FAIL LOUD, not "already gone." COMPATIBILITY CHECK (being confirmed by DevSecOps before merge):
  that `--force-deletion` and `--no-wait` combine on `az databricks workspace delete`. If they do
  NOT combine, STOP and route back to the architect for a submit-vs-wait sequencing ruling - do not
  silently drop either flag: a synchronous `--force-deletion` (no `--no-wait`) reintroduces the
  long in-session poll the token-durability ruling (9.2) exists to remove, so the ruling would be to
  force-delete asynchronously another way or let the reconcile loop (9.3) own the managed-RG wait.
- **Step 2 RG sweep:** already `--no-wait` for the delete - keep that, but (i) EXCLUDE the
  managed-RG names captured in step 1 from direct deletion (they cascade from the workspace delete;
  a direct `az group delete` on them is doomed by the RP deny-assignment and is pure noise), and
  (ii) replace the `az group list ... 2>/dev/null || true` pattern: capture exit code + stderr; a
  non-zero list call that `is_auth_error` (or any non-zero list) is FAIL LOUD, NOT an empty list.
  Only a successful zero-row list means "nothing to sweep in this sub."
- **Step 3 Key Vault:** same list-call hardening as step 2 (a failed `az keyvault list` /
  `list-deleted` must not be read as "no vaults"). KV delete can stay as is (fast); keep the
  purge-protected reporting.
- **Step 4 MG hierarchy:** replace the `az account management-group show ... 2>/dev/null` -> "already
  gone - skipping" logic. Capture stderr: only a genuine NotFound means "skip (already gone)"; an
  auth-classified error is FAIL LOUD. Same for `subscription remove` and `management-group delete` -
  a non-idempotent (auth / real) failure must fail loud, not warn-and-continue. MG ops stay
  synchronous (fast); no `--no-wait`, no reconcile wait for MGs.
- **New final step - reconciliation:** after all submissions, call `wait_for_rgs_gone` (10.1) over
  the union of the swept workload/platform RGs and the Databricks managed RGs, re-logging in each
  iteration. Only after this does the script exit. The script's own exit remains advisory (Phase 3
  is authoritative), EXCEPT that any auth-classified failure at any step is a hard non-zero exit.
- **Remove the assumption that a synchronous long delete is acceptable:** no step in this script may
  block in-session for longer than a token lifetime without an intervening `az_relogin`.

### 10.4 `scripts/teardown-verify.sh` (Phase 3)

- VERIFY stays an IMMEDIATE assertion (no waiting - the wait now lives in Phase 2).
- Harden EVERY az call against the swallow bug: the current `2>/dev/null || echo "0"` and
  `2>/dev/null || true` patterns must distinguish a failed call from an empty result. If any
  `az policy assignment list` / `az group list` / `az databricks workspace list` /
  `az account management-group show` / `az keyvault list-deleted` call returns non-zero and
  `is_auth_error` (or any non-zero for the count/list calls), VERIFY must FAIL LOUD - it must NEVER
  interpret a dead token as "0 assignments / clean / gone." A false "clean" from the truth-gate is
  the worst outcome.
- Keep the existing sub-count guard (VERIFY 0). Optionally add a one-shot `az_relogin` at job start
  is unnecessary (the workflow `azure/login` step already provides a fresh token and VERIFY is fast)
  - but the auth-fail-loud hardening above is mandatory.

### 10.5 `.github/workflows/teardown.yml`

- **az-sweep step env:** in addition to the existing `*_SUBSCRIPTION_ID` secrets and
  `REMOVE_MG_HIERARCHY`, export `AZURE_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}`,
  `AZURE_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}`, and `AZURE_SUBSCRIPTION_ID:
  ${{ vars.AZURE_SUBSCRIPTION_ID }}` so `az_relogin` can re-authenticate from inside the script.
  `ACTIONS_ID_TOKEN_REQUEST_URL` / `ACTIONS_ID_TOKEN_REQUEST_TOKEN` are auto-present because the
  workflow already sets `permissions: id-token: write` - do NOT hardcode them.
- The per-phase `azure/login` steps stay (fresh token at each job start). No change to the guard,
  the phase graph, `!cancelled()` gating, mode/target logic, or `remove_mg_hierarchy` default
  (false) - the four-phase shape is correct and unchanged.
- No `--no-wait` or reconcile logic belongs in YAML; it is all inside teardown-az-sweep.sh /
  teardown-common.sh.

### 10.6 Acceptance for the amendment

- A single mode=az-sweep dispatch completes Phase 2 in a submission pass + one bounded reconcile
  wait, never a >55-min single step, and re-authenticates across the wait (no AADSTS700024).
- No step anywhere reports "already gone / clean / nothing to do" off the back of an auth or
  transport error - such an error fails the run loudly.
- Phase 3 VERIFY is green (immediate, unwaited) after a genuinely complete teardown; loud on any
  real remnant; and can itself never certify "clean" on a dead token.
- Re-dispatch (idempotent) finishes any over-ceiling straggler; no manual deletion.
