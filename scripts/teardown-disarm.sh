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
# 2026-07-20 (third amendment / ADR-054 point 12; supersedes an earlier, also-corrected version
# of this same comment): a policy-assignment LIST call against a deleted MG scope does NOT
# return a genuine NotFound for the teardown SP - ARM evaluates RBAC on the scope BEFORE
# confirming it exists, and the SP's MG-scoped grants are deleted WITH the globaris subtree, so
# the read comes back HTTP-403 `AuthorizationFailed: ... or the scope is invalid. ... please
# refresh your credentials.`, which is_auth_error correctly matches (the "credentials" tail).
# This is why existence is resolved BEFORE any list call, by a ONE-TIME `az account
# management-group list` snapshot (see the amendment below and `mg_snapshot_load` in
# teardown-common.sh) rather than by inspecting any single call's error text, and NOT by a
# per-MG `az account management-group show` probe either - `show` is itself principal-dependent
# and 403s on a deleted MG for the same reason (proven empirically, probe run 29756715840).
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
# AMENDED again 2026-07-20 (second amendment / ADR-054 point 11) - SUPERSEDED by the third
# amendment below. That version gated the per-MG loop with `az account management-group show
# --name <mg>`, expecting a clean 404 on a deleted MG. Attempt 4 (run 29753193590) proved that
# expectation FALSE for the scoped teardown SP: `show` is itself principal-dependent and returns
# HTTP-403 `AuthorizationFailed` (not a 404) on a deleted MG, because the SP's MG-read grants are
# scoped to the globaris subtree and are deleted WITH it. DO NOT implement a `show`-based gate.
#
# AMENDED a third time 2026-07-20 (third amendment / ADR-054 point 12, docs/teardown-redesign.md
# sections 10.2 and 12) - MG-EXISTENCE via a ONE-TIME `az account management-group list`
# SNAPSHOT, not any per-MG `show`. Empirical proof (probe run 29756715840, run AS THE SP):
# `az account management-group list` SUCCEEDS and returns ONLY the tenant root (every deleted
# globaris-tree MG is ABSENT); `show --name globaris` returns 403; `show` on the tenant root
# itself succeeds (the SP's surviving grant, Management Group Contributor at the tenant root,
# identity.tf, is never deleted, and carries `managementGroups/read`). A `list` over that
# readable collection is therefore always available to the SP, and existence resolves by NAME
# MEMBERSHIP with NO per-scope call and so NO deleted-scope 403. Fix (`mg_snapshot_load` /
# `mg_in_snapshot`, teardown-common.sh):
#   - ONCE at the start of this script (before the per-MG loop), call `mg_snapshot_load`. A
#     failure there (the list call itself failing `is_auth_error`, or any non-zero) is FAIL LOUD
#     - it is the single call the SP is always entitled to make, so a failure is a genuine dead
#     token / transport error and DISARM cannot proceed without a trustworthy snapshot.
#   - In the per-MG loop, `mg_in_snapshot "$mg"` ABSENT -> the MG is gone -> `continue` (nothing
#     to disarm at a nonexistent scope; not a failure - this is the branch that makes a
#     re-dispatch against an already-empty estate pass DISARM cleanly). PRESENT -> proceed with
#     the identity-scan / role-assignment / policy-assignment logic below EXACTLY as today (a
#     dead token or a real permission gap at a LIVE scope must still fail loud - not loosened).
# `is_auth_error` is NOT loosened; the per-MG `show` is REMOVED entirely - it is never needed as
# an existence oracle (none of these sites need an EXISTING MG's detail as data, only its
# presence/absence).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

fail=0

# MG-existence snapshot (see the amendment comment at the top of this file) - ONE list call for
# the whole run, not a per-MG probe. A failure here is a genuine dead token / transport error
# (the single call the SP is always entitled to make) and DISARM cannot proceed without it.
if ! mg_snapshot_load; then
  echo "::error::DISARM cannot proceed without a trustworthy MG-existence snapshot."
  exit 1
fi

for mg in "${MG_SCOPES[@]}"; do
  scope="/providers/Microsoft.Management/managementGroups/${mg}"
  echo "== DISARM scope: ${mg} =="

  if ! mg_in_snapshot "$mg"; then
    echo "  MG ${mg}: gone (absent from the existing-MG snapshot) - nothing to disarm at a nonexistent scope."
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
    # 2026-07-20 auth-fail-loud sweep (docs/teardown-redesign.md section 10.1, class A): this
    # scope is CONFIRMED LIVE (mg_in_snapshot already gated it), so "scope no longer exists" is
    # impossible here - a non-auth, non-zero list at a live scope is a real error, never "no
    # data / already disarmed". Fail loud instead of silently proceeding with an empty identity
    # scan (which would skip the belt-and-suspenders role-assignment cleanup below it).
    echo "::error::DISARM: policy assignment (identity) list failed for scope ${mg} with a non-auth error at a confirmed-live scope - cannot treat this as empty: ${AZ_RUN_STDERR}"
    fail=1
    continue
  fi

  for row in "${identity_rows[@]:-}"; do
    [ -z "$row" ] && continue
    principal_id="$(printf '%s' "$row" | cut -f2)"
    [ -z "$principal_id" ] && continue
    echo "  Belt: checking role assignments for DINE identity ${principal_id} at ${mg}"
    # 2026-07-20 auth-fail-loud sweep (docs/teardown-redesign.md section 10.1, class A): uses
    # --assignee-object-id + --fill-principal-name false (both verified real `az role assignment
    # list` flags, CLI ref ms.date 2026-06-26) instead of --assignee, so a deleted-DINE-identity
    # Microsoft Graph resolution error cannot masquerade as this class and trip the new fail-loud
    # below - both flags bypass the Graph query entirely.
    if az_run role_ids_out role assignment list --scope "$scope" --assignee-object-id "$principal_id" \
        --fill-principal-name false --query "[].id" -o tsv; then
      # shellcheck disable=SC2154  # role_ids_out is assigned indirectly by az_run's printf -v
      mapfile -t role_ids <<< "$role_ids_out"
    elif is_auth_error "$AZ_RUN_STDERR"; then
      echo "::error::DISARM: role assignment list failed for identity ${principal_id} at scope ${mg} with an auth/transport error: ${AZ_RUN_STDERR}"
      fail=1
      continue
    else
      # This scope is CONFIRMED LIVE (mg_in_snapshot already gated it) - a non-auth, non-zero
      # list here is a real error, never "no data to remove". Fail loud instead of silently
      # skipping the belt-and-suspenders role-assignment cleanup for this identity.
      echo "::error::DISARM: role assignment list failed for identity ${principal_id} at scope ${mg} with a non-auth error at a confirmed-live scope - cannot treat this as empty: ${AZ_RUN_STDERR}"
      fail=1
      continue
    fi
    for rid in "${role_ids[@]:-}"; do
      [ -z "$rid" ] && continue
      echo "    Removing role assignment: ${rid}"
      # 2026-07-20 auth-fail-loud sweep (docs/teardown-redesign.md section 10.2, class B,
      # coherence only - the Databricks workspace delete already classifies auth this way).
      # An auth death here also hits the policy-assignment delete later in this loop, which
      # already sets fail=1, so DISARM still fails loud overall either way - this closes the
      # coherence gap, not a correctness defect.
      if ! role_del_out="$(az role assignment delete --ids "$rid" --output none 2>&1)"; then
        if is_auth_error "$role_del_out"; then
          echo "::error::DISARM: role assignment delete for ${rid} at ${mg} failed with an auth/transport error: ${role_del_out}"
          fail=1
        else
          echo "  ::warning::could not remove role assignment ${rid} (continuing - idempotent retry on next run): ${role_del_out}"
        fi
      fi
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
    # 2026-07-20 auth-fail-loud sweep (docs/teardown-redesign.md section 10.1, class A) - the
    # HIGHEST-SEVERITY of the three sites: this scope is CONFIRMED LIVE (mg_in_snapshot already
    # gated it), so "scope no longer exists" is impossible here. Silently `continue`-ing past a
    # non-auth list failure would certify this scope disarmed off a real error, re-opening the
    # F3 DINE-resurrection window this whole phase exists to close, while the run stays green.
    echo "::error::DISARM: policy assignment list failed for scope ${mg} with a non-auth error at a confirmed-live scope - cannot certify this scope disarmed: ${AZ_RUN_STDERR}"
    fail=1
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
