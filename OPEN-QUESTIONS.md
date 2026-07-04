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

### OQ-015: Environment required-reviewer gate unavailable on the current GitHub plan

- **Raised:** 2026-07-04 (Section 10 CI wiring, devsecops)
- **Section:** 10 (Pipeline & Tooling)
- **Blocking:** No - the deploy/teardown pipeline runs without it; this is a governance gap vs ADR-019
- **Priority:** Medium

**Question:**
ADR-019 / OQ-013 (RESOLVED B) require >=1 **required reviewer** on the `production` (apply) and
`production-destroy` (teardown) GitHub Environments. On wiring them, GitHub returned **HTTP 422 "Please
ensure the billing plan supports the required reviewers protection rule."** - environment protection rules
are **not available for PRIVATE repos on the Free plan**. Both environments now exist but are **ungated**
(0 protection rules). How do we restore the human-approval gate?

**Options being considered:**
- A: **Flip the repo public** (recommended) - environment protection rules (incl. required reviewers) are
  free on public repos. Aligns with the 2026-07-03 public-readiness prep (secret-swept, MIT LICENSE, history
  rewritten). Adds required-reviewer + branch-policy gates at zero cost. Then re-run the reviewer wiring.
- B: **Accept ungated environments as a documented POC deviation.** The teardown `confirm == "destroy"`
  typed guard (hard-fails before any Azure login) and the deliberate `workflow_dispatch`-only trigger remain
  as the guardrails; no automated human approval step. Cheapest; weakens ADR-019.
- C: **Upgrade to GitHub Pro/Team** to get environment protection on the private repo (recurring cost).

**Interim state:** both environments created ungated so the OIDC `environment:production` /
`environment:production-destroy` federated subjects resolve and the pipeline is functional. The reviewer gate
is the only missing piece.

**Needed from user:** choose A / B / C.

---

### OQ-014: Brownfield adoption unknowns - importing an existing environment into the ALZ

- **Raised:** 2026-07-03 (Section 11 planning, architect)
- **Section:** 11 (design captured now) / future build
- **Blocking:** No - greenfield docs proceed now; this gates the future brownfield build only
- **Priority:** Medium

**Question:**
What is the supported approach for adopting an existing (brown-field) tenant/subscriptions into this ALZ,
and which unknowns must be resolved before we build that capability?

**Open sub-questions (resolve before a brownfield build):**
- **State:** `terraform import` of pre-existing RGs/VNets/policy assignments, vs. greenfield-only with
  parallel coexistence and a later cutover?
- **MG grafting:** moving existing subscriptions under the Globaris MG tree - what is the blast radius of
  inherited policy on already-running workloads?
- **Policy rollout:** audit / DeployIfNotExists in non-enforcing mode first, then enforce - what soak period
  and exception process?
- **Networking coexistence:** existing hub/VNet/DNS vs. this platform's hub - peering, address-space
  overlap, DNS forwarder cutover.
- **RBAC:** existing assignments vs. the scoped OIDC SP (ADR-021) - does adoption need broader temporary
  grants during import?
- **Ownership boundary:** which existing resources IaC takes over vs. leaves un-managed.

**Approach captured now (ADR-022):** document the adoption approach in `docs/brownfield-adoption.md` as
roadmap; build + validate the capability in a later section/wave.

---

### OQ-013: CI/CD approval model for apply vs teardown

- **Raised:** 2026-06-27 (CI/CD deploy + teardown design session, architect)
- **Section:** 10 (Pipeline & Tooling)
- **Blocking:** Yes (until resolved) — gates the structure of `deploy.yml` / `teardown.yml`
- **Priority:** High

**Question:**
How should apply and teardown be gated? One shared GitHub Environment for both, or separate
environments so destroy approval is a distinct, more deliberate gate? And what extra guards on teardown?

**Options being considered:**
- A: One `production` Environment gates both apply and destroy.
- B: Two Environments — `production` gates apply (`deploy.yml`), `production-destroy` gates teardown
  (`teardown.yml`) — each with a required reviewer; teardown also requires a typed `confirm=destroy`
  input that hard-fails the run before any Azure login.

**RESOLVED 2026-06-27:** Option B. TWO GitHub Environments: `production` (apply gate, referenced via
`environment:` on apply jobs in `deploy.yml`) and `production-destroy` (teardown gate, referenced on the
teardown job in `teardown.yml`), each with ≥1 required reviewer. Teardown additionally hard-fails its
first step unless `confirm == "destroy"`. This requires two new OIDC federated credentials (subjects
`...:environment:production` and `...:environment:production-destroy`) in `bootstrap/identity.tf` and a
bootstrap re-apply. Captured in ADR-019.

---

### OQ-012: Does "tear down everything" include the bootstrap state backend + OIDC app?

- **Raised:** 2026-06-27 (CI/CD deploy + teardown design session, architect)
- **Section:** 10 (Pipeline & Tooling)
- **Blocking:** Yes (until resolved) — defines the `teardown.yml` `include_bootstrap` default + scope
- **Priority:** High

**Question:**
When the operator chooses to "tear down everything," should the teardown also remove the bootstrap layer
(state Storage Account, CMK Key Vault, OIDC app registration / SP / federated credentials), or only the
9 workload + platform roots?

**Options being considered:**
- A: Scorched-earth by default — full reset also deletes the state backend + OIDC app (next deploy needs
  a manual re-bootstrap and re-setting the three GitHub Variables).
- B: Workload + platform only by default — keep the bootstrap state backend + OIDC app so redeploy is
  immediate; expose an `include_bootstrap` input (default `false`) for the rare full-decommission case.

**RESOLVED 2026-06-27:** Option B. Teardown scope is workload + platform only. `teardown.yml` exposes an
`include_bootstrap` boolean input that **defaults to `false`** — the state SA, CMK KV, and OIDC
app/SP/federation are kept so the environment can be redeployed immediately from CI with no re-bootstrap
or GitHub-Variable re-wiring. `include_bootstrap=true` is full decommission only and additionally
requires a documented manual `az ad app delete` (the SP cannot delete its own Entra app via ARM Owner)
and — until LESSON 18 deterministic naming lands — a manual `poc.backend.hcl` update. Captured in
ADR-019.

---

### OQ-011: Spoke `avm-res-network-virtualnetwork` 0.17.1 schema drift + missing lock files

- **Raised:** 2026-06-25 (Gap-closure Wave 2 / G4 session, cloud-engineer)
- **Section:** 9 (Landing Zone Spokes) — infra hygiene, not a feature gap
- **Blocking:** Partially — does **not** block G4 (the new corp-a1 RSV validates clean in isolation), but **does** block a clean root-level `terraform validate`/`plan` for `landing-zones/corp-a1` (and likely `corp-a2`/`online-p1`).
- **Priority:** Medium

> **RESOLVED — 2026-06-26 (Option A+B remediation, cloud-engineer) → fully closed 2026-06-27.**
> Option B was taken across the board: reconcile each call to its pinned module/provider schema (no version bumps), and generate `.terraform.lock.hcl` for every init-able root (Option A). On 2026-06-26, **9 of 10 roots** validated clean; only `platform/connectivity` remained blocked on a provider-version conflict. **On 2026-06-27 the architect's ADR-017 azapi pin (`~> 2.5`) was applied, and connectivity now validates — making it 10 of 10.** OQ-011 is fully RESOLVED. Fixes applied:
> - **All 3 spokes** (corp-a1/corp-a2/online-p1): `spoke_vnet` `resource_group_name = …network.name` → `parent_id = …network.id` (v0.17.1 schema). Subnet sub-schema + consumed outputs (`name`, `resource_id`, `subnets[...].resource_id`) were already correct for 0.17.1 — no other change needed.
> - **corp-a1 / corp-a2**: removed the non-existent `azurerm_private_dns_zone_group` resource (it is not an azurerm resource type) and moved DNS zone registration into the `private_dns_zone_group {}` nested block on `azurerm_private_endpoint.sql` (behavior-preserving).
> - **platform/management-groups**: `subscription_placement` reshaped to the v0.19.1 schema (`{ subscription_id, management_group_name }` per entry; MG names = arch-def ids). Same subscription→MG placements.
> - **platform/security**: `module.security_kv.resource.name/.vault_uri` → `.name`/`.uri` (avm-res-keyvault-vault output names); `azurerm_sentinel_watchlist` `workspace_id` → `log_analytics_workspace_id = module.security_law.resource_id` (azurerm v4 arg), with `depends_on` re-added to preserve onboarding order.
> - **platform/connectivity**: `private_dns_zones` call reconciled to v0.23.1 (`resource_group_name`→`parent_id`, dropped non-existent `resource_group_creation_enabled`). **CLOSED 2026-06-27 — see below.**
>
> **~~STILL OPEN — `platform/connectivity` only~~ → CLOSED 2026-06-27:** On 2026-06-26 init failed on a **provider version-constraint conflict**: the root pinned `azapi = "~> 2.4.0"` (`providers.tf:19` → `>=2.4.0,<2.5.0`), but sub-modules of **both** `avm-ptn-alz-connectivity-hub-and-spoke-vnet` v0.17.1 and `avm-ptn-network-private-link-private-dns-zones` v0.23.1 require `azapi ~> 2.5` (`>=2.5.0,<3.0.0`) — disjoint ranges, so init aborted. **The architect resolved this in ADR-017: pin azapi `~> 2.5`.** On 2026-06-27 the cloud-engineer applied `providers.tf:19` → `azapi = "~> 2.5"`; `terraform init -backend=false` now succeeds (azapi resolves to v2.10.0) and `terraform validate` returns `Success! The configuration is valid.` (no warnings). The dns.tf v0.23.1 reconciliation validated clean with no further drift — the azapi bump alone was sufficient. `.terraform.lock.hcl` generated for connectivity (to be committed). **All 10 roots now validate clean. OQ-011 fully RESOLVED.**

**Question:**
On a clean `terraform init -backend=false` (no committed `.terraform.lock.hcl`), the `module "spoke_vnet"` block in `landing-zones/corp-a1/main.tf` fails validation: it passes `resource_group_name`/`address_space`, but the `Azure/avm-res-network-virtualnetwork/azurerm` source that init resolves for the `version = "0.17.1"` pin expects **`parent_id`** (a resource-group ID) instead. This aborts init before all modules install, so the whole root cannot validate. Reproduced with the new `backup.tf` removed — it is pre-existing and unrelated to G4. Root cause is most likely that no `.terraform.lock.hcl` is committed for the spokes, so the originally-validated module build is not pinned and the registry now serves a differently-shaped 0.17.1 artifact (or the call was written against a build that differs from the published 0.17.1).

**Options being considered:**
- A: Commit `.terraform.lock.hcl` for each spoke (and all roots) so module/provider builds are reproducible; re-run init/validate against the locked build.
- B: Reconcile the `spoke_vnet` call to the published 0.17.1 schema (`parent_id` + current subnet shape) across corp-a1/corp-a2/online-p1, then re-pin.
- C: Bump the vnet module to a current version and update the call shape (larger change; cross-spoke).

Recommend a dedicated remediation pass (architect + cloud-engineer) — out of scope for the G4 wave per the section-per-session rule.


- **Raised:** 2026-06-25 (gap-closure planning)
- **Section:** 9 / 12 (Wave 5)
- **Blocking:** Yes — blocks the G5 portion of Wave 5 only (does not block G1/G2/G3/G4/G6)
- **Priority:** Medium

**Question:**
ADR-003 collapsed the Sandbox and Online archetypes into the single shared Landing Zones subscription. The
ALZ reference shows them as **separate subscriptions**. ADR-014 recommends KEEPING the collapse as a
documented deviation for the POC (it is a subscription-*count* gap, not a capability gap — the MG nodes,
policy inheritance, and RG segmentation already demonstrate the boundary). The user wants all gaps
addressed, so confirm the call:

**Options:**
- A: **Keep collapsed (deviation)** — recommended. No extra cost, no billing-scope dependency. Reviewer
  accepts ADR-014 explicitly.
- B: **Provision two real subscriptions** (one Online, one Sandbox) and bind `online-p1` + a sandbox RG-set
  to them under the existing MG nodes. Requires: (1) two more subscription IDs supplied in `poc.tfvars`,
  **or** (2) an EA/MCA enrollment-account ID so the engineer can use the `avm-ptn-lz-vending` subscription-
  vending pattern. Adds provisioning complexity and a small per-sub idle baseline.

**Needed from user:** choose A or B. If B, supply either two sub IDs or an EA/MCA enrollment account ID.

---

### OQ-009: Fund Azure DDoS Network Protection for the POC? (G3)

- **Raised:** 2026-06-25 (gap-closure planning)
- **Section:** 8 (Wave 5)
- **Blocking:** No — the construct ships flag-gated (`var.enable_ddos_protection = false`); this only
  decides the default/active state
- **Priority:** Medium

**Question:**
The reference diagram shows an Azure **DDoS Network Protection** plan on the hub. Per ADR-013 the
cloud-engineer will build the construct (`Azure/avm-res-network-ddosprotectionplan/azurerm` v0.3.0, wired to
the hub + online-p1 VNets) behind `var.enable_ddos_protection`, **default false**. DDoS Network Protection
is a **~$2,944/mo flat** plan — roughly 20–35x the entire rest of the platform's idle cost.

**Options:**
- A: **Keep default false** (recommended) — capability built and one toggle away; zero idle DDoS cost. The
  ARCHITECTURE.md deviation becomes "pre-staged, disabled."
- B: **Set default true / fund it** — only if a live demo of DDoS telemetry/metrics is required and the
  ~$2,944/mo is acceptable for the demo window.
- C: (noted, not recommended) DDoS **IP Protection** per-public-IP tier (~$199/mo/IP) instead of the
  network-tier plan — cheaper but does not match the reference's network-tier construct and is billed
  per IP; out of scope unless the user prefers it.

**Needed from user:** confirm A (default false), or approve B with the monthly spend, or request C.

---

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
- **Status:** **SUPERSEDED (2026-06-28, ADR-010)** — resolved to `identity_mode = "entra-ds"` and
  **built** in Wave 3 (`platform/identity/{identity-network,domain-services}.tf`).

**Question:**
PROMPT.md Section 8 leaves this as a `var.identity_mode` toggle. For the POC default value, which should we ship?

**Options:**
- A: Two B2s VMs as DCs (~$60/mo, full control, more realistic for enterprise)
- B: Microsoft Entra Domain Services (~$110/mo, less to manage, less to demo)
- C: Skip entirely for POC, leave the variable but default to `none`

~~**RESOLVED 2026-05-14:** Option C — `identity_mode = "none"`. Identity sub not built; `platform/identity/` left as scaffold only. No impact on Section 9 (spokes do not require domain services).~~

**SUPERSEDED 2026-06-25 (ADR-010):** Reversed during gap-closure (G1). New resolution: **Option B —
Microsoft Entra Domain Services** (`identity_mode = "entra-ds"`, Standard SKU, ~$110/mo). Rationale:
2026 CAF identity guidance favours managed Entra DS over self-managed DCs (AD-minimization, cloud-first);
less to manage and demo. The `var.identity_mode` toggle is retained so `ad-ds` (two B2s DCs) remains
selectable, but `entra-ds` is the shipped default. Build path in `docs/gap-closure-plan.md` Wave 3.
Note: requires a one-time **manual** tenant pre-step (Domain Controller Services SP + `AAD DC
Administrators` group) and surfaces OQ-003 (POC domain name).

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

**RESOLVED-BY-DESIGN 2026-06-29 (architect, ADR-021) — pending devsecops impl + a real apply to validate:**
The least-privilege role matrix is designed and recorded in [ADR-021](DECISIONS.md) and the devsecops
implementation spec [`docs/oq-008-rbac.md`](docs/oq-008-rbac.md). Tenant Root **Owner** is replaced by:
**Management Group Contributor** @ Tenant Root Group (MG tree create/delete + subscription move);
**Resource Policy Contributor** + **User Access Administrator** @ Globaris root MG (MG-scoped policy +
role assignments, incl. PIM); **Contributor** + **User Access Administrator** on **each of the 5
subscriptions** (resource + in-sub role-assignment create/destroy, via `for_each` over a static map); and
the existing **Storage Blob Data Contributor** on the state SA (unchanged). The audit confirmed plain
Contributor is **insufficient** (the IaC creates role + policy assignments that Contributor's NotActions
forbid), so UAA + Resource Policy Contributor are required alongside it.

Honest residual broad grants (not "fully minimal"): MG Contributor @ Tenant Root Group is a tenant-wide
control-plane grant; UAA @ Globaris can create any role assignment (incl. Owner) within the hierarchy
(self-escalation risk intrinsic to a self-deploying platform SP); per-sub Contributor is broad within each
sub. The real reduction is **Owner-at-tenant-root (whole tenant, forever) → Globaris hierarchy + 5 named
subs**, losing unrestricted Owner / `elevateAccess` / implicit future-sub access.

**NOT closed yet — two follow-ups remain:** (1) devsecops implements the spec in `bootstrap/identity.tf` +
adds the 4 new subscription-ID variables; (2) `terraform validate`/`plan` cannot prove sufficiency — only a
real CI `target=all` **apply** then **teardown** with the SP holding exactly this set validates it. Any 403 →
add the precise missing scope, never revert to Owner. The **azuread Graph app permissions are separate ARM-vs-
directory and unchanged** by OQ-008. Stays referenced until the live apply/destroy passes green.

---
