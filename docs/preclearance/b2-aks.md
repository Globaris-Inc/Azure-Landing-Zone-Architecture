# Pre-clearance: wave B2 Kubernetes platform (platform/connectivity firewall return + landing-zones/bank-app-p1 AKS/ACR)

> Artifact of the mandatory deploy pre-clearance gate. Covers TWO ordered applies: (1) the
> ADR-042/044 firewall re-enable on platform/connectivity (state has the lean hub; firewall-class
> resources are pure adds) and (2) the first AKS/ACR apply on landing-zones/bank-app-p1 (B1 network
> state live and QA-green; workload tier is pure adds).
> Prerequisite state verified: B0a + lean B0b + B1 GREEN; B2 batch merged to banking @ 6d34a2b
> (reviewer APPROVE); AKS_ADMIN_GROUP_OBJECT_ID repo secret set, target group verified live in
> Entra by display name; quota raise landed (below).
> Prepared by: architect. Date: 2026-07-18.
> Evidence: live az CLI 2026-07-18 (per-MG policy assignment enumeration at corp/landingzones/
> globaris, corp deny-initiative member+default dump, RP registration, post-raise vm-usage, SKU
> zone/restriction listing, CI SP role assignments, Entra group lookup), merged code read at
> 6d34a2b (aks.tf, acr.tf, firewall_rules_aks.tf, poc.tfvars, variables/providers/CI deltas),
> GitHub issue sweep on both AVM module repos (incl. full read of the one on-path candidate),
> MS Learn AKS egress page dated 2026-06-18, design doc docs/b2-aks-platform-design.md section 9
> checklist executed item by item.

## Verdict: GO-conditional. Five numbered preconditions. No code defect found; no new OQ.

The single load-bearing condition is PC-2K: the merged poc.tfvars pre-flips BOTH flags
(`enable_firewall = true`, `enable_kubernetes_platform = true`), so NOTHING in CI enforces the
connectivity-before-spoke order for single-target dispatches. The order is guarded only by this
document and the operator.

| # | Precondition | Lane | Blocks |
|---|---|---|---|
| PC-1K | Code identity: dispatch both applies from `banking` at a commit whose `platform/connectivity/**` and `landing-zones/bank-app-p1/**` content is IDENTICAL to 6d34a2b (`git diff 6d34a2b..<ref> -- platform/connectivity landing-zones/bank-app-p1 envs/poc.tfvars` empty). | devsecops | both applies |
| PC-2K | **ORDERING HARD GATE (ADR-044):** apply platform/connectivity to green FIRST, then verify BOTH live firewall private IPs are EXACTLY 10.0.0.4 and 10.1.0.4 (az CLI/portal - the ADR-042 deterministic contract the spoke UDRs + repo Secrets rely on) BEFORE dispatching bank-app-p1. Wrong or missing IP = STOP, do not touch the spoke. AKS nodes cannot bootstrap through a blackholed default route; a mis-addressed firewall is the same blackhole with a bill. | devsecops + architect gate | spoke apply |
| PC-3K | Plan-scan BOTH refreshed apply plans against the section 4 bars. Any destroy or `-/+ replace` on either root = STOP, one consolidated architect disposition (LESSON 26/59). | devsecops + architect scan | each apply |
| PC-4K | Post-apply QA (design doc 6.4 step iii): private cluster w/ no public FQDN + API A record live in privatelink.eastus2.azmk8s.io; 3/3 nodes Ready across zones 1-3; ACR PE with BOTH A records (registry + `<registry>.eastus2.data`); egress proven via firewall logs (AzureKubernetesService FQDN-tag hits); Container Insights data in law-platform; firewall IPs re-confirmed; JIT state-SA window re-closed. | qa-engineer | wave green + EOD step |
| PC-5K | EOD disposition EXECUTED and RECORDED same day (ADR-044): Frame A (revert `enable_firewall = false`, connectivity apply, destroys must be exclusively firewall-class, PAIRED with out-of-band `az aks stop`) or Frame B (full teardown, spokes first). The sprint is not closed until the WORKLOG carries which frame ran. | user decision + devsecops | sprint closeout |

---

## 1. Live policy matrix delta vs the new resource classes (enumerated per-scope 2026-07-18)

Full per-scope assignment list re-pulled today (corp / landingzones / globaris MGs); unchanged in
membership from the B1 enumeration except as assessed here for the NEW classes B2 creates: AKS
managed cluster (azapi PUT), node-RG resources created by the AKS RP (VMSS, NICs, internal LB,
disks), ACR Premium, private endpoint, user-assigned identity, role assignments, firewall-class
resources in the connectivity sub, and the RCG.

| Scope / assignment | Effect | B2 disposition |
|---|---|---|
| corp `Deny-Public-Endpoints` (Deny-PublicPaaSEndpoints @ globaris, no params - set defaults govern) | Deny, Default | **Two members now in scope, both satisfied BY DESIGN (dumped live today):** `AKSPublicIpDenyEffect` default Deny (denies non-private AKS clusters) - ours sets `enable_private_cluster = true`, public FQDN off. `ACRPublicIpDenyEffect` default Deny (denies ACR with public network access) - ours sets `public_network_access_enabled = false`. `ApiManPublicIpDenyEffect` is AuditIfNotExists (B4 note only). Storage member does not fire (no new SA at B2). |
| corp `Deny-Public-IP-On-NIC` | Deny, Default | UDR outbound = NO managed egress PIP; `enable_node_public_ip` not set (false); no PIP on any NIC in either root. The 2 firewall PIPs attach to firewalls, not NICs. Clear. |
| corp `Deny-HybridNetworking` / DNS DINEs / Audit-PeDnsZones | Deny (ER/VPN types) / DINE / Audit | No hybrid types; `Deploy-Private-DNS-Zones` DINE targets PEs - our ACR PE arrives WITH its zone group wired to the central zone, so the DINE finds it compliant or no-ops; never blocks. Clear. |
| landingzones `Deny-IP-forwarding` | Deny, Default | **THE one watched item.** Denies NICs with enableIPForwarding. kubenet node NICs required IP forwarding (documented conflict class); **Azure CNI Overlay does not** - pod routing rides the Azure fabric, not NIC forwarding (MS Learn CNI comparison, checked today). Expected: node NICs PUT with ipForwarding disabled -> clear. Residual risk LOW; pre-agreed STOP disposition in section 5 if it fires. |
| landingzones `Deny-Privileged-AKS`, `Deny-Priv-Esc-AKS`, `Enforce-AKS-HTTPS` | Deny, Default | All three are **Kubernetes-mode** built-ins: they evaluate in-cluster objects through the Azure Policy add-on (gatekeeper). B2 installs NO policy add-on and deploys NO workloads - they cannot block the ARM cluster PUT. They become live constraints the day workloads/add-on arrive (recorded hand-off note). |
| landingzones `Enforce-GR-Kubernetes0`, `Enforce-GR-ContReg0` | DoNotEnforce | Verified again today. Clear. |
| landingzones `Deny-Subnet-Without-Nsg` | Deny, Default | B2 creates ZERO subnets (consumes B1's, which carry NSGs). Clear. |
| landingzones `Deny-MgmtPorts-Internet`, `Deny-Storage-http` | Deny, Default | No new NSG rules, no storage at B2. Clear. |
| landingzones VM/VMSS DINEs (`Deploy-VM(SS)-Monitoring/ChangeTrack`, `Deploy-VM-Backup`, `Enable-AUM-CheckUpdates`, `Deploy-GuestAttest`) | DINE/Modify class | Fire on the node-RG VMSS AFTER create; DINE never blocks a PUT. Possible noise: policy-driven extensions on AKS-managed VMSS may be reconciled away by AKS - accepted noise, non-blocking (OQ-016/OQ-021 class). |
| globaris `tag-governance-globaris` | Modify, Default | Fires on every create incl. node-RG resources; proven non-blocking across B0a/B0b/B1 (84/630/49 creates). OQ-032 CreatedDate drift expected on post-apply plans. |
| globaris `Deny-UnmanagedDisk`, `Deny-Classic-Resources` | Deny, Default | AKS creates managed disks only. Clear. |
| globaris audit/DINE set (`Audit-ZoneResiliency`, `Audit-TrustedLaunch`, `Deploy-MDFC-*`, `Enforce-ACSB`, ...) | Audit/DINE | Noise class, never blocks. Clear. |
| Tenant Root system MFA pair + westeurope block | Microsoft system | Unchanged; workload identity empirically exempt through every 2026 apply; eastus2 only. Clear. |

Connectivity-sub side (firewall return): identical posture to the B0b clearance - no Deny on the
connectivity chain targets firewall/PIP/RT/RCG classes (re-checked in today's corp-chain dump: the
corp assignments do not bind the connectivity chain; B0b's own enumeration of that chain stands,
with zero new assignments created since - the only writer since then was B1, which touched no MG).

## 2. Tenant/subscription prerequisites: PASS

- **RP registration (landingzones sub, live today):** Microsoft.ContainerService **Registered**,
  Microsoft.ContainerRegistry **Registered** (the section-9 checklist item; ContainerService was
  already verified at B1, ContainerRegistry newly verified).
- **Quota (live today, post-raise):** Total Regional vCPUs **0/24** (raised from 10, auto-approved);
  standardDSv4Family **0/10** (raise refused, unchanged); B2 needs 6 steady / 8 during surge-1
  upgrades - fits both caps. Standard_D2s_v4 zones 1,2,3, NO restrictions (re-listed today).
  OQ-043 trail note: the 24-core total means B5 Databricks can now fit on a DIFFERENT v4 family
  (e.g. DASv4 0/10) alongside AKS's 6 on DSv4 - record in the B5 pre-clearance.
- **CI SP rights (live today, the flagged section-9 item):** role assignments show Owner @
  globaris MG (inherits to the landingzones sub: all creates + role-assignment writes for the UAI
  Network Contributor @ network RG and AcrPull @ ACR), Owner @ connectivity MG + Contributor/UAA @
  connectivity sub (covers the cross-sub **Private DNS Zone Contributor** role-assignment PUT at
  the zone scope, plus the firewall/RCG creates). All three role_assignment resources set
  `principal_type = "ServicePrincipal"` - no directory-read dependency, no replication-race class.
  (Standing note: the tenant-root rows in that listing are the ADR-041 temp grants, still pending
  revocation - unrelated to B2, do not consume them.)
- **Identity inputs:** AKS_ADMIN_GROUP_OBJECT_ID secret set (operator); the group resolved live in
  Entra by display name today. TF_VAR wiring present in `_tf-root.yml` + `plan-on-pr.yml`
  (merged batch); the variable is declared no-default in bank-app-p1 only - other roots see an
  unused TF_VAR (warning-class, harmless).
- **Hub-side dependencies:** privatelink.eastus2.azmk8s.io + privatelink.azurecr.io zones live in
  rg-dns and spoke-linked since B1 (QA PC-4B record); the aks.tf/acr.tf lookups reuse the exact
  B1 data sources. Platform LAW live, eastus2, region-matched (LESSON 43).

## 3. Module pins, known-issues sweep, lifecycle: CLEAR

- **Pins at 6d34a2b:** avm-res-containerservice-managedcluster **0.6.7** (registry latest,
  re-verified today; azapi-based, requires terraform >= 1.11 - root floor raised accordingly in
  the reviewed batch, CI pin 1.15.6 satisfies), avm-res-containerregistry-registry **0.5.1**
  (latest). Spoke lock azurerm 4.71.0 / azapi 2.11.0 satisfies the module's azapi ~> 2.9;
  connectivity keeps its proven 2.10.0 lock - no provider drift introduced by B2.
- **AKS module issue sweep (repo issues read today):** the one on-path candidate, **#199
  EmptySubnetError with outbound userDefinedRouting, is CLOSED and OFF-PATH** - it reproduces
  only on the AKS **Automatic** SKU with API-server VNet integration and `private_dns_zone =
  "none"` at 0.6.1; we run sku name **Base**, no VNet integration, BYO zone resource id. Open
  issues: #150 (extensions feature request, n/a), #84 (deprecated `metric` attribute in the
  module's diagnostic-setting resource - warning-class at plan, never blocks). ACR repo: only
  dependency-bump PRs + one feature request (#189, n/a).
- **Firewall-side known issues:** ALZ #4196 (firewall PIP ip_tags force-replace class) stays the
  permanent plan-scan tripwire from the B0b clearance; off-path for pure creates - it is exactly
  what PC-3K's zero-replace bar catches.
- **Lifecycle (LESSON 40-41):** the full B2 audit is TODAY's design-doc section 2 (CNI Overlay
  current/default, kubenet retirement 2028 n/a, ACR Premium PE requirement current, D2s_v4
  current). Node images default Ubuntu (the 2026-03-31 Azure Linux 2.0 image removal does not
  touch us). Clock: if the applies slip past **2026-07-25**, re-run the delta.

## 4. Plan-shape bars (PC-3K)

**Apply 1 - platform/connectivity (lean-live state -> firewalls return + RCG):**
Expected `Plan: ~30-45 to add, <=4 to change, 0 to destroy`. About 20 of the adds are the
returning modtm/random telemetry pseudo-resources (the same 20 the lean-down destroyed); changes
are the OQ-032 CreatedDate + modtm payload noise class ONLY.
Hard content histogram (governs over the raw count):
- EXACTLY: 2 Azure Firewalls (Premium, zones), 2 firewall policies (Premium, IDPS Alert, no TLS
  cert - the standing DEVIATION), **1 rule collection group `rcg-aks-egress-primary`** (4 app
  rules incl. the AzureKubernetesService FQDN tag + 2 network rules, sources 10.30.0.0/24,
  attached to the PRIMARY policy only), 2 Standard PIPs, 2 AzureFirewallSubnets, 2-4 hub route
  tables + their routes/associations.
- ZERO: VPN gateways, DNS resolvers, bastion, DDoS plan, VNet or existing-subnet replaces, zone
  or peering changes, destroys of ANY kind.

**Apply 2 - landing-zones/bank-app-p1 (B1-live state -> AKS + ACR):**
Expected `Plan: ~15-20 to add, 0 to change, 0 to destroy` (telemetry pairs of both AVM modules
included in the count).
Hard content histogram:
- EXACTLY: 1 `Microsoft.ContainerService/managedClusters` azapi resource (private cluster, public
  FQDN false, BYO zone id, sku Base/**Standard**, outboundType **userDefinedRouting**, podCidr
  192.168.0.0/16, serviceCidr 172.20.0.0/16, 3x Standard_D2s_v4 zones 1-3, node RG
  `rg-bank-app-p1-aks-nodes-...`) + its agent-pool azapi_update + 2 kubeconfig
  azapi_resource_action + 1 diagnostic setting; 1 ACR (**Premium**, publicNetworkAccess
  Disabled, adminUser false, zoneRedundancy Enabled) + 1 private endpoint into
  snet-private-endpoints w/ zone group to privatelink.azurecr.io + 1 diagnostic setting; 1 UAI;
  EXACTLY 3 role assignments (Private DNS Zone Contributor @ zone, Network Contributor @ network
  RG, AcrPull @ ACR); 1 time_sleep (300s).
- ZERO: changes/destroys/replaces on ANY module.spoke_vnet resource (subnets/RT/NSG/peerings/
  links untouched - the UDR STAYS), PIPs, NAT gateways, subnets, storage accounts.

## 5. Watch-items during the applies (dispositions pre-agreed)

| Symptom | Disposition |
|---|---|
| Firewall private IP lands != 10.0.0.4 / 10.1.0.4 | PC-2K STOP. Do not dispatch the spoke. Architect disposition (contract in ADR-042; deterministic first-usable of the pinned /26 - a mismatch means the subnet carve changed, which PC-1K should have caught). |
| Node-RG NIC create RequestDisallowedByPolicy citing IP forwarding (Deny-IP-forwarding) | STOP, architect disposition. Expected NOT to fire (CNI Overlay NICs ship without ipForwarding; kubenet class). If it fires: options are member-effect parameterization or a scoped exemption - do NOT improvise an ad hoc grant mid-run. |
| AKS create times out / nodes NotReady / extension bootstrap failures | FIRST read the primary firewall logs for denied FQDNs (rule-gap class) before touching the cluster. If the azapi create failed but the cluster exists live, that is the ADR-029 built-but-unstated class: check state, import-based recovery, no delete-recreate reflex. Each retry must narrow the failure class (LESSON 59). |
| Cluster create 403 on the private DNS zone or subnet join | RBAC propagation tail beyond the 300s sleep: verify the 2 UAI role assignments live, wait, single rerun. If the assignments themselves failed, STOP (different class). |
| `EmptySubnetError` on the cluster PUT | Off-path per the #199 sweep (Automatic-SKU class). If seen anyway: STOP, architect disposition with the full PUT body - do not flip outbound_type as the issue reporter did. |
| Plan shows `metric` deprecation warnings on diagnostic settings | Module issue #84, warning-class. Ignore. |
| RCG PUT fails referencing the policy id | Module output shape drift (`firewall_policies` map). STOP, single consolidated fix - the output attribute is the only unverified-at-runtime link in the chain. |
| Policy-driven extension noise on the node VMSS post-create | DINE class, non-blocking; AKS may reconcile it away. Record, ignore. |
| Stale state lease / state-SA 403 mid-run | Standing runbook: CI force-unlock w/ lock id, rerun; ADR-025 settle gate per run; recurrence escalates. |
| Post-apply CreatedDate tag drift | OQ-032 accepted. |

## 6. Defender for Containers flip: RULED NON-GATING (design-scoped to B2, not in the merged batch)

Disposition: **does NOT gate these applies - routed as a B2 follow-up batch** on
platform/security. Rationale: it is a subscription-scope pricing flip (posture add-on), invisible
to cluster/ACR create; the sprint's demo value (private cluster + inspected egress) does not
depend on it; and rushing it into an unrelated apply is exactly the ADR-035 ForceNew-subplan
plan-scan risk. The RCG already carries the Defender FQDNs (`*.cloud.defender.microsoft.com` +
opinsights pair), so the later flip needs NO firewall change - but note the EOD time-box: if the
firewalls re-gate before the flip, Defender's egress path from the (stopped) cluster is moot until
the next enable window. Follow-up batch conditions: ADR-035 subplan pin check + plan-scan for any
`-/+ replace` on Defender pricing resources; cost ~$7/vCore/mo approximate, re-verify then.

## 7. Duration / token / settle: NON-ISSUE with one sequencing note

Connectivity: firewalls create in parallel, ~10-15 min each, total apply ~20-35 min. Spoke: 300s
sleep + private AKS create ~10-20 min + ACR/PE ~5-10 min = ~30-45 min. Both well inside job
timeout and OIDC token life (no AADDS-class hour-scale creates; LESSON 46 n/a). Runs are
SEQUENTIAL by PC-2K anyway; each single-target run manages its own JIT state-SA window with the
ADR-025 3-consecutive-probe settle gate. Mid-apply-death disposition pre-agreed: state holds,
diagnose ALL failures, one consolidated fix, single rerun.

## Ordered execution runbook

1. PC-1K (devsecops): diff-empty check vs 6d34a2b, then dispatch `deploy.yml`
   `target=platform/connectivity` `action=apply` from `banking`.
2. PC-3K scan on the refreshed connectivity plan (bar section 4 apply 1). Apply completes green.
3. PC-2K gate (devsecops + architect): live-verify firewall IPs 10.0.0.4 / 10.1.0.4.
4. Dispatch `target=landing-zones/bank-app-p1` `action=apply`. PC-3K scan (bar section 4 apply
   2). Apply completes green.
5. PC-4K: qa-engineer pass per design doc 6.4(iii). WORKLOG green-marking.
6. PC-5K: user picks Frame A or B (ADR-044); execute + record same day. Frame A = revert flag,
   connectivity apply (destroys exclusively firewall-class, plan-scanned), `az aks stop`.

## Hand-off notes

- The three Kubernetes-mode AKS denies at the landingzones MG become LIVE admission constraints
  the day the Azure Policy add-on or workloads arrive - future workload waves must clear them.
- Defender for Containers follow-up batch per section 6.
- B4 re-entry items unchanged (APIM stv2 forced-tunneling route + ApiManPublicIpDenyEffect is
  AuditIfNotExists only).
- OQ-043 trail: total 24 vCPUs / DSv4 refused at 10 - B5 plans against a different v4 family;
  quota snapshot in section 2 feeds the B5 pre-clearance.
- If the sprint slips past 2026-07-25 without applies, re-run the lifecycle delta (section 3).
