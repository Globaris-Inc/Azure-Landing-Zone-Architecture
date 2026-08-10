# Strategic review - 2026-08-09: the diagnostic-precascade silent miss, and the rebuild-model decision

**Author:** architect. **Status:** DRAFT FOR OPERATOR PROMOTION - nothing in this file is in
`DECISIONS.md` or `OPEN-QUESTIONS.md` yet. Part 2 is draft ADR-076, Part 3 is draft ADR-077,
Part 4 holds two draft OQ entries (proposed numbers OQ-075, OQ-076), Part 5 is a record
correction to apply by dated addendum. Promote by copying the marked blocks; the surrounding
analysis stays here as the working record.

**Trigger:** attempt 7 (2026-08-09) ran Steps 1-7 GREEN on exact bars and failed Step 8
(`landing-zones/bank-data-p1`, apply run `31348557765`) on ONE resource of 76:
`module.databricks_workspace["main"].azurerm_monitor_diagnostic_setting.this["platform_law"]`,
`already exists` on `diag-dbw-bank-data-p1-globaris-poc` - the PC-1DIAG class the 2026-08-02
ruling declared a failure. The operator directed a full teardown (in flight as this is written)
and held attempt 8 pending this review, under the 2026-08-09 standing directive: no further
teardown-rebuild cycle until the rebuild model itself is re-decided.

Every run id, date and count in this file is taken from `WORKLOG.md`, the day files
(2026-08-01 through 2026-08-09), ADR-071/072/075, or was re-derived from the tree this session;
none is from memory. Claims at reduced confidence are marked as such and carry the read that
would settle them.

---

## Part 1 - Analysis: why the diagnostic precascade misses settings while reporting success

### 1.1 What actually runs

The "Phase 0.5 - DIAGNOSTIC PRECASCADE" job in `.github/workflows/teardown.yml` (job id
`diagnostic-precascade`, gated `target=all AND mode=terraform`, `needs: [guard]` only) runs
`scripts/teardown-diagnostic-precascade.sh`, which calls
`sweep_resource_diagnostic_settings` in `scripts/teardown-common.sh` (lines 1119-1174,
re-derived this session). Enumeration shape:

```
teardown_subscriptions -> discover_live_rgs (RG_SWEEP_QUERY filter)
  -> az resource list per RG -> diagnosticSettings LIST per resource id
  -> DELETE + confirm-GET per setting name
```

The same function body is Phase 2's step 2-pre in `scripts/teardown-az-sweep.sh` (line 430).

### 1.2 The four limbs that let a miss coexist with SUCCESS

**Limb 1 - the sweep can only see a setting whose host is live at the moment of enumeration,
and the teardown's own sibling deletes a host out-of-band.** The Databricks force-delete
precascade (`databricks-precascade`, ADR-066 decision 4, in the tree since PR #54, 2026-07-30)
submits `az databricks workspace delete --no-wait --force-deletion` for every live workspace
before Phase 1 starts. In `teardown.yml` it runs CONCURRENTLY with `diagnostic-precascade` -
both `needs: [guard]` only, and the comment at teardown.yml (Phase 0.5 block) asserts they
"act on disjoint object classes." **That assertion is false for Databricks-hosted diagnostic
settings:** `diag-dbw-*` is an extension object keyed to the workspace URI that
`databricks-precascade` deletes. Whichever job reaches the workspace first wins, and the diag
sweep losing the race is silent (limb 3). The az-sweep path has the same defect
deterministically: `teardown-az-sweep.sh` runs step 1 (Databricks force-delete submission,
lines 384-387) BEFORE step 2-pre (the diag sweep, lines 429-430); its own header comment at
line 111 says "swept AFTER step 1."

**Limb 2 - the mint most plausibly predates the precascade entirely, via the same host, in
teardown run `30685705802` (2026-07-31, `target=all mode=terraform`).** Sequence, each element
independently in the record: (a) the 2026-07-31 B1 recovery run `30671577938` created
`diag-dbw-*` and put it in `bank-data-p1`'s state (ADR-071 context, "4 added"); (b) that
evening's teardown `30685705802` ran the Phase 0.5 `databricks-precascade`, which force-deleted
`dbw-bank-data-p1-globaris-poc` out-of-band BEFORE Phase 1 (ADR-071 decision 5a records
"Phase 0.5 submits a Databricks force-delete BEFORE Phase 1 even starts"); (c) `bank-data-p1`'s
Phase 1 `terraform destroy` then met a host-gone read on the state-held setting and dropped it
from state without any effective backend delete (a DELETE or refresh-GET on an extension path
whose scope resource is gone does not remove the Azure Monitor backend record - the record is
what resurfaced on attempt 7); (d) every later sweep was structurally blind: the 2026-08-01
az-sweep runs (`30719487245`..`30723580651`) and every precascade since ran against estates
where the host did not exist (Step 8 was never reached in attempts 1-6), and an FM-3 object on
a nonexistent host cannot be enumerated (ADR-071 decision 2). The Phase 0.5 diagnostic
precascade itself first ran in the pre-merge smoke test `30724982464` against a greenfield
estate ("proved the WIRING, not the DELETION" - 2026-08-02 record), then in `30777047207`
against attempt 1's Steps-1-2 estate. Its SUCCESS reports were accurate within its design
limits every single time; the design limits are the defect.

**The discriminating signature already in the record:** attempt 7 Step 8 created 75/76,
including the Foundry and Search diagnostic settings (`diag-aif-*`, `diag-srch-*` - the other
two bank-data orphan names from ADR-071's 2026-07-31 table) with zero collisions. Those hosts
were destroyed IN-ORDER by Terraform in `30685705802` (settings deleted first, dependents
before dependencies). Only the host that was force-deleted OUT-OF-BAND produced an orphan.
One mechanism predicts exactly this one-of-three pattern; no competing mechanism does.

**Limb 3 - the error-classification branch conflates three different failures as skippable
noise.** In `sweep_resource_diagnostic_settings`, a failed per-resource diagnosticSettings
LIST is loud only when auth-shaped; ANY other failure "is expected noise for a resource type
that does not support diagnostic settings" and silently skips that resource. That branch
cannot distinguish (i) type-does-not-support (genuinely skippable) from (ii) host mid-delete
or just-deleted (the race in limb 1 - must be loud) from (iii) a persistent non-auth transport
failure after `az_run_retry` exhausts (must be loud). A host deleted between `az resource
list` and the settings GET is silently skipped; a host deleted before `az resource list` never
appears at all.

**Limb 4 - job SUCCESS asserts "the loops completed," not "the estate's settings were
deleted."** There is no expected-set anywhere: no inventory snapshot, no count of settings
found versus deleted versus confirmed gone, no assertion that zero enumerated hosts became
unreachable mid-sweep. The script's closing text ("A zero-deletion result here is NOT
self-evidently correct...") states the exact problem and enforces nothing - it is a comment,
and a comment is not a control (ADR-062). This is the third teardown-completeness defect in
four where a job-level green did not mean per-object completeness (NWTA DCE, out-of-state
App Gateway carcass, this).

### 1.3 Refinement of the 2026-08-02 ruling's prediction

The ruling said "if it fires now, ADR-071 4b regressed." The prediction fired and the reading
needs one refinement: **4b did not regress - it shipped with a coverage hole that predates
it.** The precascade's code ran as built on every run; no run it participated in ever had the
orphan's host live and un-raced. The orphan was minted by the interaction of the Databricks
force-delete (ADR-066 decision 4) with in-order destroy, a window ADR-071's spec never
addressed and its wiring reproduces (limb 1). ADR-071's T3 trigger has now fired ("the class
recurs on a first apply that followed a teardown carrying the Phase 0.5 sweep"), which under
ADR-071's own terms buys the decision-4a fallback, scoped to the failing settings only. The
correct scope of 4a here is narrower than "G-1 refuted": G-1 holds; the sweep's coverage does
not reach a host deleted out-of-band, and exactly one host in the estate is deleted
out-of-band by design.

### 1.4 The structural options, enumerated

**Option 1 - ordering barrier: no host-deleting actor runs until the diagnostic sweep
completes.** `databricks-precascade` gains a `needs: [diagnostic-precascade]` edge (with the
`!cancelled()` form so a sweep failure orders but never gates, preserving ADR-071's
"not a gate" and ADR-066 INV-1); `teardown-az-sweep.sh` moves step 2-pre ABOVE step 1. Cheap
(one workflow edge, one script reorder), closes the known race deterministically. Alone it is
insufficient: a future host-deleting actor re-opens the window silently, and a miss from any
other cause still reports SUCCESS (limb 4 untouched).

**Option 2 - per-setting verification with loud failure (expectation-anchored sweep).** Make
the sweep two-pass: pass A snapshots the inventory (every resource id per estate RG, and every
setting name found per resource) BEFORE any deletion by any actor; pass B deletes and
confirm-GETs each. New mechanical assertions, each individually loud: (i) any
host-absence-shaped error (`ResourceNotFound`, `ResourceGroupNotFound`, or the 403-on-gone-host
form this estate has recorded - ADR-072 decision 4 table) during pass B = FAIL, it means
something deleted a host mid-sweep; (ii) the job summary prints hosts enumerated / settings
found / deleted / confirmed-gone, and SUCCESS requires found == confirmed-gone AND
unreachable-hosts == 0. The noise branch keeps skipping only type-unsupported-shaped errors,
discriminated on error content. This converts limb 3 and limb 4 from prose into controls.
Requires the Option 1 barrier to be meaningful (the snapshot is only complete if nothing is
deleting hosts yet). Residual honesty: it cannot see settings whose hosts died in a PRIOR
estate - already-minted orphans are out of any teardown's reach, which is what the transition
step in 1.6 is for.

**Option 3 - post-precascade assertion pass.** Re-enumerate after the sweep and assert zero
settings remain on any to-be-destroyed host. Weaker than Option 2 (same blindness to
mid-sweep host deletion unless the barrier exists; doubles the enumeration wall-clock; asserts
absence, which is the weaker half of what Option 2's found==confirmed-gone asserts).
Subsumed by Option 2's pass-B accounting; not worth buying separately.

**Option 4 - generation-suffixed HOST names (ADR-075 generalized).** A token in the host name
makes a recreated host a new URI, so no orphan can ever collide. Rejected as the primary fix:
(i) it is symptom-side - FM-3 objects keep accumulating invisibly in the tenant, the
governance cost ADR-071 already refused to accept; (ii) it multiplies ADR-075's own recorded
negatives (burned-name lists, doc/demo literal sweeps that have already missed a site once -
the `estate-bom.md` literal caught one bump late) across up to nine diagnostic-setting hosts;
(iii) ADR-075's token exists because the stale binding is AZURE-side and unfixable from the
repo - here the defect is OUR teardown ordering, which we can fix directly. A one-time,
single-host variant survives as the fallback in 1.6 only if the azapi conversion proves
unavailable.

**Option 5 - an FM-3-aware greenfield check on PREDICTED host ARM paths. Investigated as
directed, and dismissed on verified evidence.** Three sub-paths checked:
- **By the setting's own ARM id:** a diagnostic setting is an extension resource; its only
  address is `{hostId}/providers/Microsoft.Insights/diagnosticSettings/{name}` and ARM routes
  the call through the host scope. With the host gone the call does not return the object -
  this estate's own recorded behaviour is a 403, not the setting (ADR-072 decision 4 table,
  "host gone, object unreachable and undiscoverable (403, not 404)"). A GET that cannot
  return the object cannot detect it.
- **Azure Resource Graph:** ARG does not index `microsoft.insights/diagnosticsettings` at
  all - extension diagnostic settings cannot be enumerated by ARG even for LIVE hosts
  (verified against the Microsoft Q&A thread on exactly this question, learn.microsoft.com
  `/answers/questions/1665007/`, which concludes the type "does not seem to be available in
  Azure Resource Graph" and that ARM iteration per resource is the only path; consistent with
  the ARG supported-tables reference). So there is no side-channel listing.
- **Activity Log diff (writes minus deletes on `Microsoft.Insights/diagnosticSettings/write`
  at predicted host ids):** viable only as FORENSICS - 90-day window, proves a write happened,
  cannot prove current existence. Named in ADR-071 T2 already. Useful for provenance reads,
  not as a gate.
Conclusion: **there is no discovery path for an FM-3 diagnostic setting while its host does
not exist.** The class must be prevented at teardown (Options 1+2) or made harmless at apply
(the azapi idempotent PUT). A greenfield gate cannot be built, and pretending one exists
would be a gate that passes vacuously - worse than none.

### 1.5 Recommendation

**Options 1 + 2 as ONE consolidated fix-spec (LESSON 59), DevSecOps lane, before attempt 8**,
with the regression suite extended under the fixture-RED-first discipline (doctrine 2d:
correct the stub to real `az` output shape, prove the new assertions fail against the current
code, then fix): `scripts/test-teardown-diagnostic-sweep.sh` gains cases for (a) the
host-absence-shaped error being loud, (b) the found/deleted/confirmed accounting, (c) the
ordering edge existing in `teardown.yml` (a YAML-level check), (d) the az-sweep step order.
Plus the **scoped ADR-071 4a fallback, already pre-authorized and now triggered:** convert the
Databricks workspace diagnostic setting in `bank-data-p1` from the AVM module's
`diagnostic_settings` input to a root-level `azapi_resource`
(`Microsoft.Insights/diagnosticSettings@2021-05-01-preview`), whose idempotent PUT overwrites
any orphan instead of colliding - the estate's own `module.datalake` azapi-based setting
"never failed in the same runs that killed three azurerm siblings" (ADR-071 4a, live
evidence). This host is the only one in the estate deleted out-of-band by design (ADR-072 C4
establishes the force-delete as permanent), so it is the one host whose settings warrant
apply-side idempotence as a belt even after the teardown fix lands. Cloud Engineer lane; the
Step 8 bar stays 76 (1:1 resource swap); the azapi body's log/metric categories must be
verified against the live API at implementation (LESSON 27 surface - prefer `categoryGroup`
over hand-listed categories if the type supports it; verify, do not assume).

Draft ADR text: Part 2 below.

### 1.6 The attempt-8 transition problem, stated honestly

Whether the CURRENT in-flight teardown cleared the orphan is knowable only from its own log,
and must be read, not assumed (doctrine 2a). The orphan sits on the RECREATED live workspace,
so this teardown is the first since the mint where the diag sweep could reach it - IF it beat
the concurrent `databricks-precascade` to the host, which is a race (limb 1).
**Decisive read, required before attempt 8:** the in-flight run's `diagnostic-precascade` job
log either contains `Deleting resource-scoped diagnostic setting
diag-dbw-bank-data-p1-globaris-poc` followed by a passing confirm-GET (orphan CLEARED), or it
does not (orphan presumed to persist; no later read can see it - 1.4 Option 5). If it
persists, the azapi conversion in 1.5 makes Step 8 immune regardless; that is why the
conversion is recommended unconditionally rather than only on a bad read. This is OQ-075
(Part 4).

---

## Part 2 - DRAFT ADR-076 (for promotion to DECISIONS.md)

### ADR-076: The attempt-7 Step 8 orphan is NOT a regression of ADR-071 4b but a coverage hole that predates it - the Databricks force-delete precascade deletes the one out-of-band host while the diagnostic sweep has no ordering barrier and no completeness assertion, so a silent miss reports job SUCCESS. The fix is an ordering barrier (diag sweep strictly before ANY host-deleting actor, both modes) plus an expectation-anchored per-setting verification whose SUCCESS is found==confirmed-gone AND unreachable-hosts==0, plus the pre-authorized scoped azapi conversion of the Databricks workspace setting. FM-3 remains undetectable while the host is absent - verified against ARM routing, Azure Resource Graph, and this estate's own recorded 403 - so no greenfield gate is built

- **Date:** 2026-08-09
- **Section:** 10 (Pipeline and Tooling - the teardown belts) / 9 (Landing Zone Spokes - the
  azapi conversion). **Extends ADR-071** (decision 4b's coverage; exercises the decision-4a
  pre-authorization on its stated T3 trigger). **Extends ADR-072's** sweep-ordering table with
  the third ordering fact: a Phase 0.5 host-deleting actor is a Phase 1 destroy brought
  forward, and the G-1 rule ("sweep before the host dies") binds against it identically.
  **Corrects the teardown.yml Phase 0.5 comment** ("disjoint object classes" - false for
  Databricks-hosted settings). Applies ADR-062 (a comment is not a control), LESSON 59 (one
  consolidated fix-spec), doctrine 2d (fixture-RED-first). Relates to the 2026-08-02 PC-1DIAG
  ruling (its prediction fired; its reading is refined, not reversed).
- **Status:** Proposed (architect draft, this review; Accepted on operator promotion)
- **Landed:** NOT IMPLEMENTED. Decisions 1-3 are a written spec for DevSecOps (one PR:
  `teardown.yml` ordering edge, `teardown-az-sweep.sh` step reorder,
  `sweep_resource_diagnostic_settings` two-pass accounting + error discrimination, regression
  suite extension). Decision 4 is a written spec for the Cloud Engineer (one PR: the
  bank-data-p1 azapi conversion). Update by dated addendum when each merges.
- **Decision makers:** claude (architect); operator (directed the strategic review and holds
  promotion).

**Context:** compressed from Part 1 of `docs/strategic-review-2026-08-09.md` - the four limbs
(host-liveness dependency raced by the concurrent Databricks force-delete; the pre-precascade
mint in run `30685705802` via out-of-band host delete against in-order destroy; the noise
branch conflating host-absence with type-unsupported; SUCCESS asserting loop completion, not
completeness), and the one-of-three signature (attempt 7 run `31348557765`: `diag-aif-*` and
`diag-srch-*` created clean, only `diag-dbw-*` collided) that discriminates the mechanism.

**Decision:**

1. **Ordering barrier.** `databricks-precascade` runs strictly AFTER `diagnostic-precascade`
   (`needs` edge, `!cancelled()` form - ordering, never gating, per ADR-071 "not a gate" and
   ADR-066 INV-1). `teardown-az-sweep.sh` runs the diagnostic sweep BEFORE the Databricks
   force-delete submission. Standing rule for future actors, added to the teardown docs: **any
   job or step that deletes an estate host outside its owning root's in-order destroy MUST
   order after the diagnostic sweep** - the ADR-072 mirror table gains this row.
2. **Expectation-anchored verification.** The sweep snapshots its inventory before any
   deletion, then deletes and confirm-GETs; SUCCESS requires settings-found ==
   settings-confirmed-gone AND mid-sweep-unreachable-hosts == 0, printed in the job summary.
   Host-absence-shaped errors (ResourceNotFound / ResourceGroupNotFound / the recorded
   403-on-gone-host form) are LOUD; only type-unsupported-shaped errors remain skippable.
   The existing "zero is not self-evidently correct" echo is retired in favour of the
   mechanical assertion (ADR-062).
3. **Test discipline.** `scripts/test-teardown-diagnostic-sweep.sh` extended under
   fixture-RED-first; the new assertions must be shown failing against the unfixed code with
   numbers stated before the fix lands.
4. **Scoped azapi conversion (ADR-071 4a, triggered).** The bank-data-p1 Databricks workspace
   diagnostic setting moves to a root-level `azapi_resource`
   (`Microsoft.Insights/diagnosticSettings@2021-05-01-preview`); idempotent PUT, no
   RequiresImport pre-check, overwrites any surviving orphan. Scoped to THIS setting only -
   the only setting whose host is deleted out-of-band by design (ADR-072 C4). Step 8 bar
   stays 76. Categories verified live at implementation; prefer `categoryGroup` if supported.
5. **No FM-3 greenfield gate is built.** Verified unavailable: ARM routes extension-resource
   calls through the host scope (recorded 403 with host gone, ADR-072 table); Azure Resource
   Graph does not index `microsoft.insights/diagnosticsettings` (Microsoft Q&A
   `/answers/questions/1665007/`, checked 2026-08-09); Activity Log diffs are forensics with a
   90-day window, not a gate. A vacuously-passing gate would be worse than none.

**Alternatives considered:** post-precascade assertion pass (subsumed by decision 2's
accounting); generation-suffixed host names (rejected as primary - symptom-side, multiplies
ADR-075's burned-name and literal-sweep costs across up to nine hosts, leaves tenant debris
accumulating; retained as single-host fallback only if the azapi conversion proves
unavailable); do-nothing-plus-B1 (rejected - the 2026-08-02 ruling stands, and the class just
cost a full rebuild attempt).

**Acceptance:** (i) suite extension shown RED against unfixed code, then green; (ii) the next
`target=all mode=terraform` teardown of an estate holding a live Databricks workspace shows,
in-log and in-order, the `diag-dbw-*` deletion + confirm-GET COMPLETING BEFORE the Databricks
delete submission line, with found==confirmed-gone and unreachable-hosts==0 in the summary;
(iii) the next greenfield Step 8 apply reports zero `already exists` (ADR-071 T3, restated).

**Consequences:** positive - the silent-miss class gets a mechanical completeness assertion,
the known race is closed by construction, Step 8 becomes orphan-immune at apply as a belt;
negative - the sweep grows a second pass (wall-clock, minutes), the azapi conversion
hand-authors a category body on the AVM module's supported interface (the ADR-038/LESSON 27
trade ADR-071 4a priced and accepted for exactly this scope); the ordering rule is one more
constraint future teardown work must know (mitigated by the ADR-072 table row).
**Follow-ups:** DevSecOps PR (decisions 1-3), Cloud Engineer PR (decision 4), the Part 5
record correction, OQ-075's log read before attempt 8.

---

## Part 3 - DRAFT ADR-077 (for promotion): the rebuild-model decision

### ADR-077: The one-clean-pass standard is RETIRED as the gating validation model. The standard could not be met by a correct repo - ~28 serial runs where one vendor-side fault forfeits the pass and triggers a teardown that is itself the estate's main generator of new latent failure classes and burns an ADR-075 generation per reset. Replaced by: greenfield-to-green with documented bounded recovery (the claim), evidence-bound same-step retry for Azure-side transients (the mechanism), layer scoring as claim structure (platform 1-4 is already banked from attempt 7), and a hardening-pass/claim-pass split so remaining latent classes are flushed in ONE estate lifetime instead of one per teardown cycle. Standing rule 1's automatic-teardown consequence is replaced by classify-then-disposition; a full teardown becomes the remedy for estate-poisoning residue, not the default consequence of any failure

- **Date:** 2026-08-09
- **Section:** 10 (Pipeline and Tooling) / 12 (Acceptance Criteria Validation - the claim
  text). **Amends** the 2026-08-02 standing rule 1 (any failure -> full teardown) and the
  2026-08-03 restart-conditions pattern. **Interacts with ADR-075 decision 6** (the
  generation-burn mandate stays, but fires far less often because teardowns stop being the
  default consequence). Preserves the 2026-08-02 PC-1DIAG ruling (an `already exists` is
  never a retryable transient). Applies doctrine 1d at run scale: a bar a correct system
  cannot meet is not a gate, it is noise that trains operators to override.
- **Status:** Proposed (architect draft; this is the operator's decision to make - the
  standing directive asked for exactly this ruling)
- **Landed:** N/A on promotion for decisions 1-3 and 5 (operating rules and claim text -
  DEPLOYMENT.md / acceptance-doc edits, docs lane); decision 4's retry bar needs no code
  (it is an operator procedure) unless the operator later asks for workflow support.
- **Decision makers:** operator (the standard is theirs); claude (architect,
  recommendation and framing).

**Context - the seven-attempt evidence, compressed.** Since 2026-08-02, seven full greenfield
attempts: A1 failed Step 2 (`30776463447`, stale `budget_start_date` - repo class, fixed
PR #100); A2 failed Step 3 (`30784028698`, nine Sentinel 401s) and A3 failed Step 3
(`30844075060`, seven 400s naming a purged workspace GUID) - one class, fixed by ADR-075's
generation token and confirmed clean on r2/r3/r4 across attempts 4/5/7; A4 was ABORTED BY
CHOICE while green at Step 4 (clean-run reset after a mid-run secret repair); A5 ran Steps 1-6
green and failed Step 7 (`31059957430`, Azure-side `InternalServerError` 500 on the App
Gateway create - cleared as a one-off on attempt 7); A6 failed Step 3 PRE-Terraform
(`31219463271`, state-SA flip race - lane class, fixed PR #109); A7 ran Steps 1-7 green and
failed Step 8 (`31348557765`, the FM-3 orphan - ADR-076). Facts that bound the decision:

- **No fixed class has ever recurred.** Budget dates, ADR-075 (three consecutive clean
  generations), secret swap-proofing, flip retry - all held once fixed.
- **Every failure was a NEW class**, and the frontier advanced: 2, 3, 3, (green abort), 7,
  3-lane, 8. Roughly 65 plan/apply runs across the series (re-derived by counting the attempt
  tables); exactly ONE was a pure Azure-side stochastic fault (the A5 500).
- **The transient-only model already caps the standard.** 14 steps = 28 serial runs; at the
  observed ~1.5 percent per-run vendor-fault rate, a fully-correct repo completes an attempt
  with probability roughly 0.985^28, about 65 percent (band 57-75 percent for 1-2 percent
  rates). The standard therefore forfeits about one attempt in three to faults NO repo change
  can prevent - doctrine 1d's "bar a correct plan cannot meet," at run scale.
- **The reset operation mints failure classes.** Three of the last four teardown-completeness
  defects are silent-miss classes in belts that reported job-level success (NWTA DCE,
  out-of-state App Gateway carcass, the ADR-076 diagnostic miss). Under the current model,
  every failure runs the class-generator once more, so iterating does not reliably converge.
- **Each reset that reached Step 3 burns an ADR-075 generation** and mandates a bump PR
  before the next Step 3 (PR #106's envelope: 8 files; the literal sweep has already missed a
  site once). Burned: `<none>`, r2, r3, r4; the r5 bump is in flight for the current
  teardown. The "one clean pass with zero repo changes between attempts" framing is already
  not literally achievable under its own reset mechanism.
- **Steps 9-14 are unexplored in this series** (identity two-pass, the 60-180-minute Pass 1
  among them). Any remaining latent class lives there and is discoverable only by reaching it.

**Decision:**

1. **(a) Status quo is RETIRED as the gating standard.** Stated fully in context above: it is
   an availability claim about 28 serial draws against vendor faults plus a reset operator
   that manufactures new latent classes and burns generations. It is kept only as an
   automatic upgrade: if a claim pass (decision 5) happens to complete with zero retries, the
   claim upgrades itself to the uninterrupted form, and nothing is lost by not gating on it.

2. **(d) The validation claim is REFRAMED, and this text (or operator-edited equivalent) goes
   into DEPLOYMENT.md and the acceptance docs:**

   > **Validation standard: greenfield-to-green with documented bounded recovery.** The
   > estate deploys from a live-verified empty tenant (0 estate resource groups, 0
   > soft-deleted workspaces, 1 management group, all state at the empty baseline) to the
   > full landing zone - fourteen steps, 1,789 resources by the certified per-step plan bars -
   > exclusively through the gated CI/CD pipeline at a single repo SHA, with an exact plan
   > bar and a plan-shape gate (zero replace, zero destroy, zero import) on every step.
   > Azure-side transient faults are retried at the failed step only, at most once per step,
   > only on written evidence the fault was service-side, with the evidence logged before
   > the retry is dispatched. No console repairs, no state surgery, no unlogged mutations.
   > The rebuild series' full failure taxonomy and the class fixes it produced are part of
   > the deliverable.

   Why this is defensible for a portfolio POC rather than a retreat: it is the standard
   production platform engineering actually holds itself to - reproducibility plus bounded,
   evidenced, documented recovery - and it is HARDER to fake than a lucky pass, because the
   worklog trail is the artifact. The vendor's own faults are live-evidenced in this record
   (A5's 500 on a create that was green before and after with identical code); a claim that
   pretends those cannot happen is weaker to a technical reviewer, not stronger.

3. **(c) Layer scoring is adopted as CLAIM STRUCTURE ONLY, not as reset mechanics.** Layers:
   platform (Steps 1-4), spokes (5-9), identity (10-11), validation/demo (12-14). Each layer
   proven green on exact bars on top of a live-verified clean substrate is independently
   citable; **attempt 7 already banked the platform layer** (537/38/48/696 uninterrupted,
   runs `31319027114`/`31336038005`/`31337902958`/`31341025124`) and Steps 5-7 of the spoke
   layer. Layer-scoped RESET mechanics (per-layer teardown lanes) are NOT bought: single-root
   destroys bypass the Phase 0/0.5/2 belts (the precascade's own scope note records the
   single-root exclusion), bank-data-p1's single-root destroy retains the Databricks managed
   RG (the force-delete precascade exists because of exactly this), and building belted
   per-layer teardown is real DevSecOps scope with no claim benefit over decisions 2+4.

4. **(b) Bounded same-step retry, evidence-bound - the precise bar.**
   - **Pre-authorized classes (retry without an architect round-trip):**
     - **T-A, Azure service-side fault:** HTTP 5xx / `InternalServerError` with empty or
       generic code, no policy, auth, quota or validation text, on a resource whose identical
       configuration has applied green in a prior live run of this estate. (A5's App Gateway
       500 is the type specimen.)
     - **T-B, pre-Terraform lane failure:** the job died before `terraform init`;
       `Creation complete` count 0; the root's state blob content byte-identical to the empty
       baseline (the 2026-08-04 exception's evidence shape, now standing). (A6's flip race is
       the type specimen; its class is fixed, the shape generalizes.)
   - **Never retryable:** any `already exists` (PC-1DIAG - the 2026-08-02 ruling stands
     unchanged), any 4xx (policy, auth, quota, validation), any Sentinel resolution-shaped
     failure (ADR-075's trigger), any plan-bar or plan-shape miss, and any failure OF a
     retry.
   - **Bounds:** at most ONE retry per step; at most TWO retried steps per attempt; a second
     failure of the same step is a STOP for the architect - this generalizes the already-armed
     Step 7 two-500s escalation rule, which is the existing precedent for exactly this
     policy.
   - **Carcass rule:** if the failed create left an out-of-state object, the retry
     additionally requires: a live read of the object's provisioningState, a logged DELETE
     with confirm-GET, then plan-scan-apply (ADR-060) with a pure-adds bar (zero replace,
     zero destroy, zero import; changes limited to known-benign classes). Evidence-bound,
     logged BEFORE action - distinct in kind from the suspended blind B1 auto-recovery.
   - **Arbitration and record:** the evidence pack (error text, live reads, state check) is
     logged in the day file BEFORE the retry dispatch; the operator approves in-channel
     against this written bar; anything outside T-A/T-B goes to the architect BEFORE any
     action. The attempt table carries a RETRY row naming the class and the evidence.
   - **ADR-075 interaction:** a same-step retry never tears down, never purges the security
     LAW, never burns a generation, never needs a bump PR. Decision 6 of ADR-075 is
     untouched and fires exactly when a real purge happens.

5. **The hardening-pass / claim-pass split - the transition plan this review exists to
   produce.** The next rebuild (attempt 8) is designated a **HARDENING PASS**: it runs under
   decisions 2-4, and if it fails on a NEW deterministic class at step K, the disposition is
   fix-and-continue FROM step K (all fixes through the review gate, all logged) rather than
   teardown - driving ONE estate lifetime through all fourteen steps so every remaining
   latent class is flushed in a single cycle instead of one per teardown. Only after a full
   greenfield-to-green traversal exists does the operator decide whether to buy a final
   teardown plus **CLAIM PASS** at a fixed SHA under decision 2's text. Rationale: the
   series' binding cost is teardown cycles (each one mints risk and burns a generation);
   the cheapest path to a defensible claim is maximum class-discovery per cycle, then one
   clean demonstration. If the hardening pass happens to run clean end-to-end, it IS the
   claim pass and the decision collapses.
   **Preconditions for attempt 8, all before dispatch:** ADR-076 decisions 1-3 merged
   (DevSecOps) and 4 merged (Cloud Engineer); the ADR-075 r5 bump merged (in flight); the
   OQ-075 log read executed and recorded; greenfield re-verified live on the standard limbs;
   pre-clearance refreshed (repo state will have advanced past refresh #5 by several PRs -
   the standing refresh rule applies); the OQ-070 budget window checked (valid to
   2026-08-31 - after that the Step 2 date class re-fires and the date must be rolled first).

6. **Standing rule 1 is REPLACED by classify-then-disposition:** on any step failure - STOP,
   log, diagnose to class with the refuting measurement run (doctrine 2a). Disposition by
   class: (i) T-A/T-B transient -> bounded same-step retry per decision 4; (ii) repo defect ->
   fix as a class through the review gate, then continue from the failed step on a hardening
   pass, or reset per the operator's claim-pass judgement; (iii) estate-poisoning residue
   (FM-1/FM-2/FM-3 shapes, non-deletable blockers, anything ADR-067-shaped) -> full teardown
   to verified greenfield, with the ADR-075 bump if the current security-LAW generation is
   purged. **A full teardown is the remedy for a poisoned estate, not the consequence of an
   imperfect run.** The failure-record discipline (log first, STOP, operator) is unchanged in
   every branch.

**Alternatives considered:** keeping (a) with only the ADR-076 fix landed (rejected: the
transient-only cap stands at roughly one forfeit in three attempts, and every forfeit
re-runs the class-generator and burns a generation); (c) with real per-layer teardown
mechanics (rejected for now: new belted-teardown engineering, no claim benefit over (b)+(d);
revisit only if a claim pass repeatedly dies in one layer); (b) alone without the reframed
claim (rejected: a retry that the claim text cannot admit is a hidden repair - the claim and
the mechanism must match or the record is dishonest).

**Consequences:** positive - the validation claim becomes achievable by a correct repo,
attempts stop forfeiting to vendor faults, teardown frequency (and with it generation burn
and silent-miss minting) drops to actual need, the platform layer's banked proof stops being
re-litigated, and the seven-attempt record converts from an embarrassment into the
deliverable's strongest artifact. Negative, stated plainly - the headline claim is weaker
than "one uninterrupted pass, ever, no retries"; anyone reading the acceptance docs will see
retries and recoveries in the record (that is the point, but it is a real trade); the retry
bar adds operator judgement at failure time (bounded by the written classes and the
architect referral). **Follow-ups:** claim text into DEPLOYMENT.md and
`docs/acceptance-validation.md` (docs lane) on promotion; the attempt-8 preconditions
tracked in the WORKLOG handoff; OQ-076 records the operator decision itself.

---

## Part 4 - DRAFT OQ entries (for promotion to OPEN-QUESTIONS.md)

### OQ-075: Did the 2026-08-09 teardown clear the dbw diagnostic-setting orphan, and is the azapi conversion or an accept-risk disposition in force for attempt 8's Step 8? (proposed number - verify against the file's sequence at promotion; last recorded is OQ-074)

- **Raised:** 2026-08-09 (strategic review, Part 1 section 1.6). **Priority:** High - gates
  attempt 8's Step 8 risk posture.
- **Question:** the orphan `diag-dbw-bank-data-p1-globaris-poc` sat on the live recreated
  workspace when the attempt-7 teardown dispatched, so that teardown's `diagnostic-precascade`
  job could clear it ONLY if it beat the concurrent `databricks-precascade` to the host
  (ADR-076 limb 1). Once the host is gone, no read can see the setting (ADR-076 decision 5).
  **The one decisive read:** does the teardown run's `diagnostic-precascade` job log contain
  `Deleting resource-scoped diagnostic setting diag-dbw-bank-data-p1-globaris-poc` with a
  passing confirm-GET?
- **Options:** (a) log line present + confirm-GET pass -> orphan CLEARED; record it, proceed
  (the ADR-076 azapi conversion still lands as the belt). (b) absent -> orphan PRESUMED LIVE
  and invisible; the azapi conversion becomes the only deterministic protection for Step 8.
  (c) absent AND conversion rejected -> accept-risk: pre-authorize a single-setting
  evidence-bound recovery at Step 8 (delete the one named survivor with confirm-GET, then
  plan-scan-apply on a pure-adds bar) - a dated, bounded exception to the PC-1DIAG ruling for
  exactly this named object, once.
- **Recommended default:** run the read either way; land the conversion either way (option a
  or b); option c only if the operator rejects the conversion.
- **Supporting forensic reads, cheap and non-blocking (close ADR-076's provenance to
  measured):** T-A - run `30685705802`, `bank-data-p1 / destroy` job log: did
  `azurerm_monitor_diagnostic_setting.this["platform_law"]` log a normal
  `Destruction complete`, or was it dropped at refresh (host-gone)? The `diag-aif-*` /
  `diag-srch-*` siblings should show normal destruction - the contrast is the mechanism
  proof. T-B - same run, `databricks-precascade` job log: the force-delete submission line
  for `dbw-bank-data-p1-globaris-poc` and its timestamp versus the destroy job's.

### OQ-076: Ratify the rebuild model (draft ADR-077) - operator decision

- **Raised:** 2026-08-09 (strategic review, Part 3). **Priority:** Blocking for attempt 8 -
  the 2026-08-09 standing directive holds all rebuild activity until this is decided.
- **Question:** adopt draft ADR-077 (retire the one-clean-pass gate; reframed claim;
  evidence-bound same-step retry with the written T-A/T-B bar; layer scoring as claim
  structure; attempt 8 as a hardening pass with fix-and-continue; standing rule 1 replaced by
  classify-then-disposition)?
- **Options:** (a) adopt as drafted; (b) adopt with the retry bar narrowed (e.g. T-A only,
  one retried step per attempt); (c) keep the one-clean-pass gate and run attempt 8 under it
  with only ADR-076 landed - the review's honest estimate for (c) is roughly a one-in-three
  forfeit rate to vendor faults alone, plus a generation burn and fresh silent-miss exposure
  per forfeit; (d) operator's own composition.
- **Recommended default:** (a). The claim text is decision 2 of the draft; the operator may
  edit its wording at promotion without re-opening the mechanism.

---

## Part 5 - Record correction (apply by dated addendum, do not edit originals)

The 2026-08-09 day file and the WORKLOG attempt-7 Step 8 row attribute the miss to the
"2026-08-02 teardown ... run `30777047207`, diagnostic-precascade job SUCCESS." That run's
precascade executed against attempt 1's estate (Steps 1-2 only - no spokes, no Databricks
workspace, orphan host nonexistent), so it was structurally incapable of seeing the setting,
and its SUCCESS is not the miss. The provenance supported by the record is teardown
`30685705802` (2026-07-31): the Phase 0.5 Databricks force-delete deleted the host out-of-band
before `bank-data-p1`'s in-order destroy, minting the FM-3 orphan before the diagnostic
precascade existed (PRs #93/#94 merged 2026-08-01; first execution was the greenfield smoke
test `30724982464`). OQ-075's T-A/T-B reads settle it to measured. The correction matters
because "the precascade ran against the live setting and missed it" and "no precascade ever
had the live setting un-raced in front of it" imply different fixes - the second is what the
evidence supports and what ADR-076 fixes.

---

## Executive summary (10 lines, for relay)

1. The precascade never "missed while looking" - no run of it ever had the orphan's host live
   and un-raced; its SUCCESS means "loops finished," not "settings gone" (no completeness
   assertion - the zero-warning is a comment, and a comment is not a control).
2. Mechanism: the Databricks force-delete precascade deletes the ONE out-of-band host; the
   diag sweep has no ordering barrier against it (concurrent jobs; az-sweep even orders it
   backwards), and Terraform then drops the state-held setting on a host-gone read.
3. Attempt 7's own pattern proves it: diag-aif/diag-srch (in-order-destroyed hosts) created
   clean; only diag-dbw (force-deleted host) collided. Mint: teardown 30685705802, 07-31.
4. Fix (draft ADR-076, DevSecOps + Cloud Engineer, before attempt 8): ordering barrier +
   per-setting completeness assertion (found==confirmed-gone, unreachable-hosts==0, loud
   host-absence errors) + the pre-authorized scoped azapi conversion of the dbw setting.
5. FM-3 stays undetectable while the host is absent - verified (ARM routing 403, ARG does not
   index the type, activity log is forensics only). No greenfield gate can exist.
6. Whether the in-flight teardown cleared the orphan is decidable ONLY from its
   diagnostic-precascade job log (OQ-075); the azapi conversion makes Step 8 immune either way.
7. Rebuild model (draft ADR-077): retire the one-clean-pass gate - at the observed ~1.5
   percent per-run vendor-fault rate, 28 serial runs forfeit roughly one attempt in three
   with a CORRECT repo, and each forfeit's teardown mints new latent classes and burns an
   ADR-075 generation (8-file PR each).
8. Replace with: greenfield-to-green with documented bounded recovery (claim), evidence-bound
   same-step retry (T-A Azure 5xx / T-B pre-Terraform lane only; one per step, two per
   attempt; `already exists` and all 4xx never retryable), layer scoring as claim structure -
   platform layer 1-4 is already banked from attempt 7.
9. Attempt 8 = HARDENING pass: fix-and-continue on new classes, flush the remaining Steps 9-14
   surface in ONE estate lifetime; then one final teardown + claim pass at a fixed SHA (which
   upgrades to the uninterrupted claim automatically if it runs clean).
10. Attempt-8 preconditions: ADR-076 PRs merged, r5 bump merged, OQ-075 log read done,
    greenfield re-verified, pre-clearance refreshed, OQ-070 budget window checked (valid to
    2026-08-31).
