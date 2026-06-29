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

### ADR-020: Teardown mechanics — uniform `terraform destroy` (supersedes the ADR-019 brute-force split)

- **Date:** 2026-06-27
- **Section:** 10 (Pipeline & Tooling) — amends ADR-019
- **Status:** Accepted — amends the teardown-mechanics portion of [ADR-019](#adr-019-cicd-deploy--teardown--parameterized-deployyml--guarded-teardownyml-two-environments)
- **Decision makers:** claude (architect), code-reviewer (raised the finding)

**Context:**
Code review (finding B1) found that ADR-019 and `docs/cicd-deploy-teardown.md` §6/§9 specify the
full-environment teardown (`target=all`) as a **split** — `az group delete` brute force for the RG-bound
regional roots **plus** `terraform destroy` for the non-RG control-plane roots (`platform/management-groups`,
`platform/identity`, MG-scoped `platform/security`) — and §6 calls that split "the key correctness point
for this design," justified by LESSON 19 (`terraform destroy` gets stuck on Azure ordering quirks). **But
the implemented and validated `teardown.yml` does not do the split:** it runs `terraform destroy` for every
root uniformly, in reverse dependency order, via the reusable `_tf-root.yml`. The docs asserted behavior the
code does not implement; this had to be reconciled before merge. The reconciliation is a choice between
implementing the split in CI (Option 1) or accepting uniform `terraform destroy` and amending the docs
(Option 2).

**Decision:**
Adopt **uniform `terraform destroy`** for both single-root and `target=all` teardown — i.e. keep the
already-implemented `teardown.yml` / `_tf-root.yml` behavior — and amend the docs to match. The
`az group delete` brute-force / Terraform split is **demoted to a deferred refinement / manual fallback**
for the case where a `target=all` `terraform destroy` wedges; it lives only in the runbook (the
`include_bootstrap=true` scorched-earth path and a per-RG fallback note), not in the workflow. OQ-012
(teardown scope, `include_bootstrap=false` default), OQ-013 (two GitHub Environments), the
typed-`confirm=destroy` guard, and the reverse-order `needs:` graph are **unchanged**.

**LESSON 19 — why it does not force the split here:**
LESSON 19's stuck-`terraform destroy` failures originated in the AVD landing zone and were
**session-host VM**-driven (stopped-VM extension deletes, agent/DSC extension races, the resources that
most reliably wedge an ARM delete). **This CAF POC has no VMs.** Its workload is PaaS and control-plane
only — App Service, SQL, VNets/peerings, Key Vault, Sentinel/Defender onboarding, policy/role/MG objects —
all of which `terraform destroy` removes cleanly. Moreover the **non-RG roots** (management groups,
MG-scoped policy assignments, Entra/CA objects) are precisely what `az group delete` **cannot** touch, so
the split's "brute force handles RGs, Terraform handles control-plane" framing always needed Terraform for
the hard part anyway; using Terraform for everything is simpler and keeps state consistent for a clean
re-apply. The LESSON-19 brute-force path is retained as the documented fallback if a `target=all` run ever
does wedge in practice.

**Alternatives considered:**
- **Option 1 — implement the split in `teardown.yml`** (`az group delete` for RG-bound roots + `terraform
  destroy` for control-plane roots): rejected — it adds per-root branching and loses state fidelity (state
  must be reconciled or recreated) to solve a VM-driven failure mode this no-VM workload is not expected to
  hit; the implementation is already validated as uniform `terraform destroy`.
- **Promote brute force to the default but keep Terraform for control-plane roots only:** rejected for the
  same reason — same complexity, same state-fidelity loss, no benefit absent the VM failure mode.

**Consequences:**
- Positive: docs ↔ code are consistent (ADR-019/§6/§9 ↔ `teardown.yml` ↔ `_tf-root.yml`); one destroy
  mechanism for single-root and full reset; state stays consistent so any scope re-applies cleanly; no new
  workflow code is required to merge.
- Negative / trade-offs: if a `target=all` `terraform destroy` ever wedges on an Azure ordering quirk, the
  operator must fall back to the **manual** brute-force runbook (per-RG `az group delete` in reverse order,
  then `terraform destroy`/targeted `az` for the non-RG control-plane roots). This is documented but not
  automated. Should that prove common, re-open with a new ADR that promotes the split.
- Follow-ups required: none blocking — `teardown.yml` already implements the accepted behavior. Its header
  comment (lines 14-17) already describes uniform `terraform destroy` with brute force as "a documented
  refinement," so it is consistent with this ADR; no workflow edit is needed.

---

### ADR-019: CI/CD deploy + teardown — parameterized `deploy.yml` + guarded `teardown.yml`, two Environments

- **Date:** 2026-06-27
- **Section:** 10 (Pipeline & Tooling) — extends the bootstrap pipeline
- **Status:** Accepted — **teardown mechanics amended by [ADR-020](#adr-020-teardown-mechanics--uniform-terraform-destroy-supersedes-the-adr-019-brute-force-split)** (the `az group delete` brute-force / Terraform split below is replaced by uniform `terraform destroy`; the rest of ADR-019 — structure, scope OQ-012, two-Environment model OQ-013, OIDC federation — stands)
- **Decision makers:** user (decisions), claude (architect/design), devsecops-engineer (execution)

**Context:**
CI/CD must (1) deploy any single platform/landing-zone root individually, (2) deploy the whole
environment in dependency order, and (3) tear everything down — all via OIDC, no stored secrets,
appropriately gated. The pre-existing `apply-on-merge.yml` auto-applied on every push to `main`, which
contradicts LESSON 17 (deploys must be explicit, not merge-triggered) and the destroy-then-recreate demo
cadence. Two user decisions were outstanding: whether "tear down everything" includes the bootstrap
state backend + OIDC app (OQ-012), and the approval model (OQ-013). Full design in
[docs/cicd-deploy-teardown.md](docs/cicd-deploy-teardown.md).

**Decision:**
- **Deploy:** one parameterized `workflow_dispatch` workflow `deploy.yml` with `target`
  (choice: the 9 deployable roots + `all`) and `action` (choice: `plan` | `apply`). `target=all` runs
  the 9 backend-state roots via a `needs:` job graph in dependency order; a single `target` runs just
  that root. `apply` jobs gate on the `production` GitHub Environment.
- **Teardown:** a separate guarded workflow `teardown.yml` (`workflow_dispatch`) — not a third `action`
  on deploy — because destroy needs stronger/different guards and reverse ordering. Inputs: `confirm`
  (typed; the run hard-fails unless it equals `destroy`) and `include_bootstrap` (boolean, default
  `false`). Destroys in reverse dependency order, using `az group delete` brute force for the RG-bound
  regional roots **and** `terraform destroy` for the control-plane/tenant roots (`management-groups`,
  `identity`, MG-scoped `security`), which are not resource groups (LESSON 19). **[Amended by ADR-020:
  the brute-force / Terraform split is replaced by uniform `terraform destroy` for all roots; the
  split is now a deferred manual fallback.]**
- **Teardown scope (OQ-012):** workload + platform only by default. `include_bootstrap` **defaults to
  `false`** so the state backend (state SA, CMK KV) and the OIDC app/SP/federation survive a full reset
  and redeploy is immediate. `true` is full scorched-earth (decommission) and additionally needs a
  documented manual `az ad app delete` (the SP cannot delete its own Entra app via ARM Owner).
- **Approval model (OQ-013):** TWO GitHub Environments — `production` gates apply in `deploy.yml`;
  `production-destroy` gates teardown in `teardown.yml` — each with a required reviewer, plus the typed
  `confirm=destroy` guard on teardown. This keeps destroy approval a separate, more deliberate gate.
- **Retire** `apply-on-merge.yml` (deleted; deploys are now explicit — LESSON 17). Keep
  `plan-on-pr.yml` (always-on PR plan) and `validate.yml` (static gate).
- **OIDC federation:** two new federated credentials are required for the gated jobs (their OIDC `sub`
  becomes `repo:<org>/<repo>:environment:<env>`): subjects `...:environment:production` and
  `...:environment:production-destroy` added to `azuread_application.oidc` in `bootstrap/identity.tf`.
  **Bootstrap must be re-applied** for the gated jobs to authenticate.

**Alternatives considered:**
- Third `action=destroy` value on `deploy.yml` — rejected: destroy needs a different gate, reverse
  ordering, and a typed confirm; a separate file makes the blast radius obvious in the Actions UI.
- A `matrix` for `target=all` — rejected: a matrix cannot express the partial cross-root order
  (spokes wait for connectivity + security); a `needs:` graph can, and preserves legitimate parallelism.
- `terraform destroy` for the full reset — rejected: LESSON 19 documents it reliably gets stuck on Azure
  ordering quirks; `az group delete` brute force is the proven demo-reset path for RG-bound roots.
  **[Reversed by ADR-020: LESSON 19's stuck-destroy failures were VM-driven; this no-VM PaaS/control-plane
  POC destroys cleanly with uniform `terraform destroy`, so that is now the accepted full-reset path.]**
- Single Environment for both apply and destroy — rejected: destroy warrants a tighter, separate
  reviewer gate (OQ-013).

**Consequences:**
- Positive: explicit, auditable deploys; one-root and whole-environment paths from one entrypoint;
  destroy is hard to trigger accidentally (typed confirm + dedicated environment); default teardown
  keeps the backend so redeploy needs no re-bootstrap or GitHub-Variable re-wiring.
- Negative / trade-offs: relies on ADR-006's broad SP scope (Owner at Tenant Root MG) for both apply and
  destroy (tracked under OQ-008); `az group delete` brute force loses state fidelity for the reset roots
  (acceptable for a demo — state is recreated greenfield-safe on next apply); `include_bootstrap=true`
  needs a manual `az ad app delete` and (until LESSON 18 deterministic naming lands) a manual
  `poc.backend.hcl` update.
- Follow-ups required: re-apply `bootstrap/` to register the two environment federated credentials;
  create the `production` and `production-destroy` Environments with reviewers; cloud-engineer to migrate
  bootstrap to deterministic (sub-ID-derived) state-backend naming (LESSON 18) before relying on
  `include_bootstrap=true`.

---

### ADR-018: OQ-011 remediation — reconcile module calls to pinned AVM schemas, commit lock files per root, add a CI `terraform validate` gate

- **Date:** 2026-06-27
- **Section:** Cross-cutting (infra hygiene; touches Sections 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** claude (architect), cloud-engineer (execution)

**Context:**
Every section was marked 🟢 Complete in the WORKLOG, but those statuses **predated any real
`terraform validate`** — the work log repeatedly recorded "validate NOT RUN" (no remote-state/firewalled
backend creds during build, and no committed `.terraform.lock.hcl`, so a clean `init` re-resolved modules
to whatever the registry served). The 2026-06-26 remediation pass ran `terraform init -backend=false` +
`validate` on all 10 roots and found schema drift: several calls were written against a module build that
differed from the published pinned tag. Concretely, across the tree the following were stale against the
**pinned** AVM schemas:
- `avm-res-network-virtualnetwork` v0.17.1 — VNet sub-module is `parent_id` (RG resource ID), not
  `resource_group_name` (all 3 spokes + the connectivity hub path).
- `avm-ptn-network-private-link-private-dns-zones` v0.23.1 — `parent_id`, no `resource_group_creation_enabled`.
- `avm-ptn-alz` v0.19.1 — `subscription_placement` object shape `{ subscription_id, management_group_name }`.
- `avm-res-keyvault-vault` — outputs are `name`/`uri`, not a `resource` object.
- `azurerm_private_dns_zone_group` — **not a provider resource type**; the canonical pattern is the nested
  `private_dns_zone_group {}` block on `azurerm_private_endpoint`.
- `azurerm_sentinel_watchlist` — `log_analytics_workspace_id` (azurerm v4), not `workspace_id`.

**Decision:**
Adopt **Option B** (reconcile each call to its already-pinned module/provider schema — *no version bumps*)
as the remediation standard, plus **Option A** (generate and **commit** a `.terraform.lock.hcl` for every
init-able root) so module/provider builds are reproducible and `validate`/`plan` are deterministic going
forward. Lock files for `platform/*` and `landing-zones/*` are now committed; `bootstrap/.terraform.lock.hcl`
stays git-ignored (ADR-005 — one-time local apply). The single exception requiring a version action is the
connectivity azapi pin, handled separately in **ADR-017**. A CI `terraform validate` gate (run
`init -backend=false` + `validate` per root, `fmt -check -recursive`) is added so a 🟢 status can never
again outrun an actual validate; the gate is the new definition of "Complete" for any IaC section.

**Alternatives considered:**
- Bump module versions to match the as-written calls (Option C) — rejected: larger, cross-root change that
  re-opens verification on every consumed input/output; the pinned versions are fine, only the *calls* drifted.
- Leave roots unlocked and rely on registry "latest 0.x" — rejected: that is exactly the drift that let
  "Complete" sections fail a first real validate; non-reproducible by construction.

**Consequences:**
- Positive: 9/10 roots now `init -backend=false` + `validate` clean with committed locks; drift is frozen;
  CI gate makes regressions visible at PR time, not demo time. No behavioral change, no apply.
- Negative / trade-offs: committed lock files must be refreshed deliberately (`terraform init -upgrade`) on
  any future intentional uplift; the CI gate adds ~1–2 min per root to PR runs.
- Follow-ups: cloud-engineer applies ADR-017 (azapi pin) to make connectivity the 10th clean root and commit
  its lock; devsecops-engineer wires the `validate` gate into `.github/workflows/`; reviewer treats a green
  validate gate as a merge precondition. The pre-existing uncommitted G4 files
  (`landing-zones/corp-a1/backup.tf` + corp-a1 outputs/variables) validate clean and should be committed with
  this pass.

---

### ADR-017: Connectivity `azapi` provider pin aligned to `~> 2.5` (module requirement)

- **Date:** 2026-06-27
- **Section:** 8 — Standard Platform Components (Connectivity sub)
- **Status:** Accepted
- **Decision makers:** claude (architect); cloud-engineer applies

**Context:**
`platform/connectivity/providers.tf:19` pins `azapi = "~> 2.4.0"`. A **three-component** `~>` pin means
`>= 2.4.0, < 2.5.0`. The connectivity root composes `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet`
v0.17.1 and `Azure/avm-ptn-network-private-link-private-dns-zones` v0.23.1. Verified at the pinned tags
(2026-06-27): both top-level modules pin `azapi ~> 2.4` (two-component → `>= 2.4.0, < 3.0.0`), but their
nested sub-modules — notably the `subnet` sub-module of `avm-res-network-virtualnetwork` v0.17.1 (consumed
by the hub-and-spoke module) — pin **`azapi ~> 2.5`** (two-component → `>= 2.5.0, < 3.0.0`). The root's
`>= 2.4.0, < 2.5.0` and the sub-modules' `>= 2.5.0` are **disjoint on the lower bound**, so no azapi
version satisfies the whole graph and `terraform init` aborts before producing a lock file. (NOTE: the
remediation note described the sub-module ceiling as `< 2.6.0`; that was a mis-read — a two-component
`~> 2.5` has no 2.6 ceiling. The conflict is purely the root's `< 2.5.0` lower-bound ceiling. The fix is
the same either way.) azapi's latest is 2.10.0 (May 2026), so the 2.5.x line is well-established and stable.

**Decision:**
Bump the connectivity root pin from `azapi = "~> 2.4.0"` to **`azapi = "~> 2.5"`** (i.e. `>= 2.5.0, < 3.0.0`).
This aligns the root with the floor its own sub-modules already require and removes the disjoint constraint;
`init` then selects the highest 2.x azapi satisfying every node (currently 2.10.0) and writes a lock file.
No upper-bound conflict is introduced: every azapi constraint in the graph (`~> 2.4`, `~> 2.5`) intersects
`~> 2.5` at `>= 2.5.0`. The other root providers are independent of azapi and unaffected — `azurerm
~> 4.71.0` (matches modules' `~> 4.0`), `modtm ~> 0.3.0`, `random ~> 3.8.1`. This is the minimal, lowest-risk
resolution.

**Alternatives considered:**
- Pin `azapi = "~> 2.5.0"` (three-component, `>= 2.5.0, < 2.6.0`) — rejected: needlessly tight; would pin
  off 2.6+ while the modules accept the whole 2.x line and the rest of the repo uses two-component azapi
  pins. `~> 2.5` matches module convention and leaves room for in-band patch/minor uplifts.
- Bump the hub-and-spoke / private-dns module versions instead — rejected: a far larger change (re-verify
  every input/output of two pattern modules and their consumed sub-modules) to solve a one-line provider
  pin; the pinned module versions are correct, only the root's provider floor was stale.
- Downgrade the modules to a build that needs only `~> 2.4` — rejected: no such v0.17.1/v0.23.1 build; would
  mean abandoning the pinned, verified versions and is strictly worse.

**Consequences:**
- Positive: connectivity `init -backend=false` should succeed and produce a committable lock file, making it
  the 10th clean-validating root and closing the last OQ-011 item. One-line change, no resource/behavior
  change.
- Negative / trade-offs: a newer azapi (2.10.x) will be locked; azapi 2.x is API-stable (the 2.0 breaking
  change is long past), so risk is low. The committed lock fixes the exact version, so the bump is explicit
  and auditable.
- Follow-ups: cloud-engineer edits `providers.tf:19`, re-runs `init -backend=false` + `validate`, and commits
  `platform/connectivity/.terraform.lock.hcl`. If validate surfaces *further* schema drift in `dns.tf` after
  init finally resolves, treat it under ADR-018 (same reconcile-to-pinned-schema rule) — see task 4 note.

---

### ADR-016: Gap-closure execution sequence (G1–G6) — plan of record

- **Date:** 2026-06-25
- **Section:** Cross-cutting (slots into Sections 8, 9, 11, 12)
- **Status:** Accepted
- **Decision makers:** claude (architect); user to approve cost OQs (OQ-009, OQ-010)

**Context:**
The 2026-06-25 fidelity analysis (ARCHITECTURE.md "ALZ Reference Architecture Fidelity Map") identified
six gaps (G1–G6) vs the Microsoft ALZ Hub & Spoke reference (diagram 2026-04-02). The user directed that
**all gaps be closed**, sequenced by the architect, then handed to the engineering roles under the
reviewer gate. ADR-010…ADR-015 below record the per-gap close/deviation calls; this ADR records the
ordering and the hand-off contract.

**Decision:**
Close G1, G2, G4, G6 outright. Close G3 (DDoS) and G5 (Sandbox/Online subs) **conditionally on user
cost approval** (OQ-009, OQ-010); if not approved, both remain *documented deviations* with the
implementation pre-staged behind a disabled feature flag. Execute in five waves with explicit
dependencies, detailed in `docs/gap-closure-plan.md`:

1. **Wave 1 — G6 Bastion** (connectivity hub; flip existing module flag). No new module.
2. **Wave 2 — G4 corp-a1 backup vault** (parity with corp-a2). Independent; can run parallel to Wave 1.
3. **Wave 3 — G1 Identity subscription domain services** (Entra Domain Services — see ADR-010). New
   `platform/identity/domain-services.tf` + identity VNet + RSV. Depends on connectivity hub (peering)
   and reverses OQ-002.
4. **Wave 4 — G2 Compliant VM template** (Compute Gallery + image definition + Guest Configuration +
   backup policy + tag enforcement). Depends on G4-pattern backup vault precedent; consumes the FinOps
   tag initiative (ADR-008).
5. **Wave 5 — G3 DDoS (conditional) + G5 Sandbox/Online subs (conditional)**. Gated on OQ-009/OQ-010.

**Alternatives considered:**
- Close everything in one mega-session — rejected: violates the one-section-per-session rule and the
  reviewer gate; G1 and G2 alone are each a full section's worth of IaC.
- Defer G1 again — rejected: the user explicitly reversed the deferral; G1 is the only platform pillar
  with zero resources and is the highest-value gap to close.

**Consequences:**
- Positive: an ordered, dependency-aware backlog the cloud-engineer/devsecops-engineer execute one wave
  per session; each wave is independently reviewable and revertible.
- Negative / trade-offs: full closure spans ~5 build sessions plus review; idle cost rises (see per-ADR
  deltas — roughly +$130–190/mo for G1+G2+G4+G6, before the conditional G3/G5).
- Follow-ups: OQ-009 (DDoS cost), OQ-010 (real Sandbox/Online subs) must be answered before Wave 5.

---

### ADR-015: G6 — Deploy Azure Bastion in the primary hub (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (connectivity)
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
The reference diagram places Azure Bastion in the connectivity hub for secure management-plane access to
VMs with no public IP. The repo sets `bastion = false` in both hubs. Closing G1 (Entra DS) and G2 (image
build VM) introduces VMs that need RDP/SSH without public exposure, so Bastion becomes load-bearing.

**Decision:**
CLOSE. Enable Bastion in the **primary** hub only via the existing
`avm-ptn-alz-connectivity-hub-and-spoke-vnet` module's `enabled_resources.bastion = true` plus a
`bastion` config block (Standard SKU, dedicated `AzureBastionSubnet` /26). Secondary hub stays
`bastion = false` to control idle cost; DR-region VM access in a drill routes via the primary hub or a
just-in-time portal Bastion. No new module — this is a config change to a module already in state.

**[Amended 2026-06-27 — on-demand cost posture]:** per the gap-closure cost decision (Entra DS +
on-demand Bastion), Bastion is gated behind **`var.enable_bastion` (default `false`)**, not always-on.
Idle cost is therefore **$0**; operators set `enable_bastion = true` + apply (via `deploy.yml`) to bring
it up on demand, and `false` + apply to remove it. The "Negative" consequence below is superseded.

**Alternatives considered:**
- Bastion in both hubs — rejected: doubles idle cost (~$280/mo) for a POC; secondary-region interactive
  access is rare and can be served by the primary or temporary deployment.
- Native `azurerm_bastion_host` outside the module — rejected: the pattern module owns the hub VNet;
  using its native toggle keeps subnet/IP wiring inside one module and avoids a split-brain VNet.
- Developer SKU Bastion — rejected: does not support the per-VNet peering reach needed across spokes.

**Consequences:**
- Positive: secure management access to Entra DS DCs and the image-build VM with no public IPs; closes
  the reference gap with zero new modules.
- Negative: ~$140/mo idle for the Standard SKU instance + its public IP.
- Follow-ups: cloud-engineer adds the `AzureBastionSubnet` prefix to the hub subnet locals; verify the
  module input shape for `bastion` against v0.17.1 before writing.

---

### ADR-014: G5 — Keep Sandbox + Online collapsed into the shared LZ sub (DEVIATION, conditional close)

- **Date:** 2026-06-25
- **Section:** 9 / 12
- **Status:** Accepted (as deviation) — conditional close tracked in OQ-010
- **Decision makers:** claude (recommends keep-as-deviation); user may override via OQ-010

**Context:**
ADR-003 collapsed the Sandbox and Online archetypes into the single shared Landing Zones subscription to
keep the POC within Visual Studio benefit limits (idle ~$80–150/mo). The reference diagram shows Sandbox
and Online as **separate subscriptions**. The Sandbox and Online **management-group nodes already exist**;
only the subscription boundary is simulated.

**Decision:**
Recommend KEEP-AS-DEVIATION for the POC. Provisioning two more subscriptions is a billing/tenant action
that (a) cannot be done in Terraform without the subscription-vending pattern and EA/MCA billing-account
privileges the POC does not have, and (b) adds no new *architectural* construct — the MG nodes, policy
inheritance, and RG segmentation already demonstrate the boundary. This is a **subscription-count**
fidelity gap, not a capability gap. The user wants all gaps addressed: if faithful multi-sub is required,
OQ-010 captures the override — moving `online-p1` (and a sandbox placeholder) into real subscriptions via
`azurerm_subscription` association under the existing MG nodes once two more sub IDs are supplied.

**Alternatives considered:**
- Provision two real subs now via `azurerm-subscription`/EA vending — rejected for POC: requires billing
  scope the VS-benefit account lacks; risks cost and provisioning failure mid-build.
- Use `avm-ptn-lz-vending` to create the subscriptions — valid production path; deferred to OQ-010
  because it presumes an EA/MCA enrollment account ID the POC does not have.

**Consequences:**
- Positive: no extra idle cost; MG-level boundary already demonstrable; ADR-003 stays coherent.
- Negative: subscription count (5) is below the reference's 7+; documented as a known, intentional POC
  scope limit. Reviewer must accept the deviation explicitly.
- Follow-ups: if OQ-010 is answered "provision real subs," this ADR is superseded and Wave 5 binds
  `online-p1` + a sandbox RG-set to two new subscription IDs under the existing Online/Sandbox MG nodes.

---

### ADR-013: G3 — Azure DDoS Network Protection plan (conditional close, cost-gated)

- **Date:** 2026-06-25
- **Section:** 8 (connectivity)
- **Status:** Accepted (pre-staged, disabled) — conditional close tracked in OQ-009
- **Decision makers:** claude (recommends pre-stage disabled); user decides via OQ-009

**Context:**
The reference diagram shows an Azure DDoS Network Protection plan attached to the hub VNet (protecting
public-facing workloads, e.g. online-p1's AFD/App Gateway). DDoS Network Protection is **~$2,944/mo flat**
(plan covers up to 100 public IPs). The POC's whole-platform idle target is ~$80–150/mo (ADR-003); DDoS
alone is ~20–35x the entire rest of the platform.

**Decision:**
CLOSE *conditionally*. The cloud-engineer writes the construct now — `Azure/avm-res-network-ddosprotectionplan/azurerm`
v0.3.0 (verified on registry 2026-06-25) creating the plan, plus wiring `ddos_protection_plan` onto the
hub VNet and online-p1 spoke VNet — but **behind `var.enable_ddos_protection` defaulting to `false`**.
With the flag false the plan is not created and the repo carries no idle DDoS cost; the documented
deviation in ARCHITECTURE.md is replaced by a one-line flag flip. The user answers OQ-009 to decide
whether to set the flag `true` for any live/faithful-posture demo. This satisfies "all gaps addressed"
(the capability is built and one toggle away) without forcing ~$3k/mo on a portfolio POC.

**Alternatives considered:**
- Deploy DDoS unconditionally — rejected: ~$2,944/mo is indefensible for a portfolio POC; the user
  should make this call, not the architect.
- Leave as a pure documented deviation with no code — rejected: the user wants gaps *addressed*; a
  flag-gated, registry-verified construct is "addressed and one toggle away," strictly better than a doc
  note. (DDoS IP Protection per-IP tier was considered as a cheaper alternative but does not match the
  reference's network-tier plan and is per-IP billed — out of scope; noted in OQ-009.)

**Consequences:**
- Positive: faithful construct exists, version-pinned, reviewer-approved, zero idle cost while disabled.
- Negative: not *active* by default; a live demo of DDoS telemetry requires the flag + the monthly cost.
- Follow-ups: OQ-009 — user decides default flag state and whether to fund DDoS for any recorded demo.

---

### ADR-012: G4 — Add a corp-a1 backup vault (Recovery Services Vault) for parity (CLOSE)

- **Date:** 2026-06-25
- **Section:** 9 (landing zones)
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
corp-a2 has a Recovery Services Vault (`avm-res-recoveryservices-vault` v1.1.3, GeoRedundant). corp-a1 —
the **primary** workload spoke — has none. The reference shows backup in every landing-zone subscription.
This is an availability/asymmetry gap: the primary workload is currently less protected than its DR pair.

**Decision:**
CLOSE. Add an RSV to corp-a1's `rg-corp-a1-shared` using the **same module + pinned version already in
state for corp-a2** (`Azure/avm-res-recoveryservices-vault/azurerm` v1.1.3 — keep the existing pin for
parity and to avoid a cross-spoke version skew; latest is 1.1.11 and can be a separate uplift later).
Storage mode `ZoneRedundant` for corp-a1 (primary stays in-region for RPO; corp-a2 keeps GeoRedundant for
cross-region DR) and a default Azure Backup policy ready for the synthetic-workload VM / future IaaS.

**Alternatives considered:**
- Bump both spokes to v1.1.11 in the same change — rejected: version uplift is a separate concern from
  closing the parity gap; bundling risks a corp-a2 regression in a gap-closure change. Track uplift
  separately.
- GeoRedundant for corp-a1 too — rejected: corp-a1 is the primary; GRS doubles storage egress cost for a
  POC with no cross-region restore requirement on the primary. ZoneRedundant is the cost-right default.

**Consequences:**
- Positive: backup parity across both corp spokes; primary workload now protected; matches reference.
- Negative: ~$5–10/mo (vault is free; cost is protected-instance + storage once items are enrolled —
  near-zero until the synthetic VM is backed up).
- Follow-ups: G2's backup policy and the synthetic §13.4 VM can enrol into this vault later.

---

### ADR-011: G2 — Compliant VM template via Azure Compute Gallery + Guest Configuration (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (new platform component) / 12
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
Design area **G** of the reference calls for a "compliant VM template": a golden image in a shared gallery,
in-guest configuration (DSC / Guest Configuration), a backup policy, and required-tag enforcement. The repo
has **no** gallery, image definition, or guest-configuration construct anywhere. This is a genuine
capability gap, not just a count/cost gap.

**Decision:**
CLOSE. Compose three layers in a new `platform/management/compute-gallery.tf` (gallery is a shared platform
asset, lives in the Management subscription alongside the platform LAW/Automation):

1. **Azure Compute Gallery + image definition** — `Azure/avm-res-compute-gallery/azurerm` **v0.2.0**
   (verified on registry 2026-06-25; the module creates the gallery *and* image definitions via its
   `shared_image_definitions` map input). Define one Linux (Ubuntu 24.04 gen2) image definition to match
   the synthetic workload's distro; image **versions** are produced out-of-band by an Azure Image Builder /
   packer pipeline (documented as the build path; the POC ships the definition + a "bring your own version"
   note rather than running a full bake, to avoid a long-running build dependency).
2. **Guest Configuration assignment** — assign the built-in Azure Policy initiative *"\[Preview\]: Windows/
   Linux machines should meet requirements for the Azure compute security baseline"* (Guest Configuration /
   machineConfiguration) at the Landing Zones MG so any VM (synthetic §13.4 VM, future IaaS) is audited for
   baseline compliance. DEVIATION: full DSC authoring is out of POC scope; the built-in machineConfiguration
   audit initiative is the realistic, maintainable substitute and produces the same "in-guest compliance"
   signal.
3. **Backup policy + required-tag enforcement** — reuse the FinOps tag initiative (ADR-008) already at the
   Globaris root for tag enforcement; the backup policy is provided by the G4 RSV (ADR-012). No new tag
   policy authored.

**Alternatives considered:**
- Hand-author a full DSC configuration + Image Builder bake in-repo — rejected for POC: Image Builder runs
  take 30–60 min and need a build identity + staging RG; the gallery + definition + built-in
  machineConfiguration initiative demonstrates the design area without a brittle long-running bake.
- `avm-ptn-*` for image building — none confirmed published on registry (only the resource-level gallery
  module exists); per CLAUDE.md rule 5 we do not depend on unverified pattern modules.

**Consequences:**
- Positive: design area G is represented end-to-end (gallery, definition, in-guest baseline audit, backup,
  tag enforcement) using one verified AVM module + built-in policy; no custom policy JSON.
- Negative: no actual image *version* is baked by default — the gallery ships empty of versions until a
  packer/Image Builder run populates it. Documented as a follow-up, not a gap in the construct itself.
- Follow-ups: optional §13.x — add an Azure Image Builder template that bakes a version into the definition;
  enrol the baked image's VMs into the G4/corp-a1 RSV.

---

### ADR-010: G1 identity mode — Microsoft Entra Domain Services (reverses OQ-002 "none") (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (Identity subscription)
- **Status:** Accepted — supersedes the OQ-002 "none" resolution (2026-05-14)
- **Decision makers:** claude (architect) — user had deferred the DCs-vs-Entra-DS choice to the architect

**Context:**
G1 is the highest-value gap: the Identity subscription is the only platform pillar with zero resources
(`identity_mode = "none"`, OQ-002). The reference shows the Identity sub hosting either self-managed AD DS
domain controllers on IaaS **or** Microsoft Entra Domain Services, plus an identity VNet and a backup vault.
The user deferred the DCs-vs-Entra-DS decision to the architect and flagged the POC as cost-sensitive
(~$80–150/mo idle target). Verified 2026-06-25: current 2026 CAF identity guidance favours an
"AD-minimization", cloud-first posture — managed **Microsoft Entra Domain Services** over self-managed DCs
when AD DS capability is needed. No AVM module exists for Entra DS (registry 404 for
`avm-res-aad-domainservice`); the native `azurerm_active_directory_domain_service` resource is current
(API 2021-05-01, not deprecated; requires a one-time DS service-principal pre-step in the tenant).

**Decision:**
CLOSE with **Microsoft Entra Domain Services (managed)** as `identity_mode = "entra-ds"`. Reverses the
OQ-002 "none" resolution. The cloud-engineer builds, in `platform/identity/` (which today holds only the
CA/PIM policies):

- An **identity VNet** via `Azure/avm-res-network-virtualnetwork/azurerm` (repo pin **0.17.1**, the version
  already in state across spokes) with a dedicated Entra DS subnet + NSG carrying the
  Microsoft-mandated inbound rules, peered to the **primary hub** (ADR-009 hub).
- A native `azurerm_active_directory_domain_service` (no AVM module exists — `# DEVIATION:` documented),
  **Standard SKU** (single replica set; lowest cost ~$110/mo), `domain_name` from a new
  `var.identity_domain_name` (POC default `aadds.<orgprefix>.onmicrosoft.com` — ties to OQ-003).
- A **Recovery Services Vault** for the identity VNet's future DC/management VMs, same module/pin as G4.

**Alternatives considered:**
- Two B2s DCs on IaaS (`identity_mode = "ad-ds"`, ~$60/mo) — rejected as the default: cheaper, but
  contradicts 2026 CAF AD-minimization guidance, adds OS-patching/DC-promotion/replication management the
  POC would have to demo and maintain, and Entra DS better showcases a modern managed-identity posture.
  Kept as a documented *alternative mode* (the `var.identity_mode` toggle is retained so an operator can
  select `ad-ds` if a self-managed-DC demo is wanted) — but **not** the shipped default.
- Keep `none` — rejected: the user reversed the deferral and wants the gap closed.

**Consequences:**
- Positive: closes the top gap with the CAF-recommended managed option; less to manage/demo than DCs;
  identity VNet + RSV complete the pillar to match the reference. Cheaper than the assumed Entra DS price
  in OQ-002 if Standard SKU is used (~$110/mo vs the DCs' ~$60/mo — the delta funds "no DC management").
- Negative: ~$110/mo idle (Entra DS Standard) — the single biggest line in the gap-closure cost. Requires a
  one-time **manual** tenant pre-step (create the "Domain Controller Services" service principal +
  an `AAD DC Administrators` group) that Terraform cannot do — documented as an operator prerequisite.
  Entra DS only supports User-forest mode (no resource-forest) — acceptable for POC.
- Follow-ups: OQ-002 resolved to `entra-ds`; OQ-003 (domain name) becomes relevant — needs the POC domain.
  Confirm the `azurerm_active_directory_domain_service` argument shape against the provider pinned in
  `platform/identity` before writing; mark `# UNVERIFIED:` if the pin predates the resource's current schema.

---

### ADR-009: Firewall Policy hierarchy — independent policies per hub (no shared parent for POC)

- **Date:** 2026-05-21
- **Section:** 3 — Multi-Region DR Topology
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
PROMPT.md §3 requires a shared Azure Firewall Policy with a parent policy in the primary hub and a child policy in the secondary hub (inheriting via `base_policy_id`). The hub VNets are deployed via `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet/azurerm` v0.17.1, which creates firewall policies internally and does not expose a `base_policy_id` input in the `firewall_policy` configuration block.

**Decision:**
Each hub has an independent Azure Firewall Premium policy with identical configuration (IDPS Alert mode). A shared parent policy is not implemented for the POC. This is documented as a DEVIATION in `platform/connectivity/dr.tf`.

**Alternatives considered:**
- Fork the hub module to expose `base_policy_id` — rejected; forking AVM modules breaks the upgrade path and adds maintenance burden for a POC.
- Migrate firewall policies to standalone `azurerm_firewall_policy` resources outside the module, then link via `base_policy_id` — valid production path; deferred to Section 12 hardening because it requires refactoring the hub module invocation.
- Create a disconnected parent policy resource — rejected; dead code that isn't wired to anything is misleading in a demo context.

**Consequences:**
- Positive: Hub module stays unmodified; upgrade path to newer AVM versions preserved.
- Negative: Rule changes must be applied to both hub policies independently until production path is taken.
- Follow-ups: Section 12 should migrate firewall policies out of the hub module and establish the parent/child hierarchy.

---

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
