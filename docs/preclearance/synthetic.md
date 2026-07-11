# Pre-clearance: synthetic (first apply)

> Artifact of the deploy pre-clearance gate (see `docs/deploy-preclearance.md`).
> Prepared by: architect. Date: 2026-07-10. Status: **NO-GO as written.**
> Evidence: the full `synthetic/` root (`*.tf`, `variables.tf`, `providers.tf`, `README.md`), the shared
> `envs/poc.tfvars`, `.github/workflows/{deploy.yml,_tf-root.yml}`, the landing-zones live policy enumeration
> (`docs/preclearance/landing-zones.md`, live `az` 2026-07-10, same MG chain and same LZ sub the synthetic
> resources land in), `docs/preclearance/deprecation-audit.md` section 2.4, and the deployed-root ground truth
> in `WORKLOG.md` (Sections 6, 9, 13). This root has NEVER been applied (the layer has always been gated off).

---

## 0. Verdict up front

**NO-GO as written.** Three independent hard blockers, each of which fails the apply on its own:

1. **Missing dependency (dead data source).** The corp-a1 App Service that synthetic hard-references does not
   exist: `enable_app_service = false` (ADR-032, deployed off; the LZ-sub dedicated-compute quota ticket is
   still open). `data.azurerm_linux_web_app.corp_a1` is unconditional and fails at plan with a 404.
2. **Policy collision (Deny).** Every public-network synthetic storage account (3 of 4) and the decoy Key
   Vault land in the LZ sub under the `corp` MG, where `Deny-Public-Endpoints` / `StorageDenyPaasPublicIP`
   (Deny, enforced) fires. The OQ-024 landing-zone Waivers are RG-scoped to the spoke RGs and do NOT cover
   the synthetic RGs.
3. **Code bug (name length).** Three of the four storage-account names exceed the 24-character Azure limit
   with the live `org_prefix = globaris` + `environment = poc`, so their create is rejected.

Plus a config gate: `enable_synthetic_workload = false` in `envs/poc.tfvars`, so an apply with the standard
var-file plans **zero resources** and deploys nothing. This must be flipped to `true` to deploy anything, and
it must NOT be flipped until blockers 1 to 3 are fixed (otherwise the first real apply fails).

The path to GO is a small cloud-engineer batch (fix the SA names, gate or retarget the corp-a1 App Service
dependency), an OQ-024-style Waiver decision for the synthetic RGs, and one operator/user input if the
sign-in demo scenarios are wanted. Details below, then a crisp action list in section 8.

---

## 1. Deferred secrets / inputs (verified against `variables.tf` and the workflow)

**Correction to the brief:** `SENTINEL_OWNER_GROUP_OBJECT_ID`, `vip_user_object_ids`, and
`high_value_asset_resource_ids` are **not** synthetic variables. They belong to `platform/security` (already
deployed). `synthetic/variables.tf` declares none of them, so the synthetic apply consumes nothing from them.
The workflow does export `TF_VAR_sentinel_owner_group_object_id` globally, but for synthetic it is an unused
`TF_VAR_*` (no matching variable) and is silently ignored. Nothing for the user to provide there.

The actual synthetic input surface:

| Variable | Required? | Default | Wired in CI? | State for first apply |
|---|---|---|---|---|
| `landingzones_subscription_id` | **REQUIRED** (no default) | - | `TF_VAR_landingzones_subscription_id` <- `LANDINGZONES_SUBSCRIPTION_ID` secret | OK (secret present, sub exists) |
| `org_prefix` | **REQUIRED** (no default) | - | `envs/poc.tfvars` = `globaris` | OK |
| `environment` | **REQUIRED** (no default) | - | `envs/poc.tfvars` = `poc` | OK |
| `enable_synthetic_workload` | no | `false` | `envs/poc.tfvars` = **`false`** | **BLOCKER-config:** layer plans to zero until set `true` |
| `platform_law_workspace_id` | no | `""` | `TF_VAR_platform_law_workspace_id` <- `PLATFORM_LAW_WORKSPACE_ID` secret | Set (platform LAW). Non-empty => k6 + red-team sub-layers DO deploy => the storage/KV collisions are in scope |
| `honeypot_user_principal_name` | no | `""` | `TF_VAR_honeypot_user_principal_name` <- `HONEYPOT_USER_PRINCIPAL_NAME` secret | Empty => the 2 sign-in scenarios + impossible-travel west pole are SKIPPED gracefully (no failure). Needs a manually-created **disabled** Entra user to light up the sign-in demo. See below. |
| `cost_pattern_budget_alert_emails` | no | `[]` | `TF_VAR_cost_pattern_budget_alert_emails` <- `BUDGET_ALERT_EMAIL` secret | Non-empty => the $1 RG budget ships. Empty => skipped (other 4 anti-patterns still ship). Non-blocking. |
| `cost_guardrails_alert_emails` | no | `[]` | `TF_VAR_cost_guardrails_alert_emails` <- `BUDGET_ALERT_EMAIL` secret | Non-empty => action group + sub budget ship. Empty => skipped (Automation Account + runbooks still ship). Non-blocking. |
| `cost_pattern_vm_size` | no | `Standard_D4s_v5` | tfvars default | See section 3 (quota). |
| `red_team_geo_location` | no | `westeurope` | tfvars default | Must be outside `approved_sign_in_countries` (US/CA/GB) - westeurope satisfies that. OK. |

**None of the required variables is unset.** The apply-fatal input issue is `enable_synthetic_workload = false`
(config gate), not a missing secret.

**What the USER must provide (only if the sign-in demo scenarios are wanted):** a tenant-resident **disabled**
honeypot Entra user, created manually (Terraform does not manage it - synthetic carries no `azuread`
provider), and its UPN set into the `HONEYPOT_USER_PRINCIPAL_NAME` repo Secret. Per the project rule we ASK
rather than hunt: the user creates the disabled account (README section 13.3 has the two `az ad user`
commands) and supplies the UPN. If they do not, the layer still applies cleanly - the two sign-in scenarios
and the westeurope secondary CAE + its RG simply do not get created.

---

## 2. Dependencies on already-deployed roots

**What synthetic consumes (verified by reading every `.tf`): it has NO `terraform_remote_state` and NO data
source pointing at `platform/security`.** Its only cross-root inputs are:

- `var.platform_law_workspace_id` = the **platform LAW** (`law-platform-...`, management sub, from
  `platform/management`). Synthetic sends diagnostic settings (decoy KV AuditEvent, decoy-SA StorageRead/Write,
  online-p1 queue logs) and Container Apps console logs here.
- Deterministic-name data sources into the **LZ sub** landing zones:
  `data.azurerm_resource_group.corp_a1_workload` (`rg-corp-a1-workload-globaris-poc`),
  `data.azurerm_linux_web_app.corp_a1` (`app-corp-a1-globaris-poc`), and
  `data.azurerm_resource_group.online_p1_shared` (`rg-online-p1-shared-globaris-poc`).

**CRITICAL check - does synthetic reference the gated-off security resources (ADR-033/034)? NO.** Synthetic
does not reference `firewall_threat_intel_hit`, `dc-aad`, or `dc-ti` in any form (no remote state, no data
source, no output consumption). It only writes telemetry into the platform LAW. **The gated-off Sentinel
pieces cannot break the synthetic apply.** PASS. The security LAW is live and onboarded to Sentinel, so no
onboarding-dependent race applies to synthetic either (synthetic does not touch the Sentinel workspace).

**Name-drift check (PASS):** the deterministic names synthetic builds exactly match the landing-zone configs
(`landing-zones/corp-a1/main.tf` lines 56, 264; `landing-zones/online-p1/main.tf` line 57). The corp-a1
workload RG and the online-p1 shared RG both exist unconditionally, so those two data sources resolve.

**BLOCKER 1 - the corp-a1 App Service data source is dead.** The App Service tier on corp-a1 (and corp-a2)
was **gated off** at deploy time (`enable_app_service = false`, ADR-031/ADR-032; the landingzones-sub
offer-cap on dedicated App Service compute, quota support ticket still open per WORKLOG Section 9). So
`app-corp-a1-globaris-poc` does not exist in Azure, but `data.azurerm_linux_web_app.corp_a1` is unconditional
(`count = local.enabled`). It fails at **plan** with a "Web App not found" error. This kills:

- `corp_a1.tf`: the data source, the `azurerm_storage_account_blob_container_sas`, the `null_resource`
  `az webapp deploy`, and the `corp_a1_api_default_hostname` output.
- `k6.tf`: `TARGET_BASE_URL = data.azurerm_linux_web_app.corp_a1[0].default_hostname` - every k6 job points
  at a target that does not exist, and the reference fails at plan regardless.

Synthetic has **no flag** to skip only the corp-a1 App-Service dependency, so it cannot degrade gracefully as
written. Disposition is a DECISION (see **OQ-030**): re-enable the corp-a1 App Service (only if the compute
quota is now available - it was not at deploy time), OR retarget the REST-API stub + k6 at a live workload
(online-p1 has a LIVE App Gateway WAF_v2 + Static Web App, deployed green), OR gate the corp-a1 workload +
k6 pieces off behind a new flag so the red-team + cost-pattern layers still ship. This is a cloud-engineer
implementation once the direction is chosen.

**online-p1 dependency (PASS):** `online_p1.tf` only reads the shared RG (exists) and creates its own SA +
queue. No App Service dependency. It is only affected by the storage-name and public-access blockers below.

**corp-a2 (PASS):** `corp_a2.tf` is intentionally empty. No dependency.

**Connectivity / identity:** synthetic creates an **isolated** VNet (`10.50.0.0/24`, no peering, no UDR, no
firewall, no PE) for the cost-pattern VM, and the Container Apps environments are managed (no injected
subnet). So synthetic depends on **no hub or spoke VNet**. PASS - no connectivity/identity coupling.

---

## 3. The VM / compute

- **Image (CURRENT, PASS):** `azurerm_linux_virtual_machine.oversized_idle` uses Canonical
  `ubuntu-24_04-lts` / sku `server` / version `latest`. Verified current on the Azure Marketplace listing
  (canonical.ubuntu-24_04-lts; `server` is the standard non-Pro SKU, Gen2) and in
  `deprecation-audit.md` section 2.4 (not the retired 18.04). `version = "latest"` auto-resolves to the
  current image, avoiding a pinned-version deprecation. No action.
- **Region:** `primary_location = eastus2`. Matches corp-a1 / online-p1. OK.
- **Size vs quota (VERIFY):** default `Standard_D4s_v5` = **4 vCPUs** of the **Standard DSv5 Family**. The
  prior finding of "~10 vCPUs healthy" is a general IaaS headroom read; it does NOT guarantee the **DSv5
  family** regional quota specifically. Operator should confirm `Standard DSv5 Family vCPUs` >= 4 in eastus2
  on the LZ sub (`az vm list-usage --location eastus2 --subscription <LZ-sub>`). If tight, the mitigation is
  already in code: set `cost_pattern_vm_size = Standard_D2s_v5` (2 vCPUs) - the `Optimization=Candidate` demo
  signal is unchanged. **Synthetic needs NO SQL and NO dedicated App Service compute** (the capped families):
  the k6 + red-team compute is Azure Container Apps (serverless Consumption, no VM-family quota), and the only
  IaaS VM is this single D4s_v5. So the ADR-031/032 dedicated-compute cap does not block synthetic's own VM.
- **Subnet / NSG (PASS):** the VM NIC sits on synthetic's own isolated subnet; the NIC has **no public IP**
  and no NSG dependency on a spoke/hub. Confirmed no `public_ip_address_id` on the NIC (README: "VM has no
  public IP"). So `Deny-Public-IP-On-NIC` (corp MG) does NOT fire on the VM. Break-glass is via Bastion /
  Serial Console. PASS.

---

## 4. Live policy-matrix collision check (step 3c/3d)

Scope chain for every synthetic resource (they all land in the LZ sub): `Tenant Root -> globaris ->
landingzones -> corp -> LZ sub`. This is the SAME chain the landing zones cross, live-enumerated 2026-07-10 in
`landing-zones.md` section 2; the assignments below are reused from that live evidence.

| # | Assignment | Scope | Effect | Fires on synthetic? | Verdict |
|---|---|---|---|---|---|
| 1 | `Deny-Public-Endpoints` / `StorageDenyPaasPublicIP` (`b2982f36`) | corp | **Deny (enforced)** | **YES** - denies `Microsoft.Storage/storageAccounts` where `publicNetworkAccess NOT in [Disabled, SecuredByPerimeter]`. `online_p1_synthetic`, `red_team_decoy`, `cost_pattern_hot`, and `corp_a1_synthetic` all set `public_network_access_enabled = true`. | **BLOCKER 2 (all public synthetic SAs).** The OQ-024 Waivers are RG-scoped to `rg-<spoke>-network-*` only; they do NOT cover `rg-synthetic-*`. Needs its own decision - **OQ-029**. |
| 2 | `Deny-Public-Endpoints` / Key Vault member (same initiative) | corp | **Deny (likely)** | **LIKELY** - the ALZ Deny-PublicPaaSEndpoints initiative carries a Key Vault public-network member; `red_team_decoy` KV sets `public_network_access_enabled = true` + `network_acls.default_action = Allow`. | **VERIFY / probable BLOCKER.** Landing zones created no KV so this member was never exercised live. Confirm with `az policy set-definition show` on the initiative's members; if the KV member effect is Deny, the decoy KV needs the same OQ-029 Waiver on `rg-synthetic-red-team-*`. |
| 3 | `AsDenyPublicIP` (App Service public inbound) | corp | Deny | NO | PASS - synthetic creates no `Microsoft.Web/sites`. The corp-a1 App Service it *reads* is a separate (absent) resource. |
| 4 | `Deny-Public-IP-On-NIC` (`83a86a26`) | corp | Deny | NO | PASS - the cost-pattern VM NIC carries no PIP. No standalone-PIP Deny exists on this chain (`landing-zones.md` rows 6/7). |
| 5 | `Deny-Subnet-Without-Nsg` | landingzones | Deny | **Watch** - synthetic's `snet-cost-patterns` has **no NSG**. | **LIKELY BLOCKER (verify).** Same policy that denied corp `snet-integration`. The isolated cost-pattern subnet has no NSG attached. Expect a Deny on the subnet create. Fix: attach a minimal NSG to `snet-cost-patterns` (cloud-engineer), same remedy as the spoke fix. Confirm the policy's `excludedSubnets` does not already list it (it will not). |
| 6 | `Deny-Storage-http` (`404c3081`) | landingzones | Deny | NO | PASS - all synthetic SAs set `min_tls_version = TLS1_2`; azurerm defaults HTTPS-only. |
| 7 | `tag-governance-globaris` | globaris | Modify | Cosmetic | PASS/BY-DESIGN - the `rg-ungoverned-*` RG ships with empty tags **on purpose** (anti-pattern #4); its `ignore_changes = [tags]` absorbs the Modify remediation. Non-blocking. |
| 8 | `Enable-DDoS-VNET` | landingzones | Modify | **NO (verify)** | Synthetic's cost-pattern VNet is a `Microsoft.Network/virtualNetworks` PUT, so the same Modify assignment *targets* it. **BUT** the DDoS DoNotEnforce lever (`landing-zones.md` section 6) had to be applied at the `landingzones` MG before the spokes deployed, and the spokes ARE deployed green - so it is already DoNotEnforce. Confirm it is still DoNotEnforce before apply (`az policy assignment show --name Enable-DDoS-VNET --scope .../managementGroups/landingzones --query enforcementMode`). If it reverted, the synthetic VNet PUT would get the placeholder DDoS-plan injection and fail. |
| 9 | `deny-pub-net-globaris` (SQL/KV/Storage = Audit) | landingzones | Audit | Audit-only | PASS - Audit never blocks. |
| 10 | All `Enforce-Guardrails-*` (incl. Key Vault purge/soft-delete guardrails) | landingzones/corp | **DoNotEnforce** | n/a | PASS - the guardrail initiatives are DoNotEnforce on this chain (`landing-zones.md` row 13). So the decoy KV's `purge_protection_enabled = false` + `soft_delete_retention_days = 7` are **not** denied here. Only the public-network member (row 2, in the *Deny*-PublicPaaSEndpoints initiative, not the guardrails) is the concern. |
| 11 | DINE tail (`Deploy-*`, `Audit-*`) | globaris/corp | DINE/Audit | Noise | PASS - DINE never blocks a create; self-heals or is post-apply. |

**Honeypot / VM public-IP exposure (explicit answer):** the cost-pattern VM has **no** public IP, so
`Deny-Public-IP*` does not touch it. The `resource_anomaly` red-team job creates+deletes **public IPs at
runtime** via its MI (Network Contributor on `rg-synthetic-red-team-*`); that is a runtime action, not a
Terraform create, and there is **no standalone-`publicIPAddresses` Deny** on this chain (`landing-zones.md`
rows 6/7 PASS), so those runtime PIPs will actually succeed and generate the intended AzureActivity signal.
No apply-time PIP collision.

**Net policy verdict:** BLOCKER 2 (storage public-access, confirmed), plus two VERIFY-then-likely-blockers
(the decoy KV public-access member, row 2; and `Deny-Subnet-Without-Nsg` on `snet-cost-patterns`, row 5), plus
one standing confirm (DDoS still DoNotEnforce, row 8). All are the SAME classes already dispositioned for the
landing zones - the fixes are Waiver exemptions (OQ-029) and an NSG attach.

---

## 5. Resource-type lifecycle / deprecation audit (step 3d)

The cross-root sweep already covers this root in `deprecation-audit.md` section 2.4, re-confirmed here against
the pinned `azurerm ~> 4.71.0`:

- **Ubuntu 24.04 LTS VM image** - CURRENT (verified on the Marketplace listing 2026-07-10; not retired 18.04).
- **Automation Account (Basic SKU, System-Assigned MI)** - CURRENT. Explicitly **not** a retired Run As
  account (Run As retired 2023-09-30); it uses managed identity. "Basic" is the Automation tier, unrelated to
  the Basic-PIP/LB retirement.
- **Container Apps environment / job / environment-storage** - CURRENT.
- **Key Vault (standard), Storage (StorageV2 + blob/container/queue/share/share_file), managed disk, NIC,
  VNet, subnet, consumption budgets, action group, diagnostic settings, role assignments** - all CURRENT.
- **No `azurerm_virtual_machine_extension` / no MMA-OMS agent** - so the Log Analytics agent retirement
  (2024-08-31) does not apply.
- **No NSG-targeted flow logs** in this root (the retired landmine lives only in the landing zones).

**No RETIRED or RETIRING type in synthetic.** Lifecycle audit PASS. (Note: `grafana/k6:latest` and
`mcr.microsoft.com/azure-cli:2.66.0` are container images, not Azure resource types - no lifecycle gate; the
`:latest` tag is non-deterministic but not a blocker.)

---

## 5b. Code bug found in the pre-apply read - storage-account name length (BLOCKER 3)

Storage-account names are 3 to 24 lowercase-alphanumeric characters. With the live `org_prefix = globaris`
(8) + `environment = poc` (3) + the 6-char `random_string.sa_suffix`, three of the four SA names overflow:

| Resource | Name pattern | Length | Status |
|---|---|---|---|
| `corp_a1_synthetic` | `stsyna1` + `globaris` + `poc` + 6 | 7+8+3+6 = **24** | OK (at the limit) |
| `online_p1_synthetic` | `stsynop1` + `globaris` + `poc` + 6 | 8+8+3+6 = **25** | **INVALID** |
| `red_team_decoy` | `stsynrtdc` + `globaris` + `poc` + 6 | 9+8+3+6 = **26** | **INVALID** |
| `cost_pattern_hot` | `stsynchot` + `globaris` + `poc` + 6 | 9+8+3+6 = **26** | **INVALID** |

The provider validates SA name length at plan, so this fails before apply. It was never caught because this
root has never been applied. Fix (cloud-engineer): shorten the prefixes and/or the suffix so every name is
<= 24 for the `globaris`/`poc` values (e.g. drop `environment` from the SA names, or cut the random suffix to
4 and trim the prefixes). Keep names deterministic where other resources reference them
(`corp_a1_synthetic` is referenced by k6, red-team shares, and runbooks).

---

## 6. Teardown coupling

Synthetic is designed to be torn down by the kill switch (`enable_synthetic_workload = false` -> destroy the
layer in <5 min). Standing items to add to the teardown checklist:

- **Honeypot Entra user (manual, NOT Terraform-managed).** If created for the sign-in scenarios, it is a
  directory object that **survives `terraform destroy`**. Teardown must manually delete
  `svc-honeypot@<tenant>...` (`az ad user delete`). Add to the teardown checklist.
- **No MG/subscription-scoped standing role grants added.** Every synthetic role assignment is scoped to a
  synthetic resource: the Automation MI gets Contributor on the synthetic RGs; each red-team CAJ MI gets a
  narrow role (Network Contributor on `rg-synthetic-red-team-*`, Storage Blob Data Reader on the decoy SA,
  Key Vault Reader on the decoy KV). All die with the resources on destroy. **Synthetic adds NOTHING to the
  OQ-008 standing-Owner@MG cleanup and does NOT add any temp directory roles** (contrast the 2 AADDS
  directory roles). Confirmed - the teardown revocation list is unchanged by synthetic.
- **Runtime orphan public IPs.** The `resource_anomaly` job creates `pip-rt-anomaly-*` PIPs at runtime;
  `weekly-cleanup-ephemeral.ps1` sweeps them, but a teardown mid-run could leave orphans that block the
  `rg-synthetic-red-team-*` destroy. Confirm no in-flight CAJ before destroy (or let the stop-compute runbook
  quiesce first).
- **Long-lived automation webhook** (`wh-stop-synthetic-compute`, expires 2030) - dies with the Automation
  Account on destroy. No separate revocation needed.

---

## 7. Open questions raised

- **OQ-029** - synthetic public-network storage accounts (and the decoy Key Vault) collide with the corp-MG
  `Deny-Public-Endpoints` Deny; the OQ-024 Waivers do not cover the synthetic RGs. Decision needed (Waiver vs
  private).
- **OQ-030** - the corp-a1 App Service that synthetic hard-references is gated off; how to proceed
  (re-enable vs retarget vs gate the corp-a1 workload + k6 pieces off).
- **OQ-031** - correlation gap: synthetic ships telemetry to the **platform LAW** (management sub) but
  Sentinel is onboarded on the **security LAW** (security sub), so the Section 6 analytics rules will not see
  synthetic signals unless they cross-workspace query the platform LAW. Non-blocking for apply; blocks the
  demo's "synthetic signal -> Sentinel incident" story. Verify/decide before the demo.

---

## 8. Action list before GO

### (a) What the USER must provide

1. **Decision on OQ-029** (Waiver vs disable-public-access for the synthetic SAs + decoy KV). Recommended
   default: RG-scoped `azurerm_resource_group_policy_exemption` Waivers (ADR-028 / OQ-024 precedent) on each
   synthetic RG that holds a public SA (`rg-synthetic-corp-a1-*`, `rg-synthetic-online-p1-*`,
   `rg-synthetic-red-team-*`, `rg-synthetic-cost-patterns-*`) for `StorageDenyPaasPublicIP`, plus the Key
   Vault member on `rg-synthetic-red-team-*` if row-2 verification confirms it is Deny. Disabling public
   access is rejected as a default (breaks the App-Service SAS fetch, the SWA-Function queue write, the MI
   blob read over its outbound IP, and the Container Apps file-share mount).
2. **Decision on OQ-030** (corp-a1 App Service dependency). Recommended default given the end-of-week
   teardown: retarget the REST-API stub + k6 at the LIVE online-p1 App Gateway / Static Web App (or gate the
   corp-a1 workload + k6 off), rather than fighting the open dedicated-compute quota ticket.
3. **Honeypot user (optional, only for the sign-in demo):** create a **disabled** Entra user and set its UPN
   into the `HONEYPOT_USER_PRINCIPAL_NAME` repo Secret. If skipped, the sign-in scenarios self-disable.
4. **Confirm the DSv5-family vCPU quota** (>= 4 in eastus2 on the LZ sub) or accept the `Standard_D2s_v5`
   override.

### (b) Code / config changes needed first, by lane

| # | Change | Lane | Blocks |
|---|---|---|---|
| 1 | **Fix the 3 over-length storage-account names** (`online_p1_synthetic`, `red_team_decoy`, `cost_pattern_hot`) to <= 24 chars for `globaris`/`poc`. Keep `corp_a1_synthetic` deterministic (referenced elsewhere). | cloud-engineer | Plan-time validation |
| 2 | **Resolve the corp-a1 App Service dependency** per the OQ-030 decision: retarget the stub + k6 at a live workload, OR add a flag that gates `data.azurerm_linux_web_app.corp_a1` + `corp_a1.tf` deploy + k6 off, OR re-enable `enable_app_service` on corp-a1 (only if quota is now available). | cloud-engineer | Plan-time 404 |
| 3 | **Add the synthetic-RG Waiver exemptions** (per the OQ-029 decision) for `StorageDenyPaasPublicIP` (+ the KV member if confirmed). Same `azurerm_resource_group_policy_exemption` pattern as the spokes. | devsecops (policy exemption) | Deny at create |
| 4 | **Attach a minimal NSG to `snet-cost-patterns`** (verify `Deny-Subnet-Without-Nsg` fires on it first). | cloud-engineer | Deny at subnet create |
| 5 | **Flip `enable_synthetic_workload = true`** in `envs/poc.tfvars` - ONLY after 1 to 4 land and a `plan` is clean. | cloud-engineer (config) + reviewer | Deploys nothing until set |

### (c) Operator pre-apply confirms

- `Enable-DDoS-VNET` is still `DoNotEnforce` at the `landingzones` MG (matrix row 8).
- The row-2 (decoy KV) and row-5 (`snet-cost-patterns`) policy checks against the live initiative members.
- DSv5-family quota (or accept the D2s_v5 override).

### GO path

After (b)1 to (b)4 land and code review approves, run `deploy.yml` target `synthetic`, action `plan`. Gate
the plan: no over-length SA name error, the corp-a1 App-Service reference is resolved/gated, the public SAs
+ decoy KV are exempted, `snet-cost-patterns` has an NSG. Then flip `enable_synthetic_workload = true`,
re-plan (confirm a sane create count, not zero), and apply. Re-run this pre-clearance's policy confirms
before the apply. This root has a hard failure-budget history at the project level, so do not apply on a plan
that still shows any of the blockers above.
