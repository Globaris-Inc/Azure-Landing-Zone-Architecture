# Decision framework — the forks every landing zone must answer

Resolve these **with the project owner before writing Terraform**, and record each as an ADR. They recur on
every Azure landing zone. Each has a **recommended default** (what we'd pick absent other constraints) and
**why**. Copy this into the new project's `OPEN-QUESTIONS.md` and fill in the **Resolution** lines.

> Rule of thumb: if a fork changes *what you build* (not just a value), stop and ask — don't pick silently.

---

### Q1 — IaC stack & module strategy
**Options:** Terraform + AVM · Bicep + AVM · wrap an accelerator.
**Recommended:** **Terraform + published `Azure/avm-res-*` modules**, every source version-pinned; native
`azurerm` only as a documented `# DEVIATION`. **Why:** one maintained stack, tested building blocks,
broad ecosystem. Avoid proposed/unversioned pattern modules.

### Q2 — Subscription & resource-group topology
**Options:** single subscription (workload + shared RGs) · separate shared-services subscription · multi-sub.
**Recommended:** **single subscription, two RGs** (workload + shared-services) for a PoC; design the
multi-sub seam (provider alias) but don't build it yet. **Why:** simplest blast radius; platform LZ owns
the cross-sub topology.

### Q3 — Identity model
**Options (compute LZs):** Entra ID join · Entra Domain Services · self-managed AD DS. **Security/data
LZs:** which workload/managed identities, which RBAC.
**Recommended:** **Microsoft Entra ID join / managed identities** (cloud-native, no DC infra). **Why:**
least operational overhead; integrates with Conditional Access. Keep a toggle for the legacy options.

### Q4 — Region(s)
**No default — always ask.** Drives quota, zone availability, data residency, and the short name token in
every resource name. Confirm the region has the SKUs/zones you need *before* committing.

### Q5 — CI/CD auth
**Options:** OIDC federated credentials (no secret) · stored client secret.
**Recommended:** **OIDC federation** — no secrets in the repo or CI; IDs as repo **Variables**. **Why:**
secret-less, auditable. (A short-lived SP secret is acceptable only for a one-time *local* bootstrap when
tenant MFA blocks the user — see [LESSONS](LESSONS.md) C13.)

### Q6 — CI principal RBAC scope
**Options:** Owner · Contributor + User Access Administrator · custom role.
**Recommended:** **Contributor + User Access Administrator** at subscription scope (not Owner). **Why:**
least privilege while still able to create the role assignments an application LZ needs.

### Q7 — Remote-state backend posture
**Options & recommended defaults:** Azure Storage backend, **GZRS**, **customer-managed key**, **shared
keys disabled** (Entra/RBAC only), **blob versioning** (not WORM), default-Deny firewall + allow-list,
**deterministic name** (suffix from the subscription ID). **Why:** encrypted/versioned/recoverable,
secret-less, and reproducible re-bootstrap. See [LESSONS](LESSONS.md) A1–A4, D16, D18.

### Q8 — Bootstrap & its own state
**Options:** local/ephemeral state · self-hosted in the backend it creates.
**Recommended:** **ephemeral** if teardown is `az group delete` and deploys reach the account by name —
combined with deterministic naming, re-bootstrap is a clean re-apply. **Why:** removes the chicken-and-egg
without a state-migration dance.

### Q9 — Deploy gating & trigger model
**Options:** merge-triggered apply · manual `workflow_dispatch` only.
**Recommended:** **explicit `workflow_dispatch`** for apply/destroy with a **typed confirmation** + a
**required-reviewer `production` Environment**; PRs run **plan only**. **Why:** every deploy is a
deliberate, gated action; routine commits don't fire prod. See [LESSONS](LESSONS.md) D17.

### Q10 — Network egress & exposure
**Options:** NAT gateway · hub firewall (UDR) · (don't) rely on default outbound.
**Recommended:** an **explicit egress** path (NAT gateway by default; firewall/UDR when a hub exists);
private endpoints + private DNS for PaaS; reverse-connect / no public inbound where the service supports it.
**Why:** default outbound access is retired (see [LESSONS](LESSONS.md) B11).

### Q11 — Secrets & sensitive values
**Recommended:** **no secrets or real subscription/tenant IDs committed** — Key Vault for runtime secrets,
repo Variables / env for IDs, `*.tfvars` ship as placeholders. **Why:** the project's hard constraint.

### Q12 — Naming & tagging
**Recommended:** CAF naming (`<type>-<workload>-<env>-<region>`), a `common_tags` map applied to every
resource, minimum tags (env, workload, owner, cost-center, criticality, data-classification). Decide the
workload token and region short-name up front. **Why:** consistency + governance from day one.

### Q13 — Scope boundary (what this LZ does NOT do)
**Always state it.** An *application* (or *security*) landing zone sits on top of the **platform** landing
zone (connectivity / identity / management / management-groups) and never builds it. Write the prerequisite
list explicitly.
