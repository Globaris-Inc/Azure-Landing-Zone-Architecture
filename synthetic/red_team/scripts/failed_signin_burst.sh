#!/usr/bin/env bash
# Red-team scenario — failed sign-in burst.
# Section 13.3.
#
# Fires N ROPC password-grant attempts against $HONEYPOT_UPN with deliberately
# wrong passwords. The honeypot is a tenant-resident disabled user; every
# request returns invalid_grant / invalid_user. The §6 brute-force analytics
# rule (configured to threshold ≥5 failures in 10 minutes per principal) lights
# up; the §5 CA-002 block-legacy-auth policy may also intercept first.
#
# stdout is structured JSON so ContainerAppConsoleLogs_CL retains parseable
# fields; the source CAJ is tagged Purpose=SecuritySimulation for filtering.

set -uo pipefail

: "${TENANT_ID:?TENANT_ID must be set}"
: "${HONEYPOT_UPN:?HONEYPOT_UPN must be set}"
ATTEMPTS="${ATTEMPTS:-12}"
SCENARIO="${SCENARIO:-failed-signin-burst}"

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
endpoint="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"

emit() {
  printf '{"timestamp":"%s","scenario":"%s","run_id":"%s","event":"%s","attempt":%s,"status":%s,"upn":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO" "$run_id" "$1" "${2:-0}" "${3:-0}" "$HONEYPOT_UPN"
}

emit "scenario_start" 0 0

for i in $(seq 1 "$ATTEMPTS"); do
  status="$(
    curl -sS -o /dev/null -w '%{http_code}' \
      -X POST "$endpoint" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode 'grant_type=password' \
      --data-urlencode 'client_id=04b07795-8ddb-461a-bbee-02f9e1bf7b46' \
      --data-urlencode "username=${HONEYPOT_UPN}" \
      --data-urlencode 'password=Sp1nN3edsTo401-deliberately-wrong' \
      --data-urlencode 'scope=https://graph.microsoft.com/.default'
  )"
  emit "signin_attempt" "$i" "$status"
  sleep 1
done

emit "scenario_end" "$ATTEMPTS" 0
exit 0
