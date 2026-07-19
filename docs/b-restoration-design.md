# Wave B-R - Production restoration: the deviation register and the return to full deployment

> **Status:** DESIGNED per the user directive of 2026-07-19 (recorded in ADR-049): when the banking
> build completes, the landing zone returns to FULL deployment with every sprint/cost deviation
> reversed - the end state must meet a PRODUCTION environment setup, not a POC.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-19.
> **Placement ruling:** B-R is a DEDICATED wave, after B9 (security/compliance extension) and
> BEFORE B10 (DR docs + acceptance), so that B10's acceptance validation runs against the
> production shape - validating the POC shape and then mutating it would invalidate the stamp.
> **Sequence (ADR-049):** build (B6..B9) -> B-R restoration -> B10 validate/QA at production
> shape -> THEN the teardown/keep decision. ADR-045's end-of-week teardown is SUPERSEDED as an
> endpoint; the Frame A/B mechanics survive as the decision's implementation options.
> **User forks:** consolidated in ONE question, OQ-046 - a single pass, per-item costs, not
> piecemeal. Plain restores (no fork) proceed on the standing gates without user round-trips.

---

## 0. How to read the register

Every deviation made across the build (ADR trail 015/022/031-048 + the estate-wide `enable_*`
flag sweep + `envs/poc.tfvars` + the design docs' explicitly-deferred-to-production lists),
classified:

- **(a) Gated-off infrastructure** - restore = reviewed flag flip + apply (+ pre-clearance).
- **(b) Posture/process artifacts** - reconcile, drop, or keep-with-justification.
- **(c) POC-scale sizing vs the recorded production design targets** - SKU/topology changes.
- **(d) Unbuildable in this tenant/offer** - documented honestly; restore blocked on an external
  grant/ticket, not on this repo.

Each row: restore mechanic, cost delta per day (approximate list, to be re-verified at the B-R
pre-clearance), and PLAIN (no fork) vs FORK (user decides in OQ-046).

**Scope boundary ruling (the one framing call in this design):** "production environment setup"
is read as SINGLE-REGION PRODUCTION-GRADE for the banking workload tier plus the full dual-hub
platform fabric as originally designed. It does NOT silently pull in the multi-region scale-out
(second-region banking spokes 10.31/10.33, APIM multi-region, AKS second cluster) that every
design doc records as documented-not-deployed (ADR-022 split, B10 DR chapter). Going multi-region
roughly doubles the estate and is therefore surfaced as an explicit OQ-046 fork, not assumed.
The user's own example (VPN gateway) is a gated-off single-region platform component - class (a).

## 1. Class (a): gated-off infrastructure to restore (flag flips)

| # | Item | Flag / source | Deviation origin | Restore mechanic | ~$/day | Fork? |
|---|---|---|---|---|---|---|
| a1 | VPN Gateway (VpnGw1AZ, primary hub) | `enable_vpn_gateway` (default false; unset in tfvars) | ADR-042 (idle-spend deferral; the user's own directive example) | Flag flip in poc.tfvars + connectivity apply. LONG create 30-50 min - isolate the apply (LESSON 46 class); GatewaySubnet 10.0.1.0/27 stayed reserved, pure add | ~$8.7 | **PLAIN** (named by the directive) |
| a2 | DNS Private Resolver (primary hub) | `enable_dns_resolver` (default false) | ADR-042 | Flag flip + same connectivity apply train as a1; pure add (outbound subnet + delegation kept) | ~$12 | **PLAIN** |
| a3 | DDoS Network Protection plan | `enable_ddos_standard = false` (explicit tfvars line) | Section-3 recorded POC deviation (fidelity map) | Flag flip + apply; VNet associations follow the existing wiring | ~$98 (~$2,944/mo) | **FORK f1** - the single biggest line item; production-claim-required vs documented-exception |
| a4 | Azure Bastion | `enable_bastion` (default false, ADR-015 on-demand pattern) | Design choice, not a sprint shortcut | Either keep on-demand (recommended - a legitimate production ops pattern) or always-on | ~$4.6 if always-on | **FORK f2** (recommend: keep on-demand) |
| a5 | Fabric F2 capacity | `enable_fabric_capacity` (state per the 2026-07-19 quota fork outcome) | AMENDED 2026-07-19: activation surfaced a THREE-layer precondition stack - RP registration (done), tenant service onboarding (done), and regional CU quota **live-verified 0 in eastus2 = the offer-cap class, see d6** | Portal CU quota raise (Quotas > Microsoft Fabric > eastus2); re-flip under a mini-pre-clearance verifying ALL THREE preconditions; then pause-schedule per resolved f3 | ~$8.6 active / ~$0 paused | f3 resolved (pause-schedule); the QUOTA outcome decides whether Fabric restores at B-R or stays class (d) |
| a6 | Firewalls, AKS, messaging, APIM, data platform | `enable_firewall`, `enable_kubernetes_platform`, `enable_messaging_platform`, `enable_api_platform`, `enable_data_platform` | were sprint-gated | ALREADY TRUE - no action; listed for register completeness | in run-rate | n/a |
| a7 | Synthetic workload layer | `enable_synthetic_workload = false` | ADR-036/037 REPOSITIONED it to the O&M capability | NOT restored as synthetic - B7 builds the O&M Phase 1 slice instead; the flag stays false permanently (design supersession, not a cost deviation) | - | n/a (recorded) |

## 2. Class (b): posture/process artifacts to reconcile

| # | Item | Origin | Production answer | Fork? |
|---|---|---|---|---|
| b1 | dbstorage subscription-scoped Waiver (expires 2026-08-01) | ADR-048 collision unit guarantee half | AMENDED per B5 QA (PC-4D, 2026-07-19): the SA is live at publicNetworkAccess=Enabled behind an RP-created NSP + ACL-deny, so the waiver is LOAD-BEARING - early drop is DEAD. It RUNS TO EXPIRY, and BEFORE 2026-08-01 B-R replaces it with a STANDING managed-RG-scoped exemption (the managed RG now exists; verify the deny assignment permits exemption writes at that scope, fallback = renew the sub-scoped waiver with a new expiry). The production shape carries this as a documented flow-log-class permanent exception, not zero exemptions | PLAIN (mechanic changed, still no fork) |
| b2 | Flow-log SA RG-scoped waivers (bank-app-p1, bank-data-p1, Section-9 spokes) | OQ-024/ADR-028 - Network Watcher is not a storage trusted service | KEEP with standing justification: this is a platform constraint, not a POC shortcut; the production posture documents it as a permanent scoped exception (revisit if flow-log delivery ever supports SecuredByPerimeter) | PLAIN (keep-documented) |
| b3 | Bootstrap reconcile: ADR-041 temporary tenant-root grants + the github-banking-branch federated credential | B0a carry-over, STILL OPEN | B-R closes it: revoke the temp grants, prune fed creds to the production branch set (main + the standing workflows), re-verify OIDC per root. Revocation strictly AFTER verified estate state (LESSON 54-57 class applies if teardown is ever chosen instead) | PLAIN (devsecops lane) |
| b4 | Microsoft.Fabric RP NotRegistered | B5 pre-clearance record | Register at the a5 flip (PC-5D) | PLAIN (rides a5) |
| b5 | OQ-032 CreatedDate tag drift (accepted cosmetic noise) | tag-governance Modify vs TF | RECOMMEND: keep accepting + document as known behavior - the fix (policy parameter surgery or estate-wide tags ignore_changes) buys cosmetic cleanliness at real blast radius. Surfaced once in OQ-046 for an explicit production-answer sign-off | **FORK f4** (recommend: accept-documented) |
| b6 | NSP QA query-path limitation (standing could-not-verify class in QA) | B2+ QA notes | devsecops tooling item on the B-R checklist (fix or formally document the alternative evidence path); not infrastructure | PLAIN |
| b7 | Branch state: banking -> main promotion of the whole build | process | Final promotion PR at build completion; ruleset already on main | PLAIN |
| b8 | KV publicNetworkAccess=Enabled finding (Section 12) + CMK breadth + CA report-only mode | B9 SCOPE (already planned: KV network fix, CMK on data stores, CA enforcement decision, regulatory initiatives) | B-R VALIDATES B9 delivered them; not B-R scope itself. The CA enforce flip remains the recorded user decision inside B9 | (B9) |
| b10 | **BOTH estate Key Vaults OPEN: pna Enabled, NO networkAcls at all** (tfstate KV in management, security KV in the security sub) - USER FINDING 2026-07-19, the Section-12 finding reproduced post-redeploy | Sections 8/6 builds; escaped policy for the same reason as b9 (see b11) | **RULED per KV, lands in B9 (which already owns the KV network fix, row b8): (1) tfstate KV -> the STATE-SA JIT/Deny pattern** (ACL defaultAction Deny + AzureServices bypass, pna Enabled firewall-mode, CI JIT-allowlists the runner IP exactly as it already does for the state SA; consumers are OIDC CI on public runners + operator portal - both public-side, so PE is REJECTED on the b9 logic: no in-VNet reader). VERIFY: a full CI plan/apply cycle must succeed post-hardening. **(2) security KV -> consumer inventory FIRST** (enumerate live readers from KV diagnostics before flipping; expected: Azure security services on the trusted-services path, no in-VNet reader - the security sub has no VNet), then Deny + AzureServices bypass; if inventory finds zero external readers the flip is free. PE rejected same logic. Documented-open is NOT accepted for either - unlike flow-logs there is no functional constraint, and these hold secrets. **USER-CONFIRMED 2026-07-19: enforce at B-R, not pulled forward** | PLAIN (mechanics ruled; no fork) - DECIDED |
| b12 | **GOVERNANCE: the GitHub `production` AND `production-destroy` environments have ZERO protection rules** - no required reviewers, no wait timer (live-verified: apply runs' created_at == run_started_at, approvals API empty). EVERY apply/destroy this build ran immediately on dispatch with NO enforced human-in-the-loop; the session's "gate approval" ritual was NON-OPERATIVE (OQ-015 was carried as an interim on the belief branch-protection substituted - it does not gate environment deploys) - USER FINDING 2026-07-19 | Section 10 CI; the required-reviewer entitlement was the OQ-015/OQ-040 open item | **RULED (DevSecOps lane at B-R, enforced BEFORE the B-R validation/acceptance stamp so the restored production estate has a REAL deployment gate): required-reviewer protection on BOTH environments (operator as reviewer, `prevent_self_review` on), VERSION-CONTROLLED the way the main branch-protection ruleset already is (.github/ environment-config artifact + apply script, the imported-ruleset precedent). This closes OQ-015 for real (not the branch-protection interim). CROSS-REF: until this lands, the SINGLE-DISPATCHER RULE is the ONLY current guard against an unintended apply/destroy - stated so the risk is explicit while the estate lives. USER-CONFIRMED 2026-07-19: proceed with B6 now, fix at B-R** | PLAIN (DevSecOps; no fork) - DECIDED |
| b11 | **STRUCTURAL: the platform MG tree has ZERO public-endpoint policy coverage** - Deny-Public-Endpoints exists at corp MG, deny-pub-net-globaris at landingzones MG, NOTHING at platform (ALZ archetype default). This is WHY b9 + b10 escaped every sweep. User bar (elevated from datum to ruled item): platform subs holding secrets must not be structurally invisible to policy | ALZ archetype defaults, unexamined since Section 2 | **RULED, two stages: (1) B9 assigns the Deny-PublicPaaSEndpoints initiative at the PLATFORM MG with all members parameterized to AUDIT** - visibility lands immediately, zero blocking, zero exemption units, the deny-pub-net-globaris custom-assignment precedent is the mechanism; **(2) B-R promotes the storage + KV members to DENY as ONE unit with the exemption bill pre-built: FOUR RG-scoped member-scoped exemptions** (state SA, finops SA, tfstate KV, security KV - all firewall-mode pna-Enabled by their rulings, which violates the member LETTER while closed in effect; ADR-028 unit each, with sleeps) riding the same change (LESSON 35 one-unit rule). Promotion only after b9/b10 hardening is live-verified. Audit-first over Deny-now: Deny-now needs the same 4 exemptions anyway but gambles platform-root applies against propagation timing for zero interim gain. **USER-CONFIRMED 2026-07-19: enforce at B-R (B9 Audit -> B-R Deny), not pulled forward** | PLAIN (staged; no fork) - DECIDED |
| b9 | **finops GZRS SA (`stfinops...`, management sub) OPEN: pna Enabled + defaultAction Allow, no PE** - USER FINDING 2026-07-19; pre-banking ALZ estate (Sections 3/7), never on the register (the management sub sits outside the corp/landingzones deny scopes, so no policy ever forced it) | Section 3/7 build, cost-export delivery target | **RULED: HARDEN to the STATE-SA PATTERN at B-R - networkAcls defaultAction Deny + bypass AzureServices, pna stays Enabled (firewall mode), NO private endpoint.** PE rejected with rationale: the management sub has no VNet, and the SA has no in-VNet consumer - Cost Management writes service-side (trusted-services path) and the only reader is the user via portal (JIT/IP-rule pattern, the state-SA precedent). VERIFY-AT-B-R: a cost-export delivery run must succeed AFTER hardening (the old Section-7 OQ flagged the trusted-service path as unverified; fallback = scoped IP rules, last resort = revert to documented-open). **USER-CONFIRMED 2026-07-19: enforce at B-R, not pulled forward** | PLAIN (mechanic ruled; no fork) - DECIDED |

### 2.1 Full-estate storage-account posture table (QA-checkable truth, live-swept 2026-07-19)

The register's authoritative SA inventory - B-R QA validates live state against THIS table (and
any SA added by later waves must be appended here at its wave's design time):

| SA (class) | Sub | Live posture (2026-07-19) | Register state | B-R target |
|---|---|---|---|---|
| ADLS `stlake...` (B5) | landingzones | pna Disabled, ACL Deny, PE blob+dfs, AAD-only | compliant by design | unchanged |
| dbstorage `dbstorage...` (B5, RP-managed) | landingzones | pna Enabled + NSP + ACL Deny (closed in effect) | b1: waiver runs to expiry, then managed-RG-scoped standing exemption | unchanged posture; exemption swap per b1 |
| State backend SA (bootstrap) | management | Deny-defaulted, JIT-allowlist pattern (closed in effect) | documented since Section 10 | unchanged (the PATTERN b9 copies) |
| Flow-log SA bank-app-p1 | landingzones | pna Enabled + Allow, no PE | b2: keep-documented (platform constraint, OQ-024) | unchanged, documented |
| Flow-log SA bank-data-p1 | landingzones | pna Enabled + Allow, no PE | b2: keep-documented | unchanged, documented |
| finops GZRS `stfinops...` (Sections 3/7) | management | **pna Enabled + Allow, no PE - was NOT on the register (user finding)** | b9 NEW | **hardened to the state-SA pattern (Deny + AzureServices bypass), delivery-verified** |

## 3. Class (c): POC-scale sizing vs recorded production targets

| # | Item | POC shape (live) | Production target (recorded where) | Restore mechanic | ~$/day delta | Fork? |
|---|---|---|---|---|---|---|
| c1 | APIM | Developer_1, no SLA, no zones (~$1.6/day) | Premium w/ zones (founding 2.2, ADR-047) | In-place SKU upgrade Developer -> Premium (stv2; verify current upgrade-path support at B-R pre-clearance; long operation, isolate) | +~$93/day per unit (~$95/day total) | **FORK f5** - the second biggest line |
| c2 | Service Bus | Premium 1 MU + PE | SAME - production shape ALREADY deployed (ADR-046) | none for the base; optional geo-DR pair (target lists it) = second Premium namespace | +~$22/day if geo-DR | **FORK f6** (geo-DR only; base is done) |
| c3 | Event Hubs | Standard 1 TU, auto-inflate off | auto-inflate/TU scale-out (founding 2.2) | enable auto-inflate + max TU bound; config-only change | ~$0 idle (burst-priced) | PLAIN (config) |
| c4 | AKS | 3x D2s_v4 single system pool, zones 1-3, Standard tier, autoscaler off | + user node pool, autoscaler bounds (founding 2.1/ADR-043; OQ-043 quota trail now allows it: 24-core cap, 6 used, non-DSv4 v4 family required) | add user pool (3x 2-vCPU v4, family live-verified at pre-clearance) + enable autoscaler with bounds | +~$7/day | **FORK f7** |
| c5 | Databricks network | front-end public (AAD), NPIP, firewall egress | front+back-end Private Link, pna false (ADR-048 section 8) | back-end + front-end + browser-auth PEs, NSG rules mode change, pna false; OPERATIONAL DEPENDENCY: a private access path for humans (a1's restored VPN GW P2S, or Bastion) must exist FIRST or the UI goes dark | +~$0.7/day + ops | **FORK f8** (sequenced after a1) |
| c6 | Fabric SKU | F2 | F2 stands (right-size later per usage) | none | - | n/a |
| c7 | Multi-region scale-out: second-region banking spokes (10.31/10.33 reserved), AKS second cluster, APIM multi-region, data geo-replication | single-region + dual-hub fabric | founding design section 3 / B10 chapter: DOCUMENTED-not-deployed | full second-spoke builds (B1-class waves each) | roughly doubles workload-tier run-rate | **FORK f9** - explicitly NOT assumed by this design's production reading |

## 4. Class (d): unbuildable in this tenant/offer (honest record)

| # | Item | Blocker | What unblocks it |
|---|---|---|---|
| d1 | corp-a1/a2 SQL workload (`enable_sql`) | Offer restriction: SQL ProvisioningDisabled in eastus2 (ADR-031) | Offer change/support ticket; NOT this repo. Stays gated with the flag as the re-enable |
| d2 | corp-a1/a2 App Service workload (`enable_app_service`) | Dedicated compute quota 0 (ADR-032); ticket history | Quota grant; flag is the re-enable |
| d3 | v5 VM families | Capped 0 estate-wide on this offer (ADR-043) | Offer/quota change; v4 substitution is the standing production-acceptable answer |
| d4 | Tenant-gated security features: UEBA, aad-diagnostics, dc-aad, dc-ti, MDE connector, firewall TI rule (`enable_ueba`, `enable_aad_diagnostics`, `enable_aad_connector`, `enable_ti_connector`, `enable_mde_connector`, `enable_firewall_ti_rule` - all false) | Tenant Security Administrator grant absent (ADR-033/034, OQ-027/028) - authorization, not propagation (LESSON 49) | THE USER CAN FIX THIS ONE: grant Security Admin to the deploying identity, then the flags flip as a normal B-R item | **FORK f10** (grant + flip vs remain documented-gated) |
| d5 | GHAS (CodeQL/secret-scanning/environment approvals) | Org billing entitlement (OQ-015/OQ-040) | B8 scope; org billing decision - carried there, not B-R |
| d6 | Microsoft Fabric capacity (ADDED 2026-07-19; **RESOLVED same day - LEFT class (d) via region deviation**) | Regional CU quota = 0 in eastus2 on this sub; user portal-verified quota EXISTS in centralus | RULED (B5 pre-clearance addendum): F2 deploys in **centralus** (estate secondary region - coherent; capacity has zero VNet/PE surface; residency moot for the empty POC capacity) via `fabric_location` variable defaulting centralus. **B-R register item: region alignment revisit - eastus2 CU quota ticket to bring Fabric to the primary region, OR accept centralus permanently (coherent with the DR posture)** |

## 5. Restoration wave mechanics

1. **Pre-clearance:** B-R gets a full pre-clearance doc (policy matrix refresh, lifecycle
   re-audit MANDATORY - by B-R the estate will be near or past the 2-week re-audit clock, and
   the dbstorage waiver expiry 2026-08-01 sits inside the window; VPN GW SKU lifecycle re-check).
2. **Order:** (i) plain restores first: a1+a2 in one connectivity apply (VPN GW isolated timing),
   b1 waiver drop after B5 QA evidence, b3 bootstrap reconcile, c3 auto-inflate; (ii) OQ-046
   outcomes next, cost-descending only after the user's single-pass answer; (iii) c5 strictly
   after a1 (access path); (iv) B10 acceptance runs LAST against the final shape.
3. **Plan bars per apply:** pure adds or exact-shape config changes only; any replace = STOP
   (LESSON 26); VPN GW and APIM-upgrade applies are isolated long-runs.
4. **Cost statement:** current sprint run-rate ~$112-125/day. Plain restores add ~$21/day.
   The OQ-046 forks, if ALL accepted (excl. f9 multi-region), add roughly ~$135-145/day more -
   a full production posture around ~$270/day (~$8k/mo) before multi-region. Each fork carries
   its own line so the user can compose the exact end state.
5. **Teardown decision:** AFTER B10 validation, per ADR-049 - keep-running (production claim
   live) vs teardown (the build is proven and repeatable via CI). The Frame A/B mechanics and
   the spokes-first destroy order remain the implementation; revocation timing rules (LESSONS
   54-57) apply only if teardown is chosen.

## 6. OQ-046 RESOLUTION (2026-07-19, user: "take the recommendations"; implementation deferred to B-R)

All ten forks resolved to the recommended positions - the register's fork cells now read through
this table. Decision record: ADR-050 (incl. the delegated f1 collapse).

| Fork | Resolved state |
|---|---|
| f1 DDoS | **NO DEPLOY** (architect ruling under delegation): production design target + plan-attach mechanics documented; `enable_ddos_standard` stays the re-enable; DDoS IP Protection noted as the targeted alternative. The production claim carries this as a documented, costed exception |
| f2 Bastion | keep ON-DEMAND (ADR-015 pattern is the production ops answer) |
| f3 Fabric | pause-schedule posture once OQ-045 resolves the admin principal |
| f4 OQ-032 | keep accepting, documented |
| f5 APIM | **YES - Premium with zones at B-R** (+~$93/day, isolated in-place stv2 upgrade) |
| f6 SB geo-DR | NO (base Premium+PE already production shape) |
| f7 AKS user pool | **YES at B-R** (+~$7/day; non-DSv4 v4 family, quota live-verified at B-R pre-clearance) |
| f8 Databricks PL | **YES at B-R**, strictly after the a1 VPN GW restore (private access path first) |
| f9 Multi-region | NO - stays the B10-documented DR design |
| f10 Security-Admin | **YES - user grants Security Administrator to the CI deploy SP** (exact steps in the OQ-046 resolution); then the six ADR-033/034 flags flip at B-R |

Resolved B-R cost picture: plain restores ~$21/day + resolved forks (~$100/day: f5 ~$93 + f7 ~$7
+ f8 ~$0.7) on top of the ~$112-125/day estate = **~$235-250/day (~$7-7.5k/mo) production shape**,
with DDoS documented-not-deployed and multi-region documented-not-deployed.

## 7. Where the remaining waves fit

| Wave | Status | Relation to B-R |
|---|---|---|
| B5 | applying now | its QA evidence feeds b1 (waiver drop) |
| B6 (AI platform) | next build wave | builds POC-scale per its own design; its deviations (if any) append to THIS register at design time |
| B7 (O&M Phase 1) | planned | absorbs a7 permanently; the production monitoring bar B-R validates against |
| B8 (DevSecOps) | planned | owns d5; b3 can ride B8's devsecops lane if sequencing suits |
| B9 (security/compliance) | planned | owns b8's content (KV fix, CMK, CA decision, regulatory initiatives) |
| **B-R (this design)** | after B9 | the restoration wave; consumes the OQ-046 answers |
| B10 (DR docs + acceptance) | last | validates the PRODUCTION shape; DR chapter documents f9 whether or not it is bought |
