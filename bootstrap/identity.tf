# Purpose: OIDC federated identity for GitHub Actions — Entra app, SP, federated creds, RBAC.
# Section: 10a — Pipeline & Tooling (bootstrap subset)
# Last updated: 2026-06-29
#
# No client secret is created. All auth is via OIDC federated credentials (ADR-006).
# RBAC scope: least-privilege scoped role set (ADR-021) — resolves OQ-008 by design.
#   Tenant-root Owner is REMOVED. The SP now holds:
#     - Management Group Contributor @ Tenant Root Group (MG create/delete + sub move)
#     - Resource Policy Contributor + User Access Administrator @ Globaris MG
#       (and UAA @ Landing Zones MG — see row 4 note below)
#     - Contributor + User Access Administrator @ each of the 5 subscriptions
#     - Storage Blob Data Contributor @ state Storage Account (unchanged)
#   Sufficiency is only PROVEN by a real CI apply+destroy of all 10 roots — see ADR-021
#   "Validation caveat". Any 403 → add the precise missing scope/role; never revert to Owner.

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
# RBAC — least-privilege scoped role set (ADR-021 — resolves OQ-008)
#
# Replaces the single Owner @ Tenant Root MG (ADR-006) with the role/scope matrix
# below. All role names are stable built-ins; GUIDs (from ADR-021 §1) in comments.
#
# BOOTSTRAP-ORDERING (load-bearing — read before applying):
#   The Globaris + Landing Zones MGs do NOT exist at the FIRST bootstrap apply —
#   they are created later by platform/management-groups. A role assignment whose
#   `scope` is an MG resource-ID string still requires that MG to exist AT APPLY
#   TIME, so rows 2/3/4 (Globaris/landingzones MG scope) will 403 on a fresh
#   tenant. Resolution (per spec §3b, documented in bootstrap/README.md):
#   run platform/management-groups ONCE under the existing tenant-root Owner (or a
#   human Owner), THEN re-apply bootstrap with this scoped set so the MG-scoped
#   grants bind. Rows 1 (Tenant Root Group) and 5/6 (subscriptions) have no such
#   dependency — those scopes already exist at first apply.
# ---------------------------------------------------------------------------

locals {
  # Well-known MG resource IDs. Constructed as static strings (NOT a `data`
  # lookup) so a plan does not fail before the MG tree exists. The MG names
  # ("globaris", "landingzones") are stable, created by platform/management-groups.
  tenant_root_mg_id  = data.azurerm_management_group.tenant_root.id
  globaris_mg_id     = "/providers/Microsoft.Management/managementGroups/globaris"
  landingzones_mg_id = "/providers/Microsoft.Management/managementGroups/landingzones"

  # Static map: subscription key -> subscription ID. Drives the per-sub
  # Contributor + UAA assignments via for_each (not count — repo rule).
  cicd_subscription_ids = {
    management   = var.management_subscription_id
    connectivity = var.connectivity_subscription_id
    identity     = var.identity_subscription_id
    security     = var.security_subscription_id
    landingzones = var.landingzones_subscription_id
  }
}

# Row 1 — Management Group Contributor (5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c)
# @ Tenant Root Group: create/update/delete the Globaris MG tree + MOVE the 5
# subscriptions into it (platform/management-groups). Contributor cannot touch
# Microsoft.Management. Scope exists at first bootstrap apply.
resource "azurerm_role_assignment" "oidc_mg_contributor_tenant_root" {
  scope                            = local.tenant_root_mg_id
  role_definition_name             = "Management Group Contributor"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 2 — Resource Policy Contributor (36243c78-bf99-498c-9df9-86d9f8d28608)
# @ Globaris MG: create/delete MG-scoped policy & policy-set assignments (FinOps
# tag initiative @ globaris; MCSB/NIST/CIS @ root MG; deny-public-net).
# Requires the Globaris MG to exist — see BOOTSTRAP-ORDERING above.
resource "azurerm_role_assignment" "oidc_policy_contributor_globaris" {
  scope                            = local.globaris_mg_id
  role_definition_name             = "Resource Policy Contributor"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 3 — User Access Administrator (18d7d88d-d35e-4fb5-a5c3-7773c20a72d9)
# @ Globaris MG: create/delete MG-scoped role assignments (policy remediation
# identities, PIM eligible assignments + role-management policies). Inherits down
# to the landingzones child MG. Requires the Globaris MG — see BOOTSTRAP-ORDERING.
resource "azurerm_role_assignment" "oidc_uaa_globaris" {
  scope                            = local.globaris_mg_id
  role_definition_name             = "User Access Administrator"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 4 — User Access Administrator @ Landing Zones MG. Retained explicitly for
# auditability and to survive any future re-parenting (ADR-021 §matrix row 4).
# Technically redundant: UAA @ Globaris (row 3) inherits to this child MG. Kept
# distinct per the spec. Requires the landingzones MG — see BOOTSTRAP-ORDERING.
resource "azurerm_role_assignment" "oidc_uaa_landingzones" {
  scope                            = local.landingzones_mg_id
  role_definition_name             = "User Access Administrator"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 5 — Contributor (b24988ac-6180-42a0-ab88-20f7382dd24c) on each of the 5
# subscriptions: create/destroy all resources (hub/firewall/DNS, LAW/automation/
# budgets, Entra DS/RSV, Sentinel/Defender/KV, spokes, synthetic RGs). Sub scopes
# exist at first bootstrap apply — no ordering dependency.
resource "azurerm_role_assignment" "oidc_contributor_subs" {
  for_each                         = local.cicd_subscription_ids
  scope                            = "/subscriptions/${each.value}"
  role_definition_name             = "Contributor"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 6 — User Access Administrator on each of the 5 subscriptions: create/delete
# role assignments the IaC makes INSIDE the subs (guardrails MI, red-team MI,
# KV/Storage data-plane roles). Contributor's NotActions forbid roleAssignments/
# write+delete, so UAA is required. No ordering dependency.
resource "azurerm_role_assignment" "oidc_uaa_subs" {
  for_each                         = local.cicd_subscription_ids
  scope                            = "/subscriptions/${each.value}"
  role_definition_name             = "User Access Administrator"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------
# RBAC — Storage Blob Data Contributor on state SA
# The scoped matrix above (Contributor @ each subscription) covers the control
# plane; the Storage data plane requires an explicit data-plane role — classic
# RBAC roles (Contributor/Owner) do not include Storage blob data access.
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
