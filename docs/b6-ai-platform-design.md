# Wave B6 - AI Platform (Microsoft Foundry + one chat model + AI Search) target design

> **Status:** READY FOR IMPLEMENTATION - no user forks (OQ-038 resolved the shape; the model and
> deployment-SKU choices below are architect technical rulings within it). Design and docs only;
> no Terraform is written by this document.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-19.
> **Parent design:** `docs/banking-platform-design.md` section 2.4 / wave B6 (OQ-038 = B: Foundry
> + ONE chat model deployment + AI Search for a private RAG demo; Document Intelligence
> design-only).
> **Target spoke:** `landing-zones/bank-data-p1` (live: snet-private-endpoints with capacity;
> openai/cognitiveservices/search zones linked since B1).
> **New records:** ADR-051 (B6 rulings). No new OQs.

---

## 0. Executive summary

- B6 lands the AI tier in bank-data-p1: a **Microsoft Foundry resource** (Microsoft.
  CognitiveServices/accounts, kind `AIServices`, S0) carrying **ONE chat model deployment -
  `gpt-5.4-nano` (2026-03-17), the cheapest CURRENT-GA nano-class chat model in eastus2,
  live-verified today** - and an **AI Search `basic` service**, both PE-only, AAD-only,
  diagnostics to law-platform, behind `enable_ai_platform` (default false, LESSON 42).
- **LESSON 40 catch, live:** the founding design's example models are now DEPRECATING in the
  region catalog (gpt-4o-mini, gpt-4.1-nano, o3-mini, o4-mini, gpt-4.1-mini all carry
  `Deprecating` lifecycle). A 2026-07 design must NOT deploy them. gpt-5.4-nano and gpt-5-nano
  are the GA nano-class options; the newest (5.4, 2026-03-17) is ruled.
- **Deployment SKU ruled `DataZoneStandard`** (US data-zone processing - the banking
  data-residency posture; quota live-verified 2000 K-TPM free) over `GlobalStandard` (cheapest,
  global routing; 5000 K-TPM free) - both available for the model in this sub; GlobalStandard is
  the recorded fallback if DataZone ever caps.
- **Compliant by design, zero exemptions:** all three live corp Deny members
  (`Deny-Cognitive-Services-Public-Network-Access`, `Deny-Cognitive-Services-Network-Access`,
  `Deny-CognitiveSearch-PublicEndpoint` - all default Deny, verified live today) are satisfied by
  pna=Disabled + network ACLs default Deny + Search pna off. NOTE the second member checks
  `networkAcls.defaultAction`, so the account MUST set network_acls Deny in addition to pna
  false - encoded in the spec.
- **Zero firewall delta, zero UDR changes:** PE data-plane traffic is in-VNet; ARM control plane
  rides the CI runner. Stated formally in section 5.
- **DNS delta = ONE new zone link:** `privatelink.services.ai.azure.com` (live in central rg-dns,
  verified today; required third zone for Foundry-resource PEs) is not yet linked to the spoke -
  B6 extends `dns_links.tf` by one key. openai/cognitiveservices/search links are live since B1.
- Quota verified live: `AIServices.S0.AccountCount` 0/100; model K-TPM free at both SKUs. Cost:
  **~$3/day** (Search basic ~$2.5/day bills from create; Foundry S0 $0 idle + nano-class tokens;
  2 PEs). Wave duration ~15-25 min.

## 1. Scope and boundary

### In scope (B6)

| Item | Where |
|---|---|
| Foundry account (kind AIServices) + 1 model deployment + account PE (3-zone group) + diagnostics | `landing-zones/bank-data-p1` (new `ai.tf`), workload RG, `enable_ai_platform` default false |
| AI Search basic + PE + diagnostics | same root/flag |
| `services.ai` zone link | `dns_links.tf` +1 key |
| `enable_ai_platform = true` flip | `envs/poc.tfvars` (reviewed commit) |
| Deviation-register append (ADR-049 duty): B6 deviations recorded | this doc section 8 |

### Explicitly OUT (the demo boundary - parked, do not build)

- NO RAG indexing pipeline, indexes, indexers, skillsets, or data sources; NO Search shared
  private links (outbound Search-to-storage); NO application code.
- NO Foundry projects/agents/hubs built (project management is an account property; projects are
  design-only at POC); NO Document Intelligence resource (OQ-038 = design-only); NO second model,
  NO fine-tuning, NO provisioned throughput (PTU is production design).
- QA data-plane bar: endpoints RESOLVE through the spoke zones (in-cluster nslookup, the B4
  mechanic) = REQUIRED; one minimal AAD-authed completion call through the PE (in-cluster curl)
  = best-effort (NSP/QA query-path class caveat stands).

## 2. Verification log (2026-07-19, all dated today)

| Claim | How verified |
|---|---|
| `avm-res-cognitiveservices-account` latest STILL **0.11.1** (2026-06-21) | Terraform Registry API |
| 0.11.1 input surface covers the FULL Foundry-resource model: `kind`, `sku_name`, `parent_id` (azapi-shaped), `custom_subdomain_name`, `network_acls`, `public_network_access_enabled`, `local_auth_enabled`, `cognitive_deployments` (in-module model deployments), `private_endpoints` + `private_endpoints_manage_dns_zone_group`, `diagnostic_settings`, `managed_identities`, plus Foundry-era `allow_project_management` / `default_project` / `associated_projects` / `network_injections` | tag v0.11.1 variables.tf read |
| `avm-res-search-searchservice` latest STILL **0.3.0** (2026-06-19) | Terraform Registry API |
| 0.3.0 inputs: `sku`, `public_network_access_enabled`, `local_authentication_enabled`, `authentication_failure_mode`, `partition_count`/`replica_count`, `private_endpoints` + zone group, `diagnostic_settings`, `managed_identities`; takes `resource_group_name` (azurerm-shaped, unlike the account module) | tag v0.3.0 variables.tf read |
| eastus2 model catalog: gpt-4o-mini, gpt-4.1-nano, gpt-4.1-mini, o3-mini, o4-mini = **Deprecating**; **gpt-5-nano (2025-08-07) and gpt-5.4-nano (2026-03-17) = GenerallyAvailable** | `az cognitiveservices model list -l eastus2` live |
| Quota (this sub, eastus2): `OpenAI.GlobalStandard.gpt-5.4-nano` 0/5000; `OpenAI.DataZoneStandard.gpt-5.4-nano` 0/2000; `AIServices.S0.AccountCount` 0/100 | `az cognitiveservices usage list -l eastus2` live |
| Corp deny members: `Deny-Cognitive-Services-Public-Network-Access` (builtin 0725b4dd), `Deny-Cognitive-Services-Network-Access` (builtin 037eea7a - checks networkAcls.defaultAction), `Deny-CognitiveSearch-PublicEndpoint` (builtin ee980b6d) - **all three default Deny**, assignment passes `{}` | live set-definition dump |
| RPs Microsoft.CognitiveServices + Microsoft.Search **Registered** (landingzones sub) | `az provider show` live |
| Central zones live in rg-dns: cognitiveservices, openai, search, **services.ai** (all four) ; services.ai present in the pinned zones-module default list | `az network private-dns zone list` live + module source grep |
| services.ai NOT yet linked to bank-data-p1 (B1 linked 6 zones: blob/dfs/databricks/openai/cognitiveservices/search) | B1 dns_links.tf read |
| NOT verified (build/pre-clearance): exact gpt-5.4-nano token prices (nano-class, expected cents/1M-token order - QA usage is pennies either way); Search basic exact hourly (~$75/mo approximate carried); custom-subdomain + Search name global availability (pre-clearance live check); module telemetry fan-out counts (bar set from source at pre-clearance per the B5 lesson); whether 0.11.1 auto-creates a default project when `allow_project_management` defaults on (implementer verifies the default and keeps projects OUT) | marked where cited |

## 3. Foundry specification (implementer contract)

Module: `Azure/avm-res-cognitiveservices-account/azurerm` version = `"0.11.1"` (azapi-shaped;
the root's anchored default azapi provider carries the landingzones sub, LESSON 23).

| Input | Value | Why |
|---|---|---|
| `name` / `kind` / `sku_name` | `aif-bank-data-p1-<org>-<env>` / **`AIServices`** / `S0` | the CURRENT Foundry resource model (founding design naming audit; NOT the classic MLServices hub) |
| `parent_id` / `location` | workload RG id / eastus2 | estate template |
| `custom_subdomain_name` | `aif-bank-data-p1-<org>-<env>` | REQUIRED for PE + AAD data-plane; globally unique - pre-clearance availability check |
| `public_network_access_enabled` | **false** | member 0725b4dd compliance |
| `network_acls` | `{ default_action = "Deny" }` (no IP rules) | member 037eea7a checks defaultAction - pna false alone does NOT satisfy it |
| `local_auth_enabled` | **false** | AAD-only estate bar (keys off) |
| `managed_identities` | system-assigned | future RAG wiring target; no role assignments at B6 |
| `cognitive_deployments` | ONE: name `chat`, model format `OpenAI`, name **`gpt-5.4-nano`**, version `"2026-03-17"`, sku name **`DataZoneStandard`**, capacity **10** (10K TPM) | cheapest current-GA nano-class chat model (deprecating-catalog catch, section 2); DataZone = US data-zone residency posture; 10 of 2000 free K-TPM |
| `private_endpoints` | ONE PE `pe-aif-bank-data-p1-...` into snet-private-endpoints, subresource `account`, `private_dns_zone_resource_ids` = **[cognitiveservices, openai, services.ai zone ids]** (three-zone group), module-managed | current Foundry PE guidance needs all three zones; one PE serves them |
| `diagnostic_settings` | to `var.platform_law_workspace_id`, allLogs group | estate pattern |
| Projects | NONE built (`allow_project_management`/`default_project` left so that NO project resource is created - implementer verifies module defaults achieve this) | boundary; Foundry portal/project experience is production design |

`dns_links.tf`: add key `servicesai = "privatelink.services.ai.azure.com"` to the links map
(static key, existing data-source + link pattern; one new link resource).

## 4. AI Search specification (implementer contract)

Module: `Azure/avm-res-search-searchservice/azurerm` version = `"0.3.0"`.

| Input | Value | Why |
|---|---|---|
| `name` | `srch-bank-data-p1-<org>-<env>` | globally unique DNS name - pre-clearance check; lowercase+hyphen legal |
| `resource_group_name` / `location` | workload RG / eastus2 | note: azurerm-shaped module (resource_group_name, not parent_id) |
| `sku` | `basic` | OQ-038 shape; PE-capable (verified in module PE input); ~$2.5/day approximate |
| `partition_count` / `replica_count` | 1 / 1 | smallest basic topology |
| `public_network_access_enabled` | **false** | member ee980b6d compliance |
| `local_authentication_enabled` | **false**; `authentication_failure_mode` = null (only meaningful with keys on) | AAD-only bar |
| `managed_identities` | system-assigned | future RAG outbound identity; no roles at B6 |
| `private_endpoints` | ONE PE `pe-srch-bank-data-p1-...` into snet-private-endpoints, search zone id (live + linked since B1), module-managed zone group | proven pattern |
| `diagnostic_settings` | to platform LAW | estate pattern |
| Semantic search / CMK | omit | not needed for the boundary; CMK is B9 class |

## 5. Firewall / network delta statement (deliverable)

**ZERO firewall changes, ZERO UDR changes, ZERO NSG changes.** Both services are reached through
private endpoints in snet-private-endpoints - in-VNet traffic that never hits the 0.0.0.0/0
route's firewall next-hop in a rule-relevant way. Model inference (DataZoneStandard) is served
through the ACCOUNT's endpoint - i.e. through the same account PE; no separate egress path
exists or is needed. ARM control-plane operations originate from the CI runner (outside the
VNet), as with every prior wave. No service-tag rules, no bypass routes, no new RCG for B6.

## 6. Policy matrix + quota (deliverable)

- All three Deny members satisfied BY DESIGN (section 2 table; the 037eea7a networkAcls catch is
  encoded in the spec). Zero exemptions in wave B6. The B5 standing matrix rows (storage members,
  Audit members, DINE) are untouched by B6's resource types.
- Quota: account count 0/100; model K-TPM 10 of 2000 (DataZone) requested; nothing else consumes
  quota. No Microsoft.Compute surface.

## 7. Cost, duration, QA and pre-clearance feed

- **Cost:** Search basic ~$2.5/day (bills from create - it is the wave's only always-on cost);
  Foundry S0 $0 idle, tokens pennies at QA volume; 2 PEs ~$0.5/day. **B6 delta ~$3/day.**
- **Duration:** account 2-5 min, deployment 1-2 min, Search create 5-10 min, PEs ~2 min each.
  Wave ~15-25 min, no long-create isolation, sequential with nothing (single root apply).
- **Plan bars (pre-clearance refines; telemetry fan-out counted from module source per the B5
  lesson):** pure adds only - 2 module sets + 1 zone link; ZERO destroys/replaces; ZERO changes
  at pre-existing addresses; no exemption/sleep addresses may appear (compliant-by-design wave);
  B5 addresses untouched.
- **Pre-clearance live checks:** custom-subdomain + Search name availability; policy matrix
  refresh (any new Deny member on CognitiveServices/Search since today); model still
  non-deprecating at apply date (catalog re-list if the apply slips - the B5 lifecycle clock
  rule applies from 2026-07-25); RPs re-confirm; known-issues sweep on both module repos (0.11.1
  and 0.3.0 are FIRST estate consumptions).
- **QA (before green):** ARM live-vs-intent both services (pna false, ACL deny, local auth off,
  kind AIServices, deployment model/version/sku/capacity exact); A records present in all four
  zones (cognitiveservices, openai, services.ai for the account PE; search for the Search PE);
  in-cluster nslookup resolves both endpoints to spoke PE IPs (REQUIRED); in-cluster AAD
  completion call (best-effort, NSP caveat); zero policy violations; Fabric/Databricks addresses
  untouched.

## 8. Deviation-register append (ADR-049 duty)

B6 adds these to the docs/b-restoration-design.md register at class (c), production targets
documented not deployed: Foundry projects + agent/RAG wiring (application scope), Document
Intelligence (OQ-038 design-only), PTU/provisioned throughput, Search Standard+ tiers with
semantic search, Search shared private links for outbound indexing. None are gated-off
infrastructure (no flags to restore); B-R validates the AI tier as-built. No B6 item joins the
fork list.
