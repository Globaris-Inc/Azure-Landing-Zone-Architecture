# scripts/teardown-common.sh - shared constants for the 4-phase teardown (ADR-054).
# Sourced by teardown-disarm.sh, teardown-az-sweep.sh, teardown-verify.sh so the MG scope
# list and the RG naming-pattern match are defined ONCE. Drift between what DISARM clears
# and what VERIFY checks would silently defeat the loud-failure guarantee (design principle
# 5, docs/teardown-redesign.md). Not a standalone script (no shebang execution expected,
# no `set -e` here so it does not change the sourcing script's shell options) - `source` it.
#
# AMENDED 2026-07-20 (ADR-054 amendment, docs/teardown-redesign.md sections 9-10): added the
# token-durability primitives (`az_relogin`, `is_auth_error`, `wait_for_rgs_gone`) used by
# teardown-az-sweep.sh's --no-wait submission pass + bounded reconcile loop, and by the
# auth-fail-loud hardening in teardown-verify.sh. See each function's own comment for the
# locked mechanism it implements.

# The full globaris MG tree: root + all descendants (docs/teardown-redesign.md section 3):
# globaris -> platform -> {connectivity, security, identity, management};
# globaris -> landingzones -> {online, corp}; globaris -> {decommissioned, sandbox}.
# Hardcoded to this hierarchy rather than walked dynamically, so DISARM still runs even if
# `az account management-group list` itself is degraded mid-incident. If the tree is ever
# restructured (an MG added/removed/re-parented under globaris), this list and
# MG_DELETE_ORDER below must be updated together - drift here would leave a scope unswept.
MG_SCOPES=(globaris platform landingzones decommissioned sandbox connectivity identity management security corp online)

# Bottom-up delete order for remove_mg_hierarchy: every leaf before its parent, parents
# before globaris. Matches the live tree above (children listed before platform and
# landingzones; platform/landingzones/decommissioned/sandbox listed before globaris).
MG_DELETE_ORDER=(connectivity security identity management online corp decommissioned sandbox platform landingzones globaris)

# RG naming-pattern match. Every workload/platform RG in this estate is named
# "rg-<workload>-${var.org_prefix}-${var.environment}" (org_prefix=globaris, confirmed
# against platform/*/main.tf and landing-zones/*/main.tf), so "contains globaris" is a
# single catch-all that needs no per-root maintenance as new roots are added (avoids the
# maintenance-coupling downside ADR-054 calls out for an explicit rg-bank-*/rg-corp-*/...
# prefix list). rg-amba-monitoring-001 is the one fixed-name exception (defined directly in
# platform/management-groups and platform/management, not suffixed with org_prefix), so it
# is matched separately by substring rather than relying on the org_prefix suffix.
RG_SWEEP_QUERY="[?contains(name,'globaris') || contains(name,'amba-monitoring')].name"

# The 5 workload/platform subscriptions the estate spans (bootstrap identity.tf /
# _tf-root.yml TF_VAR_*_subscription_id secrets). All landing-zones/* roots share the single
# landingzones subscription (see any landing-zones/*/providers.tf). Populated from env vars
# the calling job must export from GitHub Secrets - never hardcoded here (no GUIDs in
# source, per DevSecOps secrets-hygiene rules).
teardown_subscriptions() {
  local subs=()
  [ -n "${MANAGEMENT_SUBSCRIPTION_ID:-}" ]   && subs+=("$MANAGEMENT_SUBSCRIPTION_ID")
  [ -n "${CONNECTIVITY_SUBSCRIPTION_ID:-}" ] && subs+=("$CONNECTIVITY_SUBSCRIPTION_ID")
  [ -n "${IDENTITY_SUBSCRIPTION_ID:-}" ]     && subs+=("$IDENTITY_SUBSCRIPTION_ID")
  [ -n "${SECURITY_SUBSCRIPTION_ID:-}" ]     && subs+=("$SECURITY_SUBSCRIPTION_ID")
  [ -n "${LANDINGZONES_SUBSCRIPTION_ID:-}" ] && subs+=("$LANDINGZONES_SUBSCRIPTION_ID")
  printf '%s\n' "${subs[@]}"
}

# is_auth_error "<text>" - classify captured az/curl stderr (or any error text) as an
# auth/token/transport failure, case-insensitive (docs/teardown-redesign.md section 9.4 /
# ADR-054 amendment point 9). Matches AADSTS / "valid time range" / "not within" /
# AuthenticationFailed / ExpiredAuthenticationToken / token / credential / 401 / 403 /
# "az login". Returns 0 (true - IS an auth error) on a match, 1 (false) otherwise. A caller
# must treat a match as FAIL LOUD - never as "resource absent / already gone / nothing to do".
# Deliberately broad ("token" / "credential" alone match) per the locked design - a caller
# distinguishes a genuine NotFound from everything else itself; this classifier only answers
# "is this specific failure text auth-shaped".
is_auth_error() {
  local text="${1:-}"
  printf '%s' "$text" | grep -qiE 'AADSTS|valid time range|not within|AuthenticationFailed|ExpiredAuthenticationToken|token|credential|401|403|az login'
}

# az_run <out_var> <az subcommand args...> - run `az <args>`, capturing STDOUT ONLY into the
# named variable and STDERR into the global AZ_RUN_STDERR. Returns az's own exit code
# unmolested.
#
# Locked reason this exists (code-review BLOCK, Finding #2, 2026-07-20): the az CLI writes
# WARNING banners to stderr even on a clean exit-0 call (update-available nags, "this command
# is from the following extension: databricks/account" advisories). Merging stdout+stderr with
# `2>&1` into a variable that then feeds `mapfile` or a scalar comparison can inject a bogus
# row into an otherwise-successful list result - a false VERIFY failure on a genuinely clean
# scope, or a bogus RG/KV "name" pushed through a delete and the 30-min reconcile wait. This
# helper is the ONLY sanctioned way in this codebase to capture az list/show output destined
# for mapfile or a scalar compare - stderr is only ever inspected (via AZ_RUN_STDERR and
# is_auth_error) on the non-zero-exit-code path, never mixed into the data channel.
AZ_RUN_STDERR=""
az_run() {
  local __az_run_outvar="$1"
  shift
  local __az_run_err_file __az_run_rc __az_run_out
  __az_run_err_file="$(mktemp)"
  __az_run_out="$(az "$@" 2>"$__az_run_err_file")"
  __az_run_rc=$?
  AZ_RUN_STDERR="$(cat "$__az_run_err_file")"
  rm -f "$__az_run_err_file"
  printf -v "$__az_run_outvar" '%s' "$__az_run_out"
  return "$__az_run_rc"
}

# az_relogin - mint a FRESH GitHub OIDC federated assertion on demand and re-authenticate the
# az CLI with it (docs/teardown-redesign.md section 9.2b / ADR-054 amendment point 7b).
#
# Why this exists: the `azure/login` step at job start consumes GitHub's federated assertion,
# which is only valid inside GitHub's own ~5-minute issuance window. Once consumed, az's own
# token-refresh has no live assertion left to refresh with, so any operation that outlives the
# resulting ~1h Azure access token dies with AADSTS700024. GitHub will happily issue a BRAND
# NEW assertion on request for the entire lifetime of the job, so this helper requests one and
# logs in again rather than ever leaning on az's structurally-broken refresh.
#
# Requires (never hardcoded - sourced from the job environment):
#   $ACTIONS_ID_TOKEN_REQUEST_URL, $ACTIONS_ID_TOKEN_REQUEST_TOKEN (auto-present because the
#     workflow already sets `permissions: id-token: write` - do NOT hardcode these).
#   $AZURE_CLIENT_ID, $AZURE_TENANT_ID, $AZURE_SUBSCRIPTION_ID (exported by the workflow step
#     from the repo Variables, per DevSecOps secrets-hygiene: identity via Variables, never a
#     client secret).
#
# The audience "api://AzureADTokenExchange" is sent URL-encoded (api%3A%2F%2FAzureADTokenExchange)
# matching the GitHub Actions toolkit's own OidcClient.getIDToken (encodeURIComponent(audience)),
# confirmed against actions/toolkit's packages/core/src/oidc-utils.ts. The az login form
# (`--service-principal --username <id> --tenant <tenant> --federated-token <token>` then a
# separate `az account set --subscription <id>`) matches Azure/login's own
# src/Cli/AzureCliLogin.ts implementation, confirmed against the upstream source.
#
# On ANY failure (missing env, no id-token in the response, az login non-zero, az account set
# non-zero) this prints ::error:: and returns non-zero. Callers MUST treat a failed re-login as
# FAIL LOUD and never continue past it (locked decision 9.2b) - never retried silently here.
az_relogin() {
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    echo "::error::az_relogin: ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN not set - the job is missing 'permissions: id-token: write'. Cannot mint a fresh OIDC assertion."
    return 1
  fi
  if [ -z "${AZURE_CLIENT_ID:-}" ] || [ -z "${AZURE_TENANT_ID:-}" ] || [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    echo "::error::az_relogin: AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID not set in the environment - cannot re-authenticate."
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "::error::az_relogin: curl and jq are both required to mint a fresh OIDC assertion (ubuntu-latest ships both by default)."
    return 1
  fi

  local id_token_response id_token
  id_token_response="$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api%3A%2F%2FAzureADTokenExchange")"
  if [ -z "$id_token_response" ]; then
    echo "::error::az_relogin: empty response from the GitHub OIDC token endpoint."
    return 1
  fi
  id_token="$(printf '%s' "$id_token_response" | jq -r '.value // empty' 2>/dev/null)"
  if [ -z "$id_token" ]; then
    echo "::error::az_relogin: GitHub returned no id-token value (response: ${id_token_response})."
    return 1
  fi

  local login_err
  if ! login_err="$(az login --service-principal --username "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" \
      --federated-token "$id_token" --output none 2>&1)"; then
    echo "::error::az_relogin: az login with the fresh federated assertion failed: ${login_err}"
    return 1
  fi
  if ! login_err="$(az account set --subscription "$AZURE_SUBSCRIPTION_ID" --output none 2>&1)"; then
    echo "::error::az_relogin: az account set --subscription failed after login: ${login_err}"
    return 1
  fi
  return 0
}

# wait_for_rgs_gone - bounded reconciliation wait for a set of (sub, rg) pairs to report gone
# (docs/teardown-redesign.md section 9.3 / ADR-054 amendment point 8). The WAIT lives here, in
# Phase 2 - Phase 3 VERIFY stays an instant, unwaited truth-gate (never put a wait inside the
# auditor). Calls `az_relogin` at the START of every iteration (locked decision 9.2c) so a poll
# can never outlive the token that started it, no matter how long the wait runs. Ceiling is 30
# minutes (1800s), well under the 360-min job ceiling.
#
# Args: alternating "<sub> <rg>" pairs, e.g. wait_for_rgs_gone "$sub1" "$rg1" "$sub2" "$rg2" ...
# Return codes (NEVER a silent success):
#   0 = every pair confirmed gone.
#   1 = the ceiling was reached with pair(s) still present (a plain still-deleting straggler,
#       not an auth problem) - advisory; Phase 3 VERIFY is the authoritative completion gate
#       and an idempotent operator re-dispatch is the documented safety net.
#   2 = a re-login failed OR an existence check came back auth-classified mid-wait - this is
#       the section-9.4 "auth error must fail loud" case, distinct from a slow delete. Callers
#       MUST treat a 2 as a hard failure of the calling script (docs/teardown-redesign.md
#       section 10.2: "any auth-classified failure at any step is a hard non-zero exit"), not
#       just a Phase-3-will-catch-it warning.
wait_for_rgs_gone() {
  local ceiling=1800 interval=20 waited=0
  local -a subs=() rgs=()
  while [ "$#" -gt 0 ]; do
    subs+=("$1")
    rgs+=("$2")
    shift 2
  done
  if [ "${#rgs[@]}" -eq 0 ]; then
    echo "  wait_for_rgs_gone: nothing to wait on."
    return 0
  fi

  while [ "$waited" -lt "$ceiling" ]; do
    if ! az_relogin; then
      echo "::error::wait_for_rgs_gone: az_relogin failed mid-wait - hard failure, not a plain timeout."
      return 2
    fi

    local -a still_subs=() still_rgs=()
    local i exists exists_rc
    for i in "${!rgs[@]}"; do
      # az_run is called DIRECTLY here (never inside a `$(...)` subshell) - az_run's
      # AZ_RUN_STDERR global side effect would otherwise be lost the instant a subshell exits.
      # A stderr WARNING banner on an otherwise-clean call must never corrupt the "true"/"false"
      # data channel this comparison relies on.
      az_run exists group exists --name "${rgs[$i]}" --subscription "${subs[$i]}"
      exists_rc=$?
      if [ "$exists_rc" -eq 0 ] && [ "$exists" = "true" ]; then
        still_subs+=("${subs[$i]}")
        still_rgs+=("${rgs[$i]}")
      elif [ "$exists_rc" -eq 0 ] && [ "$exists" = "false" ]; then
        : # gone - not re-added to still_subs/still_rgs
      else
        # Non-zero exit, or an unexpected (non-true/false) stdout value. Classify the failure
        # (section 9.4) instead of silently assuming the RG is gone.
        if is_auth_error "$AZ_RUN_STDERR"; then
          echo "::error::wait_for_rgs_gone: auth/transport error checking ${rgs[$i]} in ${subs[$i]}: ${AZ_RUN_STDERR}"
          return 2
        fi
        echo "  ::warning::wait_for_rgs_gone: could not confirm state of ${rgs[$i]} (rc=${exists_rc}, stdout='${exists}', stderr: ${AZ_RUN_STDERR}) - treating as still pending."
        still_subs+=("${subs[$i]}")
        still_rgs+=("${rgs[$i]}")
      fi
    done

    if [ "${#still_rgs[@]}" -eq 0 ]; then
      echo "  wait_for_rgs_gone: all RG(s) confirmed gone (waited ${waited}s)."
      return 0
    fi
    subs=("${still_subs[@]}")
    rgs=("${still_rgs[@]}")
    echo "  wait_for_rgs_gone: ${#rgs[@]} RG(s) still present after ${waited}s (${rgs[*]}) - sleeping ${interval}s."
    sleep "$interval"
    waited=$((waited + interval))
  done

  echo "::warning::wait_for_rgs_gone: ${#rgs[@]} RG(s) still present after the ${ceiling}s ceiling (${rgs[*]}) - Phase 3 VERIFY will report these as remnants; re-dispatch (idempotent) is the safety net for this straggler."
  return 1
}
