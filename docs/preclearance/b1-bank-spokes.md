# Pre-clearance: wave B1 banking spokes (landing-zones/bank-app-p1 + landing-zones/bank-data-p1)

> Artifact of the mandatory deploy pre-clearance gate. FIRST APPLY of both roots (empty state).
> Prerequisite state verified: B0a (management-groups, management, security) GREEN and live;
> B0b lean connectivity GREEN and QA-PASSED (apply 29627763908) - hub VNets 10.0.0.0/16 +
> 10.1.0.0/16 live and peered, 89 zones + 178 links in rg-dns-globaris-poc, NO
> firewall/GW/resolver (ADR-042 gated: the spoke UDR next hop 10.0.0.4 is a forward contract
> that blackholes harmlessly until the firewall wave).
> Prepared by: architect. Date: 2026-07-17.
> Evidence: live az CLI enumeration 2026-07-17 (MG ancestry, policy assignments at every
> ancestor scope, set-definition members + parameter defaults, RP registration, network
> quotas, network watchers, RG/resource inventory, role assignments on both subs, rg-dns
> zone list, platform LAW), gh CLI (GREEN plan runs 29629364383 bank-app-p1 and 29629429100
> bank-data-p1, both at banking @ d65ef16, full logs scanned), committed .terraform.lock.hcl
> for both roots, GitHub/registry known-issue sweep, MS Learn lifecycle delta check dated
> 2026-07-17.

## Verdict: GO. Four numbered preconditions, all procedural - no code defect found, no new OQ.

| # | Precondition | Lane | Blocks |
|---|--------------|------|--------|
| PC-1B | Code identity: dispatch each apply from branch `banking` at a commit whose `landing-zones/bank-app-p1/**` and `landing-zones/bank-data-p1/**` content is IDENTICAL to plan SHA d65ef16 (`git diff d65ef16..<dispatch-ref> -- landing-zones/` must be empty). Verified empty vs local HEAD 2026-07-17. | devsecops | both applies |
| PC-2B | SEQUENTIAL dispatch, not concurrent: apply bank-app-p1 to completion, then bank-data-p1 (order interchangeable, overlap is not). Both roots PUT peerings onto the SAME hub VNet `vnet-hub-primary-globaris-poc` and write links into the same rg-dns zone RG; concurrent VNet-level operations risk retryable-409 churn, and single-target runs each manage the JIT state-SA window (ADR-025 settle gate). | devsecops | second apply |
| PC-3B | Plan-scan the apply run's refreshed plan against the recorded shape (section 4): bank-app-p1 exactly 23 to add, bank-data-p1 exactly 26 to add, 0 to change, 0 to destroy, 0 replace, addresses matching the recorded lists. Any destroy/replace is impossible on empty state - its appearance means state is not empty: STOP, architect disposition (LESSON 26/59). | devsecops + architect scan | each apply |
| PC-4B | Post-apply, per root, before any B2+ work: qa-engineer live-vs-intent pass (house gate). Must include: RG-scoped exemption live and scoped to StorageDenyPaasPublicIP only; flow-log SA publicNetworkAccess Enabled and NOT flagged denied; flow log Succeeded with Traffic Analytics wired to law-platform-globaris-poc; both peering directions Connected; 3 (app) / 6 (data) zone links live in rg-dns; both Databricks subnets carrying the Microsoft.Databricks/workspaces delegation. The UDR next hop 10.0.0.4 blackholing egress is INTENT (ADR-042), not a defect - do not "fix". | qa-engineer | wave B2+ |

---

## 1. Live policy matrix at every ancestor scope: CLEAR, with the single known collision already designed as one unit

Ancestor chain verified live 2026-07-17: sub <subscription-id> -> **corp** MG -> **landingzones** MG ->
**globaris** MG -> Tenant Root Group. (Sub-under-corp placement confirmed by
`az account management-group show -n corp --expand`: the landingzones sub is corp's only child.)

| Scope | Assignment | Effect class | Verdict for these roots |
|---|---|---|---|
| corp MG | `Deny-Public-Endpoints` (Deny-PublicPaaSEndpoints initiative, defined at globaris) | **Deny, Default** | THE designed collision. Assignment passes NO parameters, so set defaults govern. Member `StorageDenyPaasPublicIP` -> built-in b2982f36 (storage publicNetworkAccess) default **Deny**: fires on each flow-log SA (publicNetworkAccess Enabled by functional necessity). Covered by each root's RG-scoped Waiver exemption + 300s time_sleep + depends_on (OQ-024/ADR-028/LESSON 35). Second storage member `Deny-Storage-Public-Access` -> built-in 4fa4b6c0 (BLOB public access) default Deny: SAs set `allow_nested_items_to_be_public = false` -> COMPLIANT, no exemption needed. No other member targets a type these roots create (no AKS/ACR/KV/SQL/etc. at B1). |
| corp MG | `Deny-Public-IP-On-NIC` | Deny, Default | No NICs, no PIPs created. Clear. |
| corp MG | `Deny-HybridNetworking` | Deny, Default | Denies ER/VPN/vWAN types only (verified in the Section 9 clearance); peerings/VNets/NSGs/RTs not listed. Clear. |
| corp MG | `Deploy-Private-DNS-Zones`, `Audit-PeDnsZones` | DINE / Audit | DINE targets private endpoints (none at B1); audit never blocks. Clear. |
| landingzones MG | `deny-pub-net-globaris` (our custom initiative, defined at landingzones MG) | Default, but **all 3 members (SQL/KV/Storage) effect = Audit** | RE-VERIFIED LIVE TODAY member by member. Audit never blocks; the flow-log SAs will show as non-compliant here - accepted noise (OQ-016 class). NOT covered by the corp waiver and does not need to be. |
| landingzones MG | `Deny-Subnet-Without-Nsg` | **Deny, Default** | Every subnet in both roots carries an NSG, attached inside the subnet create PUT (AVM module behavior proven by the Section 9 arc: NSG-less snet-integration was denied, NSG-carrying subnets passed on this exact module pin). Clear. |
| landingzones MG | `Deny-MgmtPorts-Internet` | Deny, Default | Matches NSG **Allow** rules from Internet on mgmt ports. Our only Allows use ApiManagement / AzureLoadBalancer service-tag sources; everything else is Deny rules. Clear. |
| landingzones MG | `Deny-Storage-http` | Deny, Default | azurerm 4.x defaults HTTPS-only true; min TLS 1.2 set. Clear. |
| landingzones MG | `Deny-IP-forwarding`, AKS denies (`Enforce-AKS-HTTPS`, `Deny-Priv-Esc-AKS`, `Deny-Privileged-AKS`) | Deny, Default | NIC/AKS-targeted; none created at B1. Re-enter scope at wave B2. |
| landingzones MG | `Enable-DDoS-VNET` | Modify, **DoNotEnforce** | The historic VNet-PUT blocker class (ADR-026) is NOT enforced on this chain. Verified live. Clear. |
| landingzones MG | `Enforce-GR-*` (incl. Network0, Storage0, APIM0, Kubernetes0), `Enforce-Subnet-Private`, `Enforce-Encrypt-CMK0` | **DoNotEnforce** | Not enforced. Clear. |
| landingzones MG | `Enforce-GR-KeyVault`, `Enforce-TLS-SSL-Q225`, `Enforce-ASR`, `Deploy-VM/VMSS/SQL-*`, `Enable-AUM-*` | Default | No KV/VM/SQL created; TLS members satisfied (TLS1_2). Clear. |
| globaris MG | `tag-governance-globaris` | **Modify, Default** | Fires on all create PUTs; proven non-blocking across B0a (84 creates) and B0b (630 creates). Expect the OQ-032 CreatedDate tag drift on the first post-apply plan - accepted estate behavior. |
| globaris MG | `Deny-Classic-Resources`, `Deny-UnmanagedDisk` | Deny, Default | No classic resources, no disks. Clear. |
| globaris MG | Audit-*, Deploy-Diag/MDFC/MCSB DINEs, reg-nist/reg-cis (DoNotEnforce) | Audit/DINE | Noise class; DINE never blocks creates (OQ-021 unwired-LAW remediation noise will log - ignore). |
| Tenant Root Group | `sys.mfa-write`/`sys.mfa-delete`, `sys.blockwesteurope` | Microsoft system | Unchanged from the B0b enumeration dated 2026-07-17: workload identities empirically exempt from the MFA pair through every 2026 apply; region block is westeurope-only, these roots deploy eastus2 + global-scope links. |
| sub | `SecurityCenterBuiltIn` | Audit-class | Never blocks. |

### 1a. Stale-reference check on the exemption units: PASS, byte-identical

Both roots' `policy_exemptions.tf` carry the literal assignment id
`/providers/Microsoft.Management/managementGroups/corp/providers/Microsoft.Authorization/policyAssignments/Deny-Public-Endpoints`.
Live `az policy assignment show` today returns EXACTLY that id (the B0a redeploy recreated the
assignment under the same name), and the live set definition at globaris contains reference id
`StorageDenyPaasPublicIP` verbatim. The GREEN plan for both roots renders the same id. The
first-apply stale-reference failure class is ruled out. COUPLING caveat of ADR-028 stands: any
future rename/rescope of that assignment must update both roots in lockstep.

## 2. Tenant/subscription prerequisites (OQ-035 recorded apply gate): PASS - this closes the OQ-035 quota condition

- **Sub inventory (live):** the landingzones sub is near-empty as expected post-teardown. RGs:
  `NetworkWatcherRG`, `cloud-shell-storage-southcentralus`, `adf-enterprise-rg` (strays, no name
  collision with the 8 RGs these roots create). No prior spoke residue; the Section 9 spokes are
  confirmed NOT live.
- **Network Watcher landmine INVESTIGATED AND CLEARED:** both roots read
  `data.azurerm_network_watcher.primary` (NetworkWatcher_eastus2 in NetworkWatcherRG) via the
  DEFAULT provider, i.e. in the LANDINGZONES sub - a different watcher than the connectivity-sub
  one QA verified at B0b. Live enumeration today: the landingzones sub has its own
  NetworkWatcherRG with NetworkWatcher_eastus2 (plus centralus/eastus/westus) - it SURVIVED the
  teardown, exactly like the connectivity sub's did. No auto-create race, no code change needed.
  Belt-and-suspenders proof: both GREEN plans resolved the data source. Standing note: NEVER
  delete NetworkWatcherRG in either sub during any future teardown; both flow-log roots and the
  region is at its 1/1 watcher quota by design.
- **RP registration (landingzones sub, live):** Microsoft.Network, Microsoft.Storage,
  **Microsoft.Databricks** (required for the two delegated subnets), Microsoft.ContainerService,
  Microsoft.ApiManagement, Microsoft.Insights, Microsoft.OperationalInsights,
  Microsoft.PolicyInsights - ALL **Registered**. The only delegation target used at B1 is
  Microsoft.Databricks/workspaces (bank-data-p1 x2); `az network vnet subnet
  list-available-delegations` for eastus2 in this sub lists it with the expected
  join/prepare/unprepare actions. bank-app-p1 uses NO delegations at B1 (AKS nodes need none;
  APIM stv2 delegation is a wave B4 item).
- **Quota (live, eastus2, landingzones sub):** VirtualNetworks 0/1000, NSGs 0/5000, RouteTables
  0/600. Need: 2 VNets, 4 NSGs, 2 RTs. No compute/PaaS offer-cap surface exists in these roots
  (network-only per LESSON 42; the only PaaS resource is 2 Standard LRS storage accounts, and
  storage creation on this sub/offer is proven by the Section 9 flow-log SAs). SA names are
  random-suffixed (21 chars, LESSON 27 checked in-file) - global-namespace collision risk nil.
- **RBAC (live):** CI SP `<ci-client-id>` holds Contributor + User Access
  Administrator on BOTH the landingzones sub and the connectivity sub. That covers: all
  in-sub creates; the cross-sub writes via the `azurerm.connectivity` alias (hub-side return
  peering on the hub VNet, 9 zone links in rg-dns-globaris-poc); and critically the
  `azurerm_resource_group_policy_exemption` PUTs - Microsoft.Authorization/policyExemptions/write
  is EXCLUDED by Contributor's NotActions and is granted here by the UAA role (Section 9
  precedent applied the identical pattern green).
- **Hub-side dependencies (live):** `vnet-hub-primary-globaris-poc` in
  rg-connectivity-primary-globaris-poc live; all 9 lookup zones present by name in
  rg-dns-globaris-poc (aks-eastus2/acr/servicebus for app; blob/dfs/databricks/openai/
  cognitiveservices/search for data). Traffic Analytics target `law-platform-globaris-poc` live
  in the management sub, location **eastus2**, provisioningState Succeeded - region-matched to
  the flow logs (LESSON 43). Hub secrets verified byte-identical at B0b PC-3L; the GREEN plans
  consumed them (the peering/UDR values render correctly, next hop masked as a secret in logs).

## 3. Provider/module pins + known-issues + lifecycle audit: CLEAR

- **Locks (committed, both roots byte-identical):** azurerm 4.71.0 (same as the whole estate),
  azapi **2.11.0**, modtm 0.3.5, random 3.8.1, time 0.13.1. Delta vs connectivity: azapi 2.11.0
  (connectivity locks 2.10.0). 2.11.0's changelog is a fix release (MSI-auth and default-retry
  regressions FIXED in it); no open issue found on our usage path (azapi here only backs the AVM
  VNet module's vnet/subnet resources), and both GREEN plans ran on it. Watch-item only.
- **Module pin:** avm-res-network-virtualnetwork **0.17.1**, same pin as the Section 9 spokes
  (OQ-017 consistency ruling). Known-issue sweep: the delegation/service-endpoint
  state-persistence drift bug (module issue #50) is a v0.16.0 class resolved before 0.17.1, and
  the delegation path on THIS pin is proven green by corp-a1 snet-integration
  (Microsoft.Web/serverFarms). Both plans show the Databricks delegation present in both subnet
  PUT bodies (grep-verified `serviceName = "Microsoft.Databricks/workspaces"` x2). No open issue
  matching our subnet/NSG/RT-association shape.
- **Lifecycle audit (step 3d), delta dated 2026-07-17:** every created type is CURRENT. VNet
  flow logs are the designated SUCCESSOR of NSG flow logs (NSG flow logs: creation blocked since
  2025-06-30, retirement 2027-09-30; these roots correctly use VNet-scoped flow logs), Traffic
  Analytics on VNet flow logs is the supported integration (MS Learn vnet-flow-logs-overview,
  checked today). Databricks VNet injection + subnet delegation: current, no retirement.
  Standard-LRS storage, private DNS zone links, peerings: core primitives, current. LESSON 41
  clock: this delta plus the 2026-07-10 estate audit covers us; **if the B1 applies slip past
  2026-07-24, re-run the lifecycle delta before dispatch.**

## 4. Plan-shape bar for the orchestrator's scan (recorded from GREEN plans at banking @ d65ef16)

Runs: 29629364383 (bank-app-p1, `Plan: 23 to add, 0 to change, 0 to destroy`) and 29629429100
(bank-data-p1, `Plan: 26 to add, 0 to change, 0 to destroy`). The refreshed plan at apply time
must match these shapes exactly.

**bank-app-p1 (23 adds):** 4 RGs (network/shared/workload/monitoring), 2 NSGs (spoke, apim - the
apim NSG carries the two verified stv2 rules 3443/ApiManagement + 6390/AzureLoadBalancer),
1 route table (0.0.0.0/0 -> firewall IP), VNet module set (azapi vnet + 3 azapi subnets
aks-nodes/apim/private-endpoints + modtm/random_uuid telemetry pair), 2 peerings (spoke_to_hub +
hub_to_spoke cross-sub), 3 zone links (aks/acr/servicebus), 1 random_id, 1 storage account,
1 flow log, 1 policy exemption, 1 time_sleep.

**bank-data-p1 (26 adds):** same skeleton; NSGs are spoke + databricks; subnets are
databricks-host/databricks-container (BOTH with the Microsoft.Databricks/workspaces delegation)
+ private-endpoints; 6 zone links (blob/dfs/databricks/openai/cognitiveservices/search).

**Zero-tolerance items (any hit = STOP, one consolidated architect disposition per LESSON 59):**
- ANY destroy or `-/+ replace` (state is empty; their appearance means it is not).
- ANY compute or paid-SKU resource beyond the 2 Standard LRS flow-log SAs (0 AKS, 0 APIM,
  0 Databricks workspace, 0 PIPs, 0 NAT GW, 0 bastion, 0 DDoS plan).
- Delegated-subnet set differing from EXACTLY: bank-data-p1 databricks-host +
  databricks-container (Microsoft.Databricks/workspaces); ZERO delegations in bank-app-p1.
- Exemption category other than Waiver, or an assignment id differing from the section 1a value.
- Any resource landing outside subs <subscription-id> (default) / <subscription-id> (connectivity alias).

## 5. Apply duration / token lifetime: NON-ISSUE

Longest single element is the fixed 300s exemption-propagation sleep; VNets/subnets/NSGs/links
are fast, the SA ~1-2 min, the flow log minutes. Realistic wall time 15-25 min per root against
a 360-min job timeout and OIDC token refresh that spans multi-hour applies. Mid-apply-death
disposition (pre-agreed): resources stay in state, single rerun plans the remainder; each retry
must narrow the failure class.

## Ordered execution runbook

1. PC-1B (devsecops): `git diff d65ef16..origin/banking -- landing-zones/` empty, then dispatch
   `deploy.yml` `target=landing-zones/bank-app-p1` `action=apply` from `banking` (single target,
   JIT state-SA window + ADR-025 settle gate).
2. PC-3B scan on the refreshed plan (23/0/0, addresses per section 4). Apply completes.
3. Dispatch `target=landing-zones/bank-data-p1` `action=apply` (PC-2B sequencing). PC-3B scan
   (26/0/0). Apply completes.
4. PC-4B: qa-engineer live-vs-intent pass per root; then WORKLOG green-marking.

## Watch-items during the applies (dispositions pre-agreed)

| Symptom | Disposition |
|---|---|
| Flow-log SA create returns RequestDisallowedByPolicy (StorageDenyPaasPublicIP) despite the 300s sleep | Propagation tail, not a design defect: verify the exemption is live at the RG (`az policy exemption list`), wait, single rerun. If the exemption itself failed to create, STOP - that is a different class. |
| Policy exemption PUT 403 AuthorizationFailed | Should be impossible (UAA verified live today); if seen, STOP and re-verify the SP's role assignments - do not grant ad hoc. |
| Hub-side peering or zone-link PUT 409 "another operation in progress" | Retryable contention on the hub VNet/zone RG; provider retries usually absorb it. If the run dies: confirm PC-2B sequencing was honored, single rerun. |
| Peering eventual-consistency error right after VNet create | Single rerun; residual races clear on retry. |
| Flow log create fails referencing the workspace | Verify law-platform-globaris-poc live + PLATFORM_LAW_* secret values; do not touch the watcher. |
| Stale state lease at init | CI force-unlock (single target + lock id), re-plan. |
| State-SA 403 mid-run despite settle gate | Rerun (state holds, remainder short); recurrence escalates to architect. |
| Post-apply plan shows CreatedDate tag drift | OQ-032 accepted estate behavior. |
| deny-pub-net-globaris / audit-class non-compliance flags on the flow-log SAs | Audit-only (verified member effects today); noise, never blocks. |
| Spoke egress blackholes at 10.0.0.4 | INTENT (ADR-042 forward contract) until the firewall wave; not a defect, do not "fix" the UDR. |

## Hand-off notes

- This document CLOSES the OQ-035 apply-gate condition (quota + namespace verification in the
  landingzones sub) for wave B1.
- Wave B2+ re-entry items parked deliberately: AKS pod CIDR pin (192.168.0.0/16, in-file
  ruling), APIM stv2 forced-tunneling service-tag route + full NSG recommended set (B4
  pre-clearance), Databricks control-plane firewall allowances (B5 pre-clearance), and the AKS
  Deny assignments at the landingzones MG re-enter scope at B2.
- The firewall-enable wave must re-run its own pre-clearance (re-arms the B0b #4196 PIP
  tripwire and re-audits appliance lifecycle) and only then does the 10.0.0.4 contract go live.
