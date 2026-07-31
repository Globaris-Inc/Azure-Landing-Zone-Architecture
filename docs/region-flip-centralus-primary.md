# Region flip: centralus becomes primary, eastus2 becomes secondary/DR

- **Authority:** ADR-069 (`DECISIONS.md`). This document is the implementation surface for that ruling.
- **Date:** 2026-07-30
- **Author:** architect. Design and specification only. No `.tf`, `.yml` or `.tfvars` edited here.
- **Applies to:** the greenfield rebuild that restarts from Step 1 after teardown run `30597640251`.
- **Open items:** OQ-066 (live verification set), OQ-004 (resolved by ADR-069).

---

## 0. The ruling in one line

`primary_location = "centralus"`, `secondary_location = "eastus2"`. Everything else in this document
is consequence, not decision.

The estate's naming and topology are already **role-based** (`primary` / `secondary`), not
region-based. That is why this is a data change and not a rename. The three places that are NOT
role-based are enumerated in section 3 and each is dispositioned.

---

## 1. Why the change surface is neither 2 lines nor 12 files

There are exactly **16 region literals across 12 files**. The distinction that matters is not
"how many files" but **"which of these values is actually read at plan time"**.

Every deploy root is run by `.github/workflows/_tf-root.yml` with
`-var-file="<backend_rel>envs/poc.tfvars"` (line 351 plan, line 366 apply, line 397 destroy), and
`plan-on-pr.yml` does the same at line 146. So for any variable that `envs/poc.tfvars` declares, the
root's own `default` is dead weight: it can never be the value that runs in CI.

That gives a clean test:

> **A region default is LOAD-BEARING if and only if `envs/poc.tfvars` does not declare a variable of
> that exact name for that root.**

Applying it:

| # | File:line | Variable | Value today | Class | Disposition |
|---|---|---|---|---|---|
| 1 | `bootstrap/variables.tf:44` | `primary_location` | `eastus2` | **LOAD-BEARING** | **DO NOT CHANGE** (section 3.3) |
| 2 | `platform/identity/variables.tf:223` | `identity_location` | `eastus2` | **LOAD-BEARING** | **MUST CHANGE to `centralus`** (section 2.1) |
| 3 | `landing-zones/bank-data-p1/variables.tf:146` | `fabric_location` | `centralus` | **LOAD-BEARING** | Value already correct; description must be rewritten (section 4.2) |
| 4 | `landing-zones/bank-data-p1/variables.tf:168` | `search_location` | `centralus` | **LOAD-BEARING** | Value already correct; description must be rewritten (section 4.1) |
| 5 | `landing-zones/bank-app-p1/variables.tf:31` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 6 | `landing-zones/bank-data-p1/variables.tf:30` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 7 | `landing-zones/corp-a1/variables.tf:26` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 8 | `landing-zones/corp-a2/variables.tf:26` | `secondary_location` | `centralus` | cosmetic | align to `eastus2` |
| 9 | `landing-zones/online-p1/variables.tf:26` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 10 | `platform/connectivity/variables.tf:20` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 11 | `platform/connectivity/variables.tf:26` | `secondary_location` | `centralus` | cosmetic | align to `eastus2` |
| 12 | `platform/management/variables.tf:38` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 13 | `platform/management-groups/variables.tf:33` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 14 | `platform/security/variables.tf:18` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 15 | `synthetic/variables.tf:27` | `primary_location` | `eastus2` | cosmetic | align to `centralus` |
| 16 | `synthetic/variables.tf:33` | `secondary_location` | `centralus` | cosmetic | align to `eastus2` |

**Answer to the question as posed:** it is a **3-value functional change** plus a **12-file
documentation-hygiene pass**. Twelve of the sixteen literals are cosmetic. Of the four load-bearing
ones, one must move (`identity_location`), two already hold the right value but carry descriptions
that will be false the moment the flip lands, and one must deliberately stay put (bootstrap).

### 1.1 Why the cosmetic twelve are still mandated

They are zero-plan-delta text edits, and a default that disagrees with `envs/poc.tfvars` is exactly
the landmine that produced defect #2 in the table above. A local
`terraform plan` run without `-var-file` silently deploys into the wrong region; a reviewer reading
`platform/security/variables.tf` in isolation is told the wrong thing. Align them, and have the code
reviewer confirm a **zero-delta** plan on at least one already-planned root as proof they are inert.

---

## 2. The functional edits (behaviour changes)

### F1, F2. `envs/poc.tfvars` lines 22 and 25

```
primary_location   = "centralus"
secondary_location = "eastus2"
```

The surrounding comment block must also drop the `cto-hub-vnet-eastus2` example on line 27 and the
banking allocation-table region annotations on lines 156-159 and 262 (see section 5).

### F3. `platform/identity/variables.tf:223`

`identity_location` default becomes `"centralus"`, and its description (currently
"Defaults to the primary region (eastus2) to co-locate with the primary hub it peers to") is
rewritten to name centralus.

**This is the one edit that silently breaks the estate if it is missed.** `identity_location` is
consumed by the identity VNet, the Entra Domain Services managed domain and the identity Recovery
Services Vault. Left at `eastus2`, the flip produces an identity VNet in eastus2 global-peered to a
centralus primary hub: the peering would succeed (global VNet peering is legal), the plan would be
clean, and the apply would go green. The estate would simply be wrong, with the identity pillar
stranded in the DR region and the AADDS domain unmovable once created (Microsoft Entra Domain
Services FAQ, fetched 2026-07-30: "After you create a Domain Services managed domain, you can't move
it to a different subscription, resource group, or region"). A three-hour AADDS create is the most
expensive thing in the estate to get wrong.

`identity_rsv_storage_mode_type` stays `ZoneRedundant`; centralus has availability zones
(section 6.1), so the posture is preserved.

### F4. `envs/poc.tfvars` gains three new entries

This is the governance half of the fix, and it is not optional.

```
identity_location = "centralus"
fabric_location   = "centralus"
search_location   = "centralus"
```

The reason this ADR exists is that a load-bearing region input lived in a root's `variables.tf`
where nobody looked while the file that people DO read (`envs/poc.tfvars`) appeared to declare the
estate's entire region surface and did not. Making `envs/poc.tfvars` the **single declaration point
for every region-valued input** removes that class of defect permanently.

This introduces no new risk. `envs/poc.tfvars` already carries many root-specific variables that
most roots do not declare (`identity_domain_name`, `bank_app_p1_spoke_address_space`,
`enable_ai_platform`, and others). Terraform emits a warning, not an error, for an undeclared
variable supplied via `-var-file`, and that pattern has been in continuous use across every apply of
this estate. The root defaults stay as a safety net; the tfvars entry is authoritative.

---

## 3. Names that embed a region

Only three mechanisms in the whole estate put a region string into a resource name. Every other
name uses the `primary` / `secondary` role token (`vnet-hub-primary-globaris-poc`,
`rg-connectivity-secondary-globaris-poc`, `rg-corp-a1-workload`, `law-platform-globaris-poc`), which
is why the flip does not cascade.

### 3.1 Derived from the variable: no action, they track automatically

**AVM hub module default naming convention.** `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet`
v0.17.1 templates `${location}` and `${sequence}` into 20 default names
(`.terraform/modules/hub_and_spoke/variables.tf` lines 3-22). The repo does not override them, so
`fw-hub-eastus2-001` and `fw-hub-centralus-001` are **module output, not repo literals**. After the
flip the primary firewall becomes `fw-hub-centralus-001` and the secondary `fw-hub-eastus2-001`:
the two names swap hubs. The same applies to `fwp-hub-*`, `pip-fw-hub-*`, `rt-hub-fw-*`,
`rt-hub-std-*`, `vgw-hub-vpn-*`, `pdr-hub-*`, `bas-hub-*`.

> **This swap is safe ONLY because the estate is greenfield.** On a live estate, changing
> `primary_location` renames every one of those resources and Azure resource names are ForceNew:
> the plan would show `-/+ replace` on both firewalls, both policies and every hub route table. Per
> LESSON 26 and Rule 1 of the rebuild runbook, that is an unconditional STOP. There is no live
> estate right now, so this is a non-event. **If the flip is ever re-attempted against a live
> estate, it is a rebuild, not an edit.**

**Private DNS zones.** `Azure/avm-ptn-network-private-link-private-dns-zones` v0.23.1 substitutes
`{regionName}` with the region short name and `{regionCode}` with the geo code from its `location`
input, which the repo wires to `var.primary_location`
(`platform/connectivity/dns.tf:41`). Five of the 93 default zones are region-templated
(`.terraform/modules/private_dns_zones/variables.tf` lines 68, 104, 152, 248, 266):

| Zone template | Today | After the flip |
|---|---|---|
| `privatelink.{regionName}.azurecontainerapps.io` | `...eastus2...` | `...centralus...` |
| `privatelink.{regionName}.kusto.windows.net` | `...eastus2...` | `...centralus...` |
| `privatelink.{regionName}.azmk8s.io` | `privatelink.eastus2.azmk8s.io` | `privatelink.centralus.azmk8s.io` |
| `privatelink.{regionCode}.backup.windowsazure.com` | `privatelink.eus2....` | `privatelink.cus....` |
| `privatelink.{regionName}.prometheus.monitor.azure.com` | `...eastus2...` | `...centralus...` |

The geo code `cus` for centralus is confirmed from the pinned regions module data
(`.terraform/modules/private_dns_zones.regions/locals.geo.codes.tf.json`).

**The zone COUNT does not change.** Substitution renames, it never adds or removes an entry. The
PC-4C check (`length(@) == 89` in `rg-dns-globaris-poc`) therefore still holds unchanged, and its
`contains(name,'azmk8s')` filter is region-agnostic by construction.

**The one consumer.** `landing-zones/bank-app-p1/dns_links.tf:28` builds
`privatelink.${var.primary_location}.azmk8s.io` and looks it up by data source. Producer and
consumer both derive from the same variable, so they move together. No other root references any of
the five region-templated zones (verified by full-repo grep of literal `privatelink.` strings: the
only hits are `database.windows.net`, `azurecr.io`, `servicebus.windows.net`, `blob`, `dfs`,
`azuredatabricks.net`, `openai.azure.com`, `cognitiveservices.azure.com`, `search.windows.net`,
`services.ai.azure.com`, all region-agnostic).

**Network Watcher.** Four roots build `NetworkWatcher_${var.primary_location}` and one builds
`NetworkWatcher_${var.secondary_location}`, all in `NetworkWatcherRG` in the landingzones
subscription (`corp-a1/dns_links.tf:79`, `corp-a2/dns_links.tf:79`, `online-p1/dns_links.tf:69`,
`bank-app-p1/dns_links.tf:88`, `bank-data-p1/dns_links.tf:97`). Derived, so they track. But see the
hard pre-dispatch check in section 7.2: this data source resolves at PLAN time and has already
blocked this estate once.

### 3.2 Literal in a comment only: text hygiene, section 5

Roughly 30 comment and description strings name a region. They are listed in section 5. None of
them are load-bearing; several will be actively misleading after the flip.

### 3.3 Literal in a resource name: the bootstrap, and it does NOT move

`bootstrap/main.tf:60` creates `rg-tfstate-mgmt-eus2-001` and line 70 creates
`id-tfstate-mgmt-eus2-001`, both with `location = var.primary_location` (default `eastus2`).
`envs/poc.backend.hcl:24` hardcodes the resource group name, and every root's `terraform init`
depends on it.

**Ruling: the bootstrap stays in eastus2. The `eus2` name token becomes cosmetically stale and that
is accepted.** Four reasons, in order of force:

1. **Purge protection makes the move a 90-day outage risk, not a redeploy.**
   `azurerm_key_vault.tfstate` sets `purge_protection_enabled = true` with
   `soft_delete_retention_days = 90` (`bootstrap/variables.tf:87`). A purge-protected Key Vault
   **cannot be purged**; the name `kv-globaris-tfstate-01` would be unavailable for 90 days after a
   delete. This is the LESSON 57 class of failure and it is unrecoverable by retry.
2. **State infrastructure is a management-plane dependency with no data-plane coupling.** It has no
   latency requirement, no policy scope, no peering, and does not participate in the DR story. CI
   reaches it from a GitHub-hosted runner over the public internet through a JIT firewall flip
   (ADR-025), so its region has no bearing on estate availability.
3. **Anti-correlation is the better posture, not merely an acceptable one.** Keeping the Terraform
   state backend OUT of the primary workload region means a centralus regional event leaves the
   state readable, so the estate can still be planned and applied during the incident. Co-locating
   state with the primary workload region is a failure mode a reviewer should flag, not a goal.
4. **The move is disproportionate.** It means destroying the state Storage Account, the CMK Key
   Vault and the UAMI, recreating them under new names, rewriting `envs/poc.backend.hcl`,
   re-running `terraform init -migrate-state` for eleven roots, and re-pointing the OIDC federated
   credentials. The bootstrap is deliberately excluded from teardown
   (`include_bootstrap=false` is the default) precisely because it is the one thing that must not
   churn.

**What must be added instead:** a one-line note in `bootstrap/main.tf`'s header and in
`envs/poc.backend.hcl` recording that `eus2` in these names is historical, that the state backend is
intentionally NOT co-located with the primary workload region, and pointing at ADR-069. A stale name
with a written reason is documentation; a stale name without one is rot.

---

## 4. The interactions that are not a simple swap

### 4.1 AI Search `search_location`: the carve-out becomes REDUNDANT, and that must be stated, not deleted

Today (`landing-zones/bank-data-p1/ai.tf:180-240`):

- `module.search` sets `location = var.search_location` (default `centralus`) because AI Search
  returned `InsufficientResourcesAvailable` in eastus2 on apply `29678062833` (2026-07-19).
- The private endpoint sets `location = var.primary_location` (eastus2) to pin the PE NIC to the
  region of `snet-private-endpoints`. Without that override the module's
  `coalesce(each.value.location, var.location)` would default the NIC to centralus and collide with
  the eastus2 subnet, which is the exact failure that apply hit.
- Result: a documented **cross-region PE** (eastus2 NIC to centralus service), deviation register d7.

After the flip: `search_location` (centralus) equals `primary_location` (centralus). The service and
the PE NIC land in the same region. **The cross-region PE ceases to exist.** The deviation d7 is
retired by construction, without anyone touching the topology.

**Ruling: keep the variable, keep the value, keep the PE `location` override, rewrite the
description.**

- Keep the **variable** because it is the estate's proven capacity escape hatch for AI Search and it
  cost a failed apply to learn that it was needed. Removing it would delete the mechanism the moment
  its trigger stopped firing, which is how a lesson gets un-learned. It also stays consistent with
  the LESSON 42 pattern of pre-staging the toggle rather than the rework.
- Keep the **value** at `centralus`, which is now simply the primary region.
- Keep the PE `location = var.primary_location` override. It is now numerically a no-op, but it is
  the line that PINS the NIC to the subnet region. Removing it re-arms the exact module-default bug
  the next time `search_location` diverges from `primary_location` for any reason. This is a
  load-bearing line whose current value happens to be redundant, and those are the lines that get
  deleted by well-meaning cleanup.
- **Rewrite the description.** As written it asserts a cross-region PE that will no longer exist and
  cites eastus2 as the capacity-short region for a service that will no longer be deployed there. A
  false description on a load-bearing variable is worse than no description.

**Inversion risk, stated plainly.** The old fallback (eastus2) is now the secondary region, and
nothing in the record establishes that AI Search has capacity in eastus2 either. If centralus AI
Search capacity is exhausted at some future apply, the escape hatch has nowhere obvious to go. That
is not a blocker today (centralus is the region with the only positive capacity evidence, see
section 6.2), and it is registered in OQ-066 item 8.

### 4.2 Fabric `fabric_location`: same shape, same ruling

`landing-zones/bank-data-p1/fabric.tf:36-39` and `variables.tf:143-147`. Fabric CU quota was
portal-verified as 0 in eastus2 and available in centralus (2026-07-19, B5 pre-clearance addendum).
The deviation collapses identically: `fabric_location` equals `primary_location` after the flip. Keep
the variable and the value, rewrite the description, and delete the now-false claim that "the RG
stays eastus2".

Both d6 and d7 in the B-restoration deviation register (`docs/b-restoration-design.md`) should be
marked **retired by ADR-069** rather than resolved by a B-R action.

### 4.3 ADR-009 and the "PRIMARY hub policy only" reasoning: no ADR change, comments invert

ADR-009 rules that each hub carries an **independent** Azure Firewall Premium policy with no shared
parent, because the AVM hub module does not expose `base_policy_id`. That reasoning is about module
capability, not geography. **ADR-009 is unaffected by the flip and is not superseded.**

What DOES invert is the justification text on the three rule collection groups that attach to the
primary policy only:

- `platform/connectivity/firewall_rules_aks.tf:6` - "spokes are eastus2-only and their UDRs point at
  10.0.0.4; the secondary firewall..."
- `platform/connectivity/firewall_rules_apim.tf:9` - "nothing in eastus2 routes to the secondary
  firewall"
- `platform/connectivity/firewall_rules_databricks.tf:9` - "nothing in eastus2 routes to the
  secondary firewall"

The **code** is already correct: the RCGs attach to the primary policy, and the spoke UDRs point at
`10.0.0.4`, which is the primary firewall's private IP under `hub_primary_address_space =
10.0.0.0/16` regardless of which region "primary" means. `10.0.0.4` / `10.1.0.4` are pinned by CIDR,
not by region (ADR-042 firewall-IP contract), so PC-3X is unchanged. Only the word `eastus2` in
those three comments becomes `centralus`.

Same for the ADR-009 note in `platform/connectivity/dr.tf:6` and the diagnostics note in
`firewall_diagnostics.tf:24` ("the single eastus2 workspace serves both hub firewalls" becomes
centralus; the point being made, that diagnostic settings are cross-region-safe unlike Traffic
Analytics, is unchanged).

### 4.4 ADR-031 (SQL) and ADR-032 (App Service): the justification SURVIVES. Neither gate is lifted.

**Ruling: `enable_sql` and `enable_app_service` stay `false`. ADR-069 does not re-enable them and
the implementer must not flip them.**

The reasoning turns on a distinction ADR-032 itself drew and LESSON 42 later codified: **a
subscription OFFER cap is a different axis from regional quota.**

- **ADR-032** states it directly: "Two portal quota exports for the Compute provider confirm the
  `landingzones` subscription has healthy VM/vCPU quota in East US 2 (Total Regional vCPUs limit 10,
  VMs limit 25000, every family limit 10, 0 usage). So this is **not** a used-up quota - it is an
  **offer cap** on dedicated App Service (Basic and above)." It then generalises: "the
  `landingzones` subscription is compute-restricted for dedicated / reserved resources... Any future
  workload tier in these spokes should assume dedicated/reserved SKUs are unavailable here." That
  restriction attaches to the subscription's offer type. Changing the region does not change the
  subscription.
- **ADR-031** predicted the same for SQL before ever testing it: "Azure SQL logical server
  provisioning is disabled for the `landingzones` subscription in **eastus2** (corp-a1's region), and
  **is expected to be disabled in centralus** (corp-a2's region) for the same reason." corp-a2 has
  shipped with `enable_sql = false` in centralus on that basis since 2026-07-10. LESSON 42 records
  the outcome as "Azure SQL `ProvisioningDisabled` in **both target regions**".

So the honest position is: **the flip provides no new evidence that either cap lifts, and the
existing evidence predicts it does not.** Lifting either gate would be a separate decision requiring
a live probe in centralus on the landingzones subscription, and it is registered as OQ-066 items 6
and 7 with a recommended default of "leave both false for this rebuild".

Comment consequence: `corp-a1/variables.tf:75` says the SQL restriction applies "in the spoke region
(eastus2)" and `corp-a2/variables.tf:75` says "(centralus)". Those two strings swap. Same for
`corp-a1/main.tf:316` and `corp-a2/main.tf:306` ("restricted in eastus2/centralus", which is
order-agnostic and can stay).

### 4.5 Traffic Analytics: the asymmetry inverts with zero code change

LESSON 43: Traffic Analytics requires a Log Analytics workspace in the flow log's own region, and
the estate has exactly one platform LAW.

| | Today | After the flip |
|---|---|---|
| Platform LAW region | eastus2 | centralus |
| corp-a1, online-p1, bank-app-p1, bank-data-p1 | eastus2, TA **ON** | centralus, TA **ON** |
| corp-a2 | centralus, TA **OFF** (`InvalidTAWorkspaceRegion`) | eastus2, TA **OFF** (same error class) |

The shape is identical, the regions swap. `corp-a1/dns_links.tf` already parameterises
`workspace_region = var.primary_location`, and `corp-a2` simply has no `traffic_analytics` block.
**Zero code change.** The comments at `corp-a2/dns_links.tf:10-15, 85-86, 107-114` become exactly
backwards ("the only LAW is in eastus2... flow log in centralus") and must be inverted, including
the re-enable trigger, which becomes "if an eastus2 LAW is provisioned".

Same inversion for `corp-a1/backup.tf:8-10` ("data is kept zone-redundant within eastus2") and the
`platform_law_workspace_id` descriptions in `bank-app-p1/variables.tf:89` and
`bank-data-p1/variables.tf:88` ("eastus2, region-matched to this spoke").

### 4.6 AKS private DNS zone: tracks, but the RBAC comment does not

`landing-zones/bank-app-p1/aks.tf:133` names `privatelink.eastus2.azmk8s.io` in a comment, and line
32 describes the Private DNS Zone Contributor grant "at the shared privatelink.eastus2.azmk8s.io
zone scope". The actual grant is scoped to `data.azurerm_private_dns_zone.linked["aks"].id`, which
is derived. Comment-only, but a wrong zone name in an RBAC comment is the kind of thing a future
operator will act on. Fix both.

### 4.7 Recovery Services Vault and the region pair

`corp-a2` uses `storage_mode_type = "GeoRedundant"`, which relies on the Azure region pair for
replication. Verified 2026-07-30 from Microsoft Learn "List of Azure regions" (page updated
2026-07-28): **Central US is paired with East US 2 and East US 2 is paired with Central US.** The
pair is symmetric, so flipping which member is primary preserves geo-redundancy exactly. `corp-a1`
and `platform/identity` keep `ZoneRedundant`, which is valid because centralus has availability
zones (section 6.1).

---

## 5. Comment and description strings that become false

Non-load-bearing, but every one of them will mislead someone. Grouped by file for the implementer.

| File | Lines | What is wrong after the flip |
|---|---|---|
| `envs/poc.tfvars` | 27, 156-159, 262 | naming example; banking CIDR allocation table region annotations (`10.30` eastus2 / `10.31` centralus reserved etc. all invert); "the live eastus2 catalog" |
| `bootstrap/main.tf` | 6 | "(Management sub, eastus2)". Correct today and stays correct; add the section 3.3 note |
| `envs/poc.backend.hcl` | 24 area | add the section 3.3 note |
| `platform/connectivity/main.tf` | 62 | "primary (eastus2) + secondary (centralus) DR hub" |
| `platform/connectivity/dr.tf` | 6 | "primary (eastus2) and secondary (centralus)" |
| `platform/connectivity/outputs.tf` | 26, 36 | "primary hub VNet (eastus2)", "secondary (DR) hub VNet (centralus)" |
| `platform/connectivity/firewall_diagnostics.tf` | 24 | "the single eastus2 workspace" |
| `platform/connectivity/firewall_rules_aks.tf` | 6 | "spokes are eastus2-only" |
| `platform/connectivity/firewall_rules_apim.tf` | 9 | "nothing in eastus2 routes" |
| `platform/connectivity/firewall_rules_databricks.tf` | 9 | "nothing in eastus2 routes" |
| `platform/connectivity/variables.tf` | 113 | "the single eastus2 workspace serves both hub firewalls" |
| `platform/identity/variables.tf` | 221, 227 | "(eastus2)" twice |
| `landing-zones/corp-a1/main.tf` | 1, 7 | "(eastus2)" twice |
| `landing-zones/corp-a1/backup.tf` | 8-10 | "zone-redundant within eastus2 (corp-a2, the DR spoke, stays GeoRedundant)" |
| `landing-zones/corp-a1/variables.tf` | 51, 75 | "primary hub VNet (eastus2)"; "the spoke region (eastus2)" |
| `landing-zones/corp-a2/main.tf` | 1, 7 | "(centralus)" twice |
| `landing-zones/corp-a2/outputs.tf` | 6 | "(centralus DR)" |
| `landing-zones/corp-a2/providers.tf` | 8 | "(centralus)" |
| `landing-zones/corp-a2/variables.tf` | 51, 75 | "(centralus)" twice |
| `landing-zones/corp-a2/dns_links.tf` | 10, 14-15, 75, 85-86, 107-114 | the entire Traffic Analytics rationale block inverts (section 4.5) |
| `landing-zones/online-p1/main.tf` | 7 | "primary hub VNet (eastus2)" |
| `landing-zones/online-p1/dns_links.tf` | 65 | "primary region - eastus2" |
| `landing-zones/bank-app-p1/main.tf` | 11, 21-24 | spoke region + the four-row banking allocation table |
| `landing-zones/bank-app-p1/aks.tf` | 32, 133, 165 | zone-scope RBAC comment, API-server A-record comment, "platform LAW (eastus2, region-matched)" |
| `landing-zones/bank-app-p1/dns_links.tf` | 95 | "(eastus2, LESSON 43)" |
| `landing-zones/bank-app-p1/variables.tf` | 50, 89 | allocation-table description; "(eastus2, region-matched)" |
| `landing-zones/bank-data-p1/main.tf` | 12, 38-41 | spoke region + allocation table |
| `landing-zones/bank-data-p1/ai.tf` | 65, 191-193, 222-229 | model-catalog region; the whole Search cross-region-PE rationale (section 4.1) |
| `landing-zones/bank-data-p1/fabric.tf` | 36-39 | the Fabric deviation rationale (section 4.2) |
| `landing-zones/bank-data-p1/dns_links.tf` | 104 | "(eastus2, LESSON 43)" |
| `landing-zones/bank-data-p1/variables.tf` | 49, 88, 144, 166 | allocation table; LAW region; the two deviation descriptions |
| `synthetic/k6.tf` | 20 | "the same eastus2 environment" |
| `synthetic/outputs.tf` | 72 | "the eastus2 red-team simulator resources" |

Two notes for whoever does this pass:

- The **CIDR allocation tables** (`10.30` bank-app-p1 primary, `10.31` reserved DR, `10.32`
  bank-data-p1 primary, `10.33` reserved DR) annotate each block with a region. The CIDRs do not
  move; only the region annotation does. Do not touch the numbers.
- `scripts/check-claims.sh` compares comment claims against real `envs/poc.tfvars` values. Run it
  after the pass.

---

## 6. Does the quota position actually hold in centralus?

The honest summary: **the evidence base is asymmetric.** Almost everything on record is evidence
that eastus2 is SHORT, not that centralus is LONG. Centralus has real positive evidence for a
specific and useful subset, and no evidence at all for the single largest consumer in the estate.

### 6.1 Verified from vendor documentation (fetched 2026-07-30)

| Fact | Source |
|---|---|
| Central US has availability zone support | Microsoft Learn, "List of Azure regions" (page updated 2026-07-28) |
| Central US is paired with East US 2, and East US 2 with Central US | same |
| Central US is not a restricted-access region | same (no restricted marker on the row) |
| Central US geo code is `cus` | pinned `Azure/regions` module data in `.terraform` |
| Azure Static Web Apps supports `centralus` (allowed set is `westus2, centralus, eastus2, westeurope, eastasia`) | Microsoft Q&A error text quoting the service's own allowed-region list |

That last one matters more than it looks: Static Web Apps is one of the narrowest region footprints
in the estate (five regions) and online-p1 depends on it. It is confirmed.

### 6.2 EVIDENCED in centralus by this estate's own live history

Every one of these was actually created in centralus by a green apply of this repository:

| Capability | Evidence |
|---|---|
| VNet, subnets, NSG, route tables, hub peering | corp-a2 spoke, run `29129801098` (2026-07-10) |
| Azure Firewall Premium and Firewall Policy Premium | `fw-hub-centralus-001` landed during the cancelled Step 4 apply, 2026-07-31, and in every prior build |
| Recovery Services Vault, GeoRedundant | corp-a2, same run |
| Storage account (flow-log sink) | corp-a2, same run |
| VNet flow log via `NetworkWatcher_centralus` | corp-a2, same run |
| `NetworkWatcher_centralus` pre-exists in the landingzones subscription | `docs/preclearance/landing-zones.md:117` records `_centralus` present while `_eastus2` was MISSING and had to be pre-created |
| Microsoft Fabric F2 capacity | portal-verified 2026-07-19 (B5 pre-clearance addendum), then deployed |
| AI Search `basic` | deployed 2026-07-19 after the eastus2 `InsufficientResourcesAvailable` |

### 6.3 ASSUMED for centralus: no evidence either way

This is the list that must be closed by live checks before dispatch. I am read-only on live Azure and
am not asserting any of it.

| # | Unknown | Why it matters | Risk |
|---|---|---|---|
| 1 | **Compute vCPU quota in centralus** (Total Regional vCPUs, and the `DSv4`/`DASv4` family) | AKS needs 6 vCPUs steady (3 x `Standard_D2s_v4`), 8 during surge, against a limit that was **10 in eastus2**. The 2026-07-18 quota increase was filed **for eastus2**. Quota is per region per subscription: a granted eastus2 increase does **not** apply to centralus. | **HIGH. This is the single biggest risk of the flip.** |
| 2 | Microsoft Entra Domain Services availability in centralus | `identity_location`. AADDS has a restricted region list and the managed domain cannot be moved after creation. Failure mode is a 1-3h apply that ends badly. | **HIGH** |
| 3 | `gpt-5.4-nano` 2026-03-17 at `DataZoneStandard` capacity 10 in centralus | Model catalogs are per-region and the eastus2 catalog was already showing deprecations (ADR-051, LESSON 40). The Foundry account follows `primary_location`. | **HIGH** |
| 4 | `Standard_D2s_v4` availability and zone restrictions in centralus | AKS pins `availability_zones = ["1","2","3"]`; a zone restriction on the SKU fails the create. | Medium |
| 5 | APIM `Developer_1` stv2, internal VNet mode, in centralus | 30-180 min create; failing late is expensive. | Medium |
| 6 | Databricks Premium VNet-injected in centralus | B5. Consumes zero compute vCPUs, but the region must offer the service. | Medium |
| 7 | Service Bus Premium 1 MU and Event Hubs Standard in centralus | B3. | Low |
| 8 | App Gateway WAF_v2 with zonal Standard public IP in centralus | online-p1. | Low |
| 9 | Log Analytics workspace and Sentinel onboarding in centralus | platform LAW and security LAW both follow `primary_location`. | Low |
| 10 | Azure SQL and dedicated App Service on the landingzones subscription in centralus | Both gates stay `false` (section 4.4), so this does not block. Register only. | Not blocking |

Items 7 through 9 are low risk on general service-footprint grounds, but "low risk" is not
"verified", and the whole point of ADR-069 is that an unverified regional assumption is what got the
estate here.

---

## 7. The pre-dispatch check set

These belong in the pre-clearance document for the rebuild
(`docs/preclearance/2026-07-22-full-estate-rebuild.md`, or a dated addendum to it). Every one is a
READ. Run them all before dispatching Step 1, because a failure on any of RC-1 through RC-4 means the
flip needs re-scoping, not a mid-run patch.

### 7.1 Blocking, run before Step 1

**RC-1. Compute quota in centralus, landingzones subscription.**
```
az vm list-usage --location centralus --subscription <landingzones-sub> \
  --query "[?contains(localName,'Total Regional vCPUs') || contains(name.value,'standardDSv4Family') || contains(name.value,'standardDASv4Family')].{name:localName, used:currentValue, limit:limit}" -o table
```
Bar: Total Regional vCPUs limit **at least 10**, and the `standardDSv4Family` limit at least 8.
Below that, AKS cannot be deployed and `enable_kubernetes_platform` must go false for this rebuild
(the spoke still ships network-only, LESSON 42) while a centralus quota increase is filed.

**RC-2. Entra Domain Services region support.**
```
az provider show --namespace Microsoft.AAD \
  --query "resourceTypes[?resourceType=='domainServices'].locations" -o json
```
Bar: the list contains Central US. If it does not, STOP: `identity_location` must stay eastus2 and
ADR-069 needs an explicit carve-out for the identity pillar, which is a real architectural change
(identity in the DR region), not an implementation detail.

**RC-3. Foundry model catalog in centralus.**
```
az cognitiveservices model list --location centralus --subscription <landingzones-sub> \
  --query "[?model.name=='gpt-5.4-nano'].{name:model.name, version:model.version, status:model.lifecycleStatus, skus:model.skus[].name}" -o json
```
(`az cognitiveservices model list --location` confirmed GA in the Azure CLI reference, page updated
2026-07-07.) Bar: `gpt-5.4-nano` present, version `2026-03-17` available, `DataZoneStandard` in the
SKU list, and lifecycle status not `Deprecating`. If any of those fail, this is a **LESSON 40/41
lifecycle catch** and the fallback already recorded in ADR-051 applies: `GlobalStandard`, or the
newest current-GA nano-class model in the **centralus** catalog. That is an architect disposition,
not an implementer choice.

**RC-4. VM SKU availability and zone restrictions.**
```
az vm list-skus --location centralus --size Standard_D2s --subscription <landingzones-sub> \
  --query "[?name=='Standard_D2s_v4'].{name:name, zones:locationInfo[0].zones, restrictions:restrictions}" -o json
```
Bar: zones `["1","2","3"]` present and `restrictions` empty.

### 7.2 Blocking, run before Steps 5 to 9 (the spokes)

**RC-5. Network Watcher, both regions, landingzones subscription.**
```
az network watcher list --subscription <landingzones-sub> \
  --query "[].{name:name, location:location, rg:resourceGroup}" -o table
```
Bar: **both** `NetworkWatcher_centralus` and `NetworkWatcher_eastus2` present in `NetworkWatcherRG`.
This has already blocked this estate once: `docs/preclearance/landing-zones.md:117` records
`NetworkWatcher_eastus2` MISSING as a hard plan-time BLOCKER for corp-a1 and online-p1, because the
`data.azurerm_network_watcher` data source resolves at PLAN time, before any VNet exists to trigger
auto-creation (LESSON 43). Under the flip, four spokes need `_centralus` and corp-a2 needs
`_eastus2`. Both were live as of the 2026-07-22 gate and `NetworkWatcherRG` is explicitly protected
from teardown (`docs/preclearance/b1-bank-spokes.md:78`), so this should pass. Verify it anyway.
If either is missing, pre-create it before the plan; do not delete `NetworkWatcherRG` in any sweep.

### 7.3 Non-blocking, run at leisure

**RC-6.** Service availability sweep for centralus across APIM, Databricks, Service Bus Premium,
Event Hubs, App Gateway WAF_v2, Log Analytics:
```
az provider show --namespace Microsoft.ApiManagement --query "resourceTypes[?resourceType=='service'].locations" -o json
az provider show --namespace Microsoft.Databricks     --query "resourceTypes[?resourceType=='workspaces'].locations" -o json
az provider show --namespace Microsoft.ServiceBus     --query "resourceTypes[?resourceType=='namespaces'].locations" -o json
az provider show --namespace Microsoft.EventHub       --query "resourceTypes[?resourceType=='namespaces'].locations" -o json
az provider show --namespace Microsoft.OperationalInsights --query "resourceTypes[?resourceType=='workspaces'].locations" -o json
```

**RC-7. Confirm no allowed-locations Deny policy blocks centralus.** After Step 1 applies:
```
az policy assignment list --scope /providers/Microsoft.Management/managementGroups/globaris --disable-scope-strict-match \
  --query "[?contains(to_string(parameters),'listOfAllowedLocations')].{name:name, scope:scope, params:parameters}" -o json
```
Bar: empty. Strong prior evidence this passes: the estate has been deploying into centralus
continuously (secondary hub, corp-a2, Fabric, AI Search), and the repo assigns no
`listOfAllowedLocations` parameter anywhere (`policy_default_values` is supplied only when
`enable_om_phase1` is true, which is held false for this rebuild). Verify anyway per LESSON 34: the
policy matrix is checked live at every ancestor MG scope, not reasoned about.

---

## 8. Dispatch impact

### 8.0 BLOCKING PRECONDITION: teardown run `30597640251` FAILED. The estate is not greenfield.

**This was found while writing this document, in response to the operator asking why
`platform/security` was skipped in the teardown. It changes the premise of the flip and it outranks
everything else in this section.**

Run `30597640251` (`target=all mode=az-sweep remove_mg_hierarchy=true`, 2026-07-31T01:56Z)
**completed with conclusion `failure`**. Job outcomes:

| Job | Result |
|---|---|
| Confirm teardown | success |
| Phase 0 DISARM | success |
| Phase 0.5 Databricks precascade | skipped |
| All 11 Phase 1 per-root `terraform destroy` jobs (synthetic, bank-app-p1, bank-data-p1, online-p1, corp-a2, corp-a1, **security**, connectivity, identity, management, management-groups) | **skipped** |
| Phase 2 AZ SWEEP | **failure** |
| Phase 3 VERIFY | **failure** |
| Phase 4 STATE RESET | **skipped** |

**Why security was "skipped": it was not singled out.** `teardown.yml:408` gates the `security` job
on `inputs.mode == 'terraform'`, and every one of the other ten Phase 1 jobs carries the same gate.
The run was dispatched `mode=az-sweep`, which is the **state-gone fallback** in which Phase 1 never
executes at all (ADR-065 decision 4, ADR-066). So all eleven were skipped by design. ADR-066 made
`mode=terraform` the PRIMARY `target=all` path specifically so every layer destroys transparently and
green; this run chose the fallback.

**Where Phase 2 died.** Step 4-pre, the MG-scope extension last-chance gate, on an ARM
**500 Internal Server Error** listing budgets at MG `management`. The script refused to read a
failed list as "no budgets" and exited 1. That is ADR-063 G-1 behaving exactly as specified, and it
is a transient server error, not a design defect. But it means the sweep stopped at step 4-pre, so:

| az-sweep step | Ran? | Consequence |
|---|---|---|
| 1 Databricks cascade | yes | - |
| 2-pre resource-scoped diagnostic settings | yes | - |
| 2 RG sweep (submitted `--no-wait`) | yes | `rg-finops`, `rg-management`, `rg-dns`, `rg-connectivity-primary`, `rg-connectivity-secondary`, `rg-security` deletes submitted |
| 3 Key Vault purge | yes, **with 4 failures** | 4 security Key Vaults left SOFT-DELETED: `Operation 'DeletedVaultPurge' is not allowed` (`MethodNotAllowed`) on each. The script classified them "not purge-protected" and the purge was still refused, so either the classification is wrong or the SP lacks `Microsoft.KeyVault/locations/deletedVaults/purge/action` |
| 4 MG hierarchy removal | **NO** (died in 4-pre) | **the MG hierarchy is still live** |
| 6 subscription-scope sweep | **NO** | budgets, cost exports, cost anomaly action, subscription diagnostic settings, Defender pricing reset, RP unregister ALL SURVIVE. This is the exact ADR-057 survivor class that collides with Step 2 |
| 7 RG reconciliation | **NO** | no bounded wait, no confirmation the submitted RG deletes finished |
| **7b Security LAW purge (OQ-063 backstop)** | **NO** | **the Security Log Analytics workspace is SOFT-DELETED, not purged** |

**That last row is the real answer to the operator's question, and it is serious.** There are two
mechanisms that purge the Security LAW:

1. **Primary:** `platform/security/providers.tf` sets `permanently_delete_on_destroy = true`, so the
   root's own `terraform destroy` purges rather than soft-deletes. **Only fires in
   `mode=terraform`.** Skipped here.
2. **Backstop:** az-sweep step 7b. **Never reached here.**

Neither ran. So the estate is now in precisely the condition ADR-067 Class 2 describes and OQ-063
was raised to prevent: the next `platform/security` apply recovers a soft-deleted workspace full of
orphaned Sentinel rules and fails with roughly 11 "already exists / needs to be imported" errors.
That is the failure class that blocked the 2026-07-29 rebuild.

**Consequence for the region flip.** The flip's safety argument in section 3.1 rests entirely on the
estate being greenfield: renaming `fw-hub-eastus2-001` to `fw-hub-centralus-001` is free on an empty
estate and a ForceNew `-/+ replace` on a live one. Right now `platform/connectivity`'s state blob
still describes the 543 resources that landed before the Step 4 cancellation, including both Premium
firewalls under their eastus2-primary names, and Phase 4 never reset it. **Applying the flip against
that state would produce exactly the replace-on-live-resource plan that Rule 1 and LESSON 26 call an
unconditional STOP.**

**Ruling (ADR-069 decision 6): the flip is authored and merged now, and is NOT dispatched until a
teardown has genuinely completed.** The gate is:

- **G-1.** Re-run teardown to green. Recommended `mode=terraform` per ADR-066, so the eleven Phase 1
  destroys actually run and the security root's native LAW purge fires as the primary mechanism
  rather than relying on a backstop that a step-4-pre failure can skip. If `mode=az-sweep` is used
  again, the 500 was transient and a retry is the correct first response (ADR-063 treats a failed
  list as fatal precisely so it can be retried rather than silently mis-read).
- **G-2.** Phase 3 VERIFY green and Phase 4 STATE RESET **executed, not skipped**. Phase 4 is gated
  hard on VERIFY success, so a green VERIFY is the only route to reset state.
- **G-3.** Independent qa-engineer greenfield confirmation (ADR-058: two gates, two actors).
- **G-4.** PC-1SEC re-verified immediately before Step 3: zero live AND zero soft-deleted
  `law-security-*` workspaces. Given the above this is now a near-certain finding rather than a
  formality:
  ```
  az monitor log-analytics workspace list-deleted-workspaces --subscription <security-sub> -o table
  ```
- **G-5.** The four soft-deleted `kv-sec-globaris-*` vaults are purged or their `MethodNotAllowed`
  is root-caused. If the SP genuinely cannot purge, the vault names are blocked for the soft-delete
  retention window and the security root's random-suffix naming is what saves the redeploy. Confirm
  that before Step 3 rather than discovering it at apply.
- **G-6.** Confirm the six submitted RG deletes actually completed (step 7 never ran, so nothing
  waited on them).

None of G-1 through G-6 is caused by the region flip. They are pre-existing teardown debt that the
flip must not be dispatched on top of. This is registered as **OQ-066 item 0** and it is the only
item in this document that blocks merging as well as dispatching, in the sense that the ADR must
carry the gate.

### 8.1 The 14-step order does NOT change

Nothing in the step order derives from geography. The dependencies are: MG tree, then platform
(management, security), then connectivity (hub fabric plus firewalls), then spokes, then identity
two-pass, then the B7 re-land. Steps 5 to 9 remain mutually independent, and the "shortest first,
longest last" recommendation is unaffected. The Step 4 ordering hazards (APIM needs firewall passage
mid-provision, ADR-047; AKS cannot bootstrap through a blackholed route, ADR-044) are role-based, not
region-based.

Step 0 of the runbook (prove the estate is actually empty, 0a-0d) is not optional this time. Given
section 8.0 it is the gate, not a formality.

### 8.2 The plan bars: expected to hold by construction, but they are NO LONGER VERIFIED

| Root | Bar | Verdict |
|---|---|---|
| `platform/management-groups` | 537 adds | Holds by construction. MG hierarchy plus ALZ policy objects; nothing region-conditional. `location` feeds DINE remediation identities, not resource count. |
| `platform/management` | 36 adds | Holds by construction. LAW, action group, budgets, exports, dashboard, workbook, policy set; all region-agnostic in count. |
| `platform/security` | 48 adds | Holds by construction. LAW, Sentinel onboarding and rules, 8 Defender plans; count region-agnostic. |
| `platform/connectivity` | **696 adds** | Holds by construction. The five region-templated private DNS zones are RENAMED, never added or removed (section 3.1); the hub resource set is identical. |

**But treat all four as UNVERIFIED until re-measured.** The runbook words the 696 bar as "EXACTLY
696... This is not an estimate, it is today's verified dry-plan (run `29851422904`)... Any deviation
is a STOP requiring a fresh disposition, not a judgement call." That precedent was measured with
`primary_location = eastus2`. It cannot be cited as verified against a changed input.

**Ruling:**

1. Run `action=plan` on all four roots against the flip branch **before** the apply of each. This is
   already mandatory under ADR-060 and the 2026-07-31 process correction; it is doubly so here.
2. If a plan returns the same number, record it as **re-verified under centralus-primary** and
   proceed.
3. If any plan returns a different number, even by one, that is a **STOP** requiring an architect
   disposition. Do not update the bar silently. A count delta means something region-conditional
   exists that this analysis did not find, which is precisely the information the bar is there to
   surface.
4. The spoke magnitudes (roughly 25-45, 25-45, 30-45, 50-60, 60-70) were always labelled derived
   estimates rather than verified precedent. They are unchanged in status. The SHAPE rules remain
   the real bar.

### 8.3 Pre-clearance conditions that change

| Condition | Change |
|---|---|
| Quota checks | **Materially changed.** Every quota and offer probe recorded for eastus2 must be re-run for centralus. The 2026-07-18 eastus2 vCPU increase does not carry over. RC-1. |
| Resource-type lifecycle audit (step 3d) | **Re-run the region-scoped half.** Same resource types, different region: the model catalog (RC-3) and SKU availability (RC-4) are region-specific and must be re-audited. The service-lifecycle half (NSG flow logs retired, Defender plan deprecations) is region-independent and carries over. |
| Live policy matrix at every ancestor MG scope | Unchanged in method, plus RC-7. |
| Tenant/directory prerequisites | Unchanged. Security Administrator gaps, RP registrations and licensing are tenant or subscription scoped, not regional. All the `false` gates (`enable_aad_diagnostics`, `enable_ueba`, `enable_mde_connector`, `enable_aad_connector`, `enable_ti_connector`, `enable_firewall_ti_rule`) stay false. |
| `enable_om_phase1` | Stays `false` for the rebuild (PC-4R option A). Unaffected. |
| PC-3X (firewall private IPs `10.0.0.4` / `10.1.0.4`) | **Unchanged.** Pinned by CIDR, not region. Only the firewall NAMES swap (section 3.1), so read the name from the table rather than assuming it. |
| PC-4C (89 private DNS zones) | **Unchanged in count**, and its `contains(name,'azmk8s')` filter is region-agnostic. |
| PC-1SEC (Security LAW purged) | Unchanged. |
| NEW: RC-1 through RC-7 | Added by this ADR. RC-1 to RC-4 block Step 1; RC-5 blocks Steps 5 to 9. |

### 8.4 Cost

No material change. The two regions price identically for every SKU in the estate, and the resource
set is unchanged.

---

## 9. Hand-off

### 9.1 cloud-engineer (Terraform and tfvars)

1. `envs/poc.tfvars` lines 22 and 25: swap the two region values (F1, F2).
2. `envs/poc.tfvars`: add `identity_location`, `fabric_location`, `search_location`, all
   `"centralus"`, in the "Global / shared" block next to the two flipped lines, with a comment
   pointing at ADR-069 section F4 (F4).
3. `platform/identity/variables.tf:223`: default to `"centralus"`; rewrite the description (F3).
4. The twelve cosmetic defaults in section 1's table: align each to the new value. Zero plan delta
   expected.
5. `landing-zones/bank-data-p1/variables.tf:144` and `:166`: rewrite both descriptions per sections
   4.1 and 4.2. **Do not change the values. Do not remove the variables. Do not remove the
   `location = var.primary_location` override on the Search private endpoint** (`ai.tf`, in the
   `private_endpoints.search` block).
6. `landing-zones/bank-data-p1/ai.tf` and `fabric.tf`: rewrite the deviation comment blocks.
7. The comment pass in section 5. Do not touch any CIDR.
8. `bootstrap/main.tf` header and `envs/poc.backend.hcl`: add the "state backend stays in eastus2 by
   design, see ADR-069 section 3.3" note. **Change nothing else in `bootstrap/`.**
9. Run `terraform fmt -recursive`, `terraform validate` on every touched root, and
   `scripts/check-claims.sh`.
10. **Do not flip `enable_sql`, `enable_app_service`, or any other gate.** ADR-069 changes region
    values and text, nothing else.

### 9.2 devsecops-engineer (workflows and pre-clearance)

The workflows carry **no region literal** (verified: the only `centralus`/`eastus2` hits under
`.github/` are substring false positives on `PLATFORM_LAW_CUSTOMER_ID`). No `.yml` change is
required by the flip.

What IS owed:

1. Fold RC-1 through RC-7 (section 7) into the rebuild pre-clearance document as a dated addendum,
   with RC-1 to RC-4 marked blocking-before-Step-1 and RC-5 blocking-before-Steps-5-to-9.
2. Update `docs/2026-07-22-full-estate-rebuild-runbook.md`: mark the four plan bars as
   re-verification-required under centralus-primary (section 8.2), and add the section 8.2 rule 3
   STOP condition to the matrix.
3. Update the Steps 5-9 table's corp-a2 row, which currently reads "secondary region... Traffic
   Analytics DISABLED on the DR (centralus) spoke".

### 9.3 code-reviewer

Specific things to check rather than a generic pass:

- No `.tf` under `bootstrap/` was modified other than the header comment.
- `search_location` and `fabric_location` still exist, still default to `centralus`, and the Search
  private endpoint still carries `location = var.primary_location`.
- `enable_sql`, `enable_app_service` and every tenant-permission gate are unchanged and still false.
- Every CIDR in every allocation table is byte-identical to before.
- `envs/poc.tfvars` now declares all five region-valued inputs.
- No em dash or en dash in any added line.
