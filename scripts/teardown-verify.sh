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
#
# AMENDED a third time 2026-07-21 (ADR-057, docs/teardown-redesign.md section 12.3): added
# VERIFY 6-8 - the four subscription-scoped object classes, the Defender for Cloud pricing
# reset to Free, and the resource-provider unregistration. These check exactly the surface
# Phase 2 step 6 (teardown-az-sweep.sh) now sweeps; see that step's header comment for the
# full root-cause account of why this surface was missing. Same subscription-scoped
# fail-loud boundary as VERIFY 2/3/5 above (a subscription can never legitimately be gone, so
# ANY non-zero list is a hard failure, never read as "clean").
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

# --- MG-existence snapshot (2026-07-20, third amendment / ADR-054 point 12, docs/teardown-
#     redesign.md sections 10.4 and 12) - ONE `az account management-group list` call for the
#     whole script, shared by VERIFY 1 (below) and VERIFY 4. REPLACES the second-amendment
#     per-MG `az account management-group show` gate (ADR-054 point 11, SUPERSEDED): `show` is
#     itself principal-dependent for the scoped teardown SP - its MG-read grants are scoped to
#     the globaris subtree (identity.tf) and are deleted WITH it, so `show` on a deleted MG
#     returns HTTP-403 `AuthorizationFailed` (NOT a clean 404), which is_auth_error correctly
#     matches, so a `show`-based gate fails loud on every benign already-gone MG (attempt 4, run
#     29753193590). Empirical proof (probe run 29756715840, run AS THE SP): `list` SUCCEEDS and
#     returns only the tenant root (every deleted globaris-tree MG absent); `show --name
#     globaris` returns 403. The SP's surviving grant (Management Group Contributor at the
#     tenant root, identity.tf, never deleted) carries managementGroups/read, so a `list` over
#     that readable collection is always available - existence resolves by NAME MEMBERSHIP, no
#     per-scope call, no deleted-scope 403. `mg_snapshot_load` (teardown-common.sh) is
#     auth-fail-loud on its own: a non-zero list is the single call the SP is always entitled to
#     make, so a failure there is a genuine dead token / transport error and VERIFY cannot
#     proceed without a trustworthy snapshot. `is_auth_error` is NOT loosened; the per-MG `show`
#     is REMOVED from VERIFY entirely (neither VERIFY 1 nor VERIFY 4 needs an EXISTING MG's
#     detail as data, only its presence/absence).
#
# GUARD: `mg_snapshot_load` resets MG_SNAPSHOT to empty before attempting the list, so on a
# FAILED load every `mg_in_snapshot` check would otherwise read as "absent" - i.e. every MG
# would be silently reported "clean (gone)" below off the back of a snapshot we know is
# untrustworthy. That is exactly the false-clean failure mode section 9.4 exists to prevent, so
# `mg_snapshot_ok` gates VERIFY 1 and VERIFY 4 below: on a failed load, neither loop runs (the
# note_fail here already fails the whole script) and each prints an explicit "cannot certify"
# notice instead of a misleading per-scope "clean". ---
mg_snapshot_ok=1
if ! mg_snapshot_load; then
  note_fail "VERIFY cannot proceed without a trustworthy MG-existence snapshot (az account management-group list failed - see the error above)."
  mg_snapshot_ok=0
fi

# --- 1. No MG-scope policy assignments remain ---
# Membership in the snapshot above: MG PRESENT -> list its assignments with auth-fail-loud
# UNCHANGED (a dead token or a real permission gap at a LIVE scope must still fail loud - not
# loosened). MG ABSENT -> the MG is gone -> VERIFY 4 below owns the gone-assertion for
# remove_mg_hierarchy=true; here it is simply not a remnant (not double-counted).
echo "== VERIFY 1: MG-scope policy assignments =="
if [ "$mg_snapshot_ok" -eq 0 ]; then
  echo "  Skipped - no trustworthy MG-existence snapshot (see the failure above); every MG-scope check is unresolved, not clean."
else
  for mg in "${MG_SCOPES[@]}"; do
    scope="/providers/Microsoft.Management/managementGroups/${mg}"
    if ! mg_in_snapshot "$mg"; then
      echo "  ${mg}: clean (MG gone - VERIFY 4 owns the gone-assertion)."
      continue
    fi
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
      note_fail "MG ${mg} policy assignment list failed for an unexpected non-auth reason at a LIVE scope - cannot certify this scope clean: ${AZ_RUN_STDERR}"
    fi
  done
fi

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
# Uses the SAME snapshot loaded above (shared with VERIFY 1, not re-fetched) - the assertion is
# now name-ABSENCE from that snapshot, not a per-MG `show` (removed - see the amendment comment
# above VERIFY 1: `show` 403s for the scoped SP on a deleted MG, which is exactly bug #2 from
# the 2026-07-20 incident re-manifesting through a different call). Same mg_snapshot_ok guard:
# a failed snapshot must never let this loop silently certify the hierarchy gone.
if [ "$REMOVE_MG_HIERARCHY" = "true" ]; then
  echo "== VERIFY 4: MG hierarchy removed (remove_mg_hierarchy=true) =="
  if [ "$mg_snapshot_ok" -eq 0 ]; then
    echo "  Skipped - no trustworthy MG-existence snapshot (see the failure above); cannot certify the hierarchy gone."
  else
    for mg in "${MG_SCOPES[@]}"; do
      if mg_in_snapshot "$mg"; then
        note_fail "MG ${mg} still exists (present in the snapshot) - remove_mg_hierarchy=true requires the full tree gone."
      else
        echo "  ${mg}: gone."
      fi
    done
  fi
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

# --- 6. Subscription-scoped object classes (ADR-057, docs/teardown-redesign.md section
#     12.3, added 2026-07-21) - the 2026-07-20 blind spot: consumption budgets, cost exports
#     (api-version 2025-03-01 - LOAD-BEARING, do NOT simplify to a default/older version, an
#     older version reads these as absent), cost anomaly scheduled actions, and subscription
#     diagnostic settings. Same list calls and API versions as Phase 2 step 6a. A
#     SUBSCRIPTION-scoped list can never legitimately be gone (design section 6 boundary), so
#     ANY non-zero here is FAIL LOUD, matching VERIFY 2/3/5 above - never read a failed list
#     as "no objects". ---
echo "== VERIFY 6: subscription-scoped object classes (budgets, cost exports, cost anomaly, diagnostic settings) =="
ARM_BASE="https://management.azure.com"
v6_clean=1
for sub in "${SUBS[@]}"; do
  if ! az_run budget_names_out consumption budget list --subscription "$sub" \
      --query "[?contains(name,'globaris')].name" -o tsv; then
    note_fail "consumption budget list failed for subscription ${sub} - a failed list is never read as 'no budgets' (a dead token would otherwise falsely certify this subscription clean): ${AZ_RUN_STDERR}"
    v6_clean=0
  else
    # shellcheck disable=SC2154  # budget_names_out is assigned indirectly by az_run's printf -v
    mapfile -t budget_names <<< "$budget_names_out"
    for name in "${budget_names[@]:-}"; do
      [ -z "$name" ] && continue
      note_fail "Subscription budget ${name} still present in subscription ${sub}."
      v6_clean=0
    done
  fi

  if ! az_run export_names_csv rest --method get \
      --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.CostManagement/exports?api-version=2025-03-01" \
      --query "join(',',value[?contains(name,'globaris')].name)" -o tsv; then
    note_fail "cost export list (api-version 2025-03-01) failed for subscription ${sub} - a failed list is never read as 'no exports' (a dead token would otherwise falsely certify this subscription clean; an older API version would also falsely read these as absent, which is exactly the 2026-07-16 false negative - 2025-03-01 is mandatory here): ${AZ_RUN_STDERR}"
    v6_clean=0
  else
    # shellcheck disable=SC2154  # export_names_csv is assigned indirectly by az_run's printf -v
    IFS=',' read -ra export_names <<< "$export_names_csv"
    for name in "${export_names[@]:-}"; do
      [ -z "$name" ] && continue
      note_fail "Cost export ${name} still present in subscription ${sub}."
      v6_clean=0
    done
  fi

  if ! az_run scheduled_action_names_csv rest --method get \
      --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.CostManagement/scheduledActions?api-version=2023-11-01" \
      --query "join(',',value[?contains(name,'globaris')].name)" -o tsv; then
    note_fail "cost anomaly scheduled action list failed for subscription ${sub} - a failed list is never read as 'no scheduled actions' (a dead token would otherwise falsely certify this subscription clean): ${AZ_RUN_STDERR}"
    v6_clean=0
  else
    # shellcheck disable=SC2154  # scheduled_action_names_csv is assigned indirectly by az_run's printf -v
    IFS=',' read -ra scheduled_action_names <<< "$scheduled_action_names_csv"
    for name in "${scheduled_action_names[@]:-}"; do
      [ -z "$name" ] && continue
      note_fail "Cost anomaly scheduled action ${name} still present in subscription ${sub}."
      v6_clean=0
    done
  fi

  if ! az_run diag_names_out monitor diagnostic-settings subscription list --subscription "$sub" \
      --query "value[].name" -o tsv; then
    note_fail "subscription diagnostic-settings list failed for subscription ${sub} - a failed list is never read as 'no diagnostic settings' (a dead token would otherwise falsely certify this subscription clean): ${AZ_RUN_STDERR}"
    v6_clean=0
  else
    # shellcheck disable=SC2154  # diag_names_out is assigned indirectly by az_run's printf -v
    mapfile -t diag_names <<< "$diag_names_out"
    for name in "${diag_names[@]:-}"; do
      [ -z "$name" ] && continue
      # Same ownership test as Phase 2 step 6a: the estate name (diag-activity-to-security-law)
      # is not org-prefixed, so a plain globaris-substring test alone would miss it.
      case "$name" in
        *globaris*|diag-activity-to-security-law)
          note_fail "Subscription diagnostic setting ${name} still present in subscription ${sub}."
          v6_clean=0
          ;;
        *) ;; # not estate-owned - not a remnant
      esac
    done
  fi
done
[ "$v6_clean" -eq 1 ] && echo "  clean (no estate-owned budgets, cost exports, cost anomaly scheduled actions, or subscription diagnostic settings found in any of the ${#SUBS[@]} subscription(s) checked)."

# --- 7. Defender for Cloud pricing reset to Free (security subscription only). Every plan in
#     DEFENDER_PLANS_TO_FREE (teardown-common.sh, mirrors platform/security exactly) must read
#     pricingTier == Free. Plans the estate does not configure are not asserted on and must
#     not have been changed (Phase 2 step 6b never touches them either). ---
echo "== VERIFY 7: Defender for Cloud pricing plans reset to Free (security subscription) =="
if [ -z "${SECURITY_SUBSCRIPTION_ID:-}" ]; then
  note_fail "SECURITY_SUBSCRIPTION_ID is empty - cannot certify Defender pricing (already counted by VERIFY 0)."
elif az_run pricing_rows_out rest --method get \
    --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/pricings?api-version=2024-01-01" \
    --query "value[].[name, properties.pricingTier]" -o tsv; then
  # shellcheck disable=SC2154  # pricing_rows_out is assigned indirectly by az_run's printf -v
  mapfile -t pricing_rows <<< "$pricing_rows_out"
  for plan in "${DEFENDER_PLANS_TO_FREE[@]}"; do
    tier=""
    for row in "${pricing_rows[@]:-}"; do
      [ -z "$row" ] && continue
      row_name="$(printf '%s' "$row" | cut -f1)"
      if [ "$row_name" = "$plan" ]; then
        tier="$(printf '%s' "$row" | cut -f2)"
        break
      fi
    done
    if [ "$tier" = "Free" ]; then
      echo "  ${plan}: clean (Free)."
    elif [ -z "$tier" ]; then
      note_fail "Defender plan ${plan} not found in the pricing list for the security subscription - cannot certify Free."
    else
      note_fail "Defender plan ${plan} still reads '${tier}' (expected Free) in the security subscription."
    fi
  done
else
  # Subscription-scoped list - per design section 6 boundary, ANY non-zero is FAIL LOUD.
  note_fail "Defender pricing list failed for the security subscription - a failed list is never read as 'all Free' (a dead token would otherwise falsely certify this subscription clean): ${AZ_RUN_STDERR}"
fi

# --- 8. Resource-provider unregistration (management subscription only). Every namespace in
#     RP_NAMESPACES_TO_UNREGISTER must read a registration state that is not Registered.
#     Unregistering is async - Unregistering is accepted as a pass with a notice rather than a
#     failure, since the submission is async and VERIFY never waits (design section 3 Phase 3
#     contract - patience belongs to the ACTOR, instant judgment to the AUDITOR). ---
echo "== VERIFY 8: resource-provider unregistration (management subscription) =="
if [ -z "${MANAGEMENT_SUBSCRIPTION_ID:-}" ]; then
  note_fail "MANAGEMENT_SUBSCRIPTION_ID is empty - cannot certify provider registration state (already counted by VERIFY 0)."
else
  for ns in "${RP_NAMESPACES_TO_UNREGISTER[@]}"; do
    if az_run reg_state_out provider show --namespace "$ns" --subscription "$MANAGEMENT_SUBSCRIPTION_ID" \
        --query registrationState -o tsv; then
      # shellcheck disable=SC2154  # reg_state_out is assigned indirectly by az_run's printf -v
      if [ "$reg_state_out" = "Registered" ]; then
        note_fail "Resource provider ${ns} still reads 'Registered' in the management subscription."
      elif [ "$reg_state_out" = "Unregistering" ]; then
        echo "  ::notice::${ns}: 'Unregistering' (async transition in progress, not yet certified - a later VERIFY run or the QA pass should confirm it reaches a terminal not-Registered state)."
      else
        echo "  ${ns}: clean (${reg_state_out})."
      fi
    else
      # Subscription-scoped read - per design section 6 boundary, ANY non-zero is FAIL LOUD.
      note_fail "provider show for ${ns} failed in the management subscription - a failed read is never read as 'not registered' (a dead token would otherwise falsely certify this clean): ${AZ_RUN_STDERR}"
    fi
  done
fi

echo "----------------------------------------------------------------"
if [ "$fail" -ne 0 ]; then
  echo "::error::VERIFY FAILED - estate remnants remain (or a check could not be trusted). Teardown is NOT complete. Re-run (idempotent) to retry."
  exit 1
fi
echo "VERIFY PASSED - zero estate remnants. Teardown complete E2E."
exit 0
