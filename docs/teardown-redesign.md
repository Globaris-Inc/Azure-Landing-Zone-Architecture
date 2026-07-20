# Reliable end-to-end teardown - redesign fix-spec (zero manual deletion)

> **Status:** DESIGN + fix-spec for DevSecOps to implement. User hard requirement (2026-07-19):
> teardown MUST be a reliable end-to-end CI/CD process with ZERO manual deletion. Today's teardown
> failed E2E and forced manual work. Wednesday needs a working teardown.
> **Owner:** Cloud Solutions Architect. Decision: ADR-054. Implementer: DevSecOps.
> **No Terraform/workflow written here - this is the contract.**

---

## 1. Root-cause diagnosis (what failed today)

| # | Failure | Root cause |
|---|---|---|
| F1 | **Workflow destroyed NOTHING** | `needs: [..., synthetic]` on every spoke + `if: ${{ !failure() ... }}`. The never-deployed `synthetic` root's destroy FAILED (empty/absent state), which put the run into `failure()` state, so `!failure()` evaluated FALSE on EVERY downstream job -> all skipped. One empty root cascade-skipped the entire teardown. |
| F2 | terraform-destroy alone can't finish some resources | Databricks MANAGED RG carries an RP deny-assignment (cannot `az group delete` directly - must delete the WORKSPACE to cascade it); APIM/AKS are slow deletes; KV purge-protection blocks re-create by name. |
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
`include_bootstrap` (unchanged), `remove_mg_hierarchy` (bool, default true - section 5).

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

Reverse-dependency-order terraform-destroy per root, with the F1 fix:
- **`needs` for ORDERING only; `if: ${{ !cancelled() && (mode == 'terraform') && (target == 'all' || target == '<root>') }}`** - NOTE: `!cancelled()` NOT `!failure()`, so a failed/no-op predecessor does NOT skip successors.
- **DELETE the `synthetic` job entirely** (never deployed; not a real root). Remove `synthetic`
  from every `needs`.
- **`_tf-root.yml` destroy resilience (the core F1 fix):** a pre-step runs `terraform init` then
  `terraform state list`; if it errors (no state) or returns empty, echo "no state - nothing to
  destroy" and EXIT 0 (skip `terraform destroy`). An empty root can then NEVER fail. Applies to
  every root, so a partially-deployed estate tears down cleanly.
- Order (reverse of deploy): spokes (corp-a1/a2, online-p1, bank-app-p1, bank-data-p1) ->
  {connectivity, security} -> identity -> management -> management-groups. management-groups LAST
  (its assignments are already gone from Phase 0; terraform destroy now removes the policy DEFS +
  MG hierarchy from state cleanly, or the `remove_mg_hierarchy` az step does it in Phase 2).
- **F2 handling inside terraform-destroy:**
  - Databricks: `terraform destroy` deletes the WORKSPACE resource, which cascades the RP-managed
    RG cleanup (the deny-assignment blocks direct RG delete but not workspace-triggered cleanup).
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
- Databricks (state-gone case): `az databricks workspace delete` on any surviving workspace
  (cascades managed RG); then verify the 2 managed RGs are gone (they "finish on their own" once
  the workspace is deleted - the sweep waits/verifies).
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

## 4. The synthetic/empty-state no-cascade fix (F1) - explicit

The single highest-value change, stated precisely for the implementer:
1. Delete the `synthetic` job; remove `synthetic` from all `needs`.
2. Change every root job `if:` from `!failure()` to `!cancelled()` (predecessor failure must not
   skip successors; `needs` still enforces ordering).
3. Add the `_tf-root.yml` destroy pre-step: `terraform state list` empty/error -> exit 0 skip.
Any one of these alone helps; all three together make an empty/partial estate tear down reliably.

---

## 5. RULING - MG hierarchy for the Wednesday redeploy: FULL TEARDOWN

The subs are REUSED Wednesday; a fresh `management-groups` apply runs against EMPTY state.

**Ruled: FULL MG-hierarchy teardown** (Phase 2 `remove_mg_hierarchy=true`), because a fresh
avm-ptn-alz apply against empty state will try to CREATE the MG tree + sub placements + policy
objects, and a LIVE hierarchy causes "already exists" collisions on MGs/assignments (empty state
has no record to reconcile against). Removing the hierarchy (subs moved to tenant root, MGs deleted
bottom-up) lets Wednesday's apply build the tree from nothing - clean and collision-free.

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
  WORKSPACE (terraform destroy, or `az databricks workspace delete`); the managed RG self-cleans.
  Phase 3 verifies it is gone.
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
