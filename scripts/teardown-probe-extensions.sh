# scripts/teardown-probe-extensions.sh - READ-ONLY per-scope extension-resource discovery probe
# (teardown-completeness extension sweep, 2026-07-23). Deliverable 1, Part B. Reports every
# scope-path-keyed EXTENSION resource (budgets, diagnostic settings, policy exemptions,
# Microsoft.Security singletons, AADDS) this estate could have left behind at MG/subscription/RG/
# tenant scope - it deletes NOTHING. Resource Graph does not index these classes (VERIFY 9's own
# header comment, teardown-verify.sh, states this explicitly for budgets/exports/scheduled-
# actions/diagnostic-settings), so this probe talks to ARM directly via `az rest`, the same
# pattern the sweep (teardown-az-sweep.sh) and VERIFY (teardown-verify.sh) already use.
#
# Purpose: the authoritative orphan MAP an operator or a later az-sweep dispatch reads BEFORE
# deciding what needs sweeping - this is what the FIX-1..FIX-5 sweep sub-steps
# (teardown-az-sweep.sh) actually remove; this script only ever reports.
#
# Every discovery loop is BY LIST (never a hardcoded name/RG list), matching the lesson
# ADR-062 already drew ("enumerated class lists are the wrong mechanism") - RG-scope discovery
# reuses `discover_live_rgs` (teardown-common.sh), the same RG_SWEEP_QUERY pattern the RG sweep
# itself uses, so a renamed or newly-added RG is still covered with no code change here.
#
# Ownership classification: OWNED (is_owned_policy_object for exemptions, is_globaris_owned for
# everything else that carries a globaris-substring naming convention) vs UNOWNED (reported for
# awareness, never a probe failure by itself - a non-estate object in a shared scope is not
# this estate's problem, same design boundary SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST already
# encodes for VERIFY 9).
#
# Fail-loud convention (identical to every other script in this codebase, section 9.4): any
# LIST call that fails is FAIL LOUD (exit 1) - a live scope's own list can never legitimately
# fail, so a failure is auth/transport-shaped or a genuine bug, never "empty". The ONE
# documented exception is 6f's tenant AAD diagnostic-settings equivalent below (Security-Admin-
# gated) - see that section's own comment for why a 401/403 there is reported as a named
# finding rather than aborting the whole probe (the probe's job is to report the FULL map in one
# pass, including "this class could not be checked" as its own finding).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

# ARM_BASE is sourced from teardown-common.sh - no local declaration here (one shared
# constant, not one copy per script).

mapfile -t SUBS < <(teardown_subscriptions)
if [ "${#SUBS[@]}" -eq 0 ]; then
  echo "::error::No subscription IDs available (MANAGEMENT_SUBSCRIPTION_ID / CONNECTIVITY_SUBSCRIPTION_ID / IDENTITY_SUBSCRIPTION_ID / SECURITY_SUBSCRIPTION_ID / LANDINGZONES_SUBSCRIPTION_ID all empty). Cannot probe."
  exit 1
fi

fail=0
declare -a FINDINGS=()
record_finding() {
  FINDINGS+=("$1")
  echo "  FOUND  $1"
}

# MG-existence snapshot (code-review BLOCK-1 fix, 2026-07-23), the SAME oracle
# teardown-verify.sh's VERIFY 1/4 and teardown-az-sweep.sh's FIX-1 already use
# (mg_snapshot_load / mg_in_snapshot, teardown-common.sh), for the SAME reason: an MG-scope
# `az rest` call against a DELETED globaris-tree MG returns HTTP-403 AuthorizationFailed for
# this scoped SP (its MG-scoped grants are deleted WITH the MG - see mg_snapshot_load's own
# comment), not a clean 404. On a partially or fully torn-down estate - this probe's PRIMARY
# use case - the three MG-scope loops below would otherwise treat that expected 403 as an
# auth-shaped list failure and report a hard probe failure instead of a clean "MG gone, nothing
# to check" result. Gating every MG-scope call behind mg_in_snapshot (skip an absent MG
# entirely) is exactly the fix FIX-1 already applies on the delete side
# (teardown-az-sweep.sh:363-367) - this closes the same gap on the read side.
mg_snapshot_ok=1
if ! mg_snapshot_load; then
  echo "::error::Extension-resource discovery probe cannot certify any MG-scope class without a trustworthy MG-existence snapshot (see the error above)."
  fail=1
  mg_snapshot_ok=0
fi

echo "== Extension-resource discovery probe =="

# ---------------------------------------------------------------------------
# 1. Consumption budgets - MG scope, subscription scope, RG scope.
#    BUDGETS_API_VERSION (2024-08-01, teardown-common.sh) uniformly across all three.
# ---------------------------------------------------------------------------
echo "-- 1. Consumption budgets (MG / subscription / RG scope) --"

if [ "$mg_snapshot_ok" -eq 0 ]; then
  echo "  MG-scope budgets: skipped - no trustworthy MG-existence snapshot (see the failure above)."
else
  for mg in "${MG_SCOPES[@]}"; do
    if ! mg_in_snapshot "$mg"; then
      echo "  MG ${mg}: absent from the snapshot - nothing to check (already gone, not a remnant)."
      continue
    fi
    mg_scope="$(mg_scope_path "$mg")"
    if ! az_run p_mg_budget_rows_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}" \
        --query "value[].name" -o tsv; then
      if is_auth_error "$AZ_RUN_STDERR"; then
        echo "::error::MG-scope budget list failed for MG ${mg} with an auth/transport error: ${AZ_RUN_STDERR}"
      else
        echo "::error::MG-scope budget list failed for MG ${mg}: ${AZ_RUN_STDERR}"
      fi
      fail=1
      continue
    fi
    # shellcheck disable=SC2154  # p_mg_budget_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_mg_budget_names <<< "$p_mg_budget_rows_out"
    for name in "${p_mg_budget_names[@]:-}"; do
      [ -z "$name" ] && continue
      owned="unowned"
      is_globaris_owned "$name" && owned="OWNED"
      record_finding "budget MG=${mg} name=${name} (${owned})"
    done
  done
fi

for sub in "${SUBS[@]}"; do
  if ! az_run p_sub_budget_rows_out consumption budget list --subscription "$sub" --query "[].name" -o tsv; then
    echo "::error::subscription-scope budget list failed for sub ${sub}: ${AZ_RUN_STDERR}"
    fail=1
  else
    # shellcheck disable=SC2154  # p_sub_budget_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_sub_budget_names <<< "$p_sub_budget_rows_out"
    for name in "${p_sub_budget_names[@]:-}"; do
      [ -z "$name" ] && continue
      owned="unowned"
      is_globaris_owned "$name" && owned="OWNED"
      record_finding "budget sub=${sub} name=${name} (${owned})"
    done
  fi

  if ! discover_live_rgs p_rg_names_budgets_out "$sub"; then
    echo "::error::RG list failed for sub ${sub} while discovering RG-scope budget targets: ${AZ_RUN_STDERR}"
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # p_rg_names_budgets_out is assigned indirectly by az_run's printf -v
  mapfile -t p_rg_names_budgets <<< "$p_rg_names_budgets_out"
  for rg in "${p_rg_names_budgets[@]:-}"; do
    [ -z "$rg" ] && continue
    if ! az_run p_rg_budget_rows_out rest --method get \
        --url "${ARM_BASE}/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}" \
        --query "value[].name" -o tsv; then
      echo "::error::RG-scope budget list failed for RG ${rg} (sub ${sub}): ${AZ_RUN_STDERR}"
      fail=1
      continue
    fi
    # shellcheck disable=SC2154  # p_rg_budget_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_rg_budget_names <<< "$p_rg_budget_rows_out"
    for name in "${p_rg_budget_names[@]:-}"; do
      [ -z "$name" ] && continue
      owned="unowned"
      is_globaris_owned "$name" && owned="OWNED"
      record_finding "budget RG=${rg} sub=${sub} name=${name} (${owned})"
    done
  done
done

# ---------------------------------------------------------------------------
# 2. Diagnostic settings - MG scope (MG_DIAGNOSTIC_SETTINGS_API_VERSION, a DISTINCT op group
#    from the generic one - see teardown-common.sh for the correction from the original brief),
#    subscription scope (activity log, via the existing `az monitor diagnostic-settings
#    subscription list` CLI wrapper), tenant Entra (Microsoft.AadIam, separate sub-section
#    below because it is Security-Admin-gated and needs its own failure handling), and
#    resource-scoped ones on resources inside surviving RGs (RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION).
# ---------------------------------------------------------------------------
echo "-- 2. Diagnostic settings (MG / subscription / resource-in-surviving-RG scope) --"

if [ "$mg_snapshot_ok" -eq 0 ]; then
  echo "  MG-scope diagnostic settings: skipped - no trustworthy MG-existence snapshot (see the failure above)."
else
  for mg in "${MG_SCOPES[@]}"; do
    if ! mg_in_snapshot "$mg"; then
      echo "  MG ${mg}: absent from the snapshot - nothing to check (already gone, not a remnant)."
      continue
    fi
    mg_scope="$(mg_scope_path "$mg")"
    if ! az_run p_mg_diag_rows_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/microsoft.insights/diagnosticSettings?api-version=${MG_DIAGNOSTIC_SETTINGS_API_VERSION}" \
        --query "value[].name" -o tsv; then
      if is_auth_error "$AZ_RUN_STDERR"; then
        echo "::error::MG-scope diagnostic-settings list failed for MG ${mg} with an auth/transport error: ${AZ_RUN_STDERR}"
      else
        echo "::error::MG-scope diagnostic-settings list failed for MG ${mg}: ${AZ_RUN_STDERR}"
      fi
      fail=1
      continue
    fi
    # shellcheck disable=SC2154  # p_mg_diag_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_mg_diag_names <<< "$p_mg_diag_rows_out"
    for name in "${p_mg_diag_names[@]:-}"; do
      [ -z "$name" ] && continue
      owned="unowned"
      is_globaris_owned "$name" && owned="OWNED"
      record_finding "diagnostic-setting MG=${mg} name=${name} (${owned})"
    done
  done
fi

for sub in "${SUBS[@]}"; do
  if ! az_run p_sub_diag_rows_out monitor diagnostic-settings subscription list --subscription "$sub" --query "value[].name" -o tsv; then
    echo "::error::subscription-scope diagnostic-settings list failed for sub ${sub}: ${AZ_RUN_STDERR}"
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # p_sub_diag_rows_out is assigned indirectly by az_run's printf -v
  mapfile -t p_sub_diag_names <<< "$p_sub_diag_rows_out"
  for name in "${p_sub_diag_names[@]:-}"; do
    [ -z "$name" ] && continue
    owned="unowned"
    { is_globaris_owned "$name" || [ "$name" = "diag-activity-to-security-law" ]; } && owned="OWNED"
    record_finding "diagnostic-setting sub=${sub} name=${name} (${owned})"
  done
done

echo "  (resource-scoped diagnostic settings on resources inside surviving RGs)"
for sub in "${SUBS[@]}"; do
  if ! discover_live_rgs p_rg_names_diag_out "$sub"; then
    echo "::error::RG list failed for sub ${sub} while discovering surviving RGs for the resource-scoped diagnostic-settings check: ${AZ_RUN_STDERR}"
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # p_rg_names_diag_out is assigned indirectly by az_run's printf -v
  mapfile -t p_rg_names_diag <<< "$p_rg_names_diag_out"
  for rg in "${p_rg_names_diag[@]:-}"; do
    [ -z "$rg" ] && continue
    if ! az_run p_rg_resource_ids_out resource list --resource-group "$rg" --subscription "$sub" --query "[].id" -o tsv; then
      echo "::error::resource list failed for RG ${rg} (sub ${sub}) while enumerating resources for the diagnostic-settings check: ${AZ_RUN_STDERR}"
      fail=1
      continue
    fi
    # shellcheck disable=SC2154  # p_rg_resource_ids_out is assigned indirectly by az_run's printf -v
    mapfile -t p_rg_resource_ids <<< "$p_rg_resource_ids_out"
    for res_id in "${p_rg_resource_ids[@]:-}"; do
      [ -z "$res_id" ] && continue
      if ! az_run p_res_diag_rows_out rest --method get \
          --url "${ARM_BASE}${res_id}/providers/Microsoft.Insights/diagnosticSettings?api-version=${RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION}" \
          --query "value[].name" -o tsv; then
        # A resource-scoped diagnostic-settings GET can legitimately 404/BadRequest for a
        # resource TYPE that does not support diagnostic settings at all (most do; some do
        # not) - this is the one list in this probe where a non-auth failure is expected
        # noise, not a probe failure. Auth-shaped failures still fail loud.
        if is_auth_error "$AZ_RUN_STDERR"; then
          echo "::error::resource-scoped diagnostic-settings list failed for ${res_id} with an auth/transport error: ${AZ_RUN_STDERR}"
          fail=1
        fi
        continue
      fi
      # shellcheck disable=SC2154  # p_res_diag_rows_out is assigned indirectly by az_run's printf -v
      mapfile -t p_res_diag_names <<< "$p_res_diag_rows_out"
      for name in "${p_res_diag_names[@]:-}"; do
        [ -z "$name" ] && continue
        owned="unowned"
        is_globaris_owned "$name" && owned="OWNED"
        record_finding "diagnostic-setting resource=${res_id} name=${name} (${owned})"
      done
    done
  done
done

# ---------------------------------------------------------------------------
# 2b. Tenant Microsoft.AadIam/diagnosticSettings (Security-Admin-gated, see FIX-5's own comment
#     in teardown-az-sweep.sh for the full rationale). A 401/403 here is reported as its OWN
#     named finding ("could not check - insufficient directory role") rather than aborting the
#     whole probe run - the probe's contract is to report the full map including "this class
#     could not be checked", not to fail all-or-nothing on one Security-Admin-gated class.
# ---------------------------------------------------------------------------
echo "-- 2b. Tenant Microsoft.AadIam/diagnosticSettings --"
if ! az_run p_tenant_diag_rows_out rest --method get \
    --url "${ARM_BASE}/providers/Microsoft.AadIam/diagnosticSettings?api-version=${TENANT_AAD_DIAGNOSTIC_SETTINGS_API_VERSION}" \
    --query "value[].name" -o tsv; then
  if is_auth_error "$AZ_RUN_STDERR"; then
    record_finding "tenant AAD diagnostic-settings: COULD NOT CHECK - the CI OIDC SP does not (or no longer) hold Security Administrator (or Global Administrator) at the tenant root (ADR-033/034 permission class). Not counted as a probe failure - this is a known, documented gap."
  else
    echo "::error::tenant Microsoft.AadIam/diagnosticSettings list failed for an unexpected non-auth reason: ${AZ_RUN_STDERR}"
    fail=1
  fi
else
  # shellcheck disable=SC2154  # p_tenant_diag_rows_out is assigned indirectly by az_run's printf -v
  mapfile -t p_tenant_diag_names <<< "$p_tenant_diag_rows_out"
  for name in "${p_tenant_diag_names[@]:-}"; do
    [ -z "$name" ] && continue
    owned="unowned"
    { is_globaris_owned "$name" || [ "$name" = "$TENANT_AAD_DIAG_SETTING_NAME" ]; } && owned="OWNED"
    record_finding "tenant AAD diagnostic-setting name=${name} (${owned})"
  done
fi

# ---------------------------------------------------------------------------
# 3. Policy exemptions - subscription scope, MG scope, RG scope (spoke + identity + synthetic
#    RGs, discovered by list). POLICY_EXEMPTIONS_API_VERSION_NEW (2022-07-01-preview), atExactScope
#    everywhere, is_owned_policy_object predicate (byte-identical to the sweep and to VERIFY 6d/9).
# ---------------------------------------------------------------------------
echo "-- 3. Policy exemptions (subscription / MG / RG scope, atExactScope) --"

for sub in "${SUBS[@]}"; do
  if ! az_run p_sub_ex_rows_out rest --method get \
      --url "${ARM_BASE}/subscriptions/${sub}/providers/Microsoft.Authorization/policyExemptions?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}&\$filter=atExactScope()" \
      --query "value[].[name, properties.policyAssignmentId]" -o tsv; then
    echo "::error::subscription-scope policy exemption list failed for sub ${sub}: ${AZ_RUN_STDERR}"
    fail=1
  else
    # shellcheck disable=SC2154  # p_sub_ex_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_sub_ex_rows <<< "$p_sub_ex_rows_out"
    for row in "${p_sub_ex_rows[@]:-}"; do
      [ -z "$row" ] && continue
      ex_name="$(printf '%s' "$row" | cut -f1)"
      ex_assignment_id="$(printf '%s' "$row" | cut -f2)"
      owned="unowned"
      is_owned_policy_object "$ex_name" "$ex_assignment_id" && owned="OWNED"
      record_finding "policy-exemption sub=${sub} name=${ex_name} (${owned})"
    done
  fi

  if ! discover_live_rgs p_rg_names_ex_out "$sub"; then
    echo "::error::RG list failed for sub ${sub} while discovering RG-scope policy-exemption targets: ${AZ_RUN_STDERR}"
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # p_rg_names_ex_out is assigned indirectly by az_run's printf -v
  mapfile -t p_rg_names_ex <<< "$p_rg_names_ex_out"
  for rg in "${p_rg_names_ex[@]:-}"; do
    [ -z "$rg" ] && continue
    if ! az_run p_rg_ex_rows_out rest --method get \
        --url "${ARM_BASE}/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.Authorization/policyExemptions?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}&\$filter=atExactScope()" \
        --query "value[].[name, properties.policyAssignmentId]" -o tsv; then
      echo "::error::RG-scope policy exemption list failed for RG ${rg} (sub ${sub}): ${AZ_RUN_STDERR}"
      fail=1
      continue
    fi
    # shellcheck disable=SC2154  # p_rg_ex_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_rg_ex_rows <<< "$p_rg_ex_rows_out"
    for row in "${p_rg_ex_rows[@]:-}"; do
      [ -z "$row" ] && continue
      ex_name="$(printf '%s' "$row" | cut -f1)"
      ex_assignment_id="$(printf '%s' "$row" | cut -f2)"
      owned="unowned"
      is_owned_policy_object "$ex_name" "$ex_assignment_id" && owned="OWNED"
      record_finding "policy-exemption RG=${rg} sub=${sub} name=${ex_name} (${owned})"
    done
  done
done

if [ "$mg_snapshot_ok" -eq 0 ]; then
  echo "  MG-scope policy exemptions: skipped - no trustworthy MG-existence snapshot (see the failure above)."
else
  for mg in "${MG_SCOPES[@]}"; do
    if ! mg_in_snapshot "$mg"; then
      echo "  MG ${mg}: absent from the snapshot - nothing to check (already gone, not a remnant)."
      continue
    fi
    mg_scope="$(mg_scope_path "$mg")"
    if ! az_run p_mg_ex_rows_out rest --method get \
        --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Authorization/policyExemptions?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}&\$filter=atExactScope()" \
        --query "value[].[name, properties.policyAssignmentId]" -o tsv; then
      if is_auth_error "$AZ_RUN_STDERR"; then
        echo "::error::MG-scope policy exemption list failed for MG ${mg} with an auth/transport error: ${AZ_RUN_STDERR}"
      else
        echo "::error::MG-scope policy exemption list failed for MG ${mg}: ${AZ_RUN_STDERR}"
      fi
      fail=1
      continue
    fi
    # shellcheck disable=SC2154  # p_mg_ex_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_mg_ex_rows <<< "$p_mg_ex_rows_out"
    for row in "${p_mg_ex_rows[@]:-}"; do
      [ -z "$row" ] && continue
      ex_name="$(printf '%s' "$row" | cut -f1)"
      ex_assignment_id="$(printf '%s' "$row" | cut -f2)"
      owned="unowned"
      is_owned_policy_object "$ex_name" "$ex_assignment_id" && owned="OWNED"
      record_finding "policy-exemption MG=${mg} name=${ex_name} (${owned})"
    done
  done
fi

# ---------------------------------------------------------------------------
# 4. Microsoft.Security singletons (security subscription only): pricings, securityContacts,
#    automations.
# ---------------------------------------------------------------------------
echo "-- 4. Microsoft.Security singletons (security subscription) --"
if [ -z "${SECURITY_SUBSCRIPTION_ID:-}" ]; then
  echo "::error::SECURITY_SUBSCRIPTION_ID is empty - cannot check Microsoft.Security singletons."
  fail=1
else
  if ! az_run p_pricing_rows_out rest --method get \
      --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/pricings?api-version=${SECURITY_PRICINGS_API_VERSION}" \
      --query "value[].[name, properties.pricingTier]" -o tsv; then
    echo "::error::pricings list failed for the security subscription: ${AZ_RUN_STDERR}"
    fail=1
  else
    # shellcheck disable=SC2154  # p_pricing_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_pricing_rows <<< "$p_pricing_rows_out"
    for row in "${p_pricing_rows[@]:-}"; do
      [ -z "$row" ] && continue
      plan_name="$(printf '%s' "$row" | cut -f1)"
      plan_tier="$(printf '%s' "$row" | cut -f2)"
      if [ "$plan_tier" != "Free" ]; then
        record_finding "Defender pricing plan=${plan_name} tier=${plan_tier} (not Free)"
      fi
    done
  fi

  if ! az_run p_contact_rows_out rest --method get \
      --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/securityContacts?api-version=${SECURITY_CONTACTS_API_VERSION}" \
      --query "value[].name" -o tsv; then
    echo "::error::securityContacts list failed for the security subscription: ${AZ_RUN_STDERR}"
    fail=1
  else
    # shellcheck disable=SC2154  # p_contact_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_contact_names <<< "$p_contact_rows_out"
    for name in "${p_contact_names[@]:-}"; do
      [ -z "$name" ] && continue
      owned="unowned"
      is_globaris_owned "$name" && owned="OWNED"
      record_finding "security-contact name=${name} (${owned})"
    done
  fi

  if ! az_run p_automation_rows_out rest --method get \
      --url "${ARM_BASE}/subscriptions/${SECURITY_SUBSCRIPTION_ID}/providers/Microsoft.Security/automations?api-version=${SECURITY_AUTOMATIONS_API_VERSION}" \
      --query "value[].name" -o tsv; then
    echo "::error::Microsoft.Security/automations list failed for the security subscription: ${AZ_RUN_STDERR}"
    fail=1
  else
    # shellcheck disable=SC2154  # p_automation_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_automation_names <<< "$p_automation_rows_out"
    for name in "${p_automation_names[@]:-}"; do
      [ -z "$name" ] && continue
      owned="unowned"
      is_globaris_owned "$name" && owned="OWNED"
      record_finding "security-automation name=${name} (${owned})"
    done
  fi
fi

# ---------------------------------------------------------------------------
# 5. AADDS (identity subscription): Microsoft.AAD/domainServices. REPORT ONLY - if present,
#    this is an IMPORT-not-delete signal for platform/identity's rerun (FIX-7 note,
#    teardown-az-sweep.sh) - no delete is ever attempted here or anywhere else in this fix.
# ---------------------------------------------------------------------------
echo "-- 5. Azure AD Domain Services (identity subscription) - REPORT ONLY, import-not-delete signal --"
if [ -z "${IDENTITY_SUBSCRIPTION_ID:-}" ]; then
  echo "::error::IDENTITY_SUBSCRIPTION_ID is empty - cannot check AADDS."
  fail=1
else
  if ! az_run p_aadds_rows_out rest --method get \
      --url "${ARM_BASE}/subscriptions/${IDENTITY_SUBSCRIPTION_ID}/providers/Microsoft.AAD/domainServices?api-version=${AADDS_DOMAINSERVICES_API_VERSION}" \
      --query "value[].[name, properties.replicaSets[0].replicaSetId]" -o tsv; then
    echo "::error::Microsoft.AAD/domainServices list failed for the identity subscription: ${AZ_RUN_STDERR}"
    fail=1
  else
    # shellcheck disable=SC2154  # p_aadds_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t p_aadds_rows <<< "$p_aadds_rows_out"
    if [ "${#p_aadds_rows[@]}" -eq 0 ] || { [ "${#p_aadds_rows[@]}" -eq 1 ] && [ -z "${p_aadds_rows[0]}" ]; }; then
      echo "  No AADDS managed domain present in the identity subscription."
    else
      for row in "${p_aadds_rows[@]:-}"; do
        [ -z "$row" ] && continue
        domain_name="$(printf '%s' "$row" | cut -f1)"
        replica_set_id="$(printf '%s' "$row" | cut -f2)"
        record_finding "AADDS domain=${domain_name} replicaSetId=${replica_set_id} - platform/identity rerun MUST import this via TF_VAR_aadds_import_replica_set_id (FIX-7 note, teardown-az-sweep.sh), never let Terraform attempt to create a new one."
      done
    fi
  fi
fi

echo "----------------------------------------------------------------"
echo "Total findings: ${#FINDINGS[@]}"
if [ "$fail" -ne 0 ]; then
  echo "::error::EXTENSION-DISCOVERY PROBE FAILED - one or more scopes could not be checked (see the errors above, and the tenant-AAD-diagnostic-settings named finding above which is a documented exception). The findings list above (if any) is still valid for the scopes that WERE checked, but the map is incomplete."
  exit 1
fi
echo "Extension-resource discovery probe complete - map above is authoritative for every scope checked."
exit 0
