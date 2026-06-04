#!/usr/bin/env bash
# Red-team scenario — suspicious resource creation.
# Section 13.3.
#
# Authenticates as the CAJ's system-assigned MI, creates a Standard SKU public
# IP in $TARGET_RG, then deletes it. The §6 "mass resource deletion" /
# "suspicious public IP creation" rule fires on the AzureActivity log of the
# delete operation matched with the create operation by the same principal.

set -uo pipefail

: "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID must be set}"
: "${TARGET_RG:?TARGET_RG must be set}"
: "${LOCATION:?LOCATION must be set}"
SCENARIO="${SCENARIO:-resource-anomaly}"

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
pip_name="pip-rt-anomaly-${run_id}"

emit() {
  printf '{"timestamp":"%s","scenario":"%s","run_id":"%s","event":"%s","resource":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO" "$run_id" "$1" "${2:-}" "${3:-}"
}

emit "scenario_start" "" "MI login"
az login --identity --allow-no-subscriptions --output none
az account set --subscription "$SUBSCRIPTION_ID" --output none

emit "public_ip_create_begin" "$pip_name" ""
az network public-ip create \
  --name "$pip_name" \
  --resource-group "$TARGET_RG" \
  --location "$LOCATION" \
  --sku Standard \
  --allocation-method Static \
  --tags "Purpose=SecuritySimulation" "Lifecycle=Ephemeral" "Scenario=$SCENARIO" \
  --output none
emit "public_ip_create_end" "$pip_name" "created"

sleep 30

emit "public_ip_delete_begin" "$pip_name" ""
az network public-ip delete \
  --name "$pip_name" \
  --resource-group "$TARGET_RG" \
  --output none
emit "public_ip_delete_end" "$pip_name" "deleted"

emit "scenario_end" "" ""
exit 0
