#!/usr/bin/env bash
# scripts/teardown-state-reset.sh - Phase 4 STATE RESET (ADR-068 decisions 9-10, DECISIONS.md).
#
# Closes the gap ADR-068 exists for: a verified `target=all` teardown deletes every Azure
# resource but never touches the Terraform state blobs, so `mode=az-sweep` (Phase 1
# terraform-destroy never runs there) leaves every workload/platform root's state FULLY
# POPULATED describing resources that no longer exist (FM-2, "state-populated-while-
# resources-gone" - the mirror image of FM-1, "state-missing-while-resources-live", which is
# OQ-053 and scripts/teardown-probe-state.sh's own concern, untouched by this script). This
# script is the one piece of code in the repository that is ever allowed to write a
# Terraform state blob to empty, and it does so by OVERWRITE, never by delete
# (INV-STATE, ADR-068 decision 1: "No repository code path may delete a Terraform state
# blob. Blob ABSENCE remains reserved, permanently and exclusively, as the FM-1
# out-of-band-loss alarm."). This script contains no `az storage blob delete` anywhere.
#
# SCOPE NOTE (2026-07-30, owner/coordinator course correction): ADR-068 decision 8 asks for
# the state-blob key list, the tiny-blob threshold, the backend parse and the empty-document
# writer to be promoted into scripts/teardown-common.sh as ONE shared source with
# scripts/teardown-probe-state.sh, and decision 11 asks for that probe script to be amended
# to recognise a deliberately-reset blob by its metadata. BOTH were explicitly DESCOPED from
# this pass - teardown-common.sh and teardown-probe-state.sh carry NO changes here and must
# show no diff. Everything this script needs is therefore defined LOCALLY below, including a
# second copy of the tiny-blob threshold (100 bytes) that DUPLICATES, rather than shares,
# teardown-probe-state.sh's own TINY_BLOB_THRESHOLD_BYTES constant - keep the two in
# lock-step BY HAND until decision 8 actually lands, the same maintenance discipline this
# codebase already documents for other paired-but-unshared constants (e.g. RG_SWEEP_QUERY /
# is_rg_owned in teardown-common.sh). teardown-probe-state.sh is UNAWARE of this script's
# metadata stamp until decision 11 lands - a probe run against a blob this script reset will
# currently classify it by size alone (present + >= 100 bytes = "OK"), which happens to be
# correct today (the canonical document lands at 150-250 bytes) but is coincidental, not
# positively labelled, exactly the gap decision 11 exists to close. Both remain open
# follow-up work, not implemented here.
#
# Sources scripts/teardown-common.sh for `az_run_retry` / `is_auth_error` / `is_not_found_error`
# only - those predate ADR-068 by months (ADR-054/ADR-062, plus `az_run_retry` added 2026-07-30 -
# see below) and are the established auth-fail-loud plumbing every teardown script already uses;
# sourcing them here does not reintroduce decision 8's promotion (the state-blob key list, tiny-
# blob threshold, backend parse and empty-document writer stay local to this script, unchanged).
#
# AMENDED 2026-07-30 (transient-list-failure fix round - see teardown-common.sh's "AMENDED an
# eighth time" header note and teardown-az-sweep.sh's "AMENDED an eleventh time" for the full
# incident and mechanism). This is a genuinely SEPARATE change from decision 8's promotion the
# SCOPE NOTE above disclaims - `az_run_retry` and `is_transient_error` are a general-purpose
# bounded-retry primitive every teardown script now shares, not part of the state-blob-specific
# constants/helpers decision 8 asks to promote, so adding this diff to teardown-common.sh does not
# violate that boundary. Every `storage blob show` read below now goes through `az_run_retry`
# instead of `az_run` - same signature, bounded retry (3 attempts, ~10s apart by default) ONLY
# for a transient 5xx/429 that is not also auth-shaped, never for the blob upload/download calls
# (writes, already captured directly with `az ... 2>&1`, unchanged).
#
# AMENDED AGAIN 2026-08-01 (Phase 4 firewall-race fix - three live reproductions: runs
# `30707957054`/`30709287789` plus one earlier occurrence). `az storage blob show` succeeding
# immediately followed by `az storage blob download` failing on the SAME blob, seconds later,
# with Azure's own "may be blocked by network rules of storage account" text - a per-front-end-
# node propagation race on the JIT firewall flip (ADR-025/LESSON 30), not the transient-5xx class
# the previous amendment fixed, and reproduced at both 153 bytes and 24 MB (size is not the
# variable). Sources two more `teardown-common.sh` primitives now: `is_storage_network_rule_error`
# (the classifier - see its own comment for why it is checked BEFORE `is_auth_error` despite
# looking 403-shaped) and `retry_blob_action_on_network_rule` (the write-shaped counterpart to
# `az_run_retry`'s now-extended network-rule branch, used for the upload and both download call
# sites below - see that helper's own comment for why retrying these specific idempotent writes
# is safe). No caller-visible behaviour changes for a genuine auth failure or a transient 5xx -
# both branches are unchanged and still checked in the same relative order.
#
# Reads three inputs from the environment, all set by the calling job
# (.github/workflows/teardown.yml "state-reset" job):
#   TEARDOWN_MODE          - "terraform" or "az-sweep" (from inputs.mode). Required.
#   REMOVE_MG_HIERARCHY    - "true" or "false" (from inputs.remove_mg_hierarchy). Defaults false.
#   PHASE1_RESULTS_JSON    - `${{ toJSON(needs) }}` from the calling job, so this script can
#                             read each Phase 1 root job's own `.result` without a second API
#                             call anywhere. Required, must be valid JSON.
#
# ELIGIBILITY (ADR-068 decision 4, AMENDED 2026-08-01 - see the dated note below) - per state
# key, in order:
#   - CARVE-OUT B (conditional): platform/management-groups is reset ONLY when
#     REMOVE_MG_HIERARCHY=true. When false the MG tree survives and VERIFY 4 explicitly SKIPS
#     its MG-existence check in that case - resetting on a skipped check is resetting on no
#     evidence.
#   - EVERY KEY: eligible if THIS key's own Phase 1 terraform-destroy job result (read from
#     PHASE1_RESULTS_JSON) is exactly "success". This is the cheapest, most specific evidence
#     and wins when it is available - the pre-registered FIX-6 invariant's limb 1 ("terraform
#     state list empty from a Phase 1 success"), honoured literally, in EITHER mode (in
#     TEARDOWN_MODE=az-sweep every Phase 1 job reports "skipped", so this branch never fires
#     there and every key falls through to the next rule below).
#   - IDENTITY_KEY, if its own job did NOT report "success": PERMANENTLY EXCLUDED regardless of
#     mode (CARVE-OUT A). platform/identity declares azuread_conditional_access_policy (x8),
#     azuread_named_location, azurerm_pim_eligible_role_assignment and
#     azurerm_role_management_policy (platform/identity/main.tf, pim.tf) - Entra/Graph/PIM-plane
#     objects teardown-verify.sh (VERIFY 0-10, ARM-plane only) cannot see at all. A green VERIFY
#     says nothing about whether those objects are still live, so resetting on that evidence
#     alone would be FM-1 by construction, landing on an object class Entra tolerates as silent
#     duplicates rather than a loud collision - identity may ONLY be reset on its own direct job
#     evidence (the rule immediately above), in any mode.
#   - EVERY OTHER KEY, if its own job did NOT report "success": eligible anyway, on the
#     whole-estate VERIFY evidence. The calling workflow job (teardown.yml's `state-reset`) hard-
#     gates this entire script's invocation on `needs.verify.result == 'success'` at target=all,
#     so by the time this script ever runs, VERIFY has ALREADY certified the ARM plane clean
#     across every subscription (ADR-068 decision 2: "A green whole-estate VERIFY is STRONGER
#     evidence than a per-root empty terraform state list ... It is not, however, a COMPLETE
#     oracle for every root" - identity, handled above, is the only root that is not fully
#     covered by it). Verified 2026-08-01 (grep-confirmed across every root's providers.tf, not
#     just checked for identity): `platform/identity` is the ONLY root anywhere in this estate
#     that declares the `azuread` provider - every other root's provider set is some mix of
#     `azurerm`/`azapi` (both ARM-plane) plus purely local/no-API providers (`modtm`, `random`,
#     `archive`, `null`, `time`, `tls`, `alz` - `alz` only emits further `azurerm`/`azapi`
#     resources itself, and `time`/`tls` make no remote Azure calls at all). No other root has a
#     non-ARM-plane footprint VERIFY cannot see. This is what makes az-sweep's prior
#     "unconditional eligibility" claim sound, and what was missing for mode=terraform before
#     this amendment.
#
# AMENDED 2026-08-01 (ADR-072-adjacent DevSecOps fix, teardown run 30685705802). The ORIGINAL
# ADR-068 decision 4 gated TEARDOWN_MODE=terraform on job success ALONE, with no VERIFY
# fallback, so a root whose Phase 1 job failed or was skipped stayed excluded even when the
# whole-estate VERIFY had independently proven its entire (ARM-plane-only) footprint gone -
# exactly what happened to `platform/management` (blocked by three cross-root orphans, since
# fixed by ADR-072 decision 4's attachment sweep) and `platform/management-groups` (which no
# longer runs under mode=terraform at target=all at all - ADR-072 decision 6) in that run: both
# blobs stayed populated after a run whose Phase 3 VERIFY had PASSED, blocking the next
# rebuild's plan (the exact FM-2 condition this ADR exists to close). The fix above unifies the
# two modes' eligibility into one rule set: a key's own job success is the cheap, specific
# belt; whole-estate VERIFY (which the job-level gate already requires) is the fallback for
# every key except identity, in EITHER mode, matching what decision 2's own text already said
# VERIFY was for. No blanket removal of the conditionality - identity's carve-out is preserved
# in full, unconditionally, in both modes.
#
# IDEMPOTENCY: resetting an already-canonical-empty blob (including the three blobs the owner
# reset by hand on 2026-07-30 under the ADR-068 decision-6 one-time exception,
# tf_state_reset_manual=true) is a clean no-op by construction, not a special case. The normal
# present-blob path below reads a valid `lineage`/`serial`/`terraform_version` off any
# well-formed empty state document (manual or CI-written) and simply re-writes it with
# `serial`+1 and fresh run metadata - no branch anywhere in this script asks "was this already
# reset". Every reset writes a new blob version regardless (an accepted ADR-068 trade-off, not
# a defect).
#
# WHY THIS RUNS IN CI, NOT LOCALLY: same reason as every other state-SA-touching script in this
# repo - the account is Entra-only (shared_access_key_enabled = false) and firewalled
# default_action=Deny with a static ip_rules list (ADR-025). The calling workflow job opens the
# firewall for its own window (JIT open / 3-consecutive-probe-wait / restore-Deny, the same
# pattern _tf-root.yml and teardown-probe.yml already use) and this script assumes that window
# is already open when it runs.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

repo_root="$(cd "${script_dir}/.." && pwd)"
backend_hcl="${repo_root}/envs/poc.backend.hcl"

# --- Local constants (see the SCOPE NOTE above for why these are not shared via
#     teardown-common.sh in this pass) ---

# Mirrors teardown-probe-state.sh's own TINY_BLOB_THRESHOLD_BYTES verbatim (100). A genuinely
# empty-but-valid Terraform state document is typically 150-250 bytes - this threshold is the
# same conservative floor that script's own header documents, chosen below that natural range
# so a truncated/corrupted/zero-byte blob is caught without flagging a legitimate empty state.
TINY_BLOB_THRESHOLD_BYTES=100

# Fallback terraform_version, used ONLY when the existing blob is absent or its
# terraform_version cannot be read (ADR-068 decision 3). MUST NOT exceed the CLI version the
# pipeline pins - Terraform refuses to operate on a state stamped by a newer version. Matches
# hashicorp/setup-terraform@v3's terraform_version pin in .github/workflows/_tf-root.yml.
PINNED_TERRAFORM_VERSION="1.15.6"

IDENTITY_KEY="platform/identity/terraform.tfstate"
MANAGEMENT_GROUPS_KEY="platform/management-groups/terraform.tfstate"

# The 11 workload/platform state-blob keys eligible for Phase 4 (bootstrap uses LOCAL state,
# ADR-005, and is never written here - see ADR-068 decision 5). Matches every
# `-backend-config="key=<root>/terraform.tfstate"` used by _tf-root.yml.
declare -a STATE_KEYS_WORKLOAD=(
  "platform/management-groups/terraform.tfstate"
  "platform/management/terraform.tfstate"
  "platform/connectivity/terraform.tfstate"
  "platform/identity/terraform.tfstate"
  "platform/security/terraform.tfstate"
  "landing-zones/bank-app-p1/terraform.tfstate"
  "landing-zones/bank-data-p1/terraform.tfstate"
  "landing-zones/corp-a1/terraform.tfstate"
  "landing-zones/corp-a2/terraform.tfstate"
  "landing-zones/online-p1/terraform.tfstate"
  "synthetic/terraform.tfstate"
)

# State key -> teardown.yml Phase 1 job id. Read in EITHER mode (2026-08-01 amendment) to
# resolve each key's own destroy-job result out of PHASE1_RESULTS_JSON - in TEARDOWN_MODE=
# az-sweep every one of these jobs reports "skipped" (gated on inputs.mode == 'terraform'), so
# the lookup always falls through to the VERIFY-fallback rule for every non-identity key, the
# same effective behaviour az-sweep had before this amendment. Kept in lock-step BY HAND with
# the job ids in .github/workflows/teardown.yml's Phase 1 chain and this job's own `needs:`
# list - if a Phase 1 job is ever renamed, update both together.
declare -A STATE_KEY_PHASE1_JOB=(
  ["platform/management-groups/terraform.tfstate"]="management-groups"
  ["platform/management/terraform.tfstate"]="management"
  ["platform/connectivity/terraform.tfstate"]="connectivity"
  ["platform/identity/terraform.tfstate"]="identity"
  ["platform/security/terraform.tfstate"]="security"
  ["landing-zones/bank-app-p1/terraform.tfstate"]="bank-app-p1"
  ["landing-zones/bank-data-p1/terraform.tfstate"]="bank-data-p1"
  ["landing-zones/corp-a1/terraform.tfstate"]="corp-a1"
  ["landing-zones/corp-a2/terraform.tfstate"]="corp-a2"
  ["landing-zones/online-p1/terraform.tfstate"]="online-p1"
  ["synthetic/terraform.tfstate"]="synthetic"
)

# canonical_empty_state_json <terraform_version> <serial> <lineage> - the ONE writer of the
# canonical empty Terraform state document (ADR-068 decision 3). `version` 4 is the current
# state format for Terraform 1.x; `resources: []` / `outputs: {}` / `check_results: null` is
# the documented minimal empty form. Defined as a LOCAL function per the SCOPE NOTE above
# (decision 8's shared promotion was descoped) - if this output's byte size ever changes
# materially (a much longer lineage/terraform_version string), re-check it still lands above
# TINY_BLOB_THRESHOLD_BYTES.
canonical_empty_state_json() {
  local tf_version="$1" serial="$2" lineage="$3"
  jq -nc --arg v "$tf_version" --argjson s "$serial" --arg l "$lineage" \
    '{version:4, terraform_version:$v, serial:$s, lineage:$l, outputs:{}, resources:[], check_results:null}'
}

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::teardown-state-reset.sh requires jq (ubuntu-latest ships it by default) - not found on this runner."
  exit 1
fi

TEARDOWN_MODE="${TEARDOWN_MODE:-}"
REMOVE_MG_HIERARCHY="${REMOVE_MG_HIERARCHY:-false}"
PHASE1_RESULTS_JSON="${PHASE1_RESULTS_JSON:-}"

if [ "$TEARDOWN_MODE" != "terraform" ] && [ "$TEARDOWN_MODE" != "az-sweep" ]; then
  echo "::error::TEARDOWN_MODE must be 'terraform' or 'az-sweep' (got '${TEARDOWN_MODE}') - refusing to guess eligibility off an unrecognised mode."
  exit 1
fi

if [ -z "$PHASE1_RESULTS_JSON" ] || ! printf '%s' "$PHASE1_RESULTS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "::error::PHASE1_RESULTS_JSON is empty or not valid JSON - cannot compute per-root eligibility. The calling workflow job must set this from \${{ toJSON(needs) }}."
  exit 1
fi

if [ ! -f "$backend_hcl" ]; then
  echo "::error::${backend_hcl} not found - cannot resolve the state Storage Account name/container."
  exit 1
fi
SA_NAME="$(grep -E '^\s*storage_account_name' "$backend_hcl" | sed -E 's/.*=\s*"?([^"#[:space:]]+)"?.*/\1/')"
CONTAINER="$(grep -E '^\s*container_name'     "$backend_hcl" | sed -E 's/.*=\s*"?([^"#[:space:]]+)"?.*/\1/')"
if [ -z "$SA_NAME" ] || [ -z "$CONTAINER" ]; then
  echo "::error::Could not parse storage_account_name/container_name from ${backend_hcl}."
  exit 1
fi

echo "== Phase 4 STATE RESET: SA=${SA_NAME} container=${CONTAINER} mode=${TEARDOWN_MODE} remove_mg_hierarchy=${REMOVE_MG_HIERARCHY} =="

# determine_action <key> - the AMENDED 2026-08-01 eligibility (see the header ELIGIBILITY note
# above for the full rationale). Order: carve-out B, this key's own Phase 1 job result, then
# (identity only) permanent exclusion / (every other key) VERIFY-fallback. Mode-independent by
# construction - TEARDOWN_MODE is read only for the summary banner, never branched on here.
# Echoes one of:
#   ELIGIBLE | ELIGIBLE-via-verify:<result> | SKIPPED-carveout-A:<result> |
#   SKIPPED-carveout-B | SKIPPED-no-job-mapping (structural bug guard, should be unreachable)
determine_action() {
  local key="$1"

  if [ "$key" = "$MANAGEMENT_GROUPS_KEY" ] && [ "$REMOVE_MG_HIERARCHY" != "true" ]; then
    printf 'SKIPPED-carveout-B'
    return 0
  fi

  local job="${STATE_KEY_PHASE1_JOB[$key]:-}"
  if [ -z "$job" ]; then
    printf 'SKIPPED-no-job-mapping'
    return 0
  fi
  local result
  result="$(printf '%s' "$PHASE1_RESULTS_JSON" | jq -r --arg j "$job" '.[$j].result // "missing"')"
  if [ "$result" = "success" ]; then
    printf 'ELIGIBLE'
    return 0
  fi

  # This key's own Phase 1 destroy job did not succeed (mode=terraform: failure/skipped;
  # mode=az-sweep: always skipped there, Phase 1 never runs). CARVE-OUT A: platform/identity is
  # the ONE permanent exception - see the header ELIGIBILITY note for the full Entra/Graph/PIM
  # rationale. Every other key falls through to the VERIFY-fallback rule below.
  if [ "$key" = "$IDENTITY_KEY" ]; then
    printf 'SKIPPED-carveout-A:%s' "$result"
    return 0
  fi

  # VERIFY-fallback (2026-08-01 amendment): the calling workflow job already hard-gates this
  # whole script's invocation on needs.verify.result == 'success' at target=all, and every key
  # reaching this line is verified (grep, 2026-08-01) to declare only ARM-plane providers - so
  # that gate is already sufficient, independent evidence this key's entire footprint is gone.
  printf 'ELIGIBLE-via-verify:%s' "$result"
}

# Globals set by reset_one_key / _reset_write_and_confirm for the calling loop iteration to
# read into the summary table (mirrors this codebase's AZ_RUN_STDERR global-side-effect idiom).
bytes_before=""
bytes_after=""

# _reset_write_and_confirm <key> <lineage|empty> <serial|empty> <terraform_version|empty> -
# builds and writes the canonical empty document (preserving any valid existing lineage/
# terraform_version and incrementing serial; generating a fresh lineage and falling back to
# serial=1 / PINNED_TERRAFORM_VERSION when a field is unavailable), stamps the ADR-068
# decision-3 metadata, then CONFIRMS the read-back (size + parsed .resources == []). Returns
# 0 on a fully confirmed reset, 1 on any failure (never partial-success).
_reset_write_and_confirm() {
  local key="$1" lineage="$2" serial_existing="$3" tf_version_existing="$4"
  local new_lineage new_serial new_tf_version

  if [ -n "$lineage" ]; then
    new_lineage="$lineage"
  else
    new_lineage="$(cat /proc/sys/kernel/random/uuid)"
  fi
  if [ -n "$serial_existing" ]; then
    # 10# forces base-10 interpretation - a serial that happens to be zero-padded (e.g. "007")
    # would otherwise be misread by bash arithmetic as octal (and "018"/"019" would hard-error,
    # 8/9 not being valid octal digits). Terraform never writes a padded serial in practice, but
    # this is cheap insurance against that specific bash footgun.
    new_serial=$((10#$serial_existing + 1))
  else
    new_serial=1
  fi
  if [ -n "$tf_version_existing" ]; then
    new_tf_version="$tf_version_existing"
  else
    new_tf_version="$PINNED_TERRAFORM_VERSION"
  fi

  local doc_tmpfile
  doc_tmpfile="$(mktemp)"
  canonical_empty_state_json "$new_tf_version" "$new_serial" "$new_lineage" > "$doc_tmpfile"

  local utc_now
  utc_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # retry_blob_action_on_network_rule (teardown-common.sh, 2026-08-01 firewall-race fix): this
  # upload is idempotent (identical bytes, --overwrite true), so a bounded retry on the
  # is_storage_network_rule_error class alone is safe - see that helper's own comment.
  local up_err
  if ! retry_blob_action_on_network_rule up_err storage blob upload \
      --account-name "$SA_NAME" --container-name "$CONTAINER" --name "$key" \
      --file "$doc_tmpfile" --auth-mode login --overwrite true --content-type application/json \
      --metadata tf_state_reset=true "tf_state_reset_run_id=${GITHUB_RUN_ID:-unknown}" \
                 "tf_state_reset_utc=${utc_now}" "tf_state_reset_mode=${TEARDOWN_MODE}" \
                 "tf_state_reset_ref=${GITHUB_SHA:-unknown}" \
      --output none; then
    echo "::error::${key}: blob upload (reset overwrite) failed: ${up_err}"
    rm -f "$doc_tmpfile"
    return 1
  fi
  rm -f "$doc_tmpfile"

  # CONFIRM READ-BACK (this codebase's confirm-GET discipline - the write side never trusts
  # its own reported success).
  local confirm_len_out
  if ! az_run_retry confirm_len_out storage blob show \
      --account-name "$SA_NAME" --container-name "$CONTAINER" --name "$key" \
      --auth-mode login --query properties.contentLength -o tsv; then
    echo "::error::${key}: confirm read-back (size) failed immediately after the reset upload: ${AZ_RUN_STDERR}"
    return 1
  fi
  case "$confirm_len_out" in
    ''|*[!0-9]*)
      echo "::error::${key}: confirm read-back returned a non-numeric contentLength ('${confirm_len_out}') after reset."
      return 1
      ;;
  esac
  if [ "$confirm_len_out" -lt "$TINY_BLOB_THRESHOLD_BYTES" ]; then
    echo "::error::${key}: confirm read-back size ${confirm_len_out} bytes is below the ${TINY_BLOB_THRESHOLD_BYTES}-byte tiny-blob threshold immediately after reset - the canonical empty document is expected to land inside the OK band; the write did not produce the expected document."
    return 1
  fi

  # retry_blob_action_on_network_rule (teardown-common.sh, 2026-08-01 firewall-race fix): a
  # re-download to a fresh temp file is idempotent, so a bounded retry on the
  # is_storage_network_rule_error class alone is safe - see that helper's own comment.
  local confirm_tmpfile confirm_dl_err
  confirm_tmpfile="$(mktemp)"
  if ! retry_blob_action_on_network_rule confirm_dl_err storage blob download \
      --account-name "$SA_NAME" --container-name "$CONTAINER" \
      --name "$key" --file "$confirm_tmpfile" --auth-mode login --output none; then
    echo "::error::${key}: confirm read-back download failed immediately after reset: ${confirm_dl_err}"
    rm -f "$confirm_tmpfile"
    return 1
  fi
  if ! jq -e '.resources | length == 0' "$confirm_tmpfile" >/dev/null 2>&1; then
    echo "::error::${key}: confirm read-back failed 'jq -e .resources | length == 0' - the written document does not read back as the canonical empty form."
    rm -f "$confirm_tmpfile"
    return 1
  fi
  rm -f "$confirm_tmpfile"

  bytes_after="$confirm_len_out"
  echo "  RESET  ${key}: lineage=${new_lineage} serial=${new_serial} terraform_version=${new_tf_version} bytes_before=${bytes_before} bytes_after=${bytes_after}"
  return 0
}

# reset_one_key <key> - the full per-key flow: show (size + lease), bounded lease-locked
# retry, download + parse (existing lineage/serial/terraform_version, or a labelled anomaly
# fallback), then _reset_write_and_confirm. Sets the bytes_before/bytes_after globals for the
# caller's summary row. Returns 0 on success, 1 on any failure.
reset_one_key() {
  local key="$1"
  bytes_before="-"
  bytes_after="-"

  local show_json
  if ! az_run_retry show_json storage blob show \
      --account-name "$SA_NAME" --container-name "$CONTAINER" --name "$key" \
      --auth-mode login --query "{length:properties.contentLength, lease:properties.lease.status}" -o json; then
    if is_not_found_error "$AZ_RUN_STDERR"; then
      echo "  INFO  ${key}: absent - writing the canonical empty state document (fresh lineage, serial=1, terraform_version=${PINNED_TERRAFORM_VERSION})."
      bytes_before="0 (absent)"
      _reset_write_and_confirm "$key" "" "" ""
      return $?
    elif is_auth_error "$AZ_RUN_STDERR"; then
      echo "::error::${key}: blob show failed with an auth/transport error - cannot certify this key's current state: ${AZ_RUN_STDERR}"
      return 1
    else
      echo "::error::${key}: blob show failed for an unexpected non-auth, non-not-found reason - cannot certify this key's current state: ${AZ_RUN_STDERR}"
      return 1
    fi
  fi

  local existing_length existing_lease
  existing_length="$(printf '%s' "$show_json" | jq -r '.length // empty')"
  existing_lease="$(printf '%s' "$show_json" | jq -r '.lease // empty')"
  bytes_before="${existing_length:-0}"

  # Bounded lease-locked retry: 3 attempts, 20s apart. By Phase 4 (strictly after a verified
  # destroy and a passed whole-estate VERIFY) no legitimate holder should exist, so a lease is
  # itself the anomaly - never auto-broken.
  local attempt=0
  while [ "$existing_lease" = "locked" ] && [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    echo "  ::warning::${key}: lease is LOCKED (retry ${attempt}/3) - sleeping 20s before recheck."
    sleep 20
    if ! az_run_retry show_json storage blob show \
        --account-name "$SA_NAME" --container-name "$CONTAINER" --name "$key" \
        --auth-mode login --query "{length:properties.contentLength, lease:properties.lease.status}" -o json; then
      echo "::error::${key}: blob show (lease recheck ${attempt}/3) failed: ${AZ_RUN_STDERR}"
      return 1
    fi
    existing_lease="$(printf '%s' "$show_json" | jq -r '.lease // empty')"
  done
  if [ "$existing_lease" = "locked" ]; then
    echo "::error::${key}: lease still LOCKED after 3 retries (~60s) - no legitimate holder should exist at this point in the run, so the lease itself is the anomaly. NOT auto-breaking. Investigate the holder first; if appropriate, run: az storage blob lease break --account-name ${SA_NAME} --container-name ${CONTAINER} --blob-name ${key} --auth-mode login"
    return 1
  fi

  # retry_blob_action_on_network_rule (teardown-common.sh, 2026-08-01 firewall-race fix): a
  # download to a fresh temp file is idempotent, so a bounded retry on the
  # is_storage_network_rule_error class alone is safe - see that helper's own comment. This is
  # the exact call shape the fix was found on live: a `show` immediately before this succeeded,
  # confirming the blob present, and this `download`, seconds later, failed with the
  # network-rule text - two consecutive requests landing on two different front ends.
  local tmpfile dl_err
  tmpfile="$(mktemp)"
  if ! retry_blob_action_on_network_rule dl_err storage blob download \
      --account-name "$SA_NAME" --container-name "$CONTAINER" \
      --name "$key" --file "$tmpfile" --auth-mode login --output none; then
    echo "::error::${key}: blob download failed (confirmed present by the preceding show call, so this is an anomaly, not absence) after exhausting the network-rule retry budget: ${dl_err}"
    rm -f "$tmpfile"
    return 1
  fi

  local lineage="" serial_existing="" tf_version_existing=""
  if ! jq -e '.' "$tmpfile" >/dev/null 2>&1; then
    echo "  ::warning::${key}: present blob is NOT valid JSON - FM-1-class anomaly found at reset time. Writing a fresh canonical empty document (fresh lineage, serial=1, terraform_version=${PINNED_TERRAFORM_VERSION})."
  else
    lineage="$(jq -r '.lineage // empty' "$tmpfile" 2>/dev/null)"
    serial_existing="$(jq -r '.serial // empty' "$tmpfile" 2>/dev/null)"
    tf_version_existing="$(jq -r '.terraform_version // empty' "$tmpfile" 2>/dev/null)"
    case "$serial_existing" in
      ''|*[!0-9]*) serial_existing="" ;;
    esac
    if [ -z "$lineage" ] || [ -z "$serial_existing" ] || [ -z "$tf_version_existing" ]; then
      echo "  ::warning::${key}: present blob is valid JSON but is missing/invalid lineage, serial or terraform_version (lineage='${lineage}' serial='${serial_existing}' terraform_version='${tf_version_existing}') - FM-1-class anomaly found at reset time. Writing a fresh canonical empty document, preserving only the field(s) that parsed validly."
    fi
  fi
  rm -f "$tmpfile"

  _reset_write_and_confirm "$key" "$lineage" "$serial_existing" "$tf_version_existing"
  return $?
}

declare -a SUMMARY_ROWS=()
overall_fail=0

for key in "${STATE_KEYS_WORKLOAD[@]}"; do
  action="$(determine_action "$key")"
  case "$action" in
    ELIGIBLE)
      if reset_one_key "$key"; then
        SUMMARY_ROWS+=("${key}|RESET|${bytes_before}|${bytes_after}")
      else
        overall_fail=1
        SUMMARY_ROWS+=("${key}|FAILED|${bytes_before}|-")
      fi
      ;;
    ELIGIBLE-via-verify:*)
      reason="${action#ELIGIBLE-via-verify:}"
      echo "  ::warning::${key}: own Phase 1 destroy job result was '${reason}' (not 'success'), but resetting anyway on whole-estate VERIFY evidence (ADR-068 decision 2/4, amended 2026-08-01) - this key has no non-ARM-plane footprint outside VERIFY's coverage."
      if reset_one_key "$key"; then
        SUMMARY_ROWS+=("${key}|RESET-via-verify(${reason})|${bytes_before}|${bytes_after}")
      else
        overall_fail=1
        SUMMARY_ROWS+=("${key}|FAILED|${bytes_before}|-")
      fi
      ;;
    SKIPPED-carveout-A:*)
      reason="${action#SKIPPED-carveout-A:}"
      echo "  INFO  ${key}: CARVE-OUT A - own Phase 1 destroy job result was '${reason}' (not 'success'), and this is the one key VERIFY cannot fall back to certify (Entra/PIM objects the ARM-only sweep cannot delete and VERIFY 0-10 cannot check; ADR-068 decision 4). Not reset."
      SUMMARY_ROWS+=("${key}|SKIPPED-carveout-A(${reason})|-|-")
      ;;
    SKIPPED-carveout-B)
      echo "  INFO  ${key}: CARVE-OUT B - remove_mg_hierarchy=false, so the MG tree survives and VERIFY 4 skipped its MG check; not reset on no evidence (ADR-068 decision 4)."
      SUMMARY_ROWS+=("${key}|SKIPPED-carveout-B|-|-")
      ;;
    SKIPPED-no-job-mapping)
      echo "::error::${key}: no Phase 1 job mapping found in STATE_KEY_PHASE1_JOB - this is a structural bug in teardown-state-reset.sh, not a runtime condition."
      overall_fail=1
      SUMMARY_ROWS+=("${key}|FAILED-no-job-mapping|-|-")
      ;;
    *)
      echo "::error::${key}: determine_action returned an unrecognised action '${action}' - structural bug in teardown-state-reset.sh."
      overall_fail=1
      SUMMARY_ROWS+=("${key}|FAILED-bug|-|-")
      ;;
  esac
done

echo "----------------------------------------------------------------"
echo "Phase 4 STATE RESET summary (mode=${TEARDOWN_MODE} remove_mg_hierarchy=${REMOVE_MG_HIERARCHY}):"
printf '%-48s %-26s %14s %14s\n' "KEY" "ACTION" "BYTES_BEFORE" "BYTES_AFTER"
for row in "${SUMMARY_ROWS[@]}"; do
  IFS='|' read -r row_key row_action row_before row_after <<< "$row"
  printf '%-48s %-26s %14s %14s\n' "$row_key" "$row_action" "$row_before" "$row_after"
done
echo "----------------------------------------------------------------"

if [ "$overall_fail" -ne 0 ]; then
  echo "::error::Phase 4 STATE RESET finished with one or more eligible keys FAILED - see the errors above. The estate destruction itself already succeeded (this job only runs after a passed Phase 3 VERIFY); the state backend is now only PARTIALLY reset, which is a condition an operator must see and fix. Re-dispatch (target=all) is safe - resetting an already-empty blob is a clean no-op (ADR-068)."
  exit 1
fi

echo "Phase 4 STATE RESET complete - every eligible key now holds the canonical empty state document."
exit 0
