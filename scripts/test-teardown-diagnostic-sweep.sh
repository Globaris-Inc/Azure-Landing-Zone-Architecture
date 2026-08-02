#!/usr/bin/env bash
# scripts/test-teardown-diagnostic-sweep.sh - regression suite for
# `sweep_resource_diagnostic_settings` (teardown-common.sh), the shared body behind BOTH Phase 0.5
# (teardown-diagnostic-precascade.sh, ADR-071 decision 4b) and Phase 2 step 2-pre
# (teardown-az-sweep.sh, ADR-063 decision 5).
#
# Stubs `az` entirely with a bash function - never a real Azure call. Read-only against the live
# estate, dispatches nothing.
#
# WHY THIS SUITE EXISTS AT ALL. ADR-071 decision 4b calls the extraction "a refactor with no
# behaviour change at the existing site". That sentence is a claim, and the same shape of claim
# went unchecked earlier the same day: the LAW purge shipped a `law_get_live` that could never
# work, behind a 28/28 suite, because its `az` stub emitted TAB-separated output where the real
# CLI emits one value per LINE. A refactor that moves a body across files and swaps `exit 1` for
# `return 1` is exactly where an out-var indirection or a control-flow path silently changes.
#
# THE FIXTURE SHAPE IS LOAD-BEARING, so it is stated once here. Every `--query` this function
# issues projects an array of SCALARS (`[?...].name`, `[].id`, `value[].name`), which `-o tsv`
# renders ONE VALUE PER LINE. No tab is involved anywhere in this code path. If a future change
# introduces a multi-field row projection here, it becomes tab-separated and these fixtures must
# change with it - do not assume the two shapes are interchangeable.
#
# COVERED: the happy path; multi-resource / multi-setting nesting (which is also what proves the
# `printf -v` out-var indirection survived the move into a function with its own locals - the exact
# dynamic-scope shadowing bug that broke law_get_live); the deliberately asymmetric list-failure
# handling (auth-shaped fails loud, anything else is expected noise for a resource type that does
# not support diagnostic settings and skips only that resource); delete failure; a confirm-GET that
# still reports the object LIVE; and RG-list failure. Every failure case asserts BOTH a non-zero
# return AND the loud ::error:: text, never just one.
#
# Usage: scripts/test-teardown-diagnostic-sweep.sh
# Exit 0 = all cases pass, 1 = at least one case failed.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 2
cd "$repo_root" || exit 2
# shellcheck source=./teardown-common.sh
source scripts/teardown-common.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Deterministic and fast: none of these cases exercise az_run_retry's transient-retry path, and
# this keeps the suite's runtime independent of that function's own attempt/sleep constants.
AZ_RUN_RETRY_ATTEMPTS=1
AZ_RUN_RETRY_SLEEP_SECONDS=0

# One fake estate subscription is enough to exercise teardown_subscriptions()/is_estate_owned.
export MANAGEMENT_SUBSCRIPTION_ID="11111111-1111-1111-1111-111111111111"
unset CONNECTIVITY_SUBSCRIPTION_ID IDENTITY_SUBSCRIPTION_ID SECURITY_SUBSCRIPTION_ID LANDINGZONES_SUBSCRIPTION_ID 2>/dev/null || true
SUB="$MANAGEMENT_SUBSCRIPTION_ID"
RG="rg-test-globaris-poc"
RID1="/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.ContainerService/managedClusters/aks-1"
RID2="/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.ContainerRegistry/registries/acr1"

pass=0; failed=0
record() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then
    printf '  PASS  %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"; failed=$((failed + 1))
  fi
}

echo "== sweep_resource_diagnostic_settings =="

# ---------------------------------------------------------------------------------------------
# Case 1: happy path. One RG, one resource, one setting: listed, deleted, confirmed gone, rc 0.
# ---------------------------------------------------------------------------------------------
log1="$tmp/case1.log"; : > "$log1"
az() {
  case "$*" in
    *"group list"*)     printf '%s\n' "$RG"; return 0 ;;
    *"resource list"*)  printf '%s\n' "$RID1"; return 0 ;;
    *"value[].name"*)   printf '%s\n' "diag-aks-1"; return 0 ;;
    *"--method delete"*) echo "delete:$*" >> "$log1"; return 0 ;;
    *"--method get"*)   echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;   # confirm-GET
    *) echo "UNEXPECTED:$*" >> "$log1"; return 1 ;;
  esac
}
out1="$(sweep_resource_diagnostic_settings 2>&1)"; rc1=$?
record "happy path: returns 0" "$([ "$rc1" -eq 0 ] && echo 1 || echo 0)"
record "happy path: issues the DELETE for the discovered setting" \
  "$(grep -qF 'diagnosticSettings/diag-aks-1' "$log1" && echo 1 || echo 0)"
record "happy path: logs the deletion by name and host" \
  "$(printf '%s' "$out1" | grep -qF 'Deleting resource-scoped diagnostic setting diag-aks-1' && echo 1 || echo 0)"
record "happy path: emits no ::error::" \
  "$(printf '%s' "$out1" | grep -qF '::error::' && echo 0 || echo 1)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 2: nesting - two resources, two settings on the first. Proves the loops iterate fully AND
# that the az_run_retry `printf -v` out-vars still reach this function's own locals after the
# extraction (if that indirection had broken the way law_get_live's did, enumeration would yield
# nothing and zero deletes would fire).
# ---------------------------------------------------------------------------------------------
log2="$tmp/case2.log"; : > "$log2"
az() {
  case "$*" in
    *"group list"*)    printf '%s\n' "$RG"; return 0 ;;
    *"resource list"*) printf '%s\n%s\n' "$RID1" "$RID2"; return 0 ;;
    *"value[].name"*)
      case "$*" in
        *"managedClusters/aks-1"*) printf '%s\n%s\n' "diag-aks-1" "diag-aks-2"; return 0 ;;
        *) printf '%s\n' "diag-acr-1"; return 0 ;;
      esac ;;
    *"--method delete"*) echo "delete:$*" >> "$log2"; return 0 ;;
    *"--method get"*)   echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;
    *) echo "UNEXPECTED:$*" >> "$log2"; return 1 ;;
  esac
}
out2="$(sweep_resource_diagnostic_settings 2>&1)"; rc2=$?
record "nesting: returns 0" "$([ "$rc2" -eq 0 ] && echo 1 || echo 0)"
record "nesting: all THREE settings across TWO resources are deleted" \
  "$([ "$(grep -cF -- '--method delete' "$log2")" -eq 3 ] && echo 1 || echo 0)"
record "nesting: the second setting on the first resource is not dropped" \
  "$(grep -qF 'diagnosticSettings/diag-aks-2' "$log2" && echo 1 || echo 0)"
record "nesting: the second RESOURCE is reached (out-var indirection survived the extraction)" \
  "$(grep -qF 'diagnosticSettings/diag-acr-1' "$log2" && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 3: a NON-auth list failure is expected noise (resource type that does not support
# diagnostic settings). It must skip THAT RESOURCE ONLY, not abort, and not be read as "has none"
# for a sibling that does support them.
# ---------------------------------------------------------------------------------------------
log3="$tmp/case3.log"; : > "$log3"
az() {
  case "$*" in
    *"group list"*)    printf '%s\n' "$RG"; return 0 ;;
    *"resource list"*) printf '%s\n%s\n' "$RID1" "$RID2"; return 0 ;;
    *"value[].name"*)
      case "$*" in
        *"managedClusters/aks-1"*)
          echo "ERROR: (BadRequest) The resource type does not support diagnostic settings." >&2; return 1 ;;
        *) printf '%s\n' "diag-acr-1"; return 0 ;;
      esac ;;
    *"--method delete"*) echo "delete:$*" >> "$log3"; return 0 ;;
    *"--method get"*)   echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;
    *) echo "UNEXPECTED:$*" >> "$log3"; return 1 ;;
  esac
}
out3="$(sweep_resource_diagnostic_settings 2>&1)"; rc3=$?
record "unsupported type: returns 0 (expected noise, not a failure)" "$([ "$rc3" -eq 0 ] && echo 1 || echo 0)"
record "unsupported type: emits no ::error::" \
  "$(printf '%s' "$out3" | grep -qF '::error::' && echo 0 || echo 1)"
record "unsupported type: the SIBLING resource is still swept (skip is per-resource, not global)" \
  "$(grep -qF 'diagnosticSettings/diag-acr-1' "$log3" && echo 1 || echo 0)"
record "unsupported type: nothing is deleted for the unsupported resource" \
  "$(grep -qF 'managedClusters/aks-1/providers/Microsoft.Insights' "$log3" && echo 0 || echo 1)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 4: an AUTH-shaped list failure is the one that fails LOUD. This is the asymmetry that
# keeps an auth problem from being silently misread as "this resource has no settings".
# ---------------------------------------------------------------------------------------------
log4="$tmp/case4.log"; : > "$log4"
az() {
  case "$*" in
    *"group list"*)    printf '%s\n' "$RG"; return 0 ;;
    *"resource list"*) printf '%s\n' "$RID1"; return 0 ;;
    *"value[].name"*)  echo "ERROR: AADSTS700024: Client assertion is not within its valid time range." >&2; return 1 ;;
    *"--method delete"*) echo "delete:$*" >> "$log4"; return 0 ;;
    *) echo "UNEXPECTED:$*" >> "$log4"; return 1 ;;
  esac
}
out4="$(sweep_resource_diagnostic_settings 2>&1)"; rc4=$?
record "auth-shaped list failure: returns non-zero" "$([ "$rc4" -ne 0 ] && echo 1 || echo 0)"
record "auth-shaped list failure: reports it as an ::error::" \
  "$(printf '%s' "$out4" | grep -qF '::error::' && printf '%s' "$out4" | grep -qiF 'auth/transport error' && echo 1 || echo 0)"
record "auth-shaped list failure: deletes nothing" \
  "$([ ! -s "$log4" ] && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 5: the DELETE itself fails. Must return non-zero, say so loudly, and never reach its
# confirm-GET (a confirm on an unattempted delete would be meaningless).
# ---------------------------------------------------------------------------------------------
log5="$tmp/case5.log"; : > "$log5"
az() {
  case "$*" in
    *"group list"*)    printf '%s\n' "$RG"; return 0 ;;
    *"resource list"*) printf '%s\n' "$RID1"; return 0 ;;
    *"value[].name"*)  printf '%s\n' "diag-aks-1"; return 0 ;;
    *"--method delete"*) echo "ERROR: (Conflict) simulated delete failure for test purposes only." >&2; return 1 ;;
    *"--method get"*)  echo "confirm-get:$*" >> "$log5"; echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;
    *) echo "UNEXPECTED:$*" >> "$log5"; return 1 ;;
  esac
}
out5="$(sweep_resource_diagnostic_settings 2>&1)"; rc5=$?
record "delete failure: returns non-zero" "$([ "$rc5" -ne 0 ] && echo 1 || echo 0)"
record "delete failure: reports it as an ::error::" \
  "$(printf '%s' "$out5" | grep -qF '::error::' && printf '%s' "$out5" | grep -qiF 'delete for diag-aks-1' && echo 1 || echo 0)"
record "delete failure: never runs the confirm-GET on an unattempted delete" \
  "$(grep -qF 'confirm-get:' "$log5" && echo 0 || echo 1)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 6: the delete SUCCEEDS but the confirm-GET still reports the object LIVE. This class has no
# separate Phase 3 VERIFY step, so the confirm-GET is its only completion check and a still-live
# result has to be a hard failure rather than a warning.
# ---------------------------------------------------------------------------------------------
az() {
  case "$*" in
    *"group list"*)    printf '%s\n' "$RG"; return 0 ;;
    *"resource list"*) printf '%s\n' "$RID1"; return 0 ;;
    *"value[].name"*)  printf '%s\n' "diag-aks-1"; return 0 ;;
    *"--method delete"*) return 0 ;;
    *"--method get"*)  return 0 ;;   # still LIVE after a successful delete
    *) return 1 ;;
  esac
}
out6="$(sweep_resource_diagnostic_settings 2>&1)"; rc6=$?
record "confirm-GET still live: returns non-zero (never a silent pass)" "$([ "$rc6" -ne 0 ] && echo 1 || echo 0)"
record "confirm-GET still live: reports the remnant as an ::error::" \
  "$(printf '%s' "$out6" | grep -qF '::error::' && printf '%s' "$out6" | grep -qiF 'still confirmed LIVE' && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 7: the RG list itself fails. A failed list is never read as "no RGs" (section 9.4).
# ---------------------------------------------------------------------------------------------
az() {
  case "$*" in
    *"group list"*) echo "ERROR: (InternalServerError) simulated RG list failure for test purposes only." >&2; return 1 ;;
    *) return 1 ;;
  esac
}
out7="$(sweep_resource_diagnostic_settings 2>&1)"; rc7=$?
record "RG list failure: returns non-zero" "$([ "$rc7" -ne 0 ] && echo 1 || echo 0)"
record "RG list failure: reports it as an ::error:: and never reads it as 'no RGs'" \
  "$(printf '%s' "$out7" | grep -qF '::error::' && printf '%s' "$out7" | grep -qiF 'RG list failed' && echo 1 || echo 0)"
unset -f az

echo
echo "test-teardown-diagnostic-sweep: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
