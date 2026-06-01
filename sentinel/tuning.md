# Sentinel Tuning — Noise Reduction & Threshold Rationale

> Section 6 deliverable per PROMPT.md.
> This file documents the rationale behind every Sentinel analytics-rule
> threshold, suppression decision, watchlist scope, and workbook-content gap
> in the POC. Treat it as the change log for detection engineering.

## How to use

Each analytics rule in `platform/security/sentinel.tf` ships with a POC-grade
threshold tuned for low telemetry volume. Production ingestion will exceed the
thresholds within minutes — re-baseline using the procedure in the
**Re-baselining workflow** section before letting the rules drive paging.

---

## Rule-by-rule tuning notes

| Rule key                  | Severity | Threshold (POC) | Reason this threshold | Production target |
|---------------------------|----------|-----------------|-----------------------|--------------------|
| `brute_force_entra`       | Medium   | ≥10 failed sign-ins in 5 min by same UPN | Catches scripted credential stuffing without firing on a user mistyping a password twice. | ≥20 in 2 min, joined against IP reputation. |
| `blocked_country_signin`  | High     | Any successful sign-in from outside US/CA/GB | CA-005 should block these — every hit is either a CA bypass, a travelling exec, or a break-glass account. Treat as a true positive until triaged. | Same, plus auto-suppression for VIP `travelMode=true` tag. |
| `legacy_auth_attempt`     | Medium   | Any attempt | CA-002 blocks legacy auth in `enabledForReportingButNotEnforced` mode initially. Detect every slip; tune to alert only on `ResultType==0` (successful legacy auth) once CA-002 is enforced. | Same. |
| `kv_bulk_secret_access`   | High     | ≥50 distinct secrets in 10 min by single caller | Even a CI pipeline rarely pulls more than 10–15 secrets per run. 50 in 10 min is harvesting. | ≥30 distinct + caller not in approved-pipeline watchlist. |
| `pim_after_hours_activation` | Medium | Any PIM activation 22:00–06:00 UTC | Picks up out-of-hours admin work. Re-check the timezone window quarterly as on-call rotation changes. | Per-user normal working hours via UEBA timeline. |
| `mass_resource_deletion`  | High     | ≥10 successful deletes in 5 min by single principal | Bulk delete is rare in steady state; even teardown scripts batch via `az group delete` (single op). | Same, joined against the principal's prior 30-day delete history (UEBA). |
| `anonymous_storage_access`| High     | Any anonymous read | All managed storage accounts in the POC deny public network access (Section 8 policy initiative). A hit means policy drift or a deliberate anonymous container. | Same. |
| `new_global_admin`        | High     | Any Global Admin / PRA / UAA addition | These roles are PIM-only in the POC. Standing assignment is per definition unexpected. | Same. |
| `firewall_threat_intel_hit` | Medium | Any TI hit logged by hub firewall | Cross-workspace query against `law-platform-...`. Threat-intel mode is set to Alert in the POC firewall policy — every hit is logged but not blocked, so detection is the value here. | Tune severity by category (C2 → High, Malware → Medium, Phishing → Low). |
| `mfa_disabled_for_admin`  | High     | Any auth-method deletion or update | Per-user MFA is being phased out in favour of CA-001; meanwhile, any change to a privileged account's auth method must be reviewed. | Same. |
| `mdc_high` (MS incident)  | (inherited) | All MDC alerts at High severity | MS Defender for Cloud already filters to High via the connector — no Sentinel-side dedupe needed. | Same. |

---

## Cross-workspace queries

The hub Azure Firewall and the spoke NSGs send their diagnostic settings to
the **platform** LA workspace (`law-platform-<org>-<env>`), not the Security
workspace. This is deliberate — duplicating ingestion would double the
~$2.30/GB cost. Detection KQL therefore uses the `workspace()` function:

```kql
workspace('law-platform-globaris-poc').AzureDiagnostics
| where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule")
```

For Sentinel to read across workspaces the Sentinel service principal must
hold `Log Analytics Reader` on the platform workspace. Confirm at apply time:

```bash
az role assignment list \
  --assignee <sentinel-workspace-principal> \
  --scope <platform-law-resource-id>
```

---

## Watchlists

| Watchlist          | Search key       | Populated from                     | Used by                       |
|--------------------|------------------|------------------------------------|-------------------------------|
| `VIPUsers`         | `UserObjectId`   | `var.vip_user_object_ids`          | (future) severity uplift on hits referencing these users. |
| `HighValueAssets`  | `ResourceId`     | `var.high_value_asset_resource_ids`| (future) severity uplift on hits referencing these resources. |

Both watchlists are skipped when the input list is empty (default). Populate
in `envs/poc.secret.tfvars` to enable.

---

## Workbooks — content gaps to close before demo

The four Sentinel workbooks deployed by `azurerm_application_insights_workbook.sentinel`
ship with a placeholder JSON payload. Replace `data_json` before the demo with
the gallery content from
[github.com/Azure/Azure-Sentinel/Workbooks](https://github.com/Azure/Azure-Sentinel/tree/master/Workbooks):

| Workbook key       | Display name             | Gallery source file (Azure-Sentinel repo) |
|--------------------|--------------------------|-------------------------------------------|
| `azure_activity`   | Azure Activity           | `Workbooks/AzureActivity.json`           |
| `identity_access`  | Identity & Access        | `Workbooks/IdentityandAccess.json`       |
| `azure_firewall`   | Azure Firewall           | `Workbooks/AzureFirewallWorkbook.json`   |
| `investigation_ins`| Investigation Insights   | `Workbooks/InvestigationInsights.json`   |

Procedure:

```bash
curl -sSL https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/Workbooks/AzureActivity.json \
  | jq -c . > /tmp/AzureActivity.json
# then edit sentinel.tf:
#   data_json = file("${path.module}/workbooks/AzureActivity.json")
```

Once the JSON is local, the workbook resource updates in place — no recreation.

---

## Suppression decisions

No Sentinel-side incident suppression is enabled in the POC. All scheduled
rules set `suppression_enabled = false` so duplicate detections produce
duplicate incidents, which is the right behaviour during the tuning window.
Re-enable per-rule once baseline noise is understood — `suppression_duration`
of `PT4H` is a sensible starting point for high-volume rules (`brute_force_entra`,
`legacy_auth_attempt`).

---

## UEBA + Entity Analytics

UEBA is enabled with `AuditLogs`, `AzureActivity`, and `SigninLogs` data
sources (`enable_ueba = true` by default). It needs **7 days** of telemetry
before user baselines stabilise — expect false positives from "first activity
detected" alerts during week 1 and tune via the BehaviorAnalytics table.

`IdentityInfo` and `UserPeerAnalytics` tables become available 1–2 hours
after enablement.

---

## Defender for Cloud regulatory compliance

Two initiatives are assigned at the Globaris root MG scope:

- **NIST SP 800-53 Rev. 5** — `179d1daa-458f-4e47-8086-2a68d0d6c38f`
- **CIS Microsoft Azure Foundations Benchmark v2.0.0** — `06f19060-9e68-4070-92ca-f15cc126059e`

Both assignments use `enforce = false` so any DeployIfNotExists policies in
the initiatives do not auto-remediate during the POC. Remediation runs are
created manually (or via Section 12 hardening) once an operator has reviewed
the recommendation set in the Defender compliance dashboard.

The Microsoft Cloud Security Benchmark (MCSB) is **not** assigned explicitly —
Defender for Cloud auto-enables it on every subscription where any plan is on.

---

## Re-baselining workflow

When telemetry volume changes (more subscriptions onboarded, new workloads
deployed, synthetic-workload layer enabled):

1. **Pull 14 days of rule firings:**
   ```kql
   SecurityIncident
   | where TimeGenerated > ago(14d)
   | summarize Count = count() by Title, Severity
   | order by Count desc
   ```
2. **For rules firing >5×/day:** lower the trigger threshold OR add an
   exclusion condition (e.g., specific service principals, CI runners).
3. **For rules firing 0×:** confirm the data source is actually present
   (`<TableName> | take 1`) before assuming the rule is well-tuned.
4. **For rules firing exclusively on a single tenant ID / IP / SP:** add
   the noisy identity to a "known-good" watchlist and join against it in
   the rule's KQL to drop those hits.
5. **Commit threshold changes to `local.analytics_rules` in `sentinel.tf`**
   and reference this file's change-log table.

---

## Change log

| Date       | Rule / setting             | Change                                    | Reason |
|------------|----------------------------|-------------------------------------------|--------|
| 2026-05-29 | (initial)                  | Section 6 deployment with POC thresholds  | First detection baseline. |
