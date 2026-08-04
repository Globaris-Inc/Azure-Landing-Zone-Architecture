# SECURITY.md - Threat Model, Zero Trust Mapping, Compliance Posture

> Section 11 documentation deliverable (PROMPT.md item 4). This document describes the security posture of the
> **as-deployed** Globaris CAF Azure Landing Zone POC. It is grounded in the resources that actually exist in
> the estate, and it is deliberately honest about the controls that are configured in a non-enforcing POC mode
> (report-only Conditional Access, deferred PIM activation, gated tenant-scoped connectors). Those are
> documented, intentional POC choices with a defined path to enforcement, not hidden gaps.
>
> Cross-references: `ARCHITECTURE.md` (topology, Zero Trust table), `DECISIONS.md` (ADRs), `RUNBOOK.md`
> (operational procedures).

---

## 1. Estate summary (what is actually deployed)

| Layer | Deployed today | Root |
|-------|----------------|------|
| Management groups | Globaris root -> Platform {Security, Management, Identity, Connectivity} + Landing Zones {Corp, Online} + Decommissioned + Sandbox; ALZ policy engine (`avm-ptn-alz`) | `platform/management-groups` |
| Subscriptions | management, connectivity, identity, security, landingzones (5) | - |
| Connectivity | 2-region hub-spoke (primary eastus2 `10.0.0.0/16`, secondary centralus `10.1.0.0/16`); Azure Firewall **Premium** per hub with **IDPS in Alert mode**; independent Premium firewall policies (ADR-009); hub-to-hub **Global VNet Peering** (module native mesh, `allow_gateway_transit = true`); VPN Gateway (VpnGw1AZ) + DNS Private Resolver in primary hub only; ~89 `privatelink.*` private DNS zones | `platform/connectivity` |
| Identity | Microsoft Entra Domain Services (`aadds.globaris.org`, 2 DCs, Standard) in an isolated identity VNet peered to the primary hub; RSV; 8 Conditional Access policies (report-only) | `platform/identity` |
| Security | Dedicated RBAC-isolated security LAW (`law-security-globaris-poc-r2`, ADR-075 generation suffix); Microsoft Sentinel onboarded; Defender for Cloud Standard plans; NIST SP 800-53 R5 + CIS Azure 2.0.0 regulatory-compliance initiatives (audit); security Key Vault | `platform/security` |
| Landing zones | corp-a1 (eastus2 `10.10.0.0/16`), corp-a2 (centralus/DR `10.11.0.0/16`), online-p1 (eastus2, live App Gateway WAF_v2 + Static Web App) | `landing-zones/*` |
| Management / FinOps | Platform LAW (`law-platform-globaris-poc`), Automation Account, platform action group (`ag-platform-globaris-poc`), budgets (sub + MG scope), daily cost exports, cost anomaly alert | `platform/management` |

**Not live by design (POC posture, see section 5):** Defender DDoS Standard plan (cost); PIM eligible activations (deferred/documented); the tenant-scoped Sentinel connectors dc-aad, dc-ti, dc-mde, plus UEBA and Entra ID diagnostics (gated pending a Security Administrator grant); the `firewall_threat_intel_hit` cross-workspace analytics rule (gated); the synthetic security-signal generator (repositioned/deferred, ADR-036/037, so there is no live synthetic incident stream).

---

## 2. Threat model

Attack-surface based, with a STRIDE lens applied per surface. Four surfaces are modelled: the internet edge, the
identity plane, the management (CI/IaC) plane, and the data plane.

### 2.1 Internet edge (App Gateway / WAF + Azure Firewall)

**Exposure.** The only intentional inbound internet path is `online-p1` in eastus2: an **Application Gateway
WAF_v2** fronting a **Static Web App**. The corp spokes are private-only (no public ingress). East-west and
egress traffic from every spoke is forced through the regional **Azure Firewall Premium** via a UDR default
route (`0.0.0.0/0 -> VirtualAppliance`).

| STRIDE | Threat | Control in the estate | Residual / notes |
|--------|--------|-----------------------|------------------|
| Spoofing | Forged host headers, request smuggling to the origin | App Gateway WAF_v2 (OWASP managed ruleset) terminates and inspects HTTP before the origin | WAF mode not asserted here as Prevention; validate ruleset mode before relying on block behaviour |
| Tampering | Payload manipulation / injection (SQLi, XSS) | WAF_v2 managed rules on the online tier | Static Web App has no SQL backend, so injection blast radius is minimal |
| Repudiation | No record of who hit the edge | App Gateway + Firewall diagnostics flow to the platform LAW; Sentinel `anonymous_storage_access` rule watches blob exfiltration paths | - |
| Information disclosure | Direct-to-PaaS bypass of the firewall | Private Endpoints only for corp PaaS; public network access denied by policy at the Landing Zones MG | Event Hub + security KV keep public access on during the POC (documented DEVIATION, PE deferred to hardening) |
| Denial of service | Volumetric / L3-L4 flood | Azure platform DDoS Basic (always on); Firewall Premium; App Gateway autoscale | **DDoS Standard plan is NOT deployed** (cost, ADR-013). This is the single largest edge deviation - flag it if a faithful production posture is required |
| Elevation of privilege | Lateral movement from a compromised spoke | All spoke egress + inter-spoke traffic forced through the Firewall Premium; IDPS in **Alert** mode inspects it | IDPS is Alert (detect), **not Deny** - it surfaces signatures but does not block. Switching to Deny is a policy-value change per hub (independent policies, ADR-009) |

**Key honest limits at the edge:** IDPS is Alert-only (no automatic block), TLS inspection is not wired
(firewall policy `tls_certificate` deliberately omitted pending the security Key Vault cert), and DDoS Standard
is off. These are cost/scope decisions appropriate to a POC and each has a one-change enforcement path.

### 2.2 Identity plane (Entra Domain Services + Conditional Access)

**Exposure.** Two identity constructs: the cloud identity control plane (Entra ID tenant, targeted by the 8 CA
policies) and a managed on-prem-style directory, **Entra Domain Services** (`aadds.globaris.org`, 2 domain
controllers) in an isolated identity VNet.

| STRIDE | Threat | Control in the estate | Residual / notes |
|--------|--------|-----------------------|------------------|
| Spoofing | Credential theft / password spray | CA-001 (MFA for admin roles), CA-002 (block legacy auth), CA-008 (MFA on sign-in risk); Sentinel `brute_force_entra`, `legacy_auth_attempt` rules | **All CA policies are report-only** - they log, they do not enforce. See section 5 |
| Spoofing | Sign-in from an unapproved country | CA-005 geo-block (named location = US, CA, GB) + Sentinel `blocked_country_signin` rule | CA-005 is deployed (named-location reference bug fixed, ADR-030) but is **report-only** like the rest; the detection rule is the live control |
| Tampering | Weakening MFA / auth methods on an admin | Sentinel `mfa_disabled_for_admin` rule | Detection only |
| Repudiation | Untracked privileged activation | Sentinel `pim_after_hours_activation`, `new_global_admin` rules | PIM eligible-only activation is **deferred** (documented); rules still fire on directory audit events |
| Information disclosure | Directory enumeration via Entra DS | Entra DS in an isolated VNet; NSG restored to Microsoft's required default-rule set (ADR-029); no public exposure of the DCs | NSG must retain the AADDS-required defaults (`AllowVnetInBound`, `AllowAzureLoadBalancerInBound`) - a custom deny-all previously broke DC replication (ADR-029) |
| Elevation of privilege | Standing privileged access | CA-004 (MFA for PIM activation); PIM eligible assignments at MG scope (design) | PIM **activation is deferred** - roles are not yet eligible-only in the live tenant. Enforcement path documented |

### 2.3 Management plane (CI OIDC service principal + Terraform state backend)

**Exposure.** The estate is built exclusively through GitHub Actions using a **workload-identity federated
credential (OIDC)** - no client secrets. State lives in an Azure Storage Account with a JIT firewall allowlist.
This plane is the highest-value target: a compromise of the CI SP or the state backend is a compromise of the
whole estate.

| STRIDE | Threat | Control in the estate | Residual / notes |
|--------|--------|-----------------------|------------------|
| Spoofing | Stolen CI credential | OIDC federated credential (short-lived assertion); **no secrets in GitHub** | Assertion lifetime is short - a multi-hour apply can outlive it (observed on the Entra DS create, ADR-029); mitigated by keeping applies short |
| Tampering | Unauthorised infra change | `apply` runs only in the `production` GitHub Environment with a **required reviewer**; `plan` is ungated dry-run | Branch-protection ruleset version-controlled; review gate enforced by pre-commit hook + PreToolUse blocker |
| Tampering | State-file corruption / poisoning | State SA with blob-lease locking; `force-unlock` is a dedicated, single-target, non-mutating CI action | A stuck lease from an orphaned local plan was observed and cleared via the CI `force-unlock` action (WORKLOG 2026-07-11) |
| Repudiation | Anonymous privileged apply | Every apply is a GitHub Actions run tied to an approver + commit SHA | - |
| Information disclosure | Reading state (contains resource metadata) | State SA firewall default-deny with JIT runner-IP allowlist per run; keyless (`storage_use_azuread`) access | No CMK on the state SA yet (PROMPT item 10 target); tracked |
| Elevation of privilege | CI SP over-privileged | RBAC scope-down from tenant-root Owner is designed (ADR-021 / OQ-008) | **The scope-down is still open** - the CI SP currently holds broad standing grants (Owner at MG scope). This is the top management-plane follow-up; teardown must revoke it |

### 2.4 Data plane (Private Endpoints + Private DNS)

**Exposure.** Corp PaaS data services (Key Vault, Storage, SQL where enabled) are reachable only over Private
Endpoints; name resolution is centralised in the connectivity subscription.

| STRIDE | Threat | Control in the estate | Residual / notes |
|--------|--------|-----------------------|------------------|
| Tampering / Information disclosure | Public data-plane access to PaaS | Private Endpoints only; `Deny public network access` policy initiative at the Landing Zones MG; centralised `privatelink.*` zones linked to hub + spokes | Corp SQL + App Service tiers are gated off (subscription offer caps, ADR-031/032), so the corp data plane is currently topology + governance, not a running datastore |
| Information disclosure | DNS leakage to public resolvers | DNS Private Resolver in the primary hub; private zones authoritative for PaaS | Secondary region resolves back to the primary resolver over the hub peering |
| Repudiation | Untracked bulk secret access | Sentinel `kv_bulk_secret_access` rule (>= 50 distinct secrets / 10 min by one caller) | Detection only |
| Tampering | Exfiltration via anonymous blob | Sentinel `anonymous_storage_access` rule | Detection only |

---

## 3. Zero Trust pillar mapping

This maps the **controls that actually exist** to the Microsoft Zero Trust pillars. Where a control is
report-only or gated, that is stated in the Mode column - "Enforce" means it blocks, "Report" means it logs
only, "Detect" means it raises a signal but takes no action.

| Pillar | Control (deployed) | Mode | Where |
|--------|--------------------|------|-------|
| **Identity** | CA-001 MFA for admin roles | Report | `platform/identity` (report-only) |
| Identity | CA-002 block legacy authentication | Report | `platform/identity` |
| Identity | CA-004 MFA for PIM role activation | Report | `platform/identity` |
| Identity | CA-005 geo-block outside approved countries (US/CA/GB) | Report | `platform/identity` (de-gated, ADR-030) |
| Identity | CA-006 sign-in frequency 4h on mgmt apps | Report | `platform/identity` |
| Identity | CA-007 block on high user risk / CA-008 MFA on sign-in risk (Identity Protection) | Report | `platform/identity` |
| Identity | PIM eligible-only at MG scope, MFA + 8h max | Designed, deferred | ADR reference; not activated in tenant |
| Identity | Workload identity via OIDC federated credential (no secrets) | Enforce | `.github/workflows`, bootstrap |
| **Device** | CA-003 require compliant / hybrid-joined device for Azure portal + management API | Report | `platform/identity` |
| **Network** | Azure Firewall Premium per hub, IDPS Alert; forced-tunnel UDR on all spokes | Detect (IDPS) / Enforce (routing) | `platform/connectivity` |
| Network | Private Endpoints only + deny-public-network policy initiative | Enforce | Landing Zones MG policy |
| Network | Hub-to-hub Global VNet Peering, DNS Private Resolver, private DNS zones | Enforce | `platform/connectivity` |
| **Application** | Application Gateway WAF_v2 (OWASP managed rules) in front of online-p1 | Enforce (WAF present) | `landing-zones/online-p1` |
| **Data** | Private-Endpoint-only PaaS; security LAW RBAC-isolated; Key Vault purge protection + 90-day soft delete | Enforce | `platform/security`, spokes |
| **Infrastructure / Visibility** | Defender for Cloud Standard plans; Sentinel analytics (9 scheduled + MDC incident rule); regulatory compliance dashboards | Detect / Audit | `platform/security` |

**Deviations from the aspirational Zero Trust table in ARCHITECTURE.md:** that table lists TLS inspection, JIT
VM access, and CMK on state as target controls. In the as-deployed estate TLS inspection is not wired (firewall
`tls_certificate` omitted), JIT VM access is not configured (no IaaS VMs in the workload tiers - they are gated
off), and the state SA has no CMK yet. These are target-state, not current-state.

---

## 4. Compliance posture

### 4.1 Regulatory compliance initiatives (audit)

Two Microsoft built-in initiatives are assigned at the **Globaris root MG** scope so every subscription inherits
them, feeding the Defender for Cloud regulatory-compliance dashboard:

| Initiative | Definition GUID | Assignment | Effect |
|------------|-----------------|------------|--------|
| NIST SP 800-53 Rev. 5 | `179d1daa-458f-4e47-8086-2a68d0d6c38f` | `reg-nist_sp_800_53_r5` at root MG | `enforce = false` -> **audit only** |
| CIS Microsoft Azure Foundations Benchmark v2.0.0 | `06f19060-9e68-4070-92ca-f15cc126059e` | `reg-cis_azure_2_0_0` at root MG | `enforce = false` -> **audit only** |

Both are parameterless (0 required parameters without a default) and produce compliance evidence without
modifying resources. `enforce = false` means the DeployIfNotExists / Modify policies inside the initiatives run
in audit mode - they generate the dashboard posture but do not remediate. This is the correct POC choice:
regulatory posture is demonstrable from the dashboard and audit findings, without unattended remediation side
effects.

### 4.2 Defender for Cloud plans (Standard)

Enabled on the security subscription (`azurerm_security_center_subscription_pricing`):

- **VirtualMachines** subplan P2 (Defender for Servers Plan 2 - includes MDE integration + vulnerability assessment)
- **StorageAccounts** (`DefenderForStorageV2`), **KeyVaults**, **Arm** (basic set)
- **AppServices**, **SqlServers**, **SqlServerVirtualMachines**, **Containers**, **OpenSourceRelationalDatabases**, **CloudPosture** (Defender CSPM)
- Security contact configured with alert notifications to admins

Notes on plan hygiene (from the deployment history, honest debt): the **Dns** plan was removed (deprecated for
new enablement). **KeyVaults** and **Arm** are also deprecated for new enablement but are held as-is because they
are already live-Standard and in state - removing them would downgrade posture and re-PUTting them would fail
(ADR-034 / OQ-028). Their subplans are pinned to state values to prevent a ForceNew destroy/recreate (ADR-035).
This is latent, documented debt, not a live failure.

### 4.3 What is enforced vs audit vs report-only (the honest summary)

| Category | State | Detail |
|----------|-------|--------|
| Network routing + Private Endpoints + deny-public-network policy | **Enforced** | Forced tunnel through Firewall Premium; PE-only PaaS; deny-public policy at LZ MG |
| WAF on the internet edge | **Enforced (present)** | App Gateway WAF_v2 live in front of online-p1 |
| Firewall IDPS | **Detect (Alert)** | Signatures raise alerts; no automatic block |
| Regulatory compliance (NIST / CIS) | **Audit** | Dashboards + findings; `enforce = false`; no remediation |
| Defender for Cloud plans | **Active (Standard)** | Full CSPM + workload plans; alerts flow to Sentinel via `mdc_high` incident rule |
| Conditional Access (all 8 policies) | **Report-only** | `ca_policy_state = enabledForReportingButNotEnforced`; they log, do not block |
| PIM activation | **Deferred** | Eligible-only model designed; not activated in the tenant |
| Tenant-scoped Sentinel telemetry (dc-aad, dc-ti, dc-mde, UEBA, Entra ID diagnostics) | **Gated off** | Need a Security Administrator directory-role grant the CI SP lacks (ADR-033/034) |

---

## 5. Intentional POC posture and the path to enforcement

These are documented, deliberate choices. Each has a defined one-change (or bounded) path to a production
posture. None is a hidden gap.

1. **Conditional Access is report-only.** All 8 CA policies run in `enabledForReportingButNotEnforced`. This is
   the recommended CA rollout pattern: deploy in report-only, validate impact against real sign-in telemetry,
   then flip. **Path to enforce:** set `ca_policy_state = "enabled"` in `envs/poc.tfvars` after (a) a break-glass
   emergency-access group is configured in `break_glass_group_object_id` and excluded from every policy, and (b)
   report-only impact has been reviewed. Do not enforce without break-glass exclusion - it can lock out all
   admins.

2. **PIM eligible assignments are deferred.** The eligible-only, MFA + approval + 8h-max model is designed at MG
   scope but not activated in the live tenant. **Path:** activate PIM eligibility for Owner / Contributor / User
   Access Administrator / Security Administrator at MG scope; this also tightens the CI SP standing-Owner grant
   (OQ-008 / ADR-021).

3. **Tenant-scoped Sentinel connectors + UEBA are gated off.** dc-aad (Entra sign-in/audit), dc-ti (Microsoft TI
   feed), dc-mde (Defender for Endpoint), UEBA, and Entra ID diagnostics all require a **Security Administrator**
   directory role the CI OIDC SP does not hold (ADR-033/034). The subscription-scoped **dc-mdc** connector IS
   live. **Path:** grant a time-boxed Security Administrator role to the CI SP, then flip
   `enable_aad_connector`, `enable_ti_connector`, `enable_mde_connector` (needs an MDE license), `enable_ueba`,
   and `enable_aad_diagnostics` to `true` in one pass and re-apply. Until then, Entra sign-in analytics rules
   (e.g. `brute_force_entra`) have no live SigninLogs source, so they will not fire on real data.

4. **`firewall_threat_intel_hit` analytics rule is gated off.** It is the only cross-workspace rule (reads
   Firewall diagnostics from the platform LAW while the rule lives in the security workspace); name-only
   `workspace()` resolution fails at create across subscriptions (ADR-034). **Path:** fully-qualify the platform
   LAW ARM resource ID + grant the Sentinel query identity Log Analytics Reader on the platform LAW, then flip
   `enable_firewall_ti_rule` (OQ-027).

5. **No live synthetic incident stream.** The synthetic load / red-team signal generator was repositioned toward
   a future Day-2 Operations and Monitoring capability and is not deployed (ADR-036/037,
   `enable_synthetic_workload = false`). **Consequence:** Sentinel and Defender are correctly configured but have
   no manufactured incidents during the POC window - the posture is demonstrable from the deployed configuration,
   dashboards, and analytics-rule definitions, not from live synthetic detections.

6. **DDoS Standard, TLS inspection, CMK on state, JIT VM access** are target-state controls not in the current
   estate (cost / scope). See sections 2.1, 2.3, and 3.

---

## 6. ADR index (security-relevant)

| ADR | Relevance |
|-----|-----------|
| ADR-009 | Independent Premium firewall policies per hub (no shared parent) |
| ADR-010 | Identity mode = Entra Domain Services |
| ADR-013 | DDoS Standard behind a default-off flag |
| ADR-021 / OQ-008 | CI SP RBAC scope-down (management-plane follow-up) |
| ADR-029 | Entra DS NSG default-rule restoration; OIDC token-expiry on long applies |
| ADR-030 | CA-005 geo-block named-location reference fix (re-enabled) |
| ADR-031 / ADR-032 | Corp SQL + App Service tiers gated off (subscription offer caps) |
| ADR-033 / ADR-034 | Tenant-scoped Sentinel connectors + firewall TI rule gated; Defender plan deprecation |
| ADR-035 | Defender basic-plan subplan pinning (prevent posture-regressing recreate) |
| ADR-036 / ADR-037 | Synthetic layer repositioned to deferred Day-2 O&M (no live signal stream) |
