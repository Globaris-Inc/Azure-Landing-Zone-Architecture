#!/usr/bin/env bash
# scripts/teardown-verify.sh - Phase 3 VERIFY (ADR-054 / docs/teardown-redesign.md
# section 3). Runs ALWAYS, last, both modes. Asserts zero estate remnants and FAILS LOUDLY
# (non-zero) if anything is found. A green Phase 3 IS the definition of "teardown succeeded
# E2E" - the design's answer to "never a silent half-teardown" (design principle 5).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

REMOVE_MG_HIERARCHY="${REMOVE_MG_HIERARCHY:-false}"

fail=0
note_fail() { echo "::error::$*"; fail=1; }

# --- 0. Subscription-ID resolution: expect all 5 (fail loud, not silently "clean") ---
# A missing secret must not make VERIFY silently skip a subscription and report "clean" for
# resources it never looked at - that would be exactly the silent-half-teardown failure mode
# this phase exists to prevent (design principle 5).
echo "== VERIFY 0: subscription-ID secrets resolved =="
EXPECTED_SUB_COUNT=5
missing_sub_names=""
[ -z "${MANAGEMENT_SUBSCRIPTION_ID:-}" ]   && missing_sub_names="$missing_sub_names MANAGEMENT_SUBSCRIPTION_ID"
[ -z "${CONNECTIVITY_SUBSCRIPTION_ID:-}" ] && missing_sub_names="$missing_sub_names CONNECTIVITY_SUBSCRIPTION_ID"
[ -z "${IDENTITY_SUBSCRIPTION_ID:-}" ]     && missing_sub_names="$missing_sub_names IDENTITY_SUBSCRIPTION_ID"
[ -z "${SECURITY_SUBSCRIPTION_ID:-}" ]     && missing_sub_names="$missing_sub_names SECURITY_SUBSCRIPTION_ID"
[ -z "${LANDINGZONES_SUBSCRIPTION_ID:-}" ] && missing_sub_names="$missing_sub_names LANDINGZONES_SUBSCRIPTION_ID"

mapfile -t SUBS < <(teardown_subscriptions)

if [ "${#SUBS[@]}" -ne "$EXPECTED_SUB_COUNT" ]; then
  note_fail "Resolved ${#SUBS[@]}/${EXPECTED_SUB_COUNT} expected subscription ID(s) - missing:${missing_sub_names:- (unknown)}. VERIFY cannot check resources in an unresolved subscription, so it would otherwise silently report 'clean' for one the estate actually uses. Fix the missing GitHub secret(s) and re-run."
else
  echo "  ${#SUBS[@]}/${EXPECTED_SUB_COUNT} subscription ID(s) resolved."
fi

# --- 1. No MG-scope policy assignments remain ---
echo "== VERIFY 1: MG-scope policy assignments =="
for mg in "${MG_SCOPES[@]}"; do
  scope="/providers/Microsoft.Management/managementGroups/${mg}"
  remaining="$(az policy assignment list --scope "$scope" --query "length(@)" -o tsv 2>/dev/null || echo "0")"
  if [ "${remaining:-0}" != "0" ]; then
    note_fail "MG ${mg} still has ${remaining} policy assignment(s) - DISARM did not fully complete."
  else
    echo "  ${mg}: clean (0 assignments, or MG itself no longer exists)."
  fi
done

# --- 2. No workload/platform/orphaned RGs remain (covers rg-amba-monitoring-001) ---
echo "== VERIFY 2: workload/platform RGs (naming pattern) =="
rg_clean=1
for sub in "${SUBS[@]}"; do
  mapfile -t rgs < <(az group list --subscription "$sub" --query "$RG_SWEEP_QUERY" -o tsv 2>/dev/null || true)
  for rg in "${rgs[@]:-}"; do
    [ -z "$rg" ] && continue
    note_fail "RG ${rg} still present in subscription ${sub}."
    rg_clean=0
  done
done
[ "$rg_clean" -eq 1 ] && echo "  clean (no rg-*-globaris-* or *amba-monitoring* RGs found in any of the ${#SUBS[@]} subscription(s) checked)."

# --- 3. Databricks workspaces gone (belt check independent of the RG naming pattern) ---
echo "== VERIFY 3: Databricks workspaces =="
for sub in "${SUBS[@]}"; do
  count="$(az databricks workspace list --subscription "$sub" --query "length(@)" -o tsv 2>/dev/null || echo "0")"
  if [ "${count:-0}" != "0" ]; then
    note_fail "${count} Databricks workspace(s) still present in subscription ${sub}."
  else
    echo "  sub ${sub}: clean (0 workspaces)."
  fi
done

# --- 4. MG hierarchy gone, if remove_mg_hierarchy ---
if [ "$REMOVE_MG_HIERARCHY" = "true" ]; then
  echo "== VERIFY 4: MG hierarchy removed (remove_mg_hierarchy=true) =="
  for mg in "${MG_SCOPES[@]}"; do
    if az account management-group show --name "$mg" --output none 2>/dev/null; then
      note_fail "MG ${mg} still exists - remove_mg_hierarchy=true requires the full tree gone."
    else
      echo "  ${mg}: gone."
    fi
  done
else
  echo "== VERIFY 4: MG hierarchy check skipped (remove_mg_hierarchy=false for this run) =="
fi

# --- 5. Soft-deleted KVs report (informational, not a failure condition) ---
echo "== VERIFY 5 (informational): soft-deleted Key Vaults - redeploy recover list =="
for sub in "${SUBS[@]}"; do
  mapfile -t deleted_kvs < <(az keyvault list-deleted --subscription "$sub" \
    --query "[].[name, properties.purgeProtectionEnabled]" -o tsv 2>/dev/null || true)
  for row in "${deleted_kvs[@]:-}"; do
    [ -z "$row" ] && continue
    echo "  sub ${sub}: ${row} (name, purgeProtectionEnabled - true means the redeploy must recover it, LESSON 56)"
  done
done

echo "----------------------------------------------------------------"
if [ "$fail" -ne 0 ]; then
  echo "::error::VERIFY FAILED - estate remnants remain. Teardown is NOT complete. Re-run (idempotent) to retry."
  exit 1
fi
echo "VERIFY PASSED - zero estate remnants. Teardown complete E2E."
exit 0
