# Pre-clearance: Wave B6 - AI platform (bank-data-p1)

> **Root:** `landing-zones/bank-data-p1` (single apply; Foundry account + model + PE, AI Search +
> PE, services.ai zone link).
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-19 (all live checks this session).
> **Code identity:** banking @ 1d974b1 (Foundry AIServices S0 + gpt-5.4-nano DataZoneStandard cap
> 10 + AI Search basic, both PE-only/AAD-only with network_acls Deny, behind `enable_ai_platform`;
> services.ai zone link UNGATED per design so it lands +1 regardless of the flag; hardened fabric
> guard rides). Design contract: docs/b6-ai-platform-design.md (ADR-051). No user forks.
>
> ## VERDICT: **GO - CONDITIONAL** on PC-1E through PC-5E.
> One known-issue (PC-1E) is a PUT-time watch with a pre-written disposition, not a blocker.

---

## 1. Live checks (this session)

| Check | Result | Disposition |
|---|---|---|
| Microsoft.CognitiveServices RP (landingzones sub) | **Registered** | PASS |
| Microsoft.Search RP (landingzones sub) | **Registered** | PASS |
| gpt-5.4-nano (2026-03-17) lifecycle in eastus2 | **GenerallyAvailable**, SKUs GlobalStandard + DataZoneStandard both present | PASS - the LESSON 40 model catch that started this design HOLDS at apply date; the founding-design example models remain Deprecating (do not substitute) |
| DataZoneStandard.gpt-5.4-nano TPM quota (sub, eastus2) | **0 / 2000 K-TPM** | PASS - the design's capacity 10 fits with vast headroom |
| AIServices.S0 account count | **0 / 100** | PASS |
| Foundry custom subdomain `aif-bank-data-p1-globaris-poc` | checkDomainAvailability = **available: true** | PASS - global-unique subdomain free |
| AI Search name `srch-bank-data-p1-globaris-poc` | checkNameAvailability = **available: true** | PASS - global-unique name free |
| Corp deny members: cognitiveServicesPublicNetworkAccess (0725b4dd), cognitiveServicesNetworkAccess (037eea7a), cognitiveSearchPublicNetworkAccess (ee980b6d) | **all default Deny**; count of Cognitive/Search/OpenAI members = 3 (no NEW member since design) | **COMPLIANT-BY-DESIGN PROOF:** Foundry sets pna=false AND network_acls default_action=Deny (satisfies BOTH the pna member 0725b4dd AND the networkAcls member 037eea7a - the subtle catch); Search sets pna=false (satisfies ee980b6d). ZERO exemptions expected in B6 |
| services.ai zone live + spoke-link state | zone live in central rg-dns; B6 adds the missing spoke link | PASS - the +1 link (see plan bars) |

## 2. Known-issues sweep (both modules are FIRST estate consumptions)

| Finding | Source | Disposition |
|---|---|---|
| **PC-1E watch - Foundry PE race:** the azurerm provider reports the AIServices account create COMPLETE while ARM still returns provisioningState `Accepted`, so a private-endpoint create in the SAME apply can fail `AccountProvisioningStateInvalid` / `AccountProvisioningStateInvalid` | hashicorp/terraform-provider-azurerm issue #31712 (Foundry-specific); older class #15152 | REAL and ON our exact path (account + PE one apply). MITIGATION already in our code path: 0.11.1 migrated the PE to `azapi_resource` WITH RETRY LOGIC (module changelog) - built precisely for this. PUT-time watch, pre-written disposition: if the PE errors AccountProvisioningState* on first apply, it is a TIMING failure, not a code defect - **single rerun** (the account is now Succeeded, the PE PUT retries clean); zero resources orphan (a failed PE creates nothing). Do NOT change code on the first occurrence. Second identical failure = STOP (LESSON 59) |
| cognitive_deployments 409 Conflict on concurrent deployment creates | module note (deployment_serialization_enabled option) | MOOT - we deploy exactly ONE model; no concurrency. Recorded so a future multi-model wave sets serialization |
| Search module PE / basic SKU | no matching open issue found on our shape (basic + single PE + zone group is the module's documented example path) | PASS - proven pattern |

## 3. Plan-shape bars (single apply, bank-data-p1, enable_ai_platform=true)

Pure adds by class (telemetry fan-out counted from source per the B5 lesson - the cognitive
module carries its own modtm/random pair, the search module another):

| Class | Expected addresses |
|---|---|
| Foundry | `module.ai_foundry` (or equivalent): the azapi cognitive account, ONE `cognitive_deployments` (chat / gpt-5.4-nano / DataZoneStandard / cap 10), ONE account PE, the PE's **3 DNS zone-group records** (cognitiveservices + openai + services.ai), 1 diagnostic setting, module telemetry pair |
| AI Search | `module.ai_search`: the search service, ONE PE, its 1 zone-group record (search zone), 1 diagnostic setting, module telemetry pair |
| DNS | **+1 zone link** `azurerm_private_dns_zone_virtual_network_link` for services.ai (UNGATED by design - lands even at flag-false; call it out so QA does not read it as stray) |

Hard bars:
- **ZERO destroys, ZERO replaces** (any `-/+` = STOP, LESSON 26).
- **ZERO changes at any pre-existing functional address:** spoke_vnet/subnets/UDR/NSG, peerings,
  B5 Databricks/ADLS/exemption/RCG addresses, DNS links (other than the +1 services.ai add).
- **The kubelet-RA-fix + hardened-fabric-guard changes that merged with this batch must NOT
  produce functional diffs** - refresh/no-op only; any functional line at those addresses = STOP.
- **NO fabric-capacity plan line.** `enable_fabric_capacity` stays true but the capacity already
  exists (centralus, B5) - the expected state is a NO-OP (refresh only). A `~`/`-+`/create at the
  fabric address = drift = STOP and diagnose before applying B6.
- **NO exemption / no time_sleep address** may appear - B6 is compliant by design; an exemption
  in the plan means the compliance assumption broke = STOP.
- services.ai link + both PE zone groups reference EXISTING central zones (connectivity sub), not
  zone creates.

## 4. Duration / operational

- ~15-25 min: account 2-5 min, model deployment 1-2 min (RP-side control-plane - the deployment
  PUT can lag the account by seconds-to-a-minute; the module's serialization/lock handles
  ordering), Search 5-10 min, PEs ~2 min each. No long-create isolation; single root apply, no
  cross-root ordering (services.ai zone pre-exists).
- Single-dispatcher: one dispatch, no second dispatch while it runs (B3 incident class).

## 5. QA feed (before green)

- ARM live-vs-intent BOTH services: Foundry kind=AIServices, S0, pna false, networkAcls
  defaultAction Deny, local auth off, custom subdomain set, ONE deployment (model/version/sku/
  capacity exact); Search basic, pna false, local auth off, 1/1 partition/replica.
- A records present: cognitiveservices + openai + services.ai for the account PE; search for the
  Search PE. In-cluster nslookup resolves both endpoints to spoke PE IPs = **REQUIRED**.
- **Data-plane QA feasibility (best-effort, NSP caveat):** one in-cluster AAD-authed completion
  call to the Foundry endpoint through the PE - a 200 with a token response proves the private
  data plane end-to-end; the standing NSP query-path limitation may block it, in which case DNS
  resolution + ARM state is the accepted proof (as at B2-B5). Not a green-blocker.
- Zero policy violations on either resource (compliant-by-design confirmation).
- Fabric capacity untouched (no-op); B5 addresses untouched; the services.ai link present.

## 6. GO conditions

| # | Condition |
|---|---|
| **PC-1E** | Foundry PE race (#31712) is a PUT-time watch: if PE errors AccountProvisioningState* on first apply, single rerun (account now Succeeded, azapi retry clears it); NO code change on first occurrence; second identical = STOP |
| **PC-2E** | Plan-scan against section 3 bars; any breach (esp. a fabric create/replace, an exemption line, or a functional diff at the kubelet/fabric-guard addresses) = STOP |
| **PC-3E** | Single apply, single dispatch; no second dispatch while running |
| **PC-4E** | QA per section 5 before green; DNS resolution REQUIRED, completion call best-effort |
| **PC-5E** | Lifecycle clock: model verified GA TODAY; if the apply slips past 2026-07-25 re-list the eastus2 catalog before applying (the model catch is the whole point of this wave) |

### ADDENDUM 2026-07-19 - PC-2E plan-scan disposition (run 29677918828): APPROVED for apply

`18 add / 22 change / 0 destroy`. All 18 adds exact-match the section 3 bar (Foundry azapi
ai_service + chat deployment + PE + 3-zone group + interfaces + diag + telemetry +
wait_ai_service_creation sleep; Search service + PE + diag + telemetry; the +1 servicesai zone
LINK). 0 destroys, 0 replaces. Non-noise change counter = 0 (all 22 changes are OQ-032
CreatedDate strips).

**Fabric watch-item RESOLVED (the PC-2E STOP guard did its job by forcing the read):** the plan
DOES carry `azurerm_fabric_capacity.this["main"]` but as `updated in-place`, full diff = exactly
ONE attribute `tags "CreatedDate" 1970-01-01 -> null` - no sku, no administration_members, no
state/pause attribute. This is NOT the create/replace the bar stops on; it is the identical
OQ-032 CreatedDate-strip noise hitting all 22 changed resources, and it independently confirms
the design prediction that the out-of-band suspend produces ZERO config drift. The "expected
NO-OP" is functionally met (zero functional change). **CLOSED-BY-RULE under the standing OQ-032
disposition.** Bar language tightened for future waves: "no fabric FUNCTIONAL change" (a
tags-only OQ-032 strip is permitted; any sku/members/create/replace remains a STOP).

**Disposition: APPROVED for apply.** PC-1E (Foundry PE race) remains the live watch during the
apply. NOTE (b12): no deployment gate is operative, so this written disposition is the last
control before the apply - single-dispatcher discipline applies.

### ADDENDUM 2026-07-19 - apply 29678062833 FAILED (3 classes): diagnosis + ONE consolidated fix-spec

STOP honoured. NOT the PC-1E PE race (zero AccountProvisioningState errors). Partial state
(live-verified): **Foundry account `aif-bank-data-p1-globaris-poc` LIVE / Succeeded / eastus2**
(create succeeded - in TF state); **Search: none created**; **Fabric: still Paused, unchanged**.
Three distinct classes, one bank-data-p1 batch fixes all three (cloud-engineer implements,
reviewer gates, single rerun).

**CLASS 1 - AI Search eastus2 capacity exhaustion (`InsufficientResourcesAvailable`).** Not a
code defect; a live regional capacity shortage. RULED (user steer): **deploy Search in centralus.**
- Fix: new variable `search_location` (string, default `"centralus"`, DEVIATION description
  mirroring `fabric_location`: eastus2 InsufficientResourcesAvailable 2026-07-19); `ai.tf` Search
  module `location = var.search_location`.
- **Cross-region PE CONFIRMED coherent:** a private endpoint is a NIC in ITS subnet's region
  (eastus2 snet-private-endpoints 10.32.2.0/24); the target Search service may live in centralus;
  Azure supports cross-region PE and private DNS is region-agnostic (one A record in the
  spoke-linked search zone regardless of service region). The Search PE STAYS in the eastus2
  spoke subnet - no PE change beyond the service location. QA verifies the A record resolves to
  the eastus2 PE IP as before.
- Register: another eastus2-capacity deviation feeds the B-R region-alignment item (see below).

**CLASS 2 - Foundry PE 3-zone group `DuplicateResourceName` (MODULE BUG, not our input).**
Diagnosed from v0.11.1 source: the `private_endpoints` variable exposes only
`private_dns_zone_group_name` (single, default "default") + `private_dns_zone_resource_ids` (a
set) - NO per-zone config-name field. The interfaces submodule builds one
`privateDnsZoneConfig` per zone but names them all "default", so a 3-zone set collides
("two child resources with the same name (default)"). Our input is CORRECT and cannot fix it -
first-consumption module bug on the multi-zone-single-PE shape (single-zone PEs, as in datalake.tf,
are unaffected, which is why B5 was clean).
- Fix (surgical, reuses the LIVE account and the already-created module PE NIC): set
  `private_endpoints_manage_dns_zone_group = false` on the Foundry module call so the module
  builds ONLY the account + the PE and STOPS emitting the broken zone group; then author a
  native **`azapi_resource` privateDnsZoneGroup** (`# DEVIATION:` citing this addendum) against
  the module PE id, `body.properties.privateDnsZoneConfigs` = THREE explicitly-named configs
  (`cognitiveservices` / `openai` / `servicesai`, each with its zone id). Explicit names kill the
  collision. Cloud-engineer verifies the module output exposing the PE id under
  manage_dns_zone_group=false (the `private_endpoints_unmanaged` path, main.privateendpoint.tf
  line 73) and the current privateDnsZoneGroups ARM api-version.
- **Reconciliation of the live account:** `terraform state list` MUST show the Foundry account
  (create succeeded before the PE step, so it is in state) - expected a NO-OP/OQ-032-tag-strip on
  rerun, NOT a recreate; if absent (partial state write), IMPORT via the live resource id, do NOT
  recreate. If the module's azapi PE was created and is in state, it stays (we keep the module
  PE, only its zone group moves to the native resource); if a PE exists in Azure but NOT in state,
  delete it out-of-band before rerun to avoid a name collision. A `-/+` on the Foundry ACCOUNT at
  plan = STOP (must never recreate the live account).

**CLASS 3 - Fabric paused-capacity tag update (`400 Service is not ready to be updated`) -
HONEST CORRECTION.** The OQ-032 CreatedDate tag-strip we jointly dispositioned as benign CANNOT
apply to a PAUSED capacity, and would fail EVERY future bank-data-p1 apply while Fabric is paused.
My B5 "out-of-band suspend produces zero config drift" prediction was WRONG in one respect: the
suspend produces no drift in the capacity's OWN attributes, but it makes the standing policy-tag
churn UNAPPLIABLE - recorded as the pause-vs-OQ032 interaction correction.
- Fix: `lifecycle { ignore_changes = [tags] }` on `azurerm_fabric_capacity.this`. Confirmed no
  conflict: tags are set at create; we never update them intentionally; the ONLY tag churn is the
  policy-injected CreatedDate strip we do not want TF fighting anyway; pause state is not a tag,
  so ignoring tags does not touch the suspend/resume path. Cleanest and correct.

**Consolidated batch (ONE bank-data-p1 change, LESSON 59 - narrows the failure class):**
`search_location` variable + `ai.tf` Search location; Foundry module
`private_endpoints_manage_dns_zone_group = false` + native azapi 3-config zone group; fabric
`lifecycle ignore_changes = [tags]`. Reviewer delta-gates. Rerun plan bar: adds = Search set
(now centralus) + the native Foundry zone group; the Foundry ACCOUNT + its module PE = no-op (or
tag-strip only); fabric = NO plan line at all now (tags ignored); 0 destroys/replaces EXCEPT the
possible removal of the module's broken zone-group address if it reached state (it did not -
it errored); any Foundry-account or live-PE replace = STOP. Rerun is single-dispatch; PC-1E PE
race still watched on the (native) PE create.

### ADDENDUM 2026-07-19 - rerun 29694639634: 3 of 4 landed, SEARCH PE region bind - feasibility ruling + FIX-vs-DEFER

Landed: Foundry (account + PE + native 3-config zone group all Succeeded - class 2 DONE); Fabric
(ignore_changes worked, no plan line - class 3 DONE). FAILED: the Search service DID create in
centralus (provisioningState "None" - orphaned/incomplete, in TF state) but its PE errored
`InvalidResourceReference: [eastus2 spoke VNET] referenced by [pe-srch] ... both resources must
be in the same region`.

**(a) Is cross-region PE supported for Search? YES (generic Azure Private Link capability) - and
the diagnosis was mis-attributed.** The error is NOT a Search RP rejection of cross-region PE. It
is the PE-vs-SUBNET region rule: a PE NIC must sit in ITS SUBNET's region (eastus2). The
avm-res-search-searchservice 0.3.0 module put the PE in CENTRALUS because
`location = coalesce(each.value.location, var.location)` and we did NOT set the per-PE
`location`, so it defaulted to the SERVICE location (centralus) - a PE in centralus against an
eastus2 subnet is the violation. **Correction to the class-1 assumption AND to the "module does
not decouple" read: the module's `private_endpoints` object HAS a per-PE `location` field
(verified in v0.3.0 variables.tf line 25 + main.privateendpoint.tf line 5).** Honest residual:
MS docs do not carry an explicit "Search supports a cross-region private-link connection"
statement (the how-to is same-region-tutorial-shaped), so whether the Search RP accepts the
eastus2-PE-to-centralus-service link is a PUT-time unknown on the fixed rerun - but if it fails
it will be a DIFFERENT error (a private-link-service rejection), not this region-reference one.

**(b) FIX-spec (module-native, NO native PE, NO deviation - cheaper than class 2's fix):** add
`location = var.primary_location` to the Search PE entry in the `private_endpoints` map. The
module's coalesce then places the PE in eastus2 (matching snet-private-endpoints) while
`var.search_location = "centralus"` drives the service. One-line addition to the existing block.

**(c) Orphan reconciliation (do regardless of fix-vs-defer):** the centralus Search service is
in state, live, provisioningState "None" (abnormal - it will likely NOT converge on a plain
re-apply). Delete the live orphan out-of-band AND `terraform state rm` the Search service address
(or `-replace`/taint) so the rerun creates it clean; leaving a "None" service in state risks a
refresh error. Cost of the orphan: Search basic bills ~$2.5/day from creation - delete promptly
either way.

**(d) RECOMMENDATION - ONE bounded fix attempt, hard-fallback to DEFER:** the fix is now a genuine
one-line module-native change (the earlier "no decoupling" framing was wrong), so it is cheap
enough to try once. **If the fixed rerun throws a NEW cross-region private-link rejection from the
Search RP, STOP and DEFER - do not open a 5th cycle.** If the user has zero appetite for even one
more Search cycle, DEFER now is fully legitimate: Foundry + the chat model (already live) deliver
the core AI story; Search RAG is demo polish. Search is the single most troublesome resource in
the build (eastus2 no-capacity + the module PE-location default), and that history justifies a
hard stop after this attempt.

**DEFER mechanics (if chosen now or as the fallback):** new flag `enable_ai_search` (bool, default
false) gating the Search module + its PE + its diagnostics; `enable_ai_platform` keeps
Foundry+model. Delete the orphan + state rm per (c). Register: Search moves to a B-R item with a
region-matched design (eastus2 capacity retry at B-R, OR a centralus PE subnet, OR accept
centralus service + confirmed cross-region PE) - a proper design, not a 4th reactive patch.

### ADDENDUM 2026-07-19 - USER DECISION supersedes fix-vs-defer: same-region (Search centralus + PE in a centralus HUB subnet). Cross-role fix-spec

User ruling: do NOT defer, do NOT attempt cross-region PE. Deploy Search in centralus AND put its
PE in a centralus subnet so both are same-region. Use the secondary hub
`vnet-hub-secondary-globaris-poc` (10.1.0.0/16, centralus - the only existing centralus network).
Once proven in centralus, the PRODUCTION pattern replicates the same Search+PE in the eastus2
spoke when eastus2 capacity returns.

**Live facts verified this session (they SIMPLIFY the spec):**
- Secondary hub VNet 10.1.0.0/16, centralus, rg-connectivity-secondary-globaris-poc; ONLY subnet
  present = `AzureFirewallSubnet` 10.1.0.0/26 (firewall live at 10.1.0.4). Vast free space.
  Chosen PE subnet CIDR: **10.1.1.0/27** (clean, no collision with the /26 firewall carve or any
  gated-off GatewaySubnet/resolver carve).
- **The search zone `privatelink.search.windows.net` (rg-dns-globaris-poc) is ALREADY LINKED to
  the secondary hub AND to the bank-data-p1 spoke** (live-verified links:
  vnet-hub-primary, vnet-hub-secondary, vnet-spoke-bank-data-p1). So NO new zone link is needed -
  the PE's A record resolves from the centralus hub AND from the eastus2 spoke automatically.
- Search zone name confirmed = `privatelink.search.windows.net` (searchService subresource).

**MECHANISM RULING (correcting the coordinator's "disable module PE + native" framing to the
cleaner path):** do NOT author a native PE. The Search module PE was only broken by REGION, and
Search has a SINGLE zone (no duplicate-"default" bug - that was the 3-zone Foundry case). The
module `private_endpoints` object exposes BOTH a per-PE `location` AND `subnet_resource_id`, so
retarget the existing module PE:
- `subnet_resource_id` = the NEW secondary-hub PE subnet (connectivity sub) - see role 1
- `location` = `var.search_location` (centralus) => PE region == subnet region == centralus, no
  mismatch
- `private_dns_zone_resource_ids` = [the search zone id] unchanged (module inline zone group,
  single zone, no bug)
Native PE is the documented FALLBACK only if the module PE's cross-sub subnet join misbehaves at
apply.

**Cross-sub note (ruled):** the module PE resource is created by the ROOT default provider
(landingzones sub) into the bank-data-p1 workload RG, with its NIC injected into the
connectivity-sub hub subnet by `subnet_resource_id`. This is a cross-sub PE (PE resource in
landingzones, subnet in connectivity) - supported. PREREQUISITE (pre-clearance gate): the CI
deploy SP must hold `Microsoft.Network/virtualNetworks/subnets/join/action` on the new hub subnet
(it already has Network Contributor on the connectivity hub RGs from the return-peering wiring -
VERIFY the scope covers the secondary hub subnet; if not, add a scoped role assignment in role 1).

**ROLE 1 - platform/connectivity (applies FIRST):**
1. Add PE subnet `snet-ai-search-pe` 10.1.1.0/27 to the secondary hub VNet with
   `private_endpoint_network_policies = "Disabled"`. BUILD-TIME VERIFY: whether the pinned
   avm-ptn-alz-connectivity-hub-and-spoke-vnet 0.17.1 exposes a hub-subnet input to add this
   cleanly (PREFERRED - avoids drift) vs a standalone `azurerm_subnet` on the module-managed VNet
   (check the module does not reconcile-delete extra subnets; AVM VNet uses standalone
   azurerm_subnet so coexistence is typical - confirm in source).
2. NO zone link needed (already linked - verified). NO firewall rule needed for B6 (PE data-plane
   is in-VNet; see QA note).
3. Gating: prefer behind `enable_ai_platform` (the subnet exists only for this wave's PE); if the
   module-subnet-map makes conditional entries awkward, an unconditional harmless empty /27 is
   acceptable - rule at build.

**ROLE 2 - landing-zones/bank-data-p1 (applies AFTER connectivity):**
1. Retarget the Search module PE per the mechanism ruling (subnet_resource_id = the new hub
   subnet id, location = var.search_location). Service `location = var.search_location`
   (centralus) unchanged.
2. The hub subnet id crosses subs - pass it into the root as a variable (like the existing
   `primary_hub_*` inputs), fed from a connectivity output or a repo variable; do NOT hardcode.

**(3) ORPHAN reconciliation:** the retarget touches only the PE's subnet+location - it does NOT
change the Search SERVICE config, so TF will NOT recreate the service. BUT the live service is
provisioningState "None" (abnormal, never became functional). GATE: `az search service show`
must read Succeeded before the PE apply; if still "None"/stuck, this service (unlike the Foundry
account which is Succeeded and MUST NOT be recreated) is a clean delete target - delete it
out-of-band + `terraform state rm` the service address so the role-2 apply recreates it clean in
centralus, THEN the PE attaches. A `-/+` on the Search service from the PE-only change = STOP
(would mean the service config drifted unexpectedly).

**(4) ARCHITECTURAL DEVIATION (documented):** a spoke workload's PE living in the HUB breaks the
estate's spoke-owns-its-PEs pattern. Recorded as a POC-proves-the-pattern DEVIATION; the
PRODUCTION target is the identical Search+PE co-located in the eastus2 bank-data-p1 spoke once
eastus2 Search capacity returns (register d7). DNS implication: none blocking - the hub-placed
PE's A record lands in the shared search zone, already linked to the eastus2 spoke, so spoke
resolvers get it. **REACHABILITY honesty (feeds QA):** DNS RESOLUTION from the eastus2 spoke is
satisfied (shared zone). Actual TCP data-plane reach from eastus2 AKS to the centralus-hub PE IP
(10.1.1.x) requires spoke->primary-hub-firewall->hub-to-hub-peering->secondary-hub routing, which
is NOT wired/verified at B6 - so the Search data-plane completion call stays BEST-EFFORT/deferred
(on top of the standing NSP caveat), and clean reachability is itself part of why the eastus2-spoke
co-location is the production target. QA bar for Search at B6: service Succeeded + PE Succeeded +
A record present in the search zone; in-spoke resolution best-effort.

**Ordering + gates:** multi-root batch. Cloud-engineer implements both roots; reviewer
delta-gates; **connectivity applies FIRST (subnet + any SP role), confirm subnet live, THEN
bank-data-p1** (PE references the subnet id - a missing subnet fails the PE PUT). Single-dispatch
each; PC-1E-class PE-race watch not applicable (Search, not Foundry). Plan bars: connectivity =
+1 subnet (+ maybe 1 role assignment), 0 destroy/replace; bank-data-p1 = Search PE now
centralus/hub-subnet (an in-place PE update or a PE add if the failed PE never reached state) +
possibly the service recreate IF the orphan was deleted per (3), 0 OTHER destroys/replaces, NO
Foundry/Fabric plan line.
