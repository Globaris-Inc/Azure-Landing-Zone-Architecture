#!/usr/bin/env bash
# scripts/test-teardown-law-purge.sh - regression suite for law_purge_soft_deleted_workspaces
# and law_confirm_purged (teardown-common.sh, ADR-073 decision 4, step 7b's discovery-based
# Log Analytics soft-delete purge).
#
# Stubs `az` entirely with a bash function - never a real Azure call. This script is read-only
# against the live estate and dispatches nothing.
#
# Per this session's own stated testing bar: a prior batch shipped a helper
# (retry_blob_action_on_network_rule) that could NEVER report failure, because an `if` with no
# `else` silently discarded `$?` and the following line always read 0. That defect passed a
# suite that only covered success and exhaustion, never "does this actually return non-zero when
# it should". Every case below therefore asserts the FAILURE return path explicitly (exit code
# AND that the loud ::error::/::warning:: text is present), not just that the happy path works.
#
# Covers: gate A (containment - a foreign entry is skipped, not purged, and does not abort the
# run), gate B (blast-radius cap aborts and purges NOTHING), gate C (a failing recover PUT aborts
# before any delete is attempted), gate D (a post-purge re-list that still shows the entry is a
# hard failure, not a false "purged"), and the strict-sequential two-region-collision case that
# is the whole reason this generalisation exists (two entries sharing one ARM resource ID,
# distinguished only by location, processed one full cycle at a time).
#
# Usage: scripts/test-teardown-law-purge.sh
# Exit 0 = all cases pass, 1 = at least one case failed.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 2
cd "$repo_root" || exit 2
# shellcheck source=./teardown-common.sh
source scripts/teardown-common.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; failed=0

# Deterministic and fast regardless of stub error text - none of the scenarios below are meant
# to exercise az_run_retry's transient-retry path, and this keeps the suite's runtime independent
# of that function's own default attempt/sleep constants.
AZ_RUN_RETRY_ATTEMPTS=1
AZ_RUN_RETRY_SLEEP_SECONDS=0

# One fake estate subscription is enough to exercise teardown_subscriptions()/is_estate_owned
# without needing all 5 real subscription IDs.
export MANAGEMENT_SUBSCRIPTION_ID="11111111-1111-1111-1111-111111111111"
unset CONNECTIVITY_SUBSCRIPTION_ID IDENTITY_SUBSCRIPTION_ID SECURITY_SUBSCRIPTION_ID LANDINGZONES_SUBSCRIPTION_ID 2>/dev/null || true
SUB="$MANAGEMENT_SUBSCRIPTION_ID"

# arg_value "<flag>" "$@" - print the value immediately following <flag> among the remaining
# positional args, or nothing if <flag> is not present.
arg_value() {
  local flag="$1"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$flag" ]; then
      printf '%s' "${2:-}"
      return 0
    fi
    shift
  done
}

# body_location "<json>" - extract the value of a {"location": "x"} body's location field.
body_location() {
  printf '%s' "$1" | sed -n 's/.*"location"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

record() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then
    printf '  PASS  %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"; failed=$((failed + 1))
  fi
}

echo "== law_purge_soft_deleted_workspaces =="

# ---------------------------------------------------------------------------------------------
# Case 1: gate A containment - a foreign (non-estate-owned) entry is SKIPPED with a warning, not
# purged and not a hard failure, while an estate-owned entry discovered in the SAME batch is
# still fully purged. Proves the skip is genuinely selective, not "skip everything" or
# "purge everything regardless".
# ---------------------------------------------------------------------------------------------
log1="$tmp/case1.log"; : > "$log1"
az() {
  case "$*" in
    *"list-deleted-workspaces"*"properties.customerId"*)
      printf 'law-owned\teastus2\t/subscriptions/%s/resourceGroups/rg-platform-globaris-poc/providers/Microsoft.OperationalInsights/workspaces/law-owned\tcid-owned\n' "$SUB"
      printf 'law-foreign\teastus2\t/subscriptions/%s/resourceGroups/rg-someoneelse-prod/providers/Microsoft.OperationalInsights/workspaces/law-foreign\tcid-foreign\n' "$SUB"
      return 0
      ;;
    *"list-deleted-workspaces"*"[].[id, location]"*)
      return 0  # confirmed gone - nothing left soft-deleted
      ;;
    *"group exists"*)
      echo "true"
      return 0
      ;;
    *"rest --method put"*)
      echo "recover:$(arg_value --url "$@")" >> "$log1"
      return 0
      ;;
    *"log-analytics workspace delete"*)
      echo "delete:$(arg_value --workspace-name "$@")" >> "$log1"
      return 0
      ;;
    *)
      echo "UNEXPECTED:$*" >> "$log1"
      return 1
      ;;
  esac
}
out1="$(law_purge_soft_deleted_workspaces 2>&1)"; rc1=$?
record "gate A: returns 0 (foreign entry is a skip, not a fatal)" "$([ "$rc1" -eq 0 ] && echo 1 || echo 0)"
record "gate A: warns by name about the foreign entry" \
  "$(printf '%s' "$out1" | grep -qF 'law-foreign' && printf '%s' "$out1" | grep -qF '::warning::' && echo 1 || echo 0)"
record "gate A: the owned entry in the same batch is still recovered" \
  "$(grep -qF 'recover:' "$log1" && echo 1 || echo 0)"
record "gate A: the owned entry in the same batch is still purged" \
  "$(grep -qF 'delete:law-owned' "$log1" && echo 1 || echo 0)"
record "gate A: the foreign entry is never recovered or deleted" \
  "$(grep -qF 'law-foreign' "$log1" && echo 0 || echo 1)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 2: gate B blast-radius cap - more purge-eligible entries than the cap aborts the WHOLE
# run and purges NOTHING (not "purge the first N and stop"). Cap is overridden to 2 for the
# test (via a temporary env prefix, restored after this one call) so the fixture does not need
# to fabricate double digits of rows to exceed the real default.
# ---------------------------------------------------------------------------------------------
log2="$tmp/case2.log"; : > "$log2"
az() {
  case "$*" in
    *"list-deleted-workspaces"*"properties.customerId"*)
      printf 'law-a\teastus2\t/subscriptions/%s/resourceGroups/rg-a-globaris-poc/providers/Microsoft.OperationalInsights/workspaces/law-a\tcid-a\n' "$SUB"
      printf 'law-b\teastus2\t/subscriptions/%s/resourceGroups/rg-b-globaris-poc/providers/Microsoft.OperationalInsights/workspaces/law-b\tcid-b\n' "$SUB"
      printf 'law-c\teastus2\t/subscriptions/%s/resourceGroups/rg-c-globaris-poc/providers/Microsoft.OperationalInsights/workspaces/law-c\tcid-c\n' "$SUB"
      return 0
      ;;
    *"rest --method put"*)
      echo "recover:$(arg_value --url "$@")" >> "$log2"
      return 0
      ;;
    *"log-analytics workspace delete"*)
      echo "delete:$(arg_value --workspace-name "$@")" >> "$log2"
      return 0
      ;;
    *)
      echo "UNEXPECTED:$*" >> "$log2"
      return 1
      ;;
  esac
}
out2="$(LAW_PURGE_BLAST_RADIUS_CAP=2 law_purge_soft_deleted_workspaces 2>&1)"; rc2=$?
record "gate B: returns non-zero when the cap is exceeded" "$([ "$rc2" -ne 0 ] && echo 1 || echo 0)"
record "gate B: reports the cap as an ::error::" \
  "$(printf '%s' "$out2" | grep -qF '::error::' && printf '%s' "$out2" | grep -qiF 'blast-radius cap' && echo 1 || echo 0)"
record "gate B: purges NOTHING when the cap trips (no recover/delete calls at all)" \
  "$([ ! -s "$log2" ] && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 3: gate C - a failing recover PUT is a hard failure, and the code never proceeds to
# force-delete a workspace it could not first recover.
# ---------------------------------------------------------------------------------------------
log3="$tmp/case3.log"; : > "$log3"
az() {
  case "$*" in
    *"list-deleted-workspaces"*"properties.customerId"*)
      printf 'law-x\teastus2\t/subscriptions/%s/resourceGroups/rg-x-globaris-poc/providers/Microsoft.OperationalInsights/workspaces/law-x\tcid-x\n' "$SUB"
      return 0
      ;;
    *"group exists"*)
      echo "true"
      return 0
      ;;
    *"rest --method put"*)
      echo "recover-attempt" >> "$log3"
      echo "ERROR: (BadRequest) simulated recovery conflict for test purposes only" >&2
      return 1
      ;;
    *"log-analytics workspace delete"*)
      echo "delete:$(arg_value --workspace-name "$@")" >> "$log3"
      return 0
      ;;
    *)
      echo "UNEXPECTED:$*" >> "$log3"
      return 1
      ;;
  esac
}
out3="$(law_purge_soft_deleted_workspaces 2>&1)"; rc3=$?
record "gate C: returns non-zero when the recover PUT fails" "$([ "$rc3" -ne 0 ] && echo 1 || echo 0)"
record "gate C: reports the recover failure as an ::error::" \
  "$(printf '%s' "$out3" | grep -qF '::error::' && printf '%s' "$out3" | grep -qiF 'via REST PUT failed' && echo 1 || echo 0)"
record "gate C: never attempts the permanent delete after a failed recover" \
  "$(grep -qF 'delete:' "$log3" && echo 0 || echo 1)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 4: gate D - the completion check is a deletedWorkspaces RE-LIST, not an ARM GET on the
# shared id. A re-list that still shows the just-purged (id, location) pair is a hard failure,
# never a false "purged".
# ---------------------------------------------------------------------------------------------
log4="$tmp/case4.log"; : > "$log4"
az() {
  case "$*" in
    *"list-deleted-workspaces"*"properties.customerId"*)
      printf 'law-y\teastus2\t/subscriptions/%s/resourceGroups/rg-y-globaris-poc/providers/Microsoft.OperationalInsights/workspaces/law-y\tcid-y\n' "$SUB"
      return 0
      ;;
    *"list-deleted-workspaces"*"[].[id, location]"*)
      # The purge "succeeded" per the delete call below, but the re-list still reports the
      # exact same (id, location) pair - simulating an incomplete/failed purge.
      printf '/subscriptions/%s/resourceGroups/rg-y-globaris-poc/providers/Microsoft.OperationalInsights/workspaces/law-y\teastus2\n' "$SUB"
      return 0
      ;;
    *"group exists"*)
      echo "true"
      return 0
      ;;
    *"rest --method put"*)
      echo "recover" >> "$log4"
      return 0
      ;;
    *"log-analytics workspace delete"*)
      echo "delete" >> "$log4"
      return 0
      ;;
    *)
      echo "UNEXPECTED:$*" >> "$log4"
      return 1
      ;;
  esac
}
out4="$(law_purge_soft_deleted_workspaces 2>&1)"; rc4=$?
record "gate D: returns non-zero when the re-list still shows the entry" "$([ "$rc4" -ne 0 ] && echo 1 || echo 0)"
record "gate D: reports the remnant as an ::error::, never a silent pass" \
  "$(printf '%s' "$out4" | grep -qF '::error::' && printf '%s' "$out4" | grep -qiF 'post-purge deletedWorkspaces re-list' && echo 1 || echo 0)"
record "gate D: the recover and delete calls DID both run (the failure is in the completion check, not upstream)" \
  "$(grep -qF 'recover' "$log4" && grep -qF 'delete' "$log4" && echo 1 || echo 0)"
unset -f az

# ---------------------------------------------------------------------------------------------
# Case 5: the motivating scenario - two entries share ONE ARM resource ID (region is not part of
# a Log Analytics workspace's ARM identity) and are distinguished only by location. Proves (a)
# gate D's re-list check does not confuse the two (purging the first must not falsely read as
# "purged" for the second, and must not falsely read as "still there" once the first really is
# gone), and (b) STRICT SEQUENTIAL ordering: entry 2's recover PUT never fires until entry 1's
# full cycle (recover, delete, confirm) has completed - the exact property ADR-073 calls
# load-bearing, now asserted from the call log rather than merely asserted in a comment.
# ---------------------------------------------------------------------------------------------
log5="$tmp/case5.log"; : > "$log5"
gone_dir="$tmp/case5_gone"; mkdir -p "$gone_dir"
shared_id="/subscriptions/${SUB}/resourceGroups/rg-management-globaris-poc/providers/Microsoft.OperationalInsights/workspaces/law-platform-globaris-poc"
az() {
  case "$*" in
    *"list-deleted-workspaces"*"properties.customerId"*)
      # Discovery is a ONE-TIME snapshot at the start, before any purging - both entries are
      # always present here regardless of what has been purged since.
      printf 'law-platform-globaris-poc\teastus2\t%s\tcid-eastus2\n' "$shared_id"
      printf 'law-platform-globaris-poc\tcentralus\t%s\tcid-centralus\n' "$shared_id"
      return 0
      ;;
    *"list-deleted-workspaces"*"[].[id, location]"*)
      [ -f "$gone_dir/eastus2" ] || printf '%s\teastus2\n' "$shared_id"
      [ -f "$gone_dir/centralus" ] || printf '%s\tcentralus\n' "$shared_id"
      return 0
      ;;
    *"group exists"*)
      echo "true"
      return 0
      ;;
    *"rest --method put"*)
      loc="$(body_location "$(arg_value --body "$@")")"
      echo "recover:$loc" >> "$log5"
      printf '%s' "$loc" > "$tmp/case5_last_recovered"
      return 0
      ;;
    *"log-analytics workspace delete"*)
      loc="$(cat "$tmp/case5_last_recovered" 2>/dev/null || true)"
      echo "delete:$loc" >> "$log5"
      touch "$gone_dir/$loc"
      return 0
      ;;
    *)
      echo "UNEXPECTED:$*" >> "$log5"
      return 1
      ;;
  esac
}
out5="$(law_purge_soft_deleted_workspaces 2>&1)"; rc5=$?
record "same-ARM-ID collision: returns 0 (both entries fully purged)" "$([ "$rc5" -eq 0 ] && echo 1 || echo 0)"
record "same-ARM-ID collision: STRICT sequential order (recover+delete for eastus2 complete before centralus starts)" \
  "$([ "$(cat "$log5")" = "$(printf 'recover:eastus2\ndelete:eastus2\nrecover:centralus\ndelete:centralus')" ] && echo 1 || echo 0)"
record "same-ARM-ID collision: gate D never reports a false remnant or a false purge for either entry" \
  "$(printf '%s' "$out5" | grep -qF '::error::' && echo 0 || echo 1)"
unset -f az

echo
echo "test-teardown-law-purge: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
