# Pre-clearance: Wave B5 - data platform (bank-data-p1 + connectivity RCG)

> **Roots:** `landing-zones/bank-data-p1` (Databricks + ADLS + exemption unit; Fabric GATED OFF) and
> `platform/connectivity` (rcg-dbx-egress-primary only).
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-18 (all live checks run this session).
> **Code identity:** banking @ the B5 merge (reviewer APPROVE after one fix cycle: the
> enable_fabric_capacity/fabric_admin_members validation guard). Design contract:
> `docs/b5-data-platform-design.md` (ADR-048). OQ-045 UNANSWERED - Fabric flag false, guard enforces
> the coupling in code.
>
> ## VERDICT: **GO - CONDITIONAL** on PC-1D through PC-5D below.
> PC-1D is a pre-dispatch CODE change (one line, found by this pre-clearance's live member sweep).

---

## 1. Live policy matrix (enumerated this session, member by member where storage/Databricks-relevant)

Corp MG carries 5 assignments; landingzones MG 56; sub scope 1 (SecurityCenterBuiltIn). Full
relevant-member dispositions:

| # | Assignment (scope) | Member / policy | Live effect | B5 exposure | Disposition |
|---|---|---|---|---|---|
| 1 | `Deny-Public-Endpoints` (corp MG) | `StorageDenyPaasPublicIP` -> builtin b2982f36 (publicNetworkAccess) | **Deny** (defaultValue; assignment passes `{}` params, enforcement Default, notScopes empty) | The RP-created `dbstorage*` PUT in the managed RG - THE ruled collision (ADR-048) | Covered by the merged collision unit: storage firewall (posture) + sub-scoped expiring Waiver + 300s sleep (guarantee). **Assignment id BYTE-VERIFIED live == the literal in policy_exemptions.tf** (the B1-precedent stale-ref check); member reference id `StorageDenyPaasPublicIP` byte-verified in the live initiative |
| 2 | `Deny-Public-Endpoints` (corp MG) | **`Deny-Storage-Public-Access`** -> builtin 4fa4b6c0 (allowBlobPublicAccess notEquals false) | **Deny** (defaultValue) | **NEW CATCH (this sweep): a SECOND Deny member evaluating the SAME dbstorage PUT, NOT covered by the merged exemption** (its ref-id list carries only StorageDenyPaasPublicIP). Same unverifiable-RP-PUT-sequencing class: if the RP's create payload omits or trails `allowBlobPublicAccess=false`, the create dies identically | **PC-1D: widen `policy_definition_reference_ids` to add `Deny-Storage-Public-Access` BEFORE dispatch.** Same assignment, so it is a one-line list edit on the existing exemption - no new resource, no new scope |
| 3 | `Deny-Public-Endpoints` (corp MG) | `Deny-Workspace-PublicNetworkAccess` -> builtin 87ac3038 | Deny | NONE - live rule read: targets **Microsoft.DesktopVirtualization/workspaces (AVD)**, not Databricks | PASS. Confirms the design assumption: NO member in the initiative targets Microsoft.Databricks; workspace `public_network_access_enabled = true` is policy-safe |
| 4 | `Deny-Public-Endpoints` (corp MG) | `MlDenyPublicIP` -> builtin 438c38d2 | Deny | NONE - Azure ML workspaces (Microsoft.MachineLearningServices), not Databricks | PASS |
| 5 | `Deny-Public-Endpoints` (corp MG) | ADLS-relevant members (Storage x2 as above) | Deny | Our `stlake*` SA is authored compliant: pna false, allow_nested false, ACL Deny | PASS - compliant by design, zero exemption (design ruling holds) |
| 6 | `Deny-Public-IP-On-NIC` (corp MG) | public IP on NIC | Deny (Default enforce) | NONE at B5: NPIP true and ZERO cluster NICs exist (hard boundary) | PASS; also future-proof (NPIP nodes carry no public IPs) |
| 7 | `Deny-HybridNetworking` (corp MG) | ER/VPN/vWAN types | Deny | NONE | PASS |
| 8 | `Audit-PeDnsZones` / `Deploy-Private-DNS-Zones` (corp MG) | PE DNS zone audit / DINE | Audit / DINE | blob+dfs PEs with module-managed zone groups | PASS by proven precedent (ACR/EH/SB PEs, B2/B3 - no DINE conflict with module-managed zone groups) |
| 9 | `deny-pub-net-globaris` (landingzones MG) | SQL/KV/Storage members | **Audit** (all 3 - B1 live member dump; assignment unchanged in today's list) | dbstorage + flow-log SAs flag as non-compliant | PASS - Audit never blocks; accepted noise (OQ-016 class) |
| 10 | `Deny-Storage-http` (landingzones MG) | builtin secure-transfer (supportsHttpsTrafficOnly) | Deny-class assignment, Default enforce | dbstorage PUT (RP-authored), stlake (authored `https_traffic_only_enabled` default true in 0.7.3) | PASS-with-rationale: the Databricks RP has set httpsOnly=true on workspace SAs for years and NO Databricks-vs-secure-transfer collision class is documented anywhere (unlike the pna collision); residual covered by the section 4 failure disposition. NOT widened into the belt: different assignment = a whole new exemption resource for a no-evidence class - disproportionate |
| 11 | `Enforce-TLS-SSL-Q225` (landingzones MG) | TLS-minimum members incl. storage | Default enforce (member effects per ALZ defaults) | dbstorage (RP sets TLS1_2 on new accounts), stlake (explicit TLS1_2) | PASS-with-rationale, same class and same disposition coverage as row 10; flow-log SA precedent applied clean at B1 under the same assignment |
| 12 | `Deny-Subnet-Without-Nsg` (landingzones MG) | subnets need NSGs | Deny | No subnet creates/updates in B5 (both Databricks subnets carry NSGs since B1) | PASS |
| 13 | `Enforce-GR-Storage0` / `-Synapse0` / `-MachLearn0` / all other Enforce-GR-* | guardrail initiatives | **DoNotEnforce** | any | PASS - moot |
| 14 | Tag-governance Modify + DINE diagnostics assignments | Modify/DINE | non-blocking | managed RG inherits workspace tags (RP behavior) | PASS; OQ-032 tag noise expected in plans as always |
| 15 | `SecurityCenterBuiltIn` (sub) | Defender defaults | Default | none blocking | PASS |

**No assignment at any ancestor scope targets Microsoft.Databricks, Microsoft.Fabric, or
Microsoft.Databricks/accessConnectors.** (Fabric is additionally gated off this wave.)

## 2. Tenant/subscription prerequisites (live)

| Check | Result | Disposition |
|---|---|---|
| `Microsoft.Databricks` RP (landingzones sub) | **Registered** | PASS |
| `Microsoft.Fabric` RP (landingzones sub) | **NotRegistered** | Recorded for the record; NOT a B5 blocker (flag false; zero Fabric resources reach ARM - the validation guard also code-enforces OQ-045). **PC-5D: any future `enable_fabric_capacity` flip MUST register the RP first** - do not assume azurerm auto-registration covers it (4.x registers only its default set; verify at flip) |
| Exemption conflicts at sub scope | Only the two B1 RG-scoped flow-log waivers exist; NO subscription-scope exemption present; name `exempt-dbx-managed-storage-bank-data-p1` free | PASS |
| Managed RG `rg-bank-data-p1-dbx-managed-globaris-poc` | Does NOT exist | PASS - clean create target for the RP |
| Workload RG `rg-bank-data-p1-workload-globaris-poc` | Exists, EMPTY | PASS - clean landing for connector/workspace/stlake; no name-collision surface |
| `dbstorage<hex8>` / `stlake...<hex8>` global SA names | NOT pre-checkable (random_id renders at apply) | Accepted: 8-hex suffix, collision probability negligible; if `StorageAccountAlreadyTaken` ever fires, fix-spec = taint the relevant random_id, single rerun |
| Compute quota | ZERO Microsoft.Compute consumption in this wave (workspace create allocates no VMs - doc-verified; no clusters built). OQ-043 family question moot for B5-as-designed | PASS - no quota surface. Fabric F-SKU offer availability = PUT-time watch at flip time only |
| Primary hub firewall policy `fwp-hub-eastus2-001` RCGs | `rcg-aks-egress-primary` @300, `rcg-apim-egress-primary` @310 - **320 FREE** | PASS - matches the design slot |
| Firewall-IP contract 10.0.0.4/10.1.0.4 | Standing (last live-verified B4); this wave's connectivity change is an RCG add only - no IP surface | PASS - no re-verification trigger |

## 3. Lifecycle audit (step 3d)

Current as of the design session THIS date (2026-07-18): Databricks `standard` SKU deprecated Oct
2026 (Premium shipped); NSG flow logs class n/a; new-VNet default-outbound retirement 2026-03-31
satisfied by the UDR-to-AZFW explicit egress; service-tag mechanism is the current
Databricks-recommended egress control; `azurerm_fabric_capacity` current in the pinned provider
line. **Re-run the delta if either apply slips past 2026-07-25** (ADR-045 re-affirmation date).

Known-issues sweeps (both FIRST-consumption modules) done at design/build: databricks-workspace
0.5.0 azapi migration notes read from tag source; storage-storageaccount 0.7.3
`account_sku_name`-wins and metrics-only SA-scope diagnostics constraints already encoded in the
merged code. No open upstream issue matching our exact shape found at build time; re-sweep only on
failure (one consolidated fix-spec rule).

## 4. The one unverifiable-pre-apply item (honesty note) + failure disposition

**RP-PUT sequencing:** whether the Databricks RP's `dbstorage*` create PUT is policy-compliant at
the instant of evaluation (pna under create-time storage firewall; allowBlobPublicAccess field
presence) CANNOT be verified before the first apply. That is precisely why the collision unit's
guarantee half (the exemption) exists, and why PC-1D widens it to both storage Deny members of the
same assignment.

**Failure signature if the race is lost anyway:** the workspace create errors with
`RequestDisallowedByPolicy` naming the `Deny-Public-Endpoints` assignment and either builtin
b2982f36 (pna member) or 4fa4b6c0 (public-access member) against a `dbstorage*` resource id in the
managed RG. Disposition (single contained retry, LESSON 59):
1. `az policy exemption show` on the sub-scope exemption - confirm it exists, is unexpired, and
   its ref-id list carries BOTH members (if 4fa4b6c0 is cited and the list does not carry
   `Deny-Storage-Public-Access`, PC-1D was skipped - fix that first).
2. If the exemption is correct, the failure is propagation timing - the 300s sleep lost the race
   once; do NOT change code.
3. Check the workspace `provisioningState`: if `Failed`, delete the failed workspace object (and
   let the RP clean its managed RG) before rerunning; the resource is not in TF state after a
   failed create, so the rerun is a clean PUT.
4. ONE rerun. A second identical failure = STOP, full diagnosis, no spray (LESSON 59).
If a DIFFERENT member fires (rows 10/11 class - https/TLS): that falsifies the no-evidence
rationale; the fix-spec is a new exemption unit against THAT assignment, one consolidated change,
single rerun.

## 5. Plan-shape bars (BOTH applies; any breach = STOP before apply)

### Apply 1 - `platform/connectivity`

- **EXACTLY 1 add:** `azurerm_firewall_policy_rule_collection_group.dbx_egress_primary["primary"]`
  at priority 320 (5 service-tag rules in one network collection).
- **0 destroys, 0 replaces.** Standing OQ-032 tag-drift changes allowed (the ~282-change noise
  class seen at B4); NO other functional change line.
- Post-apply gate: RCG live-confirmed at 320 before apply 2 is dispatched (pattern consistency
  with ADR-044/047; not create-blocking for B5 since no cluster egress exists yet).

### Apply 2 - `landing-zones/bank-data-p1` (enable_data_platform=true, enable_fabric_capacity=false)

Pure adds by address class (~14-18 total):

| Class | Addresses |
|---|---|
| Exemption unit | `azurerm_subscription_policy_exemption.dbx_managed_storage["main"]` (ref-id list per PC-1D), `time_sleep.wait_dbx_storage_exemption["this"]` |
| Random ids | `random_id.dbfs_sa["main"]`, `random_id.datalake_sa["main"]` |
| Connector | `azurerm_databricks_access_connector.dbx["main"]` |
| Workspace module set | `module.databricks_workspace["main"]`: the azapi workspace, 1 diagnostic setting, + the AVM telemetry pair |
| Datalake module set | `module.datalake["main"]`: the azapi SA, 1 `raw` gen2 filesystem, 2 private endpoints (blob + dfs) WITH module-managed zone groups, 1 metrics-only diagnostic setting, + telemetry pair |

Hard bars:
- **ZERO destroys, ZERO replaces** (any `-/+` = STOP, LESSON 26).
- **ZERO changes** at any pre-existing address: spoke_vnet/subnets, peerings, route table, NSGs
  (the lifecycle edit is config-only and must NOT produce a plan line), flow-log SA/flow log, B1
  RG-scoped exemption, DNS links.
- **NO address containing `fabric` may appear anywhere in the plan.** The flag is false and
  OQ-045 is unresolved - ANY fabric line means wrong code or wrong tfvars = STOP.
- The two PE zone groups must reference the existing central blob/dfs zone ids (connectivity
  sub), not create zones.

## 6. Durations / operational

- Wave total ~20-35 min: in-apply 300s exemption sleep, connector seconds, workspace create
  5-15 min, SA ~1-2 min, PEs ~2 min each. No long-create isolation needed (nothing near the B4
  class). NO second dispatch while an apply runs (B3 duplicate-dispatch incident class;
  single-dispatcher rule - all dispatches in the main lane).
- Teardown currency: no new root; bank-data-p1 already wired in teardown.yml (B1). Destroy note:
  workspace destroy removes the managed RG via the RP; the sub exemption and sleep destroy with
  the root; Fabric absent.

## 7. GO conditions (all must hold)

| # | Condition |
|---|---|
| **PC-1D** | **Pre-dispatch code change:** widen `azurerm_subscription_policy_exemption.dbx_managed_storage` `policy_definition_reference_ids` to `["StorageDenyPaasPublicIP", "Deny-Storage-Public-Access"]` (same assignment - one-line list edit; update the comment/description accordingly). Cloud-engineer + reviewer per standing gates. Rationale: section 1 row 2 |

### ADDENDUM 2026-07-18 - apply 2 plan-scan disposition (PC-2D bar amendment): APPROVED

Apply 1 went green (1 added, RCG live @320 Succeeded). bank-data-p1 plan run 29673424352 came in
at `28 add / 15 change / 0 destroy` vs the section 5 estimate of ~14-18 adds. Diagnosis of the
excess: entirely ONE class - the storage module 0.7.3 fans its telemetry out PER
diagnostic-submodule interface (blob/file/queue/table/storage_account x modtm_telemetry +
random_uuid = 10 telemetry stubs), which the estimate undercounted. modtm/random telemetry
resources are config-only no-ops with zero ARM PaaS surface and zero policy exposure - a benign,
fully attributable class, not scope creep.

Every HARD bar holds on the enumerated plan: 0 destroys, 0 replaces, ZERO `fabric` addresses,
all 15 changes noise-class (0 non-tag attribute changes), no changes at pre-existing functional
addresses, both PE zone groups against the existing central blob/dfs zones.

**Disposition: APPROVED for apply. The PC-2D add-bar for apply 2 is AMENDED from "~14-18 by
class" to the enumerated 28-address list of run 29673424352; that list is now the exact-shape
bar - a rerun/retry plan must match it address-for-address (LESSON 59: the retry class only
narrows).** Estimation lesson carried: first-consumption AVM modules get their telemetry fan-out
counted from source at bar-setting time.

### ADDENDUM 2026-07-19 - PC-4D QA closure dispositions (verdict: PASS-with-notes)

QA live-verified the full wave intent (workspace/ADLS/RCG/exemption/Fabric-absence exact; zero
policy errors; the ADR-048 unit admitted the create first try). Three findings, dispositioned:

**Finding 1 (MEDIUM) - connectivity plan-vs-apply delta CONFIRMED and closed as the standing
reconciliation rule.** Apply 29672760685: 463 planned changes, 282 applied Modifies, zero errors.
Arithmetic confirmed: 463 - 282 = 181 = **178 azapi zone-link computed-`output` refreshes + 3
modtm telemetry payload re-reads**. The 178 is structurally exact, not a coincidence count: 89
private DNS zones x 2 hub VNet links = 178 zone-link resources, one evaporating output-refresh
each - the same evaporation class dispositioned at B0b and decomposed by the drift attestation.
**STANDING RULE for platform/connectivity plan-scans and QA passes from now on:**
`planned-changes = applied-Modifies (OQ-032 CreatedDate strips, ~274-282) + azapi
computed-output evaporations (178 zone-links + ~3 modtm)`. A delta matching this identity is
CLOSED-BY-RULE and must not be re-flagged; a delta NOT matching it is a real finding.

**Finding 2 (LOW, doc-impacting) - the ADR-048 "posture half" does NOT hold live.** The
dbstorage SA has `publicNetworkAccess = Enabled`, protected instead by an RP-created NSP +
network ACL defaultAction=Deny. Consequences ruled: (i) the storage firewall still delivers the
real network posture (public access is blocked in effect), but the SA is NOT compliant with the
b2982f36 member's letter (requires Disabled/SecuredByPerimeter) - **the exemption is
LOAD-BEARING, not dormant insurance**; (ii) **the early-drop path is DEAD - the waiver runs to
its 2026-08-01 expiry**; (iii) NEW RISK RULED FORWARD: after expiry, any RP-driven dbstorage PUT
(e.g. a workspace update touching the SA) can be DENIED again. Disposition: at B-R (before
2026-08-01), replace the expiring sub-scoped waiver with a STANDING managed-RG-scoped exemption -
now possible because the managed RG EXISTS, killing the create-time race argument; VERIFY at B-R
that the Databricks deny assignment does not block Microsoft.Authorization exemption writes at
that scope (fallback: renew the sub-scoped waiver with a new expiry). ADR-048 carries a dated
post-QA correction; the restoration register item b1 is amended run-to-expiry-then-replace.

**Finding 3 (record):** ONE shared Databricks NSG serves both delegated subnets (the B1-authored
shape - nsg-databricks attached to host AND container); recorded so nobody "fixes" it to two.
| **PC-2D** | Plan-scan BOTH applies against section 5 bars; any breach = STOP |
| **PC-3D** | Apply order: connectivity first, RCG live-confirmed @320, then bank-data-p1; sequential, no parallel dispatch |
| **PC-4D** | QA live-vs-intent before green per design doc section 11, INCLUDING: managed-RG inventory enumerated and recorded; the live `dbstorage*` `publicNetworkAccess` AND `allowBlobPublicAccess` values recorded (closes the unverifiable item; feeds the exemption early-drop decision); NSG `UseOnly` rules counted; re-plan shows zero drift (lifecycle guard proof) |
| **PC-5D** | Fabric stays OFF: `enable_fabric_capacity=false` until OQ-045 resolves AND `Microsoft.Fabric` RP is registered (NotRegistered today, recorded); the flip gets its own mini-pre-clearance (RP + F-SKU PUT-time watch + admin principal variable in place) |
