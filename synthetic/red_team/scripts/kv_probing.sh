#!/usr/bin/env bash
# Red-team scenario — Key Vault probing.
# Section 13.3.
#
# The CAJ's MI holds Key Vault Reader on the decoy KV — it can list secret
# metadata but NOT read secret values. The script attempts to GetSecret on a
# list of plausible-but-nonexistent names. Every call fails with 403 (no
# Secrets User role) or 404 (no such secret) and lands in the decoy KV's
# AzureDiagnostics → Platform LAW stream where the §6 "KV bulk secret access"
# rule picks it up.

set -uo pipefail

: "${DECOY_KEY_VAULT_NAME:?DECOY_KEY_VAULT_NAME must be set}"
ATTEMPTS="${ATTEMPTS:-25}"
SCENARIO="${SCENARIO:-kv-probing}"

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

emit() {
  printf '{"timestamp":"%s","scenario":"%s","run_id":"%s","event":"%s","secret":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO" "$run_id" "$1" "${2:-}" "${3:-}"
}

candidates=(
  prod-db-admin-password
  storage-sas-token
  signing-key
  payment-gateway-key
  okta-client-secret
  github-app-private-key
  stripe-api-key
  jwt-signing-secret
  smtp-app-password
  encryption-master-key
)

emit "scenario_start" "" "MI login"
az login --identity --allow-no-subscriptions --output none

for i in $(seq 1 "$ATTEMPTS"); do
  secret_name="${candidates[$(( (i - 1) % ${#candidates[@]} ))]}"

  if az keyvault secret show \
        --vault-name "$DECOY_KEY_VAULT_NAME" \
        --name "$secret_name" \
        --output none 2>/dev/null; then
    emit "probe_unexpected_success" "$secret_name" "leak"
  else
    emit "probe_denied" "$secret_name" ""
  fi
  sleep 1
done

emit "scenario_end" "" ""
exit 0
