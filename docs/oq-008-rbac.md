# OQ-008 — OIDC SP Least-Privilege RBAC: devsecops implementation spec

> **Owner of this change:** devsecops-engineer. **Authoritative decision:** [ADR-021](../DECISIONS.md#adr-021-oidc-sp-least-privilege-scope-down--replace-tenant-root-owner-with-a-scoped-role-set-refinessupersedes-adr-006).
> **Scope:** edits to `bootstrap/identity.tf` and `bootstrap/variables.tf` only. Architect-authored spec; do **not**
> treat `terraform validate`/`plan` as proof — see "Validation" at the end.

This replaces the single **Owner @ Tenant Root MG** assignment (`azurerm_role_assignment.oidc_owner_tenant_root`)
with a scoped role set that still lets CI `apply` **and** `destroy` all 10 roots. The **Storage Blob Data
Contributor** assignment on the state SA is **unchanged**. The **azuread Graph app permissions are unrelated to
this change and stay as-is** (they are directory permissions, not ARM RBAC).

---

## 1. Role / scope matrix (what to implement)

All GUIDs verified against the Microsoft Learn built-in-roles reference (2026-06-20 rev).

| # | Built-in role | Role GUID | Scope | Replaces / status |
|---|---|---|---|---|
| 1 | Management Group Contributor | `5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c` | Tenant Root Group | part of Owner replacement |
| 2 | Resource Policy Contributor  | `36243c78-bf99-498c-9df9-86d9f8d28608` | Globaris root MG | part of Owner replacement |
| 3 | User Access Administrator    | `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | Globaris root MG | part of Owner replacement |
| 4 | User Access Administrator    | `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | Landing Zones MG | OPTIONAL (inherited from row 3) |
| 5 | Contributor                  | `b24988ac-6180-42a0-ab88-20f7382dd24c` | each of 5 subscriptions | part of Owner replacement |
| 6 | User Access Administrator    | `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | each of 5 subscriptions | part of Owner replacement |
| 7 | Storage Blob Data Contributor | `ba92f5b4-2d11-453d-a403-e96b0029c9fe` | state Storage Account | **UNCHANGED** (already present) |

Row 4 is functionally redundant because UAA at Globaris (row 3) inherits to the `landingzones` child MG. It is
listed for auditability; **devsecops may omit row 4**. If omitted, leave a one-line comment in `identity.tf`
noting it is covered by inheritance from Globaris.

---

## 2. New variables — `bootstrap/variables.tf`

Bootstrap currently declares only `management_subscription_id`. Add the other four (names must match the rest of
the repo exactly — verified in `platform/management-groups/main.tf` and `envs/poc.secret.tfvars.example`):

```hcl
variable "connectivity_subscription_id" {
  description = "Subscription ID of the Connectivity subscription. Used to grant the OIDC SP Contributor + User Access Administrator for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}

variable "identity_subscription_id" {
  description = "Subscription ID of the Identity subscription. Used to grant the OIDC SP Contributor + User Access Administrator for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}

variable "security_subscription_id" {
  description = "Subscription ID of the Security subscription. Used to grant the OIDC SP Contributor + User Access Administrator for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}

variable "landingzones_subscription_id" {
  description = "Subscription ID of the shared Landing Zones subscription (spokes + synthetic). Used to grant the OIDC SP Contributor + User Access Administrator for CI apply/destroy (OQ-008 / ADR-021)."
  type        = string
}
```

`management_subscription_id` already exists — reuse it; do not re-declare. Add the four IDs to
`bootstrap/terraform.tfvars.example` as `<ANGLE_BRACKET>` placeholders (no real IDs — repo rule).

---

## 3. `bootstrap/identity.tf` — replace the Owner assignment

### 3a. DELETE

```hcl
resource "azurerm_role_assignment" "oidc_owner_tenant_root" { ... }   # the whole block
```

Keep `data "azurerm_management_group" "tenant_root"` — it is reused as the Tenant Root Group scope for row 1.

### 3b. ADD — data source for the Globaris + landingzones MGs

The MG names are stable strings (`globaris`, `landingzones`) created by `platform/management-groups`. Bootstrap
runs **before** that root, so do **not** use a `data` lookup that would fail on first apply — construct the
resource IDs directly from the well-known names:

```hcl
locals {
  tenant_root_mg_id  = data.azurerm_management_group.tenant_root.id
  globaris_mg_id     = "/providers/Microsoft.Management/managementGroups/globaris"
  landingzones_mg_id = "/providers/Microsoft.Management/managementGroups/landingzones"

  # Static map: subscription key -> subscription ID. Drives the per-sub
  # Contributor + UAA assignments (for_each, not count — repo rule).
  cicd_subscription_ids = {
    management   = var.management_subscription_id
    connectivity = var.connectivity_subscription_id
    identity     = var.identity_subscription_id
    security     = var.security_subscription_id
    landingzones = var.landingzones_subscription_id
  }
}
```

> **Ordering note for devsecops:** the Globaris/landingzones MGs do **not** exist at first bootstrap apply, but a
> role assignment whose `scope` is an MG resource-ID string can be created **before** the MG exists only if the MG
> exists at apply time. Because bootstrap is a one-time apply that precedes `platform/management-groups`, assignments
> 2/3/4 will fail until the MG tree exists. **Resolution:** these MG-scoped assignments must be applied in the
> *second* bootstrap pass (after the first `deploy.yml target=platform/management-groups` run), OR
> `platform/management-groups` must be allowed to run under the existing Owner once, then bootstrap re-applied with
> the scoped set. Document the chosen sequence in `bootstrap/README.md`. The per-sub (rows 5/6) and Tenant-Root
> (row 1) assignments have no such dependency. **Flag this to the architect if the bootstrap-ordering contract needs
> an ADR** — it is an implementation sequencing detail, not a new architectural decision.

### 3c. ADD — the seven assignment resources (row 7 already exists)

```hcl
# Row 1 — Management Group Contributor @ Tenant Root Group: create/delete the
# Globaris MG tree + move the 5 subscriptions (platform/management-groups).
resource "azurerm_role_assignment" "oidc_mg_contributor_tenant_root" {
  scope                            = local.tenant_root_mg_id
  role_definition_name             = "Management Group Contributor"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 2 — Resource Policy Contributor @ Globaris MG: MG-scoped policy/initiative
# assignments (FinOps tags @ globaris; MCSB/NIST/CIS @ root MG; deny-public-net).
resource "azurerm_role_assignment" "oidc_policy_contributor_globaris" {
  scope                            = local.globaris_mg_id
  role_definition_name             = "Resource Policy Contributor"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 3 — User Access Administrator @ Globaris MG: create/delete MG-scoped role
# assignments (policy remediation identities, PIM eligible + role-mgmt policies).
resource "azurerm_role_assignment" "oidc_uaa_globaris" {
  scope                            = local.globaris_mg_id
  role_definition_name             = "User Access Administrator"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 4 — OPTIONAL: UAA @ Landing Zones MG. Inherited from row 3 (Globaris parent).
# Retained explicitly for auditability; safe to omit. Comment kept if omitted.
resource "azurerm_role_assignment" "oidc_uaa_landingzones" {
  scope                            = local.landingzones_mg_id
  role_definition_name             = "User Access Administrator"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 5 — Contributor on each of the 5 subscriptions: create/destroy all resources.
resource "azurerm_role_assignment" "oidc_contributor_subs" {
  for_each                         = local.cicd_subscription_ids
  scope                            = "/subscriptions/${each.value}"
  role_definition_name             = "Contributor"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}

# Row 6 — UAA on each of the 5 subscriptions: create/delete role assignments the
# IaC makes INSIDE the subs (guardrails MI, red-team MI, KV/Storage data-plane).
resource "azurerm_role_assignment" "oidc_uaa_subs" {
  for_each                         = local.cicd_subscription_ids
  scope                            = "/subscriptions/${each.value}"
  role_definition_name             = "User Access Administrator"
  principal_id                     = azuread_service_principal.oidc.object_id
  skip_service_principal_aad_check = true
}
```

Row 7 (`azurerm_role_assignment.oidc_storage_blob_contributor`) is already in `identity.tf` — **leave it
untouched**.

Use `role_definition_name` (string) as above for readability; if the reviewer prefers GUIDs, switch to
`role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/<GUID>"` using the GUIDs in §1.
Names are stable built-ins, so either is acceptable.

### 3d. Header comment

Update the `bootstrap/identity.tf` file header: change the "RBAC scope: Owner at Tenant Root MG (temporary…)"
line to reference ADR-021 and the scoped set. Note OQ-008 is resolved-by-design.

---

## 4. Validation (read this — it is the whole point)

- `terraform validate` / `plan` **cannot** prove the grants are sufficient. RBAC gaps only appear as
  `AuthorizationFailed` (HTTP 403) at `apply`/`destroy` time.
- The **only** real test: run `deploy.yml target=all` (apply all 10 roots) then `teardown.yml target=all`
  (destroy all 10 roots) with the SP holding exactly this set, on the POC tenant.
- If any step 403s: identify the exact operation, add the **precise** missing role/scope, and re-run. **Never**
  revert to Owner to "make it pass" — that re-opens OQ-008.
- Bootstrap is a re-apply (ADR-005 one-time-apply layer); coordinate with the MG-ordering note in §3b.

## 5. Out of scope (do not touch)

- `azuread_application` Graph/API permissions — directory permissions, not ARM RBAC.
- The state backend resources in `bootstrap/main.tf`.
- `deploy.yml` / `teardown.yml` — no workflow change needed for OQ-008.
