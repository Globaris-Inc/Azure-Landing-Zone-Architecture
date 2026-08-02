# Azure Advisor remediation plan

**Reader:** the operator sequencing the next rebuild, and whoever implements the hardening wave after it.
**Purpose:** classify every recommendation in the 2026-08-01 Azure Advisor export, separate the genuine
gaps from the decisions this project already made on purpose, and state what gets built, when, and what
is declined with a reason.

**Source:** Azure Advisor CSV export, generated `2026-08-01T05:32:25Z`, 93 rows across 7 subscriptions.
Per-row `Last refreshed on` timestamps range from `2026-07-31T15:19Z` to `2026-08-01T03:16Z`.

**Status:** plan only. Nothing here is implemented. Ordering decision taken by the user 2026-08-02:
**rebuild first, merge to `main`, then harden as a separate wave.**

---

## 1. Why this document exists

The user reviewed the Advisor export after the 2026-07-31 / 2026-08-01 rebuild and asked a direct
question: are we failing to configure things we should have configured, naming customer-managed keys and
diagnostic settings on VNets specifically.

The answer is not uniform, and treating the export as one list would produce the wrong work. 93 rows
reduce to **34 distinct recommendations**, and they fall into five groups with completely different
dispositions. Roughly a third are decisions already made and recorded; a third are genuine gaps that a
production banking platform should not have; the rest need either a decision, a lifecycle verification,
or an explicit refusal.

### 1.1 A snapshot caveat that must not be lost

**Every row predates the end of the rebuild.** Steps 13-14 (the B7 AMBA re-land, `enable_om_phase1`
flipped true) landed on 2026-08-01 *after* the Service Health rows last refreshed at
`2026-07-31T20:10:38Z`. A row is evidence about the estate **at its own refresh timestamp**, not now, and
the estate has since been torn down entirely. Any row in group B below must be re-verified against a live
estate before work is done on it. Acting on a stale row would be the same class of error as trusting a
green signal that did not mean what it said.

### 1.2 An observation the export makes incidentally

The export covers **7 subscriptions**. The managed estate is **5**. Two subscriptions
(`sub-app-01`, `sub-avd-poc-01`) appear only in the Service Health row and are not part of the landing
zone. They are outside every policy assignment, Defender plan, and diagnostic configuration this
repository creates. That is not necessarily wrong, but it is undeclared, and it is registered as part of
**OQ-071** below.

---

## 2. The two items the user raised

### 2.1 Customer-managed keys: a resolved decision that was never built

**This is not an oversight, and it is not undecided.** OQ-047 was **RESOLVED 2026-07-19** as
**Option A, full data-tier CMK**: ADLS `stlake`, Foundry, AI Search, and Databricks (managed services
plus managed disk). The implementation contract exists in `docs/b9-security-design.md` section 3.1 - a
dedicated network-hardened CMK Key Vault in `bank-data-p1`, one RSA-3072 key per resource with rotation,
a per-resource identity and role model, the ordering, and an explicit ForceNew watch on the Databricks
workspace. It is recorded in **ADR-053** and gated behind a dedicated `enable_cmk` sub-flag.

**Verified 2026-08-02:** `enable_cmk` appears in **zero** `.tf` or `.tfvars` files in this repository.
Wave B9 has no code at all. CMK is design-only, in the same designed-now-built-later state as B10 to B13
(ADR-022 precedent).

So the honest description is: the estate has **zero customer-managed keys**, the decision to have them
was made, and the wave that implements it was never started. Advisor's single CMK row
(`[Enable if required] Container registries should be encrypted with a CMK`, Low) is about **ACR**, which
is **not** in OQ-047's resolved scope - that scope is the data tier.

**Disposition:** wave B9, after the rebuild. See section 5 for the ForceNew consideration.

### 2.2 VNet diagnostic settings: a genuine gap that Advisor did not report

**No row in this export mentions virtual networks.** The user found this independently, and it is real.

Verified 2026-08-02 by grepping every composition root, excluding `.terraform/` module caches:
`diagnostic_settings` is wired into ACR, AKS, APIM, Service Bus, Foundry, Databricks, AI Search and App
Service. It is wired into **no virtual network in any root** - neither hub, nor any of the five spokes.

This reads as partially-solved because network telemetry *is* being collected by a different mechanism:
VNet flow logs with Traffic Analytics are configured across the spokes (the `stflow*` storage accounts in
the export are their targets). Flow logs and diagnostic settings are not substitutes - flow logs carry
traffic records, diagnostic settings carry the resource's own platform metrics and `VMProtectionAlerts`.

**Disposition:** group C, hardening wave. Low risk, low effort, and it closes a category the estate
otherwise covers everywhere else.

---

## 3. Classification of all 34 recommendations

Counts are rows in the export. Evidence is file:line in this repository unless stated otherwise.

### Group A - already decided and deliberately deferred (7 classes, 22 rows)

These carry an existing ADR, OQ, or an in-code `# DEVIATION:` marker. **They are not oversights.** They
should be re-affirmed or re-scoped, not "fixed" as if newly discovered.

| Recommendation | Rows | Severity | Where it was already decided |
|---|---|---|---|
| Storage account should use a private link connection | 8 | Medium | Section 12 acceptance validation already records zero private endpoints estate-wide; PEs attach to workloads gated off by ADR-031/032 |
| Azure Key Vaults should use private link | 2 | Medium | `platform/security/main.tf:103-104`, `defender.tf:102` - `# DEVIATION: PE deferred (Section 12 hardening)` |
| Firewall should be enabled on Key Vault | 2 | Medium | Same deviation. Section 12 validation explicitly recorded "both live Key Vaults have publicNetworkAccess=Enabled, no network ACL" |
| Storage accounts should restrict network access using vnet rules | 2 | Medium | `platform/management/main.tf:660` documents the spoke flow-log storage accounts as carrying no `network_acls` |
| Create a dedicated system node pool | 1 | High | `landing-zones/bank-app-p1/aks.tf:104` - "Single system pool, user pools are quota-blocked at POC (OQ-043)" |
| Add node pools to the cluster | 1 | Medium | Same, OQ-043 |
| Container registries should be encrypted with a CMK | 1 | Low | ACR is outside OQ-047's resolved data-tier CMK scope |

**Note on the Key Vault items.** These are the highest-value entries in group A. The deviation was taken
knowingly and is documented, but a Key Vault holding platform secrets and reachable from the public
internet is the single weakest posture statement in the estate. Recommend this deviation be **closed**
in the hardening wave rather than re-affirmed.

### Group B - probably closed after the snapshot, must be re-verified (2 classes, 8 rows)

| Recommendation | Rows | Why it may already be closed |
|---|---|---|
| Create an Azure Service Health alert | 7 | AMBA (`avm-ptn-monitoring-amba-alz` 0.4.0, `platform/management/main.tf:547`) delivers Service Health alerts via MG-scope DINE assignments. It landed in Steps 13-14 on 2026-08-01, **after** these rows refreshed at 2026-07-31T20:10:38Z. **But DINE requires remediation to actually create the alerts**, so policy assignment is not the same as alert existence. Verify live, per subscription. |
| Enable container monitoring for AKS clusters | 1 | `landing-zones/bank-app-p1/aks.tf:172` configures `addon_profile_oms_agent`. Container Insights IS enabled. Advisor may be detecting the legacy workspace-key path (`use_aad_auth = false` at line 176), which is the subject of OQ-068. |

**Action for this group is a QA verification task on the next deployed estate, not an implementation
task.** Two of the seven Service Health rows are for subscriptions outside the managed estate and cannot
be closed by any code in this repository (see OQ-071).

### Group C - genuine gaps, cheap, day-2 applicable (10 classes, 25 rows)

These should have been configured. All are low-risk settings applicable to a live estate.

| Recommendation | Rows | Effort | Note |
|---|---|---|---|
| Enable Soft Delete to protect blob data | 7 | Low | No `delete_retention_policy` or `blob_properties` block exists anywhere in the estate. Affects finops, flow-log, lakehouse and Databricks-managed storage accounts |
| Subscriptions should have a contact email for security issues | 4 | Low | Value must arrive via `TF_VAR_*`, never committed |
| Email notification for high severity alerts | 4 | Low | Same mechanism as above |
| Email notification to subscription owner for high severity alerts | 4 | Low | Same |
| Diagnostic logs in Key Vault should be enabled | 2 | Low | |
| Monitor Azure Firewall Metrics | 2 | Low | Metric alerts on both hub firewalls. Check AMBA coverage first, it may already assign these |
| Switch to Azure Monitor based alerts for backup | 2 | Low | Both Recovery Services vaults |
| Diagnostic logs in Event Hub should be enabled | 1 | Low | The MDC continuous-export namespace |
| Enable auto-inflate on Event Hubs Standard tier | 1 | Trivial | `landing-zones/bank-app-p1/messaging.tf:48` reads `auto_inflate_enabled = false`. One line. Note the MDC export namespace at `platform/security/defender.tf` already sets it true, so the estate is inconsistent with itself |
| Enable automatic repair policy + application health monitoring on VMSS | 2 | Low | AKS node pool properties, not raw VMSS |
| Upgrade to the latest DRS rule set in Application Gateway WAF | 1 | Low | Version bump on `wafpol-online-p1` |
| **VNet diagnostic settings** | **0** | Low | **Not in the export.** Added from the user's own finding, section 2.2 |

### Group D - need a decision or a lifecycle verification first (6 classes, 18 rows)

| Recommendation | Rows | What has to be settled |
|---|---|---|
| Microsoft Defender for Storage with Malware Scanning and Sensitive Data Threat Detection | 5 | **Defender is enabled on 1 of 5 subscriptions.** `platform/security` is a single-subscription root and nothing extends the plans outward. Separately, the sub-features (malware scanning, sensitive data discovery) are not configured on the plan that IS enabled. Both are cost-bearing. **OQ-071** |
| Microsoft Defender CSPM | 5 | `CloudPosture` is in `defender_extended_plans` (`platform/security/defender.tf:34`) but only for the security subscription. Same structural gap. **OQ-071** |
| Microsoft Defender for Resource Manager | 5 | **Direct conflict with ADR-040**, which removed `Arm` on the grounds it was "deprecated for new enablement since 2026-07-05". Advisor now recommends enabling it. **OQ-072** |
| Microsoft Defender for Key Vault | 2 | Same conflict, same ADR, same OQ. **OQ-072** |
| Microsoft Defender for APIs | 1 | Not in the plan set. APIM now exists in `bank-app-p1`, so the plan has a subject it did not have when the set was written. Cost-bearing |
| Azure Key Vault API versions prior to 2026-02-01 are being retired | 4 | Retirement date 2027-02-26, so not urgent. Driven by the `azurerm` provider's API version, not by our configuration - the fix is a provider bump, verified against the pinned version |
| Dependency network status check failed (APIM) | 1 | A real APIM health signal, not a configuration recommendation. Most likely the hub firewall or a UDR blocking one of APIM's required outbound dependencies. **Needs investigation on a live estate**, and it may be a genuine misconfiguration rather than a hardening item |

### Group E - declined for this POC, recorded as deviations (5 classes, 9 rows)

Recorded here so the refusal is explicit and reasoned, per the ADR-049 deviation-register pattern.
Silence is not a decision.

| Recommendation | Rows | Reason for declining |
|---|---|---|
| There should be more than one owner assigned to subscriptions | 5 | Adding a second subscription Owner directly conflicts with ADR-021's least-privilege model, which removed tenant-root Owner from the CI SP at real cost. This is a single-operator POC; the recommendation assumes an organisation with an on-call rota. Revisit only if the estate gains a second human operator |
| Set up Geo-replication for Service Bus namespace | 1 | Advisor itself rates the cost impact **Medium**: geo-replication provisions matching messaging units in the secondary region, so MU charges apply twice, plus per-GB replication data transfer. Not justified for a POC with no production traffic |
| Ensure Geo-replication is enabled for ACR | 1 | Cost impact **Low** but non-zero, and the DR story for images is not part of the POC's acceptance criteria. Defer |
| Use Service Bus autoscaling in the premium tier | 1 | The namespace is Premium at capacity 1 with no load. Autoscale would add cost and protect against a constraint the POC cannot reach |
| Configure the Cluster Autoscaler / Enable VPA recommendation mode | 2 | Single system node pool, user pools quota-blocked (OQ-043). Autoscaling a pool that cannot grow is not a meaningful control |

---

## 4. Ordering decision, and why

**Decided by the user 2026-08-02: rebuild first, merge `banking` to `main`, then harden as a separate
wave.** The alternatives considered were folding the cheap group C items into the rebuild, and building
the full hardening wave including B9 before dispatching at all.

The reasoning, strongest first:

1. **Plan-bar integrity.** All fourteen rebuild plan bars were certified and met exactly
   (537/36/48/696, 24/24/26/73/67, 16/10, 1, 3/223). Those bars are this estate's primary detector for
   unintended change. Any configuration added before the rebuild invalidates every affected bar and
   requires re-certification from pinned module sources. It also gives a failed apply two candidate
   causes instead of one, which is what the one-consolidated-fix-spec rule exists to prevent.
2. **The rebuild is needed regardless.** ADR-071 decision 4b's acceptance criterion and T3 can **only**
   be discharged by tearing down a *deployed* estate. A greenfield smoke test proved the wiring, not the
   deletion.
3. **Nearly everything here is day-2 applicable.** Groups B, C and most of D apply cleanly to a live
   estate. That is what a hardening wave is.
4. **`main` is stale.** It has not been merged since PR #31. A QA-green rebuild is the natural moment to
   make `main` the baseline the hardening branch cuts from.

### 4.1 The argument against, stated honestly

Retrofitting CMK is harder than building it greenfield, and ADR-053 already flags that Databricks
managed-services CMK is a workspace UPDATE carrying a ForceNew risk on a live workspace. If it forces a
replace, ADR-053's own fallback is that the store drops to design-only.

**Why this does not change the ordering:** `bank-data-p1` is a single root with a 73-resource plan and a
roughly 13-minute apply. If CMK forces a workspace replace, rebuilding that one spoke is cheap and
bounded. That does not justify delaying the rebuild to build a wave that currently has zero lines of
code.

**Carried as a required plan-scan item:** when B9 is applied, any `-/+ replace` on the Databricks
workspace is a STOP to be evaluated, not absorbed. It is expected, it is documented, and it must not be
discovered by surprise.

---

## 5. The work, in dependency order

Nothing below is started. Each item needs the normal lane routing and gates.

**Phase 0 - before the rebuild (no code changes).**
Pre-clearance refresh #5. Unchanged by this document: no group in this plan is being folded into the
rebuild, so no plan bar moves.

**Phase 1 - the rebuild.** 14 steps, unchanged, all bars as certified. Then QA green, then merge
`banking` to `main`.

**Phase 2 - verification sweep (QA, read-only, no code).**
Re-check every group B row against the live estate. Confirm whether AMBA's DINE assignments actually
produced Service Health alerts per subscription or merely assigned the policy. Investigate the APIM
dependency-network-status signal. Output: which group B rows are genuinely closed, and whether the APIM
signal is a hardening item or a defect.

**Phase 3 - hardening wave, group C (cloud-engineer, one branch per root).**
Blob soft delete, VNet diagnostic settings, Key Vault and Event Hub diagnostic logs, Event Hub
auto-inflate, VMSS auto-repair and health, WAF DRS ruleset, backup alert migration, firewall metric
alerts. All low risk. Every one changes a plan bar, so each root's bar is re-derived as part of the work.

**Phase 4 - security contacts and Defender scope (devsecops, needs OQ-071 and OQ-072 answered first).**
Subscription security contacts and the three email-notification recommendations. Then the Defender
question: whether plans extend to all five subscriptions, whether the Storage sub-features are enabled,
and whether Defender for APIs is added. Cost-bearing, so it needs the user's answer, not a default.

**Phase 5 - close the deferred private-link deviations (architect first, then implement).**
The group A Key Vault and storage private-link items. This is a design change, not a setting: it needs
private endpoints, DNS zone group wiring, and a decision about how CI reaches a firewalled state Key
Vault. Recommend the Key Vault half be prioritised over the storage half.

**Phase 6 - wave B9 including CMK (architect, then cloud-engineer).**
The resolved OQ-047 Option A scope. Largest item here by far, and the only one with a ForceNew watch.

---

## 6. Open questions raised by this evaluation

- **OQ-071** - Defender for Cloud is enabled on 1 of 5 estate subscriptions, and 2 further subscriptions
  in the tenant are outside the landing zone entirely.
- **OQ-072** - ADR-040 removed the Defender Key Vault and Resource Manager plans as deprecated for new
  enablement; Advisor recommends enabling both. One of the two is wrong and it must be verified against
  current documentation, not resolved from memory.
