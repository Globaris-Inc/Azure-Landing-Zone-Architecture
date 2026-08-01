#!/usr/bin/env bash
# scripts/teardown-summary.sh - the run-outcome summary job (DevSecOps fix, teardown run
# 30685705802, "Defect 3": a run whose Phase 3 VERIFY passed - i.e. Azure IS verified clean -
# still reported overall FAILURE because two Phase 1 jobs failed, and nothing in the run
# distinguished "estate clean, a layer took a designed fallback path" from "estate not actually
# clean". That is the same class of defect this codebase has hit before in the other direction
# (a green run that did not mean what it said) - see LESSONS.md and the WORKLOG entries this
# fix's own WORKLOG session cites.
#
# THIS SCRIPT DOES NOT AND CANNOT CHANGE THE OVERALL GITHUB ACTIONS RUN CONCLUSION. GitHub sets
# a run's top-level conclusion from its jobs' own conclusions; there is no supported mechanism to
# make an otherwise-failed run report green from a downstream job, and this script does not
# attempt one - doing so would silently launder a genuine future regression, which is a strictly
# worse failure mode than the one it exists to fix. What it DOES do is make the DISTINCTION
# legible in one place: which layers destroyed via their own Terraform job, which layer (only
# platform/management-groups, and only at target=all) is BY DESIGN not a Phase-1-owned layer at
# all (ADR-072 decision 6, INV-1'), and whether Phase 3 VERIFY - "the authoritative live-state
# answer" - actually passed. A genuine, unexplained Phase-1 failure on any OTHER layer still
# reads as exactly that: a real problem, not a benign fallback (ADR-072 decision 3 rejects
# treating "Phase 1 fails, Phase 2 catches it" as an accepted design for any layer other than the
# one ADR-072 decision 6 explicitly reassigns).
#
# Reads ALL_RESULTS_JSON (`${{ toJSON(needs) }}` from the calling job) - the SAME mechanism
# teardown-state-reset.sh already uses for PHASE1_RESULTS_JSON, reused here under a different
# name because this job's own `needs:` list is broader (every phase, not just the 11 Phase 1
# roots). No Azure calls, no OIDC login needed - this job only ever reads job-status data GitHub
# Actions itself already computed.
set -uo pipefail

ALL_RESULTS_JSON="${ALL_RESULTS_JSON:-}"
TARGET="${TARGET:-}"
MODE="${MODE:-}"
REMOVE_MG_HIERARCHY="${REMOVE_MG_HIERARCHY:-false}"

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::teardown-summary.sh requires jq (ubuntu-latest ships it by default) - not found on this runner."
  exit 1
fi
if [ -z "$ALL_RESULTS_JSON" ] || ! printf '%s' "$ALL_RESULTS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "::error::ALL_RESULTS_JSON is empty or not valid JSON - the calling workflow job must set this from \${{ toJSON(needs) }}."
  exit 1
fi

result_of() {
  printf '%s' "$ALL_RESULTS_JSON" | jq -r --arg j "$1" '.[$j].result // "missing"'
}

summary_lines=()
add_line() {
  summary_lines+=("$1")
  echo "$1"
}

add_line "== Teardown Summary (run outcome, target=${TARGET} mode=${MODE} remove_mg_hierarchy=${REMOVE_MG_HIERARCHY}) =="

guard_result="$(result_of guard)"
if [ "$guard_result" != "success" ]; then
  add_line "VERDICT: TEARDOWN DID NOT START - the guard job (confirm/target/mode validation) did not succeed (result: ${guard_result}). See the guard job's own log; nothing below is meaningful."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "${summary_lines[@]}" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi

# The 10 roots Phase 1 OWNS at target=all (every root except platform/management-groups, which
# ADR-072 decision 6 reassigned to the Phase 2 cascade - INV-1').
declare -a PHASE1_OWNED_JOBS=(synthetic bank-data-p1 bank-app-p1 online-p1 corp-a2 corp-a1 security connectivity identity management)

add_line ""
add_line "-- Phase 1 (Terraform destroy), roots Phase 1 OWNS --"
declare -a unexplained_failures=()
for job in "${PHASE1_OWNED_JOBS[@]}"; do
  r="$(result_of "$job")"
  case "$r" in
    success) add_line "  ${job}: GREEN (destroyed via its own terraform destroy)" ;;
    skipped) add_line "  ${job}: skipped (not this dispatch's target - not a finding)" ;;
    *)
      add_line "  ${job}: ${r} - UNEXPECTED. No designed fallback covers this layer (ADR-072 decision 3 rejects 'Phase 1 fails, Phase 2 catches it' as an accepted design for any layer except management-groups). This is a genuine defect in this layer even if Azure is otherwise verified clean below - investigate it."
      unexplained_failures+=("$job:$r")
      ;;
  esac
done

add_line ""
add_line "-- platform/management-groups (NOT Phase-1-owned at target=all, ADR-072 decision 6 / INV-1') --"
mg_result="$(result_of management-groups)"
case "$mg_result" in
  skipped) add_line "  management-groups: skipped - correct and expected at target=all. Destroyed by the Phase 2 MG-hierarchy cascade instead; its completion is asserted by Phase 3 VERIFY below, not by this job." ;;
  success|failure) add_line "  management-groups: ${mg_result} - this run dispatched it directly (single-root target=platform/management-groups), where Phase 1 IS the owning mechanism and this result is a genuine finding." ;;
  *) add_line "  management-groups: ${mg_result}" ;;
esac

add_line ""
add_line "-- Belt jobs (not hard gates - a failure here does not block the layer it precedes) --"
add_line "  disarm: $(result_of disarm)"
add_line "  databricks-precascade: $(result_of databricks-precascade)"
add_line "  attachment-sweep: $(result_of attachment-sweep) (ADR-072 decision 4 - a failure surfaces as platform/management's own prevent_deletion_if_contains_resources error or a Phase 2/3 remnant, never a skipped layer)"
add_line "  az-sweep (Phase 2, remnant-catch belt): $(result_of az-sweep)"

add_line ""
add_line "-- Phase 3 VERIFY (the authoritative live-state answer) --"
verify_result="$(result_of verify)"
add_line "  verify: ${verify_result}"

add_line ""
add_line "-- Phase 4 STATE RESET --"
add_line "  state-reset: $(result_of state-reset)"

add_line ""
verdict_fail=0
if [ "$verify_result" != "success" ]; then
  add_line "VERDICT: TEARDOWN INCOMPLETE - Azure is NOT verified clean (Phase 3 VERIFY did not pass, result: ${verify_result}). Investigate before treating this run as done; do not re-dispatch on the assumption the estate is clean."
  verdict_fail=1
elif [ "${#unexplained_failures[@]}" -gt 0 ]; then
  add_line "VERDICT: ESTATE VERIFIED CLEAN (Phase 3 VERIFY passed), but ${#unexplained_failures[@]} layer(s) did not destroy via their own Terraform job and are NOT covered by any designed fallback: ${unexplained_failures[*]}. This is a genuine defect in those layers even though Azure itself is clean - investigate them; do not treat this as a benign fallback (ADR-072 decision 3)."
  verdict_fail=1
else
  add_line "VERDICT: TEARDOWN COMPLETE - every Phase-1-owned layer destroyed via Terraform (or was correctly skipped for this target); platform/management-groups, if applicable, was handled by the Phase 2 cascade under INV-1' (ADR-072 decision 6); estate verified clean via Phase 3 VERIFY."
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n' "${summary_lines[@]}" >> "$GITHUB_STEP_SUMMARY"
fi

exit "$verdict_fail"
