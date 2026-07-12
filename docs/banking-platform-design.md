# Enterprise Azure Banking Platform - Founding Design (gap analysis, target architecture, phased build plan)

> **Status:** Founding design document for the banking-platform build on top of the existing CAF ALZ estate.
> Design and docs only; no Terraform is written by this document. This doc seeds a future `PROMPT-BANKING.md`
> (section-per-session model, unchanged).
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-12.
> **Source requirements:** Enterprise Azure Banking Platform Business Requirements (IT), 4 pages, provided by
> the user 2026-07-12 (kept outside the repo; content summarized in section 1 below).
> **Estate baseline:** the 13-section CAF ALZ POC in this repo, COMPLETE and QA-stamped, TORN DOWN clean
> 2026-07-11 (state backend + OIDC kept; redeploy is one `deploy.yml` run with known caveats).
> **Related ADRs:** ADR-039 (this pivot), ADR-037/036 (O&M target arch, Accepted-not-built), ADR-031/032
> (landingzones sub offer caps), ADR-033/034 (tenant Security-Admin gated security features), ADR-022
> (designed-now/built-later precedent), ADR-038 (AVM-direct, no wrapper modules).
> **Open questions raised:** OQ-034 through OQ-040.

---

## 0. Executive summary

- The user adopted an actual workload requirement: an **Enterprise Azure Banking Platform** on the existing
  landing zone. The AWS-Architecture rebuild is DEFERRED (ADR-039). The stance is **reuse, not rebuild**: the
  platform side of the requirements (ALZ, hub-spoke, identity, security, DR, IaC pipeline) is substantially
  already delivered by this repo's 13-section build.
- Gap verdict across the 11 requirement scope areas: **2 DONE** (Azure Landing Zone; Hub-and-Spoke
  Networking), **6 PARTIAL** (Identity, Enterprise Security, Shared Platform Services, Monitoring, Disaster
  Recovery, DevSecOps), **3 NET-NEW** (Kubernetes Platform, Enterprise Data Platform, AI Platform).
- "DONE" is an honest claim with a caveat: the estate is currently **torn down**. The code exists, is pinned,
  reviewed, and was live-deployed and QA-verified before teardown. Wave 0 of the build plan is the redeploy.
- The two headline NFRs - **99.99%+ availability** and **100,000 TPM** - are **design targets to document,
  not POC deployment targets** (the ADR-022 designed-now/built-later precedent). The POC deploys the private
  networking posture, the platform shape, and small SKUs; the production scale-out (APIM Premium
  multi-region, AKS multi-cluster, Service Bus Premium, zone-redundant everything) is documented per platform
  in this doc and priced separately.
- **Lifecycle audit results (LESSONS 40-41, run 2026-07-12):** the requirements doc names Azure Synapse, but
  Microsoft's strategic direction for net-new analytics is **Microsoft Fabric**; Synapse is supported with no
  announced EOL, yet has targeted deprecations and its CAF cloud-scale-analytics guidance was deprecated for
  deletion in April 2026. This design does NOT anchor net-new work on Synapse; the data platform anchors on
  **Databricks + ADLS Gen2 now, optional Fabric capacity** (decision OQ-037). The AI platform must use
  current naming: **Microsoft Foundry** (the renamed Azure AI Foundry; resources live in the
  Microsoft.CognitiveServices namespace).
- All required AVM modules for the net-new platforms **exist and were verified on the Terraform Registry
  today** (section 6, verification log). One maturity flag: `avm-res-eventhub-namespace` has a single 0.1.0
  release from 2025-04.
- Rough POC cost envelope for the net-new platforms: roughly **$0.9k-1.4k/mo** on top of the redeployed base
  estate ($3.6-4.8k/mo per COST.md), or **$1.6k-2.1k/mo** if Service Bus Premium is chosen for private
  endpoint compliance (Premium is the only Service Bus tier that supports private endpoints). Budget ceiling
  is OQ-039.
- The build plan is **11 waves (B0-B10)**, one section per session, dependency-ordered, with Wave 0 = estate
  redeploy. All standing gates carry over unchanged: architect pre-clearance before any first apply or retry,
  plan-scan before every apply, one consolidated fix-spec per failure set, batched review per deploy
  iteration, and QA-before-green.

---

## 1. Requirement-to-estate gap analysis

The requirements doc defines 11 scope areas. For each: classification, what exists (with the root/section
citation), and the delta.

Honesty note on "DONE": the estate was torn down 2026-07-11 for cost control. DONE means the code exists in
this repo, is version-pinned, was live-deployed end to end via CI, and passed the QA live-state check before
teardown. Nothing is currently running. Redeploy caveats are recorded in the 2026-07-11 WORKLOG teardown
entry (state-SA firewall window, KV soft-delete recovery, Microsoft.AAD RP re-registration timing).

| # | Scope area | Verdict | Evidence / delta summary |
|---|---|---|---|
| 1 | Azure Landing Zone | **DONE** | `platform/management-groups` (avm-ptn-alz 0.19.1, ALZ library 2026.04.2), Sections 1-2. MG hierarchy + ALZ policy engine, proven deployable + destroyable. |
| 2 | Hub-and-Spoke Networking | **DONE** | `platform/connectivity` (avm-ptn-alz-connectivity-hub-and-spoke-vnet 0.17.1), Sections 3-4. Dual-region (eastus2 + centralus), 2x Azure Firewall Premium, VPN GW, DNS Private Resolver, 89 private DNS zones, hub-to-hub global peering. Known POC deviation: no DDoS Network Protection plan (~$3k/mo, documented in the fidelity map). |
| 3 | Identity Platform | **PARTIAL** | Exists: `platform/identity` - Entra DS (identity sub), 8 CA policies (report-only), PIM eligible at MG scope, geo-block named location (Sections 5, 8). Delta: CA enforcement-mode decision for a banking bar; AKS workload identity federation; PIM access reviews / approval flows (known fidelity-map gap); CMK posture expansion. |
| 4 | Enterprise Security Platform | **PARTIAL** | Exists: `platform/security` - 7 Defender plans, Sentinel + 11 analytics rules, diagnostics (Section 6). Delta: Defender for Containers for AKS; regulatory compliance initiative assignments (PCI DSS, NIST 800-53) in Defender; KV public-network-access fix (Section 12 finding); CMK enforcement. Still tenant-gated behind Security Administrator: UEBA, aad-diagnostics, dc-aad, dc-ti, firewall TI rule (ADR-033/034, OQ-027/028) - unchanged by this initiative. |
| 5 | Shared Platform Services | **PARTIAL** | Exists: Key Vaults, state backend, on-demand Bastion (ADR-015), Automation Account, budgets/cost exports (Sections 7-8). Delta: Azure Container Registry (net-new, Premium for Private Link); the integration tier (APIM/Event Hubs/Service Bus) is treated as its own net-new platform below. |
| 6 | Kubernetes Platform | **NET-NEW** | Nothing container-related in the estate. Target: AKS private cluster + ACR in a new banking spoke (section 2.1). |
| 7 | Enterprise Data Platform | **NET-NEW** | No analytics estate. Target: Databricks + ADLS Gen2, optional Fabric capacity; Synapse NOT anchored (lifecycle audit, section 2.3, OQ-037). |
| 8 | AI Platform | **NET-NEW** | Nothing AI in the estate. Target: Microsoft Foundry resource (Azure OpenAI models), Document Intelligence, AI Search (section 2.4, OQ-038). |
| 9 | Monitoring Platform | **PARTIAL** | Exists: platform LAW, action group, Automation Account, diagnostic-settings pattern, cost anomaly alert (`platform/management`, Section 8). Delta: the ADR-037 O&M Phase-1 slice (AMBA baseline + Service/Resource Health + DINE diagnostics-at-scale + severity taxonomy) is **Accepted-not-built** - this initiative finally BUILDS it (section 2.5). |
| 10 | Disaster Recovery Platform | **PARTIAL** | Exists: dual-region hubs, corp-a2 DR spoke, RSVs (corp-a1 ZRS, corp-a2 GRS), GZRS finops SA, RTO/RPO table in ARCHITECTURE.md (Section 3). Delta: DR posture for the net-new platforms (AKS second cluster, data geo-redundancy, APIM multi-region) - documented at design, not deployed at POC scale (section 3). |
| 11 | DevSecOps Platform | **PARTIAL** | Exists: GitHub Actions OIDC CI/CD (plan-on-pr, deploy.yml, teardown.yml), branch ruleset, pre-commit hooks, review gates (Section 10). Delta: CodeQL, Dependabot, secret scanning, production environment approvals (OQ-015 still open on the apply-run gate), GitHub Enterprise question (section 2.6, OQ-040). |

Requirements explicitly satisfied by the existing estate with no delta: Azure Firewall Premium, Private DNS,
Private Endpoints pattern (89 zones + DNS zone group wiring proven on the SQL PE), Entra ID, Key Vault, RBAC,
PIM, Conditional Access, Defender for Cloud, Sentinel, Azure Monitor baseline plumbing, IaC (Terraform), and
the Zero Trust pillar mapping in ARCHITECTURE.md.

Business-capability layers (core banking apps, payments rails such as FedNow/SWIFT connectivity, fraud
scoring models) are APPLICATION scope, not landing-zone scope. This design delivers the platforms those
applications land on; it does not design the applications. That boundary matches the requirements doc's own
success criterion: "platform ready for onboarding banking workloads."

---

## 2. Target architecture for the net-new and extended platforms

All module references below were verified on the Terraform Registry on 2026-07-12 (section 6). Version pins
are the latest at time of writing; the implementer re-confirms latest patch at build time. Input-level
argument names were NOT individually verified in this doc; the implementer verifies inputs against each
module's registry docs at build time (standing CLAUDE.md rule 4). Per ADR-038, all modules are consumed
directly in composition roots; no wrapper modules.

### 2.0 Placement: spokes, subscriptions, management groups

Proposed default (decision OQ-035, verification items flagged):

- Two new landing-zone spokes under the existing Corp archetype (internal-only, no public ingress):
  - `landing-zones/bank-app-p1` (eastus2): AKS + ACR + integration tier (Event Hubs, Service Bus, APIM
    internal).
  - `landing-zones/bank-data-p1` (eastus2): data platform (Databricks, ADLS Gen2) + AI platform (Foundry,
    AI Search, Document Intelligence).
- Both peered to the primary hub, firewall-routed, private-endpoint-only, DNS-linked - the proven corp-a1
  spoke template.
- DR: no second-region banking spokes at POC. The DR posture per platform is documented in section 3 and
  follows the corp-a2 precedent when built.
- Subscription: default is the existing `landingzones` sub, BUT that sub has a documented offer-cap history
  (ADR-031 SQL ProvisioningDisabled in eastus2; ADR-032 App Service dedicated compute quota 0). **Flagged
  verification item (pre-clearance, LESSON 42/58):** AKS node pools consume Microsoft.Compute vCPU quota,
  which is a DIFFERENT quota family from the Microsoft.Web dedicated quota that blocked App Service - but the
  same offer may also carry low Compute caps, and Databricks provisions its VMs in the workload sub too.
  Check Total Regional vCPUs + the target VM family quota + any per-service provisioning restrictions in the
  candidate sub/region BEFORE anchoring placement. If caps bite, the alternative is a new banking
  subscription under the Corp MG (OQ-035).
- Every spoke must be shippable network-only (LESSON 42): each banking section gates its workload tier behind
  a default-false flag so an offer cap never strands a wave.

### 2.1 Kubernetes Platform (AKS) - NET-NEW

POC deployment:

- **Module:** `Azure/avm-res-containerservice-managedcluster/azurerm` **0.6.7** (published 2026-06-24,
  verified). The pattern module `Azure/avm-ptn-aks-production/azurerm` 0.5.0 exists but is older
  (2025-04-29) and more opinionated; default is the resource module for spoke-composition control. Final
  choice is OQ-036.
- **Posture (Zero Trust, matches the estate's Deny-Public-Network policy):** private cluster (private API
  server + private DNS zone `privatelink.<region>.azmk8s.io`, already in the 89-zone set - implementer
  confirms the zone is present and hub-linked), Azure CNI Overlay, Entra ID + Azure RBAC for cluster auth
  (no local accounts), workload identity + OIDC issuer enabled, outbound type `userDefinedRouting` through
  the hub firewall (Azure Firewall Premium already does IDPS/TLS inspection), system + one user node pool,
  availability zones where the region supports them.
- **Registry:** `Azure/avm-res-containerregistry-registry/azurerm` **0.5.1** (verified). Premium SKU
  (required for Private Link), public network access disabled, PE into the spoke.
- **Security tie-in:** enable the Defender for Containers plan in `platform/security` in the same wave
  (plan-scan required: Defender pricing resources have the ForceNew subplan landmine, LESSON 26 / ADR-035).
- POC scale: 2-3 nodes, general-purpose v5 family, cluster autoscaler bounded low. Free control-plane tier
  is acceptable at POC; Standard tier (paid, uptime SLA) is the production design target.

Production design target (documented, not deployed): Standard/Premium tier control plane, multi-AZ node
pools, second cluster in centralus behind the DR posture in section 3, image signing + policy-enforced
admission, Backup for AKS.

### 2.2 API and Integration Platform (APIM, Event Hubs, Service Bus) - NET-NEW

- **APIM:** `Azure/avm-res-apimanagement-service/azurerm` **0.9.0** (verified). POC: **Developer tier**
  (VNet-capable, no SLA, ~$50/mo) injected into the `bank-app-p1` spoke, internal mode, fronted later by the
  existing online-p1 App Gateway WAF pattern if external exposure is demonstrated. Production design target:
  **Premium** (~$2.8k/mo/unit, verified order of magnitude), multi-region active-active, availability zones,
  which is also what the 99.99% SLA line requires. Note: classic-tier APIM creates run 30-60+ minutes; do
  not co-locate its first apply with token-lifetime-bound operations (LESSON 46 class).
- **Event Hubs:** `Azure/avm-res-eventhub-namespace/azurerm` **0.1.0** (verified; MATURITY FLAG: single
  release, 2025-04-28). Standard tier at POC - private endpoints ARE supported on Standard (verified;
  Basic is not). If the module proves too thin at build time, fall back to native `azurerm_eventhub_namespace`
  with a `# DEVIATION:` comment per CLAUDE.md rule 5.
- **Service Bus:** `Azure/avm-res-servicebus-namespace/azurerm` **0.4.0** (verified). **Tier decision
  (OQ-039):** private endpoints require **Premium only** (verified, ~$680/mo/messaging unit approximate).
  Options: (a) deploy Premium at POC and eat the cost, (b) deploy Standard behind the estate's established
  RG-scoped policy-exemption pattern (ADR-028/LESSON 35 waiver unit) as a documented POC deviation,
  (c) gate Service Bus off at POC (default-false flag) and document it as production design only.
  Recommended default: (b) at POC, Premium in the production design.

Payments-rail note: ACH/FedNow/SWIFT connectivity is application/partner-network scope. The platform
contribution is the messaging backbone above plus the VPN GW (exists) for partner links; no SWIFT CSP
enclave is designed at POC.

### 2.3 Enterprise Data Platform - NET-NEW, with a mandatory lifecycle statement

**Lifecycle audit (LESSONS 40-41, run 2026-07-12):** the requirements doc names Azure Synapse. Current
Microsoft positioning, verified today against Microsoft Learn and the Fabric blog:

- Azure Synapse Analytics is **supported, no announced end-of-life**, BUT Microsoft's strategic net-new
  analytics platform is **Microsoft Fabric**; official migration guides and a built-in migration assistant
  (Synapse dedicated SQL pools to Fabric Warehouse, Synapse Spark to Fabric) are published.
- Targeted Synapse deprecations already landed: Synapse Data Explorer retired 2025-10; Synapse Link for
  Cosmos DB closed to new projects (Fabric mirroring is the successor); the CAF cloud-scale-analytics
  Synapse guidance was deprecated with deletion scheduled April 2026.
- Verdict: **anchoring a 2026 net-new banking data platform on Synapse is a stale-service risk of exactly
  the class LESSON 40 exists to catch.** An AVM module exists (`avm-res-synapse-workspace` 0.1.0,
  2026-05-15) so it is buildable, but buildable is not advisable.

Proposed anchor (decision OQ-037):

- **Databricks** for engineering/ML: `Azure/avm-res-databricks-workspace/azurerm` **0.5.0** (verified).
  Premium SKU, **VNet-injected** into `bank-data-p1` (private subnets + NPIP/secure cluster connectivity),
  private endpoints for front-end and back-end. Near-zero idle cost; compute billed only when clusters run.
- **ADLS Gen2** lakehouse storage: `Azure/avm-res-storage-storageaccount/azurerm` **0.7.3** (verified),
  HNS enabled, private endpoints (blob + dfs), CMK per the estate's KV pattern.
- **Optional Fabric capacity** for the BI/regulatory-reporting face (executive dashboards, Power BI):
  native `azurerm_fabric_capacity` resource (azurerm provider; no AVM module exists - verified) at **F2
  pay-as-you-go (~$263/mo, pausable, verified approximate)**. In-Fabric artifacts (workspaces, lakehouses)
  use the separate `microsoft/fabric` Terraform provider and are OUT of POC scope - at most the capacity
  resource is deployed.
- Synapse: NOT deployed. Recorded here as the requirements-doc term; this design satisfies the intent
  (enterprise analytics) with the current-generation services.

Regulatory-reporting and fraud-analytics capabilities from section 4 of the requirements map onto this
platform as application workloads (Databricks jobs, Fabric reports), not additional infrastructure.

### 2.4 AI Platform - NET-NEW, with the naming audit

**Naming/lifecycle audit (verified 2026-07-12):** Azure AI Foundry has been renamed **Microsoft Foundry**
(Microsoft Learn docs now live under /azure/foundry; the hub-based model is "Foundry (classic)"). Foundry
resources live in the **Microsoft.CognitiveServices** provider namespace; Azure OpenAI resources can be
upgraded to Foundry resources keeping their endpoints. A 2026 design must specify Foundry-resource-first,
not the classic hub/project (Microsoft.MachineLearningServices) shape.

Proposed POC deployment in `bank-data-p1`:

- **Foundry resource** (virtual banking assistant + predictive-analytics model access):
  `Azure/avm-res-cognitiveservices-account/azurerm` **0.11.1** (verified; the module covers
  Microsoft.CognitiveServices accounts - implementer confirms the AIServices/Foundry kind support in the
  module docs at build time; if the Foundry kind is not yet surfaced, fall back to an OpenAI-kind account or
  azapi with a `# DEVIATION:` comment). Public network access disabled, PE, managed identity, one or two
  small model deployments (e.g. a mini/nano chat model) at pay-as-you-go token pricing. PTU reservations are
  production design only.
- **Document Intelligence** (document processing): same module, Document Intelligence kind (ARM kind value
  verified at build time), S0, PE.
- **AI Search** (RAG for the assistant): `Azure/avm-res-search-searchservice/azurerm` **0.3.0** (verified).
  Basic tier at POC (~$75/mo UNVERIFIED exact price), PE, public access disabled. Note: some Basic-tier
  limits constrain private-link + semantic features; implementer confirms tier capability at build
  pre-clearance.
- All four AI/data private DNS zones (openai/cognitiveservices/search/dfs) - implementer confirms presence
  in the existing 89-zone set and adds any missing zone in the B1 network wave.

Scope control: which of the three AI services actually deploys at POC (vs design-only) is OQ-038.

### 2.5 Monitoring Platform - PARTIAL: build the ADR-037 Phase-1 slice, do not redesign

The Monitoring Platform requirement is ALREADY DESIGNED: `docs/operations-monitoring-design.md` is the
Accepted target architecture (ADR-037), with a bounded Phase-1 MVP: diagnostic-settings-at-scale (DINE via
avm-ptn-alz), AMBA baseline alerts, Service Health + Resource Health alerts, platform action group
extension, Sev0-4 severity taxonomy. This initiative changes its status from Accepted-not-built to BUILT
(wave B7). No redesign; the only build-time deltas are the two deferred sub-decisions recorded in OQ-033
(AMBA delivery form; exact DINE MG scopes) plus AMBA coverage for the new resource types (AKS, APIM, Event
Hubs, Service Bus, Databricks). The 24x7 monitoring / centralized logging / incident-response operational
requirements map to this wave plus the existing Sentinel estate; runbook content extends RUNBOOK.md.

### 2.6 DevSecOps Platform - PARTIAL: pipeline exists, add the scanning + approval layer

Exists (Section 10, proven on 92 CI runs): GitHub Actions OIDC (no secrets), plan-on-pr, per-root
deploy/teardown, branch ruleset on main, pre-commit hooks, review gate scripts.

Net-new (wave B8):

- **Dependabot:** free on all repos; version + security updates for Terraform providers/modules and Actions.
- **CodeQL:** for the repo's non-Terraform code (scripts, workflows). NOTE: CodeQL on PRIVATE repos requires
  the paid code-scanning product; since Microsoft unbundled GitHub Advanced Security (2025), Code Security
  and Secret Protection are purchasable standalone on Team plans WITHOUT GitHub Enterprise - plan/pricing
  reality for the Globaris-Inc org is OQ-040 (UNVERIFIED against the org's current billing).
- **Secret scanning + push protection:** same product family; same OQ-040 dependency. Interim: the repo
  already had a secret sweep and history rewrite (2026-07-03) plus pre-commit hooks.
- **Production approvals:** the requirements doc demands production approvals; OQ-015 is STILL OPEN on the
  apply-run gate (environment required-reviewer blocked on the org's Team billing entitlement; branch
  protection on main was the accepted interim). This initiative re-raises it as part of OQ-040 - a banking
  platform story needs the apply gate closed, either via the environment reviewer (once billing entitlement
  is live) or the free typed confirm guard.
- **GitHub Enterprise:** the requirements name GHE. The org runs Team. GHE is NOT required for any POC
  capability above once standalone GHAS products are available on Team; GHE is recorded as a production
  design target only (OQ-040).

Bicep note: the requirements say "Bicep/Terraform". The estate is Terraform-only (13 sections of precedent);
this design keeps Terraform-only and records Bicep as satisfied-by-alternative. No dual-toolchain.

### 2.7 Extended platforms (deltas on existing roots)

- **Identity (wave B1/B9):** enable AKS workload identity federation (Entra workload identities for
  in-cluster pods); revisit the 8 CA policies' report-only mode - flipping to enforced is a user decision
  recorded at build time; PIM access reviews remain a documented gap unless the user pulls them in.
- **Security (wave B9):** assign the built-in regulatory compliance initiatives relevant to the compliance
  list (PCI DSS 4.0, NIST 800-53 R5, SOC 2) in Defender for Cloud at the banking MG scope - assessment
  visibility, not new enforcement; fix the Section-12 finding (both KVs publicNetworkAccess=Enabled, no
  network ACLs); extend the CMK pattern to the new data stores. The ADR-033/034 tenant-gated items stay
  gated behind their default-false flags until the tenant Security Administrator grant exists.
- **DR (wave B10, documentation):** section 3 below.

---

## 3. POC-vs-design split (the two headline NFRs) and cost envelope

### 3.1 The split

Per the ADR-022 designed-now/built-later precedent, and now recorded in ADR-039:

| NFR | POC does | Production design documents |
|---|---|---|
| 99.99%+ availability | Correct shape: dual-region hubs (exist), zone-aware SKUs where free/cheap, health probes | APIM Premium multi-region, AKS Standard-tier multi-cluster + AZ node pools, Service Bus Premium with geo-DR, zone-redundant everything, DDoS plan; a composite SLA table per platform (single-region single-instance CANNOT meet 99.99 - the doc must say so explicitly) |
| 100,000 TPM | Nothing is load-tested (the synthetic layer was deliberately repositioned, ADR-036); document the scaling units | Scale-unit math per tier: APIM units, Event Hubs TUs/PUs, AKS node/pod autoscaling bounds, Databricks cluster policies; a capacity-management runbook section (ties to the operational requirements) |
| Horizontal scaling | Autoscaler enabled with tiny bounds on AKS | Autoscale policies per platform |

DR platform posture at POC: the existing corp-a2 pattern proves the mechanism (second-region spoke + RSV +
GRS). The banking spokes deploy single-region at POC; the DR chapter (wave B10) documents per-platform
failover design (AKS cluster pair + traffic routing, data geo-replication, APIM multi-region) with RTO/RPO
targets extending the existing ARCHITECTURE.md table.

### 3.2 Rough POC cost envelope (monthly, list, order-of-magnitude)

Verified figures marked; everything else is approximate list pricing to be re-verified at each wave's
pre-clearance. Prior estate baseline: ~$3.6-4.8k/mo with the 2 firewalls at 55-65% (COST.md).

| Item | POC est./mo | Note |
|---|---|---|
| Wave 0: redeployed base estate | $3,600-4,800 | COST.md; scope decision OQ-034 could trim this |
| AKS (nodes + LB + disks, Free control plane) | $300-500 | 2-3 small v5 nodes; UNVERIFIED exact VM rates |
| ACR Premium | ~$50 | approximate list |
| APIM Developer | ~$50 | verified order of magnitude (Premium ~$2.8k is design-only) |
| Event Hubs Standard (1 TU) | ~$25 | approximate |
| Service Bus | $10 (Standard + exemption) or ~$680 (Premium) | PE requires Premium - verified; decision in OQ-039 |
| Databricks (idle workspace + light usage) | $50-150 | usage-dependent, UNVERIFIED |
| ADLS Gen2 + PEs | $30-60 | PEs ~$7.3/mo each plus data |
| Fabric F2 (if chosen, pausable) | ~$263 | verified approximate pay-go |
| Foundry models (tokens) + Document Intelligence | $30-80 | usage-dependent, UNVERIFIED |
| AI Search Basic | ~$75 | UNVERIFIED exact |
| O&M Phase 1 (LAW ingestion delta) | $50-150 | UNVERIFIED |
| Net-new subtotal | **~$900-1,400** | **~$1,600-2,100 with Service Bus Premium** |
| Estate total | **~$4.5k-6.2k** | ceiling decision OQ-039 |

---

## 4. Phased build plan (seeds PROMPT-BANKING.md)

One section per session, dependency-ordered. Every wave: architect pre-clearance doc
(`docs/preclearance/<root>.md`) before first apply or retry, plan-scan before every apply, default-false
flags on offer-cap-exposed and tenant-gated tiers, one consolidated fix-spec per failure set, batched
review, QA-before-green. If more than 2 weeks pass between this design and a wave's first apply, re-run the
LESSON 40-41 lifecycle audit for that wave's resource types.

| Wave | Section | Scope | Depends on |
|---|---|---|---|
| **B0** | Redeploy | Redeploy the existing estate via deploy.yml per OQ-034 (full vs subset). Caveats: state-SA firewall window, `recover_soft_deleted_key_vaults` (within the 90-day window), Microsoft.AAD RP re-registration, refresh EVERY root's pre-clearance (policy matrix may have drifted since 2026-07-11). QA live-check before green. | none |
| **B1** | Banking network foundation | `landing-zones/bank-app-p1` + `landing-zones/bank-data-p1` network-only: VNets, subnets (AKS, PE, APIM, Databricks public/private pair), NSGs + VNet flow logs, hub peering + UDR via firewall, DNS zone links, any missing private DNS zones (aks/openai/search etc.), placement per OQ-035. Shippable with zero workload resources. | B0 |
| **B2** | Kubernetes platform | AKS private cluster (avm-res-containerservice-managedcluster 0.6.7) + ACR Premium (0.5.1) in bank-app-p1; workload identity + OIDC issuer; Defender for Containers plan flip in platform/security (plan-scan for the ForceNew subplan class). | B1 |
| **B3** | Eventing backbone | Event Hubs Standard (avm-res-eventhub-namespace 0.1.0, maturity fallback allowed) + Service Bus per OQ-039 tier decision, PEs/exemption unit as decided. | B1 |
| **B4** | API platform | APIM Developer, internal VNet mode, in bank-app-p1 (avm-res-apimanagement-service 0.9.0). Long-create; isolate the apply. | B1 (B2 for backends) |
| **B5** | Data platform | Per OQ-037: Databricks VNet-injected (0.5.0) + ADLS Gen2 (0.7.3) + optional Fabric F2 capacity (native resource). | B1 |
| **B6** | AI platform | Per OQ-038: Foundry resource + model deployment, Document Intelligence, AI Search (0.11.1 / 0.3.0), all PE-only. | B1 (B5 for RAG data) |
| **B7** | Monitoring Phase 1 | BUILD the ADR-037 O&M MVP exactly as designed in docs/operations-monitoring-design.md section 12 Phase 1, extended with AMBA coverage for the new resource types. Extends platform/management + avm-ptn-alz policy engine; no new root. | B0 (more value after B2-B6) |
| **B8** | DevSecOps additions | Dependabot, CodeQL + secret scanning per OQ-040 plan reality, production apply gate (closes OQ-015 one way or the other). Repo/org config, no Azure resources. | none (parallel-safe) |
| **B9** | Security and compliance extension | Defender regulatory compliance initiatives (PCI DSS, NIST 800-53, SOC 2) at banking scope; KV network posture fix; CMK on new data stores; identity deltas (CA enforcement decision, access reviews if pulled in). | B1-B6 |
| **B10** | DR + docs + acceptance | DR design chapter per net-new platform (documented, not deployed); COST.md/ARCHITECTURE.md/SECURITY.md/RUNBOOK.md updates; PROMPT-BANKING.md acceptance criteria; QA acceptance validation run (Section-12 style, honest). | all |

Parking (explicitly out of scope, recorded to prevent speculative build): FedNow/SWIFT connectivity design,
core-banking application architecture, fraud/AML model design, ExpressRoute, DDoS plan, Sentinel SOAR
playbooks beyond the O&M slice, multi-region banking spokes.

---

## 5. Standing gates and operating model (unchanged)

The section-per-session model and every standing gate carry over UNCHANGED from the ALZ build: architect
pre-clearance before any first apply or retry of any root; plan-scan (any -/+ replace or unexpected destroy
on a live resource is a STOP); one consolidated fix-spec per failure set; batched code review per deploy
iteration; QA live-state validation before any root is marked green; propose-not-run for git commits; no
personal values in committed docs; LESSONS.md as the pre-flight checklist.

---

## 6. Verification log (what this design checked, 2026-07-12)

| Claim | How verified |
|---|---|
| avm-res-containerservice-managedcluster 0.6.7 (2026-06-24) | Terraform Registry API |
| avm-ptn-aks-production 0.5.0 (2025-04-29) | Terraform Registry API |
| avm-res-containerregistry-registry 0.5.1 (2026-01-15) | Terraform Registry API |
| avm-res-apimanagement-service 0.9.0 (2026-05-25) | Terraform Registry API |
| avm-res-eventhub-namespace 0.1.0 (2025-04-28, single release - maturity flag) | Terraform Registry API |
| avm-res-servicebus-namespace 0.4.0 (2025-03-05) | Terraform Registry API |
| avm-res-databricks-workspace 0.5.0 (2026-05-21) | Terraform Registry API |
| avm-res-synapse-workspace 0.1.0 (2026-05-15) - exists but not anchored | Terraform Registry API |
| avm-res-cognitiveservices-account 0.11.1 (2026-06-21) | Terraform Registry API |
| avm-res-search-searchservice 0.3.0 (2026-06-19) | Terraform Registry API |
| avm-res-storage-storageaccount 0.7.3 (2026-06-24) | Terraform Registry API |
| avm-res-machinelearningservices-workspace 0.9.0 (2025-09-01) - classic Foundry hub shape, NOT the default | Terraform Registry API |
| No Azure/avm-res-fabric-capacity module exists; Fabric capacity = native azurerm_fabric_capacity; in-Fabric items = microsoft/fabric provider | Registry API (NOT FOUND) + web search (Microsoft Learn / Fabric blog) |
| Synapse supported / no EOL, Fabric is the strategic net-new direction, targeted Synapse deprecations (Data Explorer retired 2025-10, Synapse Link for Cosmos closed to new, CAF Synapse guidance deprecated for April 2026 deletion) | Web search, Microsoft Learn + Fabric blog, 2026-07-12 |
| Azure AI Foundry renamed Microsoft Foundry; Foundry resources in Microsoft.CognitiveServices namespace; hub model is "Foundry (classic)" | Web search, Microsoft Learn /azure/foundry, 2026-07-12 |
| Service Bus private endpoints: Premium tier ONLY; Event Hubs private link: Standard and above | Web search, Microsoft Learn, 2026-07-12 |
| APIM pricing order of magnitude (Developer ~$50/mo, Premium ~$2.8k/mo/unit) | Web search, Azure pricing pages, 2026-07-12 |
| Fabric F2 pay-go ~$263/mo | Web search, Azure pricing pages, 2026-07-12 |
| NOT verified: AVM module input names/shapes for the modules above; exact VM/Search/Databricks/LAW prices; ARM kind values for Foundry and Document Intelligence within avm-res-cognitiveservices-account; Globaris-Inc GitHub billing entitlements; landingzones sub Compute quota | Marked UNVERIFIED where cited; owned by wave pre-clearance / OQ-035 / OQ-040 |

---

## 7. Decisions and open questions

- **ADR-039** (DECISIONS.md): the pivot itself - AWS deferred, banking platform adopted on the existing LZ,
  POC-scale-vs-design-target split, reuse-not-rebuild.
- **OQ-034:** redeploy timing and scope (full estate vs banking-needed subset).
- **OQ-035:** subscription/MG placement for the banking spokes + the Compute-quota verification item.
- **OQ-036:** AKS topology and module choice.
- **OQ-037:** data platform anchor (Databricks+ADLS with optional Fabric, vs Synapse per the raw
  requirements, vs Databricks-only).
- **OQ-038:** AI platform POC scope.
- **OQ-039:** budget ceiling + the Service Bus Premium-vs-exemption decision.
- **OQ-040:** GitHub plan reality for CodeQL/secret scanning/approvals (GHE vs Team + standalone GHAS).
