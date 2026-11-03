# Section 12 Acceptance Criteria Validation

> QA / Validation Engineer report. Read-only sweep against the LIVE estate immediately before the
> planned end-of-week teardown. No resources were created, changed, or destroyed to produce this
> report. Every PASS below names the exact command run and the result that proves it. Where a
> claim could not be observed working, it is marked UNVERIFIED or DEFERRED, not PASS.

- **Validated:** 2026-07-11
- **Method:** `az` / `az rest` live queries against all 5 project subscriptions, `gh run list` for
  CI history, `terraform`/PowerShell tooling checks,,
  `DECISIONS.md` (ADR-031, ADR-032, ADR-036, ADR-037), `RUNBOOK.md`, `COST.md`, `README.md`.
- **Scope:** the 8 criteria in the project requirements, tested against the deployed estate:
  management-groups, connectivity, management, identity, security, and the 3 landing-zone spokes
  (corp-a1, corp-a2, online-p1). `synthetic` is not deployed (ADR-036/037, designed-now/built-later).

---

## Per-criterion results

| # | Criterion | Verdict | Evidence (command -> key result) |
|---|-----------|---------|-----------------------------------|
| 1 | `terraform apply` succeeds end-to-end from clean tenant in under 90 minutes | **PARTIAL / qualified** | `gh run list --limit 200` -> 92 total "Deploy (manual)" runs between 2026-05-06T13:31Z and 2026-07-11T05:52Z (66 days), 42 success / 49 failure / 1 cancelled. Every root reached green, but via multiple retries across many sessions, not one clean-tenant run. See interpretation below. |
| 2 | PSRule for Azure scan >= 90% pass | **UNVERIFIED** | `Get-Module -ListAvailable PSRule*` (Windows PowerShell) -> no output, module not installed. `pwsh` (PowerShell 7, PSRule's usual host) is not present on this machine. No `ps-rule.yaml` config file exists in the repo, and no CI workflow step runs PSRule despite `CLAUDE.md`/the project requirements referencing it. No historical scan result exists to check retroactively. |
| 3 | Defender for Cloud Secure Score >= 75% on day one | **FAIL** | `az rest --method GET .../providers/Microsoft.Security/secureScores?api-version=2020-01-01` per subscription. See table below. Blended score across the 4 subscriptions with a populated score is **56.8%** (21/37), below the 75% bar. The security subscription itself returns an empty `secureScores` array (Defender plans set to Standard about 3 hours before this check; score has not yet converged, see notes). |
| 4 | All PaaS resolves via Private Endpoint (`nslookup` from spoke VM) | **PARTIAL / DEFERRED** | Plumbing confirmed: `az network private-dns zone list` -> 89 zones in the connectivity subscription, hub VNet links present. Zero actual resolution confirmed: `az resource list --resource-type Microsoft.Network/privateEndpoints` returns empty in **all 5 subscriptions**, there are no private endpoints deployed anywhere in the estate today. The `nslookup`-from-VM portion is doubly untestable: no spoke workload VM exists (App Service/SQL gated off, ADR-031/032) and there is no PE record to resolve even if one did. |
| 5 | Failover drill runbook fails corp workload primary -> DR | **DEFERRED (topology PASS, workload N/A)** | DR topology live: `az network vnet peering list` on both hubs -> hub-to-hub peering `Connected` both directions; `peer-secondary-hub-to-corp-a2` `Connected`. `az resource list` in the landingzones subscription for `Microsoft.Compute/virtualMachines`, `Microsoft.Web/sites`, `Microsoft.Sql/servers` -> empty (confirms cold-standby, no live workload to fail over). `RUNBOOK.md` Runbook A already documents this honestly as a topology-readiness drill, not an app cutover (ADR-031/032 gating). |
| 6 | Synthetic security incident triggers Sentinel alert + auto-creates ticket via playbook | **DEFERRED / N-A** | `az sentinel alert-rule list` -> 11 analytics rules deployed and enabled. `az rest` against the Sentinel automation-rules API -> 1 automation rule ("Tag high-severity incidents for TI enrichment"). `az resource list --resource-type Microsoft.Logic/workflows` -> empty in all 5 subscriptions: **no playbook exists to auto-create a ticket**. Combined with the synthetic signal generator being deferred by design (ADR-036/037), there is no live incident today and no playbook wired even if one fired. |
| 7 | Monthly cost projection within +-10% of README estimate | **UNVERIFIED-pending-billing** | `README.md` / `COST.md` both exist and state approximately $3,600-$4,800/mo at list price (730 hrs/month, explicitly NOT billed actuals). `az consumption usage list --start-date 2026-07-01 --end-date 2026-07-11` in the management subscription returns 139 usage records, confirming billing data is flowing, but the estate has only been fully stood up for a few days within the current billing cycle, so a monthly actual cannot yet be compared against the estimate. Proof method: re-run this check at 30 days of run time, or against a full prior billing period, and diff actual Cost Management total against the COST.md band. |
| 8 | `terraform destroy` cleanly removes everything | **VALIDATED-AT-TEARDOWN** | Cannot be proven without destroying (out of scope for a read-only QA pass). Pre-req state confirmed healthy: `gh run list` shows the identity root's state lock was force-unlocked (run 29141732832, success) and a fresh plan immediately after acquired the lock cleanly (run 29141869678, success, per `WORKLOG.md`: `0 add / 6 change / 0 destroy`, benign tag drift only), so destroy will not hang on that lock. Two teardown pre-reqs remain open per `WORKLOG.md` / `OPEN-QUESTIONS.md` OQ-008: (1) revoke the 2 temporary AADDS directory-role grants on the CI service principal, (2) scope the CI SP off its current Owner-at-MG-scope grant per the ADR-021 least-privilege role matrix, OQ-008 is designed and specified (`docs/oq-008-rbac.md`) but not yet implemented and validated against a live apply-and-destroy cycle. |

---

## Secure Score detail (criterion 3)

| Subscription | Current | Max | Percentage |
|---|---|---|---|
| landingzones | 5.0 | 14 | 35.7% |
| connectivity | 4.0 | 6 | 66.7% |
| management | 8.0 | 13 | 61.5% |
| identity | 4.0 | 4 | 100.0% |
| security | (no score returned) | (no score returned) | not yet populated |
| **Blended (4 subs with data)** | **21.0** | **37** | **56.8%** |

Notes:
- The security subscription's Defender pricing plans (`az rest .../Microsoft.Security/pricings`) show 12
  plans at `Standard` (VirtualMachines, SqlServers, AppServices, StorageAccounts,
  SqlServerVirtualMachines, KeyVaults, Arm, OpenSourceRelationalDatabases, Containers, CloudPosture,
  Discovery, FoundationalCspm) and 5 assessments exist (`Microsoft.Security/assessments`), but
  `secureScores` returns an empty array for that subscription. Defender was applied about 3 hours before
  this check (run 29136434714); secure score computation commonly takes up to 24 hours to first populate
  after plans are enabled, so this is most likely a convergence lag, not a missing feature. It is reported
  as "not yet populated," not assumed.
- Even excluding the security subscription, the criterion is a clear **FAIL** today: 35.7% to 66.7% per
  subscription, well under the 75% day-one bar. This tracks with the estate's own documented posture
  (Defender gated features pending a Security Administrator grant, OQ-027/028, and several deprecated
  Defender plans held at their prior tier rather than upgraded, per ADR-033/034/035).

## Private Endpoint / DNS detail (criterion 4)

- 89 private DNS zones exist in the connectivity subscription and are linked to the hub VNets (confirmed
  by count only; not every zone link state was individually walked, for cost and time discipline).
- Zero `Microsoft.Network/privateEndpoints` resources exist in any of the 5 subscriptions today. Spot
  checks of `privatelink.vaultcore.azure.net`, `privatelink.blob.core.windows.net`, and
  `privatelink.database.windows.net` A-record sets returned no records.
- Related finding (spills into criterion 6, security posture): the two live Key Vaults in the estate
  report `publicNetworkAccess: Enabled` with no network ACL `defaultAction` set, they are not
  network-restricted today, private endpoint or otherwise. This is a governance gap worth a follow-up
  ADR or fix, not just a "PE not tested" finding.
- Honest conclusion: the private DNS **plumbing** (zones and hub links) is real and provisioned per the
  Section 4 design, but the estate currently has **no PaaS resource actually using it**, because the one
  resource the design wired a private endpoint for (Azure SQL) is gated off (ADR-031), and no other
  resource (Key Vault, Storage) was given a private endpoint in this pass. The criterion as written
  (verified with `nslookup` from a spoke VM) cannot be tested at all: there is no spoke VM and nothing to
  resolve.

---

## Interpretation: criterion 1 (clean-tenant, under-90-minutes apply)

The estate was **not** stood up in a single clean-tenant `terraform apply` under 90 minutes, and that
specific claim cannot be validated as PASS. What actually happened, honestly stated:

- 8 roots were deployed independently over roughly 9 weeks of session time (2026-05-06 to 2026-07-11):
  management-groups, connectivity, management, identity, security, and 3 landing-zone spokes.
- The bootstrap (state backend and OIDC) was created once and persisted across the whole period, later
  root applies were never against a truly clean tenant, they were against a tenant with prior roots
  already live.
- 49 of 92 total CI runs failed and were fixed forward (ADR chain: ADR-027 through ADR-035 alone cover
  fix cycles for platform/management, platform/identity, and platform/security). Some roots needed
  several apply attempts before going green (identity: 5 attempts before the ADR-029 recovery; security:
  3 apply attempts across ADR-033/034/035).
- No single run's wall-clock duration was measured against a 90-minute bar because no run was a full
  from-zero deploy, each run applied one root.

**Honest read:** the design is provably idempotent and does reach a green, drift-clean state per root
(see the retroactive QA sweep below), which is the meaningful engineering claim. The literal
"clean-tenant, single-run, under 90 minutes" acceptance bar was not attempted and is not met as written.

---

## Supporting evidence: retroactive QA sweep (2026-07-11, prior session)

Referenced here as corroborating evidence for the deployment-health criteria, not re-verified line by
line in this pass (see `WORKLOG.md` 2026-07-11 session for the full detail per root):

| Root | QA verdict | Key note |
|---|---|---|
| management-groups | PASS | MG hierarchy, subscriptions, and policy assignments confirmed; clean plan |
| connectivity | PASS | Refreshed plan showed "No changes", zero drift across dual hubs, both Premium firewalls, hub-to-hub peering, DNS Private Resolver, VPN Gateway active-active, 89 private DNS zones |
| management | PASS-with-notes | Tag-governance fix confirmed live; LAW, Automation Account, action group, budgets, exports, and anomaly alerts present; 2 cosmetic mojibake display names noted |
| identity | PASS-with-notes | Entra DS healthy with 2 domain controllers; benign drift on DES tags and VNet DNS-server order (functionally harmless); surfaced and then cleared a stuck state lock |
| security | PASS | 1 imported, 2 added, 9 changed, 0 destroyed; Defender pricing plans live-verified per plan (Standard tiers, no regression on deprecated KeyVaults/Arm plans) |
| corp-a1 / corp-a2 / online-p1 | PASS | online-p1 curled HTTP 200 end-to-end through the App Gateway WAF; corp-a1/corp-a2 confirmed as network-only landing zones (no App Service/SQL, by design) |

This sweep is real evidence that each root, independently, reached a correct and drift-free state. It
does not substitute for criterion 1 as literally written (single clean-tenant run, under 90 minutes).

---

## Overall acceptance summary

| Verdict | Criteria |
|---|---|
| PASS | none unconditional |
| PARTIAL / qualified | 1 (apply succeeds, but per-root over many sessions, not one clean-tenant run) |
| FAIL | 3 (Secure Score, blended 56.8% vs 75% target) |
| PARTIAL / DEFERRED | 4 (private DNS plumbing real, zero live private endpoints, no spoke VM to test from) |
| DEFERRED (topology proven, workload N/A) | 5 (DR network path live; no workload to fail over, by design) |
| DEFERRED / N-A | 6 (Sentinel rules live; no synthetic signal and no ticketing playbook) |
| UNVERIFIED | 2 (PSRule not installed in this environment, no CI scan wired) |
| UNVERIFIED-pending-billing | 7 (estimate documented; too early in the billing cycle to compare actuals) |
| VALIDATED-AT-TEARDOWN | 8 (destroy not run; lock cleared; 2 pre-req revocations still open) |

**Honest bottom line:** the estate is real, live, and largely well-governed as a set of individually
QA-stamped roots (management groups, hub-and-spoke connectivity, platform management, identity and
Entra DS, Defender and Sentinel, and 3 landing-zone spokes) but it does **not** meet Section 12 as a
literal checklist today. The one criterion with a hard numeric bar that was fully testable, Secure Score
at or above 75%, **fails** at 56.8% blended. Two criteria (private endpoint resolution, synthetic
incident-to-ticket) are not just "deferred for cost reasons" but structurally absent: there are zero
private endpoints anywhere in the estate, and zero automation playbooks anywhere in the estate,
independent of the workload-gating and synthetic-deferral decisions already on record. PSRule was never
actually run at any point in this project's history (not installed, not wired into CI), so criterion 2
has no evidence in either direction.

This is a portfolio-grade POC that proves the landing-zone topology, governance, and CI discipline work.
It is not, today, an estate that passes Section 12 as an acceptance gate for a production promotion.

---

## What could not be verified (explicit)

- **PSRule >= 90% pass.** Tool not installed in this environment (no `pwsh`, no `PSRule.Rules.Azure`
  module for Windows PowerShell either), and never wired into CI. Would be proven by: installing
  `PSRule.Rules.Azure`, then running `Assert-PSRule -InputPath . -Module PSRule.Rules.Azure -Format File
  -Option ps-rule.yaml -As Summary` (a `ps-rule.yaml` baseline config would need to be authored first,
  since none exists) or by adding a PSRule step to the deploy workflow.
- **Full private endpoint / nslookup chain.** No spoke workload VM exists to run `nslookup` from
  (App Service/SQL gated off, ADR-031/032), and there is no private endpoint anywhere in the estate to
  resolve even with a VM present. Would be proven by: standing up a jump VM in a spoke, attaching a real
  private endpoint to a PaaS resource (the platform Key Vault is the lowest-risk candidate), and
  confirming `nslookup` from inside the VNet returns the private endpoint's private IP.
- **Workload failover.** No live App Service or SQL exists in corp-a1/corp-a2 (ADR-031/032 gating).
  Would be proven by: flipping `enable_app_service`/`enable_sql` true, deploying a workload, then running
  `RUNBOOK.md` Runbook A end to end and confirming write traffic lands on corp-a2 after cutover.
- **Synthetic incident to Sentinel to ticket.** No signal generator exists (ADR-036/037 deferred) and no
  Logic App playbook exists in any subscription. Would be proven by: building the deferred Day-2
  Operations layer per `docs/operations-monitoring-design.md`, firing a real or synthetic signal, and
  confirming an incident closes with an automation-rule-triggered playbook run.
- **Monthly cost within +-10% of estimate.** The estate has been live only a few days within the current
  billing cycle. Would be proven by: pulling Cost Management actual cost for a full 30-day window once
  available and diffing against the COST.md band.
- **`terraform destroy` cleanly removes everything.** Intentionally not run (read-only QA pass, and
  destroying would end the estate this report is validating). Would be proven by: running the
  `teardown.yml` CI workflow end to end, confirming zero resources remain in all 5 subscriptions, and
  confirming the 2 temporary AADDS directory-role grants and the OQ-008 Owner-at-MG grant on the CI SP
  are revoked as part of, or immediately after, the destroy.
- **Secure Score for the security subscription specifically.** Returned an empty result at check time.
  Would be proven by: re-querying the secure-scores endpoint 24 hours after the Defender pricing plans
  were set to Standard, once the score has had time to converge.

---

## Recommendation

**Fix-then-recheck, not proceed-to-teardown-as-a-clean-pass.** Section 12 is not a formality here, one
hard-numeric criterion actively fails (Secure Score) and two more are structurally unmet regardless of the
workload-gating story (zero private endpoints anywhere, zero automation playbooks anywhere). None of these
block the planned teardown (a cost-sensitive POC is allowed to end with known gaps, and several are
correctly deferred by design per ADR-036/037), but they should not be recorded as "met" anywhere in the
project's closing documentation.

Smallest next steps, by lane:
- **architect** - decide whether Secure Score, private endpoint coverage, and playbook automation are
  in-scope follow-ups for a persistent environment (they map to OQ-026/027/028 and the ADR-037 Day-2
  Operations target) or explicitly accepted gaps for this POC's closing record.
- **cloud-engineer / devsecops** - if pursued, attach a real private endpoint to at least one live PaaS
  resource (the platform Key Vault is the lowest-risk candidate) to prove the DNS zone wiring end to end
  without needing the gated workload tier.
- **devsecops** - re-query Secure Score for the security subscription in about 24 hours to confirm
  whether it converges, and decide whether the 75% bar is achievable pre-teardown or is an accepted miss.
- **user** - confirm the teardown pre-reqs (2 AADDS directory-role revocations, OQ-008 CI SP scope-down)
  before running `teardown.yml`, since criterion 8 depends on them and they are not yet done.
