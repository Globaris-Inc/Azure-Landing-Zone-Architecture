# Pre-clearance: Wave B4 - API platform (APIM Developer stv2 internal mode) + kubelet RA fix

> **Root(s):** `platform/connectivity` (rcg-apim-egress-primary) then `landing-zones/bank-app-p1`
> (APIM + rt-apim + subnet delta + scoped DNS + kubelet RA durable fix).
> **Code identity:** banking @ `e0fb478` (merge of PR #16, reviewer APPROVE with 3 advisory
> findings - all dispositioned below). Design contract: `docs/b4-apim-platform-design.md`
> (ADR-047).
> **Author:** Cloud Solutions Architect. **Date:** 2026-07-18.
> **VERDICT: GO-conditional** - five preconditions (PC-1A..5A, section 5). Single-dispatcher
> rule in force: all dispatches, plan scans against these bars, and gate coordination happen in
> the main lane.

---

## 1. Reviewer findings - dispositions

### 1a. HARD checkpoint: `public_network_access_enabled` left at module default (true) on an internal-mode instance

**DISPOSITION: ACCEPT-WITH-EVIDENCE. Setting it false is AFFIRMATIVELY REJECTED - it would
break the create.** Verified today against current stv2 semantics:

1. ARM does not accept `publicNetworkAccess = Disabled` on an APIM instance unless the instance
   has **at least one approved private endpoint connection** (MS Learn private-endpoint doc;
   Azure/azure-rest-api-specs issue #24947 records exactly this internal-VNet case: "Disabling
   all publicNetworkAccess for service is not supported if the service does not have at least
   one approved Private Endpoint Connections").
2. Inbound private endpoints are **not supported in combination with VNet injection** - so a
   VNet-injected internal instance can never satisfy that precondition. A `false` in code =
   guaranteed apply failure on the longest create of the build.
3. The property is therefore moot for this shape: in internal mode the gateway, developer
   portal, and git endpoints have NO public presence at all (they are not even registered in
   public DNS). The only publicly-sourced surface is the control-plane path on TCP 3443, which
   the B1 NSG restricts to the `ApiManagement` service tag, and whose return route is the
   service-tag UDR (ADR-047). This is the Microsoft-documented correct posture for internal
   mode.
4. Residual: the corp `Deny-Public-Endpoints` member `ApiManDenyPublicIP` (effect
   **AuditIfNotExists**, re-verified live this session, assignment passes no parameters) may
   surface an AUDIT non-compliance against the instance because the property reads Enabled.
   That is an accepted, documented audit finding, not a Deny and not a posture gap - QA notes
   it if it appears (PC-5A). No code change; no exemption.

### 1b. Module 0.9.0 registry-vs-GitHub tag anomaly

**DISPOSITION: NOT A BLOCKER - fetch path proven live today; recorded as a provenance watch
item.** Facts established this session:

- GitHub tags/releases for `Azure/terraform-azurerm-avm-res-apimanagement-service` stop at
  **v0.1.0**; tags v0.2.x-v0.9.0 do not exist (registry version list jumps 0.1.0 -> 0.9.0).
- The registry download endpoint for 0.9.0 returns
  `git::https://github.com/Azure/terraform-azurerm-avm-res-apimanagement-service?ref=1bb1067ee2e5ce085f84b099fac4159e57fba15f`
  - an **immutable commit SHA**, not a tag. The commit exists (2026-05-22, three days before
  the registry publish date) and is **reachable from main** (compare API: main is 4 ahead).
- **Fetch test PASSED live:** `terraform init` against a minimal `version = "0.9.0"` stub
  downloaded the module successfully (scratchpad, this session). 93k registry downloads to
  date.
- Risk read: consumption is deterministic (SHA-pinned by the registry redirect, immune to
  upstream tag churn). The anomaly is upstream release hygiene, not integrity. Watch item for
  the known-issues sweep at any future version bump: if the registry ever re-points 0.9.0 the
  first init after cache-clear would surface it; source review for this pin uses the commit
  SHA above (the engineer already did - code comment in apim.tf).

### 1c. Engineer's greenfield-rebuild caveat: static-args kubelet data source 404s at plan if the cluster is absent with the flag on

**DISPOSITION: NOT a B4 blocker - the cluster is LIVE (provisioningState Succeeded, kubelet
identity present, verified this session), so the data source resolves. Rebuild staging note
RULED as follows:**

- **EOW teardown is UNAFFECTED:** the destroy refresh happens while the cluster still exists,
  so the data source resolves; the spokes-first flow needs no change.
- **Teardown-retry edge (pre-framed recovery):** if a partial teardown deletes the cluster and
  a retry then needs to plan against remaining state, the data source may 404. Recovery: flip
  `enable_kubernetes_platform = false` for the retry (config-only; removes the data source and
  its consumers from config so the destroy of remaining state proceeds). One line, reviewed
  commit, no improvisation.
- **Greenfield rebuild (if it ever happens - the estate is BUILD-VERIFY-DESTROY and B10 ends
  in teardown):** a fresh apply with `enable_kubernetes_platform = true` WILL fail at plan
  (data source read precedes cluster create). The pre-approved fix-spec, to be implemented
  only in the rebuild's own batch (no speculative build now): add a `aks_bootstrap` bool
  (default false); ternary the RA `principal_id` to the module output when true (the
  computed-output cascade is irrelevant on a first create - the RA is created fresh in the
  same apply) and gate the data source on `!aks_bootstrap`; bootstrap apply runs with true,
  then a one-line flip back to false yields a zero-change plan (identical value, now
  data-source-known). Recorded here and in the rebuild runbook pointer; the rebuild
  pre-clearance carries it as a precondition.

## 2. Live evidence (all checks run this session, 2026-07-18)

| Check | Result |
|---|---|
| APIM name `apim-bank-app-p1-globaris-poc` | **AVAILABLE** (checkNameAvailability 2024-05-01, re-checked today) |
| Microsoft.ApiManagement RP (landingzones sub) | **Registered** (re-checked today) |
| snet-apim live state | NSG = nsg-apim-bank-app-p1 (correct), route table = **rt-spoke** (pre-B4 expected), **no service endpoints, no delegations, EMPTY** (ipConfigurations null) - clean injection target per the MS prerequisite |
| AKS cluster | `aks-bank-app-p1-globaris-poc` provisioningState **Succeeded**, kubelet identity present - the B4 data source resolves at plan |
| Firewalls | **10.0.0.4 (eastus2) / 10.1.0.4 (centralus)** live - ADR-042 contract holds; no IP re-gate needed |
| Primary policy `fwp-hub-eastus2-001` RCGs | exactly `rcg-aks-egress-primary` @ **300**; priority **310 is free** for the new RCG |
| Policy matrix | swept live earlier THIS session (design doc section 2): zero Deny members target APIM at corp/landingzones; `ApiManDenyPublicIP` = AuditIfNotExists `{}`-parameterized; `deny-pub-net-globaris` = sql/kv/storage only; Deny-Public-IP identity-MG-only AND moot (no public IP resource in this design) |
| Module fetch | 0.9.0 downloads clean from the SHA-pinned registry redirect (section 1b) |
| Lifecycle clock | audit current as of today (classic Developer + stv2 clean); re-run the LESSON 40-41 delta if applies slip past 2026-07-25 (ADR-045 date) |
| CI ceiling | no `timeout-minutes` in any workflow - GitHub default **360 min** clears the ~3h worst-case create |

Not pre-checkable (watch items, not blockers): APIM offer-cap/capacity for this sub+region (no
quota API for Microsoft.ApiManagement; ADR-031-class failure would surface at PUT - the flag
pattern keeps the spoke shippable if it bites); SB-Premium-style capacity checks do not exist
for APIM.

## 3. Plan bars (PC-3A; scans happen in the main lane)

### Apply 1 - platform/connectivity

- **Adds: EXACTLY 1** - `azurerm_firewall_policy_rule_collection_group.apim_egress_primary["primary"]`
  (5 application rules in `apim-egress-app` @100, 3 network rules in `apim-egress-net` @200,
  RCG priority 310, source 10.30.1.0/24).
- **Changes:** noise-class only (OQ-032/computed/tags). Class bar, not count bar (B3
  precedent): any non-tag functional attribute change - especially anything touching
  `rcg-aks-egress-primary`, the firewalls, policies, or hub RTs - is a STOP.
- **Destroys/replaces: 0.** Any = STOP.

### Apply 2 - landing-zones/bank-app-p1 (after PC-2A gate)

- **Adds: ~10-14, by address class and nothing else:**
  - `azurerm_route_table.apim["main"]` (1)
  - `module.apim["main"]...` (5-8: APIM service, api, api operation, operation policy,
    diagnostic setting, plus the module telemetry pair)
  - `azurerm_private_dns_zone.apim["main"]` (1), `azurerm_private_dns_a_record.apim_apex["main"]` (1),
    `azurerm_private_dns_zone_virtual_network_link.apim["spoke"|"hub"]` (2)
- **Changes: EXACTLY ONE functional in-place update** - the `apim` subnet inside
  module.spoke_vnet (routeTable.id swap to rt-apim + the four serviceEndpoints, one azapi PUT,
  in-place per the pinned module subnet source) - plus the standing noise class. Any change on
  the aks-nodes or private-endpoints subnets, NSGs, peerings, flow log, AKS, ACR, EH/SB
  resources = STOP.
- **Destroys/replaces: 0.** Specifically: the kubelet RA
  (`module.acr["main"].azurerm_role_assignment.this["kubelet_acr_pull"]`) **must NOT appear in
  the plan AT ALL** - the durable fix makes its principal_id plan-time-known and
  value-identical, so the correct result is a no-op. The B3 interim one-accepted-replace bar
  is **RETIRED**. Any line at that address (update, replace, anything) means the fix did not
  behave as specified = STOP + one consolidated fix-spec (LESSON 59), no re-accept.
- **Zero-tolerance additions:** any policy exemption, any time_sleep, any public IP resource,
  a second route table change, any resource outside the address classes above.

## 4. Duration / token / settle posture (PC-4A)

- APIM stv2 Developer internal-mode create: **30-90+ min typical, up to ~3h** (azurerm create
  timeout default 3h governs; no module timeouts input on 0.9.0). This is the longest single
  create of the build. Treat under 2h as NORMAL - do not kill, do not re-dispatch, do not
  "check with a second run" (the B3 duplicate-dispatch incident class; state-lease protection
  is not an invitation).
- OIDC/ARM token posture proven on this estate (per-request refresh, 90+ runs); GitHub job
  ceiling 360 min clears the worst case. Nothing else hour-scale rides this apply (LESSON 46
  isolation honored: connectivity apply is separate and short).
- **Mid-apply death (runner/network death, not an ARM error):** state persists per completed
  resource; disposition BEFORE any retry: check the APIM `provisioningState` live. Not
  submitted or ARM-rejected -> plain short rerun. In flight (Created/Activating server-side,
  absent from state) -> WAIT for terminal state; if Succeeded -> `terraform import` into
  `module.apim["main"]` (LESSON 46 import-based recovery) - a blind rerun hits name-in-use.
- Sequential dispatch with the standing JIT state-SA/settle hygiene between the two applies.

## 5. Preconditions (GO is conditional on ALL)

- **PC-1A (code identity):** both applies run banking @ `e0fb478` or a descendant with zero
  .tf delta to platform/connectivity and landing-zones/bank-app-p1. Note: plan-on-pr did not
  demonstrably run on PR #16 (no check runs found on the PR); the local fetch test covers
  module resolvability, but the FIRST CI plan of each root is also the first full init of this
  code in CI - scan it against the bars with extra care rather than assuming a prior green.
- **PC-2A (ordering gate):** connectivity apply completes FIRST and `rcg-apim-egress-primary`
  is confirmed live on fwp-hub-eastus2-001 at priority 310 BEFORE the bank-app-p1 dispatch.
  An APIM create behind default-deny hangs toward the 3h timeout - this gate is cheap, the
  failure is not. Firewall IPs already verified live (no re-gate).
- **PC-3A (plan bars):** section 3, scanned in the main lane before each apply. Class-based
  change bar; the kubelet RA no-op rule is part of the bar.
- **PC-4A (duration discipline):** section 4. No second dispatch while apply 2 runs, no
  matter how long it sits in the APIM create.
- **PC-5A (QA before green):** design doc section 12.7 checklist, PLUS: (i) record the
  ApiManDenyPublicIP audit-compliance state of the new instance (accepted finding per 1a if
  non-compliant); (ii) verify the kubelet RA live and unchanged (same principal, AcrPull, ACR
  scope, same RA name/GUID as pre-apply - proving no silent recreate); (iii) the in-VNet
  data-plane probe via `az aks command invoke` curl of
  `https://apim-bank-app-p1-globaris-poc.azure-api.net/health/ping` expecting the mocked 200;
  (iv) AZFW resource-specific tables show apim-egress hits from 10.30.1.x (in-boundary query
  per B3); (v) APIM Network Status shows all REQUIRED dependencies connected.

## 6. Rollback / abort posture

- Abort before apply 2: the RCG is inert without APIM traffic; it can stay or be reverted with
  the flag - no exposure either way.
- Failed APIM create after ARM acceptance: do NOT delete-and-retry blind; soft-delete applies
  (providers.tf purge flags are in place), and a Failed instance should be diagnosed via
  Network Status + activity log first, one consolidated fix-spec per failure set (LESSON 59).
- The subnet delta (rt-apim + service endpoints) is independently revertible by flag; reverting
  restores rt-spoke association in one in-place update.
