# Wave B7 - Operations & Monitoring Phase 1 (AMBA + DINE diagnostics + health alerts) target design

> **Status:** READY FOR IMPLEMENTATION. This wave BUILDS the already-accepted ADR-037 Phase-1 MVP
> (`docs/operations-monitoring-design.md` section 12). The target architecture is designed and
> reviewed; B7 is largely implement-the-existing-design, with TWO build-time rulings OQ-033
> explicitly deferred to now (AMBA delivery form + DINE MG scopes) and ONE current-mechanism
> refinement the anti-hallucination sweep caught (the AMBA companion module). No user forks.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-19.
> **Authoritative design:** docs/operations-monitoring-design.md (ADR-037, OQ-033 resolved).
> **New record:** ADR-052 (B7 build rulings).
> **Roots touched:** EXTENDS `platform/management-groups` (policy assignments via avm-ptn-alz) and
> `platform/management` (AMBA supporting module + action-group convergence). NO new root, NO spoke
> (ADR-036/037). Both roots are B0a-deployed and green (pre-clearance re-verifies live).

---

## 0. Executive summary

- B7 makes the ADR-037 Phase-1 slice REAL: **AMBA (Azure Monitor Baseline Alerts for ALZ)
  baseline + Service Health + Resource Health alerts**, **diagnostic-settings-at-scale (DINE)**,
  and **action-group routing**, all policy-driven at MG scope so every current and future spoke
  inherits coverage. Bounded: no dashboards-for-everything, no DCR/AMA, no availability probes
  (those are Phase 2/3).
- **CURRENT-MECHANISM REFINEMENT (anti-hallucination sweep, verified today):** AMBA-for-ALZ in the
  current AVM Terraform world is a **two-part** delivery, which the ADR-037 doc's "assigned via
  avm-ptn-alz" phrasing under-specified:
  1. **`avm-ptn-alz`** (the estate ALREADY runs it at 0.19.1 in `platform/management-groups`)
     delivers the AMBA **policy definitions + initiatives + assignments** by extending the ALZ
     architecture/archetype with the AMBA library references + alerting assignments at MG scope
     (DINE) - the same engine that already assigns tag-governance and deny-public-network.
  2. **`avm-ptn-monitoring-amba-alz` 0.4.0** (published 2026-07-06, verified today - NEW to the
     estate) deploys the **supporting infrastructure the AMBA DINE policies require**: the
     `rg-amba-monitoring-001` resource group, a user-assigned managed identity, and its Monitoring
     Reader role assignment (the remediation identity the alert-deployment policies run as).
  Both are needed; neither alone delivers AMBA. This is the endorsed pattern (AMBA-ALZ docs).
- **The two OQ-033 build-time decisions, ruled here (ADR-052):** (a) AMBA delivery form = the full
  AMBA-ALZ pattern via the two modules above (not a bespoke subset), tuned to the estate's
  resource types; (b) DINE/assignment MG scopes = the AMBA "Networking / Management / (Identity) /
  Connectivity / VM" initiative family assigned at the scopes where those resource types live
  (platform MG for the management/connectivity/identity resource types; landingzones MG for the
  spokes) plus the Deploy-Diagnostics DINE initiative at the same scopes.
- **Action group:** the live platform action group exists (`azurerm_monitor_action_group.platform`,
  management sub). AMBA deploys its OWN action group + alert-processing-rule per subscription
  (`rg-amba-monitoring-001`). Convergence ruled (section 5): accept AMBA's own notification assets
  for the AMBA alerts at Phase 1 (endorsed, self-contained); route them to the SAME operator
  receiver so one human stream results; full APR convergence into the single platform action group
  is a Phase-2 item. Do NOT fork the on-call stream.
- **Cost:** near-zero. Alert rules and policy assignments are free; the AMBA RG + MI are free; LAW
  ingestion delta is small (metric/health alerts are lightweight, not log-volume). Estimate
  ~$0-2/day incremental (LAW ingestion only). No compute, no SKU.
- **Duration:** policy assignments propagate over minutes-to-~30min; DINE remediation is
  asynchronous. No long-create. The risk class is POLICY (assignment collisions, remediation
  identity RBAC) not resource-create.

## 1. Scope and boundary

### In scope (B7 = ADR-037 Phase 1)

| Item | Root / mechanism |
|---|---|
| AMBA-ALZ policy definitions + initiatives + ASSIGNMENTS (baseline metric/health alerts + Service Health) at MG scope | `platform/management-groups` via `avm-ptn-alz` 0.19.1 - extend the policy config with the AMBA library references + alerting assignments |
| AMBA supporting infra (rg-amba-monitoring-001 + user-assigned MI + Monitoring Reader role) | `platform/management` via `avm-ptn-monitoring-amba-alz` 0.4.0 (NEW module) |
| Diagnostic-settings-at-scale (Deploy-Diagnostics DINE initiatives) at MG scope | `platform/management-groups` via `avm-ptn-alz` (ALZ library Deploy-Diagnostics initiatives) |
| Resource Health alerts (platform-critical) | AMBA-inherited + the health alert layer |
| Action-group convergence (route AMBA notifications to the operator stream) | `platform/management` (receiver alignment; section 5) |
| Severity/routing taxonomy alignment (Sev0-4) to the action group | design doc section 3.4 (AMBA rules carry recommended severities; align receivers) |

### Explicitly OUT of B7 (Phase 2/3 - parked, do not build)

- DCR + AMA at scale (no guest VMs deployed; Entra DS is MS-managed) - Phase 2.
- Availability probes (App Insights / Connection Monitor), workbook fills beyond leaving the
  existing placeholders, Network Insights, custom per-component alerts beyond the AMBA baseline -
  Phase 2.
- Alert Processing Rules beyond AMBA's own (maintenance-window suppression, business-hours
  routing, full action-group convergence), Update Manager, guest-config baselines, Managed
  Grafana, ITSM/webhook - Phase 2/3.
- No new action groups beyond AMBA's pattern default + the existing platform one; no relocation of
  Sentinel/security LAW; no DR/backup alert wiring (Phase 2).

## 2. Verification log (2026-07-19, all dated today)

| Claim | How verified |
|---|---|
| **`avm-ptn-monitoring-amba-alz` latest = 0.4.0** (published 2026-07-06); deploys rg-amba-monitoring-001 + a user-assigned MI + Monitoring Reader role (supporting infra, NOT the policies); designed to run ALONGSIDE avm-ptn-alz which carries the policy assignments | Terraform Registry API + module docs today |
| AMBA-ALZ is the endorsed policy-driven pattern: policy initiatives grouped by ALZ platform structure (Networking/Management/Identity/Connectivity/VM), deploying alerts + action groups + APRs via DINE into rg-amba-monitoring-001 per subscription; Terraform is a supported deploy path | AMBA-ALZ docs (azure.github.io/azure-monitor-baseline-alerts) today |
| `avm-ptn-alz` in the estate = **0.19.1** (platform/management-groups/main.tf), ALZ library **2026.04.2**; it already delivers policy defs/initiatives/assignments/DINE at MG scope | repo read + WORKLOG |
| Platform action group LIVE in code: `azurerm_monitor_action_group.platform` (platform/management/main.tf L506), output exposed; platform LAW (`module.platform_law`) + portal dashboard + placeholder workbook present | repo read |
| ADR-037 Accepted (build deferred); OQ-033 RESOLVED, with AMBA-form + DINE-scope explicitly left as build-time decisions (now = B7) | DECISIONS.md / OPEN-QUESTIONS.md |
| platform/management + platform/management-groups are B0a-deployed green | estate status (WORKLOG); pre-clearance re-verifies live |
| **NOT verified (build/pre-clearance - implementer confirms per CLAUDE.md rule 4):** the EXACT wiring by which avm-ptn-alz 0.19.1 + ALZ library 2026.04.2 references the AMBA alerting library + assignments (whether the AMBA library reference is present in 2026.04.2 or needs an explicit additional `library_references` entry / a library bump); the avm-ptn-monitoring-amba-alz 0.4.0 exact input surface (root MG name, location, RG name, MI wiring) and whether it expects the AMBA policy assignments to reference its MI as the remediation identity (they must match); AMBA action-group notification parameters (email receiver - referenced ABSTRACTLY, no personal values committed); LAW ingestion delta | marked; owned by the B7 pre-clearance + implementer build-time verify |

## 3. Delivery mechanism (implementer contract)

### 3.1 Policy layer - `platform/management-groups` (extend avm-ptn-alz 0.19.1)

- Extend the module's policy-assignment configuration (the `policy_assignments` map keyed by MG id
  that the estate already uses for tag-governance / deny-public) with the **AMBA alerting
  initiative assignments** and the **Deploy-Diagnostics DINE initiative assignments**.
- **Library reference:** verify the AMBA policy content (Alerting-* initiatives + the Notification
  Assets policy) is available via the ALZ library 2026.04.2 the estate pins; if not present at
  that library version, add an explicit AMBA `library_references` entry (the ALZ Library carries
  the AMBA definitions) or bump the library reference - BUILD-TIME VERIFY, do not guess. Pin
  whatever library version is used.
- **Remediation identity:** the DINE alert + diagnostic assignments run as a managed identity that
  needs Monitoring Contributor (alerts) + the diagnostic-settings roles at the assigned scope. Use
  the identity the avm-ptn-monitoring-amba-alz module provisions (section 3.2) for the AMBA
  assignments; the Deploy-Diagnostics DINE follows the estate's existing tag-governance remediation
  identity pattern. Identity/scope match is a hard correctness point (a mismatched remediation
  identity = remediation fails silently).

### 3.2 Supporting infra - `platform/management` (NEW module avm-ptn-monitoring-amba-alz 0.4.0)

```
module "amba" {
  source  = "Azure/avm-ptn-monitoring-amba-alz/azurerm"
  version = "0.4.0"
  # required (implementer verifies exact names against 0.4.0 docs):
  #   location, root management group id/name, resource_group_name (default rg-amba-monitoring-001)
  # outputs the user-assigned MI + role assignment the policy layer references
}
```
Provisions rg-amba-monitoring-001 + the user-assigned MI + Monitoring Reader role. Gate behind a
default-false flag `enable_om_phase1` (LESSON 42) so the wave is shippable/revertible as one unit
with the policy assignments.

### 3.3 Scopes (the OQ-033 build-time DINE-scope ruling)

- AMBA alerting initiatives assigned at the MG scope matching each resource-type family:
  **platform MG** carries the management/connectivity/identity resource types (LAW, Automation,
  firewalls, gateways, DNS, Entra DS, KV); **landingzones MG** carries the spokes (bank-app-p1,
  bank-data-p1, corp-a1/a2, online-p1 and any future spoke inherit automatically). Assign at these
  two scopes (plus the Globaris root only for genuinely tenant-wide initiatives) - NOT per-spoke.
- Deploy-Diagnostics DINE at the same platform + landingzones scopes.
- This matches OQ-033's "coverage matches each spoke's resource types without over-alerting."

## 4. Cost, duration, risk

- **Cost:** ~$0-2/day incremental (LAW ingestion of health/metric alert data only; alert rules,
  policy assignments, the AMBA RG + MI are all free). No compute/SKU. The single cheapest wave.
- **Duration:** assignment PUTs are fast; policy propagation minutes-to-~30min; DINE remediation
  asynchronous (alerts appear as remediation runs). No long-create isolation.
- **Risk class = POLICY, not resource-create:** the failure modes are (a) assignment-name or
  scope collisions with the existing avm-ptn-alz assignments, (b) remediation-identity RBAC
  mismatch (silent remediation failure - the LESSON 49 authorization class), (c) library-reference
  version mismatch. All caught by plan-scan + the pre-clearance, none are apply-time long-runs.

## 5. Action-group convergence ruling (architect, within ADR-037 section 4 intent)

AMBA's endorsed pattern deploys its OWN action group + alert-processing rule per subscription in
rg-amba-monitoring-001, wired to the alerts by policy parameter. The estate already has one
platform action group. Ruling (Phase 1, bounded): **accept AMBA's own notification assets for the
AMBA alerts** (fighting the pattern's defaults to force every AMBA alert onto the existing action
group is Phase-2 effort for no Phase-1 value), BUT **point AMBA's notification receiver at the
SAME operator email/on-call target as the platform action group** so a human sees ONE coherent
stream, not two silos (ADR-037 section 4 "converge routing"). Receiver values referenced
abstractly - supplied via variable/CI, never committed (no-personal-values rule). Full convergence
(single action group + APRs for maintenance windows / business-hours) is the recorded Phase-2 item.
This is an architect ruling, not a user fork.

## 6. Forks and user asks

- **No genuine user fork.** OQ-033 resolved the scope/placement; ADR-037 accepted the target; the
  two build-time sub-decisions (AMBA form + DINE scope) are architect technical rulings made here
  (ADR-052) within that accepted design. The action-group convergence is likewise an architect
  ruling.
- **One user-supplied value (not a fork, the standard pattern):** the operator notification
  receiver (email/on-call endpoint) for AMBA + the platform action group - supplied via CI
  variable, referenced abstractly, never committed. If the user wants a distinct on-call/SMS
  receiver for Sev0/1 vs email for Sev2/3, that is a receiver-config choice recorded at build, not
  a blocking fork.

## 7. Pre-clearance feed (docs/preclearance/b7-om-phase1.md, before any apply)

1. Live policy matrix: enumerate existing avm-ptn-alz assignments at platform + landingzones +
   Globaris root; confirm NO name/scope collision with the AMBA + Deploy-Diagnostics assignments
   about to be added; confirm the AMBA library content is reachable at the pinned library version
   (or the explicit library reference resolves).
2. Roots green: platform/management + platform/management-groups B0a-live; the avm-ptn-alz state
   is intact (a policy-engine root is high-blast-radius - plan-scan must show PURE ADDS of the new
   assignments + the AMBA module, ZERO changes/replaces to existing MG/policy objects; any
   modify/replace on an existing assignment or MG = STOP, LESSON 26).
3. Remediation-identity RBAC: the AMBA MI holds the roles the DINE alert policies need at the
   assigned scope BEFORE the assignments evaluate (LESSON 35 propagation timing; LESSON 49
   authorization-not-propagation class - a 403 here is a missing role, not a wait).
4. Module known-issues sweep: avm-ptn-monitoring-amba-alz 0.4.0 is a FIRST estate consumption -
   full GitHub-issue sweep on our usage path (MI wiring, rg name, avm-ptn-alz interop).
5. Lifecycle clock: AMBA content changes frequently (the anti-hallucination note) - if the apply
   slips past ~2 weeks, re-verify the AMBA module version + library content.
6. Plan bars (previewed): management-groups = pure adds of the AMBA + diag assignments (+ any
   library-reference change), ZERO changes to existing assignments/MGs; management = the amba
   module set (RG + MI + role) + any action-group receiver change, ZERO destroys/replaces.
7. Standing gates: single-dispatcher, sequential (management-groups policy first so the assignments
   exist, then management for the supporting infra - OR the order the remediation-identity
   dependency dictates; implementer confirms which root's output the other consumes and orders
   accordingly), QA live-vs-intent before green.

## 8. QA feed (before green)

- AMBA + Deploy-Diagnostics assignments live at the ruled scopes; compliance evaluation begins.
- rg-amba-monitoring-001 + MI + Monitoring Reader role present; the MI is the remediation identity
  on the AMBA assignments (id match).
- A sample of AMBA alert rules deployed by DINE into a spoke (remediation ran) - pick one
  resource type present in the estate (e.g. an Azure Firewall metric alert, a LAW health alert)
  and verify the rule exists and targets the platform action group / AMBA action group.
- Action-group convergence: AMBA notifications and the platform action group resolve to the same
  operator receiver (one stream).
- No regression: existing avm-ptn-alz assignments (tag-governance, deny-public, the b11/b13 items
  still DoNotEnforce/staged) unchanged; existing hand-placed diagnostics idempotent under the new
  DINE (deploy-if-not-exists does not duplicate).
