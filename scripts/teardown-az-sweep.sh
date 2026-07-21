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
#   6. Subscription scope (ADR-057, docs/teardown-redesign.md section 12.3): the four
#      subscription-scoped object classes (budgets, cost exports at api-version 2025-03-01,
#      cost anomaly scheduled actions, subscription diagnostic settings) across all 5 subs;
#      the Defender for Cloud pricing reset to Free from the DEFENDER_PLANS_TO_FREE allow-list
#      (security subscription only, teardown-common.sh); and the RP_NAMESPACES_TO_UNREGISTER
#      provider unregistration (management subscription only, strictly after the object-class
#      deletes). Runs after step 4 and before step 7 so nothing here races a live MG-scope
#      remediation and step 6's own submissions are covered by the existing reconcile + Phase 3.
#   7. Reconciliation: ONE bounded wait for every RG submitted in steps 1-2 to report gone.
#      Step 6's writes are synchronous sub-second control-plane calls, not RGs - they are
#      deliberately NOT added to this wait (wait_for_rgs_gone is RG-shaped); Phase 3 VERIFY
#      (VERIFY 6-8) and the QA pass are their completion gate instead.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

REMOVE_MG_HIERARCHY="${REMOVE_MG_HIERARCHY:-false}"

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
if [ "$REMOVE_MG_HIERARCHY" != "true" ]; then
  echo "  Skipped (remove_mg_hierarchy=false) - the MG tree is left in place."
else
  if ! mg_snapshot_load; then
    echo "::error::Step 4 cannot proceed without a trustworthy MG-existence snapshot."
    exit 1
  fi
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
ARM_BASE="https://management.azure.com"

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
  # Consumption budgets (Microsoft.Consumption/budgets, api-version 2023-05-01).
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
        --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.Consumption/budgets/${name}?api-version=2023-05-01" \
        --output none 2>&1)"; then
      if is_auth_error "$budget_del_out"; then
        echo "::error::budget delete for ${name} (sub ${sub}) failed with an auth/transport error: ${budget_del_out}"
        exit 1
      fi
      echo "  ::warning::budget delete for ${name} failed or already gone (continuing - idempotent retry on next run): ${budget_del_out}"
    fi
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
