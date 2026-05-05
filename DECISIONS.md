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

- **Date:** TBD
- **Section:** 2
- **Status:** Proposed
- **Decision makers:** user, claude

**Context:**
The ALZ pattern can be implemented via (a) the official `Azure/avm-ptn-alz` Terraform pattern module, (b) the older `Azure/caf-enterprise-scale` module, or (c) hand-rolled MG and policy resources.

**Decision:**
Use `Azure/avm-ptn-alz` if a stable version (≥ 0.x) exists at the time Section 2 is built. Fall back to `caf-enterprise-scale` only if the AVM pattern module is not yet GA. Verify at session start.

**Alternatives considered:**
- Hand-rolled — rejected: defeats the purpose of using AVM and adds maintenance burden
- `caf-enterprise-scale` only — rejected for primary path: AVM is the forward-looking standard

**Consequences:**
- Positive: aligned with current Microsoft guidance, less custom code to maintain
- Negative: AVM pattern modules are newer and may have rough edges
- Follow-ups: re-verify module version on the day Section 2 is built

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
