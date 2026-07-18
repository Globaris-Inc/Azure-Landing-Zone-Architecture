# Wave B2 - Kubernetes Platform (AKS + ACR) target design

> **Status:** READY FOR IMPLEMENTATION. OQ-042 RESOLVED (option a, time-boxed firewall sprint - ADR-044)
> and OQ-043 RESOLVED (quota increase filed now, new-sub fallback carried). Section 6 is now the egress
> ruling + firewall-rules delta spec + wave runbook. Design and docs only; no Terraform is written by
> this document.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-18.
> **Parent design:** `docs/banking-platform-design.md` section 2.1 (this doc refines and partially
> supersedes it - see ADR-043).
> **Resolved inputs:** OQ-036 (resource module, 3 nodes AZ-spread, Standard tier), OQ-035 (landingzones
> sub placement, quota-gated), ADR-042 (firewall gated off; B2 userDefinedRouting is a recorded re-enable
> trigger).
> **Landing root:** `landing-zones/bank-app-p1` (live and QA-green since 2026-07-18: VNet 10.30.0.0/16,
> snet-aks-nodes 10.30.0.0/24, snet-private-endpoints 10.30.2.0/24, aks + acr private DNS zones linked).
> **New records:** ADR-043 (design rulings), OQ-042 (outbound/firewall fork - USER DECISION),
> OQ-043 (vCPU quota ceiling disposition - USER DECISION).

---

## 0. Executive summary

- B2 lands a **private AKS cluster (Standard tier, 3 nodes across zones 1-3) plus a Premium ACR with a
  private endpoint** in the existing `bank-app-p1` spoke, consuming the subnets, DNS links, and firewall-IP
  contract B1 already shipped. Both are flag-gated (default false) per the LESSON 42
  shippable-network-only rule.
- **Quota reality forced one supersession:** every v5 VM family in the landingzones sub is offer-capped at
  **0** in eastus2. The founding design's "general purpose v5" node family is dead in this sub. B2 moves
  to **Standard_D2s_v4** (DSv4 family, 10 vCPU cap, zones 1-3, no SKU restrictions - all live-verified
  2026-07-18). 3 nodes = 6 of the sub's **10 total regional vCPUs**; the sub is effectively full after B2,
  which collides with wave B5 Databricks - dispositioned in OQ-043.
- **Egress RULED (OQ-042 resolved 2026-07-18, user):** option (a), `outboundType = userDefinedRouting`
  with `enable_firewall = true`, explicitly TIME-BOXED - the user costs the ADR-042 firewall pair at the
  hourly rate (~$3.5/hr both hubs), stands the full landing zone up, and re-gates or tears down by end
  of day (ADR-044). The both-hubs flag stands unchanged. The spoke's existing 0.0.0.0/0 -> 10.0.0.4 UDR
  stays exactly as B1 shipped it and becomes live the moment the firewall returns. Section 6 carries the
  firewall-policy rules delta (the ADR-009 policies were authored pre-AKS and hold zero allow rules) and
  the wave ordering runbook.
- Everything else is ruled by ADR-043: CNI Overlay with pod CIDR 192.168.0.0/16 (ratified) and service
  CIDR **pinned to 172.20.0.0/16** (the AKS default 10.0.0.0/16 collides with the primary hub - landmine),
  private API server on the existing shared `privatelink.eastus2.azmk8s.io` zone via a pre-created
  user-assigned identity, Entra-only auth with Azure RBAC and local accounts disabled, OIDC issuer +
  workload identity on, Container Insights + control-plane diagnostics to the platform LAW, single system
  pool (user pools are quota-blocked), no GitOps/Flux at B2.
- Estimated B2 run-rate delta (option b egress): **~$400-460/mo** (~$73 control plane + ~$210 nodes +
  ~$55 OS disks + ~$50 ACR Premium + ~$7 PE + LB/PIP). Defender for Containers adds roughly $40/mo
  (approximate, re-verified at pre-clearance).

---

## 1. Scope and boundary

### In scope (B2)

| Item | Where |
|---|---|
| AKS private cluster, flag-gated | `landing-zones/bank-app-p1` (new `aks.tf`), `enable_kubernetes_platform` default false |
| ACR Premium + private endpoint, same flag | `landing-zones/bank-app-p1` (new `acr.tf`) |
| Control-plane UAI + role assignments (DNS zone, network RG, AcrPull) | same root |
| Container Insights + control-plane diagnostic settings to platform LAW | same root |
| Defender for Containers plan flip | `platform/security` (existing pricing map; plan-scan mandatory, LESSON 26 / ADR-035 ForceNew-subplan class) |
| Firewall re-enable (`enable_firewall = true` in poc.tfvars) + AKS egress rule collection group | `platform/connectivity` (new `firewall_rules_aks.tf`; section 6) |

### Explicitly OUT of B2 (parked, no speculative build)

- Any application workload, Helm release, or Kubernetes manifest.
- APIM (B4) and the eventing tier (B3).
- **GitOps/Flux ruled OUT** (ADR-043): the AKS Flux extension has nothing to reconcile until a workload
  exists; revisit at the first workload wave.
- Ingress controller / App Gateway for Containers, user node pools (quota-blocked, see OQ-043), cluster
  autoscaler (bounded to nothing by the 10-vCPU cap), managed Prometheus/Grafana (B7 O&M candidate),
  Backup for AKS, image signing/admission policy, ACR geo-replication and CMK, the centralus DR cluster
  (design-only per the POC-vs-design split).

---

## 2. Verification log (all items checked 2026-07-18 unless noted)

| Claim | How verified |
|---|---|
| `Azure/avm-res-containerservice-managedcluster/azurerm` latest is **0.6.7** (2026-06-24) - unchanged since the founding design | Terraform Registry API |
| Module 0.6.7 is **azapi-based** (azapi_resource ManagedCluster); requires terraform >= 1.11, azapi ~> 2.9, azurerm >= 4.46 < 5 | Registry API module metadata (B1 lock: azurerm 4.71.0 + azapi 2.11.0 - compatible) |
| Module inputs exist for every lever this design pulls: `network_profile` (network_plugin, network_plugin_mode, pod_cidr, service_cidr, dns_service_ip, outbound_type, nat_gateway_profile, load_balancer_profile), `api_server_access_profile` (enable_private_cluster, enable_private_cluster_public_fqdn, private_dns_zone), `sku` (name Base, tier Free/Standard/Premium), `oidc_issuer_profile`, `security_profile.workload_identity`, `aad_profile` (enable_azure_rbac, admin_group_object_ids), `disable_local_accounts`, `managed_identities.user_assigned_resource_ids`, `default_agent_pool` (count_of, availability_zones), `addon_profile_oms_agent`, `diagnostic_settings`, `node_resource_group`, `auto_upgrade_profile` | Registry API input schema dump |
| `Azure/avm-res-containerregistry-registry/azurerm` latest is **0.5.1** (2026-01-15); inputs cover sku, public_network_access_enabled, zone_redundancy_enabled, network_rule_bypass_option, private_endpoints (+ manage_dns_zone_group), role_assignments, diagnostic_settings | Terraform Registry API |
| `Azure/avm-res-network-natgateway/azurerm` exists, latest **0.3.2** (option c only) | Terraform Registry API |
| **Quota, sub <subscription-id> (landingzones), eastus2:** Total Regional vCPUs limit **10** (0 used); ALL v5 families (DSv5, Dv5, DASv5, DADSv5, DDSv5, ESv5, Ev5, ...) limit **0**; DSv4 / DDSv4 / DASv4 / Dv4 / DSv3 / Dv3 / BS families limit **10** each | `az vm list-usage` live, 2026-07-18 |
| Standard_D2s_v4 (and D2ds_v4 / D2as_v4 / D2s_v3) available in eastus2 **zones 1,2,3 with NO restrictions** in this sub - no SQL-style ProvisioningDisabled on compute | `az vm list-skus` live, 2026-07-18 |
| CNI lifecycle: **kubenet retires 2028-03-31**; Azure CNI Overlay is the current default and recommended plugin for new clusters - this design's overlay choice is current-generation | Microsoft Learn, web search 2026-07-18 |
| AKS Standard tier ~$0.10/cluster/hr (~$73/mo), 99.95% API SLA with AZs | Microsoft Learn + Azure pricing, web search 2026-07-18 |
| A UDR 0.0.0.0/0 to a VirtualAppliance **overrides a NAT gateway** attached to the same subnet - option (c) also requires the blackhole route scoped away | Microsoft Learn AKS NAT gateway / egress docs, web search 2026-07-18 |
| ACR private endpoints require **Premium** (unchanged) | Microsoft Learn, web search 2026-07-18 |
| privatelink.eastus2.azmk8s.io + privatelink.azurecr.io zones live in rg-dns and linked to the bank-app-p1 VNet | B1 QA PASS record (WORKLOG 2026-07-17/18); zone lookups already in `dns_links.tf` |
| NOT verified (owned by build/pre-clearance): exact D2s_v4 hourly rate, Defender for Containers per-vCore rate, module output name for the kubelet identity, `use_aad_auth` DCR side-requirements, CI SP rights to create role assignments at the connectivity-sub zone scope | marked where cited |

---

## 3. Cluster specification (implementer contract)

Root: `landing-zones/bank-app-p1`. New files `aks.tf` (+ `acr.tf`), all resources gated on
`var.enable_kubernetes_platform` (bool, default **false**; flipped via `envs/poc.tfvars` at the B2 apply,
estate flag pattern per ADR-015/LESSON 42). Cluster lands in the existing `workload` RG; ACR in `shared`.

Module: `Azure/avm-res-containerservice-managedcluster/azurerm` version = `"0.6.7"` (pin).

| Input | Value | Why |
|---|---|---|
| `name` / `dns_prefix` | `aks-bank-app-p1-<org>-<env>` / same | estate naming |
| `parent_id` | workload RG resource id | azapi parent pattern |
| `sku` | `{ name = "Base", tier = "Standard" }` | OQ-036 resolution (SLA-backed) |
| `kubernetes_version` | omit (AKS default GA) | POC; `auto_upgrade_profile` = patch channel + NodeImage node OS channel (implementer verifies exact field names in module docs) |
| `default_agent_pool` | name `systempool`, `count_of = 3`, `vm_size = "Standard_D2s_v4"`, `availability_zones = ["1","2","3"]`, autoscaling OFF, upgrade max_surge 1, managed OS disk | OQ-036 (3 nodes AZ-spread); ADR-043 supersedes v5 -> v4 (quota); surge 1 keeps upgrades at 8/10 vCPUs |
| user pools | NONE at POC | 10-vCPU ceiling (OQ-043); system pool runs POC workloads untainted; pools are a production design target |
| `network_profile` | `network_plugin = "azure"`, `network_plugin_mode = "overlay"`, `pod_cidr = "192.168.0.0/16"` (ratified), **`service_cidr = "172.20.0.0/16"`, `dns_service_ip = "172.20.0.10"`** (pinned - the AKS default service CIDR 10.0.0.0/16 COLLIDES with the primary hub 10.0.0.0/16; leaving it default would break routing from pods/nodes to every hub service), `load_balancer_sku = "standard"`, **`outbound_type = "userDefinedRouting"`** (OQ-042 resolution, ADR-044; firewall MUST be live first - section 6.4 ordering) | ADR-043/044; landmine pin |
| `api_server_access_profile` | `enable_private_cluster = true`, `enable_private_cluster_public_fqdn = false`, `private_dns_zone` = resource id of the shared `privatelink.eastus2.azmk8s.io` zone (already read by `data.azurerm_private_dns_zone.linked["aks"]`) | private cluster on the estate's central zone; hub + spoke links already live so hub-side resolution works |
| `managed_identities` | `user_assigned_resource_ids = [uai-aks id]` | BYO private DNS zone REQUIRES a user-assigned control-plane identity with rights on the zone |
| `aad_profile` | `managed = true`, `enable_azure_rbac = true`, `admin_group_object_ids = [var.aks_admin_group_object_ids]`, tenant id | Entra-only auth |
| `disable_local_accounts` | `true` | banking bar; static credentials off |
| `oidc_issuer_profile` | `{ enabled = true }` | workload identity federation (founding design 2.7) |
| `security_profile` | `workload_identity = { enabled = true }` | same |
| `addon_profile_oms_agent` | enabled, `log_analytics_workspace_resource_id = var.platform_law_workspace_id` (eastus2, region-matched, LESSON 43); `use_aad_auth` - implementer verifies whether the module wires the required DCR when true; if not, `false` with a comment | Container Insights |
| `diagnostic_settings` | control-plane categories `kube-apiserver`, `kube-audit-admin` (NOT full kube-audit - volume), `guard`, `cluster-autoscaler` to the platform LAW | estate diagnostics pattern; audit trail |
| `node_resource_group` | `rg-bank-app-p1-aks-nodes-<org>-<env>` | deterministic naming for QA/policy checks |

### Pre-created identity + RBAC (same root, ordered BEFORE the cluster)

1. `azurerm_user_assigned_identity` `uai-aks-bank-app-p1-<org>-<env>` in the workload RG.
2. Role assignments (each followed by a `time_sleep` of 300s before cluster create - RBAC propagation is
   the LESSON 35 timing class; a fresh assignment 403s at create otherwise):
   - **Private DNS Zone Contributor** for the UAI at the `privatelink.eastus2.azmk8s.io` zone scope
     (connectivity sub, `azurerm.connectivity` alias). Required for BYO-zone private clusters - the
     control plane writes the API server A record itself (this is NOT a PE zone-group; the zone-group
     pattern applies to ACR below).
   - **Network Contributor** for the UAI at the `rg-bank-app-p1-network` RG scope (covers the VNet,
     subnets, AND the route table - the route table grant is required when outbound_type is
     userDefinedRouting; RG scope covers all modes with one assignment).
3. **AcrPull** for the cluster kubelet identity at the ACR scope, after cluster create (implementer
   verifies the module's kubelet-identity output name at build; if not surfaced, look it up via the
   cluster resource).
4. Pre-clearance item: the CI SP must be able to PUT role assignments at the connectivity-sub zone scope
   (UAA scope check - B1 proved cross-sub DNS-link writes, NOT role-assignment writes).

### Networking notes

- CNI Overlay pod CIDR 192.168.0.0/16 is non-routed (NATed at node) and overlaps nothing in the estate
  (all 10.x + 172.20 service CIDR). ~250 usable node IPs in snet-aks-nodes 10.30.0.0/24 - ample.
- The private-endpoints subnet, NSGs, flow log, and DNS links need NO change for B2.
- Egress wiring depends on OQ-042; whichever option is chosen, the plan-scan bar for the spoke is
  **adds + in-place subnet updates only, zero VNet replaces** (subnets are standalone resources in
  avm-res-network-virtualnetwork - same invariant as ADR-042).

---

## 4. ACR specification

Module: `Azure/avm-res-containerregistry-registry/azurerm` version = `"0.5.1"` (pin). Shared RG.

- `name`: `acrbankappp1<org><env>` (alphanumeric only; implementer runs the LESSON 27 rendered-length
  check, 5-50 chars).
- `sku = "Premium"` - **ruled, not optional**: private endpoints require Premium (verified current), and
  a public Basic/Standard registry would violate the estate's deny-public posture and waste the live
  privatelink.azurecr.io zone. ~$50/mo is the price of the posture; there is no cheaper compliant tier.
- `public_network_access_enabled = false`, `admin_enabled = false`, `zone_redundancy_enabled = true`
  (free with Premium), `network_rule_bypass_option = "AzureServices"` (keeps Defender image scanning
  functional against a private registry).
- `private_endpoints`: one PE into `snet-private-endpoints`, `private_dns_zone_resource_ids` =
  [privatelink.azurecr.io zone id from the existing data source], module manages the zone group - the
  estate's proven SQL-PE zone-group pattern. Note the ACR PE writes TWO A records (registry +
  `<registry>.<region>.data`); QA verifies both.
- `diagnostic_settings` to the platform LAW.

---

## 5. Defender for Containers (platform/security)

Same wave, separate root apply: flip the Containers plan in the existing `platform/security` pricing
map. Conditions carried from ADR-035/LESSON 26: plan-scan the security root for `-/+ replace` on ANY
Defender pricing resource (the Azure-assigned ForceNew subplan landmine); pin subplans to state values
where Azure assigns them. Sub-scoped, not tenant-gated (none of the ADR-033/034 Security-Administrator
items are touched). Cost approximate ~$7/vCore/mo => ~$40/mo at 6 vCores; re-verify at pre-clearance.

---

## 6. Egress RULING (OQ-042 resolved), firewall-rules delta spec, and wave runbook

### 6.0 The ruling

**OQ-042 RESOLVED 2026-07-18 (user): option (a), time-boxed.** `outbound_type = "userDefinedRouting"`;
`enable_firewall = true` for the sprint; cost accepted at the HOURLY rate (~$3.5/hr for the pair, both
hubs per the standing ADR-042 one-flag design - no supersede); intent is to stand up the full banking
landing zone and re-gate or tear down the firewalls by END OF DAY. Recorded in ADR-044. Consequences for
this doc: the spoke route-table wiring from B1 is UNTOUCHED (the 0.0.0.0/0 -> 10.0.0.4 UDR stays on
snet-aks-nodes and simply goes live), and the (b)/(c) route-scoping change described in earlier drafts
is NOT needed and must NOT be made.

### 6.1 What needs NO firewall rule (and why - state these in code comments, they are posture wins)

| Traffic | Why no rule |
|---|---|
| Node/pod -> API server | Private cluster: konnectivity flows over the API server private endpoint (AKS places it in the cluster VNet). In-VNet traffic matches the more-specific VNet system route, never reaches the firewall. The classic tunnel rules (UDP 1194, TCP 9000, `APIServerIP:443`, `*.hcp.<region>.azmk8s.io`) are ALL documented not-required for private clusters - do not add them. |
| Pulls from OUR ACR | The registry PE lives in snet-private-endpoints (10.30.2.0/24); privatelink.azurecr.io resolves both the registry and `<registry>.<region>.data` endpoints to the PE. In-VNet, more-specific route, stays private. |
| Azure DNS | 168.63.129.16 is host-routed platform traffic; never hits the UDR. |
| Hub/spoke private traffic | Peering + system routes are more specific than 0.0.0.0/0. |

### 6.2 Required rule collection group (PRIMARY hub policy ONLY)

Per ADR-009 the two hub policies are independent; the bank spokes are eastus2-only and their UDRs point
at 10.0.0.4, so AKS rules go on the PRIMARY policy only. The secondary policy stays rule-less (its
firewall returns as the ADR-042 pair for mesh-route integrity, not for workload egress).

Verified against Microsoft Learn `aks/outbound-rules-control-egress` (page dated 2026-06-18, fetched
2026-07-18). One rule collection group, priority 300, two collections:

**Application rule collection `aks-required-fqdns` (priority 100, Allow), source 10.30.0.0/24:**

| Rule | Destination | Protocols | Why |
|---|---|---|---|
| `aks-fqdn-tag` | FQDN tag **`AzureKubernetesService`** | Https 443, Http 80 | The Azure-Firewall-maintained tag covering the base required FQDN set (mcr.microsoft.com, `*.data.mcr.microsoft.com`, management.azure.com, login.microsoftonline.com, packages.microsoft.com, acs-mirror.azureedge.net / packages.aks.azure.com, ...). Auto-tracks Microsoft's list; FQDN tags in application rules do NOT need DNS proxy. |
| `aks-ubuntu-repos` | `security.ubuntu.com`, `azure.archive.ubuntu.com`, `changelogs.ubuntu.com` (Http 80) + `snapshot.ubuntu.com` (Https 443) | as listed | Documented recommended set: node OS security patches between node-image upgrades. |
| `aks-defender` | `*.cloud.defender.microsoft.com`, `*.ods.opinsights.azure.com`, `*.oms.opinsights.azure.com` | Https 443 | Defender for Containers event upload + LAW auth (login.microsoftonline.com already in the tag). The opinsights pair overlaps the AzureMonitor network rule below; harmless, keeps the L7 path explicit if the network rule is ever tightened. |

**Network rule collection `aks-required-network` (priority 200, Allow), source 10.30.0.0/24:**

| Rule | Destination | Proto/port | Why |
|---|---|---|---|
| `azure-monitor` | Service tag **`AzureMonitor`** | TCP 443 | Container Insights / AMA ingestion + DCR fetch to the platform LAW - the documented service-tag form for UDR clusters. |
| `ntp` | `*` | UDP 123 | NTP; docs say not required for post-2021 node images - kept as one cheap line to remove the failure class. Destination `*` (not ntp.ubuntu.com) deliberately: FQDN-based NETWORK rules would require firewall DNS proxy, which stays OFF in our policy config. |

Explicitly NOT added: 1194/9000/hcp/API-server rules (section 6.1), GPU FQDNs, Windows FQDNs, Azure
Policy add-on FQDNs (add-on not deployed at B2), Key Vault CSI FQDNs (not deployed at B2).

### 6.3 Placement, gating, and mechanics (platform/connectivity)

- The AVM pattern module's `firewall_policy` object carries NO rule-collection support (schema read in
  the pinned 0.17.1 source, 2026-07-18) - rules are a standalone
  `azurerm_firewall_policy_rule_collection_group` in the connectivity root. New file
  `platform/connectivity/firewall_rules_aks.tf`, name `rcg-aks-egress-primary`, priority 300.
- Policy id from the module's `firewall_policies` output (module outputs.tf line 41; a per-hub map -
  implementer verifies the exact attribute shape at build and takes the primary hub's policy id).
- Gate on `var.enable_firewall` via `for_each` over a conditioned map (estate no-count rule); when the
  flag is false the RCG drops out with the policy - the EOD re-gate needs no extra step.
- Source prefix as a variable (default `10.30.0.0/24`, description citing the bank-app-p1 snet-aks-nodes
  carve) - do not hardcode inline.
- DNS proxy stays OFF (module default; our config sets no `firewall_policy.dns`): nothing in this rule
  set requires it. TLS inspection stays unconfigured (the standing ADR-009-era tls_certificate
  DEVIATION); IDPS stays Alert.
- Flag supply RULING: `enable_firewall = true` lands in `envs/poc.tfvars` as a reviewed commit for the
  sprint (NOT a workflow-dispatch TF_VAR override - the flag state must be visible to plan-on-pr and
  drift checks, and the EOD re-gate is then an equally reviewable one-line revert).

### 6.4 Wave ordering runbook

**(i) platform/connectivity apply, `enable_firewall = true`** (+ the new RCG file in the same commit).
Plan-shape bar: PURE ADDS ~20-35 (exactly 2 firewalls Premium, 2 firewall policies + 1 RCG, 2 PIPs,
2 AzureFirewallSubnets, hub route tables + routes/associations, plus the returning modtm/random
telemetry pseudo-resources); changes limited to the known OQ-032 CreatedDate noise; **0 destroys,
0 replaces** - any `-/+` on a hub VNet/subnet/zone is a STOP (ADR-042 condition; subnets are standalone
resources in this module). Expect ~15-25 min (no VPN GW).
**Post-apply HARD GATE before anything else: confirm both firewall private IPs are exactly 10.0.0.4 and
10.1.0.4** (the ADR-042 deterministic contract the spoke UDRs and repo Secrets rely on). Wrong IP =
STOP, do not touch the spoke.

**(ii) landing-zones/bank-app-p1 apply, `enable_kubernetes_platform = true`** (aks.tf + acr.tf per
sections 3-4, outbound_type userDefinedRouting). Plan-shape bar: PURE ADDS ~15-25 (UAI, 2 role
assignments + propagation sleeps, AKS cluster set - the module is azapi-based so expect
azapi_resource + azapi_update_resource + kubeconfig action resources + telemetry - ACR + PE + zone
group + AcrPull, 2 diagnostic settings); **0 changes to any subnet/route table** (the UDR stays), 0
destroys, 0 replaces. Cluster create ~10-15 min; not token-lifetime-exposed (LESSON 46 class n/a).

**(iii) QA (PC-style live-vs-intent)** before the wave is green: private cluster (no public FQDN), API
A record in privatelink.eastus2.azmk8s.io; nodes Ready 3/3 across zones 1-3; ACR PE records (registry +
data); a test pull/egress flow visible in firewall logs (AzureKubernetesService tag hits); Container
Insights data arriving in the platform LAW; firewall IPs re-confirmed; JIT state-SA window re-closed.

**(iv) EOD disposition - user decides between two frames (both pre-framed here, ADR-044):**
- **Frame A, re-gate only (estate stays up):** one-line revert `enable_firewall = false` + connectivity
  apply. Expect the lean-down mirror: ~20-35 destroys, ALL firewall-class (firewalls, policies + RCG,
  PIPs, AzureFirewallSubnets, hub RTs, telemetry) - zero VNet/zone/peering destroys, verified in the
  plan scan. The AKS cluster then sits behind a blackholed default route again: kubectl over private
  link still works, running pods keep running, but scale-up, node-image upgrades, image pulls,
  Container Insights and Defender uploads ALL fail (nodes cannot bootstrap or egress). RULING: pair
  Frame A with an out-of-band **`az aks stop`** - a stopped cluster freezes cleanly, stops node compute
  billing, AND releases its 6 vCPUs of quota (relevant to OQ-043). Re-enable order later: firewall
  first, then `az aks start`.
- **Frame B, full estate teardown:** the standing teardown flow (spokes before hubs; bank-app-p1
  destroys AKS/ACR with the spoke). Nothing in B2 adds a purge-protection or soft-delete class blocker;
  strictly-after-verified-destroy revocation rules stand (LESSON 54-57).
- Either way the firewall bill for the sprint is hours x ~$3.5, not a run-rate.

### 6.5 Production design target (unchanged)

userDefinedRouting through Firewall Premium IS the production posture - the time-box, not the
architecture, is the POC concession. The B10 fidelity map records the firewall as duty-cycled at POC
rather than always-on.

---

## 7. Quota disposition (OQ-043 - loud)

Live numbers (2026-07-18): total regional cap **10 vCPUs**, v5 families **0**, DSv4-class families 10.

- B2 as specified fits: 3 x D2s_v4 = 6/10 steady, 8/10 during a surge-1 upgrade.
- **After B2 the sub is effectively full.** Wave B5 Databricks cannot start one minimal cluster
  (driver + 1 worker ~ 8 vCPUs) in the 4-vCPU remainder. The founding design's own fallback (new
  banking sub, OQ-035) exists for exactly this. Options + recommendation in OQ-043; B2 itself is NOT
  blocked and does not wait on it.

## 8. Cost summary (approximate list; firewall shown at the user's hourly framing)

| Item | Est./mo |
|---|---|
| AKS Standard control plane | ~$73 (verified order) |
| 3 x Standard_D2s_v4 | ~$210 (UNVERIFIED exact rate) |
| 3 x managed OS disks | ~$55 |
| ACR Premium | ~$50 |
| ACR private endpoint | ~$7 |
| Defender for Containers (if flipped) | ~$40 (approximate) |
| Firewall pair while enabled (time-boxed sprint) | **~$3.5/hr both hubs** (~$2.55k/mo IF left running - the EOD re-gate is what keeps this an hours-scale line) |
| **B2 steady delta (post re-gate, Frame A + cluster stopped)** | **~$110-120** (ACR + disks + control plane if not stopped; stopped cluster drops node + control-plane compute) |
| **B2 delta while the sprint runs** | ~$400-460 equivalent monthly + firewall hours |

Estate context: current run-rate ~$50-90/mo; ceiling ~$5k/mo (OQ-039).

## 9. Pre-clearance carry-forward (docs/preclearance/b2-aks.md, before ANY apply)

1. Live policy matrix at landingzones sub ancestors (corp MG Deny set vs the AKS node RG's
   RP-created LB/PIP/disks; Deny-Public-IP was identity-MG-scoped at B0b - re-verify).
2. Re-run this doc's quota + SKU checks (numbers rot; LESSON 40-41 re-audit if 2+ weeks pass).
3. CI SP: role-assignment write at the connectivity-sub zone scope; Microsoft.ContainerService +
  Microsoft.ContainerRegistry RP registration (ContainerService verified Registered at B1).
4. Plan-scan bars (histograms in section 6.4): connectivity = pure adds, zero VNet replaces (ADR-042
   condition); spoke = pure adds, ZERO subnet/route-table changes; security root = zero pricing
   replaces. Post-connectivity hard gate: firewall private IPs exactly 10.0.0.4 / 10.1.0.4.
5. Known-issues sweep for avm-res-containerservice-managedcluster 0.6.7 (azapi-based - check the
   module's GitHub issues for private-cluster + BYO-zone reports) and the settle-gate/JIT state-SA
   window per ADR-025.
