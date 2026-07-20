#!/usr/bin/env bash
# scripts/teardown-disarm.sh - Phase 0 DISARM (ADR-054 / docs/teardown-redesign.md section 3).
#
# Deletes every MG-scope policy ASSIGNMENT across the globaris tree BEFORE any resource
# deletion, so DINE remediation cannot re-create resources while Phase 1/2 tear them down
# (fixes F3 - the rg-amba-monitoring-001 resurrection loop). Also removes any surviving role
# assignment held by a DINE policy's system-assigned identity, scoped at the SAME MG (belt -
# stops in-flight remediation from having rights even if a delete races the identity's own
# removal). The identity object itself is not deleted here - it has no purpose without both
# the role assignment AND the policy assignment, both gone after this script runs.
#
# Idempotent: listing/deleting an absent scope, assignment, or role assignment is a no-op,
# never an error - ARM delete operations are delete-if-exists (deleting an absent resource
# returns success, not a 404), and `az policy assignment delete` follows that same ARM
# semantics for a name that does not exist at a valid MG scope. A re-dispatch after a previous
# run already removed an MG (remove_mg_hierarchy=true) is a legitimate case too - CORRECTED
# 2026-07-20 (second amendment / ADR-054 point 11): a policy-assignment LIST call against that
# deleted MG scope does NOT return a genuine NotFound - ARM evaluates RBAC on the scope BEFORE
# confirming it exists, so the read comes back HTTP-403 `AuthorizationFailed: ... or the scope
# is invalid. ... please refresh your credentials.`, which is_auth_error correctly matches (the
# "credentials" tail). An earlier version of this comment claimed the opposite (a genuine
# NotFound) - that was factually wrong and is exactly why the MG-existence gate below exists:
# the disambiguation happens BEFORE the list call, by probing `az account management-group show`
# directly, not by inspecting the list call's own error text.
#
# NOTE for anyone testing this by hand on Windows Git Bash (MSYS): a leading "/" in --scope
# gets auto-converted to a Windows path by MSYS's POSIX-to-Windows path translation - this is
# the exact failure mode of earlier manual attempts (`Invalid value in --scope: 'C:/Program
# Files/Git/providers/...'`). Prefix the command with MSYS_NO_PATHCONV=1 for local testing.
# The GitHub Actions runner (ubuntu-latest, native Linux) has no such translation layer, so
# this script needs no workaround in CI - only local repro on Windows needs it.
#
# AMENDED 2026-07-20 (code-review BLOCK, Finding #1, docs/teardown-redesign.md section 9.4 /
# ADR-054 amendment point 9 - "the auth-fail-loud rule binds ALL three scripts"): this script
# previously swallowed every list call with `2>/dev/null || true`, so a dead/expired OIDC token
# (the same AADSTS700024 class as the 2026-07-20 incident) would read as "0 assignments -
# already disarmed" and DISARM would print "complete" and exit 0 having cleared nothing - while
# Phase 1/2 gate on `needs.disarm.result == 'success'`, so resource deletion would proceed with
# DINE policy assignments still live (reopening the exact F3 resurrection loop this phase
# exists to prevent). Every list call below now uses `az_run` (teardown-common.sh) - which
# keeps stdout (the data channel) and stderr fully separate, so a stderr WARNING banner on an
# otherwise-clean call can never corrupt the result either (Finding #2's same fix) - and
# classifies a non-zero exit with `is_auth_error`: an auth/transport failure is FAIL LOUD
# (fail=1, this scope is NOT counted as disarmed), never silently read as "already disarmed /
# scope gone".
#
# AMENDED again 2026-07-20 (second amendment / ADR-054 point 11, docs/teardown-redesign.md
# sections 10.2 and 11) - MG-EXISTENCE GATE, mandatory for a re-dispatch against an already-empty
# estate (attempt 4). The Finding #1 fix above correctly hardened the list calls, but it did NOT
# account for a re-dispatch AFTER a prior run already deleted the MGs (remove_mg_hierarchy=true):
# a policy-assignment list against a DELETED MG scope is not a clean NotFound - ARM evaluates RBAC
# on the scope BEFORE confirming it exists, so the read comes back HTTP-403 `AuthorizationFailed:
# ... or the scope is invalid. ... please refresh your credentials.`, which is_auth_error correctly
# matches (the "credentials" tail). Without a gate, that trips the `elif is_auth_error` branch on
# every already-deleted scope and fails DISARM loud at Phase 0, before VERIFY ever runs (this is
# LOAD-BEARING: run 29749656053 only reached VERIFY because Phase 0 ran while the MGs were still
# live - the same run's Phase 3 then failed on the mirror-image bug in VERIFY 1's policy list,
# see teardown-verify.sh). Fix: before ANY policy-assignment or role-assignment work for an MG,
# probe its existence with a direct capture (NOT az_run - only exit code + stderr are consumed):
# `mg_show_out="$(az account management-group show --name "$mg" --output none 2>&1)"`, mirroring
# the same oracle already used in teardown-verify.sh VERIFY 4 and teardown-az-sweep.sh step 4 -
# both of which correctly reported every MG gone in run 29749656053. Three-way branch:
#   - show succeeds -> MG EXISTS -> proceed with the identity-scan / role-assignment / policy-
#     assignment logic below EXACTLY as today (a dead token or a real permission gap at a LIVE
#     scope must still fail loud - this is not loosened).
#   - show fails AND is_auth_error -> genuine dead token/transport error probing existence itself
#     -> fail=1 (cannot certify this scope disarmed), continue to the next MG.
#   - show fails AND NOT is_auth_error -> genuine NotFound -> the MG is gone -> nothing to disarm
#     at a nonexistent scope -> continue (not a failure). This is the branch that makes a
#     re-dispatch against an already-empty estate pass DISARM cleanly.
# is_auth_error itself is NOT loosened - the disambiguation is scope existence, resolved by this
# gate, not by relaxing the classifier (which would re-open the exact swallow bug Finding #1 closed).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

fail=0

for mg in "${MG_SCOPES[@]}"; do
  scope="/providers/Microsoft.Management/managementGroups/${mg}"
  echo "== DISARM scope: ${mg} =="

  # MG-existence gate (see the amendment comment at the top of this file) - probe BEFORE any
  # policy/role-assignment work at this scope. Direct capture, not az_run: only the exit code
  # and stderr matter here, and this is the same oracle teardown-verify.sh VERIFY 4 and
  # teardown-az-sweep.sh step 4 already use successfully.
  if ! mg_show_out="$(az account management-group show --name "$mg" --output none 2>&1)"; then
    if is_auth_error "$mg_show_out"; then
      echo "::error::DISARM: MG ${mg} existence probe failed with an auth/transport error - cannot certify this scope disarmed off a dead token: ${mg_show_out}"
      fail=1
    else
      echo "  MG ${mg}: gone (genuine NotFound) - nothing to disarm at a nonexistent scope."
    fi
    continue
  fi

  # Capture (name, principalId) for DINE assignments with a system-assigned identity BEFORE
  # deleting the assignment - the identity's role assignment does not vanish with it.
  if az_run identity_rows_out policy assignment list --scope "$scope" \
      --query "[?identity!=null].[name,identity.principalId]" -o tsv; then
    # shellcheck disable=SC2154  # identity_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t identity_rows <<< "$identity_rows_out"
  elif is_auth_error "$AZ_RUN_STDERR"; then
    echo "::error::DISARM: policy assignment (identity) list failed for scope ${mg} with an auth/transport error - cannot certify this scope disarmed off a dead token: ${AZ_RUN_STDERR}"
    fail=1
    continue
  else
    echo "  (identity-scan) scope ${mg}: no data (already disarmed, or scope no longer exists): ${AZ_RUN_STDERR}"
    identity_rows=()
  fi

  for row in "${identity_rows[@]:-}"; do
    [ -z "$row" ] && continue
    principal_id="$(printf '%s' "$row" | cut -f2)"
    [ -z "$principal_id" ] && continue
    echo "  Belt: checking role assignments for DINE identity ${principal_id} at ${mg}"
    if az_run role_ids_out role assignment list --scope "$scope" --assignee "$principal_id" \
        --query "[].id" -o tsv; then
      # shellcheck disable=SC2154  # role_ids_out is assigned indirectly by az_run's printf -v
      mapfile -t role_ids <<< "$role_ids_out"
    elif is_auth_error "$AZ_RUN_STDERR"; then
      echo "::error::DISARM: role assignment list failed for identity ${principal_id} at scope ${mg} with an auth/transport error: ${AZ_RUN_STDERR}"
      fail=1
      continue
    else
      echo "  ::warning::role assignment list for ${principal_id} at ${mg}: no data (continuing): ${AZ_RUN_STDERR}"
      role_ids=()
    fi
    for rid in "${role_ids[@]:-}"; do
      [ -z "$rid" ] && continue
      echo "    Removing role assignment: ${rid}"
      az role assignment delete --ids "$rid" --output none 2>&1 || \
        echo "  ::warning::could not remove role assignment ${rid} (continuing - idempotent retry on next run)"
    done
  done

  # Delete every policy assignment at this scope (base ALZ + AMBA). Idempotent.
  if az_run assignment_names_out policy assignment list --scope "$scope" \
      --query "[].name" -o tsv; then
    # shellcheck disable=SC2154  # assignment_names_out is assigned indirectly by az_run's printf -v
    mapfile -t assignment_names <<< "$assignment_names_out"
  elif is_auth_error "$AZ_RUN_STDERR"; then
    # This is the exact Finding #1 bug: a dead token here must NEVER be read as "0 assignments -
    # already disarmed" - fail loud instead, so Phase 1/2 (gated on disarm success) do not
    # proceed while assignments may still be live.
    echo "::error::DISARM: policy assignment list failed for scope ${mg} with an auth/transport error - cannot certify this scope disarmed off a dead token: ${AZ_RUN_STDERR}"
    fail=1
    continue
  else
    echo "  No policy assignments at scope ${mg} (already disarmed, or scope no longer exists): ${AZ_RUN_STDERR}"
    continue
  fi

  if [ "${#assignment_names[@]}" -eq 0 ] || [ -z "${assignment_names[0]:-}" ]; then
    echo "  No policy assignments at scope ${mg} (already disarmed)."
    continue
  fi

  for name in "${assignment_names[@]}"; do
    [ -z "$name" ] && continue
    echo "  Deleting policy assignment: ${name}"
    if ! az policy assignment delete --name "$name" --scope "$scope" --output none 2>&1; then
      echo "  ::warning::failed to delete policy assignment ${name} at scope ${mg} (real error, not idempotent-absent - flagging)"
      fail=1
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "::error::DISARM finished with one or more real (non-idempotent) delete failures, or an auth/transport error that means a scope could not be certified disarmed - Phase 1 destroy will NOT proceed (phase-1 root jobs require disarm success). Phase 2/3 still run and will report the remaining assignments as remnants."
  exit 1
fi

echo "DISARM complete - all MG-scope policy assignments cleared."
exit 0
