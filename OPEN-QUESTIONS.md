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
