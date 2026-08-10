#!/usr/bin/env bash
# 04-reset.sh — return the demo environment to a clean post-walkthrough state.
# Section 13.5.
#
# Actions:
#   1. Close all open Sentinel incidents in the Security LAW (status →
#      Closed, classification → BenignPositive, classification_comment →
#      "Synthetic — closed by demo/04-reset.sh"). Confined to incidents
#      created in the last var.RESET_WINDOW_HOURS (default 24) so historic
#      real incidents are not touched.
#   2. Re-disable the honeypot Entra user if it ended up enabled mid-demo.
#   3. Delete any orphan public IPs that the red-team resource_anomaly
#      scenario may have left behind on a failed run.
#   4. (No-op for the §13.4 budget — the consumption-budget resource is
#      stateful only via Azure's portal acknowledgment flag, which clears
#      itself on the next billing cycle.)
#
# Flags:
#   --dry-run        Print actions, take none.
#   --window <H>     Override the close window (hours). Default 24.

set -euo pipefail

ORG_PREFIX="${ORG_PREFIX:-globaris}"
ENVIRONMENT="${ENVIRONMENT:-poc}"
SECURITY_RG="${SECURITY_RG:-rg-security-${ORG_PREFIX}-${ENVIRONMENT}}"
# ADR-075: -r5 generation suffix; keep in sync with security_law_generation in envs/poc.tfvars.
SECURITY_LAW="${SECURITY_LAW:-law-security-${ORG_PREFIX}-${ENVIRONMENT}-r5}"
RED_TEAM_PRIMARY_RG="rg-synthetic-red-team-${ORG_PREFIX}-${ENVIRONMENT}"
HONEYPOT_UPN="${HONEYPOT_UPN:-}"
WINDOW_HOURS=24
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --window)   WINDOW_HOURS=$2; shift 2 ;;
    -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
    *)          echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

c_green=$'\033[0;32m'
c_yellow=$'\033[0;33m'
c_blue=$'\033[0;34m'
c_off=$'\033[0m'

log()  { printf '%s[%s]%s %s\n' "$c_blue" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }
ok()   { printf '%s[%s  OK ]%s %s\n' "$c_green" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }
warn() { printf '%s[%s WARN]%s %s\n' "$c_yellow" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "(dry-run) $*"
  else
    eval "$@"
  fi
}

# ---------------------------------------------------------------------------
# 1. Close open Sentinel incidents
# ---------------------------------------------------------------------------

close_sentinel_incidents() {
  log "Closing open Sentinel incidents created in the last ${WINDOW_HOURS}h"
  local cutoff
  cutoff=$(date -u -d "-${WINDOW_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v-"${WINDOW_HOURS}H" +%Y-%m-%dT%H:%M:%SZ)

  local incidents
  incidents=$(az sentinel incident list \
    --resource-group "$SECURITY_RG" \
    --workspace-name "$SECURITY_LAW" \
    --query "[?properties.status!='Closed' && properties.createdTimeUtc > '${cutoff}'].name" \
    -o tsv 2>/dev/null || true)

  if [[ -z "$incidents" ]]; then
    ok "No open incidents in the window."
    return
  fi

  local count=0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    run "az sentinel incident update \
      --resource-group '$SECURITY_RG' \
      --workspace-name '$SECURITY_LAW' \
      --incident-id '$id' \
      --status Closed \
      --classification BenignPositive \
      --classification-comment 'Synthetic — closed by demo/04-reset.sh' >/dev/null"
    count=$((count + 1))
  done <<< "$incidents"
  ok "Closed ${count} incidents"
}

# ---------------------------------------------------------------------------
# 2. Re-disable honeypot user
# ---------------------------------------------------------------------------

redisable_honeypot() {
  if [[ -z "$HONEYPOT_UPN" ]]; then
    warn "HONEYPOT_UPN not set — skipping honeypot re-disable"
    return
  fi

  log "Re-disabling honeypot user ${HONEYPOT_UPN}"
  local enabled
  enabled=$(az ad user show --id "$HONEYPOT_UPN" --query accountEnabled -o tsv 2>/dev/null || echo "unknown")
  if [[ "$enabled" == "true" ]]; then
    run "az ad user update --id '$HONEYPOT_UPN' --account-enabled false >/dev/null"
    ok "Honeypot ${HONEYPOT_UPN} disabled"
  elif [[ "$enabled" == "false" ]]; then
    ok "Honeypot ${HONEYPOT_UPN} already disabled"
  else
    warn "Could not query honeypot account state (lookup returned: ${enabled})"
  fi
}

# ---------------------------------------------------------------------------
# 3. Orphan public IP cleanup (resource_anomaly leaves these on failure)
# ---------------------------------------------------------------------------

cleanup_orphan_pips() {
  log "Scanning ${RED_TEAM_PRIMARY_RG} for orphan public IPs (pip-rt-anomaly-*)"
  local orphans
  orphans=$(az network public-ip list \
    --resource-group "$RED_TEAM_PRIMARY_RG" \
    --query "[?starts_with(name,'pip-rt-anomaly-') && ipConfiguration==null].name" \
    -o tsv 2>/dev/null || true)

  if [[ -z "$orphans" ]]; then
    ok "No orphan public IPs found"
    return
  fi

  while IFS= read -r pip; do
    [[ -z "$pip" ]] && continue
    log "Deleting orphan ${pip}"
    run "az network public-ip delete --resource-group '$RED_TEAM_PRIMARY_RG' --name '$pip' >/dev/null"
  done <<< "$orphans"
  ok "Orphan public IP cleanup complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

command -v az >/dev/null 2>&1 || { warn "az CLI not on PATH"; exit 1; }
az account show >/dev/null 2>&1 || { warn "az not logged in — run 'az login'"; exit 1; }

[[ $DRY_RUN -eq 1 ]] && log "DRY RUN — no changes will be made"

close_sentinel_incidents
redisable_honeypot
cleanup_orphan_pips

ok "Demo reset complete"
