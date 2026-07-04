# envs/poc.backend.hcl
# Purpose: Remote state backend configuration for the POC environment.
# Section: 1 (scaffold, skeleton); Section 10a (populated with TODO markers).
# Last updated: 2026-05-05
#
# Usage: terraform init \
#   -backend-config="../../envs/poc.backend.hcl" \
#   -backend-config="key=platform/connectivity/terraform.tfstate"
#
# Authentication: the azurerm backend uses OIDC (use_oidc = true) in CI.
# Set ARM_USE_OIDC=true in the workflow environment (handled in GitHub Actions workflows).
# Locally, az login provides credentials via the Azure CLI token.
#
# AFTER running bootstrap/ terraform apply, replace the TODO values below with
# the real outputs from: terraform -chdir=bootstrap output -json
#
# Do NOT hardcode subscription IDs or access keys here — use environment variables:
#   ARM_SUBSCRIPTION_ID  (Management sub, set in GitHub Actions as AZURE_SUBSCRIPTION_ID)
#   ARM_TENANT_ID        (set in GitHub Actions as AZURE_TENANT_ID)
#   ARM_CLIENT_ID        (set in GitHub Actions as AZURE_CLIENT_ID)

# --- Replace TODO values after bootstrap apply ---

resource_group_name  = "rg-tfstate-mgmt-eus2-001"
storage_account_name = "stglobaristfstate01"
container_name       = "tfstate"

# The state SA has shared keys disabled (shared_access_key_enabled = false), so the
# backend must authenticate to blob storage via Entra ID, not an account key. The CI
# OIDC SP (and the local deployer) hold Storage Blob Data Contributor on the account.
use_azuread_auth = true

# key is NOT set here — it is set per-root-module at init time, e.g.:
#   -backend-config="key=platform/connectivity/terraform.tfstate"
#   -backend-config="key=platform/management/terraform.tfstate"
#   -backend-config="key=landing-zones/corp-a1/terraform.tfstate"
