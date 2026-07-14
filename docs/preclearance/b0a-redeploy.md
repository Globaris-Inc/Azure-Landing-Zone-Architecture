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
