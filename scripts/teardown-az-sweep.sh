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
#   5. Reconciliation: ONE bounded wait for every RG submitted in steps 1-2 to report gone.
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

# --- 5. Reconciliation: ONE bounded wait for everything submitted in steps 1-2 (section 9.3).
#     The wait lives here, never in Phase 3 VERIFY, which stays an instant unwaited truth-gate.
#     wait_for_rgs_gone calls az_relogin at the START of every iteration (section 9.2c), so this
#     can never outlive the token that started it, however long it runs (up to the 30-min
#     ceiling). Any RG still present at the ceiling is reported by Phase 3 VERIFY as a remnant -
#     re-dispatch (idempotent) is the safety net, never an in-workflow auto-retry. ---
echo "== Phase 2 step 5: reconciliation (bounded wait for submitted RGs, incl. Databricks managed) =="
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
