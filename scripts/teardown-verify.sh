#!/usr/bin/env bash
# scripts/teardown-verify.sh - Phase 3 VERIFY (ADR-054 / docs/teardown-redesign.md
# section 3). Runs ALWAYS, last, both modes. Asserts zero estate remnants and FAILS LOUDLY
# (non-zero) if anything is found. A green Phase 3 IS the definition of "teardown succeeded
# E2E" - the design's answer to "never a silent half-teardown" (design principle 5).
#
# AMENDED 2026-07-20 (ADR-054 amendment, docs/teardown-redesign.md sections 9-10, teardown
# run 29712487341): VERIFY stays an IMMEDIATE, unwaited assertion (the wait now lives in
# Phase 2's reconciliation step, never here - locked decision 9.3). Every az call below is
# hardened against the swallow bug that caused the incident: the old `2>/dev/null || echo "0"`
# and `2>/dev/null || true` patterns could not tell a genuinely empty/absent result from a dead
# OIDC token, so a truth-gate call that failed on auth silently "passed" as clean - the worst
# possible outcome for a completion gate. Every check below now captures stderr and, where the
# scope being queried can never legitimately be gone on its own (VERIFY 2/3/5 - subscriptions,
# which per design section 5 are only ever re-parented, never deleted), treats ANY non-zero
# list call as FAIL LOUD. Where a genuine NotFound is a legitimate, expected outcome (VERIFY 1's
# per-MG policy assignment list when remove_mg_hierarchy removed that MG; VERIFY 4's MG
# existence check, whose success condition IS "not found"), only an auth-classified failure
# (is_auth_error) fails loud - a real NotFound still reads as clean/gone, never treated as an
# unclassified pass-through.
#
# AMENDED again 2026-07-20 (code-review BLOCK, Finding #2): every list call whose SUCCESS-path
# output feeds a scalar comparison or `mapfile` now uses `az_run` (teardown-common.sh) instead
# of a bare `2>&1` capture. The az CLI writes WARNING banners to stderr even on a clean exit-0
# call - a merged capture could make a genuinely clean scope's length/count compare fail
# falsely (a false VERIFY BLOCK on a legitimately complete teardown). `az_run` keeps stdout
# (the data channel) and stderr (only inspected on the non-zero-exit path) fully separate.
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
  if az_run remaining policy assignment list --scope "$scope" --query "length(@)" -o tsv; then
    # shellcheck disable=SC2154  # remaining is assigned indirectly by az_run's printf -v
    if [ "${remaining:-0}" != "0" ]; then
      note_fail "MG ${mg} still has ${remaining} policy assignment(s) - DISARM did not fully complete."
    else
      echo "  ${mg}: clean (0 assignments)."
    fi
  elif is_auth_error "$AZ_RUN_STDERR"; then
    # A dead token here must NEVER be read as "0 assignments" (this is exactly bugs #2/#3 from
    # the 2026-07-20 incident) - fail loud instead of silently certifying this scope clean.
    note_fail "MG ${mg} policy assignment list failed with an auth/transport error - cannot certify this scope clean off a dead token: ${AZ_RUN_STDERR}"
  else
    # Not an auth error: the only other realistic non-zero here is the MG itself no longer
    # existing (a genuine NotFound, expected when remove_mg_hierarchy removed it in Phase 2).
    # VERIFY 4 below independently confirms the MG tree state, so this is not double-counted.
    echo "  ${mg}: clean (MG itself no longer exists): ${AZ_RUN_STDERR}"
  fi
done

# --- 2. No workload/platform/orphaned RGs remain (covers rg-amba-monitoring-001) ---
echo "== VERIFY 2: workload/platform RGs (naming pattern) =="
rg_clean=1
for sub in "${SUBS[@]}"; do
  if ! az_run rgs_out group list --subscription "$sub" --query "$RG_SWEEP_QUERY" -o tsv; then
    # Subscriptions are never deleted (design section 5 - only re-parented), so a failed list
    # here has no legitimate "scope gone" explanation - any non-zero is FAIL LOUD.
    note_fail "RG list failed for subscription ${sub} - a failed list is never read as 'no RGs' (a dead token would otherwise falsely certify this subscription clean): ${AZ_RUN_STDERR}"
    rg_clean=0
    continue
  fi
  # shellcheck disable=SC2154  # rgs_out is assigned indirectly by az_run's printf -v
  mapfile -t rgs <<< "$rgs_out"
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
  if az_run count databricks workspace list --subscription "$sub" --query "length(@)" -o tsv; then
    # shellcheck disable=SC2154  # count is assigned indirectly by az_run's printf -v
    if [ "${count:-0}" != "0" ]; then
      note_fail "${count} Databricks workspace(s) still present in subscription ${sub}."
    else
      echo "  sub ${sub}: clean (0 workspaces)."
    fi
  else
    # Same "subscription never deleted" reasoning as VERIFY 2 - any non-zero is FAIL LOUD.
    note_fail "Databricks workspace list failed for subscription ${sub} - a failed list is never read as 'no workspaces' (a dead token would otherwise falsely certify this subscription clean): ${AZ_RUN_STDERR}"
  fi
done

# --- 4. MG hierarchy gone, if remove_mg_hierarchy ---
if [ "$REMOVE_MG_HIERARCHY" = "true" ]; then
  echo "== VERIFY 4: MG hierarchy removed (remove_mg_hierarchy=true) =="
  for mg in "${MG_SCOPES[@]}"; do
    if mg_show_out="$(az account management-group show --name "$mg" --output none 2>&1)"; then
      note_fail "MG ${mg} still exists - remove_mg_hierarchy=true requires the full tree gone."
    elif is_auth_error "$mg_show_out"; then
      # The exact bug #2 from the 2026-07-20 incident: a dead token made 'show' fail and that
      # was misread as "already gone" for all 12 MGs. Never again - fail loud instead.
      note_fail "MG ${mg} existence check failed with an auth/transport error - cannot certify it gone off a dead token: ${mg_show_out}"
    else
      echo "  ${mg}: gone."
    fi
  done
else
  echo "== VERIFY 4: MG hierarchy check skipped (remove_mg_hierarchy=false for this run) =="
fi

# --- 5. Soft-deleted KVs report - the redeploy recover list. A failed list call here still
#     fails VERIFY loud (section 9.4 names az keyvault list-deleted explicitly); the CONTENT
#     of a successful list (vaults found or not) stays informational, never itself a remnant. ---
echo "== VERIFY 5: soft-deleted Key Vaults - redeploy recover list (informational content; list-call failures still fail loud) =="
for sub in "${SUBS[@]}"; do
  if ! az_run deleted_kvs_out keyvault list-deleted --subscription "$sub" \
      --query "[].[name, properties.purgeProtectionEnabled]" -o tsv; then
    note_fail "Key Vault list-deleted failed for subscription ${sub} - a failed list is never read as 'no soft-deleted vaults' (a dead token here would otherwise silently produce an incomplete redeploy-recover list): ${AZ_RUN_STDERR}"
    continue
  fi
  # shellcheck disable=SC2154  # deleted_kvs_out is assigned indirectly by az_run's printf -v
  mapfile -t deleted_kvs <<< "$deleted_kvs_out"
  for row in "${deleted_kvs[@]:-}"; do
    [ -z "$row" ] && continue
    echo "  sub ${sub}: ${row} (name, purgeProtectionEnabled - true means the redeploy must recover it, LESSON 56)"
  done
done

echo "----------------------------------------------------------------"
if [ "$fail" -ne 0 ]; then
  echo "::error::VERIFY FAILED - estate remnants remain (or a check could not be trusted). Teardown is NOT complete. Re-run (idempotent) to retry."
  exit 1
fi
echo "VERIFY PASSED - zero estate remnants. Teardown complete E2E."
exit 0
