# Estate Bill of Materials (BOM) - Regression Baseline

**Captured:** 2026-08-01, approximately 30-45 minutes after the 14-step rebuild (Step 14 GREEN). Region-flip build: centralus primary, eastus2 secondary/DR (ADR-069).

**Purpose:** mechanical baseline for comparing a future teardown-and-rebuild cycle against this estate. Every section states what a diff should check and how to tell real drift from expected non-determinism.

**Scope:** the 5 estate subscriptions - `sub-connectivity-poc-01`, `sub-identity-poc-01`, `sub-landingzones-poc-01`, `sub-management-poc-01`, `sub-security-poc-01` - plus tenant-level management groups and policy objects. `sub-app-01` and `sub-avd-poc-01` are explicitly OUT of scope (confirmed: both sit directly under Tenant Root Group, not under the `globaris` hierarchy at all).

**Identifiers:** all subscription IDs, tenant ID, and principal IDs are redacted to abstract references below (per standing repo rule). Where an ID is structurally necessary it is shown as a placeholder. Subscription IDs are actually STABLE across rebuilds in this estate (the 5 subscriptions are pre-provisioned, not created by Terraform) but are still redacted from this committed document.

---

## 0. Exclusions (recorded, not compared)

These persist across teardown/rebuild cycles because they are protected from destroy. Comparing them would produce false diffs; they are recorded here so a future operator does not re-discover this the hard way.

| Excluded item | Where | Why |
|---|---|---|
| `NetworkWatcherRG` | every subscription (one each, auto-created by Azure per region used) | Azure-managed, recreated automatically the moment any resource in a region needs a Network Watcher; not Terraform-owned |
| `rg-tfstate-mgmt-eus2-001` | `sub-management-poc-01`, eastus2 | Bootstrap Terraform state backend (storage account `stglobaristfstate01`, Key Vault `kv-globaris-tfstate-01`, a managed identity `id-tfstate-mgmt-eus2-001`, a metric alert). Deliberately outside the 14-step rebuild's blast radius; must survive every teardown or there is no way to redeploy |

**Also observed, not part of either the protected set or the IaC estate (a genuine stray, already known):**

| Item | Where | Status |
|---|---|---|
| `cloud-shell-storage-southcentralus` | `sub-landingzones-poc-01`, region southcentralus | Empty resource group (0 resources inside it), left over from someone launching Azure Cloud Shell against this subscription at some point. Not Terraform-managed, not in the protected-exclusion list either. Previously noted in `docs/preclearance/b1-bank-spokes.md` as a "stray, no name collision." Confirm on every future rebuild that this stays empty and does not silently accumulate a storage account - if teardown automation only walks Terraform state, this RG is invisible to it and could persist indefinitely. |
| `adf-enterprise-rg` | previously noted in the same preclearance doc as a second stray | No longer present - confirmed gone (`az group exists` = false). Whatever created it is not currently recurring. Worth knowing it existed once, in case it reappears. |

---

## 1. THE HARD PROBLEM: non-deterministic names, found by reading the code, not by trusting the prompt's list

Every item below was confirmed either as a live resource name (with an actual random-looking suffix) or as a `random_id`/`random_uuid`/Azure-generated-suffix construct in the Terraform source. **Comparison rule for all of them: match by prefix (the deterministic part before the suffix) and by count, never by literal full name.**

### 1.1 `random_id` resources in the Terraform source (grepped for `resource "random_id"` across the whole repo)

| Terraform resource | File | Byte length | Live example seen this cycle | Notes |
|---|---|---|---|---|
| `random_id.security_kv` | `platform/security/main.tf:97` | 4 | `kv-sec-globaris-1f0d6f8d` | Key Vault, unconditional |
| `random_id.finops_sa` | `platform/management/main.tf:122` | 4 | `stfinopspoc824266c1` | FinOps storage account, unconditional |
| `random_id.mdc_eh_namespace` | `platform/security/defender.tf:86` | 3 | `evhns-mdc-globaris-6be9f7` | Only exists when `enable_mdc_event_hub_export = true` (it IS true in this build) |
| `random_id.datalake_sa` | `landing-zones/bank-data-p1/datalake.tf:33` | 4 | `stlakepocbdp10a9340e9` | Only when `enable_data_platform = true` |
| `random_id.dbfs_sa` | `landing-zones/bank-data-p1/databricks.tf:36` | 4 | N/A - see 1.3, this SA is actually created by Databricks itself, not this Terraform resource, in this build's node RG | Only when `enable_data_platform = true` |
| `random_id.flowlog_sa` | one per spoke: `corp-a1/dns_links.tf:52`, `corp-a2/dns_links.tf:53`, `online-p1/dns_links.tf:43`, `bank-data-p1/dns_links.tf:68`, `bank-app-p1/dns_links.tf:59` | 4 | `stflowpoca178241a2f`, `stflowpoca2b9b9d99f`, `stflowp1poc9804f877`, `stflowpocbdp187781f54`, `stflowpocbap17c02fbe1` | Five instances, one per spoke. Note the online-p1 prefix is `stflowp1poc` (not `stflowpoconlinep1`) - naming module abbreviation, not a bug |
| `random_id.sql_suffix` | `corp-a1/main.tf:325`, `corp-a2/main.tf:319` | 4 | Does not exist live | `count = var.enable_sql ? 1 : 0`, and `enable_sql = false` in this build - correctly absent, see Section 7 |

### 1.2 `random_uuid` resources - found by grep, NOT on the prompt's known list

| Terraform resource | File | What it names | Live example |
|---|---|---|---|
| `random_uuid.workbooks` (for_each over 4 Sentinel workbooks) | `platform/security/sentinel.tf:572` | The 4 Sentinel workbook resource names in `rg-security-globaris-poc` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `random_uuid.telemetry` (AVM internal, multiple modules under `platform/management`) | `.terraform/modules/amba*/main.telemetry.tf` | AVM's own modtm telemetry pseudo-resource IDs | Not a real Azure resource - Terraform-only, no ARM footprint |
| `random_uuid.role_assignment_name` / `..._private_endpoint` (AVM internal, AMBA module) | `.terraform/modules/amba.resource_group.interfaces/main.role_assignments.tf` | Names (GUIDs) of the DINE remediation role assignments the AMBA module creates | Real RBAC role assignment GUIDs, will differ every apply |
| `random_uuid.query_name` (AVM internal, LAW query packs module) | `.terraform/modules/platform_law/modules/query_packs/main.tf:14` | Saved-search/query names, only if a query object omits an explicit name | Conditional, not exercised unless query packs are added without names |

**Important nuance found only by reading the code, not assumable from the workbook resource type alone:** NOT all workbooks in this estate are non-deterministic. `platform/management/main.tf` computes `local.carbon_workbook_id = uuidv5("dns", "carbon-optimization.${var.org_prefix}")` and `local.platform_workbook_id = uuidv5(...)` - a **deterministic** hash, explicitly to "avoid random resource replacement" (comment in the source). Live names confirmed stable-by-formula: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (platform overview, in `rg-management-globaris-poc`) and `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (carbon optimization, in `rg-finops-globaris-poc`). **Only the 4 Sentinel workbooks in the security subscription are non-deterministic; the 2 management-subscription workbooks are deterministic and should be compared by exact name.**

### 1.3 Azure-generated suffixes (not Terraform `random_*`, but still change every rebuild)

| Resource | Where | Live example | Why non-deterministic |
|---|---|---|---|
| AKS node RG contents | `rg-bank-app-p1-aks-nodes-globaris-poc` | `aks-agentpool-24005234-nsg`, `aks-systempool-33026936-vmss` | Azure/AKS assigns a numeric hash suffix to the auto-managed NSG and VMSS in the node resource group; not controllable from the cluster spec |
| Private endpoint NICs (most services) | throughout `sub-landingzones-poc-01` | `pe-srch-bank-data-p1-globaris-poc.nic.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, `kube-apiserver.nic.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, etc. (7 of 8 PE NICs follow this pattern) | Azure appends `.nic.<GUID>` to the PE's own (deterministic) NIC name. Compare by the prefix before `.nic.`, one NIC per PE, GUID ignored. One exception observed: the Cognitive Services/Foundry PE's NIC (`nic-account--pe-aif-bank-data-p1-globaris-poc`) has NO GUID suffix - a different AVM module version's naming convention. Do not assume all PE NICs follow the suffix pattern; verify per service. |
| Databricks managed RG contents | `rg-bank-data-p1-dbx-managed-globaris-poc` | `dbstorage8b08db8f` (random); `dbmanagedidentity`, `databricks-nsp` (both fixed, NOT random) | Only the DBFS storage account name is Azure-generated-random inside this RG; the managed identity and network security perimeter names are fixed by Databricks convention |
| Databricks VNet-injection network intent policies | `rg-bank-data-p1-network-globaris-poc` | `adb-centralus-npip-d320b89458e758044cfd82bc`, `adb-centralus-npip-7e9e7d786a7d325621b2559f` | Auto-created by the Databricks control plane when injected into a customer VNet, long hex suffix, not exposed in the workspace's Terraform config at all |
| AMBA/monitoring Data Collection Endpoint and Rule names - found by inspection, not on any known list | `rg-management-globaris-poc` | `NWTA-<law-customer-id-derived>` (DCE), `NWTA-<law-customer-id>-<suffix>RH04VX` (DCR) | The name is built from the platform LAW's `customerId` GUID, which is itself regenerated every time the LAW is destroyed and recreated (see 1.4). So these two resources are non-deterministic without using any `random_*` resource at all - they inherit volatility from a sibling resource's generated identity. This is exactly the kind of gap the prompt asked to hunt for. |

### 1.4 Generated GUIDs / timestamps (not resource names, but values that will differ)

| Value | Where | Live value (redacted) | Comparison rule |
|---|---|---|---|
| LAW `customerId` (workspace ID) | both `law-platform-globaris-poc` and `law-security-globaris-poc` | a GUID, e.g. `16957b9c-...` | Never compare literally; only check it is a well-formed GUID and non-null |
| AADDS `deploymentId` | `aadds-globaris-poc` | a GUID | Same - existence/well-formedness only |
| Resource IDs generally | everywhere | contain the subscription ID | Subscription IDs are actually STABLE across rebuilds in this estate (pre-provisioned, not Terraform-created) - but full resource IDs should still never be used as the comparison key; compare on name + resource group + type, which is portable and does not require redaction |
| Policy-injected `CreatedDate` tag | most resources (OQ-032) | a date string set by an Azure Policy modify effect | Accepted, benign drift (per OQ-032 / LESSON 38) - excluded from any tag-level diff |

---

## 2. Per-subscription, per-resource-group resource counts (ARM top-level resources)

**Methodology note, important for anyone re-running this:** `az resource list` returns only top-level ARM resources visible through the generic Resources provider. It does NOT enumerate: subnets (child of a VNet), NSG/route-table subnet associations, VNet peerings, RBAC role assignments, diagnostic settings (extension resources), or anything at management-group/policy scope. This is why the totals below are much smaller than the Terraform plan/apply counts in Section 6 - that gap is expected, not a discrepancy. Sections 3, 4, and 8 cover the constructs this method is blind to.

### 2.1 `sub-connectivity-poc-01` (excluding `NetworkWatcherRG`)

| Resource group | Type | Count |
|---|---|---|
| `rg-connectivity-primary-globaris-poc` | `Microsoft.Network/virtualNetworks` | 1 |
| `rg-connectivity-primary-globaris-poc` | `Microsoft.Network/azureFirewalls` | 1 |
| `rg-connectivity-primary-globaris-poc` | `Microsoft.Network/firewallPolicies` | 1 |
| `rg-connectivity-primary-globaris-poc` | `Microsoft.Network/publicIPAddresses` | 1 |
| `rg-connectivity-primary-globaris-poc` | `Microsoft.Network/routeTables` | 2 |
| `rg-connectivity-secondary-globaris-poc` | `Microsoft.Network/virtualNetworks` | 1 |
| `rg-connectivity-secondary-globaris-poc` | `Microsoft.Network/azureFirewalls` | 1 |
| `rg-connectivity-secondary-globaris-poc` | `Microsoft.Network/firewallPolicies` | 1 |
| `rg-connectivity-secondary-globaris-poc` | `Microsoft.Network/publicIPAddresses` | 1 |
| `rg-connectivity-secondary-globaris-poc` | `Microsoft.Network/routeTables` | 2 |
| `rg-dns-globaris-poc` | `Microsoft.Network/privateDnsZones` | 90 |
| `rg-dns-globaris-poc` | `Microsoft.Network/privateDnsZones/virtualNetworkLinks` | 193 |

Subscription total (RG-scoped, excluding `NetworkWatcherRG`): **295**. Dominated by private DNS for the whole estate's private endpoints, centralized at one hub RG. Plus 1 `Microsoft.Consumption/budgets` (subscription-scoped, not RG-scoped).

### 2.2 `sub-identity-poc-01` (excluding `NetworkWatcherRG`)

| Resource group | Type | Count |
|---|---|---|
| `rg-identity-network-globaris-poc` | `Microsoft.Network/virtualNetworks` | 1 |
| `rg-identity-network-globaris-poc` | `Microsoft.Network/networkSecurityGroups` | 1 |
| `rg-identity-aadds-globaris-poc` | `Microsoft.AAD/DomainServices` | 1 |
| `rg-identity-aadds-globaris-poc` | `Microsoft.RecoveryServices/vaults` | 1 |
| `rg-identity-aadds-globaris-poc` | `Microsoft.Network/publicIPAddresses` | 1 |
| `rg-identity-aadds-globaris-poc` | `Microsoft.Network/loadBalancers` | 1 |
| `rg-identity-aadds-globaris-poc` | `Microsoft.Network/networkInterfaces` | 2 |

Subscription total (RG-scoped): **8**. Plus 1 `Microsoft.Consumption/budgets` (subscription-scoped).

### 2.3 `sub-landingzones-poc-01` (excluding `NetworkWatcherRG`), by type across the whole subscription

| Type | Count |
|---|---|
| `Microsoft.Network/networkSecurityGroups` | 9 |
| `Microsoft.Network/privateEndpoints` | 8 |
| `Microsoft.Network/networkInterfaces` | 8 |
| `Microsoft.Storage/storageAccounts` | 7 |
| `Microsoft.Network/routeTables` | 6 |
| `Microsoft.Network/virtualNetworks` | 5 |
| `Microsoft.Network/networkWatchers/flowLogs` | 5 |
| `Microsoft.ManagedIdentity/userAssignedIdentities` | 4 |
| `Microsoft.RecoveryServices/vaults` | 2 |
| `Microsoft.Network/networkIntentPolicies` | 2 (Databricks-injected, non-deterministic names, see 1.3) |
| `Microsoft.Web/staticSites` | 1 |
| `Microsoft.ServiceBus/namespaces` | 1 |
| `Microsoft.Search/searchServices` | 1 |
| `Microsoft.Network/publicIPAddresses` | 1 |
| `Microsoft.Network/networkSecurityPerimeters` | 1 |
| `Microsoft.Network/applicationGatewayWebApplicationFirewallPolicies` | 1 |
| `Microsoft.Network/applicationGateways` | 1 |
| `Microsoft.Fabric/capacities` | 1 |
| `Microsoft.EventHub/namespaces` | 1 |
| `Microsoft.Databricks/workspaces` | 1 |
| `Microsoft.Databricks/accessConnectors` | 1 |
| `Microsoft.ContainerService/managedClusters` | 1 |
| `Microsoft.ContainerRegistry/registries` | 1 |
| `Microsoft.Compute/virtualMachineScaleSets` | 1 (AKS node pool, in the node RG) |
| `Microsoft.CognitiveServices/accounts` | 1 |
| `Microsoft.ApiManagement/service` | 1 |

Subscription total (RG-scoped): **76**. Plus 1 `Microsoft.Consumption/budgets` (subscription-scoped).

By resource group (RG existence + count, deterministic RG names, all `Succeeded`):

| Resource group | Count |
|---|---|
| `rg-bank-data-p1-workload-globaris-poc` | 13 |
| `rg-bank-app-p1-shared-globaris-poc` | 10 |
| `rg-online-p1-network-globaris-poc` | 8 |
| `rg-bank-data-p1-network-globaris-poc` | 7 |
| `rg-bank-app-p1-network-globaris-poc` | 6 |
| `rg-bank-app-p1-aks-nodes-globaris-poc` | 6 |
| `rg-corp-a2-network-globaris-poc` | 4 |
| `rg-corp-a1-network-globaris-poc` | 4 |
| `rg-bank-data-p1-dbx-managed-globaris-poc` | 3 |
| `rg-bank-app-p1-workload-globaris-poc` | 2 |
| `rg-online-p1-workload-globaris-poc` | 1 |
| `rg-corp-a2-shared-globaris-poc` | 1 |
| `rg-corp-a1-shared-globaris-poc` | 1 |
| `rg-bank-data-p1-shared-globaris-poc` | 1 |
| `rg-corp-a1-monitoring-globaris-poc`, `rg-corp-a2-monitoring-globaris-poc`, `rg-online-p1-monitoring-globaris-poc`, `rg-bank-data-p1-monitoring-globaris-poc`, `rg-bank-app-p1-monitoring-globaris-poc` | 0 each - RG exists, no top-level ARM resources land in it (monitoring for spokes is diagnostic-settings-only, pointed at the two central LAWs; nothing to enumerate this way) |

Plus `cloud-shell-storage-southcentralus` (0 resources, stray, see Section 0).

### 2.4 `sub-management-poc-01` (excluding `NetworkWatcherRG` and `rg-tfstate-mgmt-eus2-001`)

| Resource group | Type | Count |
|---|---|---|
| `rg-management-globaris-poc` | `Microsoft.Insights/actiongroups` | 1 |
| `rg-management-globaris-poc` | `Microsoft.Portal/dashboards` | 1 |
| `rg-management-globaris-poc` | `Microsoft.Automation/automationAccounts` | 1 |
| `rg-management-globaris-poc` | `Microsoft.OperationalInsights/workspaces` | 1 |
| `rg-management-globaris-poc` | `Microsoft.Insights/workbooks` | 1 |
| `rg-management-globaris-poc` | `Microsoft.Insights/dataCollectionEndpoints` | 1 |
| `rg-management-globaris-poc` | `Microsoft.Insights/dataCollectionRules` | 1 |
| `rg-management-globaris-poc` | `Microsoft.OperationsManagement/solutions` | 1 |
| `rg-finops-globaris-poc` | `Microsoft.Storage/storageAccounts` | 1 |
| `rg-finops-globaris-poc` | `Microsoft.Insights/workbooks` | 1 |
| `rg-amba-monitoring-001` | `Microsoft.ManagedIdentity/userAssignedIdentities` | 1 |

Subscription total (RG-scoped): **11**. Plus 1 `Microsoft.Consumption/budgets` (subscription-scoped, not RG-scoped - not visible via `az resource list`, see Section 7).

### 2.5 `sub-security-poc-01`

| Resource group | Type | Count |
|---|---|---|
| `rg-security-globaris-poc` | `Microsoft.EventHub/namespaces` | 1 |
| `rg-security-globaris-poc` | `Microsoft.OperationalInsights/workspaces` | 1 |
| `rg-security-globaris-poc` | `Microsoft.KeyVault/vaults` | 1 |
| `rg-security-globaris-poc` | `Microsoft.Security/automations` | 1 |
| `rg-security-globaris-poc` | `Microsoft.OperationsManagement/solutions` | 1 |
| `rg-security-globaris-poc` | `Microsoft.Insights/workbooks` | 4 |

Subscription total (RG-scoped): **9**. Plus 1 `Microsoft.Consumption/budgets` (subscription-scoped).

### 2.6 Estate total via this method

**404 top-level ARM resources**: 295 + 8 + 76 + 11 + 9 = 399 RG-scoped resources, plus 5 subscription-scoped `Microsoft.Consumption/budgets` (one per subscription, $200 each, confirmed via `az consumption budget list`) not visible to `az resource list` = 404. Spans 30 comparable resource groups (excluding the 5 `NetworkWatcherRG`, the bootstrap state RG, and the stray Cloud Shell RG).

This number is NOT the same as the rebuild WORKLOG's resource-count language - see Section 6 for why, and do not try to reconcile them to a single figure; they measure different things.

---

## 3. Explicit named inventories - the low-count, high-value resources

All confirmed live, by exact name, with health/state.

| Resource | Name | Resource group | Region | State |
|---|---|---|---|---|
| Hub VNet (primary) | `vnet-hub-primary-globaris-poc` | `rg-connectivity-primary-globaris-poc` | centralus | exists, 2 subnets (`AzureFirewallSubnet`, `snet-dns-resolver-outbound` - reserved, resolver not deployed) |
| Hub VNet (secondary/DR) | `vnet-hub-secondary-globaris-poc` | `rg-connectivity-secondary-globaris-poc` | eastus2 | exists, 1 subnet (`AzureFirewallSubnet` only - no reserved resolver subnet here, asymmetric by design) |
| Firewall (primary) | `fw-hub-centralus-001` | `rg-connectivity-primary-globaris-poc` | centralus | Succeeded, Premium, zones `1,2,3`, private IP `10.0.0.4` |
| Firewall (secondary/DR) | `fw-hub-eastus2-001` | `rg-connectivity-secondary-globaris-poc` | eastus2 | Succeeded, Premium, zones `1,2,3`, private IP `10.1.0.4` |
| Firewall policy (primary) | `fwp-hub-centralus-001` | `rg-connectivity-primary-globaris-poc` | centralus | Premium tier |
| Firewall policy (secondary) | `fwp-hub-eastus2-001` | `rg-connectivity-secondary-globaris-poc` | eastus2 | Premium tier |
| AADDS managed domain | `aadds-globaris-poc` (domain `aadds.globaris.org`) | `rg-identity-aadds-globaris-poc` | centralus | provisioningState Succeeded, Standard SKU, 1 replica set (Central US) |
| RSV (primary spoke, corp-a1) | `rsv-corp-a1-globaris-poc` | `rg-corp-a1-shared-globaris-poc` | centralus | storage redundancy `ZoneRedundant`, cross-region restore `false` |
| RSV (DR spoke, corp-a2) | `rsv-corp-a2-globaris-poc` | `rg-corp-a2-shared-globaris-poc` | eastus2 | storage redundancy `GeoRedundant`, cross-region restore `true` |
| App Gateway | `appgw-online-p1-globaris-poc` | `rg-online-p1-network-globaris-poc` | centralus | Succeeded, operational state `Running`, SKU `WAF_v2`, capacity 1 |
| WAF policy | `wafpol-online-p1-globaris-poc` | `rg-online-p1-network-globaris-poc` | (attached to App Gateway) | mode `Prevention`, state `Enabled` |
| APIM | `apim-bank-app-p1-globaris-poc` | `rg-bank-app-p1-shared-globaris-poc` | Central US | Succeeded, Developer SKU, public network access Enabled (Developer SKU management-plane default) |
| AKS | `aks-bank-app-p1-globaris-poc` | `rg-bank-app-p1-workload-globaris-poc` | centralus | Succeeded, power state Running, k8s 1.35, 3 nodes, node RG `rg-bank-app-p1-aks-nodes-globaris-poc`, private cluster (`privatelink...azmk8s.io` FQDN) |
| ACR | `acrbankappp1globarispoc` | `rg-bank-app-p1-shared-globaris-poc` | centralus | Succeeded, Premium SKU, admin user disabled, public network access Disabled |
| Service Bus | `sbns-bank-app-p1-globaris-poc` | `rg-bank-app-p1-shared-globaris-poc` | centralus | Succeeded, Premium SKU, status Active |
| Event Hubs | `evhns-bank-app-p1-globaris-poc` | `rg-bank-app-p1-shared-globaris-poc` | centralus | Succeeded, Standard SKU, status Active |
| Databricks | `dbw-bank-data-p1-globaris-poc` | `rg-bank-data-p1-workload-globaris-poc` | centralus | Succeeded, Premium SKU, Secure Cluster Connectivity (`enableNoPublicIp`) = true |
| Fabric capacity | `fabbankdataglobarispoc` | `rg-bank-data-p1-shared-globaris-poc` | centralus | state Active, SKU F2 |
| Foundry (AI Services) | `aif-bank-data-p1-globaris-poc` | `rg-bank-data-p1-workload-globaris-poc` | centralus | Succeeded, kind AIServices, SKU S0, public network access Disabled |
| AI Search | `srch-bank-data-p1-globaris-poc` | `rg-bank-data-p1-workload-globaris-poc` | Central US | Succeeded, status running, SKU basic, public network access Disabled - co-located with its private endpoint in-region (the cross-region PE that motivated ADR-069 is retired) |
| Log Analytics (platform) | `law-platform-globaris-poc` | `rg-management-globaris-poc` | centralus | PerGB2018, 90-day retention |
| Log Analytics (security) | `law-security-globaris-poc` | `rg-security-globaris-poc` | centralus | PerGB2018, 90-day retention |
| AMBA managed identity | `id-amba-prod-001` | `rg-amba-monitoring-001` | centralus | live, has a real principalId/clientId (verified per PC-2H in the rebuild) |
| AMBA resource group | `rg-amba-monitoring-001` | (itself) | centralus | Succeeded - lands in centralus via `amba_alz_resource_group_location` resolving to the primary region (ADR-069 side effect, correctly so) |

**VNet peering health (all hub-spoke and hub-hub links), cross-cutting connectivity check beyond the prompt's explicit list, done because it is nearly free once the hubs are being inspected anyway:** all 8 peerings tenant-wide (`hub-primary<->hub-secondary`, `hub-primary->{corp-a1, online-p1, bank-data-p1, bank-app-p1, identity}`, `hub-secondary->corp-a2`) report peering state **Connected**. No orphaned or disconnected peering.

---

## 4. Management group topology and policy assignment counts

### 4.1 Topology - 12 management groups confirmed (11 + Tenant Root Group)

```
Tenant Root Group
+-- globaris
    +-- platform
    |   +-- connectivity     -> sub-connectivity-poc-01
    |   +-- identity         -> sub-identity-poc-01
    |   +-- management       -> sub-management-poc-01
    |   +-- security         -> sub-security-poc-01
    +-- landingzones
    |   +-- corp             -> sub-landingzones-poc-01  (see note below)
    |   +-- online           (no subscription attached)
    +-- decommissioned       (no subscription attached)
    +-- sandbox              (no subscription attached)
```

`sub-app-01` and `sub-avd-poc-01` sit directly under **Tenant Root Group**, outside the `globaris` hierarchy entirely - consistent with being out of scope for this estate.

**Note worth recording plainly:** `sub-landingzones-poc-01` (which physically hosts all 5 landing-zone spokes - corp-a1, corp-a2, online-p1, bank-data-p1, bank-app-p1) is placed under the **`corp`** management group, not split across `corp`/`online`. This is a structural consequence of the POC using one subscription for all landing-zone workload types (a subscription can only sit under one MG at a time); it is not a misconfiguration to flag, just a fact to carry forward into the next rebuild's expectations - do not expect `online-p1`-related policy inheritance to come from the `online` MG in this build; it comes from `corp`.

### 4.2 Policy assignment counts per scope (assignments AT that scope only, `az policy assignment list --scope <mg>`, strict match, not inherited)

| Scope | Assignment count |
|---|---|
| Tenant Root Group | 3 |
| `globaris` | 22 |
| `platform` | 43 |
| `connectivity` | 3 |
| `identity` | 5 |
| `security` | 0 |
| `management` | 1 |
| `landingzones` | 63 |
| `corp` | 5 |
| `online` | 0 |
| `decommissioned` | 1 |
| `sandbox` | 1 |
| **Total (management-group scopes)** | **147** |

Plus subscription-scope assignments (additional to the MG assignments above):

| Subscription | Assignment count |
|---|---|
| `sub-connectivity-poc-01` | 1 |
| `sub-identity-poc-01` | 0 |
| `sub-landingzones-poc-01` | 1 |
| `sub-management-poc-01` | 1 |
| `sub-security-poc-01` | 3 |
| **Total (subscription scopes)** | **6** |

**`globaris` = 22 is a direct, live confirmation of the WORKLOG's own closing claim** ("Total assignments at `globaris`: 22, up from 20 - so +2 and nothing displaced" after Step 14's AMBA re-land). Verified independently here via a fresh `az policy assignment list` call, not re-read from the log.

### 4.3 Custom policy definitions and initiatives (at `globaris` scope, where the ALZ + AMBA library lives)

| Object type | Count |
|---|---|
| Custom policy definitions | 292 |
| Custom policy set definitions (initiatives) | 59 |

**Do not expect these numbers, or the 147/6 assignment counts, to sum to Step 1 + Step 14's Terraform figures of 537 + 223 = 760.** The Terraform counts include policy DEFINITIONS, INITIATIVES, ASSIGNMENTS, the DINE remediation-identity ROLE ASSIGNMENTS, and module-internal helpers (`time_sleep`, `random_uuid`, `modtm_telemetry` pseudo-resources with no Azure footprint at all). The API-side counts above are the assignment and definition/initiative objects only, queried directly against Azure rather than inferred from a Terraform plan. Use Section 6 for the plan-shaped baseline and this section for the Azure-shaped one; they measure different things by design.

### 4.4 RBAC role assignments AT `globaris` MG scope (not inherited) - 29 total

Dominated by remediation/monitoring service principals (Contributor x6, Monitoring Policy Contributor x4, Log Analytics Contributor x3, etc). **2 assignments of built-in `Owner`** to a service principal are present - this matches the already-recorded CI SP Owner-grant drift (folded into OQ-061 per user ruling 2026-07-25; confirmed still present, not a new finding, does not block anything, but should stay tracked in OQ-061 until reconciled).

---

## 5. Configuration assertions (the part a green apply does not prove)

| Assertion | Expected | Live result | Evidence |
|---|---|---|---|
| Firewall zones | `1,2,3` both firewalls | Confirmed, both | `az network firewall show --query "join(',',zones)"` -> `2,3,1` (same set) for both `fw-hub-centralus-001` and `fw-hub-eastus2-001` |
| Firewall private IPs | `10.0.0.4` primary, `10.1.0.4` DR | Confirmed | `ipConfigurations[0].privateIPAddress` on each firewall |
| RSV storage redundancy | `ZoneRedundant` primary / `GeoRedundant` DR | Confirmed | `az backup vault backup-properties show` -> `storageModelType` |
| Spoke default routes | next hop to the region's firewall private IP | Confirmed, all 5 spokes | corp-a1, online-p1, bank-data-p1, bank-app-p1 route `0.0.0.0/0` to `10.0.0.4`; corp-a2 (DR) routes to `10.1.0.4` |
| WAF policy mode | `Prevention` / `Enabled` | Confirmed | `wafpol-online-p1-globaris-poc` policySettings |
| Defender pricing plans | 11 Standard, including AI/Discovery/FoundationalCspm | Confirmed, exactly 11 | `az security pricing list`: Standard on VirtualMachines, SqlServers, AppServices, StorageAccounts, SqlServerVirtualMachines, OpenSourceRelationalDatabases, Containers, CloudPosture, AI, Discovery, FoundationalCspm. Free on KubernetesService, ContainerRegistry, KeyVaults, Dns, Arm, CosmosDbs, Api |
| Diagnostic settings present where expected | see 5.1 | Mixed, matches design | `az rest` against `.../providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview` per the note that `az monitor diagnostic-settings list` false-negatives in this estate |
| Region (every named resource in Section 3) | centralus primary, eastus2 for the DR spoke and its RSV/vnet only | Confirmed | See per-resource region column in Section 3; the DR spoke (corp-a2) and its network/monitoring/shared RGs are the only ones in eastus2 among the workload resources; `NetworkWatcherRG`/state-backend RGs also touch eastus2 but are excluded from comparison |

### 5.1 Diagnostic settings detail (via `az rest`, not the CLI helper - confirmed false negatives from the CLI helper were avoided)

| Resource | Diagnostic settings found | Assessment |
|---|---|---|
| `fw-hub-centralus-001` | 1 | present, as expected |
| `fw-hub-eastus2-001` | 1 | present, as expected |
| `appgw-online-p1-globaris-poc` | 1 | present |
| `apim-bank-app-p1-globaris-poc` | 1 | present |
| `aks-bank-app-p1-globaris-poc` | 1 | present |
| `acrbankappp1globarispoc` | 1 | present |
| `sbns-bank-app-p1-globaris-poc` | 1 | present |
| `evhns-bank-app-p1-globaris-poc` | 1 | present |
| `dbw-bank-data-p1-globaris-poc` | 1 | present |
| `aif-bank-data-p1-globaris-poc` | 1 | present |
| `srch-bank-data-p1-globaris-poc` | 1 | present |
| `aadds-globaris-poc` | 0 | By design, not a gap - confirmed by reading `platform/identity/domain-services.tf`: no `diagnostic_settings` block is wired for AADDS anywhere in the code. Expected value is 0, not 1. |
| `rsv-corp-a1-globaris-poc`, `rsv-corp-a2-globaris-poc` | 0 each | By design, not a gap - confirmed by reading `landing-zones/corp-a1(/a2)/backup.tf`: no `diagnostic_settings` passed to the RSV module. Expected value is 0. |
| `fabbankdataglobarispoc` (Fabric capacity) | N/A | `Microsoft.Fabric/capacities` does not support diagnostic settings at all (`ResourceTypeNotSupported` from the API) - a platform limitation, not a configuration gap |
| `law-platform-globaris-poc`, `law-security-globaris-poc` | 0 each | Normal - a LAW is the destination, not typically a diagnostic-settings source in this design |

**The genuinely useful finding here:** if a future rebuild shows AADDS or either RSV suddenly WITH a diagnostic setting, or the firewalls/AKS/ACR/etc WITHOUT one, that is the actual regression signal - the current 0s for AADDS/RSV are the correct baseline, not missing coverage.

---

## 6. Measured plan bars (recorded baseline, from WORKLOG)

| Step | Root | Plan (Terraform resource count) |
|---|---|---|
| 1 | `platform/management-groups` | 537 |
| 2 | `platform/management` | 36 |
| 3 | `platform/security` | 48 |
| 4 | `platform/connectivity` | 696 |
| 5 | `landing-zones/corp-a1` | 24 |
| 6 | `landing-zones/corp-a2` | 24 |
| 7 | `landing-zones/online-p1` | 26 |
| 8 | `landing-zones/bank-data-p1` | 73 |
| 9 | `landing-zones/bank-app-p1` | 67 |
| 10 | `platform/identity` Pass 1 | 16 |
| 11 | `platform/identity` Pass 2 | 10 |
| 12 | `bank-app-p1` Pass 2 | 1 |
| 13 | `platform/management` (B7) | 3 |
| 14 | `platform/management-groups` (B7) | 223 |

**Sum of the per-step bars: 1,808.** The WORKLOG's own rounded running totals ("roughly 1,495" mid-build, "roughly 1,721" near the end) were narrative checkpoints taken before all 14 steps were summed; treat the per-step table above, not either rounded running total, as the authoritative bar-by-bar baseline for a future comparison. If a future rebuild's per-step plan does not hit these bars exactly, the per-step number is what to chase, not a single grand total.

**Telemetry inflation, stated exactly as instructed:** `bank-data-p1`'s 73 = 49 real Azure resources + 24 AVM telemetry pseudo-resources (`modtm_telemetry`/`random_uuid`/similar module-internal objects with no ARM footprint). Every root that uses AVM modules carries some amount of this; `bank-data-p1` is simply where the split was explicitly measured and recorded in WORKLOG. **When comparing a future rebuild's plan output to these bars, compare the "resources to add" count only if using the exact same Terraform/provider/module versions - a version bump can change the telemetry resource count without changing the real infrastructure, producing a false diff against this table if not accounted for.**

---

## 7. NEGATIVE inventory - confirmed absent

All checked live across all 5 subscriptions via `az resource list --resource-type <type>` (empty result = confirmed absent, no error swallowed):

| Must NOT exist | Result | Reason it is gated off |
|---|---|---|
| `Microsoft.Sql/servers` (SQL server) | Absent, all 5 subscriptions | ADR-031, subscription offer cap; `enable_sql = false` |
| `Microsoft.Web/sites` (App Service) | Absent, all 5 subscriptions | ADR-032, subscription offer cap; `enable_app_service = false` |
| `Microsoft.Network/virtualNetworkGateways` (VPN gateway) | Absent, all 5 subscriptions | ADR-042, on-demand only, never in the 696-count connectivity apply |
| `Microsoft.Network/dnsResolvers` (DNS Private Resolver) | Absent, all 5 subscriptions | ADR-042, on-demand only. Note: the hub-primary VNet DOES reserve a `snet-dns-resolver-outbound` subnet for this (Section 3), but the resolver resource itself is not deployed |
| `Microsoft.Network/bastionHosts` (Bastion) | Absent, all 5 subscriptions | ADR-015/ADR-042, on-demand only |
| `Microsoft.App/*` (Container Apps, synthetic workload) | Absent, all 5 subscriptions | `enable_synthetic_workload = false` (ADR-036) |
| `Microsoft.Compute/virtualMachines` (bare VMs) | Absent, all 5 subscriptions | No VM-based workload in this estate; the only compute is AKS VMSS nodes and Databricks-managed capacity |
| `random_id.sql_suffix` resource (corp-a1, corp-a2) | Absent (count=0 in Terraform, confirmed no matching live SQL server) | Correctly gated by `enable_sql` |

**Standing blocker recorded in WORKLOG, re-confirmed as still relevant if synthetic workload is ever enabled:** the tenant-root policy `sys.blockwesteurope` enforces with no `notScopes`, and `synthetic/variables.tf` defaults `red_team_geo_location = "westeurope"`. Not tested here (synthetic workload is disabled and this QA pass does not deploy anything), but flagged again because it is invisible to any repo grep - only a live tenant policy read finds it, and this BOM is the right place to carry that forward.

---

## 8. Comparison methodology for a future operator

### 8.1 What to run, in order

1. Resource group existence and provisioning state, per subscription:
   az group list --subscription SUB --query "[].{name:name, state:properties.provisioningState}" -o tsv
   Exclude NetworkWatcherRG and rg-tfstate-mgmt-eus2-001, and note (do not fail on) cloud-shell-storage-southcentralus if still present and still empty. Compare the remaining RG name set literally - RG names in this estate are all deterministic.

2. Resource type counts per RG, per subscription:
   az resource list --subscription SUB --query "[].{rg:resourceGroup, type:type}" -o tsv
   then aggregate (sort | uniq -c) and diff type+RG+count triples against Section 2. Any new type in a RG, or a count delta on an existing type, is a candidate regression - confirm against Section 1 first (is the delta explained by a known non-deterministic resource appearing/disappearing, e.g. enable_mdc_event_hub_export flipping) before calling it a regression.

3. Named resource existence and key properties, per Section 3, using the exact az show commands recorded in this document's evidence trail (firewall zones/IP, RSV redundancy, AKS provisioningState, etc). These are the checks a bare resource-count diff cannot catch.

4. Management group topology and policy assignment counts, per Section 4:
   az account management-group list --query "[].{name:name, displayName:displayName}" -o tsv
   az account management-group show -n MG --expand -o json
   az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/MG" --query "length(@)" -o tsv
   Compare the 12-MG topology and the per-scope assignment table. A management group appearing or disappearing, or an assignment count changing at a scope OTHER than globaris or landingzones (where AMBA landed), is high severity - it means the architecture selection (globaris vs globaris-amba) or the MG hierarchy itself drifted.

5. Negative inventory, per Section 7, for every subscription:
   az resource list --subscription SUB --resource-type "Microsoft.Sql/servers" --query "length(@)" -o tsv
   (repeat for each gated type). Any non-zero result is an immediate STOP - it means a gate that should be closed reopened.

6. Diagnostic settings, using az rest, NOT az monitor diagnostic-settings list (confirmed false negatives in this estate):
   az rest --method GET --url "https://management.azure.com/RESOURCE_ID/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview" --query "length(value)" -o tsv
   against every resource in Section 5.1, expecting the same present or absent pattern (including the two by-design zeros).

7. Terraform-side cross-check (read-only, from a CI-context run or terraform state list, never a local plan against the JIT-firewalled state SA per LESSON 51): compare the per-root Plan line to Section 6's table, and treat any bar it does not hit exactly as requiring the same open-the-block-dont-just-read-the-summary discipline the rebuild itself used for Steps 12 and 14 - a changed or replaced count is not automatically a STOP, but every instance must be individually classified as a permitted helper (time_sleep, modtm_telemetry, random_uuid) or a real object before being waved through.

### 8.2 On a repeatable script

A single script that runs all of the above and emits a pass/fail table would remove the manual-comparison risk entirely. I am read-only on this repository and have not created one; if the operator wants it, it should be scoped as a new script (for example `scripts/bom-diff.sh`) that:
- takes this document (or a machine-readable sibling of it, a JSON/YAML export of Sections 2-7) as the expected-state input,
- runs the az calls in 8.1 against a live estate,
- applies the prefix/count matching rules from Section 1 automatically rather than requiring a human to remember which resources are exempt from literal-name comparison,
- and fails loudly (non-zero exit, itemized diff) rather than producing a summary a human has to interpret.

That build should go through the normal architect -> cloud-engineer/devsecops -> code-reviewer path like any other change; it is out of scope for this QA pass.

---

## 9. What I could NOT verify

- AADDS replica health beyond provisioningState Succeeded. The Microsoft.AAD/DomainServices REST response's replicaSets health fields returned null for this domain via the generic ARM read; a deeper health check would need the dedicated AADDS health blade/API, which was not exercised. Not a red flag by itself, the ARM envelope is Succeeded and a replica set exists in the correct region, but "healthy" here is inferred from the envelope, not confirmed at the AADDS-specific health layer.
- RBAC assignments and subnets were spot-checked, not exhaustively enumerated for every RG. Section 4.4 covers globaris MG scope only; a full RBAC diff across all 30 RGs was out of the cost and time budget for this pass and was not attempted.
- Whether cloud-shell-storage-southcentralus would be caught and removed by the teardown mechanism. Not tested (would require an actual teardown run, which is out of scope and cost-inappropriate for this BOM capture). Flagged in Section 0 as something to watch on the next cycle.
- Full custom policy definition and initiative counts at every management group scope, not just globaris. Section 4.3 covers globaris only (where the ALZ and AMBA library is centered); the other 10 MGs were not individually queried for custom definition counts, only assignment counts.
- Soak-time health (whether AKS, Databricks, APIM remain stable over hours, not just at this snapshot). This BOM is a point-in-time capture by design, taken deliberately close to the apply; it is not a soak test.

---

## 10. Summary of what surprised me and discrepancies found

- The sub-landingzones-poc-01 placement under the corp MG (not split corp/online) is worth carrying forward explicitly. It is correct given the one-subscription-for-all-spokes design, but an operator expecting online-p1 policy inheritance from the online MG would be wrong, and the online MG's 0 assignments could look alarming without this context.
- The AMBA-related Data Collection Endpoint and Rule names (NWTA-LAWCUSTOMERID-...) are non-deterministic by inheritance from the LAW's regenerated customerId, without using any random_* Terraform resource themselves. This was not on the prompt's known list and would not have been found without reading the live resource names against the LAW's own workspace ID.
- Not all Application Insights workbooks in this estate are non-deterministic. The 2 platform/management workbooks use a deterministic uuidv5 hash specifically to avoid this problem (the code comment says so explicitly); only the 4 Sentinel workbooks in platform/security use random_uuid. A blanket "workbooks are non-deterministic" rule would have been wrong in half of the cases.
- The cloud-shell-storage-southcentralus stray resource group is still present and still empty. Already known (prior preclearance doc), but worth re-confirming it has not grown a storage account, and worth flagging that it sits outside both the protected-exclusion list and Terraform's visibility - nothing currently guarantees it gets cleaned up.
- A previously-noted second stray, adf-enterprise-rg, is now gone. Good news, and consistent with the estate being genuinely clean of that particular residue.
- The CI SP's undeclared Owner grant at globaris MG scope (2 assignments) is still present, consistent with the already-tracked OQ-061 drift, re-confirmed live here rather than assumed, no new action implied beyond what OQ-061 already carries.
- No discrepancy found between the rebuild WORKLOG's specific, checkable claims (firewall zones and IPs, RSV redundancy, route next-hops, WAF mode, globaris assignment count of 22, AMBA identity and RG) and live Azure. Every one of those specific assertions was independently reproduced against Azure in this pass, not re-read from the log.
