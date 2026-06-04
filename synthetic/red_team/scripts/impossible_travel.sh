#!/usr/bin/env bash
# Red-team scenario — impossible travel pole.
# Section 13.3.
#
# A single sign-in attempt to $HONEYPOT_UPN. Two Container Apps Jobs run this
# script: one in the primary region (eastus2) on the hour, the other in the
# anomalous geo ($RED_TEAM_GEO_LOCATION) five minutes later. The two
# regions' outbound IPs differ enough geographically to trip the §6
# impossible-travel analytics rule.
#
# $POLE_LABEL identifies the source region in stdout / KQL.

set -uo pipefail

: "${TENANT_ID:?TENANT_ID must be set}"
: "${HONEYPOT_UPN:?HONEYPOT_UPN must be set}"
: "${POLE_LABEL:?POLE_LABEL must be set (e.g. east, west)}"
SCENARIO="${SCENARIO:-impossible-travel}"

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
endpoint="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"

emit() {
  printf '{"timestamp":"%s","scenario":"%s","pole":"%s","run_id":"%s","event":"%s","status":%s,"upn":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO" "$POLE_LABEL" "$run_id" "$1" "${2:-0}" "$HONEYPOT_UPN"
}

emit "scenario_start" 0

status="$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "$endpoint" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode 'client_id=04b07795-8ddb-461a-bbee-02f9e1bf7b46' \
    --data-urlencode "username=${HONEYPOT_UPN}" \
    --data-urlencode 'password=ImpossibleTravel-deliberately-wrong' \
    --data-urlencode 'scope=https://graph.microsoft.com/.default'
)"
emit "signin_attempt" "$status"

emit "scenario_end" 0
exit 0
