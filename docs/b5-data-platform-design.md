# Wave B5 - Data Platform (Databricks + ADLS Gen2 + Fabric F2) target design

> **Status:** READY FOR IMPLEMENTATION except the Fabric flag flip, which waits on OQ-045 (capacity
> admin principal - ask-user item). Design and docs only; no Terraform is written by this document.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-18.
> **Parent design:** `docs/banking-platform-design.md` section 2.3 / wave B5 (OQ-037 resolution:
> Databricks + ADLS Gen2 + pausable Fabric F2; Synapse satisfied-by-successor, NOT deployed).
> **Resolved inputs:** OQ-037 (anchor), OQ-035 (placement: landingzones sub), OQ-043 (quota trail -
> moot for B5-as-designed, see section 6), ADR-045 (sprint frame, EOW teardown), B1 (bank-data-p1
> network live: both Databricks subnets delegated, NSGs, UDR, 6 zone links), ADR-044/047 (per-wave
> RCG pattern on the primary hub policy).
> **New records:** ADR-048 (B5 rulings incl. the managed-RG policy collision unit), OQ-045 (Fabric
> capacity admin principal - the only user fork).

---

## 0. Executive summary

- B5 lands the data platform in the existing `landing-zones/bank-data-p1` root: an **Azure
  Databricks Premium workspace, VNet-injected** into the two live delegated subnets with **secure
  cluster connectivity (NPIP)**, an **ADLS Gen2 storage account (HNS on, PE-only blob+dfs,
  compliant by design - zero exemption)**, and a **Fabric F2 capacity (native azurerm resource,
  suspend-after-QA posture)**. Two flags: `enable_data_platform` and `enable_fabric_capacity`,
  both default false (LESSON 42).
- **The classic Databricks-vs-policy collision is ruled BEFORE pre-clearance** (section 4): the
  workspace create places a `dbstorage*` storage account in its OWN managed RG, and the corp
  Deny-Public-Endpoints `StorageDenyPaasPublicIP` member (live Deny) would kill that RP-side PUT -
  the likeliest first-apply killer of this wave. Ruled as ONE defense-in-depth unit:
  create-time **default storage firewall** (workspace SA deployed private, access connector
  pre-created) AND a **subscription-scoped, member-scoped, EXPIRING Waiver exemption** that
  admits the create regardless of the RP's PUT sequencing, which is not verifiable pre-apply.
- **Compute/quota:** the workspace create consumes ZERO Microsoft.Compute vCPUs - clusters do,
  and NONE are built (hard demo boundary). The OQ-043 VM-family question is MOOT for
  B5-as-designed (section 6 records the trail for any future cluster).
- **Firewall delta:** one new RCG `rcg-dbx-egress-primary` (priority 320, primary hub policy
  only, `enable_firewall`-gated, source = the two Databricks subnets) built ENTIRELY from
  Microsoft-maintained service tags per the current Databricks recommendation - no FQDN rules,
  DNS proxy stays off (ADR-044 precedent, LESSON 40 rot class avoided). Rules are dormant until
  a cluster ever runs, but make the posture QA-verifiable and future-proof.
- **Lifecycle catches this session:** Databricks `standard` SKU is deprecated (module docs state
  Oct 2026) - Premium is ruled, not just preferred; new-VNet default-outbound retirement
  (2026-03-31) makes explicit egress mandatory for new workspaces - our UDR-to-AZFW IS the
  explicit method; the Fabric capacity NAME cannot contain hyphens (lowercase alphanumeric only,
  provider issue #29302) - estate naming adapts.
- Cost: **~$1/day with Fabric suspended** (ADLS PEs + managed-RG storage pennies; Premium
  workspace with no clusters = $0 DBU). Fabric F2 active = ~$0.36/hr (~$8.6/day); the runbook
  suspends it the same day QA passes.
- Wave duration: ~20-35 min total (300s exemption sleep, workspace create 5-15 min, SA ~1-2 min,
  PEs ~2 min, Fabric 2-5 min). No long-create isolation needed (nothing near the B4 class).

## 1. Scope and boundary

### In scope (B5)

| Item | Where |
|---|---|
| Access connector + Databricks Premium workspace (VNet-injected, NPIP, default storage firewall) + diagnostics | `landing-zones/bank-data-p1` (new `databricks.tf`), workload RG, `enable_data_platform` |
| Subscription-scoped expiring Waiver exemption for `StorageDenyPaasPublicIP` + 300s sleep (the collision unit) | same root (extend `policy_exemptions.tf`) |
| ADLS Gen2 SA (HNS, PE blob+dfs, one filesystem) + diagnostics | same root (new `datalake.tf`), workload RG, same flag |
| Fabric F2 capacity (native resource) | same root (new `fabric.tf`), shared RG, `enable_fabric_capacity` |
| `rcg-dbx-egress-primary` prio 320 | `platform/connectivity` (new `firewall_rules_databricks.tf`), `enable_firewall`-gated |
| `lifecycle ignore_changes` on the Databricks NSG security rules (RP-injected rules drift guard, section 3.4) | `landing-zones/bank-data-p1/main.tf` (one lifecycle block) |
| Flag flips in `envs/poc.tfvars` (`enable_data_platform = true`; Fabric flag ONLY after OQ-045) | envs |

### Explicitly OUT of B5 (the demo content boundary - parked, do not build)

- NO Databricks clusters, jobs, SQL warehouses (classic or serverless), pools, or notebooks -
  nothing that consumes DBUs or vCPUs. NO Unity Catalog configuration beyond what the workspace
  create forces (automatic metastore assignment happens or not server-side; no catalogs, external
  locations, grants, or storage credentials are authored). NO `databricks` Terraform provider.
- NO Fabric workspaces, lakehouses, or items (the `microsoft/fabric` provider stays out of the
  estate); at most the capacity resource exists.
- NO Databricks front-end/back-end Private Link (production design target, section 8), no CMK
  (B9 extension wave), no AI services (B6), no cross-region DR storage (B10 documentation).

## 2. Verification log (2026-07-18, all dated today)

| Claim | How verified |
|---|---|
| `avm-res-databricks-workspace` latest STILL **0.5.0** (2026-05-21). BREAKING note: 0.5.0 moved the workspace from `azurerm_databricks_workspace` to `azapi_resource` | Terraform Registry API + module docs |
| 0.5.0 input surface covers every needed lever: `sku`, `custom_parameters` (virtual_network_id, public/private_subnet_name, both NSG association ids, `no_public_ip` DEFAULT FALSE - must set true, storage_account_name/sku), `managed_resource_group_name`, `default_storage_firewall_enabled` + `access_connector_id`, `public_network_access_enabled` (default true), `network_security_group_rules_required`, `private_endpoints`, `diagnostic_settings`, `compute_mode` (default "Hybrid") | module `variables.tf` read (main branch = 0.5.0) |
| Module docs: `standard` SKU **deprecated Oct 2026** - Premium ruled (also required by default storage firewall + any future PL) | module variables.tf `sku` description |
| Databricks VNet injection: two dedicated delegated subnets, min /26, RP auto-provisions NSG rules + delegation; managed RG "isn't modifiable and can't be used to create VMs"; VMs/disks/NICs appear in the managed RG only when a CLUSTER runs | MS Learn vnet-inject (updated 2026-06-25) |
| Required NSG outbound set (= the firewall allow set): `AzureDatabricks` TCP 443, 3306, 8443-8451; `Storage` TCP 443; `EventHub` TCP 9093; `Sql` TCP 3306 (3306 being phased out for new workspaces but still current) | MS Learn vnet-inject NSG rules table |
| UDR/egress guidance CURRENT: Databricks RECOMMENDS service tags over IPs/FQDNs ("prevent service outages due to IP changes"); Entra ID tag optional add; with Private Link the AzureDatabricks tag is not required; new VNets after 2026-03-31 REQUIRE an explicit outbound method (our UDR-to-firewall qualifies) | MS Learn udr doc (ms.date 2026-05-04) + vnet-inject warning |
| Default storage firewall: requires VNet injection + NPIP + Premium + an access connector OUTSIDE the managed RG; "Azure Databricks blocks public network access" on the workspace SA and auto-onboards it to an NSP (AzureDatabricksServerless tag); create-time enablement supported via ARM (`defaultStorageFirewall` + `accessConnector`); Fabric/Power BI Cloud Fetch against a firewalled workspace SA needs a gateway (OOS - no Fabric items) | MS Learn firewall-support (updated 2026-07-08) + firewall-support-arm-template |
| WHAT IS NOT VERIFIABLE PRE-APPLY: whether the RP's dbstorage PUT sequence ever presents `publicNetworkAccess != Disabled` to policy evaluation at create time. This is exactly why the exemption half of the collision unit exists. QA RECORDS the live dbstorage `publicNetworkAccess` value post-apply to close this | stated honestly; see section 4 |
| Pre-created managed RG as an exemption anchor: RP acceptance of a pre-existing RG is UNVERIFIED (no authoritative doc found) - REJECTED as a mechanism | search of MS Learn/ARM template docs; nothing authoritative |
| Corp `Deny-Public-Endpoints` `StorageDenyPaasPublicIP` member = Deny (live, proven by the B1 flow-log collision + waiver); `deny-pub-net-globaris` storage member = **Audit only** (B1 pre-clearance live member dump) - exactly ONE Deny member in play | estate records docs/preclearance/b1-bank-spokes.md rows |
| `avm-res-storage-storageaccount` latest STILL **0.7.3** (2026-06-24); azapi-shaped (`parent_id` like the vnet module); SECURE DEFAULTS: `public_network_access_enabled` false, `shared_access_key_enabled` false, `network_rules.default_action` "Deny", `min_tls_version` TLS1_2, `account_replication_type` ZRS; HNS = **`is_hns_enabled`** (defined in variables.container.tf); `storage_data_lake_gen2_filesystems` map; `containers`; `diagnostic_settings_storage_account`; `private_endpoints` + `private_endpoints_manage_dns_zone_group` | Registry API + tag v0.7.3 source grep (variables.storageaccount.tf, variables.container.tf, variables.data_lake.tf, variables.diagnostics.tf) |
| `azurerm_fabric_capacity` EXISTS in the current azurerm 4.x line (added late 2024, provider PR #28080; present in current provider docs) - the root pin `~> 4.71.0` covers it. Schema: name/location/resource_group_name/sku{name,tier="Fabric"} required; `administration_members` OPTIONAL in the provider schema (UPN for users, object ID for SPs); create/delete timeouts 30 min | provider docs (main) + PR #28080 |
| Fabric capacity NAME: lowercase letters and numbers only, must start with a letter (hyphens REJECTED) | provider GitHub issue #29302 |
| Fabric pause/resume: NOT a Terraform argument - capacity deploys ACTIVE; suspend/resume = ARM actions (`az fabric capacity suspend/resume`, `Suspend-AzFabricCapacity`, or REST `/suspend` `/resume`); needs `Microsoft.Fabric/capacities/suspend|resume/action` (Contributor on the RG suffices); billing stops while paused (OneLake storage would still bill - none exists here) | MS Learn pause-resume + az CLI extension docs |
| F2 pay-go ~$0.36/hr (~$263/mo) | founding-design verification carried; approximate list |
| No AVM module exists for Fabric capacity | founding-design registry NOT-FOUND check carried (2026-07-12) |
| NOT verified (build/pre-clearance): Microsoft.Fabric RP registration state in the landingzones sub; Fabric F-SKU availability in eastus2 for THIS offer (no pre-checkable quota API found - PUT-time watch, flag-protected, same class as APIM); `azurerm_databricks_access_connector` + `azurerm_subscription_policy_exemption` argument names on 4.71 (implementer verifies at build); AVM 0.5.0 exact custom_parameters value shapes (azapi body) - implementer verifies against module docs; whether ARM accepts an EMPTY administration_members list (OQ-045 gates the flag anyway) | marked where cited |

## 3. Databricks specification (implementer contract)

### 3.1 Access connector (native resource, created BEFORE the workspace)

`azurerm_databricks_access_connector` `dbac-bank-data-p1-<org>-<env>`, workload RG, eastus2,
`identity { type = "SystemAssigned" }`, common tags. No manual role assignments - the RP wires the
workspace-storage access itself under default storage firewall. Gated by `enable_data_platform`
(for_each map pattern, no count).

### 3.2 Workspace (module `Azure/avm-res-databricks-workspace/azurerm` version = `"0.5.0"`)

| Input | Value | Why |
|---|---|---|
| `name` | `dbw-bank-data-p1-<org>-<env>` | CAF abbreviation, estate convention |
| `resource_group_name` / `location` | workload RG / eastus2 | estate spoke template |
| `sku` | `"premium"` | standard deprecated Oct 2026 (lifecycle); required for storage firewall, CMK (B9), PL (prod target) |
| `managed_resource_group_name` | `rg-bank-data-p1-dbx-managed-<org>-<env>` | deterministic name = QA/policy checks can target it; NOT pre-created |
| `custom_parameters.virtual_network_id` | `module.spoke_vnet.resource_id` | VNet injection |
| `custom_parameters.public_subnet_name` | `snet-databricks-host` | live since B1, delegated |
| `custom_parameters.private_subnet_name` | `snet-databricks-container` | live since B1, delegated |
| `custom_parameters.public_subnet_network_security_group_association_id` / `private_...` | the two subnet resource IDs from `module.spoke_vnet.subnets[...]` (an azurerm NSG-association ID equals the subnet ID; implementer verifies the exact value shape the 0.5.0 azapi body expects against the module docs) | required by VNet injection validation |
| `custom_parameters.no_public_ip` | **true** | NPIP / secure cluster connectivity - module default is FALSE, must be set |
| `custom_parameters.storage_account_name` | `dbstorage<hex>` via random_id, rendered-length check (LESSON 27) | deterministic-enough for QA; avoids RP-random name |
| `default_storage_firewall_enabled` | **true** | posture half of the section 4 collision unit |
| `access_connector_id` | `azurerm_databricks_access_connector...id` | required with the firewall |
| `public_network_access_enabled` | **true (explicit)** | front-end UI/REST access for user + QA; NO private-access path is stood up this sprint (Bastion is off, no VPN); front-end/back-end PL is the production design target (section 8). No live Deny member targets Databricks workspaces (pre-clearance re-enumerates) |
| `compute_mode` | leave default `"Hybrid"` (do NOT set Serverless) | classic VNet-injected compute plane is the designed shape |
| `network_security_group_rules_required` | omit (module default) | only meaningful under PL/pna-false shapes |
| `diagnostic_settings` | to `var.platform_law_workspace_id`, category group `allLogs` | estate pattern |
| `tags` | `local.common_tags` | estate bar |

Ordering inside the root: `time_sleep.wait_dbx_storage_exemption` (section 4) -> access connector
-> workspace. `depends_on` explicit on the workspace module for the sleep (LESSON 35 unit).

### 3.3 What the workspace create places in the managed RG (deliverable: enumeration)

With VNet injection + NPIP + default storage firewall and ZERO clusters:

| Resource | Note |
|---|---|
| `dbstorage*` storage account | DBFS root + workspace system data; the policy collision target; expected private (firewall-enabled) - QA RECORDS its live `publicNetworkAccess` value |
| `dbmanagedidentity` user-assigned managed identity | RP-managed, storage access |
| RP-managed access connector and/or NSP association | automatic Unity Catalog identity / storage-firewall NSP onboarding; exact inventory is RP-version-dependent - QA enumerates and records what actually landed |
| Azure deny assignment on the RG | RP-managed; read-only to us; blocks user writes in the managed RG |
| **NOT present:** VNet/NSG/NAT gateway (VNet-injected - OUR subnets and UDR carry egress), VMs/disks/NICs/public IPs (cluster-time only, doc-verified), route tables | the create consumes NO compute |

### 3.4 NSG drift guard (rides the batch)

At workspace create the RP injects its required rules (`Microsoft.Databricks-workspaces_UseOnly_*`)
into OUR `azurerm_network_security_group.databricks` via the delegation's Network Intent Policy.
That NSG uses inline `security_rule` blocks, which are authoritative: the next refresh would show
the RP rules as drift and a later apply would try to strip them - a permanent fight with the intent
policy. Ruling: add `lifecycle { ignore_changes = [security_rule] }` to
`azurerm_network_security_group.databricks` (comment citing this section). The one authored
baseline rule is static; ignoring rule drift on this NSG is the correct steady state. The
`spoke` NSG is untouched.

## 4. THE MANAGED-RG POLICY COLLISION RULING (pre-cleared here, before the pre-clearance doc)

**Collision:** corp MG `Deny-Public-Endpoints` member `StorageDenyPaasPublicIP` = Deny on storage
accounts whose `publicNetworkAccess` is not Disabled/SecuredByPerimeter (live-proven Deny by the B1
flow-log waiver). The Databricks RP creates `dbstorage*` inside its managed RG during workspace
create; policy evaluates RP PUTs like any other. If that PUT is non-compliant even transiently, the
WORKSPACE create fails. `deny-pub-net-globaris` storage member is Audit-only (verified) - noise,
never blocks. No other corp/landingzones Deny member targets Databricks, managed identities,
access connectors, or Fabric capacities (pre-clearance re-enumerates the live matrix).

**Ruling - ONE unit, defense in depth (ADR-048):**

1. **Posture half:** `default_storage_firewall_enabled = true` + pre-created access connector
   (section 3.2). Per current MS Learn, create-time enablement deploys the workspace SA with
   public network access blocked - the managed SA is then compliant IN INTENT with the corp
   policy, which is the banking-posture answer, not a waiver-shaped hole.
2. **Guarantee half:** because the RP's PUT sequencing vs Deny evaluation is NOT verifiable
   pre-apply (section 2), a **subscription-scoped Waiver exemption** on the landingzones sub,
   scoped to `policy_definition_reference_ids = ["StorageDenyPaasPublicIP"]` ONLY, with
   **`expiration_date` = 2026-08-01T00:00:00Z** (past the ADR-045 EOW teardown), name
   `exempt-dbx-managed-storage-bank-data-p1`, description citing this section. Followed by the
   standing **300s propagation sleep** and `depends_on` from the workspace (ADR-028/LESSON 35
   unit). The exemption admits the create no matter how the RP sequences the PUT.

**Mechanism alternatives rejected:**
- **RG-scoped exemption on the managed RG (the OQ-024 precedent's shape):** the managed RG does
  not exist until the workspace create is already in flight - the exemption cannot exist before
  the PUT it must admit. Racy by construction.
- **Pre-creating the managed RG** to anchor an RG-scoped exemption: RP acceptance of a
  pre-existing managed RG is UNVERIFIED (section 2); betting the wave's first apply on an
  unverifiable RP behavior is the exact failure class this gate exists to kill.
- **notScopes / resourceSelectors on the corp assignment:** mutates an assignment owned by the
  avm-ptn-alz policy engine root - cross-root churn and a standing deviation for a one-week need.
- **Exemption-only (no storage firewall):** works, but leaves the managed SA public-enabled - a
  weaker posture than the estate demands for a banking story, for the cost of one extra cheap
  resource (the connector).

**Blast radius honesty:** while the exemption lives (at most until 2026-08-01), storage accounts
in the landingzones sub are not blocked by that ONE member. Every SA in the sub is authored by
this repo under review, the deny-public default remains the authored bar, the Audit member still
flags, and the exemption self-expires. Accepted for the sprint window; recorded in ADR-048.

**QA closure:** QA records the live `dbstorage*` `publicNetworkAccess` + network ACL state. If it
lands `Disabled`-or-equivalent, a follow-up MAY drop the exemption early (one-line destroy);
otherwise it expires on schedule.

## 5. Firewall delta: `rcg-dbx-egress-primary` (platform/connectivity)

New file `firewall_rules_databricks.tf`, `azurerm_firewall_policy_rule_collection_group`,
**priority 320**, PRIMARY hub policy only (ADR-044 precedent - nothing routes eastus2 spokes to the
secondary), gated on `var.enable_firewall` via for_each, source = variable defaulting to
`["10.32.0.0/24", "10.32.1.0/24"]` (both Databricks subnets). ONE network rule collection (allow),
all destinations as Microsoft-maintained service tags (the current Databricks-RECOMMENDED
mechanism; no FQDN rules, so firewall DNS proxy stays OFF):

| Rule | Protocol/Ports | Destination service tag | Carries |
|---|---|---|---|
| dbx-control-plane | TCP 443, 3306, 8443-8451 | `AzureDatabricks` | control plane API, SCC relay (NPIP tunnel), webapp, UC logging (8444) |
| dbx-storage | TCP 443 | `Storage` (GLOBAL, deliberately not region-scoped) | artifact + log + DBFS blob/dfs; global tag kills the documented secondary-region artifact-storage landmine |
| dbx-eventhub | TCP 9093 | `EventHub` | telemetry/log shipping |
| dbx-metastore | TCP 3306 | `Sql` | legacy Hive metastore (being phased out for new workspaces; harmless to carry, matches the RP NSG rule set) |
| dbx-entra | TCP 443 | `AzureActiveDirectory` | cluster AAD auth (optional per the UDR doc; needed for AAD-only storage access) |

These rules are DORMANT at B5 (no clusters -> no compute-plane egress) but are the difference
between "a future cluster start just works" and a mid-demo blackhole; they also give QA a
config-verifiable posture object. The B1-parked caveat in bank-data-p1 main.tf ("required firewall
allowances ... wave B5 pre-clearance scope") CLOSES with this section. No service-tag BYPASS routes
are added (unlike APIM's stv2 management-plane requirement, Databricks documents firewall/NVA
egress as fully supported - everything rides the existing 0.0.0.0/0 UDR through AZFW inspection).

## 6. Compute/quota statement (deliverable)

- The Databricks WORKSPACE create allocates no VMs, no VMSS, no NICs-with-VMs - zero
  Microsoft.Compute quota consumption. Clusters allocate compute at CLUSTER create in the
  workload sub; none are built at B5 (hard boundary, section 1).
- Therefore **the OQ-043 VM-family question is MOOT for B5-as-designed.** For the record and for
  any future cluster demo: regional cap now 24 vCPUs (raised per the OQ-043 trail), DSv4 family
  holds AKS's 6; a future Databricks cluster must use a NON-DSv4 v4 family with live headroom
  (v5 families remain capped at 0 on this offer) - re-verify live at that wave's pre-clearance.
- No NAT gateway is created (VNet injection = our UDR is the egress path); the managed RG cannot
  even host VMs per current docs.
- Fabric capacity consumes Fabric CU quota, not Compute; F-SKU availability on this offer is a
  PUT-time watch item (section 2), flag-protected.

## 7. ADLS Gen2 + Fabric specifications (implementer contract)

### 7.1 ADLS Gen2 (module `Azure/avm-res-storage-storageaccount/azurerm` version = `"0.7.3"`)

| Input | Value | Why |
|---|---|---|
| `name` | `stlake<env>bdp1<hex8>` via random_id (rendered length 21 <= 24, LESSON 27) | flow-log SA naming precedent |
| `parent_id` | workload RG resource id (azapi-shaped module, vnet-module precedent) | 0.7.3 interface |
| `location` | eastus2 | estate |
| `is_hns_enabled` | **true** | ADLS Gen2 |
| `account_kind` / `account_tier` / `account_replication_type` | module defaults (StorageV2 / Standard / ZRS) | secure/sane defaults verified in source; ZRS zone story at near-zero GB cost |
| `public_network_access_enabled`, `shared_access_key_enabled`, `network_rules.default_action`, `min_tls_version`, `allow_nested_items_to_be_public` | module defaults (false / false / Deny / TLS1_2 / false) - state them EXPLICITLY in the root anyway | compliant by design with BOTH storage policy members - ZERO exemption for this SA; AAD-only matches the B2/B3 bar |
| `storage_data_lake_gen2_filesystems` | one: `raw` | minimal QA data-plane surface |
| `private_endpoints` | TWO: `blob` + `dfs` subresources into `snet-private-endpoints`, zone IDs from the live blob/dfs zones (extend the `dns_links.tf` data-source pattern), module-managed zone groups | proven SQL/ACR/EH/SB pattern; zones linked since B1 |
| `diagnostic_settings_storage_account` | to `var.platform_law_workspace_id` | estate pattern (note the 0.7.3 per-service diagnostics variable NAME) |
| CMK / `customer_managed_key` | OMIT | B9 extension wave, matching ADR-046 precedent |

Note: Databricks does NOT consume this SA at B5 (no UC external locations, no mounts - boundary).
It is the lakehouse landing zone the platform story requires and the B6 RAG source.

### 7.2 Fabric F2 (native `azurerm_fabric_capacity` - no AVM module exists, re-verified)

| Argument | Value | Why |
|---|---|---|
| `name` | `fabbankdata<org><env>` (e.g. all-lowercase alnum; NO hyphens - provider issue #29302 name constraint) | Fabric naming rules break the estate hyphen convention; documented deviation |
| `resource_group_name` / `location` | shared RG / eastus2 | BI/reporting shared face |
| `sku { name = "F2", tier = "Fabric" }` | F2 | OQ-037/founding design; smallest SKU |
| `administration_members` | `var.fabric_admin_members` (list(string), default `[]`), fed via CI `TF_VAR_fabric_admin_members` from a GitHub Actions variable - **OQ-045: user supplies the principal (UPN); no personal values in committed files** | capacity without an admin is unmanageable in the Fabric portal; empty-list ARM acceptance UNVERIFIED - `enable_fabric_capacity` stays FALSE until OQ-045 resolves |
| `tags` | common tags | estate bar |

**Pause mechanic (deliverable):** the resource DEPLOYS ACTIVE - ARM has no create-paused and
azurerm has no pause argument. Billing (~$0.36/hr) starts at create. Posture ruling: **suspend
same-day, immediately after QA** via `az fabric capacity suspend --capacity-name <name> -g <rg>`
(resume symmetric; Contributor on the RG suffices - the CI SP or the user in the portal). An
out-of-band suspend does NOT drift the Terraform plan (provisioning state is not a tracked
argument). EOW teardown destroys the capacity regardless of suspended/active state (delete timeout
30 min; verify-at-teardown note in the runbook). No ARM diagnostic-settings surface is designed
for Fabric capacities (monitoring is in-Fabric, OOS).

## 8. Design-vs-POC split (production targets, documented not deployed)

| Area | POC (B5) | Production design |
|---|---|---|
| Databricks network | NPIP + VNet injection + AZFW service-tag egress; front-end public (AAD) | Front-end AND back-end Private Link (browser_auth PE, pna false, NSG rules `NoAzureDatabricksRules`, AzureDatabricks tag dropped from firewall per UDR doc), IP access lists |
| Workspace storage | default storage firewall + expiring waiver belt | firewall + CMK (DBFS root + managed disks) + a STANDING managed-RG-scoped documented exception for the RP-managed SA (CORRECTED per B5 QA 2026-07-19: the storage firewall protects via NSP + ACL-deny with publicNetworkAccess still Enabled, so the b2982f36 member is never satisfied by the RP shape - "no exemption anywhere" was wrong; see the PC-4D addendum and ADR-048 post-QA correction) |
| Compute | none (boundary) | cluster policies, pools, spot strategy, non-DSv4 v4 or freed v5 families, autoscaling bounds; capacity math in B10 |
| Lakehouse | ADLS ZRS, one filesystem, PE-only | GZRS/paired-region, UC external locations + storage credentials via access connector, lifecycle management, CMK (B9) |
| Fabric | F2 suspended between demos | right-sized F-SKU or reservation, Fabric workspaces/items via `microsoft/fabric` provider, gateway wiring for firewalled-SA Cloud Fetch |
| Synapse | NOT deployed (satisfied-by-successor, OQ-037) | n/a - recorded as the requirements-doc term only |

## 9. Cost (approximate list, sprint-day framing per ADR-045)

| Item | $/day |
|---|---|
| Databricks Premium workspace, zero clusters | ~$0 (DBU-idle) |
| Managed-RG dbstorage + dbmanagedidentity + connector | pennies |
| ADLS Gen2 (near-zero GB) + 2 PEs | ~$0.55 |
| Fabric F2 ACTIVE | ~$8.64 ($0.36/hr) |
| Fabric F2 SUSPENDED (the ruled posture) | ~$0 |
| **B5 delta** | **~$1/day suspended posture; ~$9-10/day if F2 left running** |

## 10. Pre-clearance feed (docs/preclearance/b5-data-platform.md, before any apply)

1. Live policy matrix re-enumeration at corp + landingzones + sub scope: confirm
   `StorageDenyPaasPublicIP` still the ONLY Deny member touching this wave's resource types
   (explicitly check for any Databricks/ML member added since 2026-07-18) and the section 4 unit
   still matches.
2. RPs: `Microsoft.Databricks` AND **`Microsoft.Fabric`** registration state in the landingzones
   sub (Fabric almost certainly needs registering - first Fabric resource in the estate).
3. Names: workspace + managed RG + SA names available; Fabric name passes the lowercase-alnum
   rule; rendered lengths (LESSON 27).
4. Lifecycle audit delta if the apply slips past 2026-07-25 (ADR-045 re-affirmation date):
   re-check Databricks standard-SKU deprecation timeline, default-outbound retirement handling,
   Fabric SKU set.
5. Known-issues sweep: BOTH module repos get a full sweep - `avm-res-databricks-workspace` 0.5.0
   (azapi migration, FIRST consumption in this estate) and `avm-res-storage-storageaccount` 0.7.3
   (FIRST consumption); plus azurerm issues on `fabric_capacity` and
   `databricks_access_connector`.
6. Quota: section 6 statement stands (zero Compute); Fabric F2 = PUT-time watch (flag-protected).
7. Plan bars (previewed; pre-clearance refines): `platform/connectivity` = EXACTLY 1 add
   (rcg-dbx-egress-primary @320) + OQ-032 noise, 0 destroys/replaces. `bank-data-p1` with
   `enable_data_platform=true`, Fabric flag false = pure adds ~12-16 by class (sub exemption,
   sleep, connector, workspace module set + telemetry, ADLS module set: SA + filesystem + 2 PEs +
   diag), ZERO destroys/replaces, ZERO changes to spoke_vnet/subnets/UDR/peering; the NSG
   lifecycle block is config-only (no ARM change). Any `-/+ replace` = STOP (LESSON 26).
8. Ordering: connectivity RCG apply FIRST (pattern consistency; not create-blocking since no
   cluster egress exists), then bank-data-p1. No long-create isolation needed.
9. Standing gates: sequential applies, JIT/settle window, single-dispatcher, QA live-vs-intent
   before green.

## 11. QA feed (per-wave, before green)

- Workspace `provisioningState = Succeeded`; parameters live-verified: NPIP true, both subnets
  bound, premium SKU, default storage firewall on, managed RG name exact.
- **Managed RG inventory enumerated and RECORDED** (section 3.3 table vs reality), especially the
  dbstorage `publicNetworkAccess` + networkAcls values (closes the section 2 unknown; feeds the
  exemption-early-drop decision).
- NSG: `Microsoft.Databricks-workspaces_UseOnly_*` rules present on `nsg-databricks` (count +
  record); re-plan shows ZERO drift (lifecycle guard working).
- Sub-scoped exemption live with the exact member scope + 2026-08-01 expiry.
- ADLS: pna Disabled, shared-key off, HNS on, both PEs Approved, TWO A records (blob + dfs zones),
  `raw` filesystem exists, diagnostics wired.
- RCG live at priority 320 with the 5 service-tag rules, primary policy only.
- Fabric (if flag flipped): capacity Active at create, then SUSPENDED post-runbook (state
  recorded); admin member matches OQ-045.
- Flow-log/exemption regressions: the B1 RG-scoped waiver untouched; corp-MG assignment id
  literal unchanged.
