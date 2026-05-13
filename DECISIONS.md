# DECISIONS.md — Architectural Decision Records

> Append-only log of architectural decisions made during the build.
> Each ADR follows the template below. Once written, an ADR is never edited — if a decision is reversed, write a new ADR that supersedes it.

---

## Template

```
### ADR-XXX: [Short Title]

- **Date:** YYYY-MM-DD
- **Section:** [N from PROMPT.md]
- **Status:** Proposed / Accepted / Superseded by ADR-YYY
- **Decision makers:** [user / claude]

**Context:**
[What's the situation that requires a decision?]

**Decision:**
[What was decided, in one or two sentences.]

**Alternatives considered:**
- [Alt A] — rejected because [reason]
- [Alt B] — rejected because [reason]

**Consequences:**
- Positive: [...]
- Negative / trade-offs: [...]
- Follow-ups required: [...]
```

---

## ADRs

<!-- Newest at the top. -->

### ADR-008: Tag governance via built-in Azure Policy Modify initiatives (no AVM, no custom policy JSON)

- **Date:** 2026-05-12
- **Section:** 7
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
Section 7 requires Modify + DINE tag policies on every resource group for 8 mandatory tags, with tag inheritance to child resources. Options were: (A) custom policy definition JSON per tag, (B) built-in Azure Policy definitions composed into a custom initiative, or (C) AVM module.

**Decision:**
Use two built-in Azure Policy definitions composed into a custom `azurerm_policy_set_definition` via `dynamic "policy_definition_reference"` blocks:

- `d157c373-a6c4-483d-aaad-570756956268` — "Add or replace a tag on resource groups" (Modify, RG scope)
- `cd3aa116-8754-49c9-a813-ad46512ece54` — "Inherit a tag from the resource group" (Modify, resource scope)

Both IDs confirmed on azadvertizer.net 2026-05-12. The initiative is scoped to the `globaris` root MG and assigned there with a system-assigned managed identity. The remediation identity receives `Contributor` at the root MG scope.

**Alternatives considered:**

- Custom policy definition JSON per tag — rejected: 16 custom policy definitions (8 tags × 2 effects) creates excessive state surface and maintenance overhead for a POC.
- AVM module for policy — rejected: no `avm-res-authorization-policysetdefinition` module confirmed on registry.terraform.io 2026-05-12.
- `ea3f2387-9b95-492a-a190-fcdc54f7b070` ("Inherit a tag from the resource group if missing") instead of `cd3aa116` — rejected: the "if missing" variant does not overwrite existing incorrect tag values; `cd3aa116` always enforces the correct value from the parent RG.

**Consequences:**

- Positive: no custom policy JSON to maintain; built-in policies are kept current by Microsoft.
- Negative: `CreatedDate` default value is static ("1970-01-01") — the Modify effect cannot use a dynamic `utcNow()` expression. Teams must set `CreatedDate` manually on their RGs.
- Follow-ups: Section 9 landing zone modules should set `CreatedDate` on their RGs at creation time via the `tags` block.

---

### ADR-007: Custom Globaris root management group — override standard ALZ root id

- **Date:** 2026-05-06
- **Section:** 2
- **Status:** Accepted
- **Decision makers:** claude (structural), user (naming)

**Context:**
The `avm-ptn-alz` module loads architecture definitions from the ALZ Library. The standard `alz` architecture uses root MG id `"alz"` and display name `"Azure Landing Zones"`. The POC uses `"Globaris"` as the organisation name, requiring a custom root MG id.

**Decision:**
Create `platform/management-groups/lib/globaris.alz_architecture_definition.json` — a custom architecture definition that retains all standard ALZ archetypes (root, platform, landing_zones, management, connectivity, identity, security, corp, online, decommissioned, sandbox) but sets root id `"globaris"` and display name `"Globaris"`. The custom lib directory is passed as a second `library_references` entry to the `alz` provider.

**Alternatives considered:**
- Use standard `alz` root MG id — rejected: produces `alz` in the Azure portal hierarchy, inconsistent with organisation branding and the expected demo narrative.
- Rename via `azurerm_management_group` rename — rejected: the AVM module owns the lifecycle; external rename would create a state conflict.

**Consequences:**
- Positive: hierarchy displays as "Globaris" in Azure portal; consistent with all naming in `poc.tfvars` and `ARCHITECTURE.md`.
- Negative: a custom lib file must be maintained alongside future ALZ Library updates.
- Follow-ups: when upgrading ALZ Library ref, re-validate that standard archetype names have not changed.

---

### ADR-006: Initial OIDC SP RBAC scope — Owner at Tenant Root MG

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted (temporary; see OQ-008 for scope-down at Section 12)
- **Decision makers:** user

**Context:**
The OIDC service principal must create Management Groups, Policy assignments, role assignments, and resources across all 5 subscriptions. The granular-minimum role set cannot be computed until all sections are built.

**Decision:**
Assign `Owner` to the OIDC SP at Tenant Root Management Group scope for the duration of the POC build (Sections 10a–12). At Section 12, replace with the principle-of-least-privilege role set tracked in OQ-008.

**Alternatives considered:**

- Per-subscription Contributor + scoped UAA — rejected for now: cannot enumerate required role assignments until all resource types are known.
- Owner at subscription level per sub — rejected: Management Group operations (Section 2) require tenant-root scope.

**Consequences:**

- Positive: zero RBAC-related CI failures during build phases 2–11.
- Negative: over-privileged SP; mitigated by POC being a dedicated demo tenant and OQ-008 tracking remediation.
- Follow-ups: OQ-008 must be resolved at Section 12.

---

### ADR-005: Bootstrap layer Terraform state — local, never committed

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user

**Context:**
The bootstrap layer creates the Azure Storage Account used as remote state backend by all other layers — a chicken-and-egg situation.

**Decision:**
Bootstrap uses local Terraform state (`bootstrap/terraform.tfstate`), gitignored and never committed. Bootstrap is a one-time manual `terraform apply`. After apply, outputs are pasted into `envs/poc.backend.hcl` for all subsequent root modules.

**Alternatives considered:**

- Local state committed to `bootstrap-state/` — rejected: state files can contain sensitive values; git history is permanent.
- Azure CLI imperative bootstrap — rejected: defeats "everything as code" and creates undocumented manual state.

**Consequences:**

- Positive: simple, no circular dependency.
- Negative: bootstrap state is not backed up; if lost, `terraform import` is required (documented in `bootstrap/README.md`).
- Follow-ups: `bootstrap/terraform.tfstate*` and `bootstrap/.terraform/` added to `.gitignore`.

---

### ADR-004: State storage CMK — bootstrap dedicated Key Vault in Management sub

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user

**Context:**
PROMPT.md Section 10 requires CMK encryption for the Terraform state Storage Account. CMK requires a Key Vault not yet built in any other section.

**Decision:**
Create a dedicated Key Vault (`kv-tfstate-<suffix>-001`) in `rg-tfstate-mgmt-eus2-001` (Management subscription) as part of the bootstrap layer. The KV holds a single RSA-2048 key for Storage Account CMK. It is NOT replaced by the Security sub KV built in Section 8 — that KV is purpose-built for workload secrets.

**Alternatives considered:**

- Microsoft-managed keys now, upgrade later — rejected: PROMPT.md explicitly requires CMK; a deviation marker would persist for 6+ sessions.
- Security sub KV (built in Section 8) — rejected: blocking CMK on that dependency leaves the state SA unencrypted for 6+ sessions.

**Consequences:**

- Positive: state SA is CMK-encrypted from first `terraform apply`; no deviation markers.
- Negative: a second Key Vault alongside the future Security sub KV; adds ~$5/mo.
- Follow-ups: bootstrap KV is referenced (not replaced) when Section 8 builds the Security sub KV.

---

### ADR-003: Subscription model — Option C (4 platform subs + 1 shared LZ sub)

- **Date:** 2026-05-05
- **Section:** 10a (resolves OQ-001, unblocks Section 2)
- **Status:** Accepted
- **Decision makers:** user

**Context:**
ALZ assumes 6+ subscriptions. For a portfolio POC on a Visual Studio benefit account, options ranged from a single subscription (cheapest) to full multi-sub (most realistic).

**Decision:**
Option C: 4 platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription hosting all Landing Zones and Sandbox. The platform/workload subscription boundary — the most architecturally significant in ALZ — is real. Within-LZ sub boundaries are simulated via MG scope and Resource Group segmentation.

**Alternatives considered:**

- Full multi-sub (Option A) — rejected: Visual Studio benefit accounts are typically capped at 1–5 subs; cost compounds.
- Single sub (Option B) — rejected: collapses the platform/workload boundary; cannot demonstrate MG policy inheritance.

**Consequences:**

- Positive: 5 subscriptions feasible on VS Enterprise; MG hierarchy is real; policy at MG scope behaves correctly.
- Negative: within-LZ sub-level isolation is simulated; documented in `ARCHITECTURE.md`.
- Follow-ups: Section 2 MG hierarchy maps 5 subscription IDs to MG nodes; IDs supplied via `poc.tfvars`.

---

### ADR-002: Treat repo root as alz-poc/ — no nested subdirectory

- **Date:** 2026-05-04
- **Section:** 1
- **Status:** Accepted
- **Decision makers:** claude (structural, low-risk)

**Context:**
PROMPT.md shows `alz-poc/` as the top-level path in the directory tree. The working directory `d:\Azure POC\Azure-Architecture\` already contains the bootstrap files (CLAUDE.md, PROMPT.md, WORKLOG.md, etc.) at its root. Two options: (a) treat the current directory as the repo root and create all subdirectories directly here, or (b) create a nested `alz-poc/` subdirectory inside the existing repo.

**Decision:**
Treat `d:\Azure POC\Azure-Architecture\` as the repo root (equivalent to `alz-poc/`). All directories from the PROMPT.md tree are created directly here, at the same level as CLAUDE.md and WORKLOG.md.

**Alternatives considered:**

- Nested `alz-poc/` subfolder — rejected: bootstrap files already live at the repo root; nesting would split Claude Code workflow files from Terraform files and break the `CLAUDE.md` read-at-start assumption.

**Consequences:**

- Positive: single working directory, no path confusion between Claude workflow files and Terraform structure
- Negative: root is slightly noisier than a clean Terraform project root (contains CLAUDE.md, WORKLOG.md etc.)
- Follow-ups: none

---

### ADR-001: Use AVM Pattern Module for ALZ Foundation

- **Date:** 2026-05-06
- **Section:** 2
- **Status:** Accepted — `Azure/avm-ptn-alz` v0.19.1 confirmed on registry.terraform.io 2026-05-06
- **Decision makers:** user, claude

**Context:**
The ALZ pattern can be implemented via (a) the official `Azure/avm-ptn-alz` Terraform pattern module, (b) the older `Azure/caf-enterprise-scale` module, or (c) hand-rolled MG and policy resources.

**Decision:**
Use `Azure/avm-ptn-alz` v0.19.1. Module confirmed published on Terraform Registry. Pinned to exact version in `platform/management-groups/providers.tf`.

**Alternatives considered:**
- Hand-rolled — rejected: defeats the purpose of using AVM and adds maintenance burden
- `caf-enterprise-scale` only — rejected for primary path: AVM is the forward-looking standard

**Consequences:**
- Positive: aligned with current Microsoft guidance, less custom code to maintain
- Negative: AVM pattern modules are newer and may have rough edges
- Follow-ups: none — ADR resolved

---


### ADR-002: Subscription Model — Platform Multi-Sub, Shared LZ Sub

- **Date:** 2026-05-05
- **Section:** 1 (foundational, surfaces in 2, 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
ALZ canonical pattern uses 6+ subscriptions. Portfolio POC on a Visual Studio benefit account needs to balance architectural fidelity with realistic provisioning constraints and idle cost.

**Decision:**
4 dedicated platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription for all Landing Zones (corp-a1, corp-a2, online-p1) and Sandbox, with separation enforced via Resource Groups, Management Group placement, and policy assignment.

**Alternatives considered:**
- Option A (full 6+ sub multi-sub): rejected for cost (~$200–500/mo idle) and provisioning complexity on Visual Studio benefits
- Option B (single sub everything): rejected because it eliminates the platform/workload boundary that ALZ exists to demonstrate

**Consequences:**
- Positive: Demonstrates the most architecturally important boundary (platform vs workload) at sub-scope; idle cost ~$80–150/mo manageable
- Negative: Corp-vs-online and individual LZ isolation is simulated via RG, not enforced at sub level — must be called out in ARCHITECTURE.md
- Follow-ups: All Terraform module designs must accept a `subscription_id` variable and not assume sub-per-LZ; policy assignments at the Landing Zones MG must compensate for the shared-sub blast radius

---


### ADR-003: Subscription Model — Platform Multi-Sub, Shared LZ Sub

- **Date:** 2026-05-05
- **Section:** Foundational (impacts 2, 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
ALZ canonical pattern uses 6+ subscriptions. Portfolio POC on a Visual Studio benefit account needs to balance architectural fidelity with realistic provisioning constraints and idle cost.

**Decision:**
4 dedicated platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription for all Landing Zones (corp-a1, corp-a2, online-p1) and Sandbox, with separation enforced via Resource Groups, Management Group placement, and policy assignment.

**Alternatives considered:**
- Option A (full 6+ sub multi-sub) — rejected: ~$200–500/mo idle cost; provisioning complexity on Visual Studio benefits
- Option B (single sub everything) — rejected: eliminates the platform/workload boundary that ALZ exists to demonstrate

**Consequences:**
- Positive: demonstrates platform/workload boundary at sub-scope; idle cost ~$80–150/mo
- Negative: corp/online and individual LZ isolation simulated via RG, not enforced at sub level — must be called out in ARCHITECTURE.md
- Follow-ups: all module designs accept `subscription_id` variable; policy assignments at Landing Zones MG must compensate for shared-sub blast radius

---

### ADR-004: State Backend CMK Approach — Dedicated Bootstrap Key Vault

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
PROMPT.md Section 10 mandates CMK encryption on the Terraform state Storage Account. CMK requires a Key Vault with an encryption key, but the security-subscription Key Vault doesn't exist until Section 8.

**Decision:**
Bootstrap a dedicated Key Vault in the Management subscription as part of 10a. This Key Vault holds only the storage encryption key plus any future bootstrap-layer secrets. It is referenced (not destroyed) by later sections.

**Alternatives considered:**
- Microsoft-managed keys — rejected: creates a deviation marker that compounds with later changes
- Use Security-sub Key Vault — rejected: that sub doesn't exist yet

**Consequences:**
- Positive: aligned with PROMPT.md from day one, no deviation marker
- Negative: Management sub now has two Key Vaults (bootstrap + future shared) — naming must distinguish them
- Follow-ups: Section 8 must NOT replace this KV; it must add a separate `kv-mgmt-shared-*` for application secrets

---

### ADR-005: Bootstrap Layer State Strategy — Local, Never Committed

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
The bootstrap layer creates the remote state backend. Its own state cannot live in the backend it creates — chicken-and-egg.

**Decision:**
Bootstrap layer uses local Terraform state. The state file is gitignored and never committed. Procedure documented as one-time manual apply in `bootstrap/README.md`. If the bootstrap state is lost, recovery path is `terraform import` against existing Azure resources.

**Alternatives considered:**
- Local state in private gitignored folder, committed encrypted — rejected: adds SOPS/git-crypt overhead for a one-time apply
- Imperative Azure CLI bootstrap — rejected: loses Terraform's state and import benefits

**Consequences:**
- Positive: simplest possible bootstrap; clear separation between "platform" and "platform of platform"
- Negative: bootstrap can drift if applied from a different machine; recovery requires `terraform import`
- Follow-ups: Section 12 acceptance criteria must include a documented bootstrap recovery drill

---

### ADR-006: Initial OIDC Service Principal RBAC Scope

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted (with deliberate scope-down deferral — see OQ-008)
- **Decision makers:** user, claude

**Context:**
The OIDC SP needs sufficient privilege to deploy ALZ — creating Management Groups, applying policies at MG scope, creating resources across 5 subscriptions. Strict least-privilege would require careful per-scope role assignments before any deployment can succeed.

**Decision:**
For Days 2–11, grant the OIDC SP **Owner at Tenant Root Management Group**. This is documented as a deliberate POC compromise. Section 12 must replace this with scoped roles before the POC is treated as "done."

**Alternatives considered:**
- Per-sub Contributor + Resource Policy Contributor + UAA from day one — rejected: would consume an entire session of RBAC plumbing before any architectural work, and would still need adjustment as new sections add new resource types
- Owner at each sub individually — rejected: doesn't grant MG-scope policy creation

**Consequences:**
- Positive: unblocks all subsequent sessions immediately; minimizes RBAC churn during build
- Negative: SP is over-privileged for the duration of the build; MUST NOT be reused in any other tenant or repurposed for a customer environment
- Follow-ups (tracked in OQ-008): Section 12 replaces with per-sub Contributor + Resource Policy Contributor at MG + UAA where role assignments are managed

---
