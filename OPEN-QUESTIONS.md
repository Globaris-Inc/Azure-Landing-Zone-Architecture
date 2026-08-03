# OPEN-QUESTIONS.md — Unresolved Items

> Questions, blockers, and clarifications that need user input before work can proceed.
> Resolved questions get a `**RESOLVED:**` answer appended and stay in the file as a record.

---

## Template

```
### OQ-XXX: [Short question]

- **Raised:** YYYY-MM-DD (Session N)
- **Section:** [N from PROMPT.md]
- **Blocking:** Yes / No (and what it blocks)
- **Priority:** High / Medium / Low

**Question:**
[Full question with context]

**Options being considered:**
- A: [...]
- B: [...]

**RESOLVED YYYY-MM-DD:** [answer]
```

---

## Open Questions

<!-- Newest at the top. -->

### OQ-073: ADR-074's continental-US Deny will block Section 13.3's red-team second pole, which is in `westeurope` BY DESIGN so the impossible-travel detection scenario has a real signal

- **Raised:** 2026-08-02 (found by the code-reviewer while gating ADR-074; it BLOCKED on it)
- **Section:** 13.3 (Synthetic Workload and Security Signals) / 2 (Management Group Hierarchy)
- **Blocking:** **No for the rebuild** - `enable_synthetic_workload = false` and `synthetic` is not one
  of the fourteen dispatched steps, so nothing fires. **Yes for Section 13.3**, which cannot ship until
  this is answered.
- **Priority:** Medium (it blocks nothing today and blocks that wave completely)

**Question:**

ADR-074 assigns `Allowed locations` at Deny on the `globaris` MG, restricted to nine continental US
regions. `synthetic/red_team.tf:157` creates `azurerm_resource_group.red_team_secondary` at
`var.red_team_geo_location`, whose default is **`westeurope`** (`synthetic/variables.tf:63`), with
further resources at `:301` and `:367`. `synthetic`'s provider targets the landingzones subscription,
which is under `globaris`.

**The `westeurope` placement is not an accident or a leftover. It is the point.** The second Container
Apps Environment is deliberately on the far side of the world from the primary so that a sign-in from
each produces a genuine **impossible-travel** signal for Defender and Sentinel to detect. Relocating it
to a US region does not "fix" it; it removes the detection scenario the wave exists to demonstrate.

So ADR-074 and Section 13.3 as currently designed are **mutually exclusive**, and nothing in the
repository said so until the code-reviewer found it. The first symptom would otherwise have been a
`RequestDisallowedByPolicy` at PUT time behind a clean plan, months from now, which is exactly the
class LESSONS 40 and 41 exist to prevent.

**Options being considered:**

- **A (RECOMMENDED). A scoped policy exemption for the red-team secondary resource group**, in the same
  shape as the ADR-070 DINE exemptions already in this estate: an RG-scoped exemption plus the
  propagation `time_sleep` plus `depends_on` from the protected resources (LESSON 35). Keeps the
  residency guardrail meaningful everywhere else, keeps the detection scenario intact, and the exemption
  is itself the documentation of why one resource group is outside the policy. Cost: one exemption unit
  on a root that is currently gated off.
- **B. Narrow the assignment scope** so it covers `platform` and the production landing zones but not
  whatever MG the synthetic workload lands under. Structurally clean, but it weakens the guardrail on a
  real landing-zone subscription and the synthetic root currently shares the landingzones subscription
  rather than having its own MG.
- **C. Move the second pole to a US region** (for example `westus3` against a `centralus` primary).
  Zero policy work, zero exemption, and it keeps the residency guarantee absolute.

  **CORRECTED 2026-08-02 at the code-reviewer gate.** This option first read "loses the
  impossible-travel signal, since both poles would then be domestic; cross-country US travel is not
  impossible travel." **That claim is unsupported and almost certainly wrong**, and it was the reviewer's
  second BLOCK on this change. Neither detection this scenario could rely on has any country or border
  term. Microsoft's own wording, read 2026-08-02:

  - **Atypical travel** (Entra ID Protection, `unlikelyTravel`, P2, offline): "identifies two sign-ins
    originating from **geographically distant locations**... The algorithm takes into account multiple
    factors including **the time between the two sign-ins and the time it would take for the user to
    travel** from the first location to the second."
  - **Impossible travel** (Defender for Cloud Apps, `mcasImpossibleTravel`): "identifies user activities
    ... originating from **geographically distant locations within a time period shorter than the time
    it takes to travel** from the first location to the second."

  Both are pure distance-and-elapsed-time feasibility calculations. `centralus` (Iowa) to `westus3`
  (Arizona) is roughly 1,150 miles great-circle, and `synthetic/README.md:146-147` fires the two poles **5 minutes
  apart**. That is as physically impossible as a transatlantic hop, so **option C very plausibly retains
  the signal at zero cost**, which makes it a serious contender rather than the trap this entry
  originally painted it as.

  What is genuinely lost under C is narrower and should be stated accurately: any detection keyed to
  **nationality** rather than distance, such as `newCountry` (`Activity from infrequent country`), and
  the existing `blocked_country_signin` rule in `platform/security/sentinel.tf`, which keys off
  `approved_sign_in_countries`. Whether this scenario was ever meant to exercise those is unresolved.

- **D. Accept that Section 13.3 does not ship** while ADR-074 stands, and record it as a deliberate
  trade of a demo capability for a residency guarantee. Section 13 is already REPOSITIONED and deferred
  (ADR-036/037), so this may cost nothing real.

**Recommended:** **C first, then A only if C is proven insufficient.** C is free, keeps the residency
guarantee unqualified, and on the documented behaviour of both detections it very likely preserves the
scenario. A costs an exemption unit and punches a permanent hole in the guardrail, which is a real price
to pay for a geo-separation that may not be needed. **D** remains the honest interim state and costs
nothing today.

**Two things to establish before this is finally resolved, neither of which is settled:**

1. **Which mechanism actually fires this scenario.** `platform/security/sentinel.tf` contains **no**
   impossible-travel or atypical-travel analytics rule - verified 2026-08-02. So the scenario depends on
   a **built-in** detection, not on repo-owned KQL. `docs/worklog/2026-06-04.md:43` refers to a
   "different country in <30 min" threshold and no implementing rule was found, so that phrasing may be
   the origin of the incorrect claim corrected above.
2. **Whether either detection can fire here at all.** Both are **P2**, and Impossible travel
   additionally needs Defender for Cloud Apps licensing. Atypical travel also carries "an initial
   learning period of the earliest of 14 days or 10 logins" - a freshly created honeypot account in a
   short-lived POC may sit inside that window for the whole demo and never trigger. **If that is so, the
   region of the second pole is moot and C is free**, which would resolve this entry outright.

**Do not resolve this by silently flipping the default in `synthetic/variables.tf`** - whichever option
wins, it should be recorded here first.

**Standing instruction until resolved: do not flip `enable_synthetic_workload` to true.**

---

### OQ-072: ADR-040 removed the Defender Key Vault and Resource Manager plans as "deprecated for new enablement"; Azure Advisor now recommends enabling both on 7 subscription rows - one of the two is wrong

- **Raised:** 2026-08-02 (Advisor export evaluation, `docs/advisor-remediation-plan.md` group D)
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Blocking:** No. Blocks only the Defender portion of the post-rebuild hardening wave (phase 4).
- **Priority:** Medium

**Question:**

`platform/security/defender.tf:20-23` carries this comment, and the plans were removed on its authority:

> (KeyVaults and Arm were removed from main.tf per ADR-040: deprecated for new enablement since
> 2026-07-05; CloudPosture/CSPM below carries the posture surface for both.)

The 2026-08-01 Advisor export contains **5 rows** of "Microsoft Defender for Resource Manager should be
enabled" and **2 rows** of "Microsoft Defender for Key Vault should be enabled", both rated **High**.

**These two statements cannot both be current.** Either the deprecation was real and Advisor is
recommending a plan that can no longer be newly enabled (Advisor's recommendation catalogue is known to
lag retirements), or the deprecation reading was wrong and the estate removed two working plans on a
mistaken basis, leaving a posture gap that Advisor is correctly flagging.

**This must not be resolved from memory or from the existing comment.** It is exactly the class the
project has been bitten by twice at apply time (NSG flow logs, the Dns Defender plan): a lifecycle claim
that `validate` and `plan` both accept and only the live API adjudicates. The answer needs a current
Microsoft documentation check dated at the time of the decision, plus the ADR-040 text itself re-read to
establish what it actually claimed.

**Options being considered:**

- **A.** Deprecation confirmed. Re-affirm ADR-040, and record in the plan document that these 7 Advisor
  rows are permanently un-actionable so nobody re-opens them at the next export. Zero code.
- **B.** Deprecation was a misreading. Restore `KeyVaults` and `Arm` to `defender_extended_plans`, with a
  dated addendum on ADR-040 recording the correction. Cost-bearing, and it interacts with OQ-071's
  question of which subscriptions carry Defender at all.
- **C.** Partial: one of the two plans is deprecated and the other is not. Treat them separately.

**Recommended:** verify first, decide after. Do not schedule the work until the lifecycle status is
established, and note that whichever way it resolves, `CloudPosture` is claimed in the same comment to
carry "the posture surface for both" - that claim is also unverified and should be checked in the same
pass.

---

### OQ-071: Defender for Cloud is enabled on ONE of the five estate subscriptions, and two further subscriptions in the tenant sit outside the landing zone entirely

- **Raised:** 2026-08-02 (Advisor export evaluation, `docs/advisor-remediation-plan.md` group D)
- **Section:** 6 (Defender for Cloud + Sentinel) / 2 (Management Group Hierarchy)
- **Blocking:** No. Blocks phase 4 of the post-rebuild hardening wave. Cost-bearing, so it needs a user
  answer rather than an architect default.
- **Priority:** High (it is the largest genuine posture gap the Advisor export surfaced)

**Question:**

**Limb A - Defender covers 1 of 5 subscriptions.** `azurerm_security_center_subscription_pricing` is a
subscription-scoped resource, and every instance of it lives in `platform/security`, which is a
single-subscription root. So the six plans in `local.defender_extended_plans`
(`platform/security/defender.tf:29-36`) plus the foundational plans in `main.tf` apply to the **security**
subscription only. Nothing in this repository extends them to connectivity, identity, management, or
landing zones.

Advisor confirms this from the outside: 5 rows for Defender for Storage, 5 for CSPM, 5 for Resource
Manager, one per estate subscription. This is not drift and not a bug in anyone's work - the root was
scoped to one subscription by construction and the gap was never named.

There is a second, narrower half: even on the subscription that IS covered, the Storage plan is enabled
at `tier = "Standard"` without the **Malware Scanning** or **Sensitive Data Threat Detection**
sub-features, which is specifically what Advisor's High-severity row asks for. And **Defender for APIs**
is absent from the plan set, which mattered less before `bank-app-p1` had an APIM instance and matters
now.

**Limb B - two subscriptions are outside the estate.** The export covers **7** subscriptions. The managed
estate is **5**. `sub-app-01` and `sub-avd-poc-01` appear only in the Service Health row. They are outside
every management group assignment, policy, Defender plan and diagnostic configuration this repository
creates. Whether that is correct is a separate question from whether it is *declared* - right now it is
not declared anywhere, which is the same shape as the undeclared CI SP grants in OQ-061.

**Options being considered (limb A):**

- **A.** Extend the Defender plan set to all five estate subscriptions via a subscription-scoped module
  or an ALZ DINE policy assignment at the MG scope. Most complete, matches the CAF intent that posture is
  a platform property and not a per-root one. Highest cost: Defender plans bill per resource, per plan,
  per subscription.
- **B.** Extend only the plans with a real subject in each subscription (Storage everywhere,
  CloudPosture everywhere, Containers only where AKS exists). Cheaper, and it needs a per-subscription
  inventory to stay correct as the estate changes, which is a maintenance obligation of the kind ADR-062
  ruled against.
- **C.** Extend CSPM (`CloudPosture`) estate-wide and leave the workload plans on security only. CSPM is
  the cheapest broad-posture plan and gives the asset graph and attack paths across the whole estate.
  Partial but defensible, and it is the single best cost-to-posture ratio in the set.
- **D.** Accept the current scope for the POC and record it as a deviation.

**Recommended:** **C** as the default, with the Storage sub-features enabled on the subscriptions that
actually hold data (landing zones, management). **A** if the portfolio claim needs to be "Defender for
Cloud across the estate" without qualification. The cost delta between C and A should be estimated before
the decision, since this is the one item in the whole Advisor evaluation with a recurring bill attached.

**For limb B:** the answer is to declare, not necessarily to change. Either bring the two subscriptions
under the hierarchy or record in `ARCHITECTURE.md` why they sit outside it.

---

### OQ-070: `envs/poc.tfvars` is a single-state file describing a POST-rebuild estate, so `banking` is never greenfield-dispatchable between rebuilds and carries a latent Step-1 and Step-9 failure by default

- **Raised:** 2026-08-01 (architect, pre-clearance refresh #4)
- **Section:** 9 (Landing Zone Spokes) / 10 (Pipeline and Tooling)
- **Blocking:** **Yes for the next rebuild, and discharged operationally by PC-1TF.** The immediate
  fix is a two-line revert PR. This entry is about the DURABLE fix, which is not blocking.
- **Priority:** Medium

**Question:**

Found live at `banking` @ `3472f4c`, read from the file rather than inferred:

- `envs/poc.tfvars:380` `enable_om_phase1 = true`
- `envs/poc.tfvars:250` `enable_acr_kubelet_binding = true`

Both are correct for the estate that existed at the end of the 2026-07-31 rebuild. Both are wrong for
Step 1 of the next one. Dispatching Step 1 from `banking` as it stands makes
`platform/management-groups` select the `globaris-amba` architecture and plan in the 700s instead of
537, which is runbook matrix **B4**; and it makes Step 9's `bank-app-p1` Pass-1 plan resolve
`data.azurerm_kubernetes_cluster.aks_lookup` against a cluster that does not exist, 404 at PLAN time,
and exit non-zero. The second one regresses PC-2S, the original hard code blocker of the rebuild
pre-clearance, purely through a tfvars line and with no `.tf` change at all.

**Neither is a bug in anyone's work.** Both flags were flipped exactly when the runbook told the
operator to flip them, by reviewed PRs, and both files carry long, accurate comments saying they must
be reverted before a fresh greenfield build. The defect is structural: **one file has to describe two
mutually exclusive estate states, and nothing in the repository or the pipeline knows which one it is
currently describing.** The comments are the only control, and a comment is not a control (ADR-062).

The runbook's checks DID catch it (PC-5X limb 2 and matrix B4 both fire correctly), which is worth
recording as a win. But the runbook's **PC-4R row** asserts as already-confirmed fact that
`envs/poc.tfvars` reads `enable_om_phase1 = false`, and that sentence is now false, so an operator
following the runbook top to bottom has one row telling them not to bother checking.

**Options being considered:**

- **A (RECOMMENDED DEFAULT). A greenfield-state assertion in `preflight.sh`, plus a dispatch-time
  check.** One cheap, mechanical rule: `envs/poc.tfvars` must contain `enable_om_phase1 = false` and
  must NOT contain `enable_acr_kubelet_binding = true` UNLESS an explicit marker says the estate is
  past Step 12. Cost is a few lines of shell. It keeps one tfvars file, keeps the two-pass sequences
  that ADR-055 and PC-2S require, and turns two comments into a gate. Recommended because it is the
  smallest change that converts a documentation obligation into a mechanical one, which is the exact
  move ADR-062 argues for.
- **B. Split the late-stage flags into a second var-file** (for example `envs/poc.post-step12.tfvars`)
  layered on only for Steps 12 to 14. Structurally cleanest and removes the ambiguity entirely, but it
  touches every CI path that passes `-var-file` and is a real change to a proven pipeline, days before
  a rebuild. Better as a post-rebuild change than a pre-rebuild one.
- **C. Revert the flags to greenfield values immediately after each rebuild completes**, as the final
  step of the runbook rather than a precondition of the next one. Zero tooling. Same failure mode as
  every other "remember to" control this project has already ruled against, and it leaves `banking`
  describing an estate that does not match the live one for the whole gap.
- **D. Do nothing beyond PC-1TF.** Accept the two-line revert as a standing pre-rebuild step. Honest,
  and it is what will happen for THIS rebuild regardless. It leaves the trap armed for the next one.

**Recommended:** **A** now (or at minimum PC-1TF plus the PC-4R row correction, which is the
non-negotiable part), **B** as a post-rebuild cleanup if the estate is rebuilt more than once more.

**Not in scope of this entry:** whether `enable_om_phase1 = false` is the right greenfield ORDERING
workaround at all. That is settled by PC-4R option A and ADR-052; this entry is only about the file
describing the wrong state at the wrong time.

---

**SECOND LIVE INSTANCE, 2026-08-02, and it cost a rebuild.** `envs/poc.tfvars:118`
`budget_start_date = "2026-07-01T00:00:00Z"` failed **Step 2** of the rebuild: Azure's Consumption API
returned `400: Start date for monthly time grain should not be prior to current month` for all **8**
budgets (3 MG-scope, 5 subscription-scope), run `30776463447`. Under the standing operator ruling the
whole estate **is being** torn down (run `30777047207`) and the rebuild **will restart** from Step 1
once this fix lands.

**Three things make this the stronger version of the same argument, not merely another example.**

1. **The trap armed itself with no code change.** The value was correct throughout the 2026-07-31
   rebuild and became wrong at 00:00 on 2026-08-01 because the month rolled over. The other two traps at
   least required someone to flip a flag; this one needed nobody to do anything.
2. **The file already documented its own failure mode, verbatim, including the exact 400 text and the
   required action** ("Bump to the first of the CURRENT month whenever platform/management is freshly
   deployed"). The control existed as prose and did not fire. That is ADR-062's thesis demonstrated
   rather than argued.
3. **Two consecutive pre-clearance refreshes read this file and passed it.** PC-1TF enumerated two
   tfvars traps and there were three. **The pre-clearance itself was an enumerated list where a property
   assertion was needed** - the same anti-pattern ADR-062 named in the teardown VERIFY sweep,
   independently reproduced here by the architect lane. (Corrected at the review gate: an earlier draft
   said this was "the very file the ruling is about", which overstates ADR-062. That ADR is about Phase 3
   VERIFY being broader than the Phase 2 sweep, not about `envs/poc.tfvars`. The principle transfers by
   analogy; the subject does not.)

4. **A fourth site of the identical class was found by the reviewer's sweep, armed and undetected.**
   `landing-zones/bank-data-p1/policy_exemptions.tf` carried `expires_on = "2026-08-01T00:00:00Z"` on the
   Databricks dbstorage waiver, with `enable_data_platform = true`. It would not have failed at its own
   PUT - an expired exemption creates but is not honoured - so **Step 8's dbstorage create would have
   been denied instead**, two files from the cause, costing another full teardown. Two more sites sit
   dormant in `synthetic/` behind a false comment claiming a past month is safe. **The self-healing guard
   for this class already existed at `modules/finops/main.tf:31-39`, complete with a comment recording
   that it had bitten the budgets once before, and had been applied to exactly ONE of the estate's four
   date sites.** That is the strongest argument in this entry: the control existed, was correct, and was
   not generalised.

**This widens option A rather than adding a new option.** The recommended `preflight.sh` greenfield
assertion must NOT be a second enumerated list of known-bad lines. It needs to assert a PROPERTY per
class:

- `budget_start_date` parses as RFC 3339 **and** its year-month equals the current year-month.
- `enable_om_phase1 = false` and `enable_acr_kubelet_binding` is absent or `false`, **unless** an
  explicit past-Step-12 marker is present.
- Any future date-valued or state-valued tfvars entry carries a machine-checkable assertion at the point
  it is added, not a comment.

**Deferred by user ruling 2026-08-02:** implement after the rebuild completes, so no shell change lands
mid-run. The immediate fix was the one-line bump to `2026-08-01T00:00:00Z`.

---

### OQ-069: Teardown's soft-deleted-workspace purge only ever looks at ONE named workspace in ONE subscription, and two soft-deleted Log Analytics workspaces are sitting in the MANAGEMENT subscription right now

- **Raised:** 2026-08-01 (architect, while ruling ADR-072 on the `platform/management` teardown orphans)
- **Section:** 8 (Standard Platform Components) / 10 (Pipeline & Tooling, teardown)
- **Blocking:** **Yes for the rebuild's `platform/management` step.** Not blocking anything else, and
  not blocking a teardown. It must carry a written disposition in the rebuild pre-clearance before
  `platform/management` is applied, per the standing pre-clearance gate.
- **Priority:** High (a rebuild inside the 14-day recovery window is the exposed case, and the window is
  open now)

**Question:**

The operator verified live on 2026-08-01, after the `30685705802` teardown completed its Phase 2/3/4,
that the SECURITY subscription holds **zero** soft-deleted Log Analytics workspaces and the MANAGEMENT
subscription holds **two**.

Teardown's purge step cannot reach them, and the reason is a design shape this estate has already ruled
against once. `scripts/teardown-az-sweep.sh` step 7b (the OQ-063 purge) is scoped to
`SECURITY_SUBSCRIPTION_ID` and filters `list-deleted-workspaces` down to a single hardcoded name,
`SECURITY_LAW_WORKSPACE_NAME`, then asserts the resolved resource group equals
`SECURITY_LAW_RESOURCE_GROUP_NAME` and aborts if it does not. Every one of those is correct FOR THE
SECURITY WORKSPACE and structurally blind to any other. It is an enumerated single-instance list, which
is exactly the mechanism ADR-062 ruled is not a control ("an enumerated list plus a written promise to
maintain it is not a control"), applied to a class where a second instance has now actually appeared.

Two things are genuinely unknown and should not be guessed:

- **What the two workspaces are.** Candidates are the platform workspace itself
  (`platform/management`), a Traffic Analytics or AMBA-adjacent workspace, or a `DefaultWorkspace-*`
  the AKS addon can create when no workspace is supplied. Their names and resource groups decide
  everything below and are one `az monitor log-analytics workspace list-deleted-workspaces
  --subscription <management>` away.
- **Whether a rebuild inside the recovery window recovers or collides.** Azure reserves a soft-deleted
  workspace's name for the retention period. If the rebuild's `platform/management` apply recreates the
  same name in the same resource group, the plausible outcomes are (a) the API silently RECOVERS the old
  workspace, carrying its old `customerId`, its old linked solutions and its old data into a run that
  believes it created something new, or (b) a hard create failure. **(a) is the dangerous one** and it
  is not hypothetical in this estate: a recovered workspace with its ORIGINAL `customerId` also revives
  the exact NWTA naming inheritance `docs/estate-bom.md` finding 1 identified and that ADR-072 decision
  1 re-attributed to Traffic Analytics.

**Options being considered:**

- **A (recommended default): read first, then disposition in the pre-clearance, and only then decide the
  code change.** One list call names the two workspaces. If either is the platform workspace, the
  rebuild pre-clearance must carry an explicit GO/NO-GO on recover-versus-create with the expected
  behaviour written down BEFORE `platform/management` is applied, per the standing rule that no first
  apply proceeds without a written disposition. Cheap, correct order of operations, and it does not
  commit to a mechanism before the facts are in.
- **B: generalise step 7b from "the one named security workspace" to discovery across all five
  subscriptions**, deleting any soft-deleted workspace whose resource group is estate-owned by the
  existing `is_estate_owned` containment predicate. This is the ADR-062-shaped fix and is almost
  certainly where this ends up. It is a DevSecOps change and should not be authored until A has
  established what is actually there, so the predicate is written against real objects.
- **C: leave it, and let the rebuild recover the workspaces.** Rejected as a default. It accepts option
  (a) above as the plan, and a recovered workspace that Terraform believes it created is FM-1-adjacent:
  state describing an object whose real history the state does not reflect.
- **D: purge them by hand from the portal.** Rejected: teardown and estate mutation are CI/CD only
  (standing user ruling). If they must go before a code change lands, that is an explicitly authorised,
  dated, scoped operator exception in the ADR-068 decision-6 shape, not a console habit.

**RESOLVED 2026-08-01 by ADR-073 (option A executed, then B ruled, with a finding option A could not
have predicted).** The operator ran the live read this OQ demanded. Results: connectivity 0, identity 0,
landingzones 0, security 0, management 2. Both management entries are `law-platform-globaris-poc` in
`rg-management-globaris-poc`, one created 2026-07-07 in `eastus2` (pre-region-flip) and one created
2026-07-31 in `centralus`, and **both carry the IDENTICAL ARM resource ID**, because region is not a
segment of a Log Analytics workspace's resource ID. So the second bullet of this OQ ("whether a rebuild
inside the recovery window recovers or collides") was the right question asked against the wrong object
model: the real question was WHICH of two same-ID candidates a recovery would target.

The ruling, in five lines:

1. **Recovery is keyed on FOUR things including REGION**, established from Microsoft's "Delete and
   Recover a Log Analytics Workspace" page and the REST contract (the recovery PUT carries
   `{"location": ...}` in its BODY, and `Restore-AzOperationalInsightsWorkspace` makes `-Location`
   mandatory), not inferred. A `centralus` create therefore cannot recover the `eastus2` entry, and the
   feared silent failure (the platform workspace returning in the DR region behind a green apply) is not
   reachable under the documented contract.
2. **The two-entry case itself is undocumented** and is not asserted. The residual outcomes are a
   region-matched recovery or a name conflict; neither is a wrong-region recovery, and both are loud.
3. **Disposition: purge BOTH entries via CI before Step 2**, so Step 2 is an unambiguous fresh create.
   This is option C rejected properly and option A's read acted on. It removes the `customerId`
   inheritance question rather than managing it, and it matches ADR-067's posture that a rebuild creates
   rather than adopts.
4. **Option B is adopted and specified**, with a safety bar this OQ did not scope: containment via the
   existing `is_estate_owned --resource-id` predicate, a blast-radius cap, a REST-PUT recover (the CLI
   verb has no `--location` and cannot select between same-ID entries), a `deletedWorkspaces` re-list as
   the completion check (the current ARM GET returns a false "purged" whenever two entries share an ID),
   and strictly sequential per-entry cycles.
5. **Root cause is one block**: `platform/management/providers.tf` never set
   `features { log_analytics_workspace { permanently_delete_on_destroy = true } }`, which
   `platform/security/providers.tf` does. Exactly two roots in the repo declare a workspace.

Owners: DevSecOps (ADR-073 decision 4), Cloud Engineer (decision 6), operator (decision 3 dispatch and
the new PC-1M gate). Full reasoning, alternatives and the verbatim documentation quotes are in ADR-073.

### OQ-068: Container Insights on `bank-app-p1` uses the legacy workspace-key path (`use_aad_auth = false`), which is the specific reason a cross-root `Microsoft.OperationsManagement/solutions` object exists at all - should the estate move to the MSCI path that creates no such object?

- **Raised:** 2026-08-01 (architect, ADR-072 corollary C3 - explicitly NOT decided in that ADR)
- **Section:** 9 (Landing Zone Spokes) / 13 or a later O&M wave (where managed Prometheus lives)
- **Blocking:** **No.** ADR-072 decision 4's sweep removes the object regardless of which path is
  chosen, so nothing waits on this. It is a "should the coupling exist at all" question, not a
  "how do we clean it up" question.
- **Priority:** Medium

**Question:**

`landing-zones/bank-app-p1/aks.tf` enables the AKS monitoring addon with
`addon_profile_oms_agent = { enabled = true, config = { log_analytics_workspace_resource_id = ...,
use_aad_auth = false } }`. The file records why, and the reason was sound at the time: the module only
wires the required MSCI data collection rule through its `onboard_monitoring` path, which also brings in
managed Prometheus resources, and that was deferred to the B7 O&M wave.

What was not priced at the time is that `use_aad_auth = false` is precisely the path that materialises a
`Microsoft.OperationsManagement/solutions/ContainerInsights(<workspace>)` object inside the PLATFORM
root's resource group. The `use_aad_auth = true` MSCI path does not create that object. So a build-time
convenience decision in a spoke created a permanent cross-root coupling into a platform root - which is
the ADR-072 decision 5 class, arriving through a single boolean.

The question is whether to keep it. It is a live-behaviour change to a deployed workload (Container
Insights ingestion path, authentication mode, and possibly a managed-Prometheus footprint), so it needs
a plan bar and a wave, not a teardown ADR.

**Options being considered:**

- **A (recommended default): keep `use_aad_auth = false` for now, revisit inside the O&M wave that
  lands managed Prometheus.** The coupling is now named, documented (ADR-072 C2's attachment-surface
  table) and swept (ADR-072 decision 4), so its cost is bounded and visible. Flipping it now changes a
  deployed monitoring path for a cleanliness benefit the sweep already delivers, and it would land
  mid-rebuild, which LESSON 59 forbids.
- **B: flip to `use_aad_auth = true` in the next `bank-app-p1` change.** Removes the cross-root object
  at source, which is strictly better architecture under ADR-072 decision 5, and moves Container
  Insights onto the current MSCI mechanism rather than the legacy workspace-key one. Cost: pulls managed
  Prometheus resources into a wave that has not budgeted them, changes what the AVM module deploys, and
  needs its own plan bar and pre-clearance. **Verify before adopting:** whether the pinned AKS module
  version exposes a path to MSCI WITHOUT the managed-Prometheus fan-out. That has not been checked and
  must not be assumed.
- **C: drop Container Insights from `bank-app-p1` entirely.** Rejected as a default - it removes a
  capability the demo narrative uses, to solve a teardown problem that is already solved.

### OQ-067: Who owns private-endpoint DNS zone groups when ALZ DINE and Terraform both write them, and what actually created the three Terraform-named diagnostic settings before any DINE deployment started?

- **Raised:** 2026-07-31 (architect, ruling ADR-070 on the twice-failed `bank-data-p1` apply)
- **Section:** 9 (Landing Zone Spokes) / 2 (Management Group Hierarchy, the DINE assignments)
- **Blocking:** **Item A: No** (ADR-070 decision 2 rules the mechanism; this entry records the live
  values the implementer needs). **Item B: Yes for Step 9** - not because it changes the recovery,
  which is the same either way, but because an unexplained writer producing Terraform-shaped names
  must be identified before the estate's most expensive root is dispatched.
- **Priority:** High
- **Relates to:** ADR-070 (the ruling), OQ-021 (the diagnostics half of the same conflict - see its
  2026-07-31 update, which REVERSES its recommended option), OQ-032 (the tag drift that accounts for
  all 29 plan changes), ADR-028 / LESSON 35 (the exemption unit being reused).

**Item A: the private-DNS DINE versus Terraform zone-group ownership.**

OQ-021 covers the diagnostics half of this conflict. It does not cover `Deploy-Private-DNS-Zones`,
which is a different policy family with a harder failure mode: Azure supports **only one private DNS
zone group per private endpoint**, so a DINE-created `deployedByPolicy` group and a Terraform-created
`default` group are not duplicates, they are mutually exclusive. On `pe-aif-bank-data-p1-globaris-poc`
the DINE group would also carry one zone where the Foundry account needs three (cognitiveservices,
openai, services.ai), so if the policy wins the race the private endpoint resolves incorrectly and
Terraform's pending PUT collides.

Three places in the repo currently classify this DINE as harmless - `docs/preclearance/landing-zones.md`
row 12 ("post-apply drift, not a create blocker"), `docs/preclearance/b5-data-platform.md` row 8 ("PASS
by proven precedent"), and the rebuild gate's PC-8S table ("post-apply drift only, never a create
blocker"). That classification holds only while every private endpoint arrives WITH its zone group in
the same PUT, which is the module-managed case. It is **false for any private endpoint whose zone group
Terraform has not yet created**, which is exactly the state a failed apply leaves behind, and it is
false for the one private endpoint in the estate whose zone group is authored natively rather than by
the module.

**Options being considered (item A):**
- **A (RULED, ADR-070 decision 2): RG-scoped `Mitigated` exemption** on the resource groups holding
  Terraform-owned private endpoints, with the ADR-028 / LESSON 35 unit (exemption + a NEW 300s
  `time_sleep` + `depends_on` from every protected resource). Narrow, reversible, keeps the control
  live everywhere else, and `Mitigated` records honestly that the policy's intent IS met by another
  mechanism.
- **B: `enforcementMode = "DoNotEnforce"` on the assignment at the MG** (the `Enable-DDoS-VNET`
  precedent). Rejected as primary, retained as the fallback if an assignment's members cannot be
  enumerated well enough to scope an exemption. It disarms the control for future workloads Terraform
  does not manage.
- **C: let DINE own zone groups and stop declaring them in Terraform.** Rejected: single-zone only, so
  it cannot express the Foundry three-zone case at all, and it removes DNS wiring from code.

**What the implementer needs, and cannot get from the repo (read D3 in ADR-070 decision 4):**
the live policy ASSIGNMENT names and their `policyDefinitionReferenceIds` for both DINE families, at
**every** ancestor scope of the landingzones subscription - tenant root, `globaris`, `landingzones` and
`corp`. The failure evidence names policy DEFINITIONS ("Configure Cognitive Services accounts to use
private DNS zones", "Configure a private DNS Zone ID for blob groupID", "... for dfs groupID"), and
exemptions are written against assignments, not definitions. **Do not guess these names.** The prior
session's "zero DINE diagnostic policies assigned at the landingzones MG" was true of that one scope
and false of the estate, which is the exact ancestor-scope error LESSON 34 and the standing
pre-clearance rule exist to prevent.

**Item B: what created `diag-aif-bank-data-p1-globaris-poc` before 19:59:44?**

The first apply failed at 19:59:44. The Foundry `PolicyDeployment` did not start until 20:00:24, forty
seconds LATER. DINE therefore cannot have created the object the first apply tripped over. Neither can
it explain the Databricks failure, for which the evidence shows no competing PolicyDeployment at all.
The name `diag-<resource>` is computed by the AVM module from our own input, so nothing in Azure other
than this Terraform would produce it.

Two candidate explanations remain:

- **B1: the objects genuinely exist under Terraform-shaped names.** Then something PUT them and lost
  the acknowledgement, and the most likely writer is our own provider on a request whose response was
  lost. There is no third-party owner, and delete-and-retry is completely safe.
- **B2: the objects do not exist under those names, and the `already exists` is a provider false
  positive.** The Azure Monitor `diagnosticSettings` GET returns something the azurerm RequiresImport
  pre-check reads as an existing object for a name that was never created. This is a reported family
  on the provider (hashicorp/terraform-provider-azurerm issues #7114, #11076, #19500, #25673, all
  "already exists" on greenfield), and it fits the asymmetry in the evidence exactly: the datalake's
  setting is an **azapi** resource, which PUTs idempotently with no pre-check, and it did not fail
  while three azurerm siblings did.

**The discriminator is one read (D1 in ADR-070 decision 4): LIST the diagnostic settings on all three
resources and print the `name` of every entry verbatim, not the requested name from the URL.** The
existing GET evidence cannot settle it, because the RequiresImport check and `az rest` issue the same
API call - if that API is answering loosely it is answering loosely to both. Note also that "points at
`law-platform-globaris-poc`" does not discriminate either: a Terraform-created setting and a
DINE-created setting would both name that workspace. Pair it with **D2** (the DINE assignment's
workspace parameter at every ancestor scope): if that parameter is still the zero-GUID subscription
then OQ-021 holds, DINE cannot successfully write anything, and B2 is the only survivor.

One more datum to capture while reading: three `PolicyDeployment_*` were still `Running` about 50
minutes after starting. A diagnostic-setting PUT takes seconds. Either they are stuck, or their inner
PUT is being retried against an unsatisfiable target, which is what an unwired workspace parameter
would produce. Record the final `provisioningState` and any inner error code here.

**Consequence of leaving item B unanswered:** an unidentified writer that produces Terraform-shaped
object names is a bigger problem than a policy collision, because no exemption suppresses it. ADR-070
does not block the `bank-data-p1` recovery on this (the action is identical under B1 and B2), but it
does gate Step 9, where the same class would fire four times after a 60 to 180 minute APIM create.

**UPDATE 2026-07-31 (B) - item B is ANSWERED at the mechanism level by ADR-071 and NARROWED to
provenance only; item A is unchanged and remains ruled by ADR-070. Body above unedited.**

**Item A: no change.** The `Mitigated` exemptions landed (`b4c058e`, PR #67, merged `68080b8`) with the
live assignment names and `policyDefinitionReferenceIds` enumerated from ARM rather than guessed, which
is what this item asked for. Terraform won the zone-group race on `pe-aif-bank-data-p1-globaris-poc`:
the private endpoint carries Terraform's `default` group with **3** zones, not DINE's single-zone
`deployedByPolicy`. The three hung `PolicyDeployment_*` were cancelled at 122 minutes after collecting
`InternalServerError` for two hours against the zero-GUID placeholder workspace, so **no
`setByPolicy-LogAnalytics` object was ever created anywhere in the estate** - which also sharpens
OQ-021: the unwired parameter does not merely make that DINE inert, it makes it hang.

**Item B: the constraint the class now carries.** Five new facts, all live-verified 2026-07-31:

1. It reproduced on a SECOND root. `landing-zones/bank-app-p1` (run `30672301220`, failed at 33 min
   50 s) produced **five** orphans - `diag-apim-*`, `diag-acr-*`, `diag-aks-*`, `diag-evhns-*`,
   `diag-sbns-*` - all present in Azure, Terraform-named, exactly one per parent, absent from state.
   Eight instances across two roots and three runs, one signature.
2. **DINE is definitively excluded**, so the `B1`/`B2` framing above is settled in favour of neither:
   `diag-aks-*` is decisive (`Deploy-Diag-LogsCat` has no member for
   `microsoft.containerservice/managedclusters`, and the only AKS diagnostics policies in the chain are
   hard-capped `[AuditIfNotExists, Disabled]`), and the pinned azurerm v4.71.0 existence check is scoped
   to the exact configured name, so a policy-named object cannot collide with a `diag-*` one.
3. **The ARM incident is excluded as the mechanism.** The class fired again hours later, after the
   `diagnosticSettings` write path had demonstrably recovered - all eight B1 DELETEs returned cleanly,
   which is itself a probe of that path.
4. **A CI-side apply retry is excluded.** `.github/workflows/_tf-root.yml` retries only `terraform
   init` (six attempts, the ADR-025 firewall backstop). The apply step is not retried.
5. **The mechanism was already established in this estate and already ruled on.**
   `scripts/teardown-az-sweep.sh` step 2-pre exists because of ADR-063 decision 5 finding G-1: a
   resource-scoped diagnostic setting is keyed to its host's URI and does not reliably cascade away when
   the host is deleted, with `diag-aa-to-law` as the live proof from the 2026-07-23 rebuild - the same
   `already exists` on a recreated same-named host. The public issue family says the same
   (terraform-provider-azurerm #7114, #11070, #11076, #25673).

**What that changes.** The premise recorded in the operator log - "the objects are created and lost
DURING the apply" - is not established and is in tension with the provider's create ordering
(`ImportAsExistsError` is raised BEFORE any PUT, so the object existed before that create began). ADR-071
therefore rules the class as **FM-3**: an object that outlives both the estate and the state and is
invisible to every discovery-based greenfield proof, because its only address runs through a host that no
longer exists. The permanent fix moves to **teardown** (a Phase 0.5 live-host sweep, mirroring the
ADR-066 decision 4 Databricks precascade, because step 2-pre now runs after Phase 1 has already deleted
the hosts and can no longer see the residue it was written for). Two applies is ratified only as an
INTERIM operating rule.

**What is still open, and it is only this: which teardown left these eight, and whether all eight share
one provenance.** Closed by three reads, none blocking (ADR-071 decision 2): **T1** re-read the run
`30672301220` log for `Still creating...` ticks and for whether the `Error:` diagnostics share one
timestamp (if they do, the 10m17s / 2m14s / 55s figures measure to the end-of-run diagnostics block and
say nothing about the provider's own duration); **T2** query the Activity Log for
`Microsoft.Insights/diagnosticSettings/write` on the eight target resource IDs, guarding against the
empty-result trap; **T3** the falsifiable prediction - after the Phase 0.5 sweep lands, the next
greenfield first apply of these roots reports zero `already exists`.

**Blocking status revised: item B is NO LONGER BLOCKING for Step 9** (it was, and Step 9 has since been
dispatched and recovered). It stays open at Medium priority against T1, T2 and T3.

### OQ-066: The centralus-primary flip (ADR-069) rests on capacity that is EVIDENCED for a subset and ASSUMED for the rest - plus a teardown that failed and left the estate non-greenfield

- **Raised:** 2026-07-30 (architect, while ruling ADR-069 on the region flip)
- **Section:** 3 (Multi-Region DR Topology) / 10 (Pipeline & Tooling, dispatch). Relates to ADR-069
  (this ADR's verification debt), ADR-031 / ADR-032 (the two gates items 6-7 ask about), ADR-057 /
  ADR-063 / ADR-066 / ADR-068 (item 0, the failed teardown), OQ-043 (the eastus2 vCPU quota
  increase that does not carry over), OQ-063 (the Security LAW purge), OQ-025 / OQ-026 (the standing
  re-enable questions for SQL and App Service).
- **Blocking:** **Item 0 is BLOCKING for dispatch** and is not caused by the flip. Items 1-4 are
  blocking for Step 1; item 5 is blocking for Steps 5-9. Items 6-8 are non-blocking register items.
- **Priority:** High (items 0-3), Medium (4-5), Low (6-8).

**Question:**

ADR-069 flips the primary region to centralus. The ruling is correct on the evidence; what follows
is the evidence it does NOT have, stated so it has an owner rather than being buried in a design
document. I am read-only on live Azure and assert none of the ASSUMED set below.

**Item 0 (BLOCKING, not caused by the flip). Teardown run `30597640251` FAILED and the estate is
not greenfield.** Found 2026-07-30 while writing ADR-069, prompted by the operator asking why
`platform/security` was skipped. Phase 2 AZ SWEEP failed at step 4-pre on an ARM 500 listing MG-scope
budgets (ADR-063 G-1 fail-loud, working as designed, transient server error); Phase 3 VERIFY failed;
**Phase 4 STATE RESET was skipped** because it is gated hard on VERIFY success. Consequences:

- All eleven Phase 1 `terraform destroy` jobs were skipped. Not a security-specific skip: `mode=az-sweep`
  gates every one of them off (`teardown.yml:408` and its ten siblings). ADR-066 made `mode=terraform`
  the primary `target=all` path; this run used the fallback.
- az-sweep steps 6, 7 and **7b never ran**. Step 7b is the **Security Log Analytics workspace purge
  backstop (OQ-063)**, and the primary purge (`platform/security/providers.tf
  permanently_delete_on_destroy = true`) only fires on that root's own terraform destroy. **Neither
  ran**, so the Security LAW is soft-deleted rather than purged - the exact ADR-067 Class 2 condition
  that blocked the 2026-07-29 rebuild.
- Step 6 never ran, so the ADR-057 subscription-scope survivor class (budgets, cost exports, cost
  anomaly action, subscription diagnostic settings, Defender pricing, RP registration) is intact and
  will collide with Step 2.
- The MG hierarchy is still live (step 4 died in its own pre-gate).
- Four `kv-sec-globaris-*` Key Vaults are soft-deleted and could not be purged:
  `Operation 'DeletedVaultPurge' is not allowed` (`MethodNotAllowed`) on each, while the script had
  classified them "not purge-protected". Either the classification is wrong or the CI SP lacks
  `Microsoft.KeyVault/locations/deletedVaults/purge/action`. **This is a distinct sub-question worth
  root-causing rather than retrying.**
- Every Terraform state blob is still populated, including `platform/connectivity`'s 543 resources
  from the cancelled Step 4 apply.

That last point is why item 0 blocks the flip specifically: the AVM hub module derives
`fw-hub-${location}-001` from its location input, so applying the flip against live state
force-replaces both Premium firewalls, both policies and every hub route table. LESSON 26 and
runbook Rule 1 make that an unconditional STOP.

**Options for item 0:**
- **0A (recommended default): re-run teardown at `mode=terraform`.** ADR-066 already designates it
  the primary `target=all` path, all eleven Phase 1 destroys run serialized, and the security root's
  NATIVE LAW purge fires as the primary mechanism instead of depending on a backstop that a
  step-4-pre failure skips. Slower, but it is the path that produces green-per-layer evidence and it
  closes the OQ-063 exposure at its source.
- 0B: re-run `mode=az-sweep`. The 500 was transient and ADR-063 treats a failed list as fatal
  precisely so it can be retried. Faster, but keeps the LAW purge on the backstop and produces no
  per-layer evidence.
- 0C: hand-clean the survivors. **Rejected** - violates the CI-only teardown bar the user has ruled
  on twice.

Gate before any Step 1 dispatch, in order: teardown green -> Phase 3 VERIFY green -> Phase 4 STATE
RESET **executed, not skipped** -> independent qa-engineer greenfield confirmation (ADR-058) ->
PC-1SEC re-verified (zero live AND zero soft-deleted `law-security-*`) -> the four Key Vaults
dispositioned -> the six submitted RG deletes confirmed complete (step 7 never ran, so nothing waited
on them).

**Items 1-5: the live checks that close the ASSUMED set.** Full commands and pass bars are in
`docs/region-flip-centralus-primary.md` section 7 as RC-1 through RC-7. Summarised:

1. **Compute vCPU quota in centralus, landingzones subscription (HIGHEST RISK).** AKS needs 6 vCPUs
   steady (3 x `Standard_D2s_v4`) and 8 on surge. The limit was **10 in eastus2** and the 2026-07-18
   quota increase (OQ-043) was **filed for eastus2**. Quota is per region per subscription, so it
   does not carry over. `az vm list-usage --location centralus`. If short: file a centralus increase
   and set `enable_kubernetes_platform = false` for this rebuild - the spoke still ships network-only
   (LESSON 42), which is exactly what that pattern exists for.
2. **Entra Domain Services region support for centralus.**
   `az provider show --namespace Microsoft.AAD --query "resourceTypes[?resourceType=='domainServices'].locations"`.
   If centralus is absent this is not an implementation detail: `identity_location` would have to
   stay eastus2 and ADR-069 needs an explicit carve-out putting the identity pillar in the DR
   region, which is a real architectural change. AADDS cannot be moved after creation and its create
   is the 1-3h long pole.
3. **`gpt-5.4-nano` 2026-03-17 at `DataZoneStandard` in the centralus catalog.**
   `az cognitiveservices model list --location centralus` (confirmed GA in the CLI reference, page
   updated 2026-07-07). Model catalogs are per-region and the eastus2 catalog was already showing
   deprecations when ADR-051 was written (LESSON 40/41 class). ADR-051's recorded fallback is
   `GlobalStandard`, or the newest current-GA nano-class model in the **centralus** catalog. That is
   an architect disposition, not an implementer choice.
4. **`Standard_D2s_v4` zone restrictions in centralus.** AKS pins zones `["1","2","3"]`.
   `az vm list-skus --location centralus --size Standard_D2s`.
5. **`NetworkWatcher_centralus` AND `NetworkWatcher_eastus2` both present in `NetworkWatcherRG`,
   landingzones subscription.** The `data.azurerm_network_watcher` data source resolves at PLAN time,
   before any VNet exists to trigger auto-creation (LESSON 43), and this has already blocked this
   estate once: `docs/preclearance/landing-zones.md:117` records `_eastus2` MISSING as a hard
   BLOCKER for corp-a1 and online-p1. After the flip four spokes need `_centralus` and corp-a2 needs
   `_eastus2`. Both were live at the 2026-07-22 gate and `NetworkWatcherRG` is explicitly protected
   from teardown, so this should pass. Verify anyway.

**Item 6 (register, non-blocking). Does the flip lift ADR-031 (SQL)?** ADR-069 decision 7 rules it
does not: ADR-031 predicted `ProvisioningDisabled` in centralus before testing it, and corp-a2 has
shipped `enable_sql = false` there since 2026-07-10. **Recommended default: leave `enable_sql = false`
for this rebuild.** If the operator wants it re-tested, the only reliable probe is an actual
`az sql server create` in a scratch RG in centralus on the landingzones subscription followed by a
delete - a logical server with no database is free. That is a write and therefore an operator action,
not an architect one. Supersedes nothing in OQ-025, which stays the standing re-enable tracker.

**Item 7 (register, non-blocking). Does the flip lift ADR-032 (App Service)?** ADR-069 decision 7
rules it does not, on stronger grounds than item 6: ADR-032 itself proved with two portal quota
exports that eastus2 compute quota was healthy and that the failure was therefore an **offer cap** on
the subscription, not a regional limit (LESSON 42's whole point). Offer caps attach to the
subscription offer type. **Recommended default: leave `enable_app_service = false`.** Check if
desired via Portal -> Subscriptions -> Usage + quotas -> provider "App Service" -> region Central US,
looking at the "Total VMs" limit; a 0 there confirms the cap holds. Supersedes nothing in OQ-026.

**Item 8 (register, non-blocking). The AI Search escape hatch now has nowhere obvious to go.**
`search_location` was added because eastus2 AI Search returned `InsufficientResourcesAvailable`; its
fallback target was centralus, which after the flip IS the primary. Nothing in the record establishes
that eastus2 AI Search capacity has recovered, so if centralus Search capacity is ever exhausted the
variable points at a region with a known negative history. Not a problem today - centralus is the
region with the only positive Search evidence - but the mechanism is now single-valued in practice.
**Recommended default: no action; revisit only if a Search create fails.** If it does, the disposition
is a third region rather than a return to eastus2.

**UPDATE 2026-07-31 (architect, pre-clearance refresh #3). Items 0 to 5 are ALL DISCHARGED. Items 6 to 8 stand as register entries. Two items are added. Body above unedited, per append-only.**

**Item 0 (was BLOCKING): DISCHARGED.** The teardown reached green, ADR-068 Phase 4 EXECUTED rather
than skipped, and on 2026-07-31 the estate and all eleven state blobs were independently confirmed
greenfield from live read-only queries: management groups at Tenant Root only, no estate resource
groups in any of the five subscriptions, ten state blobs at 152-153 bytes and `platform/identity` at
181 (its carve-out A floor), zero soft-deleted and zero live Log Analytics workspaces on the security
subscription, and `rg-security-globaris-poc` absent entirely. The ADR-057 subscription-scope survivor
class is also fully absent: budgets 0 and cost exports 0 across all five subscriptions, zero
cost-anomaly scheduled actions, no subscription-level diagnostic settings. The gate this item
specified is met in full.

**The four unpurgeable `kv-sec-globaris-*` Key Vaults: ROOT-CAUSED, and neither hypothesis in the
item above was right.** They are **genuinely purge-protected** and Azure correctly refused. All four
report `purgeProtectionEnabled = True`, deleted between 2026-07-11 and 2026-07-31, scheduled purge
between 2026-10-09 and 2026-10-29, all in eastus2. The script's "not purge-protected" classification
was the defect: it compared an Azure CLI row-embedded boolean `True` against lowercase `"true"`, so
**the guard had never once fired** and the script attempted purges it should have skipped. Only Azure
server-side `MethodNotAllowed` prevented wrong purges across three consecutive live runs. PR #59
(`f34c4b7`) fixes the compare. The CI SP's permissions were never in question. **Nothing to action.**

**They cannot block Step 3, verified against pinned config.** `platform/security/main.tf:108` names
the vault `kv-sec-${var.org_prefix}-${random_id.security_kv.hex}` - a random suffix, not a region
token and not a stable name - so every apply generates a new name. The four orphans are name-unique,
with no create-time collision and **no soft-delete RECOVERY path either**, which means OQ-063's
recover-on-rebuild reasoning does not apply to this vault at all. `main.tf:110` also puts the new
vault in `centralus`, so it will not even share a region with them.

**Items 1 to 5: DISCHARGED by live checks RC-1 to RC-5, run 2026-07-31.**

| Check | Bar | Measured |
|---|---|---|
| RC-1 compute quota, centralus, landingzones sub | Total Regional >= 10, `standardDSv4Family` >= 8 | **10 / 10 / 10. PASS with ZERO headroom improvement over eastus2** - see new item 9. |
| RC-2 Entra Domain Services supports Central US | present | yes, and East US 2 for the secondary. **The query as written in the design doc was DEFECTIVE** (`domainServices` versus `DomainServices`, case-sensitive JMESPath, returns `[]`); corrected in `docs/region-flip-centralus-primary.md` on 2026-07-31. The documented consequence of an empty result was STOP and give the identity pillar a DR-region carve-out, so a one-character casing error would have triggered a real architectural change. |
| RC-3 `gpt-5.4-nano` catalog in centralus | GA, `2026-03-17`, `DataZoneStandard`, not Deprecating | all four. PASS. |
| RC-4 `Standard_D2s_v4` in centralus | zones 1,2,3, no restrictions | PASS. Load-bearing, because the AKS pool pins `availability_zones = ["1","2","3"]`. |
| RC-5 Network Watchers, landingzones sub | `_centralus` and `_eastus2` both in `NetworkWatcherRG` | both present, **re-confirmed AFTER the teardown**. `NetworkWatcherRG` does not match `RG_SWEEP_QUERY` in `scripts/teardown-common.sh`, so no teardown can delete it. |

**RC-6 and RC-7 were NOT run, and both are re-homed as pre-clearance conditions rather than left as
design-doc checks.** Pre-clearance refresh #3 promotes them:

- **RC-6 becomes PC-3REG, BLOCKING before Steps 5 to 9.** Six `az provider show` reads (APIM,
  Databricks, Service Bus, Event Hubs, App Gateway, Log Analytics in centralus) against a Step 9 that
  costs 60 to 180 minutes and, on an APIM failure mid-provision, leaves a soft-deleted instance that
  reproduces PC-4S for the next rebuild. The cost asymmetry is not close.
- **RC-7 becomes PC-1REG, BLOCKING before Step 2, and RE-SCOPED to Tenant Root Group.** As written
  RC-7 was non-blocking, to be run after Step 1, at the `globaris` scope. Both placements are wrong
  once the primary region moves. It is too late, because the first resource-group PUT into centralus
  is **Step 2**, not Step 4, and an allowed-locations Deny fails there with a clean plan and no
  plan-time signal. And it looks at a scope that does not exist at Step 0 while missing the one that
  does: before Step 1 the only management group in the tenant is Tenant Root Group, which is exactly
  where an externally-managed policy would sit. Strong prior evidence it passes (the repo assigns no
  `listOfAllowedLocations` anywhere, and this estate has created resources in centralus continuously
  for weeks), but it stays a gate per LESSON 34.

**Item 9 (NEW, register, non-blocking). Every full rebuild cycle permanently strands one more
purge-protected Key Vault for 90 days, and that vault is invisible to any name-keyed check.** Four
have accumulated since 2026-07-11. They are inert and free, but the residue grows monotonically with
rebuild count and nothing in the estate reclaims it. This is a design consequence of `random_id` plus
`purge_protection_enabled = true`, not a defect: a stable name would collide on rebuild, and disabling
purge protection would fail the posture bar. **Recommended default: accept it, and record it once
rather than rediscovering it every teardown.** The actionable half is that any future soft-delete
sweep must enumerate `deletedVaults` **by PREFIX** (`kv-sec-<org_prefix>-`), never by exact name -
which differs from the Log Analytics and APIM soft-delete cases, both of which have stable derived
names. Handed to devsecops as an extension of pre-clearance finding F4 (`teardown-probe.yml` has no
soft-delete class at all).

**Item 10 (NEW, register, non-blocking). RC-1's real finding is that the flip bought service
availability, not compute capacity.** Central US carries the **same 10-vCPU Total Regional limit** that
constrained eastus2, and the `standardDSv4Family` limit is also 10. The 2026-07-18 quota increase
(OQ-043) was filed for eastus2 and quota is per-region, so it does not carry over. AKS fits at 6 of 10
steady and 8 of 10 on surge, and it fits **only because nothing else in the estate draws regional vCPU
in centralus** (`enable_sql` and `enable_app_service` false, Databricks ships zero clusters,
`enable_synthetic_workload` false, AKS user pools quota-blocked). **Recommended default: proceed, and
if the Step 9 AKS create returns a quota error do NOT retry** (LESSON 59, runbook matrix U5) - set
`enable_kubernetes_platform = false` via a reviewed one-line tfvars PR, ship `bank-app-p1`
network-only, which is exactly what that pattern exists for (LESSON 42), and file a centralus quota
increase in parallel. Tracked as **PC-4REG** in the pre-clearance, as a watch-item rather than a gate.

**RESOLVED:** _(items 0 to 5 discharged 2026-07-31; items 6 to 10 remain open as register entries)_

---

### OQ-065: Two state-provenance gaps ADR-068 deliberately leaves open - the az-sweep path cannot clean `platform/identity`'s Entra objects (limb A), and the DEPLOY path still has no pre-plan state check at all (limb B)

- **Raised:** 2026-07-30 (architect, while ruling ADR-068 on the stale-state-after-teardown gap)
- **Section:** 10 (Pipeline & Tooling) / teardown + state backend. Relates to ADR-068 (which creates
  limb A as an explicit carve-out and defers limb B), ADR-066 / ADR-065 (az-sweep as the state-gone
  fallback), ADR-062 (VERIFY is ARM-plane discovery), ADR-060 (sequential single-target rebuild with a
  per-root plan-scan gate), OQ-053 (the mirror-image failure mode).
- **Blocking:** No for the current rebuild. Limb A has a zero-code workaround that can go in the runbook
  today. Limb B is the gap that let today's incident happen silently; it blocks nothing, but leaving it
  open means the same class recurs without warning the next time a teardown is skipped, fails, or is
  dispatched from a ref without the ADR-068 mechanism.
- **Priority:** Medium (limb A), Medium-High (limb B - it is a detection gap on the deploy path, which
  is the path that runs most often).

**Question:**

ADR-068 adds Phase 4 STATE RESET so a verified `target=all` teardown ends with canonical empty state.
Two things it deliberately does not close, both stated here rather than buried in the ADR so they have
an owner.

**Limb A. `platform/identity` is never reset in `mode=az-sweep`, so the az-sweep fallback structurally
cannot deliver a clean identity slate.** That root declares eight `azuread_conditional_access_policy`
resources, an `azuread_named_location`, `azurerm_pim_eligible_role_assignment` and
`azurerm_role_management_policy`. The az-sweep deletes by ARM API only and `teardown-verify.sh` has no
Entra, Graph or PIM check anywhere in VERIFY 0 through 10, so a green VERIFY says nothing about whether
those objects are live. ADR-068 carve-out A therefore holds identity's state POPULATED after an
az-sweep teardown - the safe side of the trade, because resetting it on absent evidence would risk
silent DUPLICATE tenant-wide conditional-access policies (Entra tolerates duplicate display names, so
the failure is quiet rather than an `ImportAsExistsError`). The cost is that identity keeps a phantom
state into the next rebuild. How should this be closed?

**Limb B. There is no state-provenance gate anywhere on the DEPLOY path.** `teardown-probe-state.sh`
exists and is authoritative, but it only runs from a manual `teardown-probe.yml` dispatch that nobody
is required to run. Today's incident was, reduced to one sentence, a deploy that planned against a
state nobody had checked: `platform/management-groups` refreshed roughly 537 phantom resources for 25+
minutes, and `platform/security` was about to be applied over the partial state ADR-067's addendum
forbids reconciling. Phase 4 fixes this ONLY when a teardown ran and went green. It cannot help when
teardown was skipped, failed, or was dispatched from a ref without the mechanism. The check that would
have caught it belongs where the plan happens.

**Options being considered - limb A:**
- **A1 (RECOMMENDED DEFAULT, zero code):** a runbook step. Before dispatching `target=all
  mode=az-sweep`, dispatch a single-root `target=platform/identity mode=terraform action=destroy`
  first. That deletes the Entra objects through the azuread provider and empties identity's state
  natively, so by the time the az-sweep runs there is nothing for carve-out A to protect. Costs one
  extra dispatch and no new code, and it is honest about what az-sweep is: the fallback for when the
  primary path is unavailable, not a replacement for it. Downside: it is a procedural control, so it
  can be forgotten, and forgetting it is silent.
- A2: teach `teardown-az-sweep.sh` to delete the Entra objects and `teardown-verify.sh` to check them
  (a Graph limb in both). Correct and durable, and it would make az-sweep genuinely whole-estate. Real
  work, and it needs Microsoft Graph application permissions the teardown service principal may not
  hold - which is its own tenant-permission question of exactly the class LESSON 49 covers, so it must
  be designed behind a default-false flag rather than assumed available.
- A3: accept it permanently and document it. Defensible: `mode=terraform` is the ADR-066 primary path
  and does cover identity properly, so this only bites on the fallback. Rejected as the recommendation
  because "the fallback silently under-cleans one root" is exactly the kind of quiet boundary that
  produces a two-week diagnosis later.
- A4: make the guard job REJECT `mode=az-sweep` unless a prior single-root identity destroy is
  attested. Rejected: attestation-by-input is unverifiable, and adding an input that the operator can
  simply set to true is a checkbox, not a control.

**Options being considered - limb B:**
- **B1 (RECOMMENDED DEFAULT):** add an optional `expected_state` input to `_tf-root.yml` with values
  `empty` / `populated` / `any`, defaulting to `any` (so nothing changes for existing callers). After
  `terraform init` and before `plan`, run `terraform state list` and fail loud on a mismatch. The state
  SA is already open in that job whenever `manage_runner_ip: true`, so this costs one command and no
  new firewall window. `deploy.yml` then passes `expected_state: empty` for a greenfield rebuild
  dispatch. This puts the check exactly where the damage happens and makes the operator's INTENT
  explicit at dispatch time, which is the part no automated check can infer. Open sub-question: whether
  `expected_state` is a `deploy.yml` dispatch input (operator states intent per run) or is derived from
  a rebuild-mode input. Recommend the former - one input, stated once per run, visible in the run log.
- B2: run the full `teardown-probe-state.sh` inventory as a required pre-step of any `deploy.yml`
  dispatch. More thorough (it sees all 12 keys, not just the target root) but it needs its own firewall
  window and it answers a whole-estate question when the job is about one root. Better as a scheduled
  or pre-rebuild check than as a per-apply gate.
- B3: fold the check into the existing ADR-060 per-root plan-scan gate instead - the plan-scan already
  reads the plan; a plan carrying a large refresh of phantom resources is visible in it. Rejected as
  primary: the plan-scan runs AFTER the 25-minute refresh has already been paid, so it detects the
  condition at the point where detecting it saves nothing.
- B4: do nothing; rely on Phase 4 (ADR-068) plus operator discipline. Rejected: Phase 4's guarantee is
  conditional on a teardown having run and gone green, and the incident this OQ exists for happened on
  a run where exactly that was true for the ESTATE and false for the STATE.

**Recommended default:** A1 now (runbook, today, free), with A2 designed only if an az-sweep teardown
is ever the primary path rather than the fallback. B1 next, as a small `_tf-root.yml` change on the
DevSecOps lane once the ADR-068 Phase 4 job has merged - the two touch the same area and batching them
avoids two reviews of the same file.

### OQ-064: A 2026-07-29 pre-clearance REFRESH ADDENDUM carrying a GO verdict exists only as gitignored files on one machine, and its repo-state basis is two merges stale

- **Raised:** 2026-07-30 (found uncommitted in a Temp-path worktree during the post-PR-54 sweep; flagged again by the code-reviewer because the rescue location is gitignored)
- **Section:** 10 (Pipeline & Tooling) / pre-clearance. Relates to the ADR-060 sequential single-target dispatch and the 2026-07-22 full-estate rebuild runbook.
- **Blocking:** ~~No for any current change. YES for the next full-estate dispatch, which has no valid
  pre-clearance without a decision here.~~ **CLEARED 2026-07-30 - resolved by Option A; see the RESOLVED
  block below. The full-estate dispatch now has a valid, committed pre-clearance.**
- **Priority:** High the moment a rebuild dispatch is contemplated.

**Question:**

A 225-line REFRESH ADDENDUM to `docs/preclearance/2026-07-22-full-estate-rebuild.md` was written on
2026-07-29, re-clearing the estate against the confirmed-clean greenfield with a per-root verdict
table and an overall **GO** for the 14-step dispatch. It was never committed. Its branch,
`docs/preclearance-2026-07-29-rebuild-refresh`, was merged without it, and the file sat uncommitted
in a worktree under the Windows Temp tree until the 2026-07-30 sweep found it.

It is currently preserved at `.claude/preserved/` in two forms (the full file and a patch). That
directory is **gitignored**, so the work still exists on exactly one machine and nothing in git
carries it. This is the second of the two losses in this class recorded across the repo, after
ADR-066 (lost outright, re-recorded as `9974efa`); the rescue out of Temp did not close it, because
a gitignored directory is still outside version control. The count of two matches the wording used
in `scripts/check-worktrees.sh` and the agent definitions.

Two decisions are needed, and they are independent:

1. **Durability.** Land it in git in some form now, or accept that it lives outside version control
   until someone decides. Leaving it gitignored is a decision by default, and it is the one that lost
   ADR-066.
2. **Validity.** Its repo-state basis is `origin/banking @ b6db5d0`, which is now two merges stale:
   PR #53 (`3ed8dad`, ADR-067) and PR #54 (`2ca1fc5`, ADR-066). PR #53 changed
   `platform/security/sentinel.tf`, `platform/security/defender.tf` and the apply parallelism in
   `.github/workflows/_tf-root.yml` - real apply-behavior changes to a root this document clears as
   GO. Whether that invalidates the verdict HAS NOT BEEN ASSESSED.

**Options being considered:**
- A (recommended): architect re-clears the addendum against `2ca1fc5`, specifically re-checking the
  `platform/security` verdict against ADR-067, and it lands as a normal reviewed commit. Closes both
  decisions at once.
- B: commit it as-is with a dated header stating the basis is `b6db5d0` and that it must not be
  dispatched on without re-clearance. Durable immediately, honest about staleness, but leaves a GO
  verdict in the tree that is not currently valid.
- C: leave it preserved and gitignored until a dispatch is actually planned. Cheapest now, and the
  option with a demonstrated failure history in this repo.

**RESOLVED 2026-07-30: Option A, both limbs, in one architect pass.** The artefact is
`docs/preclearance/2026-07-22-full-estate-rebuild.md` on branch `docs/preclearance-refresh-2026-07-30`,
cut off `banking` at `ed3450e`. Both decisions are answered separately below because they were raised
separately.

**Limb 1, DURABILITY: satisfied, and satisfied literally.** The rescued 225-line addendum is now IN the
repository, appended to the pre-clearance file **verbatim and unedited**, under a dated provenance banner
that records what it is, that it was nearly lost, and which of its sections survive re-clearance. It was
landed by applying `.claude/preserved/2026-07-29-refresh-addendum.patch` rather than by retyping, so
there is no transcription drift between the rescued file and the committed one. Nothing above it in that
file was rewritten; the file's existing append-only, dated-addendum convention is preserved. Once this
branch is committed the work exists in git rather than on one machine, and the `.claude/preserved/`
copies become redundant backups rather than the only extant version. **Option C is explicitly rejected**
and should not be reached for again: a gitignored directory is outside version control, and "preserved"
is not "durable". That is the same reasoning that made `scripts/check-worktrees.sh` a preflight gate.

**Limb 2, VALIDITY: the addendum's GO verdict is NOT valid and does not carry.** It was assessed against
`ed3450e`, and it fails for a reason larger than the two stale merges the question named:

- The dispatch it cleared **was actually attempted and failed at Step 3** (`platform/security` run
  `30499221661`, ADR-067). Its GO for that root was falsified by the run itself, before any code change
  is considered. A pre-clearance whose subject already failed cannot be carried forward on a code diff.
- **PR #53 (ADR-067) does not invalidate it. It helps.** Assessed file by file: the `sentinel.tf`
  `depends_on` additions are meta-arguments that create no address and produce no diff, so the Step-3
  plan shape is byte-identical; the `defender.tf` change is a comment only; the `-parallelism=1` in
  `_tf-root.yml` is appended to the **apply** step only, keyed on the conditional
  `inputs.root == 'platform/security'`, which occurs exactly once (`_tf-root.yml:366`). The caller input
  `root: platform/security` itself occurs twice (`deploy.yml:232`, `teardown.yml:395`), but the teardown
  caller passes `action: destroy` and the append is gated `if: inputs.action == 'apply'`, so plan and
  destroy are untouched. Net effect at apply is
  positive (it closes ADR-067 Classes 1 and 3) with one duration watch-item.
- **PR #54's `platform/security/providers.tf` change is INERT at apply.**
  `features.log_analytics_workspace.permanently_delete_on_destroy` was verified against the **pinned
  azurerm v4.71.0** documentation: Optional, default `false`, and it governs the DESTROY path only. It
  has no create, read or update path and needs no version bump.
- **What actually moves the verdict is what none of those changes covers.** ADR-067 Class 2 (a
  soft-deleted Security LAW being RECOVERED by the create PUT, re-hydrating roughly eleven orphaned
  `Microsoft.SecurityInsights` children that the emptied state does not know about) is closed **only on
  the teardown path**, by the native provider purge and by az-sweep step 7b. Neither can act on a
  workspace that is already in soft delete unless a teardown is dispatched from a ref containing them,
  and both merged in PR #54 (`2ca1fc5`) on 2026-07-30. **Every teardown run recorded in this repository
  predates that merge**, so on the available evidence the workspace is more likely than not in soft
  delete right now, and Step 3 would reproduce Class 2 exactly. Nothing on the apply path purges
  anything and there is no plan-time signal.

**New verdict: whole-run GO-CONDITIONAL.** No NO-GO and no open code blocker. `platform/security` moves
GO -> **GO-CONDITIONAL** on **PC-1SEC** (prove the Security LAW is not in soft delete; if it is, purge it
via a `target=all mode=az-sweep` teardown dispatch from a ref at or after `2ca1fc5`, never by hand), and
**PC-1Y** (prove the estate is actually greenfield) gates every root, because the last recorded live
event is a failed partial apply and no committed artefact records a teardown after it. The full per-root
table, the verified-versus-assumed split, the 2026-07-30 lifecycle re-audit, and the Step-0 amendment to
the dispatch runbook are all in the 2026-07-30 refresh section of the pre-clearance file.

**Follow-up, deliberately not written as an ADR in that pass to hold scope, recorded here so it is not
lost:** PC-1SEC generalizes. A purge-on-destroy mechanism is teardown-side and can never repair a rebuild
whose teardown predates it, so every future pre-clearance should carry an explicit **soft-delete-recovery
sweep** across every soft-deleting type in the estate: Log Analytics workspace, Key Vault, API Management
and Cognitive Services. This repo has now been bitten by that class twice, at PC-4S (APIM) and at
PC-1SEC (LAW). The cheapest durable form is F4 in the refresh's findings table: add the soft-delete
class to the read-only `teardown-probe.yml`, which today probes extension resources and state blobs but
queries no soft-delete list at all. Worth an ADR the next time the pre-clearance framework itself is
touched.

---

### OQ-063: Teardown soft-deletes the Security LAW rather than purging it, so every rebuild recovers a workspace full of orphaned Sentinel rules that Terraform then hits as "already exists"

- **Raised:** 2026-07-29 (diagnosing the platform/security clean-empty-state apply, run 30499221661; ADR-067)
- **Section:** 6 (Defender for Cloud + Sentinel) / 10 (teardown). Relates to ADR-067, the ADR-054/066 teardown
  workstream, and the "teardown incomplete at subscription scope" finding.
- **Blocking:** ~~YES until implemented.~~ **CLEARED 2026-07-30 - implemented and code-review APPROVED; see
  the RESOLVED block below.** Updated 2026-07-29: the user's process change (any layer failure = full
  teardown-and-restart from Step 1, no import-and-continue - ADR-067 addendum) makes this blocking, not a
  deferred tax. The restart's Step 3 (platform/security) will reproduce the exact ~11 "already exists" Class 2
  failure UNLESS the teardown purges the soft-deleted Security LAW first. Being RESOLVED by the ADR-066
  all-layers-green teardown workstream (ADR-066 on `docs/adr-teardown-all-layers-green`, ~~commit 0dac862~~
  [corrected 2026-07-30: the rebase onto `origin/banking` rewrote that hash, so it no longer resolves. The
  ADR-066 doc commit is now `9974efa` on that branch. Cite the branch and the ADR number, not a hash, which
  any rebase invalidates]): the LAW-purge MUST land before the restart reaches Step 3.
- **Priority:** High (was Medium; raised because it now gates the restart).

**Question:**
Log Analytics workspaces soft-delete for 14 days. Teardown deletes the Security LAW but does not PURGE it, so a
rebuild within 14 days re-creates the same-named workspace, which Azure RECOVERS from soft-delete WITH its
prior Microsoft.SecurityInsights children (analytics rules, data connector). Those come back as live objects
absent from the freshly-emptied Terraform state, so the security apply fails ~11 "already exists - needs
import" (ADR-067 class 2). Should teardown hard-purge the Security LAW so rebuilds start truly clean, and does
the same apply to the Security Key Vault (it has purge_protection_enabled = true, so it CANNOT be purged for 90
days - a different constraint that may instead need a recover-on-rebuild path)?

**Options being considered:**
- A: Teardown purges the Security LAW (`az monitor log-analytics workspace delete --force true`, or purge the
  soft-deleted workspace) as a Phase-2/completeness step. Rebuilds create a fresh workspace, no orphans, no
  import step. Preferred for the LAW. Must be wired into the teardown CI (no manual deletes), coordinated with
  the active ADR-066 teardown redesign.
- B: [NO LONGER APPLICABLE 2026-07-29] Accept the recovery and keep an import step as a standing rebuild
  procedure. Void now that the process is full teardown-and-restart with no import-and-continue (ADR-067
  addendum); Option A (purge on teardown) is the only path consistent with the restart model.
- C: For the KV specifically, purge protection forbids a hard purge for 90 days; if a rebuild lands inside that
  window the security apply must RECOVER the KV (or the AVM module must be told to recover) rather than create.
  Track whether the current teardown/rebuild path already handles this or needs an explicit recover step.

**RESOLVED 2026-07-30 (design and implementation; live proof carried by OQ-062):** YES, teardown hard-purges
the Security LAW. Option A is adopted and implemented, in the SAME teardown pass as ADR-066 (the coupling
OQ-062 asked for), and code-review APPROVED on re-review 2026-07-30 with all five prior BLOCK findings
verified closed. Option B stays void. The mechanism is two-layer, primary and backstop:

- **PRIMARY (`mode=terraform`, which is the default path at `target=all` after ADR-066):**
  `platform/security/providers.tf` now sets `features { log_analytics_workspace {
  permanently_delete_on_destroy = true } }` on the root's DEFAULT `azurerm` provider, which is the instance
  that creates the `security_law` module (no `providers =` override on that module call). Phase 1's
  `platform/security` `terraform destroy` therefore PURGES the workspace natively, in the same operation that
  would otherwise only soft-delete it. The argument is real rather than assumed: verified against the pinned
  azurerm v4.71.0 features schema when it was written and again at code review. It defaults FALSE, so it had
  to be set explicitly. This is the systemic fix ADR-067 decision 3 called for, and it makes the purge a
  property of the OWNING ROOT rather than of a sweep script, which is the durable shape.
- **BACKSTOP (`mode=az-sweep`, or a `platform/security` state applied before the provider feature landed):**
  `scripts/teardown-az-sweep.sh` step 7b recovers the soft-deleted workspace into a placeholder RG,
  force-purges it, then removes the placeholder. It was MOVED from step 3b to step 7b so it runs AFTER
  `wait_for_rgs_gone`, closing a race in which the security RG's `--no-wait` delete had not yet landed the
  workspace in soft-delete, so the step printed "nothing to do" and exited clean on a workspace that then
  soft-deleted minutes later. Idempotent by design: a workspace that is not in soft-delete (already purged
  natively, or purged by a prior run) is success, not an error.

**Limb C (the Security Key Vault) is answered, and the answer is that no separate recover step is needed.**
ADR-066's F2 verdict item 1 read the pinned provider source: with `purge_protection_enabled = true`
(`platform/security/main.tf`) azurerm does NOT attempt the purge on destroy. It logs that Azure will purge
automatically and returns success. So the vault soft-deletes as a SUCCESSFUL destroy and the 90-day retention
is respected rather than fought. A rebuild inside that window RECOVERS the vault instead of colliding on the
name, through the azurerm `key_vault` feature defaults (`recover_soft_deleted_key_vaults` and
`purge_soft_delete_on_destroy` both default true). Adding the `log_analytics_workspace` sub-block does not
disturb that: each `features` sub-block carries its own defaults, so omitting `key_vault` still yields the
documented defaults. The KV is therefore a post-destroy REPORT item (VERIFY 5, informational), not a
teardown-completeness gap, and limb C needs no further work.

**What this resolution does NOT claim.** It is not live-proven. Neither the native purge nor the step-7b
backstop has yet run against a real soft-deleted workspace. That proof obligation is carried by OQ-062, item
(e) of its 2026-07-30 update, and is deliberately NOT duplicated here so one test has one owner. If that run
shows the Security LAW still sitting in soft-delete after a `target=all` teardown, REOPEN this entry: a
stale-soft-delete survivor is the exact condition it exists to close.

**Operational precondition, which is the real gate and not a design question.** The blocking flag clears on
MERGE, not on authoring. The branch carrying both mechanisms must be merged into `banking` BEFORE the teardown
that precedes the rebuild's Step 3 is dispatched. A teardown dispatched from a ref WITHOUT the provider
feature soft-deletes the workspace again and reproduces the ADR-067 Class 2 failure on the next security
apply, with no signal at plan time.

**Standing consequence, recorded because it is permanent.** `permanently_delete_on_destroy` is a
PROVIDER-level (root-wide) feature, not a per-resource argument. Any FUTURE Log Analytics workspace added to
`platform/security` is therefore also permanently purged on ANY destroy of that root, including an accidental
wrong-root destroy, with no 14-day recovery window. That is intended for the Security LAW and is the trade
this resolution makes, but it is a real and permanent widening of that root's destroy blast radius. Anyone
adding a second workspace to `platform/security` must know it; a workspace that needs the soft-delete safety
net belongs in a different root.

### OQ-062: All-layers-green teardown (ADR-066) is proven by doc/provider reasoning only - it must be CONFIRMED on the next full `enable_data_platform=true` deploy then teardown, and the Databricks orphan-managed-RG handling chosen

- **Raised:** 2026-07-29 (recorded with ADR-066, which re-derived the teardown model against the user's all-layers-green requirement)
- **Section:** 10 (Pipeline & Tooling) / teardown; extends ADR-066, ADR-054/055/057, ADR-065 (partially superseded)
- **Blocking:** No for landing ADR-066's design and the teardown.yml change. Yes for calling all-layers-green PROVEN, and for finalising the Databricks belt form (decision 4 preferred vs alternative).
- **Priority:** Medium (High the moment a full teardown is next dispatched).

**Question:**

The estate is EMPTY right now, so ADR-066's central claim - that all 11 per-layer `terraform destroy` jobs RUN and go green in reverse-dependency order, serialized, each with the per-job JIT state-SA firewall flip - cannot be empirically tested today. ADR-066 is grounded in provider source (azurerm v4.71.0 KV delete skips the purge), module source (the pinned `avm-res-databricks-workspace 0.5.0` issues a PLAIN azapi workspace delete with no `forceDeletion`), and current Microsoft docs (plain workspace delete retains the managed RG; ARM `forceDeletion` exists at api-version 2026-01-01). Those are strong but they are reasoning, not a live run.

What must be proven on the NEXT full deploy (with `enable_data_platform = true`) then teardown:
- (a) all 11 serialized layer destroys go GREEN end to end within the ADR-055 durable-OIDC envelope, including the slow APIM / AKS / Databricks deletes;
- (b) whether the orphan Databricks managed RG's deny-assignment survives a plain workspace delete in THIS estate's Unity-Catalog-by-default configuration - this decides whether the ADR-066 decision-4 ALTERNATIVE (`az group delete --force-deletion-types Microsoft.Databricks/workspaces` on the orphan) is needed and actually bypasses the deny-assignment; the PREFERRED form (run the workspace force-cascade as a Phase 0.5 belt while the workspace is still live) sidesteps this and is the recommended default;
- (c) the 11-in-a-row per-job firewall flip is race-free as a sequence and the state SA reads Deny between jobs (audit `default_action`);
- (d) a follow-on greenfield apply succeeds with NO Databricks managed-RG name collision.

Exact test: dispatch teardown `target=all` in the new waved mode against a fully deployed estate and require DISARM green, all 11 Phase-1 jobs green in reverse order, one-open-at-a-time firewall audit, the az-sweep belt green (orphan managed RG removed or cascade confirmed), VERIFY green, then a clean greenfield apply.

**Same-pass coupling:** OQ-063 / ADR-067 (purge the soft-deleted Security Log Analytics workspace so rebuilds start clean, ~~tracked on the other branch~~ [corrected 2026-07-30, no longer a separate branch, see the update immediately below]) is ALSO a teardown-completeness item. It should be implemented in the SAME teardown pass as ADR-066 so a single full deploy -> teardown proves both, rather than two separate teardown cycles.

**Update 2026-07-30 (post-rebase; the same-pass coupling above is SATISFIED, and this entry now carries the
LAW-purge proof too).** ADR-067 / OQ-063 merged into `banking` (PR #53, `d8da413`) and the ADR-066 branch was
rebased on top, so ADR-065, ADR-066 and ADR-067, and OQ-061, OQ-062 and OQ-063, now live in one tree. The
"other branch" framing above is dead. More than that, the coupling actually happened rather than merely being
recommended: the LAW purge landed in the SAME teardown pass as ADR-066, as a native provider feature on
`platform/security` plus the `scripts/teardown-az-sweep.sh` step-7b backstop (see OQ-063, RESOLVED
2026-07-30). One full deploy then teardown therefore proves both workstreams, which is what this paragraph
asked for. Consequently:

- **(e) is added to the exact test above:** the Security LAW must be GONE, not soft-deleted, after the
  `target=all` teardown. Check `az monitor log-analytics workspace list-deleted-workspaces` on the security
  subscription and require ZERO rows for the security workspace name. In a `mode=terraform` run this proves
  the native provider purge; a `mode=az-sweep` run instead proves the step-7b backstop, including that it
  finds the workspace in soft-delete AFTER `wait_for_rgs_gone` rather than before it (the race the step-3b to
  step-7b move closed). Ideally exercise the backstop at least once, since the primary path hides it.
- **(f), the cheap and decisive follow-on:** the greenfield apply in (d) must also show `platform/security`
  CREATING a fresh workspace with ZERO "already exists / needs import" errors on any
  `Microsoft.SecurityInsights` child. That single observation closes the ADR-067 Class 2 loop end to end. If
  those errors reappear, the purge did not happen and OQ-063 REOPENS.

**Carried defect, non-blocking, wording only (found at the 2026-07-30 code re-review, recorded here so it is
not lost).** `scripts/teardown-databricks-precascade.sh:59` prints, on failure, that Phase 0.5 is "a hard gate
ahead of Phase 1's bank-data-p1 destroy (ADR-066 decision 4)". The verified wiring is the OPPOSITE and the
opposite is CORRECT: `bank-data-p1` lists `databricks-precascade` in `needs` for ORDERING only, its `if:`
never reads `needs.databricks-precascade.result`, so the layer still runs and still goes green if the
precascade fails, which is what preserves ADR-066 INV-1 (all 11 layers run and go green) and lets a resulting
orphan managed RG surface as a loud VERIFY 2/3 failure instead of a silently skipped mandatory layer. The
error text can therefore mislead an operator reading a failed CI log into thinking the teardown stopped when
it did not. Behaviour is right, the sentence is wrong. Not fixed in this pass (the code on that branch is
review-APPROVED and frozen); fold the one-line wording fix into the next teardown-script change, and do NOT
"fix" the workflow to match the sentence.

**Options being considered:**
- A (recommended): implement ADR-066 with the decision-4 PREFERRED Databricks handling (force-cascade before Phase 1), dispatch the waved teardown on the next full estate, and gate "proven" on the exact test above.
- B: also have the Cloud Engineer check the Terraform Registry for a newer `avm-res-databricks-workspace` version exposing `delete_query_parameters` / a force-deletion input; if one exists and is pinned, drop the Databricks belt entirely and let terraform destroy cascade the managed RG natively (the cleanest end-state, all-layers pure terraform).

**RESOLVED YYYY-MM-DD:** [pending the next full deploy -> teardown]

### OQ-061: The CI service principal depends on at least five UNDECLARED out-of-band grants, including tenant-root User Access Administrator - the repo's identity model and the live tenant have drifted apart

- **Raised:** 2026-07-23 (assembled while correcting ADR-063 decision 1; the individual pieces were
  found in three separate places and none of them was visible from the others)
- **Section:** 10 (Pipeline & Tooling) / identity; consolidates and outranks the grant-inventory
  fragments in OQ-051 and OQ-059(a); extends OQ-008 and ADR-021; relates to ADR-041, ADR-063
- **Blocking:** No for the next teardown - every grant below is currently LIVE, so the mechanism works.
  **Yes for closing ADR-021 / OQ-008**, whose entire subject is that this principal holds least
  privilege, which cannot be assessed while the real privilege set is not written down anywhere.
- **Priority:** High. The specific item that makes it High is standing tenant-root User Access
  Administrator on a CI service principal.

**Question:**

`bootstrap/identity.tf` is supposed to be the declaration of what `sp-alz-poc-cicd` can do. It is not.
Verified live against the tenant on 2026-07-23, the principal additionally holds the following, none of
it in any Terraform root:

**ARM role assignments at Tenant Root Group** (listed at exact scope; the SP object id is
`e630bdd0-...`, referenced abstractly here):

| Role | Declared? | Origin |
|---|---|---|
| Management Group Contributor (`5d58bcaf-...`) | **Yes** | `bootstrap/identity.tf` row 1 |
| User Access Administrator (`18d7d88d-...`) | **No** | ADR-041 bridge, applied 2026-07-16 |
| Cost Management Contributor (`434105ed-...`) | **No** | ADR-041 bridge, applied 2026-07-16 |

`bootstrap/identity.tf` declares User Access Administrator at **Globaris MG** only (row 3). The
tenant-root copy is a strictly wider, undeclared duplicate. It carries `*/read` and
`Microsoft.Authorization/*` across the entire tenant, which is the single widest standing privilege in
this estate and is held by an unattended CI principal that authenticates from GitHub Actions.

**Microsoft Graph app roles**, admin-consented out-of-band on 2026-07-08, recorded ONLY in a comment
block at `platform/identity/providers.tf:11-17` and in no register, ADR or `.tf` resource:

- `Policy.Read.All`
- `Policy.ReadWrite.ConditionalAccess`
- `Application.Read.All`

These are directly contradicted by `bootstrap/identity.tf:39`, which states "No API permissions needed
(all access is via ARM RBAC, not Graph)". Two files in the same repo assert incompatible things about
the same principal, and the false one is the one in the file that is supposed to be authoritative. This
is not academic: the ADR-063 draft pre-flight was built on `az ad sp show`, a Graph call that works only
because of `Application.Read.All`, and the design was reviewed twice before anyone noticed it depended
on a grant the bootstrap denies exists.

**Also to confirm, not asserted:** `docs/preclearance/platform-identity.md:51` records two TEMP
directory roles on this SP, Application Administrator and Groups Administrator, with an instruction to
remove both after the apply. Whether that removal happened has not been verified in this pass. If they
are still attached, the inventory is seven, not five.

**Why this needs its own entry rather than staying distributed.** Each fragment currently lives
somewhere that only makes sense if you already knew to look: the ARM bridges in ADR-041 and OQ-051, the
Consumption one restated again in OQ-059(a), the Graph roles in a provider comment. No document
anywhere states the principal's actual effective privilege. That is precisely the condition under which
OQ-008's scope-down cannot be evaluated, and it is how a tenant-root User Access Administrator reached
seven days past its stated time-box with, per OQ-051, no revocation owner.

**Options being considered:**
- **A (RECOMMENDED): one reconciliation pass that ends with every live grant either declared in
  Terraform or revoked, and nothing in between.** For each of the five, decide deliberately: does the
  mechanism need it, and if so at what scope. The expected outcome, to be confirmed rather than assumed:
  tenant-root User Access Administrator is REVOKED (its declared Globaris-MG sibling covers everything
  the estate roots actually do, and ADR-063's corrected role tables show the MG-scope sweep does not
  need it); Cost Management Contributor is replaced by the narrower standing row in OQ-059(a) option A;
  the three Graph app roles are either declared with `azuread_app_role_assignment` resources or
  formally accepted as an out-of-band prerequisite, and `bootstrap/identity.tf:39` is corrected either
  way because it is false as written. Cost: one focused change plus a revocation with a named owner.
- **B: declare everything as-is in Terraform, revoke nothing.** Fixes the drift and the false comment,
  fixes nothing about least privilege. Makes standing tenant-root User Access Administrator an official
  design position, which should only happen deliberately and is not recommended.
- **C: accept as-is, write the inventory into the teardown and deploy pre-clearance docs, revisit after
  the rebuild campaign.** Lowest effort, keeps the current mechanism untouched, and is the honest choice
  if the campaign cannot absorb an identity change right now. It still fixes the worst part, which is
  that nobody can see the real privilege set. `bootstrap/identity.tf:39` must be corrected under this
  option too.
- **Recommended default: A, with C as the immediate step if the rebuild campaign is mid-flight.** The
  inventory table above is written so it can be pasted into a pre-clearance doc today under either.

**Sub-item (b): the register itself has the same failure, and it is cheap to fix.** OQ-041 is cited by
ADR-041 (three times) and by OQ-051 as "the OQ-041 recommendation", and **no OQ-041 entry was ever
written into this file**. OQ-044 and OQ-045 are the same: referenced across `DECISIONS.md` and the
design docs, absent from the register. So the durable disposition of the Cost Management grant has been
notionally open for a week while being invisible in the one file whose job is to list open items. This
belongs with (a) because it is the same root cause in the records plane: decisions and grants made
out-of-band and recorded only in prose next to the thing they affected. Fix: write the missing entries
or explicitly retire the numbers, and treat a reference to a non-existent OQ as a review defect.

---

### OQ-060: A failed Phase-0 DISARM does not stop `az-sweep` or `verify`, so a `target=all` teardown can destroy the whole estate by raw REST with zero `terraform destroy` and still report green

- **Raised:** 2026-07-23 (found during the ADR-063 code review; independent of ADR-063's own subject)
- **Section:** 10 (Pipeline & Tooling) / teardown; relates to ADR-054 (four-phase shape), ADR-058
  (independent QA gate), ADR-063 decision 9
- **Blocking:** No for design, YES for the next `target=all` dispatch if DISARM is at any risk of
  failing. ADR-063 decision 9 rules on the main limb; this entry exists because the current behaviour
  was DELIBERATE, so reversing it is a decision the owner should see, and because the `verify` half is
  genuinely arguable.
- **Priority:** High

**Question:**

In `.github/workflows/teardown.yml`, all eleven Phase-1 root jobs gate on
`needs.disarm.result == 'success' || needs.disarm.result == 'skipped'`, so every one of them skips when
Phase 0 DISARM fails. `az-sweep` and `verify` do not. Both list `disarm` in `needs`, but their `if:`
conditions check only `needs.guard.result == 'success'` and `inputs.target == 'all'`, and the
`az-sweep` job's own header comment states the intent outright: "`needs` lists every Phase 1 job for
ORDERING only (run after them) - `!cancelled()` means none of their individual outcomes gates this job,
only guard's confirm check does."

That was a reasonable ADR-054-era choice while `az-sweep` was purely a remnant-catch for a *failed
root*. It is not reasonable for a failed *DISARM*, and the failure mode is severe:

- On `target=all` with DISARM failed, all eleven Phase-1 jobs skip and `az-sweep` runs alone. The run
  silently degrades from `terraform destroy` to raw REST deletes. The estate is destroyed and **every
  root's tfstate is left describing resources that no longer exist**, which is the precondition for
  the requires-import collision class that has now voided two rebuilds.
- `verify` then runs, checks live Azure, finds live Azure genuinely empty, and reports the teardown
  clean. The run goes green having done the one thing the four-phase design exists to prevent.
- Post-ADR-063 there is a second harm: DISARM is now the only place the MG-scope extension sweep runs.
  A failed DISARM means owned extension objects are still attached to MG scopes that `az-sweep`'s own
  `remove_mg_hierarchy` loop may then delete, which is exactly the G-1 one-way door.
- DINE policy assignments may also still be armed, so `az-sweep`'s RG deletes race live remediation.

**Options being considered:**
- A (RECOMMENDED, and ruled in ADR-063 decision 9 for the `az-sweep` half): add
  `&& (needs.disarm.result == 'success' || needs.disarm.result == 'skipped')` to both jobs, matching
  the Phase-1 form exactly. The `skipped` limb keeps single-target dispatches working, where `disarm`
  does not run at all. Phase-1 root outcomes stay ungated, so `az-sweep` keeps its real job of
  catching remnants from a failed root. Cost: a failed DISARM now produces a run that deletes nothing,
  which is the correct outcome and costs one re-dispatch.
- B: gate `az-sweep` on DISARM as in A, but let `verify` still run read-only after a failed DISARM,
  for its diagnostic value - VERIFY is the best inventory of live estate state the pipeline produces,
  and suppressing it on the exact runs that went wrong is arguably backwards. Requires VERIFY to print
  loudly that the run ABORTED and that a clean result means nothing was destroyed, so a green VERIFY
  can never be misread as "teardown succeeded". This is the only genuinely open half of the question.
- C: leave both ungated and rely on the operator reading the run summary. Rejected on its face: three
  incident classes in this project have come from a green run that did not do what its name implied.

**Recommended default (architect):** **A for `az-sweep`, and B for `verify`** - gate the destructive job
hard, keep the read-only inventory but make it self-labelling. If the wording work in B is not wanted,
take A for both; that is strictly safe and merely less informative.

**RESOLVED 2026-07-23 (owner): option A for BOTH jobs. The architect's recommendation was overruled on
the `verify` half.**

The architect recommended A for `az-sweep` and B for `verify`, and DevSecOps independently recommended
the same split. The owner ruled that both jobs are gated on `needs.disarm.result`, with no exception
for the read-only pass. Recorded as ADR-063 decision **9a**, an explicit owner override of decision 9.

The overruled argument is preserved so the trade-off is not relitigated from a blank slate: VERIFY is
the most complete inventory of live estate state the pipeline produces, and gating it means it is
suppressed on exactly the runs that went wrong. **What that costs, plainly: after a failed DISARM the
operator gets no VERIFY output at all, in precisely the runs where the estate is most likely to be in a
bad or half-known state.** Diagnosing such a run now requires a separate read-only probe
(`teardown-probe-extensions.sh`) or a manual dispatch rather than reading the failed run's own VERIFY
section.

What the override buys is one uniform rule for every job downstream of Phase 0, no conditional-wording
contract for a future change to get wrong, and no path by which an aborted run can emit a
green-looking VERIFY. Three incident classes in this project have come from a green run that did not do
what its name implied, and the owner weighted that history above diagnostic reach.

DevSecOps is implementing the override. If the loss of post-failure visibility proves painful in
practice, the re-open is narrow and should be argued on evidence: a separately dispatchable read-only
VERIFY, not a relaxation of the gate.

---

### OQ-059: Where does the Consumption-plane grant live durably, and who owns the MG-scope `Microsoft.Insights` delete gap?

- **Raised:** 2026-07-23 (ADR-063, Phase-0 MG-scope extension sweep)
- **Section:** 10 (Pipeline & Tooling) / teardown; relates to ADR-021, ADR-041, ADR-054, ADR-063;
  cross-references OQ-041 and OQ-051
- **Blocking:** No for the next teardown. ADR-063 decision 1a establishes that the Phase-0 sweep works
  TODAY with zero bootstrap change, because the ADR-041 bridge grant is live. **(a) is now recommended
  for RESOLUTION rather than continued parking** - see the 2026-07-23 update below.
- **Priority:** Medium for (a), Low for (b)
- **Updated:** 2026-07-23 (code review of ADR-063; the decision 1b pre-flight was withdrawn and the
  framing of (a) changed with it)

**Question:**

ADR-063 decision 1 resolved how `sp-alz-poc-cicd` is able to delete MG-scoped consumption budgets at
all: not through any role in `bootstrap/identity.tf`, but through the ADR-041 bridge grant of
`Cost Management Contributor` at Tenant Root Group, applied out-of-band on 2026-07-16. Two questions
were left open by that ruling.

> **RECORDS NOTE, 2026-07-23.** This question is not new. ADR-041 raised it and routed it to "OQ-041",
> with the recommendation "a new bootstrap row at globaris MG scope, revoking the tenant-root temp"
> (`DECISIONS.md`, ADR-041 decision text and follow-ups). OQ-051 then cites "the OQ-041
> recommendation" as though it were a live entry. **There is no OQ-041 entry in this file. It was
> never written.** The question has therefore been open, referenced by two ADRs and one OQ, and
> invisible in its own register for a week. OQ-059(a) below IS that question, and it is the single
> live home for it from now on; treat any future reference to OQ-041 as pointing here. The same orphan
> pattern exists for OQ-044 and OQ-045; all three are now tracked together in **OQ-061 sub-item (b)**,
> alongside the undeclared-grant inventory they are the records-plane symptom of.

**(a) Where should the Consumption-plane grant live permanently?** Today it is an out-of-band assignment
that no Terraform root declares, which means nothing in the repo would stop it being revoked, and
nothing would warn that revoking it breaks teardown. **This is now a hard dependency of the teardown
mechanism, and OQ-051 must not be actioned without first landing an answer here.**

- A: add a standing `bootstrap/identity.tf` row granting `Cost Management Contributor` at the
  **globaris MG**. Sufficient for all three MG budgets (globaris and its descendants); subscription
  budgets are already covered by Contributor. Inherits the BOOTSTRAP-ORDERING dance of the existing
  MG-scoped rows, and dies with the subtree, which is what makes the ADR-063 G-1 ordering invariant
  load-bearing rather than merely tidy.
- B: define a custom role carrying only `Microsoft.Consumption/budgets/{read,write,delete}` and assign
  that instead. Tighter, but adds a custom-role definition to maintain and to tear down.
- C: keep the ADR-041 tenant-root bridge permanently and document it as a standing grant.
- Recommended default: **A**, and it should be RESOLVED AND LANDED now rather than parked again.

**Why the framing changed on 2026-07-23.** The original recommendation added "with the ADR-063 decision
1b pre-flight assertion retained regardless of which option lands". That was false as written: the
pre-flight was pinned to Tenant Root Group, so **landing option A would have made it hard-fail every
dispatch** while the sweep itself worked correctly. The check and the recommended fix were mutually
exclusive and nobody noticed, because the check was written against the grant's current location rather
than against the capability. ADR-063 decision 1b has been re-ruled and the pre-flight rebuilt as an
effective-permissions assertion at MG scope, which is indifferent to where the grant sits. Two
consequences for this question:

- **The pre-flight no longer papers over this question.** Whichever of A, B or C lands - and whether
  the grant arrives at tenant root, at globaris, via a custom role or via a group - the 1b(iv) probe
  reads the SP's own effective actions at each MG scope and answers correctly. It does not have to be
  rewritten when this resolves, which is exactly what disqualified both earlier designs.
- **So resolving this is no longer urgent for teardown mechanics, but it IS still the right thing to
  do,** because the mechanism should not depend on an undeclared out-of-band grant that nothing in the
  repo protects and whose revocation is tracked as an unowned action in OQ-051.

Scope correction while resolving: the corrected ADR-063 decision-1 tables show this grant is needed for
**one** of the three Phase-0 MG-scope classes, not all three. MG-scope policy exemptions are already
covered twice over by standing `bootstrap/identity.tf` rows (Resource Policy Contributor's
`Microsoft.Authorization/policyexemptions/*` and User Access Administrator's `Microsoft.Authorization/*`,
both at globaris). Only the Consumption budget class needs anything new, which makes option A a
one-row change with a well-bounded justification.

Verified while re-ruling, and recorded here because it is reusable: ARM's effective-permissions API
(`GET {scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01`) **does work at
management-group scope**, returning HTTP 200 and the caller's own effective `actions`/`notActions`,
even though Microsoft documents only `List For Resource` and `List For Resource Group` for that
operation group. Confirmed live against this tenant on 2026-07-23. Because it is undocumented at that
scope, ADR-063 1b(iv) requires a failed call to be labelled distinctly and never treated as
"capability absent".

**(b) Who owns the MG-scope `Microsoft.Insights/diagnosticSettings/delete` gap?** ADR-063 decision 1d
established that no role this SP holds can DELETE a diagnostic setting at MG scope, although it can
list one (User Access Administrator's `*/read`). The estate declares no MG-scope diagnostic setting
today, verified by grep across every root, so the gap is latent rather than live.

- A: accept the gap. Keep discovery in place so a future one is always SEEN, and make the delete fail
  loud with wording that names this as a known design gap rather than a dead token, so it is never
  misread as the auth-fail-loud signal.
- B: grant `Monitoring Contributor` at globaris pre-emptively, so the class is deletable the day
  something declares one.
- Recommended default: **A**, on the grounds that the estate declares none and a pre-emptive grant
  widens the SP for a resource class that does not exist. Revisit the moment any root declares an
  MG-scope diagnostic setting - and note that such a root must not merge without B landing first.

---

### OQ-058: Post-rebuild follow-ons parked out of the ADR-062 exemption ruling

- **Raised:** 2026-07-21 (ADR-062, subscription-scoped exemption survivor)
- **Section:** 10 (Pipeline & Tooling) / teardown; relates to ADR-048, ADR-057, ADR-062
- **Blocking:** No. All four items are deliberately parked until AFTER the 2026-07-22 rebuild. Tonight's
  change is scoped to the exemption class plus the VERIFY predicate; nothing here is needed for it.
- **Priority:** Medium for (a) and (b), Low for (c) and (d)

**Question:**
ADR-062 closed the policy-plane discovery gap and added subscription-scoped exemptions to the sweep.
Four adjacent items were identified while ruling on it and were deliberately NOT taken, to keep the
change small the night before a long rebuild day. They should be decided once the estate is back up.

**(a) Should every policy exemption carry an estate `metadata` stamp, so the ownership predicate
becomes purely structural?** `Microsoft.Authorization/policyExemptions` supports an arbitrary
`metadata` object, and azurerm exposes it. If every exemption the estate declares carried something
like an `estate` key, the predicate would stop needing the `exempt-` name limb entirely, and a
future exemption named anything at all would still be recognised. This CANNOT help the current
survivor, which already exists without metadata, and the predicate must therefore never depend on it.
It also touches `.tf` in roots that are about to apply, which is why it is parked rather than bundled.
- Recommended default: **do it, after the rebuild is green**, as a small cross-root change covering all
  8 exemption resources, with the name limb retained as a fallback rather than removed.

**ARCHITECT NOTE 2026-07-23 (ADR-063, applies to (a) only):** the recommendation above STANDS
unchanged - do the metadata stamp after the rebuild is green, as a fallback limb, never as a
dependency. What must be corrected is its GENERALITY. ADR-063 decision 6 replaced the name-first
ownership test with containment-first, and while ruling on it the following became clear: a metadata
stamp cannot be the structural answer, because `Microsoft.Consumption/budgets`,
`Microsoft.Insights/diagnosticSettings` and the `Microsoft.Security` singletons expose no metadata
object and no tags surface at all. That is three of the five extension classes now in play. The general
mechanism is T1 containment (an object is owned when its host scope is owned); metadata stamping remains
a worthwhile policy-plane nicety for the 8 exemption resources and nothing more.

**(b) Is there a discovery mechanism for the cost and monitor planes?** ADR-062 decision 5 states
plainly that ARG has no table for Consumption budgets, CostManagement exports, CostManagement
scheduled actions, or subscription diagnostic settings, so those four classes remain enumerated with no
backstop. That is the honest residual gap in the new gate.
- Options: A - accept the gap and rely on the enumerated checks plus the ADR-058 QA pass. B - build an
  Activity-Log-based discovery pass (see (c)). C - re-check periodically whether Microsoft has onboarded
  these types to Resource Graph.
- Recommended default: **A now, C as a standing pre-clearance re-check**, revisit if a fourth class is
  ever lost in those planes.

**(c) Activity-Log-based discovery as a general backstop.** Rejected for ADR-062 and worth a proper
look later. Terraform's azurerm provider calls resource-provider APIs directly and creates no ARM
deployments, so deployment history is empty and the subscription Activity Log is the only general trace
of what the estate created at subscription scope. Retention is 90 days, the API is throttled, and the
signal-to-noise is poor for a hard gate.
- Recommended default: **investigate as an informational QA aid, not as a build-breaking gate.**

**(d) Should `expires_on` be dropped from the ADR-048 dbstorage exemption?** ADR-062 established from
Microsoft's exemption-structure reference that an exemption is NOT deleted when `expiresOn` is reached:
the object is preserved for record-keeping and only stops being honoured. So the 2026-08-01 expiry gives
none of the lifecycle cleanup its design comment implies, while adding a date that will silently stop
admitting the Databricks storage create if a rebuild happens after it passes. That is a live footgun for
any rebuild after 2026-08-01.
- Options: A - keep it and push the date out at each rebuild. B - drop `expires_on` and rely on teardown
  sub-step 6d for removal, which now exists. C - keep it but add a pre-clearance check that the date is
  still in the future.
- Recommended default: **B, with C as the interim**, since removal is now a teardown obligation rather
  than a hoped-for self-expiry. Needs a decision before any rebuild dated after 2026-08-01.

---

### OQ-057: `deploy.yml target=all` is documented as the full-environment shortcut but is structurally non-functional for apply - remove it, restrict it to plan, or fund a runner-egress solution?

- **Raised:** 2026-07-21 (2026-07-22 rebuild pre-clearance, PC-1X / ADR-060)
- **Section:** 10 (Pipeline & Tooling); relates to ADR-025, LESSON 30, LESSON 31, OQ-018
- **Blocking:** No. ADR-060 rules sequential single-target for the rebuild, so nothing waits on this.
- **Priority:** Medium (a documented path that cannot work is a trap for the next operator)

**Question:**
`DEPLOYMENT.md` section 4 presents `target = all` as the way to deploy the whole environment in one
dispatch. It cannot work today: the state storage account is `default_action = Deny` with a single
operator IP rule, and `deploy.yml` disables the JIT firewall flip precisely when `target = all`, so every
root would 403 at `terraform init`. Even with a manual firewall window it removes the per-root plan-scan
gate, runs five spokes that write concurrently to the same private DNS zone and the same regional Network
Watcher, cannot express the ADR-055 identity two-pass, and cascade-skips the graph on one failure. What
should happen to it?

**Options being considered:**
- **A (recommended): restrict `target=all` to `action=plan`** and add a guard job that rejects
  `target=all` with `action=apply`, mirroring the existing `guard-untaint-target` /
  `guard-force-unlock-target` pattern. Cheap, honest, keeps the aggregate dry-run which is genuinely
  useful, and removes the trap.
- **B: delete the `all` option entirely.** Cleanest, but loses the aggregate plan.
- **C: make `target=all` work** by moving the state account behind a private endpoint with a self-hosted
  or VNet-integrated runner (the OQ-018 Option B work). Correct long-term production answer, materially
  more work, and it still would not restore the per-root plan-scan gate.
- **D: leave as is and rely on documentation.** Rejected on principle: a mechanism that fails only at
  init, only in CI, and only on one input value is exactly the class this repo keeps getting burned by.

### OQ-056: The five landing-zone spokes cannot be dry-planned against a torn-down estate - should spoke data sources be made plan-safe so a greenfield estate is fully dry-plannable end to end?

- **Raised:** 2026-07-21 (2026-07-22 rebuild pre-clearance, PC-2S and section 5a)
- **Section:** 4 (Private Endpoints + Private DNS) / 9 (Landing Zone Spokes); relates to LESSON 5,
  LESSON 43, LESSON 52
- **Blocking:** Partially. The `bank-app-p1` instance of it (`aks_lookup`) IS blocking and has a fix spec
  in PC-2S. The cross-root instance (private DNS zone lookups) is not blocking, it just removes the
  ability to pre-verify.
- **Priority:** High for the same-root case, Medium for the cross-root case

**Question:**
Three classes of data source stop a spoke plan from running on an empty estate. (1) `aks_lookup` in
`bank-app-p1` reads a cluster the SAME root creates, so it can never resolve on a greenfield plan; that is
a defect, and PC-2S specifies the flag-gated fix. (2) `azurerm_private_dns_zone` in every spoke reads
zones created by `platform/connectivity`, so no spoke can be dry-planned before connectivity applies; that
is a legitimate cross-root dependency, but it means five of ten roots go into an apply with no pre-verified
plan. (3) `azurerm_network_watcher` turned out to be fine (both regional objects survive teardown), but
only by luck of Azure auto-creating them. Should the estate adopt a rule that makes greenfield fully
dry-plannable?

**Options being considered:**
- **A (recommended): a standing rule plus targeted refactors.** Rule: a data source may never read a
  resource created by its own root; a data source that reads another root's output should, where the value
  is a deterministic id, be replaced by a constructed string from variables (the ADR-059 import-id rule
  generalised). Applied to the private DNS zones this would replace eleven lookups with constructed zone
  ids, and every spoke would become dry-plannable on an empty tenant.
- **B: accept it and rely on the shape-based plan-scan bar** applied at each spoke's own plan, as this
  rebuild does. Zero work, but it permanently gives up pre-dispatch verification for half the estate.
- **C: fix only the same-root case (PC-2S) and leave the cross-root lookups alone.** The minimum that
  unblocks Wednesday. Recommended as the immediate step regardless of which option wins.
- **D: introduce a "connectivity contract" module** that both connectivity and the spokes consume, so zone
  ids come from shared locals rather than lookups. Cleanest conceptually, largest diff.

### OQ-055: Cross-root output Secrets are a manual, unverifiable coupling that has in fact been stable across three rebuilds - keep the determinism contract, or remove the coupling?

- **Raised:** 2026-07-21 (2026-07-22 rebuild pre-clearance, PC-2X / ADR-061)
- **Section:** 10 (Pipeline & Tooling); relates to LESSON 32, ADR-061
- **Blocking:** No. ADR-061 makes the rebuild safe.
- **Priority:** Medium

**Question:**
Eleven repo Secrets carry values produced by `platform/connectivity` and `platform/management` into
`platform/connectivity` itself (the platform LAW id, for firewall diagnostics), `platform/identity` and
the five spokes. Nothing automates the refresh; the instruction is a prose bullet
in `DEPLOYMENT.md`. Repo Secrets are write-only, so a consumer can never check what it was handed, and a
wrong value surfaces days later. ADR-061 resolves the immediate risk by classifying ten of the eleven as
derived-from-names (therefore never refreshed) and mandating one unconditional re-set. But the underlying
coupling remains: a single change to `org_prefix`, `environment`, the hub address spaces or the firewall
subnet carve would silently invalidate ten Secrets at once. Should the coupling exist at all?

**Options being considered:**
- **A: keep ADR-061 as is.** Zero further work. The determinism contract is documented and the one risky
  value is re-set every rebuild. Accepts the naming-change fragility.
- **B (recommended for the production restoration wave): replace the derived Secrets with constructed
  values.** The spokes already receive `landingzones_subscription_id` and `connectivity_subscription_id`
  plus `org_prefix` and `environment`, so `primary_hub_vnet_id` and friends can be built as locals from
  variables and literals. That deletes eight Secrets, removes the manual step, and makes a naming change a
  code change rather than a silent breakage.
- **C: `terraform_remote_state` data sources against the state account.** Authoritative values with no
  manual step, but it gives every consuming root read access to producing roots' full state, widens the
  backend access model, and reintroduces a plan-time cross-root dependency for values that are currently
  static inputs.
- **D: automate `gh secret set` inside `_tf-root.yml`.** Rejected in ADR-061: it would give every apply
  job write access to repo Secrets for a value that changes approximately never.

### OQ-054: Should a recovery-only input ever live as a standing repo Secret? Second incident of a stale standing Secret silently changing a run's behaviour

- **Raised:** 2026-07-21 (greenfield `platform/identity` plan failure, run 29851615122; ADR-059
  decision 4)
- **Section:** 10 (Pipeline & Tooling) / CI inputs; relates to ADR-029, ADR-055 Part 1, LESSON 32,
  LESSON 52
- **Blocking:** No. ADR-059 decisions 2, 3 and 5 make tomorrow's run safe without this. This is the
  durable fix.
- **Priority:** Medium

**Question:**
`AADDS_IMPORT_REPLICA_SET_ID` is a ONE-SHOT recovery input carried as a standing GitHub repo Secret.
It silently armed a config-driven import block on a greenfield plan, because a stale value from the
July recovery era was never cleared. This is the SECOND time a stale standing Secret has silently
changed a run's behaviour in this repo. Should recovery-only inputs be carried as `workflow_dispatch`
inputs instead of standing Secrets, as a general rule?

**Why a standing Secret is a poor carrier for a one-shot input, specifically:**
- **Write-only.** It cannot be read back to diagnose (LESSON 32). Nobody can answer "is it set?" by
  looking at the repo.
- **Masked.** An operator cannot tell armed from unarmed. The ONLY available oracle is an indirect
  artifact: GitHub renders `***` for a non-empty secret and nothing for an empty one in a job log.
  That artifact is literally how this failure was diagnosed, after it had already broken a run.
- **Persistent.** It survives every teardown, every branch, every rebuild cycle, and every document
  that discusses it. Three separate documents touched this Secret (the 2026-07-12 gate said delete it,
  ADR-055 reinstated the wiring, the 2026-07-21 refresh marked the delete instruction superseded) and
  none of them owned the VALUE.
- **No dispatch-time signal.** It arms a code path with nothing visible at the moment a human decides
  to run something.

A `workflow_dispatch` input inverts every one of those properties: blank by default, plainly visible
in the run's own UI, typed deliberately by a human for one specific run, structurally incapable of
surviving to the next run, and fail-closed on a malformed value. The `enable_conditional_access_override`
input added by ADR-055 Part 1 is the working precedent in this same workflow.

**Options being considered:**
- A (RECOMMENDED): convert `aadds_import_replica_set_id` to a `workflow_dispatch` input on the
  ADR-055 override pattern, and adopt the general rule that **recovery-only and one-shot inputs are
  dispatch inputs, never standing Secrets**. Standing Secrets remain correct for durable
  configuration (subscription IDs, contact addresses, group object IDs) - the distinction is
  one-shot versus durable, not secret versus not. Cost: a small `deploy.yml` plus `_tf-root.yml`
  change, mirroring code that already exists.
- B: keep the Secret and add a mandatory pre-dispatch verification step to every affected gate (check
  the `***` artifact in the previous run's log, or re-set the Secret to empty before each greenfield
  run). Zero code change, but it is a procedural control over a mechanism that has now failed twice,
  and it depends on an indirect oracle.
- C: keep the Secret and have the root itself fail loudly when the input is non-empty on what looks
  like a greenfield plan. Rejected: the root cannot reliably tell greenfield from recovery at plan
  time, which is the whole problem.

**Recommended default:** A, implemented AFTER `platform/identity` is green. Deliberately not before:
it modifies the workflows whose two-pass behaviour tomorrow's run exists to prove, and changing the
subject of a proof immediately before that proof is bad practice (ADR-059 decision 4).

### OQ-053: Two Terraform state blobs were deleted from the firewalled state account and nobody can say when, how, or by whom - the data survived, the forensics did not

- **Raised:** 2026-07-21 (teardown QA pass finding 1, run 29847433748; architect ruling PC-7R)
- **Section:** 10 (Pipeline & Tooling) / state backend; relates to ADR-004, ADR-024, LESSON 3,
  LESSON 51
- **Blocking:** No. B0a is cleared to proceed (PC-7R ruling 1, `docs/preclearance/b0a-redeploy.md`
  section 11) because the affected roots are a greenfield rebuild and live Azure is independently
  confirmed empty. This is about the NEXT time, when it may not be.
- **Priority:** Medium

**Question:**
The `platform/management` and `platform/security` state blobs are ABSENT from the `tfstate` container
(genuine `BlobNotFound`, not a permissions error). Blob versioning preserved the history, so the last
good state of each root is intact and promotable. The deletion was not caused by the teardown (the
three teardown scripts contain zero references to the tfstate container, and Phase 1 was skipped for
every root in every run since 2026-07-20) and predates it. The cause cannot be established, because
blob deletes are DATA-PLANE operations that never appear in the subscription Activity Log, and no
diagnostic pipeline was wired to capture them. What is the proportionate durable fix?

**Two live facts that reframe this (verified 2026-07-21 against the account's blob service
properties):**
1. **The data protection is already correct and it worked.** Blob soft-delete is enabled (14 days,
   `allowPermanentDelete: false`), container soft-delete is enabled (14 days), and versioning is
   enabled. With versioning on, a plain DELETE leaves the base blob with no current version rather
   than destroying anything, which is exactly the observed signature. Nothing was permanently lost and
   nothing could have been. **So the gap is NOT data protection, and proposals to add more of it are
   solving a problem that does not exist.**
2. **The forensic surface is completely absent.** No diagnostic settings on the storage account or its
   blob service, and change feed is OFF. That is the entire reason "by whom and when" is unanswerable.

**Do NOT propose immutability or WORM on the state container.** ADR-024 already removed exactly that
(a container-level time-based policy) because it intercepts the azurerm backend's lease and lock path
and hard-fails state writes with `BlobImmutableDueToPolicy`. LESSON 3 records the same thing as a
general rule: never put an immutability policy on a Terraform state container, use versioning for
recovery. Re-proposing it would recreate a resolved incident.

**Options being considered:**
- A (RECOMMENDED, and it is two small pieces): (i) enable **change feed** on the state account - a
  per-account setting, pennies, that records an ordered durable log of every blob write and delete
  with timestamps, and critically it SURVIVES teardown because the state account is out of teardown
  scope; (ii) wire the **PC-7R pre-plan state-provenance probe** into the CI plan path so an absent
  blob is DETECTED and surfaced rather than silently read as greenfield. Together these answer "when
  and what" and, more importantly, make the condition visible the moment it matters. Change feed does
  NOT record caller identity, which is the honest limit of this option.
- B: A, plus storage **diagnostic logging** (blob `StorageDelete` / `StorageWrite`) to a Log Analytics
  workspace, which is what actually answers "by whom". **Design constraint that must not be missed:**
  the platform LAW is destroyed at every teardown, so the destination CANNOT be it, or the forensic
  trail dies exactly when it is needed. It must be a bootstrap-scoped destination that outlives
  teardown - a small dedicated workspace or a storage destination in the bootstrap resource group.
  That is a real (if modest) piece of new bootstrap infrastructure and its own cost line.
- C: accept the gap, rely on versioning plus soft-delete for recovery, and add nothing. Defensible
  purely on data-safety grounds (fact 1), and it is honestly where the risk actually sits. Rejected as
  the recommendation only because "a state blob vanished and we will never know why" is not a sentence
  that should be repeatable.
- D (REJECTED, recorded so it is not re-proposed): container or version-level immutability. See
  ADR-024 and LESSON 3 above.

**Recommended default:** A now (cheap, no new infrastructure, closes the detection half immediately),
with B considered if it recurs or before the estate carries anything more valuable than a rebuildable
POC state. The PC-7R probe in A(ii) is the part that carries real weight: it converts a silent,
plan-invisible condition into a loud one, which is the same failure class as the 2026-07-20 teardown
blind spot and deserves the same treatment.

### OQ-052: The Defender `AI` plan is armed at Standard in the security subscription, is owned by nobody, and its free trial converts to billed on approximately 2026-08-15

- **Raised:** 2026-07-21 (code review of the ADR-057 batch, Finding 3; live-verified by architect)
- **Section:** 6 (Defender for Cloud) / 7 (FinOps); relates to ADR-040, ADR-057 decision 5, OQ-050
- **Blocking:** No. Nothing in the rebuild touches it and nothing fails because of it. It is unowned
  estate cost with a date on it, which is exactly the class of item that should not live only in a
  review transcript.
- **Priority:** Medium, and it becomes Low or moot the moment somebody rules on it

**Question:**
A live sweep of the security subscription found THREE Defender plans at `Standard` that are not in
`platform/security`'s Terraform and are correctly not in the teardown's `DEFENDER_PLANS_TO_FREE`
allow-list: `AI`, `Discovery` and `FoundationalCspm`. Two of them are not a cost question at all.
`Discovery` and `FoundationalCspm` both report `freeTrialRemainingTime = PT0S` - they are the
always-on foundational plans that report as Standard and are free permanently. **`AI` is different.**
It reports `pricingTier = Standard`, `enablementTime = 2026-07-16`, and
`freeTrialRemainingTime = P24DT12H40M` measured from 2026-07-21, i.e. a 30-day free trial that started
when it was armed and **expires around 2026-08-15**. Nobody enabled it deliberately, nothing in the
repo manages it, and no wave references it. Disable it before the trial ends, or accept it?

**Date arithmetic, stated explicitly because it is easy to get wrong:** `freeTrialRemainingTime` is
remaining time as of the moment of the query, NOT from the enablement date. Counting 24 days from the
2026-07-16 enablement gives 2026-08-09 and is wrong; counting 24 days 12 hours from the 2026-07-21
query gives approximately 2026-08-15, which also reconciles with a 30-day trial from 2026-07-16.
Re-derive from a fresh query rather than from this note if the decision is made close to the date.

**Expected financial exposure is small but is NOT the point.** Defender for AI bills per protected AI
resource IN THAT SUBSCRIPTION. The security subscription has no AI resources today, and none is
designed for it - the estate's AI platform (wave B6, ADR-051) lands in the landingzones subscription
via `bank-data-p1`, not here. So the likely bill at conversion is at or near zero. The real defect is
that an unmanaged, unowned, Standard-tier security plan with a billing cliff exists in the estate and
would drift further every rebuild cycle.

**Options being considered:**
- A (RECOMMENDED): disable it before the conversion date with a one-line
  `az security pricing create -n AI --tier Free --subscription <security-sub>`, and do NOT add it to
  any allow-list or to Terraform. Rationale: the estate does not use it, ADR-040 already established
  that this estate only arms plans it deliberately configures, and leaving an unmanaged Standard plan
  running conflicts with that. Cheapest, reversible today (`AI` carries no `deprecated` flag, so it
  can be re-armed if a later wave wants it - unlike the five blocked plans).
- B: adopt it into `platform/security` as a managed plan, which means adding it to
  `local.defender_extended_plans` AND to `DEFENDER_PLANS_TO_FREE` so teardown keeps covering it.
  Only worth it if a future wave actually puts AI resources in the security subscription, which no
  current design does.
- C: accept it and let it convert. Defensible only because the expected charge is near zero, but it
  leaves an unowned Standard plan drifting in the estate and re-raises this same question every cycle.

**Recommended default:** A, actioned before 2026-08-15. It is a single command and it does not touch
the rebuild, so it can be done at any convenient point and is NOT a gate on B0a.

**LIVE CONFIRMATION 2026-08-02 (pre-clearance refresh #5, PC-1AI).** The estimate is now a measured
date. Read from `az security pricing show -n AI --subscription sub-security-poc-01`:

| Field | Value |
|---|---|
| `pricingTier` | `Standard` |
| `enablementTime` | `2026-07-16T04:40:39Z` |
| `freeTrialRemainingTime` | **`12 days, 5:54:00`** |

**So the conversion date is on or about 2026-08-14, one day earlier than the "approximately 2026-08-15"
this entry estimated, and it falls INSIDE the rebuild window.** Nothing else about the entry changes:
the plan is still unmanaged by Terraform, still in no root's state, and still owned by nobody, and
option A is still a single reversible command.

**Two further non-estate plans were found reading `Standard` in the same query and are NOT covered by
this entry:** `Discovery` and `FoundationalCspm`. Neither is in `local.defender_extended_plans` nor in
the foundational set in `main.tf`. Who enabled them and whether either bills was **not** determined -
named here rather than implied, and it should be resolved in the same pass that dispositions the AI
plan.

### OQ-051: The ADR-041 temporary tenant-root grants are five days past their time-box and have no revocation owner - who revokes, when, and what replaces them

- **Raised:** 2026-07-21 (B0a pre-clearance refresh, architect; PC-6R(c))
- **Section:** 10 (Pipeline & Tooling) / identity; extends OQ-008 and OQ-041, relates to ADR-021
- **Blocking:** No for the rebuild (both grants are REQUIRED for it and must stay). Yes for closing
  out ADR-041, which described them as time-boxed.
- **Priority:** Medium

**Question:**
ADR-041 created two grants on the CI service principal as an explicit BRIDGE for the B0a redeploy:
User Access Administrator at Tenant Root Group and Cost Management Contributor at Tenant Root Group.
Both were created 2026-07-16 and both are still live on 2026-07-21, verified per scope. They were
never revoked after the 2026-07-16 rebuild went green, and nothing in any workflow, runbook or
checklist owns their removal. What is the durable answer: revoke after every rebuild and re-grant
each time, replace with narrower standing rows, or accept them as permanent?

**Why it matters now:** LESSON 57 says elevated grants stay attached THROUGH the work they enable and
are revoked strictly after a verified-clean destroy. The estate is about to be rebuilt, so revoking
today would break the rebuild. But "we keep forgetting" is not a policy, and an unrevoked tenant-root
User Access Administrator on a CI principal is the single widest standing privilege in this estate.
The ADR-058 QA checklist now asserts these grants are PRESENT after teardown (item 14), which makes
their presence deliberate rather than accidental, but does not answer when they go away.

**Options being considered:**
- A (RECOMMENDED): keep both for the duration of the rebuild campaign, then revoke as an explicit,
  owned step in the post-campaign runbook, and codify the Cost Management Contributor need as a
  narrower standing bootstrap row at the Globaris root MG (the OQ-041 recommendation) so only the UAA
  grant is ever temporary. Cost: one durable bootstrap row, one revocation step with a named owner.
- B: revoke both after every green B0a and re-grant by hand before every rebuild. Least standing
  privilege, but it is manual work on the critical path of every cycle and it is exactly the step that
  has already been forgotten once.
- C: accept both as permanent standing grants and close ADR-041's time-box language. Honest about
  reality, but it moves directly against OQ-008 and ADR-021, which exist to REDUCE this principal's
  footprint.

**Recommended default:** A.

### OQ-050: Teardown now writes Defender pricing plans to Free - how do we bound the risk that a plan disarmed at teardown can never be re-armed?

- **Raised:** 2026-07-21 (teardown subscription-scope ruling, architect; ADR-057 decision 5)
- **Section:** 10 (Pipeline & Tooling) / teardown; 6 (Defender for Cloud); relates to ADR-040, LESSON 41
- **Blocking:** No - ADR-057 ships with the conservative allow-list, which is safe for all 8 plans as
  of today's live check. This records the residual risk and asks for a policy on it.
- **Priority:** Medium

**Question:**
ADR-057 makes teardown reset the 8 estate-configured Defender for Cloud plans to `Free`, because the
azurerm provider refuses to create a pricing resource whose live tier is not Free. Setting a plan to
Free is trivial. Re-arming it is NOT guaranteed: Microsoft blocks NEW Standard enablement of
deprecated plans, and five plans in this very subscription are already in that state
(KubernetesService, ContainerRegistry, Dns are API-flagged deprecated; KeyVaults and Arm were blocked
on 2026-07-05 and are the reason ADR-040 removed them from config). If Microsoft deprecates one of the
8 in the window between a teardown and the next rebuild, teardown will have permanently disarmed a
control we cannot get back. How should that risk be bounded?

**Options being considered:**
- A (RECOMMENDED, shipped as the interim): the fixed allow-list in `teardown-common.sh`
  (`DEFENDER_PLANS_TO_FREE`), which mirrors `platform/security` exactly and can never touch a plan the
  estate does not configure, plus a mandatory lifecycle re-check of those 8 plans in every
  pre-clearance that precedes a rebuild (the deprecation audit already exists as step 3d). Cheap, no
  code beyond what ADR-057 specifies, and the pre-clearance is where a deprecation would surface
  anyway.
- B: stop resetting pricing at teardown entirely, and instead adopt the live plans on the deploy side
  with config-driven `import` blocks. Nothing is ever disarmed, so nothing can become unre-armable.
  Cost: 8 import blocks plus a mandatory removal commit every cycle (LESSON 52), on the critical path
  of every rebuild, which is exactly the churn ADR-057 chose to avoid.
- C: reset to Free only the plans whose live API response carries no `deprecated` flag, evaluated at
  teardown time. Self-adjusting and it cannot disarm an already-deprecated plan. But it introduces a
  live-state-dependent branch into teardown, and it does not help at all for the case that actually
  matters (a plan that is current at teardown and deprecated by the next rebuild).

**Recommended default:** A, with B reconsidered if any of the 8 is ever announced for deprecation.

### OQ-049: Should `azurerm_resource_provider_registration` stop being managed inside `platform/management` (LESSON 54)?

- **Raised:** 2026-07-21 (B0a pre-clearance refresh, architect; PC-6R(b))
- **Section:** 10 (Pipeline & Tooling) / 7 (FinOps); relates to LESSON 54 and ADR-027
- **Blocking:** No - ADR-057 sub-step 6c makes teardown unregister it, which closes the loop for now.
  This asks whether the loop should exist at all.
- **Priority:** Medium

**Question:**
`platform/management` manages `azurerm_resource_provider_registration.cost_management_exports`
(`Microsoft.CostManagementExports`), required so the ADR-027 cost exports can write to a storage
account in the management subscription. The provider resource hard-fails create when the namespace is
already `Registered` (verified in azurerm v4.71.0 source: it returns requires-import), and destroy
UNREGISTERS the namespace. That makes registration state a per-cycle liability: if teardown does not
unregister, the next apply fails; if it does, the estate churns a subscription-wide setting on every
build. LESSON 54 already says do not manage RP registration in the same root as the resources that
need it. Should this resource be removed from the root?

**Options being considered:**
- A (RECOMMENDED): remove the resource from `platform/management`, register the namespace once,
  out-of-band, as permanent subscription state (documented in the bootstrap runbook), and delete
  ADR-057 sub-step 6c. Registration becomes a one-time environment fact rather than a per-cycle
  toggle. Matches LESSON 54 exactly. Cost: one code change plus reviewer, one documented manual
  prerequisite that only ever runs once per subscription, and a note that a brand-new subscription
  needs it before the first management apply.
- B: keep it in-root and rely on ADR-057 sub-step 6c to unregister at teardown. Zero code change,
  fully CI/CD, but it keeps a subscription-wide setting coupled to a per-root lifecycle and adds a
  permanent maintenance item to the teardown contract.
- C: keep it in-root but add a permanent config-driven `import` block so an already-registered
  namespace is adopted instead of failing. Rejected on sight: LESSON 52 says import blocks are
  one-shot and must be removed once they land, so a permanent one is a standing trap.

**Recommended default:** A, scheduled after the rebuild is green (it is a deploy-root change and
should not be made on the critical path of a rebuild that is already waiting on a teardown re-run).

### OQ-048: Teardown SP cannot verify MG deletion via a per-scope read - list-snapshot oracle (canonical) vs a minimal tenant-root Management Group Reader grant

- **Raised:** 2026-07-20 (teardown consolidation pass, architect; structural root of ADR-054 defect 3)
- **Section:** 10 (Pipeline & Tooling) / teardown; relates to OQ-008 + ADR-021 (SP scope-down)
- **Blocking:** No - the list-snapshot oracle is implemented and proven green E2E (attempt 5, run
  29765892057). This item RECORDS the design decision so the oracle is understood as deliberate, not
  accidental.
- **Priority:** Low

**Question:**
The teardown identity (the scoped OIDC SP) can DELETE the globaris MG tree but cannot then VERIFY the
deletion with a per-scope read: its MG-read grants were scoped to the globaris subtree and are deleted
WITH it, so `az account management-group show <deleted-mg>` (and a per-scope policy read) returns
HTTP-403 `AuthorizationFailed` for this principal, not a clean 404. Should the canonical design stay
the `az account management-group list` snapshot oracle, or should the SP get a minimal tenant-root
read role so deleted-MG reads return a clean 404?

**Options being considered:**
- A (RECOMMENDED, CHOSEN): keep the ONE-TIME `az account management-group list` snapshot oracle
  (`mg_snapshot_load` / `mg_in_snapshot`, teardown-common.sh); existence is name-membership in the
  snapshot, auth-fail-loud on the list call. Zero RBAC change, already proven green E2E, no bootstrap
  re-apply. Relies only on the SP's SURVIVING Management Group Contributor at the tenant root (carries
  `managementGroups/read`, never deleted), so the one list call is always available.
- B (REJECTED): grant the SP a minimal Management Group Reader (or equivalent read) at the tenant root
  so a deleted-MG `show` returns a clean 404 and per-scope existence probes "just work". Simpler call
  sites, but it WIDENS the SP's standing grant, needs a bootstrap re-apply (bootstrap/identity.tf), and
  cuts against OQ-008 / ADR-021, which are trying to REDUCE this SP's footprint.

**RESOLVED 2026-07-20 (architect, ADR-054 consolidated point 11): Option A - the list-snapshot oracle
is the canonical design.** It needs no RBAC change and no bootstrap change, is proven, and moves in the
SAME direction as OQ-008 (less standing privilege), whereas B adds a standing grant purely to fix a
diagnostic read. The per-MG `show` oracle is retired (it was principal-dependent and caused defect 3).
The design depends only on the SP's surviving tenant-root MG Contributor grant, which OQ-008 keeps, so
the two are compatible.

### OQ-047: B9 CMK scope - which data stores get customer-managed keys, and is the cost/risk worth it?

- **Raised:** 2026-07-19 (B9 design engagement, architect - ADR-053, docs/b9-security-design.md
  section 4)
- **Section:** Banking wave B9 (security/compliance)
- **Blocking:** Only the CMK sub-scope of B9. The rest of B9 (PCI/SOC compliance, b11 Audit, b13
  Audit) ships regardless.
- **Priority:** Medium (answer before the B9 apply if CMK is wanted in this wave; else defer)

**Question:**
The estate has ZERO customer-managed keys / disk encryption sets today (live-verified). The
founding design put "extend the CMK pattern to the new data stores" in B9. CMK is net-new
infrastructure - a purge-protected Key Vault + RSA keys + user-assigned identities with Key Vault
Crypto roles + per-resource CMK config - with a real availability-coupling risk: a deleted or
inaccessible key makes the encrypted data inaccessible (purge protection + soft delete + key backup
are mandatory). Which data stores get CMK?

**Options being considered (per data-store granularity):**
- A (recommended for a literal banking encryption-at-rest claim): CMK on the lakehouse ADLS
  (`stlake`) + Foundry + AI Search + Databricks managed-services/DBFS-root. One CMK KV + keys +
  identities. Cost ~$1-5/mo (KV + key ops) + operational key-management burden. Note: Databricks
  CMK is a workspace UPDATE (plan-scan for ForceNew - if it forces a workspace replace on the live
  QA-green workspace, that store drops to design-only).
- B (minimal): CMK on ADLS `stlake` only (the primary lakehouse); the rest documented-design.
- C (defer): CMK documented-design only; B9 ships without it; revisit at a later hardening pass.
  Zero cost, thinner encryption story. Platform-managed keys (already in effect) still encrypt at
  rest - CMK is about CUSTOMER control of the key, not about whether data is encrypted.

**Architect recommendation:** A if the production/banking posture claim requires customer-managed
keys across the data tier; B for a lighter footprint; C if the key-management operational burden is
not wanted at POC. All three keep the rest of B9 intact.

**RESOLVED 2026-07-19 (user): Option A - FULL data-tier CMK** across ADLS (`stlake`) + Foundry +
AI Search + Databricks (managed-services + managed-disk). Finalized implementation contract in
docs/b9-security-design.md section 3.1 (new dedicated network-hardened CMK Key Vault in
bank-data-p1, one RSA-3072 key per resource with rotation, per-resource identity/role model,
ordering, and the Databricks ForceNew watch). Recorded in ADR-053. Gated behind a separate
`enable_cmk` sub-flag so the key-loss-sensitive / ForceNew-carrying CMK build is independently
toggleable from the rest of B9.

### OQ-046: B-R production restoration - the consolidated fork list (one answer composes the end state)

- **Raised:** 2026-07-19 (ADR-049 / docs/b-restoration-design.md; architect)
- **Section:** Wave B-R (restoration, between B9 and B10)
- **Blocking:** Not the current build waves (B5 applying, B6..B9 proceed). Blocks only the B-R
  fork items; plain restores proceed regardless.
- **Priority:** Medium now, High by B9 (answer needed before B-R starts)

**Question:**
Your directive (ADR-049): the build ends at FULL production deployment with every deviation
reversed. The plain restores need no decision and will happen: VPN Gateway (~$8.7/day), DNS
Private Resolver (~$12/day), EH auto-inflate (~$0), dbstorage waiver early-drop, bootstrap
reconcile, flow-log waivers kept as documented platform constraints. TEN items are genuine forks.
Answer each with yes/no (or the noted option letter); costs are approximate list per day, to be
re-verified at the B-R pre-clearance. Current sprint run-rate is ~$112-125/day; all-yes (except
f9) lands around ~$270/day (~$8k/mo).

| Fork | Item | ~$/day delta | Recommendation |
|---|---|---|---|
| **f1** | DDoS Network Protection plan (the Section-3 POC deviation; biggest single line) | +$98 | YES if the production claim must be literal; documented-exception otherwise |
| **f2** | Bastion always-on vs the ADR-015 on-demand pattern | +$4.6 if always-on | KEEP ON-DEMAND (a legitimate production ops pattern, not a shortcut) |
| **f3** | Fabric F2 posture once OQ-045 resolves: always-active vs pause-schedule automation | +$8.6 active / ~$0 paused | PAUSE-SCHEDULE (production-legitimate Fabric cost practice) |
| **f4** | OQ-032 CreatedDate tag drift: keep accepting (documented) vs fix (policy surgery or estate-wide ignore_changes) | $0 either way | KEEP ACCEPTING - the fix buys cosmetics at real blast radius |
| **f5** | APIM Developer_1 -> Premium with zones (in-place stv2 SKU upgrade, isolated long-run) | +~$93/unit | YES for the production claim (SLA + zones live only in Premium); this is the second biggest line |
| **f6** | Service Bus geo-DR pair (base Premium+PE is ALREADY production shape) | +~$22 | NO at single-region scope; pulls in automatically if f9 = yes |
| **f7** | AKS user node pool + autoscaler bounds (quota now fits: 24-core cap, 6 used; non-DSv4 v4 family per the OQ-043 trail) | +~$7 | YES - cheap, and workloads-off-system-pool is a real production bar |
| **f8** | Databricks front+back-end Private Link, pna false (SEQUENCED after the VPN GW restore - humans need a private path to the UI first) | +~$0.7 + ops | YES for a banking posture claim; the P2S access path must be proven first |
| **f9** | Multi-region scale-out: second-region banking spokes (10.31/10.33), AKS second cluster, APIM multi-region, data geo-replication | roughly DOUBLES the workload tier | NO - keep as the B10-documented DR design (the ADR-022 split); your directive's example was a single-region platform component, so this is not silently assumed |
| **f10** | Tenant Security-Admin-gated features (UEBA, aad-diagnostics, dc-aad, dc-ti, MDE connector, firewall TI rule): grant the role to the deploying identity and flip the flags, vs remain documented-gated | ~$0 (small LAW ingestion) | GRANT + FLIP - this is the one class (d) item YOU can unblock, and a production security claim is thin without the TI/identity connectors |

**Also note (no decision needed):** SQL/App Service in corp spokes and v5 families stay honestly
unbuildable on this offer (ADR-031/032/043) unless tickets/offer change - flags remain the
re-enable; GHAS entitlement rides B8/OQ-040.

**RESOLVED 2026-07-19 (user: "take the recommendations"; implementation DEFERRED to wave B-R -
nothing changes now):** every fork adopts the architect recommendation. Recorded per item:
- **f1 DDoS: NO DEPLOY** (conditional collapsed by architect ruling under the delegation, ADR-050):
  ~$2,944/mo would be ~35 percent of the current run-rate for one control on an estate whose only
  public ingress is the online-p1 App Gateway WAF_v2; stays the PRODUCTION DESIGN TARGET with
  plan-attach mechanics documented and `enable_ddos_standard` as the one-flag re-enable; DDoS IP
  Protection (per-IP SKU) recorded as the cheaper targeted alternative if a literal claim is ever
  required. Consistent with the estate's treatment since Section 3.
- **f2:** Bastion stays ON-DEMAND (ADR-015 pattern). **f3:** Fabric pause-schedule posture.
- **f4:** OQ-032 CreatedDate acceptance KEPT (documented).
- **f5:** APIM Developer -> **Premium with zones: YES** at B-R (+~$93/day; in-place stv2 upgrade,
  isolated long-run). **f6:** SB geo-DR: NO (single-region scope; base already production shape).
- **f7:** AKS user node pool + autoscaler bounds: **YES** at B-R (+~$7/day; non-DSv4 v4 family
  per the OQ-043 trail, live-verified at B-R pre-clearance).
- **f8:** Databricks front+back-end Private Link: **YES**, sequenced strictly AFTER the VPN GW
  restore (private access path first).
- **f9:** multi-region scale-out: **NO** - remains the B10-documented DR design (ADR-022 split).
- **f10:** tenant Security Administrator grant: **YES - USER ACTION, ready-to-run when B-R
  needs it:** in Entra ID > Roles and administrators > **Security Administrator** > Add
  assignment, assign to the CI deploy service principal (the GitHub-OIDC enterprise application
  used by deploy.yml - grab its name/object ID from the portal; not written here per the
  no-personal-values rule). Directory-scope, Active (or PIM-eligible + activated for the B-R
  window). After the grant lands, B-R flips enable_ueba / enable_aad_diagnostics /
  enable_aad_connector / enable_ti_connector / enable_mde_connector / enable_firewall_ti_rule
  per ADR-033/034 with their standing plan bars.
Register updated (docs/b-restoration-design.md section 7); decision record ADR-050. - who administers the F2 capacity, supplied how?

- **Raised:** 2026-07-18 (B5 design engagement, architect - see ADR-048,
  docs/b5-data-platform-design.md section 7.2)
- **Section:** Banking wave B5 (data platform, Fabric slice only)
- **Blocking:** Only the `enable_fabric_capacity` flag flip. The rest of B5 (Databricks + ADLS +
  firewall RCG) is NOT blocked and ships with the Fabric flag false.
- **Priority:** Medium (cheap to answer; the wave is shippable without it)

**Question:**
`azurerm_fabric_capacity` takes `administration_members` - the identities allowed to administer
the capacity in the Fabric portal (assign workspaces, manage settings). The provider marks it
optional, but a capacity with no admin is unmanageable from the Fabric side, and whether ARM even
accepts an empty admin list is UNVERIFIED - so the design keeps `enable_fabric_capacity = false`
until a principal is supplied. Format rules (verified): an Entra USER is given as a UPN; a
service principal as its OBJECT ID. Per the no-personal-values rule, the value must NOT be
committed (not in poc.tfvars); the design feeds it via `TF_VAR_fabric_admin_members` from a
GitHub Actions repo variable. Note pause/resume does NOT need capacity admin - it is an ARM
action covered by Azure RBAC, so the suspend runbook works either way.

**Options being considered:**
- A (recommended): your own account as UPN - grab it from the portal (Entra ID > Users, or it is
  simply your sign-in email) and set the GitHub Actions variable `TF_VAR_FABRIC_ADMIN_MEMBERS`
  (JSON list form, exact wiring per the implementer). One-line setup; you can then see and manage
  the capacity in the Fabric portal for the demo.
- B: the CI service principal's OBJECT ID (portal: Entra ID > Enterprise applications > the CI
  SP > Object ID - the ask-user-for-GUIDs rule applies). Keeps humans out, but then NO human can
  administer the capacity in the Fabric portal, which undercuts the BI demo face.
- C: both A and B (list takes multiple members).

**Architect note:** A or C recommended; the demo value of Fabric is a human opening the portal.
Until resolved, B5 applies run with `enable_fabric_capacity = false` - zero Fabric cost, zero
blocked scope elsewhere. - does the ADR-045 sprint frame flip OQ-039's Standard-plus-Waiver to Premium-plus-PE?

- **Raised:** 2026-07-18 (B3 design engagement, architect - see docs/b3-messaging-platform-design.md,
  ADR-045)
- **Section:** Banking wave B3 (messaging/eventing)
- **Blocking:** YES - blocks the B3 Service Bus implementation shape (exemption unit vs private
  endpoint are different code)
- **Priority:** High

**Question:**
OQ-039 resolved Service Bus at STANDARD behind an RG-scoped Waiver exemption (the corp deny member
`serviceBusDisablePublicNetworkAccess` defaults to Deny - member dump re-verified live 2026-07-18),
with Premium+PE recorded as the production design target. That ruling was made under a monthly-run-rate
frame BEFORE two things changed: (1) ADR-045 reframed the estate as a time-boxed sprint torn down at
end of week - Premium's cost is now days, not months; (2) the estate posture hardened (firewalls live,
B2 shipped PE-only ACR and a private cluster with zero exemptions). Event Hubs is unaffected either way
(Standard supports PEs; its deny member is satisfied by design). Does Service Bus ship Standard+Waiver
as resolved, or Premium+PE for the sprint window?

**Options being considered:**
- A (architect recommendation under ADR-045): **Premium 1 MU + private endpoint,
  public_network_access_enabled false.** ~$0.93/hr = ~$22.4/day, roughly $110-160 through an
  end-of-week teardown (vs ~$680/mo that made OQ-039 reject it). Buys: zero policy exemptions in the
  root (no Waiver unit, no 300s propagation sleep, no LESSON 35 collision surface), the SAME shape as
  the production design target (the POC then demonstrates the real posture), PE-only symmetry with
  every other B2/B3 data-plane service, and simpler QA (compliant-by-design, like AKS/ACR). Cost is
  the only downside.
- B (the standing OQ-039 resolution): **Standard + RG-scoped Waiver exemption** on the
  serviceBusDisablePublicNetworkAccess member (ADR-028/LESSON 35 unit: exemption + 300s sleep +
  depends_on). ~$0.014/hr (~$10/mo base) - about $120 cheaper over the sprint. Costs: a public
  data-plane endpoint in a banking POC (Standard cannot attach PEs and cannot meaningfully disable
  public access; IP firewall rules are Premium-only, so the endpoint is open at the network layer with
  AAD/SAS auth only), one more exemption unit to build/verify/tear down, and a documented deviation in
  the fidelity map.
- C: gate Service Bus off (design-only, default-false flag stays false); Event Hubs alone carries the
  B3 messaging story. Zero cost, thinnest story.

**Architect note:** if B is chosen it remains safe (the exemption pattern is proven twice); the
recommendation is A purely because ADR-045 collapsed the cost argument that drove OQ-039, and
sprint-window Premium is the single cheapest way this estate ever demonstrates the production Service
Bus posture.

**RESOLVED 2026-07-18 (user):** Option **A** - Service Bus **Premium 1 MU + private endpoint,
public_network_access_enabled false, AAD-only** (~$22.4/day accepted under the ADR-045 sprint frame).
The OQ-039 Standard+Waiver posture is RETIRED for Service Bus in this build (no third exemption unit
is ever built); Premium+PE is now both the POC deployment AND the production design shape. Recorded
in ADR-046; design doc section 4 updated to Shape A only. Event Hubs unaffected (Standard+PE as
designed).

### OQ-043: The landingzones sub is vCPU-full after B2 - quota increase, new banking sub, or B5 design-only?

- **Raised:** 2026-07-18 (B2 design engagement, architect - see ADR-043, docs/b2-aks-platform-design.md)
- **Section:** Banking waves B2/B5 (bites at B5; B2 itself is NOT blocked)
- **Blocking:** Not B2. Blocks wave B5 (Databricks compute) and any future AKS user pool / scale-out.
- **Priority:** High (answer needed before B5 planning; cheap to act on now)

**Question:**
Live quota check 2026-07-18 in sub-landingzones-poc-01 (eastus2): Total Regional vCPUs limit is **10**,
every v5 VM family is capped at **0** (the ADR-031/032 offer-cap class), DSv4-class families carry 10.
B2 as designed consumes 6 of 10 (8 of 10 during node upgrades). The remainder (4 vCPUs) cannot start
even a minimal Databricks cluster (driver + 1 worker is typically 8 vCPUs), so wave B5 is dead in this
sub unless something changes. The OQ-035 resolution pre-recorded "new banking sub" as the fallback for
exactly this. What is the disposition?

**Options being considered:**
- A (recommended): file the quota increase NOW (Total Regional vCPUs 10 -> 20+ and DSv4/DASv4 family
  10 -> 20 in eastus2) - free, async, does not block B2; treat refusal as the trigger for Option B.
  This offer has refused capacity before (SQL, App Service), so refusal is a real possibility, but a
  vCPU increase on an already-nonzero family is the most commonly granted class.
- B: create the new banking subscription under the Corp MG for B5+ (the OQ-035 fallback): clean quota
  slate, cleaner cost separation; costs plumbing (sub creation, MG association, CI SP RBAC, budgets,
  CI wiring) - roughly a half-wave of work.
- C: B5 becomes design-only (Databricks documented, not deployed) - zero cost, but a second net-new
  platform slips from the POC and the banking story thins.

**Recommended default:** A now, B on refusal. Record the outcome in the B5 pre-clearance.

**RESOLVED 2026-07-18 (user):** Option A - file the quota increase NOW (Total Regional vCPUs 10 -> 20+
and DSv4/DASv4 family 10 -> 20, eastus2), az-side filing attempted immediately with portal filing as the
fallback. Option B (new banking sub under Corp MG) stays on record as the committed fallback on refusal.
Does not block B2; outcome recorded in the B5 pre-clearance. Note the ADR-044 synergy: stopping the AKS
cluster at the EOD re-gate releases its 6 vCPUs while the ticket is pending.

### OQ-042: B2 AKS egress - bring the firewalls back (userDefinedRouting) or ship cheap egress (loadBalancer / NAT gateway)?

- **Raised:** 2026-07-18 (B2 design engagement, architect - see ADR-042 re-enable trigger, ADR-043,
  docs/b2-aks-platform-design.md section 6)
- **Section:** Banking wave B2 (Kubernetes platform)
- **Blocking:** YES - blocks the B2 implementation spec hand-off (outbound_type and the route-table
  wiring differ per option)
- **Priority:** High

**Question:**
ADR-042 gated both Azure Firewalls off and recorded B2 AKS userDefinedRouting as a re-enable trigger.
The live bank-app-p1 spoke routes 0.0.0.0/0 to 10.0.0.4 (a firewall that does not exist); AKS nodes
cannot bootstrap through that blackhole, so B2 MUST either bring the firewall back or scope the
blackhole route away from snet-aks-nodes. Verified fact that shapes the options: a 0.0.0.0/0 UDR to a
VirtualAppliance overrides BOTH load-balancer egress and an attached NAT gateway, so options (b) and
(c) each require removing the route-table association from the aks-nodes subnet (the apim and
private-endpoints subnets keep the blackhole UDR). Which egress does B2 ship?

**Options being considered:**
- a: `outboundType = userDefinedRouting` + `enable_firewall = true`. Banking-grade: all node/pod egress
  inspected by Firewall Premium (IDPS/TLS). Cost ~**$2,555/mo** - the ADR-042 flag deliberately brings
  BOTH hubs' firewalls back as a pair (per-hub flags were explicitly rejected there). Extra work: AKS
  egress rule set in the firewall policy; firewall must be live BEFORE cluster create. This is the
  production target posture.
- a': single-hub variant of (a), ~**$1,280/mo**. NOT currently buildable as designed: it requires
  superseding ADR-042's one-flag-both-hubs ruling AND verifying in the module source that asymmetric
  per-hub `enabled_resources.firewall` works (UNVERIFIED; the hub mesh route generation is the risk).
  Pick only if (a)'s posture is wanted at half cost and the verification passes.
- b (recommended POC default): `outboundType = loadBalancer`, remove the route table from the aks-nodes
  subnet. ~**$0/mo** extra (AKS-managed egress PIP ~$4). Egress uninspected - documented POC deviation
  (same class as the absent DDoS plan). Clean in-place migration path to (a) when the firewalls return
  (route re-association + outbound_type change, supported without cluster rebuild).
- c: `outboundType = userAssignedNATGateway` + avm-res-network-natgateway 0.3.2 on snet-aks-nodes.
  ~**$37/mo** + $0.045/GB. Buys a deterministic egress IP and SNAT scale over (b), still zero
  inspection. Same route-table change as (b). Middle option; the POC's near-zero egress volume makes
  its benefits mostly cosmetic.

**Architect recommendation (ADR-022 POC-vs-design split, consistent with the user's ADR-042 deferral):**
Option **b** at POC; option **a** documented as the production design target; the ADR-042 firewall
re-enable trigger then moves to B4 (APIM forced tunneling) or a deliberate security-demo milestone,
whichever the user schedules first. If demonstrating inspected egress IS the point of this wave for the
portfolio story, pick (a) and accept the ~$2.55k/mo while it runs.

**RESOLVED 2026-07-18 (user):** Option **a** with a TIME-BOX - `outboundType = userDefinedRouting` and
`enable_firewall = true`, cost accepted at the HOURLY rate (~$3.5/hr for the pair, both hubs; the
ADR-042 one-flag-both-hubs design stands, no supersede), with the stated intent to stand up the entire
banking landing zone and RE-GATE (or tear down) the firewalls by end of day. The inspected-egress
posture is the point; the time-box is the cost control. Mechanics, firewall-rules delta, wave runbook,
and the two EOD disposition frames are recorded in ADR-044 and docs/b2-aks-platform-design.md section
6. The B1 spoke route wiring is untouched (no route-scoping change; the blackhole UDR simply goes live).

- **Raised:** 2026-07-12 (B0a redeploy pre-clearance, architect - see ADR-041)
- **Section:** 10a (bootstrap RBAC) / carries OQ-008 history
- **Blocking:** Not B0a (the ADR-041 temp tenant-root grant bridges it). Blocks the post-B0a cleanup
  step (when the temp grants are revoked) and, if unresolved, the eventual estate teardown (MG budget
  DELETE needs the same rights).
- **Priority:** Medium

**Question:**
The management root creates (and the teardown deletes) three consumption budgets at MG scope
(globaris / platform / landingzones), which need `Microsoft.Consumption/budgets/*` at MG scope. The
ADR-021 scoped role set never covered this - it worked only because the standing OQ-008 Owner @
globaris masked it, and that Owner died with the MG tree (and is never coming back, per ADR-041).
Where do these rights live permanently?

**Options being considered:**
- A (recommended default): add a bootstrap row - **Cost Management Contributor @ globaris MG** - to
  `bootstrap/identity.tf`, bound in the same post-B0a full bootstrap re-apply that rebinds rows 2/3/4.
  Least-privilege scope consistent with the ADR-021 matrix, survives for day-2 budget changes and the
  teardown (management destroys before management-groups, so the MG scope still exists). Small
  cloud-engineer/devsecops change + ADR-021 amendment note.
- B: keep the ADR-041 temp **Cost Management Contributor @ Tenant Root Group** standing until the final
  banking teardown, then revoke. Zero code change, but broader scope than needed and a
  must-remember-at-teardown liability.
- C: drop the MG-scope budgets from the management root (sub budgets remain). Zero RBAC need, but a
  FinOps posture regression and a silent deviation from the deployed Section 7 design.

### OQ-040: GitHub plan reality for the banking DevSecOps wave - CodeQL, secret scanning, and the production apply gate on a private Team-plan org (GHE named in requirements)

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B8)
- **Section:** Banking wave B8 (DevSecOps additions) / carries OQ-015 history
- **Blocking:** Blocks wave B8 only
- **Priority:** Medium

**Question:**
The banking requirements name GitHub Enterprise, CodeQL, Dependabot, secret scanning, and production
approvals. The org (`Globaris-Inc`) runs a Team plan on a PRIVATE repo. Dependabot is free everywhere. But:
(a) CodeQL and secret scanning on private repos need the paid code-scanning products - since Microsoft
unbundled GitHub Advanced Security (2025), Code Security and Secret Protection are purchasable standalone on
Team plans without GHE (pricing/availability for this org UNVERIFIED - verify at github.com billing before
B8); (b) OQ-015 is still open on the apply-run approval gate (environment required-reviewer PUTs returned
422 billing even on the Team plan; branch protection on main was the accepted interim). What is the B8
target state?

**Options being considered:**
- A: Buy the standalone GHAS products (Code Security + Secret Protection) on the Team plan, keep the repo
  private, and retry the environment required-reviewer wiring (it may work once billing entitlement is
  verified active - the OQ-015 422 looked like entitlement lag). Closest to the requirements at lowest cost.
- B: Flip the repo public: CodeQL, secret scanning, and environment protection rules are all free on public
  repos. Revisits the user's 2026-07-04 keep-private direction; the repo already had its secret sweep +
  history rewrite.
- C: Documented deviation: Dependabot + the free typed confirm=apply guard only; record CodeQL/secret
  scanning/GHE as production design targets. Weakest posture but zero cost.
- GHE itself: recommend recording as production-design-only in all options; no POC capability above requires
  it.

**RESOLVED 2026-07-12 (user, OQ walk):** User confirmed GHAS is ALREADY LICENSED on the org - no purchase
needed. Wave B8 therefore: enable Code Security (CodeQL) + Secret Protection on the private repo under the
existing entitlement, and RETRY the OQ-015 environment required-reviewer wiring (the 422 was an entitlement
question; GHAS presence suggests billing is live - one API call to confirm). GitHub Enterprise itself is
recorded as production-design-only. Verify at B8 pre-clearance that the entitlement covers this repo
(org-level GHAS seat/product assignment), then wire repo settings via gh api.

### OQ-039: Budget ceiling for the expanded estate + the Service Bus private-endpoint tier decision

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039)
- **Section:** Banking waves B0-B10 / FinOps
- **Blocking:** Yes - blocks wave B0 sizing and the B3 Service Bus tier
- **Priority:** High

**Question:**
The prior estate ran ~$3.6-4.8k/mo (COST.md, firewalls 55-65%). The net-new banking platforms add roughly
$0.9-1.4k/mo at POC scale - or $1.6-2.1k/mo if Service Bus Premium is chosen, because private endpoints on
Service Bus require the Premium tier ONLY (verified 2026-07-12; ~$680/mo per messaging unit approximate).
Estate total lands ~$4.5-6.2k/mo. Two decisions: (1) what monthly ceiling do we run to, and for how long a
window before the next teardown? (2) Service Bus at POC: Premium (compliant with Deny-Public-Network as-is),
Standard behind an RG-scoped policy-exemption waiver unit (ADR-028/LESSON 35 pattern, documented deviation),
or gated off entirely (default-false flag, design-only)?

**Options being considered:**
- A: Ceiling ~$5k/mo, Service Bus Standard + exemption (recommended default), fixed POC window then teardown.
- B: Ceiling ~$6.5k/mo, Service Bus Premium for a fully policy-clean posture.
- C: Trim wave 0 (subset redeploy per OQ-034) to buy headroom for the net-new platforms within ~$4.5k/mo.

**RESOLVED 2026-07-12 (user, OQ walk):** Option A - ~$5k/mo ceiling (alerts at the standard 50/75/90/100
thresholds when budgets are re-wired at B0), Service Bus STANDARD behind an RG-scoped policy-exemption
Waiver for the public-endpoint deny member (ADR-028/LESSON 35 pattern, documented deviation; Premium PE
posture recorded as the production design target). Full-scope B0 redeploy fits inside the ceiling; the
delayed-start choice in OQ-034 keeps the paid window short.

**Clarified same day (user):** the banking estate is BUILD-VERIFY-DESTROY, not a running environment -
built out wave by wave, QA-confirmed, then torn down (the ALZ POC arc). The ceiling is a guard rail for
the build window only; actual spend is the prorated window, not a monthly run rate.

### OQ-038: AI platform POC scope - which of Foundry / Document Intelligence / AI Search actually deploys

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B6)
- **Section:** Banking wave B6 (AI platform)
- **Blocking:** Blocks wave B6 only
- **Priority:** Medium

**Question:**
The requirements name virtual banking assistant, document intelligence, predictive analytics, and AI search.
The 2026-correct anchor is a Microsoft Foundry resource (renamed Azure AI Foundry; Microsoft.CognitiveServices
namespace) via avm-res-cognitiveservices-account 0.11.1, plus AI Search (avm-res-search-searchservice 0.3.0)
and a Document Intelligence account. All PE-only. Token/usage costs are small but the Search service is a
fixed ~$75/mo (Basic, UNVERIFIED exact) and each service adds PEs and build surface. What deploys at POC?

**Options being considered:**
- A: Foundry resource + one small chat-model deployment only; Search + Document Intelligence design-only.
  Cheapest credible "AI platform exists" slice.
- B: Foundry + AI Search (enables a real RAG assistant demo); Document Intelligence design-only. Recommended
  default - RAG is the portfolio-relevant pattern.
- C: All three at POC. Fullest story, most surface.

**RESOLVED 2026-07-12 (user, OQ walk):** Option B - Foundry resource + one small chat-model deployment +
AI Search, enabling the private RAG virtual-assistant demo. Document Intelligence stays design-only.

### OQ-037: Enterprise data platform anchor - Databricks + ADLS (+ optional Fabric) vs the Synapse named in the requirements

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B5)
- **Section:** Banking wave B5 (data platform)
- **Blocking:** Yes - blocks wave B5
- **Priority:** High

**Question:**
The requirements doc names Azure Synapse AND Azure Databricks. The LESSON 40-41 lifecycle audit (2026-07-12)
found: Synapse is supported with no announced EOL, but Microsoft's strategic net-new analytics platform is
Microsoft Fabric, official Synapse-to-Fabric migration tooling is shipping, targeted Synapse deprecations
have already landed (Data Explorer retired 2025-10, Synapse Link for Cosmos closed to new projects), and the
CAF cloud-scale-analytics Synapse guidance was deprecated for April 2026 deletion. Anchoring net-new 2026
work on Synapse is exactly the stale-service class this project got burned by. What anchors the data
platform?

**Options being considered:**
- A: Databricks (VNet-injected, avm-res-databricks-workspace 0.5.0) + ADLS Gen2 now; add a pausable Fabric
  F2 capacity (~$263/mo pay-go, native azurerm_fabric_capacity) for the BI/regulatory-reporting face.
  Recommended default; near-zero idle cost, current-generation, satisfies the requirements' intent.
- B: Databricks + ADLS only; Fabric design-only. Cheapest.
- C: Deploy Synapse as literally written (avm-res-synapse-workspace 0.1.0 exists) - NOT recommended; would
  need the lifecycle risk recorded as user-accepted in an ADR.

**RESOLVED 2026-07-12 (user, OQ walk):** Option A - Databricks (VNet-injected) + ADLS Gen2 now, plus a
pausable Fabric F2 capacity for the BI/regulatory-reporting face. The requirements' Synapse naming is
recorded as satisfied-by-successor (Fabric is Microsoft's strategic direction; LESSON 40-41 audit in the
design doc) - no Synapse workspace deploys.

### OQ-036: AKS topology and module choice for the Kubernetes platform

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B2)
- **Section:** Banking wave B2 (Kubernetes platform)
- **Blocking:** Blocks wave B2 only
- **Priority:** Medium

**Question:**
Kubernetes platform posture is fixed (private cluster, Azure CNI Overlay, Entra + Azure RBAC, workload
identity, userDefinedRouting via the hub firewall, ACR Premium with PE). Open: (1) module -
avm-res-containerservice-managedcluster 0.6.7 (current, composition-friendly; recommended default) vs
avm-ptn-aks-production 0.5.0 (older, opinionated pattern); (2) POC node shape - 2 or 3 nodes, which v5
family/size, Free vs Standard control-plane tier; (3) single cluster in bank-app-p1 only at POC (recommended;
the centralus DR cluster is design-only per the POC-vs-design split)?

**Options being considered:**
- A: Resource module, 2x small v5 nodes, Free tier, single region - recommended POC default.
- B: Resource module, 3 nodes across AZs, Standard tier - closer to design posture, ~$75/mo more + node cost.
- C: Pattern module (avm-ptn-aks-production) - less composition control in the spoke root.

**RESOLVED 2026-07-12 (user, OQ walk):** Option B - avm-res-containerservice-managedcluster (resource
module), 3 nodes spread across availability zones, Standard control-plane tier (SLA-backed). A deliberate
step toward the 99.99% design posture at ~$75/mo tier cost + the third node. Single region at POC; the
centralus DR cluster stays design-only per the POC-vs-design split.

### OQ-035: Subscription and MG placement for the banking spokes - existing landingzones sub (offer-cap history) vs a new subscription

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B1)
- **Section:** Banking wave B1 (network foundation)
- **Blocking:** Yes - blocks wave B1 (and everything after it)
- **Priority:** High

**Question:**
Default design places `bank-app-p1` and `bank-data-p1` under the Corp MG in the existing `landingzones`
subscription (eastus2). But that sub has a documented offer-cap history: Azure SQL ProvisioningDisabled in
eastus2 (ADR-031) and App Service dedicated compute quota 0 (ADR-032). AKS node pools and Databricks
clusters consume Microsoft.Compute vCPU quota - a different quota family from the Microsoft.Web cap that
bit App Service - but the same offer may carry low or zero Compute caps. VERIFICATION ITEM (owned by the B1
pre-clearance, do not skip): in the candidate sub/region check Total Regional vCPUs, the target VM family
quota (v5 general purpose), and any per-service provisioning restrictions (AKS, Databricks, Cognitive
Services, Search) BEFORE committing placement. Where do the banking spokes land?

**Options being considered:**
- A: Existing landingzones sub, pending the quota verification passing - zero new plumbing (recommended if
  quota checks out).
- B: One new banking subscription under Corp MG - clean quota slate and cleaner cost separation; needs sub
  creation, MG association, RBAC for the CI SP, budget wiring.
- C: Two new subs (app + data) - most enterprise-faithful, most plumbing; overkill at POC.

**RESOLVED 2026-07-12 (user, OQ walk):** Option A - banking spokes land in the existing `landingzones`
subscription under the Corp MG, CONDITIONAL on the mandatory B1 pre-clearance quota verification (Total
Regional vCPUs, v5 family quota, per-service provisioning restrictions for AKS/Databricks/Cognitive
Services/Search in eastus2). Fallback if quota fails: Option B (one new banking sub). The quota check is a
hard gate, not a formality - this sub's offer already zeroed Microsoft.Web and SQL (ADR-031/032).

### OQ-034: Wave B0 redeploy - timing and scope (full estate vs banking-needed subset)

- **Raised:** 2026-07-12 (banking platform founding design, architect - see ADR-039, wave B0)
- **Section:** Banking wave B0 (redeploy)
- **Blocking:** Yes - blocks the whole banking build
- **Priority:** High

**Question:**
The estate was torn down clean 2026-07-11 (state backend + OIDC kept). The banking build needs the platform
back. When do we redeploy, and how much? Full estate = the proven one-run path (~$3.6-4.8k/mo resumes) and
every banking dependency present. A subset (e.g. defer corp-a1/corp-a2 spokes, keep the online-p1 App
Gateway off until needed) trims cost but deviates from the proven deploy path and the DR story. Known
redeploy caveats regardless of scope (from the teardown session entry): state-SA firewall window handling,
`recover_soft_deleted_key_vaults` for the security KV (within its 90-day soft-delete window), Microsoft.AAD
RP re-registration timing for Entra DS, and a pre-clearance REFRESH for every root (policy/lifecycle may
have drifted since 2026-07-11; LESSON 41 re-audit applies if redeploy slips 2+ weeks past this design).

**Options being considered:**
- A: Full-estate redeploy, soon, exactly as torn down - proven path, full dependency set (recommended
  default).
- B: Platform-only first (management-groups, connectivity, management, identity, security), spokes deferred
  to their banking waves - saves the 3 POC spokes' cost; corp-a2 DR story goes dormant.
- C: Delay redeploy until OQ-035/036/037 are resolved so wave B1 can follow immediately and the paid window
  is shortest.

**RESOLVED 2026-07-12 (user, OQ walk):** Option C - redeploy waits for OQ-035/036/037 (all resolved the
same session), then B0 fires immediately before wave B1 so the paid window is shortest. Scope: FULL estate
(the proven one-run path) - confirmed affordable under the OQ-039 ~$5k/mo ceiling. B0 still requires the
pre-clearance REFRESH (state-SA firewall window, recover_soft_deleted_key_vaults for the security KV,
Microsoft.AAD RP re-registration timing; LESSON 41 re-audit if the start slips 2+ weeks past 2026-07-12).

**Clarified same day (user):** whole-estate lifecycle is BUILD-VERIFY-DESTROY - once all waves are built
and QA-confirmed, the estate is torn down (wave B10 ends in teardown, as the ALZ POC did). Nothing is
designed to persist; teardown.yml must stay current with every new banking root as waves add them.

**Amended same day (user): SPLIT B0 - cheap now, expensive late.** B0a deploys the firewall-independent
foundation roots now (management-groups, management, security - small idle cost). The expensive chain
(connectivity with its 2 Firewall Premiums + VPN GW, then identity, then the 3 spokes with the App
Gateway; none of these are flag-gated, all unconditional in their roots) is B0b, deferred until the first
compute wave (B2) is reviewer-approved and ready to apply, so firewall hours burn only during the active
build-verify window (~$86-120/day deferred). Deviation from the proven single-run order accepted; relative
root order preserved. Banking waves authored during the gap get static review + validate only - live plans
that data-source estate resources wait for B0b.

### OQ-033: Scope for the future Day-2 Operations and Monitoring capability (the repositioned Section 13) - platform-anchored, DINE-propagated, AMBA-based

- **Raised:** 2026-07-10 (Section 13 reposition, architect - see ADR-036)
- **Section:** 13 (repositioned) / Manage (CAF Day-2 Operations)
- **Blocking:** No - this is forward design guidance for a future build, not a current-window task. The estate
  is complete and QA-passed; teardown is imminent.
- **Priority:** Low (build later)

**Question:**
ADR-036 repositions Section 13 from a synthetic load / security-signal demo device to a Day-2 Operations and
Monitoring capability for CAF landing zones (the CAF "Manage" methodology). It is NOT a new standalone
layer/spoke. What is the bounded scope, and where does it land?

**Target shape (forward design guidance, NOT a build now):**
- **Platform-anchored:** extend the existing `platform/management` landing zone (already hosts the platform
  LAW and action group) with the monitoring baseline. Operational monitoring is a platform capability in
  canonical ALZ, not a workload tier - so no new root or spoke.
- **Policy-propagated:** deliver per-landing-zone monitoring via DeployIfNotExists (DINE) policy so every
  current and future spoke inherits it automatically (guardrail model), not hand-placed per spoke.
- **AMBA-based:** anchor to Azure Monitor Baseline Alerts (AMBA) for Azure Landing Zones - Microsoft's named,
  endorsed policy-driven alert library for ALZ (platform-level + resource-health alerts) - plus Service Health
  and Resource Health alerts wired to the existing platform action group. AMBA bounds the build and keeps it
  credible rather than a bespoke reinvention.
- **Scope discipline:** the bounded high-value slice is the AMBA baseline + Service/Resource Health alerts +
  action-group routing. Dashboards-for-everything is explicitly OUT of the bounded scope.
- **Optional recycling** within this model: the cost-pattern signals could feed a FinOps / cost-anomaly
  monitoring view; the app-traffic idea becomes real synthetic-transaction availability probes (Application
  Insights availability tests or the Azure Monitor equivalent) rather than red-team load.

**Open sub-decisions for build time (not now):**
- Which AMBA delivery form - the AMBA-for-ALZ policy initiatives/pattern assigned at the appropriate MG
  scopes, versus a lighter subset - given the estate size.
- The exact MG scope(s) for the DINE assignments (platform vs landingzones vs per-archetype) so alert
  coverage matches each spoke's resource types without over-alerting.
- The synthetic `.tf` stays a reusable idea source only; it is NOT repurposed as a monitoring spoke - the
  capability lands in `platform/management` + policy.

**RESOLVED 2026-07-11 (ADR-037):** The scope and placement are anchored. The O&M target architecture is
accepted (build deferred) in **ADR-037**, with the authoritative design in
`docs/operations-monitoring-design.md`: platform-anchored (extend `platform/management`), policy-propagated via
DeployIfNotExists at MG scope through `avm-ptn-alz`, AMBA-based, with an MVP-bounded Phase-1 slice
(diagnostic-settings-at-scale + AMBA baseline + Service/Resource Health + action-group extension + Sev0-4
taxonomy). It is NOT a new standalone layer/spoke, and the synthetic root is not the vehicle. The two
build-time sub-decisions above (AMBA delivery form; exact DINE MG scopes) are retained as deferred
implementation detail for the eventual Phase-1 build, not open blockers.

### OQ-032: Estate-wide perpetual tag drift - tag-governance Modify policy injects CreatedDate="1970-01-01" that Terraform strips every plan

- **Raised:** 2026-07-10 (Section 6 deploy QA)
- **Section:** 7 (FinOps tagging) / affects all roots
- **Blocking:** No (cosmetic; applies succeed)
- **Priority:** Low

**Question:**
Every root shows a perpetual, non-converging in-place diff: the `tag-governance-globaris` Modify policy (`platform/management/main.tf:52`) injects `CreatedDate = "1970-01-01"` (static placeholder - the Modify effect cannot compute a dynamic date) plus tag-inheritance to child resources; Terraform config does not declare `CreatedDate`, so every plan wants to strip it and the policy re-adds it. Confirmed on `platform/security` post-deploy (9 resources, plan run 29137108266: `0 to add, 9 to change, 0 to destroy`, all `- "CreatedDate" = "1970-01-01" -> null`). It is estate-wide, cosmetic, zero functional/posture impact, and by design of the tag policy.

**Options being considered:**
- A: Accept as known benign drift (POC, teardown imminent) - CHOSEN.
- B (post-POC): add `CreatedDate` to each root's declared tags so config == state, OR `ignore_changes = [tags["CreatedDate"]]` on affected resources/modules, OR make the Modify policy stop setting a placeholder date. All are estate-wide touches, not worth doing pre-teardown.

**RESOLVED 2026-07-10:** User accepted the drift ("I don't see them being a major issue, let's just accept the drift"). No code change; documented as a known cosmetic non-convergence. Deferred fix (option B) is a post-POC cleanup item.

### OQ-031: Synthetic telemetry lands in the platform LAW, but Sentinel is onboarded on the security LAW - will Section 6 analytics rules ever see the synthetic signals?

- **Raised:** 2026-07-10 (synthetic first-apply pre-clearance, architect)
- **Section:** 13 (Synthetic Workload) / 6 (Sentinel)
- **Blocking:** No - does not block the synthetic apply. Blocks the demo story "synthetic signal produces a
  Sentinel incident."
- **Priority:** Medium

**Question:**
`synthetic` sends all its diagnostic settings and Container Apps console logs to
`var.platform_law_workspace_id` = the **platform LAW** (`law-platform-...`, management sub, from
`platform/management`). But Microsoft Sentinel is onboarded on the **security LAW** (security sub, from
`platform/security`); the Section 6 analytics rules run against that workspace. Unless those rules
cross-workspace query the platform LAW, the synthetic StorageBlobLogs / KV AuditEvent / SignInLogs /
ContainerAppConsoleLogs will never trigger a Sentinel incident, so the red-team simulation produces no
detections in the demo.

**Options being considered:**
- A: Verify whether the Section 6 analytics rules already reference the platform LAW cross-workspace (some
  may). If they do, no change. If not, either
- B: point synthetic's diagnostic settings + Container Apps at the **security LAW** instead of the platform
  LAW (change the `platform_law_workspace_id` value fed to synthetic to the security LAW id, or add a
  dedicated `sentinel_law_id` variable), so the signals land where Sentinel reads; or
- C: add cross-workspace analytics rules on the security LAW that query the platform LAW (needs cross-sub
  Sentinel RBAC, the same class as OQ-027). Lowest-effort for the demo is B if the platform LAW is not
  already a Sentinel source.

### OQ-030: corp-a1 App Service (hard-referenced by synthetic) is gated off - re-enable, retarget, or gate the corp-a1 workload pieces?

- **Raised:** 2026-07-10 (synthetic first-apply pre-clearance, architect)
- **Section:** 13 (Synthetic Workload) / 9 (Landing Zones)
- **Blocking:** Yes - `data.azurerm_linux_web_app.corp_a1` (unconditional) fails at plan with a 404 because
  the App Service does not exist, killing the corp-a1 REST-API deploy and the k6 target.
- **Priority:** High

**Question:**
The corp-a1 (and corp-a2) App Service tier was gated off at deploy time (`enable_app_service = false`,
ADR-031/ADR-032; the landingzones-sub dedicated-compute offer-cap, quota support ticket still open).
`synthetic` hard-references `app-corp-a1-globaris-poc` via an unconditional data source in `corp_a1.tf` and
`k6.tf`, so it cannot plan. There is no flag to skip only the corp-a1 App-Service dependency.

**Options being considered:**
- A: Re-enable `enable_app_service = true` on corp-a1 - only viable if the dedicated App Service compute quota
  is now available in the LZ sub (it was not at deploy time). Highest fidelity to PROMPT.md 13.1/13.2, but may
  itself fail on quota and is the slowest path before an end-of-week teardown.
- B (recommended given teardown): retarget the 13.1 REST-API stub + the 13.2 k6 load at the LIVE online-p1
  workload (the App Gateway WAF_v2 public endpoint / the Static Web App, both deployed green) instead of the
  absent corp-a1 App Service. Cloud-engineer change to the data source + `TARGET_BASE_URL` + the deploy step.
- C: Add a flag (e.g. `enable_corp_a1_workload`) that gates the corp-a1 App-Service data source + REST-API
  deploy + k6 off, so the red-team + cost-pattern layers still ship without a live HTTP target. Loses the
  load-generation demo but unblocks everything else.

### OQ-029: Synthetic public-network storage accounts + decoy Key Vault collide with the corp-MG Deny-Public-Endpoints - Waiver or make private?

- **Raised:** 2026-07-10 (synthetic first-apply pre-clearance, architect)
- **Section:** 13 (Synthetic Workload) / 2 (policy)
- **Blocking:** Yes - `StorageDenyPaasPublicIP` (Deny, enforced at the corp MG) denies the three public
  synthetic storage accounts; the Key Vault member likely denies the decoy KV.
- **Priority:** High

**Question:**
The synthetic RGs land in the LZ sub under the `corp` MG, inheriting the same `Deny-Public-Endpoints`
initiative that blocked the spoke flow-log SAs (OQ-024). `synthetic` sets `public_network_access_enabled =
true` on `online_p1_synthetic`, `red_team_decoy`, `cost_pattern_hot`, and `corp_a1_synthetic` (needed for the
App-Service SAS fetch, the SWA-Function queue write, the MI blob read over its outbound IP, and the Container
Apps file-share mount), and on the decoy Key Vault (RBAC mode, `default_action = Allow`). The OQ-024 Waivers
are RG-scoped to `rg-<spoke>-network-*` and do NOT cover the `rg-synthetic-*` RGs.

**Options being considered:**
- A (recommended): RG-scoped `azurerm_resource_group_policy_exemption` Waivers on each synthetic RG that holds
  a public SA (and `rg-synthetic-red-team-*` for the KV member, if verification confirms it is Deny), scoped
  to only the offending initiative member - the ADR-028 / OQ-024 pattern, IaC-managed in the synthetic root
  (devsecops lane). Narrowest blast radius, keeps SQL/other members enforced.
- B: Disable public network access on the synthetic SAs + decoy KV. Rejected as a default - breaks the
  App-Service SAS deploy, the SWA-Function queue write, the storage-anomaly MI read path, the Container Apps
  file-share mount, and the whole point of the "public decoy" red-team resources.
- C: Downgrade the corp-assignment Storage/KeyVault member effect to Audit. Rejected - weakens governance for
  the entire corp archetype to admit POC resources.

### OQ-028: Migrate the deprecated KeyVaults + Arm Defender plans off the plan-enablement API (or keep until Microsoft enforces retirement)?

- **Raised:** 2026-07-10 (platform/security run-2 deprecation audit, architect)
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Blocking:** No - both plans are live-Standard and in Terraform state; the July 5 2026 block applies to new
  enablement only, so they do not block the next apply. Held as-is per ADR-034.
- **Priority:** Medium

**Question:**
The Defender for Cloud release notes (July 5, 2026) list five pricing plans blocked for new enablement:
KubernetesService, ContainerRegistry, KeyVaults, Dns, Arm. This root uses `KeyVaults` and `Arm` in
`defender_basic_plans` (main.tf). Both are already enabled (live-Standard, in state), so they keep working, but
they are on deprecated plans and any future re-PUT would be blocked. What is the migration path?

**Options being considered:**
- A (recommended): Hold as-is until teardown. The environment is scheduled for teardown by end of week, so the
  latent re-PUT risk is very likely moot. Code comments mark both plans deprecated; the pre-clearance plan-scan
  guard catches any drift (import, never re-create). Revisit only for a persistent environment.
- B: Remove KeyVaults and Arm from IaC and let Terraform set them to Free - clean config, but this DISABLES
  Defender for Key Vault and Resource Manager protection (a security-posture downgrade) and the "fixed pricing
  model" successor may leave them protected differently. Only sensible if the posture change is intended.
- C: Keep them enabled but move management out of `azurerm_security_center_subscription_pricing` to whatever the
  "fixed pricing model" successor path is once Microsoft documents the IaC-supported form - deferred until that
  path exists.

**RESOLVED 2026-07-12 (overtaken by events - ADR-040):** the 2026-07-11 full teardown reset every plan in the
security sub to Free, which destroyed Option A's premise (live-Standard + in state). Any redeploy re-PUT of
KeyVaults/Arm at Standard is now NEW enablement of blocked plans = deterministic 400. B0a pre-clearance
(docs/preclearance/b0a-redeploy.md, PC-1) removed both from `defender_basic_plans`; Defender CSPM
(CloudPosture) carries the posture surface. Effectively Option B, forced by the teardown rather than chosen;
the posture delta is recorded in ADR-040.

### OQ-027: Re-enable path for the firewall_threat_intel_hit cross-workspace analytics rule (fully-qualified reference + Sentinel cross-workspace RBAC)?

- **Raised:** 2026-07-10 (platform/security run-2, architect)
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Blocking:** No - the rule is pre-staged off behind `enable_firewall_ti_rule = false` (ADR-034); the other
  10 scheduled rules and the MDC incident rule stand.
- **Priority:** Low

**Question:**
firewall_threat_intel_hit is the only cross-workspace analytics rule: it reads hub Azure Firewall diagnostics
from the platform LAW (management subscription) while the rule is created against the security workspace
(security subscription). Its name-only `workspace('law-platform-<org>-<env>')` reference does not resolve
cross-subscription at rule-create time, so it failed twice and is now gated off. What does re-enabling it
require in a persistent environment?

**Options being considered:**
- A (recommended for a persistent env): Thread the platform LAW ARM resource ID into `platform/security` as a
  new input and rewrite the KQL to the fully-qualified `workspace('<platform-LAW-resource-id>')` form, AND
  grant the security Sentinel workspace's query identity Log Analytics Reader on the platform LAW so the rule
  resolves at create time and actually returns data at runtime. Then flip `enable_firewall_ti_rule = true`.
- B: Ingest the hub firewall diagnostics directly into the security workspace and make the rule
  single-workspace - rejected in design for the POC (duplicate ingestion cost) but simplest operationally.
- C: Leave gated off - acceptable for the POC; the firewall threat-intel signal is still visible in the
  platform workspace and Defender for Cloud.

### OQ-026: Corp-spoke workload tier (App Service + SQL) is fully offer-capped off - for a persistent environment, request quota / relocate, or redesign to serverless?

- **Raised:** 2026-07-10 (landing-zones deploy, architect)
- **Section:** 9 (Landing Zone Spokes)
- **Blocking:** No - both tiers are pre-staged off behind default-false flags (`enable_app_service`, ADR-032;
  `enable_sql`, ADR-031). The corp spokes stand as network landing zones without them.
- **Priority:** Low

**Question:**
The `landingzones` subscription is compute-restricted for dedicated / reserved resources: dedicated App
Service (`Microsoft.Web` VM quota = 0, offer cap, ADR-032) and Azure SQL (`ProvisioningDisabled`, ADR-031) are
both offer-capped, while serverless and PaaS-shared compute works. That gates the entire corp workload tier
(App Service + SQL) off. For a persistent (non-teardown) environment, which path do we take?

**Options being considered:**
- A (recommended): Defer. The environment is scheduled for teardown by end of week, so the workload tier is
  very likely moot. Revisit only if a persistent environment is stood up. The gates are default-false and
  cross-referenced from ADR-031 and ADR-032 so they are not forgotten.
- B: Request quota / move the landing zones to an unrestricted subscription, then flip `enable_app_service` and
  `enable_sql` to `true` - keeps the current dedicated-SKU design; cost is the quota-request latency (often
  slow or denied on restricted offer types) or a subscription migration.
- C: Redesign the workload tier to serverless (Flex Consumption Functions plus serverless SQL alternatives)
  that fits the offer - a real application redesign, only worth it for a durable environment.

Consolidates the workload-tier re-enable story. OQ-025 remains the SQL-specific re-enable trigger (allowed
region vs support exception, relocate vs wait); this OQ frames the broader App-Service-plus-SQL decision for a
persistent environment.

### OQ-025: Re-enable trigger for the corp-spoke SQL tier - which allowed region or support exception, and relocate vs wait?

- **Raised:** 2026-07-10 (landing-zones deploy, architect)
- **Section:** 9 (Landing Zone Spokes)
- **Blocking:** No - the SQL tier is pre-staged off behind `enable_sql = false` (ADR-031); the rest of the
  corp spoke stands without it.
- **Priority:** Low

**Question:**
ADR-031 gated the corp SQL tier off because Azure SQL provisioning is `ProvisioningDisabled` for the
`landingzones` subscription in eastus2 (corp-a1) and expected the same in centralus (corp-a2). When, if ever,
do we re-enable it, and how? The two levers are: an **allowed region/subscription** where SQL provisioning is
permitted, or an **Azure support-request exception** to lift the restriction on the current region. And if we
do re-enable, do we **relocate** SQL to an allowed region (accepting cross-region split from the rest of the
spoke) or **wait** for the restriction to lift in place?

**Options being considered:**
- A (recommended): Keep the tier off for this POC's lifetime. The environment is scheduled for teardown by
  end of week, so the SQL tier is very likely moot. Revisit only if a persistent (non-teardown) environment
  is stood up.
- B: Relocate SQL to an allowed region and flip `enable_sql = true` - accept cross-region fragmentation from
  the rest of the spoke. Only worth it for a durable environment.
- C: Raise a support-request exception and wait for it to lift in the current region, then flip
  `enable_sql = true` in place - slow; not aligned with the teardown timeline.

Tracked so the gate is not forgotten. Also carries the one-line .tf follow-up from ADR-031: the
`SqlServerDenyPaasPublicIP` comments in `landing-zones/corp-a1/policy_exemptions.tf:38-39` and
`corp-a2/policy_exemptions.tf:28` are stale while `enable_sql = false` (no SQL server exists) and should be
refreshed on the next edit of those files.

### OQ-024: corp-MG `Deny-Public-Endpoints` (+ `Deny-Subnet-Without-Nsg`) collide with the spoke public-PaaS resources - exempt, redesign, or downgrade?

- **Raised:** 2026-07-10 (landing-zones deploy pre-clearance, architect)
- **Section:** 9 (Landing Zone Spokes) / 2 (policy)
- **Blocking:** Yes - blocks the flow-log storage account create on all three spokes, and the App Service
  create on corp-a1/corp-a2, and the `snet-integration` subnet on corp-a1/corp-a2.
- **Priority:** High

**Question:**
The `landingzones` subscription sits under the **`corp`** MG (the `online` MG is empty), so all three spokes
inherit the corp archetype `Deny-Public-Endpoints` (Deny-PublicPaaSEndpoints) initiative, which is **enforced
with default effect = Deny**. Live-verified members that fire:
`StorageDenyPaasPublicIP` denies the flow-log storage accounts (public network access Enabled, all 3 spokes)
and `AsDenyPublicIP` denies the App Services (public inbound not disabled, corp-a1/a2). Separately,
`Deny-Subnet-Without-Nsg` (landingzones MG, Deny) denies corp `snet-integration` (no NSG). How do we admit
the required POC resources without gutting the corp archetype governance?

**Options being considered:**
- **A (recommended): RG-scoped Waiver policy exemptions + attach the NSG.** Per the ADR-028 precedent, add
  `azurerm_resource_group_policy_exemption` (Waiver) in each spoke root scoped to the specific RG for the
  specific member ref: `rg-<spoke>-network-*` for `StorageDenyPaasPublicIP`, `rg-<spoke>-workload-*` for
  `AsDenyPublicIP`. Keeps `SqlServerDenyPaasPublicIP` fully enforced (spoke SQL is already private). For the
  subnet, attach the existing spoke NSG to `snet-integration` in code (App Service delegated subnets support
  NSGs) - no exemption needed. Narrowest blast radius, auditable, IaC-managed.
- **B: Disable public network access on the flow-log SAs and App Services.** Rejected as default - can break
  NSG flow-log delivery (Network Watcher service reachability) and changes the App Service reachability model
  without validation.
- **C: Downgrade the initiative Storage/AppService effect params to `Audit`/`Disabled` at the corp
  assignment (platform/management-groups).** Rejected - weakens governance for the whole corp archetype to
  admit three POC resources.

Also parks a topology observation: an "online" archetype workload (`online-p1`) deploying under the `corp` MG
is a placement mismatch (the `online` MG has no subscription). Non-blocking; note for a later hierarchy
decision.

**RESOLVED 2026-07-10 (user decision: compliance-first, exemption fallback; committed 2581bd4):**
Split by whether the resource could be made genuinely compliant without breaking function:
- **`snet-integration` (corp-a1/a2) - made COMPLIANT.** Attached the existing spoke NSG to the subnet
  (App Service delegated subnets support NSGs), so `Deny-Subnet-Without-Nsg` is satisfied in code. No
  exemption used.
- **Flow-log storage accounts (all 3 spokes) and corp App Services (corp-a1/a2) - Waiver fallback.**
  These could not be made compliant without breaking function: Network Watcher is **not** a storage
  trusted-service, so a private flow-log SA breaks NSG flow-log delivery; and a private App Service
  needs net-new private-endpoint infrastructure. Fell back to RG-scoped `azurerm_resource_group_policy_exemption`
  Waivers (the ADR-028 pattern), each scoped to **only the single offending initiative member** -
  `StorageDenyPaasPublicIP` for the flow-log SAs, `AsDenyPublicIP` for the App Services.
  `SqlServerDenyPaasPublicIP` stays **enforced** and the spoke SQL server is independently private.

**Standing follow-up (RESOLVED-with-follow-up, do not delete):** the durable corp posture for the App
Service is a genuinely private App Service (`public_network_access = false` + a
`privatelink.azurewebsites.net` private endpoint), which would retire the `AsDenyPublicIP` Waiver.
Decision pending: build the private App Service infra or keep the Waiver. Likely moot given the planned
POC teardown by end of week.

### OQ-023: Root-cause the geo_block Conditional Access 1040 named-location reference failure (bounded diagnosis, then re-enable)

- **Raised:** 2026-07-10 (identity recovery apply run 29068343843, architect, ADR-030)
- **Section:** 5 (azuread Conditional Access) / 8 (Identity)
- **Blocking:** No - ADR-030 gates geo_block off by default (`enable_geo_block_ca_policy = false`); the
  identity root applies green with 7 of 8 report-only CA policies. geo_block enforces nothing, so nothing is
  blocked operationally.
- **Priority:** Medium

**Question:**
`azuread_conditional_access_policy.geo_block` has failed Graph `400 / 1040 "NamedLocation ... does not exist"`
roughly 5 times, most recently ~1 minute into run 29068343843 with a valid OIDC token (so NOT the ADR-029
token-expiry cause). The approved_countries named location exists and resolves on a live Graph GET (created
2026-07-08), yet the CA-policy create endpoint says it does not exist. What is the actual cause, and what is
the correct fix to re-enable geo_block?

**Options being considered:**
- A: **Reference-format bug** - the policy passes the named location by full resource path
  (`/identity/conditionalAccess/namedLocations/<id>`) where the CA store expects the bare object id (or vice
  versa). Test by inspecting the exact request body azuread emits and comparing to the Graph
  conditionalAccessPolicies schema. Likeliest and cheapest to confirm.
- B: **Graph CA-store consistency issue** distinct from ordinary propagation - the location is visible via the
  namedLocations endpoint but not yet consistent in the CA-policy store's view. Test by creating the same
  policy via raw Graph / portal and observing whether it also 1040s.
- C: **Data-quality defect on the named location** - its displayName returned with a replacement character
  (where an em dash was likely intended). Long shot; re-create the location with a clean ASCII displayName and
  retry.

**Recommendation:** Run a single **bounded** diagnosis pass in order A -> C -> B (cheapest / likeliest first),
NOT another blind apply retry. Once the cause is confirmed and the fix is known, flip
`enable_geo_block_ca_policy = true` and verify geo_block creates on one apply. Do not spend more than one
focused pass here - geo_block is 1 of 8 report-only policies and nothing depends on it.

**RESOLVED 2026-07-10 (Option A confirmed and PROVEN live):**
Root cause was the **reference-format bug (Option A)**: the policy passed the named location by its
`.id` (the full resource path `/identity/conditionalAccess/namedLocations/<id>`) where the CA store
expects the bare `.object_id` (the GUID only). Switching the reference to `.object_id` and re-enabling
(`enable_geo_block_ca_policy = true`) fixed it. Evidence: deploy run **29111153212** created the
geo_block policy (`id 6b96eb0d-...`) with **no 1040**, and QA verified it live in Graph - report-only,
`excludeLocations` set to the bare GUID which resolves to the real `approved_countries` named location.
Notes: the tag-churn management fix (built-ins made **add-if-missing** rather than overwrite) is applied
in Azure; QA observed a **mojibake in the `platform/management` tag-governance `display_name`** (a
replacement character where a clean glyph was intended) - minor cosmetic follow-up, non-blocking.

### OQ-022: Durable greenfield fix for OIDC token expiry on the identity root's long (1-3h) AADDS create - split the root, or add CI job-level re-auth?

- **Raised:** 2026-07-10 (identity apply run 29055619749 recovery, architect, ADR-029 Part C)
- **Section:** 8 (Identity) / 5 (azuread Conditional Access) / 10 (Pipeline & Tooling, OIDC auth)
- **Blocking:** No - ADR-029's config-driven import closes the token-expiry exposure for the CURRENT POC
  (the domain is built once, then only refreshed, so every future apply is short). This item is the durable
  fix for a from-scratch greenfield rebuild only.
- **Priority:** Medium

**Question:**
The `platform/identity` root co-locates a 1-3h `azurerm_active_directory_domain_service` create (create-only
wait for both DCs) with azuread Graph / Conditional-Access operations in ONE CI apply. In run 29055619749
the trailing azuread ops failed `AADSTS700024: Client assertion is not within its valid time range` - the
GitHub OIDC federated assertion (~5 min) and its derived access tokens (~1h) do not survive a 3h apply.
Empirically the azurerm/ARM operations survived (the domain was built), so the exposure is specifically the
azuread provider's tail-end Graph calls after a cold AADDS create. ADR-029's import makes THIS deployment's
future applies short (import has no create-wait), so the token never expires again for the POC lifetime. But
a full teardown + greenfield redeploy (the DEPLOYMENT.md path) would again run the 3h create BEFORE the CA
policies and re-hit AADSTS700024. What is the durable fix?

**Options being considered:**
- A: **Split the identity root** into Phase 1 (network + NSG + AADDS managed domain) and Phase 2 (azuread
  named location + Conditional Access policies), each a separate CI apply so neither apply contains both a
  multi-hour create AND trailing Graph ops. Cleanest separation of ARM vs Graph lifecycles; cost is a
  non-trivial refactor (new root, state migration, cross-root data passing for the domain/subnet, provider
  wiring, an extra pipeline stage).
- B: **CI job-level re-auth / token refresh** before the azuread operations (e.g. re-run the OIDC
  azure/login step, or fetch a fresh GitHub id-token, immediately before the Graph-touching apply phase).
  Smaller change, but the identity root is a single apply so a mid-apply re-auth is awkward; likely pairs
  with some ordering guarantee that Graph ops run last. Keeps platform/identity CI-only.
- C: **Accept as a documented POC deviation** - import covers the POC; the greenfield-rebuild token-expiry
  is a known limitation noted in DEPLOYMENT.md, revisited only if a clean-room redeploy is required.

**Recommendation:** For now, ADR-029 import (no code change here) plus **C** as the interim posture; adopt
**A** if/when a validated greenfield rebuild becomes a requirement. Do NOT build A speculatively during the
recovery - the priority is getting the identity layer green. Keep `platform/identity` CI-only either way.

**RESOLVED 2026-07-20 (architect, ADR-055) - greenfield rebuild requested, durable fix designed and chosen.**
Mechanism verified (not assumed): this is the NATIVE provider OIDC context, not az-CLI, so ADR-054's
`az_relogin` does not transfer. go-azure-sdk's GitHub OIDC authorizer (`sdk/auth/github_oidc_authorizer.go`)
caches the ACCESS token and re-mints a FRESH GitHub assertion via `githubAssertion()` on each access-token
acquisition, PROVIDED the request URL + bearer token resolve (`ARM_OIDC_REQUEST_URL`/`ARM_OIDC_REQUEST_TOKEN`,
GitHub-Actions fallback `ACTIONS_ID_TOKEN_REQUEST_URL`/`ACTIONS_ID_TOKEN_REQUEST_TOKEN`). In run 29055619749
azurerm re-minted across a 2h11m create poll (it failed on TIMEOUT, not AADSTS700024) while the azuread tail
Graph ops at +3h reused a STALE job-start assertion and hit AADSTS700024 - the divergence in the same run is
the smoking gun (a version-gated / idle-gap behaviour; the lock now resolves azuread 3.9.0 / azurerm 4.71.0,
both current, both reading the request inputs).

**Chosen fix (a coordinated two-part, NOT a root split, NOT a stored credential):**
- Part 1 (structural GUARANTEE, identity root): a single umbrella flag `enable_conditional_access` (default
  `true`) gates every azuread Graph write (named location + `time_sleep.wait_named_location` + all eight CA
  policies CA-001..CA-008),
  so greenfield runs as a documented TWO-PASS: Pass 1 (`enable_conditional_access = false`) creates
  network + AADDS as an azurerm-ONLY long apply (proven token-safe; ADR-029 import recovers a timed-out
  create), Pass 2 (flag `true`, domain already Running -> Read in seconds) runs the Graph writes in a SHORT
  apply under a fresh token. This is OQ-022 Option A's lifecycle separation achieved WITHOUT a new root/state
  migration - it reuses the `enable_*` pattern and the existing ADR-029 import.
- Part 2 (refresh HYGIENE, all roots, `_tf-root.yml`): explicitly export `ARM_OIDC_REQUEST_URL` +
  `ARM_OIDC_REQUEST_TOKEN` (from the runtime `ACTIONS_*` vars, via a `$GITHUB_ENV` step - the job `env:` map
  does not shell-expand runtime vars), with provider floors azurerm 4.71.0 / azuread 3.9.0. This makes token
  refresh reliable for Pass 2 and for every other long apply (notably connectivity WITH VPN/ExpressRoute
  gateways under production restoration, ADR-049/ADR-042; APIM/AKS/Databricks/Fabric are already sub-window).

**Rejected:** full root split (OQ Option A original) - heavier than the flag two-pass for the same
guarantee; Part-2-alone / mid-apply re-auth (OQ Option B) - refresh alone is very likely sufficient but
UNPROVABLE across a 3h idle gap without a live long-apply, and the user's 4-fail bar makes staking the first
greenfield run on it unacceptable (so Part 2 is kept as hygiene, Part 1 is the guarantee); a longer-lived
cert/secret (OQ Option c) - regresses the keyless OIDC posture (ADR-004/005/021) and is unnecessary;
self-hosted runner - out of bounds (ADR-005/OQ-007).

**Lanes:** DevSecOps owns `_tf-root.yml` (Part 2 export step + docs) and the greenfield two-pass sequencing
in the deploy runbook/DEPLOYMENT.md. Cloud-engineer owns `platform/identity` (the `enable_conditional_access`
flag + `count` gating on the nine azuread resources (named location + CA-001..CA-008) + `one(...)`-safe outputs + reinstating the ADR-029 import
block for greenfield recovery). MANDATORY pre-clearance before any deploy retry; the real proof is the live
greenfield long-apply. See ADR-055 for the full spec and consequences.

**Superseded interim note (2026-07-20, teardown consolidation) - a proven `az_relogin` primitive now exists;
generalizing it to long DEPLOY steps is a tracked item, not in scope here.** ADR-054's teardown fix
built `az_relogin` (teardown-common.sh): it mints a BRAND-NEW GitHub OIDC federated assertion on demand
(fresh id-token from `$ACTIONS_ID_TOKEN_REQUEST_URL`, audience `api://AzureADTokenExchange`, then
`az login --service-principal --federated-token`) and re-authenticates mid-job, bypassing az's broken
one-time-assertion refresh. This is exactly OQ-022's Option B mechanism, and it is PROVEN green across a
30-min reconcile wait in teardown. It currently solves the token-expiry class for TEARDOWN ONLY (it is
an az-CLI shell helper; the identity root's long AADDS create is a Terraform azurerm/azuread apply, a
different execution context). Tracked follow-up (do NOT build speculatively): evaluate whether the same
fresh-assertion-on-demand pattern can wrap or precede the long deploy steps (the identity root's 1-3h
AADDS create + trailing Graph ops), e.g. a CI re-auth step immediately before the azuread phase, which
would make OQ-022 Option B concrete for deploy. This does not change the teardown design and is not in
scope for the teardown consolidation; it is recorded so the proven primitive is not forgotten when a
validated greenfield rebuild becomes a requirement.

### OQ-021: ALZ diagnostic-settings DINE (`Deploy-Diag-LogsCat`) fails - its central Log Analytics workspace parameter is unwired (resolves to the zero-GUID subscription)

- **Raised:** 2026-07-09 (identity apply run 29055619749 remediation failure, architect)
- **Section:** 2 - Management Group Hierarchy (MG policy) / cross-cutting observability
- **Blocking:** No - does not block any apply. It is a policy auto-remediation (DINE); the Entra DS
  managed domain reached Running and the platform/identity Terraform apply are both unaffected.
- **Priority:** Medium

**Question:**
The ALZ `Deploy-Diag-LogsCat` DeployIfNotExists policy (assigned at the globaris/platform MG scope by
`platform/management-groups` via avm-ptn-alz) is failing every auto-remediation. When the new Entra DS
managed domain appeared, the policy tried to deploy a diagnostic setting routing the domain's logs to a
central Log Analytics workspace and the deployment failed. Verified evidence (az deployment operation
detail, 2026-07-09) on the `PolicyDeployment_...` deployment in the identity subscription's AADDS resource
group (`rg-identity-aadds-globaris-poc`):
- **code:** `LinkedAuthorizationFailed`
- **target:** `microsoft.aad/domainservices/providers/diagnosticSettings`
- **message:** the client had permission to write the diagnostic setting `setByPolicy-LogAnalytics` on the
  domain, "however the linked subscription '00000000-0000-0000-0000-000000000000' was not found."

This is NOT scoped to AADDS. Because the failure is at the policy-ASSIGNMENT parameter level (an empty
workspace resource ID that resolves to the all-zeros subscription), this DINE fails IDENTICALLY for every
resource it targets tenant-wide, not just the managed domain. How do we wire the real central workspace?

**Root cause:**
The avm-ptn-alz policy assignment for diagnostic-settings-to-LAW was deployed WITHOUT its `logAnalytics`
(workspace resource ID) parameter set to the real platform LAW. The deployed diagnostic setting's workspace
resource ID therefore resolves to the zero-GUID subscription `00000000-...`, which does not exist - hence
`LinkedAuthorizationFailed`. The platform LAW itself exists (its workspace/customer IDs were captured as
repo Secrets after the management apply); it is the POLICY ASSIGNMENT parameter in
`platform/management-groups` that was never wired to that workspace's resource ID.

**Correction of an earlier disposition:** prior docs (docs/preclearance/platform-identity.md and ADR-028
follow-up 3) claimed this DINE was "noise" that would "self-heal on the next compliance cycle once the
domain is Running." That is WRONG. It is a structural unwired-parameter defect, not a transient follow-on of
the earlier failed domain create. It will keep failing until the assignment's workspace parameter is
populated with the real platform LAW resource ID; `az policy remediation create` would also re-fail. It
needs a real fix, not a wait.

**Options being considered:**
- A (recommended): Wire the platform LAW resource ID into the ALZ diagnostic-settings policy assignment's
  parameter via avm-ptn-alz `policy_default_values` / the alz library assignment parameters in
  `platform/management-groups`, then re-apply that root and run `az policy remediation create` to clear the
  remediation backlog. Restores central diagnostics with the governance signal intact.
- B: Disable or adjust the `Deploy-Diag-LogsCat` assignment if central diagnostics are out of POC scope.
  Weaker - loses the governance/observability signal that logs are being routed centrally.

**Lane:** this is a `platform/management-groups` change (DevSecOps/policy to shape the assignment
parameter, cloud-engineer to wire the module input). It is SEPARATE from and does not block the identity
re-apply - track and fix it on its own.

**Consequence of leaving it:** the managed domain's and other targeted resources' diagnostic logs do not
ship to the central platform LAW until the parameter is wired. This is an observability gap, not a
security or availability one.

**UPDATE 2026-07-31 (architect, ADR-070). STILL OPEN, but Option A is REVERSED as written and must
never land alone. Body above unedited, per append-only.**

This question is no longer only an observability gap. It is one half of a live ownership conflict that
has now failed `landing-zones/bank-data-p1` twice during the centralus rebuild (runs `30661012325` and
`30662610292`). ADR-070 rules the ownership; this entry records what changes here.

**What changed.** Terraform declares diagnostic settings through the AVM `diagnostic_settings` input on
eight resources estate-wide: `platform/management` (automation account), `platform/security`
(subscription activity), `platform/connectivity` (both hub firewalls), `landing-zones/online-p1`
(App Gateway), and four in `landing-zones/bank-app-p1` (ACR, AKS, APIM, Service Bus), plus the three in
`landing-zones/bank-data-p1` that just failed. The `Deploy-Diag-LogsCat` DINE writes
`setByPolicy-LogAnalytics` on the same scopes. Two settings on one resource pointing at the SAME
workspace means the same rows are ingested twice and billed twice on the Analytics ingestion meter.
For `allLogs` on AKS, APIM, Databricks and Foundry that is a real recurring cost for zero extra insight.

**Why Option A alone is now actively harmful.** Option A wires the real platform LAW resource ID into
the assignment parameter. Today the parameter resolves to the zero-GUID subscription, so every
remediation fails and the DINE writes nothing - which is annoying but harmless. Wiring it converts a
DINE that fails harmlessly into one that **succeeds** on every resource in the estate. That produces
duplicate ingestion estate-wide, and it arms the azurerm `azurerm_monitor_diagnostic_setting`
RequiresImport failure on every future rebuild of every spoke, which is exactly the failure that just
cost this rebuild two applies. **Option A is only safe when it lands together with ADR-070 decision 2's
RG-scoped `Mitigated` exemptions on the resource groups where Terraform owns the diagnostic settings.**
The two must ship in one change or neither ships.

**Option B is correspondingly stronger than when this was written**, but still not recommended:
disabling the assignment loses the governance signal for everything Terraform does NOT wire, which is
most of the estate.

**New option C (recommended default, ADR-070 decision 1 + 2): keep the DINE, wire its parameter, and
carve Terraform's own resource groups out of it by exemption.** One writer per resource. The policy
keeps its scope over everything the estate's Terraform does not create, which is the governance signal
Option B would have thrown away, and it loses that scope over everything Terraform does create, which
is what removes the collision.

**Sequencing (do not reorder).** The exemptions must be live and propagated (300s, LESSON 35) BEFORE
the assignment parameter is wired. Wiring first and exempting second opens a window in which the DINE
successfully writes competing settings across the whole estate, and every one of those becomes a
survivor that a later apply trips over.

**Corrections to the record this update carries.** The 2026-07-31 Steps 4-8 operator entry offered
"zero DINE diagnostic policies assigned at the landingzones MG" as evidence that no policy could have
created the disputed settings. That check read one scope. These assignments are inherited from an
ANCESTOR management group, which is the precise failure mode LESSON 34 and the standing pre-clearance
rule ("live policy matrix at EVERY ancestor MG scope") exist to prevent, and live `PolicyDeployment`
evidence shows the family firing on these very resources.

**Still open, and what would close it:** read D2 in ADR-070 decision 4 - the assignment's Log Analytics
workspace parameter value at every ancestor scope. Zero-GUID means this question stands exactly as
written. The real workspace ID means it has silently resolved and the duplicate-ingestion exposure is
already live estate-wide, which would need the exemptions urgently rather than eventually. Answer this
together with OQ-067, never separately.

### OQ-020: Can Cost Management exports write to the keyless cost-exports SA?

- **Raised:** 2026-07-07 (cost-exports refresh-403 fix, cloud-engineer)
- **Section:** 7 — FinOps: Tagging & Budgets
- **Blocking:** No — does not block plan/apply; only the scheduled export RUNS may fail to deliver blobs.
- **Priority:** Medium

**Question:**
`stfinops...` has `shared_access_key_enabled = false`. The scheduled export write is performed by the
Cost Management service, not our CI SP, so the SP's new Storage Blob Data Contributor grant does not
authorize it. Microsoft supports exports to key-disabled/firewalled SAs via a system-assigned managed
identity on the export (newer CostManagement API versions), but `azurerm_subscription_cost_management_export`
in azurerm ~>4.71 exposes no `identity` block. After the next successful apply, verify whether export runs
actually deliver blobs to `cost-exports`.

**Options being considered:**
- A: Wait and verify — exports may succeed (trusted-service path). If blobs land, close this OQ.
- B: If runs fail, manage the export via `azapi` with a newer API version + system-assigned identity, then
  grant that identity Storage Blob Data Contributor on the SA.
- C: Re-enable shared keys on this one SA with a `# DEVIATION:` note (weakest, last resort).

**Update 2026-07-08 (constraint sweep):** Per the exports tutorial (learn.microsoft.com,
tutorial-improved-exports), Cost Management creates a system-assigned managed identity for a NEW export when
the creating principal holds `Microsoft.Authorization/roleAssignments/write` on the destination SA, and
auto-assigns that MI Storage Blob Data Contributor scoped to the container. Our CI SP holds User Access
Administrator at subscription scope (ADR-021 row 6), so it has that permission at create time. The MI flow
needs CostManagement API 2023-08-01+; whether azurerm ~>4.71 drives this resource with a new enough API
version is the remaining unknown. Outlook improved; still verify blob delivery after the first successful
apply (option A first).

**ANSWERED 2026-07-08 (run 28911617973) - CLOSED by ADR-027.** Live evidence refuted Option A: 4 of 5
export CREATES failed with `400: Key-based authentication is currently disabled on this storage account.
To proceed, please enable "Allow storage account key access"` - the azurerm ~>4.71 resource drives an
older CostManagement API that hard-rejects key-disabled destination SAs at PUT, so even resource creation
fails (not just scheduled delivery). User chose **Option B**: migrate the export in `modules/finops` to
`azapi_resource` (`Microsoft.CostManagement/exports@2025-03-01`) with `identity { type = "SystemAssigned" }`;
the SA stays keyless. Role grant relies on the documented service-side auto-assignment (creator SP holds
roleAssignments/write on the SA via UAA at sub scope); an explicit `azurerm_role_assignment` is the recorded
fallback if delivery fails. Option C (re-enable shared keys) rejected. The 5th export (identity sub) failed
only on a STALE "RP Not Registered" check - Microsoft.CostManagementExports was registered by the same
apply and the service check lagged; a plain rerun clears it. Full design, provider pins, state-migration
note (clean swap, nothing in state), and the remaining post-apply verification (blobs must land in
`cost-exports` after the first scheduled run) are recorded in **ADR-027**.

### OQ-019: DDoS governance spans two root modules — introduce one shared toggle so they can't diverge?

- **Raised:** 2026-07-06 (DDoS LinkedAuthorizationFailed root-cause, architect)
- **Section:** 2 — Management Group Hierarchy (policy) / 4 — Connectivity (plan)
- **Blocking:** No — ADR-026 (DoNotEnforce `Enable-DDoS-VNET` at the connectivity MG) unblocks apply now.
- **Priority:** Medium

**Question:**
DDoS is now governed in two separate root modules that were never linked: the **plan resource** in
`platform/connectivity` (gated by `var.enable_ddos_standard`, ADR/commit e2733db) and the
**`Enable-DDoS-VNET` Modify policy** assigned by `platform/management-groups` via `avm-ptn-alz`
(neutralised by ADR-026). This split is exactly what caused the outage: turning the plan off in
connectivity did nothing to the enforced policy that injected the placeholder plan id, so every VNet
create still failed. Should we introduce a single shared variable that drives both stacks — the plan
resource in connectivity AND the policy assignment enforcement/parameter in management-groups — so the
two cannot drift into an inconsistent state again?

**Options being considered:**
- A: One shared `enable_ddos_standard` (recommended default) consumed by both roots — when false, no plan
  and the `Enable-DDoS-VNET` assignment is DoNotEnforce; when true, create the plan and re-enforce the
  policy with the real plan id via `policy_default_values`. Single source of truth, no split-brain.
- B: Leave the two independent and rely on documentation (ADR-026 coupling note) to keep them consistent —
  simpler now, but re-opens the drift risk that caused this failure.

**Recommendation:** A — a single `enable_ddos_standard` wired into both the connectivity plan and the
management-groups policy assignment.

### OQ-018: Production-grade state-SA access — Private Endpoint + VNet/self-hosted runner egress (ADR-025 Option B follow-up)

- **Raised:** 2026-07-06 (CI state-backend 403 diagnosis, architect)
- **Section:** 10 — Pipeline & Tooling (state backend access)
- **Blocking:** No — ADR-025 Option A (JIT default_action Allow/Deny flip) unblocks CI now. This is the
  production-grade replacement for that time-boxed public-window trade-off.
- **Priority:** Medium

**Question:**
ADR-025 (Option A, accepted) unblocks CI by flipping the state SA `default_action` to Allow for the job
window and restoring Deny on exit. The trade-off is a ~2-3 min window in which the blob endpoint is publicly
reachable (still defended by Entra-only auth + RBAC + TLS + CMK), and it is single-root only (target=all
still relies on the permanent `ip_allow_list` prerequisite). The production-grade fix removes public exposure
entirely: put a **Private Endpoint** on the state SA (`privatelink.blob.core.windows.net` + private DNS zone),
set `public_network_access = Disabled`, keep `default_action = Deny`, and run CI on a **self-hosted or
VNet-injected runner** that egresses through that VNet. No firewall flip, no egress-IP roulette, no race.
When do we adopt this, and on what runner model?

**Options being considered:**
- A: Self-hosted runner in a CI/management VNet (container/VM scale set) + Private Endpoint on the state SA;
  `public_network_access = Disabled`. Most secure, most infra to own (runner lifecycle, VNet, private DNS).
- B: GitHub larger runners with a static outbound IP range, allow-listed permanently in bootstrap `ip_rules`
  (no Private Endpoint). Simpler than A, deterministic, but keeps public endpoint + requires the larger-runners
  plan (ADR-025 Option C).
- C: Stay on Option A for the POC lifetime; adopt A only when the environment graduates beyond POC (recommended
  default — the public window is time-boxed and RBAC/Entra/CMK-protected, acceptable for a portfolio POC).

**Note (leftover state cleanup):** the failed connectivity inits left `platform/connectivity/terraform.tfstate`
as a **0-byte blob with a broken (unlocked) lease**. No apply ever ran against it, so it holds no real state
and is **safe to overwrite on the next successful init** — Terraform will treat the empty blob as fresh state.
No manual cleanup required beyond confirming the lease is not held (verified unlocked/broken 2026-07-06).

---

### OQ-017: AVM module + provider version drift roll-up (staleness maintenance pass)

- **Raised:** 2026-07-05 (drift audit, code-reviewer)
- **Section:** cross-cutting (2, 5, 6, 8, 9)
- **Blocking:** No — staleness, not a known break. Do as a deliberate, verified maintenance pass, not ad hoc.
- **Priority:** Medium

**Question:**
Post-incident drift audit (see ADR-023 / WORKLOG 2026-07-05) found several exact-pinned AVM modules and one
provider constraint lagging upstream. None is a confirmed apply-breaker, but the same neglect produced the
`Enforce-EncryptTransit` failure. Bump deliberately (verify each changelog, re-plan the affected scope), not
in one blind sweep. Candidates (verified latest via registry API 2026-07-05):
- `avm-ptn-alz` **0.19.1 → 0.21.0** (`platform/management-groups/main.tf:32-33`) — the MG/policy engine; ADR-023
  follow-up (3). Compat cleared (root `alz ~> 0.21.0`, `azapi ~> 2.9.0` satisfy 0.21.0's floors). Re-plan MG scope.
- `avm-res-network-virtualnetwork` **0.17.1 → 0.19.0** (4 roots, lockstep: `landing-zones/corp-a1`, `corp-a2`,
  `online-p1` `main.tf`, `platform/identity/identity-network.tf`).
- `avm-res-recoveryservices-vault` **1.1.3 → 1.1.11** (3 roots: `corp-a1/backup.tf`, `corp-a2/main.tf`,
  `platform/identity/domain-services.tf`; upstream skips 1.1.8).
- LOW patch lag: `avm-res-web-serverfarm` 2.0.4→2.0.7; `avm-ptn-alz-connectivity-hub-and-spoke-vnet`
  0.17.1→0.17.3; `avm-ptn-network-private-link-private-dns-zones` 0.23.1→0.23.2.
- Provider drift: `azapi` pinned 3 ways — security `~> 2.4.0` (only root using `azapi_resource` directly, yet
  most stale), connectivity `~> 2.5`, management-groups `~> 2.9.0`. Standardize on one floor (`~> 2.9`).

**Options being considered:**
- A: Batch by module family across their lockstep roots, each with a re-plan of the affected scope, as each
  section comes up for deploy (recommended — ties the bump to a real plan review).
- B: One dedicated "dependency refresh" session bumping everything + full `validate`/plan sweep before resuming deploys.
- C: Defer all until each root's own deploy session forces the question.

### OQ-016: Built-in policies referenced without explicit `parameter_values` — PUT-time risk (management + security)

- **Raised:** 2026-07-05 (drift audit, code-reviewer)
- **Section:** 5 (management/policy) and 6 (Defender/Sentinel)
- **Blocking:** Yes — for the `platform/management` and `platform/security` apply runs (same class as ADR-023;
  invisible to `terraform validate`/`plan`, only ARM's policy-parameterization check at PUT rejects it).
- **Priority:** High

**Question:**
The drift audit flagged two spots that repeat the `Enforce-EncryptTransit` failure shape — a built-in policy
referenced with only a `reference_id`, inheriting the built-in's current default parameters (incl. `effect`),
which a newer built-in version can make ARM-invalid or newly-required:
1. `platform/management/main.tf:520-542` — `azurerm_policy_set_definition.deny_public_network_access` refs
   built-ins `1b8ca024-…`, `405c5871-…`, `34c877ad-…` with no `parameter_values`.
2. `platform/security/defender.tf:46-55` + `:201-215` — NIST 800-53 R5 `179d1daa-…` and CIS Azure Foundations
   v2.0.0 `06f19060-…` assigned with no params; code already carries `UNVERIFIED 2026-05-29` on the CIS
   GUID/benchmark version (1.4.0 vs 2.0.0 vs 2.1.0). Wrong/retired policySetDefinition GUID = hard PUT 404/400.
   Gated by `var.enable_regulatory_compliance`.

**Pre-apply mitigation (before those roots deploy):** for each built-in, `az policy definition show --name
<guid>` / `az policy set-definition show --name <guid>` to confirm it resolves and dump current param
defaults; where an `effect` param exists, pass it explicitly (`Audit|Deny|Disabled`) via `parameter_values`
rather than trusting the built-in default. Confirm the CIS GUID against the intended benchmark version.

**RESOLVED 2026-07-07:** Verified all 5 built-ins live (`az policy [set-]definition show`) and fixed.
- **Management (part 1):** the KV GUID was WRONG — `405c5871-…-58ad8008cbe8` returned `PolicyDefinitionNotFound`
  (would have hard-failed the set-definition PUT). Corrected to `405c5871-…-58e19d68ff5b` ("Azure Key Vault
  should disable public network access"). SQL `1b8ca024-…` + Storage `34c877ad-…` valid. All three now pass
  `effect` EXPLICITLY. Effect set to **Audit, not Deny** — code-review found Deny at the landingzones MG would
  hard-block the spoke NSG flow-log SAs (no `network_acls`) + the Section 13 synthetic layer (public-access by
  design). Audit governs/reports without blocking; enforce-later path (exemptions then Deny) documented in
  `platform/management/main.tf`. (User chose Audit 2026-07-07.)
- **Security (part 2): clean.** NIST `179d1daa-…` = "NIST SP 800-53 Rev. 5" (v14.19.0) and CIS `06f19060-…` =
  "CIS Microsoft Azure Foundations Benchmark v2.0.0" (v1.10.0) both resolve; CIS IS v2.0.0 as intended; 0
  required-no-default params. `defender.tf` UNVERIFIED note → VERIFIED. No code change beyond the comment.
- Committed with the management-deploy prep; **management apply unblocked.**

### OQ-015: Environment required-reviewer gate unavailable on the current GitHub plan

- **Raised:** 2026-07-04 (Section 10 CI wiring, devsecops)
- **Section:** 10 (Pipeline & Tooling)
- **Blocking:** No - the deploy/teardown pipeline runs without it; this is a governance gap vs ADR-019
- **Priority:** Medium

**Question:**
ADR-019 / OQ-013 (RESOLVED B) require >=1 **required reviewer** on the `production` (apply) and
`production-destroy` (teardown) GitHub Environments. On wiring them, GitHub returned **HTTP 422 "Please
ensure the billing plan supports the required reviewers protection rule."** - environment protection rules
are **not available for PRIVATE repos on the Free plan**. Both environments now exist but are **ungated**
(0 protection rules). How do we restore the human-approval gate?

**Options being considered:**
- A: **Flip the repo public** (recommended) - environment protection rules (incl. required reviewers) are
  free on public repos. Aligns with the 2026-07-03 public-readiness prep (secret-swept, MIT LICENSE, history
  rewritten). Adds required-reviewer + branch-policy gates at zero cost. Then re-run the reviewer wiring.
- B: **Accept ungated environments as a documented POC deviation.** The teardown `confirm == "destroy"`
  typed guard (hard-fails before any Azure login) and the deliberate `workflow_dispatch`-only trigger remain
  as the guardrails; no automated human approval step. Cheapest; weakens ADR-019.
- C: **Upgrade to GitHub Pro/Team** to get environment protection on the private repo (recurring cost).

**Interim state:** both environments created ungated so the OIDC `environment:production` /
`environment:production-destroy` federated subjects resolve and the pipeline is functional. The reviewer gate
is the only missing piece.

**User direction (2026-07-04):** keep the repo **PRIVATE** until all deployments are validated end-to-end;
find a private-compatible governance setup. Rules out Option A (public flip) for now.

**Finding (2026-07-04, retry with correct reviewer id `175745508`):** the required-reviewer PUT still returns
**HTTP 422 billing** — so the *account* backing `teeeke/Azure-Architecture` is not on a plan that supports
private-repo environment protection. (The CLI token lacks `read:user`, so `.plan` can't be confirmed via API.)
User believes they have "GitHub Pro"; likely the **Copilot Pro ≠ GitHub Pro** mix-up — needs manual verify at
github.com/settings/billing. Native reviewer wiring is a 1-command API call the moment GitHub **Pro** is
confirmed/active.

**Private-compatible path forward:**
- If GitHub **Pro** is actually active → wire required reviewers on both environments now (restores ADR-019),
  repo stays private.
- If not → either upgrade to Pro ($4/mo, private), OR add the **free typed `confirm=apply` guard** to
  `deploy.yml` apply jobs (documented deviation; hard-fails before azure/login; real reviewer gate layered on
  later). User leaned "no extra gate for now" believing Pro covered it — revisit once billing is verified.

**Update 2026-07-04 — repo moved to org `Globaris-Inc/Azure-Architecture` (PRIVATE).** Remote re-pointed;
Variables (3) + Secrets (7) + both Environments **survived the transfer** (no re-set needed). Org reads
`plan: team` (which includes private-repo environment protection), `teeeke` is an **active org admin member**.
**Yet required-reviewer AND wait-timer PUTs both still 422** ("billing plan does not support ... protection
rule") — ruled out: reviewer id, JSON payload shape, stale env metadata (deleted+recreated `production`
fresh under the org — still 422). Conclusion: GitHub-side **billing entitlement not active/propagated** for
the org's Team plan (post-transfer lag, or an unconfirmed/pending Team billing state). Not fixable from the
CLI.

**Needed from user:** at github.com/organizations/Globaris-Inc/settings/billing confirm **Team is active with
a valid payment method** (not trial/pending). Then either (a) tell me to **retry** the reviewer wiring (1
command — it will just work once entitlement is live), and/or (b) approve the **free typed `confirm=apply`
guard** on `deploy.yml` apply jobs as interim/defence-in-depth. Both environments currently exist **ungated**
so the pipeline is functional meanwhile.

**Decision 2026-07-04 (user):** set up **branch protection on `main`** (code-merge governance) instead of
chasing the environment reviewer gate now. **DONE** — a repository ruleset was imported to
`Globaris-Inc/Azure-Architecture` (no import errors) and the config is version-controlled at
`.github/rulesets/main-branch-protection.json` (+ `.github/rulesets/README.md`; documented in
`docs/cicd-deploy-teardown.md` §7). It enforces: PR required + ≥1 approval + dismiss-stale, no force-push /
no deletion, required checks (`terraform fmt -check` + the 10 `validate — <root>` jobs); repo admins bypass
(solo-owner safety). **Caveat recorded:** branch protection gates *merges to `main`*, NOT the deploy apply
run — deploys are `workflow_dispatch`-triggered (LESSON 17), so a merge never auto-applies.

**OQ-015 stays OPEN on the apply-run gate only:** the environment reviewer gate (blocked on Team billing
entitlement — retry when live) OR the free typed `confirm=apply` guard. Environments remain ungated until one
is in place.

---

### OQ-014: Brownfield adoption unknowns - importing an existing environment into the ALZ

- **Raised:** 2026-07-03 (Section 11 planning, architect)
- **Section:** 11 (design captured now) / future build
- **Blocking:** No - greenfield docs proceed now; this gates the future brownfield build only
- **Priority:** Medium

**Question:**
What is the supported approach for adopting an existing (brown-field) tenant/subscriptions into this ALZ,
and which unknowns must be resolved before we build that capability?

**Open sub-questions (resolve before a brownfield build):**
- **State:** `terraform import` of pre-existing RGs/VNets/policy assignments, vs. greenfield-only with
  parallel coexistence and a later cutover?
- **MG grafting:** moving existing subscriptions under the Globaris MG tree - what is the blast radius of
  inherited policy on already-running workloads?
- **Policy rollout:** audit / DeployIfNotExists in non-enforcing mode first, then enforce - what soak period
  and exception process?
- **Networking coexistence:** existing hub/VNet/DNS vs. this platform's hub - peering, address-space
  overlap, DNS forwarder cutover.
- **RBAC:** existing assignments vs. the scoped OIDC SP (ADR-021) - does adoption need broader temporary
  grants during import?
- **Ownership boundary:** which existing resources IaC takes over vs. leaves un-managed.

**Approach captured now (ADR-022):** document the adoption approach in `docs/brownfield-adoption.md` as
roadmap; build + validate the capability in a later section/wave.

---

### OQ-013: CI/CD approval model for apply vs teardown

- **Raised:** 2026-06-27 (CI/CD deploy + teardown design session, architect)
- **Section:** 10 (Pipeline & Tooling)
- **Blocking:** Yes (until resolved) — gates the structure of `deploy.yml` / `teardown.yml`
- **Priority:** High

**Question:**
How should apply and teardown be gated? One shared GitHub Environment for both, or separate
environments so destroy approval is a distinct, more deliberate gate? And what extra guards on teardown?

**Options being considered:**
- A: One `production` Environment gates both apply and destroy.
- B: Two Environments — `production` gates apply (`deploy.yml`), `production-destroy` gates teardown
  (`teardown.yml`) — each with a required reviewer; teardown also requires a typed `confirm=destroy`
  input that hard-fails the run before any Azure login.

**RESOLVED 2026-06-27:** Option B. TWO GitHub Environments: `production` (apply gate, referenced via
`environment:` on apply jobs in `deploy.yml`) and `production-destroy` (teardown gate, referenced on the
teardown job in `teardown.yml`), each with ≥1 required reviewer. Teardown additionally hard-fails its
first step unless `confirm == "destroy"`. This requires two new OIDC federated credentials (subjects
`...:environment:production` and `...:environment:production-destroy`) in `bootstrap/identity.tf` and a
bootstrap re-apply. Captured in ADR-019.

---

### OQ-012: Does "tear down everything" include the bootstrap state backend + OIDC app?

- **Raised:** 2026-06-27 (CI/CD deploy + teardown design session, architect)
- **Section:** 10 (Pipeline & Tooling)
- **Blocking:** Yes (until resolved) — defines the `teardown.yml` `include_bootstrap` default + scope
- **Priority:** High

**Question:**
When the operator chooses to "tear down everything," should the teardown also remove the bootstrap layer
(state Storage Account, CMK Key Vault, OIDC app registration / SP / federated credentials), or only the
9 workload + platform roots?

**Options being considered:**
- A: Scorched-earth by default — full reset also deletes the state backend + OIDC app (next deploy needs
  a manual re-bootstrap and re-setting the three GitHub Variables).
- B: Workload + platform only by default — keep the bootstrap state backend + OIDC app so redeploy is
  immediate; expose an `include_bootstrap` input (default `false`) for the rare full-decommission case.

**RESOLVED 2026-06-27:** Option B. Teardown scope is workload + platform only. `teardown.yml` exposes an
`include_bootstrap` boolean input that **defaults to `false`** — the state SA, CMK KV, and OIDC
app/SP/federation are kept so the environment can be redeployed immediately from CI with no re-bootstrap
or GitHub-Variable re-wiring. `include_bootstrap=true` is full decommission only and additionally
requires a documented manual `az ad app delete` (the SP cannot delete its own Entra app via ARM Owner)
and — until LESSON 18 deterministic naming lands — a manual `poc.backend.hcl` update. Captured in
ADR-019.

---

### OQ-011: Spoke `avm-res-network-virtualnetwork` 0.17.1 schema drift + missing lock files

- **Raised:** 2026-06-25 (Gap-closure Wave 2 / G4 session, cloud-engineer)
- **Section:** 9 (Landing Zone Spokes) — infra hygiene, not a feature gap
- **Blocking:** Partially — does **not** block G4 (the new corp-a1 RSV validates clean in isolation), but **does** block a clean root-level `terraform validate`/`plan` for `landing-zones/corp-a1` (and likely `corp-a2`/`online-p1`).
- **Priority:** Medium

> **RESOLVED — 2026-06-26 (Option A+B remediation, cloud-engineer) → fully closed 2026-06-27.**
> Option B was taken across the board: reconcile each call to its pinned module/provider schema (no version bumps), and generate `.terraform.lock.hcl` for every init-able root (Option A). On 2026-06-26, **9 of 10 roots** validated clean; only `platform/connectivity` remained blocked on a provider-version conflict. **On 2026-06-27 the architect's ADR-017 azapi pin (`~> 2.5`) was applied, and connectivity now validates — making it 10 of 10.** OQ-011 is fully RESOLVED. Fixes applied:
> - **All 3 spokes** (corp-a1/corp-a2/online-p1): `spoke_vnet` `resource_group_name = …network.name` → `parent_id = …network.id` (v0.17.1 schema). Subnet sub-schema + consumed outputs (`name`, `resource_id`, `subnets[...].resource_id`) were already correct for 0.17.1 — no other change needed.
> - **corp-a1 / corp-a2**: removed the non-existent `azurerm_private_dns_zone_group` resource (it is not an azurerm resource type) and moved DNS zone registration into the `private_dns_zone_group {}` nested block on `azurerm_private_endpoint.sql` (behavior-preserving).
> - **platform/management-groups**: `subscription_placement` reshaped to the v0.19.1 schema (`{ subscription_id, management_group_name }` per entry; MG names = arch-def ids). Same subscription→MG placements.
> - **platform/security**: `module.security_kv.resource.name/.vault_uri` → `.name`/`.uri` (avm-res-keyvault-vault output names); `azurerm_sentinel_watchlist` `workspace_id` → `log_analytics_workspace_id = module.security_law.resource_id` (azurerm v4 arg), with `depends_on` re-added to preserve onboarding order.
> - **platform/connectivity**: `private_dns_zones` call reconciled to v0.23.1 (`resource_group_name`→`parent_id`, dropped non-existent `resource_group_creation_enabled`). **CLOSED 2026-06-27 — see below.**
>
> **~~STILL OPEN — `platform/connectivity` only~~ → CLOSED 2026-06-27:** On 2026-06-26 init failed on a **provider version-constraint conflict**: the root pinned `azapi = "~> 2.4.0"` (`providers.tf:19` → `>=2.4.0,<2.5.0`), but sub-modules of **both** `avm-ptn-alz-connectivity-hub-and-spoke-vnet` v0.17.1 and `avm-ptn-network-private-link-private-dns-zones` v0.23.1 require `azapi ~> 2.5` (`>=2.5.0,<3.0.0`) — disjoint ranges, so init aborted. **The architect resolved this in ADR-017: pin azapi `~> 2.5`.** On 2026-06-27 the cloud-engineer applied `providers.tf:19` → `azapi = "~> 2.5"`; `terraform init -backend=false` now succeeds (azapi resolves to v2.10.0) and `terraform validate` returns `Success! The configuration is valid.` (no warnings). The dns.tf v0.23.1 reconciliation validated clean with no further drift — the azapi bump alone was sufficient. `.terraform.lock.hcl` generated for connectivity (to be committed). **All 10 roots now validate clean. OQ-011 fully RESOLVED.**

**Question:**
On a clean `terraform init -backend=false` (no committed `.terraform.lock.hcl`), the `module "spoke_vnet"` block in `landing-zones/corp-a1/main.tf` fails validation: it passes `resource_group_name`/`address_space`, but the `Azure/avm-res-network-virtualnetwork/azurerm` source that init resolves for the `version = "0.17.1"` pin expects **`parent_id`** (a resource-group ID) instead. This aborts init before all modules install, so the whole root cannot validate. Reproduced with the new `backup.tf` removed — it is pre-existing and unrelated to G4. Root cause is most likely that no `.terraform.lock.hcl` is committed for the spokes, so the originally-validated module build is not pinned and the registry now serves a differently-shaped 0.17.1 artifact (or the call was written against a build that differs from the published 0.17.1).

**Options being considered:**
- A: Commit `.terraform.lock.hcl` for each spoke (and all roots) so module/provider builds are reproducible; re-run init/validate against the locked build.
- B: Reconcile the `spoke_vnet` call to the published 0.17.1 schema (`parent_id` + current subnet shape) across corp-a1/corp-a2/online-p1, then re-pin.
- C: Bump the vnet module to a current version and update the call shape (larger change; cross-spoke).

Recommend a dedicated remediation pass (architect + cloud-engineer) — out of scope for the G4 wave per the section-per-session rule.


- **Raised:** 2026-06-25 (gap-closure planning)
- **Section:** 9 / 12 (Wave 5)
- **Blocking:** Yes — blocks the G5 portion of Wave 5 only (does not block G1/G2/G3/G4/G6)
- **Priority:** Medium

**Question:**
ADR-003 collapsed the Sandbox and Online archetypes into the single shared Landing Zones subscription. The
ALZ reference shows them as **separate subscriptions**. ADR-014 recommends KEEPING the collapse as a
documented deviation for the POC (it is a subscription-*count* gap, not a capability gap — the MG nodes,
policy inheritance, and RG segmentation already demonstrate the boundary). The user wants all gaps
addressed, so confirm the call:

**Options:**
- A: **Keep collapsed (deviation)** — recommended. No extra cost, no billing-scope dependency. Reviewer
  accepts ADR-014 explicitly.
- B: **Provision two real subscriptions** (one Online, one Sandbox) and bind `online-p1` + a sandbox RG-set
  to them under the existing MG nodes. Requires: (1) two more subscription IDs supplied in `poc.tfvars`,
  **or** (2) an EA/MCA enrollment-account ID so the engineer can use the `avm-ptn-lz-vending` subscription-
  vending pattern. Adds provisioning complexity and a small per-sub idle baseline.

**Needed from user:** choose A or B. If B, supply either two sub IDs or an EA/MCA enrollment account ID.

---

### OQ-009: Fund Azure DDoS Network Protection for the POC? (G3)

- **Raised:** 2026-06-25 (gap-closure planning)
- **Section:** 8 (Wave 5)
- **Blocking:** No — the construct ships flag-gated (`var.enable_ddos_protection = false`); this only
  decides the default/active state
- **Priority:** Medium

**Question:**
The reference diagram shows an Azure **DDoS Network Protection** plan on the hub. Per ADR-013 the
cloud-engineer will build the construct (`Azure/avm-res-network-ddosprotectionplan/azurerm` v0.3.0, wired to
the hub + online-p1 VNets) behind `var.enable_ddos_protection`, **default false**. DDoS Network Protection
is a **~$2,944/mo flat** plan — roughly 20–35x the entire rest of the platform's idle cost.

**Options:**
- A: **Keep default false** (recommended) — capability built and one toggle away; zero idle DDoS cost. The
  ARCHITECTURE.md deviation becomes "pre-staged, disabled."
- B: **Set default true / fund it** — only if a live demo of DDoS telemetry/metrics is required and the
  ~$2,944/mo is acceptable for the demo window.
- C: (noted, not recommended) DDoS **IP Protection** per-public-IP tier (~$199/mo/IP) instead of the
  network-tier plan — cheaper but does not match the reference's network-tier construct and is billed
  per IP; out of scope unless the user prefers it.

**Needed from user:** confirm A (default false), or approve B with the monthly spend, or request C.

---

### OQ-001: Tenant and subscription model for the POC

- **Raised:** Bootstrap
- **Section:** 1, 2
- **Blocking:** Yes — blocks Section 2
- **Priority:** High

**Question:**
ALZ assumes multiple subscriptions (Connectivity, Identity, Management, Security, multiple Landing Zones, Sandbox). For a portfolio POC, do we deploy:
- A: Multiple real subscriptions under one billing account (most faithful, highest cost)
- B: One subscription with strong RG-level segmentation simulating multi-sub (cheapest, less realistic)
- C: Subscription-per-archetype only for Platform (Connectivity, Mgmt, Security, Identity), single subscription for all Landing Zones (middle ground)

Recommended for a POC: **C**. Confirm before Section 2.

**RESOLVED 2026-05-05 (Session 2):** Option C — 4 platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription for all Landing Zones and Sandbox simulated via RG and MG-level policy assignment. Rationale: preserves the platform/workload boundary that matters most architecturally, keeps cost manageable for a portfolio POC (~$80–150/mo idle), and uses a sub count realistically provisionable on a Visual Studio benefit account.

---

### OQ-002: Identity mode — DCs on IaaS vs Microsoft Entra Domain Services

- **Raised:** Bootstrap
- **Section:** 8
- **Blocking:** No (deferrable until Section 8)
- **Priority:** Medium
- **Status:** **SUPERSEDED (2026-06-28, ADR-010)** — resolved to `identity_mode = "entra-ds"` and
  **built** in Wave 3 (`platform/identity/{identity-network,domain-services}.tf`).

**Question:**
PROMPT.md Section 8 leaves this as a `var.identity_mode` toggle. For the POC default value, which should we ship?

**Options:**
- A: Two B2s VMs as DCs (~$60/mo, full control, more realistic for enterprise)
- B: Microsoft Entra Domain Services (~$110/mo, less to manage, less to demo)
- C: Skip entirely for POC, leave the variable but default to `none`

~~**RESOLVED 2026-05-14:** Option C — `identity_mode = "none"`. Identity sub not built; `platform/identity/` left as scaffold only. No impact on Section 9 (spokes do not require domain services).~~

**SUPERSEDED 2026-06-25 (ADR-010):** Reversed during gap-closure (G1). New resolution: **Option B —
Microsoft Entra Domain Services** (`identity_mode = "entra-ds"`, Standard SKU, ~$110/mo). Rationale:
2026 CAF identity guidance favours managed Entra DS over self-managed DCs (AD-minimization, cloud-first);
less to manage and demo. The `var.identity_mode` toggle is retained so `ad-ds` (two B2s DCs) remains
selectable, but `entra-ds` is the shipped default. Build path in `docs/gap-closure-plan.md` Wave 3.
Note: requires a one-time **manual** tenant pre-step (Domain Controller Services SP + `AAD DC
Administrators` group) and surfaces OQ-003 (POC domain name).

---

### OQ-003: Domain name(s) for the POC

- **Raised:** Bootstrap
- **Section:** 5, 8
- **Blocking:** No
- **Priority:** Medium

**Question:**
Conditional Access, Entra ID, and any custom domain bindings need a domain. Are we using:
- The default `*.onmicrosoft.com` tenant domain (cheapest, no DNS work)
- A custom domain you own (more realistic, requires DNS verification)

**RESOLVED 2026-07-08:** Custom owned domain. The Entra DS managed-domain FQDN is set in
envs/poc.tfvars (`identity_domain_name`, subdomain of the org-owned domain; first label under the
15-char NetBIOS limit). IMMUTABLE once the managed domain is created - do not re-decide. Entra DS
requires no DNS verification for the managed-domain name.

---

### OQ-004: Region pair selection for DR

- **Raised:** Bootstrap
- **Section:** 3
- **Blocking:** No (deferrable until Section 3)
- **Priority:** Low

**Question:**
PROMPT.md suggests `eastus2` (primary) + `centralus` or `westus3` (DR). Confirm or override. Note: `westus3` does not yet have all the same services as `eastus2` — verify availability of Azure Firewall Premium, DNS Private Resolver, and Sentinel before locking in.

**RESOLVED 2026-07-30 (user ruling, recorded as ADR-069):** **`centralus` primary, `eastus2`
secondary/DR.** The pair itself is confirmed (not `westus3`); the roles are the reverse of what
`PROMPT.md:66` suggested.

**This question sat unanswered for the entire build and that is the finding, not a footnote.** It was
raised at bootstrap and, uniquely among OQ-001 through OQ-008, never received a `RESOLVED:` line.
There is no ADR anywhere in `DECISIONS.md` making the region choice. So `PROMPT.md`'s suggestion
became the configuration by default, and because no decision record existed there was nothing for
subsequent evidence to be weighed against. Four separate eastus2 capacity constraints were then found
and each was handled as a local point fix - AI Search relocated to centralus (ADR-051 correction,
deviation d7), Fabric relocated to centralus (ADR-048, deviation d6), a vCPU quota increase filed
(OQ-043), SQL and App Service gated off (ADR-031, ADR-032). Two of the four were resolved **by moving
work to centralus** and nobody asked the obvious question. The generalisable lesson: **a default that
is never converted into a decision cannot accumulate evidence against itself.**

Full change surface, interaction rulings and dispatch gate: ADR-069 and
`docs/region-flip-centralus-primary.md`. Residual verification debt: **OQ-066**.

---

### OQ-005: State storage CMK source

- **Raised:** 2026-05-05 (Session 2)
- **Section:** 10a
- **Blocking:** Yes — blocks state backend creation
- **Priority:** High

**Question:**
The Terraform state Storage Account requires CMK encryption per PROMPT.md Section 10. CMK requires a Key Vault with the encryption key. Which approach?

**Options:**
- A: Microsoft-managed keys for now (deviation, document in DECISIONS), upgrade to CMK in 10b
- B: Bootstrap a dedicated Key Vault in the Management sub today as part of 10a
- C: Use the Security sub Key Vault (but that sub is built in Section 8 — not yet)

**RESOLVED 2026-05-05 (pre-session):** Option B — bootstrap a small dedicated Key Vault in Management sub today. Adds ~15 min of work but avoids deviation marker. The Key Vault becomes part of the bootstrap layer and is later referenced (not destroyed) by Section 8.

---

### OQ-006: Terraform module organization for bootstrap

- **Raised:** 2026-05-05 (Session 2)
- **Section:** 10a
- **Blocking:** No
- **Priority:** Medium

**Question:**
The bootstrap layer (state backend, OIDC) needs to be deployed *before* the remote state exists. Where does its own state live?

**Options:**
- A: Local state, committed to a separate `bootstrap-state/` private folder (gitignored), one-time apply
- B: Local state, never committed, documented as one-time manual apply
- C: Use Azure CLI imperative commands for bootstrap, then Terraform takes over with remote state

**RESOLVED 2026-05-05 (pre-session):** Option B — local state never committed, manual one-time apply, documented in `bootstrap/README.md` with explicit "this is the chicken-and-egg layer" warning. Bootstrap state file added to `.gitignore`.

---

### OQ-007: GitHub Actions runner choice

- **Raised:** 2026-05-05 (Session 2)
- **Section:** 10a
- **Blocking:** No
- **Priority:** Low

**Question:**
For a portfolio POC repo, public vs private and runner choice?

**Options:**
- A: GitHub-hosted, public repo (free, exposes code as portfolio)
- B: GitHub-hosted, private repo (uses included minutes, can flip to public later)
- C: Self-hosted on Azure VM (overkill for POC)

**RESOLVED 2026-05-05 (pre-session):** Option B — private repo, GitHub-hosted runners. Workflows must be written so they work identically once the repo flips to public.

---

### OQ-008: OIDC SP RBAC scope-down follow-up tracking

- **Raised:** 2026-05-05 (Session 2)
- **Section:** 12
- **Blocking:** No (until Section 12)
- **Priority:** Medium

**Question:**
Per ADR-006 (this session), the OIDC SP receives Owner at Tenant Root MG to enable ALZ work without per-resource RBAC complexity. This is a deliberate POC compromise that must be scoped down before the POC is "done."

**Action required at Section 12:** Replace Tenant Root Owner with:
- Per-sub Contributor on the 5 subscriptions
- Resource Policy Contributor at the relevant MG scopes
- User Access Administrator only where role assignments are managed

This stays open through every session's start-of-session read until resolved at Section 12.

**RESOLVED-BY-DESIGN 2026-06-29 (architect, ADR-021) — pending devsecops impl + a real apply to validate:**
The least-privilege role matrix is designed and recorded in [ADR-021](DECISIONS.md) and the devsecops
implementation spec [`docs/oq-008-rbac.md`](docs/oq-008-rbac.md). Tenant Root **Owner** is replaced by:
**Management Group Contributor** @ Tenant Root Group (MG tree create/delete + subscription move);
**Resource Policy Contributor** + **User Access Administrator** @ Globaris root MG (MG-scoped policy +
role assignments, incl. PIM); **Contributor** + **User Access Administrator** on **each of the 5
subscriptions** (resource + in-sub role-assignment create/destroy, via `for_each` over a static map); and
the existing **Storage Blob Data Contributor** on the state SA (unchanged). The audit confirmed plain
Contributor is **insufficient** (the IaC creates role + policy assignments that Contributor's NotActions
forbid), so UAA + Resource Policy Contributor are required alongside it.

Honest residual broad grants (not "fully minimal"): MG Contributor @ Tenant Root Group is a tenant-wide
control-plane grant; UAA @ Globaris can create any role assignment (incl. Owner) within the hierarchy
(self-escalation risk intrinsic to a self-deploying platform SP); per-sub Contributor is broad within each
sub. The real reduction is **Owner-at-tenant-root (whole tenant, forever) → Globaris hierarchy + 5 named
subs**, losing unrestricted Owner / `elevateAccess` / implicit future-sub access.

**NOT closed yet — two follow-ups remain:** (1) devsecops implements the spec in `bootstrap/identity.tf` +
adds the 4 new subscription-ID variables; (2) `terraform validate`/`plan` cannot prove sufficiency — only a
real CI `target=all` **apply** then **teardown** with the SP holding exactly this set validates it. Any 403 →
add the precise missing scope, never revert to Owner. The **azuread Graph app permissions are separate ARM-vs-
directory and unchanged** by OQ-008. Stays referenced until the live apply/destroy passes green.

**UPDATE 2026-07-09 (architect) - scope-down is INCOMPLETE, standing Owner never removed. STILL OPEN.**
A live RBAC enumeration (`az role assignment list`, assignee = the CI SP, run 2026-07-09) surfaced the
real state versus the ADR-021 design. The verified live assignment set the CI SP holds SIMULTANEOUSLY:
- Owner @ managementGroups/globaris (org root MG)
- Owner @ managementGroups/connectivity
- Owner @ managementGroups/platform
- Resource Policy Contributor @ managementGroups/globaris
- User Access Administrator @ managementGroups/globaris
- Management Group Contributor @ Tenant Root Group
- Contributor @ one landing-zone subscription + User Access Administrator @ that same subscription
  (only one sub's direct grants were visible to the querying user; Owner @ globaris inherits Owner to all
  subs under the hierarchy regardless).

What this means: the ADR-021 scoped roles were **added ALONGSIDE**, not in **replacement of**, three
standing **Owner** grants (globaris + connectivity + platform MGs) that were never removed. The intended
substitution (drop broad Owner, stand up the scoped set) did NOT happen - the two sets coexist.
**Owner @ globaris (org root MG) is nearly as broad as the Owner @ Tenant Root this item set out to
eliminate**: full `elevateAccess`-adjacent control across the entire landing-zone hierarchy. So the real
security win of OQ-008 is not yet realized.

**Required remediation to actually realize ADR-021 (the concrete blocker keeping OQ-008 open):**
1. Run a real CI `target=all` apply THEN teardown with the scoped set present, to prove the scoped roles
   (MG Contributor @ tenant root, Resource Policy Contributor + UAA @ globaris, per-sub Contributor + UAA)
   are sufficient. This is the ADR-021 validation gate.
2. Only after that gate passes green, REMOVE the three standing Owner @ MG grants
   (globaris + connectivity + platform).
3. Risk of removing Owner prematurely: a mid-deploy 403 on a scope the scoped set missed. Mitigation - on
   any 403, add the PRECISE missing action/scope, never revert to Owner.

Note: ADR-028's exemption write does NOT depend on these Owner grants (it also resolves via Resource
Policy Contributor @ globaris), so the Owner removal above does not regress ADR-028.

---
