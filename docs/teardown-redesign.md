# Reliable end-to-end teardown - design (zero manual deletion)

> **Status:** GREEN and proven end-to-end. Attempt 5 (run 29765892057) ran Confirm / DISARM /
> AZ-SWEEP / VERIFY all success and the estate was fully torn down. This document is the current,
> canonical design; the code in `scripts/teardown-*.sh` and `.github/workflows/teardown.yml` is the
> source of truth and this narrative matches it.
> **Owner:** Cloud Solutions Architect. Decision record: ADR-054. Implementer: DevSecOps.
> **Contract only - no Terraform or workflow is authored here.**
>
> **Consolidation note (2026-07-20):** the mechanism below was reached through a chain of reactive
> patches, each fixing a distinct real defect (see Appendix A for the dated, run-numbered history).
> This body has been rewritten so the PRIMARY narrative is one clean current design. The
> superseded amendment chain (the per-MG `show` oracle and its supersession, the interim
> descriptions of points 7 to 12) is preserved only in Appendix A. Where any older prose disagrees
> with sections 1 to 11 here, sections 1 to 11 win.

---

## 1. What the teardown must do

The user's hard requirement (2026-07-19): teardown MUST be a reliable end-to-end CI/CD process with
ZERO manual deletion, whether Terraform state is intact or gone. A single `teardown.yml` dispatch
(`target=all`) tears the whole estate down and a green Phase 3 VERIFY is the definition of "done".

The design fixes four root causes that made an earlier teardown fail and forced manual work:

| # | Failure | Root cause |
|---|---|---|
| F1 | The workflow destroyed NOTHING | Every spoke had `needs: [..., synthetic]` plus `if: !failure()`. `synthetic` is a REAL root (its `*.tf` define RGs, red-team ACA jobs, cost-pattern VM/storage, gated behind `var.enable_synthetic_workload`, currently false); its destroy against empty state failed, which put the run into `failure()` state, so `!failure()` was false on every downstream job and all were skipped. One empty-state root cascade-skipped the entire teardown. |
| F2 | terraform-destroy alone cannot finish some resources | The Databricks MANAGED RG carries an RP deny-assignment (cannot `az group delete` it directly); a plain workspace delete now RETAINS it (see section 5); APIM/AKS are slow deletes; KV purge-protection blocks re-create by name. |
| F3 | The policy layer keeps RE-REMEDIATING | MG-scope DINE policy ASSIGNMENTS (base ALZ Deploy-* plus the AMBA objects) stay live during resource deletion and RE-CREATE resources (rg-amba-monitoring-001 was re-remediated). Resource deletion races live remediation and loses. |
| F4 | terraform-destroy can no longer help | State was cleaned to EMPTY for a fresh redeploy, so `terraform destroy` sees nothing and cannot finish a half-destroyed estate. No fallback existed. |

---

## 2. Design principles (ADR-054)

1. **No empty/undeployed root may ever fail-and-cascade.** Ordering `needs` enforces
   reverse-dependency ORDER only, never continuation gating. A predecessor that no-ops or fails must
   not skip successors.
2. **Disarm the policy layer FIRST.** Remove all MG-scope policy ASSIGNMENTS before, and
   independent of, resource deletion so DINE remediation stops and nothing re-creates mid-sweep.
3. **Two modes, one workflow.** terraform-destroy is PRIMARY (state intact); an `az` SWEEP is the
   FALLBACK (state empty/gone). DISARM and VERIFY run in BOTH modes.
4. **Idempotent and resilient.** Every step succeeds whether its target exists or not (deleting an
   absent thing is success). This is what makes E2E reliable across re-dispatch.
5. **Loud completion verification.** The run FAILS if any remnant remains. Never a silent
   half-teardown. A green Phase 3 IS the definition of E2E success.
   > **AMENDED 2026-07-21 (ADR-058, section 13).** A green Phase 3 is NECESSARY but no longer
   > SUFFICIENT. Phase 3 is the in-workflow fail-loud gate; completion is certified by an INDEPENDENT
   > qa-engineer pass against the section 13.3 checklist. The 2026-07-20 run was green on Phase 3 and
   > was not torn down.
6. **Subscription-scope completeness (added 2026-07-21, ADR-057, section 12).** Teardown must return
   every subscription to the state a greenfield apply expects. Resource-group membership is an
   implementation detail of the sweeper, never a boundary of the obligation. If leaving it makes the
   next greenfield apply fail or drift, teardown owns it.

---

## 3. The four phases

The workflow (`teardown.yml`) has a `guard` job plus four phases. Inputs: `confirm` (must equal
`destroy`), `mode` (`terraform` primary / `az-sweep` fallback, default `terraform`),
`include_bootstrap` (default false), `remove_mg_hierarchy` (default false - a safety call; a
checked-in default that silently deletes the whole MG tree on a plain dispatch is too much blast
radius, so a full-estate teardown passes `remove_mg_hierarchy=true` explicitly at dispatch time).

**Guard.** `confirm` must be exactly `destroy` (cheap pre-check before any login). `mode=az-sweep`
requires `target=all`: Phase 0/2/3 only run for `target=all` and Phase 1 only for `mode=terraform`,
so `az-sweep` with a single-root target would run NOTHING and still report green - the guard rejects
that combination before any login.

### Phase 0 - DISARM (`teardown-disarm.sh`; az, always, first, `target=all` only)

Deletes every MG-scope policy ASSIGNMENT across the globaris tree BEFORE any resource deletion, so
DINE remediation cannot re-create resources while Phases 1/2 tear them down (fixes F3). For each MG
scope it also removes any surviving role assignment held by a DINE policy's system-assigned
identity, at the same MG (belt - stops in-flight remediation having rights even if a delete races
the identity's own removal). The identity object itself is not deleted here; it has no effect once
both its role assignment and its policy assignment are gone.

DISARM is gated on the MG-existence snapshot (section 7): it only lists/deletes at MG scopes that
still exist, so a re-dispatch against an already-empty estate is a clean no-op. Phase 1 root jobs
require DISARM success (a genuine causal dependency), so a real DISARM failure stops resource
destroy; Phase 2/3 still run and report any remnant.

### Phase 1 - DESTROY (terraform, per root incl. `synthetic`; `mode=terraform` only, reverse order)

Reverse-dependency-order `terraform destroy` per root, with the F1 fix:

- **`needs` for ORDERING only; `if: !cancelled()` NOT `!failure()`** - a failed or no-op predecessor
  never cascade-skips successors. `disarm` success is the ONE real gate (a causal prerequisite, not
  the F1 anti-pattern).
- **`synthetic` is a real Phase-1 job, hardened not deleted.** It destroys FIRST (mirroring
  `deploy.yml`, which applies it last). Removing it would leave a future populated synthetic root
  without a real `terraform destroy`, drifting its state against whatever the Phase-2 naming-pattern
  sweep catches out-of-band.
- **`_tf-root.yml` state-empty no-op (the core F1 fix):** a pre-step runs `terraform init` then
  `terraform state list`; empty or errored state echoes "nothing to destroy" and exits 0. An
  undeployed or emptied root (including an inert synthetic) can then never fail a destroy.
- Order (reverse of deploy): synthetic -> spokes (corp-a1/a2, online-p1, bank-app-p1, bank-data-p1)
  -> {connectivity, security} -> identity -> management -> management-groups.
- F2 inside destroy: Databricks workspace delete (the deny-assignment blocks the RG, not the
  workspace); APIM/KV provider `features` purge flags; slow deletes covered by the 360-min CI
  ceiling and the state-empty resilience pre-step on re-run.

### Phase 2 - AZ SWEEP (`teardown-az-sweep.sh`; az, `target=all` only, both modes)

Fallback for the state-gone case (`mode=az-sweep`, fixes F4) AND a remnant-catch pass after Phase 1
in `mode=terraform`. Idempotent throughout; every delete is safe to re-run. Six ordered steps,
numbered 1 to 4 then 6 and 7 to match the shipped code exactly.

> **Numbering note (2026-07-21, ADR-057).** Before ADR-057 the reconcile was step 5. ADR-057 inserted
> the subscription-scope pass and moved the reconcile to the end, so the code now runs 1, 2, 3, 4, 6,
> 7 and **there is deliberately no step 5** - the number was retired rather than reused, so existing
> run logs and cross-references that mention a "step 5" are unambiguously pre-ADR-057. Read the ORDER,
> not the arithmetic.

1. **Databricks workspace cascade** - submit `az databricks workspace delete --no-wait
   --force-deletion` (never `az group delete` the RP-managed RG directly; `--force-deletion` is what
   makes the WORKSPACE delete cascade the managed RG - section 5). Capture each managed-RG name for
   the reconcile step.
2. **RG sweep by naming pattern** across all 5 workload/platform subscriptions (`--no-wait`
   submission), EXCLUDING the Databricks-managed RGs from step 1 (a direct delete on those is doomed
   by the RP deny-assignment and is pure noise; they cascade from step 1).
3. **Key Vault** - delete any live vault the pattern still finds (belt against a race with step 2),
   purge non-purge-protected soft-deletes, and RECORD purge-protected ones for the redeploy runbook
   (section 9 / LESSON 56).
4. **MG hierarchy removal** - only if `remove_mg_hierarchy=true`. Gated on the MG-existence snapshot
   (section 7). Bottom-up: for each MG still present, re-parent its subscriptions to the tenant root
   then delete the now-empty MG. Subscriptions are never deleted, only re-parented (section 8). MG
   ops are fast control-plane calls and stay synchronous (no `--no-wait`, no reconcile wait).
6. **SUBSCRIPTION SCOPE (added 2026-07-21, ADR-057)** - the az sweep finds resources by RG naming
   pattern and therefore cannot see anything that lives outside a resource group. This step covers
   that surface explicitly: the four subscription-scoped object classes (budgets, cost exports at API
   version `2025-03-01`, cost anomaly scheduled actions, subscription diagnostic settings), the
   Defender for Cloud pricing reset to Free from a fixed allow-list, and the resource-provider
   unregistration. Runs AFTER the MG removal in step 4 and BEFORE the reconcile in step 7. Full
   contract, including exact API versions, discovery method, failure handling and the never-touch
   lists: **section 12.3**.
7. **Reconciliation** - ONE bounded wait (section 4) for every RG submitted in steps 1 to 2 to
   report gone. The wait lives HERE, never in VERIFY. (This was step 5 before ADR-057; the shipped
   code numbers it 7.)

### Phase 3 - VERIFY (`teardown-verify.sh`; az, always, last, `target=all` only)

An IMMEDIATE, unwaited truth-gate that asserts zero estate remnants and FAILS LOUDLY on anything
found. VERIFY 0 resolves all 5 subscription IDs (a missing secret must not silently skip a
subscription and report "clean"). VERIFY 1 (no MG-scope policy assignments), VERIFY 2 (no
workload/platform RGs incl. rg-amba-monitoring-001), VERIFY 3 (no Databricks workspaces), VERIFY 4
(MG hierarchy gone, if `remove_mg_hierarchy`), VERIFY 5 (soft-deleted KV report for the redeploy
recover list). VERIFY never waits - patience belongs to the ACTOR (Phase 2), instant judgment to the
AUDITOR (Phase 3).

---

## 4. Token-durability model (az_relogin + no-wait + reconcile)

**The problem.** `azure/login`'s GitHub OIDC federated assertion is valid only inside GitHub's ~5
minute issuance window. Once consumed, az's own token refresh has no live assertion left to refresh
with, so any single step that outlives the resulting ~1h Azure access token dies with
`AADSTS700024: Client assertion is not within its valid time range`. A synchronous Databricks
workspace delete plus an in-session poll once drove one step to ~55 minutes and hit exactly this.

**The model (locked, three parts):**

- **(a) `--no-wait` submission pass.** Phase 2 fires EVERY delete asynchronously (Databricks
  workspace, RGs, KV). No operation ever long-polls in-session on the token that submitted it, so
  the submission pass completes well inside one fresh access token.
- **(b) `az_relogin` primitive** (`teardown-common.sh`). Mints a BRAND-NEW GitHub OIDC assertion on
  demand: requests a fresh id-token from `$ACTIONS_ID_TOKEN_REQUEST_URL` (bearer
  `$ACTIONS_ID_TOKEN_REQUEST_TOKEN`, audience `api://AzureADTokenExchange` sent URL-encoded), then
  `az login --service-principal --username $AZURE_CLIENT_ID --tenant $AZURE_TENANT_ID
  --federated-token <token>` and `az account set --subscription $AZURE_SUBSCRIPTION_ID`. GitHub
  serves fresh assertions for the whole job, so this bypasses az's structurally-broken refresh. A
  failed re-login is FAIL LOUD; never continue past it.
- **(c) relogin-then-poll reconcile.** The single bounded reconcile wait (`wait_for_rgs_gone`,
  section 3 Phase 2 step 7) calls `az_relogin` at the START of every iteration, so a poll can never
  outlive its token. Ceiling 30 minutes (well under the 360-min job ceiling). Reaching the ceiling
  with stragglers is advisory (Phase 3 is authoritative; idempotent re-dispatch is the safety net);
  an auth-classified failure mid-wait is a hard non-zero exit.

Identity is supplied to the sweep step via repo Variables (`AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
`AZURE_SUBSCRIPTION_ID`); the `ACTIONS_ID_TOKEN_REQUEST_*` values are auto-present because the
workflow sets `permissions: id-token: write`. No client secret is ever used.

Rejected: relying on `azure/login` at job start alone (does not survive a single step longer than
the token lifetime); relying on az token refresh (structurally impossible with a consumed one-time
assertion); putting the wait inside VERIFY (muddies the auditor's "truth at this instant" contract);
an in-workflow auto-retry loop (could mask a genuinely stuck delete).

---

## 5. The Databricks `--force-deletion` cascade

The Databricks managed RG carries an RP deny-assignment, so it can never be deleted with a direct
`az group delete`. The teardown deletes the WORKSPACE, which is entitled to cascade its managed RG.

Per the current Microsoft "Delete a workspace" doc (ms.date 2026-07-08) a plain workspace delete NO
LONGER self-cleans the managed RG: it RETAINS the managed RG (plus its DBFS storage account and
access connector), and for a Unity-Catalog-enabled workspace Azure converts the managed RG into a
regular RG and keeps its contents. So the workspace delete MUST pass `--force-deletion` to cascade
the managed RG. `--force-deletion` and `--no-wait` combine on `az databricks workspace delete`
(independent optional flags, same parameter group, no exclusivity note; confirmed against the live
CLI reference and proven in run 29749656053 where `--force-deletion` cleared the managed RG). The
submission stays async; the actual cascade is what the reconcile step (section 3 Phase 2 step 7)
waits for. The managed RG is EXCLUDED from the step 2 direct-delete sweep because a direct delete on
it is doomed by the deny-assignment until the workspace's own force-delete cascade completes.

---

## 6. The auth-fail-loud rule (and the two data-integrity traps it depends on)

**The rule (locked).** No teardown step may EVER treat an auth / token / transport failure as
"resource absent / already gone / nothing to do". Every existence check and list call must
DISTINGUISH a genuine NotFound (idempotent no-op, success) from an auth or transport error (FAIL
LOUD, non-zero, `::error::`). A failed (non-zero) list is explicitly distinct from a successful list
that returned zero rows; only the latter is "nothing to sweep". This binds ALL three scripts, VERIFY
especially - a dead token inside the truth-gate would otherwise falsely certify "clean", the worst
possible outcome. `is_auth_error` (`teardown-common.sh`) is the shared classifier, matching
(case-insensitive) `AADSTS`, "valid time range", "not within", `AuthenticationFailed`,
`ExpiredAuthenticationToken`, `token`, `credential`, `401`, `403`, `az login`.

The rule is only sound because two data-integrity traps are closed everywhere a call's stdout is
consumed as data:

- **Trap 1 - stderr-banner-into-data.** The az CLI writes WARNING banners to stderr even on a clean
  exit-0 call (update-available nags, extension advisories). A merged `2>&1` capture feeding
  `mapfile` or a scalar compare can inject a bogus row (a false VERIFY failure, or a bogus RG/KV name
  pushed through a delete and the reconcile wait). `az_run` (`teardown-common.sh`) is the ONLY
  sanctioned way to capture list/show output destined for `mapfile` or a scalar compare: it keeps
  stdout (the data channel) and stderr (`AZ_RUN_STDERR`, inspected only on the non-zero-exit path)
  fully separate.
- **Trap 2 - swallow-auth-as-empty.** The pre-hardening `2>/dev/null || true` / `2>/dev/null ||
  echo 0` patterns could not tell an empty result from a dead token, so an auth-failing call
  silently "passed" as clean. Every list call now classifies a non-zero exit with `is_auth_error`
  instead of swallowing it.

**Design boundary (which failures fail loud):**

- A call whose scope can NEVER legitimately be gone on its own (any subscription-scoped list -
  subscriptions are only re-parented, never deleted, section 8) -> ANY non-zero is FAIL LOUD.
- A call at a scope confirmed LIVE by the MG snapshot (section 7) -> ANY non-zero is FAIL LOUD (a
  dead token OR a real permission gap OR any other error at a scope known to exist is a real
  anomaly, never "absent").
- A call whose scope MIGHT legitimately be gone -> this case is designed OUT: MG existence is never
  inferred from a per-scope call's error shape; it is resolved up front by the snapshot (section 7),
  and every per-scope MG call runs only at scopes the snapshot confirms present.

---

## 7. The MG existence oracle - a one-time `az account management-group list` snapshot

**The structural root.** The teardown runs as the SCOPED OIDC service principal. Its MG-read grants
were scoped to the globaris subtree (bootstrap identity config) and are DELETED together with that
subtree. So this principal can DELETE the MGs but cannot then `show` a deleted MG: a per-MG
`az account management-group show <deleted-mg>` evaluates RBAC on a scope the SP no longer holds any
grant over and returns HTTP-403 `AuthorizationFailed`, NOT the clean 404 `ManagementGroupNotFound`
that a tenant-root-privileged principal sees. `is_auth_error` correctly matches that 403, so any
`show`-based existence gate fails loud on every benign already-gone MG for this principal. A
per-scope policy-assignment `list` on a deleted MG has the identical failure (403, because ARM
evaluates RBAC on the scope before confirming it exists).

**The oracle (locked, canonical - NOT a workaround).** Existence is resolved ONCE per script run by
a single `az account management-group list --query "[].name" -o tsv` snapshot; MG existence is name
membership in that set (`mg_snapshot_load` / `mg_in_snapshot`, `teardown-common.sh`). The SP's
SURVIVING grant is Management Group Contributor at the TENANT ROOT (never deleted), which carries
`Microsoft.Management/managementGroups/read`, so a `list` over that readable collection is always
available to the SP; a deleted MG is simply ABSENT from it, resolving existence with NO per-scope
call and therefore NO deleted-scope 403. This was proven empirically (probe run 29756715840, run AS
the SP): `list` succeeds and returns only the tenant root, `show --name globaris` returns 403,
`show` on the tenant root succeeds.

**Auth-fail-loud lives on the LIST call.** A non-zero snapshot load that `is_auth_error` (or any
non-zero) is a genuine dead token at the one call the SP is always entitled to make -> FAIL LOUD; a
successful list is authoritative ground truth for the whole run (a dead token cannot return a clean
list). This preserves the section-6 guarantee while eliminating the deleted-scope false-positive.

**All four MG-touching sites consume the snapshot, none uses `show`:**

1. `teardown-disarm.sh` per-MG loop - absent MG -> skip (nothing to disarm at a gone scope); present
   MG -> disarm with auth-fail-loud unchanged.
2. `teardown-verify.sh` VERIFY 1 (per-MG policy-assignment loop) - absent -> clean (VERIFY 4 owns the
   gone-assertion); present -> remaining-assignments check with auth-fail-loud unchanged.
3. `teardown-verify.sh` VERIFY 4 (MG-gone assertion) - name-absence from the snapshot; no `show`.
4. `teardown-az-sweep.sh` step 4 - iterate/delete only MGs PRESENT in the snapshot; already-empty
   estate -> snapshot holds none of the globaris-tree names -> step 4 no-ops.

VERIFY additionally guards on a `mg_snapshot_ok` flag: a FAILED load resets the snapshot to empty, so
without the guard every `mg_in_snapshot` would read "absent" and every MG would be falsely reported
"clean (gone)". On a failed load, VERIFY 1 and VERIFY 4 both skip and print an explicit "cannot
certify" notice while the failed load itself fails the script.

The throwaway probe workflow that produced run 29756715840 has been removed from the repo; it existed
only to prove this oracle.

---

## 8. MG hierarchy teardown for a clean redeploy

When `remove_mg_hierarchy=true`, Phase 2 step 4 removes the globaris MG tree bottom-up so a fresh
`avm-ptn-alz` apply against EMPTY state can build the tree from nothing without "already exists"
collisions (empty state has no record to reconcile a live hierarchy against). Subscriptions are
PRESERVED - they are moved to the tenant root MG (non-destructive; subs and their resources are
untouched, only the MG container membership changes) and the next apply re-places them. The removal
is the LAST teardown step, after all resources and policy assignments are gone, so nothing references
the MGs when they are deleted.

Rejected: `terraform import` of the live hierarchy into fresh state before apply (heavy, fragile,
slow for a routine redeploy); idempotent reconcile of avm-ptn-alz over a live hierarchy with empty
state (the alz provider does not adopt pre-existing MGs into empty state; it collides on create).

---

## 9. Databricks / Key Vault / APIM handling (F2), consolidated

- **Databricks managed RG:** never `az group delete` it directly (RP deny-assignment); delete the
  WORKSPACE with `--force-deletion` (section 5); the reconcile step waits and VERIFY 3 confirms.
- **KV purge-protection:** teardown soft-deletes KVs and purges the non-purge-protected ones;
  purge-protected vaults cannot be purged until retention expires. Phase 2 step 3 and VERIFY 5 record
  the soft-deleted vault list so the redeploy knows what to recover
  (`recover_soft_deleted_key_vaults=true`, LESSON 56) or uses fresh names. The bootstrap state-backend
  KV is out of the default teardown scope and preserved.
- **APIM / AKS slow deletes:** provider `features` purge flags plus the 360-min CI ceiling; the
  state-empty resilience pre-step lets a timed-out slow delete be re-run and continue.

---

## 10. Implementation contract - auth-fail-loud / principal-dependent code sweep (DevSecOps)

The token-durability, force-deletion, and snapshot-oracle fixes above are implemented and proven.
The following is the ONE residual hardening class to sweep uniformly: sites that treat a NON-auth
failure at a CONFIRMED-LIVE scope as "no data / already disarmed" (a swallow-non-auth-as-empty on the
list `else` branch). VERIFY 1 already does this correctly (its `else` calls `note_fail`); DISARM has
three siblings that do not. This is a hardening of the error path only - it changes NO happy-path
behavior and NO proven teardown behavior.

**Classification key.** For each az call: TYPE (list / scoped-read / delete-submission / snapshot);
TRAPS it can hit (T1 stderr-banner-into-data, T2 swallow-auth-as-empty, T3 principal-dependent
403-on-deleted-scope); REQUIRED behavior.

### 10.1 IN-SCOPE fix set (class A: swallow-non-auth-as-empty at a confirmed-live scope)

All three are in `teardown-disarm.sh`, all inside the `mg_in_snapshot` present-branch (so the scope
is CONFIRMED LIVE). Required change: the `else` branch (non-auth, non-zero) must FAIL LOUD, matching
VERIFY 1's `else -> note_fail`. `is_auth_error` handling is unchanged; the happy path is unchanged.

| Site | Call | Current `else` behavior | Required behavior |
|---|---|---|---|
| disarm ~L114-117 (identity scan) | `az_run ... policy assignment list --scope <live mg> --query "[?identity!=null]..."` | prints "no data (already disarmed, or scope no longer exists)", sets `identity_rows=()` and PROCEEDS | non-auth non-zero at a live scope is a real error: `::error::`, `fail=1`, `continue` (do NOT treat as empty). The scope is present in the snapshot, so "scope no longer exists" is impossible here - drop that phrasing. |
| disarm ~L132-134 (role list) | `az_run ... role assignment list --scope <live mg> --assignee <principalId>` | prints "no data (continuing)", sets `role_ids=()` and PROCEEDS | same class: non-auth non-zero -> `::error::`, `fail=1`, `continue`. ADDITIONALLY pass the harvested principal id via `--assignee-object-id "$principal_id"` (and `--fill-principal-name false`) instead of `--assignee`, so a deleted-DINE-identity Graph-resolution error cannot masquerade as this class and trip the new fail-loud. `--assignee-object-id` and `--fill-principal-name false` are verified real `az role assignment list` flags (CLI ref ms.date 2026-06-26): both bypass the Microsoft Graph query. |
| disarm ~L156-158 (assignment names) | `az_run ... policy assignment list --scope <live mg> --query "[].name"` | prints "No policy assignments at scope ... (already disarmed, or scope no longer exists)" and `continue` (treats the whole scope as clean) | non-auth non-zero at a live scope -> `::error::`, `fail=1`, `continue`. This is the highest-severity of the three: swallowing it certifies a scope disarmed off a real error, re-opening the F3 window while the run stays green. |

The DISARM header comment that still frames a deleted-MG list as returning "a genuine NotFound,
distinct from an auth failure" must be corrected: existence is resolved by the snapshot, and a
deleted-MG list returns a 403 (never reached now, because the loop skips absent MGs).

### 10.2 Consistency observation (class B: swallow-auth-as-benign on a delete/action submission) - LOWER priority, optional in this sweep

Four delete/action submissions swallow ALL failures as a warning-continue without classifying auth,
whereas the Databricks workspace delete (`teardown-az-sweep.sh` step 1) already classifies auth and
fails loud. These do NOT produce a false-green (Phase 2 reconcile + Phase 3 VERIFY backstop every
one), so they are a coherence gap, not a correctness defect. Recommendation: for uniformity, apply
the same `is_auth_error` classification the Databricks delete already uses (auth -> fail loud;
genuine idempotent-absent -> warning-continue). Fold in ONLY as a conscious, labeled coherence change
- do NOT silent-change behavior.

| Site | Call | Backstop that prevents a false-green | Suggested uniform treatment |
|---|---|---|---|
| disarm ~L139 | `az role assignment delete --ids <id>` | An auth death here also hits the policy-assignment delete (L169), which already sets `fail=1`, so DISARM still fails loud overall | classify captured stderr: auth -> `fail=1`; else warning-continue |
| az-sweep ~L160 | `az group delete --name <rg> --no-wait` | RG appended to `deleted_rgs`; reconcile `az_relogin` re-auths and re-checks; VERIFY 2 fails loud on any remnant | classify: auth -> `exit 1`; else warning-continue |
| az-sweep ~L182 | `az keyvault delete` | reconcile + VERIFY 2/5 backstop | classify: auth -> `exit 1`; else warning-continue |
| az-sweep ~L202 | `az keyvault purge` | VERIFY 5 lists soft-deleted vaults (fails loud on an auth error there) | classify: auth -> `exit 1`; else warning-continue |

Note: `az policy assignment delete` (disarm ~L169) and the MG `subscription remove` / `management-group
delete` (az-sweep ~L245/L252) already fail loud on ANY non-zero, which is safe; no change needed.

### 10.3 Confirmed - no other principal-dependent oracle lurks

Every per-scope MG call (`policy assignment list`, `role assignment list`, the assignment/role
deletes, `management-group subscription show-sub-under-mg`, `subscription remove`,
`management-group delete`) runs ONLY at MG scopes the snapshot confirms present, and each MG is
deleted at the END of its own iteration (bottom-up), so none is ever a deleted-scope call for the
SP. All subscription-scoped list/`group exists` calls target subscriptions, which are never deleted.
The ONLY tenant-root-collection call is the snapshot itself (the canonical oracle). No `show` remains
as an existence oracle. There is no other per-deleted-scope call as the scoped SP.

### 10.4 What does NOT change

The four-phase shape; `!cancelled()` gating; mode/target logic; `remove_mg_hierarchy` default
(false); the `az_run` stdout/stderr separation; the `is_auth_error` matcher (NOT loosened); the
snapshot oracle; the token-durability model; `--force-deletion`. This sweep is coherence plus the
class-A hardening only.

---

## 11. Acceptance criteria

- A single `teardown.yml` dispatch (`target=all`) tears the estate down E2E with ZERO manual steps
  for the default scope, state intact (`terraform`) or gone (`az-sweep`).
- No empty/undeployed root can cascade-skip or fail the run.
- Policy remediation is disarmed before resource deletion (no re-creation races).
- No step reports "already gone / clean / nothing to do" off an auth or transport error; such an
  error fails the run loudly.
- Phase 2 completes as a submission pass plus one relogin-bounded reconcile wait, never a
  >token-lifetime single step, re-authenticating across the wait (no AADSTS700024).
- Phase 3 VERIFY is green after a genuinely complete teardown, loud on any real remnant, and can
  never certify "clean" on a dead token.
- A fresh redeploy meets a clean slate (no MG-hierarchy collision, KV recover path documented).
- Idempotent re-dispatch finishes any over-ceiling straggler; no manual deletion.

Added 2026-07-21:

- **Subscription scope is clean (ADR-057).** Zero estate-owned budgets, cost exports, cost anomaly
  scheduled actions and subscription diagnostic settings across all 5 subscriptions; all 8
  estate-configured Defender plans read `Free`; every managed resource-provider registration reads
  not-`Registered`. Verified by VERIFY 6 to 8 in-workflow and by the section 13.3 QA checklist out of
  band.
- **An independent qa-engineer PASS against section 13.3 exists (ADR-058).** A green Phase 3 is an
  input to that pass, never a substitute. Any verdict other than PASS blocks the rebuild.
- **Nothing that must survive was destroyed**: state backend, OIDC federated credentials, the
  bootstrap identity's standing role assignments, and the ADR-041 temporary tenant-root grants the
  rebuild still needs.

---

## 12. Subscription-scope completeness (ADR-057) - the gap, the ruling, and the DevSecOps contract

> Added 2026-07-21. Sections 1 to 11 above are unchanged and remain correct; this section ADDS a
> Phase 2 step and a governing principle they did not have. Where section 3's phase list or section 11's
> acceptance criteria are read in future, read them together with sections 12 and 13.

### 12.1 Root cause, at mechanism level

The 2026-07-21 B0a pre-clearance refresh found 21 deterministic, plan-invisible apply failures waiting
for the rebuild. All 21 trace to one mechanical fact.

**`terraform destroy` never ran for `platform/management` or `platform/security` in the 2026-07-19/20
teardown.** Job-level inspection of the run history proves it:

| Run | Date | What ran |
|---|---|---|
| 29706565357 | 2026-07-19 | Phase 1 attempted. `synthetic` FAILED, `identity` FAILED, and `security`, `connectivity`, `management`, `management-groups` and every spoke were SKIPPED. No DISARM job. |
| 29712487341, 29749656053, 29753193590 | 2026-07-20 | `mode=az-sweep`. Every Phase 1 root job skipped by design. All three failed in Phase 2 or 3. |
| **29765892057** | 2026-07-20 | `mode=az-sweep`. **DISARM success, every Phase 1 root job `skipped`, AZ-SWEEP success, VERIFY success.** This is the run recorded as GREEN E2E. |
| 29773408578 | 2026-07-20 | `mode=az-sweep`, same shape, success. |

So the answer to "does the current model run `terraform destroy` at all" is: **it can, but it did not,
and has not since 2026-07-11.** Both halves of the question matter and they have different answers:

- **Phase 1 exists and is real.** `mode=terraform` runs a per-root `terraform destroy`, and a destroy
  covers subscription scope for free, because the provider that created an object deletes it
  regardless of where it lives. This is precisely why the 2026-07-11 teardown produced a clean
  greenfield and the 2026-07-16 rebuild was pure adds.
- **The az sweep structurally cannot see non-RG-scoped objects.** It finds things by RESOURCE GROUP
  NAMING PATTERN (`RG_SWEEP_QUERY` in `teardown-common.sh`,
  `[?contains(name,'globaris') || contains(name,'amba-monitoring')].name`), plus three explicit
  passes: Databricks workspaces, Key Vaults, and management groups. Nothing in it enumerates a
  subscription-scope extension resource, a Defender pricing plan, or a provider registration. It never
  did, and it never claimed to.

**Therefore: nothing regressed inside the az sweep. What regressed is which mode runs.** ADR-054
describes terraform-destroy as PRIMARY and az-sweep as FALLBACK. In practice the primary path
cascade-failed once (the F1 class, on an empty `synthetic` root) and was then abandoned for five
consecutive runs, so the fallback silently became the only path, while the design still asserted a
primary that was not executing. Everything that lives outside a resource group survived every green
run.

The surviving classes, and why each one blocks a rebuild rather than merely lingering:

| Class | Count | Owning resource | Create-time guard (source-verified) |
|---|---|---|---|
| Subscription budgets | 5 | `azurerm_consumption_budget_subscription` | `tf.ImportAsExistsError` |
| Cost exports | 5 | `azapi_resource`, `Microsoft.CostManagement/exports@2025-03-01` | azapi "Resource already exists" |
| Cost anomaly scheduled action | 1 | `azurerm_cost_anomaly_alert` | `ResourceRequiresImport` |
| Subscription diagnostic setting | 1 | `azurerm_monitor_diagnostic_setting` | `tf.ImportAsExistsError` |
| Defender pricing plans left Standard | 8 | `azurerm_security_center_subscription_pricing` | create returns requires-import unless the live tier is `Free` |
| Provider registration left Registered | 1 | `azurerm_resource_provider_registration` | `metadata.ResourceRequiresImport` when already `Registered` |

Each guard was read from the pinned provider source (azurerm v4.71.0), not from documentation or
memory. All are invisible to `validate` and to `plan`.

### 12.2 The ruling

Governing principle (ADR-057 decision 1), stated so future waves inherit it rather than re-litigate it
per object type:

> **Teardown must return every subscription in the estate to the state a greenfield apply expects.**
> "Torn down" is defined by what the NEXT apply will attempt to create, not by what the last sweep
> happened to look at. Resource-group membership is an implementation detail of the sweeper, never a
> boundary of the obligation. Where an object cannot be deleted (a subscription-level setting, a
> provider registration), teardown owns returning it to its pre-apply VALUE.
>
> The one-line test that settles any future scope argument: **if leaving it makes the next greenfield
> apply fail or drift, teardown owns it.**

Mechanism (ADR-057 decision 3): **extend the az sweep with an explicit subscription-scope pass (new
Phase 2 step 6) AND restore `mode=terraform` to real primary status.** Both, not either. The sweep must
be able to finish the job unaided, because az-sweep is the only mode that has ever completed green
since the redesign and it exists precisely for the state-empty world (F4). Terraform-destroy must be a
live path again, because a provider destroying its own state has fidelity a naming-pattern sweep can
never have. Declaring az-sweep the sole supported path was considered and REJECTED: it discards state
fidelity and makes every future object class a silent gap.

Because Phase 2 already runs in BOTH modes (fallback in `az-sweep`, remnant-catch in `terraform`),
step 6 executes on the terraform path too, where it is a pure idempotent no-op because the destroys
already removed everything.

### 12.3 Implementation contract for DevSecOps (Phase 2 step 6)

Placement: a new **step 6 in `scripts/teardown-az-sweep.sh`**, AFTER the MG-hierarchy step 4 and
BEFORE the reconcile. The ORDER is the contract, the numbering is not. Order rationale:
subscription-scope objects must be removed after the RG cascade has been submitted (so nothing
re-creates them) and before the single bounded reconcile wait (so step 6's own submissions are covered
by the existing wait and by Phase 3).

**As shipped (2026-07-21):** the reconcile that used to be step 5 moved to **step 7**, and the number
5 was retired rather than reused, so the script runs 1, 2, 3, 4, 6, 7. See the numbering note in
section 3 Phase 2.

Everything below inherits the existing conventions without exception: `az_run` for any call whose
stdout is consumed as data (Trap 1), `is_auth_error` classification on every non-zero (Trap 2),
auth-fail-loud, idempotent-absent-is-success, no new error conventions.

**Sub-step 6a - the four subscription-scoped object classes.**

Loop over `"${SUBS[@]}"` (the existing `teardown_subscriptions` array). For each subscription, for each
class: LIST, then DELETE each row found. Discovery is by LIST, never by a hardcoded name list, so a
renamed or added object is still caught. Filter the listed names by the same estate-ownership test the
sweep already uses, `contains(name,'globaris')`, so a non-estate object in a shared subscription is
never touched.

| Class | List call | Delete call | Notes |
|---|---|---|---|
| Consumption budgets | `az_run out consumption budget list --subscription "$sub" --query "[?contains(name,'globaris')].name" -o tsv` | `az rest --method delete --url ".../subscriptions/$sub/providers/Microsoft.Consumption/budgets/$name?api-version=2023-05-01"` | `az consumption budget delete` also exists; prefer whichever the reviewer confirms is non-deprecated at implementation time. The REST form is version-explicit and is what was verified live. |
| Cost exports | `az_run out rest --method get --url ".../subscriptions/$sub/providers/Microsoft.CostManagement/exports?api-version=2025-03-01" --query "join(',',value[?contains(name,'globaris')].name)" -o tsv` | `az rest --method delete --url ".../subscriptions/$sub/providers/Microsoft.CostManagement/exports/$name?api-version=2025-03-01"` | **The API version is load-bearing.** ADR-027 creates these at `2025-03-01`; a GET at an older version returns them as absent. This exact trap produced a false-negative QA finding on 2026-07-16. Do not "simplify" to `az costmanagement export list` unless the extension is confirmed to use `2025-03-01`. |
| Cost anomaly alerts / scheduled actions | `az_run out rest --method get --url ".../subscriptions/$sub/providers/Microsoft.CostManagement/scheduledActions?api-version=2023-11-01" --query "join(',',value[?contains(name,'globaris')].name)" -o tsv` | `az rest --method delete --url ".../subscriptions/$sub/providers/Microsoft.CostManagement/scheduledActions/$name?api-version=2023-11-01"` | Only the management subscription carries one today, but the loop runs across all five so a future wave is covered. |
| Subscription diagnostic settings | `az_run out monitor diagnostic-settings subscription list --subscription "$sub" --query "value[].name" -o tsv` | `az monitor diagnostic-settings subscription delete --name "$name" --subscription "$sub" --yes` | The estate name is `diag-activity-to-security-law` (NOT org-prefixed). Match it explicitly by name in addition to the `globaris` substring test, or the substring filter will miss it. This is the one class where the standard filter does not apply. |

Failure handling for 6a, per call, matching the existing step 1 and step 2 shape exactly:
- List call non-zero: this is a SUBSCRIPTION-scoped list, and per section 6's design boundary a
  subscription can never legitimately be gone. **Any** non-zero is FAIL LOUD (`::error::`, `exit 1`).
  Never read a failed list as "no objects".
- Delete call non-zero: classify with `is_auth_error`. Auth-shaped means `::error::` plus `exit 1`.
  Anything else means `::warning::` plus continue (idempotent-absent is success; Phase 3 and the QA
  pass are the backstops).

These are synchronous control-plane deletes that complete in well under a second. Do NOT add them to
`wait_for_rgs_gone`; that helper is RG-shaped and these are not resource groups.

**Sub-step 6b - Defender for Cloud pricing reset (security subscription only).**

Define the allow-list in `teardown-common.sh` next to `MG_SCOPES` and `RG_SWEEP_QUERY`, so the sweep and
any future check read one definition:

```
DEFENDER_PLANS_TO_FREE=(VirtualMachines StorageAccounts AppServices SqlServers \
                        SqlServerVirtualMachines Containers OpenSourceRelationalDatabases CloudPosture)
```

This list mirrors `platform/security` exactly: `local.defender_basic_plans` (StorageAccounts) plus the
`servers` resource (VirtualMachines) plus `local.defender_extended_plans` (the remaining six). Add a
comment stating that it MUST be kept in lock-step with those three, the same coupling note
`RG_SWEEP_QUERY` already carries.

For each plan in the allow-list, in the SECURITY subscription only:
`az security pricing create -n "$plan" --tier Free --subscription "$SECURITY_SUBSCRIPTION_ID"`

Hard rules:
- **Never iterate the live pricing list.** Iterate the allow-list. A live-list loop would eventually
  disarm a plan this estate does not own, and disarming can be permanently irreversible (LESSON 41:
  Microsoft blocks NEW enablement of deprecated plans, so a plan set to Free may never come back).
- **Never attempt to set any plan to Standard.** Teardown only ever moves toward Free.
- Explicit never-touch list, for the comment block: `KeyVaults`, `Arm`, `Dns`, `KubernetesService`,
  `ContainerRegistry`, `CosmosDbs`, `Api`, `AI`, `Discovery`, `FoundationalCspm`.
- Idempotency: setting an already-Free plan to Free is a successful no-op, so a re-dispatch is clean.
- Failure handling: classify with `is_auth_error`; auth-shaped fails loud, anything else warns and
  continues.
- Guard on `SECURITY_SUBSCRIPTION_ID` being non-empty; if it is empty, that is already a VERIFY 0
  failure class, so fail loud here too rather than silently skipping.

**Sub-step 6c - resource-provider unregistration (management subscription only).**

Runs strictly AFTER 6a, because unregistering a provider that still has resources fails.

`az provider unregister --namespace Microsoft.CostManagementExports --subscription "$MANAGEMENT_SUBSCRIPTION_ID"`

- Idempotent: unregistering an already-unregistered provider is a no-op.
- Do NOT poll to `Unregistered` in-session. Submit, and let Phase 3 plus the QA checklist confirm.
  Registration state transitions are fast, but an in-session poll is exactly the pattern the
  token-durability model (section 4) exists to forbid.
- Failure handling: `is_auth_error` classify; auth fails loud, otherwise warn and continue.
- Namespace list kept in `teardown-common.sh` as `RP_NAMESPACES_TO_UNREGISTER=(Microsoft.CostManagementExports)`
  so it is one line to extend and one line to empty if OQ-049 removes the need.

**Phase 3 VERIFY additions (`scripts/teardown-verify.sh`).**

Three new checks, using the existing `note_fail` pattern and the existing subscription-scoped
fail-loud boundary (any non-zero list is a hard failure - subscriptions are never legitimately gone):

- **VERIFY 6** - across all 5 subscriptions, each of the four 6a classes returns zero estate-owned
  rows. Uses the same list calls and the same API versions as 6a.
- **VERIFY 7** - in the security subscription, every plan in `DEFENDER_PLANS_TO_FREE` reads
  `pricingTier == Free`.
- **VERIFY 8** - in the management subscription, every namespace in `RP_NAMESPACES_TO_UNREGISTER`
  reads a registration state that is not `Registered`. Accept `Unregistering` as a pass with a
  `::notice::`, since the submission is async and VERIFY never waits (section 3 Phase 3 contract).

**What does NOT change.** The four-phase shape; `!cancelled()` gating; mode and target logic; the
`remove_mg_hierarchy` default; `az_run`; `is_auth_error` (not loosened); the MG snapshot oracle; the
token-durability model; `--force-deletion`; the single bounded reconcile and its position as the ONLY
wait. Step 6 adds a surface, not a convention.

**Workflow wiring.** None required. The `az-sweep` job already exports all five `*_SUBSCRIPTION_ID`
secrets plus `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` for `az_relogin`, and the
`verify` job already exports all five subscription IDs. Step 6 and VERIFY 6 to 8 need nothing new.

### 12.4 RBAC feasibility - VERIFIED, no grant needed, no bootstrap re-apply

The teardown identity is the scoped OIDC service principal, not the operator account. Every write step 6
performs was checked three ways.

**(a) Role definition, read live.** The SP holds **Contributor** at each of the five subscriptions.
Contributor's `actions` is `["*"]` and its `notActions` are exactly:
`Microsoft.Authorization/*/Delete`, `Microsoft.Authorization/*/Write`,
`Microsoft.Authorization/elevateAccess/Action`, `Microsoft.Blueprint/blueprintAssignments/write`,
`Microsoft.Blueprint/blueprintAssignments/delete`, `Microsoft.Compute/galleries/share/action`,
`Microsoft.Purview/consents/write`, `Microsoft.Purview/consents/delete`,
`Microsoft.Resources/deploymentStacks/manageDenySetting/action`, `Microsoft.Subscription/cancel/action`,
`Microsoft.Subscription/enable/action`. **None of the actions step 6 needs appears in that list.**

**(b) Each required operation confirmed to be a real ARM operation** (anti-hallucination, queried live
from the provider operation catalogue):

| Operation | Exists | Covered by Contributor |
|---|---|---|
| `Microsoft.Consumption/budgets/delete` | yes | yes |
| `Microsoft.CostManagement/exports/delete` | yes | yes |
| `Microsoft.CostManagement/scheduledActions/delete` | yes | yes |
| `Microsoft.Insights/DiagnosticSettings/Delete` | yes | yes |
| `Microsoft.Security/pricings/write` | yes | yes |
| `Microsoft.CostManagementExports/register/action` (the namespace publishes register; unregister is the paired action on the same namespace and falls under Contributor's `*`) | yes | yes |
| The matching `/read` operation for each of the above, for VERIFY 6 to 8 | yes | yes |

**(c) Empirical proof by this exact principal.** The 2026-07-11 teardown ran `terraform destroy` AS
THIS SP and successfully performed every one of these operations: it deleted the budgets, the exports,
the anomaly alert and the diagnostic setting; it set every Defender plan to Free (recorded in the
2026-07-12 pre-clearance as "all plans verified live Free, teardown V-5 held"); and it unregistered
`Microsoft.CostManagementExports` (which is why the 2026-07-16 apply's registration succeeded). This is
not an inference from a role definition; it is the same principal doing the same writes against the
same subscriptions, eleven days ago.

**(d) No deny assignments.** Queried live: zero deny assignments at every one of the five estate
subscriptions, so nothing overrides the Contributor grant.

**Verdict: GO. No new role assignment, no bootstrap re-apply, no change to `bootstrap/identity.tf`, no
sequencing impact on the rebuild from RBAC.** This is consistent with OQ-008 and ADR-021 direction of
travel: the fix adds zero standing privilege. If a future wave adds a class requiring an action outside
Contributor, the contract is to name the precise action and scope and propose a least-privilege
bootstrap row, never an Owner grant.

### 12.5 Safety of the immediate re-run (2026-07-21, against a mostly-empty estate)

Safe. Dispatch `mode=az-sweep`, `target=all`, `remove_mg_hierarchy=true`, `confirm=destroy`.

Expected no-ops, all by design and all already proven on run 29765892057 which ran against an
already-empty estate and went green:
- The MG snapshot returns only the tenant root, so DISARM skips every globaris-tree scope, VERIFY 1
  reports each as clean-because-gone, and step 4 no-ops.
- The RG sweep finds no estate resource groups in any of the five subscriptions (verified live
  2026-07-21: only the Terraform state RG plus service-created `NetworkWatcherRG`, plus non-estate RGs
  in the landingzones subscription, none of which match `contains(name,'globaris')` or
  `contains(name,'amba-monitoring')`).
- Databricks: no workspaces exist, so step 1 lists zero rows.
- Key Vault: no live estate vaults; the two soft-deleted vaults are purge-protected and are REPORTED,
  not purged.
- Step 6 is the only step that will actually do work.

**Must NOT be touched, and is not touched by any of the above.** Stated explicitly so the re-run cannot
be widened by mistake:
- **The Terraform state backend.** `rg-tfstate-mgmt-eus2-001` and its storage account do not match the
  RG sweep pattern and are outside the default teardown scope (`include_bootstrap` defaults false).
  The rebuild is impossible without them.
- **OIDC federation.** All five federated credentials on the app registration, including the
  `banking`-branch one the rebuild dispatches from. Teardown does not touch the app registration.
- **The bootstrap identity itself** (the service principal, its subscription-scope Contributor and
  User Access Administrator rows, its Storage Blob Data Contributor on the state account).
- **The ADR-041 temporary tenant-root grants** (User Access Administrator and Cost Management
  Contributor at Tenant Root Group). The rebuild still needs both. LESSON 57: revocation happens
  strictly after a verified-clean DESTROY of the estate that needed them, and the estate is about to be
  rebuilt, so these stay. Do not let a "teardown means revoke" reflex remove them.
- **Non-estate resources** in the landingzones and management subscriptions.

---

## 13. Completion is certified by an INDEPENDENT QA pass, not by Phase 3 (ADR-058)

> Added 2026-07-21 on a user ruling. This CHANGES section 2 design principle 5 and section 11's first
> acceptance criterion: a green Phase 3 is necessary, and is no longer sufficient.

### 13.1 Why Phase 3 alone was never enough

The 2026-07-20 teardown was reported GREEN on Phase 3 VERIFY alone. It was not green. VERIFY is a
script inside the same workflow that did the work, auditing essentially the surface Phase 2 had just
swept: resource groups by naming pattern, management groups, Databricks workspaces, Key Vaults. The 12
subscription-scoped survivors, the 8 armed pricing plans and the registered provider were not in that
surface, so VERIFY could not have found them however well it was written. **A self-check authored
from the sweeper's model of the estate cannot discover a class the sweeper never modelled.**

The deploy side already carries the correct rule (LESSON 60: apply-success is not green, QA-verified
is green). Teardown never inherited it. It does now.

### 13.2 Two gates, and why they are not redundant

| | Phase 3 VERIFY | qa-engineer pass |
|---|---|---|
| Role | the ACTOR's own conscience | the AUDITOR |
| Runs | inside the workflow, immediately, unwaited | out of band, after the run reaches a terminal state |
| Identity | the SCOPED teardown OIDC SP, whose MG-read grants die with the subtree it deletes (the whole reason the section 7 snapshot oracle exists) | a differently-scoped identity that can read scopes the teardown SP structurally cannot |
| Source of truth | what the sweeper models | a written checklist derived from what the ESTATE deploys |
| May conclude | "no remnant was found in the surface this workflow models" | "the estate is torn down", or "it is not, here is the remnant list" |
| May NEVER conclude | "the estate is torn down" | anything by inheriting VERIFY's result instead of querying live |

Both exist because they fail differently. VERIFY catches a remnant fast, inside the run, and makes the
run itself red so a broken teardown never exits 0. QA catches a remnant VERIFY was never built to see.
A green VERIFY is an INPUT to QA, never a substitute for it.

**Do not collapse them.** A future proposal to delete the QA pass because "VERIFY already checks that",
or to fold the QA checklist into VERIFY so there is "one gate", is rejected by ADR-058: the checklist
would then be authored and executed by the mechanism it is meant to audit, which is exactly the
2026-07-20 blind spot rebuilt.

### 13.3 The qa-engineer acceptance checklist

Run after the teardown workflow reaches a terminal state, green or red. Every line is a concrete query.
Record the result of each in the worklog. Any FAIL is a verdict of FAIL for the whole pass.

**A. Resource-group and management-group surface**
1. For each of the 5 subscriptions: `az group list --subscription <sub> --query "[?contains(name,'globaris') || contains(name,'amba-monitoring')].name" -o tsv` returns EMPTY.
2. `az account management-group list --query "[].name" -o tsv` returns ONLY the tenant root; none of the 11 globaris-tree names is present.
3. For each of the 5 subscriptions: `az databricks workspace list --subscription <sub> -o tsv` returns EMPTY.
4. Confirm all 5 subscriptions are parented directly to the tenant root and none has been deleted.

**B. The four subscription-scoped object classes (the 2026-07-20 blind spot)**
5. Budgets, per subscription: `az rest --method get --url ".../subscriptions/<sub>/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" --query "value[].name"` returns no estate-named row.
6. **Cost exports, per subscription, AT API VERSION `2025-03-01`**: `az rest --method get --url ".../subscriptions/<sub>/providers/Microsoft.CostManagement/exports?api-version=2025-03-01" --query "value[].name"` returns no estate-named row. **This version is mandatory.** ADR-027 creates these at `2025-03-01`; a GET at `2023-11-01` or `2024-08-01` returns them as ABSENT and reads as a false PASS. That exact false negative was recorded on 2026-07-16 as a SEVERE QA finding that turned out to be a probe error. Do not repeat it in the opposite direction.
7. Scheduled actions, per subscription: `az rest --method get --url ".../subscriptions/<sub>/providers/Microsoft.CostManagement/scheduledActions?api-version=2023-11-01" --query "value[].name"` returns no estate-named row.
8. Subscription diagnostic settings, per subscription: `az monitor diagnostic-settings subscription list --subscription <sub> --query "value[].name"` returns no estate-named row (the estate name is `diag-activity-to-security-law`).

**C. Subscription-level settings that must be RESET, not deleted**
9. Defender pricing, security subscription: `az rest --method get --url ".../subscriptions/<security-sub>/providers/Microsoft.Security/pricings?api-version=2024-01-01" --query "value[].{plan:name,tier:properties.pricingTier}" -o table`. Every one of the 8 estate-configured plans reads `Free`. Plans the estate does not configure are NOT asserted on, and must not have been changed.
10. Provider registration, management subscription: `az provider show --namespace Microsoft.CostManagementExports --subscription <management-sub> --query registrationState -o tsv` reads anything other than `Registered`. `Unregistering` is a PASS with a note.

**D. Things that must SURVIVE untouched (a teardown that destroys these has failed differently)**
11. State backend: the state resource group and its storage account still EXIST, provisioning `Succeeded`, firewall `defaultAction = Deny`, shared key access disabled. The rebuild is impossible without them.
12. OIDC federation: `az ad app federated-credential list --id <ci-app-id> --query "[].name"` still returns all five credentials, including the `banking`-branch one the rebuild dispatches from.
13. Bootstrap identity: the CI service principal still holds Contributor and User Access Administrator at each of the 5 subscriptions, and Storage Blob Data Contributor at the state storage account. Query per scope with an explicit `--scope` or an `atScope()` REST filter; the `--assignee --all` form under-reports and has produced wrong conclusions in this repo twice.
14. **ADR-041 temporary tenant-root grants**: User Access Administrator AND Cost Management Contributor at Tenant Root Group are STILL PRESENT on the CI SP. The rebuild needs both. A teardown that removed them is a FAIL, not a bonus.
15. Non-estate resources in the shared subscriptions are untouched.

**E. Soft-delete inventory (informational, feeds the rebuild)**
16. Record `az keyvault list-deleted` per subscription and `az monitor log-analytics workspace list-deleted-workspaces` per subscription, with delete dates, so the rebuild knows which names are reserved and whether a create will RECOVER or create fresh.

**F. Deferred evidence item - MG-scope budget cascade (raised by code review 2026-07-21, Finding 4)**

17. **CONDITIONAL, and it does not apply to the 2026-07-21 re-run.** `platform/management` creates 3 MG-scope budgets (`azurerm_consumption_budget_management_group`, at the globaris / platform / landingzones scopes). These are deliberately EXCLUDED from Phase 2 step 6, on the reasoning that they are extension resources on the management group and are removed when the MG itself is deleted in step 4. That reasoning is corroborated but **not directly proven**: Microsoft's documented MG-deletion prerequisites say nothing about extension resources, and the 2026-07-21 live re-audit found exactly 12 subscription-scoped survivors with no MG-scope budget among them, which is consistent with the cascade but was measured against an MG tree that was ALREADY gone. There was no live MG-scope budget left to test against, so the inference could not be converted to evidence this time.
    - **Trigger:** the next teardown that runs against an MG hierarchy which actually carries live MG-scope budgets, i.e. a teardown of a fully-deployed estate rather than a re-run against an already-empty one.
    - **What to do, IN THIS ORDER:** BEFORE dispatching, record the 3 budgets via `az rest --method get --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/<mg>/providers/Microsoft.Consumption/budgets?api-version=2023-05-01" --query "value[].name"` at each of the globaris, platform and landingzones scopes. AFTER the run, re-query the same three scopes.
    - **PASS:** the budgets are gone, and the MG itself is gone. Record the result so this item can be closed permanently and the exclusion becomes evidence-backed.
    - **FAIL:** any budget still resolvable after its MG is deleted, OR an MG delete that fails citing a child extension resource. Either outcome means the exclusion is wrong and MG-scope budgets must be added to step 6 as sub-step 6d, ordered BEFORE the step 4 MG removal (not after, because the scope disappears with the MG). Route to the architect as a contract gap per section 13.4.
    - Until this item is exercised once with a PASS, the exclusion stays flagged as inference, not fact. Do not let it be quietly inherited as settled.

### 13.4 Ordering and failure semantics

- The QA pass runs AFTER the workflow run reaches a terminal state, and it runs whether that state was
  green or red. A red run tells you something failed; it does not tell you what survived.
- QA does not reopen or edit the run. It produces a remnant list, classified per object:
  - a remnant in a class the teardown ALREADY covers means a targeted, idempotent re-dispatch of the
    same workflow, then a fresh QA pass;
  - a remnant in a class the teardown does NOT cover is a CONTRACT GAP. It goes to the architect for a
    design ruling and to DevSecOps for a change, before any re-dispatch. That is exactly what happened
    on 2026-07-21 and it is why this section exists.
- **Any QA verdict other than PASS BLOCKS the rebuild.** No deploy dispatch of any root may start while
  a teardown QA pass is outstanding or failed. This mirrors the pre-clearance gate on the deploy side.
- The verdict and the evidence are recorded in the worklog per class.

### 13.5 First application

The 2026-07-21 teardown re-run is the FIRST teardown held to this gate, and **its QA pass is the
artifact that clears the B0a rebuild to start.** A green workflow run is not the clearance. The
qa-engineer PASS against section 13.3 is.

---

## Appendix A. Audit trail / changelog (dated, run-numbered)

The mechanism above was reached through a chain of reactive patches. This appendix preserves that
history so it is not lost; it is NOT the design (sections 1 to 11 are). Runs are cited by number; no
GUIDs or subscription IDs.

- **2026-07-19 - original 4-phase design (ADR-054).** DISARM / DESTROY / AZ-SWEEP / VERIFY, fixing
  F1 to F4. Reviewer BLOCK correction the same day: the first implementation had DELETED the
  `synthetic` job and set `remove_mg_hierarchy` default `true`; both corrected - `synthetic` restored
  as a hardened Phase-1 root, `remove_mg_hierarchy` default `false`, and the guard `az-sweep`
  requires `target=all` rejection added.

- **2026-07-20 - defect 1: OIDC assertion expiry on long deletes (run 29712487341).** mode=az-sweep,
  remove_mg_hierarchy=true. DISARM and VERIFY were correct; Phase 2 exited 0 having deleted NOTHING.
  A synchronous Databricks workspace delete plus a 600s in-session poll drove one step to ~55 min;
  when the ~1h access token expired, az tried to refresh with the long-dead 5-min assertion and every
  call died AADSTS700024. Three swallow-the-error bugs turned the auth death into a silent exit 0.
  Fix: `--no-wait` submission pass + `az_relogin` + a bounded relogin-then-poll reconcile (section 4),
  plus the auth-fail-loud rule across all three scripts (section 6). This was the deferred OQ-022
  class manifesting in teardown.

- **2026-07-20 - defect 2 (parallel): Databricks managed RG no longer self-cleans.** MS "Delete a
  workspace" doc (ms.date 2026-07-08) confirmed a plain workspace delete RETAINS the managed RG. Fix:
  `--force-deletion` on the workspace delete, combined with `--no-wait` (section 5). Architect
  pre-clearance catch C1.

- **2026-07-20 - run 29749656053: token-durability fix HELD; a new VERIFY 1 false-positive.** The
  estate was fully, live-verifiably torn down (Databricks + both workload RGs + rg-amba-monitoring-001
  gone, all 11 globaris-tree MGs deleted, 0 policy assignments); Phase 2 completed in ~10 min with
  ZERO AADSTS. Only VERIFY 1 went red: a policy-assignment read on a just-deleted MG returns a 403,
  which the correct auth-fail-loud hardening over-caught. Diagnosed as needing an MG-existence gate in
  the MG-iterating loops.

- **2026-07-20 - SUPERSEDED interim oracle (ADR-054 point 11): per-MG `az account management-group
  show`.** Proposed gating each MG loop with `show`, expecting a clean 404 on a deleted MG. WRONG for
  the scoped SP.

- **2026-07-20 - defect 3: the `show` oracle was principal-dependent (attempt 4, run 29753193590;
  probe run 29756715840).** `show` returns a clean 404 only for a tenant-root-privileged principal;
  for the scoped SP (whose MG-read grants died with the globaris subtree) it returns a 403, so the
  point-11 gate failed loud at all four sites on benign gone MGs. Corrected oracle: the ONE-TIME
  `az account management-group list` snapshot (section 7), auth-fail-loud on the list call. The `show`
  oracle is superseded and must not be implemented. Interim points 7 to 12 in earlier revisions of
  this doc are folded into sections 3 to 7 above.

- **2026-07-20 - attempt 5, run 29765892057: GREEN E2E.** Confirm / DISARM / AZ-SWEEP / VERIFY all
  success against the already-empty estate; snapshot returns only the tenant root, DISARM and VERIFY 1
  skip every globaris-tree scope, step 4 no-ops, VERIFY 4 confirms every target MG absent, VERIFY
  2/3/5 clean. The design is proven.

- **2026-07-20 - consolidation pass (this document).** No behavior change. The reactive-patch
  narrative was rewritten into the single coherent design in sections 1 to 11; the class-A DISARM
  hardening (section 10.1) is specified for DevSecOps as the one residual item; the list-snapshot
  oracle is ruled the canonical design (ADR-054, OQ-048), not a workaround.

- **2026-07-21 - defect 4: the green teardown was not a complete teardown (ADR-057, sections 12 and
  13).** The B0a pre-clearance refresh for the rebuild found 21 deterministic, plan-invisible apply
  failures waiting in the two roots the teardown was supposed to have cleared. Cause, established by
  job-level inspection of the run history rather than inference: `terraform destroy` has not run for
  `platform/management` or `platform/security` since 2026-07-11. Run 29706565357 attempted Phase 1 and
  cascade-failed on `synthetic` and `identity`, skipping every downstream root; runs 29712487341,
  29749656053, 29753193590, 29765892057 and 29773408578 all ran `mode=az-sweep`, where Phase 1 root
  jobs are SKIPPED by design. The az sweep locates resources by RG naming pattern plus three explicit
  passes (Databricks, Key Vault, MG), so it never had, and never claimed, any coverage of
  subscription-scope objects. Nothing regressed inside the sweep; what regressed is that the mode
  which covers subscription scope for free (terraform-destroy, via the owning providers) stopped
  running while the design still called it PRIMARY. Survivors: 5 subscription budgets, 5 cost exports,
  1 cost anomaly scheduled action, 1 subscription diagnostic setting, 8 Defender pricing plans left at
  Standard, 1 provider registration left Registered - each colliding at create against a provider
  requires-import guard verified in azurerm v4.71.0 source. Fix: Phase 2 step 6 (section 12.3) plus
  VERIFY 6 to 8, and `mode=terraform` restored to real primary status by policy. RBAC verified GO with
  no new grant (section 12.4), including empirical proof that this same SP performed every one of these
  writes during the 2026-07-11 teardown.

- **2026-07-21 - governance change: teardown gains a mandatory independent QA gate (ADR-058, section
  13).** User ruling. The 2026-07-20 teardown was declared GREEN on Phase 3 VERIFY alone, and Phase 3
  structurally could not see any of defect 4's survivors, because it is a script inside the same
  workflow auditing the surface that workflow models. Teardown now inherits the deploy-side rule
  (LESSON 60): completion is certified by an independent qa-engineer pass against a written checklist
  (section 13.3), run out of band by a differently-scoped identity. Phase 3 is retained unchanged as
  the in-workflow fail-loud gate; the two are explicitly non-collapsible (section 13.2). Any QA verdict
  other than PASS blocks the rebuild. The 2026-07-21 re-run is the first teardown held to this gate and
  its QA pass is what clears the B0a rebuild to start.
