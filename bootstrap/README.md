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
| Global Administrator or Privileged Role Administrator on Entra ID | Required to create app registrations and assign Owner at Tenant Root MG |

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
# Edit terraform.tfvars — fill in tenant_id, management_subscription_id,
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

In **Settings → Environments**, create an environment named **`production`** and add a required reviewer. The `apply-on-merge.yml` workflow references this environment gate.

---

## What was created and why

### Resource Group `rg-tfstate-mgmt-eus2-001`

Hosts all bootstrap resources in the Management subscription (`eastus2`).

### Key Vault `kv-tfstate-<suffix>-001`

Dedicated to the state backend CMK (ADR-004). RBAC-authorised (no access policies). Soft-delete (90 days) and purge protection enabled — this KV cannot be accidentally destroyed.

### Storage Account `sttfstate<suffix>001`

- **GZRS** replication — geo-redundant, zone-redundant within primary region
- **CMK encryption** via the bootstrap Key Vault key
- **Blob versioning** enabled — previous state versions recoverable for 14 days
- **Shared access keys disabled** — only Entra ID (RBAC) authentication
- **Immutable policy** on the `tfstate` container — 7-day unlocked time-based retention (demonstrates WORM; see [deviations](#deviations))
- **Network rules** — `Deny` by default; GitHub Actions IPs + deployer IP allowed (temporary until Section 8 adds a Private Endpoint)

### OIDC Service Principal `sp-alz-poc-cicd`

- **No client secret** — workload identity federation only
- Two federated credentials: `main` branch pushes and `pull_request` events
- **Owner at Tenant Root MG** (ADR-006) — scoped down at Section 12 per OQ-008

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
terraform import azurerm_storage_account.tfstate /subscriptions/<mgmt-sub>/resourceGroups/rg-tfstate-mgmt-eus2-001/providers/Microsoft.Storage/storageAccounts/sttfstate<suffix>001
terraform import azurerm_key_vault.tfstate /subscriptions/<mgmt-sub>/resourceGroups/rg-tfstate-mgmt-eus2-001/providers/Microsoft.KeyVault/vaults/kv-tfstate-<suffix>-001
terraform import random_string.suffix <suffix>
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
