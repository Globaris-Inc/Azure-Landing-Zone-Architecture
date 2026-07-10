# Deploy Pre-clearance Gate

> **Status:** Framework / index (architect-owned).
> **Section:** 10 (Pipeline & Tooling) — a mandatory gate that wraps every deploy root.
> **Related ADRs:** [ADR-026](../DECISIONS.md) (Enable-DDoS-VNET DoNotEnforce lever),
> [ADR-028](../DECISIONS.md) (Deny-Public-IP RG-scoped Waiver exemption for Entra DS).
> **Last updated:** 2026-07-09

This document defines the deploy pre-clearance gate: what it is, why it exists, the reusable
procedure every root runs before it applies, and an index of the per-root pre-clearance files.
It is a framework doc. The per-root evidence lives in `docs/preclearance/<root>.md`.

---

## 1. Purpose and the hard bar

After roughly 10 failed deploy runs across `platform/management-groups` and `platform/identity`
(2026-07-07 / 2026-07-08), the user mandated a systemic change and set a hard bar:

> **Another streak of 4 straight failures on any deployment layer and the project moves off Claude
> Code.**

The fix-one-error-and-rerun loop is retired. Every past failure was **knowable in advance** from one
of three sources:

1. **Our own deployed ALZ policy stack** — Deny / Modify / DINE assignments at ancestor MG scopes,
   deployed by `platform/management-groups` via `avm-ptn-alz`. Examples that already bit us:
   `Deny-Public-IP` at the identity MG killed the Entra DS service-managed public IP (ADR-028);
   `Enable-DDoS-VNET` (Modify) broke hub VNet creates (ADR-026).
2. **Tenant / directory prerequisites** — licensing (Entra ID P1/P2 for Conditional Access),
   directory roles (Application Administrator + Groups Administrator to create Entra DS, Security
   Administrator for tenant diagnostics/UEBA), publisher service principals, resource-provider
   registrations, and repo Secrets.
3. **Publicly documented known issues** — Enterprise-Scale / ALZ GitHub issues, AVM module issues,
   and `azurerm` / `azapi` provider issues. A large amount of this work is already public.

Per-diff code review audits the **diff**, not the **environment the diff lands in**. It cannot see a
Deny policy three MG levels up, an unregistered RP, or a missing license. Environment pre-clearance
is therefore a **separate gate** from code review, and its output is a **committed doc, not chat**.

**This gate is architect-owned and mandatory before any root's first apply or any post-failure
retry.** No root gets an apply until its per-root pre-clearance file exists and is dispositioned.

---

## 2. Two gates, not one

| Gate | Owner | Scope | Artifact |
|------|-------|-------|----------|
| Code review (per diff) | code-reviewer | The Terraform diff: correctness, module/version pins, arguments, style | Review approval on the batch |
| **Deploy pre-clearance (per root, per apply)** | **architect** | **The live environment the diff lands in: policy, prerequisites, known issues** | **`docs/preclearance/<root>.md`** |

The code-review gate stays. It caught the ~$3k/mo DDoS misconfiguration and hallucinated role GUIDs.
It is **not** a substitute for this gate, and this gate is not a substitute for it. Both run.

---

## 3. Pre-clearance procedure (reusable checklist)

Run all three parts for the target root before its first apply, and again before any post-failure
retry. Record the evidence (commands + verdicts) in the per-root file. Use live `az` / `gh` output as
the evidence; do not assert from memory.

### (a) Live policy-assignment enumeration

For every ancestor MG scope the root crosses (org root -> platform / landingzones -> the archetype MG
-> the subscription), enumerate the live policy assignments and cross-reference each against the
resource types the root creates.

- Enumerate: `az policy assignment list --scope <mg-scope> --query "[].{name:name, def:policyDefinitionId, enforce:enforcementMode}" -o table` at each ancestor scope (and `az policy set-definition show` / `az policy definition show` to resolve initiative member effects and parameters).
- Cross-reference: list the resource types the root creates (from the plan or the module surface),
  then flag **every Deny, Modify, and DINE** that can fire on any of them.
- Disposition each flagged assignment with an explicit verdict: PASS (why it does not fire),
  BLOCKER (with the fix — exemption / enforcement mode / parameter / config change), or NOISE
  (DINE follow-on that never blocks a create and self-heals or is remediated post-apply).

### (b) Tenant / directory prerequisite manifest

Verify each prerequisite the root needs with a concrete `az` / `gh` command and record the result:

- **Licensing** — the SKUs the root's features require (e.g. Entra ID P1/P2 for CA, Defender for
  Endpoint for the MDATP connector). `az rest` against the Graph `subscribedSkus`, or the admin
  center where CLI cannot see it.
- **Directory roles on the CI SP** — standing Entra roles the SP needs for tenant-scope writes
  (Security Administrator for `microsoft.aadiam` diagnostics + Sentinel UEBA; the AADDS creation
  roles). `az rest --method GET --url ".../roleManagement/directory/roleAssignments?$filter=principalId eq '<sp-object-id>'"`.
- **Publisher SPs / directory groups** — e.g. the "Domain Controller Services" publisher SP and the
  "AAD DC Administrators" group for Entra DS. `az ad sp show` / `az ad group show`.
- **RP registrations** in the target subscription. `az provider show -n <RP> --query registrationState`.
  Note which are in `azurerm` v4's default auto-register set (registered at apply start) vs which need
  an explicit registration resource or a manual `az provider register`.
- **Repo Secrets / Variables** the root consumes. `gh secret list` / `gh variable list`.

Every item gets a verified / not-verified verdict and, where missing, an ordered action (with who
owns it: operator vs IaC) before apply.

### (c) Known-issues harvest

Search the public ALZ / Enterprise-Scale implementations and provider trackers for the resource types
and modules the root touches. Capture any known collision, ordering constraint, replication-lag, or
requires-import behavior that applies, with the fix or workaround. This is where community knowledge
substitutes for another failed run.

---

## 4. Standing known items

These are carried forward across roots and must be actioned at the point named. They come from the
pre-clearance mandate and prior ADRs.

- **Enable-DDoS-VNET at the `landingzones` MG must be set to `DoNotEnforce` BEFORE any spoke applies**
  (ADR-026 follow-up). The Modify assignment's placeholder DDoS-plan parameter breaks VNet creates
  under it; the spoke roots create VNets under `landingzones`. **CONFIRMED STILL ENFORCED live
  2026-07-10** (`az policy assignment show`: `enforcementMode=Default`, `effect=Modify`, `ddosPlan`
  = the zero-GUID placeholder). Fix spec + exact `policy_assignments_to_modify` diff is in
  `preclearance/landing-zones.md` section 6 (platform/management-groups lane). Not yet applied.
- **Check `Deny-Public-IP` at the `corp` / `online` MGs vs the `online-p1` Application Gateway PIP.**
  Same collision class as ADR-028 (Entra DS PIP at the identity MG). App Gateway v2 mandates a public
  IP; if `Deny-Public-IP` is assigned on the archetype MG above the online spoke, the App Gateway PIP
  will be denied. Disposition in the online-spoke pre-clearance file (RG-scoped Waiver exemption is
  the ADR-028 precedent).
- **Remove the 2 temporary directory roles (Application Administrator + Groups Administrator) from the
  CI SP once Entra DS reaches `Running`.** Granted time-boxed for the AADDS create; they are standing
  privilege that must not persist. Tracked in `docs/preclearance/platform-identity.md` as a mandatory
  post-apply follow-up.

---

## 5. Per-root pre-clearance index

Every root gets a file here before its first apply. Future roots are added to this table as they
enter the deploy chain.

| Root | File | Status | Notes |
|------|------|--------|-------|
| platform/identity (re-apply) | [`preclearance/platform-identity.md`](preclearance/platform-identity.md) | **CLEARED** pending the ordered actions | Policy lane cleared by ADR-028 (Deny-Public-IP RG-scoped Waiver exemption + propagation sleep). Ordered actions: implement ADR-028 (cloud-engineer) -> operator deletes the failed domain shell -> plan/apply -> remove the 2 temp directory roles once Running |
| platform/security (first apply) | [`preclearance/platform-security.md`](preclearance/platform-security.md) | **BLOCKED** on prerequisites | Policy lane clean (no Deny collision). Blocked on: Security Administrator grant for tenant diagnostics + UEBA (or toggle both off), MDATP connector has no tenant license (drop/gate/accept-fail — user decision), `SECURITY_CONTACT_EMAIL` repo Secret unset |
| landing-zones/corp-a1 (first apply) | [`preclearance/landing-zones.md`](preclearance/landing-zones.md) | **BLOCKED** | Deploy first (pattern). Blockers: (1) `Enable-DDoS-VNET` Modify still ENFORCED at `landingzones` MG — DoNotEnforce it (ADR-026 extension, platform/management-groups lane); (2) corp-MG `Deny-Public-Endpoints` denies flow-log SA + App Service public access (OQ-024); (3) `Deny-Subnet-Without-Nsg` denies `snet-integration` (attach NSG); (4) `SQL_AAD_ADMIN_OBJECT_ID`/`_LOGIN` Secrets MISSING; (5) `Microsoft.RecoveryServices` RP NotRegistered; (6) `NetworkWatcher_eastus2` missing in LZ sub |
| landing-zones/corp-a2 (first apply) | [`preclearance/landing-zones.md`](preclearance/landing-zones.md) | **BLOCKED** | Deploy second (DR, centralus). Same blockers as corp-a1 EXCEPT NetworkWatcher (`_centralus` exists). SQL Secrets + RecoveryServices RP shared with corp-a1 |
| landing-zones/online-p1 (first apply) | [`preclearance/landing-zones.md`](preclearance/landing-zones.md) | **BLOCKED** | Deploy third (internet-facing, eastus2). App Gateway PIP CLEAR (no standalone-PIP deny on this chain). Blockers: DDoS DoNotEnforce (shared), flow-log SA public-PaaS deny (OQ-024), `NetworkWatcher_eastus2` (shared). No SQL/RSV — fewer blockers |

**Status legend:** CLEARED (may apply once the listed ordered actions are done) · BLOCKED (a
prerequisite must be resolved before apply) · N/A (no gate needed, e.g. destroy-only).
