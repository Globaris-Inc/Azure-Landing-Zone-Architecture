#!/usr/bin/env bash
# scripts/test-teardown-diagnostic-sweep.sh - regression suite for
# `sweep_resource_diagnostic_settings` (teardown-common.sh), the shared body behind BOTH Phase 0.5
# (teardown-diagnostic-precascade.sh, ADR-071 decision 4b) and Phase 2 step 1-pre (renamed from
# step 2-pre by ADR-076 decision 1) (teardown-az-sweep.sh, ADR-063 decision 5).
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
# ADR-076 (2026-08-10) ADDITIONS, fixture-RED-first (doctrine 2d) against the live incident
# (teardown run 31350223388: the precascade died mid-enumeration on
# rg-bank-data-p1-dbx-managed-globaris-poc, ResourceGroupNotFound, leaving every RG after it
# unswept while the job still reported SUCCESS): a vanished RG mid-sweep (host-absent, loud, the
# sweep continues to the REMAINING RGs instead of aborting); a vanished RESOURCE mid-sweep (same
# shape, one level down); the found/confirmed/unreachable completeness accounting, exercised on
# BOTH axes independently (unreachable-hosts > 0 alone, and found != confirmed alone via a partial
# delete failure that does not stop the sweep from reaching a sibling setting); the ordering edge
# added to teardown.yml (a block-scoped structural check, not a full YAML parse - see that case's
# own comment for why); and the az-sweep step reorder in teardown-az-sweep.sh. Proved RED against
# the pre-ADR-076 code before the fix landed - see docs/worklog for the exact before/after counts.
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

# ---------------------------------------------------------------------------------------------
# Case 8 (ADR-076 decision 2): a RESOURCE GROUP vanishes MID-SWEEP - the per-RG `resource list`
# call for one RG fails ResourceGroupNotFound-shaped (the exact live shape from teardown run
# 31350223388: rg-bank-data-p1-dbx-managed-globaris-poc, force-deleted out-of-band by the
# concurrently-racing Databricks precascade before this sweep's ordering barrier existed). This
# must be LOUD (never silently read as "no resources here") and must NOT be a job-killing hard
# stop - the sweep has to continue enumerating every RG queued after the vanished one.
# ---------------------------------------------------------------------------------------------
log8="$tmp/case8.log"; : > "$log8"
RG_GONE="rg-vanished-globaris-poc"
az() {
  case "$*" in
    *"group list"*) printf '%s\n%s\n' "$RG_GONE" "$RG"; return 0 ;;
    *"resource list --resource-group ${RG_GONE} "*)
      echo "ERROR: (ResourceGroupNotFound) Resource group '${RG_GONE}' could not be found." >&2; return 1 ;;
    *"resource list"*)  printf '%s\n' "$RID1"; return 0 ;;
    *"value[].name"*)   printf '%s\n' "diag-aks-1"; return 0 ;;
    *"--method delete"*) echo "delete:$*" >> "$log8"; return 0 ;;
    *"--method get"*)   echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;
    *) echo "UNEXPECTED:$*" >> "$log8"; return 1 ;;
  esac
}
out8="$(sweep_resource_diagnostic_settings 2>&1)"; rc8=$?
record "RG vanishes mid-sweep: returns non-zero (unreachable-hosts nonzero)" "$([ "$rc8" -ne 0 ] && echo 1 || echo 0)"
record "RG vanishes mid-sweep: reported loud, with 'vanished mid-enumeration' in the text" \
  "$(printf '%s' "$out8" | grep -qF '::error::' && printf '%s' "$out8" | grep -qF 'vanished mid-enumeration' && echo 1 || echo 0)"
record "RG vanishes mid-sweep: does NOT abort the whole sweep - the SURVIVING RG is still swept" \
  "$(grep -qF 'diagnosticSettings/diag-aks-1' "$log8" && echo 1 || echo 0)"
record "RG vanishes mid-sweep: summary reports mid-sweep-unreachable-hosts=1" \
  "$(printf '%s' "$out8" | grep -qF 'mid-sweep-unreachable-hosts=1' && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 9 (ADR-076 decision 2): a single RESOURCE (not its whole RG) vanishes mid-sweep - its
# diagnosticSettings LIST fails ResourceNotFound-shaped. Same requirement one level down: loud,
# not silently folded into the "type does not support diagnostic settings" noise bucket, and the
# SIBLING resource in the same RG must still be swept.
# ---------------------------------------------------------------------------------------------
log9="$tmp/case9.log"; : > "$log9"
az() {
  case "$*" in
    *"group list"*)    printf '%s\n' "$RG"; return 0 ;;
    *"resource list"*) printf '%s\n%s\n' "$RID1" "$RID2"; return 0 ;;
    *"value[].name"*)
      case "$*" in
        *"managedClusters/aks-1"*)
          echo "ERROR: (ResourceNotFound) The Resource 'Microsoft.ContainerService/managedClusters/aks-1' under resource group '${RG}' was not found." >&2; return 1 ;;
        *) printf '%s\n' "diag-acr-1"; return 0 ;;
      esac ;;
    *"--method delete"*) echo "delete:$*" >> "$log9"; return 0 ;;
    *"--method get"*)   echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;
    *) echo "UNEXPECTED:$*" >> "$log9"; return 1 ;;
  esac
}
out9="$(sweep_resource_diagnostic_settings 2>&1)"; rc9=$?
record "resource vanishes mid-sweep: returns non-zero" "$([ "$rc9" -ne 0 ] && echo 1 || echo 0)"
record "resource vanishes mid-sweep: reported loud, with 'vanished mid-sweep' in the text" \
  "$(printf '%s' "$out9" | grep -qF '::error::' && printf '%s' "$out9" | grep -qF 'vanished mid-sweep' && echo 1 || echo 0)"
record "resource vanishes mid-sweep: the SIBLING resource's setting is still deleted" \
  "$(grep -qF 'diagnosticSettings/diag-acr-1' "$log9" && echo 1 || echo 0)"
record "resource vanishes mid-sweep: summary reports mid-sweep-unreachable-hosts=1" \
  "$(printf '%s' "$out9" | grep -qF 'mid-sweep-unreachable-hosts=1' && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 10 (ADR-076 decision 2, completeness accounting axis 1): settings-found ==
# settings-confirmed-gone can STILL be true while mid-sweep-unreachable-hosts > 0 - SUCCESS
# requires BOTH conjuncts, so this must fail even though every setting the sweep actually reached
# was deleted and confirmed clean.
# ---------------------------------------------------------------------------------------------
RG_GONE2="rg-vanished2-globaris-poc"
az() {
  case "$*" in
    *"group list"*) printf '%s\n%s\n' "$RG" "$RG_GONE2"; return 0 ;;
    *"resource list --resource-group ${RG_GONE2} "*)
      echo "ERROR: (ResourceGroupNotFound) Resource group '${RG_GONE2}' could not be found." >&2; return 1 ;;
    *"resource list"*)  printf '%s\n' "$RID1"; return 0 ;;
    *"value[].name"*)   printf '%s\n%s\n' "diag-a" "diag-b"; return 0 ;;
    *"--method delete"*) return 0 ;;
    *"--method get"*)   echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;
    *) return 1 ;;
  esac
}
out10="$(sweep_resource_diagnostic_settings 2>&1)"; rc10=$?
record "accounting axis 1: returns non-zero when unreachable-hosts > 0 even though found==confirmed" \
  "$([ "$rc10" -ne 0 ] && echo 1 || echo 0)"
record "accounting axis 1: summary states found=2 confirmed=2 unreachable=1" \
  "$(printf '%s' "$out10" | grep -qF 'settings-found=2 settings-confirmed-gone=2 mid-sweep-unreachable-hosts=1' && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 11 (ADR-076 decision 2, completeness accounting axis 2): mid-sweep-unreachable-hosts == 0
# can STILL be true while settings-found != settings-confirmed-gone - one setting's DELETE fails,
# the sweep must continue to its SIBLING setting rather than stopping, and the mismatch alone
# (with zero unreachable hosts) must fail the job.
# ---------------------------------------------------------------------------------------------
log11="$tmp/case11.log"; : > "$log11"
az() {
  case "$*" in
    *"group list"*)    printf '%s\n' "$RG"; return 0 ;;
    *"resource list"*) printf '%s\n' "$RID1"; return 0 ;;
    *"value[].name"*)  printf '%s\n%s\n' "diag-a" "diag-b"; return 0 ;;
    *"--method delete"*"diagnosticSettings/diag-a?"*)
      echo "ERROR: (Conflict) simulated delete failure for diag-a only." >&2; return 1 ;;
    *"--method delete"*) echo "delete:$*" >> "$log11"; return 0 ;;
    *"--method get"*)   echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;
    *) echo "UNEXPECTED:$*" >> "$log11"; return 1 ;;
  esac
}
out11="$(sweep_resource_diagnostic_settings 2>&1)"; rc11=$?
record "accounting axis 2: returns non-zero when found != confirmed, even though unreachable==0" \
  "$([ "$rc11" -ne 0 ] && echo 1 || echo 0)"
record "accounting axis 2: the SIBLING setting is still deleted (sweep continues past the failure)" \
  "$(grep -qF 'diagnosticSettings/diag-b' "$log11" && echo 1 || echo 0)"
record "accounting axis 2: summary states found=2 confirmed=1 unreachable=0" \
  "$(printf '%s' "$out11" | grep -qF 'settings-found=2 settings-confirmed-gone=1 mid-sweep-unreachable-hosts=0' && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 12 (ADR-076 decision 2, `is_host_absent_error`'s SECOND disjunct - code-review finding,
# 2026-08-10): cases 8/9 only exercise the 404/NotFound-shaped disjunct (ResourceGroupNotFound /
# ResourceNotFound); this case exercises the deleted-scope 403 disjunct instead
# (AuthorizationFailed / "does not have authorization" / "ABAC condition" - the exact shape
# ADR-072 decision 4's table records for a diagnostic-settings host that is gone). This text
# deliberately ALSO matches `is_auth_error`'s broad net (it ends in the standard RBAC-denial
# boilerplate "...please refresh your credentials", and `is_auth_error` matches bare
# "credential") - the point of this case is proving `is_host_absent_error` is checked FIRST at
# the list site, so the failure is classified unreachable end-to-end (loud, the sweep continues
# to the surviving RG, the entry is counted in the ledger, and the job-level completeness
# assertion fails at the end) rather than silently skipped OR hard-stopped as the auth/token
# failure this text is not.
# ---------------------------------------------------------------------------------------------
log12="$tmp/case12.log"; : > "$log12"
RG_GONE3="rg-vanished3-globaris-poc"
az() {
  case "$*" in
    *"group list"*) printf '%s\n%s\n' "$RG_GONE3" "$RG"; return 0 ;;
    *"resource list --resource-group ${RG_GONE3} "*)
      echo "ERROR: (AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.Resources/subscriptions/resourceGroups/read' over scope '/subscriptions/${SUB}/resourceGroups/${RG_GONE3}' or the scope is invalid. If access was recently granted, please refresh your credentials." >&2; return 1 ;;
    *"resource list"*)  printf '%s\n' "$RID1"; return 0 ;;
    *"value[].name"*)   printf '%s\n' "diag-aks-1"; return 0 ;;
    *"--method delete"*) echo "delete:$*" >> "$log12"; return 0 ;;
    *"--method get"*)   echo "ERROR: (ResourceNotFound) not found." >&2; return 1 ;;
    *) echo "UNEXPECTED:$*" >> "$log12"; return 1 ;;
  esac
}
out12="$(sweep_resource_diagnostic_settings 2>&1)"; rc12=$?
record "AuthorizationFailed-shaped (deleted-scope 403): classified unreachable end-to-end - loud, sweep continues to the surviving RG, counted in the ledger/summary, NOT the auth hard-stop, job assertion fails" \
  "$([ "$rc12" -ne 0 ] \
     && printf '%s' "$out12" | grep -qF 'vanished mid-enumeration' \
     && ! printf '%s' "$out12" | grep -qF 'with an auth/transport error' \
     && grep -qF 'diagnosticSettings/diag-aks-1' "$log12" \
     && printf '%s' "$out12" | grep -qF 'mid-sweep-unreachable-hosts=1' \
     && echo 1 || echo 0)"
unset -f az

echo
echo "== ordering barrier: teardown.yml (ADR-076 decision 1) =="
# Block-scoped structural check, not a full YAML parse (this suite is self-contained bash with no
# network dependency, matching every other case above - `npx js-yaml` is used separately, by hand,
# for basic syntax validation at review time, per the environment's standing js-yaml fallback).
# Extracts exactly the `databricks-precascade:` job's own block (from its own line up to, but not
# including, the next top-level 2-space-indented job key) and asserts its `needs:` line names
# `diagnostic-precascade` - the literal ordering edge ADR-076 decision 1 requires, checked where
# it is actually declared rather than as a whole-file substring search (doctrine 1b).
workflow_file="$repo_root/.github/workflows/teardown.yml"
dbx_block="$(awk '
  /^  databricks-precascade:$/ {flag=1; print; next}
  flag && /^  [a-zA-Z_-]+:$/ {exit}
  flag {print}
' "$workflow_file")"
record "ordering barrier: databricks-precascade's own needs: names diagnostic-precascade" \
  "$(printf '%s' "$dbx_block" | grep -qE 'needs:.*diagnostic-precascade' && echo 1 || echo 0)"

echo
echo "== step order: teardown-az-sweep.sh (ADR-076 decision 1) =="
azsweep_file="$repo_root/scripts/teardown-az-sweep.sh"
pre_line="$(grep -n '^echo "== Phase 2 step 1-pre:' "$azsweep_file" | head -1 | cut -d: -f1)"
dbx_line="$(grep -n '^echo "== Phase 2 step 1:' "$azsweep_file" | head -1 | cut -d: -f1)"
record "step order: step 1-pre (diagnostic sweep) is defined before step 1 (Databricks force-delete)" \
  "$([ -n "$pre_line" ] && [ -n "$dbx_line" ] && [ "$pre_line" -lt "$dbx_line" ] && echo 1 || echo 0)"

echo
echo "test-teardown-diagnostic-sweep: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
