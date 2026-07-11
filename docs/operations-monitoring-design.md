# Day-2 Operations and Monitoring (O&M) Design for the CAF Azure Landing Zone

> **Status:** Forward design (designed-now / built-later). NOT a build. No Terraform is written by this
> document. It follows the designed-now/built-later precedent (ADR-022 brownfield planning, OQ-014) and the
> repositioning decision in **ADR-036** (Section 13 reframed from a synthetic load / red-team demo device to a
> platform-anchored, policy-propagated, AMBA-based Operations and Monitoring capability).
> **Owner:** Cloud Solutions Architect. **Section:** 13 (repositioned) / CAF "Manage".
> **Grounded in the deployed estate as of 2026-07-10** (WORKLOG Section Status Tracker): management-groups,
> connectivity (2-hub), management (platform LAW + budgets + action group), identity (Entra DS), security
> (Defender + Sentinel), and the 3 landing-zone spokes.
> **Related ADRs:** ADR-036 (reposition + AMBA framing), ADR-010 (Entra DS identity), ADR-009 (firewall
> policy), ADR-003 (subscription model), ADR-022 (designed-now/built-later). **Open question:** OQ-033.

---

## 0. Executive summary

- Operational monitoring is a **platform capability** in canonical ALZ, not a workload tier. This design is
  **platform-anchored** (extends the existing `platform/management` landing zone that already hosts the
  platform Log Analytics workspace and action group), **policy-propagated** (DeployIfNotExists at management
  group scope so every current and future spoke inherits coverage automatically), and **AMBA-based** (anchored
  to Azure Monitor Baseline Alerts for Azure Landing Zones, Microsoft's named, endorsed alert library).
- The estate **already has the load-bearing pieces**: a central platform LAW, a separate Sentinel LAW, a
  platform action group, an Automation Account, budgets + cost exports + a cost anomaly alert, Recovery
  Services Vaults, and an established diagnostic-settings pattern. The net-new O&M work is mostly
  **policy-driven glue and an alert library**, not new infrastructure.
- The **two-workspace split is deliberate and stays**: the platform LAW is the operations / platform-telemetry
  hub (management sub); the security LAW is the Sentinel / SecOps workspace (security sub). O&M targets the
  platform LAW; it does not move Sentinel.
- The **bounded MVP** is a high-value, low-surface slice: AMBA baseline alerts + Service Health and Resource
  Health alerts + diagnostic-settings-at-scale (DINE) + routing into the existing platform action group. That
  is the CAF "Manage" minimum that makes the estate observable and alertable end to end.
- **Scope discipline:** dashboards-for-everything, Managed Grafana, ITSM integration, and full auto-remediation
  are explicitly Phase 2/3, not MVP. The design calls out MVP vs later at every layer.
- The **shelved synthetic idea is legitimately reusable** in exactly one place: as real synthetic-transaction
  availability probes (Application Insights availability tests / Connection Monitor), not as red-team load.
- **Demo trade-off (carried from ADR-036):** until this capability is built, Sentinel and Defender are
  correctly configured but have no live operational signal stream driving alerts. This design is the honest
  successor that produces real operational signals rather than manufactured ones.

---

## 1. CAF alignment: where O&M sits in the framework

The CAF **Manage** methodology defines the Day-2 operations baseline: an operational baseline (monitoring,
alerting, backup, patching), business commitments (SLA/SLO), and operations maturity. This design maps that
methodology onto the ALZ **design areas** already implemented in this estate:

| ALZ design area | What O&M contributes | Already deployed anchor |
|---|---|---|
| **Management and monitoring** | Central LAW strategy, DCR/AMA data collection, AMBA alert baseline, workbooks, action groups. This is the primary home of O&M. | Platform LAW, platform action group, Automation Account (management sub) |
| **Platform automation and DevOps** | DINE-propagated diagnostic settings + alerts (policy as the delivery vehicle), policy remediation tasks, runbook-based auto-response. | `avm-ptn-alz` policy engine (management-groups), tag-governance remediation identity pattern |
| **Business continuity and DR** | Surface RSV backup-job and replication health into ops alerting; tie to the Section 3 two-region topology. | RSVs (corp-a1 ZoneRedundant, corp-a2 GeoRedundant), GZRS finops SA |
| **Governance** | Ops signals close the loop on governance (policy-compliance drift, tag drift, budget breach all become alerts on one action group). | Budgets, cost exports, cost anomaly alert, tag governance policy set |
| **Security** | Clear seam between SecOps (Sentinel on the security LAW) and platform ops (alerts on the platform LAW); shared action-group routing where an operational event is also a security event. | Sentinel + Defender (security sub), firewall diagnostics landing in the platform LAW |

**Conclusion:** O&M is a first-class ALZ concern that belongs on the platform, delivered by policy, inheriting
the existing management-sub assets. It is not a bolt-on and it is not a new spoke.

---

## 2. Monitoring data plane

### 2.1 Log Analytics workspace strategy (centralized, already in place)

The estate already runs the **recommended two-workspace ALZ pattern**:

- **Platform LAW** (`law-platform-...`, management sub) is the **operations hub**: it already receives hub
  Azure Firewall diagnostics, spoke VNet flow logs + Traffic Analytics, and Automation Account diagnostics.
  O&M consolidates all platform and landing-zone operational telemetry here.
- **Security LAW** (security sub) is the **Sentinel / SecOps workspace**. It stays dedicated to security
  analytics. O&M does not relocate Sentinel and does not duplicate its data.

**When a second/regional ops LAW is warranted (design guidance, not now):** a single central platform LAW is
correct for this estate size. Add a regional LAW only if (a) data-residency requires in-region retention, (b)
a specific service cannot cross-region its diagnostics, or (c) ingestion volume or per-workspace query limits
become a bottleneck. For this POC-scale estate, one platform LAW is right; document the trigger conditions and
revisit at scale.

**Cross-workspace already proven:** the security root's `firewall_threat_intel_hit` rule reads the platform
LAW cross-workspace, so the pattern for SecOps to reach ops data (and vice versa) is established.

### 2.2 Data collection: DCR + Azure Monitor Agent

- **Azure Monitor Agent (AMA) via Data Collection Rules (DCR)** is the standard for guest telemetry, replacing
  the retired Log Analytics/MMA agent (see the deprecation audit; MMA retired 2024-08-31). Any VM in the
  estate (the Entra DS managed domain is Microsoft-managed and needs no agent; workload VMs, if re-enabled,
  do) gets AMA + a DCR association.
- **DCR design:** a small number of reusable DCRs on the platform LAW (a Windows baseline DCR, a Linux
  baseline DCR, a VM-Insights DCR), associated to machines **by policy** (see 2.4) so association is automatic
  and never hand-placed. This mirrors the estate's existing preference for deterministic, policy-driven
  delivery.

### 2.3 Insights solutions (Phase 2, targeted)

- **VM Insights** for any workload VMs (performance + dependency map) on the platform LAW.
- **Container Insights** only if AKS/Container Apps workloads land later (the shelved synthetic k6/red-team
  used Container Apps; none is deployed). Not MVP.
- **Network Insights** for the hub Azure Firewalls, the online-p1 Application Gateway/WAF, Private DNS
  resolution, and the hub-spoke peering topology. High value given this is a networking-heavy estate.

### 2.4 Diagnostic settings at scale (DINE) - the backbone of the data plane

Today, diagnostic settings are **hand-placed** where they exist (Key Vault, Automation Account, hub firewall,
flow logs, security-sub activity log). O&M replaces the hand-placement with **DeployIfNotExists policy
assignments at management group scope** so that **every current and future resource** of each supported type
automatically ships its platform logs and metrics to the platform LAW. This is the single most important
net-new capability: it turns "did someone remember to wire diagnostics" into a guardrail.

- Assign the ALZ "Deploy-Diagnostics-*" DINE initiative(s) (per resource type: Key Vault, Storage, Network
  Security Groups, Public IPs, Firewall, App Gateway, Bastion, Private DNS, the LAW itself, etc.) at the
  **Globaris root / platform / landingzones** MG scopes.
- Remediation identities follow the established pattern already used for tag-governance remediation.
- This complements, and does not conflict with, the existing hand-placed settings; where both exist the DINE
  policy is idempotent (it only deploys if not exists).

---

## 3. Alerting

### 3.1 AMBA as the policy-driven baseline

**Azure Monitor Baseline Alerts (AMBA) for Azure Landing Zones** is Microsoft's named, endorsed,
policy-driven alert library for ALZ. It ships alert rules, the supporting action group / alert-processing
assets, and Service Health alerts **as policy initiatives deployed at MG scope via DINE**, so every landing
zone inherits a consistent platform + resource-health alert baseline automatically. Anchoring to AMBA keeps
this build **bounded and credible** rather than a bespoke, hand-maintained alert set.

- **Delivery:** AMBA-for-ALZ policy initiatives assigned at the appropriate MG scopes through the existing
  `avm-ptn-alz` policy engine (same mechanism that already assigns tag-governance and deny-public-network
  initiatives). Alert thresholds are AMBA defaults, tuned per environment.
- **Coverage:** AMBA provides platform-level metric/health alerts for the common ALZ platform resource types
  (networking, storage, key vault, compute, recovery services, and more) plus a Resource Health alert layer.
- **Inheritance:** assign once at the platform and landingzones MG scopes; corp-a1, corp-a2, online-p1, and
  any future spoke inherit without per-spoke work.

### 3.2 Service Health and Resource Health alerts

- **Service Health** alerts (service issues, planned maintenance, health advisories, security advisories) per
  subscription, routed to the platform action group. AMBA includes a Service Health notification asset; if
  AMBA's is used, do not duplicate.
- **Resource Health** alerts for the platform-critical resources (firewalls, gateways, LAW, RSV, Entra DS) so
  a platform component going Unavailable/Degraded pages the on-call.

### 3.3 Custom alerts for the platform components this estate actually runs

Beyond the AMBA baseline, add targeted metric/log/activity-log alerts for the deployed components:

| Component (deployed) | Example alerts | Signal source |
|---|---|---|
| Azure Firewall (2 hubs, ADR-009 policy) | Health/SNAT-port exhaustion, threat-intel hits, throughput, rule-hit anomalies | Firewall diagnostics in platform LAW; Resource Health |
| Application Gateway + WAF_v2 (online-p1) | Backend health/unhealthy host count, WAF blocked-request spikes, 5xx rate, capacity units | AppGw metrics + WAF logs to platform LAW |
| Private DNS (connectivity) | Resolution failures, record-set/zone changes (activity log) | DNS analytics + activity log |
| Entra DS (identity, ADR-010) | Managed-domain health alerts (the AADDS104-class health signal seen in identity apply), sync/backup health | Entra DS health + Resource Health |
| Key Vault (security KV, bootstrap KV) | Availability, saturation, throttling, near-expiry secrets/certs, unusual access | KV diagnostics + metrics to platform LAW |
| Storage (state SA, cost-export SA, flow-log SAs) | Availability, throttling, capacity, anomalous access (Defender for Storage already on) | Storage metrics/diagnostics |
| Log Analytics workspace itself | Ingestion latency, daily-cap hit, collection failures, query failures | LAW metrics (self-monitoring) |
| Bastion (on-demand, ADR-015) | Session/health when enabled | Bastion diagnostics/Resource Health |
| VPN / ExpressRoute gateways (if/when added) | Tunnel/BGP/connection health | Gateway metrics (none deployed today; hub-to-hub is Global VNet Peering per Section 3) |

### 3.4 Severity taxonomy (Sev0 to Sev4)

| Sev | Meaning | Example | Routing |
|---|---|---|---|
| **Sev0** | Critical, platform down, customer-impacting | Firewall/both-hub outage, LAW ingestion stopped, Entra DS unavailable | Page on-call immediately (action group: SMS/push + email + optional ITSM P1) |
| **Sev1** | Major degradation | Single hub firewall degraded, AppGw backend all-unhealthy, RSV backup failing repeatedly | Page on-call (business hours immediate, after-hours if trending) |
| **Sev2** | Moderate, needs attention | SNAT nearing exhaustion, KV throttling, WAF block-spike, budget forecast 100% | Email + ticket, business-hours triage |
| **Sev3** | Minor / warning | Approaching daily LAW cap, cert nearing expiry, single backup retry | Email/digest, backlog |
| **Sev4** | Informational | Planned maintenance notice, policy remediation ran | Digest/log only, no page |

AMBA alert rules carry recommended severities; align the estate's action-group routing to this taxonomy.

---

## 4. Notification and response routing

- **Action groups:** extend the **existing platform action group** (`azurerm_monitor_action_group.platform`,
  management sub) rather than proliferating new ones. Add receiver classes beyond the current email receivers:
  an on-call/SMS or push (Azure mobile app) receiver for Sev0/1, and optionally an ITSM/webhook receiver
  (Phase 3). If AMBA provisions its own notification action group, converge routing so a human sees one
  coherent stream, not two.
- **Alert Processing Rules (APR):** add processing rules for
  - **maintenance-window suppression** (silence alerts on resources tagged for a change window, tie to Update
    Manager maintenance configurations),
  - **business-hours vs after-hours routing** (Sev2/3 to email during the day, Sev0/1 always page),
  - **deduplication / grouping** so a hub-wide event does not fan out into hundreds of pages.
- **On-call model (design guidance):** a single platform-ops rotation for Sev0/1 at POC scale; workload-ops
  and SecOps receive scoped routing for their domains (see section 10). Escalation policy and rotation live in
  the ITSM/on-call tool, not in Terraform.
- **ITSM integration (Phase 3):** ServiceNow/other via the action-group ITSM connector or a webhook receiver;
  optional and explicitly out of MVP.

---

## 5. Availability and experience monitoring

- **Application Insights availability tests / standard (web) tests:** synthetic transaction probes against the
  public-facing surfaces the estate actually exposes: the online-p1 Application Gateway / Static Web App
  endpoint, and any re-enabled corp App Service. **This is the one legitimate reuse of the shelved synthetic
  idea** (per ADR-036): real availability probes replace the k6 red-team load generator. Probes run from
  multiple Azure regions and alert on failure/latency into the platform action group.
- **Connection Monitor (Network Watcher):** path health across the hub-spoke and cross-region topology:
  spoke-to-hub, hub-to-hub (Global VNet Peering per Section 3), spoke-to-Private-Endpoint, and egress-through-
  firewall reachability. Surfaces peering/UDR/firewall-rule regressions as availability signals.
- **Scope discipline:** a handful of high-value probes on the public entry points and the critical internal
  paths, not a probe on every resource. Phase 2.

---

## 6. Visualization

- **Azure Monitor Workbooks on the platform LAW** are the primary visualization surface. The estate already
  has **placeholder workbooks** to replace/extend: the platform-overview workbook and the carbon-optimization
  workbook (management sub), plus the four Sentinel workbook stubs (security sub). O&M fills the
  platform-overview workbook and adds a small, curated set:
  - **Platform health overview** (firewalls, gateways, DNS, LAW, action-group fire history),
  - **Network operations** (flow logs / Traffic Analytics, Connection Monitor, WAF),
  - **Identity operations** (Entra DS health, sign-in/audit overlap where it does not duplicate Sentinel),
  - **DR/backup** (RSV job + replication health, section 8).
- **Azure dashboards:** the existing `azurerm_portal_dashboard.platform` is the pin-board for the top KPIs.
  Keep it curated.
- **Managed Grafana (Phase 3, nice-to-have):** only if a cross-cloud or richer-visualization need appears.
  Not MVP.
- **Bounded-scope reminder:** MVP visualization = fill the platform-overview workbook + the network workbook.
  Everything else is Phase 2/3. Do not build a dashboard for every resource type.

---

## 7. Platform automation and Day-2 ops

- **Azure Update Manager** for patch compliance and scheduled maintenance on any guest VMs (the Entra DS
  managed domain is Microsoft-patched and out of scope; workload VMs, if re-enabled, are in scope). Maintenance
  configurations tie to the APR maintenance-window suppression (section 4).
- **Automation runbooks / Change Analysis:** the existing platform Automation Account is the home for
  operational runbooks (the synthetic layer already prototyped a stop-compute and a weekly-cleanup runbook
  pattern that is reusable here as ops runbooks). Change Analysis surfaces "what changed before this alert."
- **Policy remediation tasks:** auto-remediation for the DINE diagnostic-settings and AMBA assignments (bring
  pre-existing resources into compliance), using remediation identities like the tag-governance one.
- **Guest configuration / machine configuration baselines (Phase 2/3):** OS-level compliance baselines
  reported into the LAW; audit-first, enforce later.

---

## 8. DR and backup monitoring

The estate already runs **Recovery Services Vaults** (corp-a1 ZoneRedundant, corp-a2 GeoRedundant) and a GZRS
finops storage account, tied to the Section 3 two-region DR topology. O&M **surfaces DR health into ops
alerting**:

- **Backup job failure alerts** and **backup health** from each RSV (RSV built-in monitoring + AMBA recovery-
  services alerts), routed to the platform action group.
- **Replication health** alerts if Azure Site Recovery replication is configured for the failover drill.
- **A DR/backup workbook** (section 6) consolidating RSV job status, RPO/retention posture, and last-successful
  backup per protected item.
- This closes the loop on Business continuity and DR: the DR posture that exists in infrastructure becomes
  observable and alertable.

---

## 9. FinOps overlap

Cost signals already exist (per-sub + per-MG budgets, daily cost exports, a cost anomaly alert). O&M
**reuses** them rather than reinventing:

- Budget-breach and cost-anomaly notifications route to the **same platform action group** (Sev2/Sev3 by
  taxonomy) so operators see cost events alongside health events.
- **Ownership stays with FinOps** (Section 7): O&M does not own budgets or exports; it only consumes their
  alert output into the shared routing plane. The cost-anomaly alert becomes one more input to the ops
  action group, tagged so FinOps remains the accountable owner.
- The shelved synthetic cost-pattern signals are reusable here as **cost-anomaly monitoring test data**, not
  as a standing generator.

---

## 10. RBAC and operating model

O&M personas and least-privilege monitoring roles, coexisting with the OQ-008 scoped SP model (ADR-021):

| Persona | Responsibility | Least-priv role(s) | Scope |
|---|---|---|---|
| **Platform Ops** | Platform health, network, LAW, action groups, AMBA, DR/backup | Monitoring Contributor (author alerts/DCRs) + Log Analytics Reader | Platform + landingzones MG |
| **Workload Ops** | Spoke workload health | Monitoring Reader (+ Monitoring Contributor on their own spoke RG) | Per-spoke subscription/RG |
| **SecOps** | Sentinel, Defender, security LAW | Microsoft Sentinel roles + Security Reader | Security sub (unchanged) |
| **On-call responder** | Acknowledge/act on pages | Monitoring Reader + scoped Contributor for the runbooks they trigger | As needed, time-boxed |

- **Monitoring Reader** for read/triage; **Monitoring Contributor** only where alert/DCR authoring is needed;
  avoid broad Contributor for monitoring.
- The CI/deploy SP (ADR-021 scoped set) already has the ARM rights to deploy the O&M policy assignments and
  LAW resources; no new standing tenant-level grant is introduced by this design. AMBA DINE remediation
  identities are per-assignment managed identities, same class as the tag-governance remediation identity, and
  are cleaned up with the assignment (no MG-scoped standing Owner, unlike the OQ-008 concern).

---

## 11. Placement and propagation (the load-bearing table)

Explicit mapping of each capability to its owning root/scope and how landing zones inherit it. **Anchor =
`platform/management`; propagation = policy at MG scope; inheritance = automatic per spoke.**

| Capability | Owning root / scope | MG or sub level | Landing zones inherit via |
|---|---|---|---|
| Platform LAW (ops hub) | `platform/management` | management sub | Central workspace; spokes send here |
| Platform action group (extend) | `platform/management` | management sub | Referenced by AMBA + custom alerts |
| Diagnostic-settings-at-scale (DINE) | policy initiative via `platform/management-groups` (`avm-ptn-alz`) | Globaris root / platform / landingzones MG | DeployIfNotExists, automatic |
| AMBA baseline alerts + Service Health | AMBA-for-ALZ policy initiatives via `platform/management-groups` | platform + landingzones MG (some at Globaris root) | Policy inheritance, automatic |
| Resource Health alerts (platform-critical) | `platform/management` (targeted) + AMBA | management sub + MG | Mixed: AMBA-inherited + targeted |
| Custom component alerts (firewall/AppGw/DNS/EntraDS/KV) | `platform/management` (or the owning platform root) | connectivity/identity/security subs | Direct on platform resources |
| DCR + AMA association | DCR in `platform/management`; association by policy | management sub + MG | DINE association, automatic |
| Availability probes (App Insights / Connection Monitor) | `platform/management` | management sub, multi-region test origins | Targeted at public/critical paths |
| Workbooks + dashboard | `platform/management` (fill existing placeholders) | management sub | Central, read by all personas |
| DR/backup alerts | `platform/management` + each RSV's root | management sub + landingzones sub | AMBA recovery-services + targeted |
| Update Manager / maintenance configs | `platform/management` | management sub + per-VM | Policy-assigned to VMs |
| FinOps alert reuse | existing (`platform/management`) | management sub | Route to shared action group |

**Everything net-new lands in `platform/management` (assets) or `platform/management-groups` (policy
initiatives).** No new root, no new spoke, per ADR-036.

---

## 12. Phased roadmap

| Phase | Scope | Why this order | Rough effort |
|---|---|---|---|
| **MVP (Phase 1)** | Diagnostic-settings-at-scale (DINE) + AMBA baseline alerts + Service Health & Resource Health alerts + extend the platform action group + severity/routing taxonomy | The CAF "Manage" minimum: makes the whole estate observable and alertable with almost entirely policy + existing assets. Highest value, lowest surface. | S/M: mostly policy assignments + action-group extension. Reuses the LAW, action group, and `avm-ptn-alz` engine already deployed. |
| **Phase 2** | Availability probes (App Insights / Connection Monitor) + fill the platform-overview + network workbooks + DR/backup alerts + custom component alerts + Network Insights + Alert Processing Rules (maintenance windows) | Adds experience monitoring, curated visualization, and DR observability once the alert backbone exists. | M: targeted resources; a handful of probes and workbooks, not estate-wide. |
| **Phase 3** | Update Manager + guest-config baselines + policy remediation auto-remediation + ITSM/webhook integration + Managed Grafana (if needed) | Automation and enterprise integration; valuable but not required for a credible O&M baseline. | M/L: introduces new services and an ITSM dependency. |

**Recommended entry point:** Phase 1 only, if/when the estate becomes persistent. It is the bounded slice
named in ADR-036 and delivers a genuine CAF-aligned O&M baseline with minimal net-new build.

---

## 13. What already exists (reuse table) vs net-new

Honest accounting so the net-new work is unambiguous.

| Building block | Exists today? | Where | O&M action |
|---|---|---|---|
| Central platform LAW | **Yes** | management sub | Reuse as the ops hub; add DCRs |
| Security/Sentinel LAW | **Yes** | security sub | Leave as-is (SecOps); cross-workspace only |
| Platform action group | **Yes** | management sub | **Extend** (on-call/SMS, optional ITSM) |
| Automation Account | **Yes** | management sub | Reuse for ops runbooks + Update Manager |
| Budgets + cost exports + cost anomaly alert | **Yes** | management sub | Route into shared action group (FinOps owns) |
| Portal dashboard + placeholder workbooks | **Yes (stubs)** | management + security subs | **Fill / extend** |
| Sentinel + analytics rules + Sentinel workbooks | **Yes** | security sub | SecOps overlap only; not duplicated |
| Diagnostic-settings pattern (hand-placed) | **Yes (partial)** | KV, firewall, flow logs, automation, activity log | **Replace with DINE-at-scale** |
| Recovery Services Vaults + GZRS | **Yes** | landingzones sub | **Surface into ops alerting** |
| `avm-ptn-alz` policy engine (DINE-capable) | **Yes** | management-groups | **Deliver AMBA + diag DINE through it** |
| Flow logs + Traffic Analytics to platform LAW | **Yes** | all spokes | Reuse in network workbook |
| Remediation-identity pattern | **Yes** | tag governance | Reuse for AMBA/diag remediation |
| **AMBA alert library** | **No** | - | **NET-NEW (Phase 1)** |
| **Diagnostic-settings DINE initiatives** | **No** | - | **NET-NEW (Phase 1)** |
| **Service Health / Resource Health alerts** | **No** | - | **NET-NEW (Phase 1)** |
| **DCR + AMA at scale** | **No** | - | **NET-NEW (Phase 2)** |
| **Availability probes / Connection Monitor** | **No** | - | **NET-NEW (Phase 2)** |
| **Update Manager / maintenance configs** | **No** | - | **NET-NEW (Phase 3)** |

**Net-new is small and mostly policy:** the alert library (AMBA), the diagnostic-settings DINE initiatives,
and the health alerts are the Phase-1 build, all delivered through the policy engine and action group that
already exist.

---

## 14. Architecture layout (O&M over the deployed estate)

```
                       Tenant Root MG (Globaris)
                                |
        +-----------------------+------------------------+
        |                       |                        |
   platform MG              landingzones MG          (decommissioned/sandbox)
        |                       |
  +-----+------+          +-----+------+-----------+
  | mgmt  conn |          | corp | corp | online   |     <-- subscriptions / spokes
  | ident sec  |          |  a1  |  a2  |  p1       |
  +------------+          +------+------+-----------+

  ===================  POLICY PROPAGATION (DINE)  =========================
  AMBA-for-ALZ initiatives  +  Deploy-Diagnostics initiatives
  assigned at platform + landingzones (and Globaris root) MG scopes
  via avm-ptn-alz  ->  EVERY current & future spoke inherits automatically
  ========================================================================
                                |
                                v
   ---------------------  platform/management (ANCHOR, mgmt sub)  ----------
  |  Platform LAW (ops hub)  <---- diagnostics/metrics/flow logs/firewall   |
  |     ^         ^                 from all subs & spokes (DINE-wired)      |
  |     |         |                                                         |
  |  DCRs+AMA   Workbooks (platform / network / identity / DR)  Dashboard   |
  |     |         |                                                         |
  |  Availability probes (App Insights) + Connection Monitor (path health)  |
  |     |                                                                   |
  |     v                                                                   |
  |  ALERTS: AMBA baseline + Service/Resource Health + custom component     |
  |          + DR/backup (RSV) + FinOps (budgets/anomaly)                   |
  |     |                                                                   |
  |     v                                                                   |
  |  Platform Action Group (extended)  --> email / SMS-push (Sev0/1)        |
  |     |                                   / ITSM-webhook (Phase 3)        |
  |  Alert Processing Rules (maint-window suppression, hours, dedup)        |
   ------------------------------------------------------------------------
                                |
                                v
                    Platform Ops / Workload Ops / On-call
                    (Monitoring Reader/Contributor, least-priv)

   ---- SecOps seam (unchanged) ----
   Security LAW + Sentinel (security sub)  <== cross-workspace <==> platform LAW
   (SecOps personas; not moved or duplicated by O&M)
```

**Reading the diagram:** policy at MG scope pushes diagnostics + AMBA alerts down to every spoke; all
operational telemetry converges on the platform LAW in the management sub; the LAW feeds workbooks, probes,
and the full alert set; alerts route through the one extended platform action group to humans; Sentinel stays
a separate SecOps plane joined only by cross-workspace query.

---

## 15. Recommendation on anchoring

This design is broader than the AMBA sketch captured in ADR-036's follow-ups. I recommend a **light anchoring
ADR (proposed ADR-037)** to make the O&M **target architecture and its placement/propagation model** a
first-class accepted decision (platform-anchored in `platform/management`, policy-propagated via
`avm-ptn-alz` at MG scope, AMBA-based, MVP-bounded per section 12), superseding only the brief future-scope
bullets in ADR-036 while leaving ADR-036's reposition decision intact. I have not written that ADR yet, since
this is a docs-only design deliverable and the build is deferred; say the word and I will draft ADR-037 to
anchor it, and update OQ-033 to point at this document as the resolved design.
