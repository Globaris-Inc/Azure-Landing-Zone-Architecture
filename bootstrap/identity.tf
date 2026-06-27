# Purpose: OIDC federated identity for GitHub Actions — Entra app, SP, federated creds, RBAC.
# Section: 10a — Pipeline & Tooling (bootstrap subset)
# Last updated: 2026-05-05
#
# No client secret is created. All auth is via OIDC federated credentials (ADR-006).
# RBAC scope: Owner at Tenant Root MG (temporary — scope-down tracked in OQ-008).

# ---------------------------------------------------------------------------
# Current Entra ID context
# ---------------------------------------------------------------------------

data "azuread_client_config" "current" {}

# ---------------------------------------------------------------------------
# Tenant Root Management Group (RBAC scope for OIDC SP — ADR-006)
# The Tenant Root MG name is always equal to the tenant ID.
# ---------------------------------------------------------------------------

data "azurerm_management_group" "tenant_root" {
  name = var.tenant_id
}

# ---------------------------------------------------------------------------
# Entra ID Application Registration
# ---------------------------------------------------------------------------

resource "azuread_application" "oidc" {
  display_name = "sp-alz-poc-cicd"

  # No web redirect URIs, no implicit grants — workload identity only.
  # No API permissions needed (all access is via ARM RBAC, not Graph).
}

# ---------------------------------------------------------------------------
# Service Principal
# ---------------------------------------------------------------------------

resource "azuread_service_principal" "oidc" {
  client_id                    = azuread_application.oidc.client_id
  app_role_assignment_required = false
}

# ---------------------------------------------------------------------------
# Federated Identity Credentials (OIDC — no client_secret)
# ---------------------------------------------------------------------------

# Triggered by: push to main branch
resource "azuread_application_federated_identity_credential" "main_branch" {
  application_id = azuread_application.oidc.id
  display_name   = "github-main-branch"
  description    = "GitHub Actions OIDC — push to main branch (apply workflow)"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
}

# Triggered by: pull_request events (any branch → main)
resource "azuread_application_federated_identity_credential" "pull_request" {
  application_id = azuread_application.oidc.id
  display_name   = "github-pull-request"
  description    = "GitHub Actions OIDC — pull_request events (plan workflow)"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:pull_request"
}

# ---------------------------------------------------------------------------
# Environment-scoped federated credentials (ADR-019 — gated deploy/teardown)
#
# When a workflow job references a GitHub Environment, the OIDC token's `sub`
# claim becomes  repo:<org>/<repo>:environment:<env-name>  — NOT the branch ref.
# The two creds below federate the gated jobs:
#   - deploy.yml  apply jobs  → environment: production
#   - teardown.yml destroy job → environment: production-destroy
#
# !!! BOOTSTRAP MUST BE RE-APPLIED for these to take effect. Until `bootstrap/`
# is re-applied (local one-time apply per ADR-005), any gated apply/teardown job
# will FAIL at `azure/login` because the matching `sub` is not yet federated.
# The non-gated `action=plan` path on `main`/PR is unaffected (it uses the
# branch/pull_request subjects above, which are already registered).
# ---------------------------------------------------------------------------

# Triggered by: deploy.yml apply jobs (environment: production)
resource "azuread_application_federated_identity_credential" "env_production" {
  application_id = azuread_application.oidc.id
  display_name   = "github-env-production"
  description    = "GitHub Actions OIDC — production Environment (deploy.yml apply gate)"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:environment:production"
}

# Triggered by: teardown.yml destroy job (environment: production-destroy)
resource "azuread_application_federated_identity_credential" "env_production_destroy" {
  application_id = azuread_application.oidc.id
  display_name   = "github-env-production-destroy"
  description    = "GitHub Actions OIDC — production-destroy Environment (teardown.yml gate)"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:environment:production-destroy"
}

# ---------------------------------------------------------------------------
# RBAC — Owner at Tenant Root MG (ADR-006; scoped down at Section 12 per OQ-008)
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "oidc_owner_tenant_root" {
  scope                = data.azurerm_management_group.tenant_root.id
  role_definition_name = "Owner"
  principal_id         = azuread_service_principal.oidc.object_id

  # SP principal type; skip AAD propagation check to avoid spurious 404 errors
  # immediately after SP creation.
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# RBAC — Storage Blob Data Contributor on state SA
# Owner (above) covers control plane; Storage data plane requires an explicit
# data-plane role — classic RBAC does not include Storage data access.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "oidc_storage_blob_contributor" {
  scope                            = azurerm_storage_account.tfstate.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# RBAC — Storage Blob Data Contributor for the bootstrap deployer
# Needed so the deployer can run local terraform commands against modules that
# use the state SA (shared_access_key_enabled = false → data-plane RBAC required).
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "deployer_storage_blob_contributor" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
