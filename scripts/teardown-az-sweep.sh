#!/usr/bin/env bash
# scripts/teardown-az-sweep.sh - Phase 2 AZ SWEEP (ADR-054 / docs/teardown-redesign.md
# section 3). Fallback for the state-gone case (mode=az-sweep) AND a remnant-catch pass
# after Phase 1 terraform-destroy (mode=terraform). Idempotent throughout: every delete is
# safe to re-run - an absent target is success, not an error. Phase 3 VERIFY is the loud,
# authoritative completion gate (docs/teardown-redesign.md design principle 5).
#
# AMENDED 2026-07-20 (ADR-054 amendment, docs/teardown-redesign.md sections 9-10, teardown
# run 29712487341): the OIDC federated assertion `azure/login` consumes at job start is only
# valid inside GitHub's ~5-minute issuance window - once consumed, az's own token refresh has
# nothing live to refresh with, so any single step that runs longer than the resulting ~1h
# Azure access token dies with AADSTS700024. That previously happened here (a synchronous
# Databricks workspace delete + a 600s in-session poll drove one step to ~55 minutes) and three
# swallow-the-error bugs then turned the resulting auth death into a silent "nothing to do".
# Fixed by:
#   - Every delete in this script now fires --no-wait (submission only, never a synchronous
#     in-session long-poll on the token that submitted it).
#   - ONE bounded reconciliation wait at the very end (wait_for_rgs_gone, teardown-common.sh),
#     which calls az_relogin (a fresh OIDC assertion, teardown-common.sh) at the START of every
#     iteration, so the wait itself can never outlive its token.
#   - Every list/existence call that used to swallow errors with `2>/dev/null` or `|| true` now
#     captures stderr and classifies it with is_auth_error: a failed call is never read as
#     "empty / already gone / nothing to do" - see each step below for exactly how.
#
# AMENDED again 2026-07-20 (code-review BLOCK, Finding #2): every list call whose SUCCESS-path
# output feeds `mapfile` or a scalar comparison now uses `az_run` (teardown-common.sh) instead
# of a bare `2>&1` capture. The az CLI writes WARNING banners to stderr even on a clean exit-0
# call (update-available nags, "this command is from the following extension" advisories) - a
# merged capture could inject a bogus row into an otherwise-successful list result. `az_run`
# keeps stdout (the data channel) and stderr (only inspected on the non-zero-exit path) fully
# separate. Delete/remove/action submissions whose captured text is read ONLY on their own
# failure branch (never on a success path compare) are unaffected - there is no data-corruption
# risk there.
#
# AMENDED again 2026-07-20 (architect pre-clearance C1, stale-design-premise catch): ADR-054's
# F2 premise ("delete the workspace, the managed RG self-cleans") is out of date per the current
# MS "Delete a workspace" doc (updated 2026-07-08) - a workspace delete WITHOUT --force-deletion
# RETAINS the managed RG (DBFS storage account + access connector; Azure Databricks converts it
# to a regular RG instead of removing it). Step 1's workspace delete now passes --force-deletion
# alongside --no-wait. Verified compatible (not mutually exclusive, no synchronous-wait side
# effect) against the live `az databricks workspace delete` CLI reference
# (learn.microsoft.com/en-us/cli/azure/databricks/workspace) - both are listed as independent
# optional flags in the same command syntax block, in the same parameter group as everything
# else (no coupling/exclusivity note). --force-deletion does not change the async contract of
# --no-wait: the submission still returns immediately, and the actual cascade delete (workspace
# + managed RG + retained UC catalog data) is what the reconcile step (step 5) then waits for.
#
# AMENDED a third time 2026-07-20 (third amendment / ADR-054 point 12, docs/teardown-redesign.md
# section 12) - step 4's MG-existence check moved from a per-MG `az account management-group
# show` (a second-amendment / ADR-054 point 11 fix, SUPERSEDED) to a ONE-TIME `az account
# management-group list` snapshot. `show` is principal-dependent for the scoped teardown SP - its
# MG-read grants are scoped to the globaris subtree (identity.tf) and are deleted WITH it, so
# `show` on a deleted MG returns HTTP-403 `AuthorizationFailed` (not the clean 404 point-11
# assumed), which is_auth_error correctly matches, so a `show`-based skip failed loud on benign
# already-gone MGs (attempt 4, run 29753193590). Empirical proof (probe run 29756715840, run AS
# THE SP): `list` succeeds and returns only the tenant root; `show --name globaris` returns 403.
# See step 4's own comment below for the corrected mechanism (`mg_snapshot_load` /
# `mg_in_snapshot`, teardown-common.sh).
#
# AMENDED a fourth time 2026-07-21 (ADR-057, docs/teardown-redesign.md section 12.3): added
# step 6 - the four subscription-scoped object classes, the Defender for Cloud pricing reset
# to Free, and the Microsoft.CostManagementExports provider unregistration. Root cause: the az
# sweep finds things by RESOURCE GROUP naming pattern (steps 1-3) plus MG scope (step 4), and
# structurally cannot see anything that lives outside a resource group or a management group.
# It never claimed to. What actually regressed is that `terraform destroy` (mode=terraform,
# Phase 1) - which covers subscription scope for free, because the owning provider deletes
# what it created - had not run for platform/management or platform/security since 2026-07-11,
# while every teardown since then ran mode=az-sweep (Phase 1 skipped by design) and reported
# green. Step 6 makes the az sweep genuinely complete on its own, restoring the reliability
# az-sweep exists for (the state-gone/F4 case) without depending on mode=terraform actually
# having run. Full root-cause account: docs/teardown-redesign.md section 12.1.
#
# AMENDED a fifth time 2026-07-21 (ADR-062, docs/teardown-redesign.md section 14.2): added
# sub-step 6d - subscription-scoped policy exemptions. Root cause: `terraform destroy` and the
# original step 6 both remove a policy exemption only when its PARENT scope is removed (an
# exemption is a child object that cascades with its parent); a subscription-scoped exemption's
# parent is the subscription itself, which is never deleted (section 5), so it can never cascade
# away on its own no matter which teardown mode ran. The live proof:
# `exempt-dbx-managed-storage-bank-data-p1` (landing-zones/bank-data-p1/policy_exemptions.tf)
# survived both teardowns AND this same step 6 this morning, and blocks a later apply with
# azurerm 4.71.0's ImportAsExistsError. Its expires_on does not help either - Microsoft's
# documented behaviour is that an exemption is preserved for record-keeping past expiry, not
# deleted. Ownership is decided by `is_owned_policy_object` (teardown-common.sh) - a three-limb
# predicate shared with VERIFY 6d/9 (teardown-verify.sh) so the delete side and the verify side
# can never drift apart; see that function's own comment for the exact limbs and why a naive
# `contains(name,'globaris')` reuse would have shipped as a silent no-op.
#
# AMENDED a sixth time 2026-07-23 (teardown-completeness extension sweep - the 2026-07-23
# rebuild failed at Step 2 because scope-path-keyed extension resources - budgets, diagnostic
# settings, policy exemptions at MG/RG scope - are orphaned by az-sweep mode and collide the
# next time Step 1 recreates a same-named MG): added FIX-1 (step 4-pre, MG-scope budgets/diag/
# exemptions swept before any MG delete), FIX-2 (step 6a extended to MG + RG scope, budgets
# api-version bumped to 2024-08-01), FIX-3 (step 6d extended to RG-scoped policy exemptions,
# defense-in-depth after the step 2 RG sweep), FIX-4 (new step 6e - Microsoft.Security
# singletons: security contacts, automations, auto-provisioning/workspace settings), and FIX-5
# (new step 6f - the tenant Microsoft.AadIam/diagnosticSettings AAD diag, Security-Admin-gated,
# fails loud rather than silently passing on a 401). See teardown-common.sh's own "AMENDED a
# sixth time" comment for the shared API-version constants and discovery helpers, and each new
# step's own comment below for the exact root cause it closes.
#
# FIX-6 note: neither this script nor teardown-disarm.sh/teardown-verify.sh contain any
# reference to the tfstate container or to deleting a Terraform state blob (grep-confirmed
# 2026-07-23; independently confirmed by OPEN-QUESTIONS.md OQ-053's own investigation into two
# state blobs that went missing out-of-band). There is therefore no existing blob-delete code
# path in this script for FIX-6 to gate. See teardown-common.sh's "FIX-6 note" for the invariant
# any FUTURE blob-delete code must honour, and scripts/teardown-probe-state.sh for the read-only
# detection half this fix DOES add (OQ-053 option A(ii)).
#
# AMENDED a seventh time 2026-07-23 (ADR-063, the Phase-0 MG-scope sweep architect ruling that
# followed the teardown-completeness extension sweep above): four changes.
#   - New step 2-pre (decision 5): resource-scoped diagnostic settings, swept AFTER step 1 and
#     BEFORE step 2 submits its --no-wait RG deletes - this class had NO sweep anywhere before
#     today (RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION was referenced only by the read-only probe,
#     scripts/teardown-probe-extensions.sh, whose enumeration shape this step reuses). Root
#     cause: diag-aa-to-law (platform/management/main.tf:493) is a resourceUri-keyed extension
#     resource that does NOT cascade away when its host resource is deleted (the same G-1
#     invariant as every other class in this fix) - it is what the 2026-07-23 rebuild collided on
#     at Step 2 ("already exists - needs to be imported").
#   - FIX-1 (step 4-pre) is DEMOTED from primary mechanism to a last-chance gate (decision 4): the
#     Phase-0 sweep in teardown-disarm.sh is now the primary MG-scope sweep, reachable in BOTH
#     teardown modes (FIX-1 here is reachable only when remove_mg_hierarchy=true AND, on
#     mode=terraform, only after Phase 1 has already deleted the MGs it would need to read - see
#     ADR-063's own root-cause account). Any survivor FIX-1 still finds now ABORTS the entire step
#     4 MG delete loop under the TEARDOWN-P0MG-SURVIVOR label and leaves the MG tree standing,
#     rather than warn-and-continue - see FIX-1's own comment below.
#   - FIX-1, FIX-2 and FIX-4 are rewired onto the shared T1/T2/T3 is_estate_owned predicate
#     (ADR-063 decision 6, teardown-common.sh) in place of their prior per-row name filters - see
#     each site's own comment for what changed and why the old filter is now redundant rather
#     than removed for its own sake.
#   - FIX-4(i)'s stale comment claiming the securityContacts API "allows" this estate's custom
#     name is corrected (ADR-063 decision 7): it does not - the live object is always named
#     "default", pinned by the API's own name-pattern constraint, regardless of what this
#     estate's Terraform configures.
#
# AMENDED an eighth time 2026-07-29 (ADR-064): the Phase 2 `6a (MG portion)` MG-scope
# consumption-budget re-sweep that the sixth amendment's FIX-2 added is REMOVED. It was the only
# step anywhere in this script that read or wrote an MG scope AFTER the step-4 delete loop
# (line ~664) could have deleted that scope in the same job - exactly the one-way door ADR-063's
# G-1 forbids - and it was fully redundant with Phase 0 DISARM's MG-scope sweep
# (teardown-disarm.sh), which covers every MG in MG_SCOPES pre-deletion in both teardown modes.
# Live teardown run 30476963087 crashed on it (403 RBACAccessDenied listing budgets at the
# just-deleted `connectivity` MG, section 9.4 correctly failing loud on the auth-shaped error),
# which aborted step 6 before 6c (RP unregister) and 6e (securityContacts) ever ran. See ADR-064
# in DECISIONS.md for the full analysis and the governing invariant it adds: no teardown step
# may read or write an MG scope after that MG could have been deleted in the same job. FIX-2's
# RG-scope budget sweep (the 6a RG portion, inside the subscription loop above) is UNCHANGED by
# this amendment - it stays RG-scoped, never touches an MG, and remains backstopped by VERIFY 6.
#
# FIX-7 note (documentation only, NO teardown code change - this is a RERUN-side guard for
# platform/identity, not a teardown responsibility): on any rerun after a partial teardown or a
# state-gone az-sweep, platform/identity MUST probe whether an Azure AD Domain Services managed
# domain already exists (scripts/teardown-probe-extensions.sh's AADDS section, report-only,
# Microsoft.AAD/domainServices) BEFORE applying, and if one is found, IMPORT it rather than let
# Terraform attempt to create a new one. The import mechanism already exists and needs no new
# code: `TF_VAR_aadds_import_replica_set_id` (platform/identity/variables.tf,
# .github/workflows/_tf-root.yml) feeds an existing `import` block whose `for_each` is inert
# (empty) when the variable is unset - see _tf-root.yml's own comment on that variable (ADR-029
# recovery, REINSTATED for the ADR-055 greenfield two-pass) for the full mechanism. AADDS
# deletion is intentionally never attempted by any teardown script (report-only everywhere) -
# Microsoft's own guidance treats AADDS delete/recreate as slow and disruptive; import is the
# correct rerun path, not a new delete capability.
#
# AMENDED a ninth time 2026-07-29 (ADR-066, folds in OQ-063): teardown.yml now re-enables and
# SERIALIZES all 11 Phase 1 per-root terraform destroy jobs at target=all (supersedes ADR-065
# decision 1), so THIS script is now typically a THIN REMNANT-CATCH BELT in the mode=terraform
# path - the bulk of the estate is already gone by the time this job starts. It remains the
# PRIMARY, full-coverage whole-estate deleter, UNCHANGED, in the mode=az-sweep state-gone
# fallback path (ADR-065 decision 4, kept) - nothing in this script's own logic needed to
# change for that role split; it is a consequence of Phase 1 now running, not a code change
# here.
#
# AMENDED a tenth time 2026-07-30 (code-review BLOCK on the ADR-066 implementation, Findings 1
# and 2 - closes both):
#   - Finding 1: the Security LAW purge step (added the day before as "step 3b", immediately
#     after step 3's Key Vault handling) is MOVED to run AFTER step 7's reconcile (now "step
#     7b", at the bottom of this script) - see that step's own comment for the exact race it
#     closes (running before step 7 could observe the security RG/workspace mid-delete, before
#     it had actually landed in soft-delete, and silently no-op). It is ALSO now correctly
#     framed as a BACKSTOP, not the primary purge mechanism: `platform/security/providers.tf`
#     now sets `permanently_delete_on_destroy = true` on the LAW (Cloud Engineer fix, same
#     pass), so the mode=terraform path purges the LAW NATIVELY via terraform destroy and this
#     step finds nothing to do there. It remains the PRIMARY mechanism for mode=az-sweep (which
#     never runs terraform destroy at all) and a backstop for any older `platform/security`
#     state applied before the provider fix.
#   - Finding 2: `enable_data_platform = true` is the LIVE setting (envs/poc.tfvars) - the
#     Databricks orphan-managed-RG gap this file's prior "AMENDED a ninth time" note called
#     "not yet load-bearing" IS load-bearing. ADR-066 decision 4's PREFERRED fix (move the
#     workspace force-delete cascade to a Phase 0.5 belt that runs BEFORE Phase 1, alongside
#     Phase 0 DISARM, so it acts while the workspace is still live) is now IMPLEMENTED as
#     `scripts/teardown-databricks-precascade.sh`, wired into teardown.yml as a new
#     `databricks-precascade` job gated identically to DISARM plus `mode == 'terraform'` (the
#     mode=az-sweep path never needs it - Phase 1 does not run there, and THIS script's own
#     step 1 below already force-deletes the workspace first in that path, unchanged). Step 1
#     below is UNCHANGED code (still force-deletes any Databricks workspace it finds) and now
#     shares its core az invocation with the new Phase 0.5 script via
#     `databricks_force_delete_cascade` (teardown-common.sh) so the two call sites cannot drift.
#     In the mode=terraform + target=all path, step 1 below is now a genuine no-op belt (the
#     Phase 0.5 job already cascaded the workspace + managed RG before Phase 1's bank-data-p1
#     destroy ever ran) - this is a consequence of the new job, not a change to this step.
#
# AMENDED an eleventh time 2026-07-30 (two independent, unrelated fixes proven by live runs the
# same evening - batched together since both touch this one file):
#   - Transient-list-failure fix: run 30597640251 died at step 4-pre on a single ARM 500 on an
#     MG-scope budget LIST call (the identical call succeeded on the immediate rerun,
#     30598510031, confirming it was transient). Every LIST/GET call in this script that fed
#     `az_run` now feeds `az_run_retry` instead (teardown-common.sh - see that function's own
#     comment and this file's "AMENDED an eighth time" analogue in teardown-common.sh for the
#     full mechanism): a bounded retry (3 attempts, ~10s apart by default) fires ONLY for a
#     transient HTTP 5xx/429 that is NOT also auth-shaped, and NEVER for a DELETE/write - the
#     fail-loud rule (section 9.4) is unchanged, this only adds a chance to recover from a
#     genuine server blip before that rule fires. Same drop-in signature as `az_run`, so no
#     call-site logic below changed beyond the function name.
#   - Key Vault purge-protection guard, dead since it was written: step 3's
#     `properties.purgeProtectionEnabled` TSV field is a ROW value (queried alongside name/
#     location, not a bare scalar), so Azure CLI's TSV formatter renders it capitalized ("True"),
#     not lowercase - live-verified against a standalone `knack` TSV-formatter harness this fix
#     round (a bare scalar boolean DOES render lowercase, e.g. `az group exists -o tsv`
#     elsewhere in this script and in teardown-common.sh, which is why those sites were never
#     affected). The `[ "$dkv_pp" = "true" ]` compare therefore never matched, and every
#     purge-protected vault silently took the "not purge-protected" branch - confirmed live by
#     QA via raw REST (all four `kv-sec-globaris-*` vaults have `purgeProtectionEnabled: true`)
#     and by three consecutive teardown runs logging "Purging (not purge-protected)" followed by
#     `MethodNotAllowed: Operation 'DeletedVaultPurge' is not allowed` for every vault - only
#     Azure's own server-side enforcement was ever preventing a wrong purge. Fixed by
#     lowercasing the captured value before the compare (`${dkv_pp,,}`, bash parameter expansion
#     - ubuntu-latest ships bash 5, same assumption this codebase already makes elsewhere) rather
#     than switching this call to JSON output: keeps the existing TSV+`cut -f`+`az_run_retry` row
#     convention every other list in this script already uses, no new parsing shape introduced
#     for one field. Grepped the rest of this codebase for the same class (an Azure CLI TSV
#     boolean compared against a lowercase literal) - the two other row-embedded-boolean sites
#     (teardown-verify.sh VERIFY 5's own `purgeProtectionEnabled` column, and this repo's
#     `properties.autoProvision` queries) are print-only or a string enum, not a broken compare;
#     every OTHER lowercase-literal compare in the teardown scripts (`group exists -o tsv`, a
#     bare scalar) is a `jq`-parsed JSON boolean or a workflow input string, neither of which
#     goes through the Azure CLI TSV formatter at all - see the WORKLOG entry for this fix round
#     for the full site-by-site accounting.
#
# AMENDED a twelfth time 2026-08-01 (ADR-073 decision 4, generalises OQ-063/ADR-066 - resolves
# OQ-069): step 7b is REWRITTEN from a single-hardcoded-name purge of the Security LAW into a
# DISCOVERY-based sweep across every estate subscription (teardown_subscriptions), gated by the
# is_estate_owned --resource-id containment predicate (gate A) and a blast-radius cap (gate B,
# LAW_PURGE_BLAST_RADIUS_CAP, teardown-common.sh). Root cause this generalisation closes: live
# evidence found a SECOND soft-deleted-workspace class member the old single-name filter
# structurally could not reach - two entries in the management subscription, both named
# law-platform-globaris-poc, sharing ONE ARM resource ID because region is not part of a Log
# Analytics workspace's ARM identity (ADR-073's own context). Also fixes two real defects in the
# PRIOR version of this step, both load-bearing once two entries can share an ID:
#   - Gate C (recover): `az monitor log-analytics workspace recover` takes only --workspace-name
#     and --resource-group - verified live against the current CLI reference 2026-08-01, it has
#     NO --location parameter at all, so it cannot select between two entries that share an ARM
#     ID. The recover call is now a REST PUT via `az rest` carrying an explicit `location` in the
#     body (Microsoft's own "Delete and Recover a Log Analytics Workspace" doc documents recovery
#     as exactly this PUT, `{"location": "<AzureRegion>"}`, at LAW_PURGE_API_VERSION).
#   - Gate D (completion check): the prior confirm-GET was `confirm_gone_or_fail_primary` against
#     an ARM GET keyed on the ARM ID ALONE, so purging one of two same-ID entries made that GET
#     404 while the other was still soft-deleted - a FALSE "purged" confirmation. Replaced with a
#     `deletedWorkspaces` RE-LIST keyed on the pair (id, location) - see `law_confirm_purged`
#     below.
# Purge cycles for entries that share an ARM ID are STRICTLY SEQUENTIAL (recover, permanently
# delete, and re-list-confirm one entry fully before the next cycle starts) - after recovering
# entry A a LIVE workspace occupies the shared ID, so a recovery PUT for entry B before A is
# fully purged would be an immutable-location change on an existing resource, which ARM rejects.
# This codebase processes the whole eligible list in one single-threaded loop, so this ordering
# holds structurally, not by a same-ID detection heuristic. Placeholder resource groups are now
# created and torn down PER CYCLE (never assumed shared across cycles, even same-ID ones) and
# this step WAITS (wait_for_rgs_gone) for each placeholder's delete to be confirmed gone before
# the next cycle starts, rather than firing the delete --no-wait and moving on the way the old
# single-entry version did - ADR-073 permits reusing one placeholder RG across same-ID cycles
# only after that is verified live in a run log, which has not happened yet, so this takes the
# conservative fallback the ADR names instead of assuming it. Known, deliberately-accepted
# residual risk (not closed in this pass): the recovery PUT is a raw `az rest` call and does not
# poll the recovered resource's `provisioningState` the way the CLI's own `recover` verb's
# default behaviour (called without `--no-wait`) would have - see the step's own comment for why
# this is accepted rather than solved here.
#
# Order matters:
#   1. Databricks: submit the WORKSPACE delete --no-wait --force-deletion (never `az group
#      delete` the managed RG directly - it still carries an RP deny-assignment, F2, even with
#      --force-deletion in play; --force-deletion is what makes the WORKSPACE delete itself
#      cascade the managed RG cleanup instead of retaining it). The managed RG name is captured
#      here and waited on in the single reconcile step at the end, not polled in-line. In the
#      mode=terraform + target=all path this is now typically a no-op (the Phase 0.5
#      `databricks-precascade` job, teardown.yml, already force-deleted the workspace before
#      Phase 1 ran) - kept unchanged so mode=az-sweep (which has no Phase 0.5 job) still gets a
#      first, live-workspace force-delete pass here.
#   2. General RG sweep by naming pattern across all 5 workload/platform subscriptions,
#      excluding any Databricks-managed RG captured in step 1 (a direct delete on those is
#      doomed by the RP deny-assignment and pure noise - they cascade from step 1 instead).
#   3. Key Vault: soft-delete triggers automatically on any deletion path (direct or via
#      step 1/2's cascade), so this step deletes any live vault the sweep pattern still
#      finds (belt, in case of a race with step 2's --no-wait), then purges non-purge-
#      protected soft-deleted vaults and records purge-protected ones for the redeploy
#      runbook (LESSON 56).
#   4. Management-group hierarchy removal - ONLY if remove_mg_hierarchy=true. Bottom-up:
#      move each MG's subscriptions to the tenant root, then delete the now-empty MG.
#      Subscriptions are never deleted, only re-parented (docs/teardown-redesign.md
#      section 5). MG ops are fast control-plane calls and stay synchronous (no --no-wait,
#      no reconcile wait needed for MGs, per locked decision 9.3).
#   6. Subscription scope: 6a (ADR-057, docs/teardown-redesign.md section 12.3) the four
#      subscription-scoped object classes (budgets, cost exports at api-version 2025-03-01,
#      cost anomaly scheduled actions, subscription diagnostic settings) across all 5 subs; 6d
#      (ADR-062, section 14.2, ordered immediately after 6a) subscription-scoped policy
#      exemptions at exact scope, matched against the is_owned_policy_object predicate
#      (teardown-common.sh); 6b the Defender for Cloud pricing reset to Free from the
#      DEFENDER_PLANS_TO_FREE allow-list (security subscription only, teardown-common.sh); and
#      6c the RP_NAMESPACES_TO_UNREGISTER provider unregistration (management subscription
#      only, strictly after the object-class deletes). Runs after step 4 and before step 7 so
#      nothing here races a live MG-scope remediation and step 6's own submissions are covered
#      by the existing reconcile + Phase 3.
#   7. Reconciliation: ONE bounded wait for every RG submitted in steps 1-2 to report gone.
#      Step 6's writes are synchronous sub-second control-plane calls, not RGs - they are
#      deliberately NOT added to this wait (wait_for_rgs_gone is RG-shaped); Phase 3 VERIFY
#      (VERIFY 6-8) and the QA pass are their completion gate instead.
#   7b. Log Analytics workspace soft-delete purge (ADR-073 decision 4, generalises OQ-063/
#      ADR-066 - see "AMENDED a twelfth time" above and the step's own comment). Runs AFTER step
#      7's reconcile, same reasoning as before: every submitted RG delete (including any
#      LAW-owning root's) needs its bounded wait to actually land before this step goes looking
#      for a soft-delete. DISCOVERS soft-deleted workspaces across every estate subscription (no
#      hardcoded name), gated by containment (is_estate_owned --resource-id) and a blast-radius
#      cap (LAW_PURGE_BLAST_RADIUS_CAP, teardown-common.sh), then recovers (REST PUT with an
#      explicit location body) and permanently purges each eligible entry in strict sequence so
#      the next redeploy creates genuinely fresh workspaces instead of recovering ones with stale
#      children. Idempotent (nothing found is success). See the step's own comment for the full
#      mechanism.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

REMOVE_MG_HIERARCHY="${REMOVE_MG_HIERARCHY:-false}"

# ARM_BASE is sourced from teardown-common.sh (single shared declaration) - no local
# declaration here. Every step below (4-pre, 6a, 6d, 6e, 6f) shares that one value.

# _is_authz_denied_design_gap "<error text>" - precise RBAC-denial discriminator used ONLY at the
# MG-scope diagnostic-setting DELETE failure branch in step 4-pre below (ADR-063 decision 1d /
# OQ-059(b)). IDENTICAL function body to the copy in teardown-disarm.sh (Phase 0's mirror of this
# same check) - the two must never drift, so if this is ever edited, edit both. Matches ONLY the
# literal ARM error code `AuthorizationFailed` and the two RBAC-denial phrases Microsoft's own RBAC
# troubleshooting reference shows verbatim
# (learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting, "Symptom - Unable to
# assign a role" / "Symptom - Authorization failed", fetched live 2026-07-23): "...does not have
# authorization or an ABAC condition not fulfilled to perform action '...' ... please refresh your
# credentials." and the short form "...(code: AuthorizationFailed)". Deliberately does NOT match
# bare `403` or bare `Forbidden` - that is what made the previous version of this check collide
# with `is_auth_error` (which matches bare `credential`/`401`/`403`), since Azure's own
# AuthorizationFailed message always ends with the "refresh your credentials" boilerplate.
# `AuthorizationFailed` is ARM's AUTHORIZATION-layer error code, returned only for an authenticated
# principal that lacks the needed action at the target scope; a dead/expired token fails at the
# separate AUTHENTICATION layer (AAD/Entra token validation - AADSTS7xxxxx,
# ExpiredAuthenticationToken, "valid time range", "not within") BEFORE ARM ever evaluates
# authorization, so it structurally cannot produce this code or either phrase - the two shapes are
# mutually exclusive by Azure's own request pipeline, not just empirically distinct today. This is
# why checking this FIRST (ahead of the broad `is_auth_error`) at its one call site is safe and
# does not reopen the codebase's general auth-fail-loud rule: nothing a dead token can say matches
# this pattern. `is_auth_error` itself is untouched and keeps its normal broad role everywhere
# else, including as the SECOND check at that same call site. Proved against realistic verbatim
# strings in a standalone harness before being wired in (see the WORKLOG entry for this fix
# round).
_is_authz_denied_design_gap() {
  printf '%s' "${1:-}" | grep -qiE 'AuthorizationFailed|does not have authorization|ABAC condition'
}

mapfile -t SUBS < <(teardown_subscriptions)
if [ "${#SUBS[@]}" -eq 0 ]; then
  echo "::error::No subscription IDs available (MANAGEMENT_SUBSCRIPTION_ID / CONNECTIVITY_SUBSCRIPTION_ID / IDENTITY_SUBSCRIPTION_ID / SECURITY_SUBSCRIPTION_ID / LANDINGZONES_SUBSCRIPTION_ID all empty). Cannot sweep."
  exit 1
fi

# --- 1. Databricks: submit the workspace delete --no-wait --force-deletion (never wait
#     in-session, section 9.2a; --force-deletion is required to cascade the managed RG at all,
#     architect pre-clearance C1 - see the header comment above) ---
# `enable_data_platform = true` is the LIVE setting (envs/poc.tfvars) - Databricks IS deployed
# in this estate. In the mode=terraform + target=all path this step is now typically a no-op
# belt: the new Phase 0.5 `databricks-precascade` job (teardown.yml) already force-deleted the
# workspace (and started the managed-RG cascade) BEFORE Phase 1's bank-data-p1 terraform destroy
# ran, per ADR-066 decision 4's preferred form (code-review Finding 2, 2026-07-30) - so this
# list below typically finds nothing. It remains the PRIMARY, load-bearing mechanism for
# mode=az-sweep (no Phase 0.5 job runs there; Phase 1 does not run at all in that path, so the
# workspace is still live when this step executes). Logic unchanged from before this fix; now
# shared with the Phase 0.5 belt via `databricks_force_delete_cascade` (teardown-common.sh) so
# the two call sites cannot drift on the exact az invocation.
echo "== Phase 2 step 1: Databricks workspace cascade (submission only, --no-wait --force-deletion) =="
declare -a dbx_managed_rgs=()
declare -a dbx_managed_rg_subs=()
if ! databricks_force_delete_cascade dbx_managed_rgs dbx_managed_rg_subs; then
  exit 1
fi

# --- 2-pre. Resource-scoped diagnostic settings, swept BEFORE step 2 below submits its
#     --no-wait RG deletes (ADR-063 decision 5, 2026-07-23). This class had no sweep anywhere in
#     this codebase before today - RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION was referenced only
#     by the read-only probe (scripts/teardown-probe-extensions.sh), whose enumeration shape this
#     step reuses (discover_live_rgs -> az resource list per RG -> diagnosticSettings GET per
#     resource id). G-1 (ADR-063): a resource-scoped diagnostic setting is an extension object
#     keyed to its host resource's URI, and does NOT reliably cascade away just because the host
#     resource is later deleted by step 2's RG delete - the live proof is diag-aa-to-law
#     (platform/management/main.tf:493, on the platform automation account inside
#     rg-management-globaris-poc), which is what the 2026-07-23 rebuild collided on at Step 2
#     ("already exists - needs to be imported") despite both the RG and the automation account
#     having been deleted by an earlier teardown. Ownership is T1(c) containment
#     (is_estate_owned --resource-id, teardown-common.sh, ADR-063 decision 6): the resource lives
#     inside an RG discover_live_rgs already filtered to RG_SWEEP_QUERY, so every row found here
#     is owned by definition - called explicitly below anyway (never hardcoded true) so this site
#     can never silently drift from the shared predicate.
#
#     No separate Phase 3 VERIFY step exists for this class (by the time VERIFY runs, the
#     resource and its RG are expected to be fully gone via step 2's own cascade, and there is
#     no other class-specific completion gate for it) - this delete's own confirm-GET is
#     therefore the ONLY completion check this class will ever get, same PRIMARY-evidence
#     rationale FIX-1's MG-scope confirm-GETs already use (confirm_gone_or_fail_primary,
#     teardown-common.sh).
#
#     List-call failure handling differs from every other list in this script: a resource-scoped
#     diagnostic-settings GET can legitimately 404/BadRequest for a resource TYPE that does not
#     support diagnostic settings at all (most do; some do not, per the probe's own established
#     precedent) - only an auth-shaped failure fails loud here; any other failure is expected
#     noise and is skipped, not treated as "no diagnostic settings" for a class that never existed
#     at all.
#     EXTRACTED 2026-08-01 (ADR-071 decision 4b) into `sweep_resource_diagnostic_settings`
#     (teardown-common.sh). The body moved verbatim - same api-version, same containment
#     predicate, same auth-shaped-failure-only loud branch, same confirm-GET - so this site's
#     behaviour is unchanged. It is shared because Phase 0.5 (teardown-diagnostic-precascade.sh)
#     is now a SECOND caller, and the two must not drift. This step STAYS: it is the belt for the
#     mode=az-sweep path (where Phase 0.5 is deliberately not wired, because Phase 1 never runs
#     there and this step already executes while hosts are live) and the backstop for anything
#     Phase 0.5 missed. Removing it would trade one gap for another.
echo "== Phase 2 step 2-pre: resource-scoped diagnostic settings (before RG deletes are submitted) =="
sweep_resource_diagnostic_settings || exit 1

# --- 2. General RG sweep by naming pattern, across all 5 subs (--no-wait submission). The
#     Databricks-managed RG is STILL excluded here even with --force-deletion in step 1: it
#     still carries the RP deny-assignment (F2) until the workspace's own force-delete cascade
#     completes, so a concurrent direct `az group delete` on it would race that cascade and is
#     doomed either way - the reconcile step (step 7) is what waits for it to actually clear.
#
#     NOTE (code-review Finding 2, 2026-07-30): the exclusion list below (dbx_managed_rgs/
#     dbx_managed_rg_subs) is populated only by THIS job's own step 1 - it does not know about
#     the Databricks managed RG the separate Phase 0.5 `databricks-precascade` job (teardown.yml)
#     may have already force-deleted in an earlier job. That is fine in the common case: the
#     Phase 0.5 cascade has an entire Phase 1 chain's worth of wall-clock time to complete before
#     this Phase 2 job even starts, so step 1 above almost always finds the workspace already
#     gone and this exclusion list stays empty by design. The narrow residual (the managed RG's
#     own cascade still mid-flight when this step runs) is not tracked further here - VERIFY 2's
#     RG naming-pattern scan is the backstop for any remnant, and an idempotent re-dispatch is
#     the safety net, matching every other advisory residual already documented in this script. ---
echo "== Phase 2 step 2: RG sweep (naming pattern, --no-wait submission) =="
declare -a deleted_rgs=()
declare -a deleted_subs=()
for sub in "${SUBS[@]}"; do
  if ! az_run_retry rgs_out group list --subscription "$sub" --query "$RG_SWEEP_QUERY" -o tsv; then
    echo "::error::RG list failed for subscription ${sub} - a failed list is never read as 'no RGs' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # rgs_out is assigned indirectly by az_run's printf -v
  mapfile -t rgs <<< "$rgs_out"
  for rg in "${rgs[@]:-}"; do
    [ -z "$rg" ] && continue
    is_managed=0
    for i in "${!dbx_managed_rgs[@]}"; do
      if [ "${dbx_managed_rgs[$i]}" = "$rg" ] && [ "${dbx_managed_rg_subs[$i]}" = "$sub" ]; then
        is_managed=1
        break
      fi
    done
    if [ "$is_managed" -eq 1 ]; then
      echo "  Skipping ${rg} (sub ${sub}) - a Databricks-managed RG, already cascading from the step 1 workspace delete; a direct delete is doomed by the RP deny-assignment and is pure noise."
      continue
    fi
    echo "  Submitting delete for RG ${rg} (sub ${sub}, --no-wait)"
    # 2026-07-20 auth-fail-loud sweep (docs/teardown-redesign.md section 10.2, class B,
    # coherence only - matches the Databricks workspace delete's classification above). Backstop
    # either way: rg is still appended to deleted_rgs/deleted_subs below, so the reconcile step
    # (az_relogin re-auths) and VERIFY 2 catch any true remnant even on a non-auth failure here.
    if ! rg_del_out="$(az group delete --name "$rg" --subscription "$sub" --yes --no-wait --output none 2>&1)"; then
      if is_auth_error "$rg_del_out"; then
        echo "::error::RG delete submission for ${rg} (sub ${sub}) failed with an auth/transport error: ${rg_del_out}"
        exit 1
      fi
      echo "  ::warning::delete request for ${rg} failed (continuing - idempotent retry on next run): ${rg_del_out}"
    fi
    deleted_rgs+=("$rg")
    deleted_subs+=("$sub")
  done
done

# --- 3. Key Vault: delete any live match (belt), then purge non-purge-protected soft-deletes ---
echo "== Phase 2 step 3: Key Vault soft-delete / purge =="
KV_QUERY="[?contains(resourceGroup,'globaris') || contains(resourceGroup,'amba-monitoring')].[name,resourceGroup]"
for sub in "${SUBS[@]}"; do
  if ! az_run_retry kv_rows_out keyvault list --subscription "$sub" --query "$KV_QUERY" -o tsv; then
    echo "::error::Key Vault list failed for subscription ${sub} - a failed list is never read as 'no vaults' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # kv_rows_out is assigned indirectly by az_run's printf -v
  mapfile -t kv_rows <<< "$kv_rows_out"
  for row in "${kv_rows[@]:-}"; do
    [ -z "$row" ] && continue
    kv_name="$(printf '%s' "$row" | cut -f1)"
    kv_rg="$(printf '%s' "$row" | cut -f2)"
    echo "  Deleting live Key Vault ${kv_name} (rg ${kv_rg}, sub ${sub}) - soft-deletes"
    # 2026-07-20 auth-fail-loud sweep (docs/teardown-redesign.md section 10.2, class B,
    # coherence only). Backstop: reconcile + VERIFY 2/5 catch any true remnant either way.
    if ! kv_del_out="$(az keyvault delete --name "$kv_name" --resource-group "$kv_rg" --subscription "$sub" --output none 2>&1)"; then
      if is_auth_error "$kv_del_out"; then
        echo "::error::Key Vault delete for ${kv_name} (sub ${sub}) failed with an auth/transport error: ${kv_del_out}"
        exit 1
      fi
      echo "  ::warning::delete for KV ${kv_name} failed or already gone (continuing): ${kv_del_out}"
    fi
  done

  if ! az_run_retry deleted_kvs_out keyvault list-deleted --subscription "$sub" \
      --query "[].[name, properties.location, properties.purgeProtectionEnabled]" -o tsv; then
    echo "::error::Key Vault list-deleted failed for subscription ${sub} - a failed list is never read as 'no soft-deleted vaults' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # deleted_kvs_out is assigned indirectly by az_run's printf -v
  mapfile -t deleted_kvs <<< "$deleted_kvs_out"
  for row in "${deleted_kvs[@]:-}"; do
    [ -z "$row" ] && continue
    dkv_name="$(printf '%s' "$row" | cut -f1)"
    dkv_loc="$(printf '%s' "$row" | cut -f2)"
    # Azure CLI's TSV formatter renders a ROW-embedded boolean (this field is queried alongside
    # name/location, not a bare scalar) capitalized - "True"/"False", Python's own str(bool) -
    # never lowercase "true"/"false" (2026-07-30 fix round, live-verified against a standalone
    # `knack` TSV-formatter harness; see this file's "AMENDED an eleventh time" header note for
    # the full account and the live evidence this was NEVER firing). Lowercase the captured value
    # before comparing rather than changing the compare's literal, so the fix is visible at the
    # read site, not buried in a case-insensitive literal a future reader could miss.
    #
    # The extraction below is NOT redundant with the lowercasing: an earlier draft of this fix
    # deleted it and left only the `${dkv_pp,,}` line, which under this script's `set -u`
    # (line 284) is a fatal unbound-variable abort, not a silent misread. With four
    # purge-protected vaults currently soft-deleted in the tenant that loop body is guaranteed
    # to execute, so it would have killed the whole sweep at step 3 - before the MG-scope gate,
    # the subscription sweep, VERIFY and the ADR-068 Phase 4 state reset. Caught at the
    # code-review gate. Keep both lines.
    dkv_pp="$(printf '%s' "$row" | cut -f3)"
    dkv_pp="${dkv_pp,,}"
    if [ "$dkv_pp" = "true" ]; then
      echo "  PURGE-PROTECTED (retention applies, cannot purge): ${dkv_name} (${dkv_loc}, sub ${sub}). Redeploy must set recover_soft_deleted_key_vaults=true (LESSON 56) or use a fresh name."
    else
      echo "  Purging (not purge-protected): ${dkv_name} (${dkv_loc}, sub ${sub})"
      # 2026-07-20 auth-fail-loud sweep (docs/teardown-redesign.md section 10.2, class B,
      # coherence only). Backstop: VERIFY 5 lists soft-deleted vaults and fails loud on an
      # auth error there too, so this never false-greens either way.
      if ! kv_purge_out="$(az keyvault purge --name "$dkv_name" --location "$dkv_loc" --subscription "$sub" --output none 2>&1)"; then
        if is_auth_error "$kv_purge_out"; then
          echo "::error::Key Vault purge for ${dkv_name} (sub ${sub}) failed with an auth/transport error: ${kv_purge_out}"
          exit 1
        fi
        echo "  ::warning::purge for ${dkv_name} failed (continuing - Phase 3 will report if it still blocks a name): ${kv_purge_out}"
      fi
    fi
  done
done

# NOTE (code-review Finding 1, 2026-07-30): the Security LAW purge that used to live HERE as
# step 3b has been MOVED to run after step 7's reconcile (see the bottom of this script, "step
# 7b"). Root cause of the move: step 2 above submits the security RG delete with --no-wait; in
# mode=az-sweep (the state-gone fallback, where this script is the PRIMARY whole-estate
# deleter) the ONLY bounded wait for that delete to actually COMPLETE is step 7's
# wait_for_rgs_gone. Running the LAW purge here, before step 7, meant `list-deleted-workspaces`
# could run before the workspace had actually landed in soft-delete - it would find nothing,
# print "nothing to do", exit success, and minutes later the RG delete would finish leaving the
# workspace soft-deleted and UNPURGED (the exact stale-soft-delete condition OQ-063 exists to
# close, reintroduced by ordering rather than logic). See step 7b's own comment for the full
# mechanism and for why it is now a BACKSTOP rather than the primary purge path.

# --- 4. MG hierarchy removal, gated on remove_mg_hierarchy. Fast control-plane ops - stay
#     synchronous, no --no-wait, no reconcile wait needed for MGs (locked decision 9.3).
#     MG-EXISTENCE via the ONE-TIME `az account management-group list` SNAPSHOT (2026-07-20,
#     third amendment / ADR-054 point 12, docs/teardown-redesign.md sections 10.3 and 12) -
#     REPLACES the per-MG `az account management-group show` gate (ADR-054 point 11,
#     SUPERSEDED): `show` is principal-dependent for the scoped teardown SP and returns 403 on
#     a deleted MG (not the clean 404 the point-11 fix assumed - proven empirically, probe run
#     29756715840), which is_auth_error correctly matches, so a `show`-based skip fails loud on
#     benign already-gone MGs. The snapshot is taken ONCE here at the START of step 4, NOT
#     re-listed per iteration - this step DELETES MGs as it goes, so later iterations correctly
#     keep checking membership against the original snapshot rather than a live re-list (which
#     would just be redundant work against a collection this step is itself shrinking). ---
echo "== Phase 2 step 4: MG hierarchy removal (remove_mg_hierarchy=${REMOVE_MG_HIERARCHY}) =="
# mg_snapshot_load now runs UNCONDITIONALLY here (2026-07-23, teardown-completeness extension
# sweep) - moved out of the remove_mg_hierarchy=true branch below. This step's own FIX-1
# pre-sweep and delete loop need it whenever remove_mg_hierarchy=true, and mg_in_snapshot
# silently reads every MG as "absent" against an unloaded snapshot (${MG_SNAPSHOT[$name]+x} is
# false on an empty array) - exactly the kind of silent false-clean this codebase's own
# is_auth_error/mg_snapshot_ok discipline exists to prevent. This load is now consumed only by
# step 4-pre and the step-4 delete loop immediately below - ADR-064 REMOVED the former 6a
# MG-portion budget re-sweep that used to take its own separate fresh reload further down this
# script, because it was the one place that read an MG scope AFTER this same loop could have
# deleted it (see ADR-064, DECISIONS.md). One extra `az account management-group list` call per
# run either way (cheap, VERIFY already calls it unconditionally too).
if ! mg_snapshot_load; then
  echo "::error::Step 4 cannot proceed without a trustworthy MG-existence snapshot."
  exit 1
fi
if [ "$REMOVE_MG_HIERARCHY" != "true" ]; then
  echo "  Skipped (remove_mg_hierarchy=false) - the MG tree is left in place."
else
  # --- 4-pre (FIX-1, teardown-completeness extension sweep, 2026-07-23; DEMOTED to a
  #     last-chance gate by ADR-063 decision 4, 2026-07-23). Sweeps every MG-scope EXTENSION
  #     resource - budgets, diagnostic settings, policy exemptions - across every MG still
  #     present in the snapshot, STRICTLY BEFORE the delete loop below issues a single
  #     `az account management-group delete`. Root cause this closes: an extension resource's
  #     ARM ID is formed by appending its own provider path onto WHATEVER scope it was attached
  #     to (an MG here) - ARM does NOT cascade-delete an extension resource when its host scope
  #     is deleted, so an orphaned MG-scoped exemption/budget/diagnostic-setting then COLLIDES
  #     the next time Step 1 (a later run) recreates an MG of the same name.
  #
  #     NO LONGER THE PRIMARY MECHANISM (ADR-063 decision 4): the Phase-0 sweep in
  #     teardown-disarm.sh now runs this same sweep, reachable in BOTH teardown modes with every
  #     MG-scope grant still bound, before Phase 1/2 touch anything - see that script's own
  #     comment for why it is the only reachable, authorised placement. On a healthy run this
  #     block should find NOTHING (Phase 0 already swept it), so it is now a cheap remnant-catch,
  #     not the mechanism this fix depends on.
  #
  #     LAST-CHANCE GATE, NOT warn-and-continue (ADR-063 decision 4): everywhere else in this
  #     script, "the next run retries idempotently" justifies a warning and a continue. That
  #     justification is VOID here specifically, because THIS SAME RUN is about to delete the MG
  #     scope that makes the retry possible (the delete loop immediately below). So ANY survivor
  #     found in this block - a list failure, a delete failure, or a still-live confirm-GET -
  #     now ABORTS THE ENTIRE step 4 MG delete loop under the distinct TEARDOWN-P0MG-SURVIVOR
  #     label and leaves the MG tree standing, rather than deleting a host scope that still has
  #     an owned extension object attached (G-1's one-way door). Because Phase 0 gates every
  #     downstream job (`needs: disarm`), reaching this block at all already means Phase 0
  #     succeeded - so a survivor found HERE is a genuinely anomalous, late-discovered condition
  #     (a race, a remediation policy, replication lag), not the expected common case, and
  #     leaving the tree standing for one idempotent re-dispatch (ADR-054 point 8) is a small
  #     price against permanently losing the ability to ever see the survivor again.
  #
  #     OWNERSHIP (ADR-063 decision 6): every object found at any MG in MG_SCOPES is owned by
  #     T1(a) containment (is_estate_owned --mg, teardown-common.sh) - the MG itself is fully
  #     estate-owned, so anything living on it is owned regardless of its own name. The prior
  #     per-row name filters (contains(name,'globaris') for budgets, is_globaris_owned for
  #     diagnostic settings, is_owned_policy_object for exemptions) are REMOVED - they were
  #     redundant at best (T1 containment already implies ownership) and were part of what let
  #     securityContacts/default-shaped misclassifications happen elsewhere (ADR-063 decision 7).
  #
  #     Same list/delete conventions as every other step in this script otherwise: az_run_retry
  #     for any list whose stdout feeds a compare/mapfile (Finding #2, bounded retry on a
  #     transient 5xx/429), is_auth_error classification,
  #     confirm_gone_or_fail_primary after every delete (no separate Phase 3 VERIFY step exists
  #     for MG scope - see that function's own comment, teardown-common.sh).
  echo "== Phase 2 step 4-pre: MG-scope extension LAST-CHANCE GATE (budgets, diagnostic settings, policy exemptions) - before any MG delete (FIX-1, demoted by ADR-063 decision 4) =="
  for mg in "${MG_DELETE_ORDER[@]}"; do
    if ! mg_in_snapshot "$mg"; then
      echo "  MG ${mg}: already gone (absent from the snapshot) - nothing to sweep."
      continue
    fi
    if ! is_estate_owned --mg "$mg"; then
      echo "::error::TEARDOWN-P0MG-SURVIVOR: step 4-pre: MG ${mg} did not classify as estate-owned by is_estate_owned - structurally impossible for a member of MG_DELETE_ORDER (a permutation of MG_SCOPES). Aborting the MG delete loop rather than proceeding on an unexpected classification."
      exit 1
    fi
    mg_scope="$(mg_scope_path "$mg")"

    # Budgets (Microsoft.Consumption/budgets, BUDGETS_API_VERSION). No server-side name filter
    # (ADR-063 decision 6) - T1(a) containment already owns every row found at this MG.
    if ! az_run_retry mg_budget_names_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}" \
        --query "value[].name" -o tsv; then
      echo "::error::MG-scope budget list failed for MG ${mg} - a failed list is never read as 'no budgets' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # mg_budget_names_out is assigned indirectly by az_run's printf -v
    mapfile -t mg_budget_names <<< "$mg_budget_names_out"
    for name in "${mg_budget_names[@]:-}"; do
      [ -z "$name" ] && continue
      echo "  Deleting MG-scope budget ${name} (MG ${mg})"
      mg_budget_url="${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets/${name}?api-version=${BUDGETS_API_VERSION}"
      if ! mg_budget_del_out="$(az rest --method delete --url "$mg_budget_url" --output none 2>&1)"; then
        echo "::error::TEARDOWN-P0MG-SURVIVOR: MG-scope budget delete for ${name} (MG ${mg}) failed - still present at this last-chance gate; aborting the MG delete loop rather than deleting a host scope with an owned extension object still attached (ADR-063 G-1): ${mg_budget_del_out}"
        exit 1
      fi
      # PRIMARY-pattern confirm-GET (code-review BLOCK-2 fix, 2026-07-23): this scope has no
      # separate Phase 3 VERIFY step (MG-scope objects are 403-shadowed once their MG is
      # deleted) - this confirm-GET IS the completion check, run here while the MG still
      # exists. See confirm_gone_or_fail_primary's own comment (teardown-common.sh).
      confirm_gone_or_fail_primary "TEARDOWN-P0MG-SURVIVOR: MG-scope budget ${name} (MG ${mg})" "$mg_budget_url" || exit 1
    done

    # Diagnostic settings (management-GROUP diagnostic settings op group, DISTINCT from the
    # generic resource op group - MG_DIAGNOSTIC_SETTINGS_API_VERSION, see teardown-common.sh). No
    # per-row name filter (ADR-063 decision 6) - T1(a) containment already owns every row found.
    # ADR-063 decision 1d: a 403 on the DELETE below is a KNOWN DESIGN GAP (OQ-059(b)), not the
    # generic auth-fail-loud dead-token signal - see the dedicated branch below.
    #
    # AMENDED AGAIN 2026-07-23 (code-review BLOCK, second pass on Finding #2 - the first pass's
    # fix was itself defective and is superseded below). The first pass made the delete-failure
    # branch check `is_auth_error` FIRST, before the narrower 403/Forbidden/AuthorizationFailed
    # design-gap grep, reasoning that this matched the codebase-wide rule (teardown-common.sh line
    # 667). That reasoning was wrong for THIS branch specifically: `is_auth_error` matches on bare
    # `credential` and bare `403` (deliberately broad, by design, and NOT loosened here), and
    # Azure's own genuine `AuthorizationFailed` RBAC-denial text - the EXACT OQ-059(b) case this
    # branch exists to label - contains both. Verified live against Microsoft's RBAC troubleshooting
    # reference (learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting,
    # "Symptom - Unable to assign a role" / "Symptom - Authorization failed" sections, fetched
    # 2026-07-23): the documented error body reads "...does not have authorization or an ABAC
    # condition not fulfilled to perform action '...' over scope '...' or the scope is invalid. If
    # access was recently granted, please refresh your credentials." and the short form is
    # "...(code: AuthorizationFailed)". So `is_auth_error` matched FIRST on every real occurrence of
    # the design gap, and the design-gap `elif` was dead code for the one input it was written to
    # handle - an operator hitting the actual OQ-059(b) gap got pointed at re-authentication instead
    # of the real remediation. Simply reordering back to grep-first would re-open the ORIGINAL
    # first-review finding (a dead token whose text happens to contain bare `403`/`Forbidden` gets
    # mislabelled "KNOWN DESIGN GAP"), because the old grep pattern itself was too broad - it was
    # never the ordering that was wrong, it was that both candidate patterns overlapped on bare
    # `403`.
    #
    # THE FIX: `_is_authz_denied_design_gap` (defined near the top of this file), a precise, narrow
    # discriminator matching ONLY the literal ARM error code `AuthorizationFailed` and the two
    # RBAC-denial phrases Azure's own docs show verbatim (`does not have authorization`, `ABAC
    # condition`) - deliberately DROPPING bare `403`/`Forbidden`, which is what caused the
    # collision. `AuthorizationFailed` is ARM's authorization-layer code, returned only for an
    # authenticated principal lacking the needed action; a dead/expired token fails at the separate
    # AUTHENTICATION layer (AADSTS7xxxxx, ExpiredAuthenticationToken, "valid time range", "not
    # within") BEFORE ARM ever evaluates authorization, so it structurally cannot produce this code
    # or either phrase - mutually exclusive by Azure's own layering, not just distinct today.
    # Checking it FIRST is therefore safe and does not reopen the auth-fail-loud rule: nothing a
    # dead token can say matches it. `is_auth_error` remains checked next, its normal unmodified
    # broad role (NOT loosened), for genuine dead-token/transport failures; a final else covers
    # anything matching neither shape. Mirrored at the identical site in teardown-disarm.sh (Phase
    # 0) with the SAME function body so the two cannot drift.
    if ! az_run_retry mg_diag_names_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/microsoft.insights/diagnosticSettings?api-version=${MG_DIAGNOSTIC_SETTINGS_API_VERSION}" \
        --query "value[].name" -o tsv; then
      echo "::error::MG-scope diagnostic-settings list failed for MG ${mg} - a failed list is never read as 'no diagnostic settings' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # mg_diag_names_out is assigned indirectly by az_run's printf -v
    mapfile -t mg_diag_names <<< "$mg_diag_names_out"
    for name in "${mg_diag_names[@]:-}"; do
      [ -z "$name" ] && continue
      echo "  Deleting MG-scope diagnostic setting ${name} (MG ${mg})"
      mg_diag_url="${ARM_BASE}${mg_scope}/providers/microsoft.insights/diagnosticSettings/${name}?api-version=${MG_DIAGNOSTIC_SETTINGS_API_VERSION}"
      if ! mg_diag_del_out="$(az rest --method delete --url "$mg_diag_url" --output none 2>&1)"; then
        if _is_authz_denied_design_gap "$mg_diag_del_out"; then
          echo "::error::TEARDOWN-P0MG-SURVIVOR (KNOWN DESIGN GAP, OQ-059(b)): MG-scope diagnostic setting delete for ${name} (MG ${mg}) returned an RBAC-denial (AuthorizationFailed) - no role held by this OIDC SP carries Microsoft.Insights/diagnosticSettings/delete at MG scope. This is NOT the generic auth-fail-loud dead-token signal. Aborting the MG delete loop rather than deleting a host scope with this object still attached (ADR-063 G-1); OQ-059(b) option B (a Monitoring Contributor grant) or a privileged one-off delete must land before this MG can be safely deleted: ${mg_diag_del_out}"
        elif is_auth_error "$mg_diag_del_out"; then
          echo "::error::TEARDOWN-P0MG-SURVIVOR: MG-scope diagnostic setting delete for ${name} (MG ${mg}) failed with an auth/transport error - cannot certify this as the KNOWN DESIGN GAP (OQ-059(b)) off a possibly-dead token: ${mg_diag_del_out}"
        else
          echo "::error::TEARDOWN-P0MG-SURVIVOR: MG-scope diagnostic setting delete for ${name} (MG ${mg}) failed - still present at this last-chance gate; aborting the MG delete loop (ADR-063 G-1): ${mg_diag_del_out}"
        fi
        exit 1
      fi
      # PRIMARY-pattern confirm-GET (BLOCK-2 fix) - see the budget block above for the full
      # rationale; identical here (no separate VERIFY step for MG scope).
      confirm_gone_or_fail_primary "TEARDOWN-P0MG-SURVIVOR: MG-scope diagnostic setting ${name} (MG ${mg})" "$mg_diag_url" || exit 1
    done

    # Policy exemptions (atExactScope, POLICY_EXEMPTIONS_API_VERSION_NEW). No per-row predicate
    # filter (ADR-063 decision 6) - T1(a) containment already owns every row found at this MG;
    # is_owned_policy_object stays the T3 mechanism for scopes that are NOT themselves
    # estate-owned (subscription/tenant scope), not for MG scope.
    if ! az_run_retry mg_exemption_rows_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Authorization/policyExemptions?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}&\$filter=atExactScope()" \
        --query "value[].[name, id]" -o tsv; then
      echo "::error::MG-scope policy exemption list failed for MG ${mg} - a failed list is never read as 'no exemptions' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # mg_exemption_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t mg_exemption_rows <<< "$mg_exemption_rows_out"
    for row in "${mg_exemption_rows[@]:-}"; do
      [ -z "$row" ] && continue
      mg_ex_name="$(printf '%s' "$row" | cut -f1)"
      mg_ex_id="$(printf '%s' "$row" | cut -f2)"
      case "$mg_ex_id" in
        "${mg_scope}"/*) ;;
        *)
          echo "::error::TEARDOWN-P0MG-SURVIVOR: MG-scope policy exemption ${mg_ex_name} (MG ${mg}) returned by atExactScope() but its id '${mg_ex_id}' does not start with this MG's own scope path '${mg_scope}' (ADR-063 rule 3b client-side belt). Not deleting off an unverified scope match; aborting the MG delete loop."
          exit 1
          ;;
      esac
      echo "  Deleting MG-scope policy exemption ${mg_ex_name} (MG ${mg})"
      mg_exemption_url="${ARM_BASE}${mg_scope}/providers/Microsoft.Authorization/policyExemptions/${mg_ex_name}?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}"
      if ! mg_exemption_del_out="$(az rest --method delete --url "$mg_exemption_url" --output none 2>&1)"; then
        echo "::error::TEARDOWN-P0MG-SURVIVOR: MG-scope policy exemption delete for ${mg_ex_name} (MG ${mg}) failed - still present at this last-chance gate; aborting the MG delete loop (ADR-063 G-1): ${mg_exemption_del_out}"
        exit 1
      fi
      # PRIMARY-pattern confirm-GET (BLOCK-2 fix) - see the budget block above for the full
      # rationale; identical here (no separate VERIFY step for MG scope).
      confirm_gone_or_fail_primary "TEARDOWN-P0MG-SURVIVOR: MG-scope policy exemption ${mg_ex_name} (MG ${mg})" "$mg_exemption_url" || exit 1
    done
  done

  for mg in "${MG_DELETE_ORDER[@]}"; do
    if ! mg_in_snapshot "$mg"; then
      echo "  MG ${mg} already gone (absent from the snapshot) - skipping."
      continue
    fi

    echo "  MG ${mg}: moving any attached subscriptions to the tenant root"
    if ! az_run_retry mg_subs_out account management-group subscription show-sub-under-mg --name "$mg" \
        --query "[].name" -o tsv; then
      echo "::error::listing subscriptions under MG ${mg} failed - a non-idempotent failure, not warn-and-continue: ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # mg_subs_out is assigned indirectly by az_run's printf -v
    mapfile -t mg_subs <<< "$mg_subs_out"
    for sub_id in "${mg_subs[@]:-}"; do
      [ -z "$sub_id" ] && continue
      echo "    Removing subscription ${sub_id} from ${mg} (re-parents to tenant root)"
      if ! mg_sub_rm_out="$(az account management-group subscription remove --name "$mg" --subscription "$sub_id" --output none 2>&1)"; then
        echo "::error::removing subscription ${sub_id} from ${mg} failed - a non-idempotent failure, not warn-and-continue: ${mg_sub_rm_out}"
        exit 1
      fi
    done

    echo "  Deleting management group ${mg}"
    if ! mg_del_out="$(az account management-group delete --name "$mg" --output none 2>&1)"; then
      echo "::error::deleting management group ${mg} failed - a non-idempotent failure, not warn-and-continue: ${mg_del_out}"
      exit 1
    fi
  done
fi

# --- 6. SUBSCRIPTION SCOPE (ADR-057, docs/teardown-redesign.md section 12.3, added
#     2026-07-21). Everything in steps 1-4 finds resources by RESOURCE GROUP naming pattern or
#     by MG scope; neither can see an object that lives at subscription scope. This step
#     covers that surface explicitly: 6a the four subscription-scoped object classes, 6b the
#     Defender for Cloud pricing reset to Free (a WRITE, not a delete - the one genuinely
#     dangerous operation here), 6c the Microsoft.CostManagementExports provider
#     unregistration. Runs AFTER step 4 (nothing here races a live MG-scope remediation) and
#     BEFORE step 7's reconcile (so step 6's own submissions are covered by the existing wait
#     and by Phase 3 - no new wait is introduced). Inherits every existing convention without
#     exception: az_run_retry for any call whose stdout is consumed as data (Trap 1, bounded
#     retry on a transient 5xx/429), is_auth_error classification on every non-zero (Trap 2),
#     auth-fail-loud, idempotent-absent-is-success.
echo "== Phase 2 step 6: subscription-scope objects (budgets, cost exports, cost anomaly, diagnostic settings, Defender pricing reset, RP unregister) =="
# ARM_BASE is sourced from teardown-common.sh (see the note near the top of this script).

# --- 6a. Four subscription-scoped object classes, all 5 subscriptions. Discovery is by LIST,
#     never a hardcoded name list, so a renamed or added object is still caught. Filtered by
#     the same estate-ownership test the RG sweep already uses (contains(name,'globaris')) so
#     a non-estate object in a shared subscription is never touched - subscription diagnostic
#     settings are the one exception (the estate name is not org-prefixed; see below).
#     List-call failure: a SUBSCRIPTION-scoped list can never legitimately be gone (section 9.4
#     design boundary - subscriptions are only re-parented, never deleted), so ANY non-zero is
#     FAIL LOUD, matching steps 1-3 above. Delete-call failure: classify with is_auth_error -
#     auth-shaped fails loud, anything else warns and continues (idempotent-absent is success;
#     Phase 3 VERIFY 6 and the QA pass are the backstops). These are synchronous sub-second
#     control-plane deletes, not RGs - deliberately not added to wait_for_rgs_gone in step 7.
echo "-- 6a: consumption budgets, cost exports, cost anomaly scheduled actions, subscription diagnostic settings --"
for sub in "${SUBS[@]}"; do
  # Consumption budgets (Microsoft.Consumption/budgets). FIX-2 (teardown-completeness
  # extension sweep, 2026-07-23): bumped the delete's api-version from 2023-05-01 to
  # BUDGETS_API_VERSION (2024-08-01, re-verified live - teardown-common.sh) - same LOAD-
  # BEARING-pin discipline as the cost-export 2025-03-01 pin below (an older version can
  # silently under-report what actually exists at some scopes; re-verify at every
  # pre-clearance). The LIST call stays on the `az consumption budget list` CLI wrapper
  # (its own internal api-version, not user-pinned) - only the raw-REST DELETE below is
  # explicitly version-pinned.
  if ! az_run_retry budget_names_out consumption budget list --subscription "$sub" \
      --query "[?contains(name,'globaris')].name" -o tsv; then
    echo "::error::consumption budget list failed for subscription ${sub} - a failed list is never read as 'no budgets' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # budget_names_out is assigned indirectly by az_run's printf -v
  mapfile -t budget_names <<< "$budget_names_out"
  for name in "${budget_names[@]:-}"; do
    [ -z "$name" ] && continue
    echo "  Deleting subscription budget ${name} (sub ${sub})"
    if ! budget_del_out="$(az rest --method delete \
        --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.Consumption/budgets/${name}?api-version=${BUDGETS_API_VERSION}" \
        --output none 2>&1)"; then
      if is_auth_error "$budget_del_out"; then
        echo "::error::budget delete for ${name} (sub ${sub}) failed with an auth/transport error: ${budget_del_out}"
        exit 1
      fi
      echo "  ::warning::budget delete for ${name} failed or already gone (continuing - idempotent retry on next run): ${budget_del_out}"
    fi
  done

  # RG-scope budgets (FIX-2, teardown-completeness extension sweep, 2026-07-23). Covers
  # synthetic/sandbox_overrun (bdgt-synthetic-overrun-<org_prefix>-<env>,
  # azurerm_consumption_budget_resource_group.sandbox_overrun, synthetic/cost_patterns.tf) -
  # an RG-scoped budget is an extension resource on that RG and does NOT cascade away just
  # because step 2 deletes the RG (same root cause as every other class in this fix).
  # Discovery is BY LIST over every RG the RG sweep pattern would already touch
  # (discover_live_rgs, teardown-common.sh) - never a hardcoded RG name - so a RG this
  # estate adds later is still covered with no code change here. A "belt" pass alongside
  # step 4-pre's MG-scope sweep (FIX-1): this loop is unconditional (runs every sweep,
  # remove_mg_hierarchy true or false) while FIX-1 only runs when MGs are actually being
  # deleted - genuinely different coverage, not pure duplication.
  #
  # No server-side or per-row name filter (ADR-063 decision 6, rewired from
  # contains(name,'globaris')): T1(b) containment (is_estate_owned --rg, teardown-common.sh)
  # already owns every row found on an RG discover_live_rgs returned - it only ever returns
  # RG_SWEEP_QUERY-matched RGs, so this call is a defensive assertion, not a live filter.
  if ! discover_live_rgs rg6a_names_out "$sub"; then
    echo "::error::RG list failed for subscription ${sub} while discovering RG-scope budget targets - a failed list is never read as 'no RGs' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # rg6a_names_out is assigned indirectly by az_run's printf -v
  mapfile -t rg6a_names <<< "$rg6a_names_out"
  for rg in "${rg6a_names[@]:-}"; do
    [ -z "$rg" ] && continue
    if ! is_estate_owned --rg "$rg"; then
      echo "::error::RG-scope budget sweep: RG ${rg} (sub ${sub}) did not classify as estate-owned by is_estate_owned - structurally impossible for a row discover_live_rgs returned (RG_SWEEP_QUERY-filtered). Failing loud rather than silently skipping."
      exit 1
    fi
    if ! az_run_retry rg_budget_names_out rest --method get \
        --url "${ARM_BASE}/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}" \
        --query "value[].name" -o tsv; then
      echo "::error::RG-scope budget list failed for RG ${rg} (sub ${sub}) - a failed list is never read as 'no budgets' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # rg_budget_names_out is assigned indirectly by az_run's printf -v
    mapfile -t rg_budget_names <<< "$rg_budget_names_out"
    for name in "${rg_budget_names[@]:-}"; do
      [ -z "$name" ] && continue
      echo "  Deleting RG-scope budget ${name} (RG ${rg}, sub ${sub})"
      rg_budget_url="${ARM_BASE}/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Consumption/budgets/${name}?api-version=${BUDGETS_API_VERSION}"
      if ! rg_budget_del_out="$(az rest --method delete --url "$rg_budget_url" --output none 2>&1)"; then
        if is_auth_error "$rg_budget_del_out"; then
          echo "::error::RG-scope budget delete for ${name} (RG ${rg}, sub ${sub}) failed with an auth/transport error: ${rg_budget_del_out}"
          exit 1
        fi
        echo "  ::warning::RG-scope budget delete for ${name} (RG ${rg}, sub ${sub}) failed or already gone (continuing): ${rg_budget_del_out}"
      else
        # BELT-pattern confirm-GET (code-review BLOCK-2 follow-up, 2026-07-23) - RG scope
        # stays queryable after this fix runs (unlike MG scope), and VERIFY 6 (RG scope)
        # (teardown-verify.sh) is the authoritative completion gate for this class, so an
        # indeterminate/still-live result here is a warning, not fatal.
        confirm_gone_or_warn_belt "RG-scope budget ${name} (RG ${rg}, sub ${sub})" "$rg_budget_url" || exit 1
      fi
    done
  done

  # Cost exports (Microsoft.CostManagement/exports, api-version 2025-03-01 - LOAD-BEARING, do
  # NOT simplify to a default/older version: an older version reads these as absent, which is
  # exactly the false-negative that happened on 2026-07-16, docs/teardown-redesign.md 12.3).
  if ! az_run_retry export_names_csv rest --method get \
      --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.CostManagement/exports?api-version=2025-03-01" \
      --query "join(',',value[?contains(name,'globaris')].name)" -o tsv; then
    echo "::error::cost export list (api-version 2025-03-01) failed for subscription ${sub} - a failed list is never read as 'no exports' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # export_names_csv is assigned indirectly by az_run's printf -v
  IFS=',' read -ra export_names <<< "$export_names_csv"
  for name in "${export_names[@]:-}"; do
    [ -z "$name" ] && continue
    echo "  Deleting cost export ${name} (sub ${sub})"
    if ! export_del_out="$(az rest --method delete \
        --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.CostManagement/exports/${name}?api-version=2025-03-01" \
        --output none 2>&1)"; then
      if is_auth_error "$export_del_out"; then
        echo "::error::cost export delete for ${name} (sub ${sub}) failed with an auth/transport error: ${export_del_out}"
        exit 1
      fi
      echo "  ::warning::cost export delete for ${name} failed or already gone (continuing - idempotent retry on next run): ${export_del_out}"
    fi
  done

  # Cost anomaly / scheduled actions (Microsoft.CostManagement/scheduledActions, api-version
  # 2023-11-01, list/delete BY SCOPE). Only the management subscription carries one today (the
  # InsightAlert cost anomaly alert), but the loop runs across all five so a future wave that
  # adds another is covered without a code change.
  if ! az_run_retry scheduled_action_names_csv rest --method get \
      --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.CostManagement/scheduledActions?api-version=2023-11-01" \
      --query "join(',',value[?contains(name,'globaris')].name)" -o tsv; then
    echo "::error::cost anomaly scheduled action list failed for subscription ${sub} - a failed list is never read as 'no scheduled actions' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # scheduled_action_names_csv is assigned indirectly by az_run's printf -v
  IFS=',' read -ra scheduled_action_names <<< "$scheduled_action_names_csv"
  for name in "${scheduled_action_names[@]:-}"; do
    [ -z "$name" ] && continue
    echo "  Deleting cost anomaly scheduled action ${name} (sub ${sub})"
    if ! sa_del_out="$(az rest --method delete \
        --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.CostManagement/scheduledActions/${name}?api-version=2023-11-01" \
        --output none 2>&1)"; then
      if is_auth_error "$sa_del_out"; then
        echo "::error::cost anomaly scheduled action delete for ${name} (sub ${sub}) failed with an auth/transport error: ${sa_del_out}"
        exit 1
      fi
      echo "  ::warning::scheduled action delete for ${name} failed or already gone (continuing - idempotent retry on next run): ${sa_del_out}"
    fi
  done

  # Subscription diagnostic settings. The ONE class where the standard globaris-substring
  # filter does not apply on its own - the estate name is diag-activity-to-security-law (NOT
  # org-prefixed) - so this lists ALL names unfiltered and applies the ownership test
  # (globaris substring OR the exact estate name) per row below, before deleting anything.
  if ! az_run_retry diag_names_out monitor diagnostic-settings subscription list --subscription "$sub" \
      --query "value[].name" -o tsv; then
    echo "::error::subscription diagnostic-settings list failed for subscription ${sub} - a failed list is never read as 'no diagnostic settings' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # diag_names_out is assigned indirectly by az_run's printf -v
  mapfile -t diag_names <<< "$diag_names_out"
  for name in "${diag_names[@]:-}"; do
    [ -z "$name" ] && continue
    case "$name" in
      *globaris*|diag-activity-to-security-law) ;;
      *)
        echo "  Skipping subscription diagnostic setting ${name} (sub ${sub}) - not estate-owned (no 'globaris' substring, not diag-activity-to-security-law)."
        continue
        ;;
    esac
    echo "  Deleting subscription diagnostic setting ${name} (sub ${sub})"
    if ! diag_del_out="$(az monitor diagnostic-settings subscription delete --name "$name" --subscription "$sub" --yes --output none 2>&1)"; then
      if is_auth_error "$diag_del_out"; then
        echo "::error::diagnostic setting delete for ${name} (sub ${sub}) failed with an auth/transport error: ${diag_del_out}"
        exit 1
      fi
      echo "  ::warning::diagnostic setting delete for ${name} failed or already gone (continuing - idempotent retry on next run): ${diag_del_out}"
    fi
  done
done

# --- 6d. Subscription-scoped policy exemptions (ADR-062, docs/teardown-redesign.md section
#     14.2, added 2026-07-21). Placed AFTER 6a and BEFORE 6b - an object-class delete like 6a,
#     ordered before the settings-writes in 6b/6c. MG-scoped exemptions are covered separately
#     by FIX-1 (step 4-pre, gated on remove_mg_hierarchy, ordered before the MG that hosts them
#     is deleted).
#
#     CORRECTION (FIX-3, teardown-completeness extension sweep, 2026-07-23): the original claim
#     below that "RG-scoped ... exemptions are OUT (they cascade with their parent, proven this
#     cycle)" did not hold under az-sweep mode - RG-scoped policy exemptions are extension
#     resources on that RG, same as budgets/diagnostic-settings, and do NOT cascade away just
#     because step 2 deletes the RG. A defense-in-depth RG-scoped sweep is added immediately
#     after this subscription-scoped block (still inside this same 6d section, after the `for
#     sub` loop below closes). Resource-scoped exemptions remain genuinely OUT of this fix's
#     scope (not requested, no known estate example) - if one is ever added, VERIFY 9's
#     discovery scan will still catch it as UNCLASSIFIED (teardown-verify.sh).
#
#     Root cause this closes: exempt-dbx-managed-storage-bank-data-p1
#     (landing-zones/bank-data-p1/policy_exemptions.tf) survived both teardowns and this
#     morning's original step 6, because its parent scope is a SUBSCRIPTION, which is never
#     deleted (section 5) - an exemption is only ever removed by cascade from its parent, and a
#     subscription-scoped exemption has no parent that can ever be removed. Its expires_on does
#     NOT help either: Microsoft's documented behaviour is that an exemption is preserved for
#     record-keeping past expiry, not deleted.
#
#     API version 2022-07-01-preview for BOTH list and delete - Microsoft.Authorization/
#     policyExemptions has NO GA api-version at all (every offered version is a preview; this
#     one and 2026-01-01-preview were confirmed live to return every property the estate sets).
#     LOAD-BEARING pin, same class as the cost-export 2025-03-01 pin above - re-verify at every
#     pre-clearance (LESSON 40/41).
#
#     $filter=atExactScope() is REQUIRED, not cosmetic: with no filter, a subscription-scope
#     list also returns exemptions inherited from ancestor MGs and exemptions on objects
#     CONTAINED WITHIN the subscription (RGs, resources) - deleting off that unfiltered list
#     would attempt deletes on inherited MG-scoped objects this script must never touch.
#     atScope() is also wrong (still includes ancestors); only atExactScope() returns objects
#     whose own scope IS the subscription (verified live against all three filter forms).
#
#     Ownership predicate is applied PER ROW IN THIS SCRIPT via is_owned_policy_object
#     (teardown-common.sh) - NOT as a server-side JMESPath name filter, because the predicate
#     needs both name and policyAssignmentId together and must stay byte-identical to what
#     VERIFY 6d/9 check for, so the delete side and the verify side can never drift apart. Do
#     NOT reuse contains(name,'globaris') alone here - the real object has no globaris
#     substring and a naive reuse would ship as a silent no-op (ADR-062).
#
#     List-call failure: a SUBSCRIPTION-scoped list can never legitimately be gone (section 9.4
#     boundary), so ANY non-zero is FAIL LOUD, matching 6a. Delete-call failure: classify with
#     is_auth_error - auth-shaped fails loud, anything else warns and continues (idempotent-
#     absent is success; a genuine 404 PolicyExemptionNotFound was confirmed live NOT to match
#     is_auth_error, so an already-deleted object is never misread as a dead token). Synchronous
#     sub-second control-plane call - no --no-wait, deliberately not added to wait_for_rgs_gone
#     in step 7 (that wait is RG-shaped); VERIFY 6d/9 are the completion gate instead.
echo "-- 6d: subscription-scoped policy exemptions (exact scope only) --"
for sub in "${SUBS[@]}"; do
  if ! az_run_retry exemption_rows_out rest --method get \
      --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview&\$filter=atExactScope()" \
      --query "value[].[name, properties.policyAssignmentId]" -o tsv; then
    echo "::error::subscription-scoped policy exemption list failed for subscription ${sub} - a failed list is never read as 'no exemptions' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # exemption_rows_out is assigned indirectly by az_run's printf -v
  mapfile -t exemption_rows <<< "$exemption_rows_out"
  for row in "${exemption_rows[@]:-}"; do
    [ -z "$row" ] && continue
    ex_name="$(printf '%s' "$row" | cut -f1)"
    ex_assignment_id="$(printf '%s' "$row" | cut -f2)"
    if ! is_owned_policy_object "$ex_name" "$ex_assignment_id"; then
      echo "  Skipping subscription-scoped policy exemption ${ex_name} (sub ${sub}) - matches no OWNED limb (policyAssignmentId '${ex_assignment_id}'), not estate-owned."
      continue
    fi
    echo "  Deleting subscription-scoped policy exemption ${ex_name} (sub ${sub})"
    if ! exemption_del_out="$(az rest --method delete \
        --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.Authorization/policyExemptions/${ex_name}?api-version=2022-07-01-preview" \
        --output none 2>&1)"; then
      if is_auth_error "$exemption_del_out"; then
        echo "::error::policy exemption delete for ${ex_name} (sub ${sub}) failed with an auth/transport error: ${exemption_del_out}"
        exit 1
      fi
      echo "  ::warning::policy exemption delete for ${ex_name} failed or already gone (continuing - idempotent retry on next run): ${exemption_del_out}"
    fi
  done
done

# --- 6d (RG scope, FIX-3, teardown-completeness extension sweep, 2026-07-23). Defense-in-depth
#     pass, run AFTER the RG naming-pattern sweep in step 2 has already submitted every matching
#     RG for deletion. Discovers surviving RGs (discover_live_rgs, teardown-common.sh - the same
#     RG_SWEEP_QUERY pattern step 2 uses, never a hardcoded name list) and sweeps RG-scoped
#     policy exemptions at exact scope on each. Covers the known estate examples (the 5
#     "corp_paas" RG-scoped exemptions per spoke, "aadds_deny_public_ip" in platform/identity,
#     "synthetic_paas" per synthetic RG - all confirmed live in-repo, landing-zones/*/
#     policy_exemptions.tf, platform/identity/domain-services.tf, synthetic/policy_exemptions.tf)
#     WITHOUT hardcoding any of their names or RGs - is_owned_policy_object (teardown-common.sh)
#     is the same three-limb predicate 6d's subscription-scope pass above already uses, so this
#     RG-scope pass can never drift from what VERIFY 9's discovery scan (teardown-verify.sh)
#     would classify OWNED. If a matching RG was already deleted by step 2, its exemption list
#     naturally 404s at scope and is skipped as "already gone" - no special-case needed.
echo "-- 6d (RG scope): policy exemptions on surviving RGs (defense-in-depth after step 2) --"
for sub in "${SUBS[@]}"; do
  if ! discover_live_rgs rg6d_names_out "$sub"; then
    echo "::error::RG list failed for subscription ${sub} while discovering RG-scope policy-exemption targets - a failed list is never read as 'no RGs' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # rg6d_names_out is assigned indirectly by az_run's printf -v
  mapfile -t rg6d_names <<< "$rg6d_names_out"
  for rg in "${rg6d_names[@]:-}"; do
    [ -z "$rg" ] && continue
    if ! az_run_retry rg_exemption_rows_out rest --method get \
        --url "${ARM_BASE}/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Authorization/policyExemptions?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}&\$filter=atExactScope()" \
        --query "value[].[name, properties.policyAssignmentId]" -o tsv; then
      echo "::error::RG-scope policy exemption list failed for RG ${rg} (sub ${sub}) - a failed list is never read as 'no exemptions' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # rg_exemption_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t rg_exemption_rows <<< "$rg_exemption_rows_out"
    for row in "${rg_exemption_rows[@]:-}"; do
      [ -z "$row" ] && continue
      rg_ex_name="$(printf '%s' "$row" | cut -f1)"
      rg_ex_assignment_id="$(printf '%s' "$row" | cut -f2)"
      if ! is_owned_policy_object "$rg_ex_name" "$rg_ex_assignment_id"; then
        echo "  Skipping RG-scope policy exemption ${rg_ex_name} (RG ${rg}, sub ${sub}) - not estate-owned."
        continue
      fi
      echo "  Deleting RG-scope policy exemption ${rg_ex_name} (RG ${rg}, sub ${sub})"
      rg_exemption_url="${ARM_BASE}/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Authorization/policyExemptions/${rg_ex_name}?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}"
      if ! rg_exemption_del_out="$(az rest --method delete --url "$rg_exemption_url" --output none 2>&1)"; then
        if is_auth_error "$rg_exemption_del_out"; then
          echo "::error::RG-scope policy exemption delete for ${rg_ex_name} (RG ${rg}, sub ${sub}) failed with an auth/transport error: ${rg_exemption_del_out}"
          exit 1
        fi
        echo "  ::warning::RG-scope policy exemption delete for ${rg_ex_name} (RG ${rg}, sub ${sub}) failed or already gone (continuing): ${rg_exemption_del_out}"
      else
        # BELT-pattern confirm-GET (BLOCK-2 follow-up) - VERIFY 6d (RG scope)
        # (teardown-verify.sh) is the authoritative completion gate for this class.
        confirm_gone_or_warn_belt "RG-scope policy exemption ${rg_ex_name} (RG ${rg}, sub ${sub})" "$rg_exemption_url" || exit 1
      fi
    done
  done
done

# --- 6b. Defender for Cloud pricing reset to Free (security subscription only). A WRITE, not
#     a delete - the one genuinely dangerous operation in this whole step. Iterates the FIXED
#     DEFENDER_PLANS_TO_FREE allow-list ONLY (teardown-common.sh) - NEVER the live pricing
#     list: a live-list loop would eventually reset a plan this estate does not own, and
#     setting a plan to Free can be permanently irreversible (Microsoft blocks NEW enablement
#     of deprecated plans - LESSON 41, OQ-050). Never attempts Standard; teardown only ever
#     moves toward Free. Idempotent: resetting an already-Free plan is a successful no-op. ---
echo "-- 6b: Defender for Cloud pricing reset to Free (security subscription, fixed allow-list only) --"
if [ -z "${SECURITY_SUBSCRIPTION_ID:-}" ]; then
  echo "::error::SECURITY_SUBSCRIPTION_ID is empty - cannot reset Defender pricing. This is already a VERIFY 0 failure class; failing loud here too rather than silently skipping."
  exit 1
fi
for plan in "${DEFENDER_PLANS_TO_FREE[@]}"; do
  echo "  Setting Defender plan ${plan} to Free (sub ${SECURITY_SUBSCRIPTION_ID})"
  if ! pricing_out="$(az security pricing create --name "$plan" --tier Free \
      --subscription "$SECURITY_SUBSCRIPTION_ID" --output none 2>&1)"; then
    if is_auth_error "$pricing_out"; then
      echo "::error::Defender pricing reset for ${plan} failed with an auth/transport error: ${pricing_out}"
      exit 1
    fi
    echo "  ::warning::Defender pricing reset for ${plan} failed (continuing - idempotent retry on next run; VERIFY 7 will report if it is still not Free): ${pricing_out}"
  fi
done

# --- 6c. Resource-provider unregistration (management subscription only). Runs strictly
#     AFTER 6a - unregistering a provider that still has resources fails. Idempotent:
#     unregistering an already-unregistered provider is a no-op. Does NOT poll to
#     Unregistered in-session - that is exactly the pattern the token-durability model
#     (section 4 / 9.2) exists to forbid. Submit only; Phase 3 VERIFY 8 and the QA pass
#     confirm the terminal state. ---
echo "-- 6c: resource-provider unregistration (management subscription) --"
if [ -z "${MANAGEMENT_SUBSCRIPTION_ID:-}" ]; then
  echo "::error::MANAGEMENT_SUBSCRIPTION_ID is empty - cannot unregister resource providers. This is already a VERIFY 0 failure class; failing loud here too rather than silently skipping."
  exit 1
fi
for ns in "${RP_NAMESPACES_TO_UNREGISTER[@]}"; do
  echo "  Unregistering resource provider ${ns} (sub ${MANAGEMENT_SUBSCRIPTION_ID})"
  if ! provider_out="$(az provider unregister --namespace "$ns" \
      --subscription "$MANAGEMENT_SUBSCRIPTION_ID" --output none 2>&1)"; then
    if is_auth_error "$provider_out"; then
      echo "::error::provider unregister for ${ns} failed with an auth/transport error: ${provider_out}"
      exit 1
    fi
    echo "  ::warning::provider unregister for ${ns} failed or already unregistered (continuing - idempotent retry on next run): ${provider_out}"
  fi
done

# --- 6e. Microsoft.Security singleton reset/sweep, security subscription only (FIX-4,
#     teardown-completeness extension sweep, 2026-07-23). Four sub-classes:
#       (i)   securityContacts - a TRUE subscription-scoped singleton, discovered by LIST and
#             deleted under the ADR-063 decision 6 T2 tier (is_estate_owned --singleton), NOT a
#             name test. CORRECTED 2026-07-23 (ADR-063 decision 7): platform/security/main.tf
#             configures name = "security-contact-${var.org_prefix}", but that name is NEVER
#             what ends up live - the API's own securityContactName constraint
#             (`pattern: ^(default)$`, api-version 2023-12-01-preview) pins every live object to
#             exactly "default", regardless of what this estate's Terraform requests. The prior
#             comment here ("a custom name the current API allows") was WRONG and is the reason
#             this sub-step, and VERIFY 6e, were silently deleting nothing: is_globaris_owned
#             (a name test) can never match an object that is always named "default". See
#             is_singleton_owned's own comment (teardown-common.sh) for the fix.
#       (ii)  Microsoft.Security/automations - discovered by a SUBSCRIPTION-WIDE list (returns
#             every automation regardless of which RG it is nested under) rather than assuming
#             it lives in a specific RG. NOTE: azurerm_security_center_automation IS genuinely
#             RG-nested in ARM's own resource hierarchy (confirmed live - the "List By Resource
#             Group" op group exists), so step 2's RG naming-pattern sweep should already have
#             cascaded it away when rg-security-<org_prefix>-<env> was deleted. This sub-step is
#             therefore a BELT check (same idiom as step 3's Key Vault "belt, in case of a race
#             with step 2's --no-wait") for the case where the RG sweep raced, was skipped, or
#             the automation outlived its RG for any other reason - not the primary removal path.
#       (iii) pricings reset to baseline - ALREADY handled by 6b above (DEFENDER_PLANS_TO_FREE
#             allow-list). Not duplicated here; noted so this comment block is a complete map of
#             "where does pricing get reset" for a future reader.
#       (iv)  autoProvisioningSettings / workspaceSettings reverted to baseline - NEITHER is
#             Terraform-managed anywhere in this repo (grep-confirmed, platform/security), so
#             "baseline" here means Azure's own unconfigured default, not a Terraform value.
#             Discovered by LIST and deleted if present - an unconfigured tenant never returns
#             anything for these lists, so this is a no-op on a clean estate and only acts if
#             something (manual testing, a prior experiment) actually created one.
#     Every list/delete follows the same conventions as every other class in this script:
#     az_run_retry for stdout-as-data (bounded retry on a transient 5xx/429), is_auth_error
#     auth-fail-loud on non-zero list (a live subscription's own-scope list can never
#     legitimately fail), idempotent-absent-is-success
#     on delete.
echo "-- 6e: Microsoft.Security singletons (security contacts, automations, auto-provisioning, workspace settings) --"
if [ -z "${SECURITY_SUBSCRIPTION_ID:-}" ]; then
  echo "::error::SECURITY_SUBSCRIPTION_ID is empty - cannot sweep Microsoft.Security singletons. This is already a VERIFY 0 failure class; failing loud here too rather than silently skipping."
  exit 1
fi

# (i) securityContacts - T2 (is_estate_owned --singleton), NOT a name test (ADR-063 decision 7).
if ! az_run_retry sec_contact_rows_out rest --method get \
    --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/securityContacts?api-version=${SECURITY_CONTACTS_API_VERSION}" \
    --query "value[].name" -o tsv; then
  echo "::error::securityContacts list failed for the security subscription - a failed list is never read as 'no contacts' (section 9.4): ${AZ_RUN_STDERR}"
  exit 1
fi
# shellcheck disable=SC2154  # sec_contact_rows_out is assigned indirectly by az_run's printf -v
mapfile -t sec_contact_names <<< "$sec_contact_rows_out"
for name in "${sec_contact_names[@]:-}"; do
  [ -z "$name" ] && continue
  if ! is_estate_owned --singleton "$SECURITY_SUBSCRIPTION_ID" "Microsoft.Security/securityContacts"; then
    # Structurally unreachable: SECURITY_SUBSCRIPTION_ID is one of the 5 env vars
    # is_estate_subscription checks, and Microsoft.Security/securityContacts is seeded on
    # ESTATE_DECLARED_SINGLETON_TYPES above - kept as a hard stop, not a silent skip, in case the
    # two are ever edited out of lock-step.
    echo "::error::security contact ${name} did not classify as estate-owned by is_estate_owned --singleton - this should be structurally impossible for the security subscription. Failing loud rather than silently skipping."
    exit 1
  fi
  echo "  Deleting security contact ${name} (sub ${SECURITY_SUBSCRIPTION_ID})"
  sec_contact_url="${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/securityContacts/${name}?api-version=${SECURITY_CONTACTS_API_VERSION}"
  if ! sec_contact_del_out="$(az rest --method delete --url "$sec_contact_url" --output none 2>&1)"; then
    if is_auth_error "$sec_contact_del_out"; then
      echo "::error::security contact delete for ${name} failed with an auth/transport error: ${sec_contact_del_out}"
      exit 1
    fi
    echo "  ::warning::security contact delete for ${name} failed or already gone (continuing): ${sec_contact_del_out}"
  else
    # BELT-pattern confirm-GET (confirm_gone_or_warn_belt, teardown-common.sh) - VERIFY 6e
    # (teardown-verify.sh) is the authoritative completion gate for this class.
    confirm_gone_or_warn_belt "security contact ${name}" "$sec_contact_url" || exit 1
  fi
done

# (ii) Microsoft.Security/automations (subscription-wide list; belt check - see comment above)
if ! az_run_retry sec_automation_rows_out rest --method get \
    --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/automations?api-version=${SECURITY_AUTOMATIONS_API_VERSION}" \
    --query "value[].[name, id]" -o tsv; then
  echo "::error::Microsoft.Security/automations list failed for the security subscription - a failed list is never read as 'no automations' (section 9.4): ${AZ_RUN_STDERR}"
  exit 1
fi
# shellcheck disable=SC2154  # sec_automation_rows_out is assigned indirectly by az_run's printf -v
mapfile -t sec_automation_rows <<< "$sec_automation_rows_out"
for row in "${sec_automation_rows[@]:-}"; do
  [ -z "$row" ] && continue
  automation_name="$(printf '%s' "$row" | cut -f1)"
  automation_id="$(printf '%s' "$row" | cut -f2)"
  if ! is_globaris_owned "$automation_name"; then
    echo "  Skipping Microsoft.Security automation ${automation_name} - not estate-owned (no 'globaris' substring)."
    continue
  fi
  echo "  Deleting Microsoft.Security automation ${automation_name} (id ${automation_id})"
  sec_automation_url="${ARM_BASE}${automation_id}?api-version=${SECURITY_AUTOMATIONS_API_VERSION}"
  if ! sec_automation_del_out="$(az rest --method delete --url "$sec_automation_url" --output none 2>&1)"; then
    if is_auth_error "$sec_automation_del_out"; then
      echo "::error::Microsoft.Security automation delete for ${automation_name} failed with an auth/transport error: ${sec_automation_del_out}"
      exit 1
    fi
    echo "  ::warning::Microsoft.Security automation delete for ${automation_name} failed or already gone (continuing - likely already cascaded with its RG in step 2): ${sec_automation_del_out}"
  else
    # BELT-pattern confirm-GET (confirm_gone_or_warn_belt) - VERIFY 6e (teardown-verify.sh) is
    # the authoritative completion gate for this class.
    confirm_gone_or_warn_belt "Microsoft.Security automation ${automation_name}" "$sec_automation_url" || exit 1
  fi
done

# (iv) autoProvisioningSettings / workspaceSettings - revert to Azure's own unconfigured
# default. No ownership predicate applied here (unlike (i)/(ii) above and the tenant AAD diag
# below) - same precedent as step 6b (Defender pricing reset, a fixed subscription-wide WRITE)
# and step 6c (RP unregistration, a fixed subscription-wide action): neither of those is
# name-filtered either, because both operate on a KNOWN, FIXED, subscription-singleton
# surface where "does this name look estate-owned" is not the right question - there is only
# ever one autoProvisioningSettings/default and the (small) workspaceSettings collection per
# subscription, and none of it is Terraform-managed anywhere in this repo (see the constants'
# own comment, teardown-common.sh), so anything found here is by definition not something this
# estate's IaC created and expects to keep.
# default (neither is Terraform-managed in this repo - see the comment block above).
if ! az_run_retry sec_autoprov_rows_out rest --method get \
    --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/autoProvisioningSettings?api-version=${SECURITY_AUTOPROVISIONING_API_VERSION}" \
    --query "value[?properties.autoProvision!='Off'].name" -o tsv; then
  echo "::error::autoProvisioningSettings list failed for the security subscription - a failed list is never read as 'nothing to revert' (section 9.4): ${AZ_RUN_STDERR}"
  exit 1
fi
# shellcheck disable=SC2154  # sec_autoprov_rows_out is assigned indirectly by az_run's printf -v
mapfile -t sec_autoprov_names <<< "$sec_autoprov_rows_out"
for name in "${sec_autoprov_names[@]:-}"; do
  [ -z "$name" ] && continue
  echo "  Reverting autoProvisioningSettings/${name} to Off (sub ${SECURITY_SUBSCRIPTION_ID})"
  if ! sec_autoprov_put_out="$(az rest --method put \
      --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/autoProvisioningSettings/${name}?api-version=${SECURITY_AUTOPROVISIONING_API_VERSION}" \
      --body "{\"properties\":{\"autoProvision\":\"Off\"}}" --output none 2>&1)"; then
    if is_auth_error "$sec_autoprov_put_out"; then
      echo "::error::autoProvisioningSettings revert for ${name} failed with an auth/transport error: ${sec_autoprov_put_out}"
      exit 1
    fi
    echo "  ::warning::autoProvisioningSettings revert for ${name} failed (continuing): ${sec_autoprov_put_out}"
  fi
done

if ! az_run_retry sec_workspace_rows_out rest --method get \
    --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/workspaceSettings?api-version=${SECURITY_WORKSPACESETTINGS_API_VERSION}" \
    --query "value[].name" -o tsv; then
  echo "::error::workspaceSettings list failed for the security subscription - a failed list is never read as 'nothing to revert' (section 9.4): ${AZ_RUN_STDERR}"
  exit 1
fi
# shellcheck disable=SC2154  # sec_workspace_rows_out is assigned indirectly by az_run's printf -v
mapfile -t sec_workspace_names <<< "$sec_workspace_rows_out"
for name in "${sec_workspace_names[@]:-}"; do
  [ -z "$name" ] && continue
  echo "  Deleting workspaceSettings/${name} (sub ${SECURITY_SUBSCRIPTION_ID}) - not Terraform-managed, reverting to the unconfigured default"
  if ! sec_workspace_del_out="$(az rest --method delete \
      --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/workspaceSettings/${name}?api-version=${SECURITY_WORKSPACESETTINGS_API_VERSION}" \
      --output none 2>&1)"; then
    if is_auth_error "$sec_workspace_del_out"; then
      echo "::error::workspaceSettings delete for ${name} failed with an auth/transport error: ${sec_workspace_del_out}"
      exit 1
    fi
    echo "  ::warning::workspaceSettings delete for ${name} failed or already gone (continuing): ${sec_workspace_del_out}"
  fi
done

# --- 6f. Tenant Microsoft.AadIam/diagnosticSettings sweep (FIX-5, teardown-completeness
#     extension sweep, 2026-07-23). Covers the security_law AAD diagnostic setting
#     (diag-aad-to-security-law, azurerm_monitor_aad_diagnostic_setting.security_law,
#     platform/security/diagnostics.tf) - a TENANT-scoped extension resource (no subscription
#     or RG segment in its URL at all), so nothing any other step in this script touches could
#     ever cascade it away.
#
#     SECURITY-ADMIN-GATED, BY DESIGN, NOT A BUG: reading/writing Microsoft.AadIam/
#     diagnosticSettings requires the CI OIDC SP to hold Security Administrator (or Global
#     Administrator) at the tenant root - the SAME permission class ADR-033/034 already
#     documents for enable_aad_diagnostics (platform/security/diagnostics.tf) and the two
#     tenant-scoped Sentinel connectors. If the SP does not currently hold that role, this call
#     401s. THIS IS TREATED AS FAIL LOUD, matching is_auth_error's classification everywhere
#     else in this script (never silently skipped as "no permission = clean") - the whole run
#     exits non-zero with a message telling the operator exactly what to do, rather than
#     reporting a false-clean sweep. Do NOT loosen this to a warn-and-continue: a directory-role
#     gap is not the same as "the object does not exist", and treating it that way would
#     reintroduce the exact swallow-the-error failure class section 9.4 already closed once.
#
#     NOTE this does NOT gate on `enable_aad_connector` (the separate, currently default-false
#     Sentinel AAD data connector, platform/security/variables.tf) - that is a DIFFERENT
#     resource. `enable_aad_diagnostics` (the one this sweep targets) is currently default TRUE
#     in this repo, so the diagnostic setting normally exists whenever platform/security has
#     applied; the SP's Security Administrator grant is the variable that determines whether
#     this delete can succeed, not this script's own gating.
echo "-- 6f: tenant Microsoft.AadIam/diagnosticSettings (security_law AAD diag) --"
if ! az_run_retry tenant_aad_diag_rows_out rest --method get \
    --url "${ARM_BASE}/providers/Microsoft.AadIam/diagnosticSettings?api-version=${TENANT_AAD_DIAGNOSTIC_SETTINGS_API_VERSION}" \
    --query "value[].name" -o tsv; then
  if is_auth_error "$AZ_RUN_STDERR"; then
    echo "::error::tenant Microsoft.AadIam/diagnosticSettings list failed with an auth/transport error - the CI OIDC SP likely does not (or no longer) hold Security Administrator (or Global Administrator) at the tenant root. Grant that role (time-boxed, the same pattern already used for enable_aad_diagnostics/ADR-033) and re-run, OR accept that ${TENANT_AAD_DIAG_SETTING_NAME} survives this teardown until a future run has that grant. NOT treated as clean - failing loud: ${AZ_RUN_STDERR}"
    exit 1
  fi
  echo "::error::tenant Microsoft.AadIam/diagnosticSettings list failed for an unexpected non-auth reason - a failed list is never read as 'no diagnostic settings' (section 9.4): ${AZ_RUN_STDERR}"
  exit 1
fi
# shellcheck disable=SC2154  # tenant_aad_diag_rows_out is assigned indirectly by az_run's printf -v
mapfile -t tenant_aad_diag_names <<< "$tenant_aad_diag_rows_out"
for name in "${tenant_aad_diag_names[@]:-}"; do
  [ -z "$name" ] && continue
  if [ "$name" != "$TENANT_AAD_DIAG_SETTING_NAME" ] && ! is_globaris_owned "$name"; then
    echo "  Skipping tenant AAD diagnostic setting ${name} - not estate-owned (not ${TENANT_AAD_DIAG_SETTING_NAME}, no 'globaris' substring)."
    continue
  fi
  echo "  Deleting tenant AAD diagnostic setting ${name}"
  tenant_aad_diag_url="${ARM_BASE}/providers/Microsoft.AadIam/diagnosticSettings/${name}?api-version=${TENANT_AAD_DIAGNOSTIC_SETTINGS_API_VERSION}"
  if ! tenant_aad_diag_del_out="$(az rest --method delete --url "$tenant_aad_diag_url" --output none 2>&1)"; then
    if is_auth_error "$tenant_aad_diag_del_out"; then
      echo "::error::tenant AAD diagnostic setting delete for ${name} failed with an auth/transport error - same Security Administrator gap as the list above: ${tenant_aad_diag_del_out}"
      exit 1
    fi
    echo "  ::warning::tenant AAD diagnostic setting delete for ${name} failed or already gone (continuing): ${tenant_aad_diag_del_out}"
  else
    # BELT-pattern confirm-GET (confirm_gone_or_warn_belt) - VERIFY 6f (teardown-verify.sh) is
    # the authoritative completion gate for this class. A confirm-GET auth failure here is
    # expected to be the SAME Security Administrator gap as the list/delete above, not a new
    # condition - confirm_gone_or_warn_belt still fails loud on it either way (pattern (b)
    # never downgrades an auth-shaped result).
    confirm_gone_or_warn_belt "tenant AAD diagnostic setting ${name}" "$tenant_aad_diag_url" || exit 1
  fi
done

# --- 7. Reconciliation: ONE bounded wait for everything submitted in steps 1-2 (section 9.3).
#     The wait lives here, never in Phase 3 VERIFY, which stays an instant unwaited truth-gate.
#     wait_for_rgs_gone calls az_relogin at the START of every iteration (section 9.2c), so this
#     can never outlive the token that started it, however long it runs (up to the 30-min
#     ceiling). Any RG still present at the ceiling is reported by Phase 3 VERIFY as a remnant -
#     re-dispatch (idempotent) is the safety net, never an in-workflow auto-retry. Step 6's
#     writes are synchronous sub-second control-plane calls, not RGs - intentionally NOT part
#     of this wait; VERIFY 6-8 and the QA pass are their completion gate instead. ---
echo "== Phase 2 step 7: reconciliation (bounded wait for submitted RGs, incl. Databricks managed) =="
declare -a reconcile_pairs=()
for i in "${!deleted_rgs[@]}"; do
  reconcile_pairs+=("${deleted_subs[$i]}" "${deleted_rgs[$i]}")
done
for i in "${!dbx_managed_rgs[@]}"; do
  reconcile_pairs+=("${dbx_managed_rg_subs[$i]}" "${dbx_managed_rgs[$i]}")
done
if [ "${#reconcile_pairs[@]}" -eq 0 ]; then
  echo "  Nothing submitted for deletion this run - reconciliation skipped."
else
  wait_for_rgs_gone "${reconcile_pairs[@]}"
  reconcile_rc=$?
  if [ "$reconcile_rc" -eq 2 ]; then
    # A re-login or an auth-classified existence check failed mid-wait - per section 10.3 this
    # is a hard non-zero exit for the whole script, not just a Phase-3-will-catch-it warning.
    echo "::error::reconciliation hit an auth/transport failure - failing loud (section 9.4), not treating this as a plain still-deleting straggler."
    exit 1
  elif [ "$reconcile_rc" -ne 0 ]; then
    echo "::warning::reconciliation did not confirm every submitted RG gone within the 30-min ceiling (a plain still-deleting straggler) - Phase 3 VERIFY will report any true remnant loudly; re-dispatch (idempotent) is the safety net."
  fi
fi

# --- 7b. Log Analytics workspace soft-delete purge (ADR-073 decision 4, 2026-08-01; generalises
#     OQ-063/ADR-066's single-workspace mechanism into a discovery-based, estate-wide sweep - see
#     this file's "AMENDED a twelfth time" note above for the full root cause and the two defects
#     this fix closes, and `law_purge_soft_deleted_workspaces`'s own comment (teardown-common.sh)
#     for the complete gate-by-gate mechanism (containment, blast-radius cap, REST-PUT recovery,
#     re-list completion check, strict per-entry ordering). The function lives in
#     teardown-common.sh, not inline here, so it can be sourced and exercised in isolation with a
#     stubbed `az` - the same reason `databricks_force_delete_cascade` and
#     `attachment_sweep_cross_root_objects` above are shared functions rather than inline steps.
#
#     STILL A BACKSTOP, not the primary purge mechanism, for the same reason as before: any root
#     that declares a Log Analytics workspace and sets
#     `features { log_analytics_workspace { permanently_delete_on_destroy = true } }` in its own
#     provider block purges that workspace NATIVELY as part of its own `terraform destroy`
#     (platform/security already does this; platform/management gains the same block under
#     ADR-073 decision 6, a Cloud Engineer fix tracked separately). This step remains
#     load-bearing PRIMARILY for mode=az-sweep (the state-gone fallback, which never runs
#     `terraform destroy` at all - ADR-065 decision 4), and as a genuine backstop for any older
#     root state applied before its own provider fix landed.
#
#     WHY THIS RUNS HERE (after step 7's reconcile): unchanged reasoning from the original
#     single-workspace version - step 2 submits every RG delete with --no-wait, and step 7's
#     wait_for_rgs_gone is the only bounded wait in this script for those submissions to actually
#     complete. Running this purge earlier would race any LAW-owning root's RG delete exactly the
#     way it used to race the security RG's: list-deleted-workspaces would find nothing yet, this
#     step would report clean, and the workspace would land in soft-delete UNPURGED minutes
#     later. A residual race still exists if step 7 hits its 30-min ceiling on a still-deleting
#     RG (warn-and-continue, matching every other straggler class in this script) - this step
#     would then find nothing for that one and report clean, idempotently retried on the
#     operator's own re-dispatch, not a new failure mode.
echo "== Phase 2 step 7b: Log Analytics workspace soft-delete purge (ADR-073 decision 4) =="
if ! law_purge_soft_deleted_workspaces; then
  exit 1
fi

echo "AZ SWEEP complete."
exit 0
