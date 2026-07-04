# bootstrap/ — Chicken-and-Egg Layer

This is the **one-time manual bootstrap** for the ALZ POC. It creates:

- Remote state backend (Resource Group + Key Vault CMK + Storage Account in the Management subscription)
- OIDC service principal for GitHub Actions (no client secrets — federated credentials only)

**This layer uses local Terraform state.** The `terraform.tfstate` file is gitignored and must never be committed. If it is lost, see [Recovery](#recovery) below.

All subsequent root modules (`platform/`, `landing-zones/`, etc.) use the remote state backend created here.

---

## Prerequisites

| Requirement | How to satisfy |
| --- | --- |
| Azure CLI ≥ 2.x | `az --version` |
| Terraform ≥ 1.9 | `terraform --version` |
| Owner on Management subscription | Required to create RGs and role assignments |
| Global Administrator or Privileged Role Administrator on Entra ID | Required to create app registrations and assign roles at Tenant Root MG / MG / subscription scope (ADR-021) |

---

## One-Time Manual Apply Procedure

### 1. Authenticate

```bash
az login
az account set --subscription "<Management Subscription ID>"
```

Verify you are in the right tenant:

```bash
az account show --query "{sub:id, tenant:tenantId}" -o table
```

### 2. Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: fill in tenant_id; ALL FIVE subscription IDs
# (management, connectivity, identity, security, landingzones per OQ-008 / ADR-021);
# github_org, github_repo, and ip_allow_list.
```

Get your public IP for `ip_allow_list`:

```bash
curl -s https://api.ipify.org
```

Get current GitHub Actions runner IP ranges:

```bash
curl -s https://api.github.com/meta | jq '.actions[]'
```

### 3. Init and apply

```bash
cd bootstrap/
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

The apply takes approximately **5–8 minutes** (Key Vault, RBAC propagation sleep, Storage Account CMK). This is normal.

### 4. Capture outputs

After a successful apply, copy the outputs:

```bash
terraform output -json
```

| Output | Where to use it |
| --- | --- |
| `resource_group_name` | `envs/poc.backend.hcl` → `resource_group_name` |
| `storage_account_name` | `envs/poc.backend.hcl` → `storage_account_name` |
| `storage_container_name` | `envs/poc.backend.hcl` → `container_name` (always `tfstate`) |
| `oidc_client_id` | GitHub repo variable → `AZURE_CLIENT_ID` |
| `oidc_tenant_id` | GitHub repo variable → `AZURE_TENANT_ID` |
| `management_subscription_id` | GitHub repo variable → `AZURE_SUBSCRIPTION_ID` |

### 5. Update envs/poc.backend.hcl

Replace the `TODO` markers in `envs/poc.backend.hcl` with the real output values.

### 6. Configure the GitHub repository

In your GitHub repository → **Settings → Secrets and variables → Actions → Variables** (not secrets — OIDC uses no secrets):

| Variable name | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | `oidc_client_id` output |
| `AZURE_TENANT_ID` | `oidc_tenant_id` output |
| `AZURE_SUBSCRIPTION_ID` | `management_subscription_id` output |

In **Settings → Environments**, create TWO environments, each with at least one required reviewer:

- **`production`** gates the apply jobs in `deploy.yml` (ADR-019 / OQ-013).
- **`production-destroy`** gates the destroy job in `teardown.yml`.

(The old `apply-on-merge.yml` was removed; deploys are explicit via `deploy.yml`, LESSON 17.)

---

## What was created and why

### Resource Group `rg-tfstate-mgmt-eus2-001`

Hosts all bootstrap resources in the Management subscription (`eastus2`).

### Key Vault `kv-globaris-tfstate-01`

Dedicated to the state backend CMK (ADR-004). RBAC-authorised (no access policies). Soft-delete (90 days) and purge protection enabled — this KV cannot be accidentally destroyed.

### Storage Account `stglobaristfstate01`

Deterministic name: `st<org_prefix>tfstate<instance>` (no random suffix). Global uniqueness relies on the distinctive org prefix; bump `local.instance` if a name is ever taken.

- **GZRS** replication — geo-redundant, zone-redundant within primary region
- **CMK encryption** via the bootstrap Key Vault key
- **Blob versioning** enabled — previous state versions recoverable for 14 days
- **Shared access keys disabled** — only Entra ID (RBAC) authentication
- **Immutable policy** on the `tfstate` container — 7-day unlocked time-based retention (demonstrates WORM; see [deviations](#deviations))
- **Network rules** — `Deny` by default; GitHub Actions IPs + deployer IP allowed (temporary until Section 8 adds a Private Endpoint)

### OIDC Service Principal `sp-alz-poc-cicd`

- **No client secret** — workload identity federation only
- Federated credentials: `main` branch pushes, `pull_request` events, and the
  `production` / `production-destroy` Environment subjects (ADR-019)
- **Least-privilege scoped RBAC (ADR-021 — resolves OQ-008).** Tenant-root Owner is
  REMOVED. The SP holds:
  - **Management Group Contributor** @ Tenant Root Group (MG create/delete + subscription move)
  - **Resource Policy Contributor** + **User Access Administrator** @ Globaris MG
  - **User Access Administrator** @ Landing Zones MG (explicit; inherited from Globaris)
  - **Contributor** + **User Access Administrator** @ each of the 5 subscriptions (`for_each`)
  - **Storage Blob Data Contributor** @ state Storage Account (unchanged)

> **Sufficiency is proven only by a live run.** `terraform validate`/`plan` cannot prove
> the grants are enough — RBAC gaps surface as `AuthorizationFailed` (HTTP 403) at
> `apply`/`destroy`. The only real test is a CI `deploy.yml target=all` apply followed by
> `teardown.yml target=all` destroy with the SP holding exactly this set. If any step 403s,
> add the **precise** missing role/scope and re-run — **never revert to Owner** (that re-opens OQ-008).

---

## Bootstrap ordering — MG-scoped grants (ADR-021)

The scoped RBAC set in [ADR-021](../DECISIONS.md#adr-021-oidc-sp-least-privilege-scope-down--replace-tenant-root-owner-with-a-scoped-role-set-refinessupersedes-adr-006)
includes role assignments scoped at the **Globaris** and **Landing Zones** management
groups. Those MGs do **not** exist at the first bootstrap apply — `platform/management-groups`
creates them later. A role assignment whose `scope` is an MG resource ID still requires
the MG to exist at apply time, so the MG-scoped grants (Resource Policy Contributor +
User Access Administrator) will **403 on a fresh tenant**.

**Apply sequence on a fresh tenant:**

1. **First bootstrap apply** — apply everything EXCEPT the three MG-scoped grants (rows 2/3/4),
   whose target MGs don't exist yet. This `-target` pass creates the state backend, the SP +
   federated creds, and the grants that bind immediately (Tenant-Root MG Contributor + the
   per-sub Contributor/UAA), which is all step 2 needs:

   ```bash
   terraform apply \
     -target=azuread_service_principal.oidc \
     -target=azuread_application_federated_identity_credential.main_branch \
     -target=azuread_application_federated_identity_credential.pull_request \
     -target=azuread_application_federated_identity_credential.env_production \
     -target=azuread_application_federated_identity_credential.env_production_destroy \
     -target=azurerm_role_assignment.oidc_mg_contributor_tenant_root \
     -target=azurerm_role_assignment.oidc_contributor_subs \
     -target=azurerm_role_assignment.oidc_uaa_subs \
     -target=azurerm_role_assignment.oidc_storage_blob_contributor \
     -target=azurerm_role_assignment.deployer_storage_blob_contributor
   ```
   (The state RG/SA/KV are pulled in automatically as dependencies.) Alternatively, run a plain
   `terraform apply` and accept that rows 2/3/4 error with a scope-not-found — everything else is
   created — then proceed; or let a human Owner perform step 2.
2. **Create the MG tree** — run `platform/management-groups` under a principal that can
   create MGs at the Tenant Root Group. The SP's row-1 grant (Management Group Contributor)
   covers this once it is bound; otherwise use a human Owner for the one-time creation.
3. **Re-apply bootstrap** — `terraform apply` again. Now that `globaris` and `landingzones`
   exist, rows 2/3/4 bind cleanly. This is the steady-state set.

Bootstrap is a re-applyable one-time layer (ADR-005) — re-running is expected and idempotent.

---

## Deviations

| Deviation | Reason | Remediation |
| --- | --- | --- |
| Storage Account allows public network access | Management VNet does not exist yet (Section 8) | Section 8 adds Private Endpoint; `network_rules.default_action` stays `Deny` but IP rules removed |
| Immutability policy `locked = false` | `locked = true` prevents blob overwrites, breaking active Terraform state | Flip to `true` only on a decommissioned/archived state container |

---

## Recovery

If the local `terraform.tfstate` is lost:

1. Re-run `terraform init` (initialises local backend, no remote state needed).
2. Import each resource manually:

```bash
# Example imports — adjust resource IDs to match your deployment
terraform import azurerm_resource_group.tfstate /subscriptions/<mgmt-sub>/resourceGroups/rg-tfstate-mgmt-eus2-001
terraform import azurerm_storage_account.tfstate /subscriptions/<mgmt-sub>/resourceGroups/rg-tfstate-mgmt-eus2-001/providers/Microsoft.Storage/storageAccounts/stglobaristfstate01
terraform import azurerm_key_vault.tfstate /subscriptions/<mgmt-sub>/resourceGroups/rg-tfstate-mgmt-eus2-001/providers/Microsoft.KeyVault/vaults/kv-globaris-tfstate-01
# ... import remaining resources (identity, role assignments, etc.)
terraform import azuread_application.oidc <application-object-id>
terraform import azuread_service_principal.oidc <sp-object-id>
```

3. Run `terraform plan` to verify the imported state matches reality. Fix any diffs before applying.

---

## Re-running after changes

This module is designed for infrequent changes. If you need to update variables (e.g., add an IP to `ip_allow_list`):

```bash
cd bootstrap/
terraform plan -var-file=terraform.tfvars -out=tfplan
terraform apply tfplan
```

Terraform will update only the changed resources (typically just `azurerm_storage_account.tfstate` for IP list changes).
