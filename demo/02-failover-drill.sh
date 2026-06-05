#!/usr/bin/env bash
# 02-failover-drill.sh — automated failover drill from corp-a1 → corp-a2.
# Section 13.5.
#
# DEVIATION vs PROMPT.md §13.5: the LZ spokes carry App Services + SQL DB,
# not IaaS VMs, so there is nothing for ASR to replicate. This drill wraps
# the realistic equivalent for an App Service workload:
#   1. SQL Failover Group failover from sql-corp-a1-* → sql-corp-a2-*.
#   2. Surface the corp-a2 App Service default hostname so traffic can be
#      cut over via DNS / Front Door / Traffic Manager (deferred — the POC
#      does not deploy a global ingress; the App Gateway in online-p1 is the
#      ingress for the internet-facing workload only).
#
# Pre-reqs (run once before the first drill):
#   1. az login + az account set to the Landing Zones subscription.
#   2. SQL Failover Group exists between the two SQL Servers:
#        ./02-failover-drill.sh --setup
#      (idempotent — creates the FOG only if missing).
#
# Modes:
#   --setup      Create the SQL Failover Group if absent. No failover.
#   --dry-run    Print what would happen without making changes.
#   --rollback   Fail back to corp-a1 as primary.
#   (no flag)    Run a planned failover from corp-a1 → corp-a2.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — overridable via env vars
# ---------------------------------------------------------------------------

ORG_PREFIX="${ORG_PREFIX:-globaris}"
ENVIRONMENT="${ENVIRONMENT:-poc}"
PRIMARY_RG="rg-corp-a1-workload-${ORG_PREFIX}-${ENVIRONMENT}"
SECONDARY_RG="rg-corp-a2-workload-${ORG_PREFIX}-${ENVIRONMENT}"
FOG_NAME="fog-corp-${ORG_PREFIX}-${ENVIRONMENT}"

MODE="run"
for arg in "$@"; do
  case "$arg" in
    --setup)    MODE="setup" ;;
    --dry-run)  MODE="dry-run" ;;
    --rollback) MODE="rollback" ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

c_green=$'\033[0;32m'
c_yellow=$'\033[0;33m'
c_red=$'\033[0;31m'
c_blue=$'\033[0;34m'
c_off=$'\033[0m'

log() { printf '%s[%s]%s %s\n' "$c_blue" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }
warn() { printf '%s[%s WARN]%s %s\n' "$c_yellow" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }
err()  { printf '%s[%s ERR ]%s %s\n' "$c_red" "$(date -u +%H:%M:%S)" "$c_off" "$*" >&2; }
ok()   { printf '%s[%s  OK ]%s %s\n' "$c_green" "$(date -u +%H:%M:%S)" "$c_off" "$*"; }

require_az() {
  command -v az >/dev/null 2>&1 || { err "az CLI not on PATH"; exit 1; }
  az account show >/dev/null 2>&1 || { err "az not logged in — run 'az login' first"; exit 1; }
}

resolve_sql_server() {
  local rg=$1
  az sql server list --resource-group "$rg" --query '[0].name' -o tsv 2>/dev/null
}

resolve_sql_db() {
  local rg=$1 server=$2
  az sql db list --resource-group "$rg" --server "$server" \
    --query "[?starts_with(name,'sqldb-app-')].name | [0]" -o tsv 2>/dev/null
}

resolve_app_service() {
  local rg=$1
  az webapp list --resource-group "$rg" --query '[0].name' -o tsv 2>/dev/null
}

# ---------------------------------------------------------------------------
# Lookup all the relevant resources up front
# ---------------------------------------------------------------------------

require_az

log "discovering corp-a1 + corp-a2 resources in subscription $(az account show --query name -o tsv)"
PRIMARY_SQL_SERVER=$(resolve_sql_server "$PRIMARY_RG")
SECONDARY_SQL_SERVER=$(resolve_sql_server "$SECONDARY_RG")
PRIMARY_DB=$(resolve_sql_db "$PRIMARY_RG" "$PRIMARY_SQL_SERVER")
PRIMARY_APP=$(resolve_app_service "$PRIMARY_RG")
SECONDARY_APP=$(resolve_app_service "$SECONDARY_RG")

if [[ -z "$PRIMARY_SQL_SERVER" || -z "$SECONDARY_SQL_SERVER" ]]; then
  err "Could not resolve both SQL servers — expected one each in $PRIMARY_RG and $SECONDARY_RG"
  exit 1
fi

cat <<EOF

corp-a1 (primary):
  SQL server : ${PRIMARY_SQL_SERVER}
  SQL DB     : ${PRIMARY_DB:-<none>}
  App Service: ${PRIMARY_APP:-<none>}
corp-a2 (DR):
  SQL server : ${SECONDARY_SQL_SERVER}
  App Service: ${SECONDARY_APP:-<none>}
Failover Group: ${FOG_NAME}

EOF

# ---------------------------------------------------------------------------
# Setup mode — create the Failover Group if absent
# ---------------------------------------------------------------------------

ensure_fog() {
  local existing
  existing=$(az sql failover-group list \
    --resource-group "$PRIMARY_RG" \
    --server "$PRIMARY_SQL_SERVER" \
    --query "[?name=='${FOG_NAME}'].name | [0]" -o tsv 2>/dev/null || true)

  if [[ -n "$existing" ]]; then
    log "Failover Group ${FOG_NAME} already exists — skipping create"
    return
  fi

  if [[ -z "$PRIMARY_DB" ]]; then
    err "Cannot create FOG: no DB found on ${PRIMARY_SQL_SERVER}"
    exit 1
  fi

  log "Creating Failover Group ${FOG_NAME} ..."
  local secondary_server_id
  secondary_server_id=$(az sql server show \
    --resource-group "$SECONDARY_RG" \
    --name "$SECONDARY_SQL_SERVER" \
    --query id -o tsv)

  az sql failover-group create \
    --name "$FOG_NAME" \
    --resource-group "$PRIMARY_RG" \
    --server "$PRIMARY_SQL_SERVER" \
    --partner-server "$SECONDARY_SQL_SERVER" \
    --partner-resource-group "$SECONDARY_RG" \
    --failover-policy Automatic \
    --grace-period 1 \
    --add-db "$PRIMARY_DB" \
    >/dev/null
  ok "Failover Group ${FOG_NAME} created — partner server ${secondary_server_id}"
}

# ---------------------------------------------------------------------------
# Failover / rollback
# ---------------------------------------------------------------------------

do_failover() {
  local from_server=$1 to_server=$2 to_rg=$3
  log "Initiating planned failover: ${from_server} → ${to_server}"
  az sql failover-group set-primary \
    --name "$FOG_NAME" \
    --resource-group "$to_rg" \
    --server "$to_server" \
    >/dev/null
  ok "FOG primary moved to ${to_server}"
}

verify_post_failover() {
  local expected_primary=$1
  log "Verifying current FOG primary..."
  local actual
  actual=$(az sql failover-group list \
    --resource-group "$PRIMARY_RG" \
    --server "$PRIMARY_SQL_SERVER" \
    --query "[?name=='${FOG_NAME}'].partnerServers[?role=='Primary'].id | [0] | [0]" \
    -o tsv 2>/dev/null || true)
  if [[ "$actual" == *"/$expected_primary" ]]; then
    ok "FOG primary is now ${expected_primary} as expected"
  else
    warn "FOG primary lookup returned: ${actual:-<empty>} — verify manually"
  fi
}

# ---------------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------------

case "$MODE" in
  setup)
    ensure_fog
    ;;

  dry-run)
    log "DRY RUN — no changes will be made"
    log "Would ensure FOG ${FOG_NAME} exists with DB ${PRIMARY_DB}"
    log "Would initiate planned failover ${PRIMARY_SQL_SERVER} → ${SECONDARY_SQL_SERVER}"
    log "Would surface secondary App Service hostname: ${SECONDARY_APP}.azurewebsites.net"
    log "Would log a synthetic 'DR drill executed' marker to Platform LAW"
    ok "DRY RUN complete"
    ;;

  run)
    ensure_fog
    do_failover "$PRIMARY_SQL_SERVER" "$SECONDARY_SQL_SERVER" "$SECONDARY_RG"
    verify_post_failover "$SECONDARY_SQL_SERVER"
    cat <<EOF

NEXT STEPS (manual until a global ingress is provisioned):
  1. Update DNS / Front Door / Traffic Manager to point at:
       https://${SECONDARY_APP:-<deferred>}.azurewebsites.net
  2. Deploy the corp-a1 REST API artifact to corp-a2:
       az webapp deploy --resource-group ${SECONDARY_RG} \
                         --name ${SECONDARY_APP:-<deferred>} \
                         --src-url '<sas-url-from-synthetic/outputs.tf>'
  3. Run smoke tests against the new endpoint.
  4. When ready, run ./02-failover-drill.sh --rollback

EOF
    ok "Failover drill complete"
    ;;

  rollback)
    do_failover "$SECONDARY_SQL_SERVER" "$PRIMARY_SQL_SERVER" "$PRIMARY_RG"
    verify_post_failover "$PRIMARY_SQL_SERVER"
    ok "Failback complete — primary is corp-a1 again"
    ;;
esac
