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
