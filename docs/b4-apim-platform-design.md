# Wave B4 - API Platform (APIM Developer, internal VNet mode) target design

> **Status:** READY FOR IMPLEMENTATION. Design and docs only; no Terraform is written by this
> document. Resolves the parked WAVE B4 CAVEAT in `landing-zones/bank-app-p1/main.tf` (stv2 forced
> tunneling) with current Microsoft Learn requirements, and carries the MANDATED kubelet RA durable
> fix from the B3 PC-3M disposition (section 8) because this batch touches bank-app-p1.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-18.
> **Parent design:** `docs/banking-platform-design.md` section 2.2 / wave B4.
> **Resolved inputs:** B1 (snet-apim 10.30.1.0/24 + NSG stv2 rules live), B2 (firewalls armed with
> rcg-aks-egress-primary, AKS/ACR green), B3 (AZFW diagnostics live - firewall log evidence now
> queryable for B4 QA), ADR-044 (RCG placement pattern), ADR-045 (sprint frame, EOW teardown).
> **New records:** ADR-047 (B4 design rulings). NO new OQ: APIM Developer is the recorded intent
> from the founding design and the B1 subnet design (main.tf line 13), not an open fork; the
> ADR-045 sprint frame makes the tier cost question moot (~$1.6/day).

---

## 0. Executive summary

- B4 lands **one API Management instance, Developer tier (stv2), injected into the live
  `snet-apim` (10.30.1.0/24) in internal VNet mode**, flag-gated behind `enable_api_platform`
  (default false, LESSON 42). Module: `Azure/avm-res-apimanagement-service/azurerm` 0.9.0
  (re-verified today: still the latest, published 2026-05-25).
- **The parked forced-tunneling caveat is RESOLVED as a three-part unit** (section 5, verified
  against MS Learn today): (1) a dedicated route table for snet-apim carrying BOTH the
  0.0.0.0/0 -> firewall default route AND an `ApiManagement` service-tag route with next hop
  `Internet` (required for management-plane return-path symmetry on stv2); (2) service endpoints
  on snet-apim for Sql, Storage, EventHub, KeyVault (Microsoft strongly recommends; takes APIM's
  own dependency traffic off the forced tunnel); (3) a new firewall rule collection group
  `rcg-apim-egress-primary` (priority 310, primary hub policy only, ADR-044 pattern) for the
  remaining force-tunneled dependencies (cert validation, Entra, Azure Monitor, NTP, KMS,
  infrastructure diagnostics).
- **DNS ruling - the stale-pattern trap caught (LESSON 40 class):** current MS Learn guidance
  (internal-vnet doc, updated 2026-06-25) explicitly states that a private DNS zone for the apex
  `azure-api.net` is **NOT SUPPORTED** and can break resolution of other Azure services. The
  widespread community pattern (apex azure-api.net private zone) must NOT be built. B4 creates
  **one private DNS zone scoped to the exact instance FQDN** (`<apim-name>.azure-api.net`) in the
  estate's central rg-dns (connectivity sub), with an apex A record to the APIM private VIP,
  linked to the bank-app-p1 VNet and the primary hub VNet. Gateway endpoint only; the
  portal/management/scm records are design-only (the direct management API was RETIRED March
  2025, and the developer portal is not published at POC).
- **No public IP resource:** since May 2024 stv2 internal-mode injection no longer needs one
  (verified today). This also makes the Deny-Public-IP question moot; that assignment lives at
  the identity MG only anyway (ADR-028, re-confirmed in the live policy sweep today).
- **Live policy sweep (this session): zero Deny collisions.** The corp `Deny-Public-Endpoints`
  initiative's `ApiManDenyPublicIP` member is effect **AuditIfNotExists** by default and the
  assignment passes no parameters; `deny-pub-net-globaris` at the landingzones MG covers
  SQL/KV/Storage only. Microsoft.ApiManagement RP is Registered. The instance name is verified
  AVAILABLE via checkNameAvailability.
- **Duration reality:** this is the longest single create of the whole build - historically
  30-90+ minutes for stv2 VNet-injected Developer, occasionally up to ~3h. The azurerm default
  APIM create timeout is 3h; CI workflows set no `timeout-minutes` (verified today) so the GitHub
  default 360 min governs. OIDC posture proven (ARM per-request token refresh). Mid-apply-death
  disposition in section 9.
- **Rides along (MANDATED, B3 PC-3M disposition):** the kubelet AcrPull RA durable fix -
  `data.azurerm_kubernetes_cluster` with deterministic name strings feeding the RA principal_id,
  killing the azapi computed-output ForceNew cascade. Verbatim spec in section 8. Once it lands,
  the interim one-accepted-replace bar on bank-app-p1 plans is RETIRED.
- Cost: **B4 adds ~$1.7/day** (Developer ~$1.6/day + one private DNS zone, negligible) under the
  ADR-045 sprint frame.

---

## 1. Scope and boundary

### In scope (B4)

| Item | Where |
|---|---|
| APIM Developer stv2, internal VNet mode, in snet-apim, flag-gated | `landing-zones/bank-app-p1` (new `apim.tf`), `enable_api_platform` default false |
| Dedicated route table for snet-apim (default-to-firewall + ApiManagement-to-Internet) | same root (route table + subnet input change) |
| Service endpoints Sql/Storage/EventHub/KeyVault on snet-apim | same root (subnet input change) |
| Scoped private DNS zone `<apim-name>.azure-api.net` + apex A record + 2 VNet links | same root, into rg-dns via the azurerm.connectivity provider (dns_links.tf precedent) |
| One health-probe demo API (mock response, GET /ping) for QA data-plane evidence | same root (module `apis` input; native azurerm_api_management_api\* fallback pre-authorized) |
| APIM diagnostics to law-platform | module diagnostic_settings |
| `rcg-apim-egress-primary` priority 310 on the PRIMARY hub firewall policy | `platform/connectivity` (new `firewall_rules_apim.tf`), gated on enable_firewall (ADR-044 pattern) |
| azurerm features flags for APIM soft-delete (teardown is designed, LESSONS 54-57) | root providers.tf |
| MANDATED kubelet RA durable fix (section 8) | same root (`aks.tf`/`acr.tf` delta) |

### Explicitly OUT of B4 (parked)

- Any APIs/products beyond the single health-probe demo API; developer portal publishing or
  customization (its CAPTCHA/Storage publish egress is therefore NOT in the firewall rules);
  self-hosted gateway; AKS backend wiring (APIM-to-AKS API routing is a later demo, needs
  workloads that do not exist yet); custom domains + certificates; external exposure via the
  online-p1 App Gateway WAF (production design path); APIM Premium, zones, multi-region (Premium
  classic only carries zones - Developer has none and no SLA; production design target, section
  10); CMK/named-value KV integration (B9); SMTP/email features; direct management API (retired
  March 2025); the portal/developer/scm DNS records (no consumers at POC).

## 2. Verification log (2026-07-18)

| Claim | How verified |
|---|---|
| `avm-res-apimanagement-service` latest STILL **0.9.0** (2026-05-25); requirements terraform >=1.9, azapi ~>2.4, azurerm >=4.0 | Terraform Registry API today |
| 0.9.0 input surface includes: `virtual_network_type`, `virtual_network_subnet_id`, `public_ip_address_id`, `zones`, `sku_name`, `publisher_name`, `publisher_email`, `managed_identities` (system_assigned), `diagnostic_settings`, `public_network_access_enabled`, `min_api_version`, `hostname_configuration`, `apis`/`products`/`backends`/`named_values`, `private_endpoints`; outputs include `private_ip_addresses`, `resource_id`, `gateway_url` | Registry schema name dump today. Exact input SHAPES not individually verified - implementer verifies against the module docs at build (standing CLAUDE.md rule 4) |
| stv2 forced tunneling: control-plane responses will not map back symmetrically through a 0.0.0.0/0 NVA route; REQUIRED fix = UDR for the `ApiManagement` service tag with next hop `Internet` | MS Learn api-management-using-with-internal-vnet (updated 2026-06-25) + the forced-tunneling include, read today |
| Service endpoints recommended on the APIM subnet for Azure SQL, Storage, Event Hubs, Key Vault; remaining dependency traffic stays force-tunneled and the firewall must allow it | same MS Learn doc, "Force tunnel traffic" section, today |
| Since **May 2024 a public IP resource is NO LONGER needed** for internal-mode stv2 injection | same MS Learn doc, Prerequisites Important note, today |
| DNS: **apex `azure-api.net` private zone is NOT SUPPORTED** ("Creating a Private DNS zone or authoritative forward lookup zone for the apex domain (azure-api.net) is not supported"); create zones scoped to the exact instance FQDNs with A records to the private VIP | same MS Learn doc, "Critical DNS design guidance", today. This is NEWER than the common community apex-zone pattern - do not build the old pattern |
| Internal-mode endpoints and default hostnames: gateway `<name>.azure-api.net`, developer portal `<name>.developer.azure-api.net`, legacy portal `<name>.portal.azure-api.net`, management `<name>.management.azure-api.net`, git `<name>.scm.azure-api.net`; service answers ONLY on hostnames, never on bare IP | same MS Learn doc, today |
| Required ports (virtual-network-reference, ms.date **2026-04-30**, APPLIES TO Developer and Premium): inbound TCP 3443 from ApiManagement + TCP 6390 from AzureLoadBalancer (BOTH already in the B1 nsg-apim); required outbound: Internet TCP 80 (certificate validation), Storage 443, Sql 1433, AzureKeyVault 443, AzureMonitor 1886+443; optional: AzureActiveDirectory 443, EventHub 5671-5672+443, AzureConnectors 443 | MS Learn virtual-network-reference, today |
| Infra egress (same reference): NTP UDP 123; KMS TCP 1688; TLS CRL/OCSP FQDNs (mscrl/crl.microsoft.com, oneocsp.microsoft.com, digicert set); Entra `login.microsoftonline.com` + `<region>.login.microsoft.com`; internal diagnostics/Windows Update/Defender FQDN sets; `issuer.pki.azure.com` | MS Learn virtual-network-reference, today |
| Tier lifecycle: classic Developer/Basic/Standard/Premium remain sold alongside v2 tiers, NO retirement announced; stv1 retired 2024-08-31, all current classic instances are stv2; **direct management API RETIRED March 2025**; availability zones are Premium-classic-only | Web search MS Learn + pricing pages, today |
| Azure Load Balancer 6390 note: not strictly required for Developer (single unit) but critical at Premium - the B1 rule stays, correct for the production path | MS Learn virtual-network-reference, today |
| UDR `address_prefix` accepts service tags (e.g. `ApiManagement`) | azurerm provider route/route_table docs (service tags in UDR GA since 2020); implementer re-confirms syntax on azurerm 4.x at build |
| **Live, this session:** Microsoft.ApiManagement RP **Registered**; corp `Deny-Public-Endpoints` member `ApiManDenyPublicIP` -> builtin df73bd95-24da-4a4f-96b9-4e8b94b402bd, allowed effects AuditIfNotExists/Disabled, default **AuditIfNotExists**, assignment passes `{}` (NOT a Deny); landingzones `deny-pub-net-globaris` members = sql/keyvault/storage only (no APIM); Deny-Public-IP at identity MG only (ADR-028) and moot (no public IP resource); name `apim-bank-app-p1-globaris-poc` **AVAILABLE** (checkNameAvailability 2024-05-01); no `timeout-minutes` in any CI workflow (GitHub default 360 min governs) | az CLI + gh repo greps, this session |
| NOT verified / not checkable: APIM offer-cap or capacity restrictions for this sub/region (NO quota API exists for Microsoft.ApiManagement - PUT-time risk of the ADR-031 class, mitigated by the flag pattern); exact Developer hourly rate (~$48/mo list carried); module input shapes (build-time job); azurerm features-block argument names for api_management soft-delete (implementer confirms on azurerm 4.x at build) | marked where cited |

## 3. APIM instance specification (implementer contract)

Module: `Azure/avm-res-apimanagement-service/azurerm` version = `"0.9.0"` (pin). New file
`landing-zones/bank-app-p1/apim.tf`, everything gated on `enable_api_platform` (bool, default
false) via the for_each map pattern (no-count rule).

| Input | Value | Why |
|---|---|---|
| `name` | `apim-bank-app-p1-<org>-<env>` (renders `apim-bank-app-p1-globaris-poc`, verified available) | estate naming; global DNS name |
| `resource_group_name` / `location` | shared RG / eastus2 | integration tier co-located with EH/SB (B3 precedent) |
| `sku_name` | `"Developer_1"` | recorded intent (founding design 2.2, B1 main.tf line 13); VNet-capable; ~$1.6/day. NOT a new fork - see ADR-047 |
| `publisher_name` | `"Globaris Banking Platform"` | required field; no personal values in code (standing rule) |
| `publisher_email` | new variable `apim_publisher_email`, default a generic non-personal alias (e.g. `platform-team@example.com`), overridable in tfvars | required field; never a personal address in the repo |
| `virtual_network_type` | `"Internal"` | the design intent; no public gateway frontend |
| `virtual_network_subnet_id` | `module.spoke_vnet.subnets["apim"].resource_id` (implementer confirms the exact subnets output attribute on the pinned 0.17.1 vnet module) | live snet-apim 10.30.1.0/24 |
| `public_ip_address_id` | omit / null | NOT required for internal mode since May 2024 (verified) |
| `zones` | omit / null | Developer has no zone support (Premium classic only); zones are production design |
| `managed_identities` | `{ system_assigned = true }` | cheapest correct identity for B4; no CMK/KV consumers yet (UAI+CMK is the B9/production pattern) |
| `public_network_access_enabled` | leave module default | the gateway is VNet-internal by mode; the corp APIM policy member is AuditIfNotExists (verified live). If the module default trips anything at plan, resolve at pre-clearance, do not improvise |
| `apis` | one demo API `health` (path `health`, protocols https, one GET `/ping` operation with a mock-response policy returning 200) | QA data-plane surface. If the 0.9.0 `apis` input shape cannot carry the operation+policy, compose native `azurerm_api_management_api` + `_api_operation` + `_api_operation_policy` alongside the module (normal composition, not a module replacement) |
| `diagnostic_settings` | to `var.platform_law_workspace_id`, category group allLogs + AllMetrics | estate pattern |
| timeouts | if the module exposes a timeouts input, set create >= 3h; otherwise rely on provider defaults (azurerm APIM create default is 3h) | longest create of the build |

Also in the batch:

- `providers.tf`: add the azurerm features flags for API Management soft-delete so the EOW
  teardown and any rebuild are clean (BUILD-VERIFY-DESTROY estate): purge on destroy = true,
  recover soft-deleted = true. Implementer confirms the exact `features { api_management { ... } }`
  argument names on the pinned azurerm 4.x at build. Without purge, a destroyed APIM name stays
  soft-delete-reserved and blocks re-create (LESSON 54-57 class).
- `variables.tf`: `enable_api_platform` (bool, default false, description citing this doc +
  the connectivity-first ordering), `apim_publisher_email` (string, generic default).
- poc.tfvars flips `enable_api_platform = true` as a reviewed commit (ADR-044 flag-supply
  precedent). NOTE the PC-2K lesson: the pre-flipped flag makes apply ordering procedural -
  operator-guarded, stated again in section 9.

## 4. DNS design (internal mode, ruled)

Internal-mode APIM registers NOTHING in public DNS and answers only on its hostnames. Without
customer-managed DNS the gateway is unreachable even in-VNet.

**Ruling (ADR-047): scoped-zone pattern, gateway endpoint only, central rg-dns placement.**

1. One `azurerm_private_dns_zone` named **exactly** `apim-bank-app-p1-<org>-<env>.azure-api.net`
   (the full instance FQDN - NOT the apex `azure-api.net`; the apex zone is explicitly
   unsupported per current MS Learn and would shadow every other azure-api.net consumer).
   Created by the bank-app-p1 root **via the azurerm.connectivity alias provider into
   `var.private_dns_rg_name` (rg-dns)** - the estate keeps all private DNS zones in the central
   connectivity rg-dns; the dns_links.tf cross-sub write pattern is proven. Flag-gated with the
   rest of B4.
2. One apex A record in that zone: name `"@"`, TTL 300, records = [the APIM private VIP] from
   the module's `private_ip_addresses` output (first entry; implementer confirms output shape).
   Known after the APIM create completes; same-apply chaining is fine.
3. Two `azurerm_private_dns_zone_virtual_network_link`: bank-app-p1 VNet (QA + future AKS
   consumers resolve in-spoke) and the PRIMARY hub VNet (hub-connected clients via the DNS
   Private Resolver path). Secondary hub link is design-only until a multi-region APIM exists.
4. NOT created (design-only, documented): `<name>.developer.azure-api.net` (portal not
   published), `<name>.portal.azure-api.net` (legacy portal), `<name>.management.azure-api.net`
   (direct management API retired March 2025), `<name>.scm.azure-api.net` (no git config flow at
   POC). If the developer portal is ever published, add its scoped zone the same way.

Why not the standard privatelink zone set: internal-mode VNet injection is NOT Private Link -
there is no privatelink.azure-api.net zone in the AVM 89-zone set for this, and no DNS zone
group. The scoped custom zone above is the correct current mechanism.

## 5. Forced tunneling resolution (the parked B1 caveat, ruled)

The live state: snet-apim carries `rt-spoke` with 0.0.0.0/0 -> 10.0.0.4 (armed firewall). Per
current MS Learn, an stv2 instance behind that route alone will fail: control-plane traffic
enters via the ApiManagement service tag on 3443 and the response path must return symmetrically
to those source IPs, not via the firewall.

**Ruling (ADR-047): three-part unit, all in one batch.**

**(a) Dedicated route table for snet-apim.** New `azurerm_route_table`
`rt-apim-bank-app-p1-<org>-<env>` (bgp propagation disabled), routes:

| Route | address_prefix | next hop |
|---|---|---|
| `default-to-firewall` | `0.0.0.0/0` | VirtualAppliance `var.primary_firewall_private_ip` |
| `apim-management-return` | `ApiManagement` (service tag) | Internet |

snet-apim's `route_table.id` input in the spoke_vnet module flips from
`azurerm_route_table.spoke.id` to the new table (ternary on the flag). The shared `rt-spoke`
is NOT touched - putting the ApiManagement-to-Internet route on the shared table would bypass
the firewall for AKS/PE subnets too, silently widening the exception (rejected). Data-plane and
all other egress from snet-apim STILL goes through the firewall; the exception is exactly the
management return path, which Microsoft states is not a significant security risk (inbound is
already restricted to 3443 from the ApiManagement tag by the B1 NSG).

**(b) Service endpoints on snet-apim:** `["Microsoft.Sql", "Microsoft.Storage",
"Microsoft.EventHub", "Microsoft.KeyVault"]` added to the apim subnet definition (ternary on the
flag). This is Microsoft's strongly-recommended path: APIM's own dependency traffic (its managed
SQL/Storage/KV/EH) rides the Azure backbone instead of the forced tunnel. Alternative rejected:
full force-tunneling of dependency traffic requires allowlisting the complete published IP
ranges of each dependent service at the firewall and keeping them current (LESSON 40 rot class)
and adds latency/timeout risk to the longest create of the build. Posture note recorded in
ADR-047: this exempts APIM PLATFORM dependency traffic from AZFW inspection, not API/workload
traffic.

**(c) Firewall rules for the remaining force-tunneled dependencies:** section 6.

## 6. Firewall RCG delta (platform/connectivity)

New file `firewall_rules_apim.tf`: one
`azurerm_firewall_policy_rule_collection_group` **`rcg-apim-egress-primary`, priority 310**, on
the PRIMARY hub policy only (ADR-044/ADR-009 pattern: nothing in eastus2 routes to the secondary
firewall; a NEW RCG rather than extending rcg-aks-egress-primary because the source prefix,
lifecycle, and review blast radius differ per wave). Gated on `var.enable_firewall` via for_each
(same as the AKS RCG). Source prefix: new variable defaulting to `10.30.1.0/24` (snet-apim).

Application rule collection `apim-egress-app` (priority 100, action Allow), all rules source
10.30.1.0/24:

| Rule | FQDNs | Ports/protocols |
|---|---|---|
| `cert-validation` | `mscrl.microsoft.com`, `crl.microsoft.com`, `oneocsp.microsoft.com`, `cacerts.digicert.com`, `crl3.digicert.com`, `csp.digicert.com` | Http 80, Https 443 |
| `entra-auth` | `login.microsoftonline.com`, `*.login.microsoft.com` | Https 443 |
| `internal-diagnostics` | `azurewatsonanalysis-prod.core.windows.net`, `*.data.microsoft.com`, `azureprofiler.trafficmanager.net`, `shavamanifestazurecdnprod1.azureedge.net`, `shavamanifestcdnprod1.azureedge.net`, `issuer.pki.azure.com` | Https 443 |
| `windows-platform` | `*.update.microsoft.com`, `*.ctldl.windowsupdate.com`, `ctldl.windowsupdate.com`, `download.windowsupdate.com`, `go.microsoft.com` | Http 80, Https 443 |
| `defender` | `wdcp.microsoft.com`, `wdcpalt.microsoft.com` | Https 443 |

Network rule collection `apim-egress-net` (priority 200, action Allow), source 10.30.1.0/24:

| Rule | Destination | Ports/protocol |
|---|---|---|
| `azure-monitor` | service tag `AzureMonitor` | TCP 1886, 443 |
| `ntp` | `*` | UDP 123 (destination `*` keeps firewall DNS proxy OFF - ADR-044 rationale) |
| `kms` | `*` | TCP 1688 (Windows activation for the stv2 platform VMs; port-scoped to keep DNS proxy off, same trade as NTP) |

Deliberate exclusions, each with its reason (mirror as code comments): Storage/Sql/KeyVault/
EventHub tags (service endpoints carry them - rule (b)); developer portal CAPTCHA
`client.hip.live.com`/`partner.hip.live.com` and portal-publish Storage egress (portal not
published at POC); SMTP relay (no email features); `dc.services.visualstudio.com` (portal
diagnostics extension, optional - add later only if troubleshooting needs it);
AzureActiveDirectory as a network tag (covered more tightly by the entra-auth FQDN app rules);
`graph.microsoft.com` (only needed for developer portal Entra sign-in - out of scope).

NSG: **ZERO changes.** The B1 nsg-apim already carries the two required inbound rules (3443
ApiManagement, 6390 AzureLoadBalancer); internal-mode client 443 rides the default
AllowVnetInBound; there are no outbound denies, so the required-outbound table is satisfied at
the NSG layer by the default rules (the firewall is the egress control point). Re-verified
against the 2026-04-30 reference table today - the B1 rules match current requirements exactly.

## 7. Ordering, plan bars, and apply mechanics

**Ordering is hard (ADR-044 class):** connectivity apply (RCG add) FIRST, then bank-app-p1. The
APIM create needs the firewall to pass its force-tunneled dependency traffic mid-provision; a
create against a default-deny firewall will hang toward the 3h timeout and fail. The firewalls
are already live and armed (ADR-045); no IP gate re-check is needed beyond confirming the RCG
apply succeeded. Both flags arrive as reviewed poc.tfvars commits; the ordering is procedural
and operator-guarded (the PC-2K lesson, restated).

Plan bars (pre-clearance refines):

- `platform/connectivity`: EXACTLY 1 add (`rcg-apim-egress-primary`) + standing OQ-032 noise;
  0 destroys, 0 replaces.
- `landing-zones/bank-app-p1`: pure adds ~8-14 (APIM instance, route table, DNS zone + A record
  + 2 links, demo API resource set, telemetry pairs; diagnostics may fold into the module
  count), plus EXACTLY ONE in-place update: the apim subnet (route table swap + service
  endpoints, both on the same subnet object). ZERO destroys, ZERO replaces - the previously
  accepted kubelet RA replace must NOT appear because its fix rides this batch (section 8); if
  it still appears, the fix failed and that is a STOP, not a re-accept. Any spoke_vnet change
  beyond the single apim subnet update is a STOP.

## 8. RIDE-ALONG (MANDATED): kubelet AcrPull RA durable fix (B3 PC-3M disposition)

This batch touches bank-app-p1, so the fix is DUE now. The disposition text, verbatim from
`docs/preclearance/b3-messaging.md` section 4a:

> **Durable fix MANDATED for the next bank-app-p1-touching batch (fix-spec):** decouple the
> RA's principal_id from the module's computed output. Specified form: a
> `data.azurerm_kubernetes_cluster` lookup whose `name`/`resource_group_name` are the ROOT'S
> OWN deterministic strings (NOT module outputs, NO depends_on on the module - either would
> re-defer the read), gated on the same flag, with
> `principal_id = data.azurerm_kubernetes_cluster.<x>.kubelet_identity[0].object_id`
> (attribute verified against azurerm 4.x docs at build). Data sources with static arguments
> resolve at refresh time, so module-internal churn can no longer cascade. Alternative if the
> attribute misbehaves: `data.azurerm_user_assigned_identity` on the deterministic
> `<cluster>-agentpool` UAI in the node RG.

Concrete for this root (deterministic strings, from aks.tf as built):

- data source in `aks.tf` (or `acr.tf`), `for_each = var.enable_kubernetes_platform ? { main = {} } : {}`:
  `name = "aks-bank-app-p1-${var.org_prefix}-${var.environment}"`,
  `resource_group_name = "rg-bank-app-p1-workload-${var.org_prefix}-${var.environment}"`
  (LITERAL interpolations of root variables only - not `azurerm_resource_group.workload.name`,
  not any module output, no depends_on).
- `acr.tf` role_assignments.kubelet_acr_pull: `principal_id =
  data.azurerm_kubernetes_cluster.aks_lookup["main"].kubelet_identity[0].object_id` (replaces
  `module.aks["main"].kubelet_identity.objectId`).
- Expected plan impact: ZERO changes at the RA address (identical value, now plan-time-known).
  The interim one-accepted-replace bar is RETIRED the moment this merges; QA re-verifies the RA
  live (AcrPull, ACR scope, kubelet principal) unchanged post-apply.

## 9. Duration, token posture, and mid-apply-death disposition

- **Expected window:** stv2 Developer internal-mode create historically runs 30-90+ minutes,
  occasionally ~3h. Treat under 2h as normal; investigate only past the 3h provider timeout.
  Post-create infrastructure changes (custom domains, VNet changes) also run 15+ min each -
  another reason APIM config beyond B4 scope is parked.
- **Isolate the apply (LESSON 46):** the bank-app-p1 B4 apply co-locates nothing else
  hour-scale; the connectivity RCG apply is separate and short. No token-lifetime-bound
  operations ride the long apply; the CI OIDC/ARM per-request refresh posture is proven on this
  estate across 90+ runs. GitHub job timeout is the 360 min default (no explicit
  timeout-minutes anywhere - verified) which clears the 3h worst case.
- **Mid-apply death (runner/network death, NOT an ARM error):** state persists per-resource at
  the backend as each create completes, so a rerun plans only the missing tail (proven on this
  estate). TWO branches, disposition BEFORE any retry (standing rule):
  - APIM create had NOT been submitted or ARM rejected it: rerun is a plain short retry.
  - APIM create was IN FLIGHT (ARM accepted, terraform died waiting): the instance keeps
    provisioning server-side and will NOT be in state. Check `provisioningState` live first;
    if Creating, WAIT for terminal state; if Succeeded, `terraform import` into the module
    address (import-based recovery, LESSON 46) - a blind rerun would hit name-in-use.
- **Teardown (designed, not improvised):** APIM rides the spoke destroy; soft-delete purge
  flags (section 3) make destroy-then-rebuild clean. No revocation timing concerns (system MI
  dies with the resource). teardown.yml needs no new root - verify currency only.

## 10. Design-vs-POC split (production targets, documented not deployed)

| Area | POC (B4) | Production design |
|---|---|---|
| Tier / SLA | Developer, 1 unit, NO SLA, no zones | Premium classic, >=2 units, availability zones, 99.99% multi-region active-active (the headline NFR line) |
| Exposure | internal-only, in-VNet consumers | internal gateway fronted by App Gateway WAF (online-p1 pattern) for external APIs; custom domains + KV certificates |
| Identity | system-assigned MI | UAI + CMK, named values from KV, workload-identity backends |
| DNS | scoped gateway zone, single region | per-region scoped zones + Traffic Manager/multi-region routing records; developer portal zone if published |
| APIs | 1 mock health API | product/subscription model, AKS backends via internal LBs, policy-as-code |
| Scale | 1 unit fixed | capacity-unit autoscale + the B10 capacity chapter TU/unit math |

## 11. Cost (approximate list, sprint-day framing per ADR-045)

| Item | $/day |
|---|---|
| APIM Developer (1 unit, ~$48/mo list) | ~$1.6 |
| Private DNS zone (1) | ~$0.02 |
| Firewall data processing delta | negligible at POC traffic |
| **B4 delta** | **~$1.7/day** on top of the ~$125-145/day sprint estate |

## 12. Pre-clearance feed (docs/preclearance/b4-apim.md, before any apply)

1. **Policy matrix:** swept live TODAY at corp + landingzones (section 2): zero Deny members
   target APIM; `ApiManDenyPublicIP` is AuditIfNotExists; Deny-Public-IP is identity-MG-only
   AND moot. Pre-clearance re-confirms nothing drifted, plus one addition: check nothing at any
   ancestor denies SUBNET service-endpoint or route-table changes (none known; the B1/B2 subnet
   writes prove route/NSG changes pass).
2. **RP:** Microsoft.ApiManagement Registered (verified today; re-confirm at apply if slipped).
3. **Quota/offer:** NOT pre-checkable - Microsoft.ApiManagement has no quota API; the ADR-031
   offer-cap class can only surface at PUT. Watch item, not a blocker; the flag pattern
   (LESSON 42) keeps the spoke shippable if a cap bites. Name availability VERIFIED today.
4. **Lifecycle audit (step 3d):** clean today (classic Developer current, stv2 current, no
   retirement; direct-management retired 2025-03 - excluded from design). Re-run the delta if
   the apply slips past 2026-07-25 (ADR-045 re-affirmation date).
5. **Known-issues sweep:** module repo (Azure/terraform-azurerm-avm-res-apimanagement-service)
   open issues + azurerm provider APIM issues, at pre-clearance time; first consumption of this
   module in the estate.
6. **Plan bars:** section 7 verbatim; class-based change bar (B3 precedent) - any non-tag
   attribute change or any destroy/replace = STOP, including the now-retired kubelet RA replace.
7. **QA (feeds the qa-engineer pass):** APIM live: sku Developer_1, platformVersion stv2/stv2.1,
   virtualNetworkType Internal, correct subnet, NO public IP resource in the RG, private VIP in
   10.30.1.0/24; scoped DNS zone + apex A record = private VIP + both links live; effective
   routes on snet-apim show BOTH routes (0/0 -> 10.0.0.4, ApiManagement -> Internet); service
   endpoints live on the subnet; APIM Network Status (Deployment + infrastructure > Network)
   shows all REQUIRED dependencies connected; diag setting -> law-platform; demo API returns
   200 via an in-VNet call - proven ARM-proxied path: `az aks command invoke` curl against
   `https://apim-bank-app-p1-<org>-<env>.azure-api.net/health/ping` (resolves through the
   spoke-linked zone, default `*.azure-api.net` cert is valid); AZFW resource-specific tables
   show apim-egress rule hits from 10.30.1.x (in-boundary query path per B3); kubelet RA
   unchanged and live.
8. Standing gates: single-dispatcher (architect designs, main lane dispatches), sequential
   applies with settle hygiene, one consolidated fix-spec per failure set, QA before green.
