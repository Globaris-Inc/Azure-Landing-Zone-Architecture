# 01-walkthrough.md — 15-minute scripted walkthrough

> Read aloud or use as the script for a recorded narration. Time budget per
> section is in the **(mm:ss)** marker after each header — total ~15 minutes.
> Companion artifacts: `02-failover-drill.sh`, `03-trigger-incidents.sh`,
> `04-reset.sh`, `05-screen-capture.md`.

---

## Prerequisites (read before recording, not on camera)

- `az login` against the demo tenant; current subscription set to the
  Landing Zones subscription.
- `var.enable_synthetic_workload = true` applied at least 24 hours before the
  demo — Defender / Advisor need that window to produce recommendations.
- Browser tabs prepared in this order (left → right):
  1. Azure Portal → **Management Groups** view
  2. Azure Portal → **Resource Visualizer** on `vnet-hub-primary-...`
  3. Azure Portal → **Microsoft Entra → Conditional Access**
  4. Azure Portal → **Microsoft Sentinel → Incidents**
  5. Azure Portal → **Microsoft Defender for Cloud → Recommendations**
  6. Azure Portal → **Cost Management → Cost analysis** (Landing Zones sub)
  7. Terminal pane with `synthetic/` working directory

---

## Scene 1 — Opening framing (00:00 → 00:45)

> "This is an Azure Landing Zone proof-of-concept built on the Microsoft
> Cloud Adoption Framework. The goal: show enterprise-grade controls — Zero
> Trust identity, hub-and-spoke connectivity, Defender + Sentinel, FinOps —
> all reproducible from Terraform, all measured by deliberate synthetic
> workload that lights up every detection layer."

Talking points:

- Code in this repo. Everything in the demo was applied via the CI pipelines
  in `.github/workflows/`.
- Subscription model: ADR-003 — 4 platform subs (Connectivity / Management /
  Identity / Security) + 1 shared Landing Zones + sandbox.
- Region pair: `eastus2` primary, `centralus` DR.

---

## Scene 2 — Management Group hierarchy (00:45 → 02:00)

**Tab:** Management Groups view.

Talking points:

- Custom Contoso root MG (`contoso`) under tenant root — ADR-007.
- Standard ALZ archetypes underneath: `platform` (connectivity / management /
  identity / security), `landingzones` (corp / online), `decommissioned`,
  `sandbox`.
- Built via `Azure/avm-ptn-alz` v0.19.1 — confirm by pointing at
  `platform/management-groups/main.tf:118`.
- Section 7 FinOps Modify policy is assigned at root; Section 6 NIST + CIS
  initiatives at root too — point to a child MG's "Compliance" blade and the
  inherited assignments.

---

## Scene 3 — Hub-and-spoke connectivity + Private DNS (02:00 → 04:00)

**Tab:** Resource Visualizer on the primary hub VNet.

Talking points:

- Two hubs: `vnet-hub-primary-...` (eastus2, 10.0.0.0/16) and
  `vnet-hub-secondary-...` (centralus, 10.1.0.0/16). Global VNet peering
  between them (Section 3).
- Azure Firewall Premium in each hub. Each spoke has a UDR forcing
  `0.0.0.0/0` through the firewall.
- Spokes: `corp-a1` (eastus2, 10.10/16), `corp-a2` (centralus DR mirror,
  10.11/16), `online-p1` (eastus2, 10.20/16 with App Gateway WAF_v2 ingress).
- Private DNS zones (`privatelink.database.windows.net` etc.) hosted in the
  Connectivity sub; all VNets linked. Section 4 wired the SQL DNS zone group
  so the corp-a1 SQL Private Endpoint resolves privately.

---

## Scene 4 — Zero Trust + Conditional Access (04:00 → 05:30)

**Tab:** Entra → Conditional Access policies list.

Talking points:

- 8 policies (CA-001 through CA-008) deployed in report-only mode by default
  (Section 5). Operator flips to enforced once break-glass is validated.
- Highlights: CA-001 admin MFA, CA-002 block legacy auth, CA-005 geo-block
  named locations (US/CA/GB approved), CA-007 block on high user risk.
- PIM eligible assignments (Owner / UAA / Security Admin at Globaris MG;
  Contributor at Landing Zones MG) require 8h max activation with MFA +
  justification. The break-glass group is excluded from every CA policy.

---

## Scene 5 — Defender for Cloud + Sentinel (05:30 → 08:00)

**Tab:** Defender for Cloud → Recommendations + Sentinel → Incidents.

Talking points:

- Defender plans extended in Section 6: AppServices, SqlServers, Containers,
  Dns, OpenSourceRelationalDatabases, CloudPosture. MDC continuous export
  → Security LAW + Event Hub.
- Sentinel detection layer: 4 connectors (AAD / MDC / MDE / Microsoft TI),
  UEBA + Entity Analytics, 2 watchlists (VIPUsers + HighValueAssets),
  10 scheduled analytics rules + 1 MS-incident rule mapped to MITRE ATT&CK.
- Compliance assignments: NIST SP 800-53 R5 + CIS Azure Foundations at the
  root MG scope.
- Switch to **Sentinel → Incidents**. Show any synthetic incidents already
  raised from the §13.3 red-team simulator (filter on
  `Purpose=SecuritySimulation` if pivoting via KQL).

---

## Scene 6 — FinOps (08:00 → 09:30)

**Tab:** Cost Management → Cost analysis on the Landing Zones sub.

Talking points:

- Section 7 deployed the Required-Tags policy initiative at the
  Landingzones MG (CostCenter / Owner / Workload / DataClassification /
  BusinessUnit / Environment). Modify effect backfills missing tags on
  existing RGs.
- Per-sub budget ($200/mo) + per-MG aggregate budget ($600/mo) with email
  notifications at 50/75/90/100%.
- Carbon Optimization workbook surfaces idle-asset signals. Cost exports
  flow daily to the GZRS storage account in the Management sub.

---

## Scene 7 — Synthetic workload tour (09:30 → 12:30)

**Tab:** Terminal pane (`cd synthetic`).

Run:

```bash
terraform output
```

Talking points while the output prints:

- **§13.1 workload targets.** `corp_a1_api_default_hostname` — a Node 20
  REST API stub on the corp-a1 App Service. Hit `/api/products`,
  `/api/login`, `/api/checkout`. `online_p1_contact_queue_url` — Storage
  Queue receiving the (deferred) contact form.
- **§13.2 k6 load generator.** Three Container Apps Jobs:
  `caj-k6-baseline-*` (5 VUs / business hours, weekdays),
  `caj-k6-spike-*` (50 VUs / 15 min, Tue + Thu noon ET),
  `caj-k6-anomalous-*` (200 VUs / 5 min, Sunday 3am ET with 60% failed-login
  bias + `x-test-geo` header).
- **§13.3 red-team simulator.** Five scenarios:
  `failed_signin_burst`, `impossible_travel_{east,west}` (two CAEs!),
  `resource_anomaly`, `storage_anomaly`, `kv_probing`. Decoy SA + decoy KV
  in the same RG. All tagged `Purpose=SecuritySimulation`.
- **§13.4 cost patterns.** Oversized Standard_D4s_v5 VM tagged
  `Optimization=Candidate`, unattached 32 GB Premium SSD, Hot-tier stale
  blobs, ungoverned RG, $1/mo budget that trips on day 1.

Optionally fire a manual incident burst:

```bash
./03-trigger-incidents.sh red-team
```

Then point at the Sentinel Incidents pane and explain the 5–10 minute
detection window.

---

## Scene 8 — Kill switch (12:30 → 13:30)

**Tab:** Terminal pane.

```bash
terraform plan -var-file=../envs/poc.tfvars -var='enable_synthetic_workload=false'
```

Talking points:

- Every synthetic resource gates on `local.enabled` (or its sub-gates
  `k6_enabled` / `red_team_enabled` / `red_team_signin_enabled` /
  `cost_patterns_enabled`).
- Setting the flag to `false` plans to **destroy** every synthetic resource
  — about 35 resources, applied in <5 minutes per the PROMPT.md §13.6
  acceptance criterion.
- The platform + landing zone stacks are untouched. The synthetic layer is
  truly drop-in / rip-out.

---

## Scene 9 — DR drill teaser (13:30 → 14:30)

**Tab:** Terminal pane.

Mention without running:

```bash
./02-failover-drill.sh --dry-run
```

Talking points:

- corp-a2 is a cold standby today (App Service Plan + App Service mirror,
  SQL Server + DB, GeoRedundant Recovery Services Vault all present from
  Section 9).
- The failover drill script wraps SQL Failover Group failover + App Service
  swap. ASR per PROMPT.md is conceptual here — the LZ spokes carry no IaaS
  VMs to replicate.
- Production path: add a SQL Failover Group between `sql-corp-a1-...` and
  `sql-corp-a2-...`, attach ASR to the §13.4 oversized VM, schedule a
  monthly drill.

---

## Scene 10 — Closing (14:30 → 15:00)

> "Everything you saw is reproducible from `git clone` + `terraform apply`.
> Detection, governance, and cost signals all come from real Azure controls
> firing on deliberately wasteful or hostile synthetic workload. The kill
> switch returns the environment to a clean platform-only state in under
> 5 minutes."

Final pointers:

- **Source of truth:** this repo. `CLAUDE.md` for operating rules,
  `PROMPT.md` for the original requirements, `WORKLOG.md` for the
  per-session build history, `DECISIONS.md` for the ADRs.
- **Open items:** OQ-008 (OIDC SP scope-down at §12), workbook JSON
  placeholders before a real demo, honeypot Entra user manual creation,
  pre-commit / drift detection / OPA (§10b/10c, ~Day 12).
