# DECISIONS.md — Architectural Decision Records

> Append-only log of architectural decisions made during the build.
> Each ADR follows the template below. Once written, an ADR is never edited — if a decision is reversed, write a new ADR that supersedes it.
>
> **The `Landed:` field is mandatory from ADR-068 onward** (added 2026-07-30, enforced by
> `scripts/check-adr-landed.sh` via `preflight.sh`). An Accepted decision with no landing reference
> is a decision nobody can prove was implemented. ADR-034 sanctioned `-parallelism=1` as its control
> and it was never wired into the apply step; the gap surfaced 33 ADRs later, in ADR-067, as a live
> apply failure. Record `NOT IMPLEMENTED` honestly rather than leaving the field off - an ADR openly
> marked unimplemented is a backlog item, while a silent one is a false belief. Update the field by
> appending a dated addendum, never by editing the body.
>
> ADR-001 through ADR-067 predate the field and are exempt from the check. They are listed as
> unverifiable by `check-adr-landed.sh --legacy`, which is the honest description of their state.

---

## Template

```
### ADR-XXX: [Short Title]

- **Date:** YYYY-MM-DD
- **Section:** [N from PROMPT.md]
- **Status:** Proposed / Accepted / Superseded by ADR-YYY
- **Landed:** NOT IMPLEMENTED | <commit-sha> (PR #N) | N/A - decision requires no code
- **Decision makers:** [user / claude]

**Context:**
[What's the situation that requires a decision?]

**Decision:**
[What was decided, in one or two sentences.]

**Alternatives considered:**
- [Alt A] — rejected because [reason]
- [Alt B] — rejected because [reason]

**Consequences:**
- Positive: [...]
- Negative / trade-offs: [...]
- Follow-ups required: [...]
```

---

## ADRs

<!-- Newest at the top. -->

### ADR-073: The Log Analytics soft-delete RECOVERY KEY is a FOUR-part key that includes REGION, established from Microsoft's own documentation and the REST contract, so two soft-deleted workspaces sharing one ARM resource ID are individually addressable and a `centralus` create CANNOT silently recover the `eastus2` entry. The rebuild's pre-Step-2 disposition is nevertheless PURGE BOTH via CI, because the two-entry case itself is undocumented and a recovered workspace is an ADR-067 FM-1 shape. OQ-063's single-name purge generalises to a DISCOVERY-based sweep across all five estate subscriptions, gated by containment plus a blast-radius cap, whose per-entry completion check must be a `deletedWorkspaces` RE-LIST and never an ARM GET on the shared ID. Root cause is a one-line provider-features asymmetry between `platform/security` and `platform/management`

- **Date:** 2026-08-01
- **Section:** 8 (Standard Platform Components, where the workspace lives) / 10 (Pipeline and Tooling,
  where the purge and the gate live). **Resolves OQ-069** in full. **Generalises OQ-063** and the
  step 7b mechanism ADR-066 records. **Applies ADR-062's ruling** that "an enumerated list plus a
  written promise to maintain it is not a control" to the soft-deleted-workspace class. **Applies
  ADR-067** (a rebuild creates fresh objects, it does not adopt recovered ones) as the tie-breaker in
  decision 3. **Applies ADR-068 decision 6** (estate mutation is CI-only) to reject the console path.
  Relates to ADR-069 (region flip to `centralus` primary), which is the invariant decision 6's
  assertion protects, and to ADR-061 (`PLATFORM_LAW_CUSTOMER_ID` is re-set unconditionally, never
  verified). Does NOT touch ADR-072, the attachment sweep, the refresh ceiling or the state-reset work.
- **Status:** Accepted (architect ruling; the operator gathered the live evidence and routed the
  finding rather than disposing of it operationally).
- **Landed:** NOT IMPLEMENTED. Decisions 1 and 2 are findings. Decision 3 is an operator action
  executed through an existing CI mechanism. Decisions 4 and 5 are a written spec for DevSecOps
  (`scripts/teardown-az-sweep.sh` step 7b, `scripts/teardown-common.sh` constants). Decision 6 is a
  one-block change to `platform/management/providers.tf` for the Cloud Engineer. Decision 7 is doc
  amendments. Update this field by dated addendum when each PR merges.
- **Decision makers:** claude (architect); user (gathered the live `deletedWorkspaces` evidence on
  2026-08-01, identified the shared-ARM-ID collision that OQ-069 did not anticipate, and named the
  silent-wrong-region failure mode this ADR had to rule out rather than reason about).

**Context:**

**The live evidence, read-only, 2026-08-01.** Soft-deleted Log Analytics workspaces across the five
estate subscriptions: connectivity 0, identity 0, landingzones 0, security 0, management 2. OQ-063's
security purge therefore works. The class it does not cover has exactly two members, both named
`law-platform-globaris-poc` in `rg-management-globaris-poc`: one created 2026-07-07 in `eastus2` (the
pre-region-flip build) and soft-deleted 2026-07-31, one created 2026-07-31 in `centralus` (the
just-completed build) and soft-deleted 2026-08-01.

**The finding OQ-069 did not anticipate.** Both entries carry the IDENTICAL ARM resource ID, verified
against the raw `Microsoft.OperationalInsights/deletedWorkspaces` response at api-version 2023-09-01.
Region is not a segment of a Log Analytics workspace's ARM resource ID, so the deleted-workspaces list
holds two records distinguishable only by their `location` field, not by identity.

**Why that mattered enough to route here.** `platform/management`'s Step 2 apply creates that same
workspace name in that same resource group in `centralus`. Azure's documented behaviour is that such a
create RECOVERS a soft-deleted workspace rather than creating fresh, which the rebuild runbook's Step 2
already tells the operator to expect. With two candidates sharing one ID, the feared outcome was that
the `eastus2` entry is recovered: the estate's central logging workspace silently returns in the DR
region, behind a clean plan and a green apply, undoing ADR-069 for the one workspace every spoke's
Traffic Analytics and every diagnostic setting points at. No plan-scan rule would show it. That is a
silent correctness failure, which is the one class this estate has ruled must never be reasoned about
when it can be read.

**What the documentation actually says (read live 2026-08-01, "Delete and Recover a Log Analytics
Workspace", `ms.date` 2024-10-31, page updated 2026-06-11).** Verbatim, under "Recover a workspace in a
soft-delete state": "The workspace recovery is performed by re-creating the Log Analytics workspace with
the details of the deleted workspace, including: Subscription ID / Resource group name / Workspace name
/ **Region**." The REST tab states the mechanism directly: recovery is
`PUT .../providers/Microsoft.OperationalInsights/workspaces/{WorkspaceName}?api-version=2025-07-01` with
body `{"location": "<AzureRegion>"}`, described as recovering the workspace "by recreating it with the
same name, resource group, and location". `Restore-AzOperationalInsightsWorkspace` declares `-Location`
as **Mandatory: True**. The `deletedWorkspaces` list contract confirms the records are not keyed by ARM
ID: each entry carries its own `location` and its own read-only `properties.customerId`.

**Decision:**

**1. The recovery target is selected by a FOUR-part key that INCLUDES region, and that is ESTABLISHED
from Microsoft's documentation and the REST contract, not inferred.** Subscription ID, resource group
name, workspace name and region together identify the entry to recover. Region is carried in the
request BODY, not the URL, which is precisely why two entries can share one ARM resource ID and still be
individually addressable. `platform/management` creates the workspace through
`avm-res-operationalinsights-workspace` with `location` bound to the primary region, so its create is
exactly the documented recovery PUT with `location: centralus` in the body. Under the documented
contract that PUT can only match the `centralus` entry. **The `eastus2` entry cannot be the recovery
target of a `centralus` PUT.** The severe silent failure mode is not supported by the contract, and
this ADR records that as a finding so it is not re-feared later.

**2. What is NOT established, stated as a limit rather than glossed.** Microsoft documents the recovery
key. It does NOT document the case where `deletedWorkspaces` holds two entries under one ARM resource
ID. Nothing on Learn addresses it, and I will not assert service behaviour in an undocumented case.
Two residual outcomes remain possible for a `centralus` PUT, and **neither of them is a wrong-region
recovery**: (i) the PUT matches on region and recovers the `centralus` entry, which is the documented
contract and the expected outcome; or (ii) the PUT is rejected as a name conflict, which is the
documented outcome for a create against a reserved name that does not constitute a recovery (the
troubleshooting section "Resolve the 'This workspace name is already in use' or 'conflict' error
message", whose stated resolution is recover, then permanently delete, then create). Both are loud.
(i) is a green apply with a correct-region workspace carrying a stale `customerId` and old data, which
the estate already absorbs because PC-2X re-sets `PLATFORM_LAW_CUSTOMER_ID` unconditionally right after
Step 2 (ADR-061). (ii) is a hard failure at Step 2 with a documented remedy. **The unverifiable case
does not contain the severe case.** A related documented fact that does NOT save us and should not be
misread as a safeguard: a recovery whose resource group no longer exists fails 404, and
`rg-management-globaris-poc` is currently gone, but Terraform creates the RG earlier in the same apply,
so the PUT will be evaluated rather than 404ing.

**3. The pre-Step-2 disposition: PURGE BOTH ENTRIES, through CI, before `platform/management` is
planned or applied.** Decision 2 leaves a coin-flip between (i) and (ii), and this decision removes the
coin rather than betting on it. After both entries are purged the name is released and Step 2's PUT is
an unambiguous fresh create, which is what the estate actually wants for three independent reasons.
First, ADR-067's teardown-and-restart posture: a rebuild creates fresh objects, it does not adopt an
object whose real history the state does not reflect, which is the FM-1 shape. Second, a recovered
workspace keeps its original `customerId`, and that is the exact value the NWTA naming inheritance in
`docs/estate-bom.md` finding 1 (re-attributed to Traffic Analytics by ADR-072 decision 1) rides on;
purging removes the question instead of managing it. Third, the documentation is explicit that installed
solutions and linked services are permanently removed at delete time and are NOT recovered, so a
recovered workspace is a partially reconstituted object in every case, never a restored one. The cost is
that up to 14 days of teardown-era log data are destroyed permanently. That cost is accepted and
intended: this is a POC estate that has just been torn down, the data has no consumer, and ADR-066's
greenfield-proof posture requires the estate to be genuinely greenfield.

**4. The generalisation: step 7b becomes DISCOVERY-based across all five estate subscriptions, with a
four-part safety bar.** This is the ADR-062-shaped fix OQ-069 option B anticipated, now written against
real objects rather than assumed ones. DevSecOps owns it. The spec:

- **Discovery.** Iterate `teardown_subscriptions()` (all five), not `SECURITY_SUBSCRIPTION_ID`. Call
  `az monitor log-analytics workspace list-deleted-workspaces --subscription <sub>` with NO name
  filter, projecting `[].{name:name, location:location, id:id, customerId:properties.customerId}`.
  `SECURITY_LAW_WORKSPACE_NAME` and `SECURITY_LAW_RESOURCE_GROUP_NAME` stop being purge selectors.
  A failed list stays FAIL LOUD (section 9.4, unchanged).
- **Safety bar gate A, containment.** Each discovered entry must pass
  `is_estate_owned --resource-id "$law_id"`, the existing T1 predicate, which extracts the
  `/resourceGroups/<rg>/` segment from the ID string and tests it against the same naming pattern
  `RG_SWEEP_QUERY` encodes. String-based containment is the correct test here precisely BECAUSE the
  resource group is already gone, so no live lookup is possible. An entry that fails the gate is
  SKIPPED with a `::warning::` naming it, not deleted and not a hard failure: a foreign workspace in
  an estate subscription is not this script's business, but it must be visible. This reuses the
  containment rule the FIX-1/2/4 sub-steps and the ADR-072 attachment sweep already share rather than
  inventing a second one.
- **Safety bar gate B, blast-radius cap.** If discovery returns more than a small fixed number of
  purge-eligible entries across the whole estate (specify 10; DevSecOps may argue the number, not the
  existence of the cap), ABORT the step with `::error::` and purge nothing. A sweep that suddenly finds
  forty workspaces is a signal that the containment predicate or the subscription list is wrong, not an
  instruction to permanently destroy forty workspaces. This is the direct answer to "a discovery-based
  purge that over-reaches would permanently destroy a workspace that something still needs": containment
  bounds WHICH, and the cap bounds HOW MANY, and only both together make the mechanism safe to run
  unattended.
- **Safety bar gate C, deterministic selection, and it is a REAL DEFECT in the current step.**
  `az monitor log-analytics workspace recover` takes only `--workspace-name` and `--resource-group`;
  verified against the current CLI reference, **it has no `--location` parameter at all**, so it
  physically cannot address one of two entries that share an ARM ID. The recover call must therefore
  become the REST PUT with an explicit `location` body, issued through `az rest` at
  `SECURITY_LAW_API_VERSION` (already pinned `2025-07-01`, which matches the current documented
  version; rename the constant, it is no longer security-specific). One purge cycle is keyed on the
  pair `(id, location)`, with `customerId` logged as evidence.
- **Safety bar gate D, the per-entry completion check, and this is the second REAL DEFECT.** The
  current step confirms the purge with `confirm_gone_or_fail_primary` against an ARM GET on `law_id`.
  That URL is keyed on the ARM ID ALONE and therefore cannot distinguish the two entries: after purging
  one of them the GET returns 404 while the other is still soft-deleted, producing a FALSE "purged"
  confirmation. The completion check must become a `deletedWorkspaces` RE-LIST asserting that no entry
  with that `(id, location)` pair remains. Fail loud on a remaining pair, unchanged from today (there is
  still no separate Phase 3 VERIFY step for this class).
- **Ordering, mandatory.** Purge cycles for entries sharing an ARM ID must be STRICTLY SEQUENTIAL: fully
  recover, force-delete and re-list-confirm entry A before recovering entry B. Two recoveries of the
  same ARM ID must never be in flight, because after recovering A a LIVE workspace occupies that ID and
  a PUT for B would be a location change on an existing resource, which ARM rejects.
- **Placeholder resource group.** The existing recreate-then-delete dance is retained and generalised:
  the placeholder RG name comes from the entry's own ID, not a constant, and its location may be taken
  from the first entry's location. A resource group's location is independent of the locations of the
  resources inside it, so ONE placeholder RG can serve both entries; DevSecOps may rely on that only
  after verifying it live in the run log, otherwise create one placeholder per cycle and wait for each
  delete to complete between cycles.

**5. The residual gates.** (a) A new pre-clearance gate **PC-1M** generalises PC-1SEC: before Step 2,
`deletedWorkspaces` must read EMPTY in all five estate subscriptions, not only security, and PC-1M
BLOCKS Step 2 exactly as PC-1SEC blocks Step 3. (b) A cheap post-apply region assertion is added
immediately after Step 2's apply, alongside the PC-2X `workspace show` that already runs at that exact
point: assert the workspace's `location` reads `centralus`. It is adopted as a SECONDARY detector, not
as the control; decision 3 is the control, and an assertion that fires after the workspace and its
diagnostic settings exist is a detector by definition. It costs one query and it is the only thing that
would catch a wrong-region workspace at all.

**6. The root cause, and it is one block.** `platform/security/providers.tf` sets
`features { log_analytics_workspace { permanently_delete_on_destroy = true } }`.
`platform/management/providers.tf` has a bare `features {}`. That asymmetry is the entire explanation
for why the security subscription holds zero soft-deleted workspaces and management holds two. Exactly
two roots in this repo declare a Log Analytics workspace, verified by search, and only one sets the
flag. The Cloud Engineer adds the same block to `platform/management/providers.tf` so the platform
workspace purges natively on its own `terraform destroy`, which makes decision 4 a genuine backstop for
this workspace rather than the only mechanism that will ever reach it. **The general rule, which is the
part that outlives these two workspaces: any root that declares a Log Analytics workspace must set
`permanently_delete_on_destroy = true` in its own provider features block.** That is a reviewable
property of a root's `providers.tf`, checkable at review time against the roots that exist, which is
what ADR-062 means by a control as opposed to a list.

**7. Documentation corrections, both mandatory before the rebuild is run.** (a) The rebuild runbook's
Step 2 currently tells the operator to expect the platform workspace as "the documented soft-delete
recovery PUT, not a fresh workspace". Once decision 3 lands that sentence is WRONG, and an operator
following it would read a real anomaly as expected. It must be amended by dated addendum to say the
opposite: with PC-1M holding, the add is a genuinely fresh create, and any evidence of a recovery is a
STOP. (b) PC-1SEC's entry gains PC-1M as its estate-wide generalisation. Both are technical-writer or
Cloud Engineer edits, not architect ones.

**Alternatives considered:**

- **Purge only the `eastus2` entry, leaving the correct-region candidate to be recovered.** Rejected.
  It reduces the case to the documented single-candidate path, which is genuinely safe on the region
  question, but it deliberately CHOOSES a recovery: the stale `customerId`, the partially reconstituted
  object, and the FM-1 shape ADR-067 rules against, for no benefit over purging both. The data it
  preserves has no consumer.
- **Recover deliberately, then verify the region afterwards.** Rejected on two grounds. It makes the
  rebuild depend on the exact undocumented behaviour decision 2 declines to assert, and the CLI verb
  that would perform it has no `--location` parameter, so it cannot even express which entry to
  recover. Verifying afterwards is decision 5(b), which is worth having as a detector and is not worth
  building a plan around.
- **Accept, and gate only on a post-apply region assertion.** Rejected as the primary control, adopted
  as the secondary one. A detector that fires after the workspace exists leaves an incorrect-region
  workspace live with diagnostic settings already pointed at it, and the remedy at that point is a
  destroy and a second soft-delete, which is the same problem one cycle later.
- **Purge them by hand from the portal.** Rejected. Teardown and estate mutation are CI-only by
  standing ruling, and this is exactly the ADR-068 decision 6 shape: if a mutation must happen before a
  code change lands, it is an explicitly authorised, dated, scoped operator exception, not a console
  habit. Decision 3 routes it through the existing `teardown.yml` `mode=az-sweep` dispatch, which is
  idempotent by construction (every class in that script treats "not present" as success) and already
  carries its own re-run pre-clearance in `docs/preclearance/teardown-az-sweep-rerun.md`.
- **Keep step 7b enumerated and just add the platform workspace name next to the security one.**
  Rejected, and it is the specific thing ADR-062 forbids. A two-item list is the same mechanism as a
  one-item list, and this class has now demonstrated it grows. It would also leave both defects in
  gates C and D unfixed, since neither is about which name is listed.
- **Rely on decision 6 alone and skip decision 4.** Rejected. The provider feature only fires on a
  `terraform destroy` that actually runs, and `mode=az-sweep` (the state-gone fallback, ADR-065
  decision 4) never runs one. The two entries currently sitting in the management subscription are the
  proof: they exist because a path that does not run `terraform destroy` deleted the resource group out
  from under the workspace.

**Consequences:**

- Positive: the load-bearing question is answered from Microsoft's own contract rather than from
  reasoning, and the answer is that the severe silent failure mode is not reachable. That finding is now
  citable instead of being re-derived under time pressure at the next rebuild.
- Positive: two real defects in the EXISTING step 7b are exposed by the two-entry case and specified
  for fix, independent of the generalisation. The ARM-GET completion check can currently return a false
  "purged" whenever more than one entry shares an ID, and the CLI recover verb cannot select between
  them at all.
- Positive: the purge stops being a single-instance enumerated list and gains a containment predicate it
  shares with every other sweep in the script, plus a blast-radius cap that bounds the one way a
  discovery sweep can do irreversible harm.
- Positive: the root cause is a one-block asymmetry with exactly two candidate roots, so it is closable
  in full rather than mitigated.
- Negative / trade-off: decision 3 permanently destroys up to 14 days of log data from the torn-down
  estate. Accepted explicitly above; it is unrecoverable once done.
- Negative / trade-off: the rebuild gains a blocking pre-Step-2 gate (PC-1M) and one extra CI dispatch
  before Step 2 can start. That is real added time on the rebuild day and it is the price of Step 2
  being an unambiguous create.
- Negative / trade-off: the blast-radius cap in gate B is a magic number. A cap that is too low turns a
  legitimate large teardown into a manual escalation. That is the correct direction to fail, and the
  number should be revisited if it ever fires.
- Follow-ups required: (1) DevSecOps implements decision 4 in `scripts/teardown-az-sweep.sh` and the
  constants in `scripts/teardown-common.sh`. (2) Cloud Engineer implements decision 6 in
  `platform/management/providers.tf`. (3) Operator executes decision 3 through CI and records PC-1M's
  result in the rebuild pre-clearance. (4) Technical-writer or Cloud Engineer lands decision 7's two
  runbook amendments as dated addenda. (5) OQ-069 is resolved by this ADR; any further finding about
  the state storage account's stale `ip_rules` entry stays in its own open item and is untouched here.

### ADR-072: A cross-root RP-ATTACHED OBJECT is owned by the root that DECLARES the attachment, never by the root that owns the container it lands in. `prevent_deletion_if_contains_resources` stays TRUE on `platform/management` and is rejected permanently; the three orphans are cleared by a PRE-DESTROY ATTACHMENT SWEEP whose ordering constraint is the exact MIRROR of ADR-063 G-1; two of the three were mis-attributed to AMBA and are in fact Traffic Analytics; and ADR-066's designation of `mode=terraform` as the primary `target=all` path is AMENDED to exclude `platform/management-groups`

- **Date:** 2026-08-01
- **Section:** 8 (Standard Platform Components, where the shared workspace lives) / 9 (Landing Zone
  Spokes, where every attachment is declared) / 10 (Pipeline & Tooling, where the sweep runs).
  **AMENDS ADR-066** decision 1 and INV-1 (the eleven-layer `mode=terraform` primacy at `target=all`).
  **EXTENDS ADR-063** decision 5 / finding G-1 with its mirror-image ordering class, and extends
  ADR-071's Phase 0.5 precascade shape with a second, differently-ordered sweep. **REJECTS** for
  `platform/management` the provider-feature trade that ADR-066's 2026-07-30 addendum item 3 accepted
  for `platform/security`, and says why the two cases are not alike. Corrects `docs/estate-bom.md`
  finding 1 and the 2026-08-01 operator WORKLOG entry on provenance. Builds on ADR-057 (the governing
  teardown-completeness principle), ADR-062 (discovery beats enumeration), ADR-038 (AVM consumed
  directly in composition roots). Does NOT supersede ADR-071, ADR-070 or ADR-068.
- **Status:** Accepted (architect ruling; the operator brought two teardown defects from run
  `30685705802` and then narrowed the referral to the ownership and blast-radius questions, routing the
  workflow-mechanics half to DevSecOps in parallel).
- **Landed:** NOT IMPLEMENTED. Decision 4 is a written spec for DevSecOps (one shared function, one new
  chain-positioned teardown job). Decisions 1, 2, 3, 5 and 6 are rulings and doc amendments that need no
  `.tf` or `.yml`. Update this field by dated addendum when the DevSecOps PR merges.
- **Decision makers:** claude (architect); operator (measured the live estate, produced the three-object
  inventory, and identified the cross-root coupling as the question worth answering).

**Scope note, stated first because it bounds everything below.** This ADR rules on OWNERSHIP and on
WHICH MECHANISM owns which root. It does NOT rule on the `platform/management-groups` refresh-stall
mechanism, the six-hour job and OIDC ceilings, any `terraform` invocation flag including
`-refresh=false`, Phase 4 state-blob eligibility, the run-level conclusion signal, or whether a
finishing dispatch is warranted. Those were referred to DevSecOps in the same pass and are deliberately
absent here so the two lanes cannot produce conflicting rulings. Decision 6 touches ADR-066 because
"which mechanism destroys which root" is a topology decision; its workflow expression is not.

**Context:**

Teardown run `30685705802` (`target=all mode=terraform remove_mg_hierarchy=true`) failed
`platform/management`'s Phase 1 destroy. The resource-group delete was refused by the provider's
`prevent_deletion_if_contains_resources` guard, and exactly three resources remained in
`rg-management-globaris-poc` after the Log Analytics workspace itself had destroyed cleanly:

| Object | Attributed in the brief and the BOM to | Actually created by, verified |
|---|---|---|
| `Microsoft.Insights/dataCollectionEndpoints/NWTA-<derived from LAW customerId>` | AMBA | **Traffic Analytics** |
| `Microsoft.Insights/dataCollectionRules/NWTA-<derived from LAW customerId>` | AMBA | **Traffic Analytics** |
| `Microsoft.OperationsManagement/solutions/ContainerInsights(<platform LAW name>)` | the AKS monitoring addon in `landing-zones/bank-app-p1` | confirmed, and the mechanism is narrower than stated |

**The provenance correction matters more than it looks, because it changes who owns the cleanup.**
Microsoft's own "Manage virtual network flow logs" reference states, verbatim: *"Traffic analytics
creates and manages data collection rule (DCR) and data collection endpoint (DCE) resources in the same
resource group as the Log Analytics workspace, prefixed with NWTA. If you perform any operation on these
resources, traffic analytics might not function as expected."* (learn.microsoft.com,
`azure/network-watcher/vnet-flow-logs-manage`, web-verified 2026-08-01.) The estate enables Traffic
Analytics on four spoke flow logs, each pointing at the platform workspace:
`landing-zones/{corp-a1,online-p1,bank-app-p1,bank-data-p1}/dns_links.tf`, every one of them a
`traffic_analytics` block carrying `workspace_id = var.platform_law_customer_id` and
`workspace_resource_id = var.platform_law_workspace_id`. `corp-a2` has the block commented out (no
centralus workspace at the time). Traffic Analytics creates ONE NWTA pair per workspace, not per flow
log, which is exactly why the live count was one DCE and one DCR rather than four of each. So the two
`Microsoft.Insights` objects are **not AMBA and have nothing to do with `platform/management`'s own
declarations at all** - they are a side effect of four SPOKE roots' configuration, landing in the
platform root's resource group.

The third object has the same shape and a narrower mechanism than "the AKS addon".
`landing-zones/bank-app-p1/aks.tf` sets `addon_profile_oms_agent` with **`use_aad_auth = false`**, the
legacy workspace-key Container Insights path, chosen deliberately and documented in the file (the
module's `onboard_monitoring` path "drags in managed Prometheus resources - deferred to the B7 O&M
wave"). It is specifically the legacy path that materialises a
`Microsoft.OperationsManagement/solutions` object in the workspace's resource group; the
`use_aad_auth = true` MSCI data-collection-rule path does not. That is a live, revisitable estate choice
with a teardown cost nobody priced at the time.

**So all three orphans are one class, not two.** Every one of them is an object that an Azure resource
provider created inside `platform/management`'s resource group as a side effect of a configuration
declared in a DIFFERENT root, and that neither root's `terraform destroy` accounts for: the declaring
root does not manage it, and the container-owning root does not know it exists. The provider error names
`prevent_deletion_if_contains_resources = false` as the remedy, which is the same category of trade as
the `permanently_delete_on_destroy` decision recorded in ADR-066's 2026-07-30 addendum item 3.

**And the class will recur on every teardown, unchanged, because nothing in the estate expresses the
coupling.** `platform/management`'s workspace is consumed by at least six declarations across five other
roots. The only expression of that surface today is two output values passed as spoke inputs.

**Decision:**

**1. The provenance record is corrected. The two `Microsoft.Insights` NWTA objects are Traffic
Analytics, not AMBA.** `docs/estate-bom.md` finding 1 (and its section 1.4 note and its closing summary
bullet) and the 2026-08-01 operator WORKLOG entry both attribute them to AMBA. The BOM's substantive
observation is CORRECT and stands - the names inherit volatility from the workspace `customerId` with no
`random_*` resource anywhere in the chain, which is a real and well-found gap. Only the attribution
changes, and it changes the answer to "who cleans them up": under decision 5 they belong to the four
Traffic-Analytics-enabled spoke roots, not to the AMBA module in `platform/management`. Amend by dated
addendum in both files; do not edit the original finding text.

**2. `prevent_deletion_if_contains_resources = false` is REJECTED for `platform/management`, and the
rejection is permanent rather than "not yet".** Five reasons, the first two decisive on their own:

- **It is a provider-level, root-wide, forever setting, on the one root where the guard is doing the
  most work.** Like `permanently_delete_on_destroy`, it lives in the `provider "azurerm" { features {} }`
  block and therefore applies to every resource group that root manages, including groups added later,
  including a mis-targeted destroy. `platform/management` is the estate's SHARED TELEMETRY root: its
  resource group is by design the place other roots' resource providers attach things. It is, of every
  resource group in the estate, the one most likely to contain objects this root does not own. Disabling
  the "am I about to delete something I do not own" check precisely there is disabling it where it is
  most load-bearing.
- **It suppresses the signal without touching the cause.** The three objects are created by other roots
  and would be created again on the next rebuild. The flag does not remove them, does not stop them
  appearing, and does not make anyone aware of them; it makes the destroy stop reporting them. This
  estate has already ruled once that a control which cannot discover what nobody told it about is not a
  control (ADR-062). A guard that has been configured to stop firing is the same defect with the
  polarity reversed.
- **The vendor's own description is the blast-radius argument.** With the flag false, Terraform "will
  succeed with the destruction of the resource group and any resource that happens to be part of it".
  That converts an RG delete from *delete what I own* into *delete whatever is here*, which is exactly
  the name-and-containment ownership semantics ADR-063 decision 6 was written to replace with an explicit
  predicate.
- **The strongest-sounding argument for it is actually against it.** Phase 2's API-level `az group
  delete` already bypasses the guard, which is how the orphans were in fact removed on 2026-08-01. The
  capability therefore already exists in the belt. Buying it a second time at Phase 1, at the price of a
  permanent root-wide widening, purchases no new capability at all.
- **The `platform/security` precedent does not transfer, and the difference is principled.**
  `permanently_delete_on_destroy` was accepted there because the object it acts on is one this root
  DECLARES and OWNS (the Security workspace), the widening is confined to future objects of that same
  declared type, and the alternative was a documented 90-day rebuild blocker (OQ-063). Here the objects
  are ones this root explicitly does NOT own, the widening is unbounded in type, and the alternative is
  a bounded sweep that already has a proven shape in this repository. Same syntax, opposite trade.

**3. "Phase 1 fails, Phase 2 catches it, the estate ends clean" is REJECTED as the standing design.**
It is an accurate description of what happened and a perfectly good description of a BELT. It is not
acceptable as the DESIGN, for one reason that is a first-class user requirement and one that is a
signal-integrity argument:

- ADR-066 INV-1 exists because the user required that a full teardown run every per-layer destroy and
  that each go green, so that a real regression in any layer is visible as that layer's red rather than
  masked. A `platform/management` that is red on every single teardown by construction has a red that
  carries zero information. The next genuine management-layer regression arrives indistinguishable from
  the standing one, which is the exact masking failure INV-1 was written to prevent, reintroduced at a
  different layer.
- A design whose correctness depends on a downstream belt catching a predictable upstream failure has
  made the belt load-bearing. ADR-066 decision 3 deliberately DEMOTED az-sweep to a thin remnant catch
  precisely so it would stop being the mechanism. Accepting this would promote it back for one layer,
  silently.

Phase 1 must therefore stop failing. Decision 4 is how.

**4. The mechanism is a PRE-DESTROY ATTACHMENT SWEEP, and its ordering constraint is the exact MIRROR
of ADR-063 G-1. This is the design content of this ADR and the reason it is not simply "add another
precascade".**

The estate now has two sweep-ordering classes, and they pull in opposite directions. Naming both is what
stops the next implementer putting the second one in the first one's phase:

| | **G-1 class** (ADR-063 decision 5, ADR-071 decision 4b) | **Attachment class** (this ADR) |
|---|---|---|
| Example | resource-scoped diagnostic settings; `diag-aa-to-law` | NWTA DCE/DCR; the ContainerInsights solution |
| Keyed to | its HOST resource's URI | its CONTAINER resource group |
| Fails if swept too LATE | host gone, object unreachable and undiscoverable (403, not 404) | container-delete refused, or the object is cascaded away silently |
| Fails if swept too EARLY | nothing | the still-live creator's RP simply RECREATES it |
| Correct position | **before** its host is destroyed (Phase 0.5, ahead of Phase 1) | **after** every declaring root is destroyed and **before** the container-owning root destroys |

The attachment class cannot go in Phase 0.5. Traffic Analytics is documented as actively MANAGING its
NWTA pair, and the AKS addon owns its solution object; deleting either while its creator is still live
invites immediate recreation, and Microsoft explicitly warns that operating on the NWTA resources while
Traffic Analytics is live breaks it. The window is genuinely mid-chain.

Spec for DevSecOps, precise enough to implement without re-deriving:

- **Position.** One new job in the ADR-066 serialized `target=all` chain, inserted between `identity`
  and `management`. The existing reverse-dependency order (`synthetic` -> `bank-data-p1` ->
  `bank-app-p1` -> `online-p1` -> `corp-a2` -> `corp-a1` -> `security` -> `connectivity` -> `identity`
  -> `management` -> `management-groups`) already places all four Traffic-Analytics spokes and
  `bank-app-p1` before that point, so a single insertion satisfies both ordering constraints with no
  re-linearization. Call it Phase 1.5 for symmetry with 0.5, or whatever name reads best in the file;
  the position is the requirement, the label is not.
- **Gating.** `target=all` and `mode=terraform` only, mirroring `databricks-precascade`. `mode=az-sweep`
  is deliberately NOT wired: Phase 1 never runs there and the API-level RG delete already cascades these
  objects, so a second mechanism would be a duplicate rather than a fix. Same reasoning, same words, as
  the Databricks and ADR-071 precascade headers.
- **Not a gate.** A failure is loud but does not skip `platform/management`'s destroy. Identical to
  ADR-066 decision 4's wiring and ADR-071 decision 4b: the layer must still run, and a residual must
  surface as a loud Phase 3 VERIFY failure rather than a silently skipped mandatory layer.
- **Scope, as a three-part predicate, in this order.** (a) CONTAINMENT: the resource group is
  estate-owned, which `is_estate_owned` already decides (ADR-063 decision 6 T1(a)). (b) TYPE: exactly
  `Microsoft.Insights/dataCollectionEndpoints`, `Microsoft.Insights/dataCollectionRules`,
  `Microsoft.OperationsManagement/solutions`. (c) For the two `Microsoft.Insights` types only, NAME
  PREFIX `NWTA-`, which is Microsoft's documented and stable prefix for this class. The type filter is
  what keeps this a sweep of a named class rather than a delete-everything-here, which is what decision
  2 rejected; do not replace it with a bare RG enumeration.
- **Discovery, not enumeration.** List by type within the resource group and delete what is found. Do
  not hardcode the derived names: the whole point of `docs/estate-bom.md` finding 1 is that the NWTA
  names are non-deterministic by inheritance from a regenerated workspace `customerId`, so any
  name-literal list is wrong the first time the workspace is recreated.
- **Confirm-GET after every delete**, via the existing `confirm_gone_or_fail_primary` primary-evidence
  helper. Auth-fail-loud throughout: a failed LIST is never read as "nothing there" (ADR-062 section
  9.4). No new conventions.
- **Shared function in `scripts/teardown-common.sh`**, called from the new script, exactly as
  `databricks_force_delete_cascade` and ADR-071's `sweep_resource_diagnostic_settings` are shared, so a
  future second call site cannot drift.
- **Acceptance.** The next `target=all mode=terraform` teardown shows `platform/management`'s Phase 1
  destroy GREEN with no `prevent_deletion_if_contains_resources` error, and Phase 2 finds nothing to
  catch in that resource group.

**5. THE GENERAL RULE, which is what the operator actually asked for and what will still be true after
this teardown is forgotten.**

> **The attachment-declares-ownership rule.** When an Azure resource provider or a platform addon
> creates an object inside root B's container, or attached to root B's resource, as a side effect of a
> configuration declared in root A, that object belongs to **root A** - the root that declared the
> attachment. Root B owns the container. It does not own the contents.

Three reasons, and the third is the one that makes it binding rather than tasteful:

- **Only root A knows the object exists.** Root A's author wrote the line that causes it. Root B cannot
  enumerate what other roots have attached to it except by live discovery, and ADR-062 already ruled
  that a class list maintained by a written promise is not a control.
- **Only root A's lifecycle explains the object's lifecycle.** It appears when root A applies and should
  disappear when root A destroys. Root B's lifecycle is orthogonal: `platform/management` can be
  redeployed end to end without any spoke changing.
- **The alternative IS the flag decision 2 rejects.** "Root B owns everything in its resource group" is
  precisely `prevent_deletion_if_contains_resources = false` written as a principle. Having rejected the
  flag, the estate is not free to adopt its semantics under another name.

Corollaries, which is where the rule becomes actionable:

- **C1. A root that attaches to another root's shared resource must declare the attachment's CLEANUP,
  not just the attachment.** Where the provider models the side-effect object, declare it and let
  Terraform own it. Where the RP owns it and Terraform structurally cannot (both classes here), the
  root's teardown obligation is discharged by the decision-4 sweep, and the root's own README must say
  which of its declarations produces which side-effect object, in whose resource group. An attachment
  whose cleanup is nobody's stated job is an incomplete design, not an operational surprise.
- **C2. A shared platform resource is an ATTACHMENT SURFACE and must be documented as one.** The
  platform workspace currently expresses its surface as two output values. Add to
  `platform/management/README.md` and to `ARCHITECTURE.md` a table with one row per consumer:
  consuming root, what it attaches, what side-effect object the RP creates, in whose resource group, and
  which mechanism removes it. Known rows today: four spokes' Traffic Analytics (one shared NWTA DCE +
  DCR pair, in the platform RG, removed by the decision-4 sweep); `bank-app-p1`'s AKS Container Insights
  addon (one `Microsoft.OperationsManagement/solutions` object, in the platform RG, removed by the same
  sweep); and the diagnostic settings every root points at the workspace (removed by the ADR-071 Phase
  0.5 sweep, different ordering class, cite it as such).
- **C3. Where the platform offers an attachment mode that creates NO cross-root object, prefer it, but
  never flip one mid-estate inside a teardown ADR.** Container Insights has exactly such a choice:
  `use_aad_auth = true` uses the MSCI data-collection-rule path and creates no
  `Microsoft.OperationsManagement/solutions` object at all. The estate chose `false` for stated build
  reasons. Changing it is a live-behaviour change to a deployed workload, needs a plan bar, and belongs
  to a wave. **Raised as OQ-068, explicitly not decided here.**
- **C4. Traffic Analytics has no such alternative, so for it the sweep is the PERMANENT mechanism, not a
  stopgap.** Microsoft creates and manages the NWTA pair and warns against operating on it. There is no
  configuration that suppresses it while Traffic Analytics is on, and no Terraform resource that can own
  it. Do not spend effort looking for one.

**6. ADR-066's designation of `mode=terraform` as the primary `target=all` path is AMENDED to exclude
`platform/management-groups`. That root is destroyed by the Phase 2 management-group cascade.**

Taken as a design ruling rather than left to DevSecOps because it decides WHICH MECHANISM OWNS WHICH
ROOT, which is the same ownership question as decision 5, one level up. The mechanics of why the
terraform path could not complete are DevSecOps's and are deliberately not restated.

- **`platform/management-groups` is structurally unlike the other ten roots.** Its objects are
  overwhelmingly CHILD objects of eleven container scopes, and the ARM control plane offers a cascading
  container delete as the natural unit of removal. The other ten roots hold resources with no cascading
  container above them inside the root's own scope, so per-object destroy there is both faithful and
  necessary. ADR-066's governing argument - owning providers should destroy their own objects and
  az-sweep should be a belt - is correct exactly where per-object destruction is the only mechanism
  available. It does not generalise to a root where the platform provides a correct bulk primitive.
- **The cascade already exists, is already gated, and is already ordered.** Phase 2 step 4 deletes the
  hierarchy bottom-up via `MG_DELETE_ORDER` under `remove_mg_hierarchy`, and Phase 0 already performs
  the ADR-063 G-1 extension sweep at every MG scope BEFORE any of it. This decision selects an existing,
  designed, reviewed mechanism. It does not invent one.
- **The estate has live evidence that the cascade discharges the obligation that actually matters.**
  Across the 2026-07-30 and 2026-07-31 rebuild cycles, Step 1 planned and applied **exactly 537**
  objects following an MG-tree deletion, with no `already exists` collision on any policy definition or
  set definition. By ADR-057's governing principle - if leaving it makes the next greenfield apply fail
  or drift, teardown owns it - the cascade owns it. **Stated precisely and not over-claimed:** this is
  evidence that the objects do not COLLIDE with a rebuild, which is the operative property. It is not a
  proof that every ARM object is purged, and this ADR does not claim one.
- **Single-root `terraform destroy` of `platform/management-groups` remains supported and available**
  for an operator who wants provider-faithful, state-exact removal and is willing to own the wall clock.
  Nothing about that path is withdrawn.
- **The honest consequence, which the user should see stated rather than discover.** ADR-066 INV-1 was
  "all eleven Phase-1 layer destroys run and go green". It becomes **INV-1'**: *every root that Phase 1
  owns runs and goes green; `platform/management-groups` is owned by the Phase 2 cascade and its
  completion is asserted by Phase 3 VERIFY.* That is a real narrowing of a requirement the user stated
  as first-class, and it is bought deliberately. The alternative is worse and less honest: leaving a
  layer designated as the primary path when it does not complete, which produces a permanently red job
  and is the same information-free red that decision 3 rejects for `platform/management`.

**Alternatives considered:**

- **`prevent_deletion_if_contains_resources = false` on `platform/management`.** Rejected, decision 2,
  five reasons.
- **Accept the standing "Phase 1 red, Phase 2 catches".** Rejected, decision 3. It is the correct
  description of the belt and an unacceptable description of the design.
- **Declare the three objects in Terraform so a root owns them.** Rejected on verified fact for two of
  three and on judgement for the third. The NWTA DCE/DCR are created and managed by Traffic Analytics
  with Microsoft warning against operating on them, so no root can own them. The ContainerInsights
  solution is modelable (`azurerm_log_analytics_solution`), but it is RP-created first, so a declaring
  root would meet `already exists` on every apply - the ADR-071 class, manufactured deliberately - and
  the only root entitled to declare it under decision 5 is `bank-app-p1`, which would need a
  cross-subscription provider alias into the management subscription to do it. Worse in every dimension
  than a sweep.
- **A config-driven `import` of the three objects into `platform/management`.** Rejected on the standing
  rule (ADR-067 addendum, LESSON 52) and on decision 5: importing them would make `platform/management`
  the owner of objects other roots create, which is the ownership error this ADR exists to correct,
  written into state.
- **Put the sweep in Phase 0.5 alongside the ADR-071 diagnostic precascade.** Rejected, decision 4: the
  ordering constraints are mirror images. Phase 0.5 runs while creators are live, and a live Traffic
  Analytics or AKS addon simply recreates what Phase 0.5 deleted.
- **A bare "delete everything in `rg-management-globaris-poc` before destroying it" sweep.** Rejected: it
  is `prevent_deletion_if_contains_resources = false` implemented in bash, with the same blast radius and
  none of the type discipline. The three-part predicate in decision 4 is the point.
- **Leave `platform/management-groups` on the terraform path and tune it.** Rejected as a design
  position, decision 6: a mechanism that is over its budget by a multiple is not tuned into range, and
  the platform already offers the right primitive. The tuning question itself belongs to DevSecOps and
  this ADR takes no position on any specific flag.

**Consequences:**

- Positive: `platform/management`'s Phase 1 destroy can go green again, restoring the information
  content of its red, without widening any root's destroy blast radius.
- Positive: the estate gains a named, citable ownership rule for a coupling that will recur with every
  future addon that attaches to the shared workspace, plus the mirror-image ordering table that stops
  the next sweep being placed in the wrong phase.
- Positive: the provenance correction removes a wrong causal story from the BOM before the BOM is used
  as the rebuild regression baseline, which is the one job the BOM exists to do.
- Negative / trade-off: ADR-066 INV-1 narrows to INV-1' (decision 6). One layer is no longer proven by
  its own green job.
- Negative / trade-off: the estate now runs two ordering-opposite sweeps around Phase 1. That is
  genuine added complexity in `teardown.yml`, and it is the price of the two classes being genuinely
  different rather than one class implemented twice. The decision-4 table exists so the complexity is
  legible.
- Negative / trade-off: the decision-4 sweep is discovery-based within a fixed type list, so a NEW
  cross-root attachment of a type not in that list will still surprise a teardown once. C1 and C2 are
  the controls that shrink that window; they are documentation obligations, which ADR-062 correctly
  distrusts. The honest position is that the type list is a smaller enumerated surface than the
  alternative, not that enumeration was avoided.
- Follow-ups required: (1) DevSecOps implements decision 4. (2) Cloud Engineer or technical-writer lands
  C2's attachment-surface table in `platform/management/README.md` and `ARCHITECTURE.md`, and the
  decision-1 dated addenda in `docs/estate-bom.md`. (3) OQ-068 (the Container Insights `use_aad_auth`
  trade) is a wave decision, not a teardown one. (4) OQ-069 records two soft-deleted Log Analytics
  workspaces found live in the management subscription on 2026-08-01 and the coverage gap they expose;
  it must be dispositioned in the rebuild pre-clearance before `platform/management` is re-applied.
  (5) The decision-6 amendment must be reflected in `docs/teardown-redesign.md` and
  `docs/cicd-deploy-teardown.md` when DevSecOps expresses it in the workflow.

### ADR-071: The ORPHANED DIAGNOSTIC SETTING is a named failure class whose mechanism is already established in this estate (ADR-063 decision 5, G-1, live proof `diag-aa-to-law`): a `microsoft.insights/diagnosticSettings` object is keyed to its host's URI, outlives the host, outlives the state, and is invisible to every greenfield proof, so it re-collides on the first apply that recreates a same-named host. The two-applies expectation is RATIFIED but only as an INTERIM operating rule; the permanent fix is a Phase 0.5 live-host sweep at TEARDOWN, not an apply-side change. Separately: teardown is CONTRAINDICATED while a Service Health `ServiceIssue` is Active against a service the destroy inventory must delete, and a blocking pre-teardown health gate is specified

- **Date:** 2026-07-31
- **Section:** 9 (Landing Zone Spokes, where the class fired) / 10 (Pipeline & Tooling, where the fix
  and the gate live). **Extends ADR-063 decision 5** (the resource-scoped diagnostic-settings sweep and
  its G-1 finding) rather than superseding it. **Extends ADR-068's failure-mode taxonomy** with FM-3.
  **Constrains ADR-066** (all eleven Phase-1 layer destroys must go green) by ruling when a teardown may
  not be dispatched at all. Applies the ADR-066 decision 4 precedent (an operation that must run while
  its target is still live belongs in Phase 0.5, not Phase 2). Does NOT supersede ADR-070: that ruling
  is about DINE ownership and is correct on its own terms, but it never addressed this class and could
  not have prevented it. Answers **OQ-067 item B**. Relates to ADR-067 (the teardown-and-restart class
  this is NOT), ADR-060 (plan before every apply), LESSON 52 (import blocks), LESSON 59 (one
  consolidated fix-spec per failure set), LESSON 62 (mechanical rules get a hook, not a habit).
- **Status:** Accepted (architect ruling; the user directed a ruling once the class had two roots, eight
  instances and a stated operational rule behind it, and separately directed a ruling on the teardown
  implication of the active Microsoft incident).
- **Landed:** NOT IMPLEMENTED. Decisions 4b and 5 are a written spec for DevSecOps (one new Phase 0.5
  teardown job plus one blocking gate step in `teardown.yml`); decisions 1, 2, 3, 4a and 6 are rulings,
  operator actions and doc amendments that need no `.tf` or `.yml`. Update this field by dated addendum
  when the DevSecOps PR merges.
- **Decision makers:** claude (architect); user (raised the class, recorded the two-applies rule that
  decision 3 ratifies and narrows, and identified the teardown hazard that decision 5 answers).

**Context:**

**The signature, established from live evidence gathered 2026-07-31.** Across three CI applies of two
roots, eight `azurerm_monitor_diagnostic_setting` resources failed with
`already exists - to be managed via Terraform this resource needs to be imported`, every one of them
with the same four properties: the object is **present in Azure**, carries a **Terraform-derived name**
(`diag-<resource>`, computed by the AVM modules and by our own native resources from our own inputs, so
nothing else in Azure composes it), is **exactly one per parent** on a LIST, and is **absent from
Terraform state**.

| Root | Runs | Orphans |
|---|---|---|
| `landing-zones/bank-data-p1` | `30661012325`, `30662610292` (both failed) | `diag-dbw-*`, `diag-aif-*`, `diag-srch-*` |
| `landing-zones/bank-app-p1` | `30672301220` (failed at 33 min 50 s) | `diag-apim-*`, `diag-acr-*`, `diag-aks-*`, `diag-evhns-*`, `diag-sbns-*` |

Both roots recovered by the runbook **B1** action - delete the survivors, rerun the same root, do not
import. `bank-data-p1`'s recovery run `30671577938` took **3 min 36 s** and came back
`4 added, 26 changed, 0 destroyed` with **zero** `already exists`. Nothing was rolled back by the failed
applies: every expensive resource (APIM, AKS, the Premium ACR, both messaging namespaces, Databricks,
Foundry, Search) had already provisioned and reported `Succeeded`.

**Three explanations are excluded, and the exclusions are evidence, not assumption.**

1. **DINE is excluded.** `diag-aks-*` is decisive: `Deploy-Diag-LogsCat` has no member for
   `microsoft.containerservice/managedclusters`, and the only AKS diagnostics policies in the
   inheritance chain are hard-capped `[AuditIfNotExists, Disabled]` and cannot write. Independently,
   the code-reviewer proved from the pinned azurerm v4.71.0 source that the existence check is built as
   `NewScopedDiagnosticSettingID(target_resource_id, name)` and GETs that **exact configured name**, so
   a differently-named policy object (`setByPolicy-LogAnalytics`) cannot collide with any of ours. Both
   arguments hold for every resource type, not just AKS. ADR-070's exemptions are correct for their own
   reasons and were never going to prevent this.
2. **The ARM instability is excluded as the mechanism** (it remains admissible as a trigger for the
   first occurrence only). The `diagnosticSettings` write path was returning `InternalServerError` for
   roughly two hours (20:00 to 21:59Z, evidenced by three DINE `PolicyDeployment_*` retrying doomed PUTs
   and still collecting fresh 500s at 21:59Z). But the class reproduced on `bank-app-p1` hours later,
   after the endpoint had demonstrably recovered: all eight B1 DELETEs returned cleanly and were
   confirmed absent by direct GET, which is itself a probe of the same write path.
3. **A CI-side retry of the apply is excluded.** Checked directly in this branch:
   `.github/workflows/_tf-root.yml` wraps only `terraform init` in a bounded retry loop (six attempts,
   the ADR-025 state-SA firewall backstop). The `apply` step is not retried. So "the same run applied
   the resource twice" is not available as an explanation, and it was worth eliminating because it would
   have made the class an artifact of our own pipeline.

**The mechanism is not new, and this estate has already ruled on it and already carries a live proof.**
`scripts/teardown-az-sweep.sh` step 2-pre exists because of exactly this behaviour, recorded there as
ADR-063 decision 5 / finding **G-1** on 2026-07-23:

> a resource-scoped diagnostic setting is an extension object keyed to its host resource's URI, and
> does NOT reliably cascade away just because the host resource is later deleted [...] the live proof
> is `diag-aa-to-law` (`platform/management/main.tf`, on the platform automation account inside
> `rg-management-globaris-poc`), which is what the 2026-07-23 rebuild collided on at Step 2
> ("already exists - needs to be imported") despite both the RG and the automation account having been
> deleted by an earlier teardown.

That is the same signature, on a different root, eight days earlier, already diagnosed. The public
issue family says the same thing from outside (hashicorp/terraform-provider-azurerm #7114, #11070,
#11076, #25673; the Microsoft Q&A thread on AVM diagnostic settings), and the provider's own create path
makes the consequence deterministic: `ImportAsExistsError` is raised **before any PUT**, so a resource
that reports `already exists` was found by the pre-create GET and was therefore present **before that
resource's create began**.

**Which forces a correction to the operating premise in the record.** The 2026-07-31 operator entry
states that "the objects are created and lost DURING the apply, so there is no pre-emptive delete
available". The first half is not established and is in tension with the provider's create ordering;
the second half is true only of the apply side. Under the established G-1 mechanism the object PREDATES
the run, and a pre-emptive delete **does** exist - at teardown, while the host is still alive. That
distinction is the whole difference between "budget for two applies forever" and "fix it once".

**Why the existing sweep did not catch these eight: an ordering regression, and it is the same one
ADR-066 decision 4 already found and fixed for Databricks.** Step 2-pre enumerates targets as
`discover_live_rgs` -> `az resource list` per RG -> `diagnosticSettings` GET per resource id. It can
only see a setting whose **host is still live**. It sits in Phase 2 (`az-sweep`), whose job in
`teardown.yml` `needs` all eleven Phase-1 jobs. Under ADR-066, `mode=terraform` at `target=all` runs
those eleven `terraform destroy` jobs FIRST, which delete the hosts, after which no enumeration can
reach any setting the destroying root did not hold in state. So in the `mode=terraform` path the sweep
is structurally unable to catch precisely the residue it was written for. This is the identical shape
ADR-066 decision 4 identified for the Databricks force-delete and solved by moving it to a Phase 0.5
job that runs while the workspace is still live. The fix was applied to Databricks only.

**What is NOT established, stated plainly.** Which teardown left these eight, and whether all eight
share one provenance. The enabling conditions are all documented and dated (the resource-scoped sweep
did not exist in this repo before 2026-07-23, `0a7607b` / `7be4dfa`; these roots were first deployed in
waves B2 to B6 on 2026-07-18 and 2026-07-19; state blobs have been emptied and reset since, so some
destroys were no-ops), but "consistent with" is not "shown". Decision 2 says how to close it for the
cost of three reads, and deliberately does not block anything on the answer.

**Decision:**

**1. The class is named, and it gets a one-read signature test.** An **orphaned diagnostic setting** is
a `microsoft.insights/diagnosticSettings` object that (a) exists in Azure, (b) carries a name this
repository composes, (c) is absent from the state of the root that composes it, and (d) blocks that
root's create with `already exists`. All four must hold. It is distinguished, in one line each, from
the two classes it keeps being confused with:

| Observation | Class | Action |
|---|---|---|
| Blocking object carries OUR name, no data, no dependents, deletable | **This ADR (orphaned diagnostic setting)** | runbook **B1**: delete the survivor, rerun the same root |
| Blocking object carries a POLICY name (`setByPolicy-*`, `deployedByPolicy`), or is a private DNS zone group | **ADR-070** (DINE ownership) | RG-scoped `Mitigated` exemption + separate 300s sleep + `depends_on` |
| Blocking object cannot be deleted at all (soft-delete, purge protection, dependents, data) | **ADR-067** | full teardown and restart from Step 1 |

ADR-070's bright-line test governs the choice between rows 1 and 3 unchanged: can every blocking object
be deleted and recreated identically by the next apply, with no data loss and no soft-delete window? For
a diagnostic setting the answer is always yes.

**2. FM-3, and the three reads that close OQ-067 item B.** ADR-068 named FM-1 (state missing while
resources live) and FM-2 (state populated while resources gone). This class is neither, and it needs its
own name because it defeats the guard both of those have:

> **FM-3: an object outlives BOTH the estate and the state, and is invisible to every discovery-based
> proof, because its only address runs through a host that no longer exists.**

This is why the 2026-07-31 greenfield verification was correct and the orphans still existed. Nothing was
missed: a `diagnosticSettings` child of a deleted resource cannot be enumerated by any subscription, RG
or resource listing. **A greenfield proof is a statement about what can be discovered, and FM-3 objects
are by construction outside it.** That sentence belongs in the teardown documentation.

Provenance is closed by three reads, all cheap, none blocking:

- **T1 (offline, on a log already held).** For each failing address in run `30672301220`, read whether
  Terraform emitted any `Still creating... [N elapsed]` ticks before the failure, and compare the
  timestamps of the three or five `Error:` diagnostics with each other. **If the errors share one
  timestamp, the "10m17s / 2m14s / 55s" figures measure from each `Creating...` line to the end-of-run
  diagnostics block and carry no information about the provider's own duration** - which is the reading
  that fits staggered dependency completion and a fast pre-create GET. If instead each address shows
  ticks running to its own figure, the create really did spend minutes before returning, and G-1 is not
  the whole story for these instances. This single read is the highest-value item in the ADR and costs
  nothing.
- **T2 (live, read-only, 90-day window).** Query the Activity Log for
  `Microsoft.Insights/diagnosticSettings/write` on each of the eight target resource IDs. A write inside
  the failed run's window supports "created during the apply"; no write inside the window plus one at an
  earlier estate lifetime confirms G-1. **Guard against the empty-result trap (ADR-069 addendum item
  6):** if the query returns nothing for BOTH windows, the query shape is uninformative and must not be
  read as evidence of absence; validate it first against a resource whose setting was demonstrably
  written today.
- **T3 (the prediction that makes this falsifiable).** G-1 predicts that after decision 4b lands, the
  next greenfield first-apply of these roots creates all nine settings with **zero** `already exists`.
  If the class recurs on a first apply that followed a teardown carrying the Phase 0.5 sweep, G-1 is
  refuted for this estate and decision 4a's fallback is bought.

**3. The two-applies rule is RATIFIED, NARROWED, and explicitly INTERIM.** The operator's rule stands as
an operating expectation, with three corrections:

- **Ratified:** any root creating `azurerm_monitor_diagnostic_setting` may fail its first apply on those
  settings; the recovery is B1 (delete the orphans, rerun), it is fast because nothing is rolled back,
  and it is budgeted rather than escalated. It is not an incident, it does not fire ADR-067, and it does
  not justify a teardown.
- **Narrowed:** the exposure is the **first apply of a root after an estate lifetime in which its
  diagnostic settings were removed without a live-host sweep**, not every apply forever. It did not fire
  on either recovery run, and it did not fire on the five root-level settings in Steps 2, 3, 4 and 7,
  which is consistent with narrowing and inconsistent with "always two applies".
- **Interim:** this expectation expires when decision 4b lands and T3 is observed once. Shipping "expect
  every apply to fail" as a permanent operating rule would be accepting a defect as a feature, and it
  would eventually be paid at the worst possible moment - `bank-app-p1` already spent 33 minutes 50
  seconds of APIM and AKS provisioning before failing on five settings.

Recovery procedure, unchanged and now written where it can be found: confirm no DINE `PolicyDeployment_*`
is mid-flight on the target RG (ADR-070 R1, with its 90-minute pathological cap), DELETE each named
survivor, confirm absent by direct GET, then plan (ADR-060, always) and apply. Plan bar for the retry:
pure adds of the previously blocked settings, 0 destroy, 0 replace, 0 import, changes limited to the
OQ-032 `CreatedDate` churn.

**4. The structural-fix ruling: buy the teardown-side fix, do not buy the apply-side rewrite.**

**4a. Rejected, with the reason each was tested against.**

- **Convert the nine `azurerm_monitor_diagnostic_setting` objects to root-level
  `azapi_resource` (`Microsoft.Insights/diagnosticSettings@2021-05-01-preview`).** This WOULD work, and
  it is hypothesis-independent: azapi PUTs idempotently with no RequiresImport pre-check, which is
  exactly why `module.datalake`'s azapi-based setting never failed in the same runs that killed three
  azurerm siblings. **Rejected as the primary fix anyway.** It treats the symptom at the apply while
  leaving FM-3 objects accumulating in the tenant; it removes nine settings from the AVM
  `diagnostic_settings` inputs that are the module's supported interface (ADR-038 consumes AVM
  directly); it requires hand-authored category bodies, which is a NEW PUT-time failure surface of
  exactly the class LESSON 27 catalogues; and landing it mid-rebuild would widen the failure class on
  the estate's most expensive roots, which is what LESSON 59 forbids. **Retained as the named fallback**
  if T3 refutes G-1, and in that event the conversion is scoped to the failing settings only, not all
  nine.
- **Move to a newer `azurerm`.** **Rejected on verified fact, not preference.** The v4 changelog was
  read end to end for this ADR: there is **no** `azurerm_monitor_diagnostic_setting` change of any kind
  between 4.72.0 and 4.81.0 (latest v4, 2026-07-14). The only create-path fix in the line -
  "add further polling to work around an eventual consistency issue when creating the resource"
  (issue #27088) - shipped in **4.0.0** and is therefore already present in our pinned 4.71.0. A bump
  buys nothing here and costs a re-plan of every root. 5.0.0 (2026-07-27) is a major-version migration
  and is out of scope entirely.
- **A `lifecycle` block.** **Rejected as impossible, not undesirable.** `ignore_changes`,
  `prevent_destroy` and `replace_triggered_by` all act on Terraform's diff; `ImportAsExistsError` is
  raised inside the provider's Create before any of them can apply. There is no meta-argument that
  suppresses it.
- **A config-driven `import` block.** Rejected: forbidden by ADR-067's addendum, constrained by LESSON
  52, and worse than deleting even if allowed - adopting an object of unknown provenance under a
  Terraform address is how you get a resource Terraform believes it controls and something else writes.

**4b. Bought: a Phase 0.5 resource-scoped diagnostic-settings PRECASCADE at teardown.** DevSecOps lane,
one PR. The shape is fixed by the precedent already in the tree, so this is a spec and not an idea:

- **Extract** the existing step 2-pre body from `scripts/teardown-az-sweep.sh` into a shared function in
  `scripts/teardown-common.sh` (working name `sweep_resource_diagnostic_settings`), exactly as
  `databricks_force_delete_cascade` is shared today, **so the two call sites cannot drift**. Behaviour,
  api-version (`RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION`, currently `2021-05-01-preview`), the
  `is_estate_owned --resource-id` containment predicate, the auth-shaped-failure-only loud branch and
  the confirm-GET all move unchanged. This is a refactor with no behaviour change at the existing site.
- **Add** `scripts/teardown-diagnostic-precascade.sh` calling that function, wired as a new Phase 0.5
  job in `.github/workflows/teardown.yml` gated **identically to `databricks-precascade`**:
  `needs: [guard]`, `if: !cancelled() && needs.guard.result == 'success' && inputs.target == 'all' &&
  inputs.mode == 'terraform'`. `mode=az-sweep` is deliberately NOT wired: Phase 1 never runs in that
  path, so the existing step 2-pre already executes while hosts are live and a second call would be a
  duplicate rather than a fix. Same reasoning, same words, as the Databricks job's own header.
- **Keep step 2-pre where it is.** It is the belt for the az-sweep path and for anything Phase 0.5
  missed; removing it would trade one gap for another.
- **Not a gate.** Consistent with the Databricks precascade: a failure here is loud but does not skip a
  layer, because Phase 1 must still run all eleven destroys green (ADR-066 INV-1).
- **Acceptance:** the next `target=all mode=terraform` teardown shows the Phase 0.5 job deleting at
  least the settings the estate currently holds, and the next greenfield first apply of `bank-data-p1`
  and `bank-app-p1` reports zero `already exists` (T3).

**5. Teardown is CONTRAINDICATED right now, and the pre-teardown health check is a blocking gate.**

**5a. The immediate ruling.** A Microsoft Service Health `ServiceIssue` titled "Azure Databricks
Workspace Deletion Failures" was Active on the landingzones subscription (impact start 16:51:26Z, still
Active at 22:41Z). `landing-zones/bank-data-p1` holds a live `dbw-bank-data-p1-globaris-poc`. ADR-066
requires all eleven Phase-1 layer destroys to go green, and Phase 0.5 submits a Databricks
force-delete BEFORE Phase 1 even starts, so a teardown dispatched during this incident drives the
estate's teardown straight into the one operation Microsoft is reporting as failing. The likely outcome
is a failed teardown with a partially destroyed estate and partially populated state - **strictly worse
than the state we are in**, and the FM-2 shape ADR-068 exists to prevent. **Do not dispatch a teardown
while that event is Active. Wait for `status = Resolved`.** The operator signalled teardown twice on
2026-07-31; this ruling is the answer both times.

There is no safe shortcut. `mode=az-sweep` does not dodge it (its step 1 issues the same force-delete),
and deleting the workspace by hand is excluded by the standing rule that teardown is CI/CD only.

**5b. The gate, so this is never a memory item again (LESSON 62).** Add a read-only step to the existing
`guard` job in `.github/workflows/teardown.yml`, before any destructive job can start:

- For each estate subscription, `GET
  https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.ResourceHealth/events?api-version=2025-05-01&queryStartTime=<today-7d>`.
  The api-version is verified current against the Resource Health REST reference (Events - List By
  Subscription Id, doc updated 2026-07-21); `2022-10-01` is the fallback if the SP's read path rejects
  it. `queryStartTime` is mandatory in our use: the default window is three days by `lastUpdateTime`,
  and a long-running incident can fall out of it.
- **Fail the job if any returned event has `properties.eventType == "ServiceIssue"` and
  `properties.status == "Active"`, or any `properties.impact[].impactedRegions[]` entry with
  `status == "Active"` in an estate region.** Deliberately broad. A curated impacted-service-to-resource
  map would drift silently and would have to be right about a service name we do not control; a short
  written disposition per event costs the operator a minute and produces the record.
- Print, for every matched event, `name` (the tracking ID), `properties.title`, `impactedService`,
  `impactStartTime` and `status`, so the disposition can be written from the job log.
- **Override:** a `workflow_dispatch` boolean input (default `false`) that downgrades the failure to a
  warning, whose description requires the architect disposition reference to be recorded in
  `docs/preclearance/` before use. A gate with no override gets bypassed by editing the workflow, which
  is worse.
- **A failed or empty LIST is never read as "no incidents"** - same section 9.4 discipline every other
  list in the teardown scripts already follows, and the same empty-result trap decision 2 guards.
- **Prerequisite to confirm at implementation:** the CI SP can read
  `Microsoft.ResourceHealth/events` (included in Reader; not yet verified live for this SP). If it
  cannot, the gate is written to fail loud on the authorization error rather than pass.
- The check runs **at dispatch time**, not at planning time. Incidents open in hours.

**6. Documentation follow-ups, owned and small.**

1. **DevSecOps:** decision 4b (the Phase 0.5 job) and decision 5b (the guard-job gate), one PR each or
   one PR total, reviewer-gated.
2. **DevSecOps / runbook:** `docs/2026-07-22-full-estate-rebuild-runbook.md` matrix row **B1** currently
   reads "on a budget, cost export, anomaly alert, or subscription diagnostic setting". Widen it to any
   `azurerm_monitor_diagnostic_setting` at **resource** scope, pointing at this ADR, and add the
   decision-3 two-applies expectation to section 3d (Steps 5-9).
3. **DevSecOps / teardown docs:** `docs/teardown-redesign.md` and `docs/cicd-deploy-teardown.md` gain the
   Phase 0.5 diagnostic precascade, the FM-3 sentence from decision 2, and the decision-5b gate as a
   documented pre-dispatch condition.
4. **Operator:** run T1 now (it is a log read), T2 when convenient, and record both in OQ-067 item B.
5. **Architect:** carry the FM-3 sentence and the "a greenfield proof is a statement about what can be
   discovered" formulation into `landing-zone-kit/LESSONS.md` at the next kit pass; it generalises well
   beyond this estate.

**Alternatives considered:**

- **Treat it as an incident each time it fires.** Rejected: it has now fired eight times with one
  signature and a documented mechanism, and escalating a known class burns the review and dispatch
  budget that LESSON 59 reserves for narrowing real failures.
- **Accept two applies permanently and change nothing.** Rejected: see decision 3. It also leaves FM-3
  objects accumulating invisibly in the tenant, which is a governance problem independent of Terraform.
- **Block the rebuild until provenance is proven.** Rejected: the recovery action is identical under
  every candidate provenance, so blocking buys nothing and costs the remaining rebuild steps. Decision 2
  is deliberately non-blocking.
- **Sweep diagnostic settings before every APPLY rather than at teardown.** Rejected as unavailable: an
  orphan is only addressable through its host, and on a greenfield apply the host does not exist until
  the apply creates it. There is genuinely no pre-emptive delete on the apply side, which is the one
  half of the operator's premise that survives.
- **Gate teardown on a curated impacted-service list rather than on any Active ServiceIssue.** Rejected:
  a hand-maintained map of Azure service display names to our resource inventory is precisely the kind
  of mirrored state that drifted and had to be retired from `WORKLOG.md`. Broad match plus a written
  disposition is cheaper and cannot go stale.

**Consequences:**

- Positive: the class has a name, a signature test, an established mechanism, an honest boundary around
  what is still hypothesis, and a fix that removes the SOURCE rather than the symptom. The B1-versus-
  ADR-070-versus-ADR-067 choice becomes a three-row table. FM-3 explains why a correct greenfield proof
  and a live orphan can coexist, which was the most confusing part of the evidence. The teardown hazard
  that was nearly acted on twice is now a workflow gate instead of a thing someone remembered.
- Negative / trade-offs: one more teardown job and one more blocking gate, both of which lengthen the
  teardown path and can fail on their own. The gate will occasionally block a teardown on an incident
  that would not actually have affected it, and the override exists precisely because that will happen.
  Two applies remains the operating expectation until decision 4b lands and T3 is observed once, so the
  rest of this rebuild still budgets for it.
- Negative: provenance for the eight is closed by prediction (T3) rather than by proof, and T3 cannot be
  observed until after the next teardown and rebuild. That is a real gap and it is why decision 4a keeps
  the azapi conversion named and scoped rather than discarded.
- Follow-ups required: the five items in decision 6. **OQ-067 item B** is answered to the extent the
  evidence allows and updated in place with the new constraint; it stays open on provenance only.

### ADR-070: Terraform is the SOLE owner of diagnostic settings and private-endpoint DNS zone groups on every resource a landing-zone root creates; the ALZ DINE policies that write the same two object classes are suppressed at those scopes by RG-scoped `Mitigated` exemptions. The twice-failed `bank-data-p1` apply is runbook matrix **B1** (delete the survivor, rerun, do not import), **NOT** the ADR-067 teardown class, and the bright-line test between the two is written down here so it stops being re-litigated.

- **Date:** 2026-07-31
- **Section:** 9 (Landing Zone Spokes) / 2 (Management Group Hierarchy, the DINE assignments) / 10 (Pipeline & Tooling, the rebuild dispatch). Extends ADR-028 and LESSON 35 (the RG-scoped exemption + 300s sleep + `depends_on` unit). Constrains ADR-067's addendum by defining when it fires. Relates to OQ-021 (the diagnostics DINE) and OQ-032 (the accepted `CreatedDate` tag drift that accounts for all 29 plan changes).
- **Status:** Accepted (architect ruling; user directed a ruling on the ownership conflict that failed `landing-zones/bank-data-p1` twice during the live centralus rebuild, runs `30661012325` and `30662610292`).
- **Landed:** NOT IMPLEMENTED (decisions 1, 2 and 6 need Cloud Engineer code in `landing-zones/bank-data-p1` and `landing-zones/bank-app-p1`; decisions 3, 4, 5 and 7 are operator and gate actions needing no code).
- **Decision makers:** claude (architect); user (evidence gathering, and the ruling that the failure be diagnosed rather than retried a third time).

**Context:**

`landing-zones/bank-data-p1` (Step 8 of the full-estate rebuild) failed identically on two consecutive applies. Three resources returned `already exists - to be managed via Terraform this resource needs to be imported`:

| Terraform address | Object |
|---|---|
| `module.databricks_workspace["main"].azurerm_monitor_diagnostic_setting.this["platform_law"]` | `diag-dbw-bank-data-p1-globaris-poc` |
| `module.foundry["main"].azurerm_monitor_diagnostic_setting.this["platform_law"]` | `diag-aif-bank-data-p1-globaris-poc` |
| `module.search["main"].azurerm_monitor_diagnostic_setting.this["platform_law"]` | `diag-srch-bank-data-p1-globaris-poc` |

Live evidence gathered by the user and treated here as sourced, not re-run:

1. All three settings return a body on a direct ARM GET at `2021-05-01-preview`, each pointing at `law-platform-globaris-poc`, with exactly ONE setting per resource on LIST.
2. None of the three is in Terraform state. The diagnostic plan (run `30662130982`) is **4 to add, 29 to change, 0 to destroy**, with 0 replacements, 0 imports and 0 tainted. The fourth add is `azapi_resource.foundry_pe_dns_zone_group["main"]`. All 29 changes are the accepted OQ-032 `CreatedDate = "1970-01-01"` tag churn, confirmed by opening the diff blocks rather than counting tokens.
3. The AVM modules compute the name as `coalesce(each.value.name, "diag-${var.name}")`, so `diag-<resource>` is a Terraform-derived name.
4. Three `PolicyDeployment_*` deployments in `rg-bank-data-p1-workload-globaris-poc` were still `Running` about 50 minutes after starting, writing **competing objects with different names**: `setByPolicy-LogAnalytics` diagnostic settings on the Foundry account and the Search service, and a `deployedByPolicy` private DNS zone group on `pe-aif-bank-data-p1-globaris-poc`.
5. The DINE definitions firing include "Configure Cognitive Services accounts to use private DNS zones" and the blob and dfs groupID private-DNS definitions, plus Defender and activity-log ones.
6. The datalake's diagnostic setting is an **azapi** resource (`module.datalake["main"].module.diagnostic_setting_storage_account.azapi_resource.this["platform_law"]`). azapi PUTs idempotently with no RequiresImport pre-check, and it did not error. The three failures are all **azurerm** `azurerm_monitor_diagnostic_setting`, which performs a pre-create GET and raises `ImportAsExistsError` on any non-404.
7. All three AVM modules are already at the latest published registry versions (`avm-res-cognitiveservices-account` 0.11.1, `avm-res-search-searchservice` 0.3.0, `avm-res-databricks-workspace` 0.5.0). There is no upgrade to take.

**Two things in the record are wrong or unestablished, and this ADR does not build on either.**

The 2026-07-31 operator entry for Steps 4-8 root-caused this as ARM read-after-write eventual consistency and offered "zero DINE diagnostic policies assigned at the landingzones MG" as evidence 2 and "all three return EMPTY when queried live" as evidence 3. Evidence 2 checked ONE scope. The ALZ diagnostics and private-DNS DINE assignments are inherited from an ANCESTOR management group, which is exactly the failure mode the standing pre-clearance rule ("live policy matrix at EVERY ancestor MG scope", LESSON 34) exists to prevent, and evidence 4 above shows those policies demonstrably firing on these very resources. Evidence 3 is contradicted by the user's direct GET and LIST. Neither correction changes the ruling below, but the prior "known transient class, retry on occurrence, no code change" disposition is **superseded**: two identical failures on one root is already at the runbook's U5 hard-stop bar, and a third bare retry is precisely what LESSON 59 forbids.

**The provenance of the three existing settings is NOT established, and this ADR says so rather than papering over it.** The first apply failed at 19:59:44; the Foundry `PolicyDeployment` began at 20:00:24, forty seconds LATER. DINE therefore cannot have created what the first apply tripped over. Two candidate explanations remain and they are separated by one cheap read each (D1 and D2 in decision 4). Note also that evidence 1 and the provider's own RequiresImport check issue the SAME API call, so if that API is answering loosely it is answering loosely to `az rest` too; the discriminator is the `name` field of each entry returned by LIST, which has not yet been read back.

**Why this is an ownership question and not only a provider question.** Two writers are competing for two object classes on the same resources:

- **Diagnostic settings.** Terraform declares them through the AVM `diagnostic_settings` input on 8 resources estate-wide. The ALZ diagnostics DINE writes `setByPolicy-LogAnalytics` on the same scopes. Two settings on one resource pointing at the SAME workspace means the same rows are ingested twice and billed twice on the Analytics ingestion meter, which for `allLogs` on AKS, APIM, Databricks and Foundry is a real and recurring FinOps cost for zero additional insight.
- **Private-endpoint DNS zone groups.** Azure supports **only one private DNS zone group per private endpoint** (Microsoft Learn, private-endpoint DNS integration). So a `deployedByPolicy` group and Terraform's `default` group on `pe-aif-bank-data-p1-globaris-poc` are not duplicates, they are mutually exclusive. Worse, the DINE group would carry ONE zone while the Foundry account needs THREE (cognitiveservices, openai, services.ai), so if DINE wins the race the private endpoint resolves incorrectly AND Terraform's pending azapi PUT collides. The repo has carried this DINE as "post-apply drift, never a create blocker" in `docs/preclearance/landing-zones.md` row 12, `docs/preclearance/b5-data-platform.md` row 8 and the rebuild gate's PC-8S table. **That classification is now falsified for any private endpoint whose zone group Terraform has not yet created**, which is exactly the state a failed apply leaves behind.

**Decision:**

1. **Ownership: Terraform, exclusively, on every resource a landing-zone or platform root creates.** For those resources Terraform is the sole writer of `microsoft.insights/diagnosticSettings` and of `Microsoft.Network/privateEndpoints/privateDnsZoneGroups`. The ALZ DINE policies keep their scope over everything the estate's Terraform does NOT create; they lose it over everything it does. Accepting duplicates is rejected (duplicate ingestion and duplicate cost for diagnostics; a hard mutual exclusion for zone groups). Disabling the AVM `diagnostic_settings` inputs and letting DINE own diagnostics is rejected (it deletes the estate's own observability wiring, makes log routing invisible in code, and today would route nothing at all while OQ-021 stands).

2. **Mechanism: RG-scoped policy exemptions, category `Mitigated`, on the resource groups that hold Terraform-owned resources.** `Mitigated` rather than `Waiver` is deliberate and load-bearing documentation: the policy's INTENT is met, by another mechanism, which is precisely what that category means. Implement with the unit already proven in these roots (ADR-028, LESSON 35): `azurerm_resource_group_policy_exemption` + a **new, separate** `time_sleep` of `300s` + `depends_on` from every protected resource. It must be a NEW `time_sleep` resource, not the existing `wait_corp_policy_exemptions`: adding a member to the existing exemption map does not re-trigger a `time_sleep` that is already in state, so the new exemption would get no propagation window at all.
   - MG-wide `enforcementMode = "DoNotEnforce"` (the `Enable-DDoS-VNET` precedent in `platform/management-groups`) is REJECTED as the primary mechanism: it is not resource-scoped, it silently disarms the control for future workloads that Terraform does not manage, and it removes the compliance signal everywhere. It is retained as the documented FALLBACK for any assignment whose members cannot be enumerated well enough to write a scoped exemption.
   - **The exact assignment names and `policyDefinitionReferenceIds` are UNVERIFIED here and must not be guessed.** The user's evidence names policy DEFINITIONS; exemptions are written against ASSIGNMENTS. The implementer's first step is decision 4's read D3. If an assignment turns out to be a standalone definition rather than an initiative, `policy_definition_reference_ids` must be omitted, since the provider rejects it in that case.

3. **This failure is runbook matrix B1, not ADR-067. The bright-line test, stated once so it stops being argued:**

   > ADR-067's addendum fires when the estate cannot move forward without either (a) importing a live Azure object into Terraform state, or (b) reconciling a state that no longer describes what Terraform built. It does **not** fire because an apply failed, and it does **not** fire on the string `already exists`.
   >
   > **Test:** can every object the failed apply is blocked on be DELETED, and recreated identically by the next apply, with no data loss, no soft-delete window, no purge protection and no dependent object?
   > - **Yes** -> runbook **B1**: stop, delete the specific survivor, rerun the same root, do not import. State and Azure are congruent the moment the delete completes.
   > - **No** -> **ADR-067**: full teardown and restart from Step 1.

   Applied here the answer is unambiguously yes. The blocking objects are three `microsoft.insights/diagnosticSettings` sub-resources and at most one `privateDnsZoneGroups` child. All four are control-plane-only, hold no data, have no soft-delete and no purge protection, have no dependents, and are reproduced identically by the plan that is already sitting there. Deleting them costs nothing and loses nothing.

   The contrast with ADR-067's actual Class 2 is the whole point: those orphans were `Microsoft.SecurityInsights` children inside a soft-delete-RECOVERED Log Analytics workspace. Deleting the workspace re-entered the recovery loop on the next apply, and the co-located Key Vault was purge-protected for 90 days, so **there was no delete path at all** and import or teardown were the only options. That is why the addendum was written, and it is why it does not reach a diagnostic setting.

   The plan corroborates it independently: **4 add / 29 change / 0 destroy, 0 replace, 0 import, 0 tainted.** A partial state that plans as a pure forward-completion is not a divergent state. Had that plan shown any replace, any destroy, or any import block, ADR-067 would fire and the answer would be teardown. It did not.

   **Full teardown and restart is therefore NOT ordered.** The seven green roots and roughly 1,391 applied resources stand.

4. **Immediate recovery for `bank-data-p1`, in this order.** The next dispatch of this root is a FIXED dispatch, not a third bare retry (U5 has already fired; LESSON 59 requires one consolidated fix-spec).

   **D1 (read-only, 2 minutes, decides the provenance).** LIST the diagnostic settings on all three resources and print the `name` of every entry verbatim, not the requested name from the URL. If the names are `diag-dbw-*` / `diag-aif-*` / `diag-srch-*`, real Terraform-shaped objects exist and something wrote them; if the names are `setByPolicy-LogAnalytics`, no Terraform-shaped object ever existed and the `already exists` is a provider false positive against a DINE sibling on the same scope. **The recovery action is the same in both branches** (delete, then retry), which is why recovery is not blocked on this read; it is required for the record and for decision 7.

   **D2 (read-only, 2 minutes, tests OQ-021 and the same provenance).** Read the diagnostics DINE assignment's Log Analytics workspace parameter at every ancestor MG scope. If it is the zero-GUID subscription, OQ-021 still holds, the DINE cannot successfully write anything, and it cannot be the creator. If it holds the real `law-platform-globaris-poc` resource ID, OQ-021 has silently resolved and DINE IS a live competing writer.

   **D3 (read-only, blocking for decision 2).** Enumerate the live policy ASSIGNMENTS and their `policyDefinitionReferenceIds` for the diagnostics and private-DNS DINE families at **every** ancestor scope of the landingzones subscription (tenant root, `globaris`, `landingzones`, `corp`), not just `landingzones`. This is the check the prior session's evidence 2 skipped.

   **R1. Confirm the PolicyDeployments have settled before touching anything.** Deleting a survivor while a remediation is mid-flight simply recreates it. **Settled** means: every deployment in `rg-bank-data-p1-workload-globaris-poc` whose name starts `PolicyDeployment` reads `provisioningState` in {`Succeeded`, `Failed`, `Canceled`}, none in {`Running`, `Accepted`}, **and** a second read five minutes later returns the same set with no NEW `PolicyDeployment` name. Both reads are required; the first alone does not prove no further remediation is queued.
   **Cap: do not wait indefinitely.** A diagnostic-setting PUT takes seconds, so a deployment `Running` for 50 minutes is already pathological. If any is still `Running`/`Accepted` 90 minutes after it started, treat it as stuck rather than slow: cancel it (`az deployment group cancel`), re-read, proceed, and record the stuck deployment as evidence in OQ-067.

   **R2. Delete the survivors.** The three diagnostic settings named in the error, plus ANY private DNS zone group on `pe-aif-bank-data-p1-globaris-poc` (whatever it is called), plus any `setByPolicy-LogAnalytics` setting D1 turned up on those three resources. This is the runbook B1 action and it is explicitly sanctioned there. Do not delete anything on a resource that is not in the failing set.

   **R3. Land the decision-2 exemption unit** (Cloud Engineer, reviewer gate, merge to `banking`) before re-dispatching. Without it the retry is a race against a remediation that is already running, and losing that race spends the U5 budget on a coin flip.

   **R4. Plan, then apply** (ADR-060, always plan first). The plan bar for the retry: pure adds only; the 4 known adds plus the new exemption and `time_sleep` resources; **0 destroy, 0 replace, 0 import, 0 `already exists`**; changes limited to OQ-032 `CreatedDate` churn. Anything else is a STOP.

5. **Steps 1 to 7 are NOT contaminated, and the check that proves it is cheap.** No already-green root holds a state-versus-Azure divergence today, because no green root is missing an object it created. The exposure that DOES exist is duplicate ingestion and a latent RequiresImport trap on the NEXT rebuild, on exactly five objects:

   | Root | Object | Shape |
   |---|---|---|
   | `platform/management` (Step 2) | `azurerm_monitor_diagnostic_setting.automation_account` | root-level azurerm, in state |
   | `platform/security` (Step 3) | `azurerm_monitor_diagnostic_setting.security_sub_activity` | root-level azurerm, subscription scope, in state |
   | `platform/connectivity` (Step 4) | `azurerm_monitor_diagnostic_setting.firewall` (both hubs) | root-level azurerm, in state |
   | `landing-zones/online-p1` (Step 7) | `azurerm_monitor_diagnostic_setting.appgw` = `diag-appgw-to-platform-law` | root-level azurerm, in state |

   `corp-a1` and `corp-a2` (Steps 5 and 6) declare diagnostic settings only on the App Service, which is gated OFF by ADR-031/ADR-032, so those two roots created **zero** diagnostic settings and **zero** private endpoints. They are clean by construction. No root before Step 8 creates a private endpoint at all, so the zone-group conflict has no earlier surface.
   **Operator check (PC-1D, cheap, read-only):** run `action=plan` on each green root and confirm zero adds of any `azurerm_monitor_diagnostic_setting`, 0 replace, 0 destroy, with only OQ-032 tag churn in the changes; and LIST the diagnostic settings on those five objects and confirm exactly one entry each. Two entries on any of them is duplicate ingestion to report, not a Terraform failure.

6. **Step 9 (`landing-zones/bank-app-p1`) is GATED on this ruling. Do not dispatch it until the decision-2 exemption unit is merged and `bank-data-p1` is green.** The same conflict awaits and the economics are worse: this root declares **four** azurerm diagnostic settings (`diag-acr-*`, `diag-aks-*`, `diag-apim-*`, `diag-sbns-*`, all through the AVM `diagnostic_settings` input, all the exact failing shape) and creates three private endpoints with module-managed zone groups. The zone-group risk is lower than Foundry's because all three are single-zone and land in the same PUT as the private endpoint, which is the b2/b3 precedent; the Foundry three-zone group was the outlier. The diagnostic-setting risk is four times bank-data-p1's per-resource exposure, AKS `allLogs` is the largest duplicate-ingestion bill in the estate, and the APIM create runs 60 to 180 minutes. **Failing on a diagnostic setting after a ninety-minute APIM provision is the single most expensive failure available in this run, and it is the failure that has now fired six times (three resources across two applies).** Dispatching Step 9 unfixed is knowingly spending the most expensive slot on a known-armed failure.

7. **OQ-021 is extended, not replaced, and its recommended option is REVERSED.** OQ-021 covers the diagnostics half of this exactly, and its Option A ("wire the platform LAW resource ID into the ALZ diagnostic-settings assignment parameter") is now shown to be **actively harmful if landed alone**: it converts a DINE that currently fails harmlessly into one that successfully writes a second `setByPolicy-LogAnalytics` setting onto every resource in the estate, including all 8 whose diagnostics Terraform owns. That means duplicate ingestion estate-wide AND it arms this exact RequiresImport failure on every future rebuild of every spoke. Option A is only safe when paired with decision 2's exemptions, and the two must land together or not at all. The private-DNS zone-group half is a DIFFERENT policy family and is NOT covered by OQ-021, so it goes to a new **OQ-067** together with the unresolved provenance sub-question.

**Alternatives considered:**

- **Full estate teardown and restart from Step 1 (the literal reading of ADR-067's addendum).** Rejected. It would discard seven green roots and roughly 1,391 applied resources to remove three objects that a single DELETE call each removes, and the restart would land in exactly the same place because the competing writer is a policy assignment that survives teardown. Reading the addendum as "any failure anywhere means teardown" also makes the runbook's own B5 and B7b rows (both "single rerun of the same root") dead letters, and this same rebuild already recovered Step 1's `PolicyAssignmentNotFound` by diagnostic-plan-then-retry without anyone calling for a teardown.
- **Config-driven `import` of the three settings.** Rejected on two independent grounds. It is forbidden outright by ADR-067's addendum, and it is worse than deleting even if it were allowed: if D1 shows the live names are `setByPolicy-LogAnalytics`, the import would adopt a DINE-owned object under a Terraform address, leaving the policy free to keep rewriting a resource Terraform believes it controls.
- **A third bare retry on the standing "known transient class" disposition.** Rejected. U5 has fired, and the class is not transient in the way that disposition assumed: a competing writer with a live policy assignment behind it recurs by design, not by timing.
- **Fork the three AVM modules to inject a `time_sleep` before the diagnostic settings.** Rejected. It buys AVM divergence and a maintenance tail against a symptom, and it does not touch the private DNS zone group conflict at all. Retained as the fallback ONLY if the exemptions land and the failure still recurs, in which case the correct shape is not a fork but moving those three settings to root-level `azapi_resource` (which PUTs idempotently and has no RequiresImport pre-check, and is precisely why the datalake setting never failed).
- **Turn the AVM `diagnostic_settings` inputs off and let DINE own diagnostics.** Rejected. See decision 1.
- **Accept the duplicates.** Rejected. It is not available for zone groups (only one per private endpoint), and for diagnostics it means paying twice, indefinitely, for identical rows.

**Consequences:**

- Positive: one writer per object class, so the failure cannot recur by design rather than by timing. The estate keeps its in-code observability wiring and its DINE governance signal everywhere Terraform is not the writer. Seven green roots survive. The B1-versus-ADR-067 boundary is now a written test instead of a judgement call. The `deployedByPolicy` zone-group hazard is caught before Step 9 rather than after a 90-minute APIM create.
- Negative / trade-offs: two more policy exemptions per affected root, which is real governance surface that a reviewer must be able to justify (the `Mitigated` category and the description field carry that justification). Another 300s propagation sleep in the apply path. Step 9 is delayed by the code change plus its reviewer gate. Any resource in an exempted RG that Terraform does NOT give a diagnostic setting will now have none at all, which is a deliberate trade and must be listed in the exemption description.
- Follow-ups required:
  1. Cloud Engineer implements decision 2 in `landing-zones/bank-data-p1` and `landing-zones/bank-app-p1` after D3 supplies the real assignment names and reference ids. One PR, both roots, reviewer gate.
  2. Operator runs D1, D2, D3 and records the answers in OQ-067; runs R1 and R2; then R4.
  3. Architect appends the retry disposition to `docs/preclearance/2026-07-22-full-estate-rebuild.md` (done in the same commit as this ADR: addendum 2026-07-31 B, PC-1DINE through PC-5DINE).
  4. DevSecOps amends the runbook: PC-8S row `Deploy-Private-DNS-Zones` must stop reading "post-apply drift only, never a create blocker", and matrix 3d needs a row for this failure class pointing at B1 and at this ADR.
  5. QA adds the duplicate-diagnostic-setting audit (decision 5's PC-1D LIST half) to the per-root acceptance criteria; it is a FinOps finding, not a pass/fail gate.
  6. OQ-021 and OQ-067 are answered together, not separately, since landing either half alone is worse than landing neither.

**ADDENDUM 2026-07-31 (the decision is IMPLEMENTED, and the scope of what it fixes is bounded. Body above unedited, per append-only.)**

- **Landed:** `b4c058e` (PR #67), merged to `banking` as `68080b8` on 2026-07-31. 11 files across
  `landing-zones/bank-data-p1` and `landing-zones/bank-app-p1`: `policy_exemptions.tf` in both roots
  (the `azurerm_resource_group_policy_exemption.dine_ownership` map, category `Mitigated`, gated on the
  new `enable_dine_ownership_exemptions` variable, plus the NEW separate
  `time_sleep.wait_dine_ownership_exemptions` at 300s that decision 2 required), `variables.tf` in both
  roots, and `depends_on` edges plus point-of-use comments in `ai.tf`, `databricks.tf`, `datalake.tf`,
  `acr.tf`, `aks.tf`, `apim.tf` and `messaging.tf`. Code-reviewer APPROVED after one BLOCK-and-fix
  round. Decisions 1, 2 and 6 are implemented; decisions 3, 4, 5 and 7 were operator and gate actions
  needing no code and are discharged. **This supersedes the `NOT IMPLEMENTED` in the field above,
  which was accurate when written.**
  **Same parser caveat as ADR-069's addendum:** `scripts/check-adr-landed.sh` keeps the FIRST
  `- **Landed:**` line in each ADR block, so it will keep reporting ADR-070 as `NOT IMPLEMENTED` until
  that parser takes the LAST one instead. Do not resolve that by editing the body. The append-only rule
  is the more important of the two and the parser is the thing that should move (DevSecOps finding F10
  in the 2026-07-22 rebuild pre-clearance refresh #3).

- **Bounding what this ADR fixed, so the record does not overclaim.** The exemptions are correct and the
  private-DNS-zone-group half is load-bearing (only one zone group per private endpoint, and the Foundry
  PE needs three zones where the policy deploys one). **They did not and could not fix the failed
  applies that prompted the ADR.** The code-reviewer proved from pinned azurerm v4.71.0 source that the
  existence check GETs the exact configured name, so a `setByPolicy-LogAnalytics` object cannot collide
  with a `diag-*` one; and `diag-aks-*` later failed on a resource type no DINE in this tenant covers at
  all. The `already exists` class is ruled separately in **ADR-071**, which names it, excludes DINE,
  and puts the permanent fix at teardown rather than in these roots. ADR-070 decision 7 (OQ-021 Option A
  is only safe paired with these exemptions) is unaffected and still stands - it is arguably
  strengthened, because the three DINE `PolicyDeployment_*` that hung for 122 minutes against the
  zero-GUID placeholder workspace were cancelled on 2026-07-31, discharging PC-3DINE.

### ADR-069: `centralus` becomes the PRIMARY region and `eastus2` the secondary/DR. The region pair was never actually decided - OQ-004 was raised at bootstrap and never answered, so `PROMPT.md`'s suggestion became the config by default and four separate capacity workarounds accumulated around a primary region that could not serve the estate. Resolves OQ-004.

- **Date:** 2026-07-30
- **Section:** 3 (Multi-Region DR Topology), with surface in every root. **Resolves OQ-004** (region
  pair selection, raised at bootstrap, never answered). Does NOT supersede ADR-009 (firewall policy
  hierarchy - that ruling is about AVM module capability, not geography). Does NOT lift ADR-031 (SQL
  gate) or ADR-032 (App Service gate) - see decision 5. RETIRES the region half of the ADR-051
  post-apply correction (AI Search `search_location`) and of the ADR-048 Fabric `fabric_location`
  deviation, by making both equal to the primary region. Constrained by ADR-060 (sequential
  single-target rebuild with a per-root plan-scan gate), ADR-066 and ADR-068 (teardown must reach
  green VERIFY and Phase 4 state reset before this can be dispatched - decision 6). Applies LESSON 26
  (ForceNew replace on a live resource is a STOP), LESSON 42 (offer caps are a separate axis from
  quota) and LESSON 43 (regional co-location constraints resolve only at apply).
- **Status:** Accepted (user ruling on the region; architect ruling on the change surface,
  the interactions, and the dispatch gate). Implementation handed to cloud-engineer, then
  devsecops-engineer, then Code Review.
- **Landed:** NOT IMPLEMENTED. This ADR is a written spec; no `.tf`, `.yml` or `.tfvars` has been
  edited. The implementation surface is `docs/region-flip-centralus-primary.md` section 9. Update
  this field by dated addendum when the cloud-engineer PR merges.
- **Decision makers:** user (ruled the region flip and identified that the accumulation of
  workarounds was itself the finding); claude (architect - change-surface classification, the
  load-bearing-versus-cosmetic test, the interaction rulings, the evidence ledger, the dispatch gate).

**Context:**

`envs/poc.tfvars` has read `primary_location = "eastus2"` / `secondary_location = "centralus"` since
the scaffold. Four independent capacity constraints have been found in eastus2 on this tenant, and
every one was handled as a point fix rather than as evidence about the region choice:

| Constraint | Response at the time |
|---|---|
| AI Search `InsufficientResourcesAvailable` in eastus2 (live capacity shortage, apply `29678062833`, 2026-07-19) | added a `search_location` variable and deployed Search in **centralus**, leaving the private endpoint in the eastus2 spoke as a documented cross-region PE (ADR-051 correction, deviation register d7) |
| Microsoft Fabric CU quota 0 in eastus2 (portal-verified 2026-07-19) | added a `fabric_location` variable and deployed the F2 capacity in **centralus** (ADR-048, deviation d6) |
| Total Regional vCPUs limit of 10 in the landingzones subscription, eastus2 | filed a quota increase 2026-07-18 (OQ-043); AKS pinned to 3 x `Standard_D2s_v4` to fit 6 of 10 |
| Azure SQL `ProvisioningDisabled` and dedicated App Service compute quota 0 | gated both tiers off (ADR-031, ADR-032) |

Two of those four were resolved **by moving the workload to centralus**. Nobody then asked the
obvious question.

**Why nobody caught it, established from the record rather than assumed.** There is no ADR making
the region choice. `DECISIONS.md` contains no region-pair decision at all. `PROMPT.md:66` states
"**Primary region:** `eastus2` - **Secondary/DR region:** `centralus` (or `westus3`)" as a
suggestion, and `OQ-004: Region pair selection for DR` was raised at bootstrap asking the user to
"Confirm or override" - and, uniquely among the resolved bootstrap questions OQ-001 through OQ-008,
**it carries no `RESOLVED:` line**. The suggestion became the configuration by default, and because
no decision record existed, there was nothing for the four subsequent capacity findings to be
weighed against. Each one was locally correct and the aggregate was never assessed. **That is the
generalisable failure: a default that is never converted into a decision cannot accumulate evidence
against itself.**

**Decision:**

**1. `primary_location = "centralus"`, `secondary_location = "eastus2"`.** The full implementation
surface, with per-line dispositions, is `docs/region-flip-centralus-primary.md`. OQ-004 is resolved
by this ADR.

**2. The change is a 3-value functional change plus a 12-file text pass, not a 2-line change and not
a 12-file change.** There are exactly 16 region literals across 12 files. The test that separates
them: `_tf-root.yml` passes `-var-file=envs/poc.tfvars` to every deploy root (lines 351/366/397), and
`plan-on-pr.yml` does the same (line 146), so **a root default is load-bearing if and only if
`envs/poc.tfvars` does not declare a variable of that exact name.** Twelve of the sixteen are
therefore cosmetic. Four are load-bearing:

- `platform/identity/variables.tf:223` `identity_location` - **MUST change to centralus.** This is
  the one that breaks the estate silently: left at eastus2 the plan is clean, the apply is green, and
  the identity pillar including the Entra DS managed domain lands in the DR region peered
  cross-region to a centralus hub. AADDS cannot be moved after creation (Microsoft Entra Domain
  Services FAQ, fetched 2026-07-30), and its create is the 1-3 hour long pole of the estate.
- `landing-zones/bank-data-p1/variables.tf:168` `search_location` and `:146` `fabric_location` -
  value already `centralus`, which is correct after the flip; descriptions must be rewritten
  (decision 4).
- `bootstrap/variables.tf:44` `primary_location` - **must NOT change** (decision 3).

The twelve cosmetic defaults are still aligned, as zero-plan-delta text: a default that disagrees
with the tfvars means a local `terraform plan` without `-var-file` silently targets the wrong region,
which is the same class of defect as `identity_location`.

**3. `envs/poc.tfvars` becomes the SINGLE declaration point for every region-valued input.** It gains
explicit `identity_location`, `fabric_location` and `search_location` entries alongside the two
flipped lines. This is the governance half of the ruling and it is not optional: the reason this ADR
exists is that a load-bearing region input lived where nobody looked while the file people do read
appeared to declare the whole region surface and did not. No new risk - `envs/poc.tfvars` already
carries many variables most roots do not declare, and Terraform warns rather than errors on an
undeclared variable in a `-var-file`.

**4. The bootstrap state backend STAYS in eastus2. The `eus2` name token becomes cosmetically stale
and that is accepted, with a written reason.** `rg-tfstate-mgmt-eus2-001` and
`id-tfstate-mgmt-eus2-001` are literal names; `envs/poc.backend.hcl:24` hardcodes the RG. Reasons, in
order of force: (a) `azurerm_key_vault.tfstate` is `purge_protection_enabled = true` with 90-day
soft-delete retention, so a purge-protected vault **cannot be purged** and the name
`kv-globaris-tfstate-01` would be blocked for 90 days after a delete - a LESSON 57 class failure that
no retry recovers; (b) state is a management-plane dependency with no data-plane coupling, no
latency requirement, no policy scope and no role in the DR story, reached from a GitHub-hosted runner
over the public internet through the ADR-025 JIT firewall flip; (c) **anti-correlation is the better
posture, not merely a tolerable one** - keeping the state backend out of the primary workload region
means a centralus regional event still leaves state readable, so the estate can be planned and
applied during the incident; (d) the move means destroying the state SA, the CMK vault and the UAMI,
rewriting the backend config, and `-migrate-state` across eleven roots, on the one layer deliberately
excluded from teardown. A note goes in `bootstrap/main.tf` and `envs/poc.backend.hcl` recording that
the name is historical and the placement deliberate. A stale name with a written reason is
documentation; without one it is rot.

**5. The AI Search and Fabric carve-outs become REDUNDANT, not inverted. Keep the mechanism, keep
the value, rewrite the description.** After the flip `search_location` and `fabric_location` both
equal `primary_location`, so the AI Search private endpoint stops being cross-region (the PE NIC and
the service are both in centralus) and deviations d6/d7 are retired by construction. Specifically:
**keep both variables** (they are the proven capacity escape hatch, and deleting a mechanism the
moment its trigger stops firing is how a lesson gets un-learned); **keep the PE's
`location = var.primary_location` override**, which is now numerically a no-op but is the line that
pins the NIC to the subnet region and whose removal re-arms the exact module-default collision that
failed apply `29678062833`; **rewrite both descriptions**, which currently assert a cross-region PE
that will not exist and cite eastus2 as capacity-short for services that will no longer be deployed
there. A false description on a load-bearing variable is worse than none.

**6. BLOCKING GATE: the flip is authored and merged now, and is NOT dispatched until a teardown has
genuinely completed.** Teardown run `30597640251` **FAILED** (found 2026-07-30 while writing this
ADR, prompted by the operator asking why `platform/security` was skipped). Phase 2 AZ SWEEP failed
at step 4-pre on an ARM 500 listing MG-scope budgets, Phase 3 VERIFY failed, and **Phase 4 STATE
RESET was skipped**, so every state blob is still populated - including `platform/connectivity`'s
543 resources from the cancelled Step 4 apply. The eleven Phase 1 `terraform destroy` jobs were
skipped because `mode=az-sweep` gates them off (`teardown.yml:408` and its ten siblings); security
was not singled out. Because az-sweep died at step 4-pre, steps 6, 7 and **7b never ran**, and 7b is
the Security LAW purge backstop - while the primary purge
(`platform/security/providers.tf permanently_delete_on_destroy = true`) only fires on that root's own
terraform destroy. **Neither purge ran, so the estate now sits in exactly the ADR-067 Class 2 /
OQ-063 condition that blocked the 2026-07-29 rebuild.** The MG hierarchy is still live and the
subscription-scope survivor class (ADR-057) was never swept.

This matters to the flip specifically because the flip's safety rests on the estate being greenfield:
the AVM hub module derives `fw-hub-${location}-001` from its location input, so on a LIVE estate the
flip force-replaces both firewalls, both policies and every hub route table - the unconditional STOP
of LESSON 26 and Rule 1. Gate G-1 through G-6 are specified in
`docs/region-flip-centralus-primary.md` section 8.0; the short form is: re-run teardown to green
(preferring `mode=terraform` per ADR-066 so the native LAW purge fires), Phase 4 must EXECUTE not
skip, independent qa greenfield confirmation, PC-1SEC re-verified, the four unpurgeable
`kv-sec-globaris-*` vaults dispositioned, and the six submitted RG deletes confirmed complete. None
of this is caused by the flip; it is pre-existing teardown debt the flip must not be dispatched on
top of.

**7. ADR-031 and ADR-032 are NOT lifted. Both gates stay `false`.** Their justification survives the
flip, and the reasoning is the axis distinction LESSON 42 codifies. ADR-032 established with two
portal quota exports that eastus2 IaaS/compute quota was **healthy** and that the App Service failure
was therefore "an **offer cap** on dedicated App Service (Basic and above)" attaching to the
subscription's offer type, generalising to "the `landingzones` subscription is compute-restricted for
dedicated / reserved resources". ADR-031 predicted SQL `ProvisioningDisabled` in centralus before
testing it, and corp-a2 has shipped `enable_sql = false` in centralus on that basis since
2026-07-10. **Changing the region does not change the subscription.** Any re-enable is a separate
decision requiring a live probe, registered as OQ-066 items 6 and 7 with a recommended default of
"leave both false for this rebuild".

**8. ADR-009 is unaffected and is not superseded.** Its ruling (independent Firewall Policy per hub,
no shared parent) turns on the AVM hub module not exposing `base_policy_id` - module capability, not
geography. The three rule collection groups still attach to the PRIMARY policy only, and the spoke
UDRs still point at `10.0.0.4`, which is pinned by `hub_primary_address_space = 10.0.0.0/16`
regardless of which region "primary" names, so the ADR-042 firewall-IP contract and PC-3X are
unchanged. Only the word `eastus2` in the three justification comments becomes `centralus`.

**9. The 14-step order does not change; the four plan bars are expected to hold BY CONSTRUCTION but
are NO LONGER VERIFIED and must be re-measured.** No resource in the estate is conditional on region,
and the five region-templated private DNS zones are RENAMED rather than added or removed (the AVM
module substitutes `{regionName}`/`{regionCode}`; centralus geo code `cus`), so the 89-zone PC-4C
count and the 537 / 36 / 48 / 696 counts should be identical. But 696 is worded in the runbook as
"EXACTLY 696... not an estimate, it is today's verified dry-plan", and that precedent was measured
under eastus2-primary. **Rule: plan every root before its apply (already mandatory under ADR-060);
an identical count is recorded as re-verified under centralus-primary; a count differing by even one
is a STOP requiring an architect disposition, never a silent bar update** - a delta means something
region-conditional exists that this analysis did not find, which is the exact information the bar
exists to surface.

**10. What must be verified live before dispatch, because it is ASSUMED rather than evidenced.** The
evidence base is asymmetric: almost everything on record shows eastus2 is SHORT, not that centralus
is LONG. Centralus is EVIDENCED by this estate's own green applies for VNet/NSG/route
tables/peering, Azure Firewall Premium and policy, GeoRedundant RSV, storage, `NetworkWatcher_centralus`,
Fabric F2 and AI Search basic; and by vendor documentation (fetched 2026-07-30) for availability
zones, pairing with East US 2 (symmetric, so geo-redundancy survives the flip), non-restricted
status, and Static Web Apps support. It is **ASSUMED** for: compute vCPU quota (the 2026-07-18
increase was filed for eastus2 and quota is per-region - **highest risk of the flip**, AKS needs 6
vCPUs steady and 8 on surge against a limit that was 10 in eastus2), Entra Domain Services
availability, the `gpt-5.4-nano` DataZoneStandard model catalog, `Standard_D2s_v4` zone
restrictions, APIM stv2, Databricks, Service Bus Premium, Event Hubs, App Gateway WAF_v2 and Log
Analytics. Checks RC-1 through RC-7 in `docs/region-flip-centralus-primary.md` section 7 are the
disposition; RC-1 to RC-4 block Step 1, RC-5 (`NetworkWatcher_centralus` and `_eastus2` both present
in `NetworkWatcherRG`, landingzones sub) blocks Steps 5 to 9 and has already blocked this estate once.
**I am read-only on live Azure and assert none of the ASSUMED set.**

**Alternatives considered:**

- **Keep eastus2 primary and continue per-service carve-outs** - rejected. This is the status quo and
  it is the thing being corrected. Two of four constraints were already resolved by moving workloads
  to centralus; a third (vCPU) is an open quota request; the design was accreting exceptions around a
  region that could not serve it.
- **Move the bootstrap state backend to centralus for consistency** - rejected, decision 4. Purge
  protection makes it a 90-day name lock, and co-locating state with the primary workload region is
  worse posture, not better.
- **Delete `search_location` and `fabric_location` now that they equal `primary_location`** -
  rejected, decision 5. Both are proven capacity escape hatches; removing the mechanism when the
  trigger stops firing is how the lesson is lost. The redundant-looking PE `location` override is
  load-bearing.
- **Re-enable `enable_sql` / `enable_app_service` on the strength of the flip** - rejected, decision
  7. The caps are subscription-offer caps, not regional quota, and ADR-031 predicted centralus would
  behave the same. Silently re-enabling on a region change would be a guess dressed as an inference.
- **Make the flip a workflow input rather than a tfvars value** - rejected, not designed. The estate
  has ONE environment and ADR-044 established reviewed-commit flag supply as the pattern. A dispatch
  input for a region would make the deployed region invisible to `plan-on-pr` and drift checks.
- **Dispatch the flip against the current partially-torn-down estate** - rejected, decision 6. It
  produces a ForceNew replace plan on live firewalls.
- **`westus3` as secondary** (the `PROMPT.md:66` alternative) - not evaluated. Out of scope; the
  user's ruling was a swap of the existing pair, and eastus2/centralus is a genuine symmetric Azure
  region pair, which `westus3` (paired with East US) is not relative to centralus.

**Consequences:**

- Positive: the estate's primary region becomes the one with the only positive capacity evidence on
  this tenant. Deviations d6 and d7 retire by construction rather than needing a B-R action. The
  AI Search cross-region private endpoint stops existing. The region surface becomes visible in one
  file. A region choice that was never a decision becomes one, with a record.
- Positive: the topology proves out its own role-based naming. Every resource name except the
  bootstrap and three module-derived families uses `primary`/`secondary` tokens, which is why a
  region flip is a data change. That is worth stating in `ARCHITECTURE.md`.
- Negative / trade-offs: the four plan bars lose verified status and must be re-measured. The
  bootstrap keeps a name token (`eus2`) that no longer describes the primary region. Roughly 30
  comments and descriptions across 12 files need inverting, and a missed one is a future operator
  misled. The highest-risk unknown (centralus compute quota) is unresolved at ADR time and could
  force `enable_kubernetes_platform = false` for this rebuild - which the design already tolerates,
  since every spoke is shippable network-only (LESSON 42).
- Negative: this ADR cannot be dispatched until unrelated teardown debt clears (decision 6).
- Follow-ups required: **OQ-066** (the live verification set RC-1..RC-7, plus the teardown gate and
  the two gate-re-enable questions). **OQ-004** resolved. `docs/b-restoration-design.md` deviations
  d6/d7 marked retired by this ADR. `ARCHITECTURE.md` region narrative updated by whoever lands the
  implementation.

**ADDENDUM 2026-07-31 (the decision is IMPLEMENTED; the Context framing is corrected; decision 3's wording is narrowed). Body above unedited, per append-only.**

- **Landed:** `91523dc` (PR #60), merged to `banking` as `fbb8e3f` on 2026-07-31. 39 files. This
  supersedes the `NOT IMPLEMENTED` in the field above, which was accurate when written.
  **Caveat on the register, not on the decision:** `scripts/check-adr-landed.sh` keeps the FIRST
  `- **Landed:**` line in each ADR block, so it will continue to report ADR-069 as
  `NOT IMPLEMENTED` until that parser is changed to take the LAST one. The same is true of ADR-068,
  which was proven live the same day. Handed to devsecops as finding F10 in
  `docs/preclearance/2026-07-22-full-estate-rebuild.md` refresh #3 (T8, listed there as F7). Do not
  resolve it by editing the body of either ADR: the append-only rule is the more important of the two
  and the parser is the thing that should move.

1. **The Context framing is wrong and should be read as corrected.** The Context table above presents
   the flip as "four independent capacity constraints accumulated in eastus2, so the region choice was
   wrong". The user corrected that framing on 2026-07-31 and the correction is the accurate one:
   **the binding constraint was AI Search.** `eastus2` returned `InsufficientResourcesAvailable`,
   Search could be obtained only in `centralus`, and it was already deployed there behind a
   cross-region private endpoint pinned back to an `eastus2` spoke. **The estate's most constrained
   service was living in the secondary region.** The vCPU quota, App Service and SQL findings were
   symptoms of a compute-restricted subscription, not causes of the region decision, which is exactly
   why decision 7 does NOT lift ADR-031 or ADR-032. This distinction is load-bearing rather than
   cosmetic: it is why the `search_location` carve-out retires **by construction** rather than
   inverting, and it is why RC-1 coming back with no improvement in the vCPU limit (10 in `centralus`,
   the same as `eastus2`) is not a contradiction of the ruling. The flip bought service availability,
   not compute capacity.

2. **Decision 3's "every region-valued input" is narrowed, and the narrowing is deliberate rather than
   an oversight.** Decision 3 says `envs/poc.tfvars` becomes "the SINGLE declaration point for every
   region-valued input". Taken literally that is false: `synthetic/variables.tf`
   `red_team_geo_location` (default `westeurope`) is a region-valued input and is correctly NOT in the
   tfvars region block. Corrected wording, which matches what was implemented and what the design
   doc's F4 lists: **`envs/poc.tfvars` is the single declaration point for every input that names the
   estate's PRIMARY or SECONDARY region.** `red_team_geo_location` is excluded on purpose, because it
   is deliberately a THIRD region - the impossible-travel pole for the Section 13.3 red-team
   simulation - and pinning it to the primary or secondary pair would destroy the signal the scenario
   exists to generate. Its distance from the estate is the feature. It is therefore a workload
   parameter, not part of the estate region surface, and it must not be swept into a future region
   flip. Count for the record: 17 region literals in repo-owned code, of which 16 name the primary or
   secondary pair (the set decision 2 classifies) and one is `red_team_geo_location`.

3. **What actually landed, versus what this ADR specified.** The implementation matched the spec on
   every load-bearing point, verified file by file in refresh #3 section T2. `envs/poc.tfvars` gained
   the three new declarations and the two flipped values; `platform/identity/variables.tf`
   `identity_location` moved to `centralus` in both the default and the tfvars, closing the silent
   failure this ADR was principally written to prevent; the Search private endpoint's
   `location = var.primary_location` override was KEPT with a DO NOT DELETE comment; both capacity
   escape-hatch variables were kept; `bootstrap` did not move and is absent from the value diff;
   ADR-031 and ADR-032 gates stayed false. One fact the implementer established independently and
   which this ADR had not stated: **`bootstrap` receives no `-var-file` from any workflow**, so its
   default is genuinely live - which is a stronger reason for decision 4 than the three the body gives.

4. **Decision 9's plan-bar prediction is now partly evidenced.** Step 1 `platform/management-groups`
   re-planned under `centralus`-primary at 537 to add, 0 change, 0 destroy, 0 replace, 0 import
   (run `30636497926`, 2 min 36 s) - an exact match to the `eastus2`-primary bar, not an approximate
   one. Four bars remain unmeasured (36 / 48 / 696 / 26). Refresh #3 section T3 certifies all five as
   expected-unchanged from the pinned module sources, with the derivation for each. **Do not
   generalise from Step 1:** that root creates no regional resources at all, so it is the weakest
   available test of the construction argument. Decision 9's STOP rule stands unchanged and applies to
   the remaining four.

5. **Decision 6's blocking gate is DISCHARGED.** The teardown reached green, Phase 4 executed, and on
   2026-07-31 the estate and all eleven state blobs were independently confirmed greenfield. The flip
   is therefore being dispatched against exactly the precondition decision 6 required, which is the
   only condition under which the `fw-hub-${location}-001` rename is free rather than a ForceNew
   replace of both Premium firewalls.

6. **One check in the implementation surface was defective and is corrected.** RC-2 in
   `docs/region-flip-centralus-primary.md` section 7.1 queried
   `resourceTypes[?resourceType=='domainServices']`; the actual ARM type is `DomainServices`. As
   written the query returns `[]`, and this ADR's own documented consequence of an empty result is
   STOP, keep `identity_location` at `eastus2`, and give the identity pillar an explicit DR-region
   carve-out. **A one-character casing error in a verification query would have triggered a real
   architectural change in the opposite direction to the evidence.** Corrected in the design doc on
   2026-07-31. The generalisable form is worth carrying: **a check whose failure mode is an empty
   result is only as trustworthy as its exact-match string.** Same defect class as the Key Vault
   `True`/`true` compare fixed in PR #59 the same night.

---

### ADR-068: A verified `target=all` teardown ends by RESETTING every eligible Terraform state blob to a canonical, metadata-labelled EMPTY document - never by deleting it. The two mirror-image state failure modes (FM-1 state-missing-while-resources-live, FM-2 state-populated-while-resources-gone) are named, given opposite guards, and reconciled by one ordering gate

- **Date:** 2026-07-30
- **Section:** 10 (Pipeline & Tooling) / teardown + state backend. SATISFIES the pre-registered
  state-blob-deletion-ordering invariant in `scripts/teardown-common.sh` (the "FIX-6 note", 2026-07-23)
  rather than superseding it, and NARROWS it: the invariant gates a DELETE path, and this ADR rules that
  no delete path may ever exist. Builds on ADR-054 (four-phase teardown shape, VERIFY-is-the-truth-gate),
  ADR-066 (at `target=all` mode=terraform runs all 11 Phase 1 destroys serialized; mode=az-sweep kept as
  the state-gone fallback), ADR-065 decision 4 (az-sweep fallback retained), ADR-062 (discovery-based
  VERIFY, deleted-scope-403), ADR-025 (JIT state-SA firewall flip), ADR-005 (bootstrap uses LOCAL
  state), ADR-060 (sequential single-target rebuild with a per-root plan-scan gate). Answers the half of
  OQ-053 that OQ-053 itself did not ask. Enforces ADR-067's addendum (no partial-state reconciliation).
- **Status:** Accepted (architect ruling; user identified the gap during the 2026-07-30 rebuild).
  Mechanism handed to DevSecOps, then Code Review. Decision 6 (the immediate disposition) is actionable
  by the owner today and does NOT wait on the mechanism.
- **Landed:** NOT IMPLEMENTED. Decisions 1-5 are a written spec for DevSecOps; no code exists yet.
  Decision 6 is an owner-executed one-time operation whose evidence goes in WORKLOG, not in code.
  Update this field by dated addendum when the Phase 4 job merges.
- **Decision makers:** claude (architect); user (raised the gap and the "a greenfield deploy should start
  from a state backend that behaves as if it had never been used" position).

**Context:**

A `target=all` teardown deletes every Azure resource and never touches the Terraform state blobs.
`include_bootstrap=false` (the default) deliberately preserves the state Storage Account, and
`mode=az-sweep` deletes by raw ARM API with Phase 1 skipped entirely, so the state survives fully
populated. Nothing in this repository has ever emptied a state blob as part of teardown: confirmed by
the full-repo grep recorded in the `teardown-common.sh` FIX-6 note and by OQ-053's own finding that
"the three teardown scripts contain zero references to the tfstate container".

Live evidence, 2026-07-30. Teardown run `30576653339` (`target=all mode=az-sweep
include_bootstrap=false remove_mg_hierarchy=true`) completed GREEN with `VERIFY PASSED - zero estate
remnants`, and qa-engineer independently confirmed the estate greenfield (no resource groups, only the
Tenant Root management group, no exemptions, the Security Log Analytics workspace gone by both list and
direct GET, bootstrap intact). Step 1 of the rebuild was then dispatched and its `terraform plan` ran
past 25 minutes. Cause, from a listing of the `tfstate` container: `platform/management-groups` holds
8,959,166 bytes, `platform/management` 123,309 bytes, and `platform/security` 78,870 bytes, while
`corp-a1`, `corp-a2`, `online-p1`, `connectivity` and `identity` hold 181 bytes each. Three roots carry
state describing roughly 537 resources that no longer exist, and the plan is refreshing all of them.
`platform/security`'s 78 KB is the PARTIAL output of failed run `30499221661` - precisely the state
ADR-067's addendum ruled must be rebuilt rather than reconciled.

The immediate cause is narrower than it looks and is worth stating exactly. ADR-066 restored
`mode=terraform` as the PRIMARY `target=all` path, and that path runs all 11 per-root `terraform
destroy` jobs, each of which leaves its own state legitimately empty as a native side effect. The run
that produced today's condition used `mode=az-sweep`, the state-gone FALLBACK, in which Phase 1 never
executes. So the estate already has one path that ends with clean state and one that structurally
cannot. **State-blindness is the defining property of the az-sweep fallback, not an oversight in it.**
What is missing is the completion step that reconciles the fallback's outcome with the estate's state
of record, plus a general guarantee that "teardown finished" implies "state is empty" regardless of
which path ran or how many of its jobs went green.

**The two failure modes, named, because a future reader will otherwise collapse them into one.**

- **FM-1: STATE-MISSING-WHILE-RESOURCES-LIVE.** This is OQ-053. A state blob is absent or truncated
  while its Azure resources are alive. Terraform reads greenfield, plans a full create against a live
  estate, and the apply fails with `ImportAsExistsError` ("already exists - needs import"). That is the
  BENIGN presentation. The malignant one is any object type whose API tolerates duplicate names:
  `platform/identity` declares eight `azuread_conditional_access_policy` resources and an
  `azuread_named_location`, and Entra accepts duplicate conditional-access display names, so a
  create-from-empty-state against live policies yields silent DUPLICATE tenant-wide access controls
  rather than a loud error. FM-1 also destroys recoverability: a resource that exists in Azure and in
  no state file can only be reconciled by config-driven import (LESSON 46) or by raw-API deletion.
  **Guard: nothing may ever delete a state blob, and `scripts/teardown-probe-state.sh` must keep
  reporting an absent blob as a Class-A lost-state root.**
- **FM-2: STATE-POPULATED-WHILE-RESOURCES-GONE.** This ADR. State describes resources that no longer
  exist. The cheap symptom is a plan that spends minutes to tens of minutes refreshing phantom objects.
  The expensive symptoms are two. First, refresh is only self-healing when the read returns 404: this
  codebase has already documented (ADR-062) that a scoped service principal reading a DELETED management
  group scope gets a 403 `AuthorizationFailed`, not a 404, and a 403 on refresh is a hard error, not
  "the resource is gone" - so a plan can fail outright, or, where a broader grant lets some reads
  succeed, produce something other than a clean full create while still looking like a normal plan.
  Second, a PARTIAL state left by a failed apply invites exactly the partial-state reconciliation
  ADR-067's addendum forbids. **Guard: reset the state to empty after a proven destroy.**

FM-1 and FM-2 are exact mirror images, and the correct response to each is the forbidden response to
the other. "Never delete state" and "state must be empty after teardown" are only compatible under two
constraints, which this ADR makes structural rather than procedural: an ORDERING gate (the state is
emptied strictly after the destroy is proven, so the FM-1 hazard is provably absent at the moment the
emptying happens) and a REPRESENTATION choice (the state is emptied by overwrite with a labelled
document, not by deletion, so the absent-blob signal stays reserved for FM-1 alone).

**Decision:**

**1. A verified `target=all` teardown ends with Phase 4 STATE RESET. Reset means OVERWRITE with a
canonical empty state document. Deleting a state blob is FORBIDDEN, permanently, in any code path.**

The invariant, stated so it can be cited: **INV-STATE.** *Teardown may only ever overwrite a Terraform
state blob with the canonical empty document. No repository code path may delete a Terraform state
blob. Blob ABSENCE remains reserved, permanently and exclusively, as the FM-1 out-of-band-loss alarm.*

Reset-to-empty beats delete-the-blob on four counts, and the first is decisive:
- **It does not spend the alarm.** `teardown-probe-state.sh` classifies an ABSENT blob as Class-A. If
  teardown routinely deleted blobs, "absent" would become the normal post-teardown state and the FM-1
  detector would be a detector of nothing. An alarm that fires on the intended state is not an alarm.
  Deleting would collapse FM-1 and FM-2 into one indistinguishable signature, which is the single
  outcome this ADR exists to prevent.
- **It preserves lineage continuity.** A deleted blob re-created by the next `terraform init` gets a
  FRESH lineage, so the state's version history stops chaining across teardown/rebuild cycles. Reset
  preserves the existing `lineage`, so one blob's version list remains one auditable timeline.
- **It carries provenance.** An overwrite can attach blob METADATA saying who emptied it, when, from
  which run and which ref (decision 3). A deletion can say nothing at all. This is what turns "small
  blob" from an ambiguous condition into a self-describing one.
- **There is no compensating upside.** Both are equally reversible and equally effective. Verified
  today against Microsoft Learn "Blob versioning": with versioning enabled (confirmed on this account by
  OQ-053's 2026-07-21 inspection of its blob service properties, alongside 14-day blob and container
  soft delete), an overwrite makes the previous content a previous VERSION that persists and can be
  promoted back to current by copying that version onto the base blob; a delete likewise leaves previous
  versions intact with no current version. Reset therefore needs no separate backup step, and every
  reset is undoable for as long as versions are retained.

**2. The gate. Phase 4 runs only at `target=all`, strictly after Phase 3 VERIFY has PASSED, and it is
the one job in `teardown.yml` that is HARD-gated on success rather than on `!cancelled()`.**

```
state-reset:
  name: "Phase 4 - STATE RESET (canonical empty state)"
  needs: [guard, verify, synthetic, bank-data-p1, bank-app-p1, online-p1, corp-a2, corp-a1,
          security, connectivity, identity, management, management-groups]
  if: ${{ needs.guard.result == 'success' && needs.verify.result == 'success' && inputs.target == 'all' }}
  runs-on: ubuntu-latest
  environment: production-destroy
```

~~**Reviewer note, written here because it will look like a defect:** every other destructive job in
`teardown.yml` uses `!cancelled()` so one root's failure cannot cascade-skip the others (the F1 fix).
Phase 4 deliberately does NOT. Its entire safety argument is that the estate has been PROVEN empty
first, and `!cancelled()` would let it run after a failed or skipped VERIFY, which is FM-1 manufactured
on purpose. Do not normalise this job to the file convention.~~

> **ADDENDUM 2026-07-30 - the struck note above is WRONG, and so is the `if:` in the YAML block above
> it. Caught at the code-review gate before Phase 4 ever ran.**
>
> The corrected condition, which the implementation now carries:
>
> ```
> if: ${{ !cancelled() && needs.guard.result == 'success' && needs.verify.result == 'success' && inputs.target == 'all' }}
> ```
>
> **Why the original was wrong.** GitHub Actions applies an IMPLICIT `success()` requirement across
> every job listed in `needs:` unless the `if:` expression itself invokes a status-check function
> (`success()`, `failure()`, `cancelled()`, `always()`). A plain string comparison such as
> `needs.verify.result == 'success'` does NOT count as invoking one. At `mode=az-sweep` all 11 Phase-1
> jobs are gated on `inputs.mode == 'terraform'` and report `skipped`, so the implicit `success()` over
> this job's 13-entry `needs:` list fails and GitHub auto-skips Phase 4 entirely - **in the exact mode
> this ADR exists to fix**, with the run still green because a skipped job is not a failed one. An
> operator following the runbook would reset state through the teardown, watch it pass, and get nothing.
>
> **Why the safety argument survives intact.** `!cancelled()` removes only the implicit
> all-needs-must-succeed default. It does not weaken the explicit `needs.verify.result == 'success'`
> conjunct, which remains the whole gate: Phase 4 still cannot run after a failed, skipped or cancelled
> VERIFY, so FM-1 stays impossible. The two mechanisms were conflated in the original reasoning.
>
> **Corroboration in-file:** the sibling `az-sweep` and `verify` jobs depend on the same 11 Phase-1
> jobs and both carry `!cancelled()`, which is precisely why they ran in run `30576653339`
> (`mode=az-sweep`) while every Phase-1 job around them showed `skipped`. **17 of the 18 jobs** in
> `teardown.yml` carry `!cancelled()` on their job-level `if:` (verified with
> `grep -E '^    if: .*!cancelled\(\)'`); the only job without one is `guard`, which has no `if:` at
> all because it is the entry job with no dependencies. The first draft of `state-reset` was the sole
> job with an `if:` that omitted it.
>
> Also amended: `mode=terraform` per-root eligibility now behaves as decision 4 always intended - a
> single failed Phase-1 destroy no longer cascade-skips the whole job, so roots that DID destroy
> cleanly still get reset while the failed one is correctly excluded by the per-key check.

This satisfies the pre-registered FIX-6 ordering invariant on both of its limbs, without weakening
either:
- In `mode=terraform`, limb 1 (`terraform state list` empty from a Phase 1 success) is available
  per root and is used per root (decision 4).
- In `mode=az-sweep`, limb 2 (a completed az-sweep with confirm-GET 404 on every class at that root's
  scopes) is exactly what Phase 3 VERIFY asserts, and asserts more broadly than the sweep deletes
  (ADR-062: VERIFY is discovery-gated, strictly broader than the enumerated sweep classes).
- The "strictly after Phase 3 VERIFY has passed for target=all" clause is the `if:` above, literally.

A green whole-estate VERIFY is STRONGER evidence than a per-root empty `terraform state list`, because
it is an assertion about Azure rather than about a state file. That is why it is the primary gate. It
is not, however, a COMPLETE oracle for every root, which is what decision 4 is about.

**3. The canonical empty state document, and the metadata label that makes it self-describing.**

For each eligible key, read the existing blob first and write back:

```json
{"version":4,"terraform_version":"<preserved from the blob>","serial":<existing serial + 1>,
 "lineage":"<preserved from the blob>","outputs":{},"resources":[],"check_results":null}
```

Verified: state format `version` 4 is the current format for Terraform 1.x, and `resources: []`,
`outputs: {}`, `check_results: null` is the documented minimal empty form. `terraform_version` MUST NOT
exceed the CLI version the pipeline pins (`1.15.6`, `hashicorp/setup-terraform@v3` in `_tf-root.yml`) -
Terraform refuses to operate on a state stamped by a newer version. Preserving the value read from the
blob satisfies that automatically, because this same pipeline wrote it. Fall back to `1.15.6` only when
the blob is absent or carries no readable version. Incrementing `serial` keeps the sequence monotonic;
`lineage` is preserved so the blob's version history stays one chain (decision 1).

Attach blob metadata on the upload:

```
--metadata tf_state_reset=true \
           tf_state_reset_run_id="$GITHUB_RUN_ID" \
           tf_state_reset_utc="<ISO-8601 UTC>" \
           tf_state_reset_mode="$TEARDOWN_MODE" \
           tf_state_reset_ref="$GITHUB_SHA"
```

Metadata names must be valid C# identifiers (letters, digits, underscore, no leading digit); these are.
Note the deliberate lifetime: the azurerm backend's own writes do not preserve custom metadata, so the
label vanishes the first time the root is applied again. That is correct, not a defect - the marker's
useful life is exactly the window between teardown and the next apply, which is exactly the window in
which "is this blob empty on purpose?" is a live question.

**4. Which roots. Eligibility is per root and derives from the evidence THIS run actually produced. Two
carve-outs are permanent, and both exist because VERIFY's coverage is real but bounded.**

Base set: the 11 workload/platform keys already enumerated in `teardown-probe-state.sh`. The bootstrap
key is NEVER written, in either value of `include_bootstrap` (decision 5).

- **`mode=terraform`:** reset root R only if R's own Phase 1 destroy job result is `success`. A
  `failure` or `skipped` result excludes R and prints a loud `::warning::` naming it. This is redundant
  belt over VERIFY, and cheap, and it is limb 1 of the pre-registered invariant honoured literally.
  Note the resets here are near no-ops: a successful `terraform destroy` already leaves the state
  empty. Phase 4 in this mode is a NORMALISER, making "post-teardown state is canonical empty" a
  property of the teardown rather than a property of 11 destroys all having gone green.
- **`mode=az-sweep`:** Phase 1 never ran, so every root's state is fully populated and eligibility comes
  from VERIFY plus the two carve-outs. This is the load-bearing case.
- **CARVE-OUT A (permanent): `platform/identity` is NEVER reset in `mode=az-sweep`.** That root declares
  eight `azuread_conditional_access_policy` resources, an `azuread_named_location`,
  `azurerm_pim_eligible_role_assignment` and `azurerm_role_management_policy` (verified in
  `platform/identity/main.tf` and `pim.tf`). The az-sweep is ARM-only and deletes none of them, and
  `teardown-verify.sh` contains no Entra, Graph or PIM check at all (verified: VERIFY 0 through 10 are
  ARM-plane only). So a green VERIFY says NOTHING about whether those objects are still live, and
  resetting identity's state on that evidence is FM-1 by construction - and lands on precisely the
  duplicate-tolerant object type that fails silently rather than loudly. In `mode=terraform`, identity
  IS eligible, because its own `terraform destroy` deletes the Entra objects through the azuread
  provider and its job result is direct evidence.
- **CARVE-OUT B (conditional): `platform/management-groups` is reset only when
  `remove_mg_hierarchy == true`.** When that input is false the management-group tree survives, and with
  it every MG-scoped policy and set definition that root owns. VERIFY 4 explicitly SKIPS its MG check in
  that case, and says so. Resetting on a skipped check is resetting on no evidence.
- Roots already at the empty floor are re-written idempotently. This is not wasted work: it normalises
  serial, clears any residual `outputs`, and stamps the provenance metadata.

The general rule these carve-outs instantiate, so future roots inherit it rather than needing a new
ADR: **a root's state may be reset only if that root's ENTIRE resource footprint is covered by the
evidence this run's mode actually produced.** Any new root that manages objects outside the ARM plane
(Entra, Graph, a SaaS provider) is ineligible under `mode=az-sweep` until VERIFY can see them.

**5. `include_bootstrap` does not interact with Phase 4, and must not be made to.**

The bootstrap root uses LOCAL state (ADR-005) and has never written to the remote container, so
`bootstrap/terraform.tfstate` is out of scope at both values of the flag. With
`include_bootstrap=false` (the default) the state Storage Account survives and Phase 4 is exactly the
step the estate needs. With `include_bootstrap=true` the account is being scorched by the manual
runbook anyway, so Phase 4 having already run is harmless. One unconditional behaviour, no branch, no
input coupling. `mode` is the only input Phase 4 reads besides `remove_mg_hierarchy` and `target`.

**6. DISPOSITION FOR RIGHT NOW (2026-07-30, three stale blobs, rebuild mid-flight at Step 1): option
(b), a scoped one-time reset, executed by the owner as a bounded and explicitly authorised exception to
the CI-only rule. Do NOT re-run teardown. Do NOT proceed on stale state.**

*(a) Implement the mechanism, re-run teardown, then rebuild - REJECTED on cost, not on principle.* It
buys the rebuild nothing that (b) does not. Re-running teardown against an estate already verified
greenfield is a 30-to-60-minute no-op sweep, and it cannot fix the state at all unless the Phase 4 job
is merged first, which puts implementation plus code review plus merge on the critical path for an end
state that is byte-identical to (b). That is most of a working day spent to arrive at the same three
empty blobs. The mechanism is still REQUIRED; it is simply not required TODAY.

*(c) Proceed on stale state - REJECTED on correctness, not on speed.* Two of the three blobs must be
emptied whatever one thinks of the refresh cost. `platform/security`'s 78 KB is the partial state
ADR-067's addendum ruled must be rebuilt rather than reconciled, so applying over it contradicts a
standing ruling (decision 7). `platform/management-groups`' 8.9 MB is being refreshed against
management-group scopes that no longer exist, and this codebase has already documented (ADR-062) that
the scoped CI principal gets a 403 rather than a 404 on a deleted scope - a refresh that 403s is a hard
error, and where a broader grant lets some reads succeed the resulting plan is not a clean full create
while still looking like a normal plan. The problem with (c) is not that the plan is slow. It is that
the plan is untrustworthy, on the root every other root depends on.

*(b) One-time reset - ADOPTED.* Cost is minutes. It is safe for exactly one reason that will not
generally hold, and that reason must be re-established every time anyone invokes this precedent: **the
estate is independently verified greenfield right now** - teardown run `30576653339` GREEN with `VERIFY
PASSED - zero estate remnants`, plus an independent qa-engineer confirmation including a direct GET on
the Security Log Analytics workspace. FM-1, the hazard that makes hand-editing state dangerous, is
provably absent at this moment. Without that evidence in hand the exception is void and the answer
reverts to (a).

Scope of the exception, exactly, and nothing beyond it:
- Exactly three keys: `platform/management-groups/terraform.tfstate`,
  `platform/management/terraform.tfstate`, `platform/security/terraform.tfstate`.
- Overwrite with the decision-3 document, preserving each blob's existing `lineage` and
  `terraform_version`, `serial` = existing + 1. Never delete.
- Same metadata as decision 3, plus `tf_state_reset_manual=true` and
  `tf_state_reset_authority=ADR-068`, so the probe and any later reader can tell a one-time operator
  reset from a CI reset.
- Do NOT touch `platform/identity`, `platform/connectivity`, the five spokes or `synthetic`. All are
  already at 181 bytes; touching them widens the exception for no benefit, and identity is carve-out A.
- CANCEL the in-flight Step 1 plan run FIRST. The azurerm backend holds a lease on the
  management-groups blob while that run is open, and the overwrite will fail 412 `LeaseIdMissing`
  against a leased blob. Cancel, confirm the lease is released, then write.
- Record it in WORKLOG: the cancelled run ID, the three keys, before and after byte counts, and the
  version IDs of the superseded versions (`az storage blob list --include v`), so the operation is
  auditable and individually reversible.

Who executes: the OWNER, from the workstation whose IPv4 already sits in the state SA `ip_rules`
(`bootstrap/main.tf`), authenticated as a principal holding Storage Blob Data Contributor. This is the
same route the operator used on 2026-07-29 to reset the security blob to 181 bytes, which is both the
precedent that the need is real and the instance of manual drift that decisions 1-5 exist to retire. If
that route is unavailable, the fallback is (a) - land Phase 4, dispatch teardown once more. It is the
fallback, not the plan.

**Evidence that would change this ruling, stated in advance:**
1. If the in-flight Step 1 plan has ALREADY completed with exactly the expected shape - 537 add / 0
   change / 0 destroy, matching the previously qa-PASSed Step 1 - that plan is trustworthy and should
   be applied rather than discarded. The management-groups reset then becomes unnecessary; `management`
   and `security` are still reset before Steps 2 and 3.
2. If the plan log shows ANY `AuthorizationFailed` or 403 on a `Microsoft.Management/managementGroups/`
   read, the deleted-scope-403 hypothesis is confirmed and the reset moves from preferred to mandatory.
3. If a `terraform state list` on any of the three roots shows a resource class VERIFY does not cover -
   an Entra object, a PIM assignment - STOP. That root is FM-1 territory and must be destroyed
   properly, not reset.

**7. `platform/security` CANNOT be applied from its 78 KB partial state. Reset it to empty before Step
3.** Three independent reasons, any one sufficient:
- ADR-067's addendum is a standing ruling from a user process change: any layer failure means a full
  teardown-and-restart from Step 1, with no import-and-continue and no partial-state reconciliation.
  Applying over the 78 KB IS partial-state reconciliation.
- The state is 100% phantom. Every resource it describes was deleted by teardown run `30576653339`, and
  qa confirmed the Security Log Analytics workspace gone by list AND by direct GET. There is nothing in
  it worth preserving.
- It is worse than merely useless. Its Sentinel child addresses point at a workspace resource ID that
  no longer exists, and its subscription-scope entries (Defender pricing plans, `Microsoft.Security`
  singletons) are refreshed at scopes whose grants have changed - the FM-2 403 hazard again, on a root
  that has already cost three fix cycles.

Confirmed on the current `banking` tree so Step 3 runs as a genuine first apply with every ADR-067 and
OQ-063 fix in place: `platform/security/providers.tf` sets
`log_analytics_workspace.permanently_delete_on_destroy = true`; `platform/security/sentinel.tf` carries
`depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]` on both automation rules; and
`_tf-root.yml` passes `-parallelism=1` for `inputs.root == 'platform/security'`.

**Alternatives considered:**

- **Delete the state blob and let `terraform init` re-create it** - rejected. It destroys the FM-1
  alarm by making "absent" the intended post-teardown state, breaks lineage continuity, and can carry
  no provenance. See decision 1 for the full four-count comparison. It has no advantage over overwrite.
- **Reset unconditionally at teardown dispatch, before any destroy** - rejected outright. That IS FM-1,
  deliberately manufactured, and it is the exact condition OQ-053 was raised about.
- **Reset per root inside Phase 1, immediately after each `terraform destroy`** - rejected. It would
  cover only `mode=terraform`, which is the mode that least needs it (destroy already empties state),
  and would leave `mode=az-sweep`, the mode that entirely needs it, untouched. It would also empty
  state before the whole-estate VERIFY had run, forfeiting the stronger evidence for the weaker.
- **Extend Phase 3 VERIFY to also reset** - rejected. VERIFY is read-only by charter and that is why
  its output can be trusted as the truth gate (ADR-054). A verifier that mutates cannot be its own
  oracle. Phase 4 is a separate job precisely so VERIFY's green remains the input to the mutation, not
  a claim about it.
- **Make the reset an operator-run script rather than a CI job** - rejected. That is the standing
  manual step this ADR exists to retire, and the 2026-07-29 security-blob reset is the evidence it does
  not stay contained. Decision 6 authorises exactly one more instance, bounded and dated.
- **Give the probe a "post-teardown" mode instead of labelling the blob** - rejected. It would require
  the probe's caller to already know the answer to the question the probe is asked. Metadata puts the
  answer on the artefact itself, where any reader finds it without context.

**Consequences:**

- Positive: a `target=all` teardown that goes green now delivers what the user asked for - a state
  backend that behaves as if it had never been used - and delivers it identically in both modes. FM-2
  cannot survive a green teardown.
- Positive: the FM-1 detector is strengthened, not weakened. Absence stays Class-A forever; and a
  deliberately emptied blob is now positively LABELLED rather than merely being coincidentally above a
  size threshold.
- Positive: the probe/reset contradiction the user anticipated does not materialise, and the reason is
  worth recording. `TINY_BLOB_THRESHOLD_BYTES` is 100, chosen because "a genuinely empty-but-valid
  Terraform state ... typically 150-250 bytes". The canonical empty document lands in that band (the
  observed floor in this container is 181 bytes), so it reads as `OK present`, not Class-A. That is the
  threshold's author having anticipated this exact state. Decision 8 below removes the coincidence.
- Negative / trade-off: `mode=az-sweep` still cannot deliver a clean `platform/identity` slate, because
  carve-out A holds its state populated while its Entra objects may be live. That is a smaller, honest
  gap replacing a larger dishonest one, and it is tracked in OQ-065 limb A with a zero-code workaround.
- Negative / trade-off: Phase 4 needs its own JIT state-SA firewall flip, so a teardown now opens that
  account once more per run. Safe by construction (Phase 4 runs after every other state-touching job,
  so exactly one flip is ever open - LESSON 31), but it is one more window.
- Negative / trade-off: every reset writes a new blob version, so the state container accumulates
  versions at one per root per teardown. Negligible at POC volume; worth a lifecycle-management rule if
  the estate ever runs many teardowns.
- Negative / trade-off: a failed Phase 4 now fails a teardown run whose estate destruction genuinely
  succeeded. That is intended - a half-reset state backend is a condition an operator must see - but it
  means "teardown red" no longer implies "resources remain". The job name and its error text must say
  so explicitly.

**Follow-ups required (DevSecOps lane; this is the whole implementation spec):**

**8. Couple the reset and the probe in ONE place so they cannot drift.** This is the same discipline
`is_owned_policy_object` already established for the exemption predicate, and it is the durable answer
to the contradiction. Promote into `scripts/teardown-common.sh`, consumed by BOTH
`teardown-probe-state.sh` and the new `teardown-state-reset.sh`:
- `STATE_KEYS_WORKLOAD` (the 11 keys) and `BOOTSTRAP_STATE_KEY`, moved out of the probe.
- `TINY_BLOB_THRESHOLD_BYTES`, moved out of the probe.
- `state_backend_load()` - the `envs/poc.backend.hcl` parse for SA name, RG and container, currently
  three inline `grep`/`sed` lines in the probe.
- `canonical_empty_state_json <terraform_version> <serial> <lineage>` - the ONE writer of the document,
  defined immediately next to the threshold that must accept its output, with a comment binding them.
- Amend the FIX-6 note: the pre-registered invariant is now SATISFIED, name the job that satisfies each
  limb, and record INV-STATE (no delete path may ever exist, so the invariant is honoured by there
  being nothing to gate).

**9. `scripts/teardown-state-reset.sh` (new).** Sources `teardown-common.sh` for `az_run`,
`is_auth_error` and the decision-8 constants. Reads `TEARDOWN_MODE`, `REMOVE_MG_HIERARCHY` and a
`PHASE1_RESULTS` JSON map passed as `${{ toJSON(needs) }}` (parsed with `jq`) to compute per-root
eligibility per decision 4. Per eligible key:
- `az storage blob show` for `properties.contentLength` and `properties.lease.status`. If the lease is
  `locked`: bounded retry 3 x 20s, then FAIL LOUD with the exact `az storage blob lease break` command
  in the error. Do NOT auto-break - by Phase 4 no legitimate holder exists, so a lease is itself the
  anomaly and must be seen.
- `az storage blob download` and `jq` out `lineage`, `serial`, `terraform_version`. Absent blob: INFO,
  write with a fresh UUID lineage and the pinned `1.15.6`. Present but unparseable or missing lineage:
  `::warning::` naming it as an FM-1-class anomaly found at reset time, then write with a fresh lineage.
- `az storage blob upload --overwrite --auth-mode login --content-type application/json` plus the
  decision-3 `--metadata`.
- CONFIRM READ-BACK, mirroring this codebase's confirm-GET discipline (the delete side never trusts its
  own success): re-`show` for `contentLength >= TINY_BLOB_THRESHOLD_BYTES`, re-download and assert
  `jq -e '.resources | length == 0'`. Fail loud on either.
- Print a summary table: key, action (`RESET` / `SKIPPED-carveout` / `SKIPPED-not-destroyed`), bytes
  before, bytes after. Exit non-zero if any eligible key failed.
- Follow the auth-fail-loud pattern throughout: an indeterminate `az` result is never read as a
  benign outcome (ADR-062, section 9.4).

**10. `.github/workflows/teardown.yml` (amend).** Add the decision-2 `state-reset` job with the
`production-destroy` environment, OIDC login, the inline JIT firewall open / three-consecutive-probe
wait / `if: always()` restore-to-Deny pattern copied from `teardown-probe.yml` (which already
implements it standalone, with no Terraform root context to borrow from), then the script. Amend the
file header's four-phase description to a five-phase one, and add Phase 4 to the guard job's NOTICE
text for both modes.

**11. `scripts/teardown-probe-state.sh` (amend).** Read `metadata` in the `blob show`. A blob carrying
`tf_state_reset=true` reports as `OK (deliberately reset by teardown run <id> at <utc>) - canonical
post-teardown empty state, NOT a lost-state root`, and is never Class-A regardless of size. An ABSENT
blob stays Class-A unconditionally. Amend the header to name FM-1 and FM-2 and to state which one this
probe detects, so the next reader cannot collapse them.

**12. `docs/teardown-redesign.md` and `docs/cicd-deploy-teardown.md` (amend).** Add the Phase 4
section and the FM-1/FM-2 distinction. Add to the teardown runbook the pre-dispatch step from OQ-065
limb A: when dispatching `target=all mode=az-sweep`, first run a single-root
`target=platform/identity mode=terraform action=destroy` so the Entra objects are deleted through the
azuread provider and identity's state is emptied natively, since carve-out A means the az-sweep path
cannot do it.

**13. Not in scope here, tracked in OQ-065:** the deploy-side pre-plan state-provenance gate (limb B).
Phase 4 guarantees state is empty when teardown ran and went green. It cannot help when teardown did
not run, ran red, or ran from a ref without the mechanism. Today's incident was ultimately a deploy
that planned against a state nobody had checked, and that check belongs on the deploy path, not the
teardown path.

**ADDENDUM 2026-07-31 (the decision is IMPLEMENTED and PROVEN LIVE. Body above unedited, per append-only.)**

- **Landed:** `f28f695` (PR #57), merged to `banking` as `1af0fc9` on 2026-07-30. Five files:
  `.github/workflows/teardown.yml` (the Phase 4 `state-reset` job, gated hard on
  `needs.verify.result == 'success'` with the `!cancelled()` prefix the 2026-07-30 addendum inside
  decision 2 corrected), `scripts/teardown-state-reset.sh` (new, 468 lines - the canonical empty
  document, lineage and `terraform_version` preserved, serial bumped, overwrite only and never delete),
  plus the runbook and pre-clearance amendments that decision 8 required. Decisions 1 to 5 and 8 to 12
  are implemented; decision 6 was the owner-executed one-time disposition and is discharged; decision 13
  is explicitly out of scope and remains OQ-065 limb B. **This supersedes the `NOT IMPLEMENTED` in the
  field above, which was accurate when written.**
- **Proven live, not just merged.** Phase 4 executed on the 2026-07-31 rebuild teardown, and on
  2026-07-31 the estate AND all eleven state blobs were independently confirmed greenfield - which is
  also the precondition ADR-069 decision 6 required before the region flip could be dispatched (see
  ADR-069's addendum, item 5). The evidence sits in the 2026-07-31 WORKLOG entries.
- **Same parser caveat as ADR-069 and ADR-070.** `scripts/check-adr-landed.sh` keeps the FIRST
  `- **Landed:**` line in each ADR block, so it will keep reporting ADR-068 as `NOT IMPLEMENTED` until
  that parser takes the LAST one. Do not fix that by editing the body. Tracked as DevSecOps finding F10
  in the 2026-07-22 rebuild pre-clearance refresh #3.
- **Why all three of ADR-068, ADR-069 and ADR-070 went stale in the same field, recorded because the
  pattern matters more than the three corrections.** The `Landed:` field is written by the architect at
  ruling time, when the honest value is always `NOT IMPLEMENTED`, and it can only be corrected by
  someone who returns to the ADR AFTER the implementation PR merges. Nothing in the merge path prompts
  that. The check script passes on `NOT IMPLEMENTED` by design (an honest backlog entry is the point),
  so the register degrades silently in exactly the direction it was built to prevent: decisions that ARE
  running, recorded as not running. **The durable fix is a check that cross-references, not a habit:**
  once the parser takes the LAST `Landed:` line, a second check can flag any ADR whose `Status` is
  Accepted, whose `Landed` is `NOT IMPLEMENTED`, and whose number is referenced by a merged commit
  message on `banking`. That is a mechanical query over data git already holds, and it is the LESSON 62
  shape (a hook, not a habit). Raised here rather than in a new OQ because F10 already owns the parser.
- **FM-3, added by ADR-071 and relevant to this ADR's taxonomy.** ADR-068 names FM-1 (state missing
  while resources live) and FM-2 (state populated while resources gone). ADR-071 names **FM-3: an object
  outlives BOTH the estate and the state and is invisible to every discovery-based proof, because its
  only address runs through a host that no longer exists.** A resource-scoped diagnostic setting is the
  worked example. FM-3 does not weaken this ADR's guards - it is a class neither of them was aimed at -
  but it does bound what a green Phase 3 VERIFY plus a reset Phase 4 state can be said to prove: they
  prove the estate is empty of everything that can be enumerated.

**ADDENDUM 2026-08-01 (DevSecOps implementation fix, teardown run 30685705802 - decision 4's
`mode=terraform` eligibility rule is AMENDED. Body above unedited, per append-only.)**

- **The gap.** Decision 4 as originally implemented gated `TEARDOWN_MODE=terraform` eligibility
  on job success ALONE, with no VERIFY fallback (`mode=az-sweep` was the only branch that fell
  back to whole-estate VERIFY evidence). Run 30685705802 (`target=all mode=terraform
  remove_mg_hierarchy=true`) exposed this directly: Phase 1 failed for `platform/management`
  (blocked by cross-root orphans, since fixed by ADR-072 decision 4's attachment sweep) and
  `platform/management-groups` (a 6-hour refresh stall, since routed off this path entirely by
  ADR-072 decision 6), Phase 2 caught both remnants, and Phase 3 VERIFY PASSED - yet Phase 4
  excluded both keys because their own jobs read `failure`, not `success`, leaving both blobs
  populated after a run whose estate was independently proven clean. This is the exact FM-2
  condition (state populated while resources gone) this ADR exists to close, produced by the
  eligibility rule itself rather than by a missing reset mechanism.
- **The fix.** `scripts/teardown-state-reset.sh`'s `determine_action` is unified across both
  modes: a key's own Phase 1 job success remains the cheapest, most specific belt (checked
  first, in either mode); a key whose job did NOT succeed now falls through to the SAME
  VERIFY-fallback decision 2 already establishes for `mode=az-sweep` - except
  `platform/identity`, which is EXCLUDED PERMANENTLY regardless of mode (carve-out A is
  unchanged and unweakened: VERIFY 0-10 is ARM-plane only and has zero Entra/Graph/PIM
  coverage, verified 2026-08-01 that no other root declares a non-ARM-plane provider). No
  carve-out was removed and no new one was added - decision 4's evidence-boundary rule
  ("a root's state may be reset only if that root's ENTIRE resource footprint is covered by the
  evidence this run's mode actually produced") was already broad enough to justify this; what
  was missing was applying it in `mode=terraform` too, not only in `mode=az-sweep`.
- **Not yet re-run live.** This addendum documents the code change; the two stuck blobs
  (`platform/management` and `platform/management-groups`) from run 30685705802 are unblocked
  by this fix on the NEXT `mode=terraform` run that reaches Phase 4, or immediately via a
  `target=all mode=az-sweep remove_mg_hierarchy=true` re-dispatch against the already-verified-
  clean estate (that path's Phase 4 branch was already unconditional for both keys before this
  fix - see WORKLOG for the full account of why no code change was needed for that path).
- **Landed:** implemented on branch `fix/teardown-refresh-ceiling`, not yet merged. Update this
  addendum (or add a further dated one) once the PR merges, per this file's own `Landed:`
  convention.

### ADR-067: The clean-empty-state platform/security apply (run 30499221661) fails on three interacting classes - a soft-delete-recovered Security LAW re-hydrates orphaned Sentinel rules ("already exists"), the two Sentinel automation rules lack the onboarding dependency (race "not onboarded"), and the pricing serialization never actually serialized the extended plan set (CloudPosture 409). Diagnosis stands; the recovery ruling was SUPERSEDED 2026-07-29 (see Addendum) - the user's process change makes recovery a FULL estate teardown-and-restart from Step 1 with the Security LAW purged, not import-and-continue.

- **Date:** 2026-07-29
- **Section:** 6 (Defender for Cloud + Sentinel). Extends ADR-033 (Sentinel connector/rule gating), ADR-034 (Defender pricing serialization + deprecation audit), ADR-035 (import-block precedent, plan-scan guard). Numbered 067 (not 066) on purpose: ADR-066 and OQ-062 are already claimed by the pending `docs/adr-teardown-all-layers-green` branch, so this ruling skips 066 to avoid a merge-time collision; banking will hold 065, 066 (teardown), 067 (this) once both merge.
- **Status:** Accepted (architect ruling; user directed the diagnosis of run 30499221661 as a live rebuild blocker). Fix handed to Cloud Engineer (code) and DevSecOps (state op + apply args), then Code Review, then merge. NOT a plain rerun: this apply is diagnosed and issued as ONE consolidated fix-spec (LESSON 59).
- **Decision makers:** claude (architect); user (requirement: land the security root on the greenfield rebuild without burning the failure budget).

**Context:**
Greenfield rebuild, single-target `--ref banking`. Steps 1 (`platform/management-groups`, 537 adds) and 2 (`platform/management`, 36 adds) are qa-PASS. Step 3 `platform/security` (run 30499221661) planned clean (48 add / 0 change / 0 destroy) from a state reset to empty (181 bytes) but FAILED during apply in three classes. The security state is now PARTIAL. This is the same root that took three fix cycles in ADR-033/034/035, but this is the FIRST time it has been applied from a genuinely empty state; every prior apply was incremental over a state that already held the Sentinel onboarding.

The three verbatim error classes (run 30499221661):
1. Defender pricing: `setting Pricing (Pricing Name: "CloudPosture"): unexpected status 409 (409 Conflict) ... Another update operation is in progress. Please retry in a few minutes.`
2. ~11 Sentinel resources "already exists - needs import": the `azurerm_sentinel_data_connector_azure_security_center` `dc-mdc-globaris-poc` plus the 10 non-firewall `azurerm_sentinel_alert_rule_scheduled` instances, all under `.../workspaces/law-security-globaris-poc/providers/Microsoft.SecurityInsights/...`.
3. Sentinel automation rule: `checking for existing Automation Rule ...: 400 BadRequest: Workspace 'law-security-globaris-poc' is not onboarded to Microsoft Sentinel.`

**The paradox and its resolution (verified facts this session):**

The STATE was emptied; AZURE was not. The prior teardown SOFT-DELETED the Security LAW (Log Analytics workspaces soft-delete for 14 days) rather than purging it. This apply's AVM LAW module PUT of `law-security-globaris-poc` (same name, same RG) RECOVERED the soft-deleted workspace instead of creating a fresh one (documented azurerm behavior, hashicorp/terraform-provider-azurerm issue #26644; MS Learn "Delete and recover a Log Analytics workspace"). Per MS Learn, recovery RESTORES the workspace configuration and its analytics rules (data connectors come back as objects but "disconnected"). So the 10 scheduled alert rules and the `dc-mdc` data connector came back as live Microsoft.SecurityInsights child objects that are absent from the freshly-emptied Terraform state. The azurerm provider's default pre-create existence GET therefore finds them and returns `ImportAsExistsError` ("already exists - needs import"). Because the recovered workspace's GET returns 404 while soft-deleted, the LAW module create did NOT itself hit "already exists" (it recovered via PUT and reported success), which is why only the Sentinel CHILDREN, not the workspace, show the import error. This is corroborated by in-repo precedent: WORKLOG 2026-07-13 (management "LAW soft-delete recovery PUT" and security "recovered security LAW ... soft-delete-recovered workspace" watch-item on run 29471713790/29471965746).

Simultaneously, the two Sentinel automation rules `azurerm_sentinel_automation_rule.auto_assign` and `.ti_enrichment_tag` (sentinel.tf lines 482-529) reference `log_analytics_workspace_id = module.security_law.resource_id` but carry NO `depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]` (verified on origin/banking: every other Sentinel child resource in the file has that edge; only these two lack it). On the graph they are SIBLINGS of the onboarding resource, both depending only on the LAW, so Terraform runs them in parallel with the onboarding PUT. The automation-rule endpoint gate-checks Sentinel onboarding even on the pre-create existence GET, so it returned 400 "not onboarded" before the racing onboarding PUT had settled the OnboardingStates/default record. "Rules exist" (recovered child objects, directly GET-able) and "workspace not onboarded" (onboardingStates record still being re-established) are BOTH true during the race window; they are not contradictory. This is exactly the pattern ADR-033 saw for `ti_enrichment_tag` on run 29133588369 and dismissed as "onboarding-propagation timing a rerun will clear" - it cleared then only because the rerun started from an already-onboarded workspace, which MASKED the missing dependency rather than fixing it. It has recurred on every truly-clean apply since (WORKLOG 29471713790: "automation rule 400 racing the same-run workspace onboarding").

The CloudPosture 409 is a code-gap, not a transient: `azurerm_security_center_subscription_pricing.extended` (defender.tf) carries `depends_on = [azurerm_security_center_subscription_pricing.servers]`, and its comment claims this "keeps only one pricing PUT in flight at a time." That is FACTUALLY WRONG. `depends_on` on a `for_each` resource gates EVERY instance behind `servers`, but the six extended instances (AppServices, SqlServers, SqlServerVirtualMachines, Containers, OpenSourceRelationalDatabases, CloudPosture) all become ready the instant `servers` completes and then run concurrently up to `-parallelism`. The Defender subscription-pricing controller serializes writes at the subscription level, so six concurrent PUTs collide -> 409 on whichever loses the race (here CloudPosture). ADR-034's REAL serialization control was `-parallelism=1` at apply time; the depends_on(servers) edge was only ever validated on the 2026-07-10 INCREMENTAL apply, where just two pricing writes were pending (servers + AppServices) so the single edge sufficed. On a clean empty state, all ~8 pricing plans are creates, so the six-way extended concurrency is exposed. The single-target rebuild dispatch did not pass `-parallelism=1`, so nothing serialized the extended set.

**Decision:**

**ADDENDUM 2026-07-29 (recovery ruling SUPERSEDED - full teardown-and-restart, not import):**
After this ADR was first written, the user changed the recovery process (2026-07-29): when ANY layer fails, the estate is FULLY torn down and the rebuild RESTARTS from Step 1. There is no import-and-continue and no partial-state reconciliation. This supersedes decision 1 below IN FULL - the import blocks in 1a, the plan-scan-for-imports in 1d, the cleanup commit in 1e, and the "live checks before importing" follow-up. Consequences of the change:
- Cloud Engineer added NO import blocks. Only the Class 3 fix (the onboarding `depends_on` on both automation rules, old 1b) and the Class 1 fix (`-parallelism=1` plus the corrected serialization comment, old 1c/1d) are implemented; both are code-reviewed and preflight-clean. Those two code fixes STAND unchanged.
- Class 2 (the soft-delete-recovered Security LAW re-hydrating ~11 orphaned Sentinel objects) is NOT closed by import. It is closed by OQ-063: the teardown PURGES the Security LAW before the restart, so Step 3 of the restart creates a genuinely fresh workspace with no orphans and no "already exists". That LAW-purge is being implemented in the ADR-066 all-layers-green teardown workstream (ADR-066 committed on `docs/adr-teardown-all-layers-green` as 0dac862). OQ-063 is therefore BLOCKING-until-implemented for the restart, not a deferred nicety (see OQ-063).
- The rejected alternative "Teardown JUST platform/security ... then re-apply" (below) remains correctly rejected in ITS narrow single-root form: a single-root destroy from partial state leaves the orphans (not in state) and traps the purge-protected KV. The now-chosen path is DIFFERENT - a FULL-estate teardown-and-restart in which the teardown's LAW-purge (OQ-063) removes the soft-deleted workspace so the orphan-recovery loop cannot occur, and the KV is handled by the teardown workstream. The diagnosis of why the naive single-root destroy fails still holds; the full-teardown path routes around exactly those flaws.
- Decision 2 (time_sleep robustness) and decision 3 (systemic LAW-purge) still stand; decision 3 is now the LOAD-BEARING Class 2 fix, not a "future" nicety.
The three-class DIAGNOSIS above (Context, the paradox, and the per-class root causes) is unchanged and remains correct.

1. **[SUPERSEDED 2026-07-29 - see Addendum above; recovery is now full teardown-and-restart, no imports.] Recovery path: IMPORT-AND-CONTINUE, not teardown-and-reapply.** The workspace is already recovered and live, the KV/LAW/onboarding/succeeded-pricing resources are correct and in state, and the failed set is a bounded list of recovered orphans. Reconcile forward:
   a. (Cloud Engineer) Add config-driven `import` blocks (interpolated IDs, ADR-029/035 precedent, no hardcoded GUID) for the recovered orphans:
      - `azurerm_sentinel_data_connector_azure_security_center.this`, id `${module.security_law.resource_id}/providers/Microsoft.SecurityInsights/dataConnectors/dc-mdc-${var.org_prefix}-${var.environment}`.
      - `azurerm_sentinel_alert_rule_scheduled.this` (for_each import over the 10 non-firewall keys), id `${module.security_law.resource_id}/providers/Microsoft.SecurityInsights/alertRules/ar-${each.key}-${var.org_prefix}-${var.environment}`. Import-block `for_each` is supported at this root's `terraform >= 1.9`. ID formats VERIFIED 2026-07-29 against the provider import docs (alertRules / dataConnectors under `Microsoft.OperationalInsights/workspaces/<ws>/providers/Microsoft.SecurityInsights/...`).
      - The exact set to import is whatever the LIVE GET returns (see Follow-ups live checks). If the recovery also re-hydrated `ti_enrichment_tag` (a Microsoft.SecurityInsights/automationRules child, hardcoded name `12345678-1111-1111-1111-000000000002`), add an import block for it too; `auto_assign` is `count`-gated on an empty `sentinel_owner_group_object_id` so it has zero instances and needs nothing. Do not import a resource that a `terraform plan` shows as "to create" (that means the id is wrong) - STOP and re-derive.
   b. (Cloud Engineer) Add `depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]` to BOTH automation rules, matching every other Sentinel child in the file. On the immediate re-apply this is sufficient because onboarding is already in state (landed in the partial apply) and re-applies as a no-op, so the automation rules run against an already-onboarded workspace.
   c. (Cloud Engineer) Correct the false serialization comment on `azurerm_security_center_subscription_pricing.extended` in defender.tf (the depends_on(servers) edge does NOT serialize the extended set among itself).
   d. (DevSecOps) Re-apply this root with `-parallelism=1` wired into the dispatch/workflow step for the security root, NOT as a hand-typed operator arg that the single-target path drops. Mandatory pre-apply PLAN-SCAN (ADR-034 step-6 guard): confirm N imports resolve, 0 destroys, no `-/+` replace on any pricing plan or Sentinel resource. Any recovered Sentinel resource showing "to create" instead of "to import" is a STOP.
   e. (Cloud Engineer) After a green apply, remove the one-shot import blocks in a cleanup commit (ADR-035 precedent).

2. **Robustness follow-up for future truly-clean applies (recommended, not required for the immediate re-apply):** add a `time_sleep` settle (create_duration ~120s) that `depends_on` the onboarding resource, and route the Sentinel child resources' onboarding dependency through it, so a future apply that does NOT benefit from an already-onboarded (recovered or prior-partial) workspace absorbs the OnboardingStates control-plane eventual-consistency window. This needs the `hashicorp/time` provider added to this root (providers.tf + lock regen), so it is deferred out of the blocker fix unless the team wants it now.

3. **Systemic recurrence fix (teardown lane, OQ-063):** the orphan-rehydration class recurs on EVERY rebuild for as long as teardown soft-deletes (rather than purges) the Security LAW inside the 14-day window. Track hard-purging the Security LAW on teardown (`az monitor log-analytics workspace delete --force true`, or a purge of the soft-deleted workspace) as a teardown-completeness item so future rebuilds create a genuinely fresh workspace with no orphans and no import step. Do NOT purge the workspace NOW (it is live and recovered; the import path adopts it).

**Alternatives considered:**
- **Teardown JUST platform/security (mode=terraform) then re-apply clean.** Rejected. (1) The state is PARTIAL: the ~11 orphans are NOT in state, so `terraform destroy` cannot target them directly; it would only destroy the in-state resources. Destroying the in-state LAW would cascade the orphaned rules back into soft-delete, and the very next clean apply would RE-RECOVER the same workspace and reproduce the identical "already exists" paradox - an infinite loop unless the soft-deleted workspace is then purged by hand. (2) It would destroy the Security Key Vault, which has `purge_protection_enabled = true` and 90-day soft-delete: re-apply would then collide on the KV name for up to 90 days or require a recover dance (LESSON 55-57). Import-and-continue touches neither the KV nor the recovery loop and is strictly less state surgery. The task's framing that a security terraform-destroy "empties its state and removes the orphaned Sentinel resources" does not hold, because the orphans are not in state.
- **`-parallelism=1` alone (no import blocks), rerun-as-is.** Rejected: it does not reconcile the recovered orphans, which are absent from state; every one would still fail "already exists."
- **`lifecycle { ignore_changes }` / recreate the Sentinel children.** Rejected: recreation requires deleting the recovered rules first (churn on live detections) and re-introduces the onboarding race; import is a zero-touch adopt of resources whose config already matches.
- **Fully serialize the extended pricing set in code (hand-rolled linear depends_on chain instead of a for_each set).** Considered as the durable fix. Deferred: `-parallelism=1` on this small root is the ADR-034-sanctioned control and is far lower code risk under a live blocker; a chain would drop the for_each and is only worth it if the team wants to keep global parallelism high on this root. Recorded as an option, not mandated.
- **Grant the Security Administrator role and flip on the tenant-gated features (aad connector, ti connector, ueba, aad diagnostics) in this same pass.** Rejected for the blocker: those stay default-false per ADR-033; this ruling adds no new tenant-permission surface.

**Consequences:**
- Positive: the security root lands from its current partial state with a single consolidated fix and no destroy of the purge-protected KV or the recovered workspace. The three error classes each get a durable disposition. The false "one PUT in flight" comment is corrected. The recurrence root cause (teardown soft-delete of the LAW) is surfaced for a permanent fix.
- Negative / trade-offs: the re-apply carries one-shot import blocks (removed in a cleanup commit). Reduced parallelism slows this one root's apply. Full future-clean robustness (the time_sleep settle) is deferred behind adding the `time` provider. Until OQ-063 is actioned, every rebuild will need the same import step.
- Follow-ups required:
  1. **LIVE CHECKS before importing (qa or Cloud Engineer)** - do not import blind:
     - Confirm recovery: `az monitor log-analytics workspace list-deleted-workspaces` (the security workspace should NOT appear if it was recovered) and `az monitor log-analytics workspace show -g rg-security-globaris-poc -n law-security-globaris-poc --query provisioningState`.
     - Enumerate the EXACT live Sentinel children to build the import set and confirm names: alert rules via `az rest --method GET --url ".../workspaces/law-security-globaris-poc/providers/Microsoft.SecurityInsights/alertRules?api-version=2023-11-01"`; data connectors via the `dataConnectors` endpoint; automation rules via the `automationRules` endpoint (to learn whether `ti_enrichment_tag` needs an import block).
     - Onboarding state now: GET `.../providers/Microsoft.SecurityInsights/onboardingStates/default` - confirm the workspace reads onboarded after the failed apply's PUT.
     - Live pricing tiers: `az security pricing list` on the security sub - which plans are already Standard (predicts which pricing PUTs the re-apply will actually issue; informs whether the 409 risk is even still present).
     - Current state contents: `terraform state list` for the security root - the authoritative partial set, so nothing already in state is double-imported.
  2. Cleanup commit to remove the import blocks after the green apply.
  3. OQ-063: teardown purges the Security LAW (and audit whether the security KV soft-delete is likewise purged on teardown, given purge protection) so rebuilds start truly clean.
  4. If the team elects the time_sleep robustness fix (decision 2), Cloud Engineer adds the `hashicorp/time` provider to `platform/security` and regenerates the lock.

**Regression vs new failure mode (per class):**
- Class 3 (automation-rule "not onboarded"): a LATENT CONFIG DEFECT / REGRESSION. The missing onboarding `depends_on` on both automation rules should have been fixed by ADR-033, which instead classified the `ti_enrichment_tag` failure as transient timing. It has been carried, masked by non-clean reruns, across multiple rebuilds. This ADR fixes the config.
- Class 2 (orphan "already exists"): a genuinely-recurring REBUILD failure mode rooted in teardown soft-delete + Azure LAW recovery, NOT a defect in sentinel.tf. Observed ad hoc before (WORKLOG 2026-07-13) but never systematically closed. Closed here for the current state (import) and for the future (OQ-063 purge).
- Class 1 (CloudPosture 409): an INCOMPLETE FIX exposed only by clean-state scale. ADR-034 intended full serialization; the implemented depends_on(servers) edge serializes extended-after-servers but not the extended set internally, and the operational `-parallelism=1` control was not wired into the single-target rebuild dispatch.

**ADDENDUM 2026-07-30 (post-merge reconciliation; the branch-split prediction resolved, and decision 3 is now IMPLEMENTED rather than tracked). Body above unedited, per append-only.**

Three corrections and one status change, none of which alters the diagnosis:

1. **The numbering note in the Section field came true, so it can stop being read as a caveat.** It predicted that "banking will hold 065, 066 (teardown), 067 (this) once both merge". Both have merged: this ADR reached `banking` in PR #53 (`d8da413`) and the ADR-066 teardown branch was rebased on top of it, so `banking` now carries ADR-065, ADR-066 and ADR-067 in one file with no collision and no renumbering. Nothing further is owed on that point.

2. **Decision 3 (the systemic LAW purge) is IMPLEMENTED, and it is no longer only a teardown-script concern.** It said to "track hard-purging the Security LAW on teardown". What actually landed is stronger and better placed: `platform/security/providers.tf` sets `features { log_analytics_workspace { permanently_delete_on_destroy = true } }` on the root's default provider, so the OWNING ROOT's own `terraform destroy` purges the workspace natively, with `scripts/teardown-az-sweep.sh` step 7b retained as the backstop for the `mode=az-sweep` path and for any older `platform/security` state. Argument verified against the pinned azurerm v4.71.0 features schema (it defaults FALSE and had to be set explicitly). That is a better shape than the `az` purge decision 3 sketched, because it removes the failure mode where the sweep script and the owning provider disagree about who cleans up. Class 2 therefore has a durable disposition and needs no import blocks, consistent with the 2026-07-29 addendum's supersession of decision 1.

3. **Stale commit reference.** The 2026-07-29 addendum cites the ADR-066 branch commit as `0dac862`. The rebase onto `banking` rewrote that hash; the ADR-066 doc commit is now `9974efa`. Cite branch plus ADR number rather than a hash in future cross-references, since any rebase invalidates the hash.

4. **Status of the whole ruling.** Classes 1 and 3 are fixed in code and merged (this ADR's own PR). Class 2 is closed by design and code but is NOT live-proven: no rebuild has yet started from a genuinely purged workspace. That single proof is owned by OQ-062 (items (e) and (f) of its 2026-07-30 update), with OQ-063 RESOLVED 2026-07-30 on the same basis. Do not read "merged" as "proven" for Class 2.

### ADR-066: All-layers-green teardown - at `target=all` the 11 per-root `terraform destroy` jobs RUN and go green, SERIALIZED in reverse-dependency order each with the per-job JIT state-SA firewall flip; az-sweep is demoted to a DISARM-before / thin remnant-catch-after belt. Supersedes ADR-065 decision 1 (skip Phase 1 at target=all). Re-derived against the user's first-class requirement that every layer destroy be transparent and green.

- **Date:** 2026-07-29
- **Section:** 10 (Pipeline & Tooling) / teardown. SUPERSEDES ADR-065 decision 1 (Phase-1 terraform-destroy skipped at target=all) and its Alternatives (a)/(b) rejections, on fresh evidence. KEEPS ADR-065 decision 2 (single-root JIT flip), decision 4 (single-root az-sweep rejection), decision 6 (deploy.yml guard). Builds on ADR-054 (four-phase shape, DISARM-first, MG list-snapshot oracle, auth-fail-loud), ADR-055 (durable OIDC token refresh, now the load-bearing enabler for long DESTROY jobs), ADR-057 (subscription-scope completeness - now largely satisfied natively by terraform-destroy), ADR-025 (JIT state-SA firewall flip). ADR-054/055/057/063/064 otherwise stand.
- **Status:** Proposed (architect ruling; user to route to DevSecOps for teardown.yml + Cloud Engineer for the bank-data-p1 / az-sweep Databricks-orphan handling, then Code Review). No `.tf` / `.yml` / shell authored here.
- **Decision makers:** claude (architect); user (requirement: a FULL teardown must run ALL ~11 per-layer terraform destroy jobs green, in reverse-dependency order, mirroring the deploy - the normal, transparent, state-faithful Terraform model - not the current "everything skipped, one az-sweep does it all")

**Context:**
The user requires that a full teardown run every per-layer `terraform destroy` job (synthetic, the 5 spokes, connectivity, security, identity, management, management-groups) and that each goes GREEN, in reverse-dependency order. ADR-065 made those 11 Phase-1 jobs DORMANT at `target=all` and left the whole-estate cleanup to the firewall-independent az-sweep flow, on two stated grounds: (1) at `target=all` the parallel layer jobs run `manage_runner_ip=false` and 403 at `init` against the Deny-by-default state SA; (2) terraform-destroy allegedly cannot finish the estate's "F2" resources (Databricks managed-RG deny-assignment, purge-protected Key Vaults). This ADR re-interrogates (1) and (2) against provider behaviour and current Microsoft docs, resource by resource, and rules whether all-layers-green is achievable.

**F2 verdict, per resource (evidence, not restatement):**

1. **Purge-protected Key Vault (platform/security, `purge_protection_enabled = true`, `soft_delete_retention_days = 90`, provider `features {}` so `purge_soft_delete_on_destroy` defaults true) - NOT a terraform-destroy blocker.** Read live from the pinned provider source (terraform-provider-azurerm v4.71.0, `internal/services/keyvault/key_vault_resource.go` Delete): when the vault has purge protection enabled the provider does NOT attempt the purge - it logs "has Purge Protection Enabled and will be purged automatically by Azure" and `return nil` (success). So `terraform destroy` SOFT-deletes the vault (a successful destroy of the resource) and correctly declines the purge. The purge is a separate operation, correctly blocked until 90-day retention expires, handled on redeploy by `recover_soft_deleted_key_vaults = true` (LESSON 56). The KV is a post-destroy purge/report concern that VERIFY 5 already treats as informational, NOT a destroy blocker. The task's hypothesis is confirmed. (Source: provider source v4.71.0 Delete function; web-verified 2026-07-29.)

2. **Databricks managed-RG deny-assignment (landing-zones/bank-data-p1, `enable_data_platform = true`) - the deny-assignment does NOT block the workspace destroy; the real residual is an ORPHAN managed RG left by the module's PLAIN delete.** Three source-verified facts:
   - The estate consumes `Azure/avm-res-databricks-workspace/azurerm 0.5.0`, which at 0.5.0 moved the workspace to an `azapi_resource` of type `Microsoft.Databricks/workspaces@2026-01-01` (module `main.tf`, read at the pinned tag). The resource sets only `delete_headers` (telemetry User-Agent); it does NOT set `delete_query_parameters`. So `terraform destroy` issues a PLAIN ARM DELETE with NO `forceDeletion` query param.
   - The workspace lives in the WORKLOAD RG, not the managed RG. The deny-assignment is scoped to the MANAGED RG. terraform never deletes the managed RG (it is RP-created, not in state), so the deny-assignment cannot block the workspace DELETE. The ADR-054/065 framing ("terraform destroy cannot finish because of the managed-RG deny-assignment") conflates the workspace delete with a direct managed-RG delete; only the latter is denied, and terraform never attempts it. So the bank-data-p1 layer's `terraform destroy` SUCCEEDS (green).
   - BUT per the current Microsoft "Delete a workspace" doc (ms.date 2026-07-21, web-verified 2026-07-29): "the DBFS storage account and access connector in the managed resource group are retained unless you force delete them." A plain delete RETAINS the managed RG; only `--force-deletion` / `-ForceDeletion` / `forceDeletion=true` (ARM DELETE query param, confirmed present at api-version 2026-01-01 in the REST reference) cascades it. Since the pinned module issues a plain delete and exposes NO force-delete input (module `variables.tf` has none), a pure terraform destroy of bank-data-p1 goes GREEN but LEAVES an orphan managed RG (`rg-bank-data-p1-dbx-managed-globaris-<env>`, which the az-sweep pattern deliberately EXCLUDES and which the deny-assignment blocks from a direct `az group delete`). That orphan collides with the deterministic `managed_resource_group_name` on the NEXT greenfield apply, so by the ADR-057 governing principle ("if leaving it makes the next greenfield apply fail or drift, teardown owns it") teardown must still remove it.
   - **Net:** the Databricks layer terraform-destroys GREEN; the residual is a completeness gap (orphan managed RG), NOT a red/stalled layer. It is real ONLY when `enable_data_platform = true` (the current posture); with the flag false the layer is a clean green no-op.

3. **APIM (bank-app-p1, provider `features { api_management { purge_soft_delete_on_destroy = true, recover_soft_deleted = true } }`) and AKS - slow, not blocking.** APIM soft-deletes then purges (not purge-protected) via the provider features; AKS deletes; both are SLOW (tens of minutes) but terraform-destroy GREEN. The former token-lifetime risk on a long destroy is closed by ADR-055 Part 2, which `_tf-root.yml` exports UNCONDITIONALLY for every action including destroy (`ARM_OIDC_REQUEST_URL/TOKEN`), so azurerm re-mints a fresh GitHub id-token on every access-token acquisition inside a single job. So a 40-minute APIM destroy does not die AADSTS700024. Not a blocker.

**No other resource genuinely blocks a layer's terraform-destroy.** The one honest residual is the Databricks orphan managed RG (F2 item 2), and it is a remnant, not a stall.

**F1-F4 mitigation status (cause by cause):**
- **F1 (empty-root cascade-skip):** MITIGATED and portable to the layered model. `!cancelled()` gating plus `_tf-root.yml`'s `terraform state list` state-empty no-op (exit 0) mean a no-op/empty root (incl. inert `synthetic`) never fails or cascades. Works identically whether layers run parallel or serialized.
- **F2:** the KV half is a NON-issue (item 1); the Databricks half is an orphan-managed-RG remnant handled by the retained belt (below), not a destroy blocker (item 2).
- **F3 (DINE re-remediation mid-destroy):** MITIGATED, and the mitigation is INDEPENDENT of Phase 1's shape. Phase 0 DISARM removes every MG-scope policy ASSIGNMENT (and each DINE identity's role assignment) BEFORE any resource deletion. In the layered model DISARM still runs first (it is a hard `needs` gate on every Phase-1 job). So F3 is not a threat to a layer-by-layer destroy.
- **F4 (state emptied for redeploy, terraform can no longer help):** does NOT apply to the NORMAL deploy -> teardown path, where state is intact. F4 is precisely why az-sweep exists as the state-gone FALLBACK; it does not argue against running terraform-destroy when state IS present. In the all-layers-green model the primary path assumes intact state (the normal case); az-sweep remains the state-gone fallback and the remnant-catch belt.

**Firewall ruling (reason 1):** the 403-at-init is REAL and ADR-065 diagnosed it correctly, but it is UNSOLVED, not UNSOLVABLE, for all-layers-green. The per-job JIT flip (`manage_runner_ip=true`: flip `default_action=Allow` for the job window, 3-consecutive-probe settle, init-retry backstop, restore Deny on `if: always()`) already works for a single root and is exactly what deploy uses. It races ONLY when two jobs flip the SAME SA concurrently (LESSON 31). Therefore: run the 11 layer jobs SERIALIZED (a strictly linear reverse-dependency `needs` chain, one firewall-flipping job at a time), each with the per-job flip. This is NOT ADR-065's rejected Alternative (b): that was ONE monolithic job doing all 11 destroys under ONE login (which can outlive the OIDC assertion and cannot re-login mid-stream). Here each layer is its OWN `_tf-root.yml` job with a FRESH `azure/login` and ADR-055 durable refresh, so the token objection does not apply. Posture: the state SA is opened by exactly ONE job at any instant and self-heals to Deny on that job's exit - the SAME exposure profile as the sequential single-target DEPLOY that BUILDS the estate (ADR-060). It is strictly better on the failure axis than ADR-065 Alternative (a)'s run-level open (one opener + one closer, where a cancelled run can strand the SA open). The whole-run-open option is therefore still rejected, but for the RIGHT reason (per-job self-healing flip is superior), not because all-layers-green is unattainable.

**Decision:**

1. **At `target=all`, RUN all 11 Phase-1 `terraform destroy` jobs, SERIALIZED in reverse-dependency order, each with the per-job JIT firewall flip.** Restore the `inputs.target == 'all'` disjunct to every Phase-1 job's `if:` (undoing ADR-065 decision 1), AND make the graph a strictly LINEAR chain at `target=all` so exactly one firewall-flipping job runs at a time (reverse deploy topological order: synthetic -> bank-data-p1 -> bank-app-p1 -> online-p1 -> corp-a2 -> corp-a1 -> security -> connectivity -> identity -> management -> management-groups; any linearization that respects the deploy dependencies is acceptable). Keep `manage_runner_ip: ${{ inputs.target != 'all' }}` from ADR-065 for the single-root path; ADD a separate wiring so the flip is ALSO enabled for each serialized target=all layer job (the implementable form is DevSecOps's - e.g. `manage_runner_ip: true` on the Phase-1 jobs now that they are serialized, or a `target=all`-aware expression - the invariant is: exactly one state-touching job open at a time). The serialization is the load-bearing safety property; keep the linear chain and do not restore intra-level parallelism among the 5 spokes.
2. **DISARM stays Phase 0, first, before any layer.** Unchanged from ADR-054/063. It is the F3 mitigation and is a hard `needs` gate on every Phase-1 job.
3. **Demote az-sweep to a thin belt, RETAINED, running AFTER the layers.** It is no longer the whole-estate deleter; the layers do the bulk transparently. Its remaining jobs: (a) the Databricks orphan-managed-RG cleanup (see decision 4); (b) the KV soft-delete REPORT (informational, VERIFY 5); (c) the ADR-057 subscription-scope step 6 - now a pure idempotent NO-OP belt, because terraform-destroy of `platform/management` and `platform/security` deletes the budgets, cost exports, anomaly action, subscription diagnostic setting, Defender pricing (returns to Free via the provider) and RP registration NATIVELY (ADR-057 section 12.1: a provider destroys its own subscription-scoped objects regardless of RG). All-layers-green therefore ELIMINATES the ADR-057 survivor class at its root rather than sweeping it; step 6 stays only as a backstop; (d) MG-hierarchy removal (Phase 2 step 4) when `remove_mg_hierarchy=true`, unchanged.
4. **Handle the Databricks orphan managed RG on the PROVEN force-cascade path (implementer choice, preference stated).** PREFERRED: run the az-sweep Databricks WORKSPACE force-delete (existing step 1, `--force-deletion --no-wait`) as a belt BEFORE Phase 1 (a Phase 0.5 alongside DISARM), so the managed RG cascades via the already-proven live-workspace force-delete while the workspace still exists; bank-data-p1's terraform destroy then finds the workspace gone (azapi DELETE on an absent resource is a 404 -> idempotent success) and cleanly destroys the spoke VNet, access connector and RG - the layer still RUNS and goes green. ALTERNATIVE (if the implementer prefers to keep az-sweep strictly post-Phase-1): after terraform plain-deletes the workspace, have az-sweep force-delete the ORPHAN managed RG directly with `az group delete --force-deletion-types Microsoft.Databricks/workspaces` (documented in the MS delete-workspace doc). The alternative carries an UNPROVEN assumption (that `--force-deletion-types` bypasses the orphan managed RG's deny-assignment); the preferred path avoids that question entirely by acting while the workspace is live. BEST END-STATE (flag for Cloud Engineer): if a newer `avm-res-databricks-workspace` version exposes `delete_query_parameters` / a force-deletion input, bump to it and set `forceDeletion=true` so terraform destroy cascades the managed RG NATIVELY - then bank-data-p1 is fully pure-terraform green-and-complete and needs no Databricks belt at all. Verify the version on the registry before recommending (this ADR did not confirm a version beyond 0.5.0 exposing it; registry WebFetch returned no content on 2026-07-29).
5. **VERIFY (Phase 3) stays the loud truth-gate, unchanged.** It will now audit an estate that terraform emptied; the orphan managed RG (if the belt or force-cascade failed) is a VERIFY 2/3 failure - loud, correct.
6. **Single-root path, deploy.yml guard, `mode` input: unchanged from ADR-065 decisions 2/4/6.** Single-root terraform destroy keeps its JIT flip; `mode=az-sweep`+single-root stays rejected; the deploy.yml `target=all && apply` guard stays. `mode` remains vestigial-but-kept; at target=all the SERIALIZED terraform path is now the primary, and `mode=az-sweep` at target=all remains available as the state-gone fallback (identical job set to today).

**Invariants (definition of done):**
- INV-1: a successful `target=all` teardown RUNS all 11 per-root terraform-destroy jobs and each ends GREEN, in reverse-dependency order (the user's requirement), followed by a green az-sweep belt and a green VERIFY.
- INV-2: the state SA is open for exactly ONE job at any instant and is Deny between and after jobs (per-job `if: always()` restore). Never a whole-run open.
- INV-3: no manual deletion; a fresh greenfield apply after teardown meets a clean slate, including NO Databricks managed-RG collision.

**Alternatives considered:**
- **Keep ADR-065 (skip Phase 1 at target=all, az-sweep does everything).** Rejected: it fails the user's first-class requirement (transparent per-layer green destroys), discards terraform state fidelity, re-creates the entire ADR-057 subscription-scope survivor class as a permanent az-sweep dependency, and its two justifications do not hold on evidence (KV is not a blocker; the workspace destroy is not blocked by the deny-assignment). ADR-065's firewall FIX for single-root and its diagnosis were correct and are KEPT; only its target=all skip (decision 1) is over-conservative and superseded.
- **Run-level firewall open for the whole target=all teardown (ADR-065 Alternative a).** Still rejected: the per-job self-healing flip (decision 1) gives one-job-at-a-time exposure identical to deploy, and self-heals on cancel, which is strictly better than a single opener/closer pair around the whole run.
- **One monolithic serial job for all 11 destroys (ADR-065 Alternative b).** Still rejected for the same reason (can outlive the OIDC assertion, cannot re-login mid-stream). The waved model avoids it by making each layer its own job with fresh login + ADR-055 refresh.
- **Parallel layer jobs each flipping the firewall.** Rejected: concurrent flips race (LESSON 31). Serialization is the price of the per-job flip; teardown is a rare deliberate op, so the wall-clock cost is acceptable in exchange for all-layers-green plus deploy-equivalent posture.
- **Self-hosted / VNet-integrated runner with a static egress IP (would let parallel target=all terraform-destroy work).** Correct production direction (OQ-018), still deferred as funded infra out of scope for the POC.

**Consequences:**
- Positive: satisfies the user's requirement - a full teardown is transparent, state-faithful, all-layers-green, mirroring the deploy. A real regression in any layer is now visible as that layer's red, not masked.
- Positive: eliminates the ADR-057 subscription-scope survivor class at its root (owning providers destroy their own objects); az-sweep step 6 becomes a no-op backstop instead of the sole mechanism.
- Positive: state SA exposure profile equals the sequential deploy's; self-healing per-job Deny restore.
- Negative / trade-offs: target=all teardown is now SERIAL (slower wall-clock) - acceptable for a rare op. The Databricks layer needs a belt (decision 4) until a module version exposes native force-deletion; that belt (preferred form) runs the workspace force-cascade before Phase 1, a small asymmetry for the one resource class the pinned AVM module cannot fully self-clean. `mode=az-sweep` at target=all remains as the state-gone fallback, so two target=all shapes now exist (serialized-terraform primary, az-sweep fallback) - documented, not removed.
- Follow-ups required: (1) DevSecOps re-enables + linearizes Phase 1 at target=all with the per-job flip (decision 1), keeps DISARM-first, demotes az-sweep to the belt (decision 3), and implements the Databricks orphan handling wiring (decision 4 preferred form). (2) Cloud Engineer investigates a newer `avm-res-databricks-workspace` version exposing `delete_query_parameters`/force-deletion (decision 4 best end-state); if found, the Databricks belt is dropped. (3) OQ-062 records the live-proof test - the estate is EMPTY now, so all-layers-green is proven by DOC/PROVIDER reasoning here and must be CONFIRMED on the next full `enable_data_platform=true` deploy -> teardown. (4) After a green waved teardown, reconsider removing the vestigial `mode` input (ADR-065 follow-up still open). (5) Coordinate the SAME teardown pass with OQ-063 / ADR-067 (purge the soft-deleted Security LAW so rebuilds start clean) - both are teardown-completeness items and should land together so one full deploy -> teardown proves both.

**Implementable spec for DevSecOps (teardown.yml), precise enough to implement without re-deriving:**

- Each of the 11 Phase-1 root jobs (`synthetic`, `corp-a1`, `corp-a2`, `online-p1`, `bank-app-p1`, `bank-data-p1`, `connectivity`, `security`, `identity`, `management`, `management-groups`):
  - In the job `if:`, RESTORE the `inputs.target == 'all'` disjunct alongside the single-root check: `(inputs.target == 'all' || inputs.target == '<that-root>')`. Leave `!cancelled()`, `needs.guard.result == 'success'`, the disarm success-or-skipped clause, and `inputs.mode == 'terraform'` unchanged. (Undoes ADR-065 decision 1's removal of that disjunct.)
  - In the `with:` block, KEEP `manage_runner_ip: ${{ inputs.target != 'all' }}` for the single-root path AND enable the flip for the serialized target=all path. Simplest correct form: `manage_runner_ip: true` on every Phase-1 job (it is only ever reached by a serialized job now), OR a guard expression that is true whenever a Phase-1 job runs. The hard invariant DevSecOps must preserve: exactly one state-SA-touching job open at any instant.
- Serialization mechanism: make the Phase-1 `needs` a strictly LINEAR chain at target=all so no two firewall-flipping jobs overlap. Reverse-deploy topological order (each job `needs` only the previous plus `disarm`): `synthetic` -> `bank-data-p1` -> `bank-app-p1` -> `online-p1` -> `corp-a2` -> `corp-a1` -> `security` -> `connectivity` -> `identity` -> `management` -> `management-groups`. This must still respect deploy dependencies (spokes before connectivity/security; connectivity+security before management; management+identity before management-groups) - the given order does. Do NOT keep the current parallel fan-out of the 5 spokes or the {connectivity,security} pair; linearize it. (For a single-root dispatch the chain is inert - only the one targeted job's `if:` is true - so single-root behaviour is unchanged.)
- Phase 0 DISARM: unchanged (runs first, target=all only, hard gate on all Phase-1 jobs).
- Phase 2 AZ SWEEP demoted to the belt: (a) MG-hierarchy removal when `remove_mg_hierarchy=true` (unchanged step 4); (b) KV soft-delete report (unchanged, informational); (c) Databricks orphan handling per decision 4 PREFERRED form - move the existing step-1 workspace force-delete (`--force-deletion --no-wait`) to run as a Phase 0.5 belt BEFORE Phase 1 (alongside DISARM) so it cascades the managed RG while the workspace is live; (d) the ADR-057 subscription-scope step 6 stays but is now a pure idempotent no-op backstop (the management/security layer destroys already cleaned it). Keep `az_run` / `is_auth_error` / auth-fail-loud conventions unchanged.
- Phase 3 VERIFY: unchanged (loud truth-gate; will now audit a terraform-emptied estate; an orphan managed RG is a correct VERIFY 2/3 failure).
- `mode` input, guard, deploy.yml guard: unchanged from ADR-065 (mode kept vestigial; `mode=az-sweep`+single-root rejected; deploy.yml `target=all && apply` guard stays). Correct the teardown.yml header/NOTICE that currently says target=all skips Phase 1 by design - it no longer does.

**What requires LIVE PROOF (estate is empty now; distinguish reasoning from proof):**
- DOC/PROVIDER-verified here (high confidence): KV is not a destroy blocker (provider source v4.71.0); the module issues a plain workspace delete (module source); a plain delete retains the managed RG (MS doc ms.date 2026-07-21); the deny-assignment is on the managed RG not the workspace; ARM `forceDeletion` exists at 2026-01-01 (REST ref); F1/F3 mitigations are mechanism-level and portable; ADR-055 durable OIDC covers destroy jobs (workflow inspection).
- MUST be proven on the next full deploy -> teardown (cannot test on an empty estate): (a) all 11 serialized layer destroys go green E2E against a live populated estate within the ADR-055 durable-OIDC envelope, including the slow APIM/AKS/Databricks deletes; (b) whether the orphan managed RG's deny-assignment survives a plain workspace delete in THIS estate's UC-by-default configuration (which determines if the decision-4 ALTERNATIVE's `--force-deletion-types` is needed and works - the PREFERRED form sidesteps this); (c) the 11-in-a-row per-job firewall flip is race-free as a sequence and the SA is audited Deny between jobs; (d) a follow-on greenfield apply succeeds with no Databricks managed-RG collision. Exact test recorded in OQ-062.

**ADDENDUM 2026-07-30 (implementation landed and code-review APPROVED; follow-up 5 satisfied; one permanent consequence to accept). Body above unedited, per append-only.**

1. **Status moves from Proposed to Accepted-and-implemented, not to proven.** Decisions 1 to 6 are implemented (the serialized 11-job Phase-1 chain with the unconditional per-job JIT firewall flip, DISARM still Phase 0, az-sweep demoted to a belt, the decision-4 PREFERRED Databricks handling as a Phase 0.5 precascade job, VERIFY unchanged, single-root path unchanged) and the implementation passed code review on 2026-07-30 with all five prior BLOCK findings verified closed. INV-1, INV-2 and INV-3 remain UNPROVEN against a live estate; that is unchanged and is owned by OQ-062, not by this ADR.

2. **Follow-up 5 ("coordinate the SAME teardown pass with OQ-063 / ADR-067") is SATISFIED.** The Security LAW purge landed in this pass. Its PRIMARY mechanism is not what this ADR anticipated and is better: `platform/security/providers.tf` sets `features { log_analytics_workspace { permanently_delete_on_destroy = true } }`, so Phase 1's `security` layer destroy purges the workspace NATIVELY, which is exactly consistent with this ADR's governing argument that owning providers should destroy their own objects and az-sweep should be a belt. The az-sweep LAW purge is retained as the backstop and was MOVED from step 3b to step 7b so it runs after `wait_for_rgs_gone` (it previously raced the security RG's `--no-wait` delete and could report "nothing to do" on a workspace that soft-deleted minutes later). OQ-063 is RESOLVED 2026-07-30; its live-proof obligation was folded into OQ-062's single test rather than duplicated.

3. **Permanent consequence of the mechanism in 2, added to the Consequences list above.** `permanently_delete_on_destroy` is a PROVIDER-level (root-wide) feature. Any FUTURE Log Analytics workspace added to `platform/security` is therefore also permanently purged on ANY destroy of that root, including an accidental wrong-root destroy, with no 14-day recovery window. Intended for the Security LAW, and it is the trade this pass makes, but it is a genuine and permanent widening of that root's destroy blast radius. A workspace that needs the soft-delete safety net must not be added to `platform/security`.

4. **Correction to decision 4's implementation note, wording only, no behaviour change.** `scripts/teardown-databricks-precascade.sh:59` describes Phase 0.5 on failure as "a hard gate ahead of Phase 1's bank-data-p1 destroy". It is NOT a hard gate, and correctly so: `bank-data-p1` takes `databricks-precascade` in `needs` for ORDERING only and its `if:` never reads that job's result, so the layer still runs and still goes green if the precascade fails. That is what preserves INV-1 and lets an orphan managed RG surface as the loud VERIFY 2/3 failure decision 5 intends, instead of a silently skipped mandatory layer. The wiring is right, the sentence is wrong; carried in OQ-062 for the next teardown-script change. Do not "fix" the workflow to match the sentence.

5. **Cross-reference hygiene.** References to this ADR by commit hash (for example `0dac862` in ADR-067's 2026-07-29 addendum and in OQ-063) were invalidated by the rebase onto `banking`; the ADR-066 doc commit is now `9974efa`. Cite branch plus ADR number, not a hash.

### ADR-065: A `target=all` teardown runs the firewall-independent az-sweep whole-estate flow only; the Phase-1 per-root `terraform destroy` jobs are restricted to single-root targets (and get the concurrency-safe JIT firewall flip). The "open the state SA once per run for target=all" option is rejected.

- **Date:** 2026-07-29
- **Section:** 10 (Pipeline & Tooling) / teardown. AMENDS ADR-058 decision 3 (mode=terraform is primary) as it applies to `target=all` only; does NOT enact ADR-058's rejected Option C. Builds on ADR-054 (four-phase shape, VERIFY-is-the-truth-gate), ADR-025 (JIT state-SA firewall flip), ADR-060 (deploy `target=all` is not an apply path). ADR-054/025/060 otherwise stand unchanged.
- **Status:** Accepted (architect ruling; user directed the diagnosis of teardown runs 30476963087 and 30483247892 and that the fix land through CI with no manual deletes; implementation handed to DevSecOps, then Code Review, then merge)
- **Decision makers:** claude (architect); user (requirement: a successful full teardown must end GREEN, and the state SA must never be left open after a run)

**Context:**
Two `target=all mode=terraform` teardowns (runs 30476963087, 30483247892, ref banking) failed the same way: every one of the ~11 Phase-1 `terraform destroy` jobs failed at `terraform init` with `403 ... This request is not authorized to perform this operation`, then burned its full 6-attempt retry budget for nothing. The retries are futile because nothing opens the firewall in the first place.

Root cause, verified in the workflow files on origin/banking. `_tf-root.yml` takes a `manage_runner_ip` input: TRUE flips the state SA `default_action` to Allow for the job window (restored to Deny on exit); FALSE relies on a static runner IP already in the bootstrap `ip_rules`. `deploy.yml` wires `manage_runner_ip: ${{ inputs.target != 'all' }}`. `teardown.yml` does NOT wire `manage_runner_ip` at all, so it is always FALSE for every Phase-1 job. The state SA (bootstrap/main.tf) is `default_action = Deny` with a single operator IPv4 in `ip_rules` and NO GitHub-hosted-runner ranges. So every Phase-1 job, on a distinct ephemeral runner drawn from a dynamic SNAT pool, is network-denied at the state backend. The estate was BUILT single-target (ADR-060), so this never bit deploy.

Two facts settle the ruling:

1. The whole-estate az-sweep flow has ZERO state-backend dependency. Phase 0 DISARM (`teardown-disarm.sh`), Phase 2 AZ SWEEP (`teardown-az-sweep.sh`) and Phase 3 VERIFY (`teardown-verify.sh`) are pure `az` REST/CLI operations against estate resources; none touches the `tfstate` container (grep-confirmed 2026-07-23, see the FIX-6 note in `teardown-az-sweep.sh` line 101). None runs `terraform init`. So none depends on the state-SA firewall. This is proven live, not just by inspection: in run 30483247892 the 11 Phase-1 jobs 403'd, yet Phase 0 DISARM, Phase 2 AZ SWEEP and Phase 3 VERIFY were all GREEN and the estate was provably clean. The only reason that run's overall conclusion was "failure" is the 11 pointless Phase-1 reds.

2. At `target=all`, Phase-1 `terraform destroy` is redundant with, and worse than, the az-sweep that follows it. Phase 2 AZ SWEEP runs in BOTH modes for `target=all` (its `if:` gates on `target == 'all'`, not on mode), and Phase 3 VERIFY is the definition of "torn down" (ADR-054 principle 6, ADR-058). So the az-sweep is ALWAYS the completeness mechanism at `target=all`. Worse, `terraform destroy` provably cannot finish the estate's F2 resources (Databricks managed RG deny-assignment, APIM/AKS slow deletes, purge-protected KV; ADR-054 F2) - az-sweep was purpose-built with `--force-deletion` / `--no-wait` / `az_relogin` to finish exactly those. So even if the firewall were opened, a `target=all` Phase-1 pass would stall or fail on the F2 resources, and Phase 2 az-sweep would have to finish them anyway. `mode=terraform + target=all` has never produced a green run since the ADR-054 redesign (ADR-058 context; the only green teardowns have been the az-sweep flow).

There is a second, latent gap the same root cause creates: a SINGLE-root `mode=terraform` teardown (`target != all`) also runs with `manage_runner_ip` FALSE, so it too would 403 at init. That path is genuinely useful (retire one root through its owning provider, keeping state consistent) and it is concurrency-safe to open the firewall for it (one root, one runner, one flip), exactly like deploy.yml.

**Decision:**

1. **`target=all` teardown runs the firewall-independent whole-estate az-sweep flow ONLY.** The Phase-1 per-root `terraform destroy` jobs are restricted to single-root targets: drop the `inputs.target == 'all'` disjunct from every Phase-1 job's `if:`. At `target=all` all Phase-1 jobs then skip and the run is exactly Phase 0 DISARM + Phase 2 AZ SWEEP + Phase 3 VERIFY, which is the proven-green path (run 30483247892) and ends GREEN with no futile Phase-1 reds. This makes the DEFAULT dispatch (`target=all`, the default `mode=terraform`) behave identically to `mode=az-sweep`, so it now succeeds instead of failing 11 jobs.

2. **The single-root Phase-1 `terraform destroy` gets the concurrency-safe JIT firewall flip.** Wire `manage_runner_ip: ${{ inputs.target != 'all' }}` into every Phase-1 root job's `with:` block, byte-identical to deploy.yml. This lets a single-root terraform teardown reach the firewalled state SA. It is concurrency-safe because only one root runs, so only one job ever flips `default_action`, and `_tf-root.yml`'s existing `if: always()` step restores Deny on exit. terraform-destroy is thereby RETAINED as the supported, provider-owned, state-fidelity path at the scope where it works.

3. **Reject the "open the state SA once per run for target=all" option (task Direction 2).** See Alternatives. A run-level Allow window on the CMK-holding state SA to enable a redundant, F2-stalling Phase-1 pass is the wrong trade.

4. **Amend ADR-058 decision 3 for `target=all` only, without enacting its rejected Option C.** ADR-058 restored `mode=terraform` to "primary by policy" so it would cross-check az-sweep; that primacy is now scoped to SINGLE-root. At whole-estate scope the primary and only supported path is az-sweep. This is NOT Option C ("abandon terraform-destroy entirely"): terraform-destroy remains primary and fully supported at single-root scope. ADR-058's cross-check intent is preserved by (a) az-sweep completeness (ADR-058 Option A, implemented and proven), (b) the ADR-058 decision-2 per-wave coverage obligation, (c) VERIFY as the truth gate, and (d) single-root terraform-destroy remaining available for any root an operator chooses to retire cleanly.

5. **`mode` is now vestigial but is KEPT (do not remove the input in this change).** After decisions 1 and 2, `mode` carries no information: at `target=all` the az-sweep flow runs regardless of mode, and at single-root `mode=az-sweep` is already rejected by the existing guard so mode is forced to `terraform`. Removing a `workflow_dispatch` input would break any saved dispatch or runbook that passes `mode=az-sweep` (GitHub rejects a dispatch carrying an undeclared input), so `mode` is kept, its `description` is corrected to say it does not affect a `target=all` run, and a guard NOTICE states the same at dispatch time. Do NOT reject `target=all + mode=terraform` - it now runs the correct proven flow and must end GREEN, which is the entire point. Eventual removal of `mode` is a follow-up (below), after a green run on the new gating.

6. **deploy.yml (related, separable).** ADR-060 already rules `target=all` deploy is NOT an apply path (full-estate deploy is sequential single-target). That path is currently UN-guarded, so `target=all + action=apply` can be dispatched and would 403 ~10 jobs at init identically to teardown. Add a guard job to deploy.yml rejecting `inputs.target == 'all' && inputs.action == 'apply'` (symmetric with the existing untaint / force-unlock target=all guards). This partially resolves OQ-057. `target=all + action=plan` has the SAME firewall exposure (manage_runner_ip false -> init 403) and does not function as the "exploration" path ADR-060 describes; it is read-only and low-harm, so it is left as an open follow-up rather than fixed here.

**Invariants (definition of done for the implementation):**
- INV-1: a successful full (`target=all`) teardown ends GREEN. No Phase-1 job runs at `target=all`, so there are no futile red `terraform destroy` jobs; a clean estate yields Phase 0 + Phase 2 + Phase 3 all green, with VERIFY as the loud completion gate. A green VERIFY is no longer buried under 11 reds.
- INV-2: the state SA is never left open after a run. At `target=all` it is never opened (Phase 1 does not run, so no `manage_runner_ip` flip occurs). At single-root it is opened only by that one job and restored to Deny by `_tf-root.yml`'s existing `if: always() && inputs.manage_runner_ip && env.SA_OPENED == '1'` step.

**Alternatives considered:**
- **Direction 2 shape (a): flip `default_action=Allow` once per run for target=all (a run-level opener job before Phase 1 and a closer job after Phase 3).** This IS concurrency-safe if done run-level (one opener, one closer, sequenced by `needs`), unlike the per-job flip the LESSON 31 header warns about. Rejected anyway because: it opens the network layer of the CMK-holding state SA for the ENTIRE teardown run (tens of minutes, versus the ~2-3 minute single-root window ADR-025 accepted), widening the residual-leak-on-cancel exposure to the whole run, all to enable a Phase-1 pass that is REDUNDANT with the Phase-2 az-sweep that runs anyway, SLOWER, and STALLS on the F2 resources az-sweep exists to finish. VERIFY already proves a clean estate at target=all without it (run 30483247892). The security-window cost buys a redundant, partial pass. Not worth it.
- **Direction 2 shape (b): serialize all Phase-1 destroys onto ONE runner/job so a single IP allowlist suffices.** Rejected: it collapses the parallelism into one long serial job that can outlive the OIDC assertion (the AADSTS700024 problem ADR-054 principle 7 was built to avoid, and a single monolithic job cannot re-login mid-stream the way the az scripts do), and it still runs the redundant, F2-stalling terraform pass.
- **Direction 2 shape (c): self-hosted runner with a static egress IP in the state SA `ip_rules`.** Rejected for the POC: an infra change (runner VNet/host, static egress, maintenance) already deferred to production by ADR-025 (OQ-018) and re-confirmed by ADR-060. It is the correct production-grade direction (private endpoint plus VNet-integrated runner) and would let a `target=all` terraform-destroy work cleanly, but it is a funded infra decision, disproportionate to fixing a teardown signal, and out of scope for this turn.
- **Add GitHub hosted-runner IP ranges to bootstrap `ip_rules`.** Rejected: hosted-runner egress is a large, changing SNAT pool - exactly the racy design ADR-025 replaced.
- **Reject `target=all + mode=terraform` at the guard (fail before login).** Rejected in favour of decision 1: rejecting the DEFAULT dispatch is user-hostile, and after decision 1 the combination is no longer a footgun - it runs the correct, proven whole-estate flow and ends green. A guard NOTICE plus corrected input docs is enough.
- **Remove the `mode` input entirely.** Correct end-state (mode is now vestigial), but rejected FOR THIS CHANGE because removing a declared `workflow_dispatch` input breaks any saved dispatch/runbook that still passes it. Deferred to a follow-up after a green run.

**Consequences:**
- Positive: the always-red teardown signal is fixed. A successful full teardown is all-green, so a real regression is visible instead of masked by 11 structural reds (the user's stated requirement).
- Positive: no change to the proven-green az-sweep machinery. At `target=all` the job set is now identical to today's `mode=az-sweep` run, which is the only shape that has been green since the redesign. Minimal risk to hard-won teardown code.
- Positive: closes the latent single-root teardown gap (Phase-1 could not reach the firewalled state SA) with the same concurrency-safe pattern deploy.yml already uses.
- Positive: the state SA is never opened for a `target=all` run at all, which is a stronger posture than a run-level Allow window - the CMK state backend keeps its network deny throughout every full teardown.
- Negative / trade-offs: `target=all` teardown no longer runs a provider-owned `terraform destroy` cross-check pass. Mitigated by az-sweep completeness (ADR-058 Option A), the ADR-058 decision-2 per-wave coverage obligation, and VERIFY as the truth gate. The cross-check remains available at single-root scope.
- Negative: `mode` becomes an input that does not affect a `target=all` run until it is removed. Mitigated by corrected docs and a guard notice; flagged for removal.
- Follow-ups required: (1) DevSecOps implements the teardown.yml changes (decisions 1, 2, 5) and, separably, the deploy.yml guard (decision 6). (2) After a green `target=all` teardown on the new gating, remove the vestigial `mode` input (and its guard) and simplify the Phase-1 `if:` to `inputs.target == '<root>'` only - a fast-follow, coordinated with any runbook that still passes `mode`. (3) OQ-057 (deploy `target=all`: guard apply now; decide plan-at-all: drop it or give it run-level firewall handling). (4) OUT OF SCOPE and NOT folded in per the task: the 2 KV-purge `MethodNotAllowed` warnings seen in run 30483247892 are soft-deleted, purge-protected vaults that VERIFY treats as informational/recoverable (recovered on the next redeploy); they are a separate known item, not a teardown defect this ADR addresses.

**Implementable spec for DevSecOps (teardown.yml, then deploy.yml):**

teardown.yml, each of the 11 Phase-1 root jobs (`synthetic`, `corp-a1`, `corp-a2`, `online-p1`, `bank-app-p1`, `bank-data-p1`, `connectivity`, `security`, `identity`, `management`, `management-groups`):
- In the job `if:`, change the trailing `(inputs.target == 'all' || inputs.target == '<that-root>')` to just `inputs.target == '<that-root>'`. Leave every other clause (`!cancelled()`, `needs.guard.result == 'success'`, the disarm success-or-skipped clause, `inputs.mode == 'terraform'`) unchanged.
- In the job `with:` block, add one line: `manage_runner_ip: ${{ inputs.target != 'all' }}`. (Evaluates true whenever a Phase-1 job now runs; written this way to stay byte-identical to deploy.yml and self-documenting.)

teardown.yml, guard job and inputs:
- Keep guard #1 (`confirm == 'destroy'`) and guard #2 (`mode == 'az-sweep'` requires `target == 'all'`) unchanged.
- Do NOT add a rejection for `target=all + mode=terraform`. Instead, add a NOTICE in the guard's confirmation echo for `target=all`, e.g. "target=all runs the whole-estate az-sweep flow (Phase 0 DISARM + Phase 2 AZ SWEEP + Phase 3 VERIFY); the per-root Phase 1 terraform destroy is skipped by design, and the mode input does not affect a target=all run."
- Update the `mode` input `description` to say the same: mode only affects a single-root dispatch; at `target=all` the az-sweep flow always runs.
- Update the teardown.yml header block (Phase 1 description) and `_tf-root.yml`'s `manage_runner_ip` note to record that teardown now also uses the JIT flip for single-root (previously only deploy.yml). Docs-only, behavior-neutral.

deploy.yml (separable PR):
- Add a guard job (same shape as `guard-untaint-target`) with `if: ${{ inputs.target == 'all' && inputs.action == 'apply' }}` that echoes an `::error::` ("full-estate deploy is sequential single-target per ADR-060; target=all + apply would 403 every root at init against the firewalled state SA. Dispatch one root at a time.") and exits 1. Leave `action=plan` unchanged (read-only, low-harm) pending OQ-057.

### ADR-064: The Phase 2 step 6a MG-portion budget re-sweep is REMOVED - it is the only az-sweep step that reads an MG scope AFTER the step-4 delete loop ran, which ADR-063 G-1 forbids, and it is fully redundant with the Phase 0 DISARM sweep

- **Date:** 2026-07-29
- **Section:** 10 (Pipeline & Tooling) / teardown. ENFORCES ADR-063's G-1 one-way-door invariant. SUPERSEDES the single sub-part of ADR-063 that left the Phase 2 `6a (MG portion)` FIX-2 budget re-sweep in place: ADR-063 ruled on decision 3 (Phase-0 placement) and decision 4 (step 4-pre demotion) but never revisited this third, post-deletion MG-scope sweep. Builds on ADR-054 (four-phase shape, MG list-snapshot oracle, auth-fail-loud), ADR-062 (deleted-scope-403), ADR-057 (step 6). ADR-063 otherwise stands unchanged.
- **Status:** Accepted (architect ruling; user directed the diagnosis of run 30476963087 and that the fix land through CI with no manual deletes; implementation handed to DevSecOps, then Code Review, then merge)
- **Decision makers:** claude (architect); user

**Context:**

Live teardown run 30476963087 (target=all, mode=terraform, remove_mg_hierarchy=true, ref banking, HEAD ea6c630) was the first run to reach Phase 2 `6a (MG portion)` alive; earlier attempts died sooner. Phase 0 DISARM passed (the recent is_auth_error fix worked). Phase 2 az-sweep then did the real cleanup: deleted every estate RG, deleted `diag-aa-to-law`, re-parented all 5 subscriptions to tenant root, ran the step-4 MG delete loop that deleted the ENTIRE globaris tree (connectivity, security, identity, management, online, corp, decommissioned, sandbox, platform, landingzones, globaris), and cleared subscription-scope budgets, cost exports and anomaly actions. It then crashed at `-- 6a (MG scope): consumption budgets --` on MG `connectivity`:

> `ERROR: Unauthorized({"code":"RBACAccessDenied", ...})` / "Interactive authentication is needed. Please run: az login"

producing the fatal `MG-scope budget list failed for MG connectivity` (teardown-az-sweep.sh line 927, section 9.4 auth-fail-loud).

The block that crashed carries its OWN fresh `mg_snapshot_load` (line 907), added as the code-review BLOCK-2 follow-up specifically to avoid a stale snapshot. It did not help, and the sequence proves why:

1. line 907 reloaded the snapshot AFTER step 4 had already deleted `connectivity`.
2. line 913 `mg_in_snapshot connectivity` returned TRUE, so `az account management-group list` STILL enumerated `connectivity`.
3. line 924 the budget list at the `connectivity` scope returned 403 RBACAccessDenied.

The MG-list control-plane read is eventually-consistent and lagged the committed `az account management-group delete`, while the SP's globaris-subtree grant over the `connectivity` scope was already gone (the deleted-scope-403 ADR-062 documented). So the fresh reload saw a false "present" and the sweep walked into a scope it had itself just deleted. The BLOCK-2 fix rested on a false premise: that `az account management-group list` reflects a just-committed MG delete immediately. It does not.

This is not an independent bug. It is a loose end of ADR-063. ADR-063 established G-1 ("an extension object must be swept BEFORE its host scope is deleted ... deleting a host that still has an owned extension object attached is a ONE-WAY DOOR"), moved the authoritative MG-scope sweep to Phase 0 DISARM (decision 3), and demoted step 4-pre to a pre-deletion last-chance gate (decision 4). But the `6a (MG portion)` FIX-2 budget re-sweep was never revisited, and it is the ONE az-sweep step that touches an MG scope AFTER the step-4 delete loop. It sits on the far side of the exact door G-1 forbids. Its stated purpose (cover the `remove_mg_hierarchy=false` window where step 4-pre never runs) is void, because Phase 0 DISARM sweeps MG-scope budgets across every MG in `MG_SCOPES`, before any deletion, in BOTH modes, regardless of `remove_mg_hierarchy`.

The two remnants Phase 3 VERIFY then reported (Microsoft.CostManagementExports still Registered; securityContacts/default still present) are downstream of this crash, not separate defects: the crash aborted step 6 before 6c (RP unregister) and 6e (securityContacts) ran. Removing the crash lets those steps run.

**Decision:**

REMOVE the Phase 2 `6a (MG portion)` MG-scope consumption-budget re-sweep from `scripts/teardown-az-sweep.sh` in full, including its dedicated fresh `mg_snapshot_load`. Do not soften it, do not reorder it, do not re-gate it. It is genuinely dead and hazardous, and the honest answer is removal.

Justification, per mode. `az-sweep` runs only when `target=all`, and the workflow gates `az-sweep` on `needs.disarm.result == 'success'` while `disarm` sits under the same `target=all` gate (ADR-063 decision 9), so Phase 0 DISARM has ALWAYS run and succeeded before Phase 2 in every path where 6a could execute:

- **mode=terraform, remove_mg_hierarchy=true:** Phase 0 DISARM swept every MG-scope budget with a `confirm_gone_or_fail_primary` completion check while all MGs were live; Phase 1 terraform-destroyed the roots; step 4-pre re-verified pre-deletion; step 4 deleted the MGs. By the time 6a runs there is nothing to sweep and the scopes are gone. Pure hazard, zero coverage. This is the mode that crashed.
- **mode=terraform, remove_mg_hierarchy=false:** step 4 deletes no MG, so there is no crash, but 6a still adds nothing - Phase 0 DISARM already swept those budgets pre-deletion.
- **mode=az-sweep (state-gone F4), either remove_mg_hierarchy:** Phase 1 is skipped by design, but Phase 0 DISARM still runs (target=all gate, no mode check) and is the authoritative MG-scope sweep. With remove_mg_hierarchy=true the step-4 delete loop then deletes the MGs and 6a would re-hit them; with false, 6a is redundant against DISARM.

Nothing is lost. There is no re-creation window between Phase 0 and Phase 2: DISARM deletes every MG-scope policy ASSIGNMENT (and each DINE identity's role assignment) first, so no deployIfNotExists remediation can re-create a budget, and the estate's MG budgets are Terraform/DISARM-removed, not policy-created. The DINE belt-and-suspenders rationale for a second sweep is therefore void. Completion evidence is not lost either: Phase 0 DISARM's own `confirm_gone_or_fail_primary` is the PRIMARY-evidence gate for MG-scope budgets (there is no Phase 3 VERIFY of MG-scope budgets because the scope is 403-shadowed post-delete; ADR-063 decision 8's VERIFY 10 checks only MGs still present).

Governing invariant this enforces (add to the mechanism's design principles):

> No teardown step may READ or WRITE an MG scope after that MG could have been deleted in the same job. MG-scope extension objects are swept EXACTLY ONCE, strictly before any MG deletion: authoritatively in Phase 0 DISARM (both modes, every MG in MG_SCOPES still live), with step 4-pre as the pre-deletion last-chance gate. There is deliberately NO post-deletion MG-scope sweep, because the MG-list existence oracle (`az account management-group list`) is eventually-consistent and cannot reliably distinguish "this MG was just deleted by our own step-4 loop" from "the token died" during the deletion-propagation window.

**Alternatives considered:**

- **Option 2, reorder the 6a MG-portion sweep to run before the step-4 delete loop** - rejected. That is exactly what step 4-pre already is (a pre-deletion MG-scope budget/diagnostic-setting/exemption sweep). Relocating 6a would duplicate step 4-pre's budget limb and still preserve a sweep Phase 0 DISARM already makes redundant. Correct pre-deletion coverage exists twice already (Phase 0 authoritative plus step 4-pre gate); a third copy adds maintenance surface, not safety.
- **Option 3, gate the re-sweep to skip MGs no longer live via a refreshed snapshot or a per-MG existence re-check** - rejected on the crux the run exposed. The existence oracle IS the unreliable signal: `az account management-group list` still returned the just-deleted `connectivity`, so `mg_in_snapshot` returned a false "present" even off a fresh reload. A per-MG existence re-check reads the same lagging endpoint and returns the same false "present". You therefore cannot distinguish a deleted-scope-403 (our own delete) from a dead-token-403 (real auth failure) from the snapshot, and section 9.4 must NOT soften auth-fail-loud for a genuinely live MG. The only mechanism that WOULD distinguish them is tracking in-process which MG names step 4 deleted and skipping them, but that is just "do not sweep an MG after deleting it", i.e. removal, dressed up with a redundant data structure to keep a redundant sweep.
- **Keep 6a but downgrade its list/delete failures to warn-and-continue** - rejected. It violates ADR-063 decision 4 (MG-scope failures are fatal) and re-introduces the swallow-the-error false-clean class section 9.4 exists to close. There is no safe way to keep a post-deletion MG-scope sweep.

**Consequences:**

- Positive: the run 30476963087 crash class is closed at the root, not patched around; step 6c (RP unregister) and 6e (securityContacts) become reachable again, removing the two downstream Phase 3 VERIFY remnants. G-1 is now honoured everywhere in az-sweep, not just at Phase 0 and step 4-pre. One fewer eventually-consistent MG-list read per run.
- Negative / trade-offs: MG-scope budget removal now depends on Phase 0 DISARM having run, but that is already a hard precondition (ADR-063 decision 9 gates az-sweep on disarm success), so this removes a redundant belt, not a load-bearing one. If a future change ever let Phase 2 run WITHOUT Phase 0 (it must not; decision 9 forbids it), step 4-pre still covers the remove_mg_hierarchy=true path pre-deletion and VERIFY 10 still fails loud on any survivor at a live MG.
- Follow-ups required: DevSecOps implements the removal (spec below); Code Review confirms no other post-step-4 MG-scope read remains; QA confirms a clean target=all + remove_mg_hierarchy=true teardown reaches step 7 and Phase 3 VERIFY 10 with no `6a (MG scope)` 403.

**Implementation spec for DevSecOps** (`scripts/teardown-az-sweep.sh`, origin/banking HEAD ea6c630):

1. DELETE the entire `6a (MG portion, FIX-2 ...)` block, currently lines 889-947: from the comment line `# --- 6a (MG portion, FIX-2, teardown-completeness extension sweep, 2026-07-23). MG-scope` through the closing `done` of its `for mg in "${MG_DELETE_ORDER[@]}"` consumption-budget loop (the `done` immediately before the `# --- 6d.` comment). This removes the block comment (889-906), the dedicated `mg_snapshot_load` guard (907-910), the `echo "-- 6a (MG scope): consumption budgets --"` (911), and the loop (912-947). Also remove the now-doubled blank line left behind.
2. DO NOT touch the RG-scope budget sweep that also carries the FIX-2 label. It lives INSIDE the `for sub in "${SUBS[@]}"` subscription loop of step 6a (the `discover_live_rgs` plus per-RG `Microsoft.Consumption/budgets` block). It is RG-scoped, runs on surviving RGs, stays queryable post-delete, and is backstopped by VERIFY 6 (RG scope). It stays.
3. DO NOT touch step 4-pre (`Phase 2 step 4-pre` last-chance gate) or the step-4 `mg_snapshot_load` (line 473). Both are pre-deletion and remain load-bearing. Only the SECOND `mg_snapshot_load` (line 907, unique to the removed block) is deleted.
4. Comment-coherence updates (comment-only, no behaviour change):
   - Step-4 header comment (around lines 462-472): remove the sentence "Step 6a's own MG-scope budget sweep (FIX-2, further down this script) does its OWN fresh reload immediately before it runs ...". The step-4 `mg_snapshot_load` is now consumed only by step 4-pre and the step-4 delete loop.
   - The remove_mg_hierarchy=false skip message (line 478): drop the trailing "(MG-existence snapshot above is still loaded for step 6a's MG-scope budget sweep.)".
   - The file header seventh-amendment / ADR-063 block: add a note that ADR-064 removed the 6a MG-portion re-sweep; leave the FIX-2 RG-scope budget description intact.
   - Add a one-line ADR-064 amendment header to the file's top comment block pointing to this ADR.
5. No change to `teardown-common.sh`, `teardown-disarm.sh`, `teardown-verify.sh`, or `.github/workflows/teardown.yml`. Phase 0 DISARM's MG-scope sweep and its `confirm_gone_or_fail_primary` completion checks are the sole authoritative MG-scope path and are unchanged.

**Sibling-limb enumeration (so the budget limb is not fixed while a sibling is left to fail next run):** a full read of `scripts/teardown-az-sweep.sh` confirms `6a (MG portion)` consumption budgets is the ONLY step that reads or writes an MG scope AFTER the step-4 delete loop (line 664). There is NO post-deletion MG-scope diagnostic-setting or policy-exemption sibling: those two classes are swept only in step 4-pre (pre-deletion). Every other step 6 sub-step (6d subscription exemptions, 6d RG exemptions, 6b Defender pricing, 6c RP unregister, 6e Microsoft.Security singletons, 6f tenant AAD diagnostic setting) and step 7 (RG reconcile) operates at subscription, RG or tenant scope, never MG. Removing the budget limb leaves no sibling to fail on the next run.

---

### ADR-063: An extension object is swept BEFORE its host scope is deleted, and it is claimed by CONTAINMENT rather than by name - the MG-scope sweep moves to Phase 0 DISARM, MG-scope delete failures become fatal, resource-scoped diagnostic settings get a pre-RG-delete pass, and the name-only ownership predicate is retired as the primary test

- **Date:** 2026-07-23
- **Section:** 10 (Pipeline & Tooling) / teardown; EXTENDS ADR-054 (four-phase shape, MG list-snapshot
  oracle, auth-fail-loud), ADR-057 (step 6 class handling) and ADR-062 (discovery-over-enumeration,
  three-limb predicate). Supersedes nothing. ADR-058's independent QA gate stands unchanged.
- **Status:** Accepted (architect ruling; user voided the rerun and directed that every survivor class
  be found before any re-attempt, with all cleanup through the CI teardown workflow and no manual
  deletes)
- **Decision makers:** claude (architect); user (voided the 2026-07-23 rerun at Step 2, set the
  no-manual-deletes bar, and required a true greenfield confirmed by live discovery before rerun)

**Context:**

The 2026-07-23 full-estate rerun died at Step 2. `platform/management` planned green at 36/0/0, created
32 of its 36 resources, then failed on 4 objects that "already exist - needs to be imported": the three
MG-scoped consumption budgets `budget-mg-{globaris,platform,landingzones}-globaris`, and the
resource-scoped diagnostic setting `diag-aa-to-law` on `aa-platform-globaris-poc`. That is failure #1
of 4 against the user's standing bar, and it was diagnosed rather than blind-retried.

The read-only orphan probe added by the FIX-1..7 change (merged as PR #46) then ran twice, at 22:19Z
and 22:50Z. The 22:50Z run is authoritative ground truth for the current partial estate and reported 13
findings: the 3 MG budgets above and 5 subscription-scoped budgets, all classified OWNED; `diag-aa-to-law`,
classified **unowned**; three Defender pricing plans (`AI`, `Discovery`, `FoundationalCspm`) still at
tier `Standard`; and `securityContacts/default`, also classified **unowned**. It found no policy
exemptions at any scope, no tenant `Microsoft.AadIam` diagnostic setting, and no AADDS managed domain.

Two things in that result are the subject of this ADR. First, the MG budgets survived a teardown that
deleted their MGs, which means the sweep is ordered wrong, not merely incomplete. Second, two live,
estate-created objects were classified **unowned** by a predicate whose primary test is "does the name
contain `globaris`" - so even a correctly ordered sweep would have walked past them.

*Why ordering, and not another class entry.* ADR-062 already established that MG-, subscription- and
tenant-scoped objects are scope-path-keyed extension objects and that parent deletion does not cascade
them. The corollary was not drawn at the time and is the whole point here: deleting the host scope does
not delete the extension object, it makes the object **invisible, unreachable and resurrectable**. It
is unreachable specifically for this principal - `sp-alz-poc-cicd`'s Resource Policy Contributor and
User Access Administrator grants are scoped at the `globaris` MG and are deleted WITH that subtree, so
a call against a deleted globaris-tree scope returns HTTP-403 `AuthorizationFailed`, not a clean 404
(proved empirically in probe run 29756715840 and already documented at `scripts/teardown-common.sh`
around line 529, which is why MG existence resolves through the `mg_snapshot_load` list oracle). And it
is resurrectable because the object re-collides the moment Step 1 recreates an MG with the same name,
which is exactly what happened.

*Why the merged FIX-1 position does not fix it.* FIX-1 put the MG-scope sweep at Phase 2 step 4-pre.
Two defects:

- **D1:** step 4-pre sits inside the `remove_mg_hierarchy=true` branch, which is the NON-default. At
  the default `false`, MG-scope diagnostic settings and MG-scope exemptions are never swept at all.
- **D2:** on `mode=terraform` it is structurally unreachable. Phase 2 `needs` every Phase 1 job, Phase
  1 destroys `platform/management-groups` last, so by the time Phase 2 runs the MGs are already absent
  from the snapshot (skip) and the globaris-scoped grants are already dead (403).

Phase 0 DISARM runs in BOTH modes, always, and gates Phase 1 through `needs: disarm`, with every MG
present and every grant still bound. That is the only point in the mechanism where the sweep is both
reachable and authorised.

**Decision:**

**1. RBAC feasibility: the Phase-0 sweep is possible TODAY with zero bootstrap change, but on a grant
that is not in `bootstrap/identity.tf`, and that dependency is now explicit.**

None of the roles `sp-alz-poc-cicd` holds at or above MG scope through `bootstrap/identity.tf` carries
any `Microsoft.Consumption` write or delete action.

> **CORRECTED 2026-07-23 (code review, in-place on unpublished text).** The first draft of this table
> was wrong for two of the four roles and was not re-derived from the live definitions.
>
> **Authority for the corrected tables, in precedence order.** (1) `az role definition list --name
> "<role>" --query "[0].permissions[0].actions"` run against the live `globaris.org` tenant on
> 2026-07-23 - what this tenant actually enforces. (2) The generated source of Microsoft Learn's
> built-in-roles reference (`MicrosoftDocs/azure-docs`,
> `articles/role-based-access-control/built-in-roles/{management-and-governance,privileged}.md`, last
> updated 2026-07-01 in the "June refresh - Updated permissions for several roles" publish). The two
> agree exactly, for all four roles, action for action. Each list below is the complete `actions`
> array; `notActions`, `dataActions` and `notDataActions` are empty for all four.
>
> **One of the review's two findings was itself a false positive and is recorded as such.** The review
> asserted that Management Group Contributor carries none of the four actions the draft cited for it.
> Three of those four are indeed absent, but `Microsoft.Authorization/*/read` **IS** in the live role,
> confirmed by both authorities above. The draft was right about that limb, and it is the load-bearing
> one: it is what authorises a role-assignment read at Tenant Root Group. The review's downstream
> conclusion - that the decision 1b pre-flight 403s on every dispatch - therefore does not follow. See
> 1b, which re-rules on the merits rather than on that finding.

   - **Management Group Contributor** (`5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c`), at **Tenant Root
     Group** (`bootstrap/identity.tf` row 1):
     `Microsoft.Management/managementGroups/delete`, `Microsoft.Management/managementGroups/read`,
     `Microsoft.Management/managementGroups/subscriptions/delete`,
     `Microsoft.Management/managementGroups/subscriptions/write`,
     `Microsoft.Management/managementGroups/write`,
     `Microsoft.Management/managementGroups/subscriptions/read`,
     `Microsoft.Authorization/*/read`.
     *Draft errors, all over-statements:* there is **no** namespace wildcard on `Microsoft.Management`
     (six explicit actions, not `managementGroups/*`), and the role carries **none** of
     `Microsoft.Resources/subscriptions/resourceGroups/read`, `Microsoft.Resources/subscriptions/read`
     or `Microsoft.Support/*`. *Not an error:* `Microsoft.Authorization/*/read` is real, and it is the
     load-bearing limb - see 1b.
   - **Resource Policy Contributor** (`36243c78-bf99-498c-9df9-86d9f8d28608`), at **globaris MG**
     (row 2): `*/read`, `Microsoft.Authorization/policyassignments/*`,
     `Microsoft.Authorization/policydefinitions/*`, `Microsoft.Authorization/policyexemptions/*`,
     `Microsoft.Authorization/policyenrollments/*`, `Microsoft.Authorization/policysetdefinitions/*`,
     `Microsoft.PolicyInsights/*`, `Microsoft.Resources/deployments/*`, `Microsoft.Support/*`.
     *Draft errors:* the draft asserted "no `policyExemptions` limb and no `*/read`" and both
     assertions are false. The role carries `Microsoft.Authorization/policyexemptions/*` outright,
     and it carries the **global** `*/read`, which is broader than the `Microsoft.Authorization/*/read`
     the reviewer proposed as the correction. It does not carry
     `Microsoft.Resources/subscriptions/resourceGroups/read` as a discrete action (that read is
     subsumed by `*/read`).
   - **User Access Administrator** (`18d7d88d-d35e-4fb5-a5c3-7773c20a72d9`), at **globaris MG**
     (row 3): `*/read`, `Microsoft.Authorization/*`, `Microsoft.Support/*`. Draft was correct.
   - **Contributor:** assigned at the 5 subscriptions only, so it reaches nothing at MG scope.

   **Two out-of-band ADR-041 bridge grants are also live and the draft inventoried only one of them.**
   Per OQ-051, verified per scope on 2026-07-21, `sp-alz-poc-cicd` additionally holds BOTH of the
   following at **Tenant Root Group**, neither declared in any Terraform root:

   - **Cost Management Contributor** (`434105ed-43f6-45c7-a02f-909b2ba83430`): `Microsoft.Consumption/*`,
     `Microsoft.CostManagement/*`, `Microsoft.Billing/billingPeriods/read`,
     `Microsoft.Resources/subscriptions/read`, `Microsoft.Resources/subscriptions/resourceGroups/read`,
     `Microsoft.Support/*`, `Microsoft.Advisor/configurations/read`,
     `Microsoft.Advisor/recommendations/read`, `Microsoft.Management/managementGroups/read`,
     `Microsoft.Billing/billingProperty/read`. It carries **no `Microsoft.Authorization` action at all**.
   - **User Access Administrator** at Tenant Root Group: same three actions as row 3, but anchored one
     level above the globaris subtree.

   All three tenant-root assignments were re-confirmed live on 2026-07-23 by listing role assignments
   at exact tenant-root scope: the CI SP holds Management Group Contributor, User Access Administrator
   and Cost Management Contributor there, none of them carrying an ABAC condition, and the scope has
   zero deny assignments. That matters for 1b.

   The Consumption conclusion is UNCHANGED by the correction: `Microsoft.Consumption/*` appears in
   exactly one role this principal holds, Cost Management Contributor, and it is a bridge grant.

   **But the correction materially NARROWS what depends on that bridge grant, and this is good news.**
   The draft treated the Phase-0 sweep as a single unit resting on an undeclared out-of-band role.
   With the corrected tables, the three classes separate cleanly:

   - **Policy exemptions at MG scope: fully covered by a STANDING bootstrap row.** Resource Policy
     Contributor at globaris carries `Microsoft.Authorization/policyexemptions/*` outright - the limb
     the draft wrongly recorded as absent - and User Access Administrator at globaris covers it again
     via `Microsoft.Authorization/*`. Two independent standing routes, neither of them a bridge grant.
     This class survives OQ-051 revoking both tenant-root bridges, with no new grant needed ever.
   - **Consumption budgets at MG scope: the ONLY class that depends on the bridge grant.** This is the
     whole of the exposure, not the sweep as a whole.
   - **MG-scope diagnostic settings: uncovered by anything, bridge or standing** - unchanged, latent,
     see 1d.

   So the honest scope of the ADR-041 dependency is one of three classes, and the durable fix in 1c
   only ever had to cover that one class. 1d is corrected accordingly.

The operation itself is real and explicitly MG-capable: Microsoft's management-and-governance
permissions reference defines `Microsoft.Consumption/budgets/delete` as "Delete the budgets by a
subscription or a management group", with the same wording on `/read` and `/write`, and the REST route
is scope-generic
(`DELETE {scope}/providers/Microsoft.Consumption/budgets/{budgetName}?api-version=2024-08-01`, matching
the pinned `BUDGETS_API_VERSION`).

The contradiction resolves as follows: **the MG budgets were never created by the bootstrap role set.**
They were created under the ADR-041 bridge grant, `Cost Management Contributor` at Tenant Root Group,
applied out-of-band on 2026-07-16 and verified live per-scope on 2026-07-21. That role carries
`Microsoft.Consumption/*` and `Microsoft.CostManagement/*`, so it covers write and delete at every
descendant scope, and being tenant-root anchored it survives the globaris-subtree delete.
`docs/preclearance/b0a-redeploy.md` PC-3 already records this as "a LATENT ADR-021 gap previously
masked by the standing Owner @ globaris".

   - **1a.** No bootstrap change is required for this teardown. ADR-058 QA item 14 already asserts the
     grant is present after teardown.
   - **1b. RE-RULED 2026-07-23 (second pass, after the review's finding 1 was itself disproved
     against the live tenant). A pre-flight DOES ship, and it is neither of the two designs on the
     table.** The draft mandated a role-assignment existence check
     (`az role assignment list --scope <tenant root> --role "Cost Management Contributor"`); the
     reviewer replaced it with a Consumption-plane capability probe
     (`GET {tenantRootScope}/providers/Microsoft.Consumption/budgets`). **Both are rejected. The
     pre-flight becomes an EFFECTIVE-PERMISSIONS assertion at the MG scopes the sweep actually
     targets.** Reasoning, in the order the facts were established:

     **(i) The original design was executable. The review's blocking finding was a false positive.**
     Management Group Contributor carries `Microsoft.Authorization/*/read` and is assigned at Tenant
     Root Group, which covers `roleAssignments/read` and the `roleDefinitions/read` needed to resolve
     `--role` by name. The check would not have 403'd. Recorded so this is charged to the review, not
     silently absorbed.

     **(ii) The reviewer's replacement probe is NOT discriminating, and this is proven live, not
     argued.** Listing role assignments at exact tenant-root scope on 2026-07-23 returns three
     assignments for the CI SP: Management Group Contributor, Cost Management Contributor, and **User
     Access Administrator** - the second ADR-041 bridge grant, which the draft's inventory omitted.
     User Access Administrator carries the global `*/read`, which authorises
     `Microsoft.Consumption/budgets/read` at tenant root **with no Consumption grant present at all**.
     So `GET {tenantRootScope}/providers/Microsoft.Consumption/budgets` returns 200 whether or not the
     grant the probe exists to check is there. It is a gate that can only ever say GO. Relocating it
     to MG scope is worse: Resource Policy Contributor and User Access Administrator both carry `*/read`
     at globaris as STANDING bootstrap rows, so the masking there is permanent and survives OQ-051.
     This is the same silent-pass failure mode as decision 7's VERIFY 6e no-op, and it would be the
     fourth instance in this project.

     *The reviewer's underlying principle is right and is adopted:* probing a capability tests what
     deny assignments and ABAC conditions actually permit, whereas enumerating an assignment tests only
     that grant metadata exists. The instance fails because it probes the wrong VERB (read, not delete)
     at the wrong SCOPE (tenant root, not the eleven MGs). Fix both and the principle holds.

     **(iii) The original design is discriminating but structurally brittle, so reverting is also
     wrong.** Three defects, independent of finding 1: it is pinned to Tenant Root Group, so landing
     OQ-059(a)'s recommended globaris-scoped grant would make it hard-fail every dispatch while the
     sweep worked perfectly; it cannot see a grant delivered via group membership or a custom role
     (OQ-059(a) option B); and resolving the SP's own object id needs `az ad sp show`, a Microsoft
     Graph call that no ARM role grants and that `bootstrap/identity.tf:39` explicitly says this SP
     does not need ("No API permissions needed (all access is via ARM RBAC, not Graph)"). It works
     only via an `Application.Read.All` consent granted out-of-band on 2026-07-08 and recorded nowhere
     but a comment in `platform/identity/providers.tf:11-17`. A check asserting one undeclared
     out-of-band grant would itself depend on a second one.

     **(iv) The design that satisfies both: ARM's effective-permissions API, at MG scope.**
     `GET {scope}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01` returns the
     CALLER's own effective `actions`/`notActions` at that scope.

     > **Management-group scope support is UNDOCUMENTED but VERIFIED.** Microsoft documents only
     > `List For Resource` and `List For Resource Group` for this operation group at 2022-04-01, with
     > no management-group URI template - which is why the first pass of this correction declined to
     > specify it. It was then executed against the live tenant on 2026-07-23 at
     > `/providers/Microsoft.Management/managementGroups/<tenantRootId>` and returned HTTP 200 with a
     > correct effective-permission set. It works. Because it is undocumented at this scope, decision
     > 3d's convention applies with full force: a FAILED probe is never an EMPTY probe, and gets its
     > own label - see the failure classification below.

     Why it satisfies every constraint the other two miss:

     - **Discriminating.** The needed action is `Microsoft.Consumption/budgets/delete`. A `*/read`
       entry does not match it. The masking that defeats a read probe cannot occur.
     - **Scope-correct.** Query each MG in `MG_SCOPES` - the exact scopes the sweep deletes at. The
       response includes grants inherited from every ancestor, so it is correct whether the grant sits
       at tenant root, at globaris, or anywhere between.
     - **Grant-shape agnostic.** Survives OQ-059(a) option A, option B, a group-delivered grant, and
       OQ-051 revoking both tenant-root bridges. **It is the only proposal that does not have to be
       rewritten when OQ-041/OQ-059(a) resolves.**
     - **Graph-free.** Pure ARM. No object-id resolution, so `bootstrap/identity.tf:39`'s contract
       holds.
     - **Authorised by a STANDING row.** The call needs `Microsoft.Authorization/permissions/read`,
       covered by Management Group Contributor's `Microsoft.Authorization/*/read` at Tenant Root Group,
       which inherits to every MG and is a `bootstrap/identity.tf` row, not a bridge grant.
     - **A complete oracle in THIS estate.** The response reflects role assignments but not deny
       assignments, and does not represent ABAC conditions. Both were checked live on 2026-07-23 at
       tenant root: **zero deny assignments, and none of the SP's three tenant-root assignments carries
       a condition.** Stated as a caveat rather than hidden: if a deny assignment or a conditioned
       assignment is ever introduced, this probe stops being complete and decision 4's fatal delete
       remains the backstop.

     **Specification for the implementer.** Placement: `scripts/teardown-disarm.sh`, immediately AFTER
     `mg_snapshot_load` and BEFORE the per-MG policy-assignment disarm loop - so it runs after the one
     read the SP is always entitled to make, and before the first thing in the run that changes estate
     state. For each MG in `MG_SCOPES` present in the snapshot,
     `GET ${ARM_BASE}$(mg_scope_path "$mg")/providers/Microsoft.Authorization/permissions?api-version=2022-04-01`,
     then glob-match each returned `actions` entry (treating `*` as a wildcard) against the literal
     action strings below, and subtract anything matched by a `notActions` entry:

     | Action tested | Absent means | Rationale |
     |---|---|---|
     | `Microsoft.Consumption/budgets/delete` | **FATAL, do not dispatch** | The class that depends on the ADR-041 bridge grant. Name ADR-041 and OQ-059(a) in the message. |
     | `Microsoft.Authorization/policyExemptions/delete` | **FATAL** | Should always be present via two standing globaris rows. Absent means something changed that nobody recorded. |
     | `Microsoft.Insights/diagnosticSettings/delete` | **WARN only, never fatal** | Expected absent - the KNOWN DESIGN GAP of 1d / OQ-059(b). Must print as such so it is never misread as a dead token. |

     Failure classification, and it matters because the API is undocumented at this scope: a non-200
     from the permissions call itself is **not** "capability absent". Fail loud under a distinct label
     (`TEARDOWN-P0-PREFLIGHT-UNAVAILABLE`) stating that the pre-flight could not be evaluated, and
     abort. Disposition of that label is architect-owned via the pre-clearance gate; decision 4's fatal
     MG-scope delete plus decision 9's workflow gate are what make a considered override survivable.

     **This is additive to, not a substitute for, decisions 4 and 9.** The first MG-scope budget DELETE
     remains the only test with no proxy in it at all, it remains FATAL, and decision 9 ensures a
     failed DISARM can no longer let `az-sweep` proceed. The pre-flight buys one thing: the failure
     lands before DISARM removes any policy assignment, rather than after.

     **OQ-051 still carries a hard dependency, restated correctly:** revoking the Cost Management
     Contributor bridge without first landing 1c breaks the MG-scope BUDGET sweep specifically - not
     the exemption sweep, which is covered by standing rows. The pre-flight above now detects that
     before dispatch regardless of where the replacement grant is placed.
   - **1c.** If the bridge grant is ever revoked, the minimum durable replacement is
     `Cost Management Contributor` scoped at the **globaris MG**, as a standing `bootstrap/identity.tf`
     row. It is sufficient (all three MG budgets are globaris or its descendants; subscription budgets
     are already covered by Contributor), it inherits the BOOTSTRAP-ORDERING dance of the existing
     MG-scoped rows, and it dies with the subtree - which is precisely what makes the ordering
     invariant in decision 2 load-bearing rather than merely tidy. Parked as OQ-059(a).
   - **1d.** Other MG-scope classes. Conclusions unchanged by the correction above; the supporting
     reasoning is tightened, since the draft under-counted the coverage.

     **Policy exemptions ARE deletable** at every scope in `MG_SCOPES` (all 11 are globaris or its
     descendants), and by two independent routes rather than the one the draft cited: User Access
     Administrator's `Microsoft.Authorization/*` at globaris, AND Resource Policy Contributor's
     `Microsoft.Authorization/policyexemptions/*` at globaris, which the draft wrongly recorded as
     absent. Nothing extra needed, with redundancy.

     **MG-scope diagnostic settings are NOT deletable by this principal.** No role carries
     `Microsoft.Insights/diagnosticSettings/delete` at MG scope - not the three bootstrap rows, and
     not either ADR-041 bridge grant (Cost Management Contributor has no `Microsoft.Insights` action;
     User Access Administrator at Tenant Root Group has `*/read` and `Microsoft.Authorization/*`, and
     neither reaches an `Microsoft.Insights` write). The estate declares none (grep-confirmed across
     every root), so the gap is latent. Keep both the LIST (authorised several times over by the
     global `*/read` in Resource Policy Contributor and User Access Administrator at globaris) and the
     DELETE, but the failure message must state that a 403 there is a KNOWN DESIGN GAP, not a dead
     token, so it is never misread as the auth-fail-loud signal. Parked as OQ-059(b).

**2. THE GOVERNING INVARIANT (G-1), and the reason this is a new ADR rather than a patch to ADR-062:**

   > **An extension object must be swept BEFORE its host scope is deleted or submitted for deletion.
   > Deleting the host first does not delete the extension object: it makes it invisible, unreachable
   > and resurrectable. Deleting a host scope that still has an owned extension object attached is a
   > ONE-WAY DOOR, and teardown must fail loud AT that door rather than pass through it.**

   Corollary, and the part that keeps costing this project runs: "the parent cascade will get it" must
   be PROVEN per type, never assumed. ADR-062 proved the cascade for RG-scoped exemptions and disproved
   it for subscription-scoped ones. This ADR disproves it for MG-scoped budgets. The pattern is now
   three-for-three that an unproven cascade assumption becomes a requires-import collision on the next
   deploy, days later, with teardown green the whole time.

**3. Placement: `scripts/teardown-disarm.sh` (Phase 0), after the per-MG policy-assignment disarm loop
and before the final failure roll-up.** Not interleaved with that loop, so no DINE assignment can
re-remediate mid-sweep. The in-flight branch `fix/teardown-phase0-mg-sweep` already carries the correct
amendment header comment at that location and its root-cause reasoning is adopted as written.

   Discovery is per MG in `MG_SCOPES`, skipping any MG absent from `mg_snapshot_load` (a FAILED load
   remains FAIL LOUD and never degrades to an empty set), against base
   `${ARM_BASE}$(mg_scope_path "$mg")`:

   | Class | Discovery | Delete |
   |---|---|---|
   | Consumption budgets | `GET .../providers/Microsoft.Consumption/budgets?api-version=${BUDGETS_API_VERSION}` | same path + `/{name}` |
   | MG diagnostic settings | `GET .../providers/microsoft.insights/diagnosticSettings?api-version=${MG_DIAGNOSTIC_SETTINGS_API_VERSION}` | same path + `/{name}` |
   | Policy exemptions | `GET .../providers/Microsoft.Authorization/policyExemptions?api-version=${POLICY_EXEMPTIONS_API_VERSION_NEW}&$filter=atExactScope()` | same path + `/{name}` |

   Four non-optional construction rules:

   - **3a.** Build delete URLs from `mg_scope_path` + name, NEVER from `${ARM_BASE}${id}`. Microsoft's
     own Budgets List sample returns `"id": "subscriptions/.../budgets/TestBudget"` with NO leading
     slash. The merged FIX-1 code is already right to build from name; keep it that way.
   - **3b.** Send `$filter=atExactScope()` AND additionally check client-side that each returned `id`
     starts with this MG's scope path. The filter is only live-verified at SUBSCRIPTION scope
     (ADR-062 6d); the client-side belt removes any dependence on an unverified MG-scope semantic.
   - **3c.** No server-side JMESPath ownership filter. FIX-1's `value[?contains(name,'globaris')].name`
     happens to match today's three budgets, but it re-creates exactly the sweep/verify coupling
     ADR-062 removed. List every row, classify in the ONE shared bash predicate from decision 6.
   - **3d.** Inherit every existing convention unchanged: `az_run` so stdout stays a clean data
     channel, `is_auth_error` on every non-zero, a failed list is never an empty list, absent-is-success,
     and `confirm_gone_or_fail_primary` after every delete.

   `MG_DELETE_ORDER` is NOT used here. The Phase-0 sweep iterates `MG_SCOPES`, because the scopes are
   independent and there is no delete ordering to respect at that point; `MG_DELETE_ORDER` continues to
   govern only the step 4 MG delete loop. The snapshot oracle is what makes this work at all, and at
   Phase 0 it is at its most complete because nothing has been deleted yet.

**4. At MG scope, a non-auth delete failure is FATAL, and step 4-pre is demoted to a last-chance gate.**

   Everywhere else in the sweep, warn-and-continue is justified by "the next run retries idempotently".
   At MG scope that justification is void, because THIS SAME RUN may go on to delete the scope that
   makes the retry possible. So:

   - A failed MG-scope delete in Phase 0 aborts the run.
   - Any survivor still found at step 4-pre aborts the ENTIRE step 4 MG delete loop under a distinct
     `TEARDOWN-P0MG-SURVIVOR` label, leaves the MG tree standing, and fails the run. Step 4-pre keeps
     its deletes as a cheap remnant-catch, but it is no longer the primary mechanism.
   - Leaving the tree standing costs one re-dispatch, which ADR-054 point 8 already establishes as the
     safety net. Deleting it costs the ability to ever SEE the survivor again. That asymmetry decides
     it.

**5. New step 2-pre: resource-scoped diagnostic settings are swept before the RGs are deleted.**

   This class has NO sweep anywhere today - `RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION` is referenced
   only by the read-only probe. Add a pass after step 1 and BEFORE step 2 submits its `--no-wait` RG
   deletes: `discover_live_rgs`, list resources per RG, then
   `GET ${ARM_BASE}{resourceId}/providers/Microsoft.Insights/diagnosticSettings?api-version=${RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION}`
   and delete every owned row. Feasibility is proven rather than assumed:
   `scripts/teardown-probe-extensions.sh` already performs this exact enumeration and completed twice
   on 2026-07-23.

   Mechanism note, recorded honestly because the fix must not appear better-founded than it is:
   `diag-aa-to-law` is declared at `platform/management/main.tf:493`. It cannot have been created by the
   failed apply (azurerm raises requires-import BEFORE creating), and it cannot be riding an RG that
   survived (the same apply created both the RG and the automation account). The operating hypothesis
   is therefore resourceUri-keyed retention inside `Microsoft.Insights` that re-surfaces when a resource
   with an identical id is recreated. A same-run policy-created setting that happens to carry an
   identical estate-specific name cannot be formally excluded. The fix does not depend on which is
   true - which is exactly the point of G-1.

**6. The ownership predicate is retired as a name test and rebuilt on CONTAINMENT, in three tiers.**

   - **T1 CONTAINMENT (primary, structural).** An object is owned if its HOST SCOPE is owned: (a) an MG
     in `MG_SCOPES`; (b) an RG matching `RG_SWEEP_QUERY`; (c) any resource whose id contains
     `/resourceGroups/{rg}/` where `{rg}` matches `RG_SWEEP_QUERY`.
   - **T2 FIXED-NAME SINGLETON.** For singletons whose NAME AZURE DICTATES, ownership is: scope is one
     of the 5 estate subscriptions AND type appears on an explicit `ESTATE_DECLARED_SINGLETON_TYPES`
     list that mirrors what the roots declare. The name is never consulted. Seeded with
     `Microsoft.Security/securityContacts`. Defender pricings stay on `DEFENDER_PLANS_TO_FREE`
     (ADR-057 d5); `autoProvisioningSettings` and `workspaceSettings` keep their existing
     no-predicate treatment.
   - **T3 NAME (retained, last resort).** `is_globaris_owned`, the `exempt-` limb and the
     `policyAssignmentId` limb are unchanged, and apply to objects whose host scope is not itself
     estate-owned (subscription-scope non-singletons, tenant scope). ADR-062's three-limb predicate
     keeps its exact behaviour.

   **Anti-widening rules, which are what make this safe:** T1 may NEVER be inverted (owning a child
   never implies owning its host); T1(c) and T2 may never match outside the 5 estate subscription ids;
   T2's type list is exact-match and grows only by reviewed PR with a dated justification, the same
   discipline already applied to `SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST`.

   **Why this is not a widening at all.** T1 claims strictly LESS than the sweep already claims: step 2
   deletes the entire RG and step 4 deletes the entire MG. If T1 is ever wrong about an object, then
   the sweep was already wrong about its HOST, and the host is by far the larger error. T2 cannot
   over-match: one object per subscription, in a subscription that is wholly estate-owned, of a type
   the estate declares.

   Applied to the two live misclassifications: **`diag-aa-to-law` is owned by T1(c)** (its host id
   contains `/resourceGroups/rg-management-globaris-poc/`) - no name limb and no special case.
   **`securityContacts/default` is owned by T2.**

**7. A no-op discovered while ruling on decision 6, and it is live in merged code today.**

   `teardown-az-sweep.sh` FIX-4(i) and `teardown-verify.sh` VERIFY 6e both filter security contacts on
   `is_globaris_owned(name)`, with a comment asserting the API accepts the custom Terraform name
   `security-contact-globaris`. Microsoft's `securityContacts` Create reference at the pinned
   `2023-12-01-preview` constrains `securityContactName` to `minLength: 7, maxLength: 7,
   pattern: ^(default)$`, and the `SecurityContactName` enum has exactly one value, `default`. The
   22:50Z probe confirms the live name IS `default`. So the sweep logs "not estate-owned", deletes
   nothing, and **VERIFY 6e then certifies the subscription clean with the object still live.** That is
   the third instance of this same trap (`diag-activity-to-security-law` was the first,
   `exempt-dbx-managed-storage-bank-data-p1` the second). Decision 6's T2 tier is the fix.

   Flagged for DevSecOps, NOT asserted: whether `azurerm_security_center_contact`
   (`platform/security/main.tf:160-161`, name `security-contact-globaris`) will hit a requires-import
   guard against the live `default` object on the next `platform/security` apply. Rated
   high-probability; not confirmed in provider source this session.

**8. VERIFY 10 is added, because Phase 3 looks at no MG scope at all today.**

   VERIFY 0 through 9 contain no MG-scope check (confirmed by reading `teardown-verify.sh`). Add
   VERIFY 10 after VERIFY 9: for every MG in `MG_SCOPES` that is ALSO present in the Phase 3 snapshot,
   list all three classes at exact scope; fail on any owned row under `TEARDOWN-VERIFY-MGSCOPE`, and
   fail on any UNCLASSIFIED row per ADR-062 decision 6. When the tree is already gone, VERIFY 10 must
   PRINT that MG scope is unverifiable post-delete by design and that completion was gated in Phase 0
   and at step 4-pre. It must not silently pass.

**9. `az-sweep` and `verify` must gate on `needs.disarm.result`, because Phase 0 is now the only place
the MG-scope sweep runs. (Added 2026-07-23 during the 1b re-ruling. Independent of 1b and of ADR-063's
own subject: this is a pre-existing hole in the workflow, and it is what made a failed DISARM dangerous
in the first place. Also raised as OQ-060.)**

   Every Phase-1 root job in `.github/workflows/teardown.yml` gates on
   `needs.disarm.result == 'success' || needs.disarm.result == 'skipped'`, so all eleven skip when
   DISARM fails. `az-sweep` and `verify` do not: both check only `needs.guard.result == 'success'` and
   `inputs.target == 'all'`. They list `disarm` in `needs`, but for ordering only, and the job's own
   header comment says so explicitly - so this was a deliberate ADR-054-era choice ("az-sweep is the
   fallback, it must run even when Phase 1 does not"), not an oversight.

   That choice was defensible when DISARM only removed policy assignments. It is not defensible now,
   for two reasons that ADR-063 itself creates:

   - A failed DISARM means the MG-scope extension sweep did not complete, which under G-1 means the
     estate has owned extension objects attached to scopes that `az-sweep`'s own
     `remove_mg_hierarchy` loop may then delete. That is the one-way door this entire ADR exists to
     close, walked through by a job that was told the door was open.
   - On `target=all` with DISARM failed, all eleven Phase-1 jobs skip and `az-sweep` proceeds alone.
     The run degrades silently from `terraform destroy` to raw REST deletes, every root's tfstate is
     left stale against a deleted estate, and `verify` then runs and can report the estate clean,
     because it is checking live Azure and live Azure really is empty. Teardown goes green having
     destroyed the estate out from under its own state files.

   Ruling: add `&& (needs.disarm.result == 'success' || needs.disarm.result == 'skipped')` to both
   jobs' `if:`, matching the Phase-1 form exactly, including the `skipped` limb so single-target
   dispatches (where `disarm` does not run) are unaffected. Phase-1 root outcomes stay ungated -
   `az-sweep` remains the remnant-catch for a failed root, which is its actual purpose. DISARM is a
   precondition, not a peer.

   **9a. OWNER OVERRIDE, 2026-07-23. The architect's position on the `verify` half was put to the
   owner and OVERRULED. Both jobs are gated, unconditionally.**

   This is recorded as an override rather than folded into the ruling above, because the two positions
   were different and the losing argument should not have to be rediscovered later.

   - *What the architect proposed:* gate `az-sweep` hard, but leave `verify` ungated so it still runs
     read-only after a failed DISARM, on the grounds that VERIFY is the best inventory of live estate
     state the pipeline produces and suppressing it on exactly the runs that went wrong is backwards.
     It would have required VERIFY to print loudly that the run ABORTED, so a clean VERIFY could never
     be misread as "teardown succeeded". DevSecOps independently recommended the same split.
   - *What the owner ruled:* gate both. `az-sweep` AND `verify`.
   - *What is lost, stated plainly rather than minimised:* a failed DISARM now suppresses the
     verification pass as well as the sweep, so the operator gets **no VERIFY output precisely in the
     runs where the estate is most likely to be in a bad or half-known state**. Diagnosing such a run
     needs a separate read-only probe run (`teardown-probe-extensions.sh`) or a manual dispatch, rather
     than reading the failed run's own VERIFY section.
   - *What is gained:* one uniform rule across every job downstream of Phase 0, with no
     conditional-wording contract for anyone to get wrong, and no path by which a green-looking VERIFY
     can be produced by a run that aborted. Given that three incident classes in this project have come
     from a green run that did not do what its name implied, the owner weighted uniformity over
     diagnostic reach. That is a defensible reading of the same evidence.

   OQ-060 records the override as its resolution.

- **Ungate step 4-pre only (drop the `remove_mg_hierarchy` condition)** - rejected: fixes D1 and leaves
  D2 untouched, so the sweep stays structurally unreachable on `mode=terraform`, which is the mode a
  healthy estate uses.
- **Sweep in Phase 1 via terraform destroy** - rejected: mode-bound, and it dies for exactly the roots
  that need it most. Three state blobs are CLASS-A absent (`bank-app-p1`, `bank-data-p1`, `synthetic`),
  so Phase 1 cannot reach their objects at all.
- **Grant Owner, or Management Group Reader, at tenant root** - rejected: against ADR-021 and the
  OQ-008 scope-down, and against ADR-054's ruling on what this SP may hold. Decision 1c's globaris-scoped
  `Cost Management Contributor` is the minimum that works.
- **A third hand-written special case for `default`** - rejected: that is precisely the pattern that has
  now failed three times. T2 generalises it once.
- **Revert 1b to the original role-assignment existence check at Tenant Root Group** - rejected, though
  NOT for the reason the review gave (that finding was a false positive; the check was authorised and
  would have run). Rejected because it asserts grant metadata rather than capability, needs a Microsoft
  Graph call the bootstrap says this SP does not need, and hard-fails the moment OQ-059(a)'s recommended
  globaris-scoped grant lands. See 1b(i) and 1b(iii).
- **Keep the reviewer's Consumption-plane read probe at tenant root** - rejected: proven
  non-discriminating against the live tenant. User Access Administrator is live at Tenant Root Group as
  the second ADR-041 bridge grant and its global `*/read` authorises
  `Microsoft.Consumption/budgets/read` there with no Consumption grant present, so the probe returns
  200 either way and can only say GO. Relocating it to MG scope is permanently worse, since Resource
  Policy Contributor and User Access Administrator both carry `*/read` at globaris as standing rows.
  See 1b(ii).
- **Drop the pre-flight entirely and rely on decision 4 plus decision 9** - rejected, but it was the
  first-pass ruling and it is a defensible fallback. It is correct by construction and costs nothing to
  maintain; it simply lands the failure after DISARM has already removed policy assignments, leaving an
  estate standing with its guardrails off for one re-dispatch. Since 1b(iv) turned out to be verifiable,
  the cheap earlier failure is worth having. If the undocumented permissions call at MG scope ever
  regresses, this is the fallback to take.
- **Metadata stamping as the general ownership mechanism** - rejected as the GENERAL answer.
  `Microsoft.Consumption/budgets`, `Microsoft.Insights/diagnosticSettings` and the `Microsoft.Security`
  singletons expose no metadata object and no tags surface at all, so it is impossible for three of the
  five classes in play. It remains a good policy-plane nicety - see the OQ-058(a) note.
- **Delete the MG tree anyway and clean the survivors up afterwards** - rejected: there is no
  afterwards. Post-delete the scope path is unreadable to this principal (403, not 404), which is the
  entire mechanism this ADR exists to close.

**Consequences:**

- Positive: the collision class that voided the 2026-07-23 rerun is closed at its mechanism rather than
  at its symptom; the sweep becomes reachable in BOTH teardown modes; two live estate objects that the
  predicate walked past are now claimed structurally; a one-way door is converted into a fail-loud gate;
  VERIFY finally covers MG scope; and decision 9 closes a pre-existing workflow hole under which a
  failed DISARM let a `target=all` run destroy the estate by raw REST with zero `terraform destroy` and
  still report green.
- Negative / trade-offs: Phase 0 gets longer and makes more ARM calls per MG (11 scopes x 3 classes);
  a fatal MG-scope delete failure will now stop a teardown that previously would have completed green
  and left a landmine, so operators will see more red runs before they see fewer collisions; the
  `Cost Management Contributor` bridge grant becomes an explicit dependency of teardown rather than an
  incidental convenience; and the 1b pre-flight now depends on an ARM behaviour that is verified live
  but undocumented at management-group scope, which is a maintenance liability accepted knowingly and
  labelled distinctly so it can never be misread as "capability absent".
- Follow-ups required: DevSecOps implements decisions 3 through 9 on `fix/teardown-phase0-mg-sweep`,
  and REPLACES the pre-flight block currently in `scripts/teardown-disarm.sh` with the 1b(iv)
  effective-permissions assertion - neither the role-assignment check nor the tenant-root Consumption
  read probe survives review; the batched code-reviewer gate; the `Cost Management Contributor` grant
  is also recorded in the teardown pre-clearance doc as an architect-owned dispatch precondition,
  because a script check and a written disposition serve different purposes; then teardown dispatch and
  the ADR-058 QA greenfield confirmation. OQ-059 records the two parked RBAC questions and now
  recommends CLOSING (a) rather than carrying it. OQ-060 raised the `az-sweep`/`verify` gating question
  and is RESOLVED by the owner override recorded in decision 9a (gate both). **OQ-061 is new and is the
  most durable thing this correction surfaced:** the corrected role tables were only reachable by
  reading the live tenant, and doing so exposed at least five undeclared out-of-band grants on the CI
  principal, including a standing tenant-root User Access Administrator that `bootstrap/identity.tf`
  does not declare. That is an ADR-021 / OQ-008 problem, not an ADR-063 one, and it outlives this ADR.
  OQ-058(a) gets a dated architect note. OQ-053 is NOT resolved by this ADR.

---

### ADR-062: Phase 3 VERIFY must be strictly BROADER than the Phase 2 sweep - completeness is gated by DISCOVERY over an ARM plane, not by an enumerated class list; subscription-scoped policy exemptions added as sub-step 6d and as the proof case

- **Date:** 2026-07-21
- **Section:** 10 (Pipeline & Tooling) / teardown; AMENDS ADR-057 (adds a class to step 6 AND corrects
  ADR-057's own completeness mechanism). Does not supersede ADR-054 or ADR-058: the four-phase shape,
  token-durability model, auth-fail-loud rule, MG list-snapshot oracle and the independent QA gate all
  stand unchanged.
- **Status:** Accepted (architect ruling; user directed the CI path over any manual step, consistent
  with the standing zero-manual-teardown bar)
- **Decision makers:** claude (architect); user (ruled fix-in-CI, and specifically asked that VERIFY be
  made broader than the sweep rather than another class be bolted onto the list)

**Context:**

The subscription-scoped policy exemption `exempt-dbx-managed-storage-bank-data-p1`, declared in
`landing-zones/bank-data-p1/policy_exemptions.tf` as `azurerm_subscription_policy_exemption.dbx_managed_storage`,
survived BOTH teardowns and this morning's ADR-057 step 6 sweep. It blocks tomorrow's `bank-data-p1`
apply: azurerm 4.71.0 carries a create-time requires-import guard on this resource and returns
`ImportAsExistsError`. Its RG-scoped sibling in the SAME FILE, one resource block above it
(`azurerm_resource_group_policy_exemption.corp_paas`), died correctly.

*Why the asymmetry, at mechanism level.* This is documented Azure behaviour, not a bug. Microsoft's
policy exemption structure reference (updated 2026-06-22) states: "A policy exemption is created as a
child object on the resource hierarchy or the individual resource granted the exemption... If the
parent resource to which the exemption applies is removed, then the exemption is removed as well." The
RG-scoped exemption cascaded because Phase 2 deleted its parent resource group. The subscription-scoped
one did not, because a subscription is NEVER deleted: design section 5 rules that subscriptions are
only ever re-parented. Its parent is immortal, so nothing upstream can ever cascade it. Two further
facts, both verified live 2026-07-21:

- The exemption is still present at exact subscription scope in the landing-zones subscription, and its
  `policyAssignmentId` still names the `corp` MG assignment even though the `corp` MG itself has been
  deleted. It is dangling by construction and self-heals never.
- The ADR-048 `expires_on` of 2026-08-01 does NOT clean it up. Same Microsoft reference: "The policy
  exemption isn't deleted when the `expiresOn` date is reached. The object is preserved for
  record-keeping, but the exemption is no longer honored." Expiry stops the waiver being honoured; it
  does not remove the object, and therefore does not clear the requires-import collision. Any design
  that treats `expires_on` as a lifecycle mechanism is wrong about deletion.

No teardown script mentions exemptions at all. Phase 0 DISARM removes policy ASSIGNMENTS at MG scope,
which is a different object type at a different scope and never touches this.

**The part that matters more than the missing class, stated plainly as a critique of my own ADR from
twelve hours ago:**

ADR-057 shipped this morning with an ENUMERATED class list, and its decision 2 wrote the maintenance
burden down as a standing obligation: "Any wave that introduces a non-RG-scoped object class must
extend the Phase 2 step 6 class list and the section 13.3 QA checklist in the same change that
introduces it." Its own Consequences called that "the honest price of the rule."

That was the wrong mechanism and the wrong ruling, and it took twelve hours to disprove. An enumerated
list plus a written promise to maintain it is not a control. It is a checklist whose correctness
depends on whoever adds a resource remembering an unrelated file in an unrelated directory. The class
it missed was not exotic or newly invented: it was declared in the SAME FILE as a class the sweep did
handle, twenty lines below it, six weeks before ADR-057 was written. If the enumeration can miss that,
it can miss anything, and "maintain the list harder" is not a fix.

The structural defect underneath is that **Phase 3 VERIFY checks exactly the classes Phase 2 deletes.**
VERIFY 6, 7 and 8 were written against step 6a, 6b and 6c respectively. A gate built that way is marking
its own homework: it can confirm the sweep did what it was told, and it can never discover what nobody
told it. The evidence is that three subscription-scope classes have now been found, and every one of
them was found by a DEPLOY failing days later, never by a teardown going red. Teardown has been green
for every one of those discoveries. That is the failure mode being fixed, and adding a fourth entry to
the list without fixing it would guarantee a fourth instance.

**Decision:**

**1. The exemption class is IN, as Phase 2 step 6 sub-step 6d.** Subscription-scoped policy exemptions
at EXACT subscription scope, across all 5 subscriptions, deleted when the ownership predicate in
decision 2 holds. Placed immediately after 6a and before 6b: it is an object-class delete like 6a, and
it must precede the settings-writes in 6b and 6c. RG-scoped and resource-scoped exemptions are
deliberately excluded (they cascade with their parent, proven this cycle). MG-scoped exemptions are
excluded (the estate declares none; verified by grep of every root).

**2. The ownership predicate is STRUCTURAL first, naming second, and it was designed against the whole
declared surface rather than against the one example.** The existing sweep predicate,
`contains(name,'globaris')`, does NOT match `exempt-dbx-managed-storage-bank-data-p1`. A naive reuse
would have shipped a fix that silently does nothing. This is the second time that predicate has failed
on this surface: step 6a already carries a hand-written special case for
`diag-activity-to-security-law` for the same reason. An exemption at exact subscription scope is
estate-owned if ANY limb holds:

   - **Limb 1 (structural, primary):** `properties.policyAssignmentId` contains
     `/managementGroups/<mg>/` for any `<mg>` in the existing `MG_SCOPES` array
     (`teardown-common.sh`), matched with BOTH delimiters so it cannot match a longer name.
   - **Limb 2 (naming):** the exemption name begins with `exempt-`.
   - **Limb 3 (org, inherited convention):** the name contains `globaris`.

   Verification, and how I know it catches the real object: limbs 1 and 2 BOTH match the live survivor,
   redundantly. Limb 1 matches because the live object's `policyAssignmentId` contains
   `/managementGroups/corp/`, and `corp` is already in `MG_SCOPES`. Limb 1 is durable across MG
   deletion, which I proved empirically rather than assumed: the `corp` MG is already gone right now,
   and the exemption's stored `policyAssignmentId` string is unchanged. Limb 2 matches because every
   one of the 8 policy-exemption resources declared anywhere in this repo is named `exempt-*`
   (enumerated by grep across all roots: 6 RG-scoped spoke exemptions, the AADDS exemption in
   `platform/identity`, and the synthetic one). Limb 3 catches nothing today and is retained only for
   consistency with the surrounding steps. The predicate deliberately does NOT depend on `metadata`,
   because the live survivor has none.

**3. THE GOVERNING PRINCIPLE, and the reason this is a new ADR rather than a line added to ADR-057:**

   > **Phase 3 VERIFY's surface must be strictly LARGER than Phase 2's sweep surface. VERIFY must
   > contain at least one check that enumerates an ARM PLANE rather than a class list, and that fails
   > loud on any object it cannot classify. A gate that only inspects what the sweep was told to delete
   > cannot discover a class nobody thought of, and every class this estate has missed was missed
   > exactly that way.**
   >
   > Corollary, which replaces ADR-057 decision 2 as the primary control: maintaining the class list is
   > still required, but it is now the SECOND line of defence, not the first. The first line is that an
   > unmaintained list produces a RED TEARDOWN at teardown time rather than a failed apply days later.

**4. Mechanism: Azure Resource Graph over `policyresources`, at exact subscription scope.** Verified
live 2026-07-21 as feasible and, critically, as low-noise: one POST to
`Microsoft.ResourceGraph/resources` at `api-version=2022-10-01` (reachable via `az rest`, no CLI
extension needed) returns exactly 5 rows across all 5 subscriptions, of which 4 are well-known
Microsoft auto-provisioned policy assignments and 1 is the estate survivor. It returned
`exempt-dbx-managed-storage-bank-data-p1` on the first attempt. This is genuinely broader than the
sweep: the sweep handles one type (`policyexemptions`), the scan sees the whole policy plane
(assignments, exemptions, definitions, set definitions) and will surface a NEW policy-plane class with
no code change at all.

**5. Honest statement of what this does NOT cover, because an aspirational gate is worse than a bounded
one.** There is NO ARM operation that enumerates every object at a subscription scope. Subscription-scoped
objects are per-provider extension resources and ARM offers no cross-provider "list everything at this
scope". `az resource list` and ARG's `resources` table cover TRACKED resources only, all of which live
inside a resource group, which is precisely why every class missed so far was invisible to them.
Concretely:

   - **Covered by discovery (new):** the policy plane, via `policyresources`.
   - **NOT covered by discovery, and no mechanism exists:** Consumption budgets, CostManagement exports,
     CostManagement scheduled actions, and subscription-scope diagnostic settings. ARG has no table for
     any of them. These four remain ENUMERATED (VERIFY 6), and that limitation is stated here rather
     than papered over.
   - **Deliberately EXCLUDED from discovery, with reasons:** ARG's `securityresources` table is
     telemetry-dominated at subscription scope (measured live: 3268 regulatory-compliance assessments,
     79 assessments, 90 pricings, plus secure scores) and its one actionable type, `microsoft.security/pricings`,
     already has a dedicated check in VERIFY 7. Scanning it would produce thousands of rows of noise
     and would train people to ignore the gate, which is the outcome the user explicitly warned
     against. ARG's `authorizationresources` table returns subscription-scope role assignments,
     including the teardown principal's OWN Contributor and User Access Administrator grants, which are
     bootstrap-owned and must NEVER be removed by teardown (LESSON 54 and 57: revocation strictly after
     a verified destroy). Both exclusions are recorded so they are decisions, not oversights.

   So the honest claim is: coverage moves from "N enumerated classes" to "N enumerated classes plus
   open-ended discovery across one whole ARM plane". That is a real improvement and it is also a
   partial one.

**6. What VERIFY does with an object it cannot classify: it FAILS the teardown, once, with an
auditable escape hatch.** Every row the scan returns is classified as OWNED (predicate in decision 2,
fail loud as a sweep remnant), KNOWN-BENIGN (an exact `type` plus `name` pair on
`SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST`, pass with a log line), or UNCLASSIFIED (fail loud under a
distinct `TEARDOWN-VERIFY-UNCLASSIFIED` label). The allow-list is seeded from the live baseline with
exactly two entries, both Microsoft auto-provisioned: `SecurityCenterBuiltIn` and
`SqlVmAndArcSqlServersProtection`. Matching is exact `type` plus `name`, never a substring and never a
wildcard, so the list can only grow deliberately. The anti-noise argument is that the surface is tiny
(5 rows live), so an UNCLASSIFIED failure is loud ONCE and then permanently quiet after a reviewed
one-line PR that adds the pair with a dated justification comment. That is the opposite of a gate that
goes red every run. It also means a suppression is always visible in git history rather than being a
silent skip.

**7. ARG staleness is handled by ARM confirmation, not by trusting the index.** Resource Graph is an
indexed cache and lags ARM. A VERIFY that failed straight off an ARG row would raise false positives on
objects the sweep had just deleted, which is exactly the cry-wolf outcome to avoid. Therefore **ARG
proposes, ARM disposes**: every non-benign row gets a direct ARM GET on its `id` at a pinned
api-version before VERIFY fails. A 404 means the row was stale, log and pass. Only an ARM-confirmed
object fails the run. The KNOWN classes never depend on ARG at all, so the discovery layer is purely
additive and cannot regress the deterministic checks.

**8. Immediate unblock for the 2026-07-22 rebuild, and it is a CI path, not a manual step.** PRIMARY:
once sub-step 6d ships, dispatch the teardown workflow once (`target=all`, `mode=az-sweep`,
`remove_mg_hierarchy=false`) against the already-empty estate. It removes the survivor AND proves 6d
plus the new VERIFY live before the rebuild starts, which converts the blocker into the acceptance
test. Section 12.5 already established the safety of an immediate re-run against a mostly-empty estate,
so this needs no new safety argument. FALLBACK, only if that dispatch cannot be run in time: a
`bank-data-p1` `import` block for the exemption, gated by a recovery-only variable armed per-run per
ADR-059. The live object was byte-compared against the Terraform config on 2026-07-21 (name, scope,
`policyAssignmentId`, both `policyDefinitionReferenceIds` in order, `Waiver`, `expiresOn`, display name,
description) and is identical, so the import yields a no-op plan. The import id is constructible from a
variable and literals only, which satisfies the ADR-059 construction rule.

**9. `Microsoft.Authorization/policyExemptions` has NO GA api-version** (verified live: every offered
version is a preview). The pin is `2022-07-01-preview` for both the list and the delete. This carries a
standing LESSON 40 and 41 obligation: re-verify at every pre-clearance that the pinned version is still
offered and still returns the object, exactly as the `2025-03-01` cost-export pin is treated.

**10. Everything not named here is unchanged.** ADR-057 decisions 1 and 3 through 7 stand. ADR-057
decision 2 is amended by decision 3 above: the class list remains a wave obligation but is demoted from
primary control to backstop. ADR-058's independent QA gate is untouched and remains the outer gate.
Step 6d inherits every existing convention without exception: `az_run` for any call whose stdout is
consumed as data, `is_auth_error` classification on every non-zero, auth-fail-loud, absent-is-success
idempotency. The mode=terraform versus az-sweep ruling is NOT reopened.

**Alternatives considered:**

- **Add the exemption class to the step 6 list and stop there** - rejected. It fixes this object and
  leaves the mechanism that lost it intact, guaranteeing a fourth instance. This is the alternative the
  user specifically declined.
- **Reuse `contains(name,'globaris')` for the new class** - rejected, and it is the design trap here: it
  does not match the real object, so it would have shipped as a silent no-op.
- **Make VERIFY exhaustive by iterating every registered resource provider's subscription-scoped types
  and GETting each collection** - rejected as not real. It is thousands of calls per run, most types do
  not support a collection GET at subscription scope, and the resulting 404 and 405 noise is
  indistinguishable from a genuinely empty result. It promises completeness it cannot deliver.
- **Reconstruct estate objects from the subscription Activity Log** - rejected for now. Terraform's
  azurerm provider calls resource-provider APIs directly and does not create ARM deployments, so
  deployment history is empty and the Activity Log is the only trace. Retention is 90 days, the API is
  throttled, and the signal-to-noise is poor for a gate. Parked as OQ-058 rather than silently dropped.
- **Scan ARG's `securityresources` and `authorizationresources` too** - rejected, per decision 5. Noise
  and blast radius respectively.
- **Grant the teardown SP a broader role to be safe** - rejected and unnecessary; see Consequences. No
  grant change of any kind is required.

**Consequences:**

- Positive: the first time an unknown subscription-scoped policy-plane object survives, teardown goes
  RED at teardown time instead of a deploy failing days later. That is the specific reversal this ADR
  exists to produce.
- Positive: no RBAC change, no bootstrap re-apply, no Owner grant. Verified live per-scope, see
  section 14.1.
- Positive: the blocker doubles as the acceptance test for the fix.
- Positive: the two-limb predicate is redundant on the real object, so a single limb being wrong about
  a future object does not silently drop it.
- Negative / trade-offs: VERIFY now depends on a second service (Resource Graph) with its own
  availability and freshness characteristics. Bounded by decision 7: ARG only ever proposes, and the
  deterministic checks never touch it.
- Negative: the benign allow-list is a new maintained artifact. Accepted deliberately, because it is
  small (2 entries), exact-match only, and grows through reviewed PRs with dated justifications rather
  than silently.
- Negative: coverage is honestly partial. The cost and monitor planes have no discovery mechanism and
  stay enumerated. Stated in decision 5 rather than hidden behind a claim of completeness.
- Negative: this ADR contradicts an ADR written the same day. That is the correct outcome and the
  record should show it plainly rather than dress it as a routine extension.
- Follow-ups required: OQ-058 (parked scope: Activity-Log-based discovery, `metadata`-stamping every
  exemption so the predicate becomes purely structural, discovery for the cost and monitor planes, and
  whether `expires_on` should be dropped from the ADR-048 exemption now that it is known not to delete
  anything). Implementation contract for DevSecOps: `docs/teardown-redesign.md` section 14. QA
  acceptance criteria: section 14.5, which extends the section 13.3 checklist.

---

### ADR-061: Cross-root output Secrets are governed by a determinism contract, not by a manual "carry forward the outputs" step - name-derived values are never refreshed, non-derivable values are re-set unconditionally after their producing root applies

- **Date:** 2026-07-21
- **Section:** 10 (Pipeline & Tooling); relates to LESSON 32, DEPLOYMENT.md sections 3.2 / 3.4
- **Status:** Accepted (architect ruling, 2026-07-22 rebuild pre-clearance PC-2X / PC-3X)
- **Decision makers:** claude (architect)

**Context:**
`_tf-root.yml` feeds `platform/connectivity`, `platform/identity` and all five spokes from repo Secrets
that earlier roots produce: `PRIMARY_HUB_VNET_ID` / `_NAME` / `PRIMARY_HUB_RG_NAME`,
`PRIMARY_FIREWALL_PRIVATE_IP`, the `SECONDARY_*` set, `PLATFORM_LAW_WORKSPACE_ID`,
`PLATFORM_LAW_CUSTOMER_ID`, `PLATFORM_ACTION_GROUP_ID`. The consumer set was re-derived per root by
matching `variable "<name>"` against `var.<name>`, separating DECLARED from USED, rather than inferred
from the architecture: `platform/security` consumes NONE of them (it uses its own workspace throughout),
`platform/connectivity` consumes `PLATFORM_LAW_WORKSPACE_ID` for firewall diagnostics, and
`PLATFORM_ACTION_GROUP_ID` is declared by three spokes and read by none.
Refreshing them is entirely manual: no workflow, script or hook calls `gh secret set`, and the only
instruction is a prose "Carry forward" bullet in `DEPLOYMENT.md`. Repo Secrets are write-only, so a
consumer cannot verify what it was handed, and a stale value surfaces days later as an ARM-id parse
error or a silently dead analytics pipeline. Going into the 2026-07-22 rebuild this looked like the
highest-risk item in the run.

Live verification changed the picture. Every producing resource is deterministically named from
`org_prefix` plus `environment` (`rg-connectivity-primary-...`, `vnet-hub-primary-...`,
`rg-management-...`, `law-platform-...`, `ag-platform-...`), and the firewall private IPs are fixed by
the subnet carve (`cidrsubnet(hub_*_address_space, 10, 0)` first usable address). `gh secret list`
confirms the hub and platform Secrets were last written on 2026-07-07 and 2026-07-08, then survived the
07-11 teardown, the 07-16 rebuild, the whole banking wave B1 to B7, and two further teardowns, unchanged,
producing green applies throughout. The single exception is `PLATFORM_LAW_CUSTOMER_ID`, a workspace GUID
that is not derivable from any name; it has been stable only because the platform Log Analytics workspace
is recovered from soft delete rather than recreated at each rebuild.

**Decision:**
Classify every cross-root output Secret as DERIVED or NON-DERIVABLE. A DERIVED Secret (an ARM id or name
that is a pure function of `org_prefix`, `environment` and a fixed carve) is never refreshed as routine
work; it is only re-set if the naming inputs or the address plan change, and its correctness is proven by
a post-apply spot check rather than by a blind re-set. A NON-DERIVABLE Secret is re-set
**unconditionally** from the live resource immediately after its producing root applies, with no attempt
to verify the stored value first. For the current estate that means exactly one mandatory refresh command
per rebuild (`PLATFORM_LAW_CUSTOMER_ID`) plus one verification (the two firewall private IPs must read
`10.0.0.4` and `10.1.0.4`).

**Alternatives considered:**
- Re-set all eleven Secrets after every rebuild, rejected because ten of the eleven cannot change, the
  step is manual and forgettable, and doing unnecessary write-only writes trains the operator to treat
  the whole set as untrustworthy without improving anything.
- Verify each Secret before use, rejected because repo Secrets are write-only; there is no read path, so
  "verify" can only ever mean "re-set" (LESSON 32).
- Replace the Secrets with `terraform_remote_state` data sources against the state account, rejected for
  now, not on merit but on scope: it changes the backend access model for six roots on the eve of a
  rebuild. Parked as OQ-055.
- Automate the refresh with a `gh secret set` step inside `_tf-root.yml`, rejected because it would give
  every apply job write access to repo Secrets, a materially worse blast radius than a manual step for a
  value that changes approximately never.

**Consequences:**
- Positive: the per-rebuild Secret work drops from eleven blind re-sets to one command plus one check, and
  the one command is on the value that can actually go wrong.
- Positive: the classification is written down, so the next operator does not have to re-derive which
  Secrets are safe to leave alone.
- Negative: the DERIVED classification is only as good as the naming scheme. If `org_prefix`,
  `environment`, the hub address spaces or the firewall subnet carve ever change, every DERIVED Secret
  goes stale at once and silently. That coupling is now explicit and must be honoured by any future
  naming change.
- Follow-ups: OQ-055 (should this coupling exist at all); update `DEPLOYMENT.md` sections 3.2 and 3.4 to
  state the contract instead of "carry forward the outputs".

### ADR-060: Full-estate rebuilds execute as SEQUENTIAL single-target dispatches with a per-root plan-scan gate; `deploy.yml target=all` is not an apply path

- **Date:** 2026-07-21
- **Section:** 10 (Pipeline & Tooling); extends ADR-025 (JIT state-SA firewall) and LESSON 30/31
- **Status:** Accepted (architect ruling, 2026-07-22 rebuild pre-clearance PC-1X)
- **Decision makers:** claude (architect)

**Context:**
`deploy.yml` offers `target = all`, whose `needs:` graph applies every root in dependency order and runs
the five landing-zone spokes concurrently. `DEPLOYMENT.md` section 4 presents it as the full-environment
shortcut. Live state contradicts that. The Terraform state storage account is `default_action = Deny`
with exactly ONE IP rule (an operator address; hosted-runner egress is a dynamic SNAT pool), and
`deploy.yml` sets `manage_runner_ip: ${{ inputs.target != 'all' }}`, so on `target=all` no job opens the
firewall and every root would 403 at `terraform init`. Beyond that, `target=all` applies ten roots with
no intervening plan-scan, runs five spokes that write concurrently to the SAME private DNS zone and the
same regional Network Watcher, cannot express the ADR-055 identity two-pass cleanly, and cascade-skips
the remaining graph on any single failure.

**Decision:**
A full-estate rebuild is executed as sequential single-target dispatches, one run in flight at a time,
`action=plan` then `action=apply` per root, with an architect-defined plan-scan bar applied between the
two. `target=all` is retained only for `action=plan` exploration and is documented as NOT an apply path.
The serial order pushes the long poles to the end so nothing waits behind them: management-groups,
management, security, connectivity, the four short spokes, bank-app-p1, then identity Pass 1 and Pass 2.

**Alternatives considered:**
- `target=all` with a manual state-SA firewall window (the teardown PD-1 pattern), rejected: it fixes only
  the init 403 and leaves the missing plan-scan gate, the concurrent-write hazard on shared private DNS
  zones, the identity two-pass mismatch and the cascade-skip recovery problem. For a run whose purpose is
  process validation, removing the process to save wall clock is the wrong trade.
- Add hosted-runner IP ranges to bootstrap `ip_allow_list`, rejected: GitHub hosted-runner egress is a
  large, changing set drawn from a SNAT pool, which is exactly the racy design ADR-025 replaced.
- Keep `manage_runner_ip` on for `target=all`, rejected: parallel jobs would flip the same account's
  `default_action` against each other and one job's restore-Deny would cut another mid-init (LESSON 31).

**Consequences:**
- Positive: every root gets a real plan-scan before its apply, which is the only gate that has ever caught
  a forced replacement or an unexpected destroy in this build (LESSON 26).
- Positive: a failure stops one root, not the graph, and the retry is a single dispatch.
- Negative: wall clock. A full rebuild is 6 to 9 hours of serialized runs, dominated by the APIM create in
  bank-app-p1 and the Entra Domain Services create in identity. The operator must plan the day around it.
- Negative: the dependency graph in `deploy.yml` stops being the thing that enforces order; a written
  runbook does. That runbook is now a required artefact of every rebuild.
- Follow-ups: OQ-057 (remove `target=all`, restrict it to plan, or fund a runner-egress solution);
  `deploy.yml` also declares `identity: needs: [management-groups]` while identity genuinely needs
  connectivity for its hub peering, a graph gap that serial ordering masks.

### ADR-059: A config-driven `import` block's `id` must be constructible from variables and literals ONLY, never from a managed resource's attributes - and recovery-only inputs must be armed per-run, not left standing (corrects the ADR-029 construction rule, unblocks the ADR-055 Pass 1)

- **Date:** 2026-07-21
- **Section:** 5 (Zero Trust / identity) / 10 (Pipeline & Tooling); CORRECTS a construction rule
  written into ADR-029 and reinstated by ADR-055 Part 1. Does not supersede either; both stand.
- **Status:** Accepted (architect ruling; found by an exploratory greenfield plan the user asked for,
  run 29851615122, not by a gate)
- **Decision makers:** claude (architect); implementation splits cloud-engineer (the `.tf` change) and
  user (the Secret value)

**Context:**
A greenfield `platform/identity` plan failed at plan time:

```
Error: Invalid import id argument
  The import block "id" argument depends on resource attributes that cannot be
  determined until apply, so Terraform cannot plan to import this resource.
```

Two compounding causes, both established from the run log rather than inferred.

**Cause 1 - the block was ACTIVE, not inert.** `TF_VAR_aadds_import_replica_set_id` rendered as `***`
in the job environment. GitHub masks a NON-EMPTY secret and renders an empty one as nothing, so the
`***` is positive evidence that the repo Secret `AADDS_IMPORT_REPLICA_SET_ID` still carries a stale
replica-set ID from the July recovery era. The `for_each` guard demonstrably passed, since evaluation
reached the `id` line at all. The history is its own lesson: the 2026-07-12 pre-clearance called the
Secret orphaned and said delete it; ADR-055 Part 1 correctly reinstated the WIRING; the 2026-07-21
refresh recorded the delete instruction as superseded. Nobody ever cleared the VALUE. Three documents
touched this Secret and none of them owned what was inside it.

**Cause 2 - the ID is structurally unplannable on greenfield.** The `id` interpolated
`azurerm_resource_group.identity_aadds[0].id`. On a clean tenant that resource group does not exist,
so `.id` is "known after apply", and Terraform cannot plan an import whose ID depends on an unknown.
This is not a stale-value artifact. It would fail identically tomorrow, because ADR-055 Pass 1 is
greenfield BY DEFINITION.

The second cause is the serious one, and it inverts the usual risk calculus: **the recovery path is
most likely to be needed on exactly the run where it is currently broken.** ADR-029 exists because the
AADDS create is a 1 to 3 hour operation that can time out with the domain built but unstated. If that
happens tomorrow, the recovery plan would fail too, under precisely the time pressure the mechanism
exists to relieve.

ADR-029's stated construction rule was: "The domain resource ID is built from the RG resource's `.id`
(so the subscription GUID comes from in-config state, never a committed literal)." The INTENT was
sound - keep GUIDs out of committed HCL. The MECHANISM chosen to achieve it was wrong, because a
resource attribute is unknown before that resource exists.

**Decision:**

1. **General rule (this is the part that generalises beyond AADDS):** a config-driven `import` block's
   `id` argument MUST be constructible from input variables, locals over variables, and string
   literals ONLY. It may NEVER reference an attribute of a resource Terraform manages. An import
   exists to adopt something that is NOT yet in state, so by definition it may run in a plan where the
   surrounding resources also do not exist. Any import ID that depends on a managed attribute is
   unplannable on greenfield and is a latent failure that `validate` cannot see.

2. **Fix the ID (option B), and it is urgent, not deferrable.** Replace the resource-attribute
   reference with a constructed prefix:
   `/subscriptions/${var.identity_subscription_id}/resourceGroups/rg-identity-aadds-${var.org_prefix}-${var.environment}`
   followed by the unchanged
   `/providers/Microsoft.AAD/domainServices/aadds-${var.org_prefix}-${var.environment}/initialReplicaSetId/${each.value}`.
   Both components are deterministic and already in config: the resource group name is a pure
   expression over `var.org_prefix` and `var.environment` (`identity-network.tf`), and
   `var.identity_subscription_id` is an existing declared variable fed from a repo Secret.
   **ADR-029's intent is fully preserved: still no GUID literal in committed HCL**, because the
   subscription arrives as a variable. Only the mechanism changes, from a resource attribute to a
   variable.
   The composite format is verified against the azurerm v4.71.0 import documentation for
   `azurerm_active_directory_domain_service` at the pinned tag:
   `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AAD/domainServices/<name>/initialReplicaSetId/<replica set GUID>`.
   Keep the name expression in lockstep with the resource, as the existing comment already requires.

3. **Clear the Secret's VALUE (option A), as well as fixing the ID.** The combined ruling is option C.
   The two fixes address different failures and neither substitutes for the other: clearing the value
   makes tomorrow's Pass 1 plan inert and correct; fixing the ID makes the block work on the day it is
   actually needed. Doing only A would leave a recovery path that fails when used. Doing only B would
   leave a greenfield run attempting to import a replica set that no longer exists.

4. **Recovery-only inputs are armed PER-RUN, not left standing (directional ruling, implemented as a
   follow-up).** A standing repo Secret is the wrong carrier for a one-shot recovery input: it is
   write-only and cannot be read back to diagnose (LESSON 32), it is masked so an operator cannot tell
   armed from unarmed by looking, it survives every teardown, branch and cycle, and it arms a code
   path with no dispatch-time signal whatsoever. The correct carrier is a `workflow_dispatch` input on
   the ADR-055 `enable_conditional_access_override` pattern: blank by default, visible in the run's own
   UI, typed deliberately by a human for one specific run, incapable of surviving to the next run, and
   fail-closed on a malformed value. **This is NOT implemented tonight**, deliberately: it changes
   `deploy.yml` and `_tf-root.yml`, which are the very workflows whose two-pass behaviour tomorrow's
   run exists to PROVE, and changing the subject of a proof on the eve of that proof is bad practice.
   Raised as OQ-054 for implementation after the identity root is green.

5. **Interim obligation while the Secret mechanism remains.** If recovery IS needed tomorrow, the
   Secret is set during the incident and **CLEARED immediately after the recovery apply lands**, as an
   explicit runbook step rather than an intention. This is the same one-shot discipline LESSON 52
   already imposes on the import block itself, extended to the input that arms it.

6. **How to verify a write-only Secret is empty, since PC-4G asserted it without a way to check.**
   Observe how it renders in a job log: GitHub prints `***` for a non-empty secret and nothing at all
   for an empty one. That artifact is the only available oracle, and it is what diagnosed this failure.
   Any future gate condition asserting a Secret is unset must cite this check rather than assuming.

**Consequences:**
- Positive: tomorrow's Pass 1 plans. The ADR-055 / OQ-022 token-durability proof run is unblocked with
  a one-line `.tf` change and one Secret edit, neither on the multi-hour path.
- Positive: the recovery path is repaired BEFORE the run most likely to need it, rather than
  discovered broken mid-incident.
- Positive: rule 1 is mechanical and greppable. Any future import block can be checked against it by
  reading one line, with no Azure knowledge required.
- Positive: rule 6 turns an unverifiable gate assertion into a checkable one.
- Negative / trade-offs: rule 2 duplicates the resource group NAME expression in a second place (the
  import ID), so the existing lockstep comment now covers two expressions rather than one. Accepted:
  the alternative is unplannable. A local for the RG name would collapse the duplication and is a
  reasonable implementer choice.
- Negative: rule 4 is stated but not yet implemented, so the standing-Secret hazard persists until
  OQ-054 lands. Bounded by rules 3 and 5.
- Follow-ups required: OQ-054 (dispatch input versus standing Secret for recovery-only inputs);
  `docs/preclearance/platform-identity.md` PC-1G and PC-4G updated for the corrected reality; the
  import block is still ONE-SHOT and must be removed once a recovery lands.
- **LESSON 52 AMENDED (2026-07-21, code review fast-follow).** The catalog ALREADY carried this defect
  class: LESSON 52's symptom text described a teardown destroy failing with "Invalid import id
  argument" because the ID interpolated a just-destroyed resource group. Same defect, mirror-image
  trigger (resource already gone versus resource not yet created), and ADR-029 reached for `.id`
  anyway - because the lesson described a SYMPTOM rather than naming the RULE. Decision 1 above is now
  folded into LESSON 52 as an explicit guardrail (a), so the next config-driven import in this repo or
  in any reused copy of the kit is checked against a one-line greppable rule instead of a war story.
  The "a plan tally is not evidence of success" trap is recorded there too.

---

### ADR-058: Teardown completion is certified by an INDEPENDENT qa-engineer pass, not by the workflow's own Phase 3 VERIFY - two gates, two actors, two identities, and neither may be collapsed into the other

- **Date:** 2026-07-21
- **Section:** 10 (Pipeline & Tooling) / teardown governance; extends ADR-054, symmetric with the
  deploy-side rule in LESSON 60
- **Status:** Accepted (user ruling 2026-07-21, recorded by architect; process ADR - binds the
  teardown lane the way LESSON 60 binds the deploy lane)
- **Decision makers:** user (the ruling), claude (architect, the mechanism and the boundary)

**Context:**
The 2026-07-20 teardown was declared GREEN on the strength of Phase 3 VERIFY alone (run 29765892057).
It was not green. Twelve subscription-scoped objects, eight armed Defender for Cloud pricing plans and
one registered resource provider survived, and every one of them was invisible to VERIFY. The reason is
structural, not a coding slip: VERIFY is a script that lives inside the same workflow that did the
work, and it audits essentially the same surface Phase 2 had just swept (resource groups by naming
pattern, management groups, Databricks workspaces, Key Vaults). A self-check written against the
sweeper's own model of the estate cannot discover a class of object the sweeper never modelled. That
is the definition of a blind spot, and no amount of hardening inside VERIFY removes it, because the
hardening is authored from the same model.

The deploy side already solved this. LESSON 60 says apply-success is not green, QA-verified is green,
and no root is marked complete until an independent qa-engineer pass validates live state against
intent. Teardown simply never inherited the rule. ADR-054's design principle 5 ("a green Phase 3 IS
the definition of E2E success") is, in hindsight, exactly the claim that let a half-teardown be
reported as complete.

There is also an identity asymmetry that makes the two checks genuinely non-redundant. VERIFY runs as
the SCOPED teardown OIDC service principal, whose management-group read grants are deleted along with
the subtree it just deleted (this is the whole reason the ADR-054 list-snapshot oracle exists, OQ-048).
Its view of the tenant is deliberately narrow and partly self-referential. A qa-engineer pass reads
live Azure as a differently-scoped identity that can see scopes the teardown SP structurally cannot.
Two identities, two vantage points, two independent chances to see a remnant.

**Decision:**
1. **Teardown is not complete, and must not be reported as green, until an independent qa-engineer
   pass confirms live state matches "torn down" against explicit, written acceptance criteria.** This
   is a rule of the teardown lane, not a step in one runbook. It applies to every teardown of this
   estate, in either mode, forever, and is inherited by any future wave without re-litigation.
2. **Phase 3 VERIFY is retained unchanged in role and is NOT downgraded.** It remains the in-workflow,
   fail-loud, instant truth-gate: it makes the workflow itself fail on a detectable remnant so a
   broken run never exits 0. It is the ACTOR's own conscience.
3. **The QA pass is structurally independent and is the AUDITOR.** Different actor (qa-engineer, not
   the workflow), different time (after the run completes, out of band), different identity (reads
   live Azure with a vantage the scoped teardown SP does not have), different source of truth (a
   written acceptance checklist derived from what the ESTATE deploys, not from what the sweeper
   sweeps).
4. **What each is allowed to conclude, stated so the two can never be collapsed again.**
   - Phase 3 VERIFY may conclude: "no remnant was found in the surface this workflow models." It may
     NEVER conclude "the estate is torn down." A green VERIFY is a necessary condition and an input to
     QA, never a verdict.
   - The qa-engineer pass may conclude: "the estate is torn down" or "it is not, here is the remnant
     list." Only this verdict clears a rebuild.
   - Neither may be derived from the other. If a future session proposes deleting the QA pass because
     "VERIFY already checks that", or folding the QA checklist into VERIFY so there is "one gate",
     that proposal is rejected by this ADR: it recreates the exact 2026-07-20 blind spot, because the
     checklist would then be authored and executed by the mechanism it is meant to audit.
5. **Ordering and failure semantics (no judgment call in the moment).**
   - The QA pass runs AFTER the teardown workflow run reaches a terminal state, and it runs whether
     the run was green or red. A red run still gets a QA pass, because a red run tells you something
     failed but not what survived.
   - QA finding a remnant does NOT reopen or edit the workflow run. It produces a remnant list
     classified per object, and the disposition is fixed by class: a remnant in a class the teardown
     ALREADY covers is a targeted idempotent re-dispatch of the same workflow; a remnant in a class the
     teardown does NOT cover is an architect gate item (a contract gap, which is what happened here)
     and goes to a design ruling plus a DevSecOps change before any re-dispatch.
   - **A QA verdict of anything other than PASS BLOCKS the rebuild.** No deploy dispatch of any root
     may start while a teardown QA pass is outstanding or failed. This is the teardown-side mirror of
     the pre-clearance gate on the deploy side.
6. **The QA verdict is recorded**, per root class, in the worklog, with the concrete queries run and
   their results, so the next teardown inherits an evidence trail rather than a claim.

**Consequences:**
- Positive: the failure mode that produced 21 latent apply failures cannot recur silently. The two
  gates fail in different ways for different reasons, which is what makes them worth having.
- Positive: symmetry with the deploy side. One rule ("the actor never certifies itself") now governs
  both directions, which is easier to hold than two different standards.
- Positive: the identity asymmetry is turned from a liability (OQ-048's 403-on-deleted-scope problem)
  into an asset - the auditor sees what the actor cannot.
- Negative / trade-offs: teardown gains a human-in-the-loop step and is no longer "one dispatch, walk
  away". Accepted deliberately: the walk-away property is exactly what produced a false green.
  Wall-clock cost is minutes against a rebuild that costs hours when it starts dirty.
- Negative: the acceptance checklist is now a maintained artifact. It must grow whenever a wave adds a
  new non-RG-scoped object class. That maintenance obligation is stated in ADR-057 decision 2 and is
  the honest price of the rule.
- Follow-ups required: the checklist lives in `docs/teardown-redesign.md` section 13.3 and is the
  qa-engineer's entry point. The FIRST teardown held to this gate is the 2026-07-21 re-run, and that
  run's QA pass is the artifact that clears the B0a rebuild to start.

---

### ADR-057: Teardown must return each subscription to the state a greenfield apply expects - subscription-scope completeness as a first-class teardown obligation, delivered by an explicit Phase 2 step 6 sweep, with terraform-destroy restored as a real (not nominal) primary path

- **Date:** 2026-07-21
- **Section:** 10 (Pipeline & Tooling) / teardown; AMENDS ADR-054 (adds a design principle and a Phase
  2 step; does not supersede it - the four-phase shape, token-durability model, force-deletion,
  auth-fail-loud rule and MG list-snapshot oracle all stand)
- **Status:** Accepted (architect ruling; user directed the fix-the-teardown path over any manual
  cleanup, 2026-07-21)
- **Decision makers:** claude (architect); user (ruled that cleanup must be CI/CD, never manual, even
  at the cost of losing a same-day rebuild start)

**Context:**
The 2026-07-21 B0a pre-clearance refresh found 21 deterministic, plan-invisible apply failures waiting
for the rebuild: 12 in `platform/management`, 9 in `platform/security`. Every one traces to a single
mechanical cause.

The estate's teardown has TWO modes. `mode=terraform` runs Phase 1, a per-root `terraform destroy`, so
every state-managed object is destroyed by the provider that owns it. `mode=az-sweep` skips Phase 1
entirely and relies on Phase 2, which finds things by RESOURCE GROUP NAMING PATTERN
(`RG_SWEEP_QUERY`), plus explicit passes for Databricks workspaces, Key Vaults and management groups.

Run history is decisive. The 2026-07-11 teardown ran `terraform destroy` and produced a clean
greenfield, which is exactly why the 2026-07-16 rebuild was pure adds. The 2026-07-19/20 teardown never
completed a single `terraform destroy`: the one attempt (run 29706565357) cascade-failed on `synthetic`
and `identity` and skipped every downstream root including `management` and `security`, and every
subsequent attempt (29712487341, 29749656053, 29753193590, 29765892057, 29773408578) ran
`mode=az-sweep`, where Phase 1 root jobs are SKIPPED by design. Job-level inspection of the green run
confirms it: `Phase 0 - DISARM` success, every Phase 1 root job `skipped`, `Phase 2 - AZ SWEEP`
success, `Phase 3 - VERIFY` success.

So nothing in the az sweep regressed. The az sweep never had a subscription-scope pass, and it never
claimed to. What changed is that the mode which does have subscription-scope coverage
(terraform-destroy, via the owning providers) stopped running, while ADR-054 still described it as
PRIMARY. The design's stated primary path was not the path that ran, and the fallback silently became
the only path. Everything that lives at subscription scope rather than inside a resource group was
therefore never deleted:

- 5 `azurerm_consumption_budget_subscription` budgets, one per subscription
- 5 cost exports created via azapi at `Microsoft.CostManagement/exports@2025-03-01`
- 1 `azurerm_cost_anomaly_alert` scheduled action in the management subscription
- 1 subscription-scope `azurerm_monitor_diagnostic_setting` in the security subscription
- 8 `azurerm_security_center_subscription_pricing` plans left at Standard in the security subscription
- 1 `azurerm_resource_provider_registration` (`Microsoft.CostManagementExports`) left Registered

and each collides at create because the corresponding provider resource carries a create-time
requires-import guard, verified in azurerm v4.71.0 source and in the azapi provider.

**Decision:**

1. **The governing principle (this is the part future waves inherit):**
   > **Teardown must return every subscription in the estate to the state a greenfield apply expects.
   > "Torn down" is defined by what the NEXT apply will attempt to create, not by what the last sweep
   > happened to look at.**
   >
   > Operationally: for every object a root creates, teardown owns its removal or its reset,
   > REGARDLESS of scope. Resource-group membership is an implementation detail of the sweeper, never
   > a boundary of the obligation. An object that lives at subscription, tenant or management-group
   > scope is exactly as in-scope as one inside a resource group. Where an object cannot be deleted
   > (a subscription-level setting such as a pricing tier, or a provider registration), teardown owns
   > returning it to its pre-apply VALUE.
   >
   > The test that settles any future "is this in scope" argument, in one line: **if leaving it makes
   > the next greenfield apply fail or drift, teardown owns it.**

2. **Coverage is a definition-of-done for every wave.** Any wave that introduces a non-RG-scoped
   object class must extend the Phase 2 step 6 class list and the section 13.3 QA checklist in the
   same change that introduces it. This is stated as a standing obligation so the gap cannot silently
   reopen the next time a root gains a subscription-scope resource.

3. **Mechanism: the design fork is resolved as BOTH, with explicit primacy.** Three options were
   considered:
   - **Option A - extend the az sweep with an explicit subscription-scope pass.** Enumerate and delete
     the four object classes, reset the pricing plans, unregister the provider.
   - **Option B - restore a real per-root `terraform destroy`** so state-managed objects are destroyed
     by their owner, and let the az sweep go back to being a genuine backstop.
   - **Option C - abandon terraform-destroy entirely** and declare az-sweep the only supported path,
     making the sweep exhaustive.

   **Ruling: Option A is implemented NOW as the mechanism, and Option B is restored as policy, with
   Option C explicitly rejected.**

   Reasoning:
   - **Option A alone is insufficient as a philosophy but necessary as a mechanism.** The estate's
     ONLY green teardowns since the redesign have been `mode=az-sweep`, because ADR-054 was built for
     a world where state is empty, partial, or unreachable (F4) and where a long delete outlives an
     OIDC assertion. That reliability is the thing we cannot regress. A teardown that only works when
     state is intact is not a teardown; it is a happy path. So the az sweep must be able to finish the
     job unaided, which means it must cover subscription scope.
   - **Option B alone is insufficient and is what just failed.** `terraform destroy` covers
     subscription scope for free, because the owning provider deletes what it created. But it is
     precisely the path that cascade-failed on an empty `synthetic` root and then was abandoned for
     five consecutive runs. Relying on it is relying on the mode that does not run.
   - **Option C is rejected** because it throws away the only mechanism that has state fidelity. A
     naming-pattern sweep can never know about an object whose name nobody predicted; a provider
     destroying its own state can. Deleting Phase 1 would also strand any future populated root and
     would make every new object class a silent gap until someone notices, which is exactly the defect
     being fixed.
   - Therefore: az-sweep becomes genuinely complete (Option A), AND `mode=terraform` is restored to
     real primary status by policy (Option B) so the two mechanisms cross-check each other. Phase 2
     already runs in BOTH modes as a remnant-catch pass, so step 6 executes on the terraform path too
     and is idempotent there (everything already deleted reads as absent and no-ops).

4. **Scope ruling per class** (full detail and exact API versions in `docs/teardown-redesign.md`
   section 12.3):
   - The 12 subscription-scoped objects: **IN**, Phase 2 new step 6, sub-step 6a.
   - Defender for Cloud pricing reset to Free: **IN**, Phase 2 step 6, sub-step 6b, with a hard
     allow-list and an explicit never-touch list (see decision 5).
   - `Microsoft.CostManagementExports` unregistration: **IN**, Phase 2 step 6, sub-step 6c, ordered
     strictly AFTER 6a so the provider has no dependent resources when it is unregistered.
   - Placement is step 6, i.e. AFTER the RG sweep and Key Vault steps and BEFORE the reconcile wait,
     so an RG-scoped cascade cannot race a subscription-scope delete, and so step 6's own work is
     covered by the existing bounded reconcile and by Phase 3.

5. **The pricing reset carries a hard safety rule.** Teardown resets to Free ONLY the plans this
   estate's `platform/security` root actually configures, read from an explicit allow-list that
   mirrors the config. It must NEVER touch a plan the estate does not configure, and must NEVER
   attempt to re-arm anything. The reason is LESSON 41 asymmetry: setting a plan to Free is trivially
   easy and may be permanently irreversible, because Microsoft blocks NEW enablement of deprecated
   plans. A blanket "reset everything to Free" would eventually disarm a plan that can never be turned
   back on. The residual risk (a currently-current plan being deprecated in the window between a
   teardown and the next rebuild) is real and is raised as OQ-050 rather than hidden.

6. **The RP unregistration is accepted as a teardown obligation only while the resource is managed
   in-root.** LESSON 54 says do not manage provider registration in the same root as the resources
   that need it. If that durable fix lands (OQ-049), sub-step 6c is deleted rather than maintained.
   Until then, teardown owns returning the registration to its pre-apply state, because the deploy
   root will otherwise fail on it every single cycle.

7. **Everything in ADR-054 that is not named here is unchanged**: the four-phase shape, `!cancelled()`
   ordering, the guard's mode/target rejection, `remove_mg_hierarchy` defaulting false, the
   `--no-wait` plus single bounded reconcile token-durability model, `az_relogin`, the `az_run`
   stdout/stderr separation, `is_auth_error` (NOT loosened), the MG list-snapshot oracle, Databricks
   `--force-deletion`, and the auth-fail-loud rule. Step 6 inherits all of them; it does not get its
   own error conventions.

**Consequences:**
- Positive: the next greenfield apply meets a real greenfield. The 21 known failures go to zero without
  a single manual `az` command, which is the user's standing requirement.
- Positive: the fix is additive. No existing step changes behaviour, so the proven-green E2E path is
  not disturbed; step 6 is new code on a new surface with its own fail-loud handling.
- Positive: naming the principle in terms of "what the next apply expects" makes future coverage
  decisions mechanical instead of a debate per object type.
- Negative / trade-offs: the sweep now has an object-class list that must be maintained per wave
  (decision 2). A naming-pattern sweep is self-maintaining; an explicit class list is not. Accepted,
  because the alternative is the silent gap this ADR exists to close, and decision 2 plus the ADR-058
  QA checklist give it two places where the omission surfaces.
- Negative: teardown now performs a WRITE (the pricing reset) rather than only deletes, which is a
  small widening of blast radius. Bounded by the allow-list in decision 5 and by the fact that the
  write only ever moves a plan toward the cheaper, less-privileged state.
- Negative: restoring `mode=terraform` to real primary status means the F1 class (an empty root
  failing and cascading) must stay fixed. It is - the `_tf-root.yml` state-empty no-op pre-step is the
  ADR-054 fix - but it is now load-bearing again rather than academic.
- Follow-ups required: OQ-049 (durable LESSON 54 fix for the in-root provider registration), OQ-050
  (the irreversible-disarm risk in the pricing reset), OQ-051 (the ADR-041 tenant-root grants are
  still attached and un-revoked). The implementation contract for DevSecOps is
  `docs/teardown-redesign.md` section 12; the QA checklist that certifies the result is section 13.3
  under ADR-058.

---

### ADR-056: Branch topology and lifecycle - feature -> integration (banking) -> main, one workstream per branch, delete-on-merge after clearance, and MANDATORY verification of branch state against origin/* refs (never trust local pointers)

- **Date:** 2026-07-20
- **Section:** 10 (Pipeline & Tooling) / cross-cutting process
- **Status:** Accepted (architect; process ADR - binds every role)
- **Decision makers:** user (repeated stale-local-ref confusion prompted it), claude (architect)

**Context:**

The build runs across three long-lived doc/code lines - short-lived `feature/*` branches, the `banking`
integration line (the real build: B1-B9 + O&M phase 1 + security + teardown redesign, merged via PR #39),
and `main` (now fully current via PR #31; `main..banking` is empty). During the ADR-055 pre-clearance a
prior agent was repeatedly misled because LOCAL branch pointers were stale and did not reflect the remote:
local refs suggested reconciliations were outstanding that were in fact already merged. The working state had
to be cleaned up and re-verified against the remote before any real work could proceed. This is a recurring,
expensive failure mode (agents re-derive an incorrect estate/branch picture from stale local git and then
act on it), and it directly threatens the user's hard bar (4 straight deploy failures moves the project off
Claude Code) because a wrong branch picture can send an apply from the wrong code.

Nothing in the ADR log had codified the branch flow or the "verify against origin/*" rule, so each agent
improvised. This ADR makes the topology and the verification discipline explicit.

**Decision:**

1. **Branch flow is `feature/* -> banking (integration) -> main`.** Feature work is done on a dedicated
   `feature/<workstream>` branch, flows into `banking` for integration, and `banking` reconciles to `main`.
   Never propose a commit straight to `main` (memory: dev-and-feature-branch-strategy).
2. **One workstream per branch.** A `feature/*` branch carries exactly one coherent workstream (e.g.
   `feature/adr-055-oidc-durability`, `feature/teardown-redesign`). Do not pile unrelated changes onto an
   in-flight feature branch.
3. **Delete-on-merge AFTER clearance.** A `feature/*` branch is deleted once it has merged and the merge is
   cleared (reviewer approve + any pre-clearance/QA gate its change requires). Deleting before clearance
   loses the recovery point; keeping stale merged branches around is what breeds the local-pointer confusion.
4. **MANDATORY: verify branch/estate state against `origin/*` refs, NEVER local pointers.** Before any agent
   reasons about "what is on branch X" or "is Y merged", it MUST consult the REMOTE-tracking refs
   (`git fetch` then read `origin/<branch>`, `git log origin/main..origin/banking`, `gh` for PR state) and
   treat local branch pointers as UNTRUSTED until reconciled. A local pointer that disagrees with `origin/*`
   is stale by default. When a task hand-off supplies remote-verified ground-truth facts (tip commits,
   which line contains what), those SUPERSEDE anything the agent infers from local git.
5. **Corollary for deploys:** because an apply runs the code on the dispatched ref, confirming the ref
   against `origin/*` is part of the pre-clearance gate - a plan/apply must never be dispatched from a branch
   whose remote state the agent has not verified.

**Alternatives considered:**
- Trunk-based single-branch flow - rejected: the build's role hand-offs (architect -> engineer/devsecops ->
  reviewer) and batched per-iteration reviews need an integration line distinct from `main`, and feature
  isolation is what lets a workstream be reviewed and cleared as a unit.
- Rely on local branch hygiene / agent memory of git state - rejected: this is the exact failure this ADR
  exists to stop. Local pointers drift; only `origin/*` is authoritative.
- Long-lived feature branches - rejected: they accumulate cross-workstream drift and are the classic source
  of stale-ref confusion; one workstream per branch, delete-on-merge keeps the set small and legible.

**Consequences:**
- Positive: a single documented topology every role follows; the stale-local-ref failure mode is named and
  guarded (verify against `origin/*`); deploys cannot be dispatched from an unverified ref; the branch set
  stays small (delete-on-merge).
- Negative / trade-offs: an explicit `git fetch` + `origin/*` check is now a required step before branch/
  merge reasoning (small, cheap); delete-on-merge means a merged branch is gone once cleared (the merge
  commit + `main`/`banking` history are the recovery point, which is the intent).
- Follow-ups required: none code-side (process ADR). It binds the architect pre-clearance gate (point 5) and
  every agent's branch reasoning (point 4). Consistent with the propose-commits-not-run rule (ADR / memory:
  propose-commits-dont-run) - this ADR does not change WHO commits, only how branch state is established.

### ADR-055: Durable greenfield fix for OIDC token expiry on the identity root's 1-3h AADDS create + trailing Graph ops (resolves OQ-022) - refresh-enabled provider OIDC (explicit ARM_OIDC_REQUEST_URL/TOKEN export) PLUS decouple the multi-hour create from the azuread Graph phase via a single umbrella enable-flag two-pass, NOT a root split and NOT a stored long-lived credential

- **Date:** 2026-07-20
- **Section:** 8 (Identity / Entra DS) / 5 (azuread Conditional Access) / 10 (Pipeline & Tooling, OIDC auth)
- **Status:** Accepted (architect design; DevSecOps + cloud-engineer implement; code-reviewer gates). Resolves OQ-022. Extends ADR-029 Part C (which deferred the durable greenfield fix). Does NOT supersede ADR-029 (its NSG fix + import recovery remain in force).
- **Decision makers:** user (requested the greenfield rebuild follow-up), claude (architect)

**Context:**

`platform/identity` co-locates, in ONE `terraform apply`, a 1-3h `azurerm_active_directory_domain_service`
create-wait (`domain-services.tf:93`, create-only wait for both DCs) with azuread Microsoft-Graph writes
(named location + CA-001..CA-008 in `main.tf`). On a from-scratch greenfield deploy the long create runs
BEFORE the Graph ops. In run 29055619749 (2026-07-10) the trailing Graph ops failed
`AADSTS700024: Client assertion is not within its valid time range`, the assertion window being the one
minted at job start (~3h earlier). ADR-029 Part C closed this for the CURRENT POC by importing the
built-once domain so every future apply is short, and PARKED the durable greenfield fix as OQ-022. The user
has now requested the greenfield rebuild, so the durable fix must land.

**Mechanism (verified 2026-07-20, not assumed - anti-hallucination):**
- Auth context is NATIVE provider OIDC (`ARM_USE_OIDC=true` + `ARM_CLIENT_ID`, `_tf-root.yml:102-103`), NOT
  az-CLI. The teardown's `az_relogin` shell helper (ADR-054) therefore does NOT transfer - it re-logs-in the
  az CLI, not the Terraform provider's in-process token source.
- Both providers authenticate through go-azure-sdk's GitHub OIDC authorizer. It exchanges a GitHub-issued
  id-token (the client assertion, ~5 min validity) for an Azure/Graph access token (~60-75 min). Verified
  against the go-azure-sdk `sdk/auth/github_oidc_authorizer.go` source: the CachedAuthorizer caches the
  ACCESS TOKEN, and on expiry re-invokes `githubAssertion()`, which issues a FRESH HTTP GET to the id-token
  request URL and mints a NEW assertion, then re-exchanges. So a correctly-configured recent provider
  re-mints per access-token acquisition; it does NOT ride one ~5 min assertion for hours.
- The request URL + bearer token resolve from `ARM_OIDC_REQUEST_URL` / `ARM_OIDC_REQUEST_TOKEN`, with a
  documented GitHub-Actions fallback to the runtime-injected `ACTIONS_ID_TOKEN_REQUEST_URL` /
  `ACTIONS_ID_TOKEN_REQUEST_TOKEN` (present whenever `permissions: id-token: write` is set - it is,
  `_tf-root.yml:92`). Confirmed against the hashicorp/azurerm and hashicorp/azuread `service_principal_oidc`
  provider guides.
- Smoking gun in run 29055619749: azurerm POLLED the AADDS create for 2h11m with NO auth failure (it failed
  on a create-wait TIMEOUT, not AADSTS700024) - proof that azurerm's authorizer DID re-mint across 2h+ in
  this exact workflow and env. azuread's tail Graph ops at +3h failed AADSTS700024 reporting the ORIGINAL
  (job-start) assertion window - proof that the azuread path reused a STALE cached assertion instead of
  re-minting. The divergence in the SAME run/env is the key finding: azuread acquired its Graph token once
  at job start, sat idle ~3h while azurerm did the long create, and on refresh did not fetch a fresh
  id-token (a version-gated / idle-gap behaviour of the resolved azuread build; the lock now resolves azuread
  to 3.9.0 and azurerm to 4.71.0, both current, both reading the OIDC request inputs). Conclusion: the
  exposure is (i) reliance on version-gated auto-detection of the request inputs, and (ii) a multi-hour idle
  gap between one provider's job-start token and the other provider's tail-end first/next Graph call.

**Decision:**

Adopt a two-part coordinated fix. Part 1 is the STRUCTURAL GUARANTEE (removes the failure mode regardless of
provider refresh edge cases); Part 2 is refresh HYGIENE that makes token refresh reliable for Part 1's short
second pass and for every OTHER long apply in the estate. Both land together.

**Part 1 - decouple the multi-hour create from the Graph phase via a single umbrella enable-flag, run
greenfield as a documented TWO-PASS sequence (identity root only). NO root split.**
- Add ONE new umbrella variable to `platform/identity`, `enable_conditional_access` (bool, default `true`),
  and gate EVERY azuread Graph WRITE on it: `azuread_named_location.approved_countries`,
  `time_sleep.wait_named_location`, and ALL EIGHT CA policies CA-001..CA-008 (`require_mfa_admins`,
  `block_legacy_auth`, `require_compliant_device_portal`, `phishing_resistant_mfa_pim`, `signin_frequency_admins`,
  `block_high_user_risk`, `mfa_signin_risk`, and the already-gated `geo_block`, which becomes
  `enable_conditional_access && enable_geo_block_ca_policy`). Gating only the first five would leave three
  azuread Graph writes (`signin_frequency_admins`, `block_high_user_risk`, `mfa_signin_risk`) running at the
  tail of Pass 1 and defeat the azurerm-only guarantee, so all eight are gated. This reuses the codebase's established
  `enable_*` flag pattern (ADR-030/031/032/043) - a `count = var.enable_conditional_access ? 1 : 0` on each,
  with the outputs made `one(...)`-safe (mirrors the existing geo_block output).
- Greenfield deploy order (documented in DEPLOYMENT.md / the deploy runbook, NOT a code default change - the
  flag stays default `true` so steady-state and every non-greenfield apply are unchanged):
  - Pass 1: apply `platform/identity` with `enable_conditional_access = false` (greenfield tfvars override).
    This creates the identity VNet/NSG + AADDS managed domain and absorbs the 1-3h create-wait as an
    azurerm-ONLY apply. That path is proven token-safe (azurerm re-minted across 2h11m in run 29055619749).
    No Graph write runs at the tail, so no stale-assertion exposure exists in this long pass.
  - Pass 1 recovery (only if the create-wait times out, e.g. slow DC2 / AADDS104): reinstate ADR-029's
    config-driven `import {}` block for `azurerm_active_directory_domain_service.this[0]` (composite ID
    `<domain resource ID>/initialReplicaSetId/<replica set GUID>`, GUID supplied by the operator per ADR-029)
    and re-apply, still with `enable_conditional_access = false`. This is the canonical greenfield recovery,
    not a new mechanism.
  - Pass 2: apply `platform/identity` with `enable_conditional_access = true` (the default). The domain
    already exists, so azurerm does a Read (seconds) and the azuread Graph writes run early in a SHORT apply
    under a fresh, just-minted token. Steady-state and CI re-applies are exactly this short single pass.
- There are NO azuread data sources in the root: the admin role-template IDs (`local.admin_role_template_ids`,
  `main.tf:30`) and the management-app IDs (`local.azure_management_app_ids`, `main.tf:60`) are hardcoded
  literal constants, not `data "azuread_*"` lookups. So the only azuread objects the root touches are the
  eight CA-policy writes + the named location gated above, and nothing azuread runs unauthenticated at the
  multi-hour tail once those are gated off in Pass 1.

**Part 2 - refresh-enabled provider OIDC (all roots, `_tf-root.yml`).**
- Explicitly export `ARM_OIDC_REQUEST_URL` and `ARM_OIDC_REQUEST_TOKEN` into the job environment, sourced
  from the runtime `ACTIONS_ID_TOKEN_REQUEST_URL` / `ACTIONS_ID_TOKEN_REQUEST_TOKEN`. This MUST be done in a
  `run:` step that writes to `$GITHUB_ENV` (the job-level `env:` map does NOT shell-expand runtime vars, so
  `ARM_OIDC_REQUEST_URL: ${ACTIONS_ID_TOKEN_REQUEST_URL}` in `env:` would be a literal, not the value). This
  removes the dependency on version-gated auto-detection of the request inputs: with them set explicitly,
  every supported provider version re-mints a fresh assertion on access-token refresh.
- Provider floors (already satisfied by the lock files, restated so a `-upgrade` cannot regress below them):
  azurerm `4.71.0` (pinned `~> 4.71.0`), azuread `3.9.0` (pinned `~> 3.0`). Both current, both read the OIDC
  request inputs and re-mint per acquisition.
- `permissions: id-token: write` is already present (`_tf-root.yml:92`) - required and confirmed.

**Alternatives considered:**
- Part-1 alternative "full root SPLIT into a Phase-1 (network+AADDS) root and a Phase-2 (azuread CA) root"
  (OQ-022 Option A) - REJECTED: achieves the same ARM-vs-Graph lifecycle separation as the flag two-pass but
  at far higher cost (a new composition root, state migration, cross-root data passing for the domain/subnet,
  provider re-wiring, an extra pipeline stage). ADR-029 already called this speculative for a POC. The
  umbrella flag delivers the identical guarantee inside the existing root.
- Part-2-alone "just export the request inputs / bump providers and keep the single 3h apply with tail Graph
  ops" (OQ-022 Option B, mechanism only) - REJECTED AS THE SOLE FIX. It is very likely sufficient (the
  mechanism verification says a current provider with explicit request inputs re-mints across the idle gap),
  but its correctness across a 3h idle gap is UNPROVABLE without a live long-apply, and the user's hard bar
  (4 straight failures moves the project off Claude Code) plus the cost of a burned 3h greenfield apply make
  it unacceptable to stake the first greenfield run on an unproven refresh across a multi-hour idle gap. Part
  2 is therefore retained as mandatory hygiene, but Part 1 (azurerm-only long pole, proven token-safe) is the
  guarantee.
- CI job-level mid-apply re-auth for the azuread phase (OQ-022 Option B, the `az_relogin`-style variant) -
  REJECTED: a single `terraform apply` process holds its provider token source in-process; an external
  `az login` between phases does not refresh the Terraform provider's authorizer, and there is no supported
  hook to re-auth mid-apply. `az_relogin` solves the az-CLI context (teardown), not the provider context.
- Longer-lived credential for the long apply only - client certificate or client secret (OQ-022 Option c) -
  REJECTED: reintroduces a stored long-lived secret, directly regressing the keyless federated-OIDC posture
  (ADR-004/005/021), and is unnecessary once refresh works (Part 2) and the long pole is azurerm-only (Part
  1). Not accepted even scoped to one apply.
- Self-hosted runner with a persistent identity - OUT OF BOUNDS (GitHub-hosted runners per ADR-005 / OQ-007).

**Scope - which deploy steps can exceed the ~60-75 min token window (so the fix covers the real set, not just
AADDS):**
- `platform/identity` / AADDS: 1-3h create-wait co-located with Graph writes - the PRIMARY case; gets BOTH
  Part 1 and Part 2.
- `platform/connectivity` WITH the paid gateways enabled (VPN Gateway / ExpressRoute Gateway) under
  production restoration (ADR-049; deferred/flag-gated off in the POC per ADR-042): gateway creates run
  30-45+ min EACH, so a two-hub apply can approach or exceed the token window. Covered by Part 2 (refresh
  export); no structural change needed because there are no trailing Graph ops in connectivity.
- APIM (ADR-047, ~29 min observed for Developer stv2 internal; a Premium multi-region unit would be longer),
  AKS private cluster, Databricks workspace, Fabric capacity - all currently under the token window (<~20-30
  min). Covered for free by the Part 2 export; no structural change.
- Net: Part 2 is the universal safety net for ALL roots at zero incremental cost; Part 1 is identity-only
  because AADDS is the only multi-hour CREATE co-located with Graph WRITES.

**Consequences:**
- Positive: the greenfield long pole becomes an azurerm-only apply on a proven-refreshing token; the Graph
  phase always runs in a short apply; keyless OIDC posture preserved (no stored secret); every long apply
  across the estate gains reliable token refresh from one workflow change; reuses two already-built
  mechanisms (the `enable_*` flag pattern and the ADR-029 import), so the change surface is small and
  no new root/state migration is introduced.
- Negative / trade-offs: greenfield identity is now a documented two-pass (one extra apply invocation on a
  clean-room rebuild only - steady-state stays single-pass); one new variable + `count` gating on nine azuread
  resources (a named location + all eight CA policies CA-001..CA-008); a `$GITHUB_ENV` export step added to
  `_tf-root.yml` that runs on every root (harmless, ~no cost).
- Follow-ups required:
  - MANDATORY pre-clearance (standing architect-owned gate) before any deploy retry of `platform/identity`,
    with a fresh resource-type lifecycle audit (AADDS `azurerm_active_directory_domain_service` still
    current, not retired) and the live policy matrix at the Identity MG ancestors (the ADR-028 Deny-Public-IP
    exemption must be live before the create).
  - The REAL proof of this fix is a live greenfield long-apply, which only the requested rebuild exercises.
    QA/architect must confirm on that run: Pass 1 completes (or times out and imports) with azurerm token
    refresh and NO AADSTS700024, and Pass 2's Graph writes succeed under a fresh token.
  - Plan-scan before each apply (LESSON 26): the AADDS resource carries an Azure-assigned ForceNew attribute
    (`domain_configuration_type`, pinned `FullySynced` per ADR-029) - a plan showing `-/+ replace` on the
    domain is a STOP.

### ADR-054: Reliable end-to-end teardown - disarm-policy-first, no-empty-root-cascade, two-mode (terraform primary + az sweep fallback), OIDC token durability, Databricks force-deletion, auth-fail-loud, MG list-snapshot oracle, full MG-hierarchy teardown, loud verification [GREEN and proven E2E, attempt 5 run 29765892057; consolidated 2026-07-20 - the reactive-patch amendment chain is folded into the coherent mechanism below, with a compact changelog; the interim per-MG `show` oracle is superseded by the `az account management-group list` snapshot oracle]

- **Date:** 2026-07-19
- **Section:** Section 10 (pipeline) / teardown; supersedes the teardown ordering/gating of the
  original teardown.yml (ADR-019 era). Full fix-spec: docs/teardown-redesign.md
- **Status:** Accepted (user hard requirement: zero manual deletion; architect design; DevSecOps
  implements)
- **Decision makers:** user (requirement), claude (architect)

**Context:**
Today's teardown failed E2E and forced manual deletion - the user set a hard requirement that
teardown be a reliable zero-manual CI/CD process. Four root causes: (F1) `needs: [..., synthetic]`
+ `if: !failure()` let the synthetic root's failed destroy (empty/absent state) cascade-skip every
real root - the workflow destroyed nothing (`synthetic` IS a real root - `synthetic/*.tf` define
real resources gated behind `var.enable_synthetic_workload`, currently false - the cascade was
about the destroy failing against empty state, not about the root not existing); (F2)
terraform-destroy alone cannot finish the Databricks managed RG (RP deny-assignment - must delete
the workspace, and per the consolidated mechanism below that delete now requires `--force-deletion`
to cascade the managed RG), APIM/AKS slow deletes, KV purge-protection; (F3) MG-scope DINE policy
assignments kept RE-REMEDIATING (recreated rg-amba-monitoring-001) during resource deletion; (F4)
state was emptied for a fresh redeploy, so terraform-destroy can no longer finish the current
half-destroy - no az fallback existed.

**Decision:**
1. **Disarm the policy layer FIRST** (Phase 0, az, always): delete every MG-scope policy assignment
   (globaris root + all descendants; base ALZ + the 223 AMBA) before/independent of resource
   deletion, so DINE stops re-remediating. The single most important reordering (fixes F3).
2. **No empty/undeployed root may cascade** (fixes F1): `needs` for ordering only; every root
   `if:` uses `!cancelled()` NOT `!failure()`; `_tf-root.yml` destroy gets a pre-step that no-ops
   (exit 0) when `terraform state list` is empty/absent. `synthetic` stays in the Phase-1 graph,
   hardened with this same fix - NOT deleted (corrected 2026-07-19, reviewer BLOCK: deleting a
   real root's job would leave a future populated `synthetic` root's Terraform state undestroyed
   and drifted; the resilience fix, not root removal, is what makes an empty root safe).
3. **Two modes, one workflow** (fixes F4): a `mode` input - `terraform` (state intact, primary
   reverse-order destroy) and `az-sweep` (state gone, az fallback that deletes orphaned/re-
   remediated RGs, Databricks-workspace-cascade, KV soft-delete, MG-hierarchy removal). DISARM
   (Phase 0) and VERIFY (Phase 3) run in both modes, target=all only (a single-root target skips
   the whole-estate phases); `mode=az-sweep` with a non-`all` target is rejected by the `guard` job
   before login (it would otherwise run nothing and report green).
4. **F2 handling:** Databricks = delete the WORKSPACE (never the managed RG directly) WITH
   `--force-deletion` (see the consolidated mechanism below - a plain workspace delete no longer
   self-cleans the managed RG); APIM/KV = provider purge features (APIM added at B4) + 360-min
   ceiling; KV purge-protected = soft-delete + redeploy recover (recover_soft_deleted_key_vaults).
5. **Full MG-hierarchy teardown for the Wednesday redeploy, dispatched explicitly**
   (`remove_mg_hierarchy` input, default **false** - a checked-in default that deletes the whole MG
   tree is too much blast radius; the redeploy runbook passes `true` explicitly at dispatch): subs
   are reused, and a fresh avm-ptn-alz apply against EMPTY state collides on a live hierarchy; so
   the az sweep moves subs to the tenant root and deletes the MGs bottom-up as the LAST step,
   giving the fresh apply a clean slate. Rejected: terraform-import (heavy/fragile for a full ALZ
   tree) and idempotent-reconcile (alz provider does not adopt pre-existing MGs into empty state).
6. **Loud verification** (Phase 3, always, last): the run FAILS on any remnant (policy assignments,
   workload/orphaned RGs, Databricks managed RGs, live MG tree). A green Phase 3 IS "teardown
   succeeded E2E"; no manual step for the default (non-bootstrap) scope.

**Alternatives considered:**
- Keep `!failure()` gating - rejected: it is the exact F1 cascade-skip bug.
- terraform-destroy only - rejected: cannot finish F2 resources or the F4 state-gone case, and does
  not disarm F3 remediation before the resource race.
- Leave the MG hierarchy for redeploy - rejected: empty-state fresh apply collides on live MGs.
- Manual runbook for the stuck parts - rejected: violates the zero-manual requirement (the whole
  point).

**Consequences:**
- Positive: a single dispatch tears down E2E, state-intact or state-gone, with zero manual steps;
  remediation can no longer resurrect resources mid-sweep; Wednesday gets a clean redeploy slate;
  verification prevents silent half-teardowns.
- Negative / trade-offs: the disarm-first + full-MG-teardown makes the workflow more complex (4
  phases); purge-protected KVs still require a redeploy-side recover (documented, not manual
  deletion); the az-sweep uses naming-pattern RG matching (must stay in sync with the estate's RG
  naming - a maintenance coupling).
- Follow-ups: DevSecOps implements docs/teardown-redesign.md (the 4-phase workflow + `_tf-root.yml`
  resilience pre-step + the az disarm/sweep/verify scripts); use it immediately in `az-sweep` mode
  to finish today's half-destroy; keep the RG-naming patterns in sync with the estate; the
  include_bootstrap scorched-earth path stays manual by design (SP cannot self-delete its OIDC app).
- Correction (2026-07-19, reviewer BLOCK on the DevSecOps implementation, applied before merge):
  the initial implementation deleted the `synthetic` job entirely and set `remove_mg_hierarchy`
  default to `true`, both since corrected in this ADR text and in docs/teardown-redesign.md -
  `synthetic` is restored as a hardened Phase-1 job (point 2 above) and `remove_mg_hierarchy`
  defaults to `false` (point 5 above). The `guard` az-sweep/target=all rejection (point 3) was
  also added at this correction pass.

**Current mechanism (consolidated 2026-07-20 - GREEN and proven E2E, attempt 5 run 29765892057).**

The four-phase shape above is unchanged. Three live-only defects were then fixed, each a distinct
real root cause; the fixes are proven and the code is the source of truth. They are described here as
one coherent mechanism (the dated, run-numbered history is in the changelog at the end of this ADR
and in docs/teardown-redesign.md Appendix A). Full design: docs/teardown-redesign.md sections 4 to 7
and 10.

7. **Token durability = a short submission pass plus an on-demand re-login primitive; never az's own
   refresh.** The `azure/login` GitHub OIDC federated assertion is valid only inside GitHub's ~5
   minute window; once consumed, az cannot refresh the derived ~1h access token, so any single step
   that outlives it dies AADSTS700024. Mechanism: (a) Phase 2 fires EVERY delete with `--no-wait`
   (submission only, no in-session long-poll on the token that submitted it); (b) a shared
   `az_relogin` helper mints a BRAND-NEW GitHub OIDC assertion on demand (fresh id-token from
   `$ACTIONS_ID_TOKEN_REQUEST_URL`, audience `api://AzureADTokenExchange`, then `az login
   --service-principal --federated-token`) - GitHub serves fresh assertions for the whole job; (c)
   the single bounded reconcile wait calls `az_relogin` at the START of every iteration, ceiling 30
   min, so a poll can never outlive its token. A failed re-login is FAIL LOUD. Rejected: `azure/login`
   at job start alone (does not survive a >token-lifetime step); az token refresh (impossible with a
   consumed one-time assertion); putting the wait inside VERIFY (muddies the auditor's instant-truth
   contract); an in-workflow auto-retry loop (masks a stuck delete).

8. **Async-delete / immediate-verify reconciliation: the WAIT lives in Phase 2, VERIFY stays an
   instant truth-gate.** After the submission pass, Phase 2 runs ONE relogin-bounded reconcile loop
   that waits for exactly the RGs it submitted plus the Databricks managed RGs to report gone; Phase 3
   VERIFY then asserts remnants=0 with no wait. Idempotent operator RE-DISPATCH is the safety net for
   the pathological over-ceiling straggler; the workflow does NOT auto-retry. MG re-parent + bottom-up
   delete are fast control-plane ops and stay synchronous in the submission pass (no reconcile wait).

9. **Auth-error-must-fail-loud, across all three scripts.** No teardown step may treat an auth / token
   / transport failure as "resource absent / already gone". Every list/existence call DISTINGUISHES a
   genuine NotFound (idempotent no-op) from an auth or transport error (fail loud, non-zero,
   `::error::`); a failed list is explicitly distinct from a successful zero-row list. Two data traps
   are closed so this is sound: (T1) the shared `az_run` helper keeps stdout (the data channel) and
   stderr fully separate, so a clean-exit WARNING banner can never inject a bogus row into a `mapfile`
   or scalar compare; (T2) the shared `is_auth_error` classifier (matching `AADSTS`, "valid time
   range", "not within", `AuthenticationFailed`, `ExpiredAuthenticationToken`, token / credential /
   401 / 403 / `az login`) replaces the old `2>/dev/null || true` swallow. VERIFY especially - a dead
   token there would otherwise falsely certify "clean". `is_auth_error` is NOT loosened.

10. **Databricks managed-RG cascade requires `--force-deletion`.** Per the current MS "Delete a
    workspace" doc (ms.date 2026-07-08) a plain workspace delete RETAINS the managed RG (plus its DBFS
    storage account and access connector; a UC-enabled workspace's managed RG is converted to a regular
    RG and kept). So the workspace delete passes `--force-deletion` to cascade the managed RG;
    `--force-deletion` and `--no-wait` combine (proven in run 29749656053, which cleared the managed
    RG). Never `az group delete` the managed RG directly (RP deny-assignment); the reconcile step waits
    for the cascade and VERIFY 3 confirms.

11. **MG existence is resolved by a ONE-TIME `az account management-group list` snapshot, never a
    per-MG `show`. This is the CANONICAL design, not a workaround (see the SP-verification ruling
    below and OQ-048).** The teardown runs as the scoped OIDC SP whose MG-read grants were scoped to
    the globaris subtree and are deleted WITH it, so the SP can DELETE the MGs but cannot then `show` a
    deleted MG: a per-MG `az account management-group show <deleted-mg>` returns HTTP-403
    `AuthorizationFailed` (not the clean 404 a tenant-root-privileged principal sees), and a per-scope
    policy read on a deleted MG returns the identical 403. So existence is captured ONCE per script run
    by `az account management-group list --query "[].name" -o tsv`; existence is name membership in
    that set (`mg_snapshot_load` / `mg_in_snapshot`, teardown-common.sh). The SP's surviving grant,
    Management Group Contributor at the tenant root (never deleted), carries
    `Microsoft.Management/managementGroups/read`, so the SP can always read that collection; a deleted
    MG is simply absent from it, with NO per-scope call and therefore NO deleted-scope 403 (proven,
    probe run 29756715840, run AS the SP: `list` returns only the tenant root; `show --name globaris`
    returns 403). Auth-fail-loud lives on the LIST call: a non-zero `is_auth_error` snapshot load is a
    genuine dead token at the one call the SP is always entitled to make -> FAIL LOUD; a successful
    list is authoritative ground truth. All four MG-touching sites (DISARM per-MG loop; VERIFY 1;
    VERIFY 4 as name-absence; az-sweep step 4) consume the snapshot; `show` is removed as an existence
    oracle everywhere. The throwaway probe workflow used to prove the oracle has been deleted from the
    repo.

**SP-verification ruling (2026-07-20, structural root of defect 3) - the list-snapshot oracle is
CANONICAL; a tenant-root Management Group Reader grant is REJECTED.** The teardown identity can delete
MGs but cannot verify their deletion via a per-scope read. Two ways to resolve it:
- (A, CHOSEN) Keep the `az account management-group list` snapshot oracle. Zero RBAC change, already
  proven green E2E, no bootstrap re-apply. It relies only on the SP's SURVIVING Management Group
  Contributor at the tenant root (which carries `managementGroups/read` and is never deleted), so the
  one list call the design depends on is always available.
- (B, REJECTED) Grant the SP a minimal Management Group Reader (or equivalent read) at the tenant root
  so a deleted-MG `show` returns a clean 404. It would simplify call sites (a per-MG existence probe
  would "just work") but it WIDENS the SP's standing grant, needs a bootstrap re-apply
  (bootstrap/identity.tf), and touches the OQ-008 / ADR-021 least-privilege scope-down that is trying
  to REDUCE this SP's footprint. Rationale for choosing A: it needs no RBAC change and no bootstrap
  change, is proven, and moves in the SAME direction as OQ-008 (less standing privilege), whereas B
  adds a standing grant to fix a purely diagnostic read. The list-oracle is therefore the deliberate,
  recorded design; the per-MG `show` oracle is retired (it was principal-dependent and is why defect 3
  occurred). Tracked as OQ-048.

**Residual hardening (follow-up, DevSecOps).** One coherence item remains from the reactive-patch
sequence: three DISARM list `else` branches (teardown-disarm.sh identity-scan ~L114-117, role list
~L132-134, assignment-names ~L156-158) still treat a NON-auth failure at a CONFIRMED-LIVE MG scope as
"no data / already disarmed" rather than failing loud, the same class VERIFY 1 already fixes. DevSecOps
hardens these three `else` branches to fail loud (per docs/teardown-redesign.md section 10.1) and
corrects the stale DISARM header comment. A lower-priority, backstopped coherence observation (four
delete-submission sites that swallow auth without classifying, section 10.2) is optional. No behavior
change beyond this class; the four-phase mechanism above is green and proven.

**Consequences of the consolidated mechanism:** a single dispatch tears the estate down E2E state-intact
or state-gone with zero manual steps; remediation cannot resurrect resources mid-sweep; Phase 2 is a
submission pass plus one relogin-bounded reconcile wait (no >token-lifetime step, no AADSTS700024); any
auth/token failure anywhere fails the run loudly; VERIFY is the instant, unwaited truth-gate that can
never certify "clean" off a dead token; a fresh redeploy meets a clean MG slate. Follow-up: DevSecOps
applies the section-10.1 DISARM hardening; OQ-008 / ADR-021 SP scope-down proceeds independently (the
list-oracle depends only on the SP's surviving tenant-root MG Contributor grant, which OQ-008 keeps);
OQ-022 tracks generalizing `az_relogin` to long deploy steps (teardown-only today).

**Changelog (compact audit trail; runs cited by number, no GUIDs):**
- 2026-07-19 - original 4-phase design (ADR-054). Same-day reviewer BLOCK correction: `synthetic`
  restored as a hardened Phase-1 root (not deleted), `remove_mg_hierarchy` default false, guard
  `az-sweep`-requires-`target=all` rejection added.
- 2026-07-20 - defect 1, OIDC assertion expiry on long deletes (run 29712487341): a ~55-min synchronous
  Databricks delete outlived the token; three swallow-the-error bugs made Phase 2 exit 0 having deleted
  nothing. Fixed by points 7 to 9 (deferred OQ-022 class in teardown).
- 2026-07-20 - defect 2 (parallel), Databricks managed RG no longer self-cleans (MS doc ms.date
  2026-07-08): fixed by point 10, `--force-deletion`.
- 2026-07-20 - run 29749656053: token-durability fix HELD, estate fully live-verified torn down; a new
  VERIFY 1 false-positive (403 on a deleted-MG policy read) surfaced.
- 2026-07-20 - SUPERSEDED interim oracle: a per-MG `az account management-group show` gate (expected a
  clean 404). Principal-dependent and WRONG for the scoped SP; do not implement.
- 2026-07-20 - defect 3 (attempt 4, run 29753193590; probe run 29756715840): the `show` oracle returns
  a 403 (not a 404) for the scoped SP on a deleted MG, failing loud at all four MG sites on benign gone
  MGs. Corrected by point 11, the `az account management-group list` snapshot oracle.
- 2026-07-20 - attempt 5, run 29765892057: GREEN E2E (Confirm / DISARM / AZ-SWEEP / VERIFY all
  success), estate fully torn down. Design proven.
- 2026-07-20 - consolidation pass (this ADR body + docs/teardown-redesign.md rewrite): reactive-patch
  chain folded into one coherent mechanism; SP-verification ruling recorded (list-oracle canonical,
  OQ-048); residual class-A DISARM hardening handed to DevSecOps.
### ADR-053: Wave B9 security/compliance rulings + the B9-vs-B-R split principle - B9 does additive/Audit-first/net-new (CMK, PCI/SOC visibility, platform-MG Audit, OpenAI-guardrails Audit); B-R does enforcement (Deny-promotion) + live-network flips; most founding-B9 scope is already built

- **Date:** 2026-07-19
- **Section:** Banking wave B9 (security/compliance); anchors register items b10/b11/b13 + CMK;
  full spec docs/b9-security-design.md
- **Status:** Accepted (architect rulings + the split; CMK scope is the OQ-047 user fork)
- **Decision makers:** claude (architect); OQ-047 to the user
- **Sequencing:** user moved B8 to last - B9 (now) -> B-R -> B8 -> B10

**Context:**
Live verification today collapsed most founding-B9 scope into already-built: Defender for Cloud
runs 11 plans including Containers (the ADR-043 B2 flip) AND AI; NIST 800-53 R5 + CIS Azure 2.0 are
assigned at the Globaris root. What remains net-new + the accumulated register items (b10 open KVs,
b11 platform-MG missing public-endpoint Deny coverage, b13 OpenAI guardrails DoNotEnforce, CMK
breadth - estate CMK=0) now overlap with B-R, which also touches security/policy. The user
previously confirmed b9/b10/b11 ENFORCE at B-R (not pulled forward). Both KVs live pna=Enabled,
no ACL; PCI DSS v4.0.1 + SOC 2 Type 2 built-ins exist (GUIDs captured).

**Decision:**
1. **The split principle:** B9 does the ADDITIVE / non-enforcing / non-breaking half (net-new
   capability + Audit-first visibility that cannot block a create or break a running estate / a
   later wave's CI); B-R does ENFORCEMENT (Deny-promotion) and live-resource network FLIPS
   (operational/CI risk). Rule for future readers: could-block-or-flip -> B-R; adds-visibility-or-
   capability -> B9. This honors the user's b9/b10/b11-at-B-R confirmation because Audit != enforce
   and a spec != a flip.
2. **B9 DEPLOYS:** (a) CMK breadth on the data stores, gated behind OQ-047 (sub-flag enable_cmk);
   (b) PCI DSS v4.0.1 + SOC 2 Type 2 regulatory initiatives at root (assessment visibility, extend
   the existing NIST/CIS assignment pattern); (c) b11 stage 1 - the Deny-PublicPaaSEndpoints
   initiative at the platform MG parameterized to ALL members Audit (the visibility the platform
   tree lacks; native assignment = lower blast radius than perturbing avm-ptn-alz); (d) b13 -
   OpenAI/CogServ guardrails DoNotEnforce -> Audit. All behind enable_security_hardening (default
   false, LESSON 42).
3. **B9 DESIGNS but does NOT deploy:** b10 KV network hardening - the tfstate-KV JIT/Deny spec +
   the security-KV consumer inventory; the FLIP is B-R (with b11 stage 2), so the KV goes private
   exactly when the enforcing policy lands (no unprotected-but-hardened window; CI risk bundled
   into restoration). Honors the user's b10-at-B-R.
4. **Already built - no B9 action:** Defender for Containers (+AI), NIST 800-53 R5, CIS Azure 2.0.
5. **Stays out:** all Deny/enforcement (B-R), the finops-SA flip (b9, B-R), tenant-Security-Admin-
   gated features (B-R f10 after the grant), CA enforcement-mode flip (user decision), flag-restore
   deviations (B-R).
6. **CMK is the one genuine fork (OQ-047):** estate CMK=0, so it is net-new cost+complexity+
   availability-coupling risk (KV key loss = data loss); scope per data store is the user's call.
   No new module - CMK is config on existing modules (storage/Databricks/Foundry/Search
   customer_managed_key inputs, verified) + a purge-protected KV + keys + identities.

**Alternatives considered:**
- B9 hardens the KVs now (founding put KV fix in B9) - rejected: flipping a live KV (esp. tfstate,
  read every plan) to network-Deny mid-build carries CI-break risk, and the user confirmed b10 at
  B-R; B9 designs, B-R flips with the enforcing policy.
- B9 does the Deny-promotion (skip Audit-first) - rejected: the user confirmed enforce-at-B-R;
  Deny-now also gambles policy-root applies on propagation timing for zero interim gain over Audit.
- Re-build Defender/NIST/CIS in B9 - rejected: already live (would collide/replace).
- CMK as an architect ruling (no fork) - rejected: material cost + availability-coupling risk with
  zero estate precedent = a real user decision.
- CMK on the RP-managed dbstorage via the storage module - rejected: dbstorage is Databricks-RP-
  managed; CMK there is a workspace-level input requiring a workspace UPDATE (ForceNew plan-scan) -
  its own OQ-047 sub-item, not a storage-module config.

**Consequences:**
- Positive: a clean, gap-free B9/B-R division that double-builds nothing and honors the user's
  confirmations; B9 is additive/non-breaking (nothing enforced or flipped); the compliance story
  gains PCI+SOC; the platform-tree policy blind spot gets Audit visibility now.
- Negative / trade-offs: B9 is a THIN wave (most founding scope pre-built) - honest, not a gap; CMK
  (if taken) adds operational key-management burden; the platform-MG Audit assignment will surface
  many non-compliant flags (visibility, expected).
- Follow-ups: OQ-047 CMK scope/cost user answer; cloud-engineer extends platform/security
  (PCI/SOC + b13) + platform-MG (b11 Audit) + CMK config (if OQ-047=yes); architect pre-clearance
  docs/preclearance/b9-security.md (Audit-only/pure-adds bar; Databricks-CMK ForceNew scan); QA per
  design doc section 8; b10 spec handed to B-R.

### ADR-052: Wave B7 O&M Phase 1 build rulings - AMBA delivered by the TWO-part current mechanism (avm-ptn-alz assignments + avm-ptn-monitoring-amba-alz 0.4.0 supporting infra), DINE at platform + landingzones MG scopes, AMBA notifications converge to the operator stream (Phase 1); extends two existing platform roots, no new root

- **Date:** 2026-07-19
- **Section:** Banking wave B7 (Operations & Monitoring Phase 1); BUILDS the ADR-037 Phase-1 MVP;
  resolves the two OQ-033 build-time sub-decisions; full spec docs/b7-om-phase1-design.md
- **Status:** Accepted (architect technical rulings within the accepted ADR-037 target; no user
  fork - OQ-033 resolved scope/placement, ADR-037 accepted the target)
- **Decision makers:** claude (architect)

**Context:**
ADR-037 accepted the O&M target architecture (platform-anchored, policy-propagated via DINE,
AMBA-based, MVP-bounded) with the build deferred and TWO sub-decisions left to build time in
OQ-033: the AMBA delivery form and the DINE MG scopes. B7 is that build time. Anti-hallucination
sweep today: the current AVM AMBA-for-ALZ mechanism is TWO-part - avm-ptn-alz (the estate already
runs 0.19.1) carries the AMBA policy definitions/initiatives/assignments via the ALZ library
references, and a companion module avm-ptn-monitoring-amba-alz (0.4.0, published 2026-07-06)
deploys the supporting rg-amba-monitoring-001 + user-assigned MI + Monitoring Reader role that the
DINE alert policies run as. The ADR-037 doc's "assigned via avm-ptn-alz" phrasing under-specified
the companion module. Platform action group + LAW are live (B0a). Both target roots are B0a-green.

**Decision:**
1. **AMBA delivery form (OQ-033 sub-decision a):** the full AMBA-ALZ pattern via the two modules -
   avm-ptn-alz (extend the policy-assignment config with the AMBA alerting initiatives + the
   Deploy-Diagnostics DINE initiatives, pinned library reference) + avm-ptn-monitoring-amba-alz
   0.4.0 (supporting identity/RG). NOT a bespoke hand-rolled subset. Behind `enable_om_phase1`
   (default false, LESSON 42).
2. **DINE / assignment MG scopes (OQ-033 sub-decision b):** AMBA alerting initiatives +
   Deploy-Diagnostics assigned at the **platform MG** (management/connectivity/identity resource
   types) and **landingzones MG** (all spokes inherit automatically), Globaris root only for
   genuinely tenant-wide initiatives. Not per-spoke.
3. **Action-group convergence (Phase 1):** accept AMBA's own per-subscription notification action
   group + APR (endorsed pattern) but point its receiver at the SAME operator target as the
   existing platform action group so one on-call stream results; full single-action-group
   convergence + maintenance/business-hours APRs are Phase 2. Receiver values referenced
   abstractly, never committed.
4. **Roots:** extend `platform/management-groups` (policy) + `platform/management` (AMBA module +
   action-group receiver) - NO new root, NO spoke (ADR-036/037). Risk class is POLICY (assignment
   collisions, remediation-identity RBAC, library-reference version) not resource-create; the
   plan-scan bar on the policy-engine root is PURE ADDS, zero change/replace to existing MG/policy
   objects (LESSON 26 blast-radius).
5. **Bounded:** Phase 1 only - no DCR/AMA, no availability probes, no workbook fills, no custom
   per-component alerts beyond AMBA, no Update Manager/Grafana/ITSM (all Phase 2/3).

**Alternatives considered:**
- Fold AMBA into avm-ptn-alz alone (per the ADR-037 doc phrasing) - rejected: the current pattern
  REQUIRES the companion module for the remediation identity/RG; avm-ptn-alz alone deploys the
  policy but not the identity the DINE alerts run as (remediation would fail silently).
- Bespoke hand-rolled alert set - rejected: AMBA is the named/endorsed library; hand-rolling is
  the unbounded reinvention ADR-037 exists to avoid.
- Force all AMBA alerts onto the single existing platform action group at Phase 1 - rejected as
  Phase-1 scope: fights the pattern defaults for no bounded-MVP value; convergence via receiver
  alignment achieves the one-stream goal cheaply, full convergence is Phase 2.
- Per-spoke assignment - rejected: defeats the DINE inheritance model (OQ-033).
- A new monitoring root/spoke - rejected (ADR-036/037: O&M is a platform capability, not a spoke).

**Consequences:**
- Positive: the estate becomes observable/alertable end to end via policy inheritance; near-zero
  cost (~$0-2/day); reuses the live LAW + action group + avm-ptn-alz engine; the current mechanism
  is pinned correctly (anti-hallucination catch on the companion module).
- Negative / trade-offs: two AMBA action groups exist until Phase-2 full convergence (mitigated by
  receiver alignment); a first-consumption module (0.4.0) rides a high-blast-radius policy-engine
  root (mitigated by the pure-adds plan bar + known-issues sweep); AMBA content churns fast
  (lifecycle-clock re-verify if the apply slips).
- Follow-ups: cloud-engineer extends both roots (verify the avm-ptn-alz AMBA library-reference
  wiring at 0.19.1 + library 2026.04.2, and the 0.4.0 module input surface + MI/assignment id
  match, per CLAUDE.md rule 4); architect pre-clearance docs/preclearance/b7-om-phase1.md
  (collision sweep, remediation-identity RBAC, pure-adds bar); QA per design doc section 8; the
  operator receiver value supplied via CI, never committed.

### ADR-051: Wave B6 AI platform rulings - Foundry resource (kind AIServices) with gpt-5.4-nano on DataZoneStandard (deprecating-catalog catch), AI Search basic, single account PE with a three-zone group, compliant-by-design (zero exemptions), zero firewall delta

- **Date:** 2026-07-19
- **Section:** Banking wave B6 (AI platform); executes the OQ-038 resolution (shape B); full spec
  and verification log in docs/b6-ai-platform-design.md
- **Status:** Accepted (architect technical rulings; no user fork - OQ-038 fixed the shape, and
  the model/SKU calls below are technical selections inside it)
- **Decision makers:** claude (architect)

**Context:**
Live verification today: both module pins unchanged since the founding design
(avm-res-cognitiveservices-account 0.11.1 - its input surface is Foundry-resource-aware: kind,
cognitive_deployments, network_acls, custom_subdomain, PE zone groups; avm-res-search-searchservice
0.3.0). The eastus2 model catalog shows every founding-design example model
(gpt-4o-mini, gpt-4.1-nano/mini, o3-mini, o4-mini) as DEPRECATING - the exact LESSON 40 class the
lifecycle audit exists to catch; gpt-5-nano and gpt-5.4-nano are the GA nano-class chat options.
All three corp Deny members touching this wave (cognitive pna, cognitive networkAcls, search pna)
default to Deny; both RPs Registered; quota clean (accounts 0/100, model K-TPM free at both
deployment SKUs); all four AI private DNS zones live centrally, with services.ai NOT yet linked
to the spoke.

**Decision:**
1. **Foundry:** ONE Microsoft.CognitiveServices account, kind `AIServices`, S0, module 0.11.1,
   workload RG of bank-data-p1, custom subdomain, `public_network_access_enabled = false` AND
   `network_acls.default_action = "Deny"` (the 037eea7a member checks the ACL, not just pna),
   `local_auth_enabled = false`, system identity, diagnostics to law-platform, flag
   `enable_ai_platform` (default false).
2. **Model:** ONE deployment - `gpt-5.4-nano` version 2026-03-17 (newest current-GA nano-class
   chat model; the deprecating catalog forbids the founding examples), SKU **`DataZoneStandard`**
   capacity 10 (US data-zone processing = the banking residency posture; 2000 K-TPM verified
   free), GlobalStandard recorded as fallback if DataZone ever caps.
3. **PE/DNS:** ONE account PE into snet-private-endpoints with a THREE-zone group
   (cognitiveservices + openai + services.ai) per current Foundry PE guidance; dns_links.tf gains
   the one missing services.ai link (zone live centrally, verified).
4. **AI Search:** module 0.3.0, `basic`, 1 partition/1 replica, pna false, local auth off,
   system identity, ONE PE on the live search zone, diagnostics to LAW.
5. **Zero exemptions** (compliant by design on all three Deny members) and **zero
   firewall/UDR/NSG delta** (PE-carried traffic; inference rides the account PE; ARM control
   plane rides the CI runner).
6. **Boundary:** no projects/agents, no RAG pipeline/indexes/shared private links, no Document
   Intelligence resource (design-only per OQ-038), no PTU, no second model. QA bar: ARM
   live-vs-intent + in-cluster DNS resolution REQUIRED; one in-cluster AAD completion call
   best-effort (NSP query-path caveat).
7. B6's production-target items appended to the ADR-049 deviation register as documentation-only
   (no flags, nothing for B-R to restore).

**Alternatives considered:**
- Deploying a founding-design example model (gpt-4o-mini class) - rejected: Deprecating in the
  live catalog; deploying into a deprecation window is the LESSON 40 failure class.
- gpt-5-nano (2025-08-07) - viable, rejected for the older lifecycle date; 5.4-nano is the same
  class, newer, same quota picture.
- GlobalStandard as primary deployment SKU - rejected: global routing undercuts the banking
  data-residency story for cents of difference at QA volume; recorded as fallback.
- OpenAI-kind account instead of AIServices - rejected: the founding naming audit anchored
  Foundry-resource-first; AIServices is the current model and the module supports it natively.
- Building a Foundry default project at POC - rejected: adds surface with no QA value; the
  boundary keeps projects design-only.
- Search free tier - rejected: no PE support; basic is the smallest PE-capable tier.
- Two PEs on the account (openai + cognitiveservices separately) - rejected: one account PE with
  a multi-zone group is the documented current pattern; fewer moving parts.

**Consequences:**
- Positive: the AI tier lands compliant-by-design with zero exemptions, zero network deltas, and
  ~$3/day; the model selection is deprecation-safe as of today; the RAG story has both halves
  (Foundry + Search) private and AAD-only.
- Negative / trade-offs: Search basic bills from create (~$2.5/day) regardless of use; the
  completion-call QA proof is best-effort behind the standing NSP caveat; model catalogs churn
  fast - if the apply slips past 2026-07-25 the catalog must be re-listed (lifecycle clock).
- Follow-ups: cloud-engineer one-pass batch (ai.tf + dns_links key + variables + poc.tfvars
  flip); architect pre-clearance docs/preclearance/b6-ai-platform.md before any apply (name
  availability, matrix refresh, telemetry fan-out counted from source per the B5 lesson); QA per
  design doc section 7.

**POST-APPLY CORRECTION (2026-07-19, appended - original above unedited per append-only):** apply
29678062833 surfaced three fixes to this design (full fix-spec: docs/preclearance/
b6-ai-platform.md failure addendum). (1) AI Search deploys in **centralus** via a `search_location`
variable (eastus2 InsufficientResourcesAvailable, live capacity shortage); the PE stays in the
eastus2 spoke subnet (cross-region PE, Azure-supported) - register d7. (2) The Foundry PE
three-zone group must be a native `azapi_resource` with explicitly-named configs
(`# DEVIATION:`), because avm-res-cognitiveservices-account 0.11.1 names every
privateDnsZoneConfig "default" and collides on a multi-zone set - a module bug on the
3-zones-one-PE shape, not our input (single-zone module PEs are unaffected). The module still
builds the account + PE with `private_endpoints_manage_dns_zone_group = false`; the live Foundry
account is reused (in-state no-op, never recreate). (3) `lifecycle ignore_changes = [tags]` on the
Fabric capacity - the OQ-032 CreatedDate tag-strip cannot apply to a PAUSED capacity
(400 "not ready to be updated"); this corrects the B5 "zero drift" prediction (the suspend leaves
capacity attributes undrifted but makes the standing policy-tag churn unappliable while paused).

### ADR-050: OQ-046 resolved as recommended (single pass, deferred to B-R) - and the delegated f1 collapse: DDoS Network Protection stays documented-not-deployed

- **Date:** 2026-07-19
- **Section:** Wave B-R (executes within the ADR-049 frame); resolves OQ-046
- **Status:** Accepted (user: "take the recommendations", implementation deferred to B-R;
  architect: the delegated f1 ruling)
- **Decision makers:** user + claude (architect)

**Context:**
OQ-046 consolidated the ten production-restoration forks with per-item costs. The user resolved
the whole pass by adopting the recommendations, deferring all implementation to wave B-R, and
delegated the one conditional (f1 DDoS, "yes if the claim must be literal") to architect judgment
against their demonstrated cost posture.

**Decision:**
1. Resolved states (full table: OQ-046 resolution + docs/b-restoration-design.md section 6):
   f2 Bastion on-demand; f3 Fabric pause-schedule; f4 keep the OQ-032 acceptance; **f5 APIM
   Premium with zones YES**; f6 SB geo-DR no; **f7 AKS user pool + autoscaler YES**; **f8
   Databricks front+back Private Link YES, strictly after the VPN GW restore**; f9 multi-region
   NO (stays the B10-documented DR design); **f10 Security Administrator grant YES** - a user
   action, exact steps recorded in the OQ-046 resolution (grant to the CI deploy SP; identifiers
   fetched from the portal, never written into the repo), after which the six ADR-033/034 flags
   flip at B-R.
2. **f1 ruled NO DEPLOY (architect, delegated):** DDoS Network Protection (~$2,944/mo) is ~35
   percent of the current estate run-rate for one control, on an estate whose only public
   ingress is the online-p1 App Gateway WAF_v2 - everything else is PE-only or internal. It
   remains the PRODUCTION DESIGN TARGET, documented with plan-attach mechanics
   (`enable_ddos_standard` is the standing one-flag re-enable; VNet associations follow the
   existing wiring), and DDoS IP Protection (per-public-IP SKU) is recorded as the cheaper
   targeted alternative if a literal claim is ever required. This is consistent with the
   estate's treatment of DDoS since Section 3 and with the documented-exception pattern the
   user has repeatedly chosen.
3. Resolved production cost picture: ~$235-250/day (~$7-7.5k/mo) at B-R completion - plain
   restores ~$21/day + resolved forks ~$100/day on the ~$112-125/day estate, with DDoS and
   multi-region as the two documented-not-deployed exceptions.

**Alternatives considered:**
- f1 YES (deploy DDoS Standard) - rejected under the delegation: disproportionate spend for the
  live ingress surface; the acceptance documentation gains honesty, not risk, from the recorded
  exception.
- f1 DDoS IP Protection now (per-IP on the App GW PIP) - noted, not adopted: still adds run-rate
  for a POC-window estate; recorded as the first escalation step in the production design.
- Re-litigating any recommended fork - rejected: the user's single-pass adoption is exactly the
  decision pattern OQ-046 was built for.

**Consequences:**
- Positive: B-R is now fully specified with zero open user decisions except OQ-045 (Fabric
  admin) and the f10 grant execution; the production claim has an exact, costed, honest shape.
- Negative / trade-offs: the production claim carries two documented exceptions (DDoS,
  multi-region); the f10 grant and OQ-045 are user actions that can lag - both are
  non-blocking until B-R.
- Follow-ups: register updated (done, section 6); B-R pre-clearance re-verifies every cost and
  the f7 family quota; f10 grant executed by the user before B-R's security slice; OQ-045
  still open.

### ADR-049: Production restoration directive - the build ends at FULL deployment (every sprint/cost deviation reversed), a dedicated B-R wave lands between B9 and B10, and the ADR-045 EOW teardown becomes a post-validation decision instead of an endpoint

- **Date:** 2026-07-19
- **Section:** Banking build closure frame (waves B6..B10 + new wave B-R); supersedes the
  teardown-as-endpoint framing of ADR-045 (its gates, cadence, and Frame A/B mechanics STAND);
  builds on ADR-042 (the flags it gated are now scheduled restores) and the ADR-022
  designed-now/built-later split (which now gets a built-at-B-R resolution per item)
- **Status:** Accepted (user directive 2026-07-19; architect design of the wave, register, and
  fork consolidation)
- **Decision makers:** user (directive), claude (architect)

**Context:**
The estate was built under two successive cost frames: monthly-run-rate POC (ADR-015/031/032/042
era gating) and the ADR-045 build-verify-destroy sprint (EOW teardown as the cost backstop). The
user has now directed: when the banking build completes, the landing zone must return to FULL
deployment with every sprint/cost deviation reversed - the end state must meet a PRODUCTION
environment setup, not a POC (the user's own example: the VPN gateway gated off under ADR-042).

**Decision:**
1. **Sequence:** build (B6..B9) -> **B-R restoration wave** -> B10 validate/QA at the production
   shape -> THEN the teardown/keep decision. B-R is a dedicated wave BEFORE B10 so the acceptance
   stamp applies to the production shape, not a mutated-after-validation one.
2. **ADR-045 supersession is narrow:** the EOW teardown stops being the scheduled endpoint; it
   becomes one of two outcomes of a decision taken AFTER B10 validation. Everything else in
   ADR-045 (per-wave gates, plan bars, QA-before-green, cost-per-wave statements) stands
   unchanged through B6..B-R.
3. **The deviation register** (docs/b-restoration-design.md) is the authoritative enumeration:
   class (a) gated-off infrastructure (VPN GW, DNS resolver, DDoS plan, Bastion, Fabric flag),
   class (b) posture/process artifacts (dbstorage waiver early-drop, flow-log waivers
   keep-documented, ADR-041 bootstrap reconcile, Fabric RP, OQ-032 stance, NSP QA path, final
   promotion), class (c) POC-sizing vs recorded production targets (APIM Premium, EH
   auto-inflate, SB geo-DR option, AKS user pool + autoscaler, Databricks Private Link,
   multi-region as an explicit opt-in), class (d) honest unbuildables (SQL/App Service offer
   caps, v5 families, tenant-Security-Admin-gated features, GHAS billing).
4. **Production reading:** single-region production-grade workload tier + full dual-hub platform
   fabric. Multi-region scale-out is NOT silently assumed - it is fork f9 in OQ-046.
5. **One consolidated fork pass:** every user decision in the register is collected in OQ-046
   with per-item cost/day, so the user composes the end state in a single answer. Plain restores
   proceed on standing gates without user round-trips.
6. **Register maintenance:** B6..B9 append any new deviation to the register at their design
   time; B-R's pre-clearance re-runs the lifecycle audit (the build will be at or past the
   2-week clock) and re-verifies every cost figure.

**Alternatives considered:**
- Fold restoration into B10 - rejected: B10's value is validating a FINISHED shape; mixing
  mutation and validation in one wave blurs the stamp and the failure attribution.
- Restore-as-you-go (flip each deferred flag inside B6..B9) - rejected: interleaves long-create,
  high-cost applies with feature waves, multiplies plan-scan surface per wave, and denies the
  user the single-pass cost decision.
- Read "production" as multi-region scale-out - rejected as a silent default: roughly doubles the
  estate; surfaced as explicit fork f9 instead (the directive's own example is a single-region
  platform component).
- Piecemeal OQs per fork - rejected: ten sequential user round-trips; one costed pass is the
  recorded preference pattern (OQ-034/039 class).

**Consequences:**
- Positive: the build closes at a defensible production claim; every deviation has a written
  disposition instead of silent drift; the acceptance validation (B10) gains meaning; the
  teardown decision is made once, with full information, against a validated estate.
- Negative / trade-offs: restoration adds ~$21/day (plain) up to ~$270/day-class (all forks,
  pre-multi-region) run-rate while the estate lives; B-R adds one wave of applies including two
  isolated long-runs (VPN GW create, APIM SKU upgrade); the dbstorage waiver expiry (2026-08-01)
  now sits inside the build window and must be handled by evidence, not by lapse.
- Follow-ups: OQ-046 single-pass user answer; register append duty on B6..B9 designs; B-R
  pre-clearance (lifecycle re-audit mandatory); b3 bootstrap reconcile ownership (B8 or B-R);
  B10 acceptance criteria updated to the production bar.

### ADR-048: Wave B5 data platform rulings - Databricks Premium VNet-injected + NPIP, the managed-RG dbstorage policy collision ruled as one unit (create-time storage firewall + expiring subscription-scoped waiver), service-tag-only rcg-dbx-egress-primary, ADLS Gen2 compliant-by-design, Fabric F2 deploy-active-then-suspend

- **Date:** 2026-07-18
- **Section:** Banking wave B5 (data platform); executes the OQ-037 resolution; closes the
  B1-parked Databricks firewall-allowances caveat in landing-zones/bank-data-p1/main.tf; full
  spec and verification log in docs/b5-data-platform-design.md
- **Status:** Accepted (architect technical rulings; the single user fork - the Fabric capacity
  admin principal - is routed to OQ-045 and gates ONLY the Fabric flag flip)
- **Decision makers:** claude (architect)

**Context:**
B1 shipped the bank-data-p1 network with both Databricks subnets delegated and a parked caveat
(control-plane egress rules = B5 scope). Verified today: the AVM module is still 0.5.0 (now
azapi-based) and its input surface covers VNet injection, NPIP, default storage firewall, and
diagnostics; the module docs mark the Databricks `standard` SKU deprecated Oct 2026; current
Databricks guidance RECOMMENDS service tags over IP/FQDN lists for UDR/firewall egress; new VNets
after 2026-03-31 require an explicit outbound method (our UDR-to-AZFW qualifies); the workspace
create places a dbstorage account in an RP-created managed RG, and the corp Deny-Public-Endpoints
StorageDenyPaasPublicIP member (live Deny, proven by the B1 flow-log collision) evaluates that RP
PUT - the classic Databricks-vs-policy first-apply killer. deny-pub-net-globaris storage member is
Audit-only (B1 live dump). azurerm_fabric_capacity exists in the pinned azurerm 4.71 line, has no
pause argument, and rejects hyphens in names.

**Decision:**
1. **Databricks:** avm-res-databricks-workspace 0.5.0, `premium` (deprecation-ruled, not
   preference), VNet-injected into the two live delegated subnets, `no_public_ip = true` (NPIP),
   compute_mode Hybrid, deterministic managed-RG name, diagnostics to the platform LAW, behind
   `enable_data_platform` (default false, LESSON 42). Front-end `public_network_access_enabled =
   true` at POC (no private access path exists this sprint; front/back-end Private Link is the
   production design target). NO clusters, jobs, warehouses, UC config, or databricks provider -
   hard demo boundary; the workspace create consumes ZERO Compute vCPUs, so the OQ-043 family
   question is moot for B5-as-designed.
2. **The dbstorage collision is ONE defense-in-depth unit:** (a) create-time
   `default_storage_firewall_enabled = true` + a pre-created access connector (posture half:
   the managed SA deploys with public access blocked per current MS Learn); (b) a
   subscription-scoped Waiver exemption on the landingzones sub scoped to the single
   StorageDenyPaasPublicIP member with `expiration_date` 2026-08-01, plus the standing 300s
   propagation sleep and depends_on (guarantee half: admits the create regardless of the RP's
   unverifiable PUT sequencing). QA records the live dbstorage publicNetworkAccess value; the
   exemption may be dropped early if the SA lands Disabled, else it self-expires.
3. **Firewall delta:** one RCG `rcg-dbx-egress-primary` priority 320 on the PRIMARY hub policy
   only, enable_firewall-gated, source = both Databricks subnets; service-tag-only network rules
   (AzureDatabricks 443/3306/8443-8451, Storage GLOBAL 443, EventHub 9093, Sql 3306,
   AzureActiveDirectory 443); no FQDN rules so DNS proxy stays off; no bypass routes. Dormant
   until a cluster exists, by design.
4. **NSG drift guard:** `lifecycle ignore_changes = [security_rule]` on nsg-databricks - the RP
   injects its UseOnly rules into our inline-rule NSG at workspace create; without the guard every
   later apply fights the Network Intent Policy.
5. **ADLS Gen2:** avm-res-storage-storageaccount 0.7.3 (azapi-shaped, first estate consumption),
   `is_hns_enabled = true`, module secure defaults stated explicitly (pna false, shared-key false,
   ACL Deny, TLS1_2, ZRS), one `raw` filesystem, blob + dfs PEs into snet-private-endpoints on the
   live zones with module-managed zone groups, diagnostics to LAW, CMK deferred to B9. Compliant
   by design - zero exemption for this SA.
6. **Fabric:** native azurerm_fabric_capacity (no AVM module exists - re-verified), F2/Fabric,
   lowercase-alnum name (provider name constraint breaks the hyphen convention - documented
   deviation), administration_members fed via TF_VAR from a GitHub variable (OQ-045 ask-user; no
   personal values committed), behind its OWN flag `enable_fabric_capacity` (default false, stays
   false until OQ-045 resolves). Deploys ACTIVE (~$0.36/hr; ARM has no create-paused); ruled
   posture = suspend same-day post-QA via `az fabric capacity suspend`; out-of-band suspend
   causes no plan drift; EOW teardown deletes it in any state.
7. **Wave cost:** ~$1/day at the suspended posture (~$9-10/day if F2 left active); Premium
   workspace with zero clusters is DBU-idle at $0.

**Alternatives considered:**
- RG-scoped exemption on the managed RG (OQ-024 shape) - rejected: the RG does not exist until
  the create is in flight; racy by construction.
- Pre-creating the managed RG to anchor the exemption - rejected: RP acceptance of a pre-existing
  managed RG is UNVERIFIED; not betting a first apply on it.
- notScopes/resourceSelectors on the corp assignment - rejected: mutates the avm-ptn-alz-owned
  assignment for a one-week need.
- Exemption-only without the storage firewall - rejected: leaves the managed SA public-enabled;
  weaker banking posture for the saving of one cheap connector resource.
- Front/back-end Private Link at POC (founding design 2.3 wording) - rejected for B5: 3+ extra
  PEs, browser-auth wiring, and NSG-mode changes for a workspace hosting zero clusters in a
  one-week sprint; recorded as the production design target.
- FQDN/IP firewall rules per region - rejected: Databricks explicitly recommends service tags;
  IP/FQDN lists rot (LESSON 40 class) and FQDN rules would force DNS proxy on.
- Synapse deployment - rejected at OQ-037 (satisfied-by-successor; lifecycle audit).
- One shared flag for Databricks+ADLS+Fabric - rejected: Fabric carries an independent
  offer-availability and OQ-045 risk; its own flag keeps the wave shippable without it.

**Consequences:**
- Positive: the likeliest first-apply killer is pre-ruled with a race-free mitigation; the B1
  parked caveat closes; zero exemptions on OUR resources (only the RP-created SA gets the
  expiring belt); the estate gains its first data-platform tier at ~$1/day; every rule object is
  service-tag-maintained.
- Negative / trade-offs: a subscription-scoped (member-scoped, expiring) exemption exists for up
  to ~2 weeks; the Databricks front end is public (AAD-gated) at POC; two first-consumption AVM
  modules ride one wave (mitigated by pre-clearance known-issues sweeps); Fabric may be blocked
  by the offer at PUT time (flag-protected watch item).
- Follow-ups: OQ-045 user answer (Fabric admin principal + GitHub variable); cloud-engineer
  one-pass batch (databricks.tf, datalake.tf, fabric.tf, policy_exemptions.tf extension, NSG
  lifecycle guard, firewall_rules_databricks.tf, variables, poc.tfvars flip); architect
  pre-clearance docs/preclearance/b5-data-platform.md before any apply; QA per design doc
  section 11 incl. recording the live dbstorage publicNetworkAccess value; suspend runbook step
  post-QA.

**POST-QA CORRECTION (2026-07-19, appended - original text above unedited per the append-only
rule; this corrects a factual expectation, it does not reverse the decision):** B5 QA (PC-4D,
PASS-with-notes) live-verified that the "posture half" expectation does NOT hold as written: the
dbstorage SA deploys with `publicNetworkAccess = Enabled`, protected by an RP-created network
security perimeter + network ACL defaultAction=Deny - public access is blocked IN EFFECT, but the
SA does not satisfy the b2982f36 member's letter (Disabled/SecuredByPerimeter). Therefore the
exemption half is LOAD-BEARING, not dormant insurance - the defense-in-depth ruling is VINDICATED
(the unit won the create first try precisely because both halves existed). The recorded
early-drop path is DEAD: the waiver runs to its 2026-08-01 expiry, and BEFORE expiry wave B-R
replaces it with a standing managed-RG-scoped exemption (the managed RG now exists, so the
create-time race argument that forced subscription scope no longer applies; deny-assignment
compatibility with exemption writes at that scope is a B-R verify item, fallback = renew the
sub-scoped waiver). The section-8 production framing "firewall + CMK + no exemption anywhere" is
corrected accordingly: production carries a standing, documented, narrowly-scoped exception for
the RP-managed SA (flow-log-waiver class) unless Microsoft moves the RP to SecuredByPerimeter.
Full disposition: docs/preclearance/b5-data-platform.md PC-4D addendum.

### ADR-047: Wave B4 API platform rulings - APIM Developer stv2 internal mode, scoped-FQDN DNS zone (apex azure-api.net pattern rejected), forced-tunneling unit (dedicated route table + service endpoints + rcg-apim-egress-primary), no public IP, kubelet RA fix rides the batch

- **Date:** 2026-07-18
- **Section:** Banking wave B4 (API platform); resolves the parked B1 forced-tunneling caveat in
  landing-zones/bank-app-p1/main.tf; full spec and verification log in
  docs/b4-apim-platform-design.md
- **Status:** Accepted (architect technical rulings; no user fork - the Developer tier is the
  recorded intent from the founding design and the B1 snet-apim design, and the ADR-045 sprint
  frame prices it at ~$1.6/day, so no SKU OQ is raised)
- **Decision makers:** claude (architect)

**Context:**
B1 shipped snet-apim (10.30.1.0/24) with the stv2 NSG rules and parked one caveat: whether stv2
forced tunneling needs an ApiManagement service-tag route. Verified today against current MS Learn
(internal-vnet doc updated 2026-06-25; virtual-network-reference dated 2026-04-30): (1) stv2
management-plane traffic REQUIRES a UDR for the ApiManagement service tag with next hop Internet
when a 0.0.0.0/0 NVA route exists - the caveat is real; (2) since May 2024 internal-mode stv2
needs NO public IP resource; (3) the common apex azure-api.net private DNS zone pattern is now
explicitly NOT SUPPORTED - zones must be scoped to the exact instance FQDNs (a LESSON 40 class
catch: the older community pattern validates and applies but is wrong per current guidance);
(4) the direct management API retired March 2025; (5) classic Developer tier is current, stv2 is
current, zones are Premium-only. Live sweep this session: Microsoft.ApiManagement RP Registered;
zero Deny policy members target APIM at corp or landingzones (ApiManDenyPublicIP =
AuditIfNotExists); instance name available; module avm-res-apimanagement-service still 0.9.0.

**Decision:**
1. **Instance:** APIM `Developer_1`, stv2, `virtual_network_type = "Internal"` in snet-apim, NO
   public IP resource, NO zones, system-assigned managed identity, module
   avm-res-apimanagement-service 0.9.0, flag `enable_api_platform` (default false, LESSON 42),
   shared RG. One mock health API for QA; nothing else (no portal publish, no self-hosted
   gateway, no AKS backend wiring, no custom domains at B4).
2. **DNS:** ONE private DNS zone scoped to the exact gateway FQDN
   (`apim-bank-app-p1-<org>-<env>.azure-api.net`) in the central rg-dns via the
   azurerm.connectivity provider, apex A record to the APIM private VIP, links to the spoke VNet
   and primary hub VNet. The apex azure-api.net zone is FORBIDDEN (unsupported, shadows other
   azure-api.net consumers). portal/developer/management/scm records are design-only.
3. **Forced tunneling is ONE unit:** (a) dedicated route table rt-apim on snet-apim carrying
   0.0.0.0/0 -> firewall AND ApiManagement -> Internet (shared rt-spoke untouched so the
   exception does not leak to AKS/PE subnets); (b) service endpoints Sql/Storage/EventHub/
   KeyVault on snet-apim (Microsoft strongly recommended; dependency traffic off the tunnel);
   (c) new RCG `rcg-apim-egress-primary` priority 310 on the PRIMARY hub policy only (ADR-044
   pattern, enable_firewall-gated, source 10.30.1.0/24) for the remaining force-tunneled
   dependencies: cert-validation/Entra/diagnostics/Windows-platform/Defender FQDN app rules +
   AzureMonitor 1886,443 + NTP UDP 123 + KMS TCP 1688 network rules, destination `*` on
   NTP/KMS to keep DNS proxy off. NSG unchanged (B1 rules match current requirements).
4. **Ordering:** connectivity RCG apply FIRST, then the bank-app-p1 apply - an APIM create
   behind a default-deny firewall hangs toward the 3h timeout. Long-create isolation and the
   mid-apply-death disposition (import-based recovery if the create was in flight) per the
   design doc section 9. Teardown designed: azurerm features api_management soft-delete purge
   flags in the root provider.
5. **The MANDATED kubelet AcrPull RA durable fix rides this batch** (B3 PC-3M disposition):
   data.azurerm_kubernetes_cluster on literal deterministic name/RG strings feeds the RA
   principal_id; the interim one-accepted-replace bar is RETIRED on merge; plans must then show
   zero replaces.

**Alternatives considered:**
- Apex azure-api.net private zone (community pattern) - rejected: explicitly unsupported per
  current MS Learn; breaks resolution of other azure-api.net names tenant-wide.
- ApiManagement -> Internet route on the shared rt-spoke - rejected: applies the bypass to
  AKS/PE subnets that never need it.
- Full force-tunnel of dependency traffic through AZFW instead of service endpoints - rejected:
  requires complete published IP-range allowlists per dependent service that rot (LESSON 40
  class) and adds timeout risk to the longest create of the build.
- Extending rcg-aks-egress-primary with APIM rules - rejected: different source prefix,
  lifecycle, and review blast radius per wave; a dedicated RCG keeps plan bars exact.
- Premium (zones, SLA) at POC - rejected: ~$95/day vs ~$1.6/day buys nothing the POC
  demonstrates; Premium multi-region + zones is the recorded production design target (ADR-022
  split). Not raised as an OQ: Developer is the standing recorded intent, not an open fork.
- v2 tiers (Standard v2/Premium v2 VNet integration/injection) - rejected for B4: the estate
  design and B1 subnet/NSG shape target classic stv2 injection; classic Developer is current
  with no retirement announced. v2 is noted for future evaluation in the production design.

**Consequences:**
- Positive: the parked caveat closes with verified current requirements; zero policy exemptions;
  zero NSG changes; the DNS ruling avoids a stale-pattern landmine; firewall evidence for QA now
  exists in-boundary (B3 diagnostics); the kubelet cascade dies.
- Negative / trade-offs: APIM platform dependency traffic bypasses AZFW inspection via service
  endpoints (recorded, Microsoft-recommended); the management return path bypasses the firewall
  by service-tag route (Microsoft states not a significant risk; inbound stays locked to 3443
  from the ApiManagement tag); Developer has no SLA and infra changes cause downtime (POC
  acceptable); the ~3h create window is the sprint's longest single apply.
- Follow-ups: cloud-engineer one-pass batch (apim.tf + rt/subnet delta + DNS + providers
  features + kubelet fix + firewall_rules_apim.tf + poc.tfvars flip); architect pre-clearance
  docs/preclearance/b4-apim.md before any apply; QA per design doc section 12.7.

### ADR-046: Wave B3 messaging platform rulings - Service Bus Premium 1 MU + PE (OQ-044 resolution retires the OQ-039 Waiver posture for SB), Event Hubs Standard PE-only, AAD-only data plane, AZFW diagnostics ride-along

- **Date:** 2026-07-18
- **Section:** Banking wave B3 (messaging/eventing); executes the OQ-044 resolution; refines
  docs/banking-platform-design.md section 2.2; carries the B2 QA MEDIUM finding fix
- **Status:** Accepted (user: SB tier; architect: platform rulings)
- **Decision makers:** user + claude (architect)

**Context:**
OQ-039 (2026-07-12) resolved Service Bus at Standard behind an RG-scoped Waiver exemption because
Premium's ~$680/mo was disproportionate under a monthly-run-rate frame, with Premium+PE recorded as
the production design target. ADR-045 (2026-07-18) collapsed that frame: the estate is a
build-verify-destroy sprint torn down at end of week, so Premium costs days (~$22.4/day, ~$110-160
to EOW), not months. Live policy verification today: the corp deny initiative's
`serviceBusDisablePublicNetworkAccess` and `eventHubNamespacesPublicNetworkAccess` members both
default to Deny. Full design and verification log: docs/b3-messaging-platform-design.md.

**Decision:**
1. **Service Bus ships Premium 1 MU + private endpoint** (OQ-044 = A, user): namespace
   `public_network_access_enabled = false`, PE into snet-private-endpoints against the live
   privatelink.servicebus.windows.net zone, `premium_messaging_partitions = 1`. Compliant with the
   Deny member by design - **the OQ-039 Standard+Waiver posture for Service Bus is RETIRED in this
   build**; no third exemption unit is built, and the POC now deploys the production design shape.
   The recorded Shape-B trap (a Standard consumer on AKS needing a `*.servicebus.windows.net`
   firewall app-rule) dies with it.
2. **Event Hubs ships Standard 1 TU, PE-only, public access off** (avm-res-eventhub-namespace
   0.1.0, MATURITY FLAG standing: single release 2025-04-28; fallback to native
   `azurerm_eventhub_namespace` + PE with a `# DEVIATION:` comment is pre-authorized if the module
   fails on our shape - one consolidated fix-spec, no improvisation).
3. **AAD-only data plane on both namespaces** (EH `local_authentication_enabled = false`, SB
   `local_auth_enabled = false`), SB `minimum_tls_version = "1.2"` - the banking no-static-
   credentials bar, matching the B2 disable_local_accounts posture.
4. **Placement + gating:** both namespaces + one demo entity each (evh-demo, sbq-demo - minimal QA
   data-plane surface) in the bank-app-p1 SHARED RG behind `enable_messaging_platform` (bool,
   default false, LESSON 42). Pins: avm-res-eventhub-namespace 0.1.0, avm-res-servicebus-namespace
   0.4.0 (both re-verified latest on the registry today).
5. **Zero new network surface:** PEs into the existing snet-private-endpoints; both use the shared
   servicebus zone (two distinct A records - QA verifies both); no new zones, subnets, UDR or
   firewall-rule changes (PE traffic is in-VNet).
6. **Ride-along:** the B2 QA MEDIUM finding fix - AZFW diagnostic settings on both hub firewalls
   (for_each over module.hub_and_spoke.firewall_resource_ids gated on enable_firewall, category
   group allLogs + AllMetrics, log_analytics_destination_type "Dedicated", new
   platform_law_workspace_id variable; CI TF_VAR already estate-wide) - full spec in the design
   doc section 6.
7. Diagnostics on both namespaces to the platform LAW; managed identities/CMK omitted at B3 (CMK
   is the B9 extension).

**Alternatives considered:**
- Standard + Waiver as resolved in OQ-039 - rejected by the user via OQ-044: ~$120 of sprint
  savings against a public data-plane endpoint in a banking POC, a third exemption unit to build
  and verify, and a latent firewall-rule dependency for future consumers.
- Gate Service Bus off (OQ-044 option C) - rejected: thins the messaging story for negligible
  savings once Premium is priced in days.
- Premium with >1 MU or zone-redundancy tuning - rejected: 1 MU is the smallest Premium unit and
  POC traffic is nil; scale-unit math is the B10 capacity chapter.
- Building the AZFW diagnostics as its own wave - rejected: 2-resource change on a root B3 already
  touches; separate dispatch ceremony for no risk reduction.

**Consequences:**
- Positive: zero policy exemptions in wave B3; every B2/B3 data-plane service is PE-only and
  AAD-only; the estate demonstrates the production Service Bus posture live; firewall log evidence
  unblocked for B4+ QA.
- Negative / trade-offs: ~$24/day B3 delta while the sprint runs (dominated by the 1 MU); EH rides
  a maturity-flagged module (mitigated by the pre-authorized fallback); the retired Waiver posture
  remains referenced in OQ-039 history - superseded here, not edited there.
- Follow-ups: cloud-engineer one-pass batch (messaging.tf + firewall_diagnostics.tf) per the
  design doc; architect pre-clearance docs/preclearance/b3-messaging.md before any apply; QA
  verifies both A records + AZFW tables populating; EOW teardown covers both namespaces with the
  spoke (no new root).

### ADR-045: Sprint extension - no EOD re-gate; the full banking architecture stands up first, teardown moves to end of week (supersedes the ADR-044 time-box and PC-5K)

- **Date:** 2026-07-18
- **Section:** Banking waves B2-B10 operating frame; supersedes the EOD framing of ADR-044 (the
  rest of ADR-044 - outbound_type pin, RCG design, flag mechanics, ordering gate - STANDS)
- **Status:** Accepted (user directive, 2026-07-18, post-B2-green)
- **Decision makers:** user (directive), claude (architect - record + consequences)

**Context:**
ADR-044 framed the firewall return as a same-day sprint: build B2, then re-gate (Frame A) or tear
down (Frame B) by end of day. With B2 green (both applies exact-shape, QA PC-4K PASS-with-notes,
firewall IPs on contract), the user superseded the time-box: stand up the ENTIRE banking
architecture first; teardown moves to END OF WEEK. Firewalls and the AKS cluster stay up through
the sprint; the firewall pair's ~$85/day is accepted as sprint cost. This aligns with the OQ-039
clarification (BUILD-VERIFY-DESTROY: the estate exists to be built, verified, and destroyed; the
ceiling guards the window, spend is prorated).

**Decision:**
1. NO end-of-day re-gate. `enable_firewall = true` and `enable_kubernetes_platform = true` persist
   through the sprint. PC-5K of docs/preclearance/b2-aks.md is SUPERSEDED (marked in the doc);
   Frames A/B remain the documented mechanics for the END-OF-WEEK teardown decision instead.
2. Waves B3-B10 proceed on the standing cadence against the live estate. Each wave still carries
   its own pre-clearance, plan-scan bars, and QA gate - the directive changes the clock, not the
   gates.
3. Cost frame while the sprint runs: firewall pair ~$85/day + AKS/ACR ~$14-16/day + base estate;
   every new wave's daily cost is stated in its design doc. The ~$5k/mo OQ-039 ceiling still
   governs as a guard rail; at sprint duty cycle the estate sits well inside it.
4. End-of-week closeout: full teardown via the standing spokes-first flow (teardown.yml must be
   current with every root added by B3+ waves - the OQ-039 clarification's standing requirement),
   OR a re-gate-and-keep decision if the user changes course; decided and recorded at EOW.

**Alternatives considered:**
- Hold the ADR-044 EOD re-gate and re-enable per wave - rejected by the user: repeated
  enable/verify/re-gate cycles add operator ceremony and re-verification risk (each re-enable
  re-arms the firewall-IP gate) for savings the sprint frame makes marginal.
- Re-gate firewalls but keep the cluster running - rejected: a blackholed cluster degrades
  (ADR-044 Frame A analysis); stopping and restarting it daily adds failure surface mid-sprint.

**Consequences:**
- Positive: B3-B10 build against a live, inspected-egress estate (QA can prove egress rules per
  wave); no daily stop/start ceremony; the firewall-IP contract is verified once and holds.
- Negative / trade-offs: sprint burn ~$100+/day while it runs; the EOW teardown is now the single
  cost backstop and MUST NOT slip silently - if the sprint extends past 2026-07-25, re-affirm the
  directive and re-run the LESSON 40-41 lifecycle deltas for unapplied waves.
- Follow-ups: PC-5K marked superseded (done); teardown.yml wiring for each new B3+ root rides
  each wave's batch; EOW disposition recorded in WORKLOG when taken.

### ADR-044: B2 egress ruling executed - time-boxed firewall sprint (userDefinedRouting), AKS rule collection group on the primary policy only, poc.tfvars flag supply, EOD re-gate frames

- **Date:** 2026-07-18
- **Section:** Banking wave B2; executes the OQ-042 resolution; fires the ADR-042 re-enable trigger; complements ADR-043 (which deliberately left outbound_type unruled)
- **Status:** Accepted (user: option choice, time-box, hourly cost framing; architect: rules delta, placement, runbook)
- **Decision makers:** user + claude (architect)

**Context:**
OQ-042 resolved: option (a), userDefinedRouting through the returning ADR-042 firewall pair,
EXPLICITLY TIME-BOXED - the user intends to stand the full banking landing zone up and re-gate or tear
the firewalls down by end of day, costing them at ~$3.5/hr for both hubs rather than as monthly
run-rate. ADR-042's one-flag-both-hubs design stands (no supersede). The hub firewall policies were
authored pre-AKS (ADR-009 era) and contain ZERO allow rules; with default-deny, an AKS cluster behind
the firewall cannot bootstrap without an explicit egress rule set. The pinned pattern module's
firewall_policy schema (0.17.1 source, read 2026-07-18) has no rule-collection support, so rules are a
standalone resource in the connectivity root.

**Decision:**
1. **outbound_type is now PINNED: `userDefinedRouting`.** The B1 spoke wiring is untouched - the
   0.0.0.0/0 -> 10.0.0.4 UDR stays on snet-aks-nodes and goes live when the firewall returns. The
   route-scoping change designed for options (b)/(c) is dead and must not be made.
2. **AKS egress rules = one `azurerm_firewall_policy_rule_collection_group` (`rcg-aks-egress-primary`,
   priority 300) on the PRIMARY hub policy only** (ADR-009 independent policies; no eastus2 spoke
   routes to the secondary firewall, which returns for mesh-route integrity only). Contents verified
   against Microsoft Learn outbound-rules-control-egress (2026-06-18 page): application collection =
   AzureKubernetesService FQDN tag (443+80) + Ubuntu repo FQDNs + Defender-for-Containers FQDNs;
   network collection = AzureMonitor service tag TCP 443 + NTP UDP 123 to `*`. Deliberate exclusions,
   each because the private-networking path already carries the traffic: UDP 1194 / TCP 9000 /
   API-server 443 / `*.hcp.<region>.azmk8s.io` (private cluster, konnectivity over the private
   endpoint) and all pulls from our own ACR (private endpoint). NTP uses destination `*`, never an
   FQDN, so firewall DNS proxy can stay OFF; the FQDN tag and application-rule FQDNs do not need it.
   New file `platform/connectivity/firewall_rules_aks.tf`, gated on `var.enable_firewall` via for_each
   (no-count rule) so the EOD re-gate removes it automatically; source prefix is a variable defaulting
   to 10.30.0.0/24.
3. **Flag supply: `enable_firewall = true` is a reviewed commit in `envs/poc.tfvars`**, not a
   workflow-dispatch override - flag state must be visible to plan-on-pr and drift checks, and the EOD
   re-gate becomes an equally reviewable one-line revert.
4. **Ordering is hard:** connectivity apply (firewalls + rules) FIRST, then a post-apply gate
   confirming the firewall private IPs are exactly 10.0.0.4 / 10.1.0.4 (the ADR-042 contract), THEN
   the bank-app-p1 AKS apply. Nodes cannot bootstrap through a blackhole; a firewall on the wrong IP
   is a STOP before the spoke is touched.
5. **EOD disposition, two pre-framed options, user picks at EOD:** Frame A = re-gate only (revert flag,
   ~20-35 firewall-class destroys, zero VNet/zone destroys) PAIRED with `az aks stop` - a cluster
   behind a re-blackholed route cannot scale, upgrade, pull, or ship telemetry, so stopping it freezes
   it cleanly, stops node billing, and releases 6 vCPUs (OQ-043 synergy); restart order later is
   firewall first, then `az aks start`. Frame B = full estate teardown via the standing spoke-first
   flow. Runbook with plan-shape histograms: design doc section 6.4.

**Alternatives considered:**
- Rules via the module's firewall_policy config - impossible; the 0.17.1 schema has no rule support.
- Rules on both hub policies - rejected: nothing routes eastus2 AKS egress to the secondary firewall;
  duplicate rules would be untestable dead config (ADR-009 notes the duplication burden).
- FQDN-by-FQDN application rules instead of the AzureKubernetesService tag - rejected: the tag is
  Microsoft-maintained and auto-tracks list changes; explicit FQDNs rot (LESSON 40 class).
- ntp.ubuntu.com FQDN network rule - rejected: would force DNS proxy on, a policy behavior change with
  spoke-wide blast radius, for a rule the docs call optional on modern node images.
- Workflow-dispatch TF_VAR for the flag - rejected: invisible to PR plans and drift detection.
- Leaving the cluster running after Frame A re-gate - rejected as default: a blackholed cluster decays
  (no pulls/upgrades/telemetry); recorded as user-overridable at EOD.

**Consequences:**
- Positive: banking-grade inspected egress is actually demonstrated (IDPS Alert, FQDN-tag allowlist,
  default-deny); the firewall bill is hours-scale; re-gate is a one-line revert; the production
  design target and the POC deployment are the same architecture, differing only in duty cycle.
- Negative / trade-offs: while re-gated (Frame A) the platform is frozen, not merely idle; the sprint
  has a hard intra-day ordering dependency (connectivity before spoke); rule changes remain
  primary-policy-only knowledge until the ADR-009 parent/child hierarchy is ever built.
- Follow-ups: implementer builds firewall_rules_aks.tf + poc.tfvars flip + aks.tf/acr.tf in one pass;
  architect pre-clearance (docs/preclearance/b2-aks.md) before the first apply; QA per section 6.4
  step iii; EOD user decision Frame A vs B recorded in the WORKLOG when taken.

### ADR-043: Wave B2 AKS platform design rulings - D2s_v4 supersedes the v5 node family (offer cap), CNI Overlay CIDR pins, private cluster on the shared estate zone, ACR Premium, single system pool, no GitOps at B2

- **Date:** 2026-07-18
- **Section:** Banking wave B2 (Kubernetes platform); refines docs/banking-platform-design.md section 2.1
- **Status:** Accepted (architect technical rulings; the egress fork and quota disposition are NOT decided here - OQ-042 / OQ-043)
- **Decision makers:** claude (architect). User forks deliberately excluded and routed to OQs.

**Context:**
B1 delivered the bank-app-p1 network foundation (QA-green 2026-07-18). B2 designs the AKS platform into
it. OQ-036 fixed the module (avm-res-containerservice-managedcluster), node count (3, AZ-spread), and
tier (Standard). Live verification on 2026-07-18 found: (1) the module is still 0.6.7 and its azapi-based
input surface covers every needed lever (network_profile incl. outbound_type/pod_cidr, private cluster w/
BYO private_dns_zone, oidc_issuer_profile, workload identity, aad_profile w/ Azure RBAC, oms agent,
diagnostic_settings); (2) the landingzones sub caps EVERY v5 VM family at 0 in eastus2 (the ADR-031/032
offer-cap class again) while DSv4-class families and the total regional cap sit at 10 vCPUs; (3) the AKS
default service CIDR (10.0.0.0/16) collides with the primary hub VNet; (4) kubenet retires 2028-03-31 and
CNI Overlay is the current default (lifecycle audit clean); (5) ACR private endpoints still require
Premium. Full log in docs/b2-aks-platform-design.md section 2.

**Decision:**
1. **Landing + gating:** AKS and ACR extend `landing-zones/bank-app-p1` (composition root, AVM-direct
   per ADR-038) behind `enable_kubernetes_platform` (bool, default false) - the LESSON 42 flag pattern.
2. **Node SKU superseded:** Standard_D2s_v4, 3 nodes, zones 1-3, single system pool, autoscaler off,
   upgrade max_surge 1. The founding design's v5 family is unbuildable in this sub (family cap 0);
   D2s_v4 is zone-complete and unrestricted (live-verified). A user node pool is quota-blocked at POC
   (10 total vCPUs) and becomes a production design target.
3. **CIDR pins:** pod_cidr 192.168.0.0/16 RATIFIED (the B1-recorded recommendation); service_cidr
   PINNED to 172.20.0.0/16 with dns_service_ip 172.20.0.10, because the AKS default service CIDR
   10.0.0.0/16 overlaps the primary hub and would silently break pod-to-hub routing. Neither CIDR may
   ever be left to defaults.
4. **Private cluster wiring:** enable_private_cluster true, public FQDN off, BYO private_dns_zone = the
   estate's shared privatelink.eastus2.azmk8s.io zone (already spoke-linked and hub-linked). This
   requires a pre-created user-assigned control-plane identity holding Private DNS Zone Contributor at
   the zone scope (connectivity sub) and Network Contributor at the spoke network RG, each with a 300s
   propagation sleep before cluster create (LESSON 35 timing class). The API-server record is written by
   the control plane, NOT a PE zone group; the zone-group pattern applies to the ACR PE only.
5. **Auth:** Entra-managed AAD profile with Azure RBAC enabled, admin group supplied by the user as a
   variable, disable_local_accounts true.
6. **Workload identity:** OIDC issuer + workload identity enabled at create.
7. **ACR:** avm-res-containerregistry-registry 0.5.1, Premium (private endpoints require it - ruled, not
   optional under the estate's deny-public posture), public access off, admin off, zone redundancy on,
   AzureServices bypass, one PE into snet-private-endpoints wired to the live privatelink.azurecr.io
   zone via the module-managed zone group; AcrPull for the kubelet identity at registry scope.
8. **Monitoring:** Container Insights (oms agent) to the platform LAW (region-matched, LESSON 43) +
   control-plane diagnostic settings (kube-apiserver, kube-audit-admin, guard) to the same LAW. Managed
   Prometheus/Grafana deferred to the B7 O&M wave.
9. **Defender for Containers** stays in B2 scope as a platform/security pricing flip with the ADR-035
   plan-scan condition (ForceNew subplan class).
10. **GitOps/Flux ruled OUT of B2** - nothing to reconcile until a workload exists.
11. **Egress outbound_type is NOT ruled here** - it is the OQ-042 user fork (firewall re-enable money
    decision, ADR-042 trigger). The root wires outbound_type and the aks-nodes route-table association
    so any OQ-042 outcome is a config change, not a redesign.

**Alternatives considered:**
- Keep the v5 family and request a quota increase before B2 - rejected: blocks the wave on a support
  ticket with refusal history on this offer (ADR-031/032); v4 is equivalent for POC purposes.
- Standard_B2ms burstable nodes - rejected: burstable CPU on a banking-platform demo undermines the
  posture story for ~$60/mo savings; BS family stays a fallback if D-family quota is ever consumed.
- Pattern module avm-ptn-aks-production - rejected at OQ-036 (older, opinionated; composition control).
- System + user pool split at POC - rejected: 3+2 nodes = 10/10 vCPUs, zero surge headroom, upgrades
  would deadlock (OQ-043).
- Free control-plane tier - rejected at OQ-036 (user chose Standard, SLA-backed).
- AKS-managed private DNS zone (system) - rejected: creates a second, unlinked zone outside the estate's
  central 89-zone set; hub-side resolution and the B1 links already serve the shared zone.
- GitOps/Flux at B2 - rejected as speculative scope (CLAUDE.md rule 3).

**Consequences:**
- Positive: B2 fits the live quota (6/10 steady, 8/10 upgrading); every OQ-036 commitment lands; the
  cluster is Zero-Trust-shaped on day one (private API, Entra-only, no local accounts, PE-only registry).
- Negative / trade-offs: the sub is effectively vCPU-full after B2 - B5 Databricks CANNOT fit alongside
  (OQ-043 disposition required); no user pool at POC; egress inspection depends on OQ-042 (loadBalancer
  or NAT gateway leaves node egress uninspected - documented POC deviation until the firewalls return).
- Follow-ups required: OQ-042 + OQ-043 user answers; docs/preclearance/b2-aks.md before any apply
  (checklist in the design doc section 9); user supplies the AKS admin group object ID (portal, per the
  ask-user-for-GUIDs rule); implementer verifies module output for the kubelet identity and the
  oms-agent use_aad_auth DCR requirement at build time.

### ADR-042: Defer the paid hub appliances - flag-gate Azure Firewalls, VPN Gateway, and DNS Private Resolver out of platform/connectivity (lean B0b = network fabric only), preserve the 10.0.0.4 / 10.1.0.4 firewall-IP contract

- **Date:** 2026-07-17
- **Section:** Banking wave B0b (platform/connectivity redeploy); amends the ADR-015 flag pattern; refines the OQ-034 split-B0 resolution
- **Status:** Accepted (user decision on the deferral itself, 2026-07-17; architect design of the gating)
- **Decision makers:** user (deferral), claude (architect - flag design, contract, recovery)

**Context:**
Apply run 29625961118 (B0b, 702 pure adds, PC-1/PC-2 passed) was cancelled by the user about 12
minutes in. The cancellation was a scope correction, not a fault: the user never intended the paid
hub appliances to deploy this early. Two Azure Firewall Premium (~$1.28k/mo each), the VpnGw1AZ VPN
Gateway (~$260/mo), and the DNS Private Resolver (~$365/mo for two endpoints) would idle with zero
consumers until B2+ workloads exist, against a ~$5k/mo ceiling. That expectation was never recorded
in any ADR or OQ - this ADR records it. The cancel SIGKILLED Terraform mid-apply: 13 resources
landed in the connectivity sub with unknown state coverage (the ADR-029 live-but-unstated class);
the firewall and both firewall PIPs are being deleted out-of-band on the same user decision.

**Decision:**
Hub network fabric now, paid appliances later, behind three default-false flags in
platform/connectivity, following the enable_bastion precedent (ADR-015):

1. `enable_firewall` (bool, default false) - wired to `enabled_resources.firewall` AND
   `enabled_resources.firewall_policy` on BOTH hubs. Verified in the pinned module source
   (avm-ptn-alz-connectivity-hub-and-spoke-vnet v0.17.1): setting `enabled_resources.firewall =
   false` nulls the firewall object per hub (locals.firewall.tf line 42), which removes the
   firewall, its PIP, the firewall policy (policy creation keys off the firewall flag, line 32),
   the AzureFirewallSubnet (mesh locals.subnet.tf line 45), and BOTH hub route tables - rt-hub-fw
   and rt-hub-std are each gated on `firewall != null || hub_router_ip_address != null` (mesh
   locals.routing.tf lines 3-4). One flag covers both hubs: the deferral is estate-wide and the
   mesh routes reference both firewalls, so they return as a pair.
2. `enable_vpn_gateway` (bool, default false) - wired to the PRIMARY hub's
   `enabled_resources.virtual_network_gateway_vpn` (secondary is already hard false). Explicit
   ruling: nothing in the POC consumes S2S or P2S VPN, there is no on-premises, and the gateway is
   the longest single create (30-50 min) and the largest apply risk in the root. GatewaySubnet is
   module-gated with the gateway (locals.subnets.tf line 24); its 10.0.1.0/27 carve stays reserved
   in the addressing plan so re-enable is a pure add.
3. `enable_dns_resolver` (bool, default false) - wired to the primary hub's
   `enabled_resources.private_dns_resolver`. Architect extension of the same principle: ~$365/mo
   with no consumer - spokes resolve private-endpoint zones via VNet links + Azure-provided DNS,
   platform/identity derives its DNS servers from AADDS (not the resolver), and the module's
   firewall-DNS-proxy default never engages in our config. Flipping the flag restores it in place.

The firewall, firewall_policy, virtual_network_gateways, and private_dns_resolver config blocks
STAY in main.tf, inert while their flags are false - exactly the bastion pattern. The
dns-resolver-outbound user subnet also stays (free, keeps its delegation, avoids conditional
subnet-map churn).

**The firewall-IP contract survives gating.** B1 spokes consume the firewall next-hop as plain
string variables (`primary_firewall_private_ip` / `secondary_firewall_private_ip`) fed from repo
Secrets, NOT from this root's outputs. Those secrets stay at 10.0.0.4 / 10.1.0.4. Determinism
verified against the root's subnet layout: main.tf pins the AzureFirewallSubnet carve to
`cidrsubnet(<hub /16>, 10, 0)` = 10.0.0.0/26 and 10.1.0.0/26; Azure reserves .0-.3, the subnet is
dedicated to the firewall, so the firewall's private IP is the first usable address = .4 - and the
2026-07-06 live deploy landed exactly 10.0.0.4 / 10.1.0.4. While gated off, spoke UDRs point
0.0.0.0/0 at a VirtualAppliance next-hop that does not exist yet: traffic blackholes, which is
harmless in network-only spokes (no workloads, no traffic) and is itself a deny-by-default
posture. Root outputs that index firewall/gateway/resolver maps become `try(..., null)` - they
must NOT hardcode the IP; the secrets carry the contract.

**When the appliances come back:** `enable_firewall = true` no later than the first wave that
needs real spoke egress. Recorded candidate triggers: B2 AKS with `outboundType =
userDefinedRouting` (hard dependency - AKS nodes cannot bootstrap through a blackholed default
route), and B4 APIM forced tunneling (the parked caveat in bank-app-p1 main.tf). The enabling
wave's pre-clearance re-runs the lifecycle audit (LESSON 40-41) and plan-scans for PURE ADDS into
the live VNets - subnets are standalone resources in this module, so the flip must never replace a
VNet; any `-/+ replace` is a STOP (LESSON 26). `enable_vpn_gateway` and `enable_dns_resolver`
return only on a demonstrated consumer (hybrid/S2S demo, hybrid DNS), possibly never in this POC.

**Alternatives considered:**
- Deploy firewalls now as originally planned - rejected by the user: ~$3.2k/mo idle spend with no
  workload to protect until B2+.
- Split the root (separate firewall root) - rejected: flags achieve the same deferral without a
  state migration or a new root; ADR-038 favors consolidated composition roots.
- Per-hub firewall flags - rejected: no scenario deploys one hub's firewall without the other; two
  flags double the test matrix for zero current need.
- Hardcode 10.0.0.4 into the root's firewall-IP outputs while gated - rejected: an output claiming
  an IP for a nonexistent appliance is a lie in live-vs-intent QA; null is honest and the secrets
  already carry the contract.
- Import the 10 surviving partial-apply resources - rejected: 12-minute-old, empty, stateless
  resources; delete-and-recreate is cheaper than import ceremony and guarantees a pure-create
  plan (recovery runbook in docs/preclearance/b0b-connectivity.md addendum).

**Consequences:**
- Positive: lean hub runs at roughly $20-40/mo (89 private DNS zones + fabric) vs ~$3.2k/mo
  deferred (2x FW Premium ~$2.55k, VpnGw1AZ ~$260, resolver ~$365, 4 PIPs ~$15). B1 unblocks on
  exactly what it needs: hub VNet IDs/names, the 3 lookup zones in rg-dns, and the deterministic
  IP secrets.
- Negative / trade-offs: no spoke internet egress and no east-west inspection while gated (all
  spoke default routes blackhole); every workload wave inherits a hard ordering gate on
  enable_firewall; hub route tables (rt-hub-std/rt-hub-fw) do not exist while gated, so nothing
  may assume them.
- Follow-ups required: cloud-engineer implements the fix-spec (3 variables, enabled_resources
  wiring, try() on 6 outputs); recovery runbook executed before the rerun (delete the two
  connectivity RGs after the in-flight firewall/PIP deletions finish, leave NetworkWatcherRG,
  force-unlock the state lease if stuck); plan-scan expects roughly 675-680 pure adds with 0
  firewall/PIP/route-table/gateway/resolver resources; PC-3 secret verification per the amended
  pre-clearance (IP secrets verified against the carve math, not against live outputs, which are
  null while gated).

- **Date:** 2026-07-12
- **Section:** Banking wave B0a (redeploy) / refines ADR-021, advances OQ-008
- **Status:** Accepted (b0a pre-clearance precondition PC-2/PC-3; see docs/preclearance/b0a-redeploy.md)
- **Decision makers:** claude (architect); operator executes the grants

**Context:**
The 2026-07-11 teardown deleted the globaris MG tree, and with it every MG-scoped role assignment on the
CI SP: bootstrap rows 2/3/4 (Resource Policy Contributor + UAA @ globaris, UAA @ landingzones) and the
3 standing OQ-008 Owner @ MG grants. Live enumeration (2026-07-12, direct per-scope queries) confirms
the SP retains Contributor + UAA at ALL FIVE subscriptions, Storage Blob Data Contributor at the state
SA, and Management Group Contributor at the Tenant Root Group - but nothing that can write policy
objects, role assignments, or consumption budgets at MG scope. The B0a roots need exactly that:
management-groups writes the whole ALZ policy engine at the recreated MG scopes; management assigns
tag-governance + a remediation role assignment @ globaris and creates 3 MG-scope budgets; security
assigns NIST/CIS @ globaris. Bootstrap rows 2/3/4 cannot be re-applied first because their scopes do
not exist until management-groups runs (the documented bootstrap-ordering caveat), and the original
first deploy escaped this only because the SP then held tenant-root Owner (ADR-006 era). A second gap
surfaced during this analysis: the ADR-021 scoped set NEVER covered Microsoft.Consumption/budgets at MG
scope - it was silently masked by the standing Owner @ globaris.

**Decision:**
1. Bridge the window with two TIME-BOXED grants to the CI SP at the Tenant Root Group scope, created
   manually by the operator before the B0a applies:
   - **User Access Administrator** (verified live: `*/read, Microsoft.Authorization/*, Microsoft.Support/*`)
     covers every policy definition / set definition / assignment / exemption write AND role-assignment
     write at all recreated MG scopes and below.
   - **Cost Management Contributor** (verified live: `Microsoft.Consumption/*, Microsoft.CostManagement/*`)
     covers the MG-scope budget writes.
2. After management-groups is green, run the FULL local bootstrap re-apply: rows 2/3/4 rebind at the
   recreated globaris/landingzones scopes (they are dangling in bootstrap state), and the known WORM
   immutability-policy drift reconciles.
3. Then REVOKE the temp UAA @ tenant root. The Cost Management Contributor grant's durable disposition
   is OQ-041 (recommended: a new bootstrap row at globaris MG scope, revoking the tenant-root temp).
4. The 3 Owner @ MG grants are NEVER re-created. Their deletion is the OQ-008 scope-down finally taking
   effect; B0a is the live validation run of the ADR-021 scoped set. Any 403 during B0a gets the precise
   missing action/scope added (ADR-021 rule), not an Owner re-grant.

**Alternatives considered:**
- Re-grant Owner @ globaris/platform/connectivity - rejected: reopens OQ-008, discards the accidental
  but real scope-down win the teardown delivered.
- Two-pass management-groups apply (create MGs, fail on policy, rebind bootstrap, rerun) - rejected:
  deliberately shipping a known-failing apply violates the one-disposition-per-failure-set discipline
  (LESSON 59) and the user's failure budget.
- Standing (permanent) UAA @ Tenant Root Group in bootstrap - rejected: broader than the globaris-scoped
  ADR-021 posture with no offsetting benefit once rows 2/3/4 rebind.

**Consequences:**
- Positive: single-pass B0a applies; ADR-021 finally gets its live validation without the Owner crutch;
  the Consumption gap is now known and tracked (OQ-041) instead of Owner-masked.
- Negative / trade-offs: temp UAA @ tenant root is self-escalation-capable for its window (same class as
  the accepted UAA @ globaris, one level broader) - mitigated by the time-box and the revoke step; two
  more manual operator actions.
- Follow-ups required: OQ-041 resolution; the eventual banking teardown needs the same MG-scope rights
  present at destroy time (rows 2/3 + the OQ-041 row cover it while the MGs still exist, since
  management destroys before management-groups); optional lifecycle hardening from the pre-clearance
  (log_analytics_workspace permanently_delete_on_destroy = true).

### ADR-040: Remove the deprecated KeyVaults and Arm Defender plans from the security root for the redeploy (supersedes the ADR-034 hold-as-latent-debt and the ADR-035 subplan pins for those two entries)

- **Date:** 2026-07-12
- **Section:** 6 (Defender/Sentinel) / Banking wave B0a redeploy
- **Status:** Accepted (b0a pre-clearance precondition PC-1)
- **Decision makers:** claude (architect); cloud-engineer implements

**Context:**
ADR-034 held the deprecated `KeyVaults` and `Arm` Defender plans as latent debt because they were
live-Standard and in state, where removing them meant a posture downgrade and the 2026-07-05 API block
only stops NEW Standard enablement. ADR-035 then pinned their Azure-assigned subplans to stop a
ForceNew recreate that the block would have failed. The teardown inverted every premise: verified live
2026-07-12, ALL Defender plans in the security sub are Free and the state is empty. On redeploy,
`azurerm_security_center_subscription_pricing.this["KeyVaults"|"Arm"]` would be a fresh Standard PUT =
new enablement of a deprecated plan = deterministic 400 ("plan is deprecated and can no longer be
enabled"), failing every security apply.

**Decision:**
Remove the `KeyVaults` and `Arm` entries from `local.defender_basic_plans` in
`platform/security/main.tf` (with a comment recording this ADR). Keep
`StorageAccounts = "DefenderForStorageV2"` pinned (ADR-035 logic still applies to it). The Defender
release-notes recheck (2026-07-12) found no additional blocked plans beyond the five of 2026-07-05;
all remaining configured plans are current.

**Alternatives considered:**
- Keep the entries and accept the failed resources - rejected: guarantees a partial apply on a root
  with a strict failure budget.
- Gate behind default-false flags - rejected: the block is permanent, not tenant-conditional; a flag
  implies a re-enable path that does not exist.

**Consequences:**
- Positive: the security redeploy plan is clean; the latent debt ADR-034 carried is retired rather
  than inherited by the banking estate.
- Negative / trade-offs: no Defender for Key Vault / Resource Manager coverage on the redeployed sub -
  identical to the forced end-state Microsoft's deprecation imposes; successor coverage is the
  Defender CSPM plan (already Standard in config).
- Follow-ups required: cloud-engineer edit + reviewer pass before the B0a security apply (PC-1);
  standing rule stays - re-audit the Defender plan list against current release notes in every
  pre-clearance that touches pricing.

### ADR-039: Adopt the Enterprise Azure Banking Platform as the next build on the existing landing zone; defer the AWS-Architecture rebuild; POC-scale deploys with production design targets documented; reuse the platform estate, do not rebuild it

- **Date:** 2026-07-12
- **Section:** Banking platform initiative (seeds PROMPT-BANKING.md; founding design in
  `docs/banking-platform-design.md`)
- **Status:** Accepted.
- **Decision makers:** user (direction), claude (architect, framing + recording)

**Context:**
The 13-section CAF ALZ POC is complete, QA-stamped, and was torn down clean on 2026-07-11 (state backend +
OIDC kept; redeploy is one deploy.yml run). The planned next step was rebuilding the same landing zone on AWS
(seeded by `docs/aws-architecture-draft.md`, OQ-A1..A8). On 2026-07-12 the user brought an actual workload
requirement instead: an Enterprise Azure Banking Platform (4-page business requirements doc; retail /
commercial / digital banking, analytics, AI, regulatory compliance) whose 11 scope areas overlap heavily with
what this repo already delivers. The gap analysis (`docs/banking-platform-design.md` section 1) classifies 2
areas DONE (ALZ, hub-spoke networking), 6 PARTIAL (identity, enterprise security, shared platform services,
monitoring, DR, DevSecOps), and 3 NET-NEW (Kubernetes platform, enterprise data platform, AI platform). The
requirements also carry two headline NFRs - 99.99%+ availability and a 100,000 TPM design target - that a
POC-budget estate cannot and should not deploy at face value.

**Decision:**
Four linked commitments:
1. **AWS-Architecture is DEFERRED**, not cancelled. The draft blueprint and OQ-A1..A8 stay on file; no AWS
   work proceeds until the user re-opens it.
2. **The banking platform is adopted as the next build, layered on the existing Azure landing zone estate.**
   The build plan is the 11-wave plan (B0-B10) in `docs/banking-platform-design.md` section 4, wave 0 being
   the redeploy of the existing estate.
3. **Reuse, not rebuild, on the platform side.** Existing roots (management-groups, connectivity, identity,
   management, security, spokes, CI/CD) are extended where the gap analysis names a delta; they are not
   redesigned. The Monitoring Platform requirement is satisfied by finally BUILDING the ADR-037
   Accepted-not-built O&M Phase-1 slice, not by a new design.
4. **POC-scale-vs-design-target split** (extends the ADR-022 designed-now/built-later precedent to NFRs):
   99.99% availability and 100k TPM are recorded as production DESIGN targets with the scale-out design
   documented per platform (APIM Premium multi-region, AKS Standard multi-cluster, Service Bus Premium
   geo-DR, zone redundancy); the POC deploys the correct private-networking shape at small SKUs and states
   explicitly where the POC posture cannot meet the target.

**Alternatives considered:**
- Proceed with the AWS rebuild as planned - rejected for now: a concrete workload requirement on the
  already-proven Azure estate delivers more portfolio and learning value than a parallel platform rebuild,
  and the AWS seed doc loses nothing by waiting.
- Greenfield a separate banking repo/estate - rejected: duplicates a QA-stamped landing zone, discards the
  proven CI/CD + policy engine, and contradicts the requirements doc itself (its platform scope IS this
  estate).
- Deploy the NFRs at face value (multi-region Premium tiers everywhere) - rejected: order-of-magnitude cost
  increase (~$2.8k/mo APIM Premium alone) for a POC; the designed-now/built-later split keeps the story
  honest and affordable.

**Consequences:**
- Positive: the estate gets a real workload narrative (banking) on top of the platform story; the three
  genuinely new platform types (AKS, data, AI) close the biggest portfolio gaps; ADR-037's O&M design finally
  gets built; all standing gates and the section-per-session model carry over unchanged.
- Negative / trade-offs: the base estate must be redeployed (cost resumes at ~$3.6-4.8k/mo) plus a net-new
  envelope of roughly $0.9-2.1k/mo at POC scale; AWS breadth is postponed; two NET-NEW areas carry 2026
  lifecycle risk that the design manages explicitly (Synapse-vs-Fabric anchor OQ-037; Microsoft Foundry
  naming).
- Follow-ups required: resolve OQ-034 through OQ-040 (redeploy scope, spoke placement + quota verification,
  AKS topology, data anchor, AI scope, budget ceiling, GitHub plan reality); author PROMPT-BANKING.md from
  the wave plan once the OQs land; refresh every root's pre-clearance at wave B0; re-run the LESSON 40-41
  lifecycle audit for any wave whose first apply lands more than 2 weeks after this design.

### ADR-038: Consume Azure Verified Modules directly in the composition roots; do not build a bespoke local-module abstraction layer (remove the unused Section-1 scaffold dirs)

- **Date:** 2026-07-11
- **Section:** 11.6 (per-module documentation) / 1 (repo structure)
- **Status:** Accepted.
- **Decision makers:** user, claude (architect)

**Context:**
Section 1 scaffolded a `modules/` directory with roughly 10 placeholder subdirectories (hub-network,
spoke-network, policy-baseline, private-dns, monitoring, security-sentinel, identity, synthetic-workload, and
others) under ADR-002, on the assumption the estate might wrap Azure Verified Modules (AVM) in bespoke local
modules. In practice only `modules/finops/` was ever populated. Every other capability consumes AVM modules
(`Azure/avm-ptn-*`, `Azure/avm-res-*`) **directly** in the composition roots (`platform/*`,
`landing-zones/*`), pinned per call. Completing Section 11.6 (per-module docs) surfaced that the 9 empty
scaffold dirs are dead structure and that "per-module documentation" is really per-root documentation.

**Decision:**
Consume AVM modules directly in the composition roots. Do NOT build a custom local-module abstraction layer
over AVM. The single exception is `modules/finops/`, a bespoke wrapper retained because no suitable AVM module
existed for the subscription/MG budget + azapi cost-export pattern it implements (ADR-027). The 9 unused
Section-1 scaffold directories are removed. Per-module documentation for Section 11.6 is therefore delivered
as per-ROOT `terraform-docs` READMEs (each composition root documents the AVM modules it calls) plus the
`modules/finops/` README, not as docs for empty scaffolds.

**Alternatives considered:**
- Keep the scaffold and build local wrapper modules over AVM - rejected: adds an indirection layer with no
  benefit and a real maintenance cost, and fights the AVM versioning/pinning model (each wrapper would have to
  re-expose and re-pin AVM inputs/outputs). Calling AVM directly in roots is the idiomatic ALZ-with-AVM
  pattern.
- Keep the empty dirs "just in case" - rejected: dead structure misleads readers and implies an abstraction
  layer that does not exist.

**Consequences:**
- Positive: the repo reflects reality (AVM-direct composition); documentation lives at the root level where
  the module calls actually are; no phantom abstraction layer to maintain.
- Negative / trade-offs: none material. If a genuine bespoke need arises later (as with finops), a new local
  module can be added deliberately at that point.
- Follow-ups / guidance: anyone extending the estate adds AVM module calls in a composition root, not a new
  local module, unless a genuine bespoke need (like `modules/finops/`) arises. Lineage: refines ADR-002
  (Section 1 scaffold) by removing its unused `modules/` placeholders; ADR-027 governs the retained
  `modules/finops/` azapi cost-export pattern.

### ADR-037: Anchor the Day-2 Operations and Monitoring target architecture - platform-anchored, policy-propagated (DINE), AMBA-based, MVP-bounded; accepted as the target, build deferred

- **Date:** 2026-07-11
- **Section:** 13 (repositioned) / CAF "Manage"
- **Status:** Accepted as the TARGET architecture. BUILD DEFERRED (designed-now / built-later, same posture as
  ADR-036 and ADR-022). Nothing is deployed by this ADR. Refines and supersedes ONLY the brief future-scope
  bullets in ADR-036; ADR-036's reposition decision and its designed-now/built-later status stand unchanged.
- **Decision makers:** user (approved the anchoring), claude (architect, design + recording)

**Context:**
ADR-036 repositioned Section 13 away from a synthetic load / red-team demo device toward a Day-2 Operations
and Monitoring (O&M) capability, and sketched the forward scope as a few bullets (platform-anchored,
DINE-propagated, AMBA-based). Those bullets were forward-sketch only, not an anchored decision. The architect
then produced a comprehensive, estate-grounded O&M design in `docs/operations-monitoring-design.md` covering
the full CAF "Manage" picture (monitoring data plane, alerting, routing, availability, visualization, platform
automation, DR/backup, FinOps overlap, RBAC, placement/propagation, phased roadmap, and an exists-vs-net-new
reuse table). The user approved making that design the accepted target architecture so the O&M layer is a
first-class decision rather than a sketch. This ADR anchors it. It does not deploy anything: the estate is
complete and QA-passed and teardown is imminent, so the build stays deferred.

Verified facts the design rests on (from the deployed estate, WORKLOG Section Status Tracker 2026-07-10 and
the `platform/management` + `platform/security` roots):
- The **platform LAW** (management sub) already exists as the operations hub and already receives hub Azure
  Firewall diagnostics, spoke VNet flow logs + Traffic Analytics, and Automation Account diagnostics.
- The **platform action group** and **Automation Account** exist in the management sub.
- A **separate Sentinel/security LAW** (security sub) is onboarded to Sentinel; cross-workspace query between
  the two is already proven (the security root's firewall threat-intel rule reads the platform LAW).
- The **`avm-ptn-alz` policy engine** (management-groups root) already delivers DINE/Modify initiatives at MG
  scope (tag governance, deny-public-network), so it is the ready vehicle for O&M policy propagation.
- Budgets, cost exports, a cost anomaly alert, Recovery Services Vaults, placeholder workbooks, and a
  hand-placed diagnostic-settings pattern already exist and are reusable.

**Decision:**
Adopt `docs/operations-monitoring-design.md` as the authoritative O&M target architecture, with these anchored
properties:
1. **Platform-anchored.** O&M assets extend the existing `platform/management` landing zone (the platform LAW,
   the platform action group, the Automation Account). No new root and no new spoke. Operational monitoring is
   a platform capability in canonical ALZ, not a workload tier.
2. **Policy-propagated.** Diagnostic settings and alerts are delivered by DeployIfNotExists initiatives at
   management-group scope through the deployed `avm-ptn-alz` engine, so every current and future landing zone
   inherits coverage automatically (the guardrail model), rather than hand-placed per spoke.
3. **AMBA-based.** Azure Monitor Baseline Alerts (AMBA) for Azure Landing Zones is the named alert library
   (platform-level + resource-health alerts), assigned as policy at MG scope, plus Service Health and Resource
   Health alerts routed to the existing platform action group.
4. **MVP-bounded.** The accepted first increment (Phase 1) is exactly: diagnostic-settings-at-scale (DINE) +
   the AMBA baseline + Service/Resource Health alerts + extending the platform action group + the Sev0-4
   severity/routing taxonomy. Phase 2 (availability probes, workbooks, DR/backup alerts, Network Insights,
   alert-processing rules) and Phase 3 (Update Manager, guest config, ITSM, Managed Grafana, auto-remediation)
   are explicitly OUT of the committed baseline and are optional later increments.
5. **Two-workspace split preserved.** The platform LAW stays the operations workspace; the security LAW stays
   the Sentinel/SecOps workspace. O&M targets the platform LAW and does not relocate or duplicate Sentinel.

**Alternatives considered:**
- A new standalone `operations/` or `platform/monitoring` root/spoke - rejected: O&M is a platform capability;
  a new tier fragments ownership and contradicts the canonical ALZ placement. The capability belongs in
  `platform/management` + policy.
- A bespoke, hand-authored alert set - rejected: AMBA is Microsoft's named, endorsed, maintained library for
  ALZ; anchoring to it bounds the build and keeps it credible rather than a reinvention.
- Per-spoke hand-placed diagnostics and alerts - rejected: does not scale and drifts; DINE at MG scope makes
  coverage a guardrail that new spokes inherit for free.
- Repurposing the synthetic root as the O&M vehicle - rejected: the synthetic `.tf` is a reusable idea source
  (notably its availability-probe potential), but the capability lands in `platform/management` + policy, not
  a renamed synthetic spoke. `enable_synthetic_workload` is irrelevant to this ADR (synthetic is not the
  vehicle; the design doc is).

**Consequences:**
- Positive: the O&M layer is now a first-class, accepted target architecture with a bounded MVP, an explicit
  placement/propagation model, and a documented reuse table; net-new Phase-1 work is small and almost entirely
  policy + existing assets; the design is CAF "Manage" aligned and portfolio-credible.
- Negative / trade-offs: nothing is deployed by this ADR (build deferred), so the estate carries no live O&M
  alerting today; the ADR-036 demo trade-off persists (Sentinel/Defender configured but no live operational
  signal stream) until Phase 1 is built.
- Relationship to existing records: **ADR-037 supersedes ONLY the future-scope bullets in ADR-036.** ADR-036
  stays **Accepted** - its reposition decision (Section 13 synthetic -> deferred O&M) and its
  designed-now/built-later status are untouched. ADR-037 refines that forward scope into an anchored target
  architecture.
- Follow-ups required:
  - Authoritative design: `docs/operations-monitoring-design.md`.
  - Build-time implementation detail (deferred, NOT open blockers): the exact AMBA-for-ALZ delivery form
    (which initiatives / how much of the library) and the precise MG scope(s) for the DINE assignments
    (platform vs landingzones vs per-archetype). Recorded against the now-resolved OQ-033.
  - When/if the estate becomes persistent, build Phase 1 first (the bounded MVP), in the cloud-engineer /
    devsecops lanes, under the normal code-review + pre-clearance gates.

### ADR-036: Reposition Section 13 from a synthetic load / security-signal demo device to a future Day-2 Operations and Monitoring layer for CAF landing zones; defer deploy (designed-now, built-later)

- **Date:** 2026-07-10
- **Section:** 13 (Synthetic Workload, being repositioned)
- **Status:** Accepted.
- **Decision makers:** user (direction + reframe), claude (architect, recording)

**Context:**
Section 13 was built as a "Synthetic Workload + Security Signals" layer: a k6 load generator, a red-team
simulator (honeypot sign-ins, decoy storage/Key Vault, impossible-travel, resource/storage/KV probing), and
five cost-generating anti-patterns - a demo device whose job was to manufacture attack and load traffic so
Section 6 Sentinel/Defender analytics rules would fire during the POC window. The layer was pre-cleared for
its first apply (`docs/preclearance/synthetic.md`: NO-GO as written, then dispositioned), the fix batch was
implemented, reviewed, and committed (`36f5044`), a gate-off plan-scan passed, and the final gate flip
(`enable_synthetic_workload = true`) was reviewer-approved. The user paused before the apply and reframed the
whole layer: the synthetic load-generation + red-team-decoy concept is not the right long-term scope for a
CAF landing-zone reference build. The user wants to drive this layer toward a Day-2 Operations and Monitoring
baseline (the CAF "Manage" methodology) - operational health and availability alerting, operational baselines,
monitoring workbooks/dashboards, and operational signals into the platform Log Analytics workspace - rather
than synthetic attack/load traffic. Teardown of the estate is imminent this week and the core estate is
complete and QA-passed, so deploy is deferred.

**Decision:**
Reposition Section 13. The synthetic load / honeypot / red-team-decoy / cost-pattern layer is retired as the
target scope and replaced, for a future build, by a Day-2 Operations and Monitoring layer for CAF landing
zones. The synthetic Terraform stays designed, reviewed, and committed but is NOT deployed:
`enable_synthetic_workload` remains `false`. Nothing is removed from the deployed architecture, because the
synthetic layer was never part of the canonical CAF Azure Landing Zone reference architecture - it was a demo
add-on. The canonical CAF ALZ layers (management-groups, management, connectivity, identity, security, and
the landing-zone spokes) ARE the reference architecture and ARE deployed, so deferring Section 13 subtracts
nothing from the architecture itself.

This mirrors the designed-now / built-later pattern already used for brownfield adoption (ADR-022 / OQ-014):
the design and code exist and are review-clean, but the build is intentionally deferred to a later, separate
effort with its own scope.

**Alternatives considered:**
- Deploy the synthetic layer as-is before teardown - rejected: the user judged the synthetic load / red-team
  demo device to be the wrong long-term scope, and there is no value in applying a to-be-repositioned layer
  hours before a teardown.
- Delete the synthetic Terraform - rejected: the code is review-clean and committed, some of it is reusable
  input for the future Ops and Monitoring layer, and deleting it discards work for no benefit. Keep it in the
  repo, gated off.
- Keep Section 13 as "Synthetic Workload" and add a separate Section for Ops and Monitoring - rejected: the
  user's intent is to REPOSITION this layer, not to run two parallel synthetic concepts.

**Consequences:**
- Positive: the architecture-as-deployed is the clean canonical CAF ALZ (no demo device baked in); the
  repositioned scope (Day-2 Manage baseline) is a more defensible, portfolio-grade landing-zone concern than
  synthetic attack traffic; no code is lost; the failure-budget exposure of a first-ever synthetic apply
  right before teardown is avoided.
- Negative / trade-offs: with Section 13 undeployed, Section 6 Sentinel and Defender for Cloud are correctly
  configured but will have NO live synthetic signals firing during the POC window (no manufactured incidents,
  no load telemetry). This is an accepted trade-off - the security posture and configuration are demonstrable
  from the deployed config, dashboards, and analytics-rule definitions rather than from live synthetic
  detections.
- Follow-ups required:
  - Target scope for the future Day-2 Operations and Monitoring capability (forward design guidance, NOT a
    build now). It is deliberately NOT a new standalone layer/spoke. Frame it as:
    - **Platform-anchored:** extend the existing `platform/management` landing zone (which already hosts the
      platform LAW and action group) with the monitoring baseline, rather than a new root or workload tier.
      Operational monitoring is a platform capability in canonical ALZ, not a workload.
    - **Policy-propagated:** deliver the per-landing-zone monitoring via DeployIfNotExists (DINE) policy so
      every current and future spoke inherits it automatically (the guardrail model), rather than hand-placing
      alerts per spoke.
    - **AMBA-based:** anchor to Azure Monitor Baseline Alerts (AMBA) for Azure Landing Zones - Microsoft's
      named, endorsed policy-driven alert library for ALZ (platform-level and resource-health alerts) - plus
      Service Health and Resource Health alerts wired to the existing platform action group. Citing AMBA keeps
      the future build bounded and credible rather than a bespoke reinvention.
    - **Scope discipline:** the bounded, high-value slice is the AMBA baseline + Service/Resource Health alerts
      + action-group routing. Building dashboards-for-everything is explicitly OUT of the bounded scope.
    - Optionally, recycle the useful synthetic ideas within this model: the cost-pattern signals could feed a
      FinOps / cost-anomaly monitoring view, and the k6 / app-traffic idea could become real
      synthetic-transaction availability probes (Application Insights availability tests or an Azure Monitor
      equivalent) rather than red-team load.
    Tracked in OQ-033.
  - `enable_synthetic_workload` stays `false`; the synthetic root is not applied. The synthetic `.tf` is kept
    as reusable input, but the future capability lands in `platform/management` + policy, not a repurposed
    synthetic spoke.

### ADR-035: Pin the basic Defender plan subplans to their Azure-assigned state values (stop a ForceNew destroy/recreate of the deprecated KeyVaults + Arm plans), and import the drifted SqlServerVirtualMachines plan via a config-driven import block

- **Date:** 2026-07-10
- **Section:** 6 / 8 (Defender for Cloud plans)
- **Status:** Accepted. Follows the ADR-034 deprecation finding; triggered by the ADR-034 step-6 plan-scan
  guard catching the issue on a clean plan before apply.
- **Decision makers:** user, claude (architect)

**Context:**
The run-3 clean plan (run 29135838771) reported `6 to add, 9 to change, 3 to destroy`. The three destroys were
FORCED REPLACEMENTS of `azurerm_security_center_subscription_pricing.this["Arm"]`, `["KeyVaults"]`, and
`["StorageAccounts"]`, each because `subplan` was going from its Azure-assigned state value to `null`
(`PerSubscription -> null`, `PerKeyVault -> null`, `DefenderForStorageV2 -> null`) and `subplan` is a ForceNew
attribute.

Verified facts this session:
- Root cause: `azurerm_security_center_subscription_pricing.this` (main.tf) uses
  `for_each = local.defender_basic_plans` (a `toset` of bare resource-type strings) and sets only
  `resource_type = each.value`, never `subplan`. The original apply let Azure auto-assign default subplans, and
  the provider stored them in state. Config `subplan = null` vs state `subplan = <value>` on a ForceNew field
  forces destroy plus recreate.
- Why it is dangerous now (not before): post 2026-07-05, KeyVaults and Arm are blocked for NEW enablement
  (ADR-034 audit). The recreate would DESTROY the plan (revert to Free, turning Defender for Key Vault and
  Resource Manager protection OFF, a real posture regression) and then attempt a re-enable PUT that now 400s -
  failing the apply and leaving both plans at Free. StorageAccounts is not deprecated, so it would recreate
  successfully, but destroy/recreate of a live plan is still unwanted churn.
- Why run-1 and run-2 did not hit it: both failed earlier (connectors / Dns) before reaching the `this`
  replacements. It only surfaced once those blockers were cleared.
- Scope confirmation: the `extended` plans (defender.tf) also never set `subplan` but do NOT force-replace -
  those resource types (AppServices, SqlServers, SqlServerVirtualMachines, Containers,
  OpenSourceRelationalDatabases, CloudPosture) are subplan-less, so Azure assigns no subplan and there is no
  drift. `servers` (VirtualMachines) already pins `subplan = "P2"` explicitly. So only the three basic plans
  with Azure-assigned subplans drift.
- Subplan values VERIFIED 2026-07-10: the pinned strings are the exact values already in state (which is what
  Azure assigned and the provider read), and are documented current subplan identifiers for their resource
  types (`PerSubscription` for Arm, `PerKeyVault` for KeyVaults, `DefenderForStorageV2` for StorageAccounts;
  azurerm docs also list alternates such as `PerApiCall` / `PerTransaction` that we deliberately do NOT switch
  to, since switching would itself be a change). Pinning config to the state value yields a zero-diff, not an
  update.
- Import mechanism VERIFIED against in-repo precedent: `platform/identity/domain-services.tf:185-190` (ADR-029)
  uses a config-driven `import` block whose `id` interpolates input variables, `each.value`, and even a managed
  resource attribute. So the project's Terraform version fully supports interpolation in an import `id`; a
  literal subscription GUID is not required.

**Decision:**
1. Restructure `local.defender_basic_plans` from a `toset` of resource-type strings to a MAP of
   `resource_type => subplan`, pinned to the exact state values: `StorageAccounts = "DefenderForStorageV2"`,
   `KeyVaults = "PerKeyVault"`, `Arm = "PerSubscription"`. Change
   `azurerm_security_center_subscription_pricing.this` to `resource_type = each.key` and `subplan = each.value`.
   The instance keys are unchanged (map keys equal the old set elements), so there is no address churn; config
   now matches state on `subplan`, so the ForceNew diff disappears and the three destroys vanish.
2. Import the drifted SqlServerVirtualMachines plan with a config-driven `import` block using an interpolated
   `id` built from the existing `var.security_subscription_id` (no hardcoded GUID). Remove the block in a
   cleanup commit after the successful apply.
3. Do NOT pin subplans on the `extended` plans (subplan-less resource types, no drift) and do NOT change
   `servers` (already pinned to P2). No speculative treatment.

**Alternatives considered:**
- `lifecycle { ignore_changes = [subplan] }` on `this` - rejected: masks the drift instead of resolving it,
  leaves config semantically wrong (subplan unset), hides the real subplan from readers, and a future provider
  change could resurface it.
- Remove KeyVaults + Arm from config to avoid the recreate - rejected (per ADR-034 / OQ-028): a DELETE
  downgrades security posture; they are held as-is until the migration decision.
- Hardcode the SqlServerVirtualMachines import `id` with a literal subscription GUID - rejected: commits a real
  subscription ID; interpolation via `var.security_subscription_id` avoids it and is proven by ADR-029.

**Consequences:**
- Positive: the three forced replacements disappear; KeyVaults and Arm stay live-Standard with no re-PUT
  (posture preserved); StorageAccounts stops churning; config now honestly reflects the live subplans. The
  ADR-034 plan-scan guard is validated - it caught a posture-degrading landmine on a clean plan before apply.
- Negative / trade-offs: `defender_basic_plans` changes shape (toset to map); the three subplan strings are now
  hardcoded and must track any future Microsoft subplan rename (low risk; these are stable identifiers).
  Pinning `DefenderForStorageV2` may surface a benign in-place `extension` diff on StorageAccounts (known
  provider behavior) - a watch item, not a blocker (in-place, not a replace, and StorageAccounts is not
  deprecated).
- Follow-ups required: (1) devsecops re-plans after the change and confirms `0 to destroy` and no replace on
  the three basic plans BEFORE apply. (2) Remove the SqlServerVirtualMachines import block in a cleanup commit
  after the apply lands. (3) Watch the StorageAccounts extension diff; if it becomes persistent noise, track
  separately (do not block this apply on it).

### ADR-034: Gate the cross-workspace firewall_threat_intel_hit analytics rule off, remove the deprecated Dns Defender plan, and hold the (now also deprecated) KeyVaults + Arm plans as latent debt

- **Date:** 2026-07-10
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Status:** Accepted. Resolves the ADR-033 firewall_threat_intel_hit contingency (the rule failed a second
  time on run 29134695521 with the same cross-workspace error, exactly as ADR-033 predicted) and records the
  Defender-plan deprecation audit that the run-2 failures forced.
- **Decision makers:** user, claude (architect)

**Context:**
The `platform/security` retry (run 29134695521) applied the ADR-033 fixes cleanly: the connector 401s are
gone (dc-aad and dc-ti gated off), and the "workspace not onboarded" automation-rule 400 cleared because
onboarding propagated from the partial apply. Four issues remained. Two require design decisions (this ADR);
two are execution mechanics recorded in `docs/preclearance/platform-security.md` (the SqlServerVirtualMachines
state import and the pricing-write parallelism).

Verified facts this session:
- **firewall_threat_intel_hit (second failure, same error):** 400 "Could not locate all the workspaces in
  your query." This is the only one of the 11 analytics rules that uses a cross-workspace reference. Its KQL
  (via `local.platform_law_workspace_function`) is
  `workspace('law-platform-<org>-<env>').AzureDiagnostics | ...` - a **name-only** reference to the platform
  LAW, which lives in the **management** subscription while the Sentinel rule is created against the security
  workspace in the **security** subscription. Name-only `workspace('name')` resolution does not resolve
  cross-subscription at rule-create validation time, so the create fails deterministically. The design reason
  the rule is cross-workspace is intentional (sentinel.tf DEVIATION header): hub Azure Firewall diagnostics
  land in the platform LAW, and the rule reads them from there to avoid duplicate ingestion cost. The other 10
  scheduled rules reference tables in their own (security) workspace with no `workspace()` prefix and create
  fine even where the source table has no data yet.
- **Dns Defender plan deprecated:** `azurerm_security_center_subscription_pricing.extended["Dns"]` failed 400
  "The 'Dns' plan is deprecated and can no longer be enabled." Dns is live-Free on the security sub (it never
  landed), so removing it from config is a no-op against live state.
- **Defender-plan deprecation audit (done now, this session):** VERIFIED 2026-07-10 against the Defender for
  Cloud release notes ("Plan enablement API now blocks onboarding to five deprecated Defender plans,"
  July 5, 2026). The five plans blocked for **new** enablement are: Azure Kubernetes Service
  (`KubernetesService`), Azure Container Registry (`ContainerRegistry`), Key Vault (`KeyVaults`), DNS (`Dns`),
  and Azure Resource Manager (`Arm`). Mapping to this root:
  - `Dns` (in `defender_extended_plans`, defender.tf) - deprecated AND live-Free -> actively failing -> remove.
  - `KeyVaults` and `Arm` (in `defender_basic_plans`, main.tf) - **also deprecated**, but both are live-Standard
    and already reconciled in Terraform state (they were created in the run-1 partial apply before the block
    matters to us; run 2 reported no error on them). The block applies to **new enablement only**; existing
    enabled plans keep working, so they do **not** block the next apply. They are latent debt: any future
    re-PUT (config change, or a state drift that makes Terraform try to re-create them like
    SqlServerVirtualMachines drifted) would hit the same deprecation block.
  - `KubernetesService` and `ContainerRegistry` - deprecated but **not used** here (we use `Containers`,
    which supersedes them). No action.
  - `AppServices`, `SqlServers`, `SqlServerVirtualMachines`, `Containers`, `OpenSourceRelationalDatabases`,
    `CloudPosture`, `VirtualMachines`, `StorageAccounts` - current/supported. No action.
  This is a process gap: the pre-clearance deprecation audit (step 3d) was run for the policy/module lane but
  the Defender-plan list was not re-audited against the release notes before run 1.

**Decision:**
1. **Gate firewall_threat_intel_hit off** behind a new `var.enable_firewall_ti_rule` (bool, default `false`)
   in `platform/security`. Rather than gate a whole resource, filter the single map key out of the
   `azurerm_sentinel_alert_rule_scheduled.this` `for_each` when the flag is false. The
   `firewall_threat_intel_hit` entry stays in `local.analytics_rules` (pre-staged), so re-enabling is a flag
   flip **plus** the two follow-ups below. The other 10 scheduled rules and the MDC incident rule are
   unaffected.
2. **Remove `Dns`** from the `defender_extended_plans` set in defender.tf. Dns is live-Free and never entered
   state, so the removal is a no-op against live and state (no destroy).
3. **Hold `KeyVaults` and `Arm` as-is** (do not remove, do not re-PUT). They are live-Standard, in state, and
   do not block the next apply. Removing them from config would issue a DELETE that disables Defender for Key
   Vault / Resource Manager protection - a real security-posture downgrade, out of scope for this retry. Add a
   code comment marking both deprecated so no one re-triggers a PUT, and track the migration decision as an
   open question (OQ-028).

**Alternatives considered:**
- **firewall_threat_intel_hit: fully-qualify the cross-workspace reference** to the platform LAW ARM resource
  ID (the ADR-033 contingency) - rejected for this retry: it requires threading the management-sub platform
  LAW resource ID into a root that is deliberately isolated from the platform workspace (main.tf), AND the
  scheduled rule needs the Sentinel workspace's query identity to hold Log Analytics Reader on the platform
  LAW or it creates but fails at runtime. Two new moving parts (cross-root input + cross-workspace RBAC) on a
  tight retry budget is the riskiest path; parked as the re-enable design in OQ-027.
- **firewall_threat_intel_hit: rewrite to single-workspace** - rejected: the firewall logs are not in the
  security workspace by design (cost), so there is nothing single-workspace to query.
- **firewall_threat_intel_hit: delete the rule** - rejected: loses a pre-staged detection; gating keeps it for
  a persistent environment, consistent with the ADR-031/032/033 pre-staged-behind-a-flag pattern.
- **KeyVaults + Arm: remove from config now** - rejected: issues a DELETE that downgrades security posture and
  is out of scope for the retry; they are not blocking. Deferred to OQ-028.
- **KeyVaults + Arm: add `lifecycle { ignore_changes }` or similar to freeze them** - rejected as unnecessary:
  state matches live (tier Standard), so no PUT is planned; the real risk is drift, which is handled by the
  pre-apply plan-scan guard in the pre-clearance doc (import, never re-create, any drifted deprecated plan).

**Consequences:**
- Positive: the third apply's Sentinel and Defender lanes reduce to resources that create cleanly. The
  recurring cross-workspace 400 is removed deterministically; the deprecated Dns PUT is gone; the newly found
  KeyVaults/Arm deprecation is documented before it can bite. 10 of 11 scheduled rules, the MDC incident rule,
  watchlists, and all supported Defender plans stand.
- Negative / trade-offs: no firewall threat-intel cross-workspace detection until it is re-enabled with a
  fully-qualified reference plus cross-workspace RBAC (OQ-027). A third default-false feature flag now lives in
  `platform/security`. KeyVaults and Arm remain on deprecated plans (latent debt, OQ-028). The Defender-plan
  deprecation audit is now a required pre-clearance step for any root that sets pricing plans.
- Follow-ups required: (1) **OQ-027** - re-enable firewall_threat_intel_hit (fully-qualified platform LAW
  reference + Sentinel cross-workspace RBAC) for a persistent environment. (2) **OQ-028** - migrate KeyVaults
  and Arm off the deprecated plans (remove from IaC vs keep until Microsoft enforces retirement). (3)
  Execution mechanics in `docs/preclearance/platform-security.md` run-2 section: import
  `azurerm_security_center_subscription_pricing.extended["SqlServerVirtualMachines"]` (devsecops) and reduce
  pricing-write parallelism on the security apply (devsecops). (4) Add "re-audit the Defender pricing-plan list
  against the current release notes" to the pre-clearance deprecation-audit step for any root that enables
  Defender plans.

### ADR-033: Gate the tenant-scoped Sentinel data connectors (Entra ID + Threat Intelligence) off - both need a Security Administrator directory role the CI SP lacks

- **Date:** 2026-07-10
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Status:** Accepted. Extends the same tenant-permission gating rationale already applied to
  `enable_aad_diagnostics` and `enable_ueba` (recorded in `envs/poc.tfvars` and
  `docs/preclearance/platform-security.md` prereq 1) to the two tenant-scoped Sentinel data connectors.
- **Decision makers:** user, claude (architect)

**Context:**
The `platform/security` apply (run 29133588369) partially applied. LAW, Key Vault, Event Hub, Defender
pricing plans, and regulatory compliance landed. Among the failures were the two **tenant-scoped** Sentinel
data connectors:
- `azurerm_sentinel_data_connector_azure_active_directory.this` (dc-aad) failed **401 Access denied**.
- `azurerm_sentinel_data_connector_threat_intelligence.this` (dc-ti) failed **401 Access denied**.

Verified facts this session:
- Both failing connectors carry `tenant_id` and enable a **tenant-level** data source (Entra
  Sign-in/Audit logs for dc-aad; the Microsoft Threat Intelligence indicator feed for dc-ti). The
  **subscription-scoped** connector `azurerm_sentinel_data_connector_azure_security_center.this` (dc-mdc,
  carries `subscription_id`) **succeeded** in the same apply. The clean split is: sub-scoped connector works
  under the SP's Contributor; tenant-scoped connectors need an Entra directory role the SP does not hold.
- This is the **same permission class** already gated for `enable_aad_diagnostics`
  (`azurerm_monitor_aad_diagnostic_setting`) and `enable_ueba` (the azapi Sentinel settings writes): all need
  **Security Administrator** (or Global Administrator) in Entra, which the CI OIDC SP does not hold. See
  `docs/preclearance/platform-security.md` prereq 1.
- A **401 is an authorization failure, not a propagation lag.** A rerun does not clear a standing
  directory-role gap, so dc-aad and dc-ti will fail identically on every retry until the role is granted.

**Decision:**
Gate both tenant-scoped Sentinel data connectors behind two new default-`false` feature flags in
`platform/security`:
- `var.enable_aad_connector` (bool, default `false`) gates `azurerm_sentinel_data_connector_azure_active_directory.this`.
- `var.enable_ti_connector` (bool, default `false`) gates `azurerm_sentinel_data_connector_threat_intelligence.this`.

Each connector takes `count = var.<flag> ? 1 : 0`. The two `outputs.tf` entries that reference them
(`aad`, `ti` in `sentinel_data_connector_ids`) convert to the `one(...[*].id)` pattern already used for the
count-gated MDE connector. Two separate flags (not one combined flag) because the connectors represent
different data sources and different downstream re-enable triggers; they may be turned on independently. The
sub-scoped dc-mdc connector stays ungated and is unaffected.

The two Sentinel resources that got **400-class** errors in the same apply -
`azurerm_sentinel_alert_rule_scheduled.this["firewall_threat_intel_hit"]` (400 "Could not locate all the
workspaces in your query") and `azurerm_sentinel_automation_rule.ti_enrichment_tag` (400 "Workspace not
onboarded to Microsoft Sentinel") - are **NOT gated**. Neither reads the ThreatIntelligenceIndicator table
that dc-ti populates: the firewall rule cross-workspace-queries the platform LAW for Azure Firewall
threat-intel block logs, and the automation rule only tags incidents by severity. They have no data
dependency on dc-ti, so gating dc-ti does not force gating them. Their 400s are onboarding-propagation /
cross-workspace-validation timing, not permission or code faults (see Consequences for the retry rationale).

**Alternatives considered:**
- Grant a time-boxed Security Administrator directory role to the CI SP and keep both connectors enabled -
  rejected for this retry: same operator-action deferral already chosen for `enable_aad_diagnostics` and
  `enable_ueba`; enabling only these two connectors would be inconsistent, and the directory-role grant is a
  standing follow-up, not a blocker for landing the rest of the root. The flags make the connectors a
  one-variable flip once the role exists.
- One combined flag for both connectors - rejected: dc-aad (Entra sign-in/audit, needs Entra ID P1/P2) and
  dc-ti (Microsoft TI feed) have different licensing and different re-enable triggers; a shared flag would
  couple two unrelated re-enable decisions.
- Rerun dc-ti as-is (treat the 401 as transient) - rejected: a 401 is authorization, not propagation; a
  rerun cannot clear a missing directory role and would just burn a retry.
- Also gate the firewall_threat_intel_hit alert rule and ti_enrichment_tag automation rule - rejected:
  neither consumes dc-ti data, so they are not blocked by the connector being off; their failures are timing,
  and gating working detections that a retry is expected to clear would remove security value for no reason.

**Consequences:**
- Positive: the retry's Sentinel lane reduces to resources the SP is actually authorized to create. The two
  tenant-scoped connectors are captured as scoped, documented gates consistent with the existing
  `enable_aad_diagnostics` / `enable_ueba` pattern, not blind retries against a permission the SP lacks. The
  MDE connector, the sub-scoped MDC connector, the 10 scheduled analytics rules, watchlists, and the MDC
  high-severity incident rule are unaffected.
- Negative / trade-offs: no Entra ID sign-in/audit ingestion and no Microsoft TI indicator feed into the
  Security workspace until the Security Administrator role is granted and the flags are flipped. Two more
  default-false feature flags now live in `platform/security`. Detections that would benefit from TI
  enrichment (the ti_enrichment_tag automation rule still tags, but no TI indicators are ingested to enrich
  against) run without that feed until re-enable.
- Follow-ups required: (1) When the time-boxed Security Administrator grant is arranged (the same operator
  action that unblocks `enable_aad_diagnostics` and `enable_ueba`), flip `enable_aad_connector`,
  `enable_ti_connector`, `enable_aad_diagnostics`, and `enable_ueba` to `true` in one later pass and re-apply.
  Tracked in `docs/preclearance/platform-security.md` (apply-time findings, Class B). (2) Contingency for the
  firewall_threat_intel_hit rule: if it fails a SECOND time on the retry with the same "Could not locate all
  the workspaces" error, the root cause is name-only cross-workspace resolution
  (`workspace('law-platform-globaris-poc')`), not timing; the durable fix is to switch that KQL reference to
  the fully-qualified platform LAW ARM resource ID (which requires threading the platform LAW resource ID
  into this root as a new input). Do not blind-retry that rule more than once.

### ADR-032: Gate the corp-spoke App Service tier off - `landingzones` subscription dedicated App Service compute quota is 0 (offer cap)

- **Date:** 2026-07-10
- **Section:** 9 (Landing Zone Spokes)
- **Status:** Accepted.
- **Decision makers:** user, claude (architect)

**Context:**
Deploying the corp landing-zone spokes. After the azapi-anchor and zone-balancing fixes cleared the prior
errors, the corp-a1 apply (deploy run 29126639533) failed on `module.app_service_plan` with
`400 Unauthorized / ExtendedCode 70007: "Operation cannot be completed without additional quota. Current
Limit (Total VMs): 0, Amount required: 3."` Verified facts this session:
- This is the **dedicated App Service compute quota** (provider `Microsoft.Web`, the reserved VM instances
  behind a Basic+ App Service Plan), **not** the IaaS Compute vCPU quota. Two portal quota exports for the
  **Compute** provider confirm the `landingzones` subscription has healthy VM/vCPU quota in East US 2 (Total
  Regional vCPUs limit 10, VMs limit 25000, every family limit 10, 0 usage). So this is **not** a used-up
  quota - it is an **offer cap** on dedicated App Service (Basic and above), the same class of restriction as
  the Azure SQL `ProvisioningDisabled` in ADR-031.
- Serverless / PaaS-shared compute is **unaffected**: Consumption / Flex Consumption Functions and Static Web
  Apps do not draw on the dedicated App Service VM quota. online-p1's Static Web App provisions fine; it has
  no App Service Plan.
- The failing resources are the App Service tier only: `module.app_service_plan` (the
  `Microsoft.Web/serverFarms` dedicated plan) and `module.app_service` (the site). The `snet-integration`
  subnet and its `Microsoft.Web/serverFarms` delegation are topology, not compute, and are unaffected.

**Decision:**
Gate the corp App Service tier behind a new `var.enable_app_service` (bool, default `false`) in
`landing-zones/corp-a1` and `landing-zones/corp-a2`. The flag gates `module "app_service"` and
`module "app_service_plan"`; the App Service outputs return `null` via `one(...)` when the tier is off. The
`snet-integration` subnet and its `Microsoft.Web/serverFarms` delegation **stay** (pre-staged topology), so
re-enabling is a single-variable flip. Re-enable by setting `enable_app_service = true` once an unrestricted
subscription is available or a quota/offer exception lifts the cap.

Broader finding: the `landingzones` subscription is **compute-restricted for dedicated / reserved resources.**
This ADR (dedicated App Service) and ADR-031 (Azure SQL) together establish that **both** dedicated App
Service and SQL are offer-capped in this subscription, while **serverless and PaaS-shared** compute works. Any
future workload tier in these spokes should assume dedicated/reserved SKUs are unavailable here.

**Alternatives considered:**
- Request a quota increase on the dedicated App Service offer - rejected: offer-cap increases on sponsored /
  restricted subscription types are commonly slow or denied outright, which does not fit the planned
  end-of-week teardown; the tier would stay down while the request is pending.
- Redesign the workload tier to serverless (Flex Consumption Functions, plus serverless alternatives that fit
  the offer) - rejected: that is a real application redesign, out of scope for a POC being torn down at the end
  of the week. Parked in OQ-026 for a persistent environment.

**Consequences:**
- Positive: the corp spokes stand as **network landing zones** - VNet, hub peering, NSG, UDR-to-firewall,
  Recovery Services Vault, VNet flow logs, and policy compliance/exemptions all provision. The running App
  Service and SQL workloads (POC filler, not the landing-zone story) are the only things gated off. The
  failure is captured as a scoped, documented gate rather than a blind retry against a capability the
  subscription does not have.
- Negative / trade-offs: no App Service plan or site exists in the corp spokes until an unrestricted
  subscription or an offer exception is available and `enable_app_service` is flipped. Combined with ADR-031,
  the corp spoke's "app + database" workload story is fully pre-staged-off; the spokes demonstrate topology and
  governance, not a running workload. A second default-false feature flag now lives in both corp landing-zone
  roots.
- Follow-ups required: **OQ-026** tracks the persistent-environment path (request quota / relocate to an
  unrestricted subscription vs redesign to serverless). Non-blocking and likely moot given the planned
  teardown. See also **ADR-031** (the SQL half of the same offer-cap finding) and **OQ-025** (SQL re-enable
  trigger).

### ADR-031: Gate the corp-spoke SQL tier off - Azure SQL `ProvisioningDisabled` in the `landingzones` subscription region

- **Date:** 2026-07-10
- **Section:** 9 (Landing Zone Spokes)
- **Status:** Accepted.
- **Decision makers:** user, claude (architect)

**Context:**
Deploying the corp landing-zone spokes. The corp-a1 apply (deploy run 29120479723) failed on
`azurerm_mssql_server.this` with `Status: ProvisioningDisabled` and the message "Provisioning is restricted
in this region. Please choose a different region...". Verified facts this session:
- This is a **subscription/region capability restriction, not a code or design fault.** Azure SQL logical
  server provisioning is disabled for the `landingzones` subscription in **eastus2** (corp-a1's region), and
  is expected to be disabled in **centralus** (corp-a2's region) for the same reason. This restriction is
  common on sponsored / Visual Studio subscription types and is imposed by Azure capacity/policy, not by our
  Terraform.
- The failing resources are the SQL tier only: `azurerm_mssql_server.this` (with its Entra admin nested
  block), `azurerm_mssql_database.app`, and `azurerm_private_endpoint.sql` (with its SQL DNS zone group). The
  corp App Service has **no** dependency on the SQL server, so it is not affected. online-p1 has no SQL tier.

**Decision:**
Gate the entire corp SQL tier behind a new `var.enable_sql` (bool, default `false`) in `landing-zones/corp-a1`
and `landing-zones/corp-a2`. The flag gates `random_id.sql_suffix`, `azurerm_mssql_server.this`,
`azurerm_mssql_database.app`, and `azurerm_private_endpoint.sql` (including its SQL DNS zone group nested
block). The 5 (corp-a1) / 4 (corp-a2) SQL-related outputs return `null` via `one(...)` when the tier is off.
The rest of the spoke stands. The pre-staged SQL wiring stays in place: the SQL private DNS zone data source
plus its vnet link in `dns_links.tf` are **not** provisioning-dependent, so they remain so a future re-enable
is a single-variable flip. Re-enable by setting `enable_sql = true` once an allowed region/subscription is
available or a support-request exception lifts the restriction.

**Alternatives considered:**
- Move the SQL tier to an Azure region where provisioning is allowed - rejected: introduces cross-region
  fragmentation (SQL split from the rest of the spoke, its VNet, and its private endpoint subnet), and corp-a2
  in centralus is expected to hit the same restriction, so it does not generalise. Not worth the topology
  distortion for a POC.
- Raise an Azure support-request exception to lift the regional provisioning restriction - rejected: too slow
  for the planned end-of-week teardown timeline; the tier would still be down while the request is pending.

**Consequences:**
- Positive: the full corp spoke topology stands minus the SQL database - VNet, peering, App Service, Recovery
  Services Vault, NSG, flow logs, and the PE subnet all provision. The App Service has no SQL dependency so it
  is unaffected. The pre-staged SQL DNS wiring (zone data source + vnet link) remains, so re-enabling is a
  one-variable flip. The failure is captured as a scoped, documented gate rather than silent debt or a blind
  retry against a capability the subscription does not have.
- Negative / trade-offs: no SQL server or database exists in the corp spokes until an allowed
  region/subscription is available and `enable_sql` is flipped; the spoke's "app + database" story is
  app-only until then. A default-false feature flag now lives in both corp landing-zone roots.
- Follow-ups required: (1) **OQ-025** tracks the re-enable trigger (which allowed region or support exception,
  and relocate-vs-wait), non-blocking and likely moot given the planned teardown. (2) **.tf comment cleanup
  (do not fix now, next touch of those files):** `landing-zones/corp-a1/policy_exemptions.tf:38-39` and
  `landing-zones/corp-a2/policy_exemptions.tf:28` still describe `SqlServerDenyPaasPublicIP` as "keeps
  governing the (already-private) SQL server" - now moot while `enable_sql = false` because no SQL server
  exists. The implementer should refresh those comments the next time those files are edited.

### ADR-030: Gate the geo_block Conditional Access policy off by default - Graph 1040 named-location reference failure persists after the ADR-029 fixes

- **Date:** 2026-07-10
- **Section:** 5 (azuread Conditional Access) / 8 (Identity)
- **Status:** Accepted. Amends the geo_block prediction in ADR-029 Part C (proven wrong - see Context).
- **Decision makers:** user, claude (architect)

**Context:**
ADR-029 Part C predicted geo_block would succeed on the recovery apply for two independent reasons: (1) the
post-import apply is short, so the OIDC client assertion stays valid; (2) the approved_countries named
location is days old, so error 1040 could not be propagation lag. **That prediction was WRONG.**

Evidence gathered this session (all verified):
- In deploy run 29068343843 (the recovery apply, ~34 min total), `azuread_conditional_access_policy.geo_block`
  was attempted about 1 minute into the apply - the OIDC token was unambiguously valid at that point - and
  still failed with Graph `400 / 1040 "NamedLocation ... does not exist in the directory."` So the cause is
  NOT token expiry. (ADR-029 conflated two failure modes: run 5's trailing-op failure was AADSTS700024 token
  expiry, but the 1040 itself is a separate, reproducible reference failure.) This is roughly the 5th
  recurrence of 1040 on geo_block.
- The named location DOES exist and is readable: a live Graph GET on its object id (created 2026-07-08)
  returns the object, yet the conditionalAccessPolicies create endpoint reports it does not exist. So this is
  neither "location missing" nor simple replication lag on a fresh object.
- Leading (unproven) hypothesis for a future root-cause pass: the policy references the named location by its
  full resource path (`/identity/conditionalAccess/namedLocations/<id>`) where the CA policy store expects the
  bare object id (or vice versa); OR a Graph CA-store consistency issue distinct from ordinary propagation.
  Secondary data-quality smell: the named location displayName came back with a replacement character where an
  em dash was likely intended - worth checking during diagnosis.

**Decision:**
Gate `azuread_conditional_access_policy.geo_block` behind a new `var.enable_geo_block_ca_policy`
(default `false`), so the identity root applies green with **7 of 8** CA policies. `time_sleep.wait_named_location`
(ADR-028) is gated on the same variable - it exists only to serialise geo_block behind the named location.
`azuread_named_location.approved_countries` STAYS created unconditionally: it is harmless, intended geo
configuration and is the object a re-enabled geo_block will reference. Re-enable by setting
`enable_geo_block_ca_policy = true` once the reference bug is root-caused.

Justification: **no enforcement or posture is lost by deferring geo_block.** All 8 CA policies in this POC are
report-only (they enforce nothing), and geo_block is 1 of 8. Deferring its CREATION while its named location
stays in place costs nothing operationally and unblocks a green identity apply, which the 4-fail bar makes the
priority. This is a scoped defer plus a bounded diagnosis follow-up, explicitly NOT another blind retry.

**Alternatives considered:**
- Keep retrying geo_block as-is - rejected: 5 identical 1040 failures make a 6th deterministic, and it keeps
  the whole identity root red for one report-only policy.
- Blind-add more `time_sleep` / propagation wait - rejected: the location is days old and a live GET resolves
  it, so this is not propagation; more sleep cannot fix a reference-format or CA-store-consistency bug.
- Speculatively switch geo_block's named-location reference (bare id vs full path) in this pass - rejected as
  premature: the correct reference form is exactly what the diagnosis pass must establish; changing it blind
  risks a 6th failure and burns the failure budget. Park it as the hypothesis to test (OQ-023).
- Delete and recreate the named location - rejected: it resolves on GET, so recreating it is unlikely to
  change the create-endpoint behaviour and only adds churn.

**Consequences:**
- Positive: identity root applies green (7/8 CA policies, all report-only); no posture lost; the named
  location stays in place so re-enabling is a one-variable flip; the failure is captured as a bounded
  diagnosis task, not carried as silent debt.
- Negative / trade-offs: geo_block does not exist in the directory until the reference bug is root-caused and
  the variable is flipped; the "8 CA policies" story is 7/8 until then (documented). A default-false feature
  flag now lives in the identity root.
- Follow-ups required: (1) **OQ-023** tracks the bounded named-location-reference diagnosis (test the
  full-path-vs-bare-id hypothesis and the CA-store-consistency angle; check the displayName
  replacement-character smell) and the re-enable via `enable_geo_block_ca_policy = true`; (2)
  `docs/preclearance/platform-identity.md` records geo_block as deferred (post-recovery addendum).

### ADR-029: Entra DS recovery - restore the default NSG inbound rules (AADDS104 fix), config-driven import of the built-but-unstated managed domain, and OIDC-token-expiry-on-long-apply mitigation

- **Date:** 2026-07-10
- **Section:** 8 (Identity subscription, Entra DS) / 5 (azuread Conditional Access) / 10 (CI auth)
- **Status:** Accepted
- **Decision makers:** user (mandated systemic fix after the 4-fail bar), claude (architect)

**Context:**
The 5th platform/identity apply (run 29055619749) failed after the ADR-028 exemption had already done its
job. Evidence that ADR-028 worked: the managed domain was actually built in Azure this time (the
service-created Standard PIP was admitted, `provisioningState: Succeeded`, replica set `Running`, one DC IP
`10.2.0.4`). The run then produced three errors, with a single primary root cause and two consequences.

Primary root cause - **AADDS104 CRITICAL health alert "The managed domain is experiencing a network
error"** (raised 2026-07-10 01:25 UTC, replica set East US 2 / vnet-identity-globaris-poc / snet-aadds).
Live network evidence gathered 2026-07-10 via az: `snet-aadds` has NSG `nsg-identity-aadds-globaris-poc`
and **routeTable = null** (no UDR, so the UDR branch of AADDS104 is ruled out - it is the NSG). The NSG's
only two custom rules are `Allow-AADDS-Management-5986` @301 (Allow TCP 5986 from the
`AzureActiveDirectoryDomainServices` service tag) and `Deny-All-Inbound` @4000 (Deny * / * / *).

The `Deny-All-Inbound` @4000 is the defect, now confirmed against MS Learn (not taken on faith):
- The AADDS104 troubleshooting article (learn.microsoft.com, entra/identity/domain-services/alert-nsg,
  reviewed 2026-07-10) lists the default inbound rules the managed domain relies on:
  `AllowPSRemoting` 5986 @301 (from `AzureActiveDirectoryDomainServices`), optional `AllowRD` 3389 @201
  (from `CorpNetSaw`), **`AllVnetInBound` Any @65000 (from `VirtualNetwork`)**, **`AllowAzureLoadBalancerInBound`
  Any @65001 (from `AzureLoadBalancer`)**, and `DenyAllInBound` Any @65500.
- The network-considerations article (entra/identity/domain-services/network-considerations, reviewed
  2026-07-10) is explicit: "Domain Services also relies on the Default Security rules AllowVnetInBound and
  AllowAzureLoadBalancerInBound." AllowVnetInBound lets the two DCs communicate and replicate and lets
  domain members join. AllowAzureLoadBalancerInBound is "required so that the service can properly
  communicate over the loadbalancer to manage the DCs." The domain sits behind an internal Standard SKU
  load balancer, and the platform health probe source is `AzureLoadBalancer` (168.63.129.16).
- NSG rules evaluate lowest-priority-number first. Our custom `Deny-All-Inbound` @4000 sits ABOVE (numerically
  below) both required defaults (`AllVnetInBound` @65000 and `AllowAzureLoadBalancerInBound` @65001), so it
  wins and blocks both intra-VNet DC replication and the load-balancer management/health path. The single
  5986 management allow is not sufficient. Result: Microsoft cannot reach the DCs, the second DC never
  becomes reachable, and AADDS104 fires. The network-considerations article warns directly: "Don't create
  or use an existing network security group with your own custom rules"; the alert-nsg article says to
  "delete any custom rules that block required traffic."

Consequence 1 - **the domain create timed out (`waiting for both domain controllers to become available ...
last state 'pending', 2h11m46s`).** This is create-only wait behaviour of
`azurerm_active_directory_domain_service` (provider docs confirm create defaults to a 3h timeout that
"accommodates the lengthy provisioning process ... for domain controller infrastructure"). Because
AADDS104 blocked the 2nd DC, the wait never returned and the create errored during polling. IMPORTANT STATE
FACT: the domain exists in Azure but is NOT in Terraform state (the provider records the ID only after the
create's polling returns). A plain rerun hits azurerm's requires-import guard ("already exists") and fails
again.

Consequence 2 - **`azuread_conditional_access_policy.geo_block` failed 400/1040 (named-location), and the
run surfaced `AADSTS700024: Client assertion is not within its valid time range`** (assertion valid
22:49:19Z to 22:54:19Z; the trailing Graph ops ran at 01:55:24Z). The GitHub OIDC federated assertion
(~5 min) and its derived access tokens (~1h) do not survive a 3h apply. The 1040 "named location not found"
is NOT propagation lag: the named location has existed since 2026-07-08 (days old, well past the Graph
replication window that ADR-028's `time_sleep.wait_named_location` guards). The true blocker was the expired
client assertion - the azuread/Graph operations at the tail of a multi-hour apply could no longer
authenticate. This is architectural: the identity root co-locates a 1-3h AADDS create with azuread
Graph/Conditional-Access operations in one CI apply. (The azurerm/ARM operations survived the long apply -
the domain was built - so the exposure is specifically the azuread provider's tail-end Graph calls.)

**Decision:**

**Part A - NSG: remove the custom `Deny-All-Inbound` rule and fall back to the Azure default rules
(Option a).** Correct the `azurerm_network_security_group.entra_ds` rule set to:
- KEEP `Allow-AADDS-Management-5986` @301 (Allow TCP 5986 from `AzureActiveDirectoryDomainServices`). This
  equals Microsoft's own `AllowPSRemoting` @301.
- DELETE the `Deny-All-Inbound` @4000 rule entirely.
- The Azure default rules then govern, exactly as Microsoft requires: `AllowVnetInBound` @65000,
  `AllowAzureLoadBalancerInBound` @65001, and `DenyAllInBound` @65500. Internet inbound remains denied by the
  default @65500, so removing our custom deny loses no protection. The resulting NSG reproduces Microsoft's
  documented default managed-domain NSG (minus the optional `CorpNetSaw` RDP rule, which is deny-by-default
  and not needed).
This does not trip policy: `Deny-Subnet-Without-Nsg` is still satisfied (the NSG still exists on the subnet),
and `Deny-MgmtPorts-Internet` is satisfied (the 5986 rule sources a service tag, not Internet). No ALZ
policy requires a custom explicit deny-all rule.

**Part B - config-driven import of the built-but-unstated domain.** The domain exists in Azure but not in
state; a rerun would fail the requires-import guard. Recover it with a Terraform **`import {}` block** (config-
driven import, supported since Terraform 1.5; the root pins `required_version >= 1.9`, so this is available)
processed during the normal CI plan/apply - NO local `terraform import`, respecting the CI-only-apply rule.
CRITICAL FORMAT DETAIL (verified against the provider import docs, v4.71.0): the import ID for
`azurerm_active_directory_domain_service` is a **composite**, not the plain resource ID -
`<domain resource ID>/initialReplicaSetId/<initial replica set GUID>`. A plain resource-ID import would fail.
The initial replica set GUID must be read from the live domain (portal, or
`az resource show --ids <domain-id> --query "properties.replicaSets[0].replicaSetId"`) and supplied to the
cloud-engineer; it is implementation detail, not committed prose. After import, the domain is in state; the
create-wait (a create-only operation) is never re-entered, so subsequent plans do a Read (GET, seconds) and
show 0 changes on the domain. The 2nd DC IP populating after the NSG heals lands in the computed
`domain_controller_ip_addresses` of the replica set, so it causes no config diff (benign).

**Part C - OIDC token expiry on long applies: import is the fix for the POC now; a durable greenfield fix
is tracked, not built.** Once the domain is imported, the identity root has no remaining multi-hour long
pole, so every future apply is short and the OIDC assertion/token never expires. `geo_block` then succeeds
on the recovery apply for two independent reasons: the apply is short (valid token) and the named location
is days old (resolves immediately). Keep `time_sleep.wait_named_location` (ADR-028) - it is harmless and
keeps the greenfield DEPLOYMENT.md path deterministic. Import ALONE suffices for the POC because the domain
is created once and thereafter only refreshed. Splitting the identity root into a Phase-1 (network + AADDS)
and Phase-2 (azuread CA) apply, or adding a CI job-level re-auth for the azuread provider, is the durable
fix for a from-scratch greenfield rebuild (where the 3h create would again precede the Graph ops), but that
is a non-trivial refactor (new root, state migration, cross-root data passing) and speculative scope for a
POC that must go green. Tracked as OQ-022. platform/identity stays CI-only.

**Ordered recovery runbook:**
1. Cloud-engineer (code, `platform/identity`, one batch, code-reviewer gates):
   (a) remove the `Deny-All-Inbound` @4000 `security_rule` from `azurerm_network_security_group.entra_ds`
   and update the NSG header comment to cite the alert-nsg / network-considerations requirement that the
   default AllowVnetInBound + AllowAzureLoadBalancerInBound rules must remain in effect and that a custom
   low-priority deny-all breaks AADDS; (b) add an `import {}` block with
   `to = azurerm_active_directory_domain_service.this[0]` and `id = "<composite import ID>"` (domain
   resource ID + `/initialReplicaSetId/<replica-set GUID>` obtained from the operator/az).
2. Operator supplies the initial replica set GUID (portal or az) to the cloud-engineer for the import ID.
3. CI plan: expect the NSG updated in place (1 rule removed), the domain IMPORTED (plan shows import, not
   create), and `geo_block` created (1 to add); 0 destroy. Gate: verify the plan shows "import" (not
   "create") for the domain and the NSG diff removes only the deny rule.
4. CI apply: NSG deny rule removed, domain imported into state, geo_block created. The apply is short (no
   multi-hour create-wait), so the OIDC token stays valid.
5. Post-apply verification (operator, az): AADDS104 clears and the domain health returns to green, and the
   2nd DC IP appears (replica set shows two DC IPs). Per the alert-nsg article, the managed domain's health
   auto-updates within ~2 hours of the NSG fix. Verify via `az ad ds show` / the portal health blade.
6. Post-apply cleanup: once the domain is healthy, REMOVE the two temp directory roles (Application
   Administrator + Groups Administrator) from the CI SP (standing follow-up from ADR-028 / the 2026-07-08
   session).
7. Confirm steady state: a subsequent CI plan shows 0 changes on the domain (Read-only refresh), proving the
   token-expiry exposure is closed for the POC lifetime.

Sequencing note (why NSG-fix and import ship together, not NSG-first-then-import): an NSG-only apply is not
viable while the domain is in config but not in state - the domain resource would attempt a CREATE and fail
the requires-import guard. The `import {}` block must therefore ship in the same change as the NSG fix so
the domain resolves to import, not create. This is safe: import is a metadata read with no create-wait, so
it succeeds even while the 2nd DC is still healing, and the heal completes asynchronously afterward (benign
computed-attribute update). Healing before import is not achievable without a local import or a -target,
both of which the CI-only rule forbids.

**Alternatives considered:**
- NSG Option (b): keep a custom `Deny-All-Inbound` and add explicit Allow-inbound rules for `VirtualNetwork`
  and `AzureLoadBalancer` (plus 5986) above priority 4000 - rejected: it merely reproduces the Azure default
  rules with two extra self-managed rules, adds maintenance surface, and gives zero additional protection
  (Internet is already denied at the default @65500). MS guidance names the default rules as the required
  ones and says to remove custom rules that block them, so Option (a) is both simpler and canonical.
- Delete the failed domain and redeploy from scratch (the ADR-028 shell-delete pattern) - rejected here: in
  run 4 the object was a hollow shell (empty replica set); in run 5 the domain is genuinely built (Succeeded,
  replica set Running, a live DC). Deleting a real, healthy-after-NSG-fix managed domain to recreate it would
  incur another 1-3h create and re-expose the token-expiry problem. Import preserves the built domain.
- Split the identity root now (Phase 1 network+AADDS, Phase 2 azuread CA) - deferred (OQ-022): the durable
  greenfield fix, but a non-trivial refactor and speculative scope for the immediate recovery. Import alone
  closes the token-expiry for the POC.
- Blame propagation for geo_block and add more sleep - rejected: the named location is days old, so 1040 was
  not propagation; the real cause was the expired client assertion, fixed by the short (post-import) apply.

**Consequences:**
- Positive: AADDS104 is fixed at the IaC layer with the MS-canonical minimal NSG; the built domain is
  recovered into state without destroying it; every future apply is short, closing the OIDC-token-expiry
  exposure; geo_block succeeds; the greenfield-reproducibility gap is captured rather than silently carried.
- Negative / trade-offs: the subnet now relies on the Azure default rules for AllowVnetInBound /
  AllowAzureLoadBalancerInBound / DenyAllInBound rather than an explicit repo-authored deny (documented and
  MS-recommended, but the deny-all is now implicit at @65500). The import ID carries a live replica set GUID
  that must be fetched operationally. A from-scratch greenfield rebuild still hits the 3h create before the
  Graph ops until OQ-022 is addressed.
- Follow-ups required: (1) operator supplies the initial replica set GUID for the import ID; (2) post-apply,
  verify AADDS104 clears and the 2nd DC heals within ~2h; (3) remove the two temp directory roles from the CI
  SP after the domain is healthy; (4) OQ-022 tracks the durable greenfield token-expiry fix (root split or CI
  re-auth); (5) OQ-021 (unwired Deploy-Diag-LogsCat LAW parameter) and OQ-008 (standing Owner removal) are
  unchanged by this ADR.

**Addendum (2026-07-10, post-recovery-apply run 29068343843) - what actually happened vs the plan above.**
The core diagnosis held: the AADDS104 NSG deny-all was the root cause, and removing it healed the domain (the
2nd DC IP appeared). But three mechanisms played out differently in execution. Recorded here for accuracy; the
decision above is not rewritten.

1. **Recovery was `terraform untaint`, NOT the config-driven import.** The timed-out create did not leave the
   domain absent from state - it left it **tainted** in state (the provider had recorded the ID, then marked
   it tainted when the create-wait errored). Config-driven `import {}` is skipped for any resource already in
   state, so Part B's import block was a **no-op** and the plan fell through to a destructive **REPLACE**
   (create-new + destroy-old) of the live managed domain. The actual recovery mechanism was `terraform
   untaint` on the domain address, run as a new **CI-only `action=untaint`** path added to `deploy.yml` /
   `_tf-root.yml`, single-target-guarded (untaint is scoped to one resource address, never a whole root). The
   `import {}` block and the `aadds_import_replica_set_id` variable are retained but re-scoped to the
   **greenfield-redeploy adoption path only** (where the domain genuinely is built-but-unstated), not this
   recovery.

2. **A second ForceNew replace surfaced after untaint: `domain_configuration_type`.** Untaint cleared the
   taint, but the next plan still proposed a ForceNew replace because `domain_configuration_type` was unset in
   config (planned null) while Azure had defaulted it server-side to `"FullySynced"`. Fixed by pinning
   `domain_configuration_type = "FullySynced"` in the module call (committed 305757f). General lesson:
   `azurerm_active_directory_domain_service` has **Optional + ForceNew + not-Computed** arguments that Azure
   fills in server-side; any such argument must be pinned explicitly in config or every plan proposes a
   destructive replace.

3. **The AADDS post-deploy DNS step was missed and had to be done manually, now wired in IaC.** A managed
   domain requires the identity VNet's DNS servers to point at the two DC IPs, which are only knowable AFTER
   the domain exists. Our AVM VNet module call omitted `dns_servers`, so the operator set them manually in the
   portal to make the domain usable. This is now in IaC by passing the DC IPs through the AVM VNet module's
   `dns_servers` input. A separate `azapi_update_resource` to set VNet DNS was rejected: the AVM VNet module
   asserts `dhcpOptions = null` and would fight an out-of-band update, causing perpetual drift. Checklist gap
   recorded: **"AADDS post-deploy: identity VNet DNS -> DC IPs"** is now a required step in the identity
   pre-clearance / runbook.

Net: the domain is healthy and in clean steady state (untaint + FullySynced pin + DNS-in-IaC), and the NSG
diagnosis in the decision above stands. Only the recovery MECHANISM (untaint, not import) and the two
follow-on ForceNew / DNS details differed from the plan. geo_block, which Part C predicted would now succeed,
did NOT - see **ADR-030**.

### ADR-028: Resource-group-scoped policy exemption for Entra Domain Services vs the ALZ Deny-Public-IP assignment at the Identity MG

- **Date:** 2026-07-09
- **Section:** 8 (Identity subscription, Entra DS) / 2 (ALZ policy stack)
- **Status:** Accepted
- **Decision makers:** user (mandated systemic fix), claude (architect)

**Context:**
Deploy run 28978396902 (platform/identity, 4th apply) failed with the Entra DS managed domain reaching
terminal `Failed`: `ResourceActionsBlockedByPolicy - Unable to deploy network resources into
rg-identity-aadds-globaris-poc because there is a policy preventing this action`. Activity Log evidence
(captured live): the denied write was `Microsoft.Network/publicIPAddresses/aadds-...-pip` in
`rg-identity-aadds-globaris-poc`, and the caller was the Entra Domain Services service principal, NOT our
CI SP. The denying assignment is `Deny-Public-IP` at the `identity` MG (built-in definition
`6c112d4e-5bc7-47ae-a041-ea2d9dccd749` "Not allowed resource types", effect `Deny`,
`listOfResourceTypesNotAllowed = ["Microsoft.Network/publicIPAddresses"]`, enforcementMode `Default`,
verified live 2026-07-09). That assignment is the ALZ identity-archetype DEFAULT, deployed by our own
`platform/management-groups` root via avm-ptn-alz.

This is a structural collision, not a bug in either side:
- The managed domain's Standard SKU public IP is a MANDATORY service-created resource. MS Learn
  (entra/identity/domain-services/network-considerations, verified 2026-07-09) lists it in "Network
  resources used by Domain Services": "Domain Services communicates with the synchronization and
  management service using a Standard SKU public IP address", with an explicit warning not to delete or
  modify these resources. There is no SKU, argument, or configuration that suppresses it.
- Azure Policy `Deny` evaluates every write at the scope regardless of caller, so no permission grant to
  any principal can bypass it. The only levers are: exemption, enforcement mode, or parameter change.
- The AADDS-vs-identity-MG-deny collision is a known pattern class in the Enterprise-Scale/ALZ community
  (same family as the Enable-DDoS-VNET placeholder trap, ADR-026). No single canonical upstream issue was
  found to cite; the load-bearing verification here is the MS Learn requirement doc plus our live
  Activity Log and policy-assignment evidence.

**Decision:**
Create a **resource-group-scoped policy exemption** on `rg-identity-aadds-globaris-poc` for the
`Deny-Public-IP` assignment, category **Waiver**, managed as code in `platform/identity` with
`azurerm_resource_group_policy_exemption` (resource verified present in azurerm v4.71.0; args `name`,
`resource_group_id`, `policy_assignment_id`, `exemption_category` in {Waiver, Mitigated}, optional
`display_name`/`description`/`expires_on`). The exemption must be created BEFORE the domain create
retries, with a propagation wait between them. `Deny-Public-IP` stays fully enforced everywhere else in
the identity MG, including `rg-identity-network-globaris-poc`.

**Implementation brief (cloud-engineer lane, all in `platform/identity`):**
1. `providers.tf`: add `time = { source = "hashicorp/time", version = "~> 0.13.1" }` to
   required_providers (same pin as bootstrap). Regenerate the lock file for windows_amd64 + linux_amd64.
2. `domain-services.tf`, before the domain resource:
   - `resource "azurerm_resource_group_policy_exemption" "aadds_deny_public_ip"`:
     `provider = azurerm.identity`, `count = local.entra_ds_enabled ? 1 : 0`,
     `name = "exempt-deny-public-ip-aadds"`,
     `resource_group_id = azurerm_resource_group.identity_aadds[0].id`,
     `policy_assignment_id = "/providers/Microsoft.Management/managementGroups/identity/providers/Microsoft.Authorization/policyAssignments/Deny-Public-IP"`
     (literal string; the assignment is owned by the management-groups root, there is no cross-root
     output for it - add a comment saying so and referencing this ADR),
     `exemption_category = "Waiver"`, plus display_name/description referencing ADR-028. No
     `expires_on`: the PIP is required for the lifetime of the managed domain.
   - `resource "time_sleep" "wait_aadds_policy_exemption"`: `count` same gate,
     `create_duration = "300s"`, `depends_on = [azurerm_resource_group_policy_exemption.aadds_deny_public_ip]`.
     Rationale: exemptions propagate to policy-engine caches asynchronously; the domain deploys its
     network resources within the first minutes of provisioning, and a lost race costs another
     multi-hour failed provisioning cycle.
   - Add `time_sleep.wait_aadds_policy_exemption` to the domain resource's `depends_on` list.
3. `main.tf` (greenfield hardening, same time provider): `resource "time_sleep" "wait_named_location"`
   with `create_duration = "300s"` and `depends_on = [azuread_named_location.approved_countries]`; make
   `azuread_conditional_access_policy.geo_block` depend on it. This encodes the known Graph
   replication lag on FRESHLY created named locations (error 1040 fired 1 second after creation in run
   28978396902). For THIS tenant no wait is strictly needed anymore (the named location has existed
   since 2026-07-08, well past the lag window; a plain rerun clears geo_block), but the sleep makes the
   greenfield DEPLOYMENT.md path deterministic. It only costs 5 minutes when the named location is
   newly created.
4. **Manual pre-apply step (operator, az CLI): delete the failed managed-domain shell.** The failed
   create left a hollow `Microsoft.AAD/domainServices` object (ARM envelope `provisioningState:
   Succeeded` but replica set empty - no subnet, no DC IPs, verified live 2026-07-09). It is NOT in
   Terraform state: the provider only records the ID after successful polling, and the run-4 log shows
   the create errored during polling. Consequence of NOT deleting: azurerm v4's requires-import guard
   GETs the resource at create start, finds it, and fails fast with "already exists ... needs to be
   imported". Import-then-replace is pointless for a broken shell; Microsoft's guidance for a failed
   managed-domain deployment is delete and redeploy. Command shape:
   `az resource delete --ids /subscriptions/<identity-sub>/resourceGroups/rg-identity-aadds-globaris-poc/providers/Microsoft.AAD/domainServices/aadds-globaris-poc`
   (wait for completion before the next apply).
5. RBAC check (verified live 2026-07-09, `az role assignment list`): the exemption write
   (`Microsoft.Authorization/policyExemptions/write`) is AUTHORIZED and will not 403 at
   `rg-identity-aadds-globaris-poc`. It is covered TWO independent ways, both inherited to the RG:
   (a) the standing **Owner** @ managementGroups/globaris (org root MG), and (b) **Resource Policy
   Contributor** @ managementGroups/globaris, which grants `Microsoft.Authorization/policyExemptions/*`.
   Least-privilege note: ADR-028 does NOT depend on the broad Owner grant. Even after the OQ-008
   Owner-at-globaris grant is eventually removed (the ADR-021 scope-down), the exemption write still
   succeeds via Resource Policy Contributor @ globaris, which survives that scope-down by design. See
   [OQ-008](OPEN-QUESTIONS.md) for the standing-Owner removal that is still pending.
6. Expected next plan: 5 to add (exemption, 2x time_sleep, domain, geo_block CA policy), 0 change,
   0 destroy. 7 of 8 CA policies already exist after run 4.

**Alternatives considered:**
- `policy_assignments_to_modify` -> `enforcementMode = DoNotEnforce` for `Deny-Public-IP` at the identity
  MG (ADR-026 precedent) - rejected: disables public-IP denial for the ENTIRE identity subscription to
  admit one service-managed PIP in one RG; also couples the identity deploy to a management-groups
  re-apply. ADR-026 used this lever because the DDoS Modify policy was broken tenant-wide by a
  placeholder parameter; here the policy is correct and should stay live.
- Parameter-modify `listOfResourceTypesNotAllowed` (drop publicIPAddresses) - rejected: functionally
  disables the assignment at the whole MG, worse than DoNotEnforce for observability (compliance still
  reports green), same blast radius problem.
- `notScopes` on the assignment - rejected: same effect as an exemption but managed in the
  management-groups root, invisible to compliance reporting (exemptions are first-class, auditable
  objects with category and expiry; notScopes are not), and Azure Policy documentation positions
  exemptions as the purpose-built mechanism for exactly this.
- Do nothing / retry - rejected: Deny is caller-independent and the PIP is mandatory; the failure is
  deterministic, proven by 1 failed provisioning cycle.

**Consequences:**
- Positive: unblocks the Entra DS create; the deny stays enforced across the identity MG; the exemption
  is IaC-managed, auditable, and scoped to the one RG that structurally requires it; the time provider
  pattern also fixes the named-location race for greenfield deploys.
- Negative / trade-offs: everything in `rg-identity-aadds-globaris-poc` (currently the domain + the
  identity RSV) is exempt from Deny-Public-IP; acceptable - the RG is dedicated and the RSV creates no
  PIPs. Two 5-minute sleeps on fresh creates. The literal policy-assignment ID string couples
  platform/identity to the ALZ assignment name `Deny-Public-IP`; if the ALZ library renames it, the
  exemption dangles (documented in the code comment).
- Follow-ups required: (1) operator deletes the failed domain shell BEFORE the next apply (step 4);
  (2) after the domain reaches Running, REMOVE the two directory roles (Application Administrator +
  Groups Administrator) from the CI SP - standing mandatory follow-up from the 2026-07-08 session;
  (3) **Correction (2026-07-09, run 29055619749):** the failed `Deploy-Diag-LogsCat` DINE deployment
  (aad-domainservices diagnostics to the platform LAW) is NOT follow-on noise from the failed domain and
  does NOT self-heal. Verified root cause: the assignment's central Log Analytics workspace parameter is
  unwired, so the diagnostic setting's workspace resource ID resolves to the zero-GUID subscription
  `00000000-...` and the deploy fails with `LinkedAuthorizationFailed`. This fails for every resource the
  policy targets tenant-wide, not just AADDS; `az policy remediation create` would re-fail. It needs a real
  fix - wire the platform LAW resource ID into the assignment in `platform/management-groups` - not a wait.
  Tracked in [OQ-021](OPEN-QUESTIONS.md). It does not block the identity apply;
  (4) pre-clearance doc for platform/identity (docs/preclearance/platform-identity.md) carries the full
  re-apply runbook.

### ADR-027: Migrate subscription cost exports to azapi with a system-assigned managed identity (keyless destination SA)

- **Date:** 2026-07-08
- **Section:** 7 - FinOps: Tagging & Budgets
- **Status:** Accepted (user-ratified direction 2026-07-08)
- **Decision makers:** user, claude

**Context:**
Deploy run 28911617973 (platform/management apply): 4 of 5 `azurerm_subscription_cost_management_export`
creates failed with `400: Key-based authentication is currently disabled on this storage account. To
proceed, please enable "Allow storage account key access"`. The destination cost-exports SA is Entra-only
(`shared_access_key_enabled = false`) by design (repo-wide keyless pattern, LESSONS #1). The azurerm
~>4.71.0 resource drives an older CostManagement API version that hard-rejects key-disabled destination
SAs at PUT, so export CREATION fails, not just delivery - this closes OQ-020's "wait and verify" option.
Microsoft's supported path for keyless/firewalled SAs is CostManagement API 2023-08-01 or newer with a
system-assigned managed identity on the export; per the improved-exports tutorial, when the creating
principal holds `Microsoft.Authorization/roleAssignments/write` on the destination SA, the service
auto-assigns the export's MI Storage Blob Data Contributor scoped to the destination container. Our CI SP
holds User Access Administrator at subscription scope (ADR-021 row 6), which covers the SA. The 5th export
(identity sub) failed only on a STALE "RP Not Registered" check - Microsoft.CostManagementExports was
registered by the same apply and the service check lagged; a plain rerun clears it (propagation lag, no
design impact).

Verified against the ARM template reference (learn.microsoft.com/azure/templates,
microsoft.costmanagement/exports, page updated 2026-01-20): GA API versions 2023-08-01 / 2023-09-01 /
2023-11-01 / 2024-08-01 / 2025-03-01 (latest); `identity` accepts `SystemAssigned`; `location` is "only
required when utilizing managed identity"; `schedule.recurrencePeriod.from` "must be in future";
delivery destination takes the STORAGE ACCOUNT `resourceId` plus container NAME (not a container ARM ID).
Verified against azapi provider docs: `ignore_body_changes` was removed in azapi 2.0 and
`lifecycle.ignore_changes` on nested `body` paths is the supported replacement (dynamic properties);
identity block exports read-only `principal_id`/`tenant_id`; OIDC auth honors the ARM_* env vars plus
GitHub's ACTIONS_ID_TOKEN_REQUEST_* - all already exported by `_tf-root.yml`.

**Decision:**
Replace `azurerm_subscription_cost_management_export` in `modules/finops` with `azapi_resource` of type
**`Microsoft.CostManagement/exports@2025-03-01`** (latest GA per the ARM reference; MI support exists from
2023-08-01, the newest GA is chosen so the FocusCost dataset is a one-line future option), created as an
extension resource with `parent_id = "/subscriptions/<sub-guid>"`, `identity { type = "SystemAssigned" }`,
and `location` set from the management root's `var.primary_location`. The SA stays keyless. Dataset parity
is preserved: ActualCost / MonthToDate / Daily granularity / Csv / Active daily schedule / per-sub root
folder. The future-start guard carries over unchanged: `schedule.recurrencePeriod.from =
local.export_recurrence_start` with `lifecycle { ignore_changes =
[body.properties.schedule.recurrencePeriod.from] }`. Role grant for the export MI: rely on the DOCUMENTED
service-side auto-assignment (creator SP holds roleAssignments/write on the SA via UAA); do NOT add an
explicit `azurerm_role_assignment` now. Provider pins: `modules/finops` adds `azapi ~> 2.5` alongside
azurerm; `platform/management` adds the same pin plus an empty `provider "azapi" {}` block (auth via the
existing ARM_* OIDC env vars; no CI changes). Module interface change: `export_container_arm_id` is
replaced by `export_storage_account_id` + `export_container_name` to match the ARM body shape without
string parsing.

**Alternatives considered:**
- Re-enable shared keys on the cost-exports SA (`shared_access_key_enabled = true`) - rejected: weakens
  posture and breaks the repo-wide keyless pattern for a single consumer; the MI path is the supported fix.
- Drop the cost exports - rejected: loses the Section 7 FinOps export evidence for a solvable problem.
- Wait for azurerm to expose `identity` on the export resource - rejected: no upstream timeline; azapi is
  the sanctioned escape hatch for API-version gaps (same rationale as prior azapi uses, ADR-017).
- Explicit `azurerm_role_assignment` on the MI principal as the PRIMARY grant - rejected as primary: the
  service may ALSO auto-assign (our SP always holds roleAssignments/write at create time), producing
  duplicate assignments, and it adds an apply-order dependency on the post-create principal id. Kept as the
  documented FALLBACK: if the first export run fails delivery with an authorization error, add
  `azurerm_role_assignment` (scope = SA id, role `Storage Blob Data Contributor`, principal =
  `azapi_resource...identity[0].principal_id`) inside `modules/finops`. A 409 duplicate is only possible on
  identical role+scope+principal; the service assigns at CONTAINER scope, the fallback at SA scope, so they
  cannot collide.
- API version 2023-08-01 (minimum for MI, used in Microsoft's own azapi sample) - not chosen as primary:
  older versions age out and FocusCost is absent; it is the designated FALLBACK if azapi plan-time schema
  validation rejects 2025-03-01 (see UNVERIFIED below). Never disable `schema_validation_enabled` to force
  a version through.

**Consequences:**
- Positive: keyless SA preserved end to end; exports move to the supported MI delivery path; the
  plantimestamp future-start guard and `export_enabled` gating carry over; FocusCost is one version-string
  away; no CI/workflow changes (azapi OIDC already proven in this pipeline by platform/connectivity).
- Negative / trade-offs: second provider in modules/finops; the export body loses azurerm's typed schema
  (azapi embedded-schema validation covers it at plan); the service-side role assignment lives outside
  Terraform state (documented here, verified operationally); azapi pin drift across roots grows by one
  (picked `~> 2.5` to match ADR-017; the OQ-017 standardization pass reconciles all azapi pins later).
- Follow-ups required: (1) rerun clears the stale RP check on the 5th export; (2) after the first
  scheduled run, verify blobs land in `cost-exports` AND that the auto-created MI role assignment exists on
  the container - if delivery fails with an auth error, implement the explicit role-assignment fallback;
  (3) migration is a clean swap - all 5 exports failed to create, so nothing exists in Azure or in state
  (engineer confirms with `terraform state list` before deleting the old resource block; no
  import/moved blocks).
- UNVERIFIED (marked honestly): whether the azapi release resolved by `~> 2.5` embeds api-version
  2025-03-01 in its validation schema cannot be enumerated offline; failure mode is a plan-time validation
  error (fail-fast, no Azure mutation), remedy is the 2023-08-01 fallback above. The tutorial documents MI
  auto-assignment for export creation generally; it has not yet been observed in this tenant - hence
  follow-up (2) is mandatory, not optional.

### ADR-026: Neutralise the ALZ `Enable-DDoS-VNET` Modify policy at the Connectivity MG for the POC

- **Date:** 2026-07-06
- **Section:** 2 — Management Group Hierarchy (policy) / 4 — Connectivity (impact)
- **Status:** Accepted (user-approved 2026-07-06)
- **Decision makers:** user, claude

**Context:**
Both hub VNet creates in the connectivity subscription failed at apply with
`403 LinkedAuthorizationFailed`: ARM ran a `Microsoft.Network/ddosProtectionPlans/join/action`
linked-auth check against the non-existent subscription `00000000-0000-0000-0000-000000000000`.
Root-caused (after a two-PUT test refuted the earlier azapi null-key theory): `avm-ptn-alz`
0.19.1 applies the ALZ default assignment **`Enable-DDoS-VNET`** (Modify, built-in def
`94de2ad3-e0c1-4caf-ad78-5d47bbc83d3d`, "Virtual networks should be protected by Azure DDoS
Protection") at the **Connectivity management group**, enforced, with its `ddosPlan` parameter set
to the placeholder `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/
providers/Microsoft.Network/ddosProtectionPlans/placeholder`. The Modify rule does
`addOrReplace` on `Microsoft.Network/virtualNetworks/ddosProtectionPlan.id` (and
`enableDdosProtection = true`) at admission time, so **every** VNet PUT in the connectivity
subscription is rewritten to reference a DDoS plan in the zero-GUID subscription, which fails the
linked-auth check. This is body-independent (Modify injects regardless of request body — PUT with
`ddosProtectionPlan: null` and PUT with the key omitted both failed identically) and
subscription-specific (the Management MG has no such assignment, so the identical body succeeds
there). Confirmed placement of the connectivity sub under the Connectivity MG via
`management-group show --expand`; corroborated upstream by Enterprise-Scale #1053/#983 and
ALZ-Bicep #181/#596 (the known "enforced DDoS Modify policy with placeholder plan id breaks all
VNet creates" trap). The failure originates in the `platform/management-groups` root module
(policy), not in `platform/connectivity`, azapi, or the AVM VNet leaf module.

**Decision:**
Set `enforcement_mode = "DoNotEnforce"` on the `Enable-DDoS-VNET` assignment at the `connectivity`
management group via the `policy_assignments_to_modify` input of `Azure/avm-ptn-alz/azurerm` 0.19.1
in `platform/management-groups/main.tf`. This stops the Modify effect from mutating VNet requests,
unblocking all hub/identity/spoke VNet creates at zero cost, consistent with the existing POC
decision to run without DDoS Standard. When DDoS is later enabled, supply a real plan id via
`policy_default_values` (the assignment binds `ddosPlan` to a library default) and restore
enforcement.

**Alternatives considered:**
- Disable via the assignment `effect` parameter (`Disabled`) or `overrides = [{ kind = "policyEffect", value = "Disabled" }]`, or drop it with `creation_enabled = false` — equivalent outcomes; `DoNotEnforce` chosen as the simplest reversible form that keeps the assignment visible.
- Supply a real DDoS Standard plan id via `policy_default_values` — rejected for the POC: DDoS Standard is a flat ~$2,944/mo and DDoS governance is out of scope.
- Manual `az policy assignment update` — rejected: would drift and be reverted on the next `management-groups` apply. The fix must be version-controlled in the root module.
- Fixing it in `platform/connectivity` (the `enable_ddos_standard` plan gate) — rejected: that gate governs the plan resource, not the Modify policy; it cannot affect an admission-time policy in a different root module (this is the coupling caveat below).

**Consequences:**
- Positive: unblocks every VNet create in the connectivity subscription at zero cost; reversible; keeps the assignment present for a future real-plan re-enforcement.
- Negative / trade-offs: no DDoS auto-enable enforcement during the POC (accepted). Introduces a documented coupling — the DDoS decision now spans two root modules (`management-groups` policy + `connectivity` plan) that must be flipped together.
- Follow-ups required: OQ-019 (single shared `enable_ddos_standard` variable driving both stacks so they cannot diverge). Supersedes commit `e2733db` as the **fix location** for this failure; `e2733db` remains valid as the cost gate for the DDoS plan resource itself.

**ADDENDUM 2026-07-10 - DoNotEnforce extended to the `landingzones` MG (committed 2581bd4):**
The original decision only DoNotEnforce'd `Enable-DDoS-VNET` at the **Connectivity** MG. Live
pre-clearance for the landing-zone spokes found the SAME `Enable-DDoS-VNET` assignment still
**ENFORCED at the `landingzones` MG**, with the same placeholder-plan `ddosPlan` parameter. Left as-is
it would inject the invalid zero-GUID plan id into every spoke VNet PUT and reproduce the identical
`403 LinkedAuthorizationFailed` outage on corp-a1 / corp-a2 / online-p1. Extended the DoNotEnforce to
the `landingzones` MG via the same `policy_assignments_to_modify` input of `Azure/avm-ptn-alz/azurerm`
0.19.1 in `platform/management-groups/main.tf` (committed 2581bd4). This is the **OQ-019 split-toggle
risk materialising**: because the plan resource in `platform/connectivity` and the `Enable-DDoS-VNET`
policy in `platform/management-groups` were never linked, neutralising the policy at one MG scope did
nothing at another, and the enforced assignment had to be found and DoNotEnforce'd per MG. This
reinforces the OQ-019 recommendation (a single `enable_ddos_standard` driving the plan resource AND
the policy assignment enforcement across every relevant MG scope). See OQ-019.

### ADR-025: CI state-SA firewall — JIT default_action Allow/Deny flip, not single-IP allow-list (fixes LESSON 16 race)

- **Date:** 2026-07-06
- **Section:** 10 — Pipeline & Tooling (state backend access)
- **Status:** Accepted (Option A; user-approved 2026-07-06)
- **Decision makers:** user, claude

**Context:**
The state SA is default_action=Deny with a static ip_rules list. The manage_runner_ip step
(LESSON 16) JIT-adds the runner's api.ipify.org egress IP, polls a blob-list until admitted,
then runs init. connectivity init failed on 4 attempts; management-groups succeeded on 3 —
misread as a deterministic per-root split. Log analysis refutes that: connectivity itself
REACHED the blob (409 BlobImmutableDueToPolicy, then a blob-lock error) in 2 of 4 runs and
only got 403 AuthorizationFailure in the other 2 — a flipping, non-deterministic outcome.
Every run drew a different random hosted-runner egress IP. In run 28798776899 the az poll was
admitted (14:24:48) yet Terraform's own read 403'd 19s later (14:25:07) from the same job.
403 AuthorizationFailure (not AuthorizationPermissionMismatch) with a network-deny SA is a
NETWORK block, not RBAC; the SP's Blob Data role is proven intact. Root cause: pinning ONE IP
is unreliable from hosted runners because (a) outbound SNATs across a dynamic IP pool so the
ipify IP is not necessarily Terraform's egress IP, and (b) Storage IP-rule propagation is
eventually consistent per front-end node, so single-IP admittance is non-monotonic within the
window. The provider subscription_id and the 0-byte connectivity state blob were both excluded
as causes by evidence.

**Decision:**
Replace the JIT single-IP allow-list with a JIT flip of the account default_action to Allow
before init and back to Deny on exit (if: always()). Allow-all is monotonic once propagated, so
the readiness poll is meaningful and the egress-IP roulette is eliminated. Retain the single-root
guard (target != 'all') to avoid concurrent default_action flips racing. Data stays protected by
Entra-only auth (shared keys disabled) + Storage Blob Data Contributor RBAC + TLS1.2 + CMK.

**Alternatives considered:**
- Keep single-IP allow-list, poll longer / retry init on 403 — rejected: cannot certify
  Terraform's specific connection path; still racy and non-monotonic.
- Private Endpoint + VNet/self-hosted runner — deferred to production (Option B, OQ-018): correct
  ALZ pattern, but needs runner VNet, private DNS, runner infra; out of scope for the POC turn.
- GitHub larger runners with static outbound IP range in permanent ip_rules — deferred (Option C):
  clean and deterministic but requires the larger-runners plan.

**Consequences:**
- Positive: unblocks connectivity and every subsequent root; removes a latent flaky gate on all
  CI state access.
- Negative / trade-offs: during the ~2-3 min job window the blob endpoint is reachable from any
  IP, defended by Entra token + RBAC + TLS + CMK (network layer dropped, time-boxed). Single-root
  only; target=all still relies on the documented permanent ip_allow_list prerequisite.
- Negative / residual-leak edge case: if the runner is cancelled or crashes between the Allow flip
  and job end, the `if: always()` restore cannot run, so the SA stays default_action=Allow until the
  next single-root run's restore step or a manual fix (a target=all run does NOT restore it —
  manage_runner_ip=false there). Inherent to any JIT-open design; exposure stays Entra-only + RBAC +
  TLS + CMK-defended, just no longer strictly time-boxed. Mitigation: on abnormal termination, run
  `az storage account update --default-action Deny` on the state SA, or dispatch any single-root plan
  (restores it on exit).
- Follow-ups: (1) implement the flip in _tf-root.yml (Cloud Engineer / DevSecOps — workflow lane).
  (2) OQ-018: adopt Private Endpoint + VNet runner as the production state-access model.
  (3) overwrite the leftover 0-byte connectivity state blob on next successful init (no apply ran).

---

### ADR-024: Remove the state-container WORM immutability policy (incompatible with the Terraform azurerm backend)

- **Date:** 2026-07-06
- **Section:** 10a (bootstrap / state backend)
- **Status:** Accepted (removes the immutability-policy portion of the ADR-004 bootstrap design)
- **Decision makers:** user, claude

**Context:**
Bootstrap created an `azurerm_storage_container_immutability_policy` (container-level, time-based, 7-day) on
the `tfstate` container, `locked = false`. The original intent was a WORM audit trail; the header even noted a
*locked* policy would break state, so it was left unlocked on the assumption that unlocked + blob versioning
was safe for active state. It is not. The first state operation on a **new** root after the policy existed
(`platform/connectivity` init) failed:
`Error loading state: failed to lock azure state: 409 This operation is not permitted as the blob is immutable
due to a policy (BlobImmutableDueToPolicy)`. The azurerm backend takes a **blob lease (lock)** and rewrites the
state blob on every run; a container time-based retention policy rejects that path with 409 **regardless of
versioning** (versioning only protects overwrite history, not the lease/lock). `management-groups` had worked
only because its state blob was written *before* the bootstrap re-apply added the policy; every future apply
on it would have failed too. Discovered during the first CI plan of connectivity, 2026-07-06.

**Decision:**
Remove the immutability policy entirely (it was `locked = false`, so removable — a *locked* policy would have
been unrecoverable without deleting the SA). State protection is provided by the Storage Account's existing,
backend-compatible controls: **blob versioning + 14-day blob/container soft-delete + Entra-ID-only (no
shared-key) access + CMK-at-rest**. WORM is not an appropriate protection model for a live Terraform state
container.

**Alternatives considered:**
- Keep the policy, disable Terraform state locking — rejected: removes concurrency safety on shared state; far
  more dangerous than losing WORM.
- Version-level immutability instead of container-level — rejected: still intercepts the lease/lock path and
  adds operational complexity for no real benefit on a state blob.
- A separate immutable audit copy of state (lifecycle-management export to a WORM container) — deferred: valid
  future enhancement, but out of scope and not on the live backend.

**Consequences:**
- Positive: unblocks all CI state operations (connectivity and every subsequent root); removes a latent bomb
  that would have broken existing roots' next applies.
- Negative / trade-offs: no WORM/immutability on state history — accepted; versioning + soft-delete + CMK +
  Entra-only auth remain. Lesson: never put a container-level immutability policy on a Terraform azurerm
  backend, locked or unlocked.
- Follow-ups required: none blocking. If an immutable state-audit trail is later required, do it as an
  out-of-band lifecycle export to a dedicated WORM container, not on the active backend.

---

### ADR-023: Pin ALZ library to platform/alz 2026.04.2 (bump the ref, not the module) to clear the Enforce-EncryptTransit apply break

- **Date:** 2026-07-05
- **Section:** 2 (Management Group Hierarchy) / 10 (first CI apply)
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
The first CI `apply` of `platform/management-groups` (run 28725677856) created the MG hierarchy and all 5
subscription placements, then failed hard on one policy set definition: `Enforce-EncryptTransit`. Azure
returned `400 InvalidPolicyParameters` — the initiative's `effect` parameter default of lowercase `deny` is
rejected by referenced built-in policy `1a5b4dca-0b6f-4cf5-907c-56316bc1bf3d` v9.0.0, whose allowed values
are the capitalized `Audit | Deny | Disabled`. This is version skew between the pinned ALZ library
(`platform/alz@2026.01.3`) and a built-in policy that bumped major version; `Enforce-EncryptTransit` is itself
deprecated upstream. The `alz` provider config carries the library reference (`providers.tf`), and the
provider is already at `~> 0.21.0`.

**Decision:**
Bump the ALZ **library** reference `platform/alz` from `2026.01.3` to **`2026.04.2`** and leave everything
else unchanged. `platform/alz/2026.04.0` explicitly "remov[ed] a number of deprecated and superseded policies
to avoid breaking changes like seen with `Enforce-EncryptTransit`" (Azure-Landing-Zones issues #4128 / #411);
`2026.04.2` is the latest patch of that line. avm-ptn-alz stays pinned at 0.19.1; no provider versions change.

**Alternatives considered:**
- Bump avm-ptn-alz 0.19.1 → 0.21.0 — rejected (for now): heavier change that also moves the `alz`/`azapi`
  provider floors and would need re-validation across every root; the library ref alone resolves the break.
- Local `lib` override patching only the `Enforce-EncryptTransit` effect default `deny`→`Deny` — rejected:
  keeps a deprecated initiative alive and forks us from the canonical library for a problem upstream already
  fixed by removal.
- Exclude the initiative from the Globaris architecture — rejected: silently drops an encryption-in-transit
  guardrail and masks the version-skew root cause.

**Consequences:**
- Positive: canonical, upstream-blessed fix; stays on the maintained library; unblocks the apply with a
  one-line, reviewable change.
- Negative / trade-offs: 2026.01→2026.04 is ~3 months of library drift — the re-plan will show more than the
  single initiative (deprecated policies removed, other definitions refreshed). Mitigated by re-running a CI
  **plan** to review the diff before the next apply.
- Follow-ups required: (1) CI plan review then re-apply management-groups; (2) any other root that pins
  `platform/alz` should move to 2026.04.2 in lock-step for library consistency; (3) reconsider the full
  avm-ptn-alz 0.21.0 bump as a separate, deliberate change later.

---

### ADR-022: Section 11 documentation set - greenfield DEPLOYMENT.md runbook; brownfield designed now, built later

- **Date:** 2026-07-03
- **Section:** 11 (Documentation Deliverables)
- **Status:** Accepted
- **Decision makers:** user, claude (architect)

**Context:**
The platform is a green-field build, validate-clean across all 10 roots, but undocumented for an operator to
deploy or hand off. PROMPT.md §11 names six deliverables (README, ARCHITECTURE, RUNBOOK, SECURITY, COST,
per-module terraform-docs). Two needs surfaced that §11 does not name explicitly: (1) a step-by-step,
per-landing-zone greenfield deployment runbook - the pipeline already supports per-root deploys via
`deploy.yml target=<root>`, but the ordered operator procedure is undocumented; (2) a forward path for using
this platform against a brown-field tenant (adopting existing subscriptions/resources into the ALZ
hierarchy).

**Decision:**
1. Author a dedicated **`DEPLOYMENT.md`** greenfield runbook, ordered to the `deploy.yml` `needs:` graph
   (bootstrap -> management-groups -> management -> {connectivity, security, identity} -> spokes ->
   synthetic). Each step is self-contained: what it creates, the exact `deploy.yml` inputs, its
   dependencies, the `terraform output` values carried forward, and a post-apply validation. README
   quickstart links to it; `docs/cicd-deploy-teardown.md` stays the pipeline reference (mechanics),
   DEPLOYMENT.md is the operator procedure (how to run).
2. **Brownfield is designed now, built later.** This pass produces a "Brownfield adoption approach" design
   deliverable (`docs/brownfield-adoption.md`) plus this ADR and OQ-014. It does not document brownfield
   capability as if it exists. The actual capability (state `import`, grafting existing subscriptions into
   the MG hierarchy, audit-first non-enforcing policy rollout, DNS/peering coexistence) is a future build.

**Alternatives considered:**
- Fold the deployment steps into README quickstart - rejected: makes README long, mixes overview with
  operational detail.
- Extend `docs/cicd-deploy-teardown.md` into the operator runbook - rejected: blurs pipeline-reference vs
  operator-guide.
- Write a full brownfield runbook now - rejected: risks documenting untested capability; brownfield is a
  distinct design problem deserving its own build + validation.
- Defer brownfield entirely - rejected: the user wants a credible adoption story; capturing the approach now
  is low-cost and portfolio-valuable.

**Consequences:**
- Positive: an operator can deploy the whole platform or any single LZ from a followable guide; the
  greenfield runbook doubles as the §12 acceptance path; the brownfield direction is on record without
  over-committing.
- Negative / trade-offs: DEPLOYMENT.md must stay in sync with the `deploy.yml` target list and root order;
  the brownfield design section names capability that does not yet exist and must be clearly labelled
  roadmap.
- Follow-ups: OQ-014 (brownfield unknowns); a future section/wave to build + validate brownfield adoption;
  per-module `terraform-docs` generation is its own step in the §11 sequence.

---

### ADR-021: OIDC SP least-privilege scope-down — replace Tenant Root Owner with a scoped role set (refines/supersedes ADR-006)

- **Date:** 2026-06-29
- **Section:** 12 (Hardening) — resolves OQ-008; refines [ADR-006](#adr-006-initial-oidc-sp-rbac-scope--owner-at-tenant-root-mg)
- **Status:** Accepted — **supersedes the RBAC-scope decision of ADR-006** (Owner at Tenant Root MG). ADR-006
  remains the historical record of the deliberate build-phase compromise; this ADR is the steady-state grant.
- **Decision makers:** claude (architect); user to ratify; devsecops to implement in `bootstrap/identity.tf`;
  a real CI `apply`+`destroy` of all roots is the only true validation (see Consequences).

**Context:**
ADR-006 granted the CI OIDC SP `sp-alz-poc-cicd` **Owner at the Tenant Root Management Group** (the MG named
after the tenant ID) plus **Storage Blob Data Contributor** on the state Storage Account. Owner-at-tenant-root
is the single most over-privileged grant in the platform: it lets the SP do anything in any subscription the
tenant ever contains, including `elevateAccess`-adjacent control. OQ-008 has tracked the scope-down since
build. The platform now has 10 Terraform roots driven by `deploy.yml` (apply) and `teardown.yml` (destroy,
ADR-019/ADR-020); the exact privileged operations the SP must perform are finally enumerable, so the scope-down
can be computed precisely. **Under-scoping breaks CI** (a missing grant fails `apply` or, worse, fails
`destroy` and orphans resources), so the matrix was derived by auditing every privileged operation in the repo,
not by guessing a "minimal" set.

Audit of privileged operations (grep of `azurerm_role_assignment`, `azurerm_management_group_policy_assignment`,
`azurerm_pim_eligible_role_assignment`, `azurerm_role_management_policy`, and the `avm-ptn-alz` MG call,
excluding `.terraform/`):

| Operation in IaC | Root(s) | Scope | ARM permission family |
|---|---|---|---|
| Create/move/delete the Globaris MG tree + place 5 subs (`avm-ptn-alz` `subscription_placement`) | `platform/management-groups` | Tenant Root Group → Globaris | `Microsoft.Management/managementGroups/*` (incl. `/subscriptions/write` to move subs) |
| MG-scoped **policy assignments** w/ system identities (FinOps tag initiative @ globaris; MCSB/NIST/CIS @ root MG; deny-public-net @ landingzones) | `platform/management`, `platform/security` | globaris MG, landingzones MG | `Microsoft.Authorization/policyAssignments/write,delete` |
| **Role assignments** for those policy remediation identities (`Contributor` @ globaris MG) + PIM eligible assignments + `azurerm_role_management_policy` @ globaris/landingzones MG | `platform/security`, `platform/management`, `platform/identity` (pim.tf) | globaris MG, landingzones MG | `Microsoft.Authorization/roleAssignments/write,delete`, `roleManagementPolicies/*`, `roleEligibilityScheduleRequests/*` |
| Resource create/destroy across all 5 subs (hub/firewall/DNS, LAW/automation/budgets, Entra DS/RSV, Sentinel/Defender/KV, spokes, synthetic RGs) | `platform/*`, `landing-zones/*`, `synthetic` | each of the 5 subscriptions | `*` minus `Microsoft.Authorization/*/Write,Delete` |
| **Role assignments** inside subs (guardrails MI → Contributor on synthetic RGs; red-team MI → Network Contributor / Storage Blob Data Reader / Key Vault Reader; KV/Storage data-plane roles in spokes) | `synthetic`, `landing-zones/*`, `platform/*` | RGs/resources within the 5 subs | `Microsoft.Authorization/roleAssignments/write,delete` at sub scope |
| State backend data plane (blob read/write/lease for `terraform.tfstate`) | every root (backend) | state Storage Account | `Microsoft.Storage/.../blobServices/...` data actions |

The decisive finding: **`Contributor` is insufficient** for this platform because the IaC itself creates
role assignments and policy assignments at MG and sub scope, and Contributor explicitly excludes
`Microsoft.Authorization/*/Write` and `*/Delete`. So the SP needs an authorization-management role (UAA) and a
policy-management role (Resource Policy Contributor) **in addition to** Contributor — at the scopes where those
operations occur.

**Decision:**
Delete the single `oidc_owner_tenant_root` Owner assignment and replace it with the following **scoped role
matrix**. Keep the Storage Blob Data Contributor assignment unchanged. All role names/GUIDs verified against
the Microsoft Learn built-in-roles reference (2026-06-20 revision).

| # | Built-in role (GUID) | Scope | Why it is needed | Root(s) that require it |
|---|---|---|---|---|
| 1 | **Management Group Contributor** `5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c` | Tenant Root Group (`/providers/Microsoft.Management/managementGroups/<tenantId>`) | Create/update/**delete** management groups and **move subscriptions** under them — `apply` builds the Globaris tree and places 5 subs; `destroy` deletes the tree. Contributor cannot touch `Microsoft.Management`. | `platform/management-groups` |
| 2 | **Resource Policy Contributor** `36243c78-bf99-498c-9df9-86d9f8d28608` | Globaris root MG (`/providers/Microsoft.Management/managementGroups/globaris`) | Create/**delete** MG-scoped policy & policy-set assignments (FinOps tag initiative @ globaris; MCSB/NIST/CIS @ root MG via `var.root_management_group_id`). `apply` writes them, `destroy` deletes them. | `platform/management`, `platform/security` |
| 3 | **User Access Administrator** `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | Globaris root MG | Create/**delete** role assignments at MG scope (Contributor for policy remediation identities; PIM eligible assignments + role-management policies @ globaris). `Microsoft.Authorization/*` is exactly UAA's grant; Contributor and Resource Policy Contributor both lack `roleAssignments/write`. | `platform/security`, `platform/management`, `platform/identity` |
| 4 | **User Access Administrator** `18d7d88d-…` | Landing Zones MG (`/providers/Microsoft.Management/managementGroups/landingzones`) | PIM eligible Contributor assignment + role-management policy are written at the **landingzones** MG (pim.tf); deny-public-net policy remediation identity also lands here. Separate row because UAA at globaris does **not** auto-cover a child MG for *all* operations cleanly in a destroy graph, and keeping it explicit documents the second scope. (Inheritance does flow down, so row 4 is technically redundant given row 3 inherits to children; it is retained for clarity and to survive any future re-parenting — see residual-risk note.) | `platform/identity` (pim.tf), `platform/management` |
| 5 | **Contributor** `b24988ac-6180-42a0-ab88-20f7382dd24c` | each of the **5 subscriptions** (management, connectivity, identity, security, landingzones) — via `for_each` over a static map | Create/**destroy** all resources in every sub: hub/firewall/DNS, LAW/automation/budgets, Entra DS/RSV, Sentinel/Defender/KV, spokes, synthetic RGs. Subscription-level Defender plan onboarding also runs at sub scope. | all `platform/*`, `landing-zones/*`, `synthetic` |
| 6 | **User Access Administrator** `18d7d88d-…` | each of the **5 subscriptions** — via the same `for_each` map | The IaC creates role assignments **inside** the subs (guardrails MI → Contributor on synthetic RGs; red-team MI → Network Contributor / Storage Blob Data Reader / Key Vault Reader; KV & Storage data-plane roles in spokes). Contributor cannot create these; UAA at sub scope can, and `destroy` needs `roleAssignments/delete` too. | `synthetic`, `landing-zones/*`, `platform/security`, `platform/identity` |
| 7 | **Storage Blob Data Contributor** `ba92f5b4-2d11-453d-a403-e96b0029c9fe` | state Storage Account (`azurerm_storage_account.tfstate.id`) | **Unchanged from today.** Entra-ID-only state SA (`shared_access_key_enabled = false`) requires a data-plane role for blob read/write/lease on `terraform.tfstate`. | every root (backend) |

Rows 1–6 replace Owner; row 7 is the existing assignment kept as-is. Rows 3 and 4 could be collapsed to a
single UAA at globaris (inherits to landingzones); they are kept distinct in the spec for auditability, and the
spec marks row 4 `OPTIONAL (inherited)` so devsecops may drop it without loss of function.

**Why not just Owner-at-each-sub + something for MGs?** Owner at sub scope re-introduces unrestricted
`Microsoft.Authorization/*` per sub — strictly broader than Contributor+UAA and with no functional gain, since
UAA already supplies the only Authorization actions the IaC needs. Contributor+UAA is the tighter pair.

**Alternatives considered:**
- **Keep Owner at Tenant Root MG (status quo / ADR-006)** — rejected: the entire purpose of OQ-008; tenant-root
  Owner is unbounded across all current and future subscriptions and is unacceptable steady-state.
- **Single Owner at Globaris MG (one level down from tenant root)** — rejected: still Owner (unrestricted
  `Microsoft.Authorization/*` + every resource action) across the whole hierarchy; only marginally narrower than
  tenant-root Owner and does not demonstrate least-privilege. Also the MG-create/sub-move operations and the
  tenant-root-scoped Globaris-creation need a grant **at** the Tenant Root Group, which a Globaris-scoped
  assignment does not provide.
- **Per-sub Contributor only (no UAA, no Resource Policy Contributor)** — rejected: **breaks apply** — the IaC
  creates role assignments and MG/sub policy assignments that Contributor's `NotActions`
  (`Microsoft.Authorization/*/Write`, `*/Delete`) explicitly forbid. This is the classic under-scope trap.
- **Custom role definition** carved to the exact action set — rejected for the POC: meaningfully tighter
  (e.g. UAA without `*/read` on the whole tenant), but adds a `azurerm_role_definition` to maintain and re-test
  on every new resource type. Logged as a future hardening option (G-series) rather than POC scope.
- **RBAC Administrator instead of UAA** — rejected: `Role Based Access Control Administrator`
  (`f58310d9-…`) grants only `roleAssignments/write,delete` + `*/read`, which **would** cover the role-assignment
  operations and is narrower than UAA — but it does **not** cover `roleManagementPolicies/*` /
  `roleEligibilityScheduleRequests/*` used by PIM (pim.tf), so it under-scopes the identity root. UAA is required
  for the PIM operations. (Noted as a partial-tightening option for the non-PIM scopes in a future custom-role pass.)

**Consequences:**
- Positive: removes tenant-root Owner — the SP can no longer act outside the Globaris hierarchy + the 5 named
  subs, cannot grant itself access at tenant scope (`elevateAccess` is Owner-only and now gone), and cannot
  touch subscriptions added to the tenant later unless they are explicitly placed and granted.
- Positive: every grant is now justified by a specific resource in the repo; the matrix is auditable row-by-row.
- Negative / **honest residual broad grants** (this is **not** "fully minimal"):
  - **Management Group Contributor at Tenant Root Group** is inherently powerful — it can create/delete **any**
    management group in the tenant and move subscriptions between them. It is the minimum that still lets CI
    build/destroy the MG tree, but it is a tenant-wide control-plane grant. Cannot be reduced further without a
    custom role, because MG-create must be authorized at the parent (Tenant Root Group).
  - **User Access Administrator at Globaris MG** can create **any** role assignment (including Owner) anywhere in
    the Globaris hierarchy. A compromised CI SP could self-escalate to Owner within Globaris. This is intrinsic to
    any self-deploying platform SP that manages RBAC as code; mitigated by OIDC (no stored secret), environment
    gates (ADR-019), and branch/PR-scoped federation — not by the role itself.
  - **Contributor at each of the 5 subs** is broad *within* a sub (all resource actions). It is the standard
    deploy grant and the floor for an IaC SP that owns the whole sub's resources.
  - Net reduction is **Owner-at-tenant-root → {MG Contributor @ root, scoped UAA/Policy @ 2 MGs, Contributor+UAA
    @ 5 subs}**: the blast radius drops from "the entire tenant, forever" to "the Globaris hierarchy + 5 named
    subs," and the SP loses unrestricted Owner (no `elevateAccess`, no implicit future-sub access). Real but not
    total.
- **Validation caveat:** `terraform validate`/`plan` will **not** prove sufficiency — RBAC gaps only surface as
  `AuthorizationFailed` at `apply`/`destroy` time. The only true test is a CI `target=all` **apply** followed by a
  **teardown** against a tenant where the SP holds exactly this set. Until that runs green, treat the matrix as
  *resolved-by-design, pending live validation*. If a specific operation 403s, the fix is to add the precise
  missing scope/role — do **not** fall back to Owner.
- **Graph (azuread) app permissions are out of scope and unchanged.** The Conditional Access work uses
  Microsoft Graph application permissions (`Policy.ReadWrite.ConditionalAccess`, etc.), which are **directory**
  permissions on the app registration, not ARM RBAC. OQ-008 concerns only ARM RBAC; the Graph grants stay exactly
  as they are. (Note: the current `bootstrap/identity.tf` header says "No API permissions needed" — if CA policies
  are applied by this same SP elsewhere, those Graph grants live outside bootstrap and are untouched here.)
- Follow-ups required:
  1. devsecops implements the spec in `docs/oq-008-rbac.md` into `bootstrap/identity.tf` (rows 1–6 replace
     `oidc_owner_tenant_root`; row 7 unchanged) and adds 4 new subscription-ID variables to `bootstrap/variables.tf`.
  2. code-reviewer gates: no Owner remains; `for_each` over a static map; every assignment has a justifying comment.
  3. a real `apply`+`destroy` of all 10 roots validates sufficiency; any 403 → add the precise scope, never Owner.
  4. (future, optional) custom role definitions to tighten UAA → RBAC Administrator where PIM is not used, and to
     drop tenant-wide `*/read`.

---

### ADR-020: Teardown mechanics — uniform `terraform destroy` (supersedes the ADR-019 brute-force split)

- **Date:** 2026-06-27
- **Section:** 10 (Pipeline & Tooling) — amends ADR-019
- **Status:** Accepted — amends the teardown-mechanics portion of [ADR-019](#adr-019-cicd-deploy--teardown--parameterized-deployyml--guarded-teardownyml-two-environments)
- **Decision makers:** claude (architect), code-reviewer (raised the finding)

**Context:**
Code review (finding B1) found that ADR-019 and `docs/cicd-deploy-teardown.md` §6/§9 specify the
full-environment teardown (`target=all`) as a **split** — `az group delete` brute force for the RG-bound
regional roots **plus** `terraform destroy` for the non-RG control-plane roots (`platform/management-groups`,
`platform/identity`, MG-scoped `platform/security`) — and §6 calls that split "the key correctness point
for this design," justified by LESSON 19 (`terraform destroy` gets stuck on Azure ordering quirks). **But
the implemented and validated `teardown.yml` does not do the split:** it runs `terraform destroy` for every
root uniformly, in reverse dependency order, via the reusable `_tf-root.yml`. The docs asserted behavior the
code does not implement; this had to be reconciled before merge. The reconciliation is a choice between
implementing the split in CI (Option 1) or accepting uniform `terraform destroy` and amending the docs
(Option 2).

**Decision:**
Adopt **uniform `terraform destroy`** for both single-root and `target=all` teardown — i.e. keep the
already-implemented `teardown.yml` / `_tf-root.yml` behavior — and amend the docs to match. The
`az group delete` brute-force / Terraform split is **demoted to a deferred refinement / manual fallback**
for the case where a `target=all` `terraform destroy` wedges; it lives only in the runbook (the
`include_bootstrap=true` scorched-earth path and a per-RG fallback note), not in the workflow. OQ-012
(teardown scope, `include_bootstrap=false` default), OQ-013 (two GitHub Environments), the
typed-`confirm=destroy` guard, and the reverse-order `needs:` graph are **unchanged**.

**LESSON 19 — why it does not force the split here:**
LESSON 19's stuck-`terraform destroy` failures originated in the AVD landing zone and were
**session-host VM**-driven (stopped-VM extension deletes, agent/DSC extension races, the resources that
most reliably wedge an ARM delete). **This CAF POC has no VMs.** Its workload is PaaS and control-plane
only — App Service, SQL, VNets/peerings, Key Vault, Sentinel/Defender onboarding, policy/role/MG objects —
all of which `terraform destroy` removes cleanly. Moreover the **non-RG roots** (management groups,
MG-scoped policy assignments, Entra/CA objects) are precisely what `az group delete` **cannot** touch, so
the split's "brute force handles RGs, Terraform handles control-plane" framing always needed Terraform for
the hard part anyway; using Terraform for everything is simpler and keeps state consistent for a clean
re-apply. The LESSON-19 brute-force path is retained as the documented fallback if a `target=all` run ever
does wedge in practice.

**Alternatives considered:**
- **Option 1 — implement the split in `teardown.yml`** (`az group delete` for RG-bound roots + `terraform
  destroy` for control-plane roots): rejected — it adds per-root branching and loses state fidelity (state
  must be reconciled or recreated) to solve a VM-driven failure mode this no-VM workload is not expected to
  hit; the implementation is already validated as uniform `terraform destroy`.
- **Promote brute force to the default but keep Terraform for control-plane roots only:** rejected for the
  same reason — same complexity, same state-fidelity loss, no benefit absent the VM failure mode.

**Consequences:**
- Positive: docs ↔ code are consistent (ADR-019/§6/§9 ↔ `teardown.yml` ↔ `_tf-root.yml`); one destroy
  mechanism for single-root and full reset; state stays consistent so any scope re-applies cleanly; no new
  workflow code is required to merge.
- Negative / trade-offs: if a `target=all` `terraform destroy` ever wedges on an Azure ordering quirk, the
  operator must fall back to the **manual** brute-force runbook (per-RG `az group delete` in reverse order,
  then `terraform destroy`/targeted `az` for the non-RG control-plane roots). This is documented but not
  automated. Should that prove common, re-open with a new ADR that promotes the split.
- Follow-ups required: none blocking — `teardown.yml` already implements the accepted behavior. Its header
  comment (lines 14-17) already describes uniform `terraform destroy` with brute force as "a documented
  refinement," so it is consistent with this ADR; no workflow edit is needed.

---

### ADR-019: CI/CD deploy + teardown — parameterized `deploy.yml` + guarded `teardown.yml`, two Environments

- **Date:** 2026-06-27
- **Section:** 10 (Pipeline & Tooling) — extends the bootstrap pipeline
- **Status:** Accepted — **teardown mechanics amended by [ADR-020](#adr-020-teardown-mechanics--uniform-terraform-destroy-supersedes-the-adr-019-brute-force-split)** (the `az group delete` brute-force / Terraform split below is replaced by uniform `terraform destroy`; the rest of ADR-019 — structure, scope OQ-012, two-Environment model OQ-013, OIDC federation — stands)
- **Decision makers:** user (decisions), claude (architect/design), devsecops-engineer (execution)

**Context:**
CI/CD must (1) deploy any single platform/landing-zone root individually, (2) deploy the whole
environment in dependency order, and (3) tear everything down — all via OIDC, no stored secrets,
appropriately gated. The pre-existing `apply-on-merge.yml` auto-applied on every push to `main`, which
contradicts LESSON 17 (deploys must be explicit, not merge-triggered) and the destroy-then-recreate demo
cadence. Two user decisions were outstanding: whether "tear down everything" includes the bootstrap
state backend + OIDC app (OQ-012), and the approval model (OQ-013). Full design in
[docs/cicd-deploy-teardown.md](docs/cicd-deploy-teardown.md).

**Decision:**
- **Deploy:** one parameterized `workflow_dispatch` workflow `deploy.yml` with `target`
  (choice: the 9 deployable roots + `all`) and `action` (choice: `plan` | `apply`). `target=all` runs
  the 9 backend-state roots via a `needs:` job graph in dependency order; a single `target` runs just
  that root. `apply` jobs gate on the `production` GitHub Environment.
- **Teardown:** a separate guarded workflow `teardown.yml` (`workflow_dispatch`) — not a third `action`
  on deploy — because destroy needs stronger/different guards and reverse ordering. Inputs: `confirm`
  (typed; the run hard-fails unless it equals `destroy`) and `include_bootstrap` (boolean, default
  `false`). Destroys in reverse dependency order, using `az group delete` brute force for the RG-bound
  regional roots **and** `terraform destroy` for the control-plane/tenant roots (`management-groups`,
  `identity`, MG-scoped `security`), which are not resource groups (LESSON 19). **[Amended by ADR-020:
  the brute-force / Terraform split is replaced by uniform `terraform destroy` for all roots; the
  split is now a deferred manual fallback.]**
- **Teardown scope (OQ-012):** workload + platform only by default. `include_bootstrap` **defaults to
  `false`** so the state backend (state SA, CMK KV) and the OIDC app/SP/federation survive a full reset
  and redeploy is immediate. `true` is full scorched-earth (decommission) and additionally needs a
  documented manual `az ad app delete` (the SP cannot delete its own Entra app via ARM Owner).
- **Approval model (OQ-013):** TWO GitHub Environments — `production` gates apply in `deploy.yml`;
  `production-destroy` gates teardown in `teardown.yml` — each with a required reviewer, plus the typed
  `confirm=destroy` guard on teardown. This keeps destroy approval a separate, more deliberate gate.
- **Retire** `apply-on-merge.yml` (deleted; deploys are now explicit — LESSON 17). Keep
  `plan-on-pr.yml` (always-on PR plan) and `validate.yml` (static gate).
- **OIDC federation:** two new federated credentials are required for the gated jobs (their OIDC `sub`
  becomes `repo:<org>/<repo>:environment:<env>`): subjects `...:environment:production` and
  `...:environment:production-destroy` added to `azuread_application.oidc` in `bootstrap/identity.tf`.
  **Bootstrap must be re-applied** for the gated jobs to authenticate.

**Alternatives considered:**
- Third `action=destroy` value on `deploy.yml` — rejected: destroy needs a different gate, reverse
  ordering, and a typed confirm; a separate file makes the blast radius obvious in the Actions UI.
- A `matrix` for `target=all` — rejected: a matrix cannot express the partial cross-root order
  (spokes wait for connectivity + security); a `needs:` graph can, and preserves legitimate parallelism.
- `terraform destroy` for the full reset — rejected: LESSON 19 documents it reliably gets stuck on Azure
  ordering quirks; `az group delete` brute force is the proven demo-reset path for RG-bound roots.
  **[Reversed by ADR-020: LESSON 19's stuck-destroy failures were VM-driven; this no-VM PaaS/control-plane
  POC destroys cleanly with uniform `terraform destroy`, so that is now the accepted full-reset path.]**
- Single Environment for both apply and destroy — rejected: destroy warrants a tighter, separate
  reviewer gate (OQ-013).

**Consequences:**
- Positive: explicit, auditable deploys; one-root and whole-environment paths from one entrypoint;
  destroy is hard to trigger accidentally (typed confirm + dedicated environment); default teardown
  keeps the backend so redeploy needs no re-bootstrap or GitHub-Variable re-wiring.
- Negative / trade-offs: relies on ADR-006's broad SP scope (Owner at Tenant Root MG) for both apply and
  destroy (tracked under OQ-008); `az group delete` brute force loses state fidelity for the reset roots
  (acceptable for a demo — state is recreated greenfield-safe on next apply); `include_bootstrap=true`
  needs a manual `az ad app delete` and (until LESSON 18 deterministic naming lands) a manual
  `poc.backend.hcl` update.
- Follow-ups required: re-apply `bootstrap/` to register the two environment federated credentials;
  create the `production` and `production-destroy` Environments with reviewers; cloud-engineer to migrate
  bootstrap to deterministic (sub-ID-derived) state-backend naming (LESSON 18) before relying on
  `include_bootstrap=true`.

---

### ADR-018: OQ-011 remediation — reconcile module calls to pinned AVM schemas, commit lock files per root, add a CI `terraform validate` gate

- **Date:** 2026-06-27
- **Section:** Cross-cutting (infra hygiene; touches Sections 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** claude (architect), cloud-engineer (execution)

**Context:**
Every section was marked 🟢 Complete in the WORKLOG, but those statuses **predated any real
`terraform validate`** — the work log repeatedly recorded "validate NOT RUN" (no remote-state/firewalled
backend creds during build, and no committed `.terraform.lock.hcl`, so a clean `init` re-resolved modules
to whatever the registry served). The 2026-06-26 remediation pass ran `terraform init -backend=false` +
`validate` on all 10 roots and found schema drift: several calls were written against a module build that
differed from the published pinned tag. Concretely, across the tree the following were stale against the
**pinned** AVM schemas:
- `avm-res-network-virtualnetwork` v0.17.1 — VNet sub-module is `parent_id` (RG resource ID), not
  `resource_group_name` (all 3 spokes + the connectivity hub path).
- `avm-ptn-network-private-link-private-dns-zones` v0.23.1 — `parent_id`, no `resource_group_creation_enabled`.
- `avm-ptn-alz` v0.19.1 — `subscription_placement` object shape `{ subscription_id, management_group_name }`.
- `avm-res-keyvault-vault` — outputs are `name`/`uri`, not a `resource` object.
- `azurerm_private_dns_zone_group` — **not a provider resource type**; the canonical pattern is the nested
  `private_dns_zone_group {}` block on `azurerm_private_endpoint`.
- `azurerm_sentinel_watchlist` — `log_analytics_workspace_id` (azurerm v4), not `workspace_id`.

**Decision:**
Adopt **Option B** (reconcile each call to its already-pinned module/provider schema — *no version bumps*)
as the remediation standard, plus **Option A** (generate and **commit** a `.terraform.lock.hcl` for every
init-able root) so module/provider builds are reproducible and `validate`/`plan` are deterministic going
forward. Lock files for `platform/*` and `landing-zones/*` are now committed; `bootstrap/.terraform.lock.hcl`
stays git-ignored (ADR-005 — one-time local apply). The single exception requiring a version action is the
connectivity azapi pin, handled separately in **ADR-017**. A CI `terraform validate` gate (run
`init -backend=false` + `validate` per root, `fmt -check -recursive`) is added so a 🟢 status can never
again outrun an actual validate; the gate is the new definition of "Complete" for any IaC section.

**Alternatives considered:**
- Bump module versions to match the as-written calls (Option C) — rejected: larger, cross-root change that
  re-opens verification on every consumed input/output; the pinned versions are fine, only the *calls* drifted.
- Leave roots unlocked and rely on registry "latest 0.x" — rejected: that is exactly the drift that let
  "Complete" sections fail a first real validate; non-reproducible by construction.

**Consequences:**
- Positive: 9/10 roots now `init -backend=false` + `validate` clean with committed locks; drift is frozen;
  CI gate makes regressions visible at PR time, not demo time. No behavioral change, no apply.
- Negative / trade-offs: committed lock files must be refreshed deliberately (`terraform init -upgrade`) on
  any future intentional uplift; the CI gate adds ~1–2 min per root to PR runs.
- Follow-ups: cloud-engineer applies ADR-017 (azapi pin) to make connectivity the 10th clean root and commit
  its lock; devsecops-engineer wires the `validate` gate into `.github/workflows/`; reviewer treats a green
  validate gate as a merge precondition. The pre-existing uncommitted G4 files
  (`landing-zones/corp-a1/backup.tf` + corp-a1 outputs/variables) validate clean and should be committed with
  this pass.

---

### ADR-017: Connectivity `azapi` provider pin aligned to `~> 2.5` (module requirement)

- **Date:** 2026-06-27
- **Section:** 8 — Standard Platform Components (Connectivity sub)
- **Status:** Accepted
- **Decision makers:** claude (architect); cloud-engineer applies

**Context:**
`platform/connectivity/providers.tf:19` pins `azapi = "~> 2.4.0"`. A **three-component** `~>` pin means
`>= 2.4.0, < 2.5.0`. The connectivity root composes `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet`
v0.17.1 and `Azure/avm-ptn-network-private-link-private-dns-zones` v0.23.1. Verified at the pinned tags
(2026-06-27): both top-level modules pin `azapi ~> 2.4` (two-component → `>= 2.4.0, < 3.0.0`), but their
nested sub-modules — notably the `subnet` sub-module of `avm-res-network-virtualnetwork` v0.17.1 (consumed
by the hub-and-spoke module) — pin **`azapi ~> 2.5`** (two-component → `>= 2.5.0, < 3.0.0`). The root's
`>= 2.4.0, < 2.5.0` and the sub-modules' `>= 2.5.0` are **disjoint on the lower bound**, so no azapi
version satisfies the whole graph and `terraform init` aborts before producing a lock file. (NOTE: the
remediation note described the sub-module ceiling as `< 2.6.0`; that was a mis-read — a two-component
`~> 2.5` has no 2.6 ceiling. The conflict is purely the root's `< 2.5.0` lower-bound ceiling. The fix is
the same either way.) azapi's latest is 2.10.0 (May 2026), so the 2.5.x line is well-established and stable.

**Decision:**
Bump the connectivity root pin from `azapi = "~> 2.4.0"` to **`azapi = "~> 2.5"`** (i.e. `>= 2.5.0, < 3.0.0`).
This aligns the root with the floor its own sub-modules already require and removes the disjoint constraint;
`init` then selects the highest 2.x azapi satisfying every node (currently 2.10.0) and writes a lock file.
No upper-bound conflict is introduced: every azapi constraint in the graph (`~> 2.4`, `~> 2.5`) intersects
`~> 2.5` at `>= 2.5.0`. The other root providers are independent of azapi and unaffected — `azurerm
~> 4.71.0` (matches modules' `~> 4.0`), `modtm ~> 0.3.0`, `random ~> 3.8.1`. This is the minimal, lowest-risk
resolution.

**Alternatives considered:**
- Pin `azapi = "~> 2.5.0"` (three-component, `>= 2.5.0, < 2.6.0`) — rejected: needlessly tight; would pin
  off 2.6+ while the modules accept the whole 2.x line and the rest of the repo uses two-component azapi
  pins. `~> 2.5` matches module convention and leaves room for in-band patch/minor uplifts.
- Bump the hub-and-spoke / private-dns module versions instead — rejected: a far larger change (re-verify
  every input/output of two pattern modules and their consumed sub-modules) to solve a one-line provider
  pin; the pinned module versions are correct, only the root's provider floor was stale.
- Downgrade the modules to a build that needs only `~> 2.4` — rejected: no such v0.17.1/v0.23.1 build; would
  mean abandoning the pinned, verified versions and is strictly worse.

**Consequences:**
- Positive: connectivity `init -backend=false` should succeed and produce a committable lock file, making it
  the 10th clean-validating root and closing the last OQ-011 item. One-line change, no resource/behavior
  change.
- Negative / trade-offs: a newer azapi (2.10.x) will be locked; azapi 2.x is API-stable (the 2.0 breaking
  change is long past), so risk is low. The committed lock fixes the exact version, so the bump is explicit
  and auditable.
- Follow-ups: cloud-engineer edits `providers.tf:19`, re-runs `init -backend=false` + `validate`, and commits
  `platform/connectivity/.terraform.lock.hcl`. If validate surfaces *further* schema drift in `dns.tf` after
  init finally resolves, treat it under ADR-018 (same reconcile-to-pinned-schema rule) — see task 4 note.

---

### ADR-016: Gap-closure execution sequence (G1–G6) — plan of record

- **Date:** 2026-06-25
- **Section:** Cross-cutting (slots into Sections 8, 9, 11, 12)
- **Status:** Accepted
- **Decision makers:** claude (architect); user to approve cost OQs (OQ-009, OQ-010)

**Context:**
The 2026-06-25 fidelity analysis (ARCHITECTURE.md "ALZ Reference Architecture Fidelity Map") identified
six gaps (G1–G6) vs the Microsoft ALZ Hub & Spoke reference (diagram 2026-04-02). The user directed that
**all gaps be closed**, sequenced by the architect, then handed to the engineering roles under the
reviewer gate. ADR-010…ADR-015 below record the per-gap close/deviation calls; this ADR records the
ordering and the hand-off contract.

**Decision:**
Close G1, G2, G4, G6 outright. Close G3 (DDoS) and G5 (Sandbox/Online subs) **conditionally on user
cost approval** (OQ-009, OQ-010); if not approved, both remain *documented deviations* with the
implementation pre-staged behind a disabled feature flag. Execute in five waves with explicit
dependencies, detailed in `docs/gap-closure-plan.md`:

1. **Wave 1 — G6 Bastion** (connectivity hub; flip existing module flag). No new module.
2. **Wave 2 — G4 corp-a1 backup vault** (parity with corp-a2). Independent; can run parallel to Wave 1.
3. **Wave 3 — G1 Identity subscription domain services** (Entra Domain Services — see ADR-010). New
   `platform/identity/domain-services.tf` + identity VNet + RSV. Depends on connectivity hub (peering)
   and reverses OQ-002.
4. **Wave 4 — G2 Compliant VM template** (Compute Gallery + image definition + Guest Configuration +
   backup policy + tag enforcement). Depends on G4-pattern backup vault precedent; consumes the FinOps
   tag initiative (ADR-008).
5. **Wave 5 — G3 DDoS (conditional) + G5 Sandbox/Online subs (conditional)**. Gated on OQ-009/OQ-010.

**Alternatives considered:**
- Close everything in one mega-session — rejected: violates the one-section-per-session rule and the
  reviewer gate; G1 and G2 alone are each a full section's worth of IaC.
- Defer G1 again — rejected: the user explicitly reversed the deferral; G1 is the only platform pillar
  with zero resources and is the highest-value gap to close.

**Consequences:**
- Positive: an ordered, dependency-aware backlog the cloud-engineer/devsecops-engineer execute one wave
  per session; each wave is independently reviewable and revertible.
- Negative / trade-offs: full closure spans ~5 build sessions plus review; idle cost rises (see per-ADR
  deltas — roughly +$130–190/mo for G1+G2+G4+G6, before the conditional G3/G5).
- Follow-ups: OQ-009 (DDoS cost), OQ-010 (real Sandbox/Online subs) must be answered before Wave 5.

---

### ADR-015: G6 — Deploy Azure Bastion in the primary hub (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (connectivity)
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
The reference diagram places Azure Bastion in the connectivity hub for secure management-plane access to
VMs with no public IP. The repo sets `bastion = false` in both hubs. Closing G1 (Entra DS) and G2 (image
build VM) introduces VMs that need RDP/SSH without public exposure, so Bastion becomes load-bearing.

**Decision:**
CLOSE. Enable Bastion in the **primary** hub only via the existing
`avm-ptn-alz-connectivity-hub-and-spoke-vnet` module's `enabled_resources.bastion = true` plus a
`bastion` config block (Standard SKU, dedicated `AzureBastionSubnet` /26). Secondary hub stays
`bastion = false` to control idle cost; DR-region VM access in a drill routes via the primary hub or a
just-in-time portal Bastion. No new module — this is a config change to a module already in state.

**[Amended 2026-06-27 — on-demand cost posture]:** per the gap-closure cost decision (Entra DS +
on-demand Bastion), Bastion is gated behind **`var.enable_bastion` (default `false`)**, not always-on.
Idle cost is therefore **$0**; operators set `enable_bastion = true` + apply (via `deploy.yml`) to bring
it up on demand, and `false` + apply to remove it. The "Negative" consequence below is superseded.

**Alternatives considered:**
- Bastion in both hubs — rejected: doubles idle cost (~$280/mo) for a POC; secondary-region interactive
  access is rare and can be served by the primary or temporary deployment.
- Native `azurerm_bastion_host` outside the module — rejected: the pattern module owns the hub VNet;
  using its native toggle keeps subnet/IP wiring inside one module and avoids a split-brain VNet.
- Developer SKU Bastion — rejected: does not support the per-VNet peering reach needed across spokes.

**Consequences:**
- Positive: secure management access to Entra DS DCs and the image-build VM with no public IPs; closes
  the reference gap with zero new modules.
- Negative: ~$140/mo idle for the Standard SKU instance + its public IP.
- Follow-ups: cloud-engineer adds the `AzureBastionSubnet` prefix to the hub subnet locals; verify the
  module input shape for `bastion` against v0.17.1 before writing.

---

### ADR-014: G5 — Keep Sandbox + Online collapsed into the shared LZ sub (DEVIATION, conditional close)

- **Date:** 2026-06-25
- **Section:** 9 / 12
- **Status:** Accepted (as deviation) — conditional close tracked in OQ-010
- **Decision makers:** claude (recommends keep-as-deviation); user may override via OQ-010

**Context:**
ADR-003 collapsed the Sandbox and Online archetypes into the single shared Landing Zones subscription to
keep the POC within Visual Studio benefit limits (idle ~$80–150/mo). The reference diagram shows Sandbox
and Online as **separate subscriptions**. The Sandbox and Online **management-group nodes already exist**;
only the subscription boundary is simulated.

**Decision:**
Recommend KEEP-AS-DEVIATION for the POC. Provisioning two more subscriptions is a billing/tenant action
that (a) cannot be done in Terraform without the subscription-vending pattern and EA/MCA billing-account
privileges the POC does not have, and (b) adds no new *architectural* construct — the MG nodes, policy
inheritance, and RG segmentation already demonstrate the boundary. This is a **subscription-count**
fidelity gap, not a capability gap. The user wants all gaps addressed: if faithful multi-sub is required,
OQ-010 captures the override — moving `online-p1` (and a sandbox placeholder) into real subscriptions via
`azurerm_subscription` association under the existing MG nodes once two more sub IDs are supplied.

**Alternatives considered:**
- Provision two real subs now via `azurerm-subscription`/EA vending — rejected for POC: requires billing
  scope the VS-benefit account lacks; risks cost and provisioning failure mid-build.
- Use `avm-ptn-lz-vending` to create the subscriptions — valid production path; deferred to OQ-010
  because it presumes an EA/MCA enrollment account ID the POC does not have.

**Consequences:**
- Positive: no extra idle cost; MG-level boundary already demonstrable; ADR-003 stays coherent.
- Negative: subscription count (5) is below the reference's 7+; documented as a known, intentional POC
  scope limit. Reviewer must accept the deviation explicitly.
- Follow-ups: if OQ-010 is answered "provision real subs," this ADR is superseded and Wave 5 binds
  `online-p1` + a sandbox RG-set to two new subscription IDs under the existing Online/Sandbox MG nodes.

---

### ADR-013: G3 — Azure DDoS Network Protection plan (conditional close, cost-gated)

- **Date:** 2026-06-25
- **Section:** 8 (connectivity)
- **Status:** Accepted (pre-staged, disabled) — conditional close tracked in OQ-009
- **Decision makers:** claude (recommends pre-stage disabled); user decides via OQ-009

**Context:**
The reference diagram shows an Azure DDoS Network Protection plan attached to the hub VNet (protecting
public-facing workloads, e.g. online-p1's AFD/App Gateway). DDoS Network Protection is **~$2,944/mo flat**
(plan covers up to 100 public IPs). The POC's whole-platform idle target is ~$80–150/mo (ADR-003); DDoS
alone is ~20–35x the entire rest of the platform.

**Decision:**
CLOSE *conditionally*. The cloud-engineer writes the construct now — `Azure/avm-res-network-ddosprotectionplan/azurerm`
v0.3.0 (verified on registry 2026-06-25) creating the plan, plus wiring `ddos_protection_plan` onto the
hub VNet and online-p1 spoke VNet — but **behind `var.enable_ddos_protection` defaulting to `false`**.
With the flag false the plan is not created and the repo carries no idle DDoS cost; the documented
deviation in ARCHITECTURE.md is replaced by a one-line flag flip. The user answers OQ-009 to decide
whether to set the flag `true` for any live/faithful-posture demo. This satisfies "all gaps addressed"
(the capability is built and one toggle away) without forcing ~$3k/mo on a portfolio POC.

**Alternatives considered:**
- Deploy DDoS unconditionally — rejected: ~$2,944/mo is indefensible for a portfolio POC; the user
  should make this call, not the architect.
- Leave as a pure documented deviation with no code — rejected: the user wants gaps *addressed*; a
  flag-gated, registry-verified construct is "addressed and one toggle away," strictly better than a doc
  note. (DDoS IP Protection per-IP tier was considered as a cheaper alternative but does not match the
  reference's network-tier plan and is per-IP billed — out of scope; noted in OQ-009.)

**Consequences:**
- Positive: faithful construct exists, version-pinned, reviewer-approved, zero idle cost while disabled.
- Negative: not *active* by default; a live demo of DDoS telemetry requires the flag + the monthly cost.
- Follow-ups: OQ-009 — user decides default flag state and whether to fund DDoS for any recorded demo.

---

### ADR-012: G4 — Add a corp-a1 backup vault (Recovery Services Vault) for parity (CLOSE)

- **Date:** 2026-06-25
- **Section:** 9 (landing zones)
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
corp-a2 has a Recovery Services Vault (`avm-res-recoveryservices-vault` v1.1.3, GeoRedundant). corp-a1 —
the **primary** workload spoke — has none. The reference shows backup in every landing-zone subscription.
This is an availability/asymmetry gap: the primary workload is currently less protected than its DR pair.

**Decision:**
CLOSE. Add an RSV to corp-a1's `rg-corp-a1-shared` using the **same module + pinned version already in
state for corp-a2** (`Azure/avm-res-recoveryservices-vault/azurerm` v1.1.3 — keep the existing pin for
parity and to avoid a cross-spoke version skew; latest is 1.1.11 and can be a separate uplift later).
Storage mode `ZoneRedundant` for corp-a1 (primary stays in-region for RPO; corp-a2 keeps GeoRedundant for
cross-region DR) and a default Azure Backup policy ready for the synthetic-workload VM / future IaaS.

**Alternatives considered:**
- Bump both spokes to v1.1.11 in the same change — rejected: version uplift is a separate concern from
  closing the parity gap; bundling risks a corp-a2 regression in a gap-closure change. Track uplift
  separately.
- GeoRedundant for corp-a1 too — rejected: corp-a1 is the primary; GRS doubles storage egress cost for a
  POC with no cross-region restore requirement on the primary. ZoneRedundant is the cost-right default.

**Consequences:**
- Positive: backup parity across both corp spokes; primary workload now protected; matches reference.
- Negative: ~$5–10/mo (vault is free; cost is protected-instance + storage once items are enrolled —
  near-zero until the synthetic VM is backed up).
- Follow-ups: G2's backup policy and the synthetic §13.4 VM can enrol into this vault later.

---

### ADR-011: G2 — Compliant VM template via Azure Compute Gallery + Guest Configuration (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (new platform component) / 12
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
Design area **G** of the reference calls for a "compliant VM template": a golden image in a shared gallery,
in-guest configuration (DSC / Guest Configuration), a backup policy, and required-tag enforcement. The repo
has **no** gallery, image definition, or guest-configuration construct anywhere. This is a genuine
capability gap, not just a count/cost gap.

**Decision:**
CLOSE. Compose three layers in a new `platform/management/compute-gallery.tf` (gallery is a shared platform
asset, lives in the Management subscription alongside the platform LAW/Automation):

1. **Azure Compute Gallery + image definition** — `Azure/avm-res-compute-gallery/azurerm` **v0.2.0**
   (verified on registry 2026-06-25; the module creates the gallery *and* image definitions via its
   `shared_image_definitions` map input). Define one Linux (Ubuntu 24.04 gen2) image definition to match
   the synthetic workload's distro; image **versions** are produced out-of-band by an Azure Image Builder /
   packer pipeline (documented as the build path; the POC ships the definition + a "bring your own version"
   note rather than running a full bake, to avoid a long-running build dependency).
2. **Guest Configuration assignment** — assign the built-in Azure Policy initiative *"\[Preview\]: Windows/
   Linux machines should meet requirements for the Azure compute security baseline"* (Guest Configuration /
   machineConfiguration) at the Landing Zones MG so any VM (synthetic §13.4 VM, future IaaS) is audited for
   baseline compliance. DEVIATION: full DSC authoring is out of POC scope; the built-in machineConfiguration
   audit initiative is the realistic, maintainable substitute and produces the same "in-guest compliance"
   signal.
3. **Backup policy + required-tag enforcement** — reuse the FinOps tag initiative (ADR-008) already at the
   Globaris root for tag enforcement; the backup policy is provided by the G4 RSV (ADR-012). No new tag
   policy authored.

**Alternatives considered:**
- Hand-author a full DSC configuration + Image Builder bake in-repo — rejected for POC: Image Builder runs
  take 30–60 min and need a build identity + staging RG; the gallery + definition + built-in
  machineConfiguration initiative demonstrates the design area without a brittle long-running bake.
- `avm-ptn-*` for image building — none confirmed published on registry (only the resource-level gallery
  module exists); per CLAUDE.md rule 5 we do not depend on unverified pattern modules.

**Consequences:**
- Positive: design area G is represented end-to-end (gallery, definition, in-guest baseline audit, backup,
  tag enforcement) using one verified AVM module + built-in policy; no custom policy JSON.
- Negative: no actual image *version* is baked by default — the gallery ships empty of versions until a
  packer/Image Builder run populates it. Documented as a follow-up, not a gap in the construct itself.
- Follow-ups: optional §13.x — add an Azure Image Builder template that bakes a version into the definition;
  enrol the baked image's VMs into the G4/corp-a1 RSV.

---

### ADR-010: G1 identity mode — Microsoft Entra Domain Services (reverses OQ-002 "none") (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (Identity subscription)
- **Status:** Accepted — supersedes the OQ-002 "none" resolution (2026-05-14)
- **Decision makers:** claude (architect) — user had deferred the DCs-vs-Entra-DS choice to the architect

**Context:**
G1 is the highest-value gap: the Identity subscription is the only platform pillar with zero resources
(`identity_mode = "none"`, OQ-002). The reference shows the Identity sub hosting either self-managed AD DS
domain controllers on IaaS **or** Microsoft Entra Domain Services, plus an identity VNet and a backup vault.
The user deferred the DCs-vs-Entra-DS decision to the architect and flagged the POC as cost-sensitive
(~$80–150/mo idle target). Verified 2026-06-25: current 2026 CAF identity guidance favours an
"AD-minimization", cloud-first posture — managed **Microsoft Entra Domain Services** over self-managed DCs
when AD DS capability is needed. No AVM module exists for Entra DS (registry 404 for
`avm-res-aad-domainservice`); the native `azurerm_active_directory_domain_service` resource is current
(API 2021-05-01, not deprecated; requires a one-time DS service-principal pre-step in the tenant).

**Decision:**
CLOSE with **Microsoft Entra Domain Services (managed)** as `identity_mode = "entra-ds"`. Reverses the
OQ-002 "none" resolution. The cloud-engineer builds, in `platform/identity/` (which today holds only the
CA/PIM policies):

- An **identity VNet** via `Azure/avm-res-network-virtualnetwork/azurerm` (repo pin **0.17.1**, the version
  already in state across spokes) with a dedicated Entra DS subnet + NSG carrying the
  Microsoft-mandated inbound rules, peered to the **primary hub** (ADR-009 hub).
- A native `azurerm_active_directory_domain_service` (no AVM module exists — `# DEVIATION:` documented),
  **Standard SKU** (single replica set; lowest cost ~$110/mo), `domain_name` from a new
  `var.identity_domain_name` (POC default `aadds.<orgprefix>.onmicrosoft.com` — ties to OQ-003).
- A **Recovery Services Vault** for the identity VNet's future DC/management VMs, same module/pin as G4.

**Alternatives considered:**
- Two B2s DCs on IaaS (`identity_mode = "ad-ds"`, ~$60/mo) — rejected as the default: cheaper, but
  contradicts 2026 CAF AD-minimization guidance, adds OS-patching/DC-promotion/replication management the
  POC would have to demo and maintain, and Entra DS better showcases a modern managed-identity posture.
  Kept as a documented *alternative mode* (the `var.identity_mode` toggle is retained so an operator can
  select `ad-ds` if a self-managed-DC demo is wanted) — but **not** the shipped default.
- Keep `none` — rejected: the user reversed the deferral and wants the gap closed.

**Consequences:**
- Positive: closes the top gap with the CAF-recommended managed option; less to manage/demo than DCs;
  identity VNet + RSV complete the pillar to match the reference. Cheaper than the assumed Entra DS price
  in OQ-002 if Standard SKU is used (~$110/mo vs the DCs' ~$60/mo — the delta funds "no DC management").
- Negative: ~$110/mo idle (Entra DS Standard) — the single biggest line in the gap-closure cost. Requires a
  one-time **manual** tenant pre-step (create the "Domain Controller Services" service principal +
  an `AAD DC Administrators` group) that Terraform cannot do — documented as an operator prerequisite.
  Entra DS only supports User-forest mode (no resource-forest) — acceptable for POC.
- Follow-ups: OQ-002 resolved to `entra-ds`; OQ-003 (domain name) becomes relevant — needs the POC domain.
  Confirm the `azurerm_active_directory_domain_service` argument shape against the provider pinned in
  `platform/identity` before writing; mark `# UNVERIFIED:` if the pin predates the resource's current schema.

---

### ADR-009: Firewall Policy hierarchy — independent policies per hub (no shared parent for POC)

- **Date:** 2026-05-21
- **Section:** 3 — Multi-Region DR Topology
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
PROMPT.md §3 requires a shared Azure Firewall Policy with a parent policy in the primary hub and a child policy in the secondary hub (inheriting via `base_policy_id`). The hub VNets are deployed via `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet/azurerm` v0.17.1, which creates firewall policies internally and does not expose a `base_policy_id` input in the `firewall_policy` configuration block.

**Decision:**
Each hub has an independent Azure Firewall Premium policy with identical configuration (IDPS Alert mode). A shared parent policy is not implemented for the POC. This is documented as a DEVIATION in `platform/connectivity/dr.tf`.

**Alternatives considered:**
- Fork the hub module to expose `base_policy_id` — rejected; forking AVM modules breaks the upgrade path and adds maintenance burden for a POC.
- Migrate firewall policies to standalone `azurerm_firewall_policy` resources outside the module, then link via `base_policy_id` — valid production path; deferred to Section 12 hardening because it requires refactoring the hub module invocation.
- Create a disconnected parent policy resource — rejected; dead code that isn't wired to anything is misleading in a demo context.

**Consequences:**
- Positive: Hub module stays unmodified; upgrade path to newer AVM versions preserved.
- Negative: Rule changes must be applied to both hub policies independently until production path is taken.
- Follow-ups: Section 12 should migrate firewall policies out of the hub module and establish the parent/child hierarchy.

---

### ADR-008: Tag governance via built-in Azure Policy Modify initiatives (no AVM, no custom policy JSON)

- **Date:** 2026-05-12
- **Section:** 7
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
Section 7 requires Modify + DINE tag policies on every resource group for 8 mandatory tags, with tag inheritance to child resources. Options were: (A) custom policy definition JSON per tag, (B) built-in Azure Policy definitions composed into a custom initiative, or (C) AVM module.

**Decision:**
Use two built-in Azure Policy definitions composed into a custom `azurerm_policy_set_definition` via `dynamic "policy_definition_reference"` blocks:

- `d157c373-a6c4-483d-aaad-570756956268` — "Add or replace a tag on resource groups" (Modify, RG scope)
- `cd3aa116-8754-49c9-a813-ad46512ece54` — "Inherit a tag from the resource group" (Modify, resource scope)

Both IDs confirmed on azadvertizer.net 2026-05-12. The initiative is scoped to the `globaris` root MG and assigned there with a system-assigned managed identity. The remediation identity receives `Contributor` at the root MG scope.

**Alternatives considered:**

- Custom policy definition JSON per tag — rejected: 16 custom policy definitions (8 tags × 2 effects) creates excessive state surface and maintenance overhead for a POC.
- AVM module for policy — rejected: no `avm-res-authorization-policysetdefinition` module confirmed on registry.terraform.io 2026-05-12.
- `ea3f2387-9b95-492a-a190-fcdc54f7b070` ("Inherit a tag from the resource group if missing") instead of `cd3aa116` — rejected: the "if missing" variant does not overwrite existing incorrect tag values; `cd3aa116` always enforces the correct value from the parent RG.

**Consequences:**

- Positive: no custom policy JSON to maintain; built-in policies are kept current by Microsoft.
- Negative: `CreatedDate` default value is static ("1970-01-01") — the Modify effect cannot use a dynamic `utcNow()` expression. Teams must set `CreatedDate` manually on their RGs.
- Follow-ups: Section 9 landing zone modules should set `CreatedDate` on their RGs at creation time via the `tags` block.

---

### ADR-007: Custom Globaris root management group — override standard ALZ root id

- **Date:** 2026-05-06
- **Section:** 2
- **Status:** Accepted
- **Decision makers:** claude (structural), user (naming)

**Context:**
The `avm-ptn-alz` module loads architecture definitions from the ALZ Library. The standard `alz` architecture uses root MG id `"alz"` and display name `"Azure Landing Zones"`. The POC uses `"Globaris"` as the organisation name, requiring a custom root MG id.

**Decision:**
Create `platform/management-groups/lib/globaris.alz_architecture_definition.json` — a custom architecture definition that retains all standard ALZ archetypes (root, platform, landing_zones, management, connectivity, identity, security, corp, online, decommissioned, sandbox) but sets root id `"globaris"` and display name `"Globaris"`. The custom lib directory is passed as a second `library_references` entry to the `alz` provider.

**Alternatives considered:**
- Use standard `alz` root MG id — rejected: produces `alz` in the Azure portal hierarchy, inconsistent with organisation branding and the expected demo narrative.
- Rename via `azurerm_management_group` rename — rejected: the AVM module owns the lifecycle; external rename would create a state conflict.

**Consequences:**
- Positive: hierarchy displays as "Globaris" in Azure portal; consistent with all naming in `poc.tfvars` and `ARCHITECTURE.md`.
- Negative: a custom lib file must be maintained alongside future ALZ Library updates.
- Follow-ups: when upgrading ALZ Library ref, re-validate that standard archetype names have not changed.

---

### ADR-006: Initial OIDC SP RBAC scope — Owner at Tenant Root MG

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted (temporary; see OQ-008 for scope-down at Section 12)
- **Decision makers:** user

**Context:**
The OIDC service principal must create Management Groups, Policy assignments, role assignments, and resources across all 5 subscriptions. The granular-minimum role set cannot be computed until all sections are built.

**Decision:**
Assign `Owner` to the OIDC SP at Tenant Root Management Group scope for the duration of the POC build (Sections 10a–12). At Section 12, replace with the principle-of-least-privilege role set tracked in OQ-008.

**Alternatives considered:**

- Per-subscription Contributor + scoped UAA — rejected for now: cannot enumerate required role assignments until all resource types are known.
- Owner at subscription level per sub — rejected: Management Group operations (Section 2) require tenant-root scope.

**Consequences:**

- Positive: zero RBAC-related CI failures during build phases 2–11.
- Negative: over-privileged SP; mitigated by POC being a dedicated demo tenant and OQ-008 tracking remediation.
- Follow-ups: OQ-008 must be resolved at Section 12.

---

### ADR-005: Bootstrap layer Terraform state — local, never committed

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user

**Context:**
The bootstrap layer creates the Azure Storage Account used as remote state backend by all other layers — a chicken-and-egg situation.

**Decision:**
Bootstrap uses local Terraform state (`bootstrap/terraform.tfstate`), gitignored and never committed. Bootstrap is a one-time manual `terraform apply`. After apply, outputs are pasted into `envs/poc.backend.hcl` for all subsequent root modules.

**Alternatives considered:**

- Local state committed to `bootstrap-state/` — rejected: state files can contain sensitive values; git history is permanent.
- Azure CLI imperative bootstrap — rejected: defeats "everything as code" and creates undocumented manual state.

**Consequences:**

- Positive: simple, no circular dependency.
- Negative: bootstrap state is not backed up; if lost, `terraform import` is required (documented in `bootstrap/README.md`).
- Follow-ups: `bootstrap/terraform.tfstate*` and `bootstrap/.terraform/` added to `.gitignore`.

---

### ADR-004: State storage CMK — bootstrap dedicated Key Vault in Management sub

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user

**Context:**
PROMPT.md Section 10 requires CMK encryption for the Terraform state Storage Account. CMK requires a Key Vault not yet built in any other section.

**Decision:**
Create a dedicated Key Vault (`kv-tfstate-<suffix>-001`) in `rg-tfstate-mgmt-eus2-001` (Management subscription) as part of the bootstrap layer. The KV holds a single RSA-2048 key for Storage Account CMK. It is NOT replaced by the Security sub KV built in Section 8 — that KV is purpose-built for workload secrets.

**Alternatives considered:**

- Microsoft-managed keys now, upgrade later — rejected: PROMPT.md explicitly requires CMK; a deviation marker would persist for 6+ sessions.
- Security sub KV (built in Section 8) — rejected: blocking CMK on that dependency leaves the state SA unencrypted for 6+ sessions.

**Consequences:**

- Positive: state SA is CMK-encrypted from first `terraform apply`; no deviation markers.
- Negative: a second Key Vault alongside the future Security sub KV; adds ~$5/mo.
- Follow-ups: bootstrap KV is referenced (not replaced) when Section 8 builds the Security sub KV.

---

### ADR-003: Subscription model — Option C (4 platform subs + 1 shared LZ sub)

- **Date:** 2026-05-05
- **Section:** 10a (resolves OQ-001, unblocks Section 2)
- **Status:** Accepted
- **Decision makers:** user

**Context:**
ALZ assumes 6+ subscriptions. For a portfolio POC on a Visual Studio benefit account, options ranged from a single subscription (cheapest) to full multi-sub (most realistic).

**Decision:**
Option C: 4 platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription hosting all Landing Zones and Sandbox. The platform/workload subscription boundary — the most architecturally significant in ALZ — is real. Within-LZ sub boundaries are simulated via MG scope and Resource Group segmentation.

**Alternatives considered:**

- Full multi-sub (Option A) — rejected: Visual Studio benefit accounts are typically capped at 1–5 subs; cost compounds.
- Single sub (Option B) — rejected: collapses the platform/workload boundary; cannot demonstrate MG policy inheritance.

**Consequences:**

- Positive: 5 subscriptions feasible on VS Enterprise; MG hierarchy is real; policy at MG scope behaves correctly.
- Negative: within-LZ sub-level isolation is simulated; documented in `ARCHITECTURE.md`.
- Follow-ups: Section 2 MG hierarchy maps 5 subscription IDs to MG nodes; IDs supplied via `poc.tfvars`.

---

### ADR-002: Treat repo root as alz-poc/ — no nested subdirectory

- **Date:** 2026-05-04
- **Section:** 1
- **Status:** Accepted
- **Decision makers:** claude (structural, low-risk)

**Context:**
PROMPT.md shows `alz-poc/` as the top-level path in the directory tree. The working directory `d:\Azure POC\Azure-Architecture\` already contains the bootstrap files (CLAUDE.md, PROMPT.md, WORKLOG.md, etc.) at its root. Two options: (a) treat the current directory as the repo root and create all subdirectories directly here, or (b) create a nested `alz-poc/` subdirectory inside the existing repo.

**Decision:**
Treat `d:\Azure POC\Azure-Architecture\` as the repo root (equivalent to `alz-poc/`). All directories from the PROMPT.md tree are created directly here, at the same level as CLAUDE.md and WORKLOG.md.

**Alternatives considered:**

- Nested `alz-poc/` subfolder — rejected: bootstrap files already live at the repo root; nesting would split Claude Code workflow files from Terraform files and break the `CLAUDE.md` read-at-start assumption.

**Consequences:**

- Positive: single working directory, no path confusion between Claude workflow files and Terraform structure
- Negative: root is slightly noisier than a clean Terraform project root (contains CLAUDE.md, WORKLOG.md etc.)
- Follow-ups: none

---

### ADR-001: Use AVM Pattern Module for ALZ Foundation

- **Date:** 2026-05-06
- **Section:** 2
- **Status:** Accepted — `Azure/avm-ptn-alz` v0.19.1 confirmed on registry.terraform.io 2026-05-06
- **Decision makers:** user, claude

**Context:**
The ALZ pattern can be implemented via (a) the official `Azure/avm-ptn-alz` Terraform pattern module, (b) the older `Azure/caf-enterprise-scale` module, or (c) hand-rolled MG and policy resources.

**Decision:**
Use `Azure/avm-ptn-alz` v0.19.1. Module confirmed published on Terraform Registry. Pinned to exact version in `platform/management-groups/providers.tf`.

**Alternatives considered:**
- Hand-rolled — rejected: defeats the purpose of using AVM and adds maintenance burden
- `caf-enterprise-scale` only — rejected for primary path: AVM is the forward-looking standard

**Consequences:**
- Positive: aligned with current Microsoft guidance, less custom code to maintain
- Negative: AVM pattern modules are newer and may have rough edges
- Follow-ups: none — ADR resolved

---


### ADR-002: Subscription Model — Platform Multi-Sub, Shared LZ Sub

- **Date:** 2026-05-05
- **Section:** 1 (foundational, surfaces in 2, 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
ALZ canonical pattern uses 6+ subscriptions. Portfolio POC on a Visual Studio benefit account needs to balance architectural fidelity with realistic provisioning constraints and idle cost.

**Decision:**
4 dedicated platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription for all Landing Zones (corp-a1, corp-a2, online-p1) and Sandbox, with separation enforced via Resource Groups, Management Group placement, and policy assignment.

**Alternatives considered:**
- Option A (full 6+ sub multi-sub): rejected for cost (~$200–500/mo idle) and provisioning complexity on Visual Studio benefits
- Option B (single sub everything): rejected because it eliminates the platform/workload boundary that ALZ exists to demonstrate

**Consequences:**
- Positive: Demonstrates the most architecturally important boundary (platform vs workload) at sub-scope; idle cost ~$80–150/mo manageable
- Negative: Corp-vs-online and individual LZ isolation is simulated via RG, not enforced at sub level — must be called out in ARCHITECTURE.md
- Follow-ups: All Terraform module designs must accept a `subscription_id` variable and not assume sub-per-LZ; policy assignments at the Landing Zones MG must compensate for the shared-sub blast radius

---


### ADR-003: Subscription Model — Platform Multi-Sub, Shared LZ Sub

- **Date:** 2026-05-05
- **Section:** Foundational (impacts 2, 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
ALZ canonical pattern uses 6+ subscriptions. Portfolio POC on a Visual Studio benefit account needs to balance architectural fidelity with realistic provisioning constraints and idle cost.

**Decision:**
4 dedicated platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription for all Landing Zones (corp-a1, corp-a2, online-p1) and Sandbox, with separation enforced via Resource Groups, Management Group placement, and policy assignment.

**Alternatives considered:**
- Option A (full 6+ sub multi-sub) — rejected: ~$200–500/mo idle cost; provisioning complexity on Visual Studio benefits
- Option B (single sub everything) — rejected: eliminates the platform/workload boundary that ALZ exists to demonstrate

**Consequences:**
- Positive: demonstrates platform/workload boundary at sub-scope; idle cost ~$80–150/mo
- Negative: corp/online and individual LZ isolation simulated via RG, not enforced at sub level — must be called out in ARCHITECTURE.md
- Follow-ups: all module designs accept `subscription_id` variable; policy assignments at Landing Zones MG must compensate for shared-sub blast radius

---

### ADR-004: State Backend CMK Approach — Dedicated Bootstrap Key Vault

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
PROMPT.md Section 10 mandates CMK encryption on the Terraform state Storage Account. CMK requires a Key Vault with an encryption key, but the security-subscription Key Vault doesn't exist until Section 8.

**Decision:**
Bootstrap a dedicated Key Vault in the Management subscription as part of 10a. This Key Vault holds only the storage encryption key plus any future bootstrap-layer secrets. It is referenced (not destroyed) by later sections.

**Alternatives considered:**
- Microsoft-managed keys — rejected: creates a deviation marker that compounds with later changes
- Use Security-sub Key Vault — rejected: that sub doesn't exist yet

**Consequences:**
- Positive: aligned with PROMPT.md from day one, no deviation marker
- Negative: Management sub now has two Key Vaults (bootstrap + future shared) — naming must distinguish them
- Follow-ups: Section 8 must NOT replace this KV; it must add a separate `kv-mgmt-shared-*` for application secrets

---

### ADR-005: Bootstrap Layer State Strategy — Local, Never Committed

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
The bootstrap layer creates the remote state backend. Its own state cannot live in the backend it creates — chicken-and-egg.

**Decision:**
Bootstrap layer uses local Terraform state. The state file is gitignored and never committed. Procedure documented as one-time manual apply in `bootstrap/README.md`. If the bootstrap state is lost, recovery path is `terraform import` against existing Azure resources.

**Alternatives considered:**
- Local state in private gitignored folder, committed encrypted — rejected: adds SOPS/git-crypt overhead for a one-time apply
- Imperative Azure CLI bootstrap — rejected: loses Terraform's state and import benefits

**Consequences:**
- Positive: simplest possible bootstrap; clear separation between "platform" and "platform of platform"
- Negative: bootstrap can drift if applied from a different machine; recovery requires `terraform import`
- Follow-ups: Section 12 acceptance criteria must include a documented bootstrap recovery drill

---

### ADR-006: Initial OIDC Service Principal RBAC Scope

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted (with deliberate scope-down deferral — see OQ-008)
- **Decision makers:** user, claude

**Context:**
The OIDC SP needs sufficient privilege to deploy ALZ — creating Management Groups, applying policies at MG scope, creating resources across 5 subscriptions. Strict least-privilege would require careful per-scope role assignments before any deployment can succeed.

**Decision:**
For Days 2–11, grant the OIDC SP **Owner at Tenant Root Management Group**. This is documented as a deliberate POC compromise. Section 12 must replace this with scoped roles before the POC is treated as "done."

**Alternatives considered:**
- Per-sub Contributor + Resource Policy Contributor + UAA from day one — rejected: would consume an entire session of RBAC plumbing before any architectural work, and would still need adjustment as new sections add new resource types
- Owner at each sub individually — rejected: doesn't grant MG-scope policy creation

**Consequences:**
- Positive: unblocks all subsequent sessions immediately; minimizes RBAC churn during build
- Negative: SP is over-privileged for the duration of the build; MUST NOT be reused in any other tenant or repurposed for a customer environment
- Follow-ups (tracked in OQ-008): Section 12 replaces with per-sub Contributor + Resource Policy Contributor at MG + UAA where role assignments are managed

---
