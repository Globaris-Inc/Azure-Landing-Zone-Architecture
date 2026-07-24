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
# Order matters:
#   1. Databricks: submit the WORKSPACE delete --no-wait --force-deletion (never `az group
#      delete` the managed RG directly - it still carries an RP deny-assignment, F2, even with
#      --force-deletion in play; --force-deletion is what makes the WORKSPACE delete itself
#      cascade the managed RG cleanup instead of retaining it). The managed RG name is captured
#      here and waited on in the single reconcile step at the end, not polled in-line.
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
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

REMOVE_MG_HIERARCHY="${REMOVE_MG_HIERARCHY:-false}"

# ARM_BASE is sourced from teardown-common.sh (promoted there 2026-07-23,
# teardown-phase0-mg-sweep follow-up) - no local declaration here. Every step below (4-pre,
# 6a, 6d, 6e, 6f) shares that one value, so this script and teardown-disarm.sh's own MG-scope
# sweep (which reuses the same constant) can never drift on it.

mapfile -t SUBS < <(teardown_subscriptions)
if [ "${#SUBS[@]}" -eq 0 ]; then
  echo "::error::No subscription IDs available (MANAGEMENT_SUBSCRIPTION_ID / CONNECTIVITY_SUBSCRIPTION_ID / IDENTITY_SUBSCRIPTION_ID / SECURITY_SUBSCRIPTION_ID / LANDINGZONES_SUBSCRIPTION_ID all empty). Cannot sweep."
  exit 1
fi

# --- 1. Databricks: submit the workspace delete --no-wait --force-deletion (never wait
#     in-session, section 9.2a; --force-deletion is required to cascade the managed RG at all,
#     architect pre-clearance C1 - see the header comment above) ---
echo "== Phase 2 step 1: Databricks workspace cascade (submission only, --no-wait --force-deletion) =="
declare -a dbx_managed_rgs=()
declare -a dbx_managed_rg_subs=()
for sub in "${SUBS[@]}"; do
  if ! az_run dbx_rows_out databricks workspace list --subscription "$sub" \
      --query "[].[name, resourceGroup, managedResourceGroupId]" -o tsv; then
    echo "::error::Databricks workspace list failed for subscription ${sub} - a failed list is never read as 'no workspaces' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # dbx_rows_out is assigned indirectly by az_run's printf -v
  mapfile -t dbx_rows <<< "$dbx_rows_out"
  for row in "${dbx_rows[@]:-}"; do
    [ -z "$row" ] && continue
    ws_name="$(printf '%s' "$row" | cut -f1)"
    ws_rg="$(printf '%s' "$row" | cut -f2)"
    managed_rg_id="$(printf '%s' "$row" | cut -f3)"
    managed_rg_name="${managed_rg_id##*/}"
    echo "  Submitting delete for Databricks workspace ${ws_name} (rg ${ws_rg}, sub ${sub}, --no-wait --force-deletion) - cascades managed rg ${managed_rg_name}"
    if ! dbx_del_out="$(az databricks workspace delete --name "$ws_name" --resource-group "$ws_rg" \
        --subscription "$sub" --yes --no-wait --force-deletion --output none 2>&1)"; then
      if is_auth_error "$dbx_del_out"; then
        echo "::error::Databricks workspace delete submission for ${ws_name} failed with an auth/transport error: ${dbx_del_out}"
        exit 1
      fi
      echo "  ::warning::workspace delete submission for ${ws_name} failed or already gone (continuing - idempotent retry on next run): ${dbx_del_out}"
      continue
    fi
    if [ -n "$managed_rg_name" ]; then
      dbx_managed_rgs+=("$managed_rg_name")
      dbx_managed_rg_subs+=("$sub")
    fi
  done
done

# --- 2. General RG sweep by naming pattern, across all 5 subs (--no-wait submission). The
#     Databricks-managed RG is STILL excluded here even with --force-deletion in step 1: it
#     still carries the RP deny-assignment (F2) until the workspace's own force-delete cascade
#     completes, so a concurrent direct `az group delete` on it would race that cascade and is
#     doomed either way - the reconcile step (step 5) is what waits for it to actually clear. ---
echo "== Phase 2 step 2: RG sweep (naming pattern, --no-wait submission) =="
declare -a deleted_rgs=()
declare -a deleted_subs=()
for sub in "${SUBS[@]}"; do
  if ! az_run rgs_out group list --subscription "$sub" --query "$RG_SWEEP_QUERY" -o tsv; then
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
  if ! az_run kv_rows_out keyvault list --subscription "$sub" --query "$KV_QUERY" -o tsv; then
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

  if ! az_run deleted_kvs_out keyvault list-deleted --subscription "$sub" \
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
    dkv_pp="$(printf '%s' "$row" | cut -f3)"
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
# is_auth_error/mg_snapshot_ok discipline exists to prevent. Step 6a's own MG-scope budget
# sweep (FIX-2, further down this script) does its OWN fresh reload immediately before it runs
# (see that block's comment - it cannot safely reuse THIS load once step 4's delete loop has
# run, since a deleted MG would still read "present" against a snapshot taken before its
# deletion). One extra `az account management-group list` call per run either way (cheap,
# VERIFY already calls it unconditionally too).
if ! mg_snapshot_load; then
  echo "::error::Step 4 cannot proceed without a trustworthy MG-existence snapshot."
  exit 1
fi
if [ "$REMOVE_MG_HIERARCHY" != "true" ]; then
  echo "  Skipped (remove_mg_hierarchy=false) - the MG tree is left in place. (MG-existence snapshot above is still loaded for step 6a's MG-scope budget sweep.)"
else
  # --- 4-pre (FIX-1, teardown-completeness extension sweep, 2026-07-23). Sweeps every
  #     MG-scope EXTENSION resource - budgets, diagnostic settings, policy exemptions - across
  #     every MG still present in the snapshot, STRICTLY BEFORE the delete loop below issues a
  #     single `az account management-group delete`. Root cause this closes: an extension
  #     resource's ARM ID is formed by appending its own provider path onto WHATEVER scope it
  #     was attached to (an MG here) - ARM does NOT cascade-delete an extension resource when
  #     its host scope is deleted, so an orphaned MG-scoped exemption/budget/diagnostic-setting
  #     then COLLIDES the next time Step 1 (a later run) recreates an MG of the same name. This
  #     is a FULL sweep-all-MGs-first pass (not interleaved with the delete loop below) - that
  #     still satisfies "strictly before each delete" (every sweep call in this block completes
  #     before ANY `management-group delete` call runs) while leaving the tested delete loop's
  #     own body untouched.
  #
  #     Same conventions as every other step in this script: az_run for any list whose stdout
  #     feeds a compare/mapfile (Finding #2), is_auth_error auth-fail-loud on every non-zero
  #     list (an MG present in the snapshot can never legitimately fail a read at its own scope -
  #     same section 9.4 boundary VERIFY 1 already applies), idempotent-absent-is-success on
  #     every delete (is_owned_policy_object / is_globaris_owned decide the DELETE, not the
  #     LIST's success/failure).
  #
  #     NOTE added 2026-07-23 (teardown-phase0-mg-sweep fix): teardown-disarm.sh (Phase 0) now
  #     carries its own copy of this same sweep, run BEFORE any MG is deleted in either mode -
  #     see that script's fourth AMENDED header comment for the full root-cause. The `disarm`
  #     job in .github/workflows/teardown.yml gates only on `inputs.target == 'all'`, with no
  #     `inputs.mode` check, so it runs first in BOTH mode=terraform and mode=az-sweep. That
  #     makes THIS block (4-pre) a harmless remnant-catch no-op in both modes now, not only on
  #     the mode=terraform path - every MG-scope extension object it would have found here was
  #     already swept by teardown-disarm.sh earlier in the same run. Left in place deliberately
  #     as a second-line backstop (a re-dispatch with `target=platform/management-groups` only,
  #     or any future change that lets Phase 2 run without Phase 0 having run first, would still
  #     be covered) - not removed, not weakened.
  echo "== Phase 2 step 4-pre: MG-scope extension sweep (budgets, diagnostic settings, policy exemptions) - before any MG delete (FIX-1) =="
  for mg in "${MG_DELETE_ORDER[@]}"; do
    if ! mg_in_snapshot "$mg"; then
      echo "  MG ${mg}: already gone (absent from the snapshot) - nothing to sweep."
      continue
    fi
    mg_scope="$(mg_scope_path "$mg")"

    # Budgets (Microsoft.Consumption/budgets, BUDGETS_API_VERSION).
    if ! az_run mg_budget_names_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}" \
        --query "join(',',value[?contains(name,'globaris')].name)" -o tsv; then
      echo "::error::MG-scope budget list failed for MG ${mg} - a failed list is never read as 'no budgets' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # mg_budget_names_out is assigned indirectly by az_run's printf -v
    IFS=',' read -ra mg_budget_names <<< "$mg_budget_names_out"
    for name in "${mg_budget_names[@]:-}"; do
      [ -z "$name" ] && continue
      echo "  Deleting MG-scope budget ${name} (MG ${mg})"
      mg_budget_url="${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets/${name}?api-version=${BUDGETS_API_VERSION}"
      if ! mg_budget_del_out="$(az rest --method delete --url "$mg_budget_url" --output none 2>&1)"; then
        if is_auth_error "$mg_budget_del_out"; then
          echo "::error::MG-scope budget delete for ${name} (MG ${mg}) failed with an auth/transport error: ${mg_budget_del_out}"
          exit 1
        fi
        echo "  ::warning::MG-scope budget delete for ${name} (MG ${mg}) failed or already gone (continuing): ${mg_budget_del_out}"
      else
        # PRIMARY-pattern confirm-GET (code-review BLOCK-2 fix, 2026-07-23): this scope has no
        # separate Phase 3 VERIFY step (MG-scope objects are 403-shadowed once their MG is
        # deleted) - this confirm-GET IS the completion check, run here while the MG still
        # exists. See confirm_gone_or_fail_primary's own comment (teardown-common.sh).
        confirm_gone_or_fail_primary "MG-scope budget ${name} (MG ${mg})" "$mg_budget_url" || exit 1
      fi
    done

    # Diagnostic settings (management-GROUP diagnostic settings op group, DISTINCT from the
    # generic resource op group - MG_DIAGNOSTIC_SETTINGS_API_VERSION, see teardown-common.sh).
    if ! az_run mg_diag_names_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/microsoft.insights/diagnosticSettings?api-version=${MG_DIAGNOSTIC_SETTINGS_API_VERSION}" \
        --query "join(',',value[].name)" -o tsv; then
      echo "::error::MG-scope diagnostic-settings list failed for MG ${mg} - a failed list is never read as 'no diagnostic settings' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # mg_diag_names_out is assigned indirectly by az_run's printf -v
    IFS=',' read -ra mg_diag_names <<< "$mg_diag_names_out"
    for name in "${mg_diag_names[@]:-}"; do
      [ -z "$name" ] && continue
      if ! is_globaris_owned "$name"; then
        echo "  Skipping MG-scope diagnostic setting ${name} (MG ${mg}) - not estate-owned (no 'globaris' substring)."
        continue
      fi
      echo "  Deleting MG-scope diagnostic setting ${name} (MG ${mg})"
      mg_diag_url="${ARM_BASE}${mg_scope}/providers/microsoft.insights/diagnosticSettings/${name}?api-version=${MG_DIAGNOSTIC_SETTINGS_API_VERSION}"
      if ! mg_diag_del_out="$(az rest --method delete --url "$mg_diag_url" --output none 2>&1)"; then
        if is_auth_error "$mg_diag_del_out"; then
          echo "::error::MG-scope diagnostic setting delete for ${name} (MG ${mg}) failed with an auth/transport error: ${mg_diag_del_out}"
          exit 1
        fi
        echo "  ::warning::MG-scope diagnostic setting delete for ${name} (MG ${mg}) failed or already gone (continuing): ${mg_diag_del_out}"
      else
        # PRIMARY-pattern confirm-GET (BLOCK-2 fix) - see the budget block above for the full
        # rationale; identical here (no separate VERIFY step for MG scope).
        confirm_gone_or_fail_primary "MG-scope diagnostic setting ${name} (MG ${mg})" "$mg_diag_url" || exit 1
      fi
    done

    # Policy exemptions (atExactScope, POLICY_EXEMPTIONS_API_VERSION_NEW, is_owned_policy_object
    # predicate - same three-limb test 6d already uses, shared so the delete side can never
    # drift from what a future VERIFY-side check expects).
    if ! az_run mg_exemption_rows_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Authorization/policyExemptions?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}&\$filter=atExactScope()" \
        --query "value[].[name, properties.policyAssignmentId]" -o tsv; then
      echo "::error::MG-scope policy exemption list failed for MG ${mg} - a failed list is never read as 'no exemptions' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # mg_exemption_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t mg_exemption_rows <<< "$mg_exemption_rows_out"
    for row in "${mg_exemption_rows[@]:-}"; do
      [ -z "$row" ] && continue
      mg_ex_name="$(printf '%s' "$row" | cut -f1)"
      mg_ex_assignment_id="$(printf '%s' "$row" | cut -f2)"
      if ! is_owned_policy_object "$mg_ex_name" "$mg_ex_assignment_id"; then
        echo "  Skipping MG-scope policy exemption ${mg_ex_name} (MG ${mg}) - not estate-owned."
        continue
      fi
      echo "  Deleting MG-scope policy exemption ${mg_ex_name} (MG ${mg})"
      mg_exemption_url="${ARM_BASE}${mg_scope}/providers/Microsoft.Authorization/policyExemptions/${mg_ex_name}?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}"
      if ! mg_exemption_del_out="$(az rest --method delete --url "$mg_exemption_url" --output none 2>&1)"; then
        if is_auth_error "$mg_exemption_del_out"; then
          echo "::error::MG-scope policy exemption delete for ${mg_ex_name} (MG ${mg}) failed with an auth/transport error: ${mg_exemption_del_out}"
          exit 1
        fi
        echo "  ::warning::MG-scope policy exemption delete for ${mg_ex_name} (MG ${mg}) failed or already gone (continuing): ${mg_exemption_del_out}"
      else
        # PRIMARY-pattern confirm-GET (BLOCK-2 fix) - see the budget block above for the full
        # rationale; identical here (no separate VERIFY step for MG scope).
        confirm_gone_or_fail_primary "MG-scope policy exemption ${mg_ex_name} (MG ${mg})" "$mg_exemption_url" || exit 1
      fi
    done
  done

  for mg in "${MG_DELETE_ORDER[@]}"; do
    if ! mg_in_snapshot "$mg"; then
      echo "  MG ${mg} already gone (absent from the snapshot) - skipping."
      continue
    fi

    echo "  MG ${mg}: moving any attached subscriptions to the tenant root"
    if ! az_run mg_subs_out account management-group subscription show-sub-under-mg --name "$mg" \
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
#     exception: az_run for any call whose stdout is consumed as data (Trap 1), is_auth_error
#     classification on every non-zero (Trap 2), auth-fail-loud, idempotent-absent-is-success.
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
  if ! az_run budget_names_out consumption budget list --subscription "$sub" \
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
  if ! discover_live_rgs rg6a_names_out "$sub"; then
    echo "::error::RG list failed for subscription ${sub} while discovering RG-scope budget targets - a failed list is never read as 'no RGs' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # rg6a_names_out is assigned indirectly by az_run's printf -v
  mapfile -t rg6a_names <<< "$rg6a_names_out"
  for rg in "${rg6a_names[@]:-}"; do
    [ -z "$rg" ] && continue
    if ! az_run rg_budget_names_out rest --method get \
        --url "${ARM_BASE}/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}" \
        --query "join(',',value[?contains(name,'globaris')].name)" -o tsv; then
      echo "::error::RG-scope budget list failed for RG ${rg} (sub ${sub}) - a failed list is never read as 'no budgets' (section 9.4): ${AZ_RUN_STDERR}"
      exit 1
    fi
    # shellcheck disable=SC2154  # rg_budget_names_out is assigned indirectly by az_run's printf -v
    IFS=',' read -ra rg_budget_names <<< "$rg_budget_names_out"
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
  if ! az_run export_names_csv rest --method get \
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
  if ! az_run scheduled_action_names_csv rest --method get \
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
  if ! az_run diag_names_out monitor diagnostic-settings subscription list --subscription "$sub" \
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

# --- 6a (MG portion, FIX-2, teardown-completeness extension sweep, 2026-07-23). MG-scope
#     budgets, run UNCONDITIONALLY (once, not gated on remove_mg_hierarchy) over every MG
#     currently live. This is a DIFFERENT coverage window than FIX-1's step 4-pre sweep (which
#     only ever runs when remove_mg_hierarchy=true, immediately before that MG is deleted): a
#     run with remove_mg_hierarchy=false never reaches step 4-pre at all, so an MG-scope budget
#     left over from an EARLIER run (MG hierarchy kept in place) would otherwise never be swept.
#
#     FRESH RELOAD, NOT the step-4 snapshot (bug fix, code-review BLOCK-2 follow-up,
#     2026-07-23): this block originally reused the SAME MG_SNAPSHOT step 4 loaded at the very
#     start of the script. When remove_mg_hierarchy=true, step 4's own delete loop deletes MGs
#     BETWEEN that snapshot load and this block running later in the script - MG_SNAPSHOT is a
#     plain associative array, never updated after deletion, so mg_in_snapshot would have kept
#     reporting a just-deleted MG as "present" here, and this block would have attempted a
#     budget list against a scope the SP's grants were just deleted with (403
#     AuthorizationFailed - is_auth_error correctly matches it, so the whole run would exit 1
#     loud on a perfectly successful teardown). Reloading the snapshot HERE, immediately before
#     this loop, makes it reflect ground truth as of RIGHT NOW - any MG step 4 deleted earlier
#     in this same run correctly reads as absent and is skipped, no 403, no false failure.
if ! mg_snapshot_load; then
  echo "::error::Step 6a (MG scope) cannot proceed without a trustworthy MG-existence snapshot."
  exit 1
fi
echo "-- 6a (MG scope): consumption budgets --"
for mg in "${MG_DELETE_ORDER[@]}"; do
  if ! mg_in_snapshot "$mg"; then
    echo "  MG ${mg}: absent from the snapshot - nothing to sweep."
    continue
  fi
  mg_scope="$(mg_scope_path "$mg")"
  if ! az_run mg6a_budget_names_out rest --method get \
      --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}" \
      --query "join(',',value[?contains(name,'globaris')].name)" -o tsv; then
    echo "::error::MG-scope budget list failed for MG ${mg} - a failed list is never read as 'no budgets' (section 9.4): ${AZ_RUN_STDERR}"
    exit 1
  fi
  # shellcheck disable=SC2154  # mg6a_budget_names_out is assigned indirectly by az_run's printf -v
  IFS=',' read -ra mg6a_budget_names <<< "$mg6a_budget_names_out"
  for name in "${mg6a_budget_names[@]:-}"; do
    [ -z "$name" ] && continue
    echo "  Deleting MG-scope budget ${name} (MG ${mg})"
    mg6a_budget_url="${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets/${name}?api-version=${BUDGETS_API_VERSION}"
    if ! mg6a_budget_del_out="$(az rest --method delete --url "$mg6a_budget_url" --output none 2>&1)"; then
      if is_auth_error "$mg6a_budget_del_out"; then
        echo "::error::MG-scope budget delete for ${name} (MG ${mg}) failed with an auth/transport error: ${mg6a_budget_del_out}"
        exit 1
      fi
      echo "  ::warning::MG-scope budget delete for ${name} (MG ${mg}) failed or already gone (continuing): ${mg6a_budget_del_out}"
    else
      # PRIMARY-pattern confirm-GET (BLOCK-2 fix) - no separate VERIFY step exists for MG
      # scope (same rationale as FIX-1's confirm-GETs above).
      confirm_gone_or_fail_primary "MG-scope budget ${name} (MG ${mg})" "$mg6a_budget_url" || exit 1
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
  if ! az_run exemption_rows_out rest --method get \
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
    if ! az_run rg_exemption_rows_out rest --method get \
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
#       (i)   securityContacts - subscription-scoped singleton-per-name, discovered by LIST
#             (never hardcoded - platform/security/main.tf names it
#             "security-contact-${var.org_prefix}", a custom name the current API allows, not
#             the historical fixed "default") and deleted if is_globaris_owned.
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
#     az_run for stdout-as-data, is_auth_error auth-fail-loud on non-zero list (a live
#     subscription's own-scope list can never legitimately fail), idempotent-absent-is-success
#     on delete.
echo "-- 6e: Microsoft.Security singletons (security contacts, automations, auto-provisioning, workspace settings) --"
if [ -z "${SECURITY_SUBSCRIPTION_ID:-}" ]; then
  echo "::error::SECURITY_SUBSCRIPTION_ID is empty - cannot sweep Microsoft.Security singletons. This is already a VERIFY 0 failure class; failing loud here too rather than silently skipping."
  exit 1
fi

# (i) securityContacts
if ! az_run sec_contact_rows_out rest --method get \
    --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/securityContacts?api-version=${SECURITY_CONTACTS_API_VERSION}" \
    --query "value[].name" -o tsv; then
  echo "::error::securityContacts list failed for the security subscription - a failed list is never read as 'no contacts' (section 9.4): ${AZ_RUN_STDERR}"
  exit 1
fi
# shellcheck disable=SC2154  # sec_contact_rows_out is assigned indirectly by az_run's printf -v
mapfile -t sec_contact_names <<< "$sec_contact_rows_out"
for name in "${sec_contact_names[@]:-}"; do
  [ -z "$name" ] && continue
  if ! is_globaris_owned "$name"; then
    echo "  Skipping security contact ${name} - not estate-owned (no 'globaris' substring)."
    continue
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
if ! az_run sec_automation_rows_out rest --method get \
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
if ! az_run sec_autoprov_rows_out rest --method get \
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

if ! az_run sec_workspace_rows_out rest --method get \
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
if ! az_run tenant_aad_diag_rows_out rest --method get \
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

echo "AZ SWEEP complete."
exit 0
