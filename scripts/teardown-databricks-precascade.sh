#!/usr/bin/env bash
# scripts/teardown-databricks-precascade.sh - Phase 0.5 DATABRICKS PRECASCADE (ADR-066
# decision 4, PREFERRED form; code-review Finding 2, 2026-07-30). Runs BEFORE Phase 1's
# serialized terraform-destroy chain, alongside Phase 0 DISARM, so the Databricks workspace
# force-delete (--no-wait --force-deletion) is submitted WHILE the workspace is still live -
# this is what lets the delete cascade the RP-managed resource group cleanly, instead of
# retaining it as an orphan.
#
# Root cause this closes (ADR-066 decision 4 / OQ-062(b)). `enable_data_platform = true` is
# the LIVE setting (envs/poc.tfvars) - Databricks IS deployed in this estate. bank-data-p1's
# terraform destroy (Phase 1, chain position 2 of 11, teardown.yml) issues a PLAIN azapi DELETE
# on the workspace (the pinned avm-res-databricks-workspace 0.5.0 module sets no
# `forceDeletion` query parameter). Per Microsoft's own "Delete a workspace" doc, a plain
# delete RETAINS the managed resource group (DBFS storage account + access connector) instead
# of removing it. That orphan managed RG then collides with the deterministic
# `managed_resource_group_name` the NEXT greenfield apply computes for the same root. The
# existing Phase 2 az-sweep step 1 (teardown-az-sweep.sh) already force-deletes the workspace
# with --force-deletion, but under the ADR-066 serialized model it now runs AFTER all 11
# Phase 1 jobs - by that point bank-data-p1's plain delete has already happened and there is no
# live workspace left for the force-delete to act on. This Phase 0.5 job runs the SAME
# operation while the workspace is provably still live, ahead of Phase 1.
#
# Gated identically to Phase 0 DISARM plus a mode check (see teardown.yml): target=all AND
# mode=terraform only. In mode=az-sweep, Phase 1 never runs at all (every Phase 1 job is gated
# on inputs.mode == 'terraform'), so az-sweep's own step 1 already performs this exact cascade
# FIRST in that path (nothing runs ahead of it there) - wiring this script into the
# mode=az-sweep path too would be a redundant duplicate, not a fix, so it is not gated there.
#
# Scope boundary (documented, not fixed here): this job runs only for target=all. A
# single-root `landing-zones/bank-data-p1` teardown does not get this belt (DISARM and every
# other Phase 0/2/3 job are also target=all only - see teardown.yml's own "Scope note"), so a
# standalone single-root bank-data-p1 destroy with a live Databricks workspace still hits the
# plain-delete orphan-managed-RG gap this script exists to close for the target=all path. This
# matches the existing single-root exclusion the rest of the teardown design already accepts,
# not a new gap this change introduces.
#
# Idempotent: `databricks workspace list` returning zero rows (no Databricks deployed,
# enable_data_platform=false, or already deleted by a prior run) is success, not an error -
# matches every other step in this codebase. Shares its core logic with the unchanged Phase 2
# az-sweep step 1 via `databricks_force_delete_cascade` (teardown-common.sh) so the two call
# sites cannot drift on the exact az invocation.
#
# Not waited on here: this script only SUBMITS the force-delete (--no-wait) and exits. The
# managed RG's own asynchronous cascade completes in the background while Phase 1 runs; Phase
# 2's own step 1 (teardown-az-sweep.sh, unchanged) and VERIFY 2's RG naming-pattern scan are the
# backstops for any remnant, matching the "submit here, reconcile/verify later" idiom this
# codebase already uses everywhere else (section 9.2a/9.3).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

declare -a dbx_managed_rgs=()
declare -a dbx_managed_rg_subs=()

echo "== Phase 0.5: Databricks workspace precascade (submission only, --no-wait --force-deletion) =="
if ! databricks_force_delete_cascade dbx_managed_rgs dbx_managed_rg_subs; then
  echo "::error::Databricks precascade failed - see the error above. This is Phase 0.5, a hard gate ahead of Phase 1's bank-data-p1 destroy (ADR-066 decision 4)."
  exit 1
fi

if [ "${#dbx_managed_rgs[@]}" -eq 0 ]; then
  echo "No Databricks workspace found in any estate subscription - nothing to cascade (enable_data_platform=false in this estate's live config, or already torn down by a prior run)."
else
  echo "Submitted force-delete for ${#dbx_managed_rgs[@]} Databricks managed resource group(s): ${dbx_managed_rgs[*]}"
  echo "Not waited on here (submission only) - Phase 1's bank-data-p1 terraform destroy (next in the chain) will find the workspace already gone or already deleting (a 404 on an azapi DELETE of an absent resource is idempotent success) and destroy its own spoke VNet/access connector/RG cleanly. The managed RG's own cascade completes asynchronously; Phase 2's az-sweep step 1 and VERIFY 2's RG naming-pattern scan are the backstops if it lags."
fi

echo "Databricks precascade complete."
exit 0
