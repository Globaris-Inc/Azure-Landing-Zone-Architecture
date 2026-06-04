#!/usr/bin/env bash
# Red-team scenario — storage anomaly (mass blob download).
# Section 13.3.
#
# 500 blob GETs against $DECOY_BLOB on $DECOY_STORAGE_ACCOUNT within ~2 minutes.
# Authenticates as the CAJ's MI (Storage Blob Data Reader on the decoy SA).
# Drives the §6 "anonymous storage access" / mass-read analytics rule via the
# resulting StorageBlobLogs entries.

set -uo pipefail

: "${DECOY_STORAGE_ACCOUNT:?DECOY_STORAGE_ACCOUNT must be set}"
: "${DECOY_CONTAINER:?DECOY_CONTAINER must be set}"
: "${DECOY_BLOB:?DECOY_BLOB must be set}"
ATTEMPTS="${ATTEMPTS:-500}"
SCENARIO="${SCENARIO:-storage-anomaly}"

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

emit() {
  printf '{"timestamp":"%s","scenario":"%s","run_id":"%s","event":"%s","attempt":%s,"detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO" "$run_id" "$1" "${2:-0}" "${3:-}"
}

emit "scenario_start" 0 "MI login"
az login --identity --allow-no-subscriptions --output none

emit "burst_begin" 0 "$DECOY_STORAGE_ACCOUNT/$DECOY_CONTAINER/$DECOY_BLOB"
for i in $(seq 1 "$ATTEMPTS"); do
  az storage blob download \
    --account-name "$DECOY_STORAGE_ACCOUNT" \
    --container-name "$DECOY_CONTAINER" \
    --name "$DECOY_BLOB" \
    --file /tmp/.decoy.bin \
    --auth-mode login \
    --no-progress >/dev/null 2>&1 || true

  # log every 50th to avoid flooding stdout
  if (( i % 50 == 0 )); then
    emit "burst_progress" "$i" ""
  fi
done
emit "burst_end" "$ATTEMPTS" ""

emit "scenario_end" "$ATTEMPTS" ""
exit 0
