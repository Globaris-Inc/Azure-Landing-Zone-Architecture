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
#
# AMENDED a fourth time 2026-07-23 (teardown-phase0-mg-sweep fix, follow-up to the
# teardown-completeness extension sweep): added the MG-scope extension-resource sweep at the
# end of this script (budgets, MG-scope diagnostic settings, policy exemptions). Root cause: the
# original placement of this sweep (teardown-az-sweep.sh Phase 2 step 4-pre, FIX-1) is too late
# on the mode=terraform path. Phase 1 terraform-destroys platform/management-groups LAST,
# deleting the globaris/platform/landingzones MGs; Phase 2 az-sweep `needs` every Phase 1 job so
# it only runs AFTER those MGs are already gone. Once an MG is deleted, mg_in_snapshot no longer
# lists it (skip) AND the scoped teardown SP's MG-scope grants die with the subtree (403
# AuthorizationFailed on any further read at that scope), so FIX-1's sweep never gets a chance to
# run for that MG on this path. Three live orphan budgets (budget-mg-globaris-globaris,
# budget-mg-platform-globaris, budget-mg-landingzones-globaris) were in no root's Terraform state
# either, so `terraform destroy` never removed them. This script runs FIRST, before any Phase 1
# destroy (`disarm` gates every Phase 1 root job via `needs: disarm`), with every MG in
# MG_SCOPES guaranteed still present - the correct home for this sweep on the mode=terraform
# path. Placed AFTER the policy-ASSIGNMENT disarm loop above (not interleaved with it) so no
# DINE policy assignment can re-remediate a budget/diagnostic-setting/exemption mid-sweep - the
# assignments must be gone first, the same belt-and-suspenders reasoning the whole phase exists
# for (see the file header comment). Reuses the SAME API-version constants and the SAME
# confirm_gone_or_fail_primary PRIMARY-evidence pattern teardown-az-sweep.sh's FIX-1 already
# established (teardown-common.sh), so the two sites can never drift on API version or scope
# math. teardown-az-sweep.sh's own FIX-1 copy is NOT removed by this change - it stays the
# load-bearing sweep for the mode=az-sweep path (Phase 1 skipped entirely there, so this script's
# sweep is the only one that runs before Phase 2's own remove_mg_hierarchy loop deletes the MGs
# in THAT mode too) and becomes a harmless remnant-catch no-op on the mode=terraform path (see
# that script's own comment at the FIX-1 site).
#
# AMENDED a fifth time 2026-07-30 (transient-list-failure fix round, teardown run 30597640251 -
# see teardown-common.sh's "AMENDED an eighth time" header note and teardown-az-sweep.sh's
# "AMENDED an eleventh time" for the full incident and mechanism). This script gates every
# Phase 1 destroy job (`needs: disarm`), so a single transient ARM 5xx/429 on any list call here
# used to kill the entire run before any real work started, with zero retry. Every LIST/GET call
# below that used `az_run` now uses `az_run_retry` (teardown-common.sh) instead - same signature,
# bounded retry (3 attempts, ~10s apart by default) ONLY for a transient 5xx/429 that is not also
# auth-shaped, never for a delete. The fail-loud rule this file already enforces (a dead token or
# a real permission gap must still abort DISARM) is unchanged.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

fail=0

# MG-existence snapshot (see the amendment comment at the top of this file) - ONE list call for
# the whole run, not a per-MG probe. A failure here is a genuine dead token / transport error
# (the single call the SP is always entitled to make) and DISARM cannot proceed without it.
#
# Moved to run FIRST (2026-07-23, ADR-063 decision 1b(iv) second re-ruling - see DECISIONS.md,
# same ADR): the pre-flight below is scoped PER MG and needs this snapshot's existence oracle to
# know which MGs to probe, exactly like the per-MG disarm loop below it already does.
if ! mg_snapshot_load; then
  echo "::error::DISARM cannot proceed without a trustworthy MG-existence snapshot."
  exit 1
fi

# --- ADR-063 decision 1b(iv): effective-permissions pre-flight, evaluated PER MG SCOPE.
#
#     SECOND RE-RULING 2026-07-23 - REPLACES BOTH PRIOR DESIGNS IN THIS FILE'S HISTORY, NEITHER OF
#     WHICH SURVIVED: (1) the original role-assignment-existence check at Tenant Root Group
#     (`az role assignment list --role "Cost Management Contributor"`) - asserted grant metadata
#     rather than capability, needed an `az ad sp show` Microsoft Graph call that
#     `bootstrap/identity.tf:39` explicitly says this SP does not need ("No API permissions
#     needed (all access is via ARM RBAC, not Graph)") and that only works via an undeclared,
#     out-of-band `Application.Read.All` consent, and would hard-fail the moment OQ-059(a)'s
#     recommended globaris-scoped grant lands even though the sweep would work perfectly. (2) this
#     file's OWN immediately-prior revision (a Consumption-plane READ probe,
#     `GET .../Microsoft.Consumption/budgets` at Tenant Root Group) - proven NON-DISCRIMINATING
#     against the LIVE tenant, not by argument: the CI SP holds a SECOND, previously undocumented
#     ADR-041 bridge grant, User Access Administrator AT TENANT ROOT (distinct from the
#     globaris-scoped UAA row `bootstrap/identity.tf` declares), whose global `*/read` authorises
#     `Microsoft.Consumption/budgets/read` at tenant root with NO Consumption grant present at
#     all. That probe returns 200 whether or not the Cost Management Contributor bridge grant it
#     exists to check is actually there - a gate that can only ever say GO, the same silent-pass
#     shape as decision 7's VERIFY 6e no-op. Full reasoning and the live evidence for both
#     rejections: DECISIONS.md, ADR-063 decision 1b (i)-(iv) - read there directly rather than
#     from this summary, so this comment cannot drift from the ruling it implements.
#
#     THE MECHANISM: `GET {scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01`
#     returns the CALLER's own effective `actions`/`notActions` at that scope - this tests
#     CAPABILITY (can this principal actually perform the delete this sweep needs), not grant
#     metadata, so a broad `*/read`-shaped role can never satisfy a test for a narrow `.../delete`
#     action the way it satisfied the rejected read-probe design above. Graph-free - pure ARM, no
#     object-id resolution, so `bootstrap/identity.tf:39`'s contract holds.
#
#     LIVE-VERIFIED AT MG SCOPE THIS SESSION (2026-07-23), because Microsoft's published reference
#     documents only "List For Resource" and "List For Resource Group" for this operation group at
#     2022-04-01 - no management-group URI template appears anywhere in it, so this could not be
#     cited and had to be proven empirically: `GET .../managementGroups/<tenant-root-id>/providers/
#     Microsoft.Authorization/permissions?api-version=2022-04-01` AND the identical call against
#     `.../managementGroups/globaris/...` both returned HTTP 200 with a `value[]` array of
#     `{actions,dataActions,notActions,notDataActions}` entries - the same response shape
#     documented for the resource/RG-scoped variants, at a scope Microsoft does not document at
#     all. Run as the authenticated human operator (the SP itself could not be reached from this
#     sandbox) - this verification confirms the endpoint ACCEPTS an MG scope and returns the
#     documented shape; the architect separately confirmed, as the actual CI principal, that none
#     of this SP's three tenant-root role assignments carries an ABAC condition and that scope has
#     zero deny assignments, which is what makes this probe a COMPLETE oracle in THIS estate
#     specifically (a deny assignment or a conditioned assignment would not show up here - see
#     DECISIONS.md 1b(iv) for that caveat, restated in the UNAVAILABLE branch below). Because the
#     scope is undocumented, decision 3d's convention applies with full force: a FAILED call below
#     is never read as an EMPTY permission set.
#
#     GLOB MATCHING: ARM action strings use `*` as a wildcard that can match any sequence of
#     characters, not just within one path segment - already proven live in this exact file's
#     revision history (`Microsoft.Authorization/*/read` matches
#     `Microsoft.Authorization/roleAssignments/read`; `Microsoft.Authorization/*` matches
#     `Microsoft.Authorization/policyExemptions/delete` too). Bash `case` pattern matching
#     implements exactly this semantic already (`*` matches any string, "/" included - `case` is
#     not pathname expansion and has no segment boundary) - `_p0pf_glob_match_any` below is a thin
#     wrapper, `_p0pf_granted` composes it into "matched by actions AND NOT revoked by
#     notActions", mirroring the "subtract anything matched by a notActions entry" instruction.
_p0pf_glob_match_any() {
  local test_str="$1" patterns="$2" pattern
  shopt -s nocasematch
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$test_str" in
      $pattern)
        shopt -u nocasematch
        return 0
        ;;
    esac
  done <<< "$patterns"
  shopt -u nocasematch
  return 1
}

_p0pf_granted() {
  local test_action="$1" actions_list="$2" not_actions_list="$3"
  if _p0pf_glob_match_any "$test_action" "$actions_list"; then
    if _p0pf_glob_match_any "$test_action" "$not_actions_list"; then
      return 1
    fi
    return 0
  fi
  return 1
}

# _is_authz_denied_design_gap "<error text>" - precise RBAC-denial discriminator used ONLY at the
# MG-scope diagnostic-setting DELETE failure branch further down (ADR-063 decision 1d /
# OQ-059(b)). Matches ONLY the literal ARM error code `AuthorizationFailed` and the two
# RBAC-denial phrases Microsoft's own RBAC troubleshooting reference shows verbatim
# (learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting, "Symptom - Unable
# to assign a role" / "Symptom - Authorization failed", fetched live 2026-07-23): "...does not
# have authorization or an ABAC condition not fulfilled to perform action '...' ... please
# refresh your credentials." and the short form "...(code: AuthorizationFailed)". Deliberately
# does NOT match bare `403` or bare `Forbidden` - that is what made the previous version of this
# check collide with `is_auth_error` (which matches bare `credential`/`401`/`403`), since Azure's
# own AuthorizationFailed message always ends with the "refresh your credentials" boilerplate.
# `AuthorizationFailed` is ARM's AUTHORIZATION-layer code, returned only for an authenticated
# principal that lacks the needed action at the target scope; a dead/expired token fails at the
# separate AUTHENTICATION layer (AAD/Entra token validation - AADSTS7xxxxx,
# ExpiredAuthenticationToken, "valid time range", "not within") BEFORE ARM ever evaluates
# authorization, so it structurally cannot produce this code or either phrase - the two shapes are
# mutually exclusive by Azure's own request pipeline, not just empirically distinct today. This is
# why checking this FIRST (ahead of the broad `is_auth_error`) at its one call site is safe and
# does not reopen the codebase's general auth-fail-loud rule: nothing a dead token can say matches
# this pattern. `is_auth_error` itself is untouched and keeps its normal broad role everywhere
# else, including as the SECOND check at that same call site. Mirrored verbatim (identical
# function body) at the equivalent site in teardown-az-sweep.sh so the two cannot drift - proven
# against realistic verbatim strings in a standalone harness before being wired in here (see the
# WORKLOG entry for this fix round).
_is_authz_denied_design_gap() {
  printf '%s' "${1:-}" | grep -qiE 'AuthorizationFailed|does not have authorization|ABAC condition'
}

# api-version pinned inline (2022-04-01, live-verified above) rather than promoted to
# teardown-common.sh - this pre-flight is the only caller in the codebase today, and
# teardown-common.sh is out of scope for this fix round (file ownership).
P0PF_PERMISSIONS_API_VERSION="2022-04-01"

echo "== Pre-flight: effective-permissions assertion, per MG scope (ADR-063 decision 1b(iv)) =="
p0pf_fail=0
for mg in "${MG_SCOPES[@]}"; do
  if ! mg_in_snapshot "$mg"; then
    echo "  MG ${mg}: gone (absent from the existing-MG snapshot) - nothing to assert at a nonexistent scope."
    continue
  fi
  p0pf_scope="$(mg_scope_path "$mg")"
  p0pf_url="${ARM_BASE}${p0pf_scope}/providers/Microsoft.Authorization/permissions?api-version=${P0PF_PERMISSIONS_API_VERSION}"

  # CLASSIFICATION, RE-DERIVED FOR THIS PROBE SHAPE (do not port the old probe's inverted
  # is_auth_error order across - the two designs fail differently). The rejected Consumption-read
  # probe used success/403 as its OWN pass/fail signal, so a genuine "grant absent" case had to
  # arrive as a 403 indistinguishable-by-crude-grep from a dead token, which is why that revision
  # deliberately checked a narrow dead-token signature BEFORE the broad is_auth_error. This probe
  # does not have that problem: "capability absent" is read from the DATA of a SUCCESSFUL (200)
  # call - it is never expressed as an error status at all, so there is no error-shaped case this
  # classification has to protect from being swallowed. The only failure mode left is the GET
  # itself not returning 200, and every cause of that (a dead token, the undocumented-MG-scope
  # surface misbehaving, or a genuine gap on `Microsoft.Authorization/permissions/read` itself)
  # gets the IDENTICAL disposition: abort, never read as "capability absent" (decision 3d/the spec
  # above are explicit that a failed call is not an empty permission set). Since the response does
  # not fork on the cause, there is nothing to invert here - `is_auth_error` is used in its normal,
  # unmodified, checked-first role purely to ENRICH the message (matching every other list-call
  # site in this file, e.g. the policy-assignment list below), not to decide the outcome.
  if ! az_run_retry p0pf_actions_out rest --method get --url "$p0pf_url" --query "value[].actions[]" -o tsv; then
    if is_auth_error "$AZ_RUN_STDERR"; then
      echo "::error::TEARDOWN-P0-PREFLIGHT-UNAVAILABLE: the effective-permissions read failed for MG ${mg} with an auth/transport error - cannot evaluate the pre-flight for this scope off a dead token. Not treated as capability absent: ${AZ_RUN_STDERR}"
    else
      echo "::error::TEARDOWN-P0-PREFLIGHT-UNAVAILABLE: the effective-permissions read failed for MG ${mg} with a non-auth error - possibly the undocumented MG-scope surface itself misbehaving. Not treated as capability absent: ${AZ_RUN_STDERR}"
    fi
    p0pf_fail=1
    continue
  fi
  if ! az_run_retry p0pf_notactions_out rest --method get --url "$p0pf_url" --query "value[].notActions[]" -o tsv; then
    if is_auth_error "$AZ_RUN_STDERR"; then
      echo "::error::TEARDOWN-P0-PREFLIGHT-UNAVAILABLE: the effective-permissions notActions read failed for MG ${mg} with an auth/transport error - cannot evaluate the pre-flight for this scope without it (a granted action can still be revoked by a notActions entry): ${AZ_RUN_STDERR}"
    else
      echo "::error::TEARDOWN-P0-PREFLIGHT-UNAVAILABLE: the effective-permissions notActions read failed for MG ${mg} with a non-auth error - cannot evaluate the pre-flight for this scope without it (a granted action can still be revoked by a notActions entry): ${AZ_RUN_STDERR}"
    fi
    p0pf_fail=1
    continue
  fi
  p0pf_actions="$p0pf_actions_out"
  p0pf_notactions="$p0pf_notactions_out"

  if _p0pf_granted "Microsoft.Consumption/budgets/delete" "$p0pf_actions" "$p0pf_notactions"; then
    echo "  MG ${mg}: Microsoft.Consumption/budgets/delete - granted."
  else
    echo "::error::Phase 0 pre-flight (ADR-063 decision 1b(iv)): Microsoft.Consumption/budgets/delete is NOT granted at MG ${mg}. This is the ADR-041 Cost Management Contributor bridge grant's own action (Tenant Root Group, applied out-of-band 2026-07-16) - none of this SP's bootstrap/identity.tf roles carry it. Absent means DO NOT DISPATCH: the MG-scope budget sweep below would 403 partway through instead of failing here, before any resource deletion. Grant the role (or land the durable bootstrap/identity.tf replacement tracked as OQ-059(a)) and re-dispatch."
    p0pf_fail=1
  fi

  if _p0pf_granted "Microsoft.Authorization/policyExemptions/delete" "$p0pf_actions" "$p0pf_notactions"; then
    echo "  MG ${mg}: Microsoft.Authorization/policyExemptions/delete - granted."
  else
    echo "::error::Phase 0 pre-flight (ADR-063 decision 1b(iv)): Microsoft.Authorization/policyExemptions/delete is NOT granted at MG ${mg}. This should ALWAYS be present, via two independent standing bootstrap rows at globaris (User Access Administrator's Microsoft.Authorization/* and Resource Policy Contributor's Microsoft.Authorization/policyexemptions/*, both inherited at every MG in MG_SCOPES). Absent means something changed that nobody recorded - do not dispatch until this is understood."
    p0pf_fail=1
  fi

  if _p0pf_granted "Microsoft.Insights/diagnosticSettings/delete" "$p0pf_actions" "$p0pf_notactions"; then
    echo "  MG ${mg}: Microsoft.Insights/diagnosticSettings/delete - granted (unexpected - the estate declares no MG-scope diagnostic setting; if one exists live, the Phase 0 sweep below will actually be able to remove it)."
  else
    echo "  ::warning::Phase 0 pre-flight (ADR-063 decision 1b(iv)): Microsoft.Insights/diagnosticSettings/delete is NOT granted at MG ${mg}. This is the KNOWN DESIGN GAP (OQ-059(b)), WARN only, never fatal - do not misread this as the auth-fail-loud dead-token signal. The estate declares no MG-scope diagnostic setting today, so this is expected; if one is ever created live, the Phase 0 sweep's own delete will 403 and is separately labelled a KNOWN DESIGN GAP there."
  fi
done

if [ "$p0pf_fail" -ne 0 ]; then
  echo "::error::Phase 0 pre-flight (ADR-063 decision 1b(iv)) failed for one or more MG scopes - see the ::error:: lines above. Aborting BEFORE the policy-assignment disarm loop and before any resource deletion. This is additive to, not a substitute for, decision 4's fatal MG-scope delete gate later in this run."
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
  if az_run_retry identity_rows_out policy assignment list --scope "$scope" \
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
    if az_run_retry role_ids_out role assignment list --scope "$scope" --assignee-object-id "$principal_id" \
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
  if az_run_retry assignment_names_out policy assignment list --scope "$scope" \
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

# --- ADR-063 decision 3: the Phase-0 MG-scope extension sweep. Sweeps 3 classes across every
#     MG still present in MG_SCOPES (NOT MG_DELETE_ORDER - decision 3 is explicit that these are
#     independent extension-resource sweeps with no delete ordering to respect, unlike the step 4
#     MG DELETE loop in teardown-az-sweep.sh, which still needs MG_DELETE_ORDER's bottom-up
#     ordering) - consumption budgets, MG-scope diagnostic settings, and policy exemptions.
#     Placed here, AFTER the per-MG policy-assignment disarm loop above (not interleaved with
#     it) so no DINE assignment can re-remediate a budget/diagnostic-setting/exemption mid-sweep
#     - see the amendment header comment at the top of this file for the full root-cause account
#     of why Phase 0 is the only placement that is both reachable and authorised in BOTH
#     teardown modes.
#
#     G-1 (ADR-063): an extension object must be swept BEFORE its host scope is deleted or
#     submitted for deletion. Deleting the host first does not delete the extension object - it
#     makes it invisible (403, not 404, for this scoped SP once the MG-scope grants die with the
#     subtree), unreachable and resurrectable the next time an MG of the same name is recreated.
#     Phase 0 runs before Phase 1/2 touch anything, with every MG still present and every grant
#     still bound - the only point in the whole mechanism where this sweep is both reachable and
#     authorised.
#
#     Ownership: every object found at any MG in MG_SCOPES is owned by T1(a) containment
#     (is_estate_owned --mg, teardown-common.sh, ADR-063 decision 6) - the MG itself is fully
#     estate-owned (MG_SCOPES IS the definition of "this estate's MG tree"), so anything living
#     on it is owned regardless of its own name. No server-side JMESPath ownership filter and no
#     per-row name check (decision 3c) - list every row, delete every row found.
#
#     A non-auth delete failure here is FATAL (ADR-063 decision 4) - unlike everywhere else in
#     this sweep, "the next run retries idempotently" does not hold at MG scope, because THIS
#     SAME RUN may go on to delete the scope that makes the retry possible. Accumulated via
#     fail=1 (not an immediate exit) so every failing MG/class is reported in one run, matching
#     this file's own established idiom above - the final roll-up below still turns any fail=1
#     into a non-zero exit, which is what stops Phase 1 (gated on needs.disarm.result ==
#     'success').
echo "== Phase 0 MG-scope extension sweep: consumption budgets, diagnostic settings, policy exemptions (ADR-063 decision 3) =="
for mg in "${MG_SCOPES[@]}"; do
  if ! mg_in_snapshot "$mg"; then
    echo "  MG ${mg}: gone (absent from the snapshot) - nothing to sweep at a nonexistent scope."
    continue
  fi
  if ! is_estate_owned --mg "$mg"; then
    # Structurally unreachable (mg was drawn from MG_SCOPES itself) - kept as a hard stop rather
    # than a silent skip in case MG_SCOPES and is_mg_owned are ever edited out of lock-step.
    echo "::error::Phase 0 MG-scope sweep: MG ${mg} did not classify as estate-owned by is_estate_owned - this should be structurally impossible for any member of MG_SCOPES. Failing loud rather than silently skipping."
    fail=1
    continue
  fi
  mg_scope="$(mg_scope_path "$mg")"
  echo "  == MG ${mg} =="

  # Consumption budgets (Microsoft.Consumption/budgets, BUDGETS_API_VERSION). Rule 3a: the
  # delete URL is built from mg_scope + name, NEVER from a returned "id" field - Microsoft's own
  # Budgets List sample returns "id": "subscriptions/.../budgets/TestBudget" with NO leading
  # slash, so ${ARM_BASE}${id} would silently mis-form the URL.
  if ! az_run_retry p0_budget_names_out rest --method get \
      --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}" \
      --query "value[].name" -o tsv; then
    echo "::error::Phase 0: MG-scope budget list failed for MG ${mg} - a failed list is never read as 'no budgets': ${AZ_RUN_STDERR}"
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # p0_budget_names_out is assigned indirectly by az_run's printf -v
  mapfile -t p0_budget_names <<< "$p0_budget_names_out"
  for name in "${p0_budget_names[@]:-}"; do
    [ -z "$name" ] && continue
    echo "    Deleting MG-scope budget ${name}"
    p0_budget_url="${ARM_BASE}${mg_scope}/providers/Microsoft.Consumption/budgets/${name}?api-version=${BUDGETS_API_VERSION}"
    if ! p0_budget_del_out="$(az rest --method delete --url "$p0_budget_url" --output none 2>&1)"; then
      echo "::error::Phase 0: MG-scope budget delete for ${name} (MG ${mg}) failed: ${p0_budget_del_out}"
      fail=1
      continue
    fi
    confirm_gone_or_fail_primary "Phase 0 MG-scope budget ${name} (MG ${mg})" "$p0_budget_url" || fail=1
  done

  # MG-scope diagnostic settings (management-GROUP diagnostic settings op group, DISTINCT from
  # the generic resource op group - MG_DIAGNOSTIC_SETTINGS_API_VERSION, teardown-common.sh).
  # ADR-063 decision 1d: this SP holds no role that carries
  # Microsoft.Insights/diagnosticSettings/delete at MG scope (only the LIST, via User Access
  # Administrator's */read) - the estate declares none today (grep-confirmed across every root),
  # so this is expected to be a no-op. If it ever fires, the DELETE 403 below is labelled a KNOWN
  # DESIGN GAP (OQ-059(b)), never the generic auth-fail-loud dead-token signal - do not misread
  # it as an expired credential.
  #
  # AMENDED AGAIN 2026-07-23 (code-review BLOCK, second pass on Finding #2 - the first pass's
  # fix was itself defective and is superseded below). The first pass made the delete-failure
  # branch check `is_auth_error` FIRST, before the narrower 403/Forbidden/AuthorizationFailed
  # design-gap grep, reasoning that this matched the codebase-wide rule (teardown-common.sh line
  # 667). That reasoning was wrong for THIS branch specifically: `is_auth_error` matches on bare
  # `credential` and bare `403` (deliberately broad, by design, and NOT loosened here), and
  # Azure's own genuine `AuthorizationFailed` RBAC-denial text - the EXACT OQ-059(b) case this
  # branch exists to label - contains both. Verified live against Microsoft's RBAC troubleshooting
  # reference (learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting,
  # "Symptom - Unable to assign a role" / "Symptom - Authorization failed" sections, fetched
  # 2026-07-23): the documented error body reads "...does not have authorization or an ABAC
  # condition not fulfilled to perform action '...' over scope '...' or the scope is invalid. If
  # access was recently granted, please refresh your credentials." and the short form is
  # "...(code: AuthorizationFailed)". So `is_auth_error` matched FIRST on every real occurrence of
  # the design gap, and the design-gap `elif` was dead code for the one input it was written to
  # handle - an operator hitting the actual OQ-059(b) gap got pointed at re-authentication instead
  # of the real remediation (a Monitoring Contributor grant or a privileged one-off delete).
  # Simply reordering back to grep-first would re-open the ORIGINAL first-review finding (a dead
  # token whose text happens to contain bare `403`/`Forbidden` gets mislabelled "KNOWN DESIGN
  # GAP"), because the old grep pattern (`403|Forbidden|AuthorizationFailed`) is itself too broad -
  # it is not the ordering that was wrong, it is that both candidate patterns overlapped on bare
  # `403`.
  #
  # THE FIX: a precise, narrow design-gap discriminator, `_is_authz_denied_design_gap`, matching
  # ONLY the literal ARM error code `AuthorizationFailed` and the two RBAC-denial phrases Azure's
  # own docs show verbatim (`does not have authorization`, `ABAC condition`) - deliberately
  # DROPPING bare `403` and bare `Forbidden` from the pattern, which is what made it collide with
  # a dead token. `AuthorizationFailed` is ARM's authorization-layer error code, returned only for
  # an authenticated principal that lacks the needed action at the target scope; a dead or expired
  # token fails at the AUTHENTICATION layer (AAD/Entra token validation - AADSTS7xxxxx,
  # ExpiredAuthenticationToken, "valid time range", "not within") BEFORE ARM ever evaluates
  # authorization, so it can never produce an `AuthorizationFailed` code or either RBAC-denial
  # phrase - the two shapes are structurally mutually exclusive by Azure's own layering, not just
  # empirically distinct today. Because the new pattern cannot match a dead token, checking it
  # FIRST is safe: it no longer needs `is_auth_error`'s broad net to protect it, and it correctly
  # intercepts the design-gap case before the broad pattern would otherwise swallow it.
  # `is_auth_error` remains checked next (its normal, unmodified, broad role - NOT loosened) to
  # catch genuine dead-token/transport failures; a final else covers anything matching neither
  # shape, so no failure is silently unclassified. Standalone harness proved both directions
  # against verbatim strings before this was wired in (see the WORKLOG entry for this fix round).
  # Mirrored at the identical site in teardown-az-sweep.sh (step 4-pre) with the SAME function
  # body (defined near the top of THIS file, alongside the 1b(iv) pre-flight helpers) so the two
  # cannot drift.
  if ! az_run_retry p0_diag_names_out rest --method get \
      --url "${ARM_BASE}${mg_scope}/providers/microsoft.insights/diagnosticSettings?api-version=${MG_DIAGNOSTIC_SETTINGS_API_VERSION}" \
      --query "value[].name" -o tsv; then
    echo "::error::Phase 0: MG-scope diagnostic-settings list failed for MG ${mg} - a failed list is never read as 'no diagnostic settings': ${AZ_RUN_STDERR}"
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # p0_diag_names_out is assigned indirectly by az_run's printf -v
  mapfile -t p0_diag_names <<< "$p0_diag_names_out"
  for name in "${p0_diag_names[@]:-}"; do
    [ -z "$name" ] && continue
    echo "    Deleting MG-scope diagnostic setting ${name}"
    p0_diag_url="${ARM_BASE}${mg_scope}/providers/microsoft.insights/diagnosticSettings/${name}?api-version=${MG_DIAGNOSTIC_SETTINGS_API_VERSION}"
    if ! p0_diag_del_out="$(az rest --method delete --url "$p0_diag_url" --output none 2>&1)"; then
      if _is_authz_denied_design_gap "$p0_diag_del_out"; then
        echo "::error::Phase 0: MG-scope diagnostic setting delete for ${name} (MG ${mg}) returned an RBAC-denial (AuthorizationFailed) - this is a KNOWN DESIGN GAP (OQ-059(b)): no role held by this OIDC SP carries Microsoft.Insights/diagnosticSettings/delete at MG scope (User Access Administrator's */read covers the LIST above, not this DELETE). This is NOT the generic auth-fail-loud dead-token signal - do not read it as an expired credential. The estate declares no MG-scope diagnostic setting today; if this fired, one now exists live and must be removed by a privileged one-off action, or OQ-059(b) option B (a Monitoring Contributor grant) must land, before this MG can be safely deleted (ADR-063 G-1): ${p0_diag_del_out}"
      elif is_auth_error "$p0_diag_del_out"; then
        echo "::error::Phase 0: MG-scope diagnostic setting delete for ${name} (MG ${mg}) failed with an auth/transport error - cannot certify this as the KNOWN DESIGN GAP (OQ-059(b)) off a possibly-dead token: ${p0_diag_del_out}"
      else
        echo "::error::Phase 0: MG-scope diagnostic setting delete for ${name} (MG ${mg}) failed: ${p0_diag_del_out}"
      fi
      fail=1
      continue
    fi
    confirm_gone_or_fail_primary "Phase 0 MG-scope diagnostic setting ${name} (MG ${mg})" "$p0_diag_url" || fail=1
  done

  # Policy exemptions (atExactScope, POLICY_EXEMPTIONS_API_VERSION_NEW). Rule 3b: the filter is
  # only live-verified at SUBSCRIPTION scope (ADR-062 6d) - additionally verify client-side that
  # every returned id actually starts with this MG's own scope path, removing any dependence on
  # an unverified MG-scope atExactScope() semantic.
  if ! az_run_retry p0_exemption_rows_out rest --method get \
      --url "${ARM_BASE}${mg_scope}/providers/Microsoft.Authorization/policyExemptions?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}&\$filter=atExactScope()" \
      --query "value[].[name, id]" -o tsv; then
    echo "::error::Phase 0: MG-scope policy exemption list failed for MG ${mg} - a failed list is never read as 'no exemptions': ${AZ_RUN_STDERR}"
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # p0_exemption_rows_out is assigned indirectly by az_run's printf -v
  mapfile -t p0_exemption_rows <<< "$p0_exemption_rows_out"
  for row in "${p0_exemption_rows[@]:-}"; do
    [ -z "$row" ] && continue
    p0_ex_name="$(printf '%s' "$row" | cut -f1)"
    p0_ex_id="$(printf '%s' "$row" | cut -f2)"
    case "$p0_ex_id" in
      "${mg_scope}"/*) ;;
      *)
        echo "::error::Phase 0: MG-scope policy exemption ${p0_ex_name} (MG ${mg}) returned by atExactScope() but its id '${p0_ex_id}' does not start with this MG's own scope path '${mg_scope}' - the atExactScope() filter's MG-scope semantic is unverified (ADR-063 rule 3b) and this row failed the client-side belt check. Not deleting off an unverified scope match."
        fail=1
        continue
        ;;
    esac
    echo "    Deleting MG-scope policy exemption ${p0_ex_name}"
    p0_exemption_url="${ARM_BASE}${mg_scope}/providers/Microsoft.Authorization/policyExemptions/${p0_ex_name}?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}"
    if ! p0_exemption_del_out="$(az rest --method delete --url "$p0_exemption_url" --output none 2>&1)"; then
      echo "::error::Phase 0: MG-scope policy exemption delete for ${p0_ex_name} (MG ${mg}) failed: ${p0_exemption_del_out}"
      fail=1
      continue
    fi
    confirm_gone_or_fail_primary "Phase 0 MG-scope policy exemption ${p0_ex_name} (MG ${mg})" "$p0_exemption_url" || fail=1
  done
done

if [ "$fail" -ne 0 ]; then
  echo "::error::DISARM finished with one or more real (non-idempotent) delete failures, or an auth/transport error that means a scope could not be certified disarmed - Phase 1 destroy will NOT proceed (phase-1 root jobs require disarm success). Phase 2/3 still run and will report the remaining assignments as remnants."
  exit 1
fi

echo "DISARM complete - all MG-scope policy assignments cleared."
exit 0
