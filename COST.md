# COST.md - Estimated Monthly Cost + FinOps Levers

> **Section:** 11 (Documentation Deliverables), item 5. See [PROMPT.md](PROMPT.md) §7 (FinOps) and §11.
> **Scope:** the estate as actually deployed and gated today (see [WORKLOG.md](WORKLOG.md) Section Status
> Tracker and [ARCHITECTURE.md](ARCHITECTURE.md)). Config sourced from [`envs/poc.tfvars`](envs/poc.tfvars).
> **Last updated:** 2026-07-11

---

## Read this first - these are estimates, not a bill

Every figure below is a **list-price estimate** at **POC scale**, computed from public Azure retail prices for
US regions (`eastus2` primary, `centralus` DR), using **730 hours/month**. They are **not** billed actuals and
carry **no** Enterprise Agreement / MCA discount, reservation, or Azure Hybrid Benefit. Data-plane charges
(egress, log ingestion, backup storage, per-transaction Defender) scale with real traffic, which a POC with no
live workload keeps near the floor. Treat the numbers as a planning envelope, and reconcile against Azure Cost
Management once the estate has run for a full billing cycle (the FinOps cost export and budgets described in §7
exist precisely for that reconciliation).

**Headline:** as deployed and gated today the estate lands at roughly **$3,600 to $4,800 per month**. The two
**Azure Firewall Premium** instances alone are ~$2,555/mo fixed (about 55-65% of the bill), so they plus the
**Defender for Cloud** plans are the dominant cost levers. Prices flagged with a dagger (`†`) are the ones I am
least certain of - see [Prices I was unsure about](#prices-i-was-unsure-about).

---

## Per-component estimate (as-deployed, gated)

The "as-deployed" column reflects the live gating: DDoS off, corp App Service + SQL gated off (ADR-031 /
ADR-032), Bastion on-demand and idle (ADR-015), synthetic layer deferred (ADR-036 / ADR-037).

| # | Component | Where | Unit basis (list price) | Est. monthly (USD) |
|---|-----------|-------|--------------------------|--------------------|
| 1 | **Azure Firewall Premium x2** (fixed) | connectivity, both hubs | $1.75 / deployment-hour x 730 x 2 | **~$2,555** |
| 2 | Azure Firewall data processing | connectivity | $0.016 / GB (POC traffic low) | ~$5 - $30 |
| 3 | **VPN Gateway `VpnGw1AZ`** (primary, active-active) | connectivity primary hub | ~$0.36 / hour x 730 `†` | ~$260 `†` |
| 4 | **DNS Private Resolver** (inbound + outbound endpoints) | connectivity primary hub | $180 / mo per endpoint x 2 `†` | ~$360 `†` |
| 5 | **App Gateway WAF_v2** (capacity 1) | online-p1 | $0.443 / gw-hr x 730 + ~1 CU x $0.0144 x 730 | ~$335 |
| 6 | Log Analytics x2 workspaces (ingest + retention) | management LAW + security LAW | ~$2.76 / GB ingest; +$0.10 / GB-mo over 31d | ~$60 - $150 |
| 7 | Microsoft Sentinel (analytics on security LAW) | security | per-GB analyzed (POC low; some free tier) | ~$0 - $50 |
| 8 | **Defender for Cloud plans** (Standard) | all subs | per-resource, see breakdown below | ~$75 - $250 |
| 9 | Event Hub (Standard, 1 TU) - MDC export | security | ~$0.03 / TU-hr + per-event ingestion | ~$25 |
| 10 | **Entra Domain Services** (Standard managed domain) | identity | ~$0.15 / hour x 730 | ~$110 |
| 11 | Recovery Services Vaults x3 (corp-a1 ZRS, corp-a2 GRS, identity) | landing zones + identity | vault free; pay per protected instance + backup storage | ~$5 - $30 |
| 12 | Static Web App (Standard) | online-p1 | ~$9 / mo per app | ~$9 |
| 13 | Private DNS zones (89) | connectivity (`rg-dns-globaris-poc`) | $0.50 / zone (first 25) + $0.10 / zone after + query | ~$20 - $30 |
| 14 | Storage - GZRS finops + CMK state SA + cost exports | connectivity / management | GZRS ~2x LRS; low volume | ~$10 - $30 |
| 15 | Public IPs (Standard static: 2x firewall, VPN GW, App GW) | connectivity + online-p1 | ~$3.65 / IP-mo | ~$15 - $30 |
| 16 | VNet peering data transfer (incl. global hub-to-hub) | connectivity | ~$0.035 / GB each direction (POC low) | ~$5 - $20 |
| 17 | Automation Account + Update Manager | management | base free; runbook minutes minimal | ~$0 - $5 |
| 18 | Budgets, cost anomaly alerts, cost export, tag policy | management + management-groups | Azure Cost Management + Policy | $0 (free) |
| | **Estimated total (as-deployed, gated)** | | | **~$3,600 - $4,800 / mo** |

### Defender for Cloud plan detail (row 8)

Defender is billed **per protected resource**, so the total tracks the resource count, which the gating keeps
low. The plans onboarded (per [ARCHITECTURE.md](ARCHITECTURE.md) and `platform/security`):

| Plan | List basis | POC exposure |
|------|-----------|--------------|
| Servers P2 | ~$15 / server-mo | Near $0 - Entra DS DCs are managed (not billable VMs); no spoke VMs |
| Storage (DefenderForStorageV2) | ~$10 / storage account-mo + malware scan per GB | Several storage accounts - a few tens of $ |
| Key Vault | ~$0.02 / 10K transactions | Cents at POC transaction volume |
| Resource Manager (Arm) | per subscription | Small, per-sub (held as latent debt, ADR-034) |
| Containers | per vCore-hour | $0 - no AKS / container hosts |
| App Service | ~$14.60 / instance-mo | $0 - App Service gated off (ADR-032) |
| SQL (servers / SQL-on-VM) | ~$15 / server-mo | $0 - SQL gated off (ADR-031) |
| CSPM (CloudPosture) | foundational free; advanced per-resource | Low |

> With App Service and SQL gated off and no billable VMs, Defender sits at the **low** end of its range today.
> Turning the corp workload tiers on (App Service + SQL) would add both the compute cost **and** the matching
> Defender plan cost, which is why item 8 is a top production lever, not just a POC line.

---

## What the total is NOT counting (gated / deferred today)

These are **off** in the live estate, so they are excluded from the total above. This is the FinOps story: the
architecture is faithful, but the expensive knobs are deliberately turned down for the POC.

| Deferred / gated item | If enabled | Monthly delta | Reference |
|-----------------------|-----------|----------------|-----------|
| **DDoS Network Protection** | `enable_ddos_standard = false` | **~+$2,944** (flat plan) | ADR-026, [`envs/poc.tfvars`](envs/poc.tfvars) |
| **corp App Service tier** (B2) | `enable_app_service = false` | ~+$25 - $60 compute + Defender for App Service | ADR-032 |
| **corp SQL tier** (Basic/5 DTU) | `enable_sql = false` | ~+$5 - $15 + Defender for SQL | ADR-031 |
| **Azure Bastion** (Standard) | `enable_bastion = false` (idle = $0) | ~+$140 while running | ADR-015 |
| **Synthetic workload layer** | `enable_synthetic_workload = false` | ~+$50 - $150 (ACI, k6, idle demo VM, disks) | ADR-036 / ADR-037 |
| Second-hub DNS Private Resolver | present in primary only today `†` | ~+$360 if added to DR hub | see §4 note |

---

## FinOps levers

### Already pulled for cost (the POC is cost-tuned by design)

- **DDoS Network Protection is off** - the single biggest saving, ~$2,944/mo avoided. The ALZ `Enable-DDoS-VNET`
  Modify policy is also neutralised (`DoNotEnforce`) so it does not inject a plan (ADR-026).
- **corp App Service + SQL tiers gated off** - the corp spokes stand as **network** landing zones (VNet, peering,
  NSG, UDR-to-firewall, RSV, flow logs, policy), with the billable app + database tiers pre-staged behind
  single-variable flags (ADR-031 / ADR-032). Removes both the compute cost and the matching Defender plan cost.
- **Bastion is on-demand** - Standard Bastion costs $0 while `enable_bastion = false`; it is flipped on only for a
  session and back off, instead of running ~$140/mo idle (ADR-015).
- **Synthetic layer deferred** - no k6 load generator in ACI, no red-team simulator, no oversized idle demo VM or
  unattached premium disk drawing cost (ADR-036 / ADR-037).
- **VPN Gateway in the primary hub only** - the DR hub has no gateway; it transits via global VNet peering,
  avoiding a second ~$260/mo gateway (ARCHITECTURE.md DR topology).
- **Independent per-hub firewall policies** (no premium shared-policy tier), **single App Gateway capacity unit**
  (`appgw_capacity = 1`), and **7-day flow-log retention** (`flow_log_retention_days = 7`) all keep variable costs
  at the floor.
- **Budgets + anomaly alerts are live** - $200/sub (5 subs = $1,000/mo sub-scope ceiling) and $600 at MG scope,
  alerting at 50 / 75 / 90 / 100% (`budget_amount_per_subscription`, `budget_amount_per_mg`). Note: the estate's
  *modeled* run-rate (~$3,600-$4,800/mo) exceeds the per-sub budget once concentrated in the connectivity sub
  (the two firewalls sit there), so those thresholds will fire - by design, as an early-warning FinOps signal.

### What a production build would add (and cost)

- **Turn DDoS on** (~+$2,944/mo) for a faithful edge-security posture, driven by a single `enable_ddos_standard`
  toggle that also restores the `Enable-DDoS-VNET` policy enforcement (OQ-019).
- **Enable the corp workload tiers** - move App Service off the B2 POC SKU to `P1v3` (per the tfvars note) and
  bring SQL online in an unrestricted subscription/region; add the matching Defender plans.
- **Scale App Gateway WAF_v2** above capacity 1 and Log Analytics ingestion up as real traffic and Sentinel
  connectors (Entra ID, TI, MDE - currently gated) come online; both are per-unit / per-GB and grow with load.
- **Add a second-hub DNS Private Resolver**, run Bastion continuously, and lengthen backup/flow-log retention for
  forensic and DR requirements - each a bounded, known increment from the table above.
- **Reservations / savings plans** on the always-on fixed components (both firewalls, the VPN gateway, App
  Gateway) would materially cut the ~55-65% firewall share that dominates this estate.

---

## Prices I was unsure about

Called out honestly so a reviewer can re-verify before quoting these to a customer:

1. **`VpnGw1AZ` hourly rate (`†`, row 3).** Public sources disagreed: one search returned an implausible
   $1.34/hr (rejected - outside the documented $0.15-$0.55/hr gateway-SKU band), so I used **~$0.36/hr**
   (~$260/mo) as the zone-redundant VpnGw1 estimate. Re-confirm on the VPN Gateway pricing page for the exact
   `eastus2` `VpnGw1AZ` rate; active-active may add a second Standard public IP (~$4/mo) but is billed as one
   gateway resource.
2. **DNS Private Resolver endpoint count (`†`, rows 4 / second-hub row).** Priced as **one resolver in the
   primary hub with an inbound + outbound endpoint pair (~$360/mo)**. PROMPT §4/§8 call for "a resolver in each
   hub"; the ARCHITECTURE mermaid shows it in the primary hub only. If the DR hub also carries a resolver, add
   ~$360/mo. Confirm against the deployed `platform/connectivity` resolver resources.
3. **Defender for Cloud total (row 8).** Highly resource-count dependent; the ~$75-$250 range assumes today's
   gated resource set. It rises directly with any enabled workload tier.
4. **Log Analytics / Sentinel ingestion (rows 6 / 7).** Driven by real log volume, which a no-live-workload POC
   keeps near the floor; the range widens sharply under production traffic and once the gated Sentinel
   connectors are enabled.

---

## Sources

- [Azure Firewall pricing](https://azure.microsoft.com/en-us/pricing/details/azure-firewall/)
- [VPN Gateway pricing](https://azure.microsoft.com/en-us/pricing/details/vpn-gateway/)
- [Azure DNS (Private Resolver) pricing](https://azure.microsoft.com/en-us/pricing/details/dns/)
- [Application Gateway pricing](https://azure.microsoft.com/en-us/pricing/details/application-gateway/)
- [Web Application Firewall pricing](https://azure.microsoft.com/en-us/pricing/details/web-application-firewall/)
