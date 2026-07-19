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
