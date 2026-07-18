# Pre-clearance: wave B0b redeploy (platform/connectivity)

> Artifact of the mandatory deploy pre-clearance gate. First REDEPLOY of this root since the full
> estate teardown of 2026-07-11. B0a (management-groups, management, security) is GREEN and live,
> which means this redeploy INVERTS the original order: in the 2026-07-06 first deploy, connectivity
> went in BEFORE the tag-governance Modify and the NIST/CIS assignments existed. That inversion is
> the structural risk this document clears.
> Prepared by: architect. Date: 2026-07-17.
> Evidence: live az CLI enumeration 2026-07-17 (policy assignments at every ancestor scope of the
> connectivity sub, soft-deleted KV list, RP registration, network quotas per region, network
> watchers, RG inventory), gh CLI (run 29541997637 full plan log, repo secrets), committed
> `.terraform.lock.hcl` vs run-log provider installs, GitHub issue sweep (Azure/Azure-Landing-Zones
> open issues for both pinned pattern modules), MS Learn / Azure updates (VPN GW SKU consolidation,
> lifecycle audit cross-check vs docs/preclearance/deprecation-audit.md 2026-07-10).

## Verdict: GO-conditional. Three numbered preconditions, all lightweight, then apply.

| # | Precondition | Lane | Blocks |
|---|--------------|------|--------|
| PC-1 | Dispatch `deploy.yml` `target=platform/connectivity` `action=apply` from branch `banking` at a commit whose `platform/connectivity/**` content is IDENTICAL to the one run 29541997637 planned (banking @ bbde824). Verify with `git diff bbde824..HEAD -- platform/connectivity` = empty before dispatch. The plan-scan below is only valid for that code state. | devsecops | apply |
| PC-2 | Plan-scan the apply run's own refreshed plan before it executes (or, if the workflow plans and applies in one step, scan the streamed plan header the moment it prints): expect approximately 702 to add, 0 to change, 0 to destroy, pure adds, no `-/+ replace`. Any destroy/replace, or a materially different add count, is a STOP (LESSON 26). Specifically confirm: 0 `ddos_protection_plan`, 0 bastion, 2 firewalls at `sku_tier = Premium`, 4 public IPs. | devsecops + architect scan | apply |
| PC-3 | Post-apply, BEFORE any B1 plan: qa-engineer live-vs-intent pass (house gate), then re-verify the 8 hub repo Secrets against live outputs (expected byte-identical, see check 8; update any that differ) and confirm `primary_dns_resolver_inbound_ips` handling per the 2026-07-06 note. | qa-engineer + operator | B1, not this apply |

No new operator grants are needed: the CI SP's Contributor + UAA at the connectivity sub were
verified live 2026-07-12 (B0a pre-clearance check 3) and this root writes nothing at MG scope.
No new OQ raised; no code change required.

---

## 1. Live policy matrix at every ancestor scope: CLEAN - no Deny fires on anything this root creates

Enumerated live 2026-07-17 (`az policy assignment list` per scope). Ancestor chain of the
connectivity sub: Tenant Root Group -> globaris -> platform -> connectivity -> sub.

| Scope | Assignment | Effect class | Verdict for this root |
|---|---|---|---|
| connectivity MG | `Enable-DDoS-VNET` | Modify, **DoNotEnforce** | The ADR-026 lever HELD through teardown/redeploy (B0a management-groups re-applied it; verified live today). This was the policy that 403-blocked every VNet PUT in the original deploy. Cleared. |
| platform MG | `Enforce-GR-Network0` | Initiative, **DoNotEnforce** | The network guardrail set (firewall/PIP/VNet members) is not enforced. Cleared. |
| platform MG | `Enforce-Subnet-Private` | **DoNotEnforce** | Would otherwise touch subnet PUTs (private default outbound). Not enforced. Cleared. |
| platform MG | `Enforce-GR-KeyVault` | Default (Deny members) | Moot: this root creates NO Key Vault (verified, see check 2). |
| platform MG | remaining `Enforce-GR-*`, VM/AMA/ASR DINEs | DoNotEnforce or VM-only | No member targets a resource type this root creates. |
| globaris MG | `Deny-Classic-Resources`, `Deny-UnmanagedDisk` | Deny, Default | Neither matches any created type (no classic resources, no VMs). |
| globaris MG | `tag-governance-globaris` | **Modify, Default** | Fires on all 702 create PUTs. This is the order-inversion delta vs 2026-07-06 - assessed benign, see check 1a. |
| globaris MG | `Audit-ZoneResiliency`, `Audit-ResourceRGLocation`, `Audit-*` | Audit | Never blocks. Note: private DNS zones are location `global`; audit-only regardless. |
| globaris MG | `Deploy-Diag-LogsCat`, `Deploy-AzActivity-Log`, `Deploy-MDFC-*`, `Deploy-MCSB2/ASC-Monitoring` | DINE / Default | Noise class only; DINE never blocks creates. Known OQ-021 unwired-LAW remediation failures will log against new connectivity resources - ignore. This root creates no diagnostic settings of its own, so there is no DINE-vs-Terraform ownership contention. |
| globaris MG | `reg-nist_sp_800_53_r5`, `reg-cis_azure_2_0_0` | **DoNotEnforce** | Audit-class benchmarks, not enforced. |
| Tenant Root Group | `sys.mfa-write`/`sys.mfa-delete`, `sys.blockwesteurope` | Microsoft system | Workload identities exempt from the MFA pair (empirically green through all 2026 applies); region block is westeurope-only, estate deploys eastus2/centralus and `global`. |
| connectivity sub | `SecurityCenterBuiltIn` | Audit-class | Never blocks. |

### 1a. The order-inversion delta, explicitly

Assignments that did NOT exist when connectivity first deployed 2026-07-06 but ARE live now:
`tag-governance-globaris` (Modify), `reg-nist`/`reg-cis` (DoNotEnforce), plus the B0a-recreated
MDFC/MCSB DINEs. The only enforced one is the tag-governance Modify. Precedent that it is
non-blocking at create time: (a) the ORIGINAL estate ran with this exact assignment over the live
connectivity resources from 2026-07-07 to teardown with only the benign OQ-032 CreatedDate tag
drift; (b) all B0a creates (84 resources incl. azapi-created ones) went through it green
2026-07-16. Deny-Public-IP exists ONLY at the identity MG (ADR-028 arc) - it is NOT on the
connectivity sub's ancestor chain, confirmed by today's enumeration. The corp-MG deny sets sit on
the landingzones branch, also not on this chain. No exemption unit (LESSON 35) is needed for this
root.

Consequence to expect, not fear: the first post-apply plan will show the OQ-032 CreatedDate tag
drift across connectivity resources. That is the accepted estate-wide behavior, not a defect.

## 2. Soft-delete / name-reuse collisions: NONE - the B0-split KV watch-item CLOSES as not-applicable

- **This root deploys NO Key Vault.** Verified by grep of the root .tf files AND the full
  `.terraform/modules` cache for `azurerm_key_vault` / `azurerm_storage_account` resources: hits
  exist only in module `examples/` directories, never in module code paths we instantiate. The
  TLS-inspection KV remains an explicit DEVIATION deferred to platform/security wiring (main.tf
  header comment). `az keyvault list-deleted` in the connectivity sub 2026-07-17: EMPTY.
- No storage accounts (global namespace) are created here - flow-log SAs live in the spokes.
- Public IPs: 4 Standard-SKU PIPs, module-generated names, NO `domain_name_label` set in our
  config (the module supports it but we do not pass it), so no DNS-label reservation to collide.
- Private DNS zone names are unique per RG, not globally reserved; the RG is recreated fresh.
- RG inventory in the connectivity sub today: only `NetworkWatcherRG` survives (expected - see
  check 5). No name conflicts for the three RGs this root creates.

## 3. Plan-scan of run 29541997637 (GREEN dry-run, banking @ bbde824, 2026-07-16): PASS

Full log pulled and scanned by class, not by line:

- `Plan: 702 to add, 0 to change, 0 to destroy`. Grep confirms 702 `will be created`,
  **0** `must be replaced`, **0** `will be destroyed`.
- Type histogram (excluding 404 modtm/random telemetry pairs): 270 azapi_resource (VNets, subnets,
  peerings, 89 private DNS zones, 178 zone VNet-links, VPN GW), 4 azurerm_public_ip (2 firewall +
  2 VPN GW active-active), 4 route tables + 4 routes, 3 resource groups, 2 azurerm_firewall +
  2 azurerm_firewall_policy (both `sku_tier = "Premium"`), 1 DNS private resolver +
  1 outbound endpoint. Matches the intended shape exactly.
- **0 DDoS protection plan** (enable_ddos_standard=false honored - the ADR-026 coupled intent),
  **0 bastion** (enable_bastion=false honored).
- Wrong-sub risk: nil by construction - the root's azurerm AND azapi providers are both anchored
  to `var.connectivity_subscription_id` (providers.tf); no other subscription appears in the root.
- The dns-resolver-outbound subnet carries the `Microsoft.Network/dnsResolvers` delegation in
  config (the 2792a87 fix), so the original SubnetMissingRequiredDelegation arc cannot recur.
- Warnings in the log, all benign: undeclared-variable warnings from the shared poc.tfvars
  (standing behavior on every root), azapi `retry.multiplier` deprecation notices from inside the
  pinned module (plan-time only), Node 20 runner deprecation notices (GitHub, not us).
- Delta vs the ~704-resource prior estate: consistent with the removed duplicate dr.tf peerings
  and post-deploy fixes. Not a landmine.

## 4. Provider/module drift + known-issues sweep: NO drift, nothing on our path

- **Zero provider drift vs the last GREEN full deploy.** `platform/connectivity/.terraform.lock.hcl`
  is committed and pins azurerm 4.71.0, azapi 2.10.0, modtm 0.3.5, random 3.8.1. The run-29541997637
  init installed exactly those versions. These are byte-identical to the 2026-07-06 green deploy -
  the floating `~> 2.5` azapi constraint is neutralized by the lock file.
- Module pins unchanged: avm-ptn-alz-connectivity-hub-and-spoke-vnet 0.17.1,
  avm-ptn-network-private-link-private-dns-zones 0.23.1 - the exact pair that deployed green.
- Open-issue sweep (Azure/Azure-Landing-Zones tracker, 2026-07-17), assessed against OUR shapes:
  - #4196 (2026-06-30, open): firewall PIP `ip_tags` not forwarded -> forced replacement where a
    tenant policy injects ip_tags (MCAPS-class tenants). NOT on our path for a pure-create apply,
    and no policy in this tenant injects ip_tags. Recorded as a plan-scan tripwire: any FUTURE
    `-/+` on a firewall PIP is a STOP-and-diagnose, not a rerun.
  - #4039 (`enabled_resources.firewall_policy` not honored): affects BYO-policy users setting it
    false; we set true and the module owns the policies - prior deploy proves our path.
  - #335 (VPN GW bgpPeeringAddresses perpetual drift), #4021 (bgp_route_propagation), #4067
    (deprecated enable_bgp on connections), #3993 (0.16.9 GW route-table plan error): none match
    our config (no BGP customization, no connections, pin is 0.17.1), and the prior estate's
    steady-state plans were drift-free (`No changes` proven 2026-07-06).
  - private-link-private-dns-zones tracker: no open issue matching the 89-zone + 2-hub-link shape.
- **Lifecycle audit (step 3d): current.** The 2026-07-10 estate-wide audit classified this root
  CURRENT (no NSG flow logs here, Standard-SKU PIPs only). Delta recheck today: Azure Firewall
  Premium CURRENT; DNS Private Resolver CURRENT; **VpnGw1AZ is on the safe side of the VPN GW SKU
  consolidation** - non-AZ VpnGw1-5 SKUs are creation-blocked since 2025-11-01 and retire
  2026-09-30, AZ SKUs unaffected (MS Learn gateway-sku-consolidation, checked 2026-07-17); Basic
  PIP retirement moot (Standard everywhere); DDoS plan not created. LESSON 41 clock: last full
  audit 2026-07-10/11, within the 2-week window as of this writing. **If the B0b apply slips past
  2026-07-25, re-run the lifecycle recheck before dispatch.**

## 5. Tenant/subscription prerequisites: PASS

- RP registration (connectivity sub, live today): Microsoft.Network, Microsoft.Resources,
  Microsoft.ManagedIdentity all **Registered** - teardown does not unregister; no first-apply
  registration wait.
- Quota (live `az network list-usages`, connectivity sub): eastus2 AND centralus each show
  PublicIPAddresses 0/20 (need 4 total, max 3 in eastus2), IPv4StandardSkuPublicIpAddresses 0/20,
  VirtualNetworks 0/1000. Azure Firewall and VPN GW counts are not offer-capped for this sub -
  evidenced by the identical prior deploy on this same subscription/offer (2 Premium firewalls +
  VpnGw1AZ built 2026-07-06). No SQL/App-Service-class offer-cap surface in this root.
- Network Watchers: `NetworkWatcherRG` with NetworkWatcher_eastus2 + NetworkWatcher_centralus
  SURVIVED teardown (1/1 at quota in both regions). Good on two counts: the VNet creates will not
  race an auto-create, and the watcher objects B1-class lookups expect in this sub already exist.
- RBAC: Contributor + UAA at the connectivity sub verified live 2026-07-12 and unchanged since
  (nothing in B0a touched sub-scope grants). No MG-scope writes in this root. The still-live
  ADR-041 temp tenant-root grants are irrelevant to this apply either way.
- GitHub side: fed cred `github-banking-branch` verified live during B0a and used by the plan run
  itself 2026-07-16 (strongest possible evidence). All TF_VARs resolved in the plan run - the
  green plan is the proof. Environments remain ungated (OQ-015 accepted interim). ADR-025 settle
  gate (3 consecutive state-SA probe successes) is on banking and ran in the plan run.

## 6. Apply-duration vs token lifetime: ACCEPTABLE, with a pre-agreed mid-apply-death disposition

- Estimate for 702 adds: 89 zones + 178 links + telemetry are fast bulk API calls; the long poles
  are the 2 Premium firewalls (~10-20 min each, parallel) and the VpnGw1AZ active-active VPN GW
  (~30-50 min, the single longest create). Realistic wall time 60-100 min. GitHub job timeout is
  the 360-min default (no `timeout-minutes` override in `_tf-root.yml`).
- Auth: `ARM_USE_OIDC=true` - azurerm requests a FRESH GitHub OIDC assertion whenever it needs a
  new access token, so token refresh spans a multi-hour apply. The identity-root 3h failure class
  needed a single blocking create longer than the refresh machinery plus trailing second-provider
  ops; nothing here approaches that (no azuread provider in this root, longest create well under
  1h). Nothing has been added to the root since the 2026-07-06 deploy (git log confirms last
  functional commit 2792a87).
- Pre-agreed disposition if the run dies mid-apply (transient/timeout class): resources stay in
  state, the rerun plans only the remainder and is short. This root's own history proves partial
  applies resume cleanly (2026-07-06 arc finished a partial in a 0-add follow-up). One
  consolidated fix-spec per failure set (LESSON 59); do not spray reruns.

## 7. Cost re-activation: known and accepted

This apply restarts the big idle meters that B0a deliberately left down: 2 Azure Firewall Premium
(~$1.75/hr each) + VpnGw1AZ (~$0.36/hr) + resolver/PIPs, roughly $2,700-3,000/month while up.
That is the priced-in B0b step per the split-B0 decision (OQ-034 resolution); no new decision
needed. DDoS Standard stays off.

---

## Ordered execution runbook

1. PC-1 code-state check (devsecops): `git diff bbde824..origin/banking -- platform/connectivity`
   must be empty; then dispatch `deploy.yml` `target=platform/connectivity` `action=apply` from
   `banking`. Single-target run -> `manage_runner_ip=true` -> JIT state-SA window + settle gate.
2. PC-2 plan-scan on the run's refreshed plan: ~702/0/0 pure adds, 0 replace, 0 DDoS plan,
   0 bastion, 2 Premium firewalls, 4 PIPs. Any deviation = STOP, architect disposition before any
   retry.
3. Apply completes. Capture outputs from the run log.
4. PC-3 post-apply gate, before B1: qa-engineer live-vs-intent pass; verify the 8 hub Secrets
   (check 8 below); confirm firewall private IPs are 10.0.0.4 / 10.1.0.4; note the
   `primary_dns_resolver_inbound_ips` output state.

## Watch-items during the apply (dispositions pre-agreed)

| Symptom | Disposition |
|---|---|
| Stale state lease at init | CI `force-unlock` (single target + lock_id), then re-plan |
| State-SA 403 mid-run despite settle gate | Rerun (state holds, remainder is short); if it recurs, escalate to architect - do not loop |
| Any `-/+ replace` in the refreshed plan (esp. firewall PIPs, issue #4196 class) | STOP. Not possible on empty state; its appearance means state is not empty - diagnose before anything else |
| Zone/link create throttling (429) on the 89-zone bulk | Provider retries handle it; if the run still dies, plain rerun - links are idempotent in state |
| Peering eventual-consistency error right after VNet create | Single rerun; module sequences internally, residual races clear on retry |
| VPN GW create exceeds ~60 min but run alive | Wait - normal variance up to ~90 min; only a hard run failure triggers the rerun path |
| DINE remediation failures on new resources (Deploy-Diag-LogsCat etc.) | OQ-021 noise; never blocks; ignore |
| Post-apply plan shows CreatedDate tag drift | OQ-032 accepted estate behavior; not a defect |

## 8. Hand-off to B1 (what must happen between apply-success and any B1 plan)

The 8 hub repo Secrets (PRIMARY/SECONDARY_HUB_VNET_ID/_VNET_NAME/_RG_NAME,
PRIMARY/SECONDARY_FIREWALL_PRIVATE_IP) hold pre-teardown values. Every one of them is
DETERMINISTIC under this redeploy: RG/VNet names are fixed strings, sub ID unchanged, and the
firewall private IPs are the first usable address of each fixed AzureFirewallSubnet carve
(10.0.0.4 / 10.1.0.4 - Azure reserves .0-.3). Expected outcome: all 8 match and need no update.
The gate is VERIFY, not assume - compare each against live outputs post-apply and update any
mismatch before B1 plans (B1's data lookups also need the 3 private DNS zones in the rg-dns RG,
which this apply creates, and the network watcher, which already exists). PLATFORM_LAW_* secrets
stay valid (the LAW was recovered in-window, QA-confirmed 2026-07-16). Separately, OQ-035
landingzones-sub quota verification remains a B1-apply gate, not a B0b item.

---

## ADDENDUM 2026-07-17: run 29625961118 cancelled, root re-scoped to the lean (no-appliance) hub - ADR-042

**What changed.** The apply this document cleared was dispatched (PC-1/PC-2 passed) and then
CANCELLED ~12 min in on a user scope decision: hub network fabric now, paid appliances later
(ADR-042). The root is being re-scoped behind three default-false flags (`enable_firewall`,
`enable_vpn_gateway`, `enable_dns_resolver`); the firewalls, their PIPs, the firewall policies,
both per-hub route tables (module-gated with the firewall), the VPN Gateway + GatewaySubnet, and
the DNS Private Resolver drop out of the next apply. The cancel SIGKILLED Terraform: 13 resources
landed with unknown state coverage; the firewall and both firewall PIPs are already being deleted
out-of-band.

**What carries from the original clearance (valid for the lean subset, which is a strict subset
of the cleared shape):**
- Check 1/1a policy matrix: unchanged - the lean root creates fewer types, all already cleared.
- Check 2 soft-delete/name-reuse: unchanged (still no KV, no SA; now also fewer PIP names).
- Check 4 provider/module pins + known-issues: unchanged pins; firewall-PIP issue #4196 and the
  VPN GW issues become moot while gated. Lifecycle audit: still current; the 2026-07-25 recheck
  clock still applies, and the appliance types must be RE-AUDITED at whatever wave re-enables them.
- Check 5 tenant prereqs/quota: unchanged; PIP quota need drops from 4 to 0.
- Check 6 duration: improves - the two long poles (firewalls, VPN GW) are gone; expect a much
  shorter apply dominated by the 89-zone/178-link bulk.
- Check 7 cost: SUPERSEDED by ADR-042 - lean hub ~$20-40/mo; the ~$2.7-3k/mo reactivation does
  NOT happen at B0b.

**Void:** PC-1 (code identity with bbde824) and PC-2 (~702-add plan shape) are void - the gating
change intentionally alters both.

**New preconditions for the lean apply (replace PC-1/PC-2; PC-3 amended):**

| # | Precondition | Lane |
|---|--------------|------|
| PC-1L | Recovery runbook complete BEFORE dispatch: (a) confirm the in-flight deletions of fw-hub-eastus2-001 + both fw PIPs finished; (b) delete resource groups `rg-connectivity-primary-globaris-poc` and `rg-connectivity-secondary-globaris-poc` wholesale - this removes all 8 surviving orphans (2 hub VNets, 2 fw policies, 4 route tables) in two operations; do NOT touch `NetworkWatcherRG` (pre-existing, shared, expected by B1); `rg-dns` was never created. Rationale: every survivor is minutes old, empty, and stateless - delete-and-clean-create beats import (ADR-042); the fw policies and route tables are not even in the lean config. (c) Check the state lease; if stuck from the SIGKILL, run the CI force-unlock action with the lock ID. State entries for out-of-band-deleted resources self-resolve at refresh; after (b) nothing in state can still be live, so the plan MUST be pure creates. | operator + devsecops |
| PC-2L | Dispatch plan/apply from `banking` at the commit carrying the ADR-042 gating change (code-reviewed). Plan-scan: roughly 675-680 to add, 0 to change, 0 to destroy, 0 replace. Specifically: 0 azurerm_firewall, 0 azurerm_firewall_policy, 0 azurerm_public_ip, 0 route tables/routes, 0 VPN gateway, 0 GatewaySubnet, 0 AzureFirewallSubnet, 0 DNS resolver, 0 DDoS plan, 0 bastion; still present: 3 RGs, 2 hub VNets, hub-to-hub mesh peering (both directions), dns-resolver-outbound subnet, 89 zones + 178 links. ANY destroy or replace = STOP (state was not clean - back to PC-1L, architect disposition). One consolidated disposition per failure set (LESSON 59). | devsecops + architect scan |
| PC-3L | Post-apply, before any B1 plan: qa-engineer live-vs-intent pass against the LEAN intent (absence of the gated resources is intent, not drift). Secret verification amended: the 6 VNet/RG secrets verify against live outputs as before; PRIMARY/SECONDARY_FIREWALL_PRIVATE_IP verify against the carve math (10.0.0.4 / 10.1.0.4 per ADR-042) because the root's firewall-IP outputs are null while gated - do NOT blank or "fix" these secrets. `primary_dns_resolver_inbound_ips` is null while gated: expected. | qa-engineer + operator |

**Watch-item deltas:** the VPN-GW-duration and firewall-PIP-replace rows in the watch-item table
are moot while gated (the #4196 tripwire re-arms at the wave that flips `enable_firewall`). All
other rows stand, including the stuck-lease and 429-bulk-zone rows. New row: a 409
already-exists on ANY create means PC-1L(b) was incomplete - STOP, enumerate the sub, delete the
survivor, rerun; do not import mid-incident.

### PC-2L scan disposition, 2026-07-17 (architect): APPROVED - single consolidated ruling (LESSON 59)

Plan run 29627562853 (banking @ 6b76623, post-ADR-042 gating, post-PC-1L runbook + force-unlock
run 29627514245) printed `630 to add, 4 to change, 20 to destroy` against the PC-2L bar of pure
adds. Deviations dispositioned as ONE unit:

- **20 destroys: APPROVED.** All are `modtm_telemetry`/`random_uuid` pairs inside the five gated
  firewall submodule chains (fw_default_ips, fw_policies, hub_firewalls, hub_routing_firewall,
  hub_routing_user_subnets, x2 hubs), recorded in state by the killed apply and config-removed by
  the gating. These are state-only pseudo-resources; destroying them performs no ARM mutation.
  The LESSON 26 stop-rule targets live-resource destroys/replaces; none exist here (0 replaces,
  grep-verified).
- **4 changes: APPROVED.** rg-dns tag update is the accepted OQ-032 CreatedDate-strip class; the
  3 modtm payload updates are config-hash noise from the gating.
- **630 adds vs the 675-680 estimate: RECONCILED, bar amended to the 630/4/20 shape.** The gap is
  state-satisfied no-ops (surviving telemetry pairs of non-gated submodules, time/random anchors,
  watchers) plus rg-dns moving from create to change. Zero firewall/VPN-GW/resolver/route-table/
  PIP/GatewaySubnet/AzureFirewallSubnet resources in the creates (grep-verified), 0 DDoS,
  0 bastion.
- **PC-1L runbook deviation RATIFIED:** `rg-dns-globaris-poc` survived the killed apply (RGs were
  outside the resource-level enumeration) and was correctly LEFT in place - it is empty, in the
  lean config, and in state, so refresh reconciles it as a benign tag-only change. No action.

Conditions on the apply: (1) destroy set at apply time must remain exactly the 20
modtm/random_uuid addresses - any azurerm/azapi destroy appearing = STOP; (2) post-apply
spot-check that the 89 zones (including B1's 3 lookup zones) and 178 links landed in
`rg-dns-globaris-poc`; (3) PC-3L stands unchanged (lean-intent QA, 6 VNet/RG secrets vs live
outputs, IP secrets verified against carve math, null resolver output expected); (4) first
post-apply plan will show OQ-032 CreatedDate drift on new resources - accepted noise, not a
defect.
