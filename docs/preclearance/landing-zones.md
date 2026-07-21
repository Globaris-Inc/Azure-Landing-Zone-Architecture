# Pre-clearance: landing-zones/{corp-a1, corp-a2, online-p1}

> Artifact of the deploy pre-clearance gate (see `docs/deploy-preclearance.md`).
> Prepared by: architect. Date: 2026-07-10. Deploy order: corp-a1 (pattern) -> corp-a2 -> online-p1.
> Evidence: live `az` policy/resource enumeration + `gh secret list` on 2026-07-10, the three root
> `main.tf`/`dns_links.tf`/`backup.tf` files, `azurerm` provider `required.go` (Core RP set), and
> ADR-026 (DDoS DoNotEnforce lever) / ADR-028 (RG-scoped Waiver exemption precedent).
>
> **Verdict up front:** all three spokes are **BLOCKED**. Four environment blockers must be cleared
> first (one is the ADR-026 DDoS trap, live-confirmed still enforced at the `landingzones` MG). Details
> and the ordered actions per spoke are below.

---

## 0. Topology finding that reframes the whole matrix (verified live)

The `landingzones` **subscription** (`<subscription-id>`) is placed under the **`corp`**
MG. The `online` MG has **no subscription** under it (`az account management-group show --name globaris
--expand --recurse`). All three spoke roots deploy into that one subscription
(`LANDINGZONES_SUBSCRIPTION_ID`). Therefore **all three spokes - including `online-p1` - inherit the `corp`
archetype policies**, not the `online` MG. The ancestor chain for every spoke resource is:

```
Tenant Root -> globaris -> landingzones -> corp -> sub <subscription-id> (all 3 spokes)
online MG = empty, irrelevant to deployed resources
```

Consequence: the `corp`-MG `Deny-Public-Endpoints` (Deny-PublicPaaSEndpoints) initiative governs
`online-p1` too, and there is **no** `Deny-Public-IP` (standalone `publicIPAddresses`) assignment anywhere on
this chain, so the `online-p1` App Gateway PIP is clean (see the matrix). That `online-p1` is an "online"
archetype workload sitting under the `corp` MG is a topology mismatch worth a follow-up, but it does not
block deploy - flagged in **OQ-024**.

---

## 1. What each root creates (enumerated from the roots)

| Resource class | corp-a1 (eastus2) | corp-a2 (centralus, DR) | online-p1 (eastus2) |
|---|---|---|---|
| Resource groups (network/shared/workload/monitoring) | 4 | 4 | 4 |
| Spoke VNet (AVM `avm-res-network-virtualnetwork` 0.17.1) + subnets | 10.10.0.0/16; snet-integration(/26, **no NSG**), snet-data, snet-private-endpoints | 10.11.0.0/16; same shape | 10.20.0.0/16; snet-appgateway(/24), snet-workload(/24), snet-private-endpoints(/24) all with NSG |
| NSG(s) | 1 (spoke, deny-internet) | 1 | 2 (appgw allow-GatewayManager/LB/HTTP80; workload deny-internet) |
| Route table (0.0.0.0/0 -> firewall) | yes (10.0.0.4) | yes (10.1.0.4) | yes (workload/PE only; NOT appgw subnet) |
| VNet peering spoke<->hub (x2, cross-sub) | primary hub | secondary hub | primary hub |
| App Service Plan + App Service (Linux B2, VNet-integrated) | yes | yes | none |
| Azure SQL server + DB (Entra-only, `public_network_access_enabled=false`) + Private Endpoint + PE DNS zone group + zone VNet link | yes | yes | none (Static Web App instead) |
| Recovery Services Vault (`avm-res-recoveryservices-vault` 1.1.3) | yes (ZoneRedundant) | yes (GeoRedundant) | none |
| Static Web App (Standard) | none | none | yes (public) |
| Public IP (Standard, zonal) + WAF policy (OWASP 3.2) + Application Gateway WAF_v2 + diag setting | none | none | yes |
| Flow-log storage account (Standard LRS, **public network access = Enabled**) + NSG flow log(s) + Traffic Analytics | 1 SA / 1 flow log | 1 SA / 1 flow log | 1 SA / 2 flow logs |
| Network Watcher (data source, default provider = LZ sub) | `NetworkWatcher_eastus2` | `NetworkWatcher_centralus` | `NetworkWatcher_eastus2` |

No `azurerm_role_assignment` in any root (UAA present but not strictly exercised by the spokes).

---

## 2. Policy collision matrix (live-verified 2026-07-10)

Enumerated at `globaris`, `landingzones`, `corp` (and `online` = empty). Only Deny/Modify/DINE that can
touch a spoke resource type are listed; the long DINE/Audit tail (Deploy-*, Audit-*, Enforce-Guardrails-*
which are all `DoNotEnforce`) is dispositioned as NOISE at the bottom.

| # | Assignment | Scope | Effect / mode | Fires on | Verdict |
|---|---|---|---|---|---|
| 1 | **`Enable-DDoS-VNET`** (builtin `94de2ad3`) | **landingzones** | **Modify / Default (ENFORCED)** | **Every spoke VNet PUT** - `ddosPlan` = placeholder `/subscriptions/0000.../ddosProtectionPlans/placeholder`, `addOrReplace` on `ddosProtectionPlan.id` | **BLOCKER (all 3).** Identical trap to ADR-026 (which fixed it at the *connectivity* MG only). Live `az policy assignment show`: `enforcementMode=Default`, `effect=Modify`, placeholder plan present. Fix = DoNotEnforce at `landingzones` MG (section 6). |
| 2 | **`Deny-Public-Endpoints`** / member `StorageDenyPaasPublicIP` (`b2982f36`) | **corp** | **Deny / Default** (assignment params `{}` -> initiative default `StoragePublicIpDenyEffect=Deny`) | **Flow-log storage accounts** (all 3 spokes) - rule denies `Microsoft.Storage/storageAccounts` where `publicNetworkAccess NOT in [Disabled, SecuredByPerimeter]`. The flow-log SAs never set `public_network_access_enabled=false` -> Enabled -> **denied**. | **BLOCKER (all 3).** Decision needed (OQ-024): RG-scoped Waiver exemption (ADR-028 precedent) vs disable public net access vs param->Audit. |
| 3 | **`Deny-Public-Endpoints`** / member `AsDenyPublicIP` (`1b5ef780`) | **corp** | **Deny / Default** (`AsPublicIpDenyEffect=Deny`) | **App Service** (`Microsoft.Web/sites`, non-ASE) where `publicNetworkAccess` absent or `!= Disabled`. corp-a1/a2 App Services are VNet-integrated for egress but do not disable public inbound -> **denied**. | **BLOCKER (corp-a1, corp-a2).** online-p1 has no `Microsoft.Web/sites` (Static Web App = `Microsoft.Web/staticSites`, not covered) -> PASS for online-p1. Same OQ-024 decision. |
| 4 | **`Deny-Subnet-Without-Nsg`** (custom) | **landingzones** | **Deny / Default** | Subnets with no NSG whose name is not in `excludedSubnets` (default Bastion/Gateway/Firewall subnets). corp **`snet-integration`** has delegation + route table but **no NSG** -> **denied**. | **BLOCKER (corp-a1, corp-a2).** online-p1: all 3 subnets carry an NSG -> PASS. Fix = attach the spoke NSG to `snet-integration` (cloud-engineer), or exempt (OQ-024). |
| 5 | `deny-public-network-access-globaris` initiative (`deny-pub-net-globaris`) | landingzones | Default, but **all 3 members (SQL/KeyVault/Storage) effect = Audit** | SQL / storage public access | **PASS.** Confirms OQ-016: Audit, not Deny. Non-blocking for SQL/PE/flow-log SAs. |
| 6 | `Deny-Public-IP-On-NIC` (`83a86a26`) | corp | Deny / Default | `Microsoft.Network/networkInterfaces` with a PIP on an ipconfig | **PASS (all 3).** The online-p1 App Gateway PIP is a **standalone** `publicIPAddresses` on the gateway frontend, not a NIC. PE NICs carry no PIP. corp spokes create no PIP. |
| 7 | `Deny-HybridNetworking` (`6c112d4e`, "not allowed types") | corp | Deny / Default | `listOfResourceTypesNotAllowed` = ExpressRoute/VPN/vWAN/gateway types only (verified) | **PASS (all 3).** Does not list `publicIPAddresses` or App Gateway. Confirms there is **no** standalone-PIP deny on this chain. |
| 8 | `Deny-MgmtPorts-Internet` (`Deny-MgmtPorts-From-Internet`) | landingzones | Deny / Default | NSG **Allow** inbound rules for mgmt ports (default `[22,3389]`) or `*` from `Internet`/`*`/`0.0.0.0/0` | **PASS (all 3).** corp NSGs have only a Deny rule (policy matches Allow). online-p1 appgw NSG Allow rules: HTTP:80 from Internet (not a mgmt port), and LB/GatewayManager (service-tag sources, not Internet). |
| 9 | `Deny-Storage-http` (`404c3081`) | landingzones | Deny / Default | Storage without HTTPS-only | **PASS (all 3).** Flow-log SAs set `min_tls_version=TLS1_2`; azurerm defaults `https_traffic_only=true`. |
| 10 | `Deny-IP-forwarding` (`88c0b9da`) | landingzones | Deny / Default | NICs with IP forwarding | **PASS.** No spoke NIC enables IP forwarding; PE NICs do not. |
| 11 | `tag-governance-globaris` | globaris | Modify (modify/inherit tag members) | RG tags | **PASS (all 3).** Add-if-missing / inherit only; non-breaking. Spokes set all tags explicitly. |
| 12 | `Deploy-Private-DNS-Zones` (DINE) | corp | DINE / Default | Private endpoints -> add ALZ-managed private DNS zone group | **NOISE / known issue.** Does not block PE create. May contend with the spoke's own `private_dns_zone_group` on the SQL PE (both target `privatelink.database.windows.net`). Post-apply drift, not a create blocker - see Known issues. |
| 13 | `Audit-AppGW-WAF`, `Audit-PeDnsZones`, `Audit-*`, `Deploy-*` (VM/SQL/MDFC/backup DINE), all `Enforce-Guardrails-*` (`DoNotEnforce`) | globaris/landingzones/corp | Audit / DINE / DoNotEnforce | various | **NOISE.** Audit never blocks; the guardrail initiatives are all `DoNotEnforce`; the Deploy/Enforce-ASR DINE remediate post-apply (mostly need VMs, which the spokes do not create). |

**Net:** four hard blockers (rows 1-4). Rows 5-11 verified PASS. Rows 12-13 NOISE.

---

## 3. Cross-root input prerequisites - CI Secrets / connectivity outputs

`gh secret list` (2026-07-10) vs the `TF_VAR_*` map in `.github/workflows/_tf-root.yml`, cross-checked
against live connectivity/management resources. Non-secret inputs (`org_prefix`, `private_dns_rg_name`,
`flow_log_retention_days`, `app_service_sku`, `waf_mode`, `appgw_capacity`, `rsv_geo_redundant`) come from
`envs/poc.tfvars` and are present/correct.

| Secret / input | Present? | Live cross-check | Verdict |
|---|---|---|---|
| `LANDINGZONES_SUBSCRIPTION_ID` | yes | sub `<subscription-id>` exists | OK |
| `CONNECTIVITY_SUBSCRIPTION_ID` | yes | sub `<subscription-id>` exists | OK |
| `PRIMARY_HUB_VNET_ID` / `_NAME` / `_RG_NAME` | yes (set 2026-07-08) | `vnet-hub-primary-globaris-poc` in `rg-connectivity-primary-globaris-poc` exists | OK (values not readable; deterministic name confirmed live) |
| `SECONDARY_HUB_VNET_ID` / `_NAME` / `_RG_NAME` | yes | `vnet-hub-secondary-globaris-poc` in `rg-connectivity-secondary-globaris-poc` exists | OK |
| `PRIMARY_FIREWALL_PRIVATE_IP` | yes (set 2026-07-07) | `fw-hub-eastus2-001` private IP = **`10.0.0.4`** | OK - **operator should confirm the secret holds `10.0.0.4`** (prior-session "unverified" flag now resolved: live value is 10.0.0.4) |
| `SECONDARY_FIREWALL_PRIVATE_IP` | yes | `fw-hub-centralus-001` private IP = **`10.1.0.4`** | OK - **confirm the secret holds `10.1.0.4`** |
| `PLATFORM_LAW_WORKSPACE_ID` | yes | `law-platform-globaris-poc` in `rg-management-globaris-poc` exists | OK |
| `PLATFORM_LAW_CUSTOMER_ID` | yes | live `customerId = <law-customer-id>` | OK - confirm the secret equals this GUID (Traffic Analytics needs the customerId, not the ARM id) |
| `PLATFORM_ACTION_GROUP_ID` | yes | consumed only by unused `platform_action_group_id` var | OK (not on a create path) |
| **`SQL_AAD_ADMIN_OBJECT_ID`** | **MISSING** | consumed by `azurerm_mssql_server.azuread_administrator.object_id` (corp-a1, corp-a2) | **BLOCKER (corp-a1, corp-a2).** Unset secret -> `TF_VAR_sql_aad_admin_object_id=""` -> empty object_id -> SQL server create rejected (invalid principal GUID). |
| **`SQL_AAD_ADMIN_LOGIN`** | **MISSING** | consumed by `azuread_administrator.login_username` | **BLOCKER (corp-a1, corp-a2).** Same class. Set both to a real Entra group (recommended: a "sql-admins" group objectId + display name). online-p1 has no SQL -> unaffected. |
| `private_dns_rg_name` (tfvars) | yes = `rg-dns-globaris-poc` | zone `privatelink.database.windows.net` lives in `rg-dns-globaris-poc` (connectivity sub) | OK - the SQL PE zone-group + VNet-link data source resolves |

---

## 4. Tenant / subscription prerequisites

| Prerequisite | Verified | Verdict |
|---|---|---|
| RP `Microsoft.Network` @ LZ sub | Registered | OK |
| RP `Microsoft.Sql` @ LZ sub | Registered | OK |
| RP `Microsoft.Storage` @ LZ sub | Registered | OK |
| RP `Microsoft.Web` @ LZ sub | Registered | OK (App Service, Static Web App, App Gateway backend FQDN) |
| RP `Microsoft.OperationalInsights` / `microsoft.insights` @ LZ sub | Registered | OK (diagnostics / Traffic Analytics) |
| **RP `Microsoft.RecoveryServices` @ LZ sub** | **NotRegistered** | **BLOCKER (corp-a1, corp-a2).** RSV create needs it. The spoke provider is `features {}` only = azurerm v4 default `resource_provider_registrations="core"`; `Core()` in the provider's `required.go` (verified on `main`) does **NOT** include `Microsoft.RecoveryServices` (it is only in `Extended()`/`Legacy()`/`All()`), so the provider will **not** auto-register it. Operator must register it first. online-p1 has no RSV -> unaffected. |
| **Network Watcher `NetworkWatcher_eastus2` @ LZ sub** | **MISSING** | **BLOCKER (corp-a1, online-p1).** LZ sub has `NetworkWatcher_eastus`, `_westus`, `_centralus` but **no `_eastus2`**, and the sub currently has zero VNets. The flow-log `data.azurerm_network_watcher.primary` (name `NetworkWatcher_eastus2`, static args, default = LZ provider) resolves at **plan** time, before the spoke VNet exists -> "not found" -> plan fails. `NetworkWatcher_centralus` exists -> corp-a2 PASS. |
| SQL Entra admin principal exists | depends on the value chosen for the two missing SQL secrets | Ensure the objectId is a real Entra user/group in this tenant before corp-a1 apply. |
| CI SP RBAC @ LZ sub | Contributor + User Access Administrator (direct); Owner + Resource Policy Contributor + UAA inherited from globaris MG | OK - can create every spoke resource type, write role assignments, and (Resource Policy Contributor) write the DDoS DoNotEnforce + any exemptions. |

---

## 5. Known issues harvest (spoke + AVM patterns in play)

- **DDoS Modify placeholder trap** (row 1) - Enterprise-Scale #1053/#983, ALZ-Bicep #181/#596; already
  root-caused for this estate in ADR-026. The `landingzones` MG assignment was never neutralised (only the
  `connectivity` MG was), so it is still live. This is the single most important item.
- **`Deploy-Private-DNS-Zones` DINE vs the spoke's own PE DNS zone group** (row 12) - the corp-MG ALZ DINE
  policy remediates private endpoints by adding an ALZ-managed `privateDnsZoneGroups` entry pointing at the
  connectivity-sub zones. The spoke SQL PE already wires its own `private_dns_zone_group` to the same
  `privatelink.database.windows.net` zone. Both target the same zone so records converge, but expect a
  benign post-apply remediation task and possible Terraform drift on the PE's `private_dns_zone_group` on a
  later plan. Not a create blocker. Watch on the next `plan` after apply.
- **RSV `parent_id`/scope 404** - the identity RSV hit an azapi `parent_id` resolution issue (see the
  identity worklog). The spoke RSVs use `Azure/avm-res-recoveryservices-vault` **1.1.3** with
  `resource_group_name` (not azapi `parent_id`), so that specific failure class does not apply. The
  `Microsoft.RecoveryServices` RP registration (section 4) is the real RSV gate here.
- **App Gateway WAF_v2 + PIP** - WAF_v2 mandates a Standard, static, zonal public IP (the root provides
  exactly that) and a dedicated `snet-appgateway` with **no** UDR to an NVA (the root correctly omits the
  route table on that subnet and attaches an NSG allowing GatewayManager 65200-65535 + AzureLoadBalancer).
  No policy denies the standalone PIP on this chain (rows 6-7). No known blocker beyond capacity/quota
  (capacity=1, within default limits).
- **Flow-log SA + public access** - NSG flow logs deliver via the Network Watcher service. Fully disabling
  the SA public network access can break flow-log delivery unless trusted-Microsoft-services bypass is
  arranged; this is why row 2's fix is a decision (OQ-024), not an automatic "set public access = Disabled".

---

## 6. The critical fix spec - DDoS DoNotEnforce at the `landingzones` MG (do NOT implement here)

**Lane:** cloud-engineer (or devsecops), root **`platform/management-groups`**, code-reviewer gates.
**Change:** extend the existing `policy_assignments_to_modify` in `platform/management-groups/main.tf`
(currently only `connectivity`) to also neutralise the same assignment at the `landingzones` MG:

```hcl
policy_assignments_to_modify = {
  connectivity = {
    policy_assignments = {
      "Enable-DDoS-VNET" = { enforcement_mode = "DoNotEnforce" }
    }
  }
  landingzones = {                       # ADD - unblocks all spoke VNet creates
    policy_assignments = {
      "Enable-DDoS-VNET" = { enforcement_mode = "DoNotEnforce" }
    }
  }
}
```

Governing decision: **ADR-026** (this is a direct extension of it - same policy, same rationale, next MG
down; warrants an ADR-026 amendment note, not a new decision). Schema: `Azure/avm-ptn-alz` 0.19.1
`policy_assignments_to_modify` (map keyed by MG name -> `policy_assignments` -> assignment-name ->
`{ enforcement_mode }`; allowed `Default` | `DoNotEnforce`). This root must be **applied before any spoke**.
Verify after apply: `az policy assignment show --name Enable-DDoS-VNET --scope
/providers/Microsoft.Management/managementGroups/landingzones --query enforcementMode` returns
`DoNotEnforce`. Reversible; when DDoS Standard is later enabled, re-enforce and supply a real `ddosPlan`
(the coupling tracked in OQ-019).

---

## 7. Per-spoke verdict and ordered actions

### corp-a1 (deploy first, the pattern) - **BLOCKED**

Ordered actions before apply:
1. **DDoS (matrix #1):** apply the section-6 change in `platform/management-groups` (cloud-engineer +
   review), then re-apply that root. Confirm `Enable-DDoS-VNET` = `DoNotEnforce` at `landingzones` MG.
2. **corp public-PaaS collisions (matrix #2, #3):** resolve **OQ-024** (recommended default: RG-scoped
   Waiver exemptions on `rg-corp-a1-network-*` for `StorageDenyPaasPublicIP` and on `rg-corp-a1-workload-*`
   for `AsDenyPublicIP`, ADR-028 pattern, IaC-managed in the spoke root). Implement the chosen option
   (cloud-engineer/devsecops + review).
3. **snet-integration NSG (matrix #4):** cloud-engineer attaches `azurerm_network_security_group.spoke` to
   the `integration` subnet in `corp-a1/main.tf` (App Service delegated subnets support NSGs), OR exempt via
   OQ-024. Recommended: attach the NSG (correct posture, no exemption sprawl).
4. **SQL Entra admin secrets (section 3):** operator sets repo Secrets `SQL_AAD_ADMIN_OBJECT_ID` (objectId
   of a real Entra group/user) and `SQL_AAD_ADMIN_LOGIN` (its display name/UPN).
5. **RecoveryServices RP (section 4):** operator runs
   `az provider register --namespace Microsoft.RecoveryServices --subscription <subscription-id>`
   and waits for `Registered` (~1-2 min). Covers corp-a2 too (same sub).
6. **NetworkWatcher_eastus2 (section 4):** operator runs
   `az network watcher configure --locations eastus2 --enabled true --subscription <subscription-id>`
   (creates `NetworkWatcher_eastus2` in `NetworkWatcherRG`) before the plan.
7. Confirm `PRIMARY_FIREWALL_PRIVATE_IP=10.0.0.4` and `PLATFORM_LAW_CUSTOMER_ID=<law-customer-id>` in Secrets.
8. Deploy: `deploy.yml` target `landing-zones/corp-a1`, action `plan` (gate the plan: VNet create shows no
   injected `ddosProtectionPlan`, `snet-integration` has an NSG, SQL server has a non-empty AAD admin, RSV
   plans clean), then action `apply`.

### corp-a2 (DR, deploy second) - **BLOCKED**

Same blocker set as corp-a1 **except** NetworkWatcher (centralus watcher already exists -> skip action 6).
Its RSV is GeoRedundant. Ordered actions = corp-a1 actions 1-5, 7-8 with the corp-a2 RGs
(`rg-corp-a2-network-*`, `rg-corp-a2-workload-*`) and `SECONDARY_FIREWALL_PRIVATE_IP=10.1.0.4`. Actions 4
and 5 are already satisfied if corp-a1 completed them (same Secrets, same sub). Deploy target
`landing-zones/corp-a2`.

### online-p1 (deploy third) - **BLOCKED**

Fewer blockers (no SQL, no App Service, no RSV):
1. **DDoS (matrix #1):** same section-6 fix (shared; already done if corp-a1 ran). Required.
2. **Flow-log SA public-PaaS deny (matrix #2):** resolve OQ-024; exemption on `rg-online-p1-network-*` for
   `StorageDenyPaasPublicIP` (or chosen option).
3. **NetworkWatcher_eastus2 (section 4):** required (eastus2) - same as corp-a1 action 6 (shared; already
   done if corp-a1 ran).
4. Not blocking: App Gateway PIP (matrix #6, #7 PASS), subnets all have NSGs (matrix #4 PASS), no SQL secrets
   needed, no RecoveryServices RP needed.
5. Deploy target `landing-zones/online-p1`, plan then apply.

---

## 8. Open question raised

**OQ-024** - the `corp`-MG `Deny-Public-Endpoints` (Deny-PublicPaaSEndpoints, effect Deny) collides with the
spoke public-PaaS resources (flow-log storage accounts on all 3; App Services on corp-a1/a2), and
`Deny-Subnet-Without-Nsg` collides with corp `snet-integration`. Options (recommended default: **A + attach
NSG**):

- **A. RG-scoped Waiver policy exemptions** (ADR-028 precedent) on the specific spoke RGs for the
  `StorageDenyPaasPublicIP` / `AsDenyPublicIP` member refs, IaC-managed in each spoke root. Keeps the SQL
  member Deny fully enforced (spoke SQL is already private), narrowest blast radius, auditable. For the
  subnet: **attach the spoke NSG to `snet-integration`** (a code fix, no exemption). *Recommended.*
- **B. Disable public network access** on the flow-log SAs and App Services. Rejected as a default - can
  break NSG flow-log delivery and changes the App Service reachability model without validation.
- **C. Set the initiative Storage/AppService effect params to `Audit`/`Disabled` at the corp assignment.**
  Rejected - weakens governance for the entire corp archetype to admit three POC resources.

Also parks the topology mismatch (an "online" archetype workload under the `corp` MG) for a later decision;
does not block deploy.

---

# ADDENDUM 2026-07-21: SUPERSEDED for the 2026-07-22 full-estate rebuild

Everything above is HISTORY from 2026-07-10. Its live evidence predates the 2026-07-16 build and the two
teardowns since, and it contains identifiers that current house rules keep out of committed docs. Do not
use it as a gate.

The current gate for `landing-zones/corp-a1`, `landing-zones/corp-a2` and `landing-zones/online-p1` is
**[`docs/preclearance/2026-07-22-full-estate-rebuild.md`](2026-07-22-full-estate-rebuild.md)**,
conditions **PC-1S..PC-9S** (plus the whole-run conditions PC-1X..PC-8X).

Headline deltas versus this document:

- **Verdict: GO-CONDITIONAL for all three.** No blocker specific to these roots, but they **cannot be
  dry-planned** while the estate is torn down: `data.azurerm_private_dns_zone` resolves against
  `rg-dns-globaris-poc`, which does not exist until `platform/connectivity` applies. The new gate states
  per root which conditions are verifiable pre-apply and which are not, and replaces the count-based bar
  with a shape-based one (exit status 0, zero `Error:` diagnostics, pure adds, zero change/destroy/replace).
- **The `azurerm_network_watcher` data source is NOT a blocker.** Re-verified live 2026-07-21:
  `NetworkWatcher_eastus2` and `NetworkWatcher_centralus` both exist in `NetworkWatcherRG` in the
  landingzones subscription.
- **The four hard blockers of section 2 are all closed in code**: `Enable-DDoS-VNET` is set DoNotEnforce
  at the landingzones MG as well as connectivity; the flow-log storage collision carries the RG-scoped
  Waiver plus a 300s sleep; `snet-integration` now carries the spoke NSG; the App Service collision is
  moot because `enable_app_service` is false (ADR-032). `enable_sql` is likewise false (ADR-031), so the
  once-missing SQL admin Secrets are not on a create path (they exist anyway, set 2026-07-10).
- **Cross-root Secret finding:** every Secret in section 3 except `PLATFORM_LAW_CUSTOMER_ID` is derived
  from names that have not changed since 2026-07-07, and all of them have now survived two full rebuild
  cycles unchanged. Only `PLATFORM_LAW_CUSTOMER_ID` gets an unconditional re-set (PC-2X).
- **Standing caveat:** these three roots have not been applied since 2026-07-10, the longest gap of any
  root in the rebuild. Treat their plan-scan as a first-ever plan.
