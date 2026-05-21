# OPEN-QUESTIONS.md — Unresolved Items

> Questions, blockers, and clarifications that need user input before work can proceed.
> Resolved questions get a `**RESOLVED:**` answer appended and stay in the file as a record.

---

## Template

```
### OQ-XXX: [Short question]

- **Raised:** YYYY-MM-DD (Session N)
- **Section:** [N from PROMPT.md]
- **Blocking:** Yes / No (and what it blocks)
- **Priority:** High / Medium / Low

**Question:**
[Full question with context]

**Options being considered:**
- A: [...]
- B: [...]

**RESOLVED YYYY-MM-DD:** [answer]
```

---

## Open Questions

<!-- Newest at the top. -->

### OQ-001: Tenant and subscription model for the POC

- **Raised:** Bootstrap
- **Section:** 1, 2
- **Blocking:** Yes — blocks Section 2
- **Priority:** High

**Question:**
ALZ assumes multiple subscriptions (Connectivity, Identity, Management, Security, multiple Landing Zones, Sandbox). For a portfolio POC, do we deploy:
- A: Multiple real subscriptions under one billing account (most faithful, highest cost)
- B: One subscription with strong RG-level segmentation simulating multi-sub (cheapest, less realistic)
- C: Subscription-per-archetype only for Platform (Connectivity, Mgmt, Security, Identity), single subscription for all Landing Zones (middle ground)

Recommended for a POC: **C**. Confirm before Section 2.

**RESOLVED 2026-05-05 (Session 2):** Option C — 4 platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription for all Landing Zones and Sandbox simulated via RG and MG-level policy assignment. Rationale: preserves the platform/workload boundary that matters most architecturally, keeps cost manageable for a portfolio POC (~$80–150/mo idle), and uses a sub count realistically provisionable on a Visual Studio benefit account.

---

### OQ-002: Identity mode — DCs on IaaS vs Microsoft Entra Domain Services

- **Raised:** Bootstrap
- **Section:** 8
- **Blocking:** No (deferrable until Section 8)
- **Priority:** Medium

**Question:**
PROMPT.md Section 8 leaves this as a `var.identity_mode` toggle. For the POC default value, which should we ship?

**Options:**
- A: Two B2s VMs as DCs (~$60/mo, full control, more realistic for enterprise)
- B: Microsoft Entra Domain Services (~$110/mo, less to manage, less to demo)
- C: Skip entirely for POC, leave the variable but default to `none`

**RESOLVED 2026-05-14:** Option C — `identity_mode = "none"`. Identity sub not built; `platform/identity/` left as scaffold only. No impact on Section 9 (spokes do not require domain services).

---

### OQ-003: Domain name(s) for the POC

- **Raised:** Bootstrap
- **Section:** 5, 8
- **Blocking:** No
- **Priority:** Medium

**Question:**
Conditional Access, Entra ID, and any custom domain bindings need a domain. Are we using:
- The default `*.onmicrosoft.com` tenant domain (cheapest, no DNS work)
- A custom domain you own (more realistic, requires DNS verification)

---

### OQ-004: Region pair selection for DR

- **Raised:** Bootstrap
- **Section:** 3
- **Blocking:** No (deferrable until Section 3)
- **Priority:** Low

**Question:**
PROMPT.md suggests `eastus2` (primary) + `centralus` or `westus3` (DR). Confirm or override. Note: `westus3` does not yet have all the same services as `eastus2` — verify availability of Azure Firewall Premium, DNS Private Resolver, and Sentinel before locking in.

---

### OQ-005: State storage CMK source

- **Raised:** 2026-05-05 (Session 2)
- **Section:** 10a
- **Blocking:** Yes — blocks state backend creation
- **Priority:** High

**Question:**
The Terraform state Storage Account requires CMK encryption per PROMPT.md Section 10. CMK requires a Key Vault with the encryption key. Which approach?

**Options:**
- A: Microsoft-managed keys for now (deviation, document in DECISIONS), upgrade to CMK in 10b
- B: Bootstrap a dedicated Key Vault in the Management sub today as part of 10a
- C: Use the Security sub Key Vault (but that sub is built in Section 8 — not yet)

**RESOLVED 2026-05-05 (pre-session):** Option B — bootstrap a small dedicated Key Vault in Management sub today. Adds ~15 min of work but avoids deviation marker. The Key Vault becomes part of the bootstrap layer and is later referenced (not destroyed) by Section 8.

---

### OQ-006: Terraform module organization for bootstrap

- **Raised:** 2026-05-05 (Session 2)
- **Section:** 10a
- **Blocking:** No
- **Priority:** Medium

**Question:**
The bootstrap layer (state backend, OIDC) needs to be deployed *before* the remote state exists. Where does its own state live?

**Options:**
- A: Local state, committed to a separate `bootstrap-state/` private folder (gitignored), one-time apply
- B: Local state, never committed, documented as one-time manual apply
- C: Use Azure CLI imperative commands for bootstrap, then Terraform takes over with remote state

**RESOLVED 2026-05-05 (pre-session):** Option B — local state never committed, manual one-time apply, documented in `bootstrap/README.md` with explicit "this is the chicken-and-egg layer" warning. Bootstrap state file added to `.gitignore`.

---

### OQ-007: GitHub Actions runner choice

- **Raised:** 2026-05-05 (Session 2)
- **Section:** 10a
- **Blocking:** No
- **Priority:** Low

**Question:**
For a portfolio POC repo, public vs private and runner choice?

**Options:**
- A: GitHub-hosted, public repo (free, exposes code as portfolio)
- B: GitHub-hosted, private repo (uses included minutes, can flip to public later)
- C: Self-hosted on Azure VM (overkill for POC)

**RESOLVED 2026-05-05 (pre-session):** Option B — private repo, GitHub-hosted runners. Workflows must be written so they work identically once the repo flips to public.

---

### OQ-008: OIDC SP RBAC scope-down follow-up tracking

- **Raised:** 2026-05-05 (Session 2)
- **Section:** 12
- **Blocking:** No (until Section 12)
- **Priority:** Medium

**Question:**
Per ADR-006 (this session), the OIDC SP receives Owner at Tenant Root MG to enable ALZ work without per-resource RBAC complexity. This is a deliberate POC compromise that must be scoped down before the POC is "done."

**Action required at Section 12:** Replace Tenant Root Owner with:
- Per-sub Contributor on the 5 subscriptions
- Resource Policy Contributor at the relevant MG scopes
- User Access Administrator only where role assignments are managed

This stays open through every session's start-of-session read until resolved at Section 12.

---
