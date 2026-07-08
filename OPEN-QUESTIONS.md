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

### OQ-020: Can Cost Management exports write to the keyless cost-exports SA?

- **Raised:** 2026-07-07 (cost-exports refresh-403 fix, cloud-engineer)
- **Section:** 7 — FinOps: Tagging & Budgets
- **Blocking:** No — does not block plan/apply; only the scheduled export RUNS may fail to deliver blobs.
- **Priority:** Medium

**Question:**
`stfinops...` has `shared_access_key_enabled = false`. The scheduled export write is performed by the
Cost Management service, not our CI SP, so the SP's new Storage Blob Data Contributor grant does not
authorize it. Microsoft supports exports to key-disabled/firewalled SAs via a system-assigned managed
identity on the export (newer CostManagement API versions), but `azurerm_subscription_cost_management_export`
in azurerm ~>4.71 exposes no `identity` block. After the next successful apply, verify whether export runs
actually deliver blobs to `cost-exports`.

**Options being considered:**
- A: Wait and verify — exports may succeed (trusted-service path). If blobs land, close this OQ.
- B: If runs fail, manage the export via `azapi` with a newer API version + system-assigned identity, then
  grant that identity Storage Blob Data Contributor on the SA.
- C: Re-enable shared keys on this one SA with a `# DEVIATION:` note (weakest, last resort).

**Update 2026-07-08 (constraint sweep):** Per the exports tutorial (learn.microsoft.com,
tutorial-improved-exports), Cost Management creates a system-assigned managed identity for a NEW export when
the creating principal holds `Microsoft.Authorization/roleAssignments/write` on the destination SA, and
auto-assigns that MI Storage Blob Data Contributor scoped to the container. Our CI SP holds User Access
Administrator at subscription scope (ADR-021 row 6), so it has that permission at create time. The MI flow
needs CostManagement API 2023-08-01+; whether azurerm ~>4.71 drives this resource with a new enough API
version is the remaining unknown. Outlook improved; still verify blob delivery after the first successful
apply (option A first).

**ANSWERED 2026-07-08 (run 28911617973) - CLOSED by ADR-027.** Live evidence refuted Option A: 4 of 5
export CREATES failed with `400: Key-based authentication is currently disabled on this storage account.
To proceed, please enable "Allow storage account key access"` - the azurerm ~>4.71 resource drives an
older CostManagement API that hard-rejects key-disabled destination SAs at PUT, so even resource creation
fails (not just scheduled delivery). User chose **Option B**: migrate the export in `modules/finops` to
`azapi_resource` (`Microsoft.CostManagement/exports@2025-03-01`) with `identity { type = "SystemAssigned" }`;
the SA stays keyless. Role grant relies on the documented service-side auto-assignment (creator SP holds
roleAssignments/write on the SA via UAA at sub scope); an explicit `azurerm_role_assignment` is the recorded
fallback if delivery fails. Option C (re-enable shared keys) rejected. The 5th export (identity sub) failed
only on a STALE "RP Not Registered" check - Microsoft.CostManagementExports was registered by the same
apply and the service check lagged; a plain rerun clears it. Full design, provider pins, state-migration
note (clean swap, nothing in state), and the remaining post-apply verification (blobs must land in
`cost-exports` after the first scheduled run) are recorded in **ADR-027**.

### OQ-019: DDoS governance spans two root modules — introduce one shared toggle so they can't diverge?

- **Raised:** 2026-07-06 (DDoS LinkedAuthorizationFailed root-cause, architect)
- **Section:** 2 — Management Group Hierarchy (policy) / 4 — Connectivity (plan)
- **Blocking:** No — ADR-026 (DoNotEnforce `Enable-DDoS-VNET` at the connectivity MG) unblocks apply now.
- **Priority:** Medium

**Question:**
DDoS is now governed in two separate root modules that were never linked: the **plan resource** in
`platform/connectivity` (gated by `var.enable_ddos_standard`, ADR/commit e2733db) and the
**`Enable-DDoS-VNET` Modify policy** assigned by `platform/management-groups` via `avm-ptn-alz`
(neutralised by ADR-026). This split is exactly what caused the outage: turning the plan off in
connectivity did nothing to the enforced policy that injected the placeholder plan id, so every VNet
create still failed. Should we introduce a single shared variable that drives both stacks — the plan
resource in connectivity AND the policy assignment enforcement/parameter in management-groups — so the
two cannot drift into an inconsistent state again?

**Options being considered:**
- A: One shared `enable_ddos_standard` (recommended default) consumed by both roots — when false, no plan
  and the `Enable-DDoS-VNET` assignment is DoNotEnforce; when true, create the plan and re-enforce the
  policy with the real plan id via `policy_default_values`. Single source of truth, no split-brain.
- B: Leave the two independent and rely on documentation (ADR-026 coupling note) to keep them consistent —
  simpler now, but re-opens the drift risk that caused this failure.

**Recommendation:** A — a single `enable_ddos_standard` wired into both the connectivity plan and the
management-groups policy assignment.

### OQ-018: Production-grade state-SA access — Private Endpoint + VNet/self-hosted runner egress (ADR-025 Option B follow-up)

- **Raised:** 2026-07-06 (CI state-backend 403 diagnosis, architect)
- **Section:** 10 — Pipeline & Tooling (state backend access)
- **Blocking:** No — ADR-025 Option A (JIT default_action Allow/Deny flip) unblocks CI now. This is the
  production-grade replacement for that time-boxed public-window trade-off.
- **Priority:** Medium

**Question:**
ADR-025 (Option A, accepted) unblocks CI by flipping the state SA `default_action` to Allow for the job
window and restoring Deny on exit. The trade-off is a ~2-3 min window in which the blob endpoint is publicly
reachable (still defended by Entra-only auth + RBAC + TLS + CMK), and it is single-root only (target=all
still relies on the permanent `ip_allow_list` prerequisite). The production-grade fix removes public exposure
entirely: put a **Private Endpoint** on the state SA (`privatelink.blob.core.windows.net` + private DNS zone),
set `public_network_access = Disabled`, keep `default_action = Deny`, and run CI on a **self-hosted or
VNet-injected runner** that egresses through that VNet. No firewall flip, no egress-IP roulette, no race.
When do we adopt this, and on what runner model?

**Options being considered:**
- A: Self-hosted runner in a CI/management VNet (container/VM scale set) + Private Endpoint on the state SA;
  `public_network_access = Disabled`. Most secure, most infra to own (runner lifecycle, VNet, private DNS).
- B: GitHub larger runners with a static outbound IP range, allow-listed permanently in bootstrap `ip_rules`
  (no Private Endpoint). Simpler than A, deterministic, but keeps public endpoint + requires the larger-runners
  plan (ADR-025 Option C).
- C: Stay on Option A for the POC lifetime; adopt A only when the environment graduates beyond POC (recommended
  default — the public window is time-boxed and RBAC/Entra/CMK-protected, acceptable for a portfolio POC).

**Note (leftover state cleanup):** the failed connectivity inits left `platform/connectivity/terraform.tfstate`
as a **0-byte blob with a broken (unlocked) lease**. No apply ever ran against it, so it holds no real state
and is **safe to overwrite on the next successful init** — Terraform will treat the empty blob as fresh state.
No manual cleanup required beyond confirming the lease is not held (verified unlocked/broken 2026-07-06).

---

### OQ-017: AVM module + provider version drift roll-up (staleness maintenance pass)

- **Raised:** 2026-07-05 (drift audit, code-reviewer)
- **Section:** cross-cutting (2, 5, 6, 8, 9)
- **Blocking:** No — staleness, not a known break. Do as a deliberate, verified maintenance pass, not ad hoc.
- **Priority:** Medium

**Question:**
Post-incident drift audit (see ADR-023 / WORKLOG 2026-07-05) found several exact-pinned AVM modules and one
provider constraint lagging upstream. None is a confirmed apply-breaker, but the same neglect produced the
`Enforce-EncryptTransit` failure. Bump deliberately (verify each changelog, re-plan the affected scope), not
in one blind sweep. Candidates (verified latest via registry API 2026-07-05):
- `avm-ptn-alz` **0.19.1 → 0.21.0** (`platform/management-groups/main.tf:32-33`) — the MG/policy engine; ADR-023
  follow-up (3). Compat cleared (root `alz ~> 0.21.0`, `azapi ~> 2.9.0` satisfy 0.21.0's floors). Re-plan MG scope.
- `avm-res-network-virtualnetwork` **0.17.1 → 0.19.0** (4 roots, lockstep: `landing-zones/corp-a1`, `corp-a2`,
  `online-p1` `main.tf`, `platform/identity/identity-network.tf`).
- `avm-res-recoveryservices-vault` **1.1.3 → 1.1.11** (3 roots: `corp-a1/backup.tf`, `corp-a2/main.tf`,
  `platform/identity/domain-services.tf`; upstream skips 1.1.8).
- LOW patch lag: `avm-res-web-serverfarm` 2.0.4→2.0.7; `avm-ptn-alz-connectivity-hub-and-spoke-vnet`
  0.17.1→0.17.3; `avm-ptn-network-private-link-private-dns-zones` 0.23.1→0.23.2.
- Provider drift: `azapi` pinned 3 ways — security `~> 2.4.0` (only root using `azapi_resource` directly, yet
  most stale), connectivity `~> 2.5`, management-groups `~> 2.9.0`. Standardize on one floor (`~> 2.9`).

**Options being considered:**
- A: Batch by module family across their lockstep roots, each with a re-plan of the affected scope, as each
  section comes up for deploy (recommended — ties the bump to a real plan review).
- B: One dedicated "dependency refresh" session bumping everything + full `validate`/plan sweep before resuming deploys.
- C: Defer all until each root's own deploy session forces the question.

### OQ-016: Built-in policies referenced without explicit `parameter_values` — PUT-time risk (management + security)

- **Raised:** 2026-07-05 (drift audit, code-reviewer)
- **Section:** 5 (management/policy) and 6 (Defender/Sentinel)
- **Blocking:** Yes — for the `platform/management` and `platform/security` apply runs (same class as ADR-023;
  invisible to `terraform validate`/`plan`, only ARM's policy-parameterization check at PUT rejects it).
- **Priority:** High

**Question:**
The drift audit flagged two spots that repeat the `Enforce-EncryptTransit` failure shape — a built-in policy
referenced with only a `reference_id`, inheriting the built-in's current default parameters (incl. `effect`),
which a newer built-in version can make ARM-invalid or newly-required:
1. `platform/management/main.tf:520-542` — `azurerm_policy_set_definition.deny_public_network_access` refs
   built-ins `1b8ca024-…`, `405c5871-…`, `34c877ad-…` with no `parameter_values`.
2. `platform/security/defender.tf:46-55` + `:201-215` — NIST 800-53 R5 `179d1daa-…` and CIS Azure Foundations
   v2.0.0 `06f19060-…` assigned with no params; code already carries `UNVERIFIED 2026-05-29` on the CIS
   GUID/benchmark version (1.4.0 vs 2.0.0 vs 2.1.0). Wrong/retired policySetDefinition GUID = hard PUT 404/400.
   Gated by `var.enable_regulatory_compliance`.

**Pre-apply mitigation (before those roots deploy):** for each built-in, `az policy definition show --name
<guid>` / `az policy set-definition show --name <guid>` to confirm it resolves and dump current param
defaults; where an `effect` param exists, pass it explicitly (`Audit|Deny|Disabled`) via `parameter_values`
rather than trusting the built-in default. Confirm the CIS GUID against the intended benchmark version.

**RESOLVED 2026-07-07:** Verified all 5 built-ins live (`az policy [set-]definition show`) and fixed.
- **Management (part 1):** the KV GUID was WRONG — `405c5871-…-58ad8008cbe8` returned `PolicyDefinitionNotFound`
  (would have hard-failed the set-definition PUT). Corrected to `405c5871-…-58e19d68ff5b` ("Azure Key Vault
  should disable public network access"). SQL `1b8ca024-…` + Storage `34c877ad-…` valid. All three now pass
  `effect` EXPLICITLY. Effect set to **Audit, not Deny** — code-review found Deny at the landingzones MG would
  hard-block the spoke NSG flow-log SAs (no `network_acls`) + the Section 13 synthetic layer (public-access by
  design). Audit governs/reports without blocking; enforce-later path (exemptions then Deny) documented in
  `platform/management/main.tf`. (User chose Audit 2026-07-07.)
- **Security (part 2): clean.** NIST `179d1daa-…` = "NIST SP 800-53 Rev. 5" (v14.19.0) and CIS `06f19060-…` =
  "CIS Microsoft Azure Foundations Benchmark v2.0.0" (v1.10.0) both resolve; CIS IS v2.0.0 as intended; 0
  required-no-default params. `defender.tf` UNVERIFIED note → VERIFIED. No code change beyond the comment.
- Committed with the management-deploy prep; **management apply unblocked.**

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

**User direction (2026-07-04):** keep the repo **PRIVATE** until all deployments are validated end-to-end;
find a private-compatible governance setup. Rules out Option A (public flip) for now.

**Finding (2026-07-04, retry with correct reviewer id `175745508`):** the required-reviewer PUT still returns
**HTTP 422 billing** — so the *account* backing `teeeke/Azure-Architecture` is not on a plan that supports
private-repo environment protection. (The CLI token lacks `read:user`, so `.plan` can't be confirmed via API.)
User believes they have "GitHub Pro"; likely the **Copilot Pro ≠ GitHub Pro** mix-up — needs manual verify at
github.com/settings/billing. Native reviewer wiring is a 1-command API call the moment GitHub **Pro** is
confirmed/active.

**Private-compatible path forward:**
- If GitHub **Pro** is actually active → wire required reviewers on both environments now (restores ADR-019),
  repo stays private.
- If not → either upgrade to Pro ($4/mo, private), OR add the **free typed `confirm=apply` guard** to
  `deploy.yml` apply jobs (documented deviation; hard-fails before azure/login; real reviewer gate layered on
  later). User leaned "no extra gate for now" believing Pro covered it — revisit once billing is verified.

**Update 2026-07-04 — repo moved to org `Globaris-Inc/Azure-Architecture` (PRIVATE).** Remote re-pointed;
Variables (3) + Secrets (7) + both Environments **survived the transfer** (no re-set needed). Org reads
`plan: team` (which includes private-repo environment protection), `teeeke` is an **active org admin member**.
**Yet required-reviewer AND wait-timer PUTs both still 422** ("billing plan does not support ... protection
rule") — ruled out: reviewer id, JSON payload shape, stale env metadata (deleted+recreated `production`
fresh under the org — still 422). Conclusion: GitHub-side **billing entitlement not active/propagated** for
the org's Team plan (post-transfer lag, or an unconfirmed/pending Team billing state). Not fixable from the
CLI.

**Needed from user:** at github.com/organizations/Globaris-Inc/settings/billing confirm **Team is active with
a valid payment method** (not trial/pending). Then either (a) tell me to **retry** the reviewer wiring (1
command — it will just work once entitlement is live), and/or (b) approve the **free typed `confirm=apply`
guard** on `deploy.yml` apply jobs as interim/defence-in-depth. Both environments currently exist **ungated**
so the pipeline is functional meanwhile.

**Decision 2026-07-04 (user):** set up **branch protection on `main`** (code-merge governance) instead of
chasing the environment reviewer gate now. **DONE** — a repository ruleset was imported to
`Globaris-Inc/Azure-Architecture` (no import errors) and the config is version-controlled at
`.github/rulesets/main-branch-protection.json` (+ `.github/rulesets/README.md`; documented in
`docs/cicd-deploy-teardown.md` §7). It enforces: PR required + ≥1 approval + dismiss-stale, no force-push /
no deletion, required checks (`terraform fmt -check` + the 10 `validate — <root>` jobs); repo admins bypass
(solo-owner safety). **Caveat recorded:** branch protection gates *merges to `main`*, NOT the deploy apply
run — deploys are `workflow_dispatch`-triggered (LESSON 17), so a merge never auto-applies.

**OQ-015 stays OPEN on the apply-run gate only:** the environment reviewer gate (blocked on Team billing
entitlement — retry when live) OR the free typed `confirm=apply` guard. Environments remain ungated until one
is in place.

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

**RESOLVED 2026-07-08:** Custom owned domain. The Entra DS managed-domain FQDN is set in
envs/poc.tfvars (`identity_domain_name`, subdomain of the org-owned domain; first label under the
15-char NetBIOS limit). IMMUTABLE once the managed domain is created - do not re-decide. Entra DS
requires no DNS verification for the managed-domain name.

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
