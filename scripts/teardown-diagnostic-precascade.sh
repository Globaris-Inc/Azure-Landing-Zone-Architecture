#!/usr/bin/env bash
# scripts/teardown-diagnostic-precascade.sh - Phase 0.5 DIAGNOSTIC-SETTINGS PRECASCADE
# (ADR-071 decision 4b). Runs BEFORE Phase 1's serialized terraform-destroy chain, alongside
# Phase 0 DISARM and the Databricks precascade, so every resource-scoped
# `microsoft.insights/diagnosticSettings` object is deleted WHILE ITS HOST IS STILL LIVE.
#
# THE CLASS THIS CLOSES (ADR-071, G-1, FM-3). A diagnostic setting is an EXTENSION object keyed to
# its host resource's URI. It does not reliably cascade away when the host is deleted, it is not
# in any root's Terraform state once that state is emptied, and - this is the part that makes it
# nasty - it cannot be enumerated by ANY subscription, RG or resource listing once the host is
# gone, because its only address runs through that host. ADR-068's FM-3: an object that outlives
# BOTH the estate and the state, and is invisible to every discovery-based greenfield proof. The
# 2026-07-31 greenfield verification was correct AND the orphans still existed; nothing was missed,
# because a greenfield proof is a statement about what can be DISCOVERED.
#
# The consequence is paid on the next apply that recreates a same-named host: the provider's
# create issues NewScopedDiagnosticSettingID(target_resource_id, name) and GETs that exact name,
# finds the survivor, and fails with `already exists - to be managed via Terraform this resource
# needs to be imported`. Live evidence, 2026-07-31: eight such failures across two roots -
# bank-data-p1 (runs 30661012325, 30662610292) and bank-app-p1 (run 30672301220, which failed at
# 33 minutes 50 seconds, AFTER APIM and AKS had already provisioned).
#
# THE ORDERING REGRESSION THIS FIXES, which is the same one ADR-066 decision 4 already found and
# fixed for Databricks. Phase 2's step 2-pre sweeps this exact class, but it can only see a setting
# whose host is still LIVE, and it sits in Phase 2, which `needs` all of Phase 1. Under ADR-066,
# `mode=terraform` at `target=all` runs the per-root terraform destroys FIRST - deleting the hosts -
# so by the time step 2-pre runs there is nothing left for it to enumerate. On that path the sweep
# is structurally unable to catch precisely the residue it was written for. Moving the operation
# ahead of Phase 1, while the hosts are provably still there, is the whole fix.
#
# GATED IDENTICALLY TO THE DATABRICKS PRECASCADE (see teardown.yml): target=all AND mode=terraform
# only. `mode=az-sweep` is deliberately NOT wired: Phase 1 never runs in that path (every Phase 1
# job gates on inputs.mode == 'terraform'), so step 2-pre there already executes while hosts are
# live and a second call would be a redundant duplicate rather than a fix. Same reasoning, same
# words, as the Databricks job's own header.
#
# NOT A GATE. Consistent with the Databricks precascade and with ADR-066 INV-1: a failure here is
# LOUD but must never skip a layer, because Phase 1 still has to run all its destroys green. An
# orphan left behind by a failure here surfaces later as an `already exists` on a first apply,
# recovered by runbook B1 (delete the survivor, rerun the same root, never import) - which is the
# interim two-applies rule this job exists to retire, not an incident.
#
# SCOPE BOUNDARY, documented rather than fixed here: this job runs only for target=all, matching
# DISARM, the Databricks precascade and every other Phase 0/2/3 job (see teardown.yml's own "Scope
# note"). A standalone single-root destroy does not get this belt. That is the existing
# single-root exclusion the teardown design already accepts, not a new gap.
#
# Shares its entire body with Phase 2's step 2-pre via `sweep_resource_diagnostic_settings`
# (teardown-common.sh) so the two call sites cannot drift on the exact az invocation, api-version,
# containment predicate or confirm-GET - the same anti-drift reason `databricks_force_delete_cascade`
# is shared.
#
# ACCEPTANCE (ADR-071 decision 4b + T3). The next `target=all mode=terraform` teardown shows this
# job deleting at least the settings the estate holds, and the next greenfield first apply of
# `bank-data-p1` and `bank-app-p1` reports ZERO `already exists`. If the class recurs on a first
# apply that FOLLOWED a teardown carrying this job, G-1 is refuted for this estate and decision
# 4a's named fallback (scoped azapi conversion of the failing settings only) is bought.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

echo "== Phase 0.5: resource-scoped diagnostic-settings precascade (delete while hosts are still live) =="

if ! sweep_resource_diagnostic_settings; then
  echo "::error::Diagnostic-settings precascade failed - see the error above. This is Phase 0.5 (ADR-071 decision 4b). NOTE: this is NOT a gate - every Phase 1 root still runs and still must go green (ADR-066 INV-1). A diagnostic setting left behind by this failure is an FM-3 orphan: it will NOT be visible to any later greenfield proof, and it surfaces as an 'already exists' on the first apply that recreates its host, recovered by runbook B1 (delete the survivor, rerun the root, never import)."
  exit 1
fi

echo "Diagnostic-settings precascade complete."
echo "A zero-deletion result here is NOT self-evidently correct: on a deployed estate these settings exist (nine are composed by this repository across bank-data-p1, bank-app-p1 and online-p1), so zero means either a prior run already swept them or the enumeration did not reach them. Phase 2's step 2-pre remains the belt for whatever this missed, and the real acceptance test is T3 - zero 'already exists' on the next greenfield first apply."
exit 0
