# Pre-clearance: wave B3 messaging platform (landing-zones/bank-app-p1 messaging tier + platform/connectivity AZFW diagnostics ride-along)

> Artifact of the mandatory deploy pre-clearance gate. Covers TWO short applies: (1) the AZFW
> diagnostics fix on platform/connectivity (B2 QA MEDIUM finding; 2 pure adds onto the live
> firewalls) and (2) the messaging tier on landing-zones/bank-app-p1 (EH Standard + SB Premium,
> both PE-only, pure adds into the live B2 root).
> Prerequisite state verified: B2 GREEN (firewalls live on 10.0.0.4/10.1.0.4, AKS/ACR QA-passed),
> B3 batch merged to banking @ 3869f80 (reviewer APPROVE, zero findings; EH diagnostics DEVIATION
> verified true against the 0.1.0 module source), poc.tfvars carries `enable_messaging_platform =
> true` + `enable_firewall = true` (ADR-045 sprint frame).
> Prepared by: architect. Date: 2026-07-18.
> Evidence: merged code read at 3869f80 (messaging.tf, firewall_diagnostics.tf, variables/tfvars
> deltas); live az CLI today: EventHub + ServiceBus RP registration, corp deny-initiative member
> defaults, BOTH namespace names checked available (global DNS), snet-private-endpoints IP usage,
> servicebus private-DNS zone A-record inventory; Terraform Registry pin re-verification (EH
> 0.1.0 / SB 0.4.0 still latest); design doc docs/b3-messaging-platform-design.md section 9 feed
> executed item by item.

## Verdict: GO-conditional. Four numbered preconditions. No code defect found, no new OQ.

Unlike B2 there is NO hard inter-apply ordering dependency: the diag settings and the namespaces
are independent (order chosen for hygiene, not correctness). The conditions are the standing
gates.

| # | Precondition | Lane | Blocks |
|---|---|---|---|
| PC-1M | Code identity: dispatch both applies from `banking` at a commit whose `platform/connectivity/**`, `landing-zones/bank-app-p1/**`, and `envs/poc.tfvars` content is IDENTICAL to 3869f80 (diff-empty check). | devsecops | both applies |
| PC-2M | SEQUENTIAL dispatch (not concurrent): the two roots are independent, but single-target runs each manage the JIT state-SA window + ADR-025 settle gate; run connectivity (2-add diag fix) first, then bank-app-p1. | devsecops | second apply |
| PC-3M | Plan-scan BOTH refreshed apply plans against the section 4 bars. The CHANGE bar is CLASS-based, not count-based (the 4a/4b lesson): any count of changes is acceptable IFF 100% attribute to the OQ-032 CreatedDate + modtm/azapi computed-output noise class; ONE non-tag attribute change, or ANY destroy or `-/+ replace`, = STOP, consolidated architect disposition (LESSON 26/59). | devsecops + architect scan | each apply |
| PC-4M | Post-apply QA before green: section 5 checklist (both zone A records, AAD-only data-plane probes, AZFW tables populating, gated-off absences). | qa-engineer | wave green |

---

## 1. Live policy matrix delta: CLEAR, zero exemptions in this wave

Carried from the B2 enumeration (2026-07-18, same day - no re-pull needed; no MG writer has run
since) plus the member-level dump for the new classes:

| Scope / assignment | B3 disposition |
|---|---|
| corp `Deny-Public-Endpoints` | `eventHubNamespacesPublicNetworkAccess` default **Deny** and `serviceBusDisablePublicNetworkAccess` default **Deny** (member dump, live 2026-07-18). BOTH satisfied BY DESIGN: each namespace ships `public_network_access_enabled = false` (SB can, because Premium attaches a PE - the OQ-044 shape A point). NO exemption unit exists or is needed anywhere in B3. |
| corp `Deploy-Private-DNS-Zones` (DINE) / `Audit-PeDnsZones` | Both PEs arrive WITH module-managed zone groups against the central servicebus zone - DINE finds them compliant or no-ops; never blocks. |
| landingzones `Enforce-GR-EventHub0`, `Enforce-GR-ServiceBus0` | DoNotEnforce (re-verified in the B2 per-scope dump). Clear. |
| landingzones `Deny-Subnet-Without-Nsg`, `Deny-MgmtPorts-Internet`, `Deny-Storage-http`, `Deny-IP-forwarding` | No subnets, NSG rules, storage, or NICs created by B3 (PE NICs are Microsoft-managed PE NICs, not IP-forwarding NICs). Clear. |
| globaris `tag-governance-globaris` (Modify) | Fires on all creates; proven non-blocking 4 waves running. OQ-032 drift noise expected on later plans. |
| Connectivity chain (diag apply) | Diagnostic settings are a Microsoft.Insights child PUT on the firewalls; no deny on the connectivity chain targets them (B0b/B2 enumerations). Clear. |

## 2. Tenant/subscription prerequisites: PASS (live 2026-07-18)

- **RPs:** Microsoft.EventHub **Registered**, Microsoft.ServiceBus **Registered** (landingzones sub).
- **Namespace names (global DNS):** `az servicebus namespace exists` AND `az eventhubs namespace
  exists` both return **available** for the exact rendered names. No collision.
- **PE subnet capacity:** snet-private-endpoints 10.30.2.0/24 has **2 of ~251** usable IPs consumed
  (the ACR PE NIC's two IP configs). B3 adds 2 PE NICs - trivial headroom.
- **Zone A-record collision check (two namespaces, one shared zone):**
  privatelink.servicebus.windows.net currently holds **ZERO A records** (live listing). The two
  zone groups write DISTINCT records (`evhns-...` and `sbns-...`) - no overlap possible, and QA
  verifies exactly 2 records post-apply.
- **SB Premium capacity in eastus2:** no ARM API exposes messaging-unit availability pre-create;
  Premium is GA in eastus2 (mainstream region). Carried as a watch-item (section 6), NOT a
  blocker - a capacity failure surfaces as a clean create error with no partial state beyond the
  namespace itself.
- **Quota:** namespaces consume no Compute vCPU quota; no other quota family applies. The B2
  snapshot (24 total vCPUs) is untouched by B3.
- **Flags:** `enable_messaging_platform = true` + `enable_firewall = true` confirmed present in
  the merged poc.tfvars (lines 196/210).

## 3. Module pins, known-issues, lifecycle: CLEAR with the standing EH maturity flag

- **Pins (re-verified latest on the registry today):** avm-res-eventhub-namespace **0.1.0**
  (MATURITY FLAG - single release 2025-04-28; TWO of its quirks are already neutralized in the
  merged code: the type-required-but-ignored `namespace_name`/`resource_group_name` on the
  event_hubs map, and the declared-but-never-consumed `diagnostic_settings` input, worked around
  with the native `# DEVIATION:` diagnostic setting - both verified against the 0.1.0 tag source
  by the reviewer); avm-res-servicebus-namespace **0.4.0** (in-module diagnostics verified
  implemented). Provider lock unchanged (azurerm 4.71.0 / azapi 2.11.0); `enabled_log`/
  `enabled_metric` block forms verified against 4.71.0.
- **Known-issues:** EH/ACR-class repo sweeps done at design time (2026-07-18): EH repo has no
  open issue on the namespace/PE path (the two found quirks are the flag's substance); SB repo
  clean. No new sweep needed same-day.
- **Lifecycle:** audited in the design doc today (Standard EH + Premium SB current tiers, PE
  patterns current). Clock: re-run the delta if applies slip past **2026-07-25** (ADR-045
  re-affirmation date).
- **LESSON 63 recorded** (from this batch's review): stale local `.terraform` backend pointers
  forge state-SA 403s; delete + re-init before diagnosing RBAC/firewall. CI unaffected (fresh
  checkouts).

## 4. Plan-shape bars (PC-3M)

**Apply 1 - platform/connectivity (live firewalls -> +2 diagnostic settings):**
`Plan: EXACTLY 2 to add` - `azurerm_monitor_diagnostic_setting.firewall["primary"|"secondary"]`,
each with category group allLogs + AllMetrics, destination type Dedicated, target = the live
firewall ids, workspace = platform LAW. Changes: any count IFF 100% OQ-032/computed-output noise
class (post-B2 the tag-Modify re-injected CreatedDate on everything the B2 apply PUT, so a
three-digit change count is EXPECTED and fine; one non-tag attribute change = STOP).
**0 destroys, 0 replaces** - any firewall/policy/RCG/VNet mutation beyond tags is a STOP.

**Apply 2 - landing-zones/bank-app-p1 (live B2 root -> messaging tier):**
`Plan: ~11-15 to add` (exact set, count varies only by per-module telemetry pairs):
- module.event_hubs["main"]: 1 EH namespace (Standard, capacity 1, public access FALSE, local
  auth FALSE), 1 event hub `evh-demo` (2 partitions, 1-day retention), 1 private endpoint into
  snet-private-endpoints w/ zone group -> servicebus zone, + telemetry pair.
- 1 NATIVE `azurerm_monitor_diagnostic_setting.event_hubs["main"]` (the DEVIATION).
- module.service_bus["main"]: 1 SB namespace (**Premium, capacity 1, partitions 1**, public
  access FALSE, local auth FALSE, TLS 1.2), 1 queue `sbq-demo`, 1 private endpoint w/ zone group
  -> same zone, 1 in-module diagnostic setting, + telemetry pair.
Changes: same class-based bar as apply 1 (the B2-era 12-change noise shape may persist).
**Zero-tolerance:** ANY destroy or replace; ANY change/mutation on module.spoke_vnet, module.aks,
module.acr, or the UAI/role assignments beyond tag noise; ANY policy exemption or time_sleep in
the plan (shape A has none - an exemption appearing means wrong code); ANY PIP/NSG/subnet/route
resource; a THIRD private endpoint.

### 4a. PC-3M disposition, apply 2 (plan run 29662551030): APPROVED WITH ONE ACCEPTED REPLACE + a mandated durable fix

Recorded shape `13 add, 18 change, 1 destroy`. Adds: all 13 exact-match the bar, zero
exemptions/sleeps. Changes: noise-class, zero non-tag attributes. The STOP item:
`module.acr["main"].azurerm_role_assignment.this["kubelet_acr_pull"]` forced replace, cause
`principal_id -> (known after apply)`.

**Root cause (architect-confirmed):** the RA's principal_id is wired to
`module.aks["main"].kubelet_identity.objectId`, an azapi `response_export_values` computed
output. Whenever the AKS module has ANY pending change (including pure tag-noise plans), its
computed outputs defer to known-after-apply and cascade a ForceNew replace into a perfectly
valid role assignment. This is a plan-graph artifact, not drift: the kubelet identity objectId
is stable for the cluster's life, so the RA is recreated with IDENTICAL values.

**Disposition (LESSON 59, one unit):**
1. **ACCEPT this single replace for apply 2.** The momentary AcrPull gap during
   destroy-then-create has zero impact: no workload pulls from this ACR (B2 deployed no pods;
   system pods pull from MCR through the firewall path). LESSON 26's replace-STOP is satisfied
   by this disposition: no posture regression, no deprecation-blocked recreate.
2. **Durable fix MANDATED for the next bank-app-p1-touching batch (fix-spec):** decouple the
   RA's principal_id from the module's computed output. Specified form: a
   `data.azurerm_kubernetes_cluster` lookup whose `name`/`resource_group_name` are the ROOT'S
   OWN deterministic strings (NOT module outputs, NO depends_on on the module - either would
   re-defer the read), gated on the same flag, with
   `principal_id = data.azurerm_kubernetes_cluster.<x>.kubelet_identity[0].object_id`
   (attribute verified against azurerm 4.x docs at build). Data sources with static arguments
   resolve at refresh time, so module-internal churn can no longer cascade. Alternative if the
   attribute misbehaves: `data.azurerm_user_assigned_identity` on the deterministic
   `<cluster>-agentpool` UAI in the node RG.
3. **Interim bar amendment:** until the fix lands, ANY bank-app-p1 plan may carry EXACTLY this
   one replace (this address, this cause). Plan scans treat it as a known-accepted deviation,
   narrowly scoped; a replace at any other address, or this address with any other cause, stays
   a full STOP.
4. **PC-4M addition:** post-apply, QA verifies the recreated RA is live (AcrPull, ACR scope,
   kubelet identity principal) - the replace must land, not just plan.

## 5. QA checklist (PC-4M, feeds the qa-engineer pass)

1. Both namespaces live in the shared RG: EH Standard/1TU, SB **Premium/1MU/1 partition**; both
   `publicNetworkAccess: Disabled`, local auth disabled, SB minimumTlsVersion 1.2.
2. privatelink.servicebus.windows.net holds EXACTLY 2 A records (evhns-... and sbns-...), each
   resolving to its PE IP in 10.30.2.0/24; both PE connections Approved.
3. Data-plane: AAD-authenticated send/receive probe to evh-demo and sbq-demo from a sanctioned
   context (CI; the NSP KQL constraint from B2 QA does not block ARM checks - data-plane probe is
   best-effort if the NSP also bites the runner, record could-not-verify honestly).
4. AZFW: diag-fw-primary + diag-fw-secondary exist on the firewalls; AZFWApplicationRule /
   AZFWNetworkRule resource-specific tables receive rows within ~10-15 min of egress traffic
   (re-run the B2 FQDN-tag check as a table query - this CLOSES the B2 MEDIUM finding).
5. Gated-off absences: no exemption on the shared RG, no third PE, no SAS rules created.
6. JIT state-SA window re-closed after each run.

## 6. Watch-items during the applies (dispositions pre-agreed)

| Symptom | Disposition |
|---|---|
| SB Premium create fails on regional capacity | Clean failure class: STOP, architect disposition (options: retry later, or capacity in a paired region is NOT an option under the single-region B3 design - do not improvise a region change). No partial-state risk beyond the namespace resource itself. |
| EH 0.1.0 module errors at plan/apply on our shape | The pre-authorized fallback fires: ONE consolidated fix-spec swapping module.event_hubs for native azurerm_eventhub_namespace + azurerm_eventhub + azurerm_private_endpoint w/ `# DEVIATION:` (design doc section 3). Do not patch the module inline. |
| Diagnostic setting PUT rejects category group allLogs or Dedicated mode for a resource type | Architect disposition: fall back to enumerated categories for THAT resource only, cited from the live `az monitor diagnostic-settings categories list` output - never guess the list (LESSON 40). |
| PE stuck Pending / zone-group record absent | PE approval is auto (same-tenant, no manual-approval flow configured); a Pending PE = STOP and inspect, do not approve by hand and mask a config defect. |
| SB/EH namespace name 409 at apply | Impossible per today's availability check unless raced externally; STOP, re-check availability, single rerun. |
| Local init 403 against the state SA (any operator doing local work) | LESSON 63: delete `.terraform`, re-init, THEN diagnose. |
| Post-apply plan CreatedDate drift | OQ-032 accepted. |
| Stale state lease / settle-gate flap | Standing runbook (CI force-unlock w/ lock id; ADR-025 gate; recurrence escalates). |

## 7. Duration / token: NON-ISSUE

Apply 1: ~5-10 min (2 diag PUTs + refresh of the large connectivity state is the long pole).
Apply 2: ~10-20 min (SB Premium namespace create ~5-10 min is the long pole; EH ~2-4 min; PEs +
zone groups minutes). No hour-scale creates (LESSON 46 n/a). Sequential per PC-2M.

## Ordered execution runbook

1. PC-1M diff-empty check vs 3869f80; dispatch `deploy.yml` `target=platform/connectivity`
   `action=apply` from `banking`.
2. PC-3M scan (bar section 4 apply 1: exactly 2 adds). Apply green.
3. Dispatch `target=landing-zones/bank-app-p1` `action=apply`. PC-3M scan (bar apply 2). Apply
   green.
4. PC-4M qa-engineer pass (section 5), incl. closing the B2 MEDIUM finding via the AZFW table
   query. WORKLOG green-marking.

## Hand-off notes

- B3 adds no new root: teardown.yml already covers both touched roots (ADR-045 currency
  requirement satisfied as a no-op - devsecops confirms, no change expected).
- B4 re-entry items unchanged (APIM stv2 forced-tunneling route verification; ApiManagement deny
  member is AuditIfNotExists only; APIM long-create isolation per LESSON 46 class).
- The NSP/QA KQL query-path item (B2 LOW finding) remains open with devsecops - PC-4M item 3
  records could-not-verify honestly if it bites.
- EOW closeout (ADR-045): both namespaces die with the spoke in the standing teardown; the diag
  settings die with the firewalls on re-gate. Nothing in B3 adds a soft-delete/purge class.
