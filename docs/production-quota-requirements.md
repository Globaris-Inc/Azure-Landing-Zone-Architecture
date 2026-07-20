# Production Quota & Offer Requirements - Wednesday production deploy (ticket-ready)

> **Status:** ACTION DOC for opening Azure support tickets TODAY (2026-07-19). Estate destroy is
> running; Wednesday = full production-level deploy. Mined from the build history (WORKLOG,
> DECISIONS, docs/b-restoration-design.md register, the B2/B5/B6 pre-clearances).
> **Owner:** Cloud Solutions Architect.
> **The single most important thing in this doc is section 1: OFFER caps vs QUOTA limits. A region
> move does NOT fix an offer cap - only a different subscription offer does. Get this decided
> before filing region-based tickets.**
> **Live data captured 2026-07-19** on `sub-landingzones-poc-01` across eastus2/centralus/eastus/
> westus3/southcentralus (quota is per-sub-per-region, unaffected by the teardown).

---

## 1. THE CRUX: OFFER caps vs QUOTA limits (decide this FIRST)

Two different failure classes hit this build. They need DIFFERENT remedies:

- **QUOTA limit** = a per-subscription-per-region ceiling on a resource you ARE allowed to create.
  Raised by a **quota support ticket** (often self-service / auto-approved). Examples: Total
  Regional vCPUs, a v4 VM-family vCPU count, Fabric CU, AI Search units, OpenAI TPM.
- **OFFER cap** = the subscription's OFFER (the POC/MSDN/CSP/PAYG type) structurally DISALLOWS a
  resource type or SKU family, regardless of region. A quota ticket typically will NOT lift it.
  **The fix is a different subscription offer (EA / MCA / production PAYG), NOT a ticket, NOT a
  region move.** Live-proven examples on this sub:
  - **v5 VM families = 0 in EVERY region tested** (DSv5, Dv5 = 0/0 in eastus2, centralus, eastus,
    westus3, southcentralus - verified today). The cap TRAVELS with the subscription. Moving
    eastus2 -> centralus -> anywhere does NOT give v5.
  - **SQL Database ProvisioningDisabled** (eastus2, ADR-031) and **App Service dedicated compute
    ProvisioningDisabled** (ADR-032) - offer-level "provisioning disabled" restrictions, distinct
    from vCPU quota.

**-> HIGHEST-RISK DECISION for Wednesday:** confirm whether the production subscription is a
PRODUCTION-GRADE OFFER (EA/MCA) that does not carry these caps. If the Wednesday deploy stays on
the current POC-class offer, v5 / SQL / App Service will fail in ANY region and no ticket fixes it.
If a new production sub is used, most of section 3's per-region tickets are filed against a clean
slate (default quotas, ticketable up).

---

## 2. Live quota snapshot (2026-07-19, current landingzones sub, per region)

| Quota | eastus2 | centralus | eastus | westus3 | southcentralus | Class |
|---|---|---|---|---|---|---|
| Total Regional vCPUs | 6/**24** | 0/10 | 0/10 | 0/10 | 0/10 | QUOTA (ticketable) |
| Standard DSv4 vCPUs | 6/10 | 0/10 | 0/10 | 0/10 | 0/10 | QUOTA |
| Standard DDSv4 vCPUs | 0/10 | 0/10 | 0/10 | 0/10 | 0/10 | QUOTA |
| Standard DASv4 vCPUs | 0/10 | 0/10 | 0/10 | 0/10 | 0/10 | QUOTA |
| **Standard DSv5 / Dv5 vCPUs** | **0/0** | **0/0** | **0/0** | **0/0** | **0/0** | **OFFER cap (all regions)** |

The 24 in eastus2 is the OQ-043 build-time raise; every other region sits at the 10 default. v5 = 0
everywhere is the offer signature.

---

## 3. Constraint enumeration (every item the build hit or production needs)

Each row: what, the live/known limit, the production target (planning estimate - tune to final
workload sizing), the ticket category, and OFFER-or-QUOTA.

| # | Requirement | Quota/resource name | Current | Production target (estimate) | Ticket category | Class |
|---|---|---|---|---|---|---|
| Q1 | **AKS + general Compute, main region** | Total Regional vCPUs | 10 (24 eastus2) | **256-512** (system+user pools, autoscale, surge; +DR cluster if f9 doubles) | Compute-VM (cores) quota | QUOTA |
| Q2 | AKS/Databricks node family | Standard DSv4 / DDSv4 / DASv4 vCPUs (per family) | 10 each | **64-128 per chosen family** | Compute-VM (per-family cores) | QUOTA (on v4) |
| Q3 | **v5 node family (IF wanted)** | Standard DSv5 / Dv5 / DDSv5 vCPUs | **0 (all regions)** | 64-128 if v5 chosen | Compute-VM cores | **OFFER cap - needs a production offer, not a ticket; else STAY ON v4** |
| Q4 | Databricks cluster compute | (consumes the same Compute vCPU families as Q1/Q2 in the workload sub) | n/a (no clusters built) | included in Q1/Q2 totals; size to job/interactive cluster plan | Compute-VM cores | QUOTA (v4) / OFFER (v5) |
| Q5 | **Microsoft Fabric capacity** | Fabric CU (F-SKU), main region | **0 in eastus2** (forced to centralus, d6/d7); exists centralus | F2 (=2 CU) POC / higher F-SKU prod, in the MAIN region | Microsoft.Fabric capacity / CU quota (portal: Quotas > Microsoft Fabric > <region>) | QUOTA (regional; verify per candidate region) |
| Q6 | **Azure AI Search** | Search service units / regional capacity | eastus2 **InsufficientResourcesAvailable** (forced centralus, d7) | Basic/Standard units in the MAIN region | Search / Cognitive Search capacity | QUOTA/capacity (regional; verify per region) |
| Q7 | Foundry / OpenAI chat model TPM | OpenAI.DataZoneStandard.<model> + OpenAI.GlobalStandard.<model> (K-TPM) | 0/2000 DataZone, 0/5000 Global (eastus2, AVAILABLE) | scale to prod TPM (e.g. 50-200K+) per model | Cognitive Services / OpenAI TPM | QUOTA |
| Q8 | AIServices account count | AIServices.S0.AccountCount | 0/100 | fine as-is | Cognitive Services | QUOTA (ample) |
| Q9 | **APIM Premium** | APIM capacity (no pre-checkable quota API) | Developer at POC | Premium units, multi-AZ (f5) | API Management (PUT-time; region capacity) | QUOTA/capacity (region-dependent; verify) |
| Q10 | SQL Database (corp spokes) | offer provisioning | **ProvisioningDisabled eastus2** | if needed, a region/offer that allows SQL | SQL / offer | **OFFER cap - region/offer change** |
| Q11 | App Service dedicated compute | Microsoft.Web dedicated quota | **0 / ProvisioningDisabled** | if needed, dedicated plan quota | App Service / Web | **OFFER cap - region/offer change** |
| Q12 | Public IP addresses | Standard Public IP (per region) | default | firewalls, App GW, NAT, gateways = ~10-20 | Networking | QUOTA (usually ample) |
| Q13 | DDoS Network Protection (if f1 flips) | 1 plan / region | not deployed (f1 = documented) | 1 plan if the literal claim is taken | Networking / DDoS | not quota-constrained; cost decision |
| Q14 | LAW ingestion / daily cap | LAW GB/day | small | size to AMBA + diagnostics-at-scale + prod telemetry | Monitor / LAW | QUOTA (raise daily cap if set) |
| Q15 | VPN Gateway / DNS Resolver (B-R a1/a2 restores) | gateway per region | gated off | 1 each in the main hub | Networking | not quota-constrained typically |

Production Compute totals (Q1/Q2) are the biggest ask and the item most likely to need lead time -
**file Q1/Q2 first.** The estimate assumes a real production AKS (system + user pools, autoscaling)
plus running Databricks clusters; the user should refine against the final node counts, but request
GENEROUSLY (headroom for autoscale + surge + rolling upgrades) since raises take time.

---

## 4. REGION-FIT MATRIX (pick ONE main region that meets ALL requirements -> avoid the d6/d7 split)

The build accumulated split-region deviations (Fabric + Search forced to centralus while the main
tier is eastus2 - register d6/d7). The Wednesday goal is ONE region that satisfies everything, so
those deviations disappear. Legend: Y = generally available + quota-ticketable; ? = must be
confirmed by ticket / live check per region; OFFER = gated by the subscription offer regardless of
region.

| Capability | eastus2 | centralus | eastus | westus3 | southcentralus | Note |
|---|---|---|---|---|---|---|
| Compute v4 families (AKS/Databricks) | Y (24 raised) | Y (ticket) | Y (ticket) | Y (ticket) | Y (ticket) | all default 10, ticketable |
| Compute v5 families | OFFER=0 | OFFER=0 | OFFER=0 | OFFER=0 | OFFER=0 | **offer cap everywhere - not a region differentiator** |
| Fabric CU | **0 (blocked)** | Y (had capacity) | ? | ? | ? | eastus2 confirmed 0; centralus confirmed available; others verify |
| AI Search capacity | **Insufficient** | Y (deployed there) | ? | ? | ? | eastus2 confirmed short; centralus works; others verify |
| OpenAI/Foundry models | Y (5.4-nano GA) | ? | Y (broad model avail) | ? | ? | eastus2 rich; eastus typically richest for OpenAI; verify prod model+TPM per region |
| APIM Premium | ? | ? | ? | ? | ? | capacity not pre-checkable; verify at ticket time |
| SQL / App Service | OFFER | OFFER | OFFER | OFFER | OFFER | offer caps - not region-fixable on this sub |

**Reading the matrix:** eastus2 is DISQUALIFIED as the single main region for the data/AI tier
(Fabric CU 0 + Search insufficient - the exact reason d6/d7 exist). centralus is the only region
this build has PROVEN meets Fabric + Search. eastus is the strongest candidate for the AI/OpenAI
tier and generally has deep capacity, but Fabric/Search must be ticket-confirmed there.

---

## 5. RECOMMENDATION + top-3 risks

**Recommended main region: centralus** - it is the only candidate this build has empirically proven
meets BOTH Fabric CU and AI Search (the two hardest, region-scarce capabilities), collapsing the
d6/d7 split into a single region. eastus2 is disqualified (Fabric 0 + Search insufficient). If the
user wants eastus (deepest OpenAI/AKS capacity), file Fabric CU + Search capacity tickets for eastus
FIRST and only commit if both are granted - do not assume them.

**But the region choice is SECONDARY to the offer decision.** Sequence for the user today:
1. **Decide the subscription OFFER** (production EA/MCA vs the current POC offer). This gates v5,
   SQL, App Service - none of which a region move or quota ticket fixes on the current offer.
2. **File the QUOTA tickets** for the chosen main region (start with Q1/Q2 Compute - the biggest,
   slowest; then Q5 Fabric, Q6 Search, Q7 OpenAI TPM, Q9 APIM).
3. **Confirm Fabric CU + AI Search capacity in the chosen region BEFORE committing** the main-region
   decision (these are the split-region culprits).

**Top-3 highest-risk items:**
1. **OFFER caps (v5 = 0 everywhere, SQL/App Service ProvisioningDisabled) - a region move does NOT
   fix them.** If Wednesday stays on the POC-class offer and the design needs v5/SQL/App Service,
   it fails at apply in every region. HIGHEST risk. Mitigation: production offer, OR pin the design
   to v4 families + skip SQL/App Service (the estate already runs v4 D2s_v4 for AKS per ADR-043).
2. **Fabric CU + AI Search regional scarcity** - both hit hard limits in eastus2 (0 / insufficient).
   Only centralus is proven. If the main region is anything other than centralus, these two need
   granted tickets before the region is committed, or the d6/d7 split-region deviation returns.
3. **Production Compute vCPU volume (Q1/Q2)** - going from 24 to 256-512 regional + 64-128/family is
   a large raise that can take days and may be partially refused; file it first, request headroom,
   and have the v4-family fallback ready if v5 stays offer-blocked.

---

## 6. Note - B9 CMK spec + register status

The B9 CMK implementation spec (OQ-047 = A, full data-tier CMK) and the b1-b14 restoration register
become **Wednesday's production blueprint**, not throwaway work: CMK, KV/policy hardening (b10/b11),
the OQ-046 production forks (APIM Premium, AKS user pools, Databricks PL, DDoS-documented,
multi-region-documented), and the O&M/AMBA layer all target the production estate. CMK spec
finalization is PAUSED per the pivot; resume once the region + offer are fixed (the CMK Key Vault
and per-resource identities are region-local, so they follow the main-region decision).
