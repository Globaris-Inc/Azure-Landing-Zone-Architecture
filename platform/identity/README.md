# platform/identity

Identity subscription root module. Two concerns live here:

1. **Zero Trust governance** (Section 5) — Conditional Access policies + PIM eligible
   role assignments (`main.tf`, `pim.tf`). Tenant/MG-scoped via the `azuread` provider
   and the management-anchored default `azurerm` provider.
2. **Identity subscription domain services** (Section 8 — G1 / Gap-Closure Wave 3 /
   ADR-010) — the identity VNet, **Microsoft Entra Domain Services**, and a Recovery
   Services Vault (`identity-network.tf`, `domain-services.tf`). These land in the
   **Identity subscription** via the `azurerm.identity` provider alias, and the
   hub-side return peering uses the `azurerm.connectivity` alias.

---

## identity_mode (ADR-010)

| Value | Behaviour |
|-------|-----------|
| `"entra-ds"` (default) | Builds identity VNet + NSG + **Entra Domain Services** (Standard) + RSV, peered to the primary hub. |
| `"ad-ds"` | **Documented-only branch.** Keeps the identity VNet + RSV (mode != "none") but builds **no** Entra DS resource and **no** DC VMs in this wave. Selecting it is an intentional placeholder for a future self-managed-DC build. |
| `"none"` | Identity sub left empty — no VNet / DS / RSV. Reverses to the pre-G1 posture. |

Everything is gated on `identity_mode != "none"`; the Entra DS resource is additionally
gated on `identity_mode == "entra-ds"`. Gating uses static booleans (never an unknown ID).

---

## ⚠️ Manual operator prerequisite (run BEFORE `terraform apply`)

Microsoft Entra Domain Services requires two directory objects that **Terraform cannot
create** (the DS publisher service principal is provisioned by Microsoft, not by ARM).
A tenant administrator must create both **once**, before the first apply that sets
`identity_mode = "entra-ds"`:

1. **"Domain Controller Services" enterprise application / service principal.**
   This is the Microsoft-published first-party app (app ID `2565bd9d-da50-47d4-8b85-4c97f669dc36`).
   Register its service principal in the tenant:

   ```bash
   # Idempotent — no-op if the SP already exists.
   az ad sp create --id 2565bd9d-da50-47d4-8b85-4c97f669dc36
   ```

   (Also ensure the legacy "Azure AD Domain Services" publisher SP, app ID
   `abba844e-bc0e-44b0-947a-dc74e5d09022`, exists if your tenant predates the rename.)

2. **"AAD DC Administrators" group.** Entra DS delegates administration of the managed
   domain to members of a group that **must** be named exactly `AAD DC Administrators`:

   ```bash
   az ad group create \
     --display-name "AAD DC Administrators" \
     --mail-nickname "AADDCAdministrators"
   # Then add at least one administrator:
   az ad group member add --group "AAD DC Administrators" --member-id <admin-object-id>
   ```

If either object is missing, the `azurerm_active_directory_domain_service` apply fails.
This step is also captured in the operator runbook.

---

## Inputs added by Wave 3 (G1)

| Variable | Purpose |
|----------|---------|
| `identity_subscription_id` | Anchor sub for VNet / Entra DS / RSV (`azurerm.identity`). |
| `connectivity_subscription_id` | Hub-side return peering (`azurerm.connectivity`). |
| `identity_mode` | `entra-ds` (default) / `ad-ds` / `none`. |
| `identity_domain_name` | FQDN for the managed domain (required when `entra-ds`). |
| `identity_vnet_address_space` | Identity VNet CIDR (default `10.2.0.0/24`). |
| `identity_location` | Region (default `eastus2`, co-located with the primary hub). |
| `primary_hub_vnet_id` / `_name` / `primary_hub_rg_name` | Primary hub peering targets. |
| `identity_rsv_storage_mode_type` | RSV redundancy (default `ZoneRedundant`). |

Hub peering values come from `platform/connectivity` outputs (`primary_hub_vnet_id`,
`primary_hub_vnet_name`) and the deterministic hub RG name
(`rg-connectivity-primary-<org>-<env>`), the same inputs the corp-a1 spoke consumes.
