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
# semantics for a name that does not exist at a valid MG scope.
#
# NOTE for anyone testing this by hand on Windows Git Bash (MSYS): a leading "/" in --scope
# gets auto-converted to a Windows path by MSYS's POSIX-to-Windows path translation - this is
# the exact failure mode of earlier manual attempts (`Invalid value in --scope: 'C:/Program
# Files/Git/providers/...'`). Prefix the command with MSYS_NO_PATHCONV=1 for local testing.
# The GitHub Actions runner (ubuntu-latest, native Linux) has no such translation layer, so
# this script needs no workaround in CI - only local repro on Windows needs it.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

fail=0

for mg in "${MG_SCOPES[@]}"; do
  scope="/providers/Microsoft.Management/managementGroups/${mg}"
  echo "== DISARM scope: ${mg} =="

  # Capture (name, principalId) for DINE assignments with a system-assigned identity BEFORE
  # deleting the assignment - the identity's role assignment does not vanish with it.
  mapfile -t identity_rows < <(az policy assignment list --scope "$scope" \
    --query "[?identity!=null].[name,identity.principalId]" -o tsv 2>/dev/null || true)

  for row in "${identity_rows[@]:-}"; do
    [ -z "$row" ] && continue
    principal_id="$(printf '%s' "$row" | cut -f2)"
    [ -z "$principal_id" ] && continue
    echo "  Belt: checking role assignments for DINE identity ${principal_id} at ${mg}"
    mapfile -t role_ids < <(az role assignment list --scope "$scope" --assignee "$principal_id" \
      --query "[].id" -o tsv 2>/dev/null || true)
    for rid in "${role_ids[@]:-}"; do
      [ -z "$rid" ] && continue
      echo "    Removing role assignment: ${rid}"
      az role assignment delete --ids "$rid" --output none 2>&1 || \
        echo "  ::warning::could not remove role assignment ${rid} (continuing - idempotent retry on next run)"
    done
  done

  # Delete every policy assignment at this scope (base ALZ + AMBA). Idempotent.
  mapfile -t assignment_names < <(az policy assignment list --scope "$scope" \
    --query "[].name" -o tsv 2>/dev/null || true)

  if [ "${#assignment_names[@]}" -eq 0 ] || [ -z "${assignment_names[0]:-}" ]; then
    echo "  No policy assignments at scope ${mg} (already disarmed, or scope no longer exists)."
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
  echo "::error::DISARM finished with one or more real (non-idempotent) delete failures - Phase 1 destroy will NOT proceed (phase-1 root jobs require disarm success). Phase 2/3 still run and will report the remaining assignments as remnants."
  exit 1
fi

echo "DISARM complete - all MG-scope policy assignments cleared."
exit 0
