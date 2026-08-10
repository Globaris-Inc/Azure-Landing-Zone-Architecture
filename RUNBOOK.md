# RUNBOOK.md - Operational Runbooks

> Section 11 documentation deliverable (PROMPT.md item 3). Concrete, step-by-step operational procedures for the
> **as-deployed** Globaris CAF Azure Landing Zone POC. Three runbooks: (A) DR failover drill, (B) incident
> triage, (C) cost-spike response. Procedures use the real resource names, roots, and CI actions that exist in
> the estate.
>
> Cross-references: `ARCHITECTURE.md` (topology, RTO/RPO), `SECURITY.md` (threat model, posture),
> `DECISIONS.md` (ADRs).

---

## 0. Operator prerequisites and the CI action model

**How operators act on this estate.** All infrastructure mutation goes through the GitHub Actions workflow
`.github/workflows/deploy.yml`. Operators do **not** run `terraform apply` locally. The workflow exposes four
actions via `workflow_dispatch`:

| Action | Purpose | Gating | Extra input |
|--------|---------|--------|-------------|
| `plan` | Dry-run, read-only | Ungated | - |
| `apply` | Mutate infra | Runs in the `production` GitHub Environment (**required reviewer**) | - |
| `untaint` | Clear a tainted resource from state (single root only) | Ungated (plan-path OIDC) | `resource_address` |
| `force-unlock` | Release a stuck state-lock lease (no Azure mutation) | Ungated | `lock_id` (GUID) |

`target` selects a single root (e.g. `landing-zones/corp-a2`, `platform/security`) or `all`. `untaint` and
`force-unlock` **require a single target** - the workflow has fail-fast guards that reject `target = all` for
those two (a per-root state write must not fan out across roots).

**Standing accounts to know:** the CI OIDC service principal (no secrets; federated credential) performs all
applies. Two temporary Entra directory roles and the CI SP standing Owner-at-MG grant (OQ-008) must be revoked
at teardown - see the teardown note in WORKLOG.

**Resource-name patterns used below** (org prefix `globaris`, environment `poc`):

| Resource | Name / pattern |
|----------|----------------|
| Platform LAW (ops, management sub) | `law-platform-globaris-poc` |
| Security LAW (Sentinel/SecOps, security sub) | `law-security-globaris-poc-r5` (ADR-075 generation suffix; the unsuffixed name is burned) |
| Platform action group (management sub) | `ag-platform-globaris-poc` |
| Sentinel scheduled rules | `ar-<rule-key>-globaris-poc` |
| Sentinel MDC incident rule | `ar-mdc-high-globaris-poc` |
| MDC continuous export automation | `automation-mdc-export-globaris-poc` |
| Live Sentinel connector | `dc-mdc-globaris-poc` (subscription-scoped Defender for Cloud) |
| Per-sub budgets / exports | `budget-sub-<sub>-globaris` / `export-daily-<sub>-globaris` |
| MG budgets | `budget-mg-{globaris,platform,landingzones}-globaris` |
| Cost anomaly alert | `anomaly-alert-management-globaris` |
| DR spoke | corp-a2, centralus, `10.11.0.0/16`, RSV GeoRedundant |

---

## Runbook A - DR failover drill (primary eastus2 -> secondary centralus)

### A.0 Scope and honesty note

This drill exercises **topology-level failover**: the ability of the secondary region (centralus) to stand up a
corp workload path when the primary region (eastus2) is degraded. It uses the hub-to-hub Global VNet Peering,
the secondary hub's Azure Firewall Premium, the standby **corp-a2** spoke, and the corp-a2 Recovery Services
Vault.

**Be explicit about what is and is not live:** corp-a2 is the **cold-standby DR landing zone**. Its App Service
and Azure SQL **workload tiers are gated off** (`enable_app_service = false`, `enable_sql = false`) because the
landingzones subscription offer-caps dedicated App Service compute and disables Azure SQL provisioning in these
regions (ADR-031 / ADR-032). So there is **no running application or database to fail over** in the current
estate. This drill therefore validates the DR *topology and readiness*, not an application cutover. Where a step
would act on the App Service / SQL tier, it is marked **[GATED - workload tier off]** with the action that would
run once the tier is enabled.

### A.1 RTO / RPO targets (POC, from ARCHITECTURE.md)

| Target | RTO | RPO | Mechanism |
|--------|-----|-----|-----------|
| Hub network connectivity | 30 min | N/A | Global VNet Peering between hubs; secondary Firewall Premium active |
| Private DNS resolution | Near-zero | N/A | Zones linked to both hubs; secondary resolves via primary resolver |
| SQL (corp-a1 -> corp-a2) | 1 h | 5 min | Active geo-replication **[GATED - SQL tier off]** |
| App Service (corp-a1 -> corp-a2) | 30 min | Near-zero | Manual cutover, pre-warmed corp-a2 **[GATED - App Service tier off]** |
| Spoke VM replication | 4 h | 15 min | ASR to corp-a2 RSV **[no IaaS VMs deployed]** |

These are demonstration targets, not contractual SLAs.

### A.2 Pre-drill checklist

1. Confirm both hubs are healthy: `plan` on `platform/connectivity` (`action = plan`, `target =
   platform/connectivity`) - expect **No changes** (zero drift is the QA baseline).
2. Confirm the DR spoke exists: `plan` on `landing-zones/corp-a2` - expect no destroys.
3. Confirm the corp-a2 RSV is present and GeoRedundant (portal: `rg-corp-a2-*` -> Recovery Services Vault ->
   Backup Infrastructure).
4. Announce the drill window and confirm no real change freeze conflicts.

### A.3 Failover procedure

**Step 1 - Declare the primary region impaired (drill trigger).** Record the start time. In a real event this
is an Azure Service Health regional advisory on eastus2.

**Step 2 - Verify the DR network path is live.** The secondary hub firewall and hub-to-hub peering are always
on (not standby-provisioned), so the DR path exists before any action:
- Confirm the hub-to-hub peering `vnet-hub-primary-...-to-vnet-hub-secondary-...` (and reverse) is `Connected`.
- Confirm the secondary hub Azure Firewall Premium is `Succeeded` / running in centralus.
- Confirm corp-a2 spoke peering `peer-corp-a2-to-secondary-hub` is `Connected`.
Result: east-west and egress for corp-a2 route through the centralus Firewall independently of eastus2.

**Step 3 - Confirm DNS resolves in the DR region.** From a host in corp-a2 (or via the DNS Private Resolver),
resolve a `privatelink.*` PaaS name and confirm it returns the private IP. The private DNS zones are linked to
both hubs, so resolution does not depend on eastus2. (The DNS Private Resolver itself lives in the primary hub;
secondary queries traverse the hub peering to reach it - if the primary hub network is fully down, add a
resolver to the secondary hub as the documented gap, see A.5.)

**Step 4 - Fail over the data tier. [GATED - SQL tier off]** When `enable_sql = true`: fail over the
active-geo-replicated SQL to the corp-a2 secondary (portal: SQL server -> Failover, or `az sql failover-group
set-primary`). Confirm the corp-a2 replica is now the read-write primary. **Today:** no SQL exists; record the
step as not-applicable and note the RTO/RPO target that would apply.

**Step 5 - Bring up / promote the app tier. [GATED - App Service tier off]** When `enable_app_service = true`:
confirm the pre-warmed corp-a2 App Service is healthy and cut traffic over (Traffic Manager / Front Door
endpoint priority, or DNS). **Today:** no App Service exists; record not-applicable.

**Step 6 - Spoke VM replication (if IaaS were present).** ASR enrollment targets the corp-a2 RSV
(GeoRedundant). There are **no IaaS VMs** in the workload tiers, so there is nothing to trigger. The RSV is
provisioned and ready to accept ASR replication when a VM tier is added.

**Step 7 - Validate the DR posture.** Confirm from the DR region: network egress works through the centralus
firewall, DNS resolves privately, and (when un-gated) the app answers and the DB is writable. Record the
achieved timings against A.1.

### A.4 Failback

1. Confirm eastus2 is healthy (`plan` on `platform/connectivity` clean).
2. **[GATED]** Reverse the SQL failover group back to corp-a1; re-warm corp-a1 App Service; cut traffic back.
3. Re-confirm both-hub peering `Connected` and DNS resolution from the primary region.
4. Record failback time and close the drill.

### A.5 Known DR gaps to disclose in the drill report

- corp-a2 workload tiers (App Service + SQL) are gated off - this is a *readiness* drill, not an app cutover
  (ADR-031/032).
- The DNS Private Resolver is primary-hub-only; a full primary-region outage would need a resolver added to the
  secondary hub (documented cost trade-off, ARCHITECTURE.md).
- No IaaS VMs, so ASR replication is provisioned-but-unused.
- centralus has no VPN Gateway (primary-only, cost); secondary uses the primary VPN via hub peering and
  gateway transit.

---

## Runbook B - Incident triage (Sentinel incident + Defender for Cloud alert)

### B.0 Where the signals live

- **Microsoft Sentinel** is onboarded to the **security LAW** (`law-security-globaris-poc-r5`, ADR-075) in the
  security subscription. This is the SecOps workspace.
- **Platform LAW** (`law-platform-globaris-poc`) in the management subscription is the operations workspace and
  holds Azure Firewall diagnostics + spoke VNet flow logs + Automation diagnostics. Cross-workspace query
  between the two is proven.
- **Defender for Cloud** alerts flow into Sentinel via the `dc-mdc-globaris-poc` connector and surface as
  incidents through the `ar-mdc-high-globaris-poc` MS-security-incident rule (High severity).
- **Analytics rules** (9 scheduled live + the MDC incident rule) are named `ar-<key>-globaris-poc`. Live
  scheduled rules: `brute_force_entra`, `blocked_country_signin`, `legacy_auth_attempt`, `kv_bulk_secret_access`,
  `pim_after_hours_activation`, `mass_resource_deletion`, `anonymous_storage_access`, `new_global_admin`,
  `mfa_disabled_for_admin`. (`firewall_threat_intel_hit` is gated off - ADR-034.)
- **Automation rules:** `auto_assign` (assigns new incidents to the SecOps owner group, if configured) and
  `ti_enrichment_tag` (labels High-severity incidents `TI-enrichment-needed`).
- **Notifications:** the platform action group `ag-platform-globaris-poc` (email receivers) is the routing
  target for budget/monitor alerts. Sentinel incident assignment is handled by the `auto_assign` automation
  rule.

**Honesty note:** with the synthetic signal generator deferred (ADR-036/037) and the tenant-scoped connectors
gated off (dc-aad, dc-ti, dc-mde, UEBA - ADR-033/034), there is **no live Entra SigninLogs / TI feed** and **no
manufactured incidents** in the current estate. Identity-sourced rules (e.g. `brute_force_entra`,
`blocked_country_signin`) will not fire until dc-aad is enabled. This runbook is written for when signals are
present (persistent environment or after the connector grant).

### B.1 Triage a Sentinel incident

1. **Pick up the incident.** Sentinel -> Incidents (on `law-security-globaris-poc-r5`, ADR-075). If `auto_assign` is
   configured, new incidents are already assigned to the SecOps owner group; otherwise assign yourself.
2. **Read the rule context.** The incident title maps to an `ar-<key>-globaris-poc` rule. Open the rule to see
   its MITRE tactics/techniques and KQL. Example: `ar-brute_force_entra-globaris-poc` = >= 10 failed
   interactive sign-ins for one UPN in 5 min (CredentialAccess / T1110).
3. **Investigate entities.** Use the incident's mapped Account entity (most rules map a `FullName` account from
   a UPN, caller, or app id). Pivot on the entity in the investigation graph.
4. **Check watchlists.** If a `VIPUsers` or `HighValueAssets` watchlist is populated, confirm whether the entity
   is high-value (elevate severity/priority accordingly).
5. **Cross-workspace corroboration.** For network-adjacent incidents, query the platform LAW for Firewall /
   flow-log context: `workspace('law-platform-globaris-poc').AzureDiagnostics | where Category startswith
   "AzureFirewall"`.
6. **Classify and act.** Confirm true/false positive. For a confirmed identity compromise: disable the account,
   revoke sessions, and (path) flip the relevant CA policy from report-only to enforce once break-glass is in
   place (SECURITY.md section 5). For confirmed exfiltration: isolate the storage/KV resource.
7. **Close the incident** with a classification (TruePositive / BenignPositive / FalsePositive) and a reason;
   tune the rule threshold in `sentinel/tuning.md` if it was noise.

### B.2 Triage a Defender for Cloud alert

1. **Source.** High-severity MDC alerts auto-create Sentinel incidents via `ar-mdc-high-globaris-poc`. You can
   also work them directly in Defender for Cloud -> Security alerts on the security subscription.
2. **Read the recommendation / attack path.** With Defender CSPM (CloudPosture plan) enabled, use the attack-path
   and asset-graph view to see blast radius.
3. **Continuous export context.** Alerts + assessments are streamed by `automation-mdc-export-globaris-poc` to
   both the security LAW and the MDC Event Hub (`evh-mdc-export`) for any downstream SIEM.
4. **Remediate.** Apply the Defender recommendation (e.g. enable a missing control). Regulatory compliance is
   audit-only (`enforce = false`), so remediation is operator-driven, not automatic.
5. **Correlate to compliance.** Check whether the alert maps to a NIST SP 800-53 R5 or CIS Azure 2.0.0 control
   in the regulatory-compliance dashboard; record the control if it affects posture reporting.

### B.3 Escalation and notification

- Monitor/budget alerts route to `ag-platform-globaris-poc` (email). Extend this action group with additional
  receivers (SMS, webhook, ITSM) for a persistent environment.
- Sentinel incident ownership is set by the `auto_assign` automation rule; configure
  `sentinel_owner_group_object_id` to activate it.

---

## Runbook C - Cost-spike response (budget breach -> investigate -> remediate)

### C.0 The FinOps signals in the estate

- **Budgets** at three MG scopes (`budget-mg-globaris-*`, `budget-mg-platform-*`, `budget-mg-landingzones-*`)
  and per subscription (`budget-sub-<sub>-globaris`), each with alert thresholds at 50/75/90/100%, emailing the
  configured FinOps contacts.
- **Cost anomaly alert** `anomaly-alert-management-globaris` (management subscription scope) - fires on an
  anomalous cost pattern independent of the fixed budget thresholds.
- **Daily cost exports** `export-daily-<sub>-globaris` writing FOCUS-aligned data to the cost-exports storage
  account (management sub, `rg-finops-*`), one root folder per subscription.
- **Tag governance** initiative at MG scope (Modify + audit) so cost is attributable by `CostCenter`, `Owner`,
  `Workload`, `BusinessUnit`.
- **Carbon Optimization workbook** (placeholder JSON - replace before a live demo).

### C.1 On a budget breach alert

**Step 1 - Read the alert.** Identify which budget fired (`budget-sub-*` vs `budget-mg-*`) and which threshold
(50/75/90/100%). A 100% breach on `budget-sub-landingzones-globaris` points at the workload subscription; an MG
breach points at aggregate platform spend.

**Step 2 - Confirm it is real, not a false spike.** Cross-check with the `anomaly-alert-management-globaris`
anomaly alert - a budget breach plus an anomaly alert together strongly indicates a genuine spend change.

**Step 3 - Investigate via cost exports / Cost Management.**
- Open Cost Management for the flagged scope: group by Resource Group, then by Service, then by Resource, over
  the alert window.
- Or query the daily export in the cost-exports SA (`export-daily-<sub>-globaris` root folder) for the offending
  subscription and sort by cost delta day-over-day.
- Use tags (`Workload`, `Owner`, `CostCenter`) to attribute the spike to a team/workload. Untagged spend is a
  governance smell (tag-governance Modify should backfill missing tags).

**Step 4 - Identify the driver.** Common candidates in this estate:
- A firewall / gateway SKU left running (VpnGw1AZ, Firewall Premium, an on-demand Bastion left up).
- An un-gated workload tier if `enable_app_service` / `enable_sql` were flipped on.
- Log ingestion growth into a LAW (PerGB2018) - check ingestion volume.
- The Event Hub namespace auto-inflate on MDC export.

**Step 5 - Apply the FinOps levers.**
- **On-demand resources:** turn off the Bastion (`enable_bastion = false`) and any on-demand SKU when idle -
  these are default-off by design (ADR-015).
- **Gated tiers:** confirm `enable_app_service` / `enable_sql` are `false` if the corp workload tiers are not
  intended to run (ADR-031/032).
- **Right-size:** reduce LAW retention or the Event Hub throughput units; drop a SKU tier where the POC does not
  need it.
- **Tighten the budget / tags:** lower the offending budget amount to catch the pattern earlier; enforce missing
  tags via the tag-governance initiative.
- **DDoS Standard** stays off (default) - do not enable it as a cost reaction; it is a large fixed cost
  (ADR-013).

**Step 6 - Remediate through CI.** Any change to a SKU or gate is a Terraform change: edit the relevant var in
`envs/poc.tfvars`, run `action = plan` on the affected root to confirm the delta, then `action = apply`
(reviewer-gated) on that single target. Do not change infra outside the pipeline.

**Step 7 - Record and close.** Note the driver, the lever applied, and the projected monthly saving. If the
spend was legitimate, adjust the budget baseline and update the README cost estimate (COST.md) so future alerts
stay meaningful.

### C.2 Emergency spend brake

If spend is runaway and a specific root is the driver, the fastest safe brake is to gate the offending tier off
(flip its `enable_*` var to `false`) and `apply` that single root. There is no automatic stop-runbook wired in
the current estate (the synthetic hard-budget kill-switch from Section 13 is not deployed - ADR-036). For a
persistent environment, wire an action-group-triggered Automation runbook to deallocate/stop on a 100% breach.

---

## Appendix - ADR index (operations-relevant)

| ADR | Relevance |
|-----|-----------|
| ADR-009 | Independent per-hub firewall policies (DR: each region self-contained) |
| ADR-015 | On-demand Bastion, default off (cost lever) |
| ADR-029 | Entra DS recovery; OIDC token-expiry on long applies (keep applies short) |
| ADR-031 / ADR-032 | corp-a2 SQL + App Service tiers gated off (DR drill is topology-level) |
| ADR-033 / ADR-034 | Sentinel connectors + firewall TI rule gated (triage has no live identity/TI feed) |
| ADR-036 / ADR-037 | Synthetic signal generator deferred (no live incidents / no cost kill-switch) |
