# Pre-clearance: 2026-07-22 full-estate rebuild - `platform/connectivity` + the five landing-zone spokes

**Date:** 2026-07-21 (for a 2026-07-22 dispatch)
**Author:** cloud-solutions-architect
**Roots cleared here (six):** `platform/connectivity`, `landing-zones/corp-a1`, `landing-zones/corp-a2`,
`landing-zones/online-p1`, `landing-zones/bank-app-p1`, `landing-zones/bank-data-p1`
**Condition series introduced:** `PC-1X..PC-8X` (whole-run), `PC-1C..PC-7C` (connectivity),
`PC-1S..PC-9S` (spokes), `PC-1H..PC-4H` (wave B7 AMBA re-land). None of these collide with the live
`PC-1R..PC-7R` (B0a) or `PC-1G..PC-8G` (identity) series.
**Repo state this gate was computed against:** `origin/banking` @ `d3b9e8c`, working tree clean, local
`banking` at 0/0 vs origin.

---

## Why this is a new document rather than four addenda

The existing gates for these roots (`b0b-connectivity.md`, `landing-zones.md`, `b1-bank-spokes.md`, and
the b2..b7 wave docs) predate the 2026-07-16 build and TWO teardowns since. Their live evidence is stale
in exactly the way the 07-12 B0a doc turned out to be. Those documents stay untouched as history; each
one carries a short dated pointer to this file. The six roots share one dispatch, one Secret surface, one
ordering decision and one dispatch-mode decision, so they are cleared as one unit here rather than as
four partially-overlapping addenda.

**Already cleared elsewhere, NOT revisited here:** `platform/management-groups`, `platform/management`,
`platform/security` (`b0a-redeploy.md`, refresh addendum, PC-1R..PC-7R) and `platform/identity`
(`platform-identity.md`, PC-1G..PC-8G plus the A10 addendum). Those verdicts stand.

---

## VERDICT: GO-CONDITIONAL, with ONE hard code blocker that must clear before Wednesday

| Root | Verdict | Gating condition |
|---|---|---|
| `platform/connectivity` | **GO** | Dry-planned CLEAN today. No open blocker. |
| `landing-zones/corp-a1` | **GO-CONDITIONAL** | Cannot be dry-planned. Shape bar + post-connectivity zone check. |
| `landing-zones/corp-a2` | **GO-CONDITIONAL** | As corp-a1. |
| `landing-zones/online-p1` | **GO-CONDITIONAL** | As corp-a1. |
| `landing-zones/bank-data-p1` | **GO-CONDITIONAL** | Blocked until the surviving subscription-scoped policy exemption is deleted (PC-1S). |
| `landing-zones/bank-app-p1` | **NO-GO as it stands. GO-CONDITIONAL once PC-2S lands.** | A same-root data source makes a greenfield plan structurally impossible. Code fix required tonight. |

Two findings drive the verdict. Both are new, both were found live today, and neither is visible to
`validate`, to code review, or to any plan that has ever been run in this repo:

1. **PC-2S (HARD BLOCKER).** `landing-zones/bank-app-p1` **cannot plan on a greenfield estate.**
   `data.azurerm_kubernetes_cluster.aks_lookup` (acr.tf) reads a cluster that the SAME root creates, with
   fully-static arguments and no `depends_on`, so Terraform resolves it during the plan phase and it 404s
   until the cluster exists. This path has never been exercised: the data source was introduced at wave B4
   against an already-live cluster, and the root has not been applied since. Fix spec in PC-2S.
2. **PC-1S (BLOCKER, no code change).** A subscription-scoped policy exemption
   `exempt-dbx-managed-storage-bank-data-p1` **survived both teardowns and the PC-1R survivor sweep**. The
   azurerm create path for `azurerm_subscription_policy_exemption` returns `tf.ImportAsExistsError` when
   the object exists, so `bank-data-p1` fails at apply. Delete it pre-dispatch.

Everything else in the six roots is either verified clean today or is a defined post-apply gate.

---

## 1. The dispatch-mode ruling (PC-1X): SEQUENTIAL SINGLE-TARGET. `target=all` is not usable.

This is not a preference. `target = all` is currently **structurally non-functional for apply**, on
evidence gathered today:

| Fact | Evidence (2026-07-21) |
|---|---|
| The state SA is `default_action = Deny` with exactly **one** IP rule | `az storage account show`: `defaultAction=Deny`, `ipRuleCount=1`, `bypass=AzureServices`, `allowSharedKeyAccess=false` |
| That one rule is an operator IP, not a GitHub hosted-runner range | `bootstrap/terraform.tfvars` `ip_allow_list` is the deployer IP list; hosted-runner egress is a dynamic SNAT pool (LESSON 30) |
| `deploy.yml` sets `manage_runner_ip: ${{ inputs.target != 'all' }}` | `.github/workflows/deploy.yml`, every job |
| So on `target=all` NO job opens the firewall | `_tf-root.yml` "Open state SA firewall" step is `if: inputs.manage_runner_ip` |

Consequence: a `target=all` apply would 403 at `terraform init` in **every** root. It is not a
performance trade-off, it is a guaranteed failure unless somebody manually flips the SA to Allow for the
whole run (the teardown PD-1 pattern) and manually restores Deny afterwards.

Even with a manual firewall window, `target=all` is rejected for this run on four further grounds:

- **No per-root plan-scan gate.** `target=all` + `action=apply` applies ten roots with no intervening
  human scan. The mandated loop (plan -> scan -> apply, LESSON 26) cannot be run. For a run whose entire
  purpose is process validation, that removes the process.
- **Parallel writes to shared objects.** The five spoke jobs all sit on `needs: [connectivity, security]`
  and run concurrently. corp-a1, corp-a2 and online-p1 all create a VNet link on the SAME private DNS
  zone (`privatelink.database.windows.net`) in `rg-dns-globaris-poc`, and four spokes write flow logs
  against the same `NetworkWatcher_eastus2`. Concurrent writes to one zone are a 409 class we have never
  tested. LESSON 31 says do not dispatch roots in parallel.
- **The identity two-pass does not fit.** `enable_conditional_access_override` is threaded into the
  identity job on `target=all` too, so a Pass-1 run would set it for identity while ALSO applying every
  other root, and Pass 2 would then re-run all ten roots as (mostly) no-ops, which cannot satisfy any
  pure-adds bar because of the standing OQ-032 tag drift.
- **Failure recovery is worse.** `if: !failure() && !cancelled()` cascade-skips downstream roots on any
  upstream failure, so one PUT-time error costs the rest of the graph.

**RULING (PC-1X):** tomorrow runs as **sequential single-target dispatches, one run at a time, plan then
apply per root**. Never two runs in flight at once, because any `_tf-root.yml` run restores
`default_action=Deny` at exit and would cut a concurrent run mid-init (LESSON 31). Recorded as **ADR-060**.

---

## 2. Cross-root output Secrets (PC-2X, PC-3X): the map, the determinism proof, and what actually breaks

This was flagged as the highest-risk item in the run. After live verification it is **LOW risk**, and the
reason is worth stating precisely because it changes what the operator has to do.

### 2a. Producer / consumer map (read from `_tf-root.yml`, `deploy.yml` and each root's outputs)

| Secret | Produced by | Consumed by | Value shape |
|---|---|---|---|
| `PRIMARY_HUB_VNET_ID` | `platform/connectivity` output `primary_hub_vnet_id` | corp-a1, online-p1, bank-app-p1, bank-data-p1, identity | Full ARM id |
| `PRIMARY_HUB_VNET_NAME` | same root | same | `vnet-hub-primary-globaris-poc` |
| `PRIMARY_HUB_RG_NAME` | same root | same | `rg-connectivity-primary-globaris-poc` |
| `PRIMARY_FIREWALL_PRIVATE_IP` | same root | corp-a1, online-p1, bank-app-p1, bank-data-p1 | `10.0.0.4` (ADR-042 contract) |
| `SECONDARY_HUB_VNET_ID` / `_NAME` / `SECONDARY_HUB_RG_NAME` | same root | corp-a2 | `vnet-hub-secondary-globaris-poc` / `rg-connectivity-secondary-globaris-poc` |
| `SECONDARY_FIREWALL_PRIVATE_IP` | same root | corp-a2 | `10.1.0.4` |
| `PLATFORM_LAW_WORKSPACE_ID` | `platform/management` output `platform_law_workspace_id` | connectivity (`firewall_diagnostics.tf`) and all five spokes. **NOT `platform/security`** | Full ARM id |
| `PLATFORM_LAW_CUSTOMER_ID` | `platform/management` output `platform_law_customer_id` | Traffic Analytics in **four** spokes: corp-a1, online-p1, bank-app-p1, bank-data-p1. corp-a2 declares the variable but uses it nowhere. **NOT `platform/security`** | **Workspace GUID, NOT derivable from names** |
| `PLATFORM_ACTION_GROUP_ID` | `platform/management` output `platform_action_group_id` | **Nobody, on any create path.** corp-a1, corp-a2 and online-p1 declare the variable and reference it nowhere | Full ARM id |

> **Correction, 2026-07-21 (code-reviewer finding, verified by reading `platform/security` rather than
> reasoning from the architecture).** An earlier revision of this table listed `platform/security` as a
> consumer of `PLATFORM_LAW_CUSTOMER_ID` and of `PLATFORM_LAW_WORKSPACE_ID`. **Both were wrong.**
> `platform_law_customer_id` and `platform_law_workspace_id` appear NOWHERE in `platform/security/`.
> Every `log_analytics_workspace_id` in `sentinel.tf` (lines 25, 33, 50, 62, 130, 158, 419, 463, 486, 506)
> and `diagnostics.tf` (lines 27, 71) points at `module.security_law.resource_id`, which is security's
> OWN workspace, and `platform/security/outputs.tf` defines its own `security_law_customer_id` for
> Sentinel connector configuration. Sentinel needs A workspace GUID, its own, not the platform one.
> `DEPLOYMENT.md` section 3 Step 5 carries the same error ("Secrets: ... `PLATFORM_LAW_CUSTOMER_ID`") and
> should be corrected with it.
>
> Two further precision fixes found in the same pass: `corp-a2` declares `platform_law_customer_id` but
> never uses it, because Traffic Analytics is deliberately omitted from the DR flow log (no centralus LAW,
> LESSON 43), and `PLATFORM_ACTION_GROUP_ID` is declared by the three Section 9 spokes and referenced by
> none of them.
>
> **Operator impact: NONE, and PC-2X does not move.** Re-setting `PLATFORM_LAW_CUSTOMER_ID` immediately
> after Step 2 (`platform/management`) and before Step 3 is still correct, and is now known to be
> conservative: every real consumer is a spoke at Step 5 or later, so the refresh has even more slack than
> the ordering assumed. This is a factual-accuracy fix to the map, not an ordering change.
>
> **Root cause for calibration (LESSON 48 class):** the consumer set was asserted from the shape of the
> architecture ("Sentinel needs a workspace GUID, the platform LAW has one") and from a stale
> `DEPLOYMENT.md` line, instead of being read out of the code. Every row of this table has now been
> re-derived by grepping `variable "<name>"` against `var.<name>` per root, separating DECLARED from
> USED, which is the only form of this check that is worth anything.

**Refreshing them is 100% MANUAL.** There is no automation anywhere in the repo: `deploy.yml` and
`_tf-root.yml` only READ `secrets.*`, and no workflow, script or hook calls `gh secret set`. The only
written instruction is a prose "Carry forward" bullet in `DEPLOYMENT.md` sections 3.2 and 3.4.

**Declared is not consumed.** Every Secret above is supplied to every root that DECLARES the matching
`TF_VAR_*`, because these variables have no default and Terraform hard-fails on an unset required
variable. That is why `corp-a2` still needs `PLATFORM_LAW_CUSTOMER_ID` supplied and all three Section 9
spokes still need `PLATFORM_ACTION_GROUP_ID` supplied. It is NOT evidence that anything reads them.

### 2b. The determinism proof (this is the finding)

**Every one of these Secrets except `PLATFORM_LAW_CUSTOMER_ID` is a pure function of names that never
change.** The producing resources are all deterministically named from `org_prefix` + `environment`:

- `azurerm_resource_group.connectivity_primary` = `rg-connectivity-primary-${org}-${env}` (main.tf)
- hub VNets = `vnet-hub-primary-${org}-${env}` / `vnet-hub-secondary-${org}-${env}` (main.tf)
- firewall subnets are `cidrsubnet(hub_*_address_space, 10, 0)` = `10.0.0.0/26` / `10.1.0.0/26`, first
  usable address `.4` = the 10.0.0.4 / 10.1.0.4 contract
- `rg-management-${org}-${env}`, `law-platform-${org}-${env}`, `ag-platform-${org}-${env}`
  (`platform/management/main.tf` lines 446, 459, 507)

`gh secret list` confirms it empirically. **The hub and platform Secrets were last written on 2026-07-07
and 2026-07-08.** They then survived the 07-11 teardown, the 07-16 rebuild, the whole banking wave
B1..B7, the 07-19 teardown and the 07-20 teardown, unchanged, and produced green applies for all five
spokes and for identity. Two full rebuild cycles is stronger evidence than any single re-set would be.

`PLATFORM_LAW_CUSTOMER_ID` is the one non-derivable value, and it is **also stable, for a different
reason**: the platform LAW is in Log Analytics soft delete right now (deleted 2026-07-19, 14-day window
ends approximately 2026-08-02), and a create with the same name in the same RG **recovers** it with the
same immutable workspace GUID. Verified today: the soft-deleted record's `customerId` is byte-identical to
the value recorded in `landing-zones.md` section 3 when the Secret was set on 2026-07-08, and the
workspace's `createdDate` is 2026-07-07, which proves it has been recovered rather than recreated at
every rebuild since.

### 2c. What the operator actually has to do

**PC-2X (agent lane, MANDATORY, one command):** immediately after `platform/management` applies green,
**re-set `PLATFORM_LAW_CUSTOMER_ID` unconditionally** from the live workspace. Do not try to verify it:
repo Secrets are write-only (LESSON 32), so "probably unchanged" is not a checkable state, and the cost
of being wrong is silent (the Traffic Analytics block in four spokes pointing at a dead workspace GUID).

```bash
az monitor log-analytics workspace show \
  --resource-group rg-management-globaris-poc \
  --workspace-name law-platform-globaris-poc \
  --query customerId -o tsv | gh secret set PLATFORM_LAW_CUSTOMER_ID
```

**PC-3X (agent lane, VERIFY-ONLY):** immediately after `platform/connectivity` applies green, confirm the
two firewall private IPs are exactly `10.0.0.4` and `10.1.0.4`. This is the one place where a
"deterministic" value could drift (a different subnet carve, a firewall placed at a different offset), and
four spokes hard-depend on it for their default route.

```bash
az network firewall list --subscription <connectivity-sub> \
  --query "[].{name:name, ip:ipConfigurations[0].privateIPAddress}" -o table
```

If either value is not `.4`, **STOP**: re-set `PRIMARY_FIREWALL_PRIVATE_IP` / `SECONDARY_FIREWALL_PRIVATE_IP`
before any spoke dispatch. Everything else in section 2a needs **no action**.

### 2d. Failure mode if somebody forgets

| Secret | If stale | Symptom |
|---|---|---|
| Hub id/name/RG (6 Secrets) | Impossible: values are name-derived and the names are unchanged | none |
| Firewall private IPs | Only if the carve changed | Spoke UDR points at a non-existent next hop. Applies succeed, egress blackholes. **Silent.** |
| `PLATFORM_LAW_WORKSPACE_ID`, `PLATFORM_ACTION_GROUP_ID` | Impossible: name-derived | none |
| `PLATFORM_LAW_CUSTOMER_ID` | Only if the LAW is recreated rather than recovered | Traffic Analytics in corp-a1, online-p1, bank-app-p1 and bank-data-p1 points at a dead GUID. Expect a 400 at flow-log create at best, a silently dead analytics pipeline at worst. corp-a2 is unaffected: it supplies the value but never reads it |

Complete `TF_VAR_*` coverage check for the six roots was run today: every no-default variable in all six
roots maps to a Secret that exists or to a value in `envs/poc.tfvars`. **Nothing is missing.** This
includes `SQL_AAD_ADMIN_OBJECT_ID` / `SQL_AAD_ADMIN_LOGIN` (present since 2026-07-10, and consumed only
when `enable_sql` is true, which it is not), `AKS_ADMIN_GROUP_OBJECT_ID` and `FABRIC_ADMIN_UPN`.

---

## 3. Ordering and parallelism (PC-4X): the full 10-root order plus the B7 second pass

Dependencies (from `deploy.yml` `needs:` plus the cross-root Secret map plus DEPLOYMENT.md section 2):

```
management-groups
  -> management ---> connectivity ---+
  |            \--> security -------+--> corp-a1, corp-a2, online-p1, bank-data-p1, bank-app-p1
  \-------------------------------------> identity (also needs connectivity: it peers to the primary hub)
```

`deploy.yml` declares `identity: needs: [management-groups]` only. That is a **graph gap**: the identity
root creates a VNet peering to the primary hub and therefore genuinely needs `platform/connectivity`
applied. Serial ordering makes the gap moot tomorrow; recorded as a doc/CI item, not a blocker.

**RECOMMENDED SERIAL ORDER (PC-4X).** Long poles are pushed to the end so nothing waits behind them:

| # | Root | Dispatch notes | Expected duration |
|---|---|---|---|
| 1 | `platform/management-groups` | plan bar 537 adds (PC-1R..7R) | ~5 min |
| 2 | `platform/management` | plan bar 36 adds. **Then PC-2X (re-set LAW customer id).** | ~10 min |
| 3 | `platform/security` | plan bar 48 adds. Short, high-information, 3-failure history | ~15 min |
| 4 | `platform/connectivity` | plan bar **696 adds**. **Then PC-3X (firewall IPs) and PC-4C (zone check).** | ~45-70 min |
| 5 | `landing-zones/corp-a1` | first spoke, validates the whole spoke contract | ~10-15 min |
| 6 | `landing-zones/corp-a2` | DR spoke, Traffic Analytics OFF on the DR flow log | ~10-15 min |
| 7 | `landing-zones/online-p1` | App Gateway WAF_v2 create dominates | ~20-30 min |
| 8 | `landing-zones/bank-data-p1` | Databricks + ADLS + Foundry + Search + Fabric F2 | ~30-45 min |
| 9 | `landing-zones/bank-app-p1` | **longest spoke.** APIM Developer stv2 internal-mode create is 30-90 min and has been observed near 3h | ~60-180 min |
| 10 | `platform/identity` Pass 1 | `enable_conditional_access_override = false` (ADR-055) | ~60-180 min |
| 11 | `platform/identity` Pass 2 | `enable_conditional_access_override = true`, 10 plan addresses | ~5 min |
| 12 | (optional, same day) `landing-zones/bank-app-p1` Pass 2 | AcrPull binding flip, see PC-2S | ~5 min |
| 13 | **B7 re-land**: `platform/management` with `enable_om_phase1 = true` | see PC-1H..PC-4H | ~5 min |
| 14 | **B7 re-land**: `platform/management-groups` with `enable_om_phase1 = true` | see PC-1H..PC-4H | ~10-20 min |

**Total wall clock: budget 6 to 9 hours of serialized runs.** That is a direct consequence of PC-1X and
the operator should plan the day around it, not discover it at hour four.

Steps 5..9 may be reordered freely among themselves (they are mutually independent), but **never run two
of them concurrently**. Step 9 must follow step 4 (the APIM create needs firewall passage for its
force-tunneled dependency traffic mid-provision, ADR-047) and the AKS nodes cannot bootstrap through a
blackholed `0.0.0.0/0` route (ADR-044).

---

## 4. `platform/connectivity` refresh (PC-1C..PC-7C)

### PC-1C. Dry-plan: CLEAN, and still valid at HEAD. **PASS.**

Run `29851422904` (2026-07-21T17:04Z, `workflow_dispatch`, headSha `341134a`): job
`connectivity / plan platform/connectivity` conclusion **success**, `Plan: 696 to add, 0 to change,
0 to destroy`, zero `Error:` diagnostics.

Between `341134a` and current HEAD `d3b9e8c` the ONLY `.tf` change anywhere in the repo is
`platform/identity/domain-services.tf` (ADR-059). **No connectivity or spoke code changed**, so the
696-add plan is authoritative at `d3b9e8c`.

**Bar for tomorrow: EXACTLY `696 to add, 0 to change, 0 to destroy`, exit status 0, zero `Error:` lines.**
Any deviation is a STOP and needs a fresh disposition, not a judgement call at the console.

### PC-2C. Teardown survivors in the connectivity subscription: NONE. **PASS.**

The class that bit B0a (12 subscription-scoped objects that outlived the RG and MG deletes) was
re-enumerated in the connectivity subscription today:

| Probe | Result |
|---|---|
| Resource groups | only service-created `NetworkWatcherRG` |
| `az resource list` | only the two regional Network Watcher objects |
| Subscription budgets (`Microsoft.Consumption/budgets`) | none |
| Cost exports (`Microsoft.CostManagement/exports`, **api-version 2025-03-01**) | none |
| Cost scheduled actions | none |
| Subscription diagnostic settings | none |
| Subscription-scoped policy assignments | only `SecurityCenterBuiltIn` (Microsoft system assignment) |
| Subscription-scoped policy exemptions / custom definitions / set definitions | none |
| Resource locks | none |
| Soft-deleted Key Vaults | none |

### PC-3C. Live policy matrix: **DERIVED, NOT LIVE-READ. Say so out loud.**

There is **no management group in the tenant except Tenant Root Group** (`az account management-group
list`, today). Every ancestor scope of the connectivity subscription will be created roughly one hour
before this root applies, by `platform/management-groups`, from pinned content
(`avm-ptn-alz 0.19.1` + ALZ library `platform/alz @ 2026.04.2`). **A live policy read is therefore
impossible today and any claim of one would be false.** The matrix below is derived from the code that
will create it plus the 2026-07-16 live-proven behaviour of the identical content.

| Assignment | Scope | Disposition |
|---|---|---|
| `Enable-DDoS-VNET` (Modify, placeholder plan id, LESSON 34) | Connectivity MG **and** landingzones MG | **Neutralised in code**: `policy_assignments_to_modify` sets `enforcement_mode = "DoNotEnforce"` at BOTH scopes (`platform/management-groups/main.tf` lines 147-162). Verified present at HEAD. |
| `Deny-Subnet-Without-Nsg` | landingzones | Not on the connectivity chain. AzureFirewallSubnet is excluded by the policy's own `excludedSubnets` default in any case |
| Tag governance Modify | globaris root | Add-if-missing / inherit only. Produces the standing OQ-032 `CreatedDate` drift on later plans. Benign |
| Everything else | globaris / platform / connectivity | Audit or DoNotEnforce. Live-proven on 2026-07-16 by a 630-resource green apply of this exact root against this exact policy content |

**PC-3C verification gate (not skippable):** after `platform/management-groups` applies and BEFORE
dispatching connectivity, confirm the DoNotEnforce lever actually landed at both scopes:

```bash
for MG in connectivity landingzones; do
  az policy assignment show --name Enable-DDoS-VNET \
    --scope "/providers/Microsoft.Management/managementGroups/$MG" \
    --query "{scope:'$MG', mode:enforcementMode}" -o tsv
done
```

Both must read `DoNotEnforce`. If either reads `Default`, **STOP** - the hub VNet PUTs will 403
`LinkedAuthorizationFailed` exactly as they did in the ADR-026 incident.

### PC-4C. The 89-zone private DNS set: statically verified, with a post-apply gate. **PASS.**

All eleven zone names that the five spokes look up by data source are present in the pinned
`Azure/avm-ptn-network-private-link-private-dns-zones 0.23.1` default zone list (read from the downloaded
module's `variables.tf` today), plus the regional template `privatelink.{regionName}.azmk8s.io` which
renders as `privatelink.eastus2.azmk8s.io`:

`database.windows.net`, `azurecr.io`, `servicebus.windows.net`, `blob.core.windows.net`,
`dfs.core.windows.net`, `azuredatabricks.net`, `openai.azure.com`, `cognitiveservices.azure.com`,
`search.windows.net`, `services.ai.azure.com`, `{region}.azmk8s.io` (all `privatelink.` prefixed).

**PC-4C gate:** after connectivity applies and before ANY spoke dispatch, confirm all eleven exist:

```bash
az network private-dns zone list -g rg-dns-globaris-poc --subscription <connectivity-sub> \
  --query "length(@)" -o tsv     # expect 89
az network private-dns zone list -g rg-dns-globaris-poc --subscription <connectivity-sub> \
  --query "[?contains(name,'azmk8s') || contains(name,'azurecr') || contains(name,'servicebus') || contains(name,'database') || contains(name,'dfs') || contains(name,'azuredatabricks') || contains(name,'openai') || contains(name,'cognitiveservices') || contains(name,'search.windows') || contains(name,'services.ai') || contains(name,'blob.core')].name" -o tsv
```

A missing zone is a spoke plan failure, not an apply failure, and it is cheaper to see it here.

### PC-5C. Both Azure Firewall Premium instances: IN SCOPE, current, nothing newly constrained. **PASS.**

`enable_firewall = true` is live in `envs/poc.tfvars` (the ADR-044 reviewed-commit flag supply) and both
hubs take `firewall.sku_tier = "Premium"` + `firewall_policy.sku = "Premium"`. Lifecycle audit run today
against current Microsoft sources:

| Type | Status 2026-07-21 | Note |
|---|---|---|
| Azure Firewall Premium + Firewall Policy Premium | **CURRENT.** No retirement, no new-enablement block | Only a Firewall-Premium-related *Azure Policy definition* is marked deprecated, which is unrelated to the SKU |
| Standard SKU public IPs (firewall PIPs) | CURRENT | Basic SKU public IPs are retired; the pattern module emits Standard |
| Application Gateway WAF_v2 (online-p1) | CURRENT | App Gateway **V1 retired 2026-04-28**; the estate is v2 only |
| VNet flow logs + Traffic Analytics | CURRENT | NSG flow logs blocked for new creation since 2025-06-30, retire 2027-09-30. The estate migrated at wave B0c |
| VPN Gateway `VpnGw1AZ` | CURRENT but **flag OFF** | Non-AZ VPN Gateway SKUs retire Sept 2026; we would be on an AZ SKU. `enable_vpn_gateway` defaults false and is not set in tfvars |
| DNS Private Resolver, Bastion, DDoS Standard | **flag OFF** | `enable_dns_resolver`, `enable_bastion`, `enable_ddos_standard` all default false and are not set in tfvars |

**Note for the operator:** `DEPLOYMENT.md` section 3 Step 3 still describes connectivity as creating the
VPN Gateway and DNS Private Resolver. That text predates ADR-042 and is stale. The 696-add plan contains
neither. Documentation item, not a blocker.

### PC-6C. Provider / module pins and quota. **PASS.**

`.terraform.lock.hcl` present, azurerm pinned **4.71.0** exactly. Modules
`avm-ptn-alz-connectivity-hub-and-spoke-vnet 0.17.1` and
`avm-ptn-network-private-link-private-dns-zones 0.23.1`, both the exact versions that applied green on
2026-07-16. Registry module versions are immutable, so no re-verification beyond the lock is required.
Connectivity creates no compute, so no vCPU axis applies; public IP and firewall counts are far under any
default limit.

### PC-7C. Duration vs OIDC token lifetime. **PASS with a watch-item.**

The 07-16 lean apply (no appliances) took ~35 min for 630 resources. Adding two Premium firewalls,
two policies, two PIPs and the hub route tables should land ~45-70 min. ADR-055 Part 2 exports
`ARM_OIDC_REQUEST_URL` / `ARM_OIDC_REQUEST_TOKEN` for **every** root now, so azurerm re-mints its
assertion on each token acquisition. The root has no `azuread` resources, so there is no trailing-Graph
exposure at all. Watch-item only.

---

## 5. The five spokes (PC-1S..PC-9S)

### 5a. THE HARD CONSTRAINT, stated per spoke: what can and cannot be verified before dispatch

I re-verified the premise rather than inheriting it, and **one third of it is wrong in our favour**:

| Data source | Present in | Resolves TODAY? | Consequence |
|---|---|---|---|
| `azurerm_network_watcher` (`NetworkWatcher_eastus2` / `_centralus` in `NetworkWatcherRG`, landingzones sub, default provider) | all five spokes | **YES.** Both objects live, verified by `az network watcher list` in the landingzones subscription today | **Not a blocker.** The LESSON 43 pre-create requirement is already satisfied |
| `azurerm_private_dns_zone` (in `rg-dns-globaris-poc`, connectivity sub, `azurerm.connectivity` alias) | all five spokes (1 zone in corp-a1/corp-a2/online-p1, 3 in bank-app-p1, 7 in bank-data-p1) | **NO.** `rg-dns-globaris-poc` returns `ResourceGroupNotFound` today | Blocks any dry plan. Becomes verifiable the moment connectivity is green (PC-4C) |
| `azurerm_kubernetes_cluster.aks_lookup` | bank-app-p1 only | **NO,** and it will still be NO at plan time tomorrow, because the cluster is created by the same root | **Structural. See PC-2S** |

**Therefore, per spoke:**

| Spoke | Verifiable PRE-dispatch | Verifiable ONLY after connectivity (+ security) are live | Not verifiable at all before apply |
|---|---|---|---|
| corp-a1 | lock/pins, TF_VAR coverage, RPs, quota, survivors, network watcher, lifecycle audit, policy-collision design | private DNS zone lookup (PC-4C); full plan | flow-log SA vs `StorageDenyPaasPublicIP` at PUT time (mitigated by the RG Waiver + 300s sleep) |
| corp-a2 | as corp-a1 | as corp-a1, secondary region | as corp-a1 |
| online-p1 | as corp-a1 | as corp-a1 | App Gateway WAF_v2 create against live policy |
| bank-data-p1 | as corp-a1, **plus** the surviving exemption must be deleted first (PC-1S) | as corp-a1 (7 zones) | Databricks managed-RG `dbstorage` PUT vs the two storage Deny members (that is exactly what the exemption exists for) |
| bank-app-p1 | as corp-a1 | as corp-a1 (3 zones) | **Nothing, until PC-2S lands. The root cannot plan at all today** |

A gate nobody can check is not a gate. The spoke gates that cannot be checked pre-dispatch are named
above as such, and each is converted into a **defined verification moment** (PC-4C for the zones, the
plan-scan bar at each spoke's own plan) rather than being asserted as pre-cleared.

### PC-1S (BLOCKER, USER-ACTION). Delete the surviving subscription-scoped policy exemption.

Live in the landingzones subscription right now:

```
name:                exempt-dbx-managed-storage-bank-data-p1
scope:               subscription (landingzones)
policyAssignmentId:  /providers/Microsoft.Management/managementGroups/corp/.../policyAssignments/Deny-Public-Endpoints
category:            Waiver, expires 2026-08-01
created:             2026-07-19 by the CI application
```

It is created by `azurerm_subscription_policy_exemption.dbx_managed_storage`
(`landing-zones/bank-data-p1/policy_exemptions.tf` line 85). The azurerm v4.71.0 create path performs an
existence check and returns `tf.ImportAsExistsError` (source-verified today against the v4.71.0 tag), so
a greenfield apply **fails at that resource**. It also currently references an assignment id that does
not exist, because the corp MG is gone.

**Disposition: DELETE, do not import.** Same reasoning as PC-1R: deleting restores the exact greenfield
the pure-adds bar assumes, whereas importing costs an import block plus a mandatory removal commit
(LESSON 52) for an object that holds no state worth preserving.

```bash
az policy exemption delete \
  --name exempt-dbx-managed-storage-bank-data-p1 \
  --scope "/subscriptions/<landingzones-sub>"
# verify
az policy exemption list --subscription <landingzones-sub> --query "[].name" -o tsv   # expect empty
```

### PC-2S (HARD BLOCKER, CLOUD-ENGINEER LANE + REVIEWER). Make `bank-app-p1` plannable on greenfield.

**Defect.** `landing-zones/bank-app-p1/acr.tf` line 33:

```hcl
data "azurerm_kubernetes_cluster" "aks_lookup" {
  for_each            = var.enable_kubernetes_platform ? { main = "main" } : {}
  name                = "aks-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = "rg-bank-app-p1-workload-${var.org_prefix}-${var.environment}"
}
```

consumed at line 80 as the ACR `role_assignments.kubelet_acr_pull.principal_id`. `for_each` is a static
bool and every argument is a literal interpolation of root variables, so Terraform reads it during the
**plan** phase. The cluster is created by `module.aks` in the same root, so on a greenfield estate the
read 404s and the plan exits non-zero. Verified today: `rg-bank-app-p1-workload-globaris-poc` returns
`ResourceGroupNotFound`.

This is not a regression, it is an untested path. The data source was introduced at wave B4 as the
durable fix for an apply-time-deferred principal id, against a cluster that already existed. The root has
not been applied since, its state blob does not exist, and no greenfield plan of it has ever been run.

**Fix spec (implement exactly this, no wider refactor):**

1. Add a root variable in `landing-zones/bank-app-p1/variables.tf`:
   - name `enable_acr_kubelet_binding`, type `bool`, `default = false`
   - description must record: the AcrPull binding for the AKS kubelet identity cannot be planned until the
     cluster exists, because the lookup is a same-root data source; flip to true on a second apply once
     the cluster is live (LESSON 42 flag pattern, ADR-055 two-pass precedent).
2. In `acr.tf`, change the data source gate to
   `for_each = var.enable_kubernetes_platform && var.enable_acr_kubelet_binding ? { main = "main" } : {}`.
3. In `acr.tf`, make the module input conditional:
   `role_assignments = var.enable_acr_kubelet_binding ? { kubelet_acr_pull = { ... } } : {}`
   keeping the map KEY static (LESSON 5a) and leaving the existing block body unchanged.
4. Do **not** add `depends_on` to the data source. That would defer the read to apply and can reintroduce
   the exact ForceNew role-assignment churn the wave B4 fix removed.
5. Do **not** add an entry to `envs/poc.tfvars` in this change. The flag must be false for tomorrow's
   first pass.

**Then, tomorrow, after bank-app-p1 Pass 1 is green:** a one-line PR adding
`enable_acr_kubelet_binding = true` to `envs/poc.tfvars` (the ADR-044 reviewed-commit flag-supply
precedent), reviewer approve, merge to `banking`, and dispatch `bank-app-p1` Pass 2. **Pass 2 plan bar:
exactly 1 add (the ACR role assignment), 0 change, 0 destroy.**

**If PC-2S does not land tonight**, the fallback is to run tomorrow with
`enable_kubernetes_platform = false` for bank-app-p1, which drops AKS **and** ACR **and** their subnets'
purpose from the run. That is a materially smaller estate and I do not recommend it for a
process-validation rebuild.

### PC-3S. Teardown survivors and soft-delete collisions in the landingzones subscription.

Enumerated today. Exactly two findings, both listed above and below; everything else is clean.

| Probe | Result |
|---|---|
| Resource groups | `NetworkWatcherRG` (service-created) and an unrelated pre-existing cloud-shell RG |
| `az resource list` | four Network Watcher objects only |
| Budgets / cost exports (api-version **2025-03-01**) / scheduled actions / subscription diagnostic settings / locks | all empty |
| Subscription-scoped policy assignments | `SecurityCenterBuiltIn` only |
| Subscription-scoped policy exemptions | **`exempt-dbx-managed-storage-bank-data-p1` -> PC-1S** |
| Soft-deleted Key Vaults | none |
| Soft-deleted Cognitive Services accounts | none |
| **Soft-deleted API Management** | **`apim-bank-app-p1-globaris-poc`, deleted 2026-07-19T23:06Z, scheduled purge 2026-07-21T22:53Z -> PC-4S** |
| Live Cognitive Services accounts | none |
| Subscription-scope role assignments | CI SP holds Contributor + User Access Administrator + Cost Management Contributor + Management Group Contributor. No orphan that any spoke re-creates (the spokes create only resource-scoped and RG-scoped assignments with provider-generated names) |

### PC-4S (USER-ACTION, conditional). APIM soft-delete window.

`apim-bank-app-p1-globaris-poc` is in APIM soft delete with an auto-purge scheduled for **2026-07-21
22:53 UTC**, roughly three hours from the time this gate was written, so it will most likely be gone
before any Wednesday dispatch. It survived because the last teardown ran the `az` sweep path rather than
`terraform destroy`, so the provider's `purge_soft_delete_on_destroy = true` never fired.

**Pre-dispatch check (required, cheap):**

```bash
az rest --method get --url \
 "https://management.azure.com/subscriptions/<landingzones-sub>/providers/Microsoft.ApiManagement/deletedservices?api-version=2024-05-01" \
 --query "value[].name" -o tsv     # expect empty
```

If it is still listed, **purge it** rather than relying on recovery:

```bash
az apim deletedservice purge --service-name apim-bank-app-p1-globaris-poc --location eastus2
```

Rationale: `landing-zones/bank-app-p1/providers.tf` sets `recover_soft_deleted = true`, so a still-deleted
service would be RESTORED instead of created. Restore is a code path this estate has never executed, and
it would bring back the previous instance's stored VNet configuration. Purging keeps the run on the
proven create path.

### PC-5S. Quota reality check (re-verifying the OQ-043 position LIVE, not inheriting it). **PASS.**

Measured today in the landingzones subscription:

| Counter | Region | Used | Limit | Need | Verdict |
|---|---|---|---|---|---|
| Total Regional vCPUs | eastus2 | 0 | 24 | 6 | PASS, 18 spare |
| Standard DSv4 Family vCPUs | eastus2 | 0 | 10 | 6 (3 x `Standard_D2s_v4`) | PASS, 4 spare |
| Total Regional vCPUs | centralus | 0 | 10 | 0 (corp-a2 deploys no compute) | PASS |
| AIServices S0 account count | eastus2 | 1 (stale counter, no account exists) | 100 | 1 | PASS |
| gpt-5.4-nano DataZoneStandard TPM | eastus2 | 10 (stale counter) | 2000 | 10 | PASS |

Note the two Cognitive Services counters still report the torn-down estate's consumption; `az
cognitiveservices account list` and the `deletedAccounts` probe both return empty, so these are lagging
usage records, not live objects. Headroom is large enough that the lag cannot bite.

Everything else in the spokes is zero-vCPU by design: APIM Developer, Databricks with **no clusters**
(ADR-048 hard boundary), Fabric F2 (capacity units, separate axis), AI Search basic, Static Web App
(serverless), App Gateway WAF_v2 (capacity 1, its own quota, verified healthy at 1000 on 2026-07-10).

### PC-6S. Gated-off tiers and every banking wave flag: what must build and what must stay absent.

Read from `envs/poc.tfvars` at HEAD plus each root's `variables.tf` defaults:

| Flag | Value tomorrow | Where set | Effect |
|---|---|---|---|
| `enable_sql` (corp-a1, corp-a2) | **false** | root default, no tfvars entry | Azure SQL server/DB/PE stay ABSENT. ADR-031, `ProvisioningDisabled` offer cap |
| `enable_app_service` (corp-a1, corp-a2) | **false** | root default, no tfvars entry | App Service plan + site stay ABSENT. ADR-032, dedicated compute quota 0 (ARM 70007) |
| `enable_corp_policy_exemptions` (all 5) | **true** | root default | Flow-log SA Waiver + 300s sleep per spoke. corp-a1/a2 also carry an App Service waiver entry that is inert while the tier is off |
| `enable_kubernetes_platform` (bank-app-p1) | **true** | tfvars | Private AKS (3 x D2s_v4, CNI Overlay, UDR egress) + Premium ACR + PE. **Gated by PC-2S** |
| `enable_acr_kubelet_binding` (bank-app-p1) | **false on Pass 1** | new, PC-2S | AcrPull binding deferred to Pass 2 |
| `enable_messaging_platform` (bank-app-p1) | **true** | tfvars | Service Bus Premium 1 MU + PE, Event Hubs Standard 1 TU + PE, both AAD-only |
| `enable_api_platform` (bank-app-p1) | **true** | tfvars | APIM Developer_1 stv2 internal mode, dedicated `snet-apim` route table, scoped gateway-FQDN private DNS zone |
| `enable_data_platform` (bank-data-p1) | **true** | tfvars | Databricks Premium VNet-injected + NPIP, ADLS Gen2 PE-only, the sub-scoped dbstorage Waiver (see PC-1S) |
| `enable_fabric_capacity` (bank-data-p1) | **true** | tfvars | Fabric F2 deploys ACTIVE. `Microsoft.Fabric` RP verified Registered today. Suspend post-QA per OQ-046 f3 |
| `enable_ai_platform` (bank-data-p1) | **true** | tfvars | Foundry account (AIServices S0) + gpt-5.4-nano + AI Search basic, all PE-only |
| `enable_om_phase1` (management, management-groups) | **false for the main run** | tfvars, PC-4R | Re-landed as a second pass, PC-1H..PC-4H |
| `enable_synthetic_workload` | **false** | tfvars | `synthetic` root is NOT dispatched at all (ADR-036/037) |

Model lifecycle re-verified live today against the eastus2 catalog: **`gpt-5.4-nano` version
`2026-03-17`, kind `AIServices`, `lifecycleStatus = GenerallyAvailable`, `DataZoneStandard` SKU offered,
inference deprecation 2027-03-18.** The ADR-051 pin is current, with eight months of margin.

### PC-7S. Provider and module pins across the five spokes. **PASS.**

Every spoke has a committed `.terraform.lock.hcl` pinning azurerm **4.71.0**. Module pins, all being the
exact versions that applied green between 2026-07-16 and 2026-07-19:

`avm-res-network-virtualnetwork 0.17.1` (all five), `avm-res-recoveryservices-vault 1.1.3` (corp-a1,
corp-a2), `avm-res-web-serverfarm 2.0.4` + `avm-res-web-site 0.22.0` (corp spokes, gated off),
`avm-res-containerservice-managedcluster 0.6.7`, `avm-res-containerregistry-registry 0.5.1`,
`avm-res-apimanagement-service 0.9.0`, `avm-res-eventhub-namespace 0.1.0`,
`avm-res-servicebus-namespace 0.4.0` (bank-app-p1), `avm-res-databricks-workspace 0.5.0`,
`avm-res-storage-storageaccount 0.7.3`, `avm-res-cognitiveservices-account 0.11.1`,
`avm-res-search-searchservice 0.3.0` (bank-data-p1).

**Standing caveat worth naming:** `landing-zones/corp-a1`, `corp-a2` and `online-p1` have not been
applied since **2026-07-10**. That is 12 days and it is the longest gap of any root in this run. Their
code has changed only in ways already applied (the fix arc of 07-10, plus the 07-12 dead-variable
cleanup) and their provider pin is unchanged, but tomorrow is the first exercise of these three roots at
the current pins. Treat their plan-scan with the same seriousness as a first-ever plan.

### PC-8S. Policy collisions the spokes must survive (DERIVED, same caveat as PC-3C).

| Collision | Handled by | Verify |
|---|---|---|
| `Enable-DDoS-VNET` Modify at the landingzones MG rewrites EVERY spoke VNet PUT | `policy_assignments_to_modify` DoNotEnforce at landingzones (in code) | PC-3C |
| `Deny-Public-Endpoints` / `StorageDenyPaasPublicIP` vs the flow-log storage account (all five spokes) | Per-spoke RG-scoped Waiver exemption + `time_sleep` 300s + `depends_on` from the SA (LESSON 35 unit) | Plan must show the exemption, the sleep, and the SA in that dependency order |
| `Deny-Public-Endpoints` / `StorageDenyPaasPublicIP` + `Deny-Storage-Public-Access` vs the Databricks managed-RG `dbstorage` SA | Subscription-scoped expiring Waiver + 300s sleep (bank-data-p1) | Must be a fresh CREATE after PC-1S deletes the survivor |
| `Deny-Subnet-Without-Nsg` vs corp `snet-integration` | NSG attached in code (corp-a1 main.tf, corp-a2 mirror). No exemption needed | Static, already verified |
| `Deny-Public-IP-On-NIC` vs the online-p1 App Gateway PIP | Not applicable: the gateway PIP is a standalone `publicIPAddresses`, not a NIC ipconfig. There is no standalone-PIP Deny on the landingzones chain | Live-proven 2026-07-10 |
| `Deploy-Private-DNS-Zones` DINE at corp | Post-apply drift only, never a create blocker | QA item |

### PC-9S. Plan-scan bars for the five spokes (SHAPE-based, because counts cannot be pre-verified).

**The bar is the shape, not the number.** Every spoke plan must satisfy ALL of:

1. **Exit status 0** for the plan job, and **zero `Error:` diagnostics anywhere in the log.**
   A `Plan: N to add` tally is NOT evidence of success. On 2026-07-21, run `29851615122` rendered a full
   tally 29 milliseconds AFTER its fatal error and still exited 1 (corrected PC-1G, LESSON 52).
2. `0 to change, 0 to destroy`, **zero `forces replacement`**, **zero `must be replaced`**, zero import
   blocks reported.
3. Every address is `+ create`.
4. The address classes below are all present.

| Spoke | Classes that MUST appear | Derived magnitude (NOT a bar) |
|---|---|---|
| corp-a1 | 4 RGs, spoke VNet module (3 subnets, `snet-integration` carrying both the NSG and the route table), 1 NSG, route table + default route to `10.0.0.4`, 2 peerings (spoke-to-hub and hub-to-spoke via the connectivity alias), RSV module (ZoneRedundant), flow-log SA + `random_id`, 1 VNet flow log with Traffic Analytics, 1 private DNS zone VNet link, 2 policy exemptions + 1 `time_sleep`, modtm telemetry pairs | roughly 25-45 adds |
| corp-a2 | same shape, secondary region, RSV GeoRedundant, route to `10.1.0.4`, **Traffic Analytics DISABLED** on the DR flow log (no centralus LAW, LESSON 43) | roughly 25-45 adds |
| online-p1 | 4 RGs, spoke VNet (3 subnets all with NSGs), 2 NSGs, route table on workload/PE subnets ONLY (never on the App Gateway subnet), 2 peerings, Standard zonal public IP, WAF policy (OWASP 3.2, Prevention), App Gateway WAF_v2 capacity 1 + diagnostic setting, Static Web App Standard, flow-log SA + 2 flow logs, exemption unit | roughly 30-45 adds |
| bank-data-p1 | 4 RGs, spoke VNet with the two Databricks-delegated subnets, NSG, UDR, 2 peerings, 7 private DNS zone links, flow-log unit, **subscription-scoped dbstorage exemption + 300s sleep**, Databricks workspace + access connector, ADLS Gen2 + raw filesystem + blob/dfs PEs, Fabric F2 capacity, Foundry account + gpt-5.4-nano deployment + 3-zone account PE, AI Search basic + PE, diagnostics to the platform LAW | roughly 50-60 adds |
| bank-app-p1 (Pass 1) | 4 RGs, spoke VNet with `snet-aks-nodes` / `snet-apim` / `snet-private-endpoints`, NSGs, UDR, dedicated `snet-apim` route table, 2 peerings, 3 private DNS zone links, flow-log unit, exemption unit, control-plane UAI + 2 role assignments + 300s RBAC sleep, AKS cluster, Premium ACR + PE (**and NO `kubelet_acr_pull` role assignment while PC-2S keeps the flag false**), Service Bus Premium + PE, Event Hubs Standard + PE, APIM Developer_1 + scoped gateway-FQDN zone | roughly 60-70 adds |

The magnitudes are **derived by adding the landed per-wave increments** (bank-app-p1 B1 landed 23 adds,
B2 roughly 15-20, B3 roughly 11-15, B4 12; bank-data-p1 B1 landed 26 adds, B5 roughly 14-18, B6 roughly
10-14) and are offered only to make a wildly wrong plan obvious at a glance. **They are not pass/fail
criteria.** The operator records the ACTUAL counts as the new reference bars for the next rebuild.

---

## 6. Wave B7 AMBA re-land (PC-1H..PC-4H)

`enable_om_phase1 = false` is live in `envs/poc.tfvars` at HEAD (PC-4R option A) because the two roots are
circular on an empty tenant. Re-landing it is a **second pass over two already-green platform roots**, run
at the END of the day.

### PC-1H (CLOUD-ENGINEER LANE + REVIEWER APPROVAL). The tfvars flip.

One-line change, `envs/poc.tfvars` line 315: `enable_om_phase1 = false` -> `enable_om_phase1 = true`.
This is a reviewed-commit flag supply (ADR-044 precedent), so it needs a feature branch, a reviewer
approval and a merge to `banking` before dispatch. It is **not** a workflow-dispatch override and there is
no input for it. The surrounding comment block must be updated to record that the false value was the
greenfield-ordering workaround and that true is the steady state.

**Do not merge this before the main run.** If it lands early, `platform/management-groups` at step 1 would
select the `globaris-amba` architecture and reintroduce the exact circularity PC-4R removed.

After merging, confirm the dispatched run's `headSha` is the flipped commit before letting it write
(LESSON 33).

### PC-2H (HARD ORDERING GATE, restating PC-3F). management FIRST, then management-groups.

1. Dispatch `platform/management`, `action=plan`, scan, then `action=apply`.
2. **Verify the managed identity is LIVE before dispatching management-groups:**

```bash
az identity show -g rg-amba-monitoring-001 -n id-amba-prod-001 --subscription <management-sub> \
  --query "{id:id, principalId:principalId}" -o json
```

A missing identity means **do not dispatch** `platform/management-groups`. The Deploy-AMBA-* DINE
assignments attach `id-amba-prod-001` by constructed resource id as their bring-your-own remediation
identity; if it does not exist the assignments carry a dangling identity and remediation fails with no
identity to run as (LESSON 35/49: a 403 there is a missing role, not a wait).

3. Dispatch `platform/management-groups`, `action=plan`, scan, then `action=apply`.

### PC-3H. Plan bars for the two B7 passes.

**`platform/management` with the flag true**, planned against the green estate from earlier in the day:

- **Expected: 3 adds** (`rg-amba-monitoring-001` resource group, `id-amba-prod-001` user-assigned managed
  identity, its Monitoring Reader role assignment at the Globaris root MG). This is the LANDED count from
  run `29703260837`, not an estimate; the older B7 doc's "4-6 adds" was the pre-apply guess.
- **ZERO destroys, ZERO replaces.** The platform LAW, the platform action group, the Automation Account,
  the portal dashboard, the budgets and the workbook are REFERENCED, never recreated. Any change or
  replace on any of them is a STOP.
- **Accepted noise:** OQ-032 `CreatedDate` tag-strip `~ change` entries on existing management-sub
  resources. By the time this pass runs, the tag-governance Modify policy will have had hours to inject
  them. These are the ONLY permitted changes.

**`platform/management-groups` with the flag true:**

- **Expected: approximately 223 adds** (the landed count on 2026-07-19 across the initial 178 plus the
  45-add reconciliation). Accept a band of roughly 200-260; the AMBA library ref
  `platform/amba @ 2026.06.2` is pinned, so a large drift would itself be the finding.
- **Permitted non-adds: module-internal helpers ONLY** (`time_sleep`, `modtm_telemetry`, `random_uuid`).
  The 07-19 plan showed exactly `1 change / 2 destroy` of that class and it was dispositioned as such.
- **ZERO-TOLERANCE STOP items, any single one:** a change or replace on an existing policy ASSIGNMENT
  (tag governance, `Deny-Public-Endpoints`, `deny-pub-net-globaris`, the staged guardrails), on an
  existing policy DEFINITION or INITIATIVE, on an existing MANAGEMENT GROUP or its archetype (the 11-MG
  topology is shared between the `globaris` and `globaris-amba` architectures and must not churn), or any
  Deploy-Diagnostics collision with the pre-existing ALZ diagnostic assignments.
- **Expected non-fatal noise:** roughly 70 `PolicyRoleAssignmentError` warnings from the alz provider.
  These are the pre-existing non-AMBA OQ-021 class and are structurally unamplifiable by this change.
- The `InvalidPolicyParameterType` failure of 2026-07-19 **cannot recur**: the array-wrap fix is live at
  HEAD (`platform/management-groups/main.tf` line 66, `jsonencode({ value = [ ... ] })` with an
  empty-guard). Verified in code today.

### PC-4H. B7 prerequisites already satisfied.

`OM_OPERATOR_NOTIFICATION_EMAIL` exists as a repo Secret (set 2026-07-19) and is wired as
`TF_VAR_om_operator_notification_email` in `_tf-root.yml`, so the AMBA notification action group gets a
real receiver. No tenant, licensing or RP prerequisite applies.

---

## 7. Pre-dispatch checklist, split by lane

### 7a. USER-ACTION (only these can block a Wednesday start)

| ID | Action | Command / artefact | Blocking |
|---|---|---|---|
| **PC-1S** | Delete the surviving subscription-scoped Databricks policy exemption in the landingzones sub | `az policy exemption delete --name exempt-dbx-managed-storage-bank-data-p1 --scope /subscriptions/<lz-sub>` | **YES** for bank-data-p1 |
| **PC-4S** | Confirm the soft-deleted APIM instance is gone; purge it if the auto-purge has not fired | `az rest ... /deletedservices` then `az apim deletedservice purge` | **YES** for bank-app-p1 |
| **PC-5X** | Merge the PC-2S code fix into `banking` (review is agent lane, the merge is yours) | PR on a `fix/` branch | **YES** for bank-app-p1 |
| **PC-6X** | Do NOT open the state SA firewall manually and do NOT dispatch `target=all` | posture only | n/a |

### 7b. AGENT LANE (before the first dispatch)

| ID | Action | Owner |
|---|---|---|
| **PC-2S** | Author the `enable_acr_kubelet_binding` gate in `landing-zones/bank-app-p1` exactly as specified | cloud-engineer, then code-reviewer |
| **PC-7X** | Write the executable dispatch runbook from this document: the 14-step order in section 3, the per-root plan-scan bars, the PC-3C / PC-4C / PC-2X / PC-3X gates as explicit numbered steps, and the STOP conditions | devsecops-engineer |
| **PC-8X** | During the run: after `platform/management` -> PC-2X (re-set `PLATFORM_LAW_CUSTOMER_ID`). After `platform/connectivity` -> PC-3X (firewall IPs) and PC-4C (11 zones) | devsecops-engineer / operator |

### 7c. ALREADY SATISFIED (verified today, no action)

| Item | Evidence |
|---|---|
| MG tree empty | `az account management-group list` returns Tenant Root Group only |
| State blobs: 8 present at 181 bytes (empty, `resources: []`, serial 1), 2 absent (`bank-app-p1`, `bank-data-p1`) | `az storage blob list` on the state container |
| **No stale state leases** | every blob reports `lease: unlocked` (LESSON 51 check) |
| State SA posture correct | `default_action=Deny`, shared keys disabled, AzureServices bypass |
| RBAC | CI SP holds Contributor + User Access Administrator at both the connectivity and landingzones subscriptions, plus the still-live tenant-root grants covering MG-scope writes |
| Resource provider registrations | all 21 namespaces the six roots touch are `Registered` in BOTH subscriptions, including `Microsoft.Fabric`, `Microsoft.Databricks`, `Microsoft.ApiManagement`, `Microsoft.CognitiveServices`, `Microsoft.Search` |
| Network Watchers | `NetworkWatcher_eastus2` and `NetworkWatcher_centralus` live in `NetworkWatcherRG`, landingzones sub |
| Cross-root Secrets | complete `TF_VAR_*` coverage for all six roots; determinism proof in section 2 |
| Connectivity dry-plan | run `29851422904`, 696/0/0, exit 0, no `Error:` |
| Lifecycle audit | section PC-5C plus the gpt-5.4-nano catalog read in PC-6S |
| Branch state | local `banking` == `origin/banking` @ `d3b9e8c`, clean tree |

---

## 8. Watch-items during the applies (dispositions pre-agreed, so nobody improvises)

| Watch-item | Where | Pre-agreed disposition |
|---|---|---|
| Policy exemption propagation race | every spoke | The 300s `time_sleep` plus `depends_on` is the unit. If a flow-log SA still 403s on `RequestDisallowedByPolicy`, that is ONE rerunnable retry, then STOP and re-disposition (LESSON 35) |
| Databricks managed-RG `dbstorage` denied at create | bank-data-p1 | Confirm the sub-scoped exemption exists and its 300s sleep completed, then ONE retry. A second failure is a design question, not a wait |
| APIM create exceeding 90 minutes | bank-app-p1 | Do not cancel before the provider's 3h timeout. A cancelled APIM create leaves a soft-deleted instance and repeats PC-4S |
| AKS node bootstrap failing | bank-app-p1 | Check the firewall private IP is `10.0.0.4` and the `rcg-aks-egress-primary` collection group is live on the primary policy BEFORE touching anything else |
| Fabric F2 active cost | bank-data-p1 | Expected. Suspend post-QA per OQ-046 f3. Cost is explicitly not a gating input for this run |
| OQ-032 `CreatedDate` tag drift on later plans | everywhere | Accepted, cosmetic, no posture impact. Never a STOP on its own |
| `PolicyRoleAssignmentError` warnings | management-groups | Pre-existing OQ-021 class, non-fatal |
| Any `-/+` or unexpected destroy | any root | **STOP.** No exceptions, no console judgement calls (LESSON 26) |

---

## 9. Open questions raised

- **OQ-055** - cross-root output Secrets are a manual, forgettable, unverifiable coupling that has in fact
  been stable across three rebuilds. Replace with a determinism contract, remote state data sources, or
  leave as is?
- **OQ-056** - the five spokes cannot be dry-planned against a torn-down estate. Should spoke data sources
  be made plan-safe so a greenfield estate is fully dry-plannable end to end?
- **OQ-057** - `deploy.yml target=all` is documented as the full-environment shortcut but is structurally
  non-functional for apply. Remove it, restrict it to `action=plan`, or fund a runner-egress solution?

## 10. Decisions recorded

- **ADR-060** - full-estate rebuilds execute as sequential single-target dispatches with a per-root
  plan-scan gate; `target=all` is not an apply path.
- **ADR-061** - cross-root output Secrets are governed by a determinism contract: name-derived values are
  refreshed never, non-derivable values are re-set unconditionally after their producing root applies.

---

## Proposed commit message

```
docs(preclearance): 2026-07-22 full-estate rebuild gate - connectivity GO, five spokes GO-CONDITIONAL,
bank-app-p1 blocked on an unplannable same-root AKS data source (PC-2S) and bank-data-p1 on a surviving
subscription-scoped exemption (PC-1S); sequential single-target ruling (ADR-060) and the cross-root
Secret determinism contract (ADR-061)
```

---
---

# 2026-07-29 REFRESH ADDENDUM - re-clearance against the confirmed-clean greenfield

> **Provenance note added 2026-07-30 (not part of the 2026-07-29 text below).** This section was
> written on 2026-07-29 and was never committed. Its branch was merged without it and it survived only
> as an uncommitted file in a volatile worktree until the 2026-07-30 sweep rescued it (OQ-064). It is
> recorded here **verbatim**, unedited, as the historical record. Its per-root VERDICT TABLE is
> **SUPERSEDED** by the 2026-07-30 refresh below, which was computed after the dispatch this section
> cleared was actually attempted and failed at Step 3. Its sections R1, R2, R3 and R5 are re-verified
> and carried forward there; R4 and R6 are amended there. Read this section for the reasoning, and the
> 2026-07-30 section for the verdict.

**Date:** 2026-07-29
**Author:** cloud-solutions-architect
**Type:** REFRESH of the gate above, not a re-derivation. The history above is unchanged. This section
records what still holds, what drifted, and the single verdict for dispatching NOW.
**Repo state this refresh was computed against:** `origin/banking` @ `b6db5d0` (HEAD of banking, PR #52
merged), working tree clean. The 2026-07-22 gate above was computed at `d3b9e8c`; the delta between the
two is enumerated in section R3 and is confined to teardown scripts, one deploy guard, and the PC-2S
spoke fix.

**Why a refresh is needed and why the gate above did not simply carry:** the 2026-07-22 dispatch was
attempted on 2026-07-23 and **voided at Step 2**, not on any deploy defect but on a TEARDOWN-completeness
defect - MG-scoped extension survivors (3 MG-scope budgets plus `diag-aa-to-law`) that the prior teardown
left behind, which would have collided at the `platform/management-groups` apply. Those survivors, plus
the completeness mechanism that leaves them, were fixed across ADR-062 / ADR-063 / ADR-064 / ADR-065, a
fresh teardown was run, and **qa has now independently confirmed a clean greenfield (PASS)**: no estate
RGs, the `globaris` MG tree gone with all 5 subs re-parented to tenant root, the 2026-07-23 collision
objects gone, other orphan classes clean, soft-deleted KVs pose no name collision (fresh random
suffixes), and the bootstrap intact (state SA `stglobaristfstate01` + `tfstate` container + KV + OIDC SP
`sp-alz-poc-cicd` + federated creds). This refresh re-clears the APPLY against that confirmed state.

---

## VERDICT: GO. Dispatch the 14-step sequence now, from `--ref banking`.

Every root is GO or GO-CONDITIONAL with its condition already satisfied on `banking`. **There is no
NO-GO and no open code blocker.** The two conditions that gated the 2026-07-22 verdict (PC-2S, PC-1S) are
both resolved and verified in this refresh (section R2). The only remaining "conditional" items are the
two-pass roots that were always designed as two passes (identity ADR-055, bank-app-p1 PC-2S Pass 2) and
one reviewed tfvars flip (B7), none of which block the FIRST dispatch.

| Root | 2026-07-22 verdict | 2026-07-29 refresh verdict | What changed |
|---|---|---|---|
| `platform/management-groups` | GO (via b0a) | **GO** | none. Watch-point W3 (MG-budget collision is now provable only at this apply). |
| `platform/management` | GO (via b0a) | **GO** | none. PC-2X (re-set `PLATFORM_LAW_CUSTOMER_ID`) still applies. |
| `platform/security` | GO (via b0a) | **GO** | none. Carried-forward b0a PC-2R Defender-Free pre-flight still applies (W2). |
| `platform/connectivity` | GO | **GO** | none. 696-add plan still authoritative: no connectivity `.tf` changed since `d3b9e8c` (R3). |
| `landing-zones/corp-a1` | GO-CONDITIONAL | **GO-CONDITIONAL** | unchanged. Condition = post-connectivity zone check (PC-4C), a defined post-apply gate, not a blocker. |
| `landing-zones/corp-a2` | GO-CONDITIONAL | **GO-CONDITIONAL** | as corp-a1. |
| `landing-zones/online-p1` | GO-CONDITIONAL | **GO-CONDITIONAL** | as corp-a1. |
| `landing-zones/bank-data-p1` | GO-CONDITIONAL (blocked on PC-1S) | **GO** | **PC-1S RESOLVED** (R2). The surviving subscription-scoped exemption is gone (CI sweep + qa-confirmed greenfield). Condition removed. |
| `landing-zones/bank-app-p1` | NO-GO until PC-2S lands | **GO-CONDITIONAL (condition already satisfied on `banking`)** | **PC-2S RESOLVED** (R2). The `enable_acr_kubelet_binding` gate is merged on `banking`; Pass 1 is now plannable. Pass 2 is a reviewed tfvars flip, unchanged. |
| `platform/identity` | GO (two-pass, ADR-055) | **GO** | none. Pass 1 clean at 26 adds (ADR-059 closed); two-pass override still applies. |

---

## R1. Dispatch ref = `banking`, NOT `main`. CONFIRMED, with a POST-rebuild cleanup flagged.

`main` is behind `banking` and **must not be dispatched**. Verified today by `git log
origin/main..origin/banking`: PRs **#46, #48, #49, #50, #51, #52** are on `banking` and absent from
`main`. That delta carries every fix this rebuild depends on: the ADR-055/059/060/061 deploy wiring, the
PC-2S spoke gate (#45), the operator runbook, and the ADR-062/063/064/065 teardown-completeness fixes.
`main`'s newest deploy-relevant commit predates all of it. The runbook (`docs/2026-07-22-full-estate-
rebuild-runbook.md`) already dispatches `-R Globaris-Inc/Azure-Architecture --ref banking` on every
command and states the rule in its section 2 ("never dispatch from `main`, it lacks the ADR-055/059/060
wiring this whole day depends on"). No change needed there.

**POST-rebuild cleanup (NOT a pre-req for this apply): promote `banking` -> `main`, or block `main` from
`deploy.yml` dispatch.** `main` being dispatchable-but-stale is a standing foot-gun (an operator who
forgets `--ref banking` gets a silently wrong deploy). This is deferred to after the rebuild is green and
QA'd, consistent with the memory rule that `banking` is the integration branch feeding `main`. It does
not gate today. Recorded as a watch-item, not a blocker. (Related: OQ-057 already tracks the wider
`target=all` dispatch-safety question.)

---

## R2. The two prior blockers are TRULY resolved on `banking`. Verified, not assumed.

### PC-2S (bank-app-p1 unplannable same-root AKS data source) - RESOLVED.

Verified in the `origin/banking` tree today (not inferred from a commit subject):

- `landing-zones/bank-app-p1/variables.tf` line 137: `variable "enable_acr_kubelet_binding"` exists,
  `type = bool`, `default = false`, with the description recording the PC-2S two-pass rationale.
- `landing-zones/bank-app-p1/acr.tf` line 46: the data source gate reads
  `for_each = var.enable_kubernetes_platform && var.enable_acr_kubelet_binding ? { main = "main" } : {}`.
  With the flag false, the map is empty, so the `azurerm_kubernetes_cluster` lookup **does not resolve at
  plan time** and cannot 404 against the not-yet-created cluster.
- `landing-zones/bank-app-p1/acr.tf` line 95: the ACR `role_assignments` input is
  `var.enable_acr_kubelet_binding ? { kubelet_acr_pull = { ... } } : {}` with the map KEY held static
  (LESSON 5a), so the address identity never moves between passes.
- `envs/poc.tfvars`: **`enable_acr_kubelet_binding` is NOT present** (grep returns nothing), so it takes
  its `false` default for Pass 1. This is the correct posture: flipping it early would reproduce the exact
  PC-2S defect. The `depends_on` anti-pattern was correctly NOT used.

Landed as commit `5cc519b` (merged into `banking` via PR #45). **bank-app-p1 Pass 1 is now plannable on a
greenfield estate.** The Pass 2 flip (`enable_acr_kubelet_binding = true` in `envs/poc.tfvars`, reviewed
one-line commit, plan bar exactly 1 add) is unchanged from the gate above and is Step 12, not a Step 9
pre-req.

### PC-1S (surviving subscription-scoped Databricks policy exemption) - RESOLVED.

Two independent lines of evidence, both post-dating the 2026-07-22 gate:

1. **Removed by the pipeline, not by hand.** ADR-062 sub-step 6d deleted
   `exempt-dbx-managed-storage-bank-data-p1` during teardown run `29880338547`, and that run's VERIFY 6d
   plus VERIFY 9 confirmed zero OWNED subscription-scoped policy objects across all 5 subscriptions
   (documented on `banking` at commits `6a48b4c` / `d8cadfb`; the runbook section 2a already records
   PC-1S as "ALREADY SATISFIED via CI - no action").
2. **qa's fresh greenfield PASS** independently confirms no surviving subscription-scoped policy objects
   and clean orphan classes across the estate.

**bank-data-p1's blocking condition is removed; it is now GO.** PC-1S survives only as a cheap read-only
re-confirm in the Step 8 pre-flight (`az policy exemption list ... --query "[].name"` -> expect empty),
which the runbook already carries. If it were somehow present, that pre-flight catches it before the
apply, as designed.

---

## R3. Config drift on the APPLY path since 2026-07-22: NONE that affects a single-target apply.

The full `.tf` / `.yml` / `.tfvars` / `.hcl` delta between the gate baseline `d3b9e8c` and `banking`
HEAD `b6db5d0` is six files, itemized:

| File | Change | Effect on the apply path |
|---|---|---|
| `landing-zones/bank-app-p1/acr.tf`, `variables.tf` | PC-2S gate | **Intended.** Makes Pass 1 plannable. Covered in R2. |
| `.github/workflows/deploy.yml` | +`guard-target-all-apply` job (ADR-065 decision 6) | **Inert on single-target.** The guard is a standalone job with `if: inputs.target == 'all' && inputs.action == 'apply'`; no root job `needs:` it. On any single-target dispatch it is simply skipped. It cannot affect Steps 1-14, which are all single-target. It only closes the `target=all + apply` foot-gun ADR-060 already forbade. |
| `.github/workflows/_tf-root.yml` | 8-line comment update only (documents the ADR-065 teardown `manage_runner_ip` wiring) | **None.** The "Open state SA firewall" / "Restore Deny" steps are byte-unchanged. |
| `.github/workflows/teardown.yml`, `teardown-probe.yml` | ADR-063/064/065 teardown logic | **None.** Teardown-only; not on the deploy path. |

**Single-target firewall wiring is intact.** All 11 root jobs in `deploy.yml`
(management-groups, management, connectivity, identity, security, corp-a1, corp-a2, online-p1,
bank-app-p1, bank-data-p1, synthetic) set `manage_runner_ip: ${{ inputs.target != 'all' }}`, so every
single-target apply opens the firewalled state SA for its job window and restores Deny on exit
(`_tf-root.yml` line 238 open, line 433 restore). ADR-060's sequential single-target ruling and ADR-061's
Secret determinism contract both stand unchanged.

**`envs/poc.tfvars` posture matches the intended rebuild scope** (read from `banking` today):
`enable_firewall = true`, `enable_kubernetes_platform = true`, `enable_messaging_platform = true`,
`enable_api_platform = true`, `enable_data_platform = true`, `enable_fabric_capacity = true`,
`enable_ai_platform = true`, `enable_om_phase1 = false` (correct for the main run, PC-4R; re-landed as
Steps 13-14), `enable_synthetic_workload = false` (the `synthetic` root is not dispatched),
`enable_acr_kubelet_binding` absent (false for Pass 1). No drift from the scope the gate above assumed.

**Connectivity 696-add plan is still authoritative:** no file under `platform/connectivity/` changed
between `d3b9e8c` and `b6db5d0`. The PC-1C bar (EXACTLY 696 to add, 0 change, 0 destroy, exit 0, zero
`Error:`) stands.

---

## R4. Watch-points (qa's open items, dispositioned as watch-points, NOT blockers).

| ID | Watch-point | Disposition |
|---|---|---|
| **W1: RBAC-on-first-job** | qa could not re-confirm the CI SP's role bindings live (an `az`-CLI quirk; the SP `sp-alz-poc-cicd`, its federated creds, and the bootstrap all exist and are intact). | **Not a blocker. The first apply job IS the live confirmation.** Step 1 (`platform/management-groups`) performs an OIDC login and `terraform init` against the firewalled state SA and then writes MG-scope objects; a missing or insufficient binding fails loud there, immediately, before any estate resource is touched. Treat a Step 1 auth failure per matrix U3 (one init retry for a firewall-propagation flap) then, if it recurs as an actual `AuthorizationFailed` on the write, STOP - that is a real RBAC gap, not a wait. Do NOT pre-grant anything speculatively. |
| **W2: Defender-standard-accepted** | Defender plans `AI`, `Discovery`, `FoundationalCspm` remain `Standard` in the security subscription (OQ-050, accepted). | **Not a blocker.** These three are intentionally NOT reset by teardown and are held at their state values by `platform/security` (ADR-035 pins basic-plan subplans to state values to avoid the ForceNew regress; ADR-040 holds the latent-debt plans). The rebuild re-establishes Defender over them. The DISTINCT carried-forward b0a pre-flight PC-2R (the EIGHT estate-managed plans - `VirtualMachines`, `StorageAccounts`, `AppServices`, `SqlServers`, `SqlServerVirtualMachines`, `Containers`, `OpenSourceRelationalDatabases`, `CloudPosture` - must read `Free` before Step 3) still applies as a cheap read-only check; matrix B2 covers a miss. W2 (the 3 Standard plans) and PC-2R (the 8 Free plans) are different sets; do not conflate them. |
| **W3: MG-budget-collision-check** | The 3 MG-scope budgets are structurally unverifiable post-deletion (a deleted MG scope is 403-shadowed; ADR-062/063). qa cannot prove their absence by query. | **Not a blocker. The Step 1 `platform/management-groups` apply IS the definitive collision check.** If a budget survived, the create returns a requires-import at that apply (matrix B1: stop, delete the specific survivor per b0a UA-1, rerun - do not import). This is the exact class that voided the 2026-07-23 attempt, and it is now both fixed at source (Phase 0 DISARM MG-scope sweep, ADR-063/064) and re-provable at Step 1. Scan the Step 1 plan for any `already exists`/import-block line. |

---

## R5. The confirmed dispatch sequence (unchanged from the runbook; ref = `banking` throughout).

The 14-step order in the runbook and in section 3 above is correct for this greenfield and is confirmed.
management-groups first (creates every ancestor scope), then the platform dependency chain, then the
spokes, then the identity two-pass, then the two deferred second passes. ADR-055 identity two-pass
(`enable_conditional_access_override` false on Pass 1 / true on Pass 2) and ADR-061 Secret determinism
(re-set `PLATFORM_LAW_CUSTOMER_ID` after Step 2; verify firewall IPs after Step 4) both still apply.

| # | Dispatch | `action` | Special inputs | In-run gate after |
|---|---|---|---|---|
| 1 | `platform/management-groups` | plan then apply | none | PC-3C (DDoS DoNotEnforce at both MGs) before Step 4; scan for W3 budget collision |
| 2 | `platform/management` | plan then apply | none | **PC-2X: re-set `PLATFORM_LAW_CUSTOMER_ID`** |
| 3 | `platform/security` | plan then apply | none | (PC-2R Defender-Free pre-flight is BEFORE this step) |
| 4 | `platform/connectivity` | plan then apply | none | **PC-3X (firewall IPs = .4) + PC-4C (89 zones / 11 lookups)** |
| 5 | `landing-zones/corp-a1` | plan then apply | none | per-spoke plan-scan (PC-9S shape) |
| 6 | `landing-zones/corp-a2` | plan then apply | none | per-spoke plan-scan |
| 7 | `landing-zones/online-p1` | plan then apply | none | per-spoke plan-scan |
| 8 | `landing-zones/bank-data-p1` | plan then apply | none | Step 8 pre-flight: PC-1S re-confirm (expect empty) |
| 9 | `landing-zones/bank-app-p1` Pass 1 | plan then apply | none (flag false) | Step 9 pre-flight: PC-4S (APIM soft-delete gone) + PC-5X (gate present) + tfvars-flip-not-early |
| 10 | `platform/identity` Pass 1 | plan then apply | `enable_conditional_access_override=false` | AADDS create-wait; matrix I1/I2 |
| 11 | `platform/identity` Pass 2 | plan then apply | `enable_conditional_access_override=true` | 10 pure adds (named location + 8 CA policies) |
| 12 | `landing-zones/bank-app-p1` Pass 2 | plan then apply | none (after tfvars flip PR merges) | plan bar exactly 1 add |
| 13 | `platform/management` (B7) | plan then apply | none (after `enable_om_phase1=true` merges) | **PC-2H: confirm `id-amba-prod-001` live** |
| 14 | `platform/management-groups` (B7) | plan then apply | none | ~200-260 adds; matrix H3 |

Steps 5-9 may be reordered among themselves but never run concurrently (Rule 2 / ADR-060). Steps 5-14 use
the plain two-line plan-then-apply pattern; only Steps 10 and 11 carry the identity override input.

**STOP conditions are unchanged** and live in the runbook's STOP/rollback matrix (section 3: U1-U6, B1-B7,
C1-C3, S1-S5, I1-I2, H1-H3). The load-bearing ones for this refresh: **U1** (any `-/+ replace` or
unexpected destroy anywhere is a hard STOP - every root runs from empty state), **B1** (a budget/export
requires-import at Step 1 means a survivor is back = W3), **U5** (a second identical failure on one root
after one clean retry is a HARD STOP - this counts toward the project's 4-failure bar), and **C1** (DDoS
policy reads `Default` not `DoNotEnforce` before Step 4).

---

## R6. What this refresh did NOT re-verify live (stated honestly, per the pre-clearance discipline).

This refresh is a repo-and-evidence re-clearance. It confirmed code state on `banking`, the drift delta,
and the two prior blockers directly. It **relied on qa's independent greenfield PASS** for the live estate
state (no estate RGs, MG tree gone, orphan classes clean, bootstrap intact) rather than re-running those
queries, because that is qa's just-completed, independently-owned confirmation and re-running it here
would duplicate it without adding assurance. The live PUT-time gates that no plan can see (policy-collision
races, firewall-IP determinism, zone presence, Defender-Free pre-flight, RBAC-on-first-job) are NOT
asserted as pre-cleared here; each is a named in-run gate or watch-point above (W1-W3, PC-2R, PC-3C,
PC-3X, PC-4C) with a pre-agreed disposition, exactly as the gate above designed them. **A gate nobody can
check pre-dispatch is not asserted as passed; it is converted to a defined verification moment.**

---

## R7. Decisions / open items from this refresh.

- **No new ADR.** This refresh introduces no new decision; it confirms ADR-060 and ADR-061 still govern
  and that ADR-063/064/065 are teardown-scoped with no deploy-path effect beyond the inert
  `guard-target-all-apply`.
- **Watch-item (not OQ-worthy on its own):** promote `banking` -> `main` (or block `main` from
  `deploy.yml` dispatch) as a post-rebuild cleanup (R1). Related to the standing OQ-057.

---

## Proposed commit message (refresh)

```
docs(preclearance): 2026-07-29 refresh - GO to dispatch the full-estate rebuild from banking; PC-2S and
PC-1S both resolved and verified on banking, no apply-path drift (ADR-065 guard is inert on single-target),
tfvars scope matches, connectivity 696-add plan still authoritative; watch-points RBAC-on-first-job,
Defender-standard-accepted, MG-budget-collision-at-step-1
```

---
---

# 2026-07-30 REFRESH #2 - re-clearance against `banking` @ `ed3450e`, after the Step-3 failure, ADR-067 and ADR-066

**Date:** 2026-07-30
**Author:** cloud-solutions-architect
**Type:** REFRESH of both sections above. Append-only: nothing above this line was edited except the
dated provenance banner on the 2026-07-29 heading.
**Repo state this refresh was computed against:** `banking` @ `ed3450e` (the PR #55 merge, tip of
`banking` when this was written), working tree clean. Written on branch
`docs/preclearance-refresh-2026-07-30`, cut off `banking` at `ed3450e`.
**Supersedes:** the per-root verdict table in the 2026-07-29 addendum.
**Closes:** OQ-064, both limbs (durability by landing this file in git, validity by the table in S0).

---

## Why refresh #2 exists

Four things happened after the 2026-07-29 addendum was written, and the addendum can see none of them:

1. **The dispatch it cleared was attempted and FAILED at Step 3.** `platform/security` run
   `30499221661` was the first apply of that root from a genuinely empty state, and it failed on three
   interacting classes (ADR-067). The addendum's GO for `platform/security` was therefore falsified by
   the run itself, not by any later code change. That alone makes a carry-forward inadmissible.
2. **ADR-067 (PR #53, `3ed8dad`) changed that root's apply behaviour**: `depends_on` on both Sentinel
   automation rules, a corrected pricing comment, and `-parallelism=1` appended to the
   `platform/security` apply step in `_tf-root.yml`.
3. **ADR-066 (PR #54, `2ca1fc5`) rebuilt the teardown** and, on the apply path, added a `features`
   block to `platform/security/providers.tf`.
4. **The addendum was never committed** and nearly went the way of ADR-066 (OQ-064). Landing it here,
   verbatim, with this refresh on top, is the durability half of that resolution.

---

## S0. VERDICT

**Whole-run verdict: GO-CONDITIONAL. There is no NO-GO and no open code blocker. There are two hard
pre-flight conditions that cannot be checked from the repository and MUST be proved live before any
dispatch: PC-1Y (estate is actually greenfield) and PC-1SEC (the Security LAW is not in soft delete).**

Every per-root verdict below is stated **conditional on PC-1Y passing**. PC-1Y is a whole-run gate: if
it fails, no root is GO and the disposition is a teardown, not a dispatch.

**PC-1Y has TWO halves, and checking only the first is how 2026-07-30 went wrong (added that day).**
Greenfield means no live Azure resources **and** no Terraform state describing resources that no longer
exist. Both must be proved. The second half was omitted from this gate until it cost a stalled plan:

```bash
az storage blob list --account-name stglobaristfstate01 --container-name tfstate \
  --auth-mode login --query "sort_by([].{name:name,bytes:properties.contentLength}, &name)" -o table
```

**Every blob must be at the empty baseline, roughly 150-250 bytes** (the observed floor in this
container is 181). Anything materially larger describes resources and is a **STOP**: reconcile before
dispatching. Note the asymmetry, because the two failure directions need opposite responses:

| Observed | Class | Meaning | Disposition |
|---|---|---|---|
| blob materially larger than the baseline, estate empty | **FM-2** | state describes resources that are gone | STOP. The plan will refresh phantoms, and per ADR-062 the scoped CI principal returns **403, not 404**, on a deleted MG scope, so those refreshes are hard errors rather than a clean "gone". Reset via the teardown (ADR-068 Phase 4), never by hand. |
| blob ABSENT, or below the 100-byte probe threshold | **FM-1** | state lost while resources may be live | STOP. This is the OQ-053 alarm. A plan would read greenfield and collide at create time (`ImportAsExistsError`). Do NOT reset; investigate provenance first. |

An emptied blob and a lost blob look superficially similar and mean opposite things. Size alone
distinguishes them: a canonical empty state is well above the 100-byte threshold
`scripts/teardown-probe-state.sh` uses for FM-1.

**Evidence this belongs in the gate:** on 2026-07-30 the estate was independently qa-confirmed
greenfield on live Azure and PC-1Y passed, while `platform/management-groups` state still held
8,959,166 bytes describing ~537 deleted resources. The first Step 1 plan ran 41 minutes without
completing and had to be cancelled. Nothing in the gate looked at the state backend. Once the three
stale blobs were reset the same plan completed in 2 minutes 17 seconds at 537 add / 0 change /
0 destroy. This is OQ-065 limb B, and the check above is its zero-code half: the mechanism that
prevents the condition is ADR-068 Phase 4, but this gate is what catches it if the mechanism is ever
skipped, fails, or the teardown is dispatched from a ref that predates it.

| # | Root | 2026-07-29 verdict | 2026-07-30 verdict | Gating condition |
|---|---|---|---|---|
| 1 | `platform/management-groups` | GO | **GO** | PC-1Y. Watch W3 (MG-budget collision is provable only at this apply) carried unchanged. |
| 2 | `platform/management` | GO | **GO** | PC-1Y. PC-2X (re-set `PLATFORM_LAW_CUSTOMER_ID` after apply) carried unchanged. |
| 3 | `platform/security` | GO | **GO-CONDITIONAL** | PC-1Y **and PC-1SEC** (soft-deleted Security LAW proved ABSENT, purged via CI if present) **and PC-2R** (the 8 estate-managed Defender plans read `Free`). **Fresh judgement, see S3.** |
| 4 | `platform/connectivity` | GO | **GO** | PC-1Y. 696-add bar re-verified as still authoritative (S2). |
| 5 | `landing-zones/corp-a1` | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-1Y, then PC-4C (11 zones present) after Step 4. Unchanged. |
| 6 | `landing-zones/corp-a2` | GO-CONDITIONAL | **GO-CONDITIONAL** | as corp-a1. |
| 7 | `landing-zones/online-p1` | GO-CONDITIONAL | **GO-CONDITIONAL** | as corp-a1. |
| 8 | `landing-zones/bank-data-p1` | GO | **GO-CONDITIONAL** | PC-1Y, then the Step-8 PC-1S re-confirm (expect zero subscription-scoped policy exemptions). Tightened from GO because the 2026-07-29 GO rested on a qa greenfield PASS that now predates a failed rebuild attempt; the re-confirm is already in the runbook and costs one query. |
| 9 | `landing-zones/bank-app-p1` Pass 1 | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-1Y, PC-4S (APIM soft-delete gone), PC-5X (the `enable_acr_kubelet_binding` gate present on the dispatched ref), tfvars-flip-not-early. Unchanged. |
| 10 | `platform/identity` Pass 1 | GO | **GO** | PC-1Y. ADR-055 two-pass unchanged. No `platform/identity` file has changed since `d3b9e8c` (S2). |
| 11 | `platform/identity` Pass 2 | GO | **GO** | as Pass 1, `enable_conditional_access_override=true`. |
| 12 | `landing-zones/bank-app-p1` Pass 2 | GO-CONDITIONAL | **GO-CONDITIONAL** | the reviewed one-line `envs/poc.tfvars` flip merged AFTER Step 9 is green. Unchanged. |
| 13 | `platform/management` (B7) | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-1H (reviewed `enable_om_phase1 = true` flip, merged only after Step 12). Unchanged. |
| 14 | `platform/management-groups` (B7) | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-1H plus PC-2H (`id-amba-prod-001` confirmed live before dispatch). Unchanged. |

The single substantive verdict movement is `platform/security`, GO -> GO-CONDITIONAL, and the reason is
not ADR-067's code (which is correct and helps) but what ADR-067's code deliberately does **not** cover.

---

## S1. What the 2026-07-29 addendum still carries, and what it does not

| Section | Status at 2026-07-30 | Basis |
|---|---|---|
| **R1** dispatch ref = `banking`, never `main` | **CARRIED, re-verified.** `banking` is still ahead of `main` and still carries every fix this rebuild depends on, now including PRs #53, #54 and #55. | `git log origin/main..banking` |
| **R2** PC-2S and PC-1S resolved | **CARRIED.** PC-2S is code state and is unchanged since `b6db5d0` (`landing-zones/bank-app-p1/acr.tf` and `variables.tf` are not in the `b6db5d0..ed3450e` delta). PC-1S is live state and is folded into PC-1Y plus the Step-8 re-confirm. | S2 delta, this document |
| **R3** no apply-path drift | **AMENDED.** There IS apply-path drift now, confined to four files, all in or adjacent to `platform/security`. Fully enumerated and dispositioned in S2. | S2 |
| **R4** watch-points W1/W2/W3 | **CARRIED unchanged.** W1 RBAC-on-first-job (Step 1 is the live confirmation), W2 Defender-standard-accepted (AI, Discovery, FoundationalCspm stay Standard; distinct from PC-2R's eight), W3 MG-budget-collision (Step 1 is the definitive check). Nothing since 2026-07-29 touches any of them. | S4, S5 |
| **R5** the 14-step dispatch sequence | **CARRIED, with three amendments.** Order and gates unchanged; a Step 0 is prepended, Step 3's duration expectation is revised, and two STOP-matrix rows are corrected. See S6. | S6 |
| **R6** what was not re-verified live | **REPLACED by S5.** R6 leaned on a qa greenfield PASS that now predates a failed rebuild attempt, so it can no longer stand as the live-state basis. | S5 |
| Verdict table | **SUPERSEDED by S0.** | S0 |

---

## S2. Apply-path drift since the 2026-07-29 basis `b6db5d0`: FOUR files, all dispositioned

Full `.tf` / `.tfvars` / `.hcl` / deploy-workflow delta for `b6db5d0..ed3450e`. Everything else in that
range is teardown scripts, `teardown.yml`, docs, agent definitions and new preflight scripts, none of
which is on the deploy path.

| File | Change | Effect on the apply |
|---|---|---|
| `platform/security/sentinel.tf` | `depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]` added to `azurerm_sentinel_automation_rule.auto_assign` and `.ti_enrichment_tag` | **Beneficial, zero plan-shape change.** `depends_on` is a meta-argument: it adds graph edges, creates no address, changes no attribute, and produces no diff. The Step-3 plan address set is byte-identical to the pre-ADR-067 one. At apply it removes the ADR-067 Class 3 race. See S3a. |
| `platform/security/defender.tf` | comment rewrite only on `azurerm_security_center_subscription_pricing.extended` | **Inert.** The `depends_on` line itself is unchanged. |
| `platform/security/providers.tf` | `features { log_analytics_workspace { permanently_delete_on_destroy = true } }` on the default provider | **Inert at apply.** See S3c. |
| `.github/workflows/_tf-root.yml` | comment rewrite (header + `manage_runner_ip` description) plus `-parallelism=1` appended to the **apply** step when `inputs.root == 'platform/security'` | **Behaviour change, confined to Step 3's apply.** Plan and destroy steps untouched. See S3b. |

**Not in the delta, and each absence matters:**

- `envs/poc.tfvars` is **unchanged since `d3b9e8c`**, the original 2026-07-22 gate basis. The whole
  flag posture that gate assumed (`enable_firewall`, `enable_kubernetes_platform`,
  `enable_messaging_platform`, `enable_api_platform`, `enable_data_platform`,
  `enable_fabric_capacity`, `enable_ai_platform` all true; `enable_om_phase1` false;
  `enable_synthetic_workload` false; `enable_acr_kubelet_binding` absent) still holds byte for byte.
- `.github/workflows/deploy.yml` is unchanged since `b6db5d0`. ADR-060's sequential single-target
  ruling, the per-root `manage_runner_ip: ${{ inputs.target != 'all' }}` wiring on all 11 root jobs,
  and the inert `guard-target-all-apply` job all stand exactly as the 2026-07-29 addendum described.
- **Nothing under `platform/connectivity/`, `landing-zones/`, `platform/identity/`,
  `platform/management/` or `platform/management-groups/` has changed since `d3b9e8c`**, apart from
  the two PC-2S files in `bank-app-p1`. The PC-1C connectivity bar (**exactly 696 to add, 0 change,
  0 destroy, exit 0, zero `Error:`**) is therefore still authoritative at `ed3450e`.

---

## S3. `platform/security`: the fresh judgement

ADR-067 diagnosed three classes on run `30499221661`. The repo now fixes two of them on the apply path.
The third is fixed on the **teardown** path only, and that is the whole verdict.

### S3a. Class 3 (automation rules race the onboarding) - CLOSED on the apply path. No condition.

Both automation rules now carry the same onboarding `depends_on` that the eight sibling Sentinel
resources in `sentinel.tf` already had. This is the correct fix and the correct shape: the
automation-rule endpoint gate-checks onboarding even on the existence GET, so an ordering edge is the
only control that works. ADR-033 saw this exact failure on run `29133588369` and dismissed it as
transient, which it never was.

**Plan impact: none.** `depends_on` does not appear in a plan diff. Step 3's expected plan is unchanged.

### S3b. Class 1 (CloudPosture 409) - CLOSED on the apply path, with a duration watch-item.

`-parallelism=1` is now appended to the apply command by `_tf-root.yml` itself, keyed on
`inputs.root == 'platform/security'`. Verified in the repo, not assumed:

- `root: platform/security` appears **twice** in `.github/workflows/`: `deploy.yml:232` (the apply-path
  `security` job) and `teardown.yml:395` (the ADR-066 Phase-1 `security` destroy job). What is unique is
  the CONDITIONAL, `inputs.root == 'platform/security'` in `_tf-root.yml:366`, which occurs exactly once.
  The teardown caller cannot reach it: it passes `action: destroy`, and the append sits on the
  `Terraform Apply` step, gated `if: inputs.action == 'apply'`. So the destroy path is unaffected for a
  reason, not by coincidence. (An earlier draft of this bullet, and the 2026-07-29 DevSecOps session
  entry it came from, both asserted the literal appeared exactly once. It does not. The engineering
  conclusion survives, the count did not, and it was corrected at the code-review gate on 2026-07-30.)
- The flag is appended to the **`Terraform Apply`** step only. The `Terraform Plan` and destroy steps
  are untouched, so the plan-scan bar is unaffected and this cannot mask a plan-shape problem.
- No other root's `with:` block changes, so no other root is slowed.

Wiring it into the workflow rather than leaving it as an operator-typed argument is the right call and
directly addresses the ADR-034 failure mode: `-parallelism=1` was named as that ADR's sanctioned
control, was never wired anywhere, and the gap surfaced 33 ADRs later as a live apply failure.

**No provider-side fix exists.** There is no open azurerm issue proposing serialization inside
`azurerm_security_center_subscription_pricing`, and the general class (high parallelism against
single-controller Azure APIs) is a long-standing provider-level limitation. So this is a durable
control, not a temporary hack, and it should not be removed later on the theory that the provider will
fix it.

**Watch-item PC-3SEC (not a blocker):** serializing the whole root, not just the pricing set, makes
Step 3 slower. The runbook says "Duration ~15 min". At `-parallelism=1` across roughly 48 addresses,
including a Log Analytics workspace create, a Key Vault create, a Standard Event Hub namespace with
auto-inflate, the Sentinel onboarding, ten scheduled alert rules, eight pricing PUTs and two MG-scope
policy assignments, **budget 25 to 45 minutes**. This is comfortably inside the ADR-055 durable-OIDC
envelope (the root re-mints its assertion on every token acquisition) and nowhere near the identity or
APIM long-apply class. **Do not treat a Step 3 that is still running at minute 20 as hung.** Runbook
correction handed to DevSecOps in S7.

### S3c. The `providers.tf` features block - INERT AT APPLY. Verified, not assumed.

`permanently_delete_on_destroy` is a real argument of the `log_analytics_workspace` sub-block of the
azurerm `features` block, it is Optional, it **defaults to `false`**, and it governs one thing only:
whether the workspace is purged rather than soft-deleted **when the Terraform resource is destroyed**.
Verified 2026-07-30 against the pinned provider's own documentation at the **v4.71.0** tag, so the
argument is real at the exact version the lock file resolves, not merely at provider HEAD.

It has no create, read or update path, so it cannot affect Step 3's apply, cannot affect the plan, and
does not require a provider version bump. **It is correctly placed** on the default provider instance,
which is the instance `module "security_law"` is created through (that module call carries no
`providers =` override, and this root declares a single `azurerm` instance).

One standing consequence, already recorded in OQ-063 and the ADR-066 addendum and repeated here because
it is a permanent widening of that root's destroy blast radius: **any** Log Analytics workspace ever
added to `platform/security` is now permanently purged by **any** destroy of that root, including an
accidental wrong-root destroy, with no 14-day recovery window. That is the intended trade. It is not an
apply-path risk.

### S3d. Class 2 (soft-delete-recovered LAW re-hydrates orphaned Sentinel objects) - NOT closed by anything on the apply path. **This is PC-1SEC and it is the condition.**

This is the finding of this refresh, and it is the one the 2026-07-29 addendum structurally could not
have made.

The causal chain, restated so the gap is unmissable:

1. ADR-067 Class 2 happened because the AVM LAW module's PUT **recovered** a soft-deleted
   `law-security-<org>-<env>` instead of creating a fresh one. Recovery restores workspace
   configuration **and** its `Microsoft.SecurityInsights` children, so roughly eleven analytics rules
   and the MDC data connector came back as live objects absent from the freshly-emptied state, and the
   provider's pre-create GET returned `ImportAsExistsError` on each. The workspace itself did not
   error, because a soft-deleted workspace GETs 404 and the PUT reports success.
2. The repo's fix for Class 2 is **entirely teardown-side**, in two layers: the native provider purge
   in S3c (fires only during `terraform destroy` of `platform/security`) and
   `scripts/teardown-az-sweep.sh` step 7b (fires only inside a Phase 2 az-sweep).
3. **Neither layer can act on a workspace that is ALREADY in soft delete**, unless a teardown is
   dispatched from a ref that contains them. Both merged in PR #54 (`2ca1fc5`) on 2026-07-30.
4. **Nothing on the apply path purges anything.** There is no argument, no flag and no plan-time
   signal. A plan against a soft-deleted workspace looks like a clean create.
5. OQ-063 states this precondition in terms, and it is the repo's own words, not mine: a teardown
   dispatched from a ref without the provider feature "soft-deletes the workspace again and reproduces
   the ADR-067 Class 2 'already exists' failure on the next security apply, with no signal at plan
   time. This branch must be merged into `banking` before the teardown that precedes the rebuild's
   Step 3 is dispatched."
6. **Every teardown run recorded anywhere in this repository predates `2ca1fc5`.** No committed
   artefact records a teardown dispatched from `banking` at or after that merge.

**Therefore, on the evidence available to me, `law-security-<org>-<env>` is more likely than not sitting
in Log Analytics soft delete right now, and dispatching Step 3 against it would reproduce ADR-067
Class 2 exactly.** I cannot confirm or refute this from the repository, and I am read-only on live
Azure. It is a live-state question with a one-command answer, so it becomes a hard pre-flight gate
rather than a guess in either direction.

**PC-1SEC (BLOCKER for Step 3, operator/QA lane, read-only check).** Before dispatching Step 3, prove
the workspace is not in soft delete:

```bash
az monitor log-analytics workspace list-deleted-workspaces \
  --subscription <security-sub> \
  --query "[?name=='law-security-globaris-poc'].[name,location,id]" -o tsv
```

**Expect EMPTY output.** A non-empty result is a **STOP**: do not dispatch Step 3.

**Remediation, via CI, not by hand** (the standing rule is that teardown is CI/CD and never manual):
dispatch `teardown.yml` with `target=all`, `mode=az-sweep`, `include_bootstrap=false`, `confirm=destroy`,
from `--ref banking` at or after `2ca1fc5`. On that path:

- every Phase 1 per-root `terraform destroy` job is skipped (each is gated on `inputs.mode ==
  'terraform'`), which is the correct behaviour against an already-empty estate;
- Phase 0 DISARM plus Phase 2 az-sweep run, and az-sweep **step 7b** recovers the soft-deleted
  workspace into a placeholder resource group, force-purges it, confirms it gone with a fail-loud GET,
  then deletes the placeholder;
- Phase 3 VERIFY runs and **fails the run on any estate remnant**.

Then re-run the PC-1SEC query and require empty before dispatching Step 3.

That one dispatch closes three things at once, which is why it is recommended rather than merely
tolerated: it satisfies PC-1SEC, it satisfies PC-1Y (VERIFY is the whole-estate remnant check), and it
exercises the OQ-063 step-7b **backstop**, which OQ-062 item (e) explicitly asks for on the grounds
that the primary native-purge path otherwise hides the backstop forever.

**Two cautions on that dispatch, both hard:**

- `include_bootstrap` **MUST be false**. True is scorched earth and takes the state backend and OIDC
  app with it.
- az-sweep **deletes**; it is not a probe. Against a genuinely empty estate it should be all no-ops plus
  the LAW purge, but it must not be dispatched casually while anything is in flight, and never
  concurrently with any other run that flips the state SA firewall (LESSON 31).

**If the PC-1SEC query comes back empty on the first look, there is no remediation to run and Step 3 is
GO.** The condition is the check, not the teardown.

---

## S4. Lifecycle audit, re-run 2026-07-30 (LESSON 40/41)

The governing audit was run 2026-07-21. That is **9 days old**, inside the 14-day re-audit window, so
this is a targeted re-check of the highest-risk items rather than a full re-derivation. **Next full
re-audit due 2026-08-04** if the dispatch has still not happened by then.

### Re-verified TODAY against current Microsoft sources

| Item | Status 2026-07-30 | Consequence |
|---|---|---|
| **The eight Defender plans this estate enables** (`VirtualMachines` P2, `StorageAccounts` DefenderForStorageV2, `AppServices`, `SqlServers`, `SqlServerVirtualMachines`, `Containers`, `OpenSourceRelationalDatabases`, `CloudPosture`) | **ALL CURRENT and all enablable.** The five plans Microsoft blocked for NEW enablement through the plan-enablement API on 2026-07-05 are exactly: Defender for **Azure Kubernetes Service**, Defender for **Azure Container Registry**, Defender for **Key Vault**, Defender for **DNS**, Defender for **Azure Resource Manager**. **None of the eight is in that set.** | **PASS.** ADR-040 already removed `KeyVaults` and `Arm`; `Dns` was never enabled; `KubernetesService` and `ContainerRegistry` are superseded by `Containers`, which is exactly what `defender.tf` already uses. Step 3's pricing block is clean. |
| Foundational CSPM | Moves to an **opt-in** model on **2026-10-27**, no longer default-enabled for new subscriptions | **No effect on this dispatch.** Future-dated by three months. Relevant only to W2 (FoundationalCspm currently Standard and intentionally untouched). Worth revisiting before any rebuild after October. |
| Microsoft Sentinel | **NOT retired.** Only the **Azure portal experience** is deprecated, redirecting to the Defender portal from 2026-07-01 and retiring 2027-03-31. The `Microsoft.SecurityInsights` ARM surface and every `azurerm_sentinel_*` resource are unaffected | **PASS, with a QA note.** Operators verifying Sentinel objects after Step 3 will be redirected into the Defender portal. That is cosmetic and expected; it is not evidence of a failed apply. |
| App Gateway WAF (online-p1) | App Gateway **v1 retired 2026-04-28** (estate is v2 only). Separately, the **inline WAF configuration on the WAF_v2 SKU** retires **2027-03-15**, superseded by the separate WAF policy object | **PASS.** Verified in code: `landing-zones/online-p1/main.tf` creates an `azurerm_web_application_firewall_policy` and attaches it via `firewall_policy_id`. The estate is already on the surviving model and uses no inline `waf_configuration`. |
| Azure Firewall Premium + Firewall Policy Premium | **CURRENT.** No retirement, no new-enablement block | **PASS.** Unchanged from 2026-07-21. |
| azurerm `features.log_analytics_workspace.permanently_delete_on_destroy` | **Real at the pinned v4.71.0**, Optional, default `false`, destroy-path only | **PASS.** See S3c. |

### Carried forward from the 2026-07-21 audit, NOT re-verified today

VNet flow logs and Traffic Analytics (current; NSG flow logs blocked for new creation since 2025-06-30
and the estate migrated at wave B0c), Standard SKU public IPs, `gpt-5.4-nano` version `2026-03-17`
GenerallyAvailable with inference deprecation 2027-03-18, Recovery Services vault, APIM Developer stv2
(note: APIM trusted-service connectivity retired March 2026, which predates this estate's last green
APIM apply on 2026-07-18/19, so it is already proven post-retirement), Databricks Premium VNet-injected,
Fabric F2, AI Search basic, Static Web App Standard, and the flags that are OFF (`enable_vpn_gateway`,
`enable_dns_resolver`, `enable_bastion`, `enable_ddos_standard`, `enable_sql`, `enable_app_service`,
`enable_synthetic_workload`). Nine days is short and none of these had a pending deprecation dated
inside the window; they are listed so the boundary of today's re-check is explicit rather than implied.

### Module and provider pins

All module pins are registry-immutable and unchanged since the versions that applied green between
2026-07-16 and 2026-07-19. `azurerm` is pinned to **4.71.0** by every root's committed
`.terraform.lock.hcl` and none of those lock files is in the `d3b9e8c..ed3450e` delta. No re-verification
beyond the locks is required.

---

## S5. VERIFIED vs ASSUMED (this replaces R6)

### Verified by me, from the repository, at `ed3450e`

The complete apply-path delta and its per-file disposition (S2); that `envs/poc.tfvars` and every root
except `platform/security` and `bank-app-p1` is unchanged since the original gate basis; that the
`-parallelism=1` conditional has exactly one match point and touches only the apply step; that the
`features` argument is real at the pinned provider version and is destroy-only; that `online-p1` uses
the WAF policy model; that the eight Defender plans are outside the blocked-five set; that az-sweep
step 7b exists, is unconditional within Phase 2, and is reachable at `target=all mode=az-sweep`; that
`teardown-probe.yml` is genuinely read-only.

### NOT verified, because it requires live Azure and I am read-only on it

**Everything below is an operator or QA pre-flight item to be proved BEFORE dispatch. None of it is
asserted here as fact.** The 2026-07-29 addendum leaned on a qa greenfield PASS for this; that PASS now
predates a failed rebuild attempt and can no longer carry the weight.

| ID | What must be proved live | How | Owner | Blocks |
|---|---|---|---|---|
| **PC-1Y** | **The estate is actually greenfield.** The last recorded live event is a FAILED partial apply of `platform/security` (run `30499221661`), and no committed artefact records a teardown after it. Steps 1 and 2 may also have applied before the failure. | Preferred: dispatch `teardown-probe.yml` (read-only, deletes nothing, no `confirm` input) and read the orphan map plus the state-blob inventory. Or accept the Phase 3 VERIFY of the PC-1SEC remediation dispatch, which fails the run on any remnant. Then a qa greenfield confirmation as the standing ADR-058 gate. | qa-engineer / operator | **EVERY root** |
| **PC-1SEC** | The Security LAW is not in soft delete. See S3d for the query, the STOP, and the CI remediation. | `az monitor log-analytics workspace list-deleted-workspaces` | operator | **Step 3** |
| **PC-2R** | The 8 estate-managed Defender plans read `Free` in the security subscription | runbook section 2b, PC-2R row | operator | **Step 3** |
| **PC-1R** | The 12 subscription-scoped teardown survivors are gone (budgets, cost exports, anomaly action, subscription diagnostic setting) | runbook section 2b | operator | Steps 1-2 |
| **PC-3R** | `Microsoft.CostManagementExports` is `NotRegistered` in the management subscription | runbook section 2b | operator | Step 2 |
| **PC-4S** | The soft-deleted APIM instance is gone. **Do not assume the auto-purge fired**; the same soft-delete class is what produced PC-1SEC. | runbook section 2a | operator | Step 9 |
| **PC-1S** | Zero subscription-scoped policy exemptions in the landingzones subscription | Step-8 pre-flight, already in the runbook | operator | Step 8 |
| **Live policy matrix** | Every ancestor MG scope of every target subscription. **Structurally unreadable today**: there is no management group in the tenant except Tenant Root Group until Step 1 creates them. The matrix in section 4 (PC-3C) and section 5 (PC-8S) above remains DERIVED from pinned content, not live-read, exactly as it was on 2026-07-21. | **PC-3C** after Step 1 and before Step 4: `Enable-DDoS-VNET` must read `DoNotEnforce` at BOTH the connectivity and landingzones MGs. Matrix row C1 if not. | operator | Step 4 |
| **Tenant prerequisites** | CI SP role bindings at every scope, resource provider registrations in both subscriptions, federated credentials, licensing for the identity root | Not re-readable by me. Carried as **W1**: Step 1 IS the live confirmation and fails loud there before any estate resource is touched. Do not pre-grant speculatively. | operator | Step 1 |
| **Subscription OFFER caps and quota** | vCPU headroom in eastus2/centralus, and the OFFER restrictions that are distinct from quota (SQL `ProvisioningDisabled`, App Service dedicated-quota-0) | Carried from PC-5S. The two offer-capped tiers are gated OFF by flag (`enable_sql`, `enable_app_service` both false), so an offer cap cannot break a spoke; every spoke remains shippable network-only. Quota headroom was measured 2026-07-21 with large margin and nothing has consumed it since. Re-measure only if PC-1Y shows the estate is not empty. | operator | Steps 5-9 |
| **GitHub known-issues sweep** | Open azurerm / AVM issues affecting these roots at 4.71.0 | Partially done: I checked the `azurerm_security_center_subscription_pricing` 409 class specifically (no provider-side fix pending, so `-parallelism=1` is durable). **I did not sweep the full issue set for the other nine roots.** Named here rather than implied. | architect / operator, before dispatch | advisory |

---

## S6. The dispatch sequence

**The runbook is `docs/2026-07-22-full-estate-rebuild-runbook.md` and it remains the executable
document. Do not duplicate it. Its 14-step order, its per-step commands, its plan-scan bars and its
STOP/rollback matrix all stand.** This refresh changes exactly four things about it.

**Amendment 1 - a Step 0 is prepended.**

```
STEP 0 (new, this refresh):
  0a. PC-1Y: dispatch teardown-probe.yml (read-only) and read the orphan map + state-blob inventory.
  0b. PC-1SEC: az monitor log-analytics workspace list-deleted-workspaces  ->  expect EMPTY.
  0c. If 0a shows remnants OR 0b returns a row:
        dispatch teardown.yml  target=all  mode=az-sweep  include_bootstrap=false  confirm=destroy
        --ref banking  (must be at or after 2ca1fc5).
        Require Phase 3 VERIFY green. Then re-run 0a and 0b and require clean/empty.
  0d. qa greenfield confirmation (ADR-058 standing gate).
  Only then: Step 1.
```

**Amendment 2 - Step 3's duration expectation.** "Duration ~15 min" becomes **"budget 25-45 min"**
(PC-3SEC, S3b). The plan-scan bar for Step 3 is UNCHANGED: pure adds, roughly 48, `0 change,
0 destroy, 0 replace, 0 import`, exactly 8 pricing adds, zero pricing resources named `KeyVaults`,
`Arm`, `Dns`, `KubernetesService` or `ContainerRegistry`, Key Vault and Event Hub namespace carrying
NEW random suffixes.

**Amendment 3 - STOP matrix row B6 is WRONG and must be corrected.** It currently reads "Sentinel
onboarding 409 already onboarded -> config-driven IMPORT of the onboarding resource, then remove the
import block once adopted." That disposition was superseded on 2026-07-29 by the user's process change
and by ADR-067: **recovery is a full estate teardown and a restart from Step 1. There is no
import-and-continue and no partial-state reconciliation.** Corrected disposition: any "already exists /
needs to be imported" on the onboarding resource **or on any `Microsoft.SecurityInsights` child** means
**PC-1SEC did not actually hold** and the workspace was recovered from soft delete. **STOP.** Do not
import. Complete the LAW purge, then restart.

**Amendment 4 - STOP matrix row B7 is now too permissive.** It reads "Sentinel connector or automation
rule 400 workspace not onboarded -> wait, then exactly one rerun." That was the ADR-033 misdiagnosis
ADR-067 corrected: for the two automation rules it was never transient, it was a missing `depends_on`,
and that edge is now in the code. Corrected disposition: with the ADR-067 fix on the dispatched ref, a
400 "not onboarded" **on either automation rule** is NOT transient. **STOP** and confirm the dispatched
`headSha` actually carries the `depends_on` (LESSON 33). The "wait then one rerun" disposition still
applies to the MDC automation and the data connectors, which are a genuine RP-propagation class.

**Unchanged and load-bearing:** ADR-060 sequential single-target dispatch, one run in flight at a time,
never `target=all` for apply; `--ref banking` on every dispatch; plan then scan then apply per root;
PC-2X after Step 2; PC-3X and PC-4C after Step 4; the identity two-pass override on Steps 10-11 only;
U1 (any `-/+` replace or unexpected destroy is a hard STOP) and U5 (a second identical failure on one
root after one clean retry is a HARD STOP, counting toward the project's 4-failure bar).

---

## S7. Findings handed to other roles (NOT fixed here, docs-only pass)

| # | Finding | Owner | Severity |
|---|---|---|---|
| F1 | Runbook STOP-matrix rows **B6** and **B7** carry dispositions superseded by ADR-067. Exact replacement text is in S6 amendments 3 and 4. | devsecops-engineer | **Should land before dispatch.** An operator following B6 today would import into a state ADR-067 says must be rebuilt. |
| F2 | Runbook Step 3 says "Duration ~15 min", which is wrong after `-parallelism=1`. Replace with "budget 25-45 min" plus a line saying a still-running Step 3 at minute 20 is not hung. | devsecops-engineer | Low, but it invites a wrong cancel. |
| F3 | **`-parallelism=1` is applied to the apply step only, not the destroy step.** Destroying `azurerm_security_center_subscription_pricing` resets the plan to `Free`, which is the SAME subscription-level pricing write that 409s under concurrency. Eight of them destroy concurrently at the default parallelism of 10 during ADR-066 Phase 1's `security` layer destroy, which has **never been run live** (OQ-062 states all-layers-green is proven by reasoning only). Consider keying the flag on the root for `destroy` as well as `apply`. | devsecops-engineer | Medium. Not a blocker for this apply; a plausible first failure of the ADR-066 teardown. |
| F4 | **`teardown-probe.yml` has no soft-delete class.** It probes extension resources and state blobs but never queries `list-deleted-workspaces`, APIM `deletedservices`, deleted Key Vaults or deleted Cognitive Services accounts. Every one of those is a proven rebuild-blocker class in this repo (PC-1SEC, PC-4S). Adding them would turn two hand-typed `az` pre-flights into one read-only CI probe. | devsecops-engineer | Medium. Directly addresses the class that produced this refresh's only conditional verdict. |
| F5 | `DEPLOYMENT.md` section 3 Step 5 still lists `PLATFORM_LAW_CUSTOMER_ID` as a `platform/security` secret; section 3 Step 3 still describes connectivity as creating a VPN Gateway and DNS Private Resolver. Both were identified as false on 2026-07-21 and are still uncorrected. | technical-writer | Low, documentation only. |

---

## S8. Decisions and open items

- **No new ADR.** This refresh introduces no new decision. ADR-060 (sequential single-target) and
  ADR-061 (Secret determinism) still govern; ADR-066 and ADR-067 are correctly implemented and are
  confirmed here rather than revised.
- **ADR-worthy, deliberately NOT written this pass to hold scope:** the generalization behind PC-1SEC,
  that a **purge-on-destroy mechanism is teardown-side and can never repair a rebuild whose teardown
  predates it**, so every pre-clearance must carry an explicit soft-delete-recovery sweep across every
  soft-deleting type in the estate (Log Analytics workspace, Key Vault, API Management, Cognitive
  Services). Recorded as a follow-up under OQ-064 so it is not lost.
- **OQ-064 is RESOLVED by this document**, both limbs. See `OPEN-QUESTIONS.md`.
- **OQ-062 remains open** and this dispatch is part of its proof: item (e) is exercised by the PC-1SEC
  remediation dispatch if one is needed, and item (f) is closed by a Step 3 that creates a fresh
  workspace with zero "already exists" on any `Microsoft.SecurityInsights` child.
- **Watch-item carried unchanged from R1:** promote `banking` to `main`, or block `main` from
  `deploy.yml` dispatch, as a post-rebuild cleanup. Related to OQ-057.

---

## Proposed commit message (refresh #2)

```
docs(preclearance): 2026-07-30 refresh #2 - land the rescued 2026-07-29 addendum and re-clear the
full-estate rebuild against ed3450e; platform/security drops to GO-CONDITIONAL on PC-1SEC (the ADR-067
Class 2 LAW soft-delete is closed only on the teardown path, and every recorded teardown predates
2ca1fc5), PC-1Y greenfield re-proof gates every root, ADR-067 parallelism and depends_on verified inert
on plan, Defender plan set re-audited clean against the blocked-five list; closes OQ-064
```

---

# 2026-07-31 REFRESH #3 - re-clearance against `banking` @ `7fc8930`, with `centralus` as PRIMARY (ADR-069)

**Date:** 2026-07-31
**Author:** cloud-solutions-architect
**Type:** REFRESH of all three sections above. Append-only: nothing above this line was edited.
**Repo state this refresh was computed against:** `banking` @ `7fc8930`. Written on branch
`docs/preclearance-refresh-2026-07-31-centralus`, cut off `banking` at `7fc8930`.
**Supersedes:** the per-root verdict table in refresh #2 (S0). S1 through S8 are otherwise carried,
amended where stated in T1.
**Basis moved:** `ed3450e` -> `7fc8930`, three merges: PR #59 (`f34c4b7`, teardown hardening),
**PR #60 (`fbb8e3f`, commit `91523dc`, the ADR-069 region flip, 39 files)** and PR #61 (`7fc8930`,
worklog only).

---

## Why refresh #3 exists, and why a carry-forward is inadmissible

Refresh #2 cleared an apply path whose primary region was `eastus2`. That path no longer exists.
Three things changed underneath it:

1. **Both of refresh #2's conditions were discharged LIVE on 2026-07-31.** PC-1SEC and PC-1Y both
   passed, Step 3 `platform/security` applied green with zero Class-1/2/3 failures, and Steps 1 and 2
   went green before it. The GO-CONDITIONAL was resolved by execution, not by re-reasoning.
2. **That estate was then torn down deliberately, for the flip.** So refresh #3 starts from a
   genuinely greenfield estate, which is the strongest possible starting position and is also the
   only position in which the flip is safe at all: on a LIVE estate the AVM hub module derives
   `fw-hub-${location}-001` and the flip would force-replace both Premium firewalls, both policies
   and every hub route table, which is the unconditional STOP of LESSON 26 and runbook Rule 1.
3. **PR #60 changed the apply path in every root.** Not by much, and T2 quantifies exactly how much,
   but a pre-clearance that cannot see it is worthless.

**One framing correction, carried from the 2026-07-31 WORKLOG close and repeated here because it
changes what this document has to check.** ADR-069's Context frames the flip as "four eastus2 capacity
workarounds accumulated". The user corrected that and the correction is the accurate one: **the
binding constraint was AI Search.** `eastus2` returned `InsufficientResourcesAvailable`, Search could
only be obtained in `centralus`, and it was already deployed there behind a cross-region private
endpoint pinned back to an `eastus2` spoke. The estate's most constrained service was living in the
secondary region. vCPU quota, App Service and SQL were symptoms, not the cause. This is why the
`search_location` carve-out retires **by construction** rather than inverting, and it is why RC-1
passing with no improvement in the vCPU limit is not a contradiction of the flip's rationale.

**And one thing no gate here would have caught, stated so nobody builds a false confidence on this
document.** The wrong region was found by the user looking at the portal and seeing the primary
firewall in East US. `primary_location = "eastus2"` was internally consistent, so pre-clearance
passed, every plan-scan passed, `validate` passed and three applies went green. These gates verify
internal consistency, not correspondence with intent. No tightening of them would have caught it.

---

## T0. VERDICT

**Whole-run verdict: GO-CONDITIONAL. There is no NO-GO, no open code blocker, and no root whose
region behaviour I could not resolve from pinned sources.**

The conditional load is materially LOWER than refresh #2's, because the two whole-run gates that
carried it (PC-1Y and PC-1SEC) are now discharged from live read-only evidence gathered today, and
five of the seven ADR-069 verification checks (RC-1 through RC-5) were run live and passed. What
replaces them is smaller and more specific: **three new conditions, all read-only, all cheap, all
caused by the flip.**

### The three new conditions

| ID | What must be proved | Command shape | Blocks | Why the flip creates it |
|---|---|---|---|---|
| **PC-1REG** | **No `listOfAllowedLocations` (or resource-group equivalent) policy assignment exists at Tenant Root Group scope whose allowed set excludes `centralus`.** | `az policy assignment list --scope /providers/Microsoft.Management/managementGroups/<tenant-root> --disable-scope-strict-match --query "[?contains(to_string(parameters),'listOfAllowedLocations')]" -o json` -> expect empty | **Step 2** and every later root | This is RC-7, PROMOTED from "non-blocking, at leisure, after Step 1, at the `globaris` scope" to **BLOCKING, before Step 2, at Tenant Root Group**. Rationale in T5 amendment 1. Under `eastus2`-primary this risk was silently discharged by three green applies; under `centralus`-primary it is not. A Deny of this class passes `validate`, passes `plan`, and fails at the first resource-group PUT. |
| **PC-2REG** | **Each of the five plan bars is RE-MEASURED against `centralus`-primary and the actual recorded, before that root's apply.** 537 / 36 / 48 / 696 (Steps 1-4) plus 26 (Step 10 identity Pass 1). **Step 1 is now DISCHARGED** (run `30636497926`, `banking` @ `7fc8930`: **537 to add, 0 change, 0 destroy, 0 replace, 0 import**, 2 min 36 s - an exact match, not an approximate one). Four remain. | the plan dispatch ADR-060 already mandates; read `Plan: N to add` | **every remaining root** | T3 certifies all five as expected-unchanged from pinned module sources. That certification is exactly what makes a delta informative. **A delta of even ONE against a bar certified unchanged is a STOP requiring a fresh architect disposition, never a silent bar update.** A delta means something region-conditional exists that T3 did not find, and that is precisely the information the bar exists to surface. **Do not generalise from Step 1's exact match:** `platform/management-groups` contains no regional resources at all, which makes it the weakest available test of the construction argument. The roots that carry regional names and locations (2, 3, 4, 10) are where a delta could hide. |
| **PC-3REG** | **Service availability in `centralus` for the six provider surfaces the spokes need.** APIM `service`, Databricks `workspaces`, Service Bus `namespaces`, Event Hub `namespaces`, App Gateway (`Microsoft.Network`), Log Analytics `workspaces`. | `az provider show --namespace <ns> --query "resourceTypes[?resourceType=='<type>'].locations"` | **Steps 5-9** | This is RC-6, PROMOTED from "non-blocking, run at leisure" to **BLOCKING before Steps 5-9**. Six read-only commands against a Step 9 that costs 60 to 180 minutes and, if APIM is unavailable, leaves a soft-deleted instance behind that reproduces PC-4S for the next rebuild. The cost asymmetry is not close. |

### Carried conditions, unchanged in substance

PC-2R (the 8 estate-managed Defender plans read `Free`), PC-3C (`Enable-DDoS-VNET` reads
`DoNotEnforce` at BOTH the connectivity and landingzones MGs, after Step 1, before Step 4), PC-2X
(re-set `PLATFORM_LAW_CUSTOMER_ID` after Step 2), PC-4C (the 89 zones plus the 11 the spokes look up,
after Step 4), PC-3X (firewall private IPs `10.0.0.4` / `10.1.0.4`), PC-1S (zero subscription-scoped
policy exemptions, before Step 8), PC-4S (APIM soft-delete gone, before Step 9), PC-5X (the
`enable_acr_kubelet_binding` gate present and the tfvars flip NOT yet merged, before Step 9), PC-1H
and PC-2H (Steps 13-14). T5 states which of these change shape under the flip. Only PC-2X, PC-4S and
the corp-a2 shape row carry text that is now wrong; none changes behaviour.

### PC-4REG - a WATCH-ITEM, explicitly not a blocker

**RC-1 passed with zero headroom, and the pass is not the finding.** Central US carries the **same
10-vCPU Total Regional limit** that constrained `eastus2`, and the `standardDSv4Family` limit is also
10. Measured 10 / 10 / 10 on 2026-07-31. What that means for the AKS steps, concretely:

- AKS is pinned at 3 x `Standard_D2s_v4` = **6 of 10 regional vCPUs steady**, `max_surge = "1"` =
  **8 of 10 during an upgrade** (`landing-zones/bank-app-p1/aks.tf`, ADR-043). It fits, with 2 vCPUs
  of margin at peak.
- **It fits only because nothing else in the estate draws regional vCPU in `centralus`.**
  `enable_sql` and `enable_app_service` are both false (ADR-031 / ADR-032, NOT lifted by the flip -
  offer caps attach to the subscription, not the region, LESSON 42). Databricks ships with zero
  clusters. `enable_synthetic_workload` is false. AKS user pools are quota-blocked at POC per OQ-043.
  Any change to any of those during this rebuild consumes AKS's margin.
- **The flip bought service availability, not compute capacity.** The 2026-07-18 quota increase
  (OQ-043) was filed for `eastus2` and quota is per-region, so it does not carry over. If this
  rebuild ever needs more than 10 regional vCPUs in `centralus`, it hits the identical wall.
- **Pre-agreed disposition if Step 9 returns a quota error on the AKS create:** do NOT retry
  (LESSON 59, matrix U5). Set `enable_kubernetes_platform = false` for this rebuild via a reviewed
  one-line tfvars PR and ship `bank-app-p1` network-only, which is exactly what the
  shippable-network-only pattern exists for (LESSON 42), and file a `centralus` quota increase in
  parallel.

### Per-root verdict table, re-cleared against `7fc8930`

| # | Root | R#2 verdict | **R#3 verdict** | Basis, and what the flip changed |
|---|---|---|---|---|
| 1 | `platform/management-groups` | GO | **GO** | **R#2 verdict holds and is now stronger:** its gating condition PC-1Y is DISCHARGED live today (MGs at Tenant Root only, no estate RGs in any of 5 subscriptions, all 11 state blobs at the empty baseline). Flip surface in this root is one attribute: `location` on `avm-ptn-alz` 0.19.1, plus an `amba_alz_resource_group_location` default value that is not even in the graph while `enable_om_phase1 = false`. `lib/globaris.alz_architecture_definition.json` carries **zero** region literals (verified). Watch W3 (MG-budget collision provable only at this apply) carried unchanged. **PC-2REG DISCHARGED for this root: plan run `30636497926` at `7fc8930` measured 537 / 0 / 0 / 0 / 0 under `centralus`-primary, an exact match to the `eastus2`-primary bar.** |
| 2 | `platform/management` | GO | **GO-CONDITIONAL** | **Tightened by the flip, on PC-1REG only.** Step 2 creates `rg-management-globaris-poc`, which is **the estate's first resource-group PUT into `centralus` under this configuration**. An allowed-locations Deny permitting `eastus2` and not `centralus` fails HERE, with a clean plan and no plan-time signal. Step 1 creates no resource group, so Step 1 going green proves nothing about it. Otherwise unchanged: 11 plain `location =` attributes, no count or `for_each` touched. PC-2X carried (text correction in T5). |
| 3 | `platform/security` | GO-CONDITIONAL (PC-1Y, PC-1SEC, PC-2R) | **GO-CONDITIONAL (PC-2R only)** | **Two of three conditions DISCHARGED live today.** PC-1Y discharged. **PC-1SEC discharged on BOTH halves:** zero soft-deleted workspaces on the security subscription, zero live workspaces, and `rg-security-globaris-poc` does not exist at all, which satisfies the second half the runbook added on 2026-07-30 after a soft-delete query alone read as a false PASS. PC-2R (the 8 Defender plans read `Free`) is **not** covered by today's evidence and remains the single open condition. ADR-067's `depends_on` and `-parallelism=1` are unaffected by the flip (both are graph and CLI concerns, not regional). Region surface is 7 plain `location =` attributes. |
| 4 | `platform/connectivity` | GO | **GO-CONDITIONAL** | PC-3C carried unchanged (region-independent: `Enable-DDoS-VNET` is checked by assignment name at two MG scopes and is created by Step 1 from a region-literal-free library). **This is the root the flip touches hardest and it still comes out clean:** the firewall, policy and route-table NAMES swap between the two hubs (`fw-hub-eastus2-001` and `fw-hub-centralus-001` exchange places), which is free on greenfield and would be a ForceNew replace on a live estate. The 696 bar is certified expected-unchanged in T3 from three independently checked mechanisms. Subject to PC-2REG. |
| 5 | `landing-zones/corp-a1` | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-4C after Step 4, unchanged. Plus **PC-3REG**. The spoke moves `eastus2` -> `centralus`; the RSV stays `ZoneRedundant` and Central US has availability zones. `data.azurerm_network_watcher` now resolves `NetworkWatcher_centralus`, re-confirmed live today. |
| 6 | `landing-zones/corp-a2` | GO-CONDITIONAL | **GO-CONDITIONAL** | as corp-a1, plus the largest semantic change of any spoke: **corp-a2 was the DR spoke in `centralus` and is now the DR spoke in `eastus2`.** RSV stays `GeoRedundant` (Central US and East US 2 are a symmetric Azure pair, so geo-redundancy survives the swap intact). Traffic Analytics stays DISABLED on its flow log, and the reason inverts with **zero code change** (see T2). `data.azurerm_network_watcher.secondary` now resolves `NetworkWatcher_eastus2`, re-confirmed live today. |
| 7 | `landing-zones/online-p1` | GO-CONDITIONAL | **GO-CONDITIONAL** | as corp-a1. App Gateway WAF_v2 and the Static Web App both move to `centralus`; Static Web Apps' allowed region set includes `centralus` (verified at ADR-069 time). App Gateway availability is inside **PC-3REG**. |
| 8 | `landing-zones/bank-data-p1` | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-1S re-confirm before dispatch, unchanged. **The flip IMPROVES this root:** the ADR-051 cross-region private endpoint stops existing (service and PE NIC are both `centralus`), and deviation register entries d6 (Fabric) and d7 (Search) retire by construction. RC-3 discharged live (`gpt-5.4-nano` `2026-03-17` `DataZoneStandard`, GA not Deprecating, in the `centralus` catalog). Databricks availability is inside **PC-3REG**. |
| 9 | `landing-zones/bank-app-p1` Pass 1 | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-4S, PC-5X, tfvars-flip-not-early, all carried. Plus **PC-3REG** (APIM, Service Bus, Event Hubs) and the **PC-4REG** quota watch. RC-4 discharged live (`Standard_D2s_v4` in `centralus`: zones 1,2,3, no restrictions), which is load-bearing because the pool pins `availability_zones = ["1","2","3"]`. The AKS control-plane UAI role assignment now targets `privatelink.centralus.azmk8s.io`, derived from `var.primary_location`, never a literal. |
| 10 | `platform/identity` Pass 1 | GO | **GO** | **The load-bearing root of the entire flip, and it clears.** `identity_location` flipped to `centralus` in BOTH the root default and, for the first time, in `envs/poc.tfvars`. Left at `eastus2` this was the failure that produced a clean plan, a green apply, and the identity pillar plus an unmovable AADDS managed domain stranded in the DR region. **RC-2 discharged live: Entra Domain Services supports Central US** (and East US 2). ADR-055 two-pass unchanged. Subject to PC-2REG (the 26-add Pass 1 bar). |
| 11 | `platform/identity` Pass 2 | GO | **GO** | as Pass 1, `enable_conditional_access_override=true`. Entra objects are tenant-scoped and carry no region, so the "exactly ten pure adds" bar is region-independent by construction. |
| 12 | `landing-zones/bank-app-p1` Pass 2 | GO-CONDITIONAL | **GO-CONDITIONAL** | unchanged. The reviewed one-line `envs/poc.tfvars` flip merged AFTER Step 9 is green. |
| 13 | `platform/management` (B7) | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-1H unchanged. One flip consequence worth stating: `amba_alz_resource_group_location` now resolves to `centralus`, so `rg-amba-monitoring-001` lands in `centralus`. That is correct and intended, and it is a second resource-group-create-in-`centralus` surface, so it inherits **PC-1REG**. |
| 14 | `platform/management-groups` (B7) | GO-CONDITIONAL | **GO-CONDITIONAL** | PC-1H plus PC-2H, unchanged. |

**Movement summary:** one root improves (3, security: three conditions down to one), two tighten
(2 and 4, both on new region conditions), eleven hold. No root moved to NO-GO and none is close to it.

---

## T1. What refresh #2 still carries, and what it does not

| Section | Status at 2026-07-31 | Basis |
|---|---|---|
| **S0** verdict table | **SUPERSEDED by T0.** Both its gating conditions are discharged. | live evidence, this refresh |
| **S0** PC-1Y definition (two halves, FM-1 / FM-2 asymmetry) | **CARRIED and reaffirmed as the right shape.** It is region-agnostic and it worked: today's check passed both halves, with ten blobs at 152-153 bytes and `platform/identity` at 181 (its natural floor under ADR-068 carve-out A). One text correction to the runbook's restatement, T5 amendment 4. | T5 |
| **S1** carry-forward table from the 2026-07-29 addendum | **CARRIED**, with R3 further amended: there IS more apply-path drift now, fully enumerated in T2. | T2 |
| **S2** apply-path drift `b6db5d0..ed3450e` (four files) | **CARRIED as history.** Superseded as the current drift statement by T2, which covers `ed3450e..7fc8930`. | T2 |
| **S3a** ADR-067 Class 3 `depends_on` closed on the apply path | **CARRIED unchanged.** `depends_on` is a graph edge; region is not in the graph. `platform/security/sentinel.tf` is not in the PR #60 diff. | `git diff fbb8e3f^ fbb8e3f` |
| **S3b** Class 1 `-parallelism=1` wired into the apply step, PC-3SEC 25-45 min budget | **CARRIED unchanged, and now LIVE-PROVEN.** Step 3 applied green on 2026-07-31 with zero Class-1/2/3 failures. `_tf-root.yml` is not in the PR #60 diff. | live run plus diff |
| **S3c** `permanently_delete_on_destroy` inert at apply | **CARRIED unchanged.** `platform/security/providers.tf` is not in the PR #60 diff. | diff |
| **S3d** PC-1SEC | **DISCHARGED, both halves, live today.** Retired as a condition; the check itself stays in Step 0 because it is one command and the class recurs. | live evidence |
| **S4** lifecycle audit (2026-07-30, next full re-audit due 2026-08-04) | **CARRIED, with a targeted region delta in T4.** Still 1 day old, well inside the 14-day window. Nothing in the audit was region-parameterised. | T4 |
| **S5** verified-vs-assumed | **REPLACED by T6**, which promotes most of it from assumed to verified. | T6 |
| **S6** the dispatch sequence and its four amendments | **CARRIED**, with six further amendments in T5. Step 0 stands; amendments 2 (Step 3 duration), 3 (STOP row B6) and 4 (STOP row B7) all stand unchanged and are region-independent. | T5 |
| **S7** findings F1 to F5 handed to other roles | **F1 and F2 are LANDED** (STOP rows B6 and B7 and the Step 3 duration are corrected in the runbook, verified in the file today). **F3, F4, F5 remain OPEN** and are re-stated in T8 with the flip's additions. | runbook, read today |
| **S8** decisions and open items | **CARRIED.** OQ-064 stays resolved. OQ-062 is now partly proven by the 2026-07-31 green Step 3. | T9 |

---

## T2. Apply-path drift `ed3450e..7fc8930`, file by file

Three merges. Two of them are off the apply path in one line each:

- **PR #59 (`f34c4b7`), teardown hardening.** `az_run_retry` for 5xx/429 on **reads only** (never on
  a delete, never when `is_auth_error` matches, so ADR-063 section 9.4 is preserved: a failed list is
  still never read as clean and a 403 can be neither retried nor swallowed), plus the Key Vault
  purge-protection boolean compare fix. **Entirely in `scripts/` and `teardown.yml`. Zero apply-path
  surface.** Consequential for the NEXT teardown, not for this rebuild.
- **PR #61 (`7fc8930`).** `WORKLOG.md` only.

**PR #60 (`91523dc`, merged `fbb8e3f`) is the whole of the drift. 39 files. The single most useful
sentence about it is this: exactly ONE of the 39 changes what gets PUT.**

| Class | Files | What changes | Effect on the apply |
|---|---|---|---|
| **A. Changes what gets PUT** | **1**: `envs/poc.tfvars` | `primary_location` `eastus2` -> `centralus`; `secondary_location` `centralus` -> `eastus2`; **three NEW declarations** `identity_location`, `fabric_location`, `search_location`, all `centralus` | **This is the entire functional change of the flip.** Every CI path (`_tf-root.yml` line 351 plan, 366 apply, 397 destroy; `plan-on-pr.yml`) passes `-var-file=envs/poc.tfvars`, so these five values are authoritative for every root. |
| **B. Changes a default that A overrides on every CI path** | **11** `variables.tf`: management-groups, management, security, connectivity, identity, bank-app-p1, bank-data-p1, corp-a1, corp-a2, online-p1, synthetic - carrying 13 `default =` changes | 13 default values realigned | **Zero effect on any CI plan or apply.** A tfvars value beats a root default unconditionally. These exist so a local `terraform plan` run WITHOUT `-var-file` targets the right region, which is the same defect class as `identity_location` itself. `bank-data-p1`'s `fabric_location` and `search_location` defaults were already `centralus` and did not move. |
| **C. Comments and variable descriptions** | **27**: `bootstrap/main.tf`, `envs/poc.backend.hcl`, and 25 `.tf` files across connectivity (7), corp-a2 (4), bank-data-p1 (4), bank-app-p1 (3), synthetic (3), corp-a1 (2), online-p1 (2) | prose | **Zero effect.** Terraform does not evaluate comments, and a `description` on a variable has no plan or apply semantics. |

### The named files, at S2's level of specificity

**`platform/identity/variables.tf` (14 lines) - the load-bearing one, and it is correct.**
`identity_location` default `eastus2` -> `centralus`, description rewritten to a heredoc that states
the constraint. This root **declares no `primary_location` at all**, which is exactly why the default
was live: the load-bearing-versus-cosmetic test is "a root default is load-bearing if and only if
`envs/poc.tfvars` declares no variable of that name", and until PR #60 `envs/poc.tfvars` declared no
`identity_location`. The variable reaches six sites, all plain `location =` attributes: the identity
VNet, both subnets by inheritance, the AADDS managed domain (`domain-services.tf:100`) and the
identity RSV (`domain-services.tf:244`). **What gets PUT changes: the unmovable AADDS managed domain
now builds in `centralus`.** The `initial_replica_set` block carries only `subnet_id` and inherits the
domain's region, so there is no second region input to keep in step. Belt and braces are both present:
the default now matches and the tfvars entry now exists, so a local plan and a CI plan agree.
**RC-2 discharged this live.** The AADDS domain name `aadds.globaris.org` is tenant-scoped and carries
no region token, so there is no naming interaction with any prior instance.

**`landing-zones/bank-data-p1/ai.tf` (45) and `variables.tf` (43) - the largest per-file deltas, and
both are essentially prose.** Not one `default =` in `ai.tf`, and one in `variables.tf`
(`primary_location`, class B). What actually happened is that two DEVIATION notes were converted into
KEEP-THIS notes, which is the right direction and worth checking rather than trusting:

- The AI Search `search_location` carve-out is now **numerically redundant**
  (`search_location == primary_location == centralus`). ADR-069 decision 5 keeps the variable and the
  implementation keeps it. Correct: it is the proven escape hatch, and deleting a mechanism the moment
  its trigger stops firing is how the lesson gets un-learned.
- **The Search private endpoint's `location = var.primary_location` override is KEPT, and this is the
  single most important line in the two files.** It is numerically a no-op today. It is load-bearing
  the moment the two values differ again: the pinned Search module v0.3.0 consumes the per-PE location
  as `coalesce(each.value.location, var.location)`, so without the override the NIC falls through to
  the SERVICE region and collides with `snet-private-endpoints`, which is the literal failure of apply
  `29678062833`. The comment now says DO NOT DELETE, with the reason. Verified present at `7fc8930`.
- Same shape for `fabric_location` in `fabric.tf`. Deviation register entries **d6 and d7 retire by
  construction**, not by action.

**`landing-zones/corp-a2/*` (25 lines in `dns_links.tf`, plus main, outputs, providers, variables) -
the DR spoke swaps regions, and the one asymmetry inverts with zero code change.** `secondary_location`
default `centralus` -> `eastus2` (class B). Everything else is prose. The interesting part is the
Traffic Analytics comment block: TA stays DISABLED on this spoke's flow log and the REASON inverts.
Before: "the only LAW is in eastus2 and there is no centralus LAW". After: "the only LAW is in
centralus and there is no eastus2 LAW". **The asymmetry itself is unchanged, because the estate still
has exactly one platform LAW and it follows the primary region.** No `traffic_analytics` block is
added or removed, so this root's plan shape is identical. The flow-log storage account and the
`data.azurerm_network_watcher.secondary` lookup both follow `var.secondary_location` and now resolve
in `eastus2`. **`NetworkWatcher_eastus2` re-confirmed live today.**

**`bootstrap/main.tf` (19) and `envs/poc.backend.hcl` (7) - comment blocks ONLY. I checked this
specifically and it is clean.** Neither file changes a single value.
`bootstrap/variables.tf:44 primary_location` is still `"eastus2"` and **is not in the diff at all**.
`envs/poc.backend.hcl` still reads `resource_group_name = "rg-tfstate-mgmt-eus2-001"`,
`storage_account_name = "stglobaristfstate01"` and `container_name = "tfstate"`, unchanged.
**Nothing in the diff moves bootstrap, and nothing changes the backend the deploy roots initialise
against.** The added comments record why: the state key vault is purge-protected with 90-day
retention, so a delete would block the vault name for 90 days (LESSON 57 class, no retry recovers it);
state is a management-plane dependency with no data-plane coupling; and anti-correlation is the better
posture, because keeping state out of the primary workload region means a `centralus` regional event
still leaves state readable. The bootstrap comment also records the fact the implementer established
independently and the ADR had not stated: **bootstrap receives no `-var-file` from any workflow, so
its default is genuinely live** and must not be flipped. That is the correct reason, written down.

### Three deliberate non-changes, each of which reads as an obvious tidy-up

Recorded so a future reader does not "fix" them:

1. **`bootstrap` stays `eastus2`** and is absent from the value diff, for the reasons above.
2. **ADR-031 and ADR-032 gates stay `false`.** `enable_sql` and `enable_app_service` are not in
   `envs/poc.tfvars` at all, so the root defaults govern and both remain `false`. Their descriptions
   were updated to say explicitly that ADR-069 does NOT lift them, because the restriction attaches to
   the subscription OFFER, not the region (LESSON 42; ADR-032 proved `eastus2` compute quota was
   healthy, so the App Service failure was never regional).
3. **The Search PE `location` override stays** despite becoming numerically redundant.

### The one thing in class A that deserved a second look, and clears

Adding `identity_location`, `fabric_location` and `search_location` to `envs/poc.tfvars` means those
three values are now supplied to **all eleven roots**, and only one or two roots declare each. Ten
roots therefore emit `Warning: Value for undeclared variable` on every plan and apply.

**This is safe, and it is proven safe rather than reasoned safe.** Terraform errors on an undeclared
variable supplied via `-var` on the command line but only WARNS for one supplied via `-var-file`.
`envs/poc.tfvars` has carried root-specific variables that most roots do not declare since the
scaffold (`identity_domain_name`, `appgw_capacity`, `enable_fabric_capacity`,
`bank_app_p1_spoke_address_space` and others) across every green apply this estate has ever had.
`_tf-root.yml` uses no `-detailed-exitcode` and no warning-to-error escalation on the plan or apply
steps, so a warning cannot fail a run. **No behaviour change.**

---

## T3. The plan bars, assessed from the pinned module sources

ADR-069 decision 9 claims the bars hold by construction. **I assessed that claim rather than
inheriting it, and it holds for all five, with one honest caveat inside the Step 4 assessment.**

Classification used: **(a)** expected to hold unchanged, **(b)** expected to move by a stated
predictable delta, **(c)** genuinely unknown, must be re-measured before its apply with no prediction.
**No bar in this estate falls into (b) or (c).** Where that conclusion could be wrong, T3 says so
explicitly rather than rounding it away.

| Step | Root | Bar | Class | Derivation |
|---|---|---|---|---|
| 1 | `platform/management-groups` | **537 adds** | **(a) unchanged - and now EMPIRICALLY CONFIRMED** | `var.primary_location` reaches exactly two places in this root. (i) `amba_policy_default_values.amba_alz_resource_group_location` - consumed ONLY when `enable_om_phase1 = true`, which is `false` at Step 1, so the AMBA architecture is not selected and this value is not in the graph. (ii) `module.alz_management_groups.location` on `Azure/avm-ptn-alz` 0.19.1, where `location` sets the location attribute of policy-assignment managed identities. It is **not** a `for_each` key, **not** a `count`, and **not** a filter. The address set is generated from `lib/globaris.alz_architecture_definition.json`, which I grepped for region strings and which contains **none**. No `listOfAllowedLocations` parameter is set anywhere in the repository. **Predicted exactly 537. Measured exactly 537** (run `30636497926`, 2 min 36 s, 0 change / 0 destroy / 0 replace / 0 import). |
| 2 | `platform/management` | **36 adds** | **(a) unchanged** | `var.primary_location` appears 11 times, every one a plain `location =` attribute on a resource that exists unconditionally (RG, platform LAW, Automation Account, action group, budgets, cost exports, dashboard, workbook). No count, no `for_each`, no conditional expression consumes it. Checked specifically for the Azure Automation linked-workspace region-mapping constraint, which IS region-pair-sensitive: **the repo creates no `azurerm_log_analytics_linked_service`** (that resource appears only in module-cache examples), and the Automation Account is joined to the LAW by a diagnostic setting, which is cross-region-safe. **36 must be exactly 36.** |
| 3 | `platform/security` | **~48 adds** | **(a) unchanged** | 7 plain `location =` attributes (RG, Security LAW, Key Vault, Event Hub namespace, two Defender-adjacent resources, one Sentinel-adjacent resource). Everything else in this root is subscription-scoped (the 8 Defender pricing PUTs), workspace-scoped (Sentinel onboarding, 10 scheduled alert rules, the connectors, 2 automation rules) or MG-scoped (2 policy assignments) - none of which carries a region. The Key Vault and Event Hub namespace names carry NEW `random_id` suffixes regardless of region, so the "new random suffixes" sub-check is unaffected. **Whatever the measured value was under `eastus2`, it is unchanged.** |
| 4 | `platform/connectivity` | **EXACTLY 696 adds** | **(a) unchanged, and this is the one that needed the work** | Three mechanisms could plausibly have moved it. All three were checked in the pinned sources and none does. Detail below. |
| 10 | `platform/identity` Pass 1 | **26 adds** | **(a) unchanged** | 6 plain `location =` attributes off `var.identity_location`. The AADDS managed domain, its replica set (which carries only `subnet_id` and inherits the domain's region), the VNet, its subnets, the NSG, the RSV, the RG, the policy exemption and the hub peering are all unconditional. Nothing counts or keys on region. **26 must be exactly 26.** (Step 11's "exactly ten pure adds" is Entra-only and carries no region at all, so it is region-independent by construction.) |

**Do not generalise Step 1's exact match to the rest.** `platform/management-groups` creates no
regional resources whatsoever, which makes it the weakest available test of the construction argument.
It confirms that nothing in the ALZ policy engine is region-conditional, which is worth having, and
nothing more. Steps 2, 3, 4 and 10 are where a delta could actually hide.

### Step 4's three mechanisms, in detail

**1. The AVM hub module templates `${location}` into 19 default names.**
`Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet` v0.17.1, `locals.names.tf`, renders
`var.default_naming_convention` through `templatestring(..., { location = value.location, sequence =
... })`. The 19 defaults include `fw-hub-${location}-${sequence}`,
`fwp-hub-${location}-${sequence}`, `pip-fw-hub-${location}-${sequence}`,
`rt-hub-fw-${location}-${sequence}` and `rt-hub-std-${location}-${sequence}`. **Every one of these is
an ATTRIBUTE of a resource whose Terraform address is keyed on the hub key (`primary` / `secondary`),
never on the rendered name.** The observable effect is that `fw-hub-eastus2-001` and
`fw-hub-centralus-001` **swap which hub they belong to**. Zero address change, zero count change, and
free on greenfield. (On a live estate this is a ForceNew replace of both firewalls, both policies and
every hub route table - the reason ADR-069 decision 6 gated its own dispatch behind a green teardown.)
The two hub VNet names are repo-supplied literals, `vnet-hub-primary-*` and `vnet-hub-secondary-*`, and
do not move at all - which is the topology proving out its own role-based naming.

**2. The AVM private-DNS-zones module renames 5 of 93 zones and adds or removes none.**
`Azure/avm-ptn-network-private-link-private-dns-zones` v0.23.1. Read from `locals.tf` at the pin:

- Region substitution happens in exactly one expression, inside
  `private_link_private_dns_zones_filtered_and_processed`:
  `replace(replace(zone_value.zone_name, "{regionCode}", local.location_geo_code), "{regionName}", local.location_name)`.
  It rewrites the `zone_name` VALUE and nothing else.
- **The `for_each` key is `zone_key`, not the rendered zone name.**
  `module "avm_res_network_privatednszone" { for_each = local.private_link_private_dns_zones_final }`,
  and `private_link_private_dns_zones_final` is keyed on `item.zone_key` - a stable map key such as
  `azmk8s`, optionally suffixed by a `custom_iterator` key that is a subzone name, never a region.
  **So the address set is byte-identical across the flip.**
- The only mechanism in this module that COULD change the zone count is
  `private_link_private_dns_zones_regex_filter`, whose `enabled` field **defaults to `false`** and
  which `platform/connectivity/dns.tf` does not set. So no zone is filtered in or out.
- `variables.tf` at the pin carries **93** `zone_name` entries, of which exactly **5** are templated:
  `privatelink.{regionName}.azurecontainerapps.io`, `privatelink.{regionName}.kusto.windows.net`,
  `privatelink.{regionName}.azmk8s.io`, `privatelink.{regionCode}.backup.windowsazure.com`,
  `privatelink.{regionName}.prometheus.monitor.azure.com`.
- Geo-code resolution verified from the pinned `Azure/avm-utl-regions` data file, not assumed:
  **`centralus` -> `cus`**, `eastus2` -> `eus2`. So `privatelink.eus2.backup.windowsazure.com` becomes
  `privatelink.cus.backup.windowsazure.com`, and the four `{regionName}` zones follow the obvious
  shape.
- Both hubs set `enabled_resources.private_dns_zones = false`, so the hub module's own nested
  private-DNS submodule creates nothing and there is no second zone set to reason about.

**Consequence for PC-4C: 89 stays 89**, and the 11 zones the spokes look up stay resolvable. The only
one of the 11 that moves is the AKS zone, and `landing-zones/bank-app-p1/dns_links.tf:28` builds it as
`"privatelink.${var.primary_location}.azmk8s.io"` from the same variable that drives the module's
`location`, so producer and consumer **cannot diverge**. Verified in the file: it is derived, never a
literal. Same for the AKS control-plane UAI role-assignment scope in `aks.tf`.

**3. The honest caveat: the hub module's availability-zone list is a LIVE lookup, not repo content.**
`main.availability_zones.tf` instantiates `Azure/avm-utl-regions` v0.5.2 with **`use_cached_data =
false`**, which issues a real ARM `locations` action against the connectivity subscription at plan
time, and derives
`local.availability_zones[key] = module.regions[0].regions_by_name[value.location].zones`. That value
feeds `zones` on the Azure Firewall and on its public IPs via
`coalesce(value.firewall.zones, local.availability_zones[key])`.

- **It cannot move the bar.** `zones` is a list ATTRIBUTE on a resource that exists either way, never
  a `count` and never a `for_each`. The 696 is unaffected in both directions.
- **It can silently change posture.** If the subscription's logical zone mapping for `centralus`
  returned fewer than three zones, both firewalls would be created less zone-redundant than intended,
  with a clean plan and a green apply. RC-4 (`Standard_D2s_v4` in `centralus` with zones 1,2,3 and no
  restrictions) is indirect but strong evidence against that, and Central US is documented as having
  availability zones. **Flagged as a QA acceptance item after Step 4, not as a gate:** confirm both
  firewalls report three zones.

**Therefore 696 must be exactly 696.**

### The rule that makes all of this useful

**PC-2REG, restated because it is the point of T3.** I am certifying five bars as
expected-unchanged, and one of the five has already come back exact. That certification is what gives
a delta its meaning.

> **A delta of even ONE against any bar certified unchanged above is a STOP. It is never a silent bar
> update, never a "close enough", and never an operator judgement call.** A delta means something
> region-conditional exists in this estate that the analysis above did not find, and finding that
> thing is the entire reason the bar is written down. Escalate to the architect for a fresh
> disposition before the apply.

This applies with particular force to 696, which the runbook words as "EXACTLY 696 ... not an
estimate, it is today's verified dry-plan". **Record the measured value for each of the five. Those
recorded values become the verified `centralus`-primary precedent that replaces the `eastus2`-primary
ones for the next rebuild.** Step 1's is already recorded above.

---

## T4. Lifecycle audit delta (LESSON 40/41)

The governing audit was run 2026-07-21 and re-checked 2026-07-30 (refresh #2, S4). That is **1 day
old**, comfortably inside the 14-day re-audit window, so this is a **region delta only**, not a
re-derivation. **Next full re-audit still due 2026-08-04** if dispatch has not happened by then.

**Nothing in the S4 audit was region-parameterised.** The eight Defender plans and the blocked-five
enablement list, Foundational CSPM's 2026-10-27 opt-in move, the Sentinel portal-only deprecation,
App Gateway v1 retirement and the WAF_v2 inline-configuration retirement (the estate is already on the
separate WAF-policy model), Azure Firewall Premium, and the pinned-provider `features` argument are
all service-lifecycle facts that do not vary by region. **All of S4 carries.**

Region-specific items checked for this refresh:

| Item | Status | Basis |
|---|---|---|
| **Traffic Analytics with a `centralus` Log Analytics workspace** | **PASS.** Central US is a supported region both for enabling Traffic Analytics on flow logs and for the linked Log Analytics workspace. This matters because four of the five spokes set `traffic_analytics { workspace_region = var.primary_location }` and an unsupported region returns `400 InvalidTAWorkspaceRegion` at apply, with a clean plan. | Microsoft Learn, Traffic Analytics supported regions, checked 2026-07-31 |
| Central US: availability zones, symmetric pairing with East US 2, not access-restricted | **PASS**, carried from ADR-069's 2026-07-30 verification against Microsoft Learn "List of Azure regions" (page updated 2026-07-28). 1 day old. | ADR-069 evidence ledger |
| `gpt-5.4-nano` `2026-03-17` `DataZoneStandard` in the `centralus` catalog | **PASS, live.** GA, not Deprecating. Model catalogs are per-region and this is exactly the LESSON 40/41 class, so it was right to re-check rather than carry. | RC-3, run live 2026-07-31 |
| Entra Domain Services in Central US | **PASS, live.** | RC-2, run live 2026-07-31 |
| `Standard_D2s_v4` in Central US: zones 1,2,3, no restrictions | **PASS, live.** | RC-4, run live 2026-07-31 |
| Static Web Apps allowed regions include `centralus` | **PASS**, carried from ADR-069. | ADR-069 evidence ledger |
| APIM, Databricks, Service Bus, Event Hubs, App Gateway, Log Analytics in `centralus` | **NOT VERIFIED. This is PC-3REG.** | T0 |
| Module and provider pins | **UNCHANGED.** No `.terraform.lock.hcl` and no module `version =` is in the `ed3450e..7fc8930` delta. `azurerm` stays pinned at **4.71.0** by every root's committed lock file; `avm-ptn-alz` 0.19.1, hub-and-spoke 0.17.1 and private-DNS-zones 0.23.1 are all unchanged. | `git diff --stat` |

---

## T5. Runbook amendments

**The runbook `docs/2026-07-22-full-estate-rebuild-runbook.md` remains the executable document. Its
14-step order, its per-step commands and its STOP/rollback matrix all stand. Refresh #2's amendments
1 to 4 all stand, and amendments 3 and 4 (STOP rows B6 and B7) are confirmed LANDED in the file.**
This refresh changes six things, and answers the three shape questions directly.

**Answering the three questions asked, before the amendments:**

- **Step 0's PC-1Y and PC-1SEC checks do NOT change shape under `centralus`-primary.** PC-1Y
  enumerates management groups, resource groups across five subscriptions, and eleven state blobs.
  None of those is keyed on region: the MG names come from `lib/`, the RG names are
  `rg-<role>-${org_prefix}-${environment}`, and the blob names are root paths. PC-1SEC queries the
  workspace by the name `law-security-globaris-poc`, which `platform/security/main.tf` builds from
  `org_prefix` and `environment` **only** - it carries no region token, so the same single query
  covers both the pre-flip and post-flip workspace. Both checks are also **discharged live today**.
- **The PC-3C DDoS gate before Step 4 does NOT change shape.** It reads the enforcement mode of the
  `Enable-DDoS-VNET` assignment at two MG scopes. Enforcement mode is not region-parameterised, and
  the assignment is created by Step 1 from a library file that carries no region literal. The reason
  it exists (the ADR-026 `LinkedAuthorizationFailed` 403 on the hub VNet PUT) applies identically to a
  `centralus` hub. **Keep it exactly as written.**
- **The PC-2X `PLATFORM_LAW_CUSTOMER_ID` re-set does NOT change shape, but one clause inside it is
  now false.** The command reads `law-platform-globaris-poc` in `rg-management-globaris-poc`, neither
  of which carries a region token, so the command is correct unchanged. Its justification paragraph
  says corp-a2 never reads the value "because Traffic Analytics is deliberately omitted from its DR
  flow log (no centralus LAW, LESSON 43)". After the flip the LAW is in `centralus` and corp-a2 is in
  `eastus2`, so the correct clause is **"no eastus2 LAW"**. The behaviour is unchanged: corp-a2 still
  needs the value SUPPLIED because a no-default variable hard-fails if unset.

**Amendment 1 (NEW, BLOCKING). Add PC-1REG to Step 0, and re-scope RC-7 to reach it.**

RC-7 in `docs/region-flip-centralus-primary.md` section 7.3 is listed as non-blocking, to be run at
leisure, **after Step 1**, at the `globaris` MG scope. That placement is wrong in two ways once the
primary region moves:

- **It is too late.** The first resource-group PUT into `centralus` is **Step 2**, not Step 4. An
  allowed-locations Deny fails there, with a clean plan and no plan-time signal at all.
- **It looks at a scope that does not exist yet at Step 0**, and it misses the one that does. Before
  Step 1 the only management group in the tenant is Tenant Root Group, which is precisely where an
  externally-managed policy would sit.

Replacement, run at Step 0 alongside 0a and 0b:

```
az policy assignment list \
  --scope /providers/Microsoft.Management/managementGroups/<tenant-root-id> \
  --disable-scope-strict-match \
  --query "[?contains(to_string(parameters),'listOfAllowedLocations')].{name:name, scope:scope, params:parameters}" -o json
```

**Bar: empty.** A non-empty result whose allowed set excludes `centralus` is a **STOP** before Step 2.
**Strong prior evidence it passes**, stated so nobody treats this as alarmism: the repository assigns
no `listOfAllowedLocations` parameter anywhere (grepped, zero hits, including both ALZ library files),
and this estate has been creating resources in `centralus` continuously for weeks (secondary hub,
corp-a2, Fabric F2, AI Search). It stays a gate anyway per LESSON 34: the policy matrix is read live at
every ancestor scope, never reasoned about. **Repeat it at the `globaris` scope after Step 1**, which
is the original RC-7, now cheap because it is the same command with a different scope.

**Amendment 2 (NEW, BLOCKING). Promote RC-6 to PC-3REG, before Steps 5-9.**

Six `az provider show` reads against a Step 9 that costs 60 to 180 minutes and, on an APIM failure
mid-provision, leaves a soft-deleted instance that reproduces PC-4S for the next rebuild. Move it out
of design-doc section 7.3 "at leisure" and into the Steps 5-9 pre-flight next to PC-4S and PC-5X.

**Amendment 3 (correction). PC-4S's APIM purge `--location` must NOT be flipped.**

Section 2a currently reads
`az apim deletedservice purge --service-name apim-bank-app-p1-globaris-poc --location eastus2`.
**`eastus2` is CORRECT and must be left alone:** the argument identifies where the SOFT-DELETED
instance lives, and that instance was created under `eastus2`-primary. An operator doing a
find-and-replace pass for the flip would break this command. Better still, remove the hazard entirely
by reading the location from the `deletedservices` response rather than hardcoding it - because after
THIS rebuild a cancelled APIM create leaves a soft-delete in `centralus` and the hardcoded value
becomes wrong in the other direction.

**Amendment 4 (correction, not caused by the flip). Step 0a's state-blob baseline sentence is
misleading.**

It reads "roughly 150-250 bytes (observed floor 181)". The ADR-068 Phase 4 canonical empty document is
**152-153 bytes**; **181 is `platform/identity`'s** natural terraform-empty floor under carve-out A,
which is never Phase-4 reset. As written, the sentence makes a perfectly correct 152 read as
suspicious. Today's live check saw exactly that split: ten blobs at 152-153 and identity at 181.
Suggested replacement: "Ten blobs should read 152-153 bytes (the ADR-068 Phase 4 canonical empty
document); `platform/identity` should read about 181 (its natural terraform-empty floor - carve-out A
means it is never Phase-4 reset). Anything materially larger is FM-2; absent or under 100 bytes is
FM-1."

**Amendment 5 (correction). Two inverted Traffic Analytics clauses.**

Runbook line 393 (inside PC-2X) and line 505 (the corp-a2 row of the Steps 5-9 shape table) both say
"no centralus LAW". After the flip both should read **"no eastus2 LAW"**. Behaviour unchanged; the
text is now the wrong way round, and it is exactly the kind of thing an operator reasons from at 2am.

**Amendment 6 (addition). Record the measured plan values.**

Steps 1, 2, 3, 4 and 10 should each gain an explicit instruction to WRITE DOWN the observed
`Plan: N to add`, because those five numbers become the verified `centralus`-primary precedent that
replaces the `eastus2`-primary ones. PC-9S already says this for the spokes; it should be said for the
platform roots too, since those are the ones carrying hard bars. Step 1's value is already recorded in
T3 (537, run `30636497926`).

**Unchanged and load-bearing:** ADR-060 sequential single-target dispatch, one run in flight at a
time, never `target=all` for apply; **plan then scan then apply, per root, every time** (the rule that
was got wrong twice on 2026-07-31 - `action=apply` skips the Plan step entirely, so a bare apply means
no plan-scan and no U1 or B4 check); `--ref banking` on every dispatch; the identity two-pass override
on Steps 10-11 only; U1 (any `-/+` replace or unexpected destroy is a hard STOP) and U5 (a second
identical failure on one root after one clean retry is a HARD STOP, counting toward the project's
4-failure bar).

---

## T6. VERIFIED vs ASSUMED (this replaces S5)

### Verified LIVE by the operator lane, 2026-07-31, read-only, sourced not inferred

| ID | Result |
|---|---|
| **PC-1Y half 1 (live Azure)** | **PASS.** Management groups: Tenant Root Group only, no `globaris` tree. No estate resource groups in any of the 5 subscriptions - only `NetworkWatcherRG` (protected from teardown by design), the bootstrap state RG in the management sub, and a Cloud Shell storage RG in landingzones. |
| **PC-1Y half 2 (state backend)** | **PASS.** All 11 blobs at the empty baseline: ten at 152-153 bytes, `platform/identity` at 181 (carve-out A floor). No blob materially larger, so **no FM-2**. No blob absent or under 100 bytes, so **no FM-1**. |
| **PC-1SEC, both halves** | **PASS.** Zero soft-deleted workspaces on the security subscription, zero live workspaces, and `rg-security-globaris-poc` does not exist at all. The second half is the one the runbook added on 2026-07-30 after the soft-delete query alone read as a false PASS. |
| **PC-1R (ADR-057 subscription-scope survivors)** | **PASS.** Across all five estate subscriptions: budgets 0, cost exports 0. Management sub cost-anomaly scheduled actions 0. Security sub subscription-level diagnostic settings none. This is the class that voided the 2026-07-23 attempt and that the 2026-07-30 failed teardown left intact. |
| **Step 1 plan bar under `centralus`-primary** | **PASS, exact.** Run `30636497926`, ref `banking` @ `7fc8930`: **537 to add, 0 change, 0 destroy, 0 replace, 0 import, 0 "already exists"**, 2 min 36 s. |
| **RC-1** compute quota, `centralus`, landingzones sub | **PASS with ZERO headroom improvement.** Total Regional 10, `standardDSv4Family` 10, `standardDASv4Family` 10. See PC-4REG in T0 - this is the finding, not the pass. |
| **RC-2** Entra DS supports Central US | **PASS.** And East US 2 for the secondary. |
| **RC-3** `gpt-5.4-nano` catalog in `centralus` | **PASS.** GA, `2026-03-17`, `DataZoneStandard`, not Deprecating. |
| **RC-4** `Standard_D2s_v4` in `centralus` | **PASS.** Zones 1,2,3, no restrictions. |
| **RC-5** Network Watchers | **PASS, re-confirmed 2026-07-31 AFTER the teardown.** `NetworkWatcher_centralus` and `NetworkWatcher_eastus2` both live in `NetworkWatcherRG` in the landingzones subscription. This matters more than it looks: `data.azurerm_network_watcher` resolves at PLAN time, before any VNet exists to trigger auto-creation, and a missing watcher has already blocked corp-a1 and online-p1 once in this estate's history. Four spokes now need `_centralus` and corp-a2 needs `_eastus2`. Both present. Independently, `NetworkWatcherRG` does not match `RG_SWEEP_QUERY` in `scripts/teardown-common.sh`, so no teardown can delete it. |
| **The four soft-deleted `kv-sec-globaris-*` Key Vaults** | **ROOT-CAUSED, and they do NOT block Step 3.** See T7. |

### RC-6 and RC-7 were NOT run

Stated plainly because the ADR-069 check set is only 5 of 7 discharged. **RC-6** (service availability
sweep for `centralus`) becomes **PC-3REG**, blocking Steps 5-9. **RC-7** (allowed-locations policy)
becomes **PC-1REG**, re-scoped to Tenant Root Group and promoted to blocking before Step 2.

### Verified by me, from the repository, at `7fc8930`

The complete apply-path delta and its per-file disposition (T2); that exactly one of the 39 files in
PR #60 changes what gets PUT; that `bootstrap/variables.tf` is not in the diff and
`envs/poc.backend.hcl` changes no value; that all 16 `eastus2`/`centralus` literals in the repo are
accounted for and that `red_team_geo_location = "westeurope"` is a seventeenth, deliberately a third
region; that only six names in repo-owned code interpolate a region variable and all six are DATA
SOURCE lookups (five Network Watchers, one AKS private DNS zone); that no `listOfAllowedLocations`
parameter is assigned anywhere in the repo including both ALZ library files; that
`lib/globaris.alz_architecture_definition.json` contains no region literal; that the private-DNS-zones
module's `for_each` key is `zone_key` and not the rendered zone name, that its regex filter defaults
off, and that `centralus` maps to geo code `cus` in the pinned regions data; that the hub module
templates `${location}` into 19 default NAMES and derives `zones` from a live regions lookup that is an
attribute and never a count; that both hubs set `enabled_resources.private_dns_zones = false`; that the
repo creates no `azurerm_log_analytics_linked_service`; that `enable_sql`, `enable_app_service`,
`enable_vpn_gateway`, `enable_dns_resolver`, `enable_bastion`, `enable_acr_kubelet_binding` and
`enable_synthetic_workload` are all still off; that `_tf-root.yml` passes `-var-file` on plan, apply
and destroy and uses no `-detailed-exitcode`.

### NOT verified, because it requires live Azure and I am read-only on it

| ID | What must be proved | Owner | Blocks |
|---|---|---|---|
| **PC-1REG** | No allowed-locations Deny at Tenant Root Group excluding `centralus` | operator | **Step 2** onward |
| **PC-3REG** | APIM, Databricks, Service Bus, Event Hubs, App Gateway, Log Analytics available in `centralus` (RC-6) | operator | **Steps 5-9** |
| **PC-2R** | The 8 estate-managed Defender plans read `Free` in the security subscription | operator | **Step 3** |
| **PC-3R** | `Microsoft.CostManagementExports` is `NotRegistered` in the management subscription | operator | Step 2 |
| **PC-3C** | `Enable-DDoS-VNET` reads `DoNotEnforce` at BOTH the connectivity and landingzones MGs | operator | Step 4 |
| **PC-4S** | The soft-deleted APIM instance is gone. Do not assume the auto-purge fired. | operator | Step 9 |
| **PC-1S** | Zero subscription-scoped policy exemptions in the landingzones subscription | operator | Step 8 |
| **PC-2REG** | The remaining four plan bars (36 / 48 / 696 / 26), re-measured and recorded | operator | Steps 2, 3, 4, 10 |
| **Live policy matrix at every ancestor MG scope** | Structurally unreadable below Tenant Root until Step 1 creates the tree. PC-1REG covers the one scope that exists now; PC-3C and the re-run of PC-1REG at `globaris` cover it after Step 1. | operator | Steps 2, 4 |
| **Tenant prerequisites** | CI SP role bindings, RP registrations, federated credentials, identity licensing. Carried as W1: Step 1 IS the live confirmation and fails loud there before any estate resource is touched. Step 1's clean plan on 2026-07-31 is partial evidence (it proves read access at MG scope), not full. | operator | Step 1 |
| **Firewall zone redundancy after Step 4** | Both firewalls should report three zones. Attribute-level, cannot move the 696 bar, but can silently degrade posture (T3 mechanism 3). QA acceptance item, not a gate. | qa-engineer | advisory |
| **GitHub known-issues sweep** | Open `azurerm` and AVM issues at 4.71.0 affecting these roots. Refresh #2 checked the `azurerm_security_center_subscription_pricing` 409 class specifically and did not sweep the other nine roots. **I did not extend that sweep this pass either.** Named rather than implied. | architect / operator | advisory |

---

## T7. The four soft-deleted Key Vaults: root-caused, inert, and a standing consequence worth recording once

OQ-066 item 0 recorded four `kv-sec-globaris-*` vaults refusing purge with `MethodNotAllowed` and
asked whether the teardown script's "not purge-protected" classification was wrong or the CI SP lacked
the purge action. **Neither. They are genuinely purge-protected and Azure correctly refused.** Read
live from the security subscription on 2026-07-31: all four report `purgeProtectionEnabled = True`,
deleted between 2026-07-11 and 2026-07-31, scheduled purge dates between 2026-10-09 and 2026-10-29, all
four in `eastus2`.

This is exactly consistent with the PR #59 finding that the guard compared an Azure CLI row-embedded
boolean `True` against lowercase `"true"`, so **the guard had never once fired** and the script
attempted purges it should have skipped. Only Azure's server-side `MethodNotAllowed` prevented wrong
purges across three consecutive live runs. PR #59 fixes the compare, so the next teardown classifies
them correctly and skips them. **Nothing to action.**

**Why they cannot block Step 3, verified against the pinned config rather than assumed.**
`platform/security/main.tf:108` names the vault
`kv-sec-${var.org_prefix}-${random_id.security_kv.hex}`. The name carries a **random suffix - not a
region token and not a stable name** - so every apply generates a new vault name. The four
soft-deleted vaults are therefore name-unique orphans with **no create-time interaction of any kind**:
no collision, and no soft-delete RECOVERY path either, which means **OQ-063's recover-on-rebuild
reasoning does not apply to this vault at all**. Additionally `main.tf:110` sets
`location = var.primary_location`, now `centralus`, so the new vault will not even land in the same
region as the four orphans.

**Two consequences, stated here so they are recorded once rather than rediscovered every teardown:**

1. **Every full rebuild cycle permanently strands one more purge-protected Key Vault for 90 days.**
   Four have accumulated since 2026-07-11. They are inert and free, but the residue grows monotonically
   with rebuild count and nothing in the estate reclaims it. That is a design consequence of
   `random_id` plus `purge_protection_enabled = true`, not a defect. It is the correct trade for a
   security root: a stable name would collide on rebuild, and disabling purge protection would fail the
   posture bar.
2. **Because the name is random rather than derived, this vault is invisible to any pre-clearance check
   keyed on a known name.** Any future soft-delete sweep must enumerate `deletedVaults` **by prefix**
   (`kv-sec-<org_prefix>-`), never by exact name. Refresh #2's S8 flagged the general principle (every
   pre-clearance needs a soft-delete-recovery sweep across every soft-deleting type); this is the
   concrete shape that sweep must take for Key Vault, and it differs from the Log Analytics and APIM
   cases, both of which DO have stable derived names.

---

## T8. Findings handed to other roles (NOT fixed here, docs-only pass)

Refresh #2's F1 and F2 are LANDED (verified in the runbook today). F3, F4 and F5 remain open and are
restated. F6 to F10 are new.

| # | Finding | Owner | Severity |
|---|---|---|---|
| F3 (carried) | **`-parallelism=1` is applied to `platform/security`'s apply step only, not its destroy step.** Destroying `azurerm_security_center_subscription_pricing` resets the plan to `Free`, which is the SAME subscription-level pricing write that 409s under concurrency. Eight destroy concurrently at default parallelism during ADR-066 Phase 1's security-layer destroy. | devsecops-engineer | Medium. Not a blocker for this apply; a plausible first failure of the next teardown. |
| F4 (carried) | **`teardown-probe.yml` has no soft-delete class.** It never queries `list-deleted-workspaces`, APIM `deletedservices`, deleted Key Vaults or deleted Cognitive Services accounts. Every one is a proven rebuild-blocker class here. **Extended by T7: the Key Vault query must enumerate by PREFIX, because the vault name is random.** | devsecops-engineer | Medium. |
| F5 (carried) | `DEPLOYMENT.md` section 3 Step 5 still lists `PLATFORM_LAW_CUSTOMER_ID` as a `platform/security` secret; Step 3 still describes connectivity as creating a VPN Gateway and DNS Private Resolver. Both false since 2026-07-21. **Now also carries stale region text.** | technical-writer | Low. |
| **F6 (NEW)** | **Runbook amendments 1 to 6 in T5.** Amendments 1 and 2 are new BLOCKING gates (PC-1REG at Step 0, PC-3REG before Steps 5-9). Amendments 3 to 6 are corrections: the APIM purge `--location` must NOT be flipped, the state-blob baseline sentence is misleading, two Traffic Analytics clauses are inverted, and the five platform plan bars need a "record the actual" instruction. | devsecops-engineer | **Amendments 1-3 should land before dispatch.** 4-6 are low but cheap. |
| **F7 (NEW)** | **`check-adr-landed.sh` and the append-only ADR convention are in structural tension, and the register is already wrong twice.** The awk keeps the FIRST `- **Landed:**` line in each ADR block (`if (!has_landed)`), while `DECISIONS.md`'s own preamble instructs authors to "update the field by appending a dated addendum, never by editing the body". So an ADR whose landing is corrected by addendum **still reports `NOT IMPLEMENTED`**. Both **ADR-068** (Phase 4 proven live 2026-07-31) and **ADR-069** (merged as PR #60) are affected today. This is the exact class of false register the check was built to prevent, inverted. Fix: take the LAST `- **Landed:**` line in the block, and add one line to the preamble saying an addendum must repeat the field as a top-level `- **Landed:**` list item. | devsecops-engineer | Medium. A traceability check that reports false negatives is worse than none, because it is trusted. |
| **F8 (NEW)** | **`shellcheck` should be added to `preflight.sh` as a best-effort step, the same shape as `actionlint`.** The PR #59 regression (a deleted `cut -f3` leaving an unassigned variable, fatal under `set -u`) is SC2154 territory. `bash -n` cannot catch it, `preflight.sh` has no shell-execution step, and only a careful human read of the diff caught it. | devsecops-engineer | Medium. |
| **F9 (NEW)** | **`check-claims.sh` exits 1 on `banking` from pre-existing failures in its own fixtures and two docs**, so it cannot currently serve as a red/green gate. Either fix the fixtures or scope the check so a clean tree passes. | devsecops-engineer | Low, but it silently devalues a gate. |
| **F10 (NEW)** | **ADR-068 Phase 4's absent-blob fallback creates blobs where none existed**, clearing three standing FM-1 alarms at `INFO`. Either it should warn loudly or INV-STATE needs amending. Carried from the 2026-07-31 close; unchanged by the flip but still open. FM-1 is the "state lost while resources may be live" class, and silently manufacturing state is the wrong default for it. | devsecops-engineer | Medium. |

---

## T9. Decisions and open items

- **No new ADR.** This refresh introduces no new decision. ADR-060 (sequential single-target),
  ADR-061 (Secret determinism), ADR-066, ADR-067, ADR-068 and **ADR-069** all govern unchanged; this
  document confirms ADR-069's implementation rather than revising it.
- **ADR-069 gets a dated addendum** (written this pass, in `DECISIONS.md`): `Landed:` moves from
  `NOT IMPLEMENTED` to `91523dc (PR #60)`, the Context framing is corrected to the AI Search
  rationale, and decision 3's "every region-valued input" wording is narrowed to exclude
  `red_team_geo_location`.
- **`docs/region-flip-centralus-primary.md` RC-2 casing defect CORRECTED this pass** (one line):
  `resourceType=='domainServices'` becomes `resourceType=='DomainServices'`. As written the query
  returns `[]`, and the documented consequence of an empty result is STOP, keep `identity_location` at
  `eastus2`, and give the identity pillar an explicit DR-region carve-out. **A one-character casing
  error in a check would have triggered a real architectural change.** Same defect class as the Key
  Vault `True`/`true` compare fixed in PR #59 the same night, and worth naming as a class: **a check
  whose failure mode is an empty result is only as trustworthy as its exact-match string.**
- **OQ-066 updated** (append, dated): item 0 DISCHARGED, items 1 to 5 DISCHARGED by RC-1 to RC-5, the
  four Key Vaults root-caused, RC-6 and RC-7 re-homed as PC-3REG and PC-1REG, and a new item 9
  recording the monotonic purge-protected-vault residue and the prefix-enumeration requirement.
- **OQ-062 is partly proven.** Item (f) is closed by the 2026-07-31 green Step 3, which created a
  fresh workspace with zero "already exists" on any `Microsoft.SecurityInsights` child. Item (e), the
  az-sweep step 7b backstop, remains unexercised.
- **OQ-065 limb B remains open** (no state-provenance gate on the deploy path). Step 0a is its
  zero-code half and it worked today.
- **Watch-item carried unchanged:** promote `banking` to `main`, or block `main` from `deploy.yml`
  dispatch, as a post-rebuild cleanup. Related to OQ-057.
- **ADR-worthy, deliberately NOT written this pass to hold scope:** the generalisation behind
  PC-1REG, that **a change to a foundational estate-wide value silently re-arms every environmental
  precondition that was previously discharged only by successful execution.** Three green applies
  proved `eastus2` was permitted by the live policy matrix, by the offer, and by the model catalog.
  They proved nothing whatsoever about `centralus`. The corollary is a pre-clearance rule worth
  writing down properly: when a foundational value changes, every check whose evidence was
  "it worked last time" reverts to unproven, regardless of how many times it worked. Recorded here and
  under OQ-066 so it is not lost.

---

## Proposed commit message (refresh #3)

```
docs(preclearance): 2026-07-31 refresh #3 - re-clear the full-estate rebuild against 7fc8930 with
centralus primary; whole-run GO-CONDITIONAL, PC-1SEC and PC-1Y discharged live, three new region
conditions (PC-1REG allowed-locations at tenant root before Step 2, PC-2REG re-measure the plan bars,
PC-3REG service availability before Steps 5-9); PR #60's 39 files assessed with exactly one changing
what gets PUT; five plan bars certified expected-unchanged from pinned module sources and Step 1
confirmed exact at 537; ADR-069 addendum lands the Landed field and narrows decision 3; RC-2 casing
defect corrected
```

---

# 2026-07-31 ADDENDUM B - RETRY disposition for `landing-zones/bank-data-p1` (Step 8), and the Step 9 gate

**Why this addendum exists.** The standing rule is that no first apply **or retry** of any root
proceeds without a written architect disposition. `landing-zones/bank-data-p1` has now failed twice
(runs `30661012325` and `30662610292`), which is already at the runbook's U5 hard-stop bar, so the
next dispatch of this root is a FIXED dispatch and needs its own clearance. This addendum is
append-only; nothing above the heading is edited. The ruling it enforces is **ADR-070**; the open
items are **OQ-021 (updated 2026-07-31)** and **OQ-067**.

## U0. VERDICT

| Root | Verdict | Conditions |
|---|---|---|
| `landing-zones/bank-data-p1` (Step 8 retry) | **GO-CONDITIONAL** | PC-1DINE, PC-2DINE, PC-3DINE, PC-4DINE all discharged, in that order, before dispatch |
| `landing-zones/bank-app-p1` (Step 9) | **NO-GO until PC-5DINE clears** | Gated on ADR-070 decision 6 |
| Steps 1 to 7 (the seven green roots) | **NOT contaminated. No teardown.** | PC-1D is a cheap confirmation, not a blocker |

**Full estate teardown is NOT ordered.** ADR-070 decision 3 gives the bright-line test and applies it:
the blocking objects are deletable control-plane children with no data, no soft-delete, no purge
protection and no dependents, and the pending plan reproduces them identically. That is runbook matrix
**B1** (delete the specific survivor, rerun, do not import), not ADR-067. The seven green roots and
roughly 1,391 applied resources stand.

## U1. Conditions

**PC-1DINE (BLOCKING, read-only, records provenance).** LIST the diagnostic settings on the Databricks
workspace, the Foundry account and the Search service, and print the `name` of every entry **verbatim**,
not the requested name from the URL. Expect either the three `diag-*` names or
`setByPolicy-LogAnalytics`. Record which, in OQ-067. The recovery action is identical either way, so
this does not block the retry - it blocks Step 9, and it is the only read that can settle OQ-067
item B. Do not treat the existing GET evidence as sufficient: the provider's RequiresImport check and
`az rest` issue the same call, so a loose answer is loose to both.

**PC-2DINE (BLOCKING, read-only, tests OQ-021).** Read the diagnostics DINE assignment's Log Analytics
workspace parameter at **every** ancestor scope of the landingzones subscription - tenant root,
`globaris`, `landingzones`, `corp`. Zero-GUID means OQ-021 stands and the DINE cannot successfully
write anything. The real `law-platform-globaris-poc` resource ID means OQ-021 has silently resolved and
the duplicate-ingestion exposure is already live estate-wide. In the same pass, enumerate the live
policy ASSIGNMENT names and their `policyDefinitionReferenceIds` for both the diagnostics and the
private-DNS DINE families at those same four scopes; ADR-070 decision 2 cannot be implemented without
them and they must not be guessed. **Checking only the `landingzones` scope is the exact error that
produced the prior "zero DINE diagnostic policies" finding.**

**PC-3DINE (BLOCKING, the settle gate).** Before deleting anything, confirm every deployment in
`rg-bank-data-p1-workload-globaris-poc` whose name starts `PolicyDeployment` reads `provisioningState`
in {`Succeeded`, `Failed`, `Canceled`}, none in {`Running`, `Accepted`}, **and** that a second read five
minutes later returns the same set with no NEW `PolicyDeployment` name. Both reads are required: the
first alone proves nothing about a remediation still queued. Deleting a survivor mid-remediation simply
recreates it.
**Cap:** a diagnostic-setting PUT takes seconds, so a deployment `Running` for 50 minutes is already
pathological. If any is still `Running`/`Accepted` 90 minutes after it started, treat it as stuck, not
slow: cancel it, re-read, proceed, and record it in OQ-067.

**PC-4DINE (BLOCKING, the fix).** The decision-2 exemption unit is merged to `banking` before dispatch,
and the dispatched `headSha` carries it (LESSON 33). Without it the retry races a live policy
assignment, and losing that race spends the U5 budget on a coin flip. Delete the survivors (the three
diagnostic settings named in the errors, plus ANY private DNS zone group on
`pe-aif-bank-data-p1-globaris-poc`, plus anything PC-1DINE turned up on those three resources) only
AFTER PC-3DINE clears and only on the failing set.

**PC-5DINE (BLOCKING before Step 9).** `landing-zones/bank-app-p1` is not dispatched until the
exemption unit is merged AND `bank-data-p1` is green. Four azurerm diagnostic settings of the exact
failing shape (`diag-acr-*`, `diag-aks-*`, `diag-apim-*`, `diag-sbns-*`) sit behind a 60 to 180 minute
APIM create. Failing on a diagnostic setting after a ninety-minute provision is the most expensive
failure available in this run.

## U2. Plan bar for the retry (Rule 1 applies unchanged)

| Scan item | Bar |
|---|---|
| adds | the 4 known (3 diagnostic settings + `azapi_resource.foundry_pe_dns_zone_group["main"]`) plus the new exemption and its new `time_sleep` |
| changes | OQ-032 `CreatedDate` churn ONLY, confirmed by opening a diff block, never by counting `-` prefixes |
| destroys | 0 |
| replacements (`must be replaced` / `-/+` / `forces replacement`) | 0 |
| imports / `already exists` | **0**. Any recurrence here is a STOP and escalates to ADR-070's fallback (move the three settings to root-level `azapi_resource`), not a fourth retry |

## U3. What this addendum does NOT clear

- The provenance of the three settings before 19:59:44 (OQ-067 item B). Open by design; PC-1DINE and
  PC-2DINE are the reads that close it.
- Wiring the OQ-021 assignment parameter. Out of scope for this retry, and ADR-070 decision 7 rules it
  must never land without the exemptions in the same change.
- Steps 10 to 14. Untouched by this addendum.

## U4. Correction to PC-8S in this document

The PC-8S table row `Deploy-Private-DNS-Zones` DINE at corp reads "Post-apply drift only, never a
create blocker | QA item". That is **false for any private endpoint whose zone group Terraform has not
yet created**, which is exactly the state a failed apply leaves behind, and false for the Foundry
account private endpoint whose three-zone group is authored natively rather than by the module. Azure
supports only one private DNS zone group per private endpoint, so the policy's group and Terraform's
group are mutually exclusive, not duplicative. Handed to DevSecOps as a runbook amendment
(ADR-070 follow-up 4). Recorded here rather than edited above, per append-only.

## Proposed commit message (addendum B)

```
docs(preclearance): 2026-07-31 addendum B - bank-data-p1 Step 8 RETRY cleared GO-CONDITIONAL on
PC-1DINE..PC-4DINE, Step 9 gated on PC-5DINE; full teardown NOT ordered (ADR-070 decision 3, runbook
B1 not ADR-067); PC-8S private-DNS DINE row corrected
```
