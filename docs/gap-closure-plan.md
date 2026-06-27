# Gap-Closure Plan — ALZ Reference Fidelity (G1–G6)

> **Author:** Cloud Solutions Architect · **Date:** 2026-06-25 · **Status:** Plan of record (ADR-016)
> **Source gap list:** `ARCHITECTURE.md` → "ALZ Reference Architecture Fidelity Map" (vs Microsoft ALZ
> Hub & Spoke diagram 2026-04-02).
> **Per-gap decisions:** `DECISIONS.md` ADR-010 (G1) · ADR-011 (G2) · ADR-012 (G4) · ADR-013 (G3) ·
> ADR-014 (G5) · ADR-015 (G6) · ADR-016 (this sequence).
>
> This is a **plan**, not an implementation. The cloud-engineer and devsecops-engineer execute it
> **one wave per session** under the code-reviewer gate. Every module/version below was verified on
> `registry.terraform.io` on **2026-06-25**; the engineer must re-confirm against the provider pin in the
> target directory before writing, and mark `# UNVERIFIED:` on anything that cannot be confirmed at write
> time (CLAUDE.md rules 4–5).

---

## Roles (hand-off contract)

| Role | Owns in this plan |
|------|-------------------|
| **cloud-engineer** | Module composition + `azurerm` resources in `platform/`, `landing-zones/`; variables/outputs; local validation (`terraform fmt`/`validate`). |
| **devsecops-engineer** | `bootstrap/` + MG wiring, OIDC scope, CI `TF_VAR`/secret plumbing, policy/Guest-Config assignments, security posture. |
| **code-reviewer** | Per-wave review + merge gate (`docs/review-gate.md`). |

Hand-off order **within each wave:** architect (done — this plan) → cloud-engineer → devsecops-engineer →
code-reviewer.

---

## Verified module / resource inventory

| Construct | Module / resource | Version (verified 2026-06-25) | Used by |
|-----------|-------------------|-------------------------------|---------|
| Bastion | (flag on existing) `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet/azurerm` | **0.17.1** (already in state) | G6 |
| Backup vault | `Azure/avm-res-recoveryservices-vault/azurerm` | **1.1.3** (match corp-a2 pin; latest 1.1.11) | G4, G1 |
| Identity VNet | `Azure/avm-res-network-virtualnetwork/azurerm` | **0.17.1** (repo pin; latest 0.19.0) | G1 |
| Entra Domain Services | native `azurerm_active_directory_domain_service` (no AVM module — registry 404) | provider `azurerm ~> 4.71` (API 2021-05-01) | G1 |
| Compute Gallery + image def | `Azure/avm-res-compute-gallery/azurerm` | **0.2.0** (creates gallery **and** image definitions via `shared_image_definitions`) | G2 |
| Guest Configuration | built-in Azure Policy initiative (machineConfiguration baseline) — assignment via `azurerm_management_group_policy_assignment` | n/a (built-in) | G2 |
| DDoS plan | `Azure/avm-res-network-ddosprotectionplan/azurerm` | **0.3.0** | G3 (flag-gated) |
| Sandbox/Online subs | (conditional) `azurerm_subscription` assoc. **or** `avm-ptn-lz-vending` | TBD per OQ-010 | G5 (conditional) |

> **Anti-hallucination note:** `avm-res-aad-domainservice` does **not** exist (registry 404). G1's Entra DS
> uses the native `azurerm_active_directory_domain_service` resource with a `# DEVIATION:` comment. The
> native resource is current and not deprecated (verified against the provider docs source 2026-06-25).

---

## Execution sequence (5 waves)

```
Wave 1  G6 Bastion ─────────────┐
Wave 2  G4 corp-a1 RSV ─────────┤ (1 & 2 independent — may run in either order / parallel)
                                 │
Wave 3  G1 Identity (Entra DS) ──┤ needs: primary hub (peering) from connectivity ✅ already deployed
                                 │        + Bastion (Wave 1) for DC/mgmt VM access (soft dep)
Wave 4  G2 Compliant VM template │ needs: G4 backup-vault pattern (ADR-012) + FinOps tag init (ADR-008) ✅
                                 │
Wave 5  G3 DDoS (cond. OQ-009) ──┘ + G5 Sandbox/Online subs (cond. OQ-010)
```

Hard dependencies are called out per wave below. Waves 1–4 have **no blocking open question**; Wave 5 is
gated on OQ-009 (DDoS spend) and OQ-010 (real subscriptions).

---

### Wave 1 — G6: Azure Bastion in the primary hub  · **CLOSE** (ADR-015)

- **Owning role:** cloud-engineer (module config) — devsecops only if a CI var is needed (none expected).
- **Section slot:** 8 (connectivity).
- **What:** Flip `enabled_resources.bastion = true` on the **primary** hub in
  `platform/connectivity/main.tf`'s `avm-ptn-alz-connectivity-hub-and-spoke-vnet` block (v0.17.1, already in
  state); add the matching `bastion` config sub-block (Standard SKU) and an `AzureBastionSubnet` /26 prefix
  to the hub subnet locals (`platform/connectivity/main.tf` locals near `hub_primary_*_prefix`). Secondary
  hub stays `bastion = false`.
- **Module(s)/resources:** none new — existing pattern module flag + config.
- **Dependencies:** none (the hub VNet is already deployed). Must land **before** Wave 3 so Entra DS DC /
  any management VM has no-public-IP access. Soft dependency only — Wave 3 can deploy first and add Bastion
  after, but ordering this first is cleaner.
- **Pre-write check:** confirm the v0.17.1 module's `bastion` input shape (subnet prefix vs subnet object;
  SKU key name) before writing — the engineer reads the module's variables doc; mark `# UNVERIFIED:` if the
  shape can't be confirmed.
- **Cost delta:** ~**+$140/mo** (Standard Bastion instance + its Standard public IP).
- **Acceptance:** `terraform plan` shows the Bastion host + `AzureBastionSubnet` added to the primary hub
  only; no change to the secondary hub.

---

### Wave 2 — G4: corp-a1 backup vault (parity with corp-a2)  · **CLOSE** (ADR-012)

- **Owning role:** cloud-engineer.
- **Section slot:** 9 (landing zones).
- **What:** Add a Recovery Services Vault to corp-a1 in `landing-zones/corp-a1/` (new `backup.tf` or in
  `main.tf`), in `rg-corp-a1-shared`, using **the same module + pin as corp-a2**:
  `Azure/avm-res-recoveryservices-vault/azurerm` **v1.1.3**, storage mode **ZoneRedundant** (primary stays
  in-region; corp-a2 keeps GeoRedundant). Include a default Azure Backup policy.
- **Module(s):** `Azure/avm-res-recoveryservices-vault/azurerm` **1.1.3** (verified; matches corp-a2 to
  avoid cross-spoke skew — a later uplift to 1.1.11 across **both** spokes is a separate change).
- **Dependencies:** none (corp-a1 RGs already exist). Fully parallel to Wave 1.
- **Cost delta:** ~**+$0–10/mo** (vault free; cost is protected-instance/storage, near-zero until items
  enrol).
- **Acceptance:** RSV present in corp-a1 with the same module version as corp-a2; `ARCHITECTURE.md` fidelity
  row F flips corp-a1 backup from ❌ to ✅.

---

### Wave 3 — G1: Identity subscription domain services (Entra DS)  · **CLOSE** (ADR-010)

> **Reverses OQ-002.** Highest-value gap. This is a full section's worth of IaC — its own session.

- **Owning roles:** cloud-engineer (VNet + Entra DS + RSV + peering); devsecops-engineer (MG/sub wiring is
  already done — `identity` MG → `var.identity_subscription_id` exists; devsecops adds any CI `TF_VAR` for
  the new vars and confirms the OIDC SP can create the resource in the Identity sub).
- **Section slot:** 8 (Identity subscription — completes the platform pillar).
- **Manual operator prerequisite (NOT Terraform):** create the **Domain Controller Services** enterprise
  application/service principal and an **`AAD DC Administrators`** group in the tenant before apply (Entra DS
  requires both; Terraform cannot create the DS publisher SP). Document in `platform/identity/README.md` and
  the runbook.
- **What (in `platform/identity/`, which today holds only CA/PIM policies):**
  1. **Resource group(s)** in the Identity subscription (`rg-identity-network-*`, `rg-identity-aadds-*`).
  2. **Identity VNet** — `Azure/avm-res-network-virtualnetwork/azurerm` **0.17.1**; dedicated Entra DS
     subnet + NSG with the Microsoft-mandated inbound rules; peer to the **primary hub** (ADR-009).
  3. **Entra Domain Services** — native `azurerm_active_directory_domain_service` (`# DEVIATION:` no AVM
     module), **Standard SKU**, `domain_name = var.identity_domain_name`, `initial_replica_set` bound to the
     Entra DS subnet. New vars: `identity_mode` (default `"entra-ds"`; also accepts `"ad-ds"`, `"none"`),
     `identity_domain_name`, `identity_vnet_address_space`.
  4. **Recovery Services Vault** for the identity sub — same module/pin as G4 (1.1.3), for future
     DC/management VMs.
  5. Gate everything on `var.identity_mode != "none"` (retain the toggle; `ad-ds` path is an alternative
     mode for a self-managed-DC demo — build the `entra-ds` path now, leave `ad-ds` as a documented branch).
- **Module(s)/resources:** `avm-res-network-virtualnetwork` **0.17.1**; native
  `azurerm_active_directory_domain_service`, `azurerm_subnet`, `azurerm_network_security_group`,
  `azurerm_virtual_network_peering` (both directions to primary hub); `avm-res-recoveryservices-vault`
  **1.1.3**.
- **Dependencies:** **primary hub VNet** (already deployed) for peering; **Bastion** (Wave 1) for
  no-public-IP management access (soft). The MG→Identity-sub mapping already exists.
- **Pre-write check:** confirm `azurerm_active_directory_domain_service` argument shape (esp.
  `initial_replica_set`, `sku`, `notifications`) against the provider pin in `platform/identity/`; verify
  the Entra DS subnet NSG rule set against current Microsoft network-considerations doc; mark `# UNVERIFIED:`
  if the pin predates the schema.
- **Cost delta:** ~**+$110/mo** (Entra DS Standard, single replica set) + small VNet/peering egress.
  Biggest single line in the plan.
- **Acceptance:** Identity sub now non-empty; `ARCHITECTURE.md` row "Identity sub — DCs or Entra DS"
  flips ❌ → ✅; OQ-002 marked superseded → `entra-ds`.

---

### Wave 4 — G2: Compliant VM template  · **CLOSE** (ADR-011)

- **Owning roles:** cloud-engineer (gallery + image definition + backup wiring);
  devsecops-engineer (Guest Configuration / machineConfiguration policy initiative assignment at the
  Landing Zones MG + any remediation identity).
- **Section slot:** 8 (new platform component, gallery lives in Management sub) + 12 (policy assignment).
- **What:**
  1. **Compute Gallery + image definition** — new `platform/management/compute-gallery.tf`:
     `Azure/avm-res-compute-gallery/azurerm` **0.2.0**, one **Linux** image definition (Ubuntu 24.04 gen2,
     matching the synthetic workload distro) passed via the module's `shared_image_definitions` map. The
     gallery is a shared platform asset → Management subscription (alongside the platform LAW/Automation).
  2. **Guest Configuration** — devsecops assigns the **built-in** machineConfiguration baseline initiative
     (\"machines should meet requirements for the Azure compute security baseline\") at the **Landing Zones
     MG** via `azurerm_management_group_policy_assignment` + a system-assigned identity for remediation.
     `# DEVIATION:` full custom DSC authoring is out of POC scope — the built-in audit initiative is the
     maintainable substitute.
  3. **Backup policy** — provided by the G4 / corp-a1 RSV (ADR-012); no new vault. **Tag enforcement** —
     reuse the FinOps tag initiative at Globaris root (ADR-008); no new tag policy.
- **Module(s)/resources:** `avm-res-compute-gallery/azurerm` **0.2.0**;
  `azurerm_management_group_policy_assignment` (built-in initiative). No image *version* baked by default
  (gallery ships empty of versions — see consequence in ADR-011).
- **Dependencies:** **G4** establishes the backup-vault pattern this references; **ADR-008** tag initiative
  already at root. No hard dep on G1/G6.
- **Pre-write check:** confirm the `avm-res-compute-gallery` v0.2.0 `shared_image_definitions` input schema
  (key names for `identifier` publisher/offer/sku, `os_type`, `hyper_v_generation`); confirm the built-in
  machineConfiguration initiative's definition ID on azadvertizer before assignment.
- **Cost delta:** ~**+$0–2/mo** (empty gallery + image definition cost ~nothing; storage only once versions
  are baked; policy assignment is free).
- **Acceptance:** gallery + Linux image definition exist in Management sub; machineConfiguration initiative
  assigned at Landing Zones MG; `ARCHITECTURE.md` row G (compliant VM template) flips ❌ → ✅.
- **Optional follow-up (not this wave):** add an Azure Image Builder template to bake a version into the
  definition; out of POC scope by ADR-011.

---

### Wave 5 — G3 DDoS + G5 Sandbox/Online subs  · **CONDITIONAL** (ADR-013 / ADR-014)

> Gated on **OQ-009** (DDoS spend) and **OQ-010** (real subscriptions). Do not start the active portions
> until the user answers. The DDoS *construct* can be built (flag-off) regardless.

**G3 — DDoS Network Protection (ADR-013):**
- **Owning role:** cloud-engineer.
- **Section slot:** 8 (connectivity).
- **What:** Add `Azure/avm-res-network-ddosprotectionplan/azurerm` **0.3.0** behind
  `var.enable_ddos_protection` (**default false**); when true, create the plan and wire
  `ddos_protection_plan` onto the hub VNet + the online-p1 spoke VNet.
- **Dependencies:** hub + online-p1 VNets (deployed). No dep on other waves.
- **Cost delta:** **$0** while flag false; ~**+$2,944/mo** if OQ-009 sets it true.
- **Acceptance:** with flag false, `plan` shows no DDoS resources but the construct exists and is
  version-pinned; `ARCHITECTURE.md` DDoS row → "pre-staged, disabled (var.enable_ddos_protection)".

**G5 — Sandbox + Online subscriptions (ADR-014):**
- **Owning role:** devsecops-engineer (sub association / vending + MG wiring) → cloud-engineer (rebind
  `online-p1` provider/sub).
- **Section slot:** 9 / 12.
- **Default (recommended):** **keep collapsed (deviation)** — no work; reviewer accepts ADR-014.
- **If OQ-010 = "provision real subs":** bind `online-p1` (and a sandbox RG-set) to two new subscription IDs
  under the existing Online/Sandbox MG nodes — via supplied sub IDs **or** `avm-ptn-lz-vending` if an
  EA/MCA enrollment-account ID is provided. ADR-014 is then superseded.
- **Cost delta:** small per-sub idle baseline if provisioned; **$0** if kept collapsed.

---

## Cost summary (idle delta vs today)

| Wave | Gap | Close type | ~Idle $/mo delta |
|------|-----|-----------|------------------|
| 1 | G6 Bastion | CLOSE | +140 |
| 2 | G4 corp-a1 RSV | CLOSE | +0–10 |
| 3 | G1 Entra DS + identity VNet + RSV | CLOSE | +110 |
| 4 | G2 Compute Gallery + Guest Config | CLOSE | +0–2 |
| 5 | G3 DDoS | CONDITIONAL (flag-off default) | +0 (or +2,944 if enabled) |
| 5 | G5 Sandbox/Online subs | CONDITIONAL (keep-collapsed default) | +0 (or small if provisioned) |
| | **Total, default path (Waves 1–4 + conditionals off)** | | **≈ +$255–265/mo** |

> This pushes the platform's idle cost from ADR-003's ~$80–150/mo to ~$340–415/mo, driven by Bastion and
> Entra DS. If the user wants to stay near the original idle target, the two levers are: **(a)** ship
> Bastion as deploy-on-demand rather than always-on, and/or **(b)** select `identity_mode = "ad-ds"`
> (two B2s DCs ~$60/mo) instead of Entra DS. Both are documented alternatives in ADR-010/ADR-015 — raise
> with the user if the idle ceiling is hard.

---

## Per-wave reviewer-gate checklist (code-reviewer)

For every wave: module/version pinned and registry-verified · `for_each` not `count` · every resource
tagged from `local.common_tags` · `# DEVIATION:`/`# UNVERIFIED:` comments present where this plan calls for
them · `terraform fmt -recursive` + `terraform validate` clean · `ARCHITECTURE.md` fidelity row updated ·
`WORKLOG.md` session entry + `DECISIONS.md` reference. Wave 5 additionally: OQ-009/OQ-010 answered before
any *active* (cost-bearing) resource is enabled.
