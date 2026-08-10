# 2026-08-10 REFRESH #6 - re-clearance against `banking` @ `6ec9fba` for ATTEMPT 8, after PRs #109 to #118 (ADR-076 landed, ADR-077 rejected, generation r5)

**Series note.** This is refresh #6 of the pre-clearance series that lives in
`docs/preclearance/2026-07-22-full-estate-rebuild.md` (refreshes R through W plus Amendments
A/B/C). It is the first refresh in its OWN file: the master document stands at 3,155 lines and
is closed for new refresh sections by a dated pointer addendum appended there this session.
Section lettering continues the series: refresh #5 was W, this is **X**. Append-only discipline
unchanged. All dates local time. Author: architect.

Every SHA, run id, line number and count below was re-derived this session from
`git diff`/`git show` against `origin/banking` @ `6ec9fba`, from the pinned module sources, or
from the cited worklog entries. Nothing is carried from memory.

---

## X0. VERDICT

**Whole-run verdict: GO for the attempt-8 Step 1 dispatch.** No blocking condition stands
between `banking` @ `6ec9fba` and Step 1. All repo-side attempt-8 preconditions are discharged
and verified from the merged diffs (X1); the greenfield, PC-1SEC and PC-1TF'' gates were
live-verified this session (X2); all fourteen bars are re-derived or carried with the carrying
condition named (X5); the one material plan-rendering change since the bars were live-certified
(PR #115) is re-derived from source as count-neutral (X4).

**Dispatch-time conditions (mechanical, none blocking now):**

1. **headSha:** the dispatch runs the post-merge `banking` HEAD. At writing that is `6ec9fba`;
   this refresh itself merges as a docs-only PR and moves HEAD by docs alone - re-read HEAD at
   dispatch and confirm the delta from `6ec9fba` is docs-only.
2. **Step 3 plan render marker:** the LAW renders exactly once, solely as
   `law-security-globaris-poc-r5`. Any other generation (or a bare name) is a STOP.
3. **Step 8 plan render marker (NEW, PR #115):**
   `azapi_resource.dbw_diag_platform_law["main"]` MUST appear, and
   `module.databricks_workspace["main"].azurerm_monitor_diagnostic_setting.this["platform_law"]`
   MUST NOT. Any scan or tooling still matching the old address is stale (X3).
4. **OQ-070 window:** dispatch and land Step 2 by **2026-08-31 UTC** (21 days at writing), else
   execute the bump procedure in X7 first.
5. **Re-confirm the X2 live limbs at dispatch** if any time passes or anything touches Azure in
   between - the limb set is cheap and dies with any estate mutation.
6. **In-run gates re-discharged LIVE in their windows** (X3) - they die with every teardown and
   are never carried.

### Three things this GO does not mean

1. **It is not a claim attempt 8 will succeed.** Under the OQ-076 ruling the attempt is
   all-or-nothing (ADR-077 REJECTED): any failure at any step, including an evidence-bound
   Azure-side transient, forfeits the attempt into a full teardown under standing rule 1. The
   strategic review's estimate stands and was accepted by the operator: at the observed
   ~1.5 percent per-run vendor-fault rate, roughly one attempt in three forfeits across the 28
   serial runs even with a fully correct repo (`docs/strategic-review-2026-08-09.md` Part 3).
2. **The FM-3 orphan set entering this rebuild is formally UNKNOWN** (teardown `31350223388`'s
   sweep aborted mid-enumeration; unverifiable by construction, ADR-076 decision 5). X6 states
   what bounds it, what is immunized, and exactly which residual exposure remains - read it
   before dispatching Step 9.
3. **The ADR-076 teardown fix (PR #116) is suite-proven but has never run live.** Its live
   acceptance (ADR-076 acceptance ii) discharges only at the NEXT `target=all mode=terraform`
   teardown of an estate holding a live Databricks workspace - which is attempt 8's teardown,
   whenever that is. Nothing about it gates this dispatch.

---

## X1. Basis chain, and the complete delta since the last certification

**The certification chain this refresh stands on:**

- **Refresh #5 (GO, basis `c4da1bc`) + Amendments A (bar 38), B (PR #100 zero-effect),
  C (ADR-075 envelope)** - the last full refresh of record.
- **Attempt 7 (basis `71a62df`, 2026-08-09): the strongest bar certification the series has** -
  Steps 1-8 plans hit their bars EXACTLY, live: 537 (`31301492495`), 38 (`31325883718`),
  48 (`31336521742`, `-r4` sole render), 696 (`31339777034`), 24 (`31343709802`),
  24 (`31346362777`), 26 (`31347697755`), 76 (`31348447792`); applies matched for Steps 1-7
  (Step 8's apply failed on the FM-3 orphan, not on any bar). PR #109's zero-bar claim is
  live-proven by the same sixteen runs, all of which executed the flip-retry `_tf-root.yml`.
- **This refresh (basis `6ec9fba`)** certifies the remaining delta: `71a62df..6ec9fba`.

**Every merge in that delta, classified from its diff (not its message):**

| PR | Merge | Files | Classification |
|---|---|---|---|
| #110 | `9cda66c` | `envs/poc.tfvars` + 6 doc/demo files | **Value-only** (ADR-075 decision 6: `security_law_generation` r4 -> r5 + literal sweep). Changes Step 3's RENDER, not its count. Amendment C's ruling applies verbatim: values are not addresses; bar stays 48 |
| #111 | `96d3aaa` | WORKLOG + day file | Docs |
| #112 | `d4cb4b9` | strategic review + day file | Docs |
| #113 | `5bea2dd` | DECISIONS + OPEN-QUESTIONS + day file | Docs (ADR-076 Accepted, ADR-077 Rejected, OQ-075/076 resolved) |
| #114 | `6b9846b` | WORKLOG | Docs (index + attribution correction) |
| #115 | `ec0075a` | `landing-zones/bank-data-p1/{databricks,ai,policy_exemptions,providers}.tf` + day file | **THE material change.** Re-derived in X4: 1:1 resource swap, bar stays 76; `ai.tf`/`policy_exemptions.tf` hunks are comment-only (read line-by-line this session) |
| #116 | `e2c06f8` | `teardown.yml` + 3 teardown scripts + suite + day file | **Teardown-side only.** `deploy.yml` and `_tf-root.yml` untouched (the full workflow delta `71a62df..6ec9fba` is `teardown.yml` alone, verified by `git diff --name-only`). Zero deploy-path bar effect |
| #117 | `f6cfadf` | WORKLOG + day file | Docs |
| #118 | `6ec9fba` | day file | Docs |

**The complete `.tf`/`.tfvars`/`.hcl` delta since refresh #5's basis** (`git diff --name-only
c4da1bc origin/banking`, 11 files) - every file dispositioned, so nothing rides unclassified:

- `envs/poc.tfvars` - three value deltas: `allowed_locations` (Amendment A / ADR-074, bar 38
  live-proven at attempts 2-7), `budget_start_date` 07-01 -> 08-01 (PR #100 / Amendment B,
  live-proven), `security_law_generation` added, now `"r5"` (Amendment C class + PR #110).
- `landing-zones/bank-data-p1/` x4 - PR #115 (X4).
- `platform/management/region-restriction.tf`, `variables.tf` - ADR-074 / Amendment A
  (live-proven: Step 2 = 38 exact on five consecutive attempts).
- `platform/security/main.tf`, `variables.tf` - ADR-075 / Amendment C (live-proven: Step 3 = 48
  exact on attempts 4, 5, 7).
- `synthetic/cost_guardrails.tf`, `cost_patterns.tf` - PR #100's stale-date class fix
  (`ceec9d7`): dormant sites behind `enable_synthetic_workload = false`; the synthetic root is
  not one of the fourteen dispatched steps. Zero bar effect (Amendment B). Note: these sites
  are also dated `2026-08-01` and stale past 2026-08-31 - dormant, so the X7 bump procedure
  covers only the live site unless the synthetic flag ever flips.
- `modules/` delta since `c4da1bc`: **empty** (verified).

**`landing-zones/bank-app-p1` and `platform/identity` appear NOWHERE in the delta** - the
carrying condition for bars 9-12 (X5) is therefore satisfied by classification, not assumption.

---

## X2. Live verification (done-at-T, cite-and-recheck)

Verified live **this session** by the operator against `banking` @ `f6cfadf` (one docs commit
before `6ec9fba`; the delta between them is one day-file edit), recorded in
`docs/worklog/2026-08-10.md` ("dispatch-time greenfield re-verification: ALL GATES CLEAN"):

| Gate | Read |
|---|---|
| Estate RGs | 0 in all five subscriptions (baseline exclusions applied) |
| Soft-deleted LAWs | 0 in all five subscriptions |
| Management groups | 1 (Tenant Root only) |
| State blobs | 11; `platform/management` (serial 122) and `landing-zones/bank-data-p1` (serial 67) content spot-checked `"resources":[]` |
| State-SA posture | `default_action = Deny` |
| PC-1SEC | 0 live AND 0 soft-deleted `law-security-*` |
| PC-1TF'' by VALUE | `enable_acr_kubelet_binding = false` (:292), `enable_om_phase1 = false` (:428), `security_law_generation = "r5"` (:484) |

This refresh independently re-read the three PC-1TF'' values and line numbers from
`origin/banking` this session (same values, same lines) and additionally confirmed
`enable_data_platform = true` (:339) and `enable_ai_platform = true` (:367), which X4's bar
derivation depends on. **Re-confirm the limb set at dispatch if time passes** - the reads are
cheap and the estate is only as greenfield as its last read.

---

## X3. Gate table refresh

**Dispatch gates (before Step 1):**

| Gate | Definition (current) | Delta vs refresh #5 |
|---|---|---|
| PC-1TF'' | By VALUE: `enable_acr_kubelet_binding = false` (:292), `enable_om_phase1 = false` (:428), `security_law_generation = "r5"` (:484). Line numbers are locators, values are the gate | **r5** (was r2 at Amendment C; r3/r4 intervening). Line :484 (was :478/:481) |
| PC-1SEC | 0 live AND 0 soft-deleted `law-security-*` (wildcard, never the exact name) | Unchanged (covers every generation) |
| PC-1M / PC-1Y | The greenfield limb set of X2 | Unchanged |
| headSha | Dispatch headSha = post-merge `banking` HEAD, docs-only delta from `6ec9fba` | Basis moved |

**In-run gates (die with every teardown, re-discharge LIVE in their windows):**

| Gate | Window | Definition |
|---|---|---|
| PC-3C | After Step 1, before Step 4 | `Enable-DDoS-VNET` reads `DoNotEnforce` at BOTH `connectivity` and `landingzones` MGs (`MSYS_NO_PATHCONV=1` on MG-scope `az` from Git Bash) |
| PC-2X' | After Step 2 | 8 budgets live-counted (3 MG-scope via `az rest`, 5 subscription-scope) |
| PC-2X | After Step 2, before Step 5 | Fresh platform LAW mints a NEW customerId: set BOTH secrets via the swap-proofed sealed-box setter (shape-check per name BEFORE sealing - GUID to `PLATFORM_LAW_CUSTOMER_ID`, 9-segment ARM path to `PLATFORM_LAW_WORKSPACE_ID`); HTTP 204 x2 + `updated_at` is the discharge record |
| PC-2R | Before Step 3 | The 8 estate-managed Defender plans read `Free`; W2 trio exactly `AI`/`Discovery`/`FoundationalCspm` |
| PC-3X | After Step 4 | Firewall private IPs exact: primary/centralus `10.0.0.4`, secondary/eastus2 `10.1.0.4` (ADR-042/ADR-069); read via `az rest` (the `azure-firewall` CLI extension cannot auto-install non-interactively on the operator machine) |
| PC-4C | After Step 4 | 89 private DNS zones exact; all eleven consumer zones; AKS zone renders `centralus` (ADR-069) |

**Gate definitions the delta CHANGES (flagged, per the dispatch instruction):**

1. **Step 3 plan-scan marker:** sole render is now `law-security-globaris-poc-r5`. Any check
   still written against `-r4` (or any burned generation) is stale. Burned list:
   `<none>`, `r2`, `r3`, `r4`.
2. **Step 8 plan-scan marker (PR #115):** the diagnostic setting renders as
   `azapi_resource.dbw_diag_platform_law["main"]`; the old module address
   `module.databricks_workspace["main"].azurerm_monitor_diagnostic_setting.this["platform_law"]`
   must NOT appear. A repo-wide sweep this session (Cloud Engineer's, re-confirmed) found no
   script, test or workflow matching the old address - but any OPERATOR scan habit built on it
   must update.
3. **PC-1DIAG (restated, definition unchanged, consequence sharpened by OQ-076):** an
   `already exists` on any step is a failure AND forfeits the attempt (all-or-nothing). The
   one place it can no longer structurally fire is the dbw setting itself - azapi PUTs
   idempotently, no RequiresImport pre-check (X4/X6).
4. **Scan discipline carries unchanged** (emitted marker forms, never substrings; assert the
   `Plan:`/`Apply complete!` line exists before trusting any zero; match jobs by NAME; REST
   dispatches log-before-dispatch).

---

## X4. The material change: PR #115, and the Step 8 bar re-derived from source

**What changed** (diff read line-by-line this session): `databricks.tf` removed the module's
`diagnostic_settings` input and added root-level `azapi_resource.dbw_diag_platform_law`
(`Microsoft.Insights/diagnosticSettings@2021-05-01-preview`, `for_each` gated on
`enable_data_platform`, body = one `categoryGroup "allLogs"` log entry to the platform LAW,
normalization arguments per the estate-proven datalake idiom, `schema_validation_enabled =
false`, lifecycle ignore on `logAnalyticsDestinationType`); `providers.tf` raised the azapi
floor `~> 2.5` -> `~> 2.9` (`ignore_other_items_in_list` / `list_unique_id_property` need
v2.9.0+); `ai.tf` and `policy_exemptions.tf` hunks are **comment-only**.

**Bar derivation (re-derived, not copied):**

- The vendored `avm-res-databricks-workspace` 0.5.0 consumes `var.diagnostic_settings` in
  exactly ONE resource (`main.tf:57`, the `for_each` of
  `azurerm_monitor_diagnostic_setting.this`). The input previously carried one entry
  (`platform_law`), so emptying it removes exactly one planned resource.
- The new `azapi_resource` plans exactly one instance (`for_each = { main = "main" }` under
  `enable_data_platform = true`, confirmed at `envs/poc.tfvars:339`).
- Net: **-1 +1 = 0. Step 8 stays 76** (unit per the series: the raw `Plan: N to add` integer,
  AVM telemetry included; the 52-real + 24-telemetry composition is unchanged - one real
  resource replaced by one real resource, module count and telemetry untouched).

**Provider selection at plan time (the coordinator's explicit check):** the committed
`.terraform.lock.hcl` at `6ec9fba` locks `azure/azapi` at **`2.11.0`**, which satisfies the new
`~> 2.9` floor, so `terraform init` re-verifies the SAME version and **no provider
re-selection occurs** - the floor bump changes what the constraint ADMITS, not what any run
USES (the Cloud Engineer's init on this root confirmed "lock file NOT modified"). One cosmetic
note so nobody misreads it later: the lock's informational `constraints` string still reads
`"~> 2.0, ~> 2.4, ~> 2.5"` (it records the constraint set at the init that last wrote the
lock); the selection gate is the `version` line, and a future init may rewrite the string
without changing the selection. Not a defect, not a gate.

**Review chain:** PR #115 merged `ec0075a` (head `e6393f5`, stamp `3123223`; one-round BLOCK on
an over-broad `ai.tf` comment, reworded, re-verify APPROVE). PR #116 merged `e2c06f8` (head
`0d9166d`, stamp `d22d1e6`; BLOCK -> Case-12 coverage added with RED proof 22/16 -> 34/4, 38
assertions -> re-verify APPROVE).

**What PR #115 buys at Step 8, stated precisely:** the azapi PUT overwrites any surviving
FM-3 orphan record for `diag-dbw-bank-data-p1-globaris-poc` instead of colliding. The
attempt-7 killer cannot structurally recur at that address. It does NOT immunize any other
setting (X6).

---

## X5. Plan bars: all fourteen, with the derivation method named

**Unit statement (carried from V3/W6, unchanged):** each bar is the raw `Plan: N to add`
integer, AVM telemetry pseudo-resources INCLUDED. **Rule 1 unchanged: a delta of even ONE
against any bar is a STOP requiring a fresh architect disposition, never a silent bar update.**

| Step | Root | Bar | Derivation method |
|---|---|---|---|
| 1 | `platform/management-groups` | **537** | Live-hit exactly, attempt 7 plan `31301492495` + apply `31319027114`; zero apply-path delta for this root since (X1). CARRIES |
| 2 | `platform/management` | **38** | Live-hit, attempt 7 `31325883718`/`31336038005` (8 budgets at 2026-08-01); zero delta since. CARRIES, conditional on the OQ-070 window (X7) |
| 3 | `platform/security` | **48** | Live-hit, attempt 7 `31336521742`/`31337902958` under `-r4`; PR #110 is value-only (Amendment C ruling: values are not addresses). CARRIES at 48 with the `-r5` sole-render marker |
| 4 | `platform/connectivity` | **696** | Live-hit, attempt 7 `31339777034`/`31341025124`; zero delta since. CARRIES |
| 5 | `landing-zones/corp-a1` | **24** | Live-hit, attempt 7 `31343709802`/`31343973375`; zero delta. CARRIES |
| 6 | `landing-zones/corp-a2` | **24** | Live-hit, attempt 7 `31346362777`/`31346511575`; zero delta. CARRIES |
| 7 | `landing-zones/online-p1` | **26** | Live-hit, attempt 7 `31347697755` + apply green (zero 500s); zero delta. CARRIES |
| 8 | `landing-zones/bank-data-p1` | **76** | Live-hit, attempt 7 plan `31348447792`, THEN materially changed by PR #115; re-derived from source as count-neutral (X4). CARRIES at 76 with the new address marker |
| 9 | `landing-zones/bank-app-p1` Pass 1 | **67** | NOT exercised in the attempt series. Source-assessed at refresh #4 V3, carried through W6 + Amendments; carrying condition = zero root delta since `c4da1bc`, SATISFIED by the X1 classification (root appears nowhere in the delta). CARRIES |
| 10 | `platform/identity` Pass 1 | **16** | Same carry logic as Step 9 (root untouched since `c4da1bc`). Dispatch input `enable_conditional_access_override=false` REQUIRED (workflow input, not tfvars). CARRIES |
| 11 | `platform/identity` Pass 2 | **10** | Same. CARRIES |
| 12 | `landing-zones/bank-app-p1` Pass 2 | **1** | Conditional: requires the PC-1TF kubelet line re-merged first (operator tfvars PR). CARRIES with condition |
| 13 | `platform/management` (B7) | **3** | Conditional: requires `enable_om_phase1 = true` re-merged first. CARRIES with condition |
| 14 | `platform/management-groups` (B7) | **223** | Same condition as 13; plus the two permitted `time_sleep` replacement halves and exactly 70 `PolicyRoleAssignmentError` warnings, per V3. CARRIES with condition |

One structural note supporting the Step 9-11 carries: every root consumes the shared
`envs/poc.tfvars` via `-var-file`, and undeclared entries there (the r-token, region params)
are warnings, not errors - proven structurally by the file's shared-by-design use across all
roots since Section 10, and live by attempts 5-7 running five spoke roots against a tfvars
carrying every other root's values.

---

## X6. FM-3 residual risk entering attempt 8, stated plainly

**Formal position:** the orphan set is UNKNOWN and unverifiable by construction. Teardown
`31350223388`'s diagnostic sweep aborted mid-enumeration (`ResourceGroupNotFound` on
`rg-bank-data-p1-dbx-managed-globaris-poc`, the ADR-076 limb-1 race in its loud expression),
and an FM-3 object cannot be enumerated while its host is absent (ADR-076 decision 5: ARM
routes extension calls through the host scope - recorded 403; ARG does not index the type;
activity log is 90-day forensics only).

**Mechanism bound:** FM-3 minting requires a host deleted OUT-OF-BAND of its settings'
deletion. The estate has exactly one such host class - the Databricks workspace (teardown
force-delete, ADR-072 C4, permanent). Everything else in the attempt-7 estate was state-held
and destroyed IN-ORDER by green per-root destroys in `31350223388` (settings deleted before
hosts; `platform/management`'s settings deleted before its RG-delete failure on the NWTA DCE;
`online-p1`'s destroy green with the App Gateway in state).

**What is immunized:** the one known-colliding site. `diag-dbw-bank-data-p1-globaris-poc` is
now an idempotent azapi PUT (PR #115) - a surviving orphan is overwritten, not collided with.

**Live evidence for the in-order class:** attempt 7 Step 8 created `diag-aif-*` and
`diag-srch-*` clean (run `31348557765`, 75/76) - the azurerm-interface settings on
in-order-destroyed hosts are SHOWN clean of FM-3, exactly as the strategic review's Part 1
predicted from the mechanism.

**The residual exposure, named:** **Step 9.** `bank-app-p1`'s five azurerm-interface settings
(`diag-apim/acr/aks/evhns/sbns-*`) were last destroyed in-order on 2026-07-31 (run
`30685705802`) and the root has not applied greenfield since. By the mechanism they are clean
(their hosts were never deleted out-of-band); by evidence they are REASONED clean, not
live-proven - attempt 8's Step 9 is the first test. An `already exists` there is a PC-1DIAG
failure and, under the OQ-076 ruling, forfeits the attempt. There is no pre-dispatch read that
can close this (FM-3 invisibility); it is a stated risk, accepted with the ruling. No other
Databricks-hosted setting exists in config (the workspace carries exactly one), so no other
azapi conversion is warranted.

**Forward-looking:** attempt 8's eventual teardown is the FIRST to run the hardened sweep
(ordering barrier + completeness assertion, PR #116) - ADR-076 acceptance (ii) discharges
there, and from then on a silent miss of this class cannot report success.

---

## X7. Standing rules and windows for attempt 8

- **ADR-077 REJECTED (OQ-076, 2026-08-10): all-or-nothing.** Standing rule 1 in force: ANY
  failure at ANY step -> full stop, log, then full teardown to verified greenfield and restart
  from Step 1 on operator direction. No same-step retries of any class. The 2026-08-04
  zero-creates exception remains dated and non-precedential (offered twice since, declined
  twice).
- **PC-1DIAG:** `already exists` = failure AND forfeits the attempt. Runbook B1 auto-recovery
  remains suspended.
- **ADR-075 generation mandate:** current token `r5` (:484). Burned: `<none>`, `r2`, `r3`,
  `r4`. Any teardown that purges the r5 generation makes the bump to `r6` MANDATORY on
  `banking` before the next rebuild's Step 3 - and the bump PR must sweep the doc/demo
  literals (the r4 sweep was 8 files; one literal has been missed once before).
- **Step 7 watch:** one App Gateway 500 on record (attempt 5, run `31059957430`), cleared by
  attempt 7's green. Under all-or-nothing any new 500 forfeits the attempt regardless; if it
  is a SECOND 500 on the same create, the 2026-08-05 escalation rule additionally fires -
  architect, support ticket / SKU-region check, before any attempt 9 is even discussed.
- **Step 10 dispatch input:** `enable_conditional_access_override=false` must be passed on the
  dispatch (workflow input, defaults true; missing it caused the AADSTS700024 token-expiry
  failure).
- **OQ-070 window:** `budget_start_date = "2026-08-01T00:00:00Z"` (`envs/poc.tfvars:128`) is
  valid to **2026-08-31 UTC**; 21 days remain at writing. **Bump procedure if the dispatch
  slips past it:** one value edit at `:128` to the new month's first day
  (`"2026-09-01T00:00:00Z"`), PR'd and reviewed; the PR #100 guard class fails fast at plan on
  a stale date, and Step 2's bar stays 38 with all 8 budgets rendering at the new date. The
  two synthetic-root sites of the same class are dormant (`enable_synthetic_workload = false`)
  and only need the same edit if that flag ever flips.
- **Lifecycle audit (LESSON 40/41):** last full pass T4 (2026-07-31) with the V6 delta
  (2026-08-01). Steps 1-8's surface was live-applied GREEN on 2026-08-09, which supersedes any
  static audit for those roots. Steps 9-14 introduce ZERO new resource types since V6 (PR
  #115's azapi type is the same `diagnosticSettings` type already live in the estate). If the
  attempt-8 dispatch slips past ~2026-08-15 (two weeks from V6), re-run the delta audit for
  the Step 9-14 resource types before dispatching those steps.

---

## X8. VERIFIED vs ASSUMED (this replaces W8)

**Verified this pass (command-backed):** the PR-by-PR classification of `71a62df..6ec9fba`
(merge diffs); the complete 11-file `.tf`/`.tfvars` delta since `c4da1bc` with per-file
disposition; `modules/` delta empty; workflow delta since `71a62df` = `teardown.yml` only;
PR #115's diff line-by-line incl. comment-only status of `ai.tf`/`policy_exemptions.tf`; the
single-consumer derivation of the module's `diagnostic_settings` input (vendored 0.5.0 source,
`main.tf:57`); azapi lock `2.11.0` at `6ec9fba` satisfying `~> 2.9`; tfvars gate values and
line numbers (:128, :292, :339, :367, :428, :484); the greenfield/PC-1SEC/PC-1TF'' table
(operator live reads this session, cited done-at-T).

**Carried on named conditions (not re-verified live):** bars 9-14 (source-assessed V3/W6 +
zero-root-delta classification; Steps 12-14 additionally conditional on future tfvars flips);
the Step 9 FM-3 cleanliness (mechanism-reasoned + sibling live evidence, NOT provable before
the apply); the lifecycle audit for Step 9-14 types (V6 carry, zero new types, re-run trigger
dated); the ADR-076 teardown fix's live behaviour (suite-proven RED-first, never yet run
against a live estate).

**Explicitly NOT verified, stated so nobody reads silence as coverage:** no live plan was run
against `6ec9fba` (the certification is source-derivation + the attempt-7 live bars; the
dispatch's own Step 1-8 plans ARE the live proof, and Rule 1 stops on any delta of one);
`shellcheck`/`actionlint` remain unrun anywhere (not installed; no CI lints workflows).

---

## X9. Decisions and open items

1. **ADR-076's `Landed:` field updated by dated addendum this session** (same branch): PRs
   #115 (`ec0075a`) and #116 (`e2c06f8`) merged; acceptance (i) discharged (RED-first,
   38 assertions), (ii) pending the next live teardown, (iii) pending attempt 8 Steps 8-9.
2. **The master pre-clearance document is closed for new refresh sections** by a dated pointer
   addendum (this session); future refreshes continue as standalone dated files in
   `docs/preclearance/`, pointed from there.
3. **OQ-075's forensic reads F-1/F-2** (run `30685705802` logs) remain open, optional,
   non-blocking - they upgrade ADR-076's provenance from best-fit to measured.
4. Open DevSecOps chips carried, none blocking dispatch: NWTA DCE attachment-sweep class
   (`task_f8d01737`, SECOND firing recorded in `31350223388`), out-of-state appgw carcass limb
   (`task_69b98162`), pre-commit dash-check no-op (`task_27ce1528`), hook-pair staleness limbs.
5. Attempt 8 dispatches on operator direction only, all-or-nothing, with this refresh cited as
   the pre-clearance of record.

---

## Proposed commit message (refresh #6)

```
docs(preclearance): refresh #6 - GO for attempt 8 vs banking@6ec9fba; all 14 bars re-derived
(Step 8 = 76 re-proven vs PR #115 azapi swap); gates refreshed (r5, new Step 8 scan marker);
FM-3 residual + OQ-070 window + all-or-nothing rules stated [skip-review]
```
