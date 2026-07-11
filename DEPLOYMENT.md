# DEPLOYMENT.md - Greenfield End-to-End Deploy Guide

> **Section:** 11 (Documentation Deliverables). Planned in [ADR-022](DECISIONS.md).
> **What this is:** the ordered operator procedure to stand up the whole platform from a clean tenant.
> **What this is not:** the pipeline internals. For workflow mechanics, gating, teardown, and the firewalled
> state account, [`docs/cicd-deploy-teardown.md`](docs/cicd-deploy-teardown.md) is the reference; this guide
> tells you which button to press, in what order, and how to verify each step. It does not duplicate that doc.
> **Last updated:** 2026-07-11

---

## 0. How the deploy works (one paragraph)

**Bootstrap is the only local Terraform step.** It creates the remote state backend and the OIDC federation.
**Everything after bootstrap is CI-driven** through the `Deploy (manual)` GitHub Actions workflow
([`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)), which authenticates with **OIDC (no stored
secrets)** and applies one Terraform root at a time in dependency order. You never run `terraform apply` locally
for a platform or landing-zone root. You dispatch the workflow with a `target` (one root, or `all`) and an
`action` (`plan` then `apply`); `apply` is gated by the `production` GitHub Environment.

---

## 1. Prerequisites

### 1.1 Azure tenant + subscriptions

| Requirement | Detail |
|-------------|--------|
| Entra ID tenant | One tenant; you (or the bootstrap operator) hold **Global Administrator** for the MG + Entra work |
| Subscriptions | **5** subscriptions, one each for **management, connectivity, identity, security, landing zones** |
| Elevated access | "Access management for Azure resources" enabled so the operator can create the Tenant Root MG grant |
| Region availability | `eastus2` (primary) and `centralus` (DR) available to the subscriptions |
| Entra DS pre-step | One-time manual tenant step (DS service principal + `AAD DC Administrators` group) - see [`platform/identity/README.md`](platform/identity/README.md) |
| Domain | An org-owned domain for the managed-domain FQDN (`identity_domain_name`, e.g. a subdomain like `aadds.<org>.org`) |

> **Offer caveat (observed on this POC).** The landing-zones subscription used here was **compute-restricted**:
> dedicated App Service and Azure SQL provisioning were capped by the subscription offer, so those tiers are
> gated **off** (ADR-031 / ADR-032). A production landing-zones subscription without those caps can flip
> `enable_sql` / `enable_app_service` to `true`. Plan the subscription type accordingly.

### 1.2 Bootstrap identity + state backend (the one local step)

The [`bootstrap/`](bootstrap/) root (local state - ADR-005, never committed) creates:

- The **OIDC app registration + service principal** (`sp-alz-poc-cicd`) with federated credentials - no client
  secret is ever created.
- The **remote state backend**: a CMK-encrypted, versioned, Entra-only (shared-key-disabled) Storage Account in
  `rg-tfstate-mgmt-*`, firewalled `default_action = Deny` (ADR-025). One state blob per root.
- The SP **RBAC**: the scoped role matrix from [ADR-021](DECISIONS.md) (Management Group Contributor at Tenant
  Root, Resource Policy Contributor + User Access Administrator at the Globaris / landingzones MGs, Contributor +
  UAA at each of the 5 subs, Storage Blob Data Contributor on the state SA). ADR-006 (Owner at Tenant Root) is
  the historical build-phase grant that ADR-021 supersedes.

**Federated-credential subjects must include the gated environments.** Bootstrap must federate, at minimum:
`repo:<org>/<repo>:ref:refs/heads/main`, `repo:<org>/<repo>:pull_request`,
`repo:<org>/<repo>:environment:production`, and `repo:<org>/<repo>:environment:production-destroy`. Without the
two `environment:*` subjects, gated `apply` / `destroy` jobs fail at `azure/login`
(`docs/cicd-deploy-teardown.md` §7).

### 1.3 GitHub repository configuration

Split per LESSON 15 - **OIDC login IDs are Variables, per-resource values are Secrets** (never the reverse).

**Repository Variables** (`Settings -> Secrets and variables -> Actions -> Variables`):

| Variable | Purpose |
|----------|---------|
| `AZURE_CLIENT_ID` | OIDC app (client) ID for `azure/login` |
| `AZURE_TENANT_ID` | Tenant ID for `azure/login` |
| `AZURE_SUBSCRIPTION_ID` | Default subscription for the login context |

**Repository Secrets** - the `TF_VAR_*` values consumed by [`_tf-root.yml`](.github/workflows/_tf-root.yml).
The workflow maps these Secrets to `TF_VAR_*` env vars; supply each before the root that needs it (§3 lists which
root consumes which). The core set:

| Secret | Consumed by |
|--------|-------------|
| `AZURE_TENANT_ID` | all (as `TF_VAR_tenant_id`) |
| `MANAGEMENT_SUBSCRIPTION_ID`, `CONNECTIVITY_SUBSCRIPTION_ID`, `IDENTITY_SUBSCRIPTION_ID`, `SECURITY_SUBSCRIPTION_ID`, `LANDINGZONES_SUBSCRIPTION_ID` | all roots (provider sub selection) |
| `TERRAFORM_SP_OBJECT_ID` | policy remediation / role assignments |
| `BUDGET_ALERT_EMAIL`, `SECURITY_CONTACT_EMAIL` | management, security |
| `PRIMARY_HUB_VNET_ID` / `_NAME` / `PRIMARY_HUB_RG_NAME` / `PRIMARY_FIREWALL_PRIVATE_IP` and the `SECONDARY_*` set | identity + spokes (from connectivity outputs - see §3.4) |
| `PLATFORM_LAW_WORKSPACE_ID`, `PLATFORM_ACTION_GROUP_ID`, `PLATFORM_LAW_CUSTOMER_ID` | spokes + security (from management outputs) |
| `SQL_AAD_ADMIN_OBJECT_ID`, `SQL_AAD_ADMIN_LOGIN` | corp spokes (only if `enable_sql = true`) |
| `BREAK_GLASS_GROUP_OBJECT_ID`, `PIM_PRIVILEGED_GROUP_OBJECT_ID`, `PIM_APPROVER_GROUP_OBJECT_ID` | identity (PIM + CA) |
| `SENTINEL_OWNER_GROUP_OBJECT_ID`, `HONEYPOT_USER_PRINCIPAL_NAME` | security / synthetic |
| `AADDS_IMPORT_REPLICA_SET_ID` | identity - leave **unset** on greenfield (import block is a no-op; ADR-029) |

> The "deferred per-root Secrets" (the cross-root outputs - hub VNet IDs, firewall IPs, platform LAW / action
> group IDs) do not exist until an earlier root has been applied. You add them **between** steps, as §3.4 and
> §3.7 call out. Greenfield sequencing is: apply the producing root, read its `terraform output`, paste those
> values into the consuming root's Secrets, then apply the consuming root.

**GitHub Environments** (`Settings -> Environments`): `production` (gates `apply`) and `production-destroy`
(gates teardown), each with a required reviewer where the plan entitlement allows (reviewer gate status:
OQ-015). Both exist **ungated** in the interim, so the pipeline is functional either way.

### 1.4 Tooling versions

| Tool | Version | Where used |
|------|---------|------------|
| Terraform | **1.15.6** (pinned in `_tf-root.yml`; use the same locally for bootstrap) | CI + bootstrap |
| Azure CLI | 2.x | bootstrap, portal-value lookups |
| `azurerm` provider | `>= 4.0`, pinned per root | all roots |
| `azuread` provider | `>= 3.0`, pinned | identity |
| `alz` provider / library | `~> 0.21.0` / `platform/alz@2026.04.2` (ADR-023) | management-groups |

---

## 2. Deploy order (the dependency graph)

This is the topological order the `deploy.yml target=all` `needs:` graph enforces
(`docs/cicd-deploy-teardown.md` §2). Deploying out of order fails or orphans (e.g. spokes before the hub they
peer to). **Synthetic is deferred** (ADR-036 / ADR-037) and is not applied.

```
bootstrap  (local, one-time)
  -> 1 platform/management-groups
       -> 2 platform/management ──┬─> 3 platform/connectivity ─┐
       │                          └─> 5 platform/security ─────┼─> 6 corp-a1 ─┐
       └─> 4 platform/identity                                 │   7 corp-a2  ├─> (9 synthetic - DEFERRED)
                                                               └─> 8 online-p1┘
```

Parallelism the graph allows: **identity** runs alongside the management -> connectivity/security chain; the
**three spokes** run concurrently once connectivity + security are done.

---

## 3. Ordered deploy procedure

For every CI step the pattern is the same:

1. Open **Actions -> `Deploy (manual)` -> Run workflow**.
2. Set `target` to the root, `action = plan`. Review the plan output. (`plan` is ungated.)
3. Re-run with the same `target`, `action = apply`. **Approve the `production` environment gate** when prompted.
4. Run the step's validation, capture any `terraform output` the next step needs.

> **Firewalled state (JIT firewall, ADR-025).** The state SA is `default_action = Deny`. For **single-root** runs
> from a hosted runner, the workflow opens the SA (`manage_runner_ip`, auto-set when `target != all`) for the job
> window and restores `Deny` on exit. For `target = all`, the runner IP(s) must instead be pre-listed in bootstrap
> `ip_allow_list` (the documented prerequisite; the JIT flip is disabled on `all` to avoid a parallel-mutation
> race). See `docs/cicd-deploy-teardown.md` §8.

### Step 0 - bootstrap (local, one-time)

```bash
cd bootstrap
terraform init
terraform plan      # review: OIDC app + SP + federated creds, state SA (CMK, versioned, firewalled), RBAC
terraform apply
```

Then set the GitHub **Variables** and **Secrets** from §1.3, and confirm `envs/poc.backend.hcl` carries the
state SA name / RG / container that bootstrap produced. **Validate:** the OIDC app has the four federated
subjects (incl. both `environment:*`); the state SA is `default_action = Deny` with shared keys disabled.

> Re-bootstrap caveat: bootstrap names the state SA/KV with a random suffix, so a full scorched-earth teardown
> (`include_bootstrap = true`) yields a new name and `poc.backend.hcl` must be re-pasted (LESSON 18 gap,
> `docs/cicd-deploy-teardown.md` §8). The default teardown keeps the backend, so this only matters on full
> decommission.

### Step 1 - `platform/management-groups`

- **Creates:** the Globaris MG hierarchy (Platform / Landing Zones / Decommissioned / Sandbox and children),
  places the 5 subscriptions, assigns the ALZ policy initiatives (tag governance, deny-public-network, and the
  `Enable-DDoS-VNET` assignment set to `DoNotEnforce` at Connectivity + landingzones MGs - ADR-026).
- **Depends on:** bootstrap. **Secrets:** the 5 subscription IDs + `TERRAFORM_SP_OBJECT_ID`.
- **Run:** `target = platform/management-groups`, `plan` then `apply`.
- **Validate:** the MG tree exists with 5 subs placed; policy assignments present; no `Enable-DDoS-VNET`
  enforcement (else spoke/hub VNet creates will 403, ADR-026).

### Step 2 - `platform/management`

- **Creates:** the **platform Log Analytics workspace** (operations hub), budgets ($200/sub, $600/MG, alerting
  50/75/90/100%), the daily **cost export**, the **cost anomaly alert**, tag governance, the **platform action
  group**, and the **Automation Account** (Update Manager).
- **Depends on:** 1. **Secrets:** subscription IDs, `BUDGET_ALERT_EMAIL`.
- **Run:** `plan` then `apply`.
- **Carry forward:** `terraform output` -> set `PLATFORM_LAW_WORKSPACE_ID`, `PLATFORM_ACTION_GROUP_ID`, and the
  workspace GUID `PLATFORM_LAW_CUSTOMER_ID` as Secrets (consumed by security + spokes).

### Step 3 - `platform/connectivity`

- **Creates:** the two regional **hub VNets**, **Azure Firewall Premium** (IDPS) in each hub, **VPN Gateway
  `VpnGw1AZ`** (active-active) in the primary hub, **DNS Private Resolver**, the **89 private DNS zones** in
  `rg-dns-globaris-poc` linked to both hubs, global hub-to-hub peering, and the GZRS finops storage. DDoS stays
  off (`enable_ddos_standard = false`). Bastion is on-demand (`enable_bastion = false`).
- **Depends on:** 2. **Run:** `plan` then `apply`. (This is the longest, most expensive root - see COST.md.)
- **Carry forward (§3.4):** `terraform output` -> set `PRIMARY_HUB_VNET_ID`, `PRIMARY_HUB_VNET_NAME`,
  `PRIMARY_HUB_RG_NAME`, `PRIMARY_FIREWALL_PRIVATE_IP` and the `SECONDARY_*` equivalents as Secrets. **Identity
  and all three spokes consume these** - they cannot be applied until these Secrets exist.

### Step 4 - `platform/identity` (parallelizable with 2/3/5)

- **Creates:** the identity VNet (peered to the primary hub), **Entra Domain Services** (Standard managed
  domain, `identity_mode = "entra-ds"`), the identity **Recovery Services Vault**, PIM eligible assignments, and
  **8 Conditional Access policies** (report-only; `geo_block` gated off by default, ADR-030 - so 7 of 8 create).
- **Depends on:** 1 (MGs) + the primary-hub Secrets from step 3 for the peering. **Secrets:** identity sub ID,
  the PIM/break-glass group object IDs, `HONEYPOT_USER_PRINCIPAL_NAME`; leave `AADDS_IMPORT_REPLICA_SET_ID`
  **unset** on greenfield (the import block is a no-op - ADR-029).
- **Pre-step:** the one-time manual DS SP + `AAD DC Administrators` group (§1.1).
- **Run:** `plan` then `apply`. **Note:** the Entra DS create can take 1-3 hours; the CI OIDC assertion does not
  survive a multi-hour apply for the trailing `azuread` calls - ADR-029 documents the untaint / import recovery
  and the `deploy.yml` `action = untaint` / `force-unlock` state-recovery paths if a long apply is interrupted.
- **Validate:** managed domain `provisioningState: Succeeded`; 7/8 CA policies present.

### Step 5 - `platform/security`

- **Creates:** the **security Log Analytics workspace** (RBAC-isolated), **Microsoft Sentinel**, the **Defender
  for Cloud** Standard plans, **regulatory compliance** (NIST SP 800-53 R5 + CIS Azure Foundations 2.0), the
  security **Key Vault**, the MDC **Event Hub** export (1 TU), and the analytics rules.
- **Gated off by default** (need a Security Administrator directory role the CI SP lacks, or are latent debt):
  `enable_aad_diagnostics`, `enable_ueba`, `enable_aad_connector`, `enable_ti_connector`, `enable_mde_connector`,
  `enable_firewall_ti_rule` (ADR-033 / ADR-034). Result: the sub-scoped MDC connector + 10 of 11 analytics rules
  land; the tenant-scoped connectors are one flag-flip away once the directory role is granted.
- **Depends on:** 2 (needs the platform LAW customer ID / workspace ID Secrets from step 2). **Secrets:**
  security sub ID, `SECURITY_CONTACT_EMAIL`, `SENTINEL_OWNER_GROUP_OBJECT_ID`, `PLATFORM_LAW_CUSTOMER_ID`.
- **Run:** `plan` then `apply`. **Validate:** Defender plans Standard; Sentinel onboarded; compliance assignments
  at root MG.

### Step 6-8 - landing-zone spokes (parallel after 3 + 5)

Each spoke: `plan` then `apply`. All three consume the hub Secrets from step 3 and the platform LAW / action
group Secrets from step 2.

| Root | Creates | Notes |
|------|---------|-------|
| `landing-zones/corp-a1` | eastus2 network spoke - VNet, hub peering, NSG, UDR-to-firewall, RSV (ZRS), VNet flow logs + Traffic Analytics, policy compliance | App Service + SQL **gated off** (ADR-031/032). Network landing zone. |
| `landing-zones/corp-a2` | centralus DR cold-standby spoke - same shape, RSV GeoRedundant, geo-paired to corp-a1 | App Service + SQL gated off. DR topology. |
| `landing-zones/online-p1` | internet-facing spoke - **App Gateway WAF_v2** (`WAF_mode = Prevention`, `appgw_capacity = 1`) + **Static Web App** | **Live workload.** Public entry point. |

- **corp SQL only:** set `SQL_AAD_ADMIN_OBJECT_ID` / `SQL_AAD_ADMIN_LOGIN` and flip `enable_sql = true` **only**
  in an unrestricted subscription (else `ProvisioningDisabled`, ADR-031).
- **Validate:** spoke VNets peered to the correct regional hub; default route `0.0.0.0/0 -> firewall`; online-p1
  App Gateway healthy and reachable.

### Step 9 - `synthetic` - DEFERRED, do not deploy

`enable_synthetic_workload = false`. The synthetic root is repositioned toward a future Day-2 Operations and
Monitoring capability (ADR-036 / ADR-037, [`docs/operations-monitoring-design.md`](docs/operations-monitoring-design.md))
and is **not** applied. Skip this step.

---

## 4. Full-environment deploy (shortcut)

Once every consuming Secret exists (i.e. after at least one full manual pass, or when re-deploying after a
non-bootstrap teardown), you can run the whole graph in one dispatch:

- `target = all`, `action = plan` - review the aggregate plan.
- `target = all`, `action = apply` - the `needs:` graph applies all roots in order; each `apply` job hits the
  `production` gate. Synthetic is skipped by policy (gated off).

> `target = all` disables the per-job JIT state-firewall flip (race-prone in parallel), so the runner IP must be
> covered by bootstrap `ip_allow_list` first (§3 firewalled-state note; `docs/cicd-deploy-teardown.md` §8).
> First-time greenfield still needs the **per-root** order in §3 because the cross-root output Secrets do not
> exist yet.

---

## 5. What is CI-only vs local (be honest about it)

| Action | Where | Why |
|--------|-------|-----|
| Bootstrap (`apply`) | **Local** (or optional `bootstrap.yml`) | Local state, one-time; creates the very backend + OIDC the CI needs (ADR-005) |
| Every platform / landing-zone `apply` | **CI only** (`deploy.yml`) | OIDC federation, `production` gate, JIT state firewall - deploys are explicit dispatches, never merge-triggered (LESSON 17) |
| `plan` on any root | CI (ungated) or local | Local plan needs the state SA reachable + `-var-file` overrides; CI plan is the supported path |
| State recovery (`untaint`, `force-unlock`) | **CI only** (`deploy.yml` actions) | Pure state writes against the firewalled backend (ADR-029) |
| Teardown (`destroy`) | **CI only** (`teardown.yml`) | Reverse-order `terraform destroy`, `production-destroy` gate + typed confirm |

---

## 6. Teardown

Teardown is CI-driven and covered in full by [`docs/cicd-deploy-teardown.md`](docs/cicd-deploy-teardown.md)
(§5-§6) and the runbook - this guide does not duplicate it. In short: `teardown.yml`, `target = all`, typed
`confirm = destroy`, `production-destroy` gate, uniform `terraform destroy` in **reverse** dependency order
(ADR-020). `include_bootstrap` defaults to **false** (keeps the state backend + OIDC app so redeploy is
immediate); set it `true` only for full decommission (then re-paste `poc.backend.hcl`, per the LESSON 18 gap).
Single-root teardown (`target = <one root>`) is the cheap "cut cost on one spoke" path.

---

## 7. References

- [`docs/cicd-deploy-teardown.md`](docs/cicd-deploy-teardown.md) - pipeline mechanics, gating, teardown, firewalled state (authoritative)
- [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) + [`_tf-root.yml`](.github/workflows/_tf-root.yml) - the workflows
- [ARCHITECTURE.md](ARCHITECTURE.md) - topology, RTO/RPO, fidelity map
- [COST.md](COST.md) - per-component monthly estimate + FinOps levers
- [DECISIONS.md](DECISIONS.md) - ADRs (notably 019/020/021/022/025/026/029/031/032/033/034/036/037)
- [`platform/identity/README.md`](platform/identity/README.md) - the one-time Entra DS tenant pre-step
