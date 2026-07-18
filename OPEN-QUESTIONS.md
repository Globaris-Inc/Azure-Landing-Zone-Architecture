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

### OQ-043: The landingzones sub is vCPU-full after B2 - quota increase, new banking sub, or B5 design-only?

- **Raised:** 2026-07-18 (B2 design engagement, architect - see ADR-043, docs/b2-aks-platform-design.md)
- **Section:** Banking waves B2/B5 (bites at B5; B2 itself is NOT blocked)
- **Blocking:** Not B2. Blocks wave B5 (Databricks compute) and any future AKS user pool / scale-out.
- **Priority:** High (answer needed before B5 planning; cheap to act on now)

**Question:**
Live quota check 2026-07-18 in sub-landingzones-poc-01 (eastus2): Total Regional vCPUs limit is **10**,
every v5 VM family is capped at **0** (the ADR-031/032 offer-cap class), DSv4-class families carry 10.
B2 as designed consumes 6 of 10 (8 of 10 during node upgrades). The remainder (4 vCPUs) cannot start
even a minimal Databricks cluster (driver + 1 worker is typically 8 vCPUs), so wave B5 is dead in this
sub unless something changes. The OQ-035 resolution pre-recorded "new banking sub" as the fallback for
exactly this. What is the disposition?

**Options being considered:**
- A (recommended): file the quota increase NOW (Total Regional vCPUs 10 -> 20+ and DSv4/DASv4 family
  10 -> 20 in eastus2) - free, async, does not block B2; treat refusal as the trigger for Option B.
  This offer has refused capacity before (SQL, App Service), so refusal is a real possibility, but a
  vCPU increase on an already-nonzero family is the most commonly granted class.
- B: create the new banking subscription under the Corp MG for B5+ (the OQ-035 fallback): clean quota
  slate, cleaner cost separation; costs plumbing (sub creation, MG association, CI SP RBAC, budgets,
  CI wiring) - roughly a half-wave of work.
- C: B5 becomes design-only (Databricks documented, not deployed) - zero cost, but a second net-new
  platform slips from the POC and the banking story thins.

**Recommended default:** A now, B on refusal. Record the outcome in the B5 pre-clearance.

**RESOLVED 2026-07-18 (user):** Option A - file the quota increase NOW (Total Regional vCPUs 10 -> 20+
and DSv4/DASv4 family 10 -> 20, eastus2), az-side filing attempted immediately with portal filing as the
fallback. Option B (new banking sub under Corp MG) stays on record as the committed fallback on refusal.
Does not block B2; outcome recorded in the B5 pre-clearance. Note the ADR-044 synergy: stopping the AKS
cluster at the EOD re-gate releases its 6 vCPUs while the ticket is pending.

### OQ-042: B2 AKS egress - bring the firewalls back (userDefinedRouting) or ship cheap egress (loadBalancer / NAT gateway)?

- **Raised:** 2026-07-18 (B2 design engagement, architect - see ADR-042 re-enable trigger, ADR-043,
  docs/b2-aks-platform-design.md section 6)
- **Section:** Banking wave B2 (Kubernetes platform)
- **Blocking:** YES - blocks the B2 implementation spec hand-off (outbound_type and the route-table
  wiring differ per option)
- **Priority:** High

**Question:**
ADR-042 gated both Azure Firewalls off and recorded B2 AKS userDefinedRouting as a re-enable trigger.
The live bank-app-p1 spoke routes 0.0.0.0/0 to 10.0.0.4 (a firewall that does not exist); AKS nodes
cannot bootstrap through that blackhole, so B2 MUST either bring the firewall back or scope the
blackhole route away from snet-aks-nodes. Verified fact that shapes the options: a 0.0.0.0/0 UDR to a
VirtualAppliance overrides BOTH load-balancer egress and an attached NAT gateway, so options (b) and
(c) each require removing the route-table association from the aks-nodes subnet (the apim and
private-endpoints subnets keep the blackhole UDR). Which egress does B2 ship?

**Options being considered:**
- a: `outboundType = userDefinedRouting` + `enable_firewall = true`. Banking-grade: all node/pod egress
  inspected by Firewall Premium (IDPS/TLS). Cost ~**$2,555/mo** - the ADR-042 flag deliberately brings
  BOTH hubs' firewalls back as a pair (per-hub flags were explicitly rejected there). Extra work: AKS
  egress rule set in the firewall policy; firewall must be live BEFORE cluster create. This is the
  production target posture.
- a': single-hub variant of (a), ~**$1,280/mo**. NOT currently buildable as designed: it requires
  superseding ADR-042's one-flag-both-hubs ruling AND verifying in the module source that asymmetric
  per-hub `enabled_resources.firewall` works (UNVERIFIED; the hub mesh route generation is the risk).
  Pick only if (a)'s posture is wanted at half cost and the verification passes.
- b (recommended POC default): `outboundType = loadBalancer`, remove the route table from the aks-nodes
  subnet. ~**$0/mo** extra (AKS-managed egress PIP ~$4). Egress uninspected - documented POC deviation
  (same class as the absent DDoS plan). Clean in-place migration path to (a) when the firewalls return
  (route re-association + outbound_type change, supported without cluster rebuild).
- c: `outboundType = userAssignedNATGateway` + avm-res-network-natgateway 0.3.2 on snet-aks-nodes.
  ~**$37/mo** + $0.045/GB. Buys a deterministic egress IP and SNAT scale over (b), still zero
  inspection. Same route-table change as (b). Middle option; the POC's near-zero egress volume makes
  its benefits mostly cosmetic.

**Architect recommendation (ADR-022 POC-vs-design split, consistent with the user's ADR-042 deferral):**
Option **b** at POC; option **a** documented as the production design target; the ADR-042 firewall
re-enable trigger then moves to B4 (APIM forced tunneling) or a deliberate security-demo milestone,
whichever the user schedules first. If demonstrating inspected egress IS the point of this wave for the
portfolio story, pick (a) and accept the ~$2.55k/mo while it runs.

**RESOLVED 2026-07-18 (user):** Option **a** with a TIME-BOX - `outboundType = userDefinedRouting` and
`enable_firewall = true`, cost accepted at the HOURLY rate (~$3.5/hr for the pair, both hubs; the
ADR-042 one-flag-both-hubs design stands, no supersede), with the stated intent to stand up the entire
banking landing zone and RE-GATE (or tear down) the firewalls by end of day. The inspected-egress
posture is the point; the time-box is the cost control. Mechanics, firewall-rules delta, wave runbook,
and the two EOD disposition frames are recorded in ADR-044 and docs/b2-aks-platform-design.md section
6. The B1 spoke route wiring is untouched (no route-scoping change; the blackhole UDR simply goes live).

- **Raised:** 2026-07-12 (B0a redeploy pre-clearance, architect - see ADR-041)
- **Section:** 10a (bootstrap RBAC) / carries OQ-008 history
- **Blocking:** Not B0a (the ADR-041 temp tenant-root grant bridges it). Blocks the post-B0a cleanup
  step (when the temp grants are revoked) and, if unresolved, the eventual estate teardown (MG budget
  DELETE needs the same rights).
- **Priority:** Medium

**Question:**
The management root creates (and the teardown deletes) three consumption budgets at MG scope
(globaris / platform / landingzones), which need `Microsoft.Consumption/budgets/*` at MG scope. The
ADR-021 scoped role set never covered this - it worked only because the standing OQ-008 Owner @
globaris masked it, and that Owner died with the MG tree (and is never coming back, per ADR-041).
Where do these rights live permanently?

**Options being considered:**
- A (recommended default): add a bootstrap row - **Cost Management Contributor @ globaris MG** - to
  `bootstrap/identity.tf`, bound in the same post-B0a full bootstrap re-apply that rebinds rows 2/3/4.
  Least-privilege scope consistent with the ADR-021 matrix, survives for day-2 budget changes and the
  teardown (management destroys before management-groups, so the MG scope still exists). Small
  cloud-engineer/devsecops change + ADR-021 amendment note.
- B: keep the ADR-041 temp **Cost Management Contributor @ Tenant Root Group** standing until the final
  banking teardown, then revoke. Zero code change, but broader scope than needed and a
  must-remember-at-teardown liability.
- C: drop the MG-scope budgets from the management root (sub budgets remain). Zero RBAC need, but a
  FinOps posture regression and a silent deviation from the deployed Section 7 design.

### OQ-040: GitHub plan reality for the banking DevSecOps wave - CodeQL, secret scanning, and the production apply gate on a private Team-plan org (GHE named in requirements)

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B8)
- **Section:** Banking wave B8 (DevSecOps additions) / carries OQ-015 history
- **Blocking:** Blocks wave B8 only
- **Priority:** Medium

**Question:**
The banking requirements name GitHub Enterprise, CodeQL, Dependabot, secret scanning, and production
approvals. The org (`Globaris-Inc`) runs a Team plan on a PRIVATE repo. Dependabot is free everywhere. But:
(a) CodeQL and secret scanning on private repos need the paid code-scanning products - since Microsoft
unbundled GitHub Advanced Security (2025), Code Security and Secret Protection are purchasable standalone on
Team plans without GHE (pricing/availability for this org UNVERIFIED - verify at github.com billing before
B8); (b) OQ-015 is still open on the apply-run approval gate (environment required-reviewer PUTs returned
422 billing even on the Team plan; branch protection on main was the accepted interim). What is the B8
target state?

**Options being considered:**
- A: Buy the standalone GHAS products (Code Security + Secret Protection) on the Team plan, keep the repo
  private, and retry the environment required-reviewer wiring (it may work once billing entitlement is
  verified active - the OQ-015 422 looked like entitlement lag). Closest to the requirements at lowest cost.
- B: Flip the repo public: CodeQL, secret scanning, and environment protection rules are all free on public
  repos. Revisits the user's 2026-07-04 keep-private direction; the repo already had its secret sweep +
  history rewrite.
- C: Documented deviation: Dependabot + the free typed confirm=apply guard only; record CodeQL/secret
  scanning/GHE as production design targets. Weakest posture but zero cost.
- GHE itself: recommend recording as production-design-only in all options; no POC capability above requires
  it.

**RESOLVED 2026-07-12 (user, OQ walk):** User confirmed GHAS is ALREADY LICENSED on the org - no purchase
needed. Wave B8 therefore: enable Code Security (CodeQL) + Secret Protection on the private repo under the
existing entitlement, and RETRY the OQ-015 environment required-reviewer wiring (the 422 was an entitlement
question; GHAS presence suggests billing is live - one API call to confirm). GitHub Enterprise itself is
recorded as production-design-only. Verify at B8 pre-clearance that the entitlement covers this repo
(org-level GHAS seat/product assignment), then wire repo settings via gh api.

### OQ-039: Budget ceiling for the expanded estate + the Service Bus private-endpoint tier decision

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039)
- **Section:** Banking waves B0-B10 / FinOps
- **Blocking:** Yes - blocks wave B0 sizing and the B3 Service Bus tier
- **Priority:** High

**Question:**
The prior estate ran ~$3.6-4.8k/mo (COST.md, firewalls 55-65%). The net-new banking platforms add roughly
$0.9-1.4k/mo at POC scale - or $1.6-2.1k/mo if Service Bus Premium is chosen, because private endpoints on
Service Bus require the Premium tier ONLY (verified 2026-07-12; ~$680/mo per messaging unit approximate).
Estate total lands ~$4.5-6.2k/mo. Two decisions: (1) what monthly ceiling do we run to, and for how long a
window before the next teardown? (2) Service Bus at POC: Premium (compliant with Deny-Public-Network as-is),
Standard behind an RG-scoped policy-exemption waiver unit (ADR-028/LESSON 35 pattern, documented deviation),
or gated off entirely (default-false flag, design-only)?

**Options being considered:**
- A: Ceiling ~$5k/mo, Service Bus Standard + exemption (recommended default), fixed POC window then teardown.
- B: Ceiling ~$6.5k/mo, Service Bus Premium for a fully policy-clean posture.
- C: Trim wave 0 (subset redeploy per OQ-034) to buy headroom for the net-new platforms within ~$4.5k/mo.

**RESOLVED 2026-07-12 (user, OQ walk):** Option A - ~$5k/mo ceiling (alerts at the standard 50/75/90/100
thresholds when budgets are re-wired at B0), Service Bus STANDARD behind an RG-scoped policy-exemption
Waiver for the public-endpoint deny member (ADR-028/LESSON 35 pattern, documented deviation; Premium PE
posture recorded as the production design target). Full-scope B0 redeploy fits inside the ceiling; the
delayed-start choice in OQ-034 keeps the paid window short.

**Clarified same day (user):** the banking estate is BUILD-VERIFY-DESTROY, not a running environment -
built out wave by wave, QA-confirmed, then torn down (the ALZ POC arc). The ceiling is a guard rail for
the build window only; actual spend is the prorated window, not a monthly run rate.

### OQ-038: AI platform POC scope - which of Foundry / Document Intelligence / AI Search actually deploys

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B6)
- **Section:** Banking wave B6 (AI platform)
- **Blocking:** Blocks wave B6 only
- **Priority:** Medium

**Question:**
The requirements name virtual banking assistant, document intelligence, predictive analytics, and AI search.
The 2026-correct anchor is a Microsoft Foundry resource (renamed Azure AI Foundry; Microsoft.CognitiveServices
namespace) via avm-res-cognitiveservices-account 0.11.1, plus AI Search (avm-res-search-searchservice 0.3.0)
and a Document Intelligence account. All PE-only. Token/usage costs are small but the Search service is a
fixed ~$75/mo (Basic, UNVERIFIED exact) and each service adds PEs and build surface. What deploys at POC?

**Options being considered:**
- A: Foundry resource + one small chat-model deployment only; Search + Document Intelligence design-only.
  Cheapest credible "AI platform exists" slice.
- B: Foundry + AI Search (enables a real RAG assistant demo); Document Intelligence design-only. Recommended
  default - RAG is the portfolio-relevant pattern.
- C: All three at POC. Fullest story, most surface.

**RESOLVED 2026-07-12 (user, OQ walk):** Option B - Foundry resource + one small chat-model deployment +
AI Search, enabling the private RAG virtual-assistant demo. Document Intelligence stays design-only.

### OQ-037: Enterprise data platform anchor - Databricks + ADLS (+ optional Fabric) vs the Synapse named in the requirements

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B5)
- **Section:** Banking wave B5 (data platform)
- **Blocking:** Yes - blocks wave B5
- **Priority:** High

**Question:**
The requirements doc names Azure Synapse AND Azure Databricks. The LESSON 40-41 lifecycle audit (2026-07-12)
found: Synapse is supported with no announced EOL, but Microsoft's strategic net-new analytics platform is
Microsoft Fabric, official Synapse-to-Fabric migration tooling is shipping, targeted Synapse deprecations
have already landed (Data Explorer retired 2025-10, Synapse Link for Cosmos closed to new projects), and the
CAF cloud-scale-analytics Synapse guidance was deprecated for April 2026 deletion. Anchoring net-new 2026
work on Synapse is exactly the stale-service class this project got burned by. What anchors the data
platform?

**Options being considered:**
- A: Databricks (VNet-injected, avm-res-databricks-workspace 0.5.0) + ADLS Gen2 now; add a pausable Fabric
  F2 capacity (~$263/mo pay-go, native azurerm_fabric_capacity) for the BI/regulatory-reporting face.
  Recommended default; near-zero idle cost, current-generation, satisfies the requirements' intent.
- B: Databricks + ADLS only; Fabric design-only. Cheapest.
- C: Deploy Synapse as literally written (avm-res-synapse-workspace 0.1.0 exists) - NOT recommended; would
  need the lifecycle risk recorded as user-accepted in an ADR.

**RESOLVED 2026-07-12 (user, OQ walk):** Option A - Databricks (VNet-injected) + ADLS Gen2 now, plus a
pausable Fabric F2 capacity for the BI/regulatory-reporting face. The requirements' Synapse naming is
recorded as satisfied-by-successor (Fabric is Microsoft's strategic direction; LESSON 40-41 audit in the
design doc) - no Synapse workspace deploys.

### OQ-036: AKS topology and module choice for the Kubernetes platform

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B2)
- **Section:** Banking wave B2 (Kubernetes platform)
- **Blocking:** Blocks wave B2 only
- **Priority:** Medium

**Question:**
Kubernetes platform posture is fixed (private cluster, Azure CNI Overlay, Entra + Azure RBAC, workload
identity, userDefinedRouting via the hub firewall, ACR Premium with PE). Open: (1) module -
avm-res-containerservice-managedcluster 0.6.7 (current, composition-friendly; recommended default) vs
avm-ptn-aks-production 0.5.0 (older, opinionated pattern); (2) POC node shape - 2 or 3 nodes, which v5
family/size, Free vs Standard control-plane tier; (3) single cluster in bank-app-p1 only at POC (recommended;
the centralus DR cluster is design-only per the POC-vs-design split)?

**Options being considered:**
- A: Resource module, 2x small v5 nodes, Free tier, single region - recommended POC default.
- B: Resource module, 3 nodes across AZs, Standard tier - closer to design posture, ~$75/mo more + node cost.
- C: Pattern module (avm-ptn-aks-production) - less composition control in the spoke root.

**RESOLVED 2026-07-12 (user, OQ walk):** Option B - avm-res-containerservice-managedcluster (resource
module), 3 nodes spread across availability zones, Standard control-plane tier (SLA-backed). A deliberate
step toward the 99.99% design posture at ~$75/mo tier cost + the third node. Single region at POC; the
centralus DR cluster stays design-only per the POC-vs-design split.

### OQ-035: Subscription and MG placement for the banking spokes - existing landingzones sub (offer-cap history) vs a new subscription

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B1)
- **Section:** Banking wave B1 (network foundation)
- **Blocking:** Yes - blocks wave B1 (and everything after it)
- **Priority:** High

**Question:**
Default design places `bank-app-p1` and `bank-data-p1` under the Corp MG in the existing `landingzones`
subscription (eastus2). But that sub has a documented offer-cap history: Azure SQL ProvisioningDisabled in
eastus2 (ADR-031) and App Service dedicated compute quota 0 (ADR-032). AKS node pools and Databricks
clusters consume Microsoft.Compute vCPU quota - a different quota family from the Microsoft.Web cap that
bit App Service - but the same offer may carry low or zero Compute caps. VERIFICATION ITEM (owned by the B1
pre-clearance, do not skip): in the candidate sub/region check Total Regional vCPUs, the target VM family
quota (v5 general purpose), and any per-service provisioning restrictions (AKS, Databricks, Cognitive
Services, Search) BEFORE committing placement. Where do the banking spokes land?

**Options being considered:**
- A: Existing landingzones sub, pending the quota verification passing - zero new plumbing (recommended if
  quota checks out).
- B: One new banking subscription under Corp MG - clean quota slate and cleaner cost separation; needs sub
  creation, MG association, RBAC for the CI SP, budget wiring.
- C: Two new subs (app + data) - most enterprise-faithful, most plumbing; overkill at POC.

**RESOLVED 2026-07-12 (user, OQ walk):** Option A - banking spokes land in the existing `landingzones`
subscription under the Corp MG, CONDITIONAL on the mandatory B1 pre-clearance quota verification (Total
Regional vCPUs, v5 family quota, per-service provisioning restrictions for AKS/Databricks/Cognitive
Services/Search in eastus2). Fallback if quota fails: Option B (one new banking sub). The quota check is a
hard gate, not a formality - this sub's offer already zeroed Microsoft.Web and SQL (ADR-031/032).

### OQ-034: Wave B0 redeploy - timing and scope (full estate vs banking-needed subset)

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B0)
- **Section:** Banking wave B0 (redeploy)
- **Blocking:** Yes - blocks the whole banking build
- **Priority:** High

**Question:**
The estate was torn down clean 2026-07-11 (state backend + OIDC kept). The banking build needs the platform
back. When do we redeploy, and how much? Full estate = the proven one-run path (~$3.6-4.8k/mo resumes) and
every banking dependency present. A subset (e.g. defer corp-a1/corp-a2 spokes, keep the online-p1 App
Gateway off until needed) trims cost but deviates from the proven deploy path and the DR story. Known
redeploy caveats regardless of scope (from the teardown session entry): state-SA firewall window handling,
`recover_soft_deleted_key_vaults` for the security KV (within its 90-day soft-delete window), Microsoft.AAD
RP re-registration timing for Entra DS, and a pre-clearance REFRESH for every root (policy/lifecycle may
have drifted since 2026-07-11; LESSON 41 re-audit applies if redeploy slips 2+ weeks past this design).

**Options being considered:**
- A: Full-estate redeploy, soon, exactly as torn down - proven path, full dependency set (recommended
  default).
- B: Platform-only first (management-groups, connectivity, management, identity, security), spokes deferred
  to their banking waves - saves the 3 POC spokes' cost; corp-a2 DR story goes dormant.
- C: Delay redeploy until OQ-035/036/037 are resolved so wave B1 can follow immediately and the paid window
  is shortest.

**RESOLVED 2026-07-12 (user, OQ walk):** Option C - redeploy waits for OQ-035/036/037 (all resolved the
same session), then B0 fires immediately before wave B1 so the paid window is shortest. Scope: FULL estate
(the proven one-run path) - confirmed affordable under the OQ-039 ~$5k/mo ceiling. B0 still requires the
pre-clearance REFRESH (state-SA firewall window, recover_soft_deleted_key_vaults for the security KV,
Microsoft.AAD RP re-registration timing; LESSON 41 re-audit if the start slips 2+ weeks past 2026-07-12).

**Clarified same day (user):** whole-estate lifecycle is BUILD-VERIFY-DESTROY - once all waves are built
and QA-confirmed, the estate is torn down (wave B10 ends in teardown, as the ALZ POC did). Nothing is
designed to persist; teardown.yml must stay current with every new banking root as waves add them.

**Amended same day (user): SPLIT B0 - cheap now, expensive late.** B0a deploys the firewall-independent
foundation roots now (management-groups, management, security - small idle cost). The expensive chain
(connectivity with its 2 Firewall Premiums + VPN GW, then identity, then the 3 spokes with the App
Gateway; none of these are flag-gated, all unconditional in their roots) is B0b, deferred until the first
compute wave (B2) is reviewer-approved and ready to apply, so firewall hours burn only during the active
build-verify window (~$86-120/day deferred). Deviation from the proven single-run order accepted; relative
root order preserved. Banking waves authored during the gap get static review + validate only - live plans
that data-source estate resources wait for B0b.

### OQ-033: Scope for the future Day-2 Operations and Monitoring capability (the repositioned Section 13) - platform-anchored, DINE-propagated, AMBA-based

- **Raised:** 2026-07-10 (Section 13 reposition, architect - see ADR-036)
- **Section:** 13 (repositioned) / Manage (CAF Day-2 Operations)
- **Blocking:** No - this is forward design guidance for a future build, not a current-window task. The estate
  is complete and QA-passed; teardown is imminent.
- **Priority:** Low (build later)

**Question:**
ADR-036 repositions Section 13 from a synthetic load / security-signal demo device to a Day-2 Operations and
Monitoring capability for CAF landing zones (the CAF "Manage" methodology). It is NOT a new standalone
layer/spoke. What is the bounded scope, and where does it land?

**Target shape (forward design guidance, NOT a build now):**
- **Platform-anchored:** extend the existing `platform/management` landing zone (already hosts the platform
  LAW and action group) with the monitoring baseline. Operational monitoring is a platform capability in
  canonical ALZ, not a workload tier - so no new root or spoke.
- **Policy-propagated:** deliver per-landing-zone monitoring via DeployIfNotExists (DINE) policy so every
  current and future spoke inherits it automatically (guardrail model), not hand-placed per spoke.
- **AMBA-based:** anchor to Azure Monitor Baseline Alerts (AMBA) for Azure Landing Zones - Microsoft's named,
  endorsed policy-driven alert library for ALZ (platform-level + resource-health alerts) - plus Service Health
  and Resource Health alerts wired to the existing platform action group. AMBA bounds the build and keeps it
  credible rather than a bespoke reinvention.
- **Scope discipline:** the bounded high-value slice is the AMBA baseline + Service/Resource Health alerts +
  action-group routing. Dashboards-for-everything is explicitly OUT of the bounded scope.
- **Optional recycling** within this model: the cost-pattern signals could feed a FinOps / cost-anomaly
  monitoring view; the app-traffic idea becomes real synthetic-transaction availability probes (Application
  Insights availability tests or the Azure Monitor equivalent) rather than red-team load.

**Open sub-decisions for build time (not now):**
- Which AMBA delivery form - the AMBA-for-ALZ policy initiatives/pattern assigned at the appropriate MG
  scopes, versus a lighter subset - given the estate size.
- The exact MG scope(s) for the DINE assignments (platform vs landingzones vs per-archetype) so alert
  coverage matches each spoke's resource types without over-alerting.
- The synthetic `.tf` stays a reusable idea source only; it is NOT repurposed as a monitoring spoke - the
  capability lands in `platform/management` + policy.

**RESOLVED 2026-07-11 (ADR-037):** The scope and placement are anchored. The O&M target architecture is
accepted (build deferred) in **ADR-037**, with the authoritative design in
`docs/operations-monitoring-design.md`: platform-anchored (extend `platform/management`), policy-propagated via
DeployIfNotExists at MG scope through `avm-ptn-alz`, AMBA-based, with an MVP-bounded Phase-1 slice
(diagnostic-settings-at-scale + AMBA baseline + Service/Resource Health + action-group extension + Sev0-4
taxonomy). It is NOT a new standalone layer/spoke, and the synthetic root is not the vehicle. The two
build-time sub-decisions above (AMBA delivery form; exact DINE MG scopes) are retained as deferred
implementation detail for the eventual Phase-1 build, not open blockers.

### OQ-032: Estate-wide perpetual tag drift - tag-governance Modify policy injects CreatedDate="1970-01-01" that Terraform strips every plan

- **Raised:** 2026-07-10 (Section 6 deploy QA)
- **Section:** 7 (FinOps tagging) / affects all roots
- **Blocking:** No (cosmetic; applies succeed)
- **Priority:** Low

**Question:**
Every root shows a perpetual, non-converging in-place diff: the `tag-governance-globaris` Modify policy (`platform/management/main.tf:52`) injects `CreatedDate = "1970-01-01"` (static placeholder - the Modify effect cannot compute a dynamic date) plus tag-inheritance to child resources; Terraform config does not declare `CreatedDate`, so every plan wants to strip it and the policy re-adds it. Confirmed on `platform/security` post-deploy (9 resources, plan run 29137108266: `0 to add, 9 to change, 0 to destroy`, all `- "CreatedDate" = "1970-01-01" -> null`). It is estate-wide, cosmetic, zero functional/posture impact, and by design of the tag policy.

**Options being considered:**
- A: Accept as known benign drift (POC, teardown imminent) - CHOSEN.
- B (post-POC): add `CreatedDate` to each root's declared tags so config == state, OR `ignore_changes = [tags["CreatedDate"]]` on affected resources/modules, OR make the Modify policy stop setting a placeholder date. All are estate-wide touches, not worth doing pre-teardown.

**RESOLVED 2026-07-10:** User accepted the drift ("I don't see them being a major issue, let's just accept the drift"). No code change; documented as a known cosmetic non-convergence. Deferred fix (option B) is a post-POC cleanup item.

### OQ-031: Synthetic telemetry lands in the platform LAW, but Sentinel is onboarded on the security LAW - will Section 6 analytics rules ever see the synthetic signals?

- **Raised:** 2026-07-10 (synthetic first-apply pre-clearance, architect)
- **Section:** 13 (Synthetic Workload) / 6 (Sentinel)
- **Blocking:** No - does not block the synthetic apply. Blocks the demo story "synthetic signal produces a
  Sentinel incident."
- **Priority:** Medium

**Question:**
`synthetic` sends all its diagnostic settings and Container Apps console logs to
`var.platform_law_workspace_id` = the **platform LAW** (`law-platform-...`, management sub, from
`platform/management`). But Microsoft Sentinel is onboarded on the **security LAW** (security sub, from
`platform/security`); the Section 6 analytics rules run against that workspace. Unless those rules
cross-workspace query the platform LAW, the synthetic StorageBlobLogs / KV AuditEvent / SignInLogs /
ContainerAppConsoleLogs will never trigger a Sentinel incident, so the red-team simulation produces no
detections in the demo.

**Options being considered:**
- A: Verify whether the Section 6 analytics rules already reference the platform LAW cross-workspace (some
  may). If they do, no change. If not, either
- B: point synthetic's diagnostic settings + Container Apps at the **security LAW** instead of the platform
  LAW (change the `platform_law_workspace_id` value fed to synthetic to the security LAW id, or add a
  dedicated `sentinel_law_id` variable), so the signals land where Sentinel reads; or
- C: add cross-workspace analytics rules on the security LAW that query the platform LAW (needs cross-sub
  Sentinel RBAC, the same class as OQ-027). Lowest-effort for the demo is B if the platform LAW is not
  already a Sentinel source.

### OQ-030: corp-a1 App Service (hard-referenced by synthetic) is gated off - re-enable, retarget, or gate the corp-a1 workload pieces?

- **Raised:** 2026-07-10 (synthetic first-apply pre-clearance, architect)
- **Section:** 13 (Synthetic Workload) / 9 (Landing Zones)
- **Blocking:** Yes - `data.azurerm_linux_web_app.corp_a1` (unconditional) fails at plan with a 404 because
  the App Service does not exist, killing the corp-a1 REST-API deploy and the k6 target.
- **Priority:** High

**Question:**
The corp-a1 (and corp-a2) App Service tier was gated off at deploy time (`enable_app_service = false`,
ADR-031/ADR-032; the landingzones-sub dedicated-compute offer-cap, quota support ticket still open).
`synthetic` hard-references `app-corp-a1-globaris-poc` via an unconditional data source in `corp_a1.tf` and
`k6.tf`, so it cannot plan. There is no flag to skip only the corp-a1 App-Service dependency.

**Options being considered:**
- A: Re-enable `enable_app_service = true` on corp-a1 - only viable if the dedicated App Service compute quota
  is now available in the LZ sub (it was not at deploy time). Highest fidelity to PROMPT.md 13.1/13.2, but may
  itself fail on quota and is the slowest path before an end-of-week teardown.
- B (recommended given teardown): retarget the 13.1 REST-API stub + the 13.2 k6 load at the LIVE online-p1
  workload (the App Gateway WAF_v2 public endpoint / the Static Web App, both deployed green) instead of the
  absent corp-a1 App Service. Cloud-engineer change to the data source + `TARGET_BASE_URL` + the deploy step.
- C: Add a flag (e.g. `enable_corp_a1_workload`) that gates the corp-a1 App-Service data source + REST-API
  deploy + k6 off, so the red-team + cost-pattern layers still ship without a live HTTP target. Loses the
  load-generation demo but unblocks everything else.

### OQ-029: Synthetic public-network storage accounts + decoy Key Vault collide with the corp-MG Deny-Public-Endpoints - Waiver or make private?

- **Raised:** 2026-07-10 (synthetic first-apply pre-clearance, architect)
- **Section:** 13 (Synthetic Workload) / 2 (policy)
- **Blocking:** Yes - `StorageDenyPaasPublicIP` (Deny, enforced at the corp MG) denies the three public
  synthetic storage accounts; the Key Vault member likely denies the decoy KV.
- **Priority:** High

**Question:**
The synthetic RGs land in the LZ sub under the `corp` MG, inheriting the same `Deny-Public-Endpoints`
initiative that blocked the spoke flow-log SAs (OQ-024). `synthetic` sets `public_network_access_enabled =
true` on `online_p1_synthetic`, `red_team_decoy`, `cost_pattern_hot`, and `corp_a1_synthetic` (needed for the
App-Service SAS fetch, the SWA-Function queue write, the MI blob read over its outbound IP, and the Container
Apps file-share mount), and on the decoy Key Vault (RBAC mode, `default_action = Allow`). The OQ-024 Waivers
are RG-scoped to `rg-<spoke>-network-*` and do NOT cover the `rg-synthetic-*` RGs.

**Options being considered:**
- A (recommended): RG-scoped `azurerm_resource_group_policy_exemption` Waivers on each synthetic RG that holds
  a public SA (and `rg-synthetic-red-team-*` for the KV member, if verification confirms it is Deny), scoped
  to only the offending initiative member - the ADR-028 / OQ-024 pattern, IaC-managed in the synthetic root
  (devsecops lane). Narrowest blast radius, keeps SQL/other members enforced.
- B: Disable public network access on the synthetic SAs + decoy KV. Rejected as a default - breaks the
  App-Service SAS deploy, the SWA-Function queue write, the storage-anomaly MI read path, the Container Apps
  file-share mount, and the whole point of the "public decoy" red-team resources.
- C: Downgrade the corp-assignment Storage/KeyVault member effect to Audit. Rejected - weakens governance for
  the entire corp archetype to admit POC resources.

### OQ-028: Migrate the deprecated KeyVaults + Arm Defender plans off the plan-enablement API (or keep until Microsoft enforces retirement)?

- **Raised:** 2026-07-10 (platform/security run-2 deprecation audit, architect)
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Blocking:** No - both plans are live-Standard and in Terraform state; the July 5 2026 block applies to new
  enablement only, so they do not block the next apply. Held as-is per ADR-034.
- **Priority:** Medium

**Question:**
The Defender for Cloud release notes (July 5, 2026) list five pricing plans blocked for new enablement:
KubernetesService, ContainerRegistry, KeyVaults, Dns, Arm. This root uses `KeyVaults` and `Arm` in
`defender_basic_plans` (main.tf). Both are already enabled (live-Standard, in state), so they keep working, but
they are on deprecated plans and any future re-PUT would be blocked. What is the migration path?

**Options being considered:**
- A (recommended): Hold as-is until teardown. The environment is scheduled for teardown by end of week, so the
  latent re-PUT risk is very likely moot. Code comments mark both plans deprecated; the pre-clearance plan-scan
  guard catches any drift (import, never re-create). Revisit only for a persistent environment.
- B: Remove KeyVaults and Arm from IaC and let Terraform set them to Free - clean config, but this DISABLES
  Defender for Key Vault and Resource Manager protection (a security-posture downgrade) and the "fixed pricing
  model" successor may leave them protected differently. Only sensible if the posture change is intended.
- C: Keep them enabled but move management out of `azurerm_security_center_subscription_pricing` to whatever the
  "fixed pricing model" successor path is once Microsoft documents the IaC-supported form - deferred until that
  path exists.

**RESOLVED 2026-07-12 (overtaken by events - ADR-040):** the 2026-07-11 full teardown reset every plan in the
security sub to Free, which destroyed Option A's premise (live-Standard + in state). Any redeploy re-PUT of
KeyVaults/Arm at Standard is now NEW enablement of blocked plans = deterministic 400. B0a pre-clearance
(docs/preclearance/b0a-redeploy.md, PC-1) removed both from `defender_basic_plans`; Defender CSPM
(CloudPosture) carries the posture surface. Effectively Option B, forced by the teardown rather than chosen;
the posture delta is recorded in ADR-040.

### OQ-027: Re-enable path for the firewall_threat_intel_hit cross-workspace analytics rule (fully-qualified reference + Sentinel cross-workspace RBAC)?

- **Raised:** 2026-07-10 (platform/security run-2, architect)
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Blocking:** No - the rule is pre-staged off behind `enable_firewall_ti_rule = false` (ADR-034); the other
  10 scheduled rules and the MDC incident rule stand.
- **Priority:** Low

**Question:**
firewall_threat_intel_hit is the only cross-workspace analytics rule: it reads hub Azure Firewall diagnostics
from the platform LAW (management subscription) while the rule is created against the security workspace
(security subscription). Its name-only `workspace('law-platform-<org>-<env>')` reference does not resolve
cross-subscription at rule-create time, so it failed twice and is now gated off. What does re-enabling it
require in a persistent environment?

**Options being considered:**
- A (recommended for a persistent env): Thread the platform LAW ARM resource ID into `platform/security` as a
  new input and rewrite the KQL to the fully-qualified `workspace('<platform-LAW-resource-id>')` form, AND
  grant the security Sentinel workspace's query identity Log Analytics Reader on the platform LAW so the rule
  resolves at create time and actually returns data at runtime. Then flip `enable_firewall_ti_rule = true`.
- B: Ingest the hub firewall diagnostics directly into the security workspace and make the rule
  single-workspace - rejected in design for the POC (duplicate ingestion cost) but simplest operationally.
- C: Leave gated off - acceptable for the POC; the firewall threat-intel signal is still visible in the
  platform workspace and Defender for Cloud.

### OQ-026: Corp-spoke workload tier (App Service + SQL) is fully offer-capped off - for a persistent environment, request quota / relocate, or redesign to serverless?

- **Raised:** 2026-07-10 (landing-zones deploy, architect)
- **Section:** 9 (Landing Zone Spokes)
- **Blocking:** No - both tiers are pre-staged off behind default-false flags (`enable_app_service`, ADR-032;
  `enable_sql`, ADR-031). The corp spokes stand as network landing zones without them.
- **Priority:** Low

**Question:**
The `landingzones` subscription is compute-restricted for dedicated / reserved resources: dedicated App
Service (`Microsoft.Web` VM quota = 0, offer cap, ADR-032) and Azure SQL (`ProvisioningDisabled`, ADR-031) are
both offer-capped, while serverless and PaaS-shared compute works. That gates the entire corp workload tier
(App Service + SQL) off. For a persistent (non-teardown) environment, which path do we take?

**Options being considered:**
- A (recommended): Defer. The environment is scheduled for teardown by end of week, so the workload tier is
  very likely moot. Revisit only if a persistent environment is stood up. The gates are default-false and
  cross-referenced from ADR-031 and ADR-032 so they are not forgotten.
- B: Request quota / move the landing zones to an unrestricted subscription, then flip `enable_app_service` and
  `enable_sql` to `true` - keeps the current dedicated-SKU design; cost is the quota-request latency (often
  slow or denied on restricted offer types) or a subscription migration.
- C: Redesign the workload tier to serverless (Flex Consumption Functions plus serverless SQL alternatives)
  that fits the offer - a real application redesign, only worth it for a durable environment.

Consolidates the workload-tier re-enable story. OQ-025 remains the SQL-specific re-enable trigger (allowed
region vs support exception, relocate vs wait); this OQ frames the broader App-Service-plus-SQL decision for a
persistent environment.

### OQ-025: Re-enable trigger for the corp-spoke SQL tier - which allowed region or support exception, and relocate vs wait?

- **Raised:** 2026-07-10 (landing-zones deploy, architect)
- **Section:** 9 (Landing Zone Spokes)
- **Blocking:** No - the SQL tier is pre-staged off behind `enable_sql = false` (ADR-031); the rest of the
  corp spoke stands without it.
- **Priority:** Low

**Question:**
ADR-031 gated the corp SQL tier off because Azure SQL provisioning is `ProvisioningDisabled` for the
`landingzones` subscription in eastus2 (corp-a1) and expected the same in centralus (corp-a2). When, if ever,
do we re-enable it, and how? The two levers are: an **allowed region/subscription** where SQL provisioning is
permitted, or an **Azure support-request exception** to lift the restriction on the current region. And if we
do re-enable, do we **relocate** SQL to an allowed region (accepting cross-region split from the rest of the
spoke) or **wait** for the restriction to lift in place?

**Options being considered:**
- A (recommended): Keep the tier off for this POC's lifetime. The environment is scheduled for teardown by
  end of week, so the SQL tier is very likely moot. Revisit only if a persistent (non-teardown) environment
  is stood up.
- B: Relocate SQL to an allowed region and flip `enable_sql = true` - accept cross-region fragmentation from
  the rest of the spoke. Only worth it for a durable environment.
- C: Raise a support-request exception and wait for it to lift in the current region, then flip
  `enable_sql = true` in place - slow; not aligned with the teardown timeline.

Tracked so the gate is not forgotten. Also carries the one-line .tf follow-up from ADR-031: the
`SqlServerDenyPaasPublicIP` comments in `landing-zones/corp-a1/policy_exemptions.tf:38-39` and
`corp-a2/policy_exemptions.tf:28` are stale while `enable_sql = false` (no SQL server exists) and should be
refreshed on the next edit of those files.

### OQ-024: corp-MG `Deny-Public-Endpoints` (+ `Deny-Subnet-Without-Nsg`) collide with the spoke public-PaaS resources - exempt, redesign, or downgrade?

- **Raised:** 2026-07-10 (landing-zones deploy pre-clearance, architect)
- **Section:** 9 (Landing Zone Spokes) / 2 (policy)
- **Blocking:** Yes - blocks the flow-log storage account create on all three spokes, and the App Service
  create on corp-a1/corp-a2, and the `snet-integration` subnet on corp-a1/corp-a2.
- **Priority:** High

**Question:**
The `landingzones` subscription sits under the **`corp`** MG (the `online` MG is empty), so all three spokes
inherit the corp archetype `Deny-Public-Endpoints` (Deny-PublicPaaSEndpoints) initiative, which is **enforced
with default effect = Deny**. Live-verified members that fire:
`StorageDenyPaasPublicIP` denies the flow-log storage accounts (public network access Enabled, all 3 spokes)
and `AsDenyPublicIP` denies the App Services (public inbound not disabled, corp-a1/a2). Separately,
`Deny-Subnet-Without-Nsg` (landingzones MG, Deny) denies corp `snet-integration` (no NSG). How do we admit
the required POC resources without gutting the corp archetype governance?

**Options being considered:**
- **A (recommended): RG-scoped Waiver policy exemptions + attach the NSG.** Per the ADR-028 precedent, add
  `azurerm_resource_group_policy_exemption` (Waiver) in each spoke root scoped to the specific RG for the
  specific member ref: `rg-<spoke>-network-*` for `StorageDenyPaasPublicIP`, `rg-<spoke>-workload-*` for
  `AsDenyPublicIP`. Keeps `SqlServerDenyPaasPublicIP` fully enforced (spoke SQL is already private). For the
  subnet, attach the existing spoke NSG to `snet-integration` in code (App Service delegated subnets support
  NSGs) - no exemption needed. Narrowest blast radius, auditable, IaC-managed.
- **B: Disable public network access on the flow-log SAs and App Services.** Rejected as default - can break
  NSG flow-log delivery (Network Watcher service reachability) and changes the App Service reachability model
  without validation.
- **C: Downgrade the initiative Storage/AppService effect params to `Audit`/`Disabled` at the corp
  assignment (platform/management-groups).** Rejected - weakens governance for the whole corp archetype to
  admit three POC resources.

Also parks a topology observation: an "online" archetype workload (`online-p1`) deploying under the `corp` MG
is a placement mismatch (the `online` MG has no subscription). Non-blocking; note for a later hierarchy
decision.

**RESOLVED 2026-07-10 (user decision: compliance-first, exemption fallback; committed 2581bd4):**
Split by whether the resource could be made genuinely compliant without breaking function:
- **`snet-integration` (corp-a1/a2) - made COMPLIANT.** Attached the existing spoke NSG to the subnet
  (App Service delegated subnets support NSGs), so `Deny-Subnet-Without-Nsg` is satisfied in code. No
  exemption used.
- **Flow-log storage accounts (all 3 spokes) and corp App Services (corp-a1/a2) - Waiver fallback.**
  These could not be made compliant without breaking function: Network Watcher is **not** a storage
  trusted-service, so a private flow-log SA breaks NSG flow-log delivery; and a private App Service
  needs net-new private-endpoint infrastructure. Fell back to RG-scoped `azurerm_resource_group_policy_exemption`
  Waivers (the ADR-028 pattern), each scoped to **only the single offending initiative member** -
  `StorageDenyPaasPublicIP` for the flow-log SAs, `AsDenyPublicIP` for the App Services.
  `SqlServerDenyPaasPublicIP` stays **enforced** and the spoke SQL server is independently private.

**Standing follow-up (RESOLVED-with-follow-up, do not delete):** the durable corp posture for the App
Service is a genuinely private App Service (`public_network_access = false` + a
`privatelink.azurewebsites.net` private endpoint), which would retire the `AsDenyPublicIP` Waiver.
Decision pending: build the private App Service infra or keep the Waiver. Likely moot given the planned
POC teardown by end of week.

### OQ-023: Root-cause the geo_block Conditional Access 1040 named-location reference failure (bounded diagnosis, then re-enable)

- **Raised:** 2026-07-10 (identity recovery apply run 29068343843, architect, ADR-030)
- **Section:** 5 (azuread Conditional Access) / 8 (Identity)
- **Blocking:** No - ADR-030 gates geo_block off by default (`enable_geo_block_ca_policy = false`); the
  identity root applies green with 7 of 8 report-only CA policies. geo_block enforces nothing, so nothing is
  blocked operationally.
- **Priority:** Medium

**Question:**
`azuread_conditional_access_policy.geo_block` has failed Graph `400 / 1040 "NamedLocation ... does not exist"`
roughly 5 times, most recently ~1 minute into run 29068343843 with a valid OIDC token (so NOT the ADR-029
token-expiry cause). The approved_countries named location exists and resolves on a live Graph GET (created
2026-07-08), yet the CA-policy create endpoint says it does not exist. What is the actual cause, and what is
the correct fix to re-enable geo_block?

**Options being considered:**
- A: **Reference-format bug** - the policy passes the named location by full resource path
  (`/identity/conditionalAccess/namedLocations/<id>`) where the CA store expects the bare object id (or vice
  versa). Test by inspecting the exact request body azuread emits and comparing to the Graph
  conditionalAccessPolicies schema. Likeliest and cheapest to confirm.
- B: **Graph CA-store consistency issue** distinct from ordinary propagation - the location is visible via the
  namedLocations endpoint but not yet consistent in the CA-policy store's view. Test by creating the same
  policy via raw Graph / portal and observing whether it also 1040s.
- C: **Data-quality defect on the named location** - its displayName returned with a replacement character
  (where an em dash was likely intended). Long shot; re-create the location with a clean ASCII displayName and
  retry.

**Recommendation:** Run a single **bounded** diagnosis pass in order A -> C -> B (cheapest / likeliest first),
NOT another blind apply retry. Once the cause is confirmed and the fix is known, flip
`enable_geo_block_ca_policy = true` and verify geo_block creates on one apply. Do not spend more than one
focused pass here - geo_block is 1 of 8 report-only policies and nothing depends on it.

**RESOLVED 2026-07-10 (Option A confirmed and PROVEN live):**
Root cause was the **reference-format bug (Option A)**: the policy passed the named location by its
`.id` (the full resource path `/identity/conditionalAccess/namedLocations/<id>`) where the CA store
expects the bare `.object_id` (the GUID only). Switching the reference to `.object_id` and re-enabling
(`enable_geo_block_ca_policy = true`) fixed it. Evidence: deploy run **29111153212** created the
geo_block policy (`id 6b96eb0d-...`) with **no 1040**, and QA verified it live in Graph - report-only,
`excludeLocations` set to the bare GUID which resolves to the real `approved_countries` named location.
Notes: the tag-churn management fix (built-ins made **add-if-missing** rather than overwrite) is applied
in Azure; QA observed a **mojibake in the `platform/management` tag-governance `display_name`** (a
replacement character where a clean glyph was intended) - minor cosmetic follow-up, non-blocking.

### OQ-022: Durable greenfield fix for OIDC token expiry on the identity root's long (1-3h) AADDS create - split the root, or add CI job-level re-auth?

- **Raised:** 2026-07-10 (identity apply run 29055619749 recovery, architect, ADR-029 Part C)
- **Section:** 8 (Identity) / 5 (azuread Conditional Access) / 10 (Pipeline & Tooling, OIDC auth)
- **Blocking:** No - ADR-029's config-driven import closes the token-expiry exposure for the CURRENT POC
  (the domain is built once, then only refreshed, so every future apply is short). This item is the durable
  fix for a from-scratch greenfield rebuild only.
- **Priority:** Medium

**Question:**
The `platform/identity` root co-locates a 1-3h `azurerm_active_directory_domain_service` create (create-only
wait for both DCs) with azuread Graph / Conditional-Access operations in ONE CI apply. In run 29055619749
the trailing azuread ops failed `AADSTS700024: Client assertion is not within its valid time range` - the
GitHub OIDC federated assertion (~5 min) and its derived access tokens (~1h) do not survive a 3h apply.
Empirically the azurerm/ARM operations survived (the domain was built), so the exposure is specifically the
azuread provider's tail-end Graph calls after a cold AADDS create. ADR-029's import makes THIS deployment's
future applies short (import has no create-wait), so the token never expires again for the POC lifetime. But
a full teardown + greenfield redeploy (the DEPLOYMENT.md path) would again run the 3h create BEFORE the CA
policies and re-hit AADSTS700024. What is the durable fix?

**Options being considered:**
- A: **Split the identity root** into Phase 1 (network + NSG + AADDS managed domain) and Phase 2 (azuread
  named location + Conditional Access policies), each a separate CI apply so neither apply contains both a
  multi-hour create AND trailing Graph ops. Cleanest separation of ARM vs Graph lifecycles; cost is a
  non-trivial refactor (new root, state migration, cross-root data passing for the domain/subnet, provider
  wiring, an extra pipeline stage).
- B: **CI job-level re-auth / token refresh** before the azuread operations (e.g. re-run the OIDC
  azure/login step, or fetch a fresh GitHub id-token, immediately before the Graph-touching apply phase).
  Smaller change, but the identity root is a single apply so a mid-apply re-auth is awkward; likely pairs
  with some ordering guarantee that Graph ops run last. Keeps platform/identity CI-only.
- C: **Accept as a documented POC deviation** - import covers the POC; the greenfield-rebuild token-expiry
  is a known limitation noted in DEPLOYMENT.md, revisited only if a clean-room redeploy is required.

**Recommendation:** For now, ADR-029 import (no code change here) plus **C** as the interim posture; adopt
**A** if/when a validated greenfield rebuild becomes a requirement. Do NOT build A speculatively during the
recovery - the priority is getting the identity layer green. Keep `platform/identity` CI-only either way.

### OQ-021: ALZ diagnostic-settings DINE (`Deploy-Diag-LogsCat`) fails - its central Log Analytics workspace parameter is unwired (resolves to the zero-GUID subscription)

- **Raised:** 2026-07-09 (identity apply run 29055619749 remediation failure, architect)
- **Section:** 2 - Management Group Hierarchy (MG policy) / cross-cutting observability
- **Blocking:** No - does not block any apply. It is a policy auto-remediation (DINE); the Entra DS
  managed domain reached Running and the platform/identity Terraform apply are both unaffected.
- **Priority:** Medium

**Question:**
The ALZ `Deploy-Diag-LogsCat` DeployIfNotExists policy (assigned at the globaris/platform MG scope by
`platform/management-groups` via avm-ptn-alz) is failing every auto-remediation. When the new Entra DS
managed domain appeared, the policy tried to deploy a diagnostic setting routing the domain's logs to a
central Log Analytics workspace and the deployment failed. Verified evidence (az deployment operation
detail, 2026-07-09) on the `PolicyDeployment_...` deployment in the identity subscription's AADDS resource
group (`rg-identity-aadds-globaris-poc`):
- **code:** `LinkedAuthorizationFailed`
- **target:** `microsoft.aad/domainservices/providers/diagnosticSettings`
- **message:** the client had permission to write the diagnostic setting `setByPolicy-LogAnalytics` on the
  domain, "however the linked subscription '00000000-0000-0000-0000-000000000000' was not found."

This is NOT scoped to AADDS. Because the failure is at the policy-ASSIGNMENT parameter level (an empty
workspace resource ID that resolves to the all-zeros subscription), this DINE fails IDENTICALLY for every
resource it targets tenant-wide, not just the managed domain. How do we wire the real central workspace?

**Root cause:**
The avm-ptn-alz policy assignment for diagnostic-settings-to-LAW was deployed WITHOUT its `logAnalytics`
(workspace resource ID) parameter set to the real platform LAW. The deployed diagnostic setting's workspace
resource ID therefore resolves to the zero-GUID subscription `00000000-...`, which does not exist - hence
`LinkedAuthorizationFailed`. The platform LAW itself exists (its workspace/customer IDs were captured as
repo Secrets after the management apply); it is the POLICY ASSIGNMENT parameter in
`platform/management-groups` that was never wired to that workspace's resource ID.

**Correction of an earlier disposition:** prior docs (docs/preclearance/platform-identity.md and ADR-028
follow-up 3) claimed this DINE was "noise" that would "self-heal on the next compliance cycle once the
domain is Running." That is WRONG. It is a structural unwired-parameter defect, not a transient follow-on of
the earlier failed domain create. It will keep failing until the assignment's workspace parameter is
populated with the real platform LAW resource ID; `az policy remediation create` would also re-fail. It
needs a real fix, not a wait.

**Options being considered:**
- A (recommended): Wire the platform LAW resource ID into the ALZ diagnostic-settings policy assignment's
  parameter via avm-ptn-alz `policy_default_values` / the alz library assignment parameters in
  `platform/management-groups`, then re-apply that root and run `az policy remediation create` to clear the
  remediation backlog. Restores central diagnostics with the governance signal intact.
- B: Disable or adjust the `Deploy-Diag-LogsCat` assignment if central diagnostics are out of POC scope.
  Weaker - loses the governance/observability signal that logs are being routed centrally.

**Lane:** this is a `platform/management-groups` change (DevSecOps/policy to shape the assignment
parameter, cloud-engineer to wire the module input). It is SEPARATE from and does not block the identity
re-apply - track and fix it on its own.

**Consequence of leaving it:** the managed domain's and other targeted resources' diagnostic logs do not
ship to the central platform LAW until the parameter is wired. This is an observability gap, not a
security or availability one.

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

**UPDATE 2026-07-09 (architect) - scope-down is INCOMPLETE, standing Owner never removed. STILL OPEN.**
A live RBAC enumeration (`az role assignment list`, assignee = the CI SP, run 2026-07-09) surfaced the
real state versus the ADR-021 design. The verified live assignment set the CI SP holds SIMULTANEOUSLY:
- Owner @ managementGroups/globaris (org root MG)
- Owner @ managementGroups/connectivity
- Owner @ managementGroups/platform
- Resource Policy Contributor @ managementGroups/globaris
- User Access Administrator @ managementGroups/globaris
- Management Group Contributor @ Tenant Root Group
- Contributor @ one landing-zone subscription + User Access Administrator @ that same subscription
  (only one sub's direct grants were visible to the querying user; Owner @ globaris inherits Owner to all
  subs under the hierarchy regardless).

What this means: the ADR-021 scoped roles were **added ALONGSIDE**, not in **replacement of**, three
standing **Owner** grants (globaris + connectivity + platform MGs) that were never removed. The intended
substitution (drop broad Owner, stand up the scoped set) did NOT happen - the two sets coexist.
**Owner @ globaris (org root MG) is nearly as broad as the Owner @ Tenant Root this item set out to
eliminate**: full `elevateAccess`-adjacent control across the entire landing-zone hierarchy. So the real
security win of OQ-008 is not yet realized.

**Required remediation to actually realize ADR-021 (the concrete blocker keeping OQ-008 open):**
1. Run a real CI `target=all` apply THEN teardown with the scoped set present, to prove the scoped roles
   (MG Contributor @ tenant root, Resource Policy Contributor + UAA @ globaris, per-sub Contributor + UAA)
   are sufficient. This is the ADR-021 validation gate.
2. Only after that gate passes green, REMOVE the three standing Owner @ MG grants
   (globaris + connectivity + platform).
3. Risk of removing Owner prematurely: a mid-deploy 403 on a scope the scoped set missed. Mitigation - on
   any 403, add the PRECISE missing action/scope, never revert to Owner.

Note: ADR-028's exemption write does NOT depend on these Owner grants (it also resolves via Resource
Policy Contributor @ globaris), so the Owner removal above does not regress ADR-028.

---
