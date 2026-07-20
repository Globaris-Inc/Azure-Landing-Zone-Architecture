#!/usr/bin/env bash
# scripts/teardown-az-sweep.sh - Phase 2 AZ SWEEP (ADR-054 / docs/teardown-redesign.md
# section 3). Fallback for the state-gone case (mode=az-sweep) AND a remnant-catch pass
# after Phase 1 terraform-destroy (mode=terraform). Idempotent throughout: every delete is
# safe to re-run - an absent target is success, not an error. Never hard-fails on its own;
# Phase 3 VERIFY is the loud, authoritative completion gate (docs/teardown-redesign.md
# design principle 5).
#
# Order matters:
#   1. Databricks: delete the WORKSPACE resource (never `az group delete` the managed RG
#      directly - it carries an RP deny-assignment, F2). Deleting the workspace cascades the
#      managed RG cleanup; wait for it to clear before the general RG sweep so the sweep's
#      own group-delete calls do not race the RP's own cleanup of the same RG.
#   2. General RG sweep by naming pattern across all 5 workload/platform subscriptions.
#   3. Key Vault: soft-delete triggers automatically on any deletion path (direct or via
#      step 1/2's cascade), so this step deletes any live vault the sweep pattern still
#      finds (belt, in case of a race with step 2's --no-wait), then purges non-purge-
#      protected soft-deleted vaults and records purge-protected ones for the redeploy
#      runbook (LESSON 56).
#   4. Management-group hierarchy removal - ONLY if remove_mg_hierarchy=true. Bottom-up:
#      move each MG's subscriptions to the tenant root, then delete the now-empty MG.
#      Subscriptions are never deleted, only re-parented (docs/teardown-redesign.md
#      section 5).
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

wait_for_rg_gone() {
  # $1 = subscription id, $2 = rg name, $3 = timeout seconds (default 600)
  local sub="$1" rg="$2" timeout="${3:-600}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if [ "$(az group exists --name "$rg" --subscription "$sub")" = "false" ]; then
      echo "    ${rg} gone (waited ${waited}s)."
      return 0
    fi
    sleep 20
    waited=$((waited + 20))
  done
  echo "  ::warning::${rg} still present after ${timeout}s - it may still be deleting; Phase 3 VERIFY will catch it if not."
  return 1
}

# --- 1. Databricks: delete the workspace (never the managed RG directly, F2) ---
echo "== Phase 2 step 1: Databricks workspace cascade =="
for sub in "${SUBS[@]}"; do
  mapfile -t dbx_rows < <(az databricks workspace list --subscription "$sub" \
    --query "[].[name, resourceGroup, managedResourceGroupId]" -o tsv 2>/dev/null || true)
  for row in "${dbx_rows[@]:-}"; do
    [ -z "$row" ] && continue
    ws_name="$(printf '%s' "$row" | cut -f1)"
    ws_rg="$(printf '%s' "$row" | cut -f2)"
    managed_rg_id="$(printf '%s' "$row" | cut -f3)"
    managed_rg_name="${managed_rg_id##*/}"
    echo "  Deleting Databricks workspace ${ws_name} (rg ${ws_rg}, sub ${sub}) - cascades managed rg ${managed_rg_name}"
    az databricks workspace delete --name "$ws_name" --resource-group "$ws_rg" \
      --subscription "$sub" --yes --output none 2>&1 || \
      echo "  ::warning::workspace delete for ${ws_name} failed or already gone (continuing)"
    if [ -n "$managed_rg_name" ]; then
      wait_for_rg_gone "$sub" "$managed_rg_name" 600 || true
    fi
  done
done

# --- 2. General RG sweep by naming pattern, across all 5 subs ---
echo "== Phase 2 step 2: RG sweep (naming pattern) =="
declare -a deleted_rgs=()
declare -a deleted_subs=()
for sub in "${SUBS[@]}"; do
  mapfile -t rgs < <(az group list --subscription "$sub" --query "$RG_SWEEP_QUERY" -o tsv 2>/dev/null || true)
  for rg in "${rgs[@]:-}"; do
    [ -z "$rg" ] && continue
    echo "  Deleting RG ${rg} (sub ${sub}, no-wait)"
    az group delete --name "$rg" --subscription "$sub" --yes --no-wait --output none 2>&1 || \
      echo "  ::warning::delete request for ${rg} failed (continuing - idempotent retry on next run)"
    deleted_rgs+=("$rg")
    deleted_subs+=("$sub")
  done
done
for i in "${!deleted_rgs[@]}"; do
  wait_for_rg_gone "${deleted_subs[$i]}" "${deleted_rgs[$i]}" 600 || true
done

# --- 3. Key Vault: delete any live match (belt), then purge non-purge-protected soft-deletes ---
echo "== Phase 2 step 3: Key Vault soft-delete / purge =="
KV_QUERY="[?contains(resourceGroup,'globaris') || contains(resourceGroup,'amba-monitoring')].[name,resourceGroup]"
for sub in "${SUBS[@]}"; do
  mapfile -t kv_rows < <(az keyvault list --subscription "$sub" --query "$KV_QUERY" -o tsv 2>/dev/null || true)
  for row in "${kv_rows[@]:-}"; do
    [ -z "$row" ] && continue
    kv_name="$(printf '%s' "$row" | cut -f1)"
    kv_rg="$(printf '%s' "$row" | cut -f2)"
    echo "  Deleting live Key Vault ${kv_name} (rg ${kv_rg}, sub ${sub}) - soft-deletes"
    az keyvault delete --name "$kv_name" --resource-group "$kv_rg" --subscription "$sub" --output none 2>&1 || \
      echo "  ::warning::delete for KV ${kv_name} failed or already gone (continuing)"
  done

  mapfile -t deleted_kvs < <(az keyvault list-deleted --subscription "$sub" \
    --query "[].[name, properties.location, properties.purgeProtectionEnabled]" -o tsv 2>/dev/null || true)
  for row in "${deleted_kvs[@]:-}"; do
    [ -z "$row" ] && continue
    dkv_name="$(printf '%s' "$row" | cut -f1)"
    dkv_loc="$(printf '%s' "$row" | cut -f2)"
    dkv_pp="$(printf '%s' "$row" | cut -f3)"
    if [ "$dkv_pp" = "true" ]; then
      echo "  PURGE-PROTECTED (retention applies, cannot purge): ${dkv_name} (${dkv_loc}, sub ${sub}). Redeploy must set recover_soft_deleted_key_vaults=true (LESSON 56) or use a fresh name."
    else
      echo "  Purging (not purge-protected): ${dkv_name} (${dkv_loc}, sub ${sub})"
      az keyvault purge --name "$dkv_name" --location "$dkv_loc" --subscription "$sub" --output none 2>&1 || \
        echo "  ::warning::purge for ${dkv_name} failed (continuing - Phase 3 will report if it still blocks a name)"
    fi
  done
done

# --- 4. MG hierarchy removal, gated on remove_mg_hierarchy ---
echo "== Phase 2 step 4: MG hierarchy removal (remove_mg_hierarchy=${REMOVE_MG_HIERARCHY}) =="
if [ "$REMOVE_MG_HIERARCHY" != "true" ]; then
  echo "  Skipped (remove_mg_hierarchy=false) - the MG tree is left in place."
else
  for mg in "${MG_DELETE_ORDER[@]}"; do
    if ! az account management-group show --name "$mg" --output none 2>/dev/null; then
      echo "  MG ${mg} already gone - skipping."
      continue
    fi
    echo "  MG ${mg}: moving any attached subscriptions to the tenant root"
    mapfile -t mg_subs < <(az account management-group subscription show-sub-under-mg --name "$mg" \
      --query "[].name" -o tsv 2>/dev/null || true)
    for sub_id in "${mg_subs[@]:-}"; do
      [ -z "$sub_id" ] && continue
      echo "    Removing subscription ${sub_id} from ${mg} (re-parents to tenant root)"
      az account management-group subscription remove --name "$mg" --subscription "$sub_id" --output none 2>&1 || \
        echo "  ::warning::could not remove subscription ${sub_id} from ${mg} (continuing - Phase 3 will report if the MG still cannot delete)"
    done
    echo "  Deleting management group ${mg}"
    az account management-group delete --name "$mg" --output none 2>&1 || \
      echo "  ::warning::could not delete MG ${mg} (continuing - Phase 3 will report if it remains, likely still has a child or subscription)"
  done
fi

echo "AZ SWEEP complete."
exit 0
