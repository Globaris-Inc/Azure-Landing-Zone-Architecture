#!/usr/bin/env bash
# 03-trigger-incidents.sh — manually fire the synthetic CAJs that drive
#                            Defender + Sentinel + Advisor signals.
# Section 13.5.
#
# Usage:
#   ./03-trigger-incidents.sh             # fire one job from each group + print pivots
#   ./03-trigger-incidents.sh load        # only §13.2 k6 scenarios
#   ./03-trigger-incidents.sh red-team    # only §13.3 red-team scenarios
#   ./03-trigger-incidents.sh all         # every scenario
#   ./03-trigger-incidents.sh list        # list available CAJs, exit
#   ./03-trigger-incidents.sh <scenario>  # specific scenario by name
#
# Detection windows are estimates — Defender/Sentinel rules typically take
# 5–15 minutes after the source event lands in LAW.

set -euo pipefail

ORG_PREFIX="${ORG_PREFIX:-globaris}"
ENVIRONMENT="${ENVIRONMENT:-poc}"
CORP_A1_SYNTHETIC_RG="rg-synthetic-corp-a1-${ORG_PREFIX}-${ENVIRONMENT}"
RED_TEAM_PRIMARY_RG="rg-synthetic-red-team-${ORG_PREFIX}-${ENVIRONMENT}"
RED_TEAM_SECONDARY_RG="rg-synthetic-red-team-${ORG_PREFIX}-${ENVIRONMENT}-secondary"

# ---------------------------------------------------------------------------
# Scenario catalogue — name → (resource_group, job_name, group, detection_hint)
# ---------------------------------------------------------------------------

declare -A SCENARIOS_RG SCENARIOS_JOB SCENARIOS_GROUP SCENARIOS_HINT

register() {
  local key=$1 rg=$2 job=$3 group=$4 hint=$5
  SCENARIOS_RG[$key]=$rg
  SCENARIOS_JOB[$key]=$job
  SCENARIOS_GROUP[$key]=$group
  SCENARIOS_HINT[$key]=$hint
}

# §13.2 k6 load — all hosted on the same RG
register k6-baseline       "$CORP_A1_SYNTHETIC_RG" "caj-k6-baseline-${ORG_PREFIX}-${ENVIRONMENT}"  load     "App Service request volume baseline — Application Insights pickup ~2 min"
register k6-spike          "$CORP_A1_SYNTHETIC_RG" "caj-k6-spike-${ORG_PREFIX}-${ENVIRONMENT}"     load     "App Service scale-out + Defender 'sustained-volume' recommendation"
register k6-anomalous      "$CORP_A1_SYNTHETIC_RG" "caj-k6-anomalous-${ORG_PREFIX}-${ENVIRONMENT}" load     "60% failed-login bursts + non-approved-geo header → §6 brute-force rule"

# §13.3 red-team — primary CAE for all but impossible-travel-west
register failed-signin     "$RED_TEAM_PRIMARY_RG"   "caj-rt-failed-signin-burst-${ORG_PREFIX}-${ENVIRONMENT}"      red-team "12× ROPC failures → Entra SignInLogs → §6 brute-force rule (5–10 min)"
register impossible-east   "$RED_TEAM_PRIMARY_RG"   "caj-rt-impossible-travel-east-${ORG_PREFIX}-${ENVIRONMENT}"   red-team "east pole — pair with impossible-west within 30 min"
register impossible-west   "$RED_TEAM_SECONDARY_RG" "caj-rt-impossible-travel-west-${ORG_PREFIX}-${ENVIRONMENT}"   red-team "west pole (${RED_TEAM_SECONDARY_RG#rg-synthetic-red-team-}) — fires the impossible-travel rule"
register resource-anomaly  "$RED_TEAM_PRIMARY_RG"   "caj-rt-resource-anomaly-${ORG_PREFIX}-${ENVIRONMENT}"         red-team "public IP create+delete → AzureActivity → §6 mass-resource-deletion correlate"
register storage-anomaly   "$RED_TEAM_PRIMARY_RG"   "caj-rt-storage-anomaly-${ORG_PREFIX}-${ENVIRONMENT}"          red-team "500× decoy blob downloads → StorageBlobLogs → Defender for Storage anomaly"
register kv-probing        "$RED_TEAM_PRIMARY_RG"   "caj-rt-kv-probing-${ORG_PREFIX}-${ENVIRONMENT}"               red-team "25× failed GetSecret → KV AuditEvent → §6 KV-bulk-access rule"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

c_green=$'\033[0;32m'
c_yellow=$'\033[0;33m'
c_blue=$'\033[0;34m'
c_off=$'\033[0m'

log()  { printf '%s[%s]%s %s\n' "$c_blue" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }
ok()   { printf '%s[%s  OK ]%s %s\n' "$c_green" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }
warn() { printf '%s[%s WARN]%s %s\n' "$c_yellow" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }

require_az() {
  command -v az >/dev/null 2>&1 || { warn "az CLI not on PATH"; exit 1; }
  az account show >/dev/null 2>&1 || { warn "az not logged in — run 'az login'"; exit 1; }
}

fire_scenario() {
  local key=$1
  local rg=${SCENARIOS_RG[$key]}
  local job=${SCENARIOS_JOB[$key]}
  local hint=${SCENARIOS_HINT[$key]}

  log "Starting ${key} → ${job} (rg=${rg})"
  if az containerapp job start --resource-group "$rg" --name "$job" >/dev/null 2>&1; then
    ok "${key} started — ${hint}"
  else
    warn "${key} could not start. Check that synthetic is applied and the CAJ exists in ${rg}"
  fi
}

list_scenarios() {
  printf '%-22s %-9s %s\n' "scenario" "group" "detection hint"
  printf '%-22s %-9s %s\n' "----------------------" "---------" "----------------------------------------------"
  for key in "${!SCENARIOS_JOB[@]}"; do
    printf '%-22s %-9s %s\n' "$key" "${SCENARIOS_GROUP[$key]}" "${SCENARIOS_HINT[$key]}"
  done | sort
}

# ---------------------------------------------------------------------------
# Pivot KQL — printed after firing so the demo operator can paste into LAW
# ---------------------------------------------------------------------------

print_pivots() {
  cat <<'EOF'

KQL pivots (paste into Platform / Security LAW):

  // All synthetic events in the last hour
  union ContainerAppConsoleLogs_CL, AzureDiagnostics
  | where TimeGenerated > ago(1h)
  | where Log_s has "SecuritySimulation" or Resource has "synthetic"

  // Brute-force rule input (§6)
  SigninLogs
  | where TimeGenerated > ago(30m)
  | where UserPrincipalName has "honeypot"
  | summarize attempts = count() by UserPrincipalName, IPAddress, bin(TimeGenerated, 5m)

  // Impossible-travel rule input (§6)
  SigninLogs
  | where TimeGenerated > ago(1h)
  | where UserPrincipalName has "honeypot"
  | project TimeGenerated, UserPrincipalName, IPAddress, Location

  // Decoy KV probing — every entry is a 403 by design
  AzureDiagnostics
  | where TimeGenerated > ago(30m)
  | where ResourceProvider == "MICROSOFT.KEYVAULT" and Resource has "kv-rt-"
  | where ResultSignature !startswith "OK"

EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

require_az
TARGET=${1:-default}

case "$TARGET" in
  default)
    fire_scenario k6-anomalous
    fire_scenario failed-signin
    fire_scenario storage-anomaly
    print_pivots
    ;;
  load)
    for k in k6-baseline k6-spike k6-anomalous; do fire_scenario "$k"; done
    print_pivots
    ;;
  red-team)
    for k in failed-signin impossible-east impossible-west resource-anomaly storage-anomaly kv-probing; do
      fire_scenario "$k"
    done
    print_pivots
    ;;
  all)
    for k in "${!SCENARIOS_JOB[@]}"; do fire_scenario "$k"; done
    print_pivots
    ;;
  list)
    list_scenarios
    ;;
  *)
    if [[ -n "${SCENARIOS_JOB[$TARGET]:-}" ]]; then
      fire_scenario "$TARGET"
      print_pivots
    else
      warn "unknown scenario: $TARGET (try 'list')"
      exit 2
    fi
    ;;
esac
