# Wave B3 - Messaging/Eventing Platform (Event Hubs + Service Bus) target design

> **Status:** READY FOR IMPLEMENTATION - OQ-044 RESOLVED (option A: Service Bus Premium 1 MU + PE,
> ADR-046); section 4 is now Shape A only. Design and docs only; no Terraform is written by this
> document. Includes the fix-spec for the B2 QA MEDIUM finding (hub firewall diagnostics) so it rides
> this wave's connectivity-touching batch.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-18.
> **Parent design:** `docs/banking-platform-design.md` section 2.2 / wave B3.
> **Resolved inputs:** OQ-039 (Standard + Waiver posture, Premium as production target - now
> re-opened as OQ-044 under ADR-045), ADR-045 (sprint frame: estate up through the week, EOW
> teardown), B1 (servicebus zone live + linked), B2 (bank-app-p1 live: AKS/ACR green, firewalls up).
> **New records:** ADR-046 (B3 design rulings incl. the OQ-044 = A resolution, which RETIRES the
> OQ-039 Standard+Waiver posture for Service Bus in this build), OQ-044 (RESOLVED 2026-07-18: A).

---

## 0. Executive summary

- B3 lands the eventing backbone in the existing `bank-app-p1` spoke: an **Event Hubs Standard
  namespace (1 TU, PE-only)** and a **Service Bus Premium namespace (1 MU, PE-only - OQ-044
  RESOLVED option A, user, 2026-07-18; the OQ-039 Standard+Waiver posture is retired for SB in
  this build, ADR-046)**. Both flag-gated behind `enable_messaging_platform` (default false,
  LESSON 42). Zero policy exemptions in this wave: every B3 service is compliant by design.
- **No new network surface:** both services private-endpoint into the existing
  `snet-private-endpoints` and share the live, spoke-linked `privatelink.servicebus.windows.net`
  zone (Event Hubs uses the servicebus Private Link domain). No new zones, no new subnets, no new
  firewall rules - PE traffic is in-VNet and never reaches the firewall.
- **Policy shape verified live today:** the corp deny initiative's `eventHubNamespacesPublicNetworkAccess`
  and `serviceBusDisablePublicNetworkAccess` members BOTH default to Deny. Event Hubs Standard
  supports PEs, so it ships public-access-off = compliant by design. Service Bus Standard cannot
  attach PEs, hence the OQ-044 fork (Premium+PE compliant-by-design vs Standard+Waiver exemption).
- **Module reality re-verified today:** `avm-res-eventhub-namespace` is STILL 0.1.0 (single release
  2025-04-28 - the maturity flag stands; input surface is adequate: PEs + zone group, public access
  toggle, local-auth toggle, in-module event_hubs map, diagnostic_settings; fallback to native
  `azurerm_eventhub_namespace` with a `# DEVIATION:` comment remains pre-authorized if it misbehaves
  at build). `avm-res-servicebus-namespace` STILL 0.4.0 (queues/topics maps, PEs, public access,
  local_auth_enabled, min TLS). RPs Microsoft.EventHub + Microsoft.ServiceBus both Registered in the
  landingzones sub (live).
- Both namespaces: AAD-only data plane (local/SAS auth disabled), min TLS 1.2, diagnostics to the
  platform LAW, one tiny demo entity each (1 event hub, 1 queue) so QA has a data-plane surface.
- Cost while the sprint runs: EH ~$0.78/day; SB ~$22.4/day (option A) or ~$0.35/day (option B);
  2 PEs ~$0.48/day. Rounding: **B3 adds ~$2-24/day** depending on OQ-044.
- **Rides along:** the AZFW diagnostics fix (section 6) - 2 diagnostic settings on the live hub
  firewalls to the platform LAW, closing the B2 QA MEDIUM finding and unblocking firewall-log
  evidence for B4+ QA.

---

## 1. Scope and boundary

### In scope (B3)

| Item | Where |
|---|---|
| Event Hubs Standard namespace + 1 demo event hub + PE + diagnostics, flag-gated | `landing-zones/bank-app-p1` (new `messaging.tf`), `enable_messaging_platform` default false |
| Service Bus namespace per OQ-044 (+ 1 demo queue + PE-or-exemption + diagnostics), same flag | same root |
| AZFW diagnostic settings fix (B2 QA MEDIUM finding) | `platform/connectivity` (new `firewall_diagnostics.tf` + 1 variable; section 6) |
| teardown.yml currency for the wave (ADR-045 follow-up; no new root, so expected no-op - verify) | devsecops check |

### Explicitly OUT of B3 (parked)

- APIM (B4), producers/consumers/workloads (application scope), Event Grid, Event Hubs Capture
  (needs a storage target - nothing consumes it), auto-inflate, Dedicated/Premium Event Hubs, SB
  geo-DR pairing and CMK (B9 extends CMK; DR is B10 documentation), SB topics beyond the demo
  queue, Kafka-protocol demos, the NSP/QA query-path fix (LOW finding - routed to devsecops
  separately, not a B3 deliverable).

## 2. Verification log (2026-07-18)

| Claim | How verified |
|---|---|
| avm-res-eventhub-namespace latest STILL **0.1.0** (2025-04-28; single release - maturity flag stands) | Terraform Registry API today |
| avm-res-servicebus-namespace latest STILL **0.4.0** (2025-03-05) | Terraform Registry API today |
| EH 0.1.0 inputs: private_endpoints (+manage_dns_zone_group), public_network_access_enabled, local_authentication_enabled, event_hubs map, sku/capacity, diagnostic_settings, network_rulesets | Registry input schema dump |
| SB 0.4.0 inputs: private_endpoints (+manage_dns_zone_group), public_network_access_enabled, local_auth_enabled, minimum_tls_version, sku/capacity, queues/topics maps, diagnostic_settings, network_rule_config | Registry input schema dump |
| Corp deny initiative members `eventHubNamespacesPublicNetworkAccess` = **Deny** default, `serviceBusDisablePublicNetworkAccess` = **Deny** default (assignment passes no params, defaults govern) | `az policy set-definition show` live today |
| Microsoft.EventHub + Microsoft.ServiceBus **Registered** (landingzones sub) | `az provider show` live today |
| privatelink.servicebus.windows.net zone live in rg-dns + linked to the bank-app-p1 VNet | B1 QA record (app spoke links: aks/acr/servicebus); zone data source already in `dns_links.tf` |
| SB private endpoints require Premium ONLY; EH private link supported on Standard+ | Founding design verification 2026-07-12 (MS Learn); unchanged posture carried |
| Hub firewall module exposes `firewall_resource_ids` output map; NO diagnostic-settings input exists on the firewall config | Module source read (outputs.tf lines 56-59; variables.tf grep) today |
| Connectivity root has NO LAW variable today; CI already injects `TF_VAR_platform_law_workspace_id` for every root | root variables.tf grep + `_tf-root.yml` line 118 today |
| NOT verified (build/pre-clearance): exact EH/SB hourly rates (approximate list carried), EH 0.1.0 runtime behavior (maturity flag - first-ever consumption in this estate), AZFW structured-log category set vs the live API | marked where cited |

## 3. Event Hubs specification (implementer contract)

Module: `Azure/avm-res-eventhub-namespace/azurerm` version = `"0.1.0"` (pin; MATURITY FLAG - if the
module fails at plan/apply on our shape, fall back to native `azurerm_eventhub_namespace` +
`azurerm_eventhub` + `azurerm_private_endpoint` with `# DEVIATION:` per CLAUDE.md rule 5, one
consolidated fix-spec, no improvisation).

| Input | Value | Why |
|---|---|---|
| `name` | `evhns-bank-app-p1-<org>-<env>` | estate naming |
| `resource_group_name` / `location` | shared RG / eastus2 | integration tier co-located with ACR |
| `sku` / `capacity` | `"Standard"` / 1 TU | founding design; PE-capable, cheapest adequate tier |
| `auto_inflate_enabled` | false | POC; production design target documents auto-inflate/TU scale-out |
| `public_network_access_enabled` | **false** | satisfies the Deny member by design |
| `local_authentication_enabled` | **false** | AAD-only data plane (banking bar; SAS off) |
| `event_hubs` | one entry: `evh-demo`, 2 partitions, 1-day retention (module default message retention acceptable) | minimal QA data-plane surface |
| `private_endpoints` | one PE `pe-evhns-bank-app-p1-...` into `snet-private-endpoints`, `private_dns_zone_resource_ids` = [servicebus zone id from the existing `dns_links.tf` data source], module manages the zone group | proven SQL/ACR zone-group pattern |
| `diagnostic_settings` | to `var.platform_law_workspace_id` | estate pattern |
| `managed_identities` | omit at POC | no CMK (B9), nothing consumes an identity yet |

## 4. Service Bus specification (implementer contract - OQ-044 RESOLVED: Shape A, ADR-046)

Module: `Azure/avm-res-servicebus-namespace/azurerm` version = `"0.4.0"` (pin).

| Input | Value | Why |
|---|---|---|
| `name` | `sbns-bank-app-p1-<org>-<env>` | global-DNS namespace - LESSON 27 length/uniqueness check at build |
| `resource_group_name` / `location` | shared RG / eastus2 | integration tier co-located with ACR/EH |
| `sku` / `capacity` | **`"Premium"` / 1** (1 messaging unit) | OQ-044 = A (user, 2026-07-18); production shape at sprint-day cost (~$22.4/day) |
| `premium_messaging_partitions` | 1 | smallest Premium topology; scale-unit math is B10 |
| `public_network_access_enabled` | **false** | satisfies the `serviceBusDisablePublicNetworkAccess` Deny member BY DESIGN - no exemption anywhere in B3 |
| `local_auth_enabled` | **false** | AAD-only data plane (banking bar) |
| `minimum_tls_version` | `"1.2"` | estate bar |
| `queues` | one entry `sbq-demo` (module defaults; no sessions/DLQ tuning) | minimal QA data-plane surface |
| `private_endpoints` | one PE `pe-sbns-bank-app-p1-...` into `snet-private-endpoints`, `private_dns_zone_resource_ids` = [servicebus zone id from `dns_links.tf`], module-managed zone group | proven zone-group pattern; second A record in the shared zone |
| `diagnostic_settings` | to `var.platform_law_workspace_id` | estate pattern |

The RETIRED Shape B (Standard + shared-RG Waiver on the SB member) is preserved in the OQ-044
record only; do NOT build any exemption in this wave. Its latent consumer trap (AKS clients of a
PE-less namespace needing a `*.servicebus.windows.net` firewall app-rule) dies with it.

Both namespaces are pure adds into the live root; nothing touches spoke_vnet/subnets/UDR. The demo
queue and event hub give QA an AAD data-plane check (send/receive via CLI in CI context - subject
to the NSP/QA query-path constraint noted by B2 QA, which does NOT block ARM live-vs-intent
verification).

## 5. Monitoring, egress, and posture notes

- Diagnostics: both namespaces send allLogs-class categories + metrics to the platform LAW
  (module diagnostic_settings; exact category groups verified at build against each module's
  schema).
- **No firewall rule changes needed for B3:** PE data-plane traffic is in-VNet (more-specific
  route); nothing in B3 egresses through the firewall. Any future AKS workload consuming EH/SB
  resolves through the linked servicebus zone to the PEs - still in-VNet, still no firewall rule.
  (The retired Shape B would have broken this property; see the OQ-044 record.)
- Zone-sharing note for QA: the EH and SB(-A) PEs write DISTINCT A records into the SAME
  privatelink.servicebus.windows.net zone (one per namespace FQDN). Verify both.

## 6. RIDE-ALONG FIX-SPEC: hub firewall diagnostic settings (B2 QA MEDIUM finding)

Finding: neither hub firewall has ANY diagnostic setting - no AZFW logs reach the LAW, blocking
firewall-log evidence for all future waves (B4 forced-tunneling checks, egress QA).

Spec (platform/connectivity, new file `firewall_diagnostics.tf`):
1. New variable `platform_law_workspace_id` (string, description citing the finding + LESSON 43
   note that diagnostic settings are cross-region-safe unlike Traffic Analytics). CI already
   injects `TF_VAR_platform_law_workspace_id` for every root (verified today) - ZERO CI change.
2. One `azurerm_monitor_diagnostic_setting` per hub, `for_each = var.enable_firewall ?
   module.hub_and_spoke.firewall_resource_ids : {}` (output verified in the pinned module source,
   outputs.tf; map keyed primary/secondary) - gating means the EOW re-gate/teardown drops them
   automatically, and the resource dies with its firewall.
3. `name = "diag-fw-<key>-<org>-<env>"`, `target_resource_id = each.value`,
   `log_analytics_workspace_id = var.platform_law_workspace_id`,
   `log_analytics_destination_type = "Dedicated"` (AZFW structured logs land in
   resource-specific tables - the current MS-recommended mode), enabled log **category group
   `allLogs`** + metric `AllMetrics`. Implementer confirms the provider argument names on azurerm
   4.71.0 at build (`enabled_log { category_group = "allLogs" }` block form) - category-group form
   avoids hardcoding the AZFW category list (LESSON 40 rot class).
4. Plan impact when it rides B3: connectivity plan gains EXACTLY 2 adds (both diagnostic
   settings) + the standing OQ-032 noise; zero destroys/replaces. Ingestion cost at POC traffic:
   negligible-to-small; firewall logs are the point of having the firewall up (ADR-045).
5. QA follow-up: AZFWApplicationRule/AZFWNetworkRule tables populate within ~10-15 min of the
   next egress traffic; the B2 FQDN-tag hit check can then be re-run as a table query instead of
   the portal log view.

## 7. Design-vs-POC split (production targets, documented not deployed)

| Area | POC (B3) | Production design |
|---|---|---|
| Service Bus | OQ-044 shape | Premium >=2 MU, zone redundant, geo-DR paired namespace, CMK, IP rules empty + PE-only |
| Event Hubs | Standard 1 TU, 1 hub | Auto-inflate or Dedicated/PU-based, Capture to ADLS, schema registry, multi-consumer-group topology |
| Auth | AAD-only, no SAS | same, plus workload-identity federated producers/consumers from AKS |
| Throughput | none demonstrated (no load - ADR-036 stance) | scale-unit math in the B10 capacity chapter (TU/PU/MU tables) |

## 8. Cost (approximate list, sprint-day framing per ADR-045)

| Item | $/day |
|---|---|
| Event Hubs Standard 1 TU | ~$0.78 |
| Service Bus Premium 1 MU (OQ-044 = A) | ~$22.4 |
| 2 private endpoints | ~$0.48 |
| AZFW diag ingestion | small, traffic-dependent |
| **B3 delta** | **~$24/day** on top of the ~$100/day sprint estate (~$110-170 to the EOW teardown) |

## 9. Pre-clearance feed (docs/preclearance/b3-messaging.md, before any apply)

1. Policy: members re-verified live TODAY (both Deny-by-default; BOTH namespaces compliant by
   design under OQ-044 = A - zero exemptions in this wave). No other corp/landingzones member
   targets EH/SB namespace creates (Enforce-GR-EventHub0 and Enforce-GR-ServiceBus0 both
   DoNotEnforce, re-verified in the B2 enumeration).
2. RPs: EventHub + ServiceBus Registered (done today, re-confirm at apply if slipped).
3. No compute quota surface; namespace names are global-DNS (collision check at plan).
4. Known-issues sweep on both module repos at pre-clearance time (EH 0.1.0 gets a full sweep -
   first consumption of a maturity-flagged module in this estate; fallback pre-authorized).
5. Plan bars (previewed; pre-clearance refines): bank-app-p1 = pure adds ~10-16 (2 namespaces + 1
   hub + 1 queue + 2 PEs + 2 diags + telemetry pairs; NO exemption, NO sleep), ZERO spoke_vnet
   changes, 0 destroys/replaces. platform/connectivity = EXACTLY 2 adds (firewall diags) + OQ-032
   noise, 0 destroys/replaces.
6. Standing gates: PC-1-style code identity, sequential applies, JIT/settle window, QA
   live-vs-intent before green (subject to the NSP query-path note).
7. Lifecycle clock: audit current as of today; re-run the delta if applies slip past 2026-07-25
   (aligned with the ADR-045 re-affirmation date).
