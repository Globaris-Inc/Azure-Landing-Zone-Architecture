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
in `mode=terraform`. Idempotent throughout; every delete is safe to re-run. Five ordered steps:

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
5. **Reconciliation** - ONE bounded wait (section 4) for every RG submitted in steps 1 to 2 to
   report gone. The wait lives HERE, never in VERIFY.

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
  section 3 Phase 2 step 5) calls `az_relogin` at the START of every iteration, so a poll can never
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
submission stays async; the actual cascade is what the reconcile step (section 3 Phase 2 step 5)
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
