# CI/CD Deploy & Teardown Design

> **Status:** Design (architect). Implementation owned by `devsecops-engineer`.
> **Section:** 10 (Pipeline & Tooling) — extends the bootstrap pipeline.
> **ADR:** [ADR-019](../DECISIONS.md#adr-019-cicd-deploy--teardown--parameterized-deployyml--guarded-teardownyml-two-environments)
> (teardown mechanics amended by [ADR-020](../DECISIONS.md#adr-020-teardown-mechanics--uniform-terraform-destroy-supersedes-the-adr-019-brute-force-split))
> **Last updated:** 2026-06-27

This document specifies how CI/CD deploys and tears down the ALZ POC. It is the design the
`devsecops-engineer` implements; it does not contain final workflow YAML. Where exact action
versions / inputs are load-bearing they are named; everything else follows the conventions already
in `.github/workflows/plan-on-pr.yml` and `apply-on-merge.yml`.

---

## 1. Requirements (verbatim intent)

CI/CD must be able to:

1. **Deploy each landing zone (or any single platform root) individually.**
2. **Deploy the entire environment** — all roots, in dependency order.
3. **Tear down everything.**

All via **OIDC** (no stored secrets), appropriately **gated** (teardown is destructive).

---

## 2. The 10 roots and their apply order

The environment is composed of **10 Terraform roots**. `bootstrap/` is the state backend + OIDC
federation; it is a special one-time root (local state — ADR-005) and is treated separately from the
9 backend-state roots that the deploy/teardown workflows iterate over.

| # | Root | State key | Subscription (provider) | Backend `-config` rel. path | Depends on (apply) |
|---|------|-----------|--------------------------|------------------------------|--------------------|
| 0 | `bootstrap/` | local (ADR-005) | Management | — (local) | — |
| 1 | `platform/management-groups` | `platform/management-groups/terraform.tfstate` | Tenant root / Management | `../../envs/poc.backend.hcl` | bootstrap |
| 2 | `platform/management` | `platform/management/terraform.tfstate` | Management | `../../envs/poc.backend.hcl` | 1 |
| 3 | `platform/connectivity` | `platform/connectivity/terraform.tfstate` | Connectivity | `../../envs/poc.backend.hcl` | 2 |
| 4 | `platform/identity` | `platform/identity/terraform.tfstate` | Identity (Entra/CA) | `../../envs/poc.backend.hcl` | 1 |
| 5 | `platform/security` | `platform/security/terraform.tfstate` | Security | `../../envs/poc.backend.hcl` | 2 |
| 6 | `landing-zones/corp-a1` | `landing-zones/corp-a1/terraform.tfstate` | Landing Zones | `../../envs/poc.backend.hcl` | 3, 5 |
| 7 | `landing-zones/corp-a2` | `landing-zones/corp-a2/terraform.tfstate` | Landing Zones | `../../envs/poc.backend.hcl` | 3, 5 |
| 8 | `landing-zones/online-p1` | `landing-zones/online-p1/terraform.tfstate` | Landing Zones | `../../envs/poc.backend.hcl` | 3, 5 |
| 9 | `synthetic` | `synthetic/terraform.tfstate` | Landing Zones | `../envs/poc.backend.hcl` | 6, 7, 8 |

> **Path gotcha (load-bearing):** `synthetic/` is one directory level shallower than every other root,
> so its backend/var-file relative paths are `../envs/...`, **not** `../../envs/...`. The matrix job
> must compute the backend-config path from the root depth, or special-case `synthetic`. This is
> already handled inconsistently in `apply-on-merge.yml` (the `synthetic` job hard-codes `../envs/`);
> the new parameterized workflow must preserve that behavior.

**Apply order (topological):**

```
bootstrap
  → 1 management-groups
      → 2 management ───┬─→ 3 connectivity ─┐
      │                 └─→ 5 security ──────┼─→ 6 corp-a1 ─┐
      └─→ 4 identity                         │   7 corp-a2  ├─→ 9 synthetic
                                             └─→ 8 online-p1┘
```

**Parallelism:** roots 6/7/8 (the three spokes) are mutually independent and parallelize once
3 + 5 are done. Root 4 (identity) parallelizes with the 2→3/5 chain (it only needs MGs). Everything
else is a strict chain.

**Teardown order = reverse:** `9 → (6,7,8) → (3,4,5) → 2 → 1 → [bootstrap]`. Destroying connectivity
before the spokes that peer to its hub, or MGs before the policy assignments scoped under them, fails
or orphans. Teardown uses `terraform destroy` for every root in this reverse order (§6, ADR-020); the
`az group delete` brute force is a deferred manual fallback, not the default.

---

## 3. Decision: workflow structure

**One parameterized `workflow_dispatch` workflow** (`deploy.yml`) for plan/apply across a single root
**or** all roots, **plus a separate `teardown.yml`** for destroy, **plus the existing `plan-on-pr.yml`**
for always-on PR plans. Rationale:

- A single dispatch entrypoint for **plan/apply** satisfies requirements 1 and 2 with one `target`
  input (`all` or a specific root) and one `action` input (`plan` | `apply`). This is the kit's proven
  `manual-deploy.yml` model (LESSON 17: deploys explicit, not merge-triggered).
- **Teardown is split into its own workflow** (`teardown.yml`, the kit's `cleanup-demo.yml` model) — not
  a third `action` value on the deploy workflow — because destroy needs *stronger and different* guards
  (typed confirmation + a dedicated environment) and a *reverse* ordering engine. Keeping destroy in a
  separate file makes the blast radius obvious in the Actions UI and lets the two workflows gate on
  **different GitHub Environments** (§7).
- `plan-on-pr.yml` stays as-is: PRs run **plan only**, no apply, no credentials beyond read. It is the
  always-on safety net (LESSON 21 spirit — cheap, always runs).
- `apply-on-merge.yml` is **retired / converted to plan-only or deleted** by devsecops. Merge-to-main
  auto-apply contradicts LESSON 17 and the destroy-then-recreate demo cadence. (Flagged in §9.)

### Workflow inventory (target state)

| Workflow | Trigger | Action | Gate | Replaces |
|----------|---------|--------|------|----------|
| `plan-on-pr.yml` | `pull_request` → main | plan all roots, comment | none (read-only) | keep |
| `deploy.yml` | `workflow_dispatch` | plan **or** apply; `target` = one root \| `all` | `production` env on apply | new (kit `manual-deploy`) |
| `teardown.yml` | `workflow_dispatch` | destroy; `target` = one root \| `all` | `production-destroy` env + typed confirm | new (kit `cleanup-demo`) |
| `bootstrap.yml` | `workflow_dispatch` | apply bootstrap root (one-time / re-bootstrap) | `production` env | new (kit `bootstrap`) — optional, see §8 |

---

## 4. `deploy.yml` — inputs and behavior

### Inputs (`workflow_dispatch.inputs`)

| Input | Type | Values | Default | Purpose |
|-------|------|--------|---------|---------|
| `target` | choice | `all`, `platform/management-groups`, `platform/management`, `platform/connectivity`, `platform/identity`, `platform/security`, `landing-zones/corp-a1`, `landing-zones/corp-a2`, `landing-zones/online-p1`, `synthetic` | `all` | which root(s) to act on |
| `action` | choice | `plan`, `apply` | `plan` | dry-run vs apply |

> `target` is a **`choice`** input enumerating the exact root paths so an operator cannot ffree-type a
> non-existent path. The list mirrors the matrix in `plan-on-pr.yml`.

### Requirement 1 — per-root deploy

When `target != all`: a single job runs `init → plan` and (if `action == apply`) `apply` for that one
root. This is the "deploy a single landing zone or platform root" path. `apply` runs only after the
`production` environment approval (§7).

### Requirement 2 — full-environment deploy

When `target == all`: run all 9 backend-state roots **in dependency order**. **Recommended
implementation: a sequential job chain that mirrors `apply-on-merge.yml`'s `needs:` graph**, not a
matrix. Rationale:

- Terraform roots have **hard cross-root ordering** (MGs before policy, hub before spokes). A matrix
  runs jobs concurrently and cannot express "6/7/8 wait for 3 and 5"; faking it with `max-parallel: 1`
  loses the legitimate parallelism (spokes, identity) and still can't encode the partial order.
- The `needs:`-chained job graph already exists and is correct in `apply-on-merge.yml`. The new
  `deploy.yml` reuses that exact graph, with two changes: trigger is `workflow_dispatch` (not push),
  and each job's apply/plan is selected by the `action` input.
- Legitimate parallel fan-out is preserved by the graph: `identity` runs alongside `management`’s
  downstream chain; `corp-a1/a2/online-p1` run concurrently after `connectivity` + `security`.

To avoid duplicating ~9 near-identical jobs, devsecops **should** factor the per-root steps into a
**reusable workflow** (`_terraform-root.yml`, called via `uses:` + `with: { root, action }`) or a
composite action, and have `deploy.yml` call it once per node with the right `needs:`. This keeps the
ordering graph declarative and the per-root logic in one place. (Implementation detail — devsecops’s
call; the ordering contract in §2 is the binding part.)

---

## 5. `teardown.yml` — inputs and behavior

### Inputs

| Input | Type | Values | Default | Purpose |
|-------|------|--------|---------|---------|
| `target` | choice | same root list as `deploy.yml`, plus `all` | `all` | scope of destroy |
| `confirm` | string | (free text) | `""` | **typed confirmation** — must equal `destroy` (or the literal target name) or the workflow fails its first step |
| `include_bootstrap` | boolean | `true` / `false` | `false` | whether "all" also removes the **state backend + OIDC** (see §6 — **USER DECISION**) |

### Behavior

- **First job step is a guard** that fails the run unless `confirm` matches the required token. This is a
  cheap pre-check before any Azure login, so a fat-fingered dispatch never reaches `destroy`.
- When `target != all`: destroy that one root only. (Useful for tearing down a single spoke to cut cost.)
- When `target == all`: destroy the roots in **reverse dependency order** (§2). Implemented as the same
  `needs:` chain as `deploy.yml` but **inverted** - `synthetic` first, `management` last.
  **AMENDED 2026-08-01 (ADR-072 decision 6):** `platform/management-groups` is no longer part of
  this chain at `target=all` - it is destroyed by the Phase 2 management-group hierarchy cascade
  instead (`teardown-az-sweep.sh`, gated on `remove_mg_hierarchy`), because its objects are
  overwhelmingly child objects of MG container scopes with no cascading-delete equivalent inside
  Terraform's own per-object destroy model, and a live run measured its `terraform destroy`
  spending 5+ hours in Terraform's refresh prefix with zero deletes issued. Single-root
  `target=platform/management-groups` remains fully supported. See `teardown.yml`'s own header
  and `docs/teardown-redesign.md`'s Phase 1 section for the full account.
- `include_bootstrap == true` additionally removes the bootstrap layer **last** (see §6).

---

## 6. Teardown mechanics — uniform `terraform destroy` (with a brute-force fallback)

> **Reconciled 2026-06-27 (ADR-020, supersedes the ADR-019 split).** The decision below is **uniform
> `terraform destroy`** for every root (single-root *and* `target=all`). An earlier draft specified a
> brute-force / Terraform split as "the key correctness point"; that was reconciled to match the
> validated implementation (`teardown.yml` → `_tf-root.yml`, which runs `terraform destroy` for all roots
> in reverse order). The split is now a **deferred refinement** (see "Deferred refinement" below), not the
> design.

**LESSON 19 context.** In the AVD landing zone, `terraform destroy` reliably got stuck on Azure ordering
quirks — principally **session-host VM** churn (stopped-VM extension deletes, agent/DSC extension races) —
so the kit's `cleanup-demo.yml` uses **`az group delete` brute force**. **That risk profile does not
transfer to this repo.** This CAF POC has **no VMs**; its workload is PaaS and control-plane only
(App Service, SQL, VNets/peerings, Key Vault, Sentinel/Defender onboarding, policy/role/MG objects), all
of which `terraform destroy` removes cleanly, and Terraform's dependency graph correctly orders the
MG/policy teardown that `az group delete` cannot even reach (management groups and MG-scoped policy
assignments are **not** resource groups).

**Decision for this repo:**

- **Both per-root teardown (`target != all`) and full-environment reset (`target == all`) use
  `terraform destroy`**, in reverse dependency order (§2), via the same reusable `_tf-root.yml` the deploy
  path uses. Reasons:
  - It keeps **state consistent** so any root — or the whole environment — re-applies cleanly afterward,
    which is the point of the destroy-then-recreate demo cadence.
  - One mechanism for single-root and full-reset means **one code path** (`_tf-root.yml` `action=destroy`),
    no per-root branching on whether a root is RG-bound or control-plane.
  - Terraform's graph handles the **non-RG roots** (`platform/management-groups`, `platform/identity`,
    MG-scoped parts of `platform/security`) natively — these are exactly the objects `az group delete`
    cannot remove, so a Terraform-driven destroy needs no special-casing for them.
  - The VM-driven `terraform destroy` failures LESSON 19 documents **do not occur** here (no session hosts).

**State-account reachability:** the state SA lives in `rg-tfstate-mgmt-*` (its own RG, never targeted by a
`target=all` destroy), so state survives a full reset and the next deploy re-applies cleanly. Only
`include_bootstrap == true` removes the backend (next item).

### Deferred refinement — `az group delete` brute force (LESSON-19 fallback)

The brute-force split is **demoted to a fallback**, not the default mechanism:

- **When it applies.** If a `target=all` `terraform destroy` ever **wedges** on an Azure ordering quirk
  (the LESSON-19 failure mode), the operator falls back to a manual brute-force reset: `az group delete`
  on each regional RG-bound resource group in reverse order, then a re-run of `terraform destroy` (or
  targeted `az`/Terraform calls) for the **non-RG control-plane roots** (`platform/management-groups`,
  `platform/identity`, MG-scoped `platform/security`), which `az group delete` cannot remove. This is the
  same brute-force/Terraform split that was previously the design — it now lives only in the runbook.
- **Where it lives.** This manual fallback is part of the `include_bootstrap=true` scorched-earth runbook
  surfaced by the `teardown-bootstrap` job (the same path that also documents the manual `az ad app delete`
  and `rg-tfstate-mgmt-*` deletion). A stuck *non-bootstrap* `target=all` run uses the same per-RG
  `az group delete` commands without touching the backend.
- **Why deferred, not built.** Implementing the split in CI adds per-root branching and loses state
  fidelity (state must be reconciled or recreated) for a failure mode that the no-VM workload here is not
  expected to hit. Promoting it to the default would only be warranted if `target=all` `terraform destroy`
  proves unreliable in practice — at which point this section is re-opened with a new ADR.

### Does "tear down everything" include the bootstrap state backend? — **USER DECISION (see §10)**

Two coherent options, exposed as the `include_bootstrap` input:

- **`false` (default, recommended):** full reset destroys all 9 roots + their RGs but **keeps** the
  bootstrap state backend (state SA, CMK Key Vault, OIDC app/SP/federation). The environment can be
  redeployed immediately with `deploy.yml` — no re-bootstrap, no re-wiring of GitHub Variables/federated
  creds. This is the everyday "reset the demo" button.
- **`true` (full scorched-earth, AVD `cleanup-demo` style):** also deletes `rg-tfstate-mgmt-*` (state SA
  + CMK KV) and the OIDC app registration / federated credentials. After this, **the next deploy requires
  a manual re-bootstrap** (`bootstrap.yml` / local apply) and re-setting the three GitHub Variables. Only
  appropriate when fully decommissioning the POC.

This needs the user to confirm which is the intended meaning of "tear down everything," and it interacts
with the OIDC scope question in §7 (an SP that can delete its own backend + app registration).

---

## 7. Auth & gating model (OIDC only)

### OIDC, no secrets

All workflows authenticate via the existing federated `sp-alz-poc-cicd` app (bootstrap `identity.tf`).
No client secret exists and none is added. The three OIDC identifiers stay **GitHub repository
Variables** (`vars.AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID`) — **not Secrets** (LESSON 15). The
existing workflows already split these correctly into `vars.*` (login IDs) and `secrets.*` (the
per-resource TF_VAR values); the new workflows follow the same split.

### GitHub Environments (the gate)

| Workflow / action | Environment | Required reviewer | Other protection |
|-------------------|-------------|-------------------|------------------|
| `plan-on-pr.yml` (plan) | none | — | read-only, no apply |
| `deploy.yml` `action=plan` | none | — | dry-run only |
| `deploy.yml` `action=apply` | `production` | yes (1+ reviewer) | — |
| `teardown.yml` (destroy) | `production-destroy` | yes (1+ reviewer) | typed `confirm` input + (recommended) branch/actor restriction |

Two distinct Environments so destroy approval is a **separate, more deliberate** gate than apply, and so
the `production-destroy` environment can carry a tighter reviewer list and a wait timer if desired.

> **Reviewer status (2026-07-04, OQ-015):** the "Required reviewer" column above is the *target*. GitHub
> environment protection rules (required reviewers / wait timers) are a **paid, private-repo** feature. The
> repo now lives in the `Globaris-Inc` org (GitHub **Team**), but the protection-rule API still returns a
> billing 422 (entitlement not yet active/propagated). Both environments exist **ungated** in the interim,
> so the pipeline is functional; the reviewer gate is a one-command wiring once entitlement is live. See
> **OQ-015** for the resolution path and the free `confirm=apply` fallback guard.

### Branch protection (`main`) — repo ruleset

The default branch is protected by a **repository ruleset**, version-controlled at
[`.github/rulesets/main-branch-protection.json`](../.github/rulesets/main-branch-protection.json) so the
configuration is reproducible and reviewable like the rest of the platform. It enforces on `main`:

- **Pull request required** (no direct pushes), **≥1 approval**, stale approvals **dismissed on push**.
- **No force-pushes** (`non_fast_forward`) and **no branch deletion**.
- **Required status checks:** `terraform fmt -check` + all ten `validate — <root>` jobs from
  `validate.yml` (ADR-018). Contexts must match the job names **exactly** — note the em dash (`—`) in
  `validate — <root>`; if those jobs are ever renamed, update this ruleset in lock-step.
- **Repository admins can bypass** (`bypass_actors`) so a solo owner is not locked out (GitHub forbids
  approving your own PR).

**How it is applied:** GitHub does **not** auto-apply a repo-stored ruleset JSON — the file is the source
of record. Apply/update it via **Settings → Rules → Rulesets → New ruleset → Import a ruleset** (or
`gh api --method POST repos/<org>/<repo>/rulesets --input .github/rulesets/main-branch-protection.json`).
Applied to `Globaris-Inc/Azure-Architecture` on 2026-07-04.

**Scope (important):** this ruleset gates **code merges into `main`**, not the **deploy apply run** —
deploys are `workflow_dispatch`-triggered (LESSON 17), so a merge never auto-applies. The apply-run gate is
the environment reviewer / typed-confirm guard tracked separately in **OQ-015**.

### Load-bearing gap — federated-credential subjects must be added (FLAG)

**The current bootstrap only federates two subjects** (`identity.tf`):

- `repo:<org>/<repo>:ref:refs/heads/main`
- `repo:<org>/<repo>:pull_request`

When a job references a GitHub **Environment**, the OIDC token's `sub` claim becomes
`repo:<org>/<repo>:environment:<env-name>` (confirmed against GitHub OIDC + Microsoft Entra workload
federation docs, 2026-06-27). **Neither `environment:production` nor `environment:production-destroy` is
currently federated.** Therefore the gated `apply`/`destroy` jobs **will fail Azure login** until two new
federated credentials are added to `azuread_application.oidc`:

- `repo:<org>/<repo>:environment:production`
- `repo:<org>/<repo>:environment:production-destroy`

A `workflow_dispatch` run on `main` that does **not** reference an environment uses
`repo:<org>/<repo>:ref:refs/heads/main`, which **is** already covered — so `action=plan` on a non-gated
job works today, but any gated job does not. **This is the single most important implementation
prerequisite** and is the first item in the devsecops hand-off (§9).

### OIDC SP scope (ties to ADR-006 / OQ-008)

The SP holds **Owner at Tenant Root MG** (ADR-006) plus `Storage Blob Data Contributor` on the state SA.
Owner-at-root is **sufficient for subscription-wide apply *and* destroy** across all 5 subscriptions,
including MG-scoped policy/role objects and the `az group delete` brute-force path — so no RBAC change is
needed to ship deploy/teardown. **This design therefore relies on ADR-006's deliberately broad scope**
(flagged here so the reliance is explicit and tracked under **OQ-008**). Two notes:

- For `include_bootstrap == true` (destroying the OIDC app registration / state backend), the SP must be
  able to delete its **own** Entra app registration. Owner (ARM) does not grant Entra app management —
  app deletion is a **Graph / Entra directory** permission, not an ARM role. So full scorched-earth
  teardown of the OIDC app likely **cannot** be done by the SP itself and should be a documented manual
  `az ad app delete` step, or left out of scope. (Another reason `include_bootstrap` defaults to `false`.)
- When OQ-008 scopes the SP down, the scoped role set **must** retain delete rights subscription-wide
  (e.g. Contributor per sub for `az group delete`, Resource Policy Contributor + RBAC admin at MG scope
  for the control-plane roots). Record teardown in the OQ-008 least-privilege analysis.

---

## 8. State reachability in CI

### Per-root backend init

Each root initializes the shared azurerm backend the same way the existing workflows do:

```
terraform init \
  -backend-config="<rel>/envs/poc.backend.hcl" \
  -backend-config="key=<root-path>/terraform.tfstate" \
  -input=false
```

- `poc.backend.hcl` carries `resource_group_name`, `storage_account_name`, `container_name = "tfstate"`.
- The **`key` is set per-root at init time** (one shared backend, one state blob per root) — already the
  established pattern. The matrix/job sets it from the root path.
- `<rel>` is `../../` for all roots **except `synthetic`** (`../`) — §2 path gotcha.
- Backend auth is OIDC (`ARM_USE_OIDC=true`, `use_oidc=true` semantics) — no storage keys, consistent
  with `shared_access_key_enabled = false` on the state SA. The SP's `Storage Blob Data Contributor`
  data-plane role (bootstrap `identity.tf`) is what makes backend reads/writes work.

### Deterministic state-backend naming (LESSON 18) — currently a GAP (FLAG)

LESSON 18 / the kit prescribe deriving the state SA + KV suffix deterministically from the subscription
ID (`substr(sha1(lower(sub_id)),0,8)`) so a re-bootstrap after teardown yields the **same** names and
`poc.backend.hcl` keeps working. **This repo's `bootstrap/main.tf` currently uses `random_string.suffix`
(6 chars) instead** — so after an `include_bootstrap=true` teardown, a re-bootstrap produces a **new**
SA/KV name and `poc.backend.hcl` must be re-pasted. This breaks the "tear down everything then redeploy
from CI with no manual edits" story for the scorched-earth case.

**Recommendation (for cloud-engineer, not part of this section's build):** migrate bootstrap naming to the
deterministic subscription-ID-derived suffix (LESSON 18) before relying on `include_bootstrap=true` in
CI. Until then, scorched-earth teardown is followed by a manual `poc.backend.hcl` update — document this
in the teardown runbook. The default (`include_bootstrap=false`) path is unaffected because the backend
is never destroyed.

### Firewalled state account (LESSON 16)

The state SA is `default_action = "Deny"` with an `ip_allow_list`. Hosted runners' egress IPs are not
fixed, so backend `init` can be blocked. Options for devsecops (pick one, document it):

- Add/remove the runner egress IP around `init` (`az storage account network-rule add/remove`) — the AVD
  pattern's firewalled-state handling.
- Or keep GitHub Actions IP ranges in `ip_allow_list` (brittle, large) — not recommended.
- Or a private/self-hosted runner — out of scope for the POC.

This is an existing constraint, not introduced here, but the deploy/teardown workflows must account for it
or they'll hang at `init`.

**DECISION (devsecops, 2026-06-27).** The supported default is **option 2, as a documented prerequisite**:
the operator keeps the deployer/runner IP(s) (or, for hosted runners, a stable egress IP via an outbound
NAT — not the brittle full GitHub IP range) in bootstrap `var.ip_allow_list` so `init` reaches the state
SA. `_tf-root.yml` does **not** mutate the firewall by default — runner-IP churn is an operator concern,
and mutating a shared SA firewall from inside the parallel `target=all` graph would race (one job's
`network-rule remove` can cut another job's `init`).

For ad-hoc **single-root** runs from a hosted runner where the IP is not pre-listed, the reusable workflow
exposes an **opt-in** `manage_runner_ip` input (default `false`). When `true` it allow-lists the runner's
egress IP via `az storage account network-rule add` before `init` and removes it on exit
(`if: always()`), so the firewall never leaks a stale IP. It is **deliberately not wired into `deploy.yml`
/ `teardown.yml`** (which default it to `false`) and **must not** be enabled for `target=all` because of
the parallel-mutation race. Long-term fix = a private endpoint + self-hosted/private runner (Section 8),
which removes the firewall-mutation question entirely.

---

## 9. DevSecOps hand-off spec

Concrete, ordered build list. The architecture decisions above are fixed; these are implementation tasks.

1. **(Prerequisite, blocks everything gated)** Add two federated credentials to `azuread_application.oidc`
   in `bootstrap/identity.tf`:
   - subject `repo:${var.github_org}/${var.github_repo}:environment:production`
   - subject `repo:${var.github_org}/${var.github_repo}:environment:production-destroy`
   Re-apply bootstrap. Without these, gated apply/destroy fail at `azure/login`.
2. **Create the two GitHub Environments**: `production` (apply gate) and `production-destroy` (teardown
   gate), each with ≥1 required reviewer. Optionally restrict `production-destroy` to the `main` branch
   and a named approver, and add a wait timer.
3. **Author `deploy.yml`** (`workflow_dispatch`): inputs `target` (choice, the 9 roots + `all`) and
   `action` (choice `plan`|`apply`). Reuse the `needs:` ordering graph from `apply-on-merge.yml`. Gate
   `apply` jobs on `environment: production`. Preserve the `synthetic` `../envs/` path special-case.
   Factor per-root steps into a reusable/composite workflow to avoid 9× duplication.
4. **Author `teardown.yml`** (`workflow_dispatch`): inputs `target`, `confirm` (typed; must equal
   `destroy`), `include_bootstrap` (boolean, default false). First step = confirmation guard. Reverse
   ordering. **Full reset = `terraform destroy` for every root** (uniform), via the reusable `_tf-root.yml`
   `action=destroy`, in reverse dependency order — same mechanism as a single-root teardown, which keeps
   state consistent for a clean re-apply (§6, ADR-020). Gate on `environment: production-destroy`. The
   `az group delete` brute-force split is a **deferred refinement / manual fallback** for a stuck
   `target=all` run — document it in the runbook (§6), do not build it into the workflow.
5. **Retire merge-to-main auto-apply**: delete `apply-on-merge.yml` (or convert to plan-only). Keep
   `plan-on-pr.yml` as the always-on PR plan. (LESSON 17.)
6. **Add a preflight var-presence check** (LESSON 15) at the top of `deploy.yml`/`teardown.yml`: fail fast
   if `vars.AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID` are empty.
7. **Document the firewalled-state handling** (LESSON 16) actually used, in the workflow and the runbook.
8. **(Follow-up, not blocking this section)** Cloud-engineer: migrate `bootstrap` to deterministic
   (sub-ID-derived) state-backend naming (LESSON 18) before `include_bootstrap=true` is used in CI.

### Conventions to match (from existing workflows)

- `actions/checkout@v4`, `azure/login@v2`, `hashicorp/setup-terraform@v3`.
- `permissions: { id-token: write, contents: read }` (+ `pull-requests: write` only where commenting).
- Terraform version pin: existing files use `~> 1.9`; recent CI work pinned `1.15.6` (`>= 1.10`) for
  AVM storage/compute floors (LESSON 7). **Devsecops: confirm and use the single repo-wide pin / 
  `.terraform-version`; do not split versions across workflows.**
- OIDC IDs via `vars.*`; per-resource TF_VAR values via `secrets.*`; `ARM_USE_OIDC: "true"`.

---

## 10. User decisions required

> **RESOLVED.** Both decisions below are now settled — see OQ-012 (teardown scope) and OQ-013
> (approval model) in `OPEN-QUESTIONS.md`, captured in ADR-019. Summary:
> 1. Teardown scope = workload + platform only; `include_bootstrap` input **defaults to `false`**
>    (state backend + OIDC app are kept so redeploy is immediate). `true` = full decommission.
> 2. Approval model = **two** GitHub Environments — `production` gates apply in `deploy.yml`,
>    `production-destroy` gates teardown in `teardown.yml` — each with a required reviewer, plus a
>    typed `confirm=destroy` input on teardown.

1. **Teardown scope — does "tear down everything" include the bootstrap state backend + OIDC app?**
   - Recommended: **no by default** (`include_bootstrap=false`) — keep the backend so redeploy is
     immediate; expose `true` only for full decommission. Confirm this is acceptable, or state that
     scorched-earth (delete state SA, CMK KV, OIDC app) is the intended default.
   - Note: deleting the OIDC **app registration** needs Entra/Graph rights the SP likely lacks — that
     step would be a documented manual `az ad app delete`, not CI-automated.
2. **Approval model** — confirm: separate `production` (apply) and `production-destroy` (teardown)
   Environments, each with a required reviewer, and a typed `confirm=destroy` input on teardown. Confirm
   whether `production-destroy` should additionally have a wait timer and/or be restricted to specific
   approvers.

(Both logged to `OPEN-QUESTIONS.md` as OQ-012 / OQ-013 by the architect — now RESOLVED.)
