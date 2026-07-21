# Pre-clearance: wave B0a redeploy (management-groups, management, security)

> Artifact of the mandatory deploy pre-clearance gate. First REDEPLOY of these three roots since the
> full estate teardown of 2026-07-11 (state backend + OIDC kept, all revocations done).
> Prepared by: architect. Date: 2026-07-12.
> Evidence: live az CLI enumeration 2026-07-12 (RBAC per-scope, soft-delete lists, Defender pricing,
> MG tree, policy assignments, state-SA config), gh CLI (variables/secrets/environments), GitHub
> release/issue sweep for the pinned ALZ surface, MS Learn (LAW soft-delete semantics), azurerm
> features-block defaults. Scope per OQ-034..040 resolutions: B0a = these 3 roots only; B0b
> (connectivity, identity, spokes) deferred until wave B2 is ready.

## Verdict: GO-conditional. Four numbered preconditions, then apply in order.

| # | Precondition | Lane | Blocks |
|---|--------------|------|--------|
| PC-1 | Remove `KeyVaults` and `Arm` from `defender_basic_plans` in `platform/security/main.tf` (ADR-040). Both are live-Free post-teardown; re-applying them Standard is NEW enablement of deprecated plans and fails deterministically (400, the 2026-07-05 API block). Keep the `StorageAccounts = "DefenderForStorageV2"` pin (ADR-035). Must land on the dispatch ref before the security apply. | cloud-engineer, then reviewer | security root |
| PC-2 | Time-boxed **User Access Administrator @ Tenant Root Group** grant to the CI SP (ADR-041). Verified live: UAA carries `Microsoft.Authorization/*`, which covers every MG-scope policy definition / set definition / assignment / exemption write AND the DINE remediation-identity role assignments the three roots create at the recreated MG scopes. Nothing the SP currently holds covers these (the globaris-scoped rows died with the MG tree). Revoke after the post-B0a bootstrap rebind (step 6 below). | operator (USER-MANUAL) | all 3 roots |
| PC-3 | Time-boxed **Cost Management Contributor @ Tenant Root Group** grant to the CI SP (ADR-041). Verified live: it carries `Microsoft.Consumption/*`, needed for the three MG-scope budgets in the management root (globaris / platform / landingzones). This was a LATENT ADR-021 gap previously masked by the standing Owner @ globaris (OQ-008); durable home is OQ-041. | operator (USER-MANUAL) | management root |
| PC-4 | Plan-first + plan-scan per root, every apply (LESSON 26). Post-teardown states are empty, so every plan must be PURE ADDS: any `-/+ replace`, any destroy, any unexpected import is a STOP. The first plan per root also doubles as the state-backend / stale-lease probe (the operator IP cannot reach the firewalled SA to inspect leases directly; the CI JIT window can). | devsecops + architect scan | all 3 roots |

Date-triggered addenda (only if B0a slips):
- After **2026-07-25**: LESSON 41 lifecycle re-audit fires (2 weeks since the last audit at teardown),
  AND the two soft-deleted LAWs fall out of their 14-day window (behavior flips from recover to fresh
  create, see check 2). Re-run this pre-clearance's check 2 and 5.
- After **2026-07-31**: bump `budget_start_date` in `envs/poc.tfvars` to `2026-08-01T00:00:00Z`
  (Consumption API rejects a start date prior to the current month).

---

## 1. State backend readiness: PASS (lease check deferred to the first CI plan)

Verified live 2026-07-12:
- State SA (`stglobaristfstate01` in `rg-tfstate-mgmt-eus2-001`, management sub) EXISTS; firewall
  `default_action = Deny` (expected steady state), bypass AzureServices, 1 static ip rule, shared
  keys disabled. The teardown's manual Deny restore held.
- Blob/lease enumeration from the operator workstation is BLOCKED by the firewall (by design). The
  teardown ended green on all three roots (management-groups last), so their states are expected
  empty-with-serial-bumped; the lock quirks during teardown (management stale lock) were cleared via
  the CI `force-unlock` action, which remains available (`deploy.yml action=force-unlock`, single
  target + `lock_id`). Disposition: the PC-4 plan-first run per root is the probe; a stale lease
  surfaces at init/plan and is cleared with the proven CI path. OPERATOR-OPTIONAL: eyeball the three
  blobs' leases during the first JIT window.
- `deploy.yml` wiring confirmed: every root job passes `manage_runner_ip: ${{ inputs.target != 'all' }}`,
  so all B0a single-target runs get the JIT firewall flip + Deny restore on exit (LESSON 16 / ADR-025).
  Init has the bounded retry backstop for firewall propagation.

## 2. Soft-delete collisions: KV premise CORRECTED (no collision); LAW x2 recover-by-create; EH/AA clean

### Security Key Vault: NO name collision (task premise corrected)
The vault name is `kv-sec-<org_prefix>-<random_id.hex>` (`platform/security/main.tf:97-109`). The
`random_id` lived in the destroyed state, so the redeploy generates a NEW suffix and a NEW vault name.
The soft-deleted vault from 2026-07-11 (purge protection ON, scheduled purge 2026-10-09, verified via
`az keyvault list-deleted`) does not collide and cannot be purged; it parks at zero cost until Azure
purges it. No recovery flag, no extra permission, no code change needed.
- `platform/security/providers.tf` carries an empty `features {}`; azurerm 4.x documented defaults are
  `recover_soft_deleted_key_vaults = true` and `purge_soft_delete_on_destroy = true` (verified against
  the provider features-block doc 2026-07-12). Both are moot for a new name; the defaults are correct
  for this lifecycle anyway (purge attempt is skipped on purge-protected vaults, as the green teardown
  proved).
- Build-verify-destroy note: each deploy/destroy cycle strands one more purge-protected soft-deleted
  vault for 90 days. Zero cost, zero collision (random names). Accepted; no action.
- Noted in passing: five unrelated `kv-pptest-*` soft-deleted vaults (no purge protection) predate the
  estate in the security sub. Not ours; no action.

### Log Analytics workspaces: BOTH deterministic names sit in 14-day soft delete; create = recover
Verified live: `law-platform-globaris-poc` (management sub) and `law-security-globaris-poc` (security
sub) are in the soft-delete list (deleted 2026-07-11; window ends ~2026-07-25). MS Learn (delete-workspace,
verified 2026-07-12): the name is RESERVED during soft delete, and a create (PUT) with the same
subscription + RG name + workspace name + region IS the documented recovery operation. Both roots
recreate the same RG names and names/regions, so the Terraform creates will RECOVER the workspaces and
succeed. Permission is `workspaces/write` (Contributor at the sub, held). Consequences, per the doc:
- Recovered workspaces return WITH prior data/tables (harmless; ingestion-billing neutral at this scale).
- Solutions and linked services (including the Sentinel/SecurityInsights solution on the security LAW)
  were PERMANENTLY removed at delete time, so the fresh `azurerm_sentinel_log_analytics_workspace_onboarding`
  create is expected clean. Watch-item: if it 409s "already onboarded", the disposition is IMPORT the
  onboarding resource (config-driven), never blind-retry.
- If B0a lands after ~2026-07-25 the names are released and both become plain fresh creates (then the
  `PLATFORM_LAW_CUSTOMER_ID` secret goes stale - a B0b concern, see check 6).
- Lifecycle recommendation (non-blocking, cloud-engineer, ADR-041 follow-up): set
  `features { log_analytics_workspace { permanently_delete_on_destroy = true } }` (documented default
  is `false`) in the management + security providers so FUTURE teardowns free the names immediately -
  the doc's stated pattern for repeated dev/test redeploys. Not required for this apply.

### Event Hub namespace, Automation Account: PASS
- EH namespace name is `random_id`-suffixed (`defender.tf:89`) and EH namespaces have no soft-delete
  semantics: fresh name, fresh create.
- Automation Account (`aa-platform-<org>-poc`) has no soft-delete semantics; name freed at delete.
- Defender pricing plans: all plans verified live **Free** in the security sub (teardown V-5 held) -
  which is exactly what makes the config's KeyVaults/Arm entries a deterministic failure. See PC-1.

## 3. RBAC reality vs need: sub lane INTACT (teardown log under-reported); MG lane is the gap

Live per-scope enumeration 2026-07-12 (direct `--scope` queries per subscription; note the
`az role assignment list --assignee --all` form under-reports to a non-elevated caller and is what
produced the too-small list in the teardown WORKLOG entry - same artifact recorded 2026-07-09):

| Held live (verified) | Scope |
|---|---|
| Contributor + User Access Administrator | ALL FIVE subscriptions (management, connectivity, identity, security, landingzones) |
| Storage Blob Data Contributor | state SA |
| Management Group Contributor | Tenant Root Group |

Bootstrap local state agrees (all 10 sub-scope assignments present). GONE (died with the MG tree,
confirmed empty at the globaris scope): Resource Policy Contributor @ globaris, UAA @ globaris, UAA @
landingzones (bootstrap rows 2/3/4, now dangling in bootstrap state), and the 3 standing OQ-008
Owner @ MG grants. The Owners MUST NOT be re-created - their death is the OQ-008 scope-down finally
taking effect; B0a is the ADR-021 validation run.

Per-root need vs held:

| Root | Needs | Held? |
|---|---|---|
| management-groups | MG tree create + 5 sub placements (MG Contributor @ tenant root); policy defs/set defs/assignments + DINE remediation role assignments AT the recreated MG scopes | MG Contributor YES. MG-scope Authorization writes NO -> **PC-2**. Sub-placement precedent: the original 2026-07-05 apply moved all 5 subs under the same grant with subs sitting at tenant root - identical starting condition now; PC-2 adds `roleAssignments/write` everywhere as belt and braces |
| management | All sub-scope resources incl. per-sub budgets/exports across the 5 subs (Contributor per sub - held); tag-governance Modify assignment + remediation role assignment @ globaris (**PC-2**); 3 MG-scope consumption budgets (**PC-3**) | Partially -> PC-2 + PC-3 |
| security | RG/LAW/KV/Sentinel/EH/Defender pricing + contact + sub activity-log diagnostics (Contributor + UAA @ security sub - HELD, verified directly); NIST + CIS initiative assignments @ globaris (**PC-2**) | Mostly -> PC-2 |

What re-grants what: NOTHING in the three applies restores the SP's own MG-scoped roles. Bootstrap
rows 2/3/4 rebind ONLY via a full local `bootstrap/` re-apply AFTER management-groups has recreated the
MG tree (their scopes must exist at apply time - the documented bootstrap-ordering caveat). A full
bootstrap apply BEFORE B0a would fail on those rows. Hence the ADR-041 bridge: temp tenant-root grants
(PC-2/PC-3) for the window, full bootstrap re-apply after management-groups is green (also reconciles
the known WORM-policy state drift), then revoke temp UAA. Durable home for the Consumption gap: OQ-041
(recommended: new bootstrap row, Cost Management Contributor @ globaris MG). Both role definitions were
verified live today (UAA = `*/read, Microsoft.Authorization/*, Microsoft.Support/*`; Cost Management
Contributor = `Microsoft.Consumption/*, Microsoft.CostManagement/*, ...`).

Tenant/directory prerequisites: none for B0a. All Security-Administrator-gated features stay off
(enable_ueba, enable_aad_diagnostics, enable_aad_connector, enable_ti_connector, enable_mde_connector,
enable_firewall_ti_rule - default false, ADR-033/034). RP registrations in the security sub verified
live STILL Registered (SecurityInsights, OperationsManagement, EventHub, Security, OperationalInsights) -
teardown does not unregister them, so the redeploy skips the first-apply registration wait.

## 4. Live policy matrix: clean; only Microsoft system assignments remain

- MG scope: only the Tenant Root Group exists (verified). Its assignments are three Microsoft-managed
  system items: `sys.mfa-write` / `sys.mfa-delete` (mandatory MFA enforcement for resource write/delete -
  applies to USER identities; workload identities such as the CI SP are exempt per Microsoft's mandatory
  MFA rollout docs; also empirically these applies ran green through 2026-07-11) and
  `sys.blockwesteurope` (region restriction on westeurope only; estate deploys eastus2/centralus).
  Not deletable, not blocking.
- Sub scope: management sub carries `SecurityCenterBuiltIn` (ASC Default, audit-class); security sub
  carries `SqlVmAndArcSqlServersProtection` (Defender auto-provisioning leftover, DINE-class). Neither
  denies creates. Optional cleanup, not blocking.
- Recreate-order note: management-groups re-creates the ALZ policy engine BEFORE management/security
  apply, restoring the ORIGINAL verified collision matrix (docs/preclearance/platform-security.md): the
  Enforce-GR-KeyVault purge-protection/soft-delete Denies are satisfied by config; the KV firewall
  member is Audit-only; EH guardrails are DoNotEnforce. Watch (noise-class, never blocks creates):
  Deploy-MDFC-Config DINE remediations that touch deprecated Defender plans will fail their remediation
  tasks; upstream issue 4203 flags wrong defaults in a NEWER variant of that policy - our library ref
  is pinned 2026.04.2 and unaffected at plan/apply.
- Tag-governance Modify returns with the management root; the known benign estate-wide CreatedDate
  drift (OQ-032) resumes with it. Accepted.

## 5. Provider/module drift since 2026-07-11: NONE blocking

- Pins unchanged (avm-ptn-alz 0.19.1, alz provider ~>0.21.0, azurerm ~>4.71.0, azapi ~>2.9.0/2.5/2.4
  per root). Upstream sweep 2026-07-12: no avm-ptn-alz release since v0.21.0 (2026-05-26) - the 0.19.1
  pin is untouched; NO platform/alz library release after the pinned 2026.04.2 (an immutable ref in any
  case); no new open issue on the avm-ptn-alz or Azure-Landing-Zones repos matching our pinned surface
  (MG recreate, policy engine, provider) since the last successful management-groups deploy.
- Defender for Cloud release notes recheck: no NEW plan-enablement blocks beyond the five of 2026-07-05
  (KubernetesService, ContainerRegistry, KeyVaults, Dns, Arm). The remaining configured plans
  (VirtualMachines/P2, StorageAccounts, AppServices, SqlServers, SqlServerVirtualMachines, Containers,
  OpenSourceRelationalDatabases, CloudPosture) are current. The grouped-recommendations deprecation
  (2026-07-30) does not touch pricing PUTs.
- The one config-vs-live landmine is PC-1 (KeyVaults/Arm Standard-in-config vs Free-live + new-enablement
  block). Full LESSON 41 re-audit not triggered (1 day since teardown); trigger date 2026-07-25.

## 6. GitHub side: PASS with two hygiene notes

- `_tf-root.yml` and `deploy.yml` on main contain NO reference to `aadds_import_replica_set_id`
  (removed in 010d4a9, which IS on main; the banking branch also contains it but is behind main).
  Dispatch from **main**. PC-1 must be merged to the dispatch ref before the security run (per the new
  feature -> dev -> main flow).
- Hygiene (non-blocking): the orphaned repo Secret `AADDS_IMPORT_REPLICA_SET_ID` still exists and is
  read by nothing - delete it. Bootstrap state still references the dead rows 2/3/4 assignments -
  reconciled by the post-B0a full bootstrap re-apply.
- Repo Variables: all 3 present (AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID) - the only
  set `_tf-root.yml` hard-validates. Secrets needed by the 3 roots all present: AZURE_TENANT_ID, the 5
  *_SUBSCRIPTION_ID, TERRAFORM_SP_OBJECT_ID, SECURITY_CONTACT_EMAIL, BUDGET_ALERT_EMAIL. The five
  never-set optional secrets (SENTINEL_OWNER_GROUP_OBJECT_ID, HONEYPOT_USER_PRINCIPAL_NAME,
  BREAK_GLASS_GROUP_OBJECT_ID, PIM_*_GROUP_OBJECT_ID) resolve to empty strings with skip-semantics
  defaults - identical to the original green runs.
- Stale-but-not-B0a: the hub/LAW cross-root output secrets (PRIMARY/SECONDARY_HUB_*, PLATFORM_LAW_*,
  PLATFORM_ACTION_GROUP_ID) are consumed by B0b roots only. If the platform LAW is RECOVERED (applies
  within the 14-day window) its resource ID and customer GUID are preserved and the secrets stay valid;
  if B0a/B0b slips past ~2026-07-25 the LAW is a fresh create and `PLATFORM_LAW_CUSTOMER_ID` (+ possibly
  PLATFORM_ACTION_GROUP_ID if names change - they do not) must be re-captured. Carry to the B0b
  pre-clearance.
- Environments `production` / `production-destroy` exist, ungated - the OQ-015 accepted interim.

## 7. Cost sanity: B0a idles at roughly $30-50/month

Dominated by the Event Hub Standard 1 TU (~$22/mo). LAW + Sentinel ingestion on near-empty subs is
single-digit dollars (activity logs only; the tenant-scoped connectors stay gated off). Defender plans
bill per protected resource and the subs are near-empty (0 servers, 0 app services, 0 SQL, no storage
accounts in the security sub), so ~$0 despite Standard tiers. MGs, policies, budgets, exports, action
group, workbooks: free. FinOps/cost-export SA: pennies. Budgets recreate at $200/sub + $600/MG (alert
thresholds only, not spend). The big-ticket items (2 Premium firewalls, VPN GW, AADDS, App Gateway)
stay DOWN until B0b. Meter reading for the authoring gap: about $1.0-1.7/day.

---

## Ordered execution runbook

1. PC-1 lands (cloud-engineer edit, reviewer approval, user merges to main).
2. Operator creates the two time-boxed tenant-root grants (PC-2, PC-3). Doing this may require the
   operator to re-elevate access (Global Admin elevateAccess) or act from an account with UAA at tenant
   root; the SP object ID and tenant-root MG ID are hand-off values per the house rule.
3. `deploy.yml`: `target=platform/management-groups`, `action=plan` (branch main, ungated). Plan-scan:
   pure adds (~319 expected from precedent), 0 destroy, 0 replace. Then same target `action=apply`.
4. `deploy.yml`: `target=platform/management`, `action=plan`. Scan: pure adds; the LAW create is the
   documented recovery PUT. Then `action=apply`.
5. `deploy.yml`: `target=platform/security`, `action=plan`. Scan: pure adds; confirm NO pricing
   resource named KeyVaults, Arm, or Dns appears; expect the KV and EH namespace with NEW random
   suffixes. Then `action=apply` (pricing PUT serialization is already code-side via depends_on).
6. Post-B0a: qa-engineer live-vs-intent pass per root (house gate); full local `bootstrap/` re-apply
   (rows 2/3/4 rebind at the recreated MGs, WORM policy reconcile, plus the OQ-041 row if resolved =
   recommended option A); revoke the temp UAA @ tenant root; resolve OQ-041 disposition for the
   Cost Management Contributor grant; delete the orphaned AADDS secret.

All three runs are single-target, so `manage_runner_ip` auto-resolves true (JIT state-SA window,
restored to Deny on exit). One consolidated fix-spec per failure set if anything fails (LESSON 59);
any 403 gets the PRECISE missing action/scope added, never an Owner re-grant.

## Watch-items during the applies (dispositions pre-agreed)

| Symptom | Disposition |
|---|---|
| Stale state lease at init/plan | CI `force-unlock` (single target + lock_id), then re-plan |
| Sentinel onboarding 409 "already onboarded" | Config-driven IMPORT of the onboarding resource; no blind retry |
| Defender pricing 409 "another update in progress" | Already serialized code-side; if it still fires, single rerun (plans in state become no-ops) |
| MDFC DINE remediation failures on deprecated plans | Noise only; never blocks creates; ignore |
| MG or sub-placement eventual-consistency error right after MG create | Single rerun of the same root; avm-ptn-alz sequences internally, residual races clear on retry |

---
---

# REFRESH ADDENDUM - 2026-07-21 (wave B0a redeploy, second rebuild)

> Everything above this line is the 2026-07-12 record and is retained verbatim as history. It described
> the estate as it stood after the 2026-07-11 teardown. Since then the estate was fully rebuilt
> (B0a on 2026-07-16, B0b, then banking waves B1 to B7 all green) and torn down again on 2026-07-20
> (ADR-054 teardown redesign, green E2E, run 29765892057). Every "verified live" fact in the 07-12
> section is therefore one full build-and-teardown cycle out of date. This addendum supersedes it.
>
> Prepared by: architect. Date: 2026-07-21. Condition series: **PC-nR** (fresh series, cannot collide
> with the 07-12 PC-1..PC-4 or the identity PC-1G..PC-8G series).
> Scope: B0a only, three roots, in order `platform/management-groups`, `platform/management`,
> `platform/security`. B0b (connectivity, identity, spokes) and the banking waves are NOT cleared here;
> `platform/identity` has its own current gate in `docs/preclearance/platform-identity.md`.
>
> Evidence gathered 2026-07-21: live `az` enumeration (per-scope role assignments via direct ARM REST
> at each scope, MG tree, soft-deleted LAW and Key Vault lists, Defender pricing per plan, policy
> assignments at every sub and at Tenant Root Group, resource-provider registration states,
> subscription-scoped budgets / cost exports / scheduled actions / diagnostic settings, state storage
> account config); `gh` (repo Variables, Secrets, Environments, workflow run history, upstream release
> and issue sweep); `git` against `origin/*` refs only; azurerm v4.71.0 provider SOURCE at the pinned
> tag for create-time guard behaviour; the pinned avm-ptn-alz 0.19.1 module source for policy role
> assignment scoping; Microsoft Learn for Sentinel and Cost Management lifecycle.

## Verdict: GO-CONDITIONAL. Six conditions. Three of them are USER-ACTION and are on today's critical path.

The headline change since 07-12 is that **the 2026-07-20 teardown was not complete at subscription
scope**. It cleaned resource groups and the management group tree, but left a layer of
subscription-scoped objects alive, and left Defender for Cloud pricing armed. The 07-12 plan assumed a
true greenfield (that is what made the 07-16 applies pure adds). That assumption is now false, and it
breaks two of the three roots deterministically at PUT time while the plan still looks perfectly clean.

**21 pre-known deterministic create failures** are queued up if the three roots are dispatched as-is:
12 in `platform/management`, 9 in `platform/security`. All 21 are invisible to `validate` and to `plan`,
because every one of them is a create-time existence guard inside the provider, not a schema or graph
property. Conditions PC-1R, PC-2R and PC-3R remove all 21.

| # | Condition | Lane | Blocks |
|---|-----------|------|--------|
| **PC-1R** | **Purge the 12 subscription-scoped teardown survivors.** 5 subscription budgets + 5 cost exports + 1 cost anomaly scheduled action (management sub) + 1 subscription diagnostic setting (security sub). Every one collides by exact name with a resource the roots create, and every one of the four provider resource types carries a create-time requires-import guard (source-verified below). | **user-action** | management, security |
| **PC-2R** | **Reset the 8 configured Defender for Cloud pricing plans in the security sub to `Free`.** They are all live `Standard` (armed 2026-07-16, never disarmed by the teardown). `azurerm_security_center_subscription_pricing` create hard-fails when the live tier is not Free. All 8 are current, non-deprecated plans, so re-enabling them is permitted; this is NOT the LESSON 41 trap, and the 5 deprecated plans stay Free and untouched. | **user-action** | security |
| **PC-3R** | **Unregister `Microsoft.CostManagementExports` in the management subscription.** It is live `Registered`; `azurerm_resource_provider_registration` returns requires-import when the RP is already registered. The 07-11 teardown had unregistered it, which is exactly why the 07-16 apply was green. | **user-action** | management |
| **PC-4R** | **Resolve the `enable_om_phase1` greenfield ordering circularity.** `envs/poc.tfvars` now sets `enable_om_phase1 = true` (wave B7, landed 2026-07-19). On a greenfield that is circular: `platform/management-groups` needs the AMBA managed identity that `platform/management` creates, and `platform/management` needs the MG tree that `platform/management-groups` creates. **Recommended: set `enable_om_phase1 = false` for the B0a pass** and re-land wave B7 in its natural position after the estate is back, exactly as it was built and proven on 2026-07-19. Alternative: a per-run dispatch override mirroring ADR-055. | **cloud-engineer** (then reviewer), or **devsecops** if the override route is chosen | management-groups, management |
| **PC-5R** | **Dispatch every B0a run from `banking`, not `main`, and plan-first with a pure-adds plan-scan per root.** The 07-12 instruction to "dispatch from main" is STALE and wrong under ADR-056. Post-PC-1R/2R/3R the states are empty AND the estate is genuinely greenfield, so every plan must be pure adds: any `-/+ replace`, any destroy, any import is a STOP. The first plan per root also doubles as the state-backend and stale-lease probe. | **devsecops** dispatch, **architect** scan | all 3 |
| **PC-6R** | **Non-blocking follow-ups to record before the estate is rebuilt on top of the gaps.** (a) The teardown has no subscription-scope sweep: raise it as an open question and fix `teardown.yml` before the next teardown, otherwise this same 21-failure set returns every cycle. (b) LESSON 54 durable fix: stop managing `Microsoft.CostManagementExports` registration inside `platform/management`. (c) The ADR-041 temporary tenant-root grants are still attached and still un-revoked. | **architect** | nothing today |

**RBAC needs NO condition this cycle.** The 07-12 PC-2 and PC-3 (the ADR-041 time-boxed tenant-root
grants) are both still live on the CI deploy SP and were never revoked. See check 1.

---

## 1. RBAC: every grant the three roots need is LIVE. No user action.

Enumerated per scope with explicit scope-targeted ARM queries (`.../providers/Microsoft.Authorization/
roleAssignments?$filter=atScope()` at Tenant Root Group, at each of the five subscriptions, and at the
state storage account). The `az role assignment list --assignee --all` form was deliberately NOT used;
it under-reports to a non-elevated caller and has produced wrong conclusions in this repo twice.

| Role | Scope | State | Created |
|---|---|---|---|
| Management Group Contributor | Tenant Root Group | LIVE | original bootstrap |
| **User Access Administrator** | **Tenant Root Group** | **LIVE (ADR-041 temp grant, the 07-12 PC-2)** | 2026-07-16 |
| **Cost Management Contributor** | **Tenant Root Group** | **LIVE (ADR-041 temp grant, the 07-12 PC-3)** | 2026-07-16 |
| Contributor | each of the 5 subscriptions | LIVE (all five) | original bootstrap |
| User Access Administrator | each of the 5 subscriptions | LIVE (all five) | original bootstrap |
| Storage Blob Data Contributor | state storage account | LIVE | original bootstrap |

Consequences:
- The MG-scope Authorization writes that the 07-12 gate had to bridge (policy definitions, set
  definitions, assignments, exemptions, and the DINE remediation role assignments at the recreated MG
  scopes) are covered by the still-live tenant-root UAA. Nothing to grant.
- The three MG-scope consumption budgets in the management root are covered by the still-live tenant-root
  Cost Management Contributor.
- No Owner grant exists anywhere and none must be created. B0a remains the ADR-021 least-privilege
  validation run.
- **These two grants are five days past their "time-boxed" intent.** They are needed again for this
  rebuild, so do NOT revoke them now (LESSON 57: revocation happens strictly after a verified-clean
  destroy, and elevated grants stay attached through the work they enable). Carry the revocation, plus
  the OQ-041 durable-home decision, into the post-B0a bootstrap reconcile. PC-6R(c).

**Tenant and directory prerequisites for B0a: none.** Every Security-Administrator-gated feature is
explicitly off in `envs/poc.tfvars` (`enable_aad_diagnostics = false`, `enable_ueba = false`,
`enable_aad_connector = false`, `enable_ti_connector = false`, `enable_mde_connector = false`,
`enable_firewall_ti_rule = false`). Note the code defaults for `enable_aad_diagnostics` and
`enable_ueba` are `true`; the tfvars file is what holds them off, so the tfvars file must be passed
(it is, by `_tf-root.yml`, on every plan and apply).

## 2. MG tree: genuinely empty. Teardown verified clean at MG scope.

- The only management group in the tenant is Tenant Root Group. No Globaris root, no platform family,
  no landing zone MGs. The 11-MG topology is fully gone.
- All five estate subscriptions sit directly under Tenant Root Group, alongside two unrelated
  subscriptions that are not part of this estate. This is the identical starting condition to the
  2026-07-05 first-ever apply and to the 2026-07-16 rebuild, both of which moved all five subscriptions
  successfully under Management Group Contributor.
- No resource groups survive in the security, connectivity or identity subscriptions. The management
  subscription holds only the Terraform state resource group and the service-created `NetworkWatcherRG`.
  The landingzones subscription holds only pre-existing non-estate resource groups.

## 3. Teardown survivors and soft-delete collisions (RECOMPUTED for the 2026-07-20 delete)

### 3a. THE NEW BLOCKER: 12 subscription-scoped objects survived (PC-1R)

Resource groups and management groups were deleted, but subscription-scoped extension resources were
not. All 12 are live right now and all 12 collide by exact name with a resource these roots create
(the names are `org_prefix`-derived and deterministic, verified against the config):

| Object | Count | Subscription | Created by | Provider guard at v4.71.0 |
|---|---|---|---|---|
| `budget-sub-<lz>-<org>` subscription budgets | 5 (one per sub) | all five | `azurerm_consumption_budget_subscription` (management root, via `modules/finops`) | `tf.ImportAsExistsError` |
| `export-daily-<lz>-<org>` cost exports | 5 (one per sub) | all five | `azapi_resource` at `Microsoft.CostManagement/exports@2025-03-01` (ADR-027) | azapi "Resource already exists" |
| `anomaly-alert-management-<org>` scheduled action | 1 | management | `azurerm_cost_anomaly_alert` (management root) | `ResourceRequiresImport` |
| `diag-activity-to-security-law` subscription diagnostic setting | 1 | security | `azurerm_monitor_diagnostic_setting` (security root) | `tf.ImportAsExistsError` |

Every guard was read from the pinned provider source, not from memory or from docs. Each one turns a
clean-looking plan add into a hard apply error. 11 hit `platform/management`, 1 hits `platform/security`.

**Disposition: delete them (PC-1R), do not import them.** Deleting restores the exact greenfield the
07-16 green run started from and keeps the pure-adds plan-scan bar meaningful. Importing would need 12
import blocks across two roots plus a mandatory removal commit (LESSON 52), two extra review cycles on
the critical path, for zero benefit: none of the 12 holds state worth preserving (budgets are alert
thresholds, exports re-emit on their next schedule, the diagnostic setting points at a soft-deleted
workspace).

### 3b. THE SECOND NEW BLOCKER: Defender pricing survived armed (PC-2R)

Live tiers in the security subscription today, versus the 07-12 record of "all plans Free":

| Plan | Live tier now | Configured by us | Verdict |
|---|---|---|---|
| VirtualMachines | **Standard, subplan P2** | yes (`main.tf`, subplan pinned P2 per ADR-035) | must reset to Free |
| StorageAccounts | **Standard, subplan DefenderForStorageV2** | yes (`main.tf`, subplan pinned per ADR-035) | must reset to Free |
| AppServices, SqlServers, SqlServerVirtualMachines, Containers, OpenSourceRelationalDatabases, CloudPosture | **Standard** (no subplan) | yes (`defender.tf` extended set) | must reset to Free |
| KeyVaults, Arm | Free | **no** (removed per ADR-040) | leave alone |
| Dns, KubernetesService, ContainerRegistry | Free, API-flagged `deprecated: true` | **no** | leave alone, never re-enable |
| CosmosDbs, Api | Free | no | leave alone |
| AI | Standard | **no** (out-of-band, armed during the 07-16 window) | leave alone for B0a, but it is NOT benign indefinitely - see the note below. **OQ-052** |
| Discovery, FoundationalCspm | Standard | no | free foundational plans (both report `freeTrialRemainingTime = PT0S`), leave alone, no cost question |

> **Correction, 2026-07-21 (code review Finding 3, live-verified).** An earlier revision of this table
> called the `AI` plan "unmanaged drift, benign". That is true for B0a and false from mid-August. `AI`
> reports `enablementTime = 2026-07-16` and `freeTrialRemainingTime = P24DT12H40M` as of 2026-07-21,
> i.e. a 30-day free trial that **converts to billed Standard around 2026-08-15**. It is armed, owned
> by nobody, and referenced by nothing in the repo. Expected charge is at or near zero (Defender for
> AI bills per protected AI resource in that subscription, and the estate's AI platform lands in the
> landingzones subscription, not here), so this is an ownership and hygiene item rather than a cost
> emergency. **It does not gate B0a and must not be actioned as part of the rebuild.** Recommended
> disposition and the date arithmetic (the remaining-time field is measured from the query, not from
> enablement, so 08-09 is a common mis-derivation) are recorded in **OQ-052**.

Source-verified in azurerm v4.71.0
(`internal/services/securitycenter/security_center_subscription_pricing_resource.go`), the create path
returns, before it ever issues its PUT:

> `if err == nil && apiResponse.Model != nil && apiResponse.Model.Properties != nil && apiResponse.Model.Properties.PricingTier != PricingTierFree { return fmt.Errorf("the pricing tier of this subscription is not Free ..." , tf.ImportAsExistsError(...)) }`

So **all 8 configured plans fail at create**, not just the deprecated ones. This is the exact inverse
of the 07-12 finding and it is the single most important correction in this addendum.

**Disposition: reset the 8 to Free (PC-2R), then let Terraform create them.** This is safe and is NOT
a LESSON 41 / ADR-035 regression: none of the 8 carries the API `deprecated` flag (only Dns,
KubernetesService and ContainerRegistry do, and those are already Free and not in our config), so
re-enabling all 8 at Standard is permitted. The two subplans stay pinned in config, so config equals
state after create and the ADR-035 ForceNew landmine cannot re-arm. Fallback if any single plan refuses
to go Free: import that one plan (its live subplan already matches config, so the import is clean) and
report it before the apply.

### 3c. PC-1 of the 07-12 gate: LANDED and verified in code

`platform/security` no longer configures `KeyVaults` or `Arm`. `local.defender_basic_plans` is
`{ StorageAccounts = "DefenderForStorageV2" }` and `local.defender_extended_plans` contains no
deprecated plan. Verified by reading the code today, not assumed. Both files carry the ADR-040 rationale
in comments. The security plan must still show ZERO pricing resources named KeyVaults, Arm, Dns,
KubernetesService or ContainerRegistry.

### 3d. Log Analytics workspaces: both still recoverable, window recomputed

Both deterministic-name workspaces are in the soft-delete list, deleted 2026-07-19 (late UTC):

| Workspace | Subscription | Deleted | 14-day window ends |
|---|---|---|---|
| `law-platform-globaris-poc` | management | 2026-07-19 | approximately **2026-08-02** |
| `law-security-globaris-poc` | security | 2026-07-19 | approximately **2026-08-02** |

Today is 2026-07-21, so both are 12 days inside the window and the documented recovery semantics from
the 07-12 gate STILL HOLD: the name is reserved during soft delete, and a PUT with the same
subscription, resource group name, workspace name and region IS the recovery operation. Both roots
recreate identical resource group names, workspace names and regions, so both creates will recover.
Permission is `workspaces/write` at the subscription, held.

New supporting evidence: the platform workspace's `createdDate` is 2026-07-07 while its `modifiedDate`
is 2026-07-19. It was created on 07-07, soft-deleted on 07-11, RECOVERED by the 07-16 apply, then
soft-deleted again on 07-19. That is a live, in-this-estate proof that the recovery path works and that
recovery preserves the workspace `customerId`. Consequence for tomorrow: the `PLATFORM_LAW_CUSTOMER_ID`
and `PLATFORM_LAW_WORKSPACE_ID` Secrets stay valid as long as B0b lands before roughly 2026-08-02.
After that both workspaces become fresh creates and `PLATFORM_LAW_CUSTOMER_ID` must be re-captured.
Carry to the B0b gate.

Unchanged from 07-12: solutions and linked services (including the SecurityInsights / Sentinel
solution) are permanently removed at delete, so the fresh Sentinel onboarding create is expected clean.
Watch-item retained.

### 3e. Key Vaults: still no collision, premise re-verified

`az keyvault list-deleted` in the security subscription now returns exactly two soft-deleted vaults,
both ours, both purge-protected, both with DIFFERENT random suffixes (one from the 07-11 teardown with
a scheduled purge in early October, one from the 07-19 teardown with a scheduled purge in mid-October).
That is the random-suffix design working as documented: `kv-sec-<org_prefix>-<random_id.hex>` where the
`random_id` died with the state, so the redeploy mints a third distinct name. No collision, no recovery
flag, no permission, no code change. The five unrelated non-estate soft-deleted vaults noted on 07-12
are gone (expired). Each build-verify-destroy cycle strands one more zero-cost vault for 90 days;
accepted, no action.

### 3f. Event Hub namespace, Automation Account: clean

No Event Hub namespaces live in the security subscription and no Automation Accounts live in the
management subscription. The EH namespace name is `random_id`-suffixed and EH has no soft-delete
semantics; the Automation Account name is deterministic but Automation has no soft-delete semantics and
the name is free. Both are plain fresh creates.

## 4. Resource-provider registrations: one blocker, everything else clean

All namespaces the three roots touch are `Registered` in both the management and security
subscriptions: OperationalInsights, OperationsManagement, Insights, Automation, Storage, CostManagement,
Consumption, Security, SecurityInsights, KeyVault, EventHub, PolicyInsights, ManagedIdentity,
Management. Teardown does not unregister them, so the redeploy skips the first-apply registration wait.
`Microsoft.AlertsManagement` is `NotRegistered` in both, and is referenced by nothing in these three
roots (no direct usage; the AMBA examples that mention alert processing rules are module example code,
not our call). Not a blocker.

**The one blocker is `Microsoft.CostManagementExports` (PC-3R).** It is `Registered` in the management
subscription and `NotRegistered` in the other four (correct: the export destination storage account
lives in the management subscription, so `platform/management` registers it only there). Source-verified
in azurerm v4.71.0 (`internal/services/resource/resource_provider_registration_resource.go`), the create
path does:

> `if strings.EqualFold(registrationState, "Registered") { return metadata.ResourceRequiresImport(...) }`

so `azurerm_resource_provider_registration.cost_management_exports` fails deterministically. The 07-11
teardown unregistered it (a Terraform destroy of that resource unregisters the RP) which is why the
07-16 apply was green; the 07-20 teardown did not. Unregistering is safe: no Cost Management export
resources will exist once PC-1R has removed the five survivors, and the CI SP holds Contributor, which
carries `*/register/action`. **Sequence matters: run PC-1R before PC-3R**, so the RP has no dependent
resources when it is unregistered.

Durable fix, deferred to PC-6R(b): LESSON 54 says do not manage RP registration in the same root as the
resources. Registering this namespace out-of-band and dropping the resource from the root removes this
failure mode permanently.

## 5. State backend: PASS, unchanged posture, lease probe deferred to the first CI plan

- The state storage account exists in the management subscription, provisioning `Succeeded`, firewall
  `defaultAction = Deny` with `bypass = AzureServices` and one static IP rule, shared key access
  disabled, public network access enabled (that combination is the intended steady state: Entra-only
  auth plus blob RBAC plus the JIT window). The teardown's manual Deny restore held.
- Blob and lease enumeration from the operator workstation is blocked by the firewall by design. All
  three roots ended green at teardown, so their state blobs are expected empty with a bumped serial.
- **`deploy.yml` still passes `manage_runner_ip: ${{ inputs.target != 'all' }}` on every root job**
  (verified line by line, 11 occurrences, all three B0a roots included). Every single-target B0a run
  therefore gets the JIT firewall flip plus the guaranteed Deny restore on exit (LESSON 16 / ADR-025).
- The 2026-07-16 firewall-settle hardening is present on the dispatch ref: `_tf-root.yml` requires 3
  consecutive successful reachability probes 8 seconds apart before `init`, with a counter that resets
  on failure. That fix was written precisely because 3 of 5 runs on 07-16 died on the propagation flap.
  Keep it in mind if an init 403 appears anyway; it is a known class with a known backstop.
- Stale-lease disposition (carried forward from 07-12 PC-4, unchanged): the PC-5R plan-first run per
  root is the probe. A stale lease surfaces at init or plan and is cleared with the proven CI path
  (`deploy.yml action=force-unlock`, single target plus `lock_id`).
- Reminder from LESSON 31: one state-storage-account-touching run at a time. All B0a dispatches are
  sequential and single-target, so this holds by construction. Do not run a local plan against the
  firewalled account (LESSON 51), and if any local init misbehaves, delete `.terraform` first
  (LESSON 63).

## 6. Live policy matrix: clean, nothing denies these creates

At **Tenant Root Group** (the only MG that exists) there are exactly three assignments, all
Microsoft-managed system items, all `enforcementMode = Default`, none deletable, none blocking:
`sys.mfa-write` and `sys.mfa-delete` (mandatory MFA enforcement for resource write and delete, which
applies to USER identities; workload identities such as the CI SP are exempt per Microsoft's mandatory
MFA rollout, and empirically every apply through 2026-07-20 ran green under them) and
`sys.blockwesteurope` (region restriction on West Europe only; this estate deploys eastus2 and
centralus).

At **subscription scope**, only Defender for Cloud auto-provisioning assignments remain, all audit or
DINE class, none Deny:

| Subscription | Assignments |
|---|---|
| management | `SecurityCenterBuiltIn` (ASC Default) |
| security | `SqlVmAndArcSqlServersProtection`, `OpenSourceRelationalDatabasesProtectionSecurityCenter`, `DataProtectionSecurityCenter` |
| connectivity | `SecurityCenterBuiltIn` |
| identity | none |
| landingzones | `SecurityCenterBuiltIn` |

The two additional security-sub assignments are new since 07-12; they were auto-created when the
Defender plans were armed on 07-16 and are a direct consequence of the PC-2R condition above. They are
DINE, not Deny. Optional cleanup, not blocking. Note they may linger after PC-2R resets the plans to
Free; that is cosmetic.

**Recreate-order note (unchanged and still important):** `platform/management-groups` restores the ALZ
policy engine BEFORE `platform/management` and `platform/security` apply, which restores the original
verified collision matrix in `docs/preclearance/platform-security.md`. The Enforce-GR-KeyVault
purge-protection and soft-delete Denies are satisfied by config (purge protection on, 90-day retention);
the Key Vault firewall member is Audit-only; the Event Hub guardrails are DoNotEnforce. The
Enable-DDoS-VNET placeholder Modify is set DoNotEnforce at both the connectivity and landingzones MGs
by the root's `policy_assignments_to_modify` (ADR-026), which matters for B0b, not B0a. The tag
governance Modify returns with the management root and brings back the benign estate-wide `CreatedDate`
drift (OQ-032); accepted, already formally recorded.

## 7. Provider, module and library drift since 2026-07-12: NONE reaches these roots

Every root commits a `.terraform.lock.hcl` with exact provider versions, so upstream releases cannot
float in. Verified pins:

| Root | Providers pinned by lock | Modules |
|---|---|---|
| management-groups | alz 0.21.0, azapi 2.9.0, azurerm 4.71.0, modtm 0.3.5, random 3.8.1, time 0.13.1 | `Azure/avm-ptn-alz/azurerm` 0.19.1 |
| management | azapi 2.10.0, azurerm 4.71.0, modtm 0.4.0, random 3.8.1, time 0.14.0 | `Azure/avm-res-operationalinsights-workspace/azurerm` 0.5.1, `Azure/avm-ptn-monitoring-amba-alz/azurerm` 0.4.0, local `modules/finops` |
| security | azapi 2.4.0, azurerm 4.71.0, modtm 0.3.5, random 3.8.1, time 0.14.0 | `Azure/avm-res-operationalinsights-workspace/azurerm` 0.5.1, `Azure/avm-res-keyvault-vault/azurerm` 0.10.2 |

Upstream sweep 2026-07-21:
- `avm-ptn-alz`: latest release is still v0.21.0 (2026-05-26). No release since the 07-12 sweep. The
  0.19.1 pin is untouched. Zero issues created or updated on the repo since 2026-07-10.
- `terraform-provider-alz`: latest is still v0.21.0 (2026-04-27). Zero issues since 2026-07-10.
- ALZ Library: `platform/alz/2026.04.2` is still the newest `platform/alz` release, and
  `platform/amba/2026.06.2` is still the newest AMBA release. Both pinned refs are current-latest, and
  both are immutable git tags in any case. No library release at all since 2026-06-12.
- `azurerm`: v4.81.0 shipped 2026-07-14, and v4.80.0 on 2026-07-02. **Not consumed**: every root's
  constraint is `~> 4.71.0` and every lock pins 4.71.0 exactly.
- `azapi`: v2.11.0 shipped 2026-07-16. **Not consumed**: locks pin 2.9.0 / 2.10.0 / 2.4.0. Note the
  management root's constraint is the looser `~> 2.5`, so a `terraform init -upgrade` (which CI does
  not run) WOULD pull 2.11.0. Leave the lock authoritative.
- `avm-ptn-monitoring-amba-alz`: no issues since 2026-07-10.
- Defender for Cloud: no new plan-enablement block beyond the five already known. Live API confirms
  only Dns, KubernetesService and ContainerRegistry carry `deprecated: true` (each with an explicit
  `replacedBy`); KeyVaults and Arm now return neither a `deprecated` flag nor a `replacedBy`, and both
  show `freeTrialRemainingTime`. That is a possible softening of the 2026-07-05 block. It changes
  nothing for B0a (neither plan is configured) and re-adding them is explicitly OUT of scope for this
  wave; park it as an ADR-040 revisit.
- Microsoft Sentinel: the subscription-based Microsoft Defender for Cloud connector that
  `azurerm_sentinel_data_connector_azure_security_center` creates is labelled legacy, and the Azure
  portal sunset for Sentinel management is 2027-03-31 (extended from an earlier 2026-07-01 date). It is
  still creatable and still supported today. Watch-item, not a blocker, and firmly a post-POC migration
  item.
- Cost Management: the `Microsoft.CostManagement/exports@2025-03-01` API used by ADR-027 is the current
  enhanced-exports GA surface. No deprecation reaches it.

**LESSON 41 trigger check.** The 07-12 doc set a re-audit trigger of 2026-07-25 and a
`budget_start_date` bump trigger of 2026-07-31.
- The 2026-07-25 lifecycle re-audit trigger has **NOT** fired (today is 2026-07-21). It is nonetheless
  effectively discharged: this addendum re-ran the full audit today.
- The 2026-07-31 `budget_start_date` trigger has **NOT** fired. `envs/poc.tfvars` still carries
  `budget_start_date = "2026-07-01T00:00:00Z"`, which is the first of the current month and therefore
  **valid for a July 2026 apply**. No change needed. **If B0a slips past 2026-07-31, bump it to
  `2026-08-01T00:00:00Z`** before the management apply (the Consumption API rejects a start date prior
  to the current month). `export_end_date` is 2030-12-01 and is fine.

## 8. Wave B7 collision on greenfield: the `enable_om_phase1` ordering circularity (PC-4R)

This did not exist on 2026-07-12. Wave B7 landed on 2026-07-19 and `envs/poc.tfvars` now carries
`enable_om_phase1 = true`, which changes BOTH B0a platform roots:

- `platform/management-groups` selects the `globaris-amba` architecture instead of `globaris`, adding
  roughly 223 AMBA policy objects on top of the 537 the `globaris` architecture creates.
- `platform/management` deploys `avm-ptn-monitoring-amba-alz` 0.4.0: `rg-amba-monitoring-001`, the
  `id-amba-prod-001` user-assigned managed identity, and that identity's Monitoring Reader role
  assignment **at the Globaris root management group**.

The circularity, which only bites on greenfield:
- `platform/management` cannot complete before `platform/management-groups`, because it writes a role
  assignment at the Globaris root MG and three MG-scope consumption budgets, and those MGs do not exist.
- `platform/management-groups` should not complete before `platform/management`, because the
  `Deploy-AMBA-*` DINE assignments attach `id-amba-prod-001` as their bring-your-own remediation
  identity by constructed resource ID. The B7 gate made this a hard ordering condition (PC-3F: "apply
  management FIRST, verify the MI is live, THEN apply management-groups; a missing MI means do not
  dispatch"). Reading the pinned module source confirms the exposure is real and possibly worse than
  the B7 note implies: `avm-ptn-alz` 0.19.1 creates policy role assignments as
  `azapi_resource.policy_role_assignments` with `parent_id = each.value.scope`, where the scope comes
  straight from the alz provider's generated `policy_role_assignments`. If any generated scope is the
  managed identity resource ID, that create targets a resource that does not exist yet. The module's
  default retry regex for this resource does include `ResourceNotFound`, so it may spin rather than
  fail immediately, but "may retry itself out of a design flaw" is not a bar this gate accepts.

When B7 was actually deployed, this was a non-issue: B0a was already green, so the MG tree existed and
management could be applied first. On a greenfield there is no ordering that satisfies both.

**Recommended disposition (PC-4R option A): set `enable_om_phase1 = false` in `envs/poc.tfvars` for
the B0a pass.** Rationale:
- It reproduces exactly the 2026-07-16 green B0a: `globaris` architecture, no AMBA module, known-good
  plan counts to scan against (537 / 36 / 48).
- It requires zero new CI code on a same-day start.
- Wave B7 then re-lands in its natural position, as an increment on a green estate, in the proven
  PC-3F order (management first, verify the MI is live, then management-groups). That is precisely how
  it was built and QA-passed on 2026-07-19.
- The flag exists for exactly this (LESSON 42 wave gating), and both roots' variable descriptions
  require them to hold the SAME value, which a single tfvars line satisfies.
- Cost: one reviewed one-line change now, and one reviewed one-line change back when B7 is redone.

**Alternative (PC-4R option B): add an `enable_om_phase1_override` dispatch input** to `deploy.yml` and
`_tf-root.yml`, mirroring the ADR-055 `enable_conditional_access_override` pattern approved on
2026-07-20 (blank means fall through to the tfvars/code value, `"false"` and `"true"` are the only
other accepted values, anything else fails the step loudly). Then run management-groups twice:
pass 1 with `false`, management, then pass 2 with `true`. This keeps `poc.tfvars` at its steady-state
value and lands AMBA inside B0a, at the cost of new CI code plus a review on the critical path, and a
three-dispatch sequence for two roots. Choose this only if the user wants AMBA live today.

**Do NOT choose option C** (single-pass with the flag left true and hope the module's `ResourceNotFound`
retry covers the missing identity). LESSON 58: this gate exists to convert would-be apply failures into
paper catches, and a failure here would be mid-way through a roughly 760-resource apply.

## 9. GitHub side: dispatch ref CORRECTED, everything else PASS

**The 07-12 instruction "dispatch from main" is STALE and must not be followed.** Verified against
`origin/*` refs only, after an explicit `git fetch --all --prune`:

- `origin/main` and `origin/banking` have **diverged**: each carries 5 commits the other does not.
  `main`'s five are four historical merge commits of `banking` into `main` plus one older commit whose
  content is already reflected on `banking`.
- The content difference is one-directional in substance: `origin/banking` carries work that
  `origin/main` lacks, and the diff from banking to main is **pure deletion** (roughly 1,350 lines
  removed, 33 added). `main` lacks the ADR-055 identity two-pass work, the
  `enable_conditional_access_override` wiring in `deploy.yml` and `_tf-root.yml`, the reinstated AADDS
  import wiring, the ADR-055 Part 2 explicit OIDC request export, the identity two-pass runbook, the
  identity pre-clearance, and the technical-writer agent.
- **The three B0a root directories and `envs/poc.tfvars` are byte-identical between the two refs.** So
  for B0a the choice of ref does not change what gets deployed; it changes which workflow runs.
- `banking` is the better ref regardless: it carries the ADR-055 Part 2 change that exports
  `ARM_OIDC_REQUEST_URL` and `ARM_OIDC_REQUEST_TOKEN` into `$GITHUB_ENV` for **every root**, so both
  Terraform providers re-mint a fresh GitHub id-token on each access-token acquisition. B0a applies are
  short, so this is a safety net rather than a requirement, but there is no reason to run the older
  workflow.
- OIDC will authenticate: the app registration carries a `github-banking-branch` federated credential
  with subject `ref:refs/heads/banking` (created 2026-07-16 after a `main`-only credential set caused
  AADSTS700213), plus `github-env-production`, `github-env-production-destroy`, `github-pull-request`
  and `github-main-branch`. `action=plan` runs ungated on the branch subject; `action=apply` runs in
  the `production` Environment and uses the environment subject. Both are covered.

**Decision: dispatch all three B0a runs from `banking`.** ADR-056 codifies feature to banking to main,
and `banking` is the integration branch this rebuild is being driven from.

Repo configuration:
- **Variables** (the only set `_tf-root.yml` hard-validates): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID`. All three present.
- **Secrets consumed by these three roots**: `AZURE_TENANT_ID`, the five `*_SUBSCRIPTION_ID`,
  `TERRAFORM_SP_OBJECT_ID`, `SECURITY_CONTACT_EMAIL`, `BUDGET_ALERT_EMAIL`, and (only if PC-4R option B
  is chosen) `OM_OPERATOR_NOTIFICATION_EMAIL`. All present.
- The five never-set optional Secrets (`SENTINEL_OWNER_GROUP_OBJECT_ID`, `HONEYPOT_USER_PRINCIPAL_NAME`,
  `BREAK_GLASS_GROUP_OBJECT_ID`, and the two `PIM_*_GROUP_OBJECT_ID`) resolve to empty strings with
  skip-semantics defaults, identical to every green run.
- **Environments** `production` and `production-destroy` both exist with **zero protection rules**.
  That is the OQ-015 accepted interim (required reviewers are a billing-plan feature, HTTP 422).
  Practical consequence for today: an `action=apply` dispatch runs immediately with no human gate, so
  the plan-scan of PC-5R is the ONLY thing standing between a dispatch and a write. Treat it as such.
- Hygiene, non-blocking: the `AADDS_IMPORT_REPLICA_SET_ID` Secret is no longer orphaned; ADR-055
  deliberately reinstated its `_tf-root.yml` wiring, and it is inert while unset. The 07-12 note telling
  us to delete it is **superseded, do not delete it**.
- Stale-but-not-B0a: the cross-root output Secrets (`PRIMARY_*` / `SECONDARY_HUB_*`, `PLATFORM_LAW_*`,
  `PLATFORM_ACTION_GROUP_ID`, the firewall private IPs) are consumed by B0b roots only. See check 3d for
  why `PLATFORM_LAW_CUSTOMER_ID` survives a recovery. Carry to the B0b gate.

## 10. Cost: B0a idles at roughly $30 to $50 per month, unchanged

Dominated by the Event Hub Standard namespace at 1 throughput unit (roughly $22 per month). Log
Analytics plus Sentinel ingestion on near-empty subscriptions is single-digit dollars (activity logs
only; the tenant-scoped connectors stay gated off). Defender plans bill per protected resource and the
subscriptions are empty (no servers, no App Service plans, no SQL, no storage accounts in the security
sub), so effectively zero despite Standard tiers. Management groups, policies, budgets, exports, action
group, dashboards and workbooks are free. The FinOps cost-export storage account is pennies. Budgets
recreate at their configured per-subscription and per-MG thresholds, which are alert thresholds and not
spend. With PC-4R option A the AMBA alert rules are not deployed, which if anything trims the figure.
Meter reading: roughly $1.0 to $1.7 per day.

**When B0b lands tomorrow the run rate changes by two orders of magnitude.** B0b brings up the two
Premium Azure Firewalls, the VPN gateway, Entra Domain Services and the Application Gateway. The
recorded sprint posture for B0a plus B0b plus the first banking waves was roughly **$112 to $125 per
day**. B0b alone is the dominant share of that. Plan the rebuild so the estate is not left idling
armed; the ADR-042 `enable_firewall` lever and the wave flags exist precisely for that.

---

## Ordered execution runbook for 2026-07-21

Preparation, in this exact order, before any dispatch:

**Step 0a (PC-4R, cloud-engineer then reviewer).** Land `enable_om_phase1 = false` in
`envs/poc.tfvars` on a feature branch, PR into `banking`, user merges. Confirm `origin/banking` carries
it before dispatching anything. If PC-4R option B is chosen instead, this is a devsecops change to
`deploy.yml` and `_tf-root.yml` and the runbook below gains a fourth dispatch.

**Step 0b (PC-1R, PC-2R, PC-3R, user-action).** Run the cleanup listed in the USER-ACTION section
below, in the stated order (survivors first, RP unregister last), and read back each result. These are
Azure mutations against resources that no longer have a Terraform owner; nothing else in the tenant
depends on them.

Then the three dispatches, sequential, one at a time, never in parallel (LESSON 31):

**1. `platform/management-groups`**
- Dispatch: `deploy.yml`, ref **`banking`**, `target = platform/management-groups`, `action = plan`.
- Plan-scan bar: **pure adds, 0 change, 0 destroy, 0 replace, 0 import.** Expected magnitude roughly
  **537 adds** (the 2026-07-16 `globaris` precedent, which is the same architecture PC-4R option A
  selects). STOP conditions: any destroy, any `forces replacement`, any import, any count in the 700s
  (that means the `globaris-amba` architecture was selected and PC-4R did not land), or a plan-time
  library fetch failure (that one is a plan rerun, not an estate event).
- Then dispatch the same target with `action = apply`.
- Expected tolerated noise: alz-provider `PolicyRoleAssignmentError` warnings (the OQ-021 class, roughly
  70 of them on the last run, all non-AMBA and non-fatal).

**2. `platform/management`**
- Dispatch: `deploy.yml`, ref `banking`, `target = platform/management`, `action = plan`.
- Plan-scan bar: **pure adds, 0 change, 0 destroy, 0 replace, 0 import.** Expected magnitude roughly
  **36 adds** (the 2026-07-16 precedent). STOP conditions: any destroy or replace; any add count near
  39 or above with an `rg-amba-monitoring-001` or `id-amba-prod-001` address (PC-4R did not land); any
  budget, cost export, or anomaly-alert address missing from the adds (that would mean PC-1R deleted
  something it should not have, or the plan is reading a non-empty state).
- Confirm in the plan that the platform Log Analytics workspace appears as an ADD; that create is the
  documented soft-delete recovery PUT.
- Then `action = apply`.

**3. `platform/security`**
- Dispatch: `deploy.yml`, ref `banking`, `target = platform/security`, `action = plan`.
- Plan-scan bar: **pure adds, 0 change, 0 destroy, 0 replace, 0 import.** Expected magnitude roughly
  **48 adds** (the 2026-07-16 precedent). Additional mandatory checks: **zero** pricing resources named
  `KeyVaults`, `Arm`, `Dns`, `KubernetesService` or `ContainerRegistry` (ADR-040 proof); exactly 8
  pricing adds; the Key Vault and Event Hub namespace both carrying NEW random suffixes; the
  `diag-activity-to-security-law` subscription diagnostic setting present as a clean add.
- Then `action = apply`. Pricing PUTs are already serialized code-side via `depends_on`.

**Post-B0a (not part of this gate, but do not skip):**
1. qa-engineer live-versus-intent pass per root. Apply-success is not green (LESSON 60). Note for the
   QA lane: verify the five azapi-created cost exports at their create-time API version
   `2025-03-01`, not at an older one, or they will read as absent (the 07-16 false negative).
2. Full local `bootstrap/` re-apply once the MG tree exists: rebinds the MG-scoped bootstrap rows,
   codifies the `github-banking-branch` federated credential, reconciles the known WORM policy drift,
   and lands the OQ-041 row if that decision is taken.
3. Only then revoke the two ADR-041 temporary tenant-root grants, and verify the revocation by query
   rather than assumption (LESSON 57).
4. Raise PC-6R(a) and PC-6R(b) as open questions so the next teardown does not regenerate this
   21-failure set.

If anything fails: diagnose the FULL failure set, run the PUT-time constraint sweep over every
still-uncreated resource, and issue ONE consolidated fix-spec (LESSON 59). Never spray single fixes.
Every retry must narrow the failure class. Any 403 gets the precise missing action and scope added,
never an Owner re-grant.

## Watch-items during the applies (dispositions pre-agreed)

Carried forward from 07-12 where still valid, corrected or dropped where the new evidence says so.

| Symptom | Disposition | Status |
|---|---|---|
| Stale state lease at init or plan | CI `force-unlock` (single target plus `lock_id`), then re-plan | carried forward, unchanged |
| Init 403 `AuthorizationFailure` against the state SA | Known flap class. The 3-consecutive-probe settle gate plus the bounded init retry are both on the dispatch ref. One rerun. If it recurs a second time on the same root, stop and treat it as structural | carried forward, strengthened |
| Sentinel onboarding 409 "already onboarded" | Config-driven IMPORT of the onboarding resource, then remove the import block once adopted. Never blind-retry | carried forward |
| Sentinel connector or automation rule 400 "workspace not onboarded" | Eventual consistency; exactly one rerun of the same root clears it (seen on 07-16) | carried forward |
| MDC automation 400 "Workspace resource id could not be found" on the recovered security LAW | Defender RP propagation lag against a soft-delete-recovered workspace, seen on 07-16. Wait, then one rerun. Not a code fault | carried forward |
| Defender pricing 409 "another update in progress" | Already serialized code-side; if it still fires, a single rerun (plans already in state become no-ops) | carried forward |
| Defender pricing "the pricing tier of this subscription is not Free" | **This is PC-2R not having landed.** Stop, reset that plan to Free, rerun. Do NOT import blindly | NEW |
| `azurerm_resource_provider_registration` requires-import | **This is PC-3R not having landed.** Stop, unregister, rerun | NEW |
| Any `already exists ... needs to be imported` on a budget, cost export, anomaly alert or subscription diagnostic setting | **This is PC-1R not having landed.** Stop, delete that survivor, rerun | NEW |
| MDFC DINE remediation failures on deprecated plans | Noise only, never blocks creates, ignore | carried forward |
| alz-provider `PolicyRoleAssignmentError` warnings at management-groups | Pre-existing OQ-021 class, roughly 70 of them, non-fatal. Not a stop | carried forward |
| MG or sub-placement eventual-consistency error right after MG create | Single rerun of the same root; the module sequences internally and residual races clear on retry | carried forward |
| Policy-injected `CreatedDate` tag drift on the next plan | OQ-032, formally accepted, benign, do not chase | carried forward |
| 07-12 item: "delete the orphaned `AADDS_IMPORT_REPLICA_SET_ID` Secret" | **DROPPED.** ADR-055 reinstated its wiring; the Secret is live and intentional | INVALIDATED |
| 07-12 item: "dispatch from main" | **DROPPED and REPLACED.** Dispatch from `banking` (ADR-056, and `main` lacks the ADR-055 workflow changes) | INVALIDATED |
| 07-12 item: "all Defender plans are live Free" | **INVERTED.** 8 of them are live Standard. This is PC-2R | INVALIDATED |

---

## USER-ACTION items (the only things that can block a same-day start)

Three cleanup groups plus one merge. Everything else in this gate is already satisfied or is an agent
lane. **Nothing here requires an Owner grant or any new RBAC**: the operator account already holds Owner
and User Access Administrator on these subscriptions, and the CI SP needs no new role.

Subscription IDs are already stored as repo Secrets and are visible in `az account list -o table`;
they are referenced abstractly below per the house rule.

### UA-1 (PC-1R): delete the 12 subscription-scoped teardown survivors

Run these read-only checks first to confirm the list has not changed, then the deletes. Do the four
groups in any order, but complete ALL of UA-1 before UA-3.

- **Five subscription budgets**, one in each of the five estate subscriptions, named
  `budget-sub-management-globaris`, `budget-sub-connectivity-globaris`, `budget-sub-identity-globaris`,
  `budget-sub-security-globaris`, `budget-sub-landingzones-globaris`. Portal path: Cost Management plus
  Billing, scope the subscription, Budgets. CLI shape:
  `az rest --method delete --url "https://management.azure.com/subscriptions/<sub-id>/providers/Microsoft.Consumption/budgets/<budget-name>?api-version=2023-05-01"`
- **Five cost exports**, one per subscription, named `export-daily-management-globaris`,
  `export-daily-connectivity-globaris`, `export-daily-identity-globaris`,
  `export-daily-security-globaris`, `export-daily-landingzones-globaris`. These were created at API
  version `2025-03-01` and must be deleted at that version or they will appear absent. CLI shape:
  `az rest --method delete --url "https://management.azure.com/subscriptions/<sub-id>/providers/Microsoft.CostManagement/exports/<export-name>?api-version=2025-03-01"`
- **One cost anomaly alert / scheduled action** named `anomaly-alert-management-globaris` in the
  MANAGEMENT subscription. CLI shape:
  `az rest --method delete --url "https://management.azure.com/subscriptions/<management-sub-id>/providers/Microsoft.CostManagement/scheduledActions/anomaly-alert-management-globaris?api-version=2023-11-01"`
- **One subscription diagnostic setting** named `diag-activity-to-security-law` in the SECURITY
  subscription. CLI shape:
  `az monitor diagnostic-settings subscription delete --name diag-activity-to-security-law --subscription <security-sub-id>`

Verification after: re-run the four list queries and confirm every one returns empty for the estate
names.

### UA-2 (PC-2R): reset the 8 configured Defender plans to Free in the SECURITY subscription

Plans to reset, exactly these 8 and no others: `VirtualMachines`, `StorageAccounts`, `AppServices`,
`SqlServers`, `SqlServerVirtualMachines`, `Containers`, `OpenSourceRelationalDatabases`, `CloudPosture`.

`az security pricing create -n <plan> --tier Free --subscription <security-sub-id>`

**Do not touch** `KeyVaults`, `Arm`, `Dns`, `KubernetesService`, `ContainerRegistry`, `CosmosDbs`, `Api`
(already Free, and the middle three are deprecated and must never be re-enabled), nor `AI`, `Discovery`
or `FoundationalCspm` (not managed by this estate).

Verification after:
`az rest --method get --url "https://management.azure.com/subscriptions/<security-sub-id>/providers/Microsoft.Security/pricings?api-version=2024-01-01" --query "value[].{plan:name,tier:properties.pricingTier}" -o table`
and confirm all 8 read `Free`. If any refuses, report which one before the security apply; the fallback
is a config-driven import for that single plan.

### UA-3 (PC-3R): unregister the Cost Management Exports resource provider (management sub only)

Run this AFTER UA-1, so the RP has no dependent resources.

`az provider unregister --namespace Microsoft.CostManagementExports --subscription <management-sub-id>`

Then poll until it reports unregistered:
`az provider show --namespace Microsoft.CostManagementExports --subscription <management-sub-id> --query registrationState -o tsv`

Unregistration can take a few minutes. `platform/management` re-registers it as part of its apply.

### UA-4 (PC-4R): merge the `enable_om_phase1 = false` change into `banking`

The cloud-engineer raises the one-line `envs/poc.tfvars` change on a feature branch, the reviewer
approves, and the user merges the PR into `banking`. Confirm `origin/banking` carries it before the
first dispatch. This is the only code change B0a needs.

### Not required, explicitly

- **No RBAC grants.** The 07-12 PC-2 and PC-3 tenant-root grants are still live. Do not re-create them
  and do not revoke them yet.
- **No Owner grant, ever.**
- **No `budget_start_date` change.** The current value is valid for a July apply.
- **No manual state storage account firewall change.** All three B0a runs are single-target, so
  `manage_runner_ip` handles the JIT window and restores Deny on exit. (This differs from teardown,
  which does need a manual open. Do not confuse the two.)

---

### Proposed commit message for this addendum

```
docs(preclearance): B0a redeploy refresh addendum for the 2026-07-21 rebuild (PC-1R..PC-6R)

Refreshes docs/preclearance/b0a-redeploy.md against live tenant state after the
2026-07-20 teardown. Verdict GO-conditional, 6 conditions, 3 user-action.

Material inversions vs the 2026-07-12 record:
- teardown left 12 subscription-scoped objects live (5 budgets, 5 cost exports,
  1 anomaly scheduled action, 1 subscription diagnostic setting); all 4 provider
  types carry create-time requires-import guards, source-verified at azurerm 4.71.0
- Defender pricing survived armed: 8 configured plans live Standard, and the
  pricing resource hard-fails create when the live tier is not Free
- Microsoft.CostManagementExports left Registered, requires-import on create
- 21 deterministic apply failures total, all invisible to validate and plan
- ADR-041 tenant-root grants (07-12 PC-2/PC-3) verified still live, no re-grant needed
- dispatch ref corrected from main to banking (ADR-056; main lacks the ADR-055 wiring)
- new wave-B7 greenfield circularity on enable_om_phase1, resolved by gating it off
  for the B0a pass
```

