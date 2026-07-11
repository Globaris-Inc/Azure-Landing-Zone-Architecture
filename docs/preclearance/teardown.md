# Teardown Pre-Clearance Runbook (full estate `terraform destroy`)

> **Owner:** architect (pre-clearance gate, per the mandatory pre-clearance-before-any-apply rule, applied
> here to the destroy path).
> **Scope of this doc:** sanity-check `teardown.yml` against the CURRENT live state, nail the RBAC and
> directory-role revocation timing, and issue a go / no-go plus an execution runbook. **Docs only. No
> Terraform, no workflow edits.**
> **Last updated:** 2026-07-11

**One-line verdict: GO, conditional on ONE mandatory pre-destroy step** (state-SA reachability for the
teardown runner, item PD-1). All revocations happen strictly AFTER a fully-successful destroy.

---

## 0. Live-state inputs this pre-clearance is built on

- All 9 backend-state roots are deployed and QA-stamped EXCEPT `synthetic`, which was never applied
  (its `terraform destroy` is a **no-op**: nothing in state, `enable_synthetic_workload = false`).
- The identity stuck state lock was cleared (CI `force-unlock`, run 29141732832); a fresh identity plan
  re-acquired the lock cleanly. Re-verify no new lock exists immediately before dispatch.
- The CI SP currently holds, on top of its ADR-021 scoped role matrix:
  - **3 STANDING Owner role assignments** at the **globaris**, **platform**, and **connectivity** MG
    scopes (the OQ-008 standing grants).
  - **2 TEMPORARY Entra directory roles**: **Application Administrator** and **Groups Administrator**
    (added to build the Entra DS managed domain; ADR-028 / ADR-029 follow-up).
- Teardown default is `include_bootstrap = false`: destroy the 9 roots + their RGs, **keep** the state SA
  + CMK KV + OIDC app/SP/federation for immediate redeploy.

---

## 1. Destroy order - confirmed dependency-correct

`teardown.yml` inverts the `deploy.yml` `needs:` graph. Verified job-by-job against the workflow:

```
guard (typed confirm=destroy)
  -> synthetic                         (needs guard)            [no-op, never applied]
  -> corp-a1, corp-a2, online-p1       (needs synthetic)        [3 spokes, parallel]
  -> connectivity                      (needs the 3 spokes)
  -> security                          (needs the 3 spokes)
  -> identity                          (needs guard only; runs in parallel with the chain above)
  -> management                        (needs connectivity + security)
  -> management-groups                 (needs management + identity)   <-- LAST
  -> teardown-bootstrap                (needs management-groups; only if include_bootstrap=true)
```

**Ordering claims checked:**

- **`management-groups` is destroyed LAST - CONFIRMED.** Its `needs: [guard, management, identity]`, and
  `management` transitively depends on `connectivity` + `security` (which depend on the spokes). So every
  resource root and both privileged sub-roots finish before the MG hierarchy + the `avm-ptn-alz` MG-scoped
  policy/role assignments come down. Correct: MG-scoped Deny/Modify/DINE assignments and role assignments
  must be removed after the resources they govern, and the MG hierarchy can only be deleted once its child
  policy/role objects and subscription placements are gone.
- **Entra DS is removed before the MG/identity-sub scaffolding it sits in - CONFIRMED.** `identity` (which
  owns the Entra DS managed domain, its VNet/NSG/RSV, and the ADR-028 RG-scoped policy exemption) completes
  before `management-groups` runs, because `management-groups needs identity`. So the managed domain and the
  exemption are gone before the MG hierarchy and the Deny-Public-IP assignment (at the identity MG, held in
  `management-groups` state) are torn down. If the order were reversed, the exemption would outlive the
  assignment it references and the MG delete would race the sub placement.
- **`identity` runs in parallel with the connectivity/security/management chain - fine.** Different
  subscriptions, no cross-root Terraform dependency. The only join point is `management-groups`, which waits
  for identity. The long Entra DS delete (item 2.a) therefore overlaps the other roots rather than serializing
  behind them.

**Ordering risk flags:** none in the graph itself. The residual risks are per-root Azure-side (Section 2),
not sequencing. One note for a **single-root** teardown: destroying `platform/connectivity` or
`platform/security` alone while the spokes still exist is safe for delete (Deny policies gate create/update,
not delete), but do not single-root-destroy `management-groups` while any sub still carries MG-scoped
assignments in another root's state - use `target=all` for the hierarchy.

---

## 2. Per-root destroy risk sweep (against current live state)

Mechanism is uniform `terraform destroy` (ADR-020); this estate has **no VMs**, so the LESSON-19
stuck-destroy failure mode does not apply. Risks below are Azure-ordering / permission / eventual-consistency,
not Terraform-graph.

### 2.a `platform/identity` - HIGH attention (longest, needs the temp directory roles)
- **Entra DS managed-domain delete is long (15-30+ min, can exceed that).** ARM tears down both DCs, the
  internal load balancer, and the service-managed networking. Expect the job to sit in delete-poll for a long
  window. Not a failure - just slow. Do not cancel.
- **Directory rights are required during this delete.** Deleting the managed domain also unwinds the
  directory objects AADDS created (its service principal / managed groups). The **2 temp directory roles
  (Application Administrator + Groups Administrator) MUST still be attached to the CI SP while `identity`
  destroys.** This is the load-bearing reason all directory-role revocation happens AFTER a successful
  destroy, never before (Section 3).
- **RSV (Recovery Services Vault) soft-delete gotcha.** `platform/identity/domain-services.tf` deploys an
  `avm-res-recoveryservices-vault` with `soft_delete_enabled = true`, `immutability = "Unlocked"`. If the
  vault has **any protected backup item**, `terraform destroy` fails on the vault delete
  ("vault cannot be deleted as there are existing resources within the vault"). This RSV is a scaffold with
  no VM/file-share workloads, so it should have **zero** protected items and destroy clean. Watch-item: if it
  wedges, disable soft-delete and delete/undelete-then-delete any backup items via
  `az backup ...` / `az resource`, then re-run the `identity` destroy. Immutability is `Unlocked`, so nothing
  is delete-locked.
- **Steady state is clean** (post-untaint + `FullySynced` pin + DNS-in-IaC, ADR-029 addendum), so the plan
  side of destroy is a straight delete graph, no ForceNew surprises.

### 2.b `platform/security` - MEDIUM (Defender-to-Free, KV purge protection)
- **Disabling deprecated Defender plans is NOT blocked the way enabling them was.** The July 5 2026 block
  (OQ-028 / ADR-034) applies to **new Standard enablement** of the deprecated plans (KeyVaults, Arm, Dns).
  `terraform destroy` removes the `azurerm_security_center_subscription_pricing` resources, which reverts each
  plan to **Free** - a downgrade, not a new enablement, so it is not caught by the retirement block. **Watch-item:**
  if the provider issues a Free PUT that references a deprecated plan name and ARM rejects it, the fallback is
  `az security pricing create --name <KeyVaults|Arm> --tier Free --subscription <security-sub>`, or
  `terraform state rm` that pricing resource (the subscription survives teardown under
  `include_bootstrap=false`, so a left-Standard plan would keep billing - so **verify Free post-destroy**,
  item V-5).
- **Sentinel de-onboarding is clean.** Sentinel onboarding + analytics rules + watchlists + the
  regulatory-compliance (NIST/CIS) policy-set assignments are all Terraform-managed ARM/policy objects;
  destroy removes them in-graph. Removing the MG/sub-scoped policy-set assignments needs Resource Policy
  Contributor (SP has it) and UAA for their remediation-identity role assignments (SP has it).
- **`mdc_export` automation** (`azurerm_security_center_automation`, type `Workspace` per ADR-033) deletes
  cleanly.
- **Key Vault purge protection - redeploy consideration, not a destroy blocker.** The security KV has
  `soft_delete_retention_days = 90` and **`purge_protection_enabled = true`** (`platform/security/main.tf:116`).
  `terraform destroy` soft-deletes the vault; purge protection means it **cannot be purged for 90 days**. A
  redeploy of `platform/security` within that window recreates the same-named vault and will 409 unless the
  provider recovers the soft-deleted vault (`features { key_vault { recover_soft_deleted_key_vaults = true } }`).
  Flag for the redeploy path (item V-8), not for destroy.

### 2.c `platform/connectivity` - MEDIUM (long, no ordering blocker expected)
- **Long destroy: 2 Premium Azure Firewalls, active-active VPN Gateway, hub-to-hub Global VNet Peering, 89
  private DNS zones + VNet links, DNS Private Resolver.** VPN Gateway and Firewall deletes are individually
  slow (~15-30 min each); the whole root is the second-longest after identity. Not a failure - budget the time.
- **Peering / lock ordering:** the hub-to-hub Global VNet Peering resources are both Terraform-managed;
  destroy removes both sides in-graph. Removing the peerings does not depend on external state because the
  spokes (and their spoke-to-hub peerings) are already gone by this point (spokes destroy before connectivity).
- **Private DNS zone delete residual-link risk is LOW here.** A private DNS zone delete 409s if it still has
  VNet links or record sets created out-of-band (by a DINE policy or a private endpoint). The §12 validation
  found **zero private endpoints estate-wide** (the PE-bearing workloads are gated off, ADR-031/032), so there
  are no PE-created A-records/links to strand the zones. Terraform deletes the links it owns before the zones.
  Watch-item only: if a zone delete 409s on a residual link, remove the stray link
  (`az network private-dns link vnet delete`) and re-run.

### 2.d `platform/management` - LOW
- Budgets, the `azapi` cost-management exports (ADR-027, `Microsoft.CostManagement/exports`, system-assigned
  identity), the LAW / automation account / action group, the anomaly alert, and the **tag-governance Modify
  policy assignment** + its remediation-identity **role assignment** (Contributor @ globaris MG) all delete
  in-graph. Policy-assignment delete needs Resource Policy Contributor (SP has it @ globaris); the role
  assignment delete needs UAA (SP has it @ globaris).
- Benign note: destroying the tag-governance Modify assignment does not roll back the `CreatedDate=1970-01-01`
  tags it injected (OQ-032), but the tagged resources are being destroyed in the same teardown, so it is moot.

### 2.e `platform/management-groups` - MEDIUM (needs Owner@MG; must be LAST)
- Destroys the `avm-ptn-alz` MG hierarchy, the MG-scoped policy/policy-set assignments (Deny-Public-IP @
  identity MG, DDoS @ connectivity/landingzones MG, FinOps tag initiative @ globaris, MCSB/NIST/CIS @ root
  MG), the associated role assignments, and the subscription placements.
- **Permission:** deleting the MG tree needs `Microsoft.Management/managementGroups/*` at the parent (Tenant
  Root Group) - ADR-021 row 1 (Management Group Contributor @ Tenant Root) - plus the **standing Owner @
  globaris / platform / connectivity** currently attached covers the MG-scoped policy/role deletes and sub
  moves belt-and-suspenders. Keep those standing grants attached through this destroy (Section 3).
- **Order dependency:** MG delete requires each MG to be emptied first - subscription placements removed
  (subs move back toward Tenant Root) and MG-scoped assignments deleted. Terraform's `avm-ptn-alz` graph
  sequences this within the root. Because this root is last, all sub-level resources are already gone, so the
  MG-scoped Deny assignments have nothing left to guard when they are removed.

### 2.f State-SA firewall during teardown - see PD-1 (this is the one real pre-destroy gap)
The `_tf-root.yml` `manage_runner_ip` JIT firewall flip is **NOT** wired into `teardown.yml` (Section 5,
PD-1). This is the single environmental item that can stop every teardown job at `terraform init`.

---

## 3. The revocation sequence (the critical correctness point)

### 3.0 Confirm: the SP needs BOTH grant sets to PERFORM the destroy
- **Standing Owner @ globaris / platform / connectivity MGs** - needed for MG-scoped object deletion:
  removing MG policy/role assignments, moving subscriptions, and deleting the MG hierarchy in
  `management-groups` (and the MG-scoped policy/exemption deletes in `management`, `security`, `identity`).
- **Temp directory roles (Application Administrator + Groups Administrator)** - needed for the Entra DS
  managed-domain delete in `identity` (unwinding the AADDS-created directory SP / groups).

Therefore **ALL revocations happen strictly AFTER a fully-successful `target=all` destroy. Never before.**
Revoking early would 403 the very deletes still in flight and orphan MG or directory objects.

### 3.1 Exactly what to revoke (5 items)
1. Owner role assignment on the CI SP at the **globaris** MG scope.
2. Owner role assignment on the CI SP at the **platform** MG scope.
3. Owner role assignment on the CI SP at the **connectivity** MG scope.
4. **Application Administrator** directory-role membership of the CI SP.
5. **Groups Administrator** directory-role membership of the CI SP.

### 3.2 Mechanism and who runs each (USER-MANUAL vs automatable)

| # | What | Mechanism | Runs it | Manual? |
|---|------|-----------|---------|---------|
| 1-3 | Owner @ globaris / platform / connectivity MG | `az role assignment delete --assignee <CI-SP-object-id> --role Owner --scope <MG-resource-id>` (once per MG scope) | A human admin with **Owner or User Access Administrator** at that MG scope (e.g. the user) | **USER-MANUAL (recommended).** Technically the SP itself holds UAA @ globaris (inherits to platform/connectivity) so it *could* self-delete, but self-revocation from CI is risky (a mid-way failure can strand the SP), out of the teardown workflow's scope, and better done deliberately by a human. |
| 4-5 | Application Administrator + Groups Administrator directory roles | Entra portal **Roles and administrators -> `<role>` -> Remove assignment** for the CI SP; or Graph `DELETE /directoryRoles/{roleTemplateId}/members/{sp-id}/$ref`; or `Remove-MgDirectoryRoleMemberByRef` | A human with **Privileged Role Administrator or Global Administrator** | **USER-MANUAL (mandatory).** The SP holds only App Admin + Groups Admin, neither of which can manage directory-role memberships, so **the SP cannot self-revoke these.** |

**Project-rule note (hard-to-find IDs go to the user):** the CI SP object ID and the three MG resource IDs
(`/providers/Microsoft.Management/managementGroups/<globaris|platform|connectivity>`) are hand-off values -
the user supplies them from the portal / az rather than the runbook hard-coding real IDs. `az role assignment
list --assignee <CI-SP-object-id> --all -o table` enumerates all 3 Owner scopes in one shot to confirm before
deleting.

### 3.3 If `include_bootstrap = true` is chosen instead (full decommission)
Do these only AFTER the 9-root destroy AND after the `teardown-bootstrap` job has emitted its runbook. All are
USER-MANUAL:
1. **Delete the state backend RG** (state SA + CMK KV): find the exact name first (LESSON 18 non-deterministic
   suffix), then delete. `az group list --subscription <management-sub> --query "[?starts_with(name,'rg-tfstate')].name" -o tsv`
   then `az group delete --name <rg-tfstate-mgmt-XXXXXX> --subscription <management-sub> --yes`. Note the CMK
   Key Vault soft-deletes (recover/purge separately if the name must be reused).
2. **Delete the OIDC app registration:** `az ad app delete --id <oidc-client-id>`. The SP **cannot** delete its
   own app registration (needs directory/Graph rights, and it would kill the auth it is running under), so this
   is a privileged-user step done last.
3. Ordering: bootstrap teardown is strictly **after** `management-groups` (the workflow enforces this via
   `teardown-bootstrap needs: management-groups`). After this, redeploy requires a manual re-bootstrap plus
   re-setting the 3 GitHub Variables and a fresh `poc.backend.hcl` (LESSON 18).

**Recommendation:** keep `include_bootstrap = false` for this run unless the intent is permanent
decommission. False keeps redeploy immediate and avoids the manual app/backend deletion + re-bootstrap.

---

## 4. Post-destroy verification checklist

Run after the `target=all` run reports success (and before any revocation, so the SP can still read).

| # | Check | Command / where | Pass condition |
|---|-------|-----------------|----------------|
| V-1 | Estate RGs gone in all 5 subs | `az group list --subscription <each> -o table` | No estate `rg-*` remain (only `rg-tfstate-mgmt-*` in the management sub survives on `include_bootstrap=false`) |
| V-2 | MG hierarchy gone | `az account management-group list -o table` | No globaris tree; the 5 subs sit back under Tenant Root |
| V-3 | MG-scoped policy + role assignments gone | `az policy assignment list --scope <each MG>`; `az role assignment list --scope <each MG> -o table` | Empty of estate assignments |
| V-4 | No lingering resources per sub | `az resource list --subscription <each> -o table` | Empty of estate resources |
| V-5 | Defender pricing back to Free | `az security pricing list --subscription <security-sub> -o table` | All plans **Free** (explicitly confirm KeyVaults + Arm did not stick on Standard - Section 2.b) |
| V-6 | Entra DS gone | `az ad ds list -o table` / portal Domain Services blade | No managed domain; AADDS104 alert cleared |
| V-7 | RSV left no soft-deleted backup items | portal RSV backup items / `az backup` | None stranded (Section 2.a) |
| V-8 | Security KV soft-delete state (redeploy note) | `az keyvault list-deleted --subscription <security-sub> -o table` | KV appears soft-deleted; note it CANNOT be purged for 90 days (purge protection). Redeploy needs `recover_soft_deleted_key_vaults` (Section 2.b) |
| V-9 | Cost accrual stops | Cost Management / confirm firewalls, VPN GW, App Gateway, LAWs gone | The big-ticket compute/gateway/firewall items absent; budgets + exports gone |
| V-10 | State backend survived (`include_bootstrap=false`) | `az group show -n <rg-tfstate-mgmt-XXXXXX> --subscription <management-sub>`; `az storage account show ...` | Present and reachable |
| V-11 | OIDC survived (`include_bootstrap=false`) | `az ad app show --id <oidc-client-id>`; GitHub Variables `AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID` intact | App + federation + 3 Variables present |
| V-12 | Redeploy path proven | dispatch `deploy.yml` `target=platform/management-groups action=plan` | Plan runs (backend init + OIDC login succeed), proving the kept backend + OIDC still work |

---

## 5. Go / No-Go and mandatory pre-destroy steps

### Verdict: **GO**, conditional on PD-1 being resolved first.

The design is sound, the reverse order is dependency-correct, uniform `terraform destroy` is right for this
no-VM PaaS/control-plane estate, the state lock is cleared, and the grants the destroy needs are still
attached. One environmental gap must be closed before dispatch, and two facts must be confirmed.

### PD-1 (MANDATORY) - state-SA reachability for the teardown runner
**Finding / correction of a premise:** the `manage_runner_ip` JIT state-SA firewall flip is **NOT** wired
into `teardown.yml`. `deploy.yml` sets `manage_runner_ip: ${{ inputs.target != 'all' }}` on every root job;
`teardown.yml` passes **no** `manage_runner_ip`, so it is always `false`. (This is correct by design - on
`target=all` the flip races across parallel jobs sharing one state SA - but it means teardown does not open
the firewall for you.) Therefore every teardown job reaches the firewalled state SA
(`default_action = Deny`) **only** if the runner egress path is already in the bootstrap static
`ip_allow_list`; otherwise `terraform init` 403s and every root fails.

**Resolve before dispatch (pick one):**
- **(a) Recommended for `target=all`:** manually open the state SA for the teardown window -
  `az storage account update --name <state-sa> --resource-group <rg-tfstate-mgmt-XXXXXX> --default-action Allow`
  before dispatch, and restore `--default-action Deny` after the run completes. Data stays protected by
  Entra-only auth + Blob RBAC + TLS + CMK during the window (the ADR-025 trade-off, applied manually here).
- **(b)** Confirm the intended runner's egress IP/CIDR is already in bootstrap `var.ip_allow_list` and leave
  the SA `Deny` (only reliable for a self-hosted / fixed-egress runner - hosted-runner IPs churn).

Do **not** rely on `manage_runner_ip` inside teardown - it is not there.

### PD-2 (CONFIRM, do not change) - grants still attached
Before dispatch, confirm the CI SP **still** holds the 3 standing Owner @ MG grants and the 2 temp directory
roles. The destroy needs them (Section 3.0). Do not revoke anything yet.

### PD-3 (CONFIRM) - no stuck state lock
Re-confirm no orphaned state lease exists on any root (the identity lock was cleared; a stray lock would hang
`init`/destroy). A quick `deploy.yml target=<root> action=plan` on a suspect root, or checking the lock blob,
suffices. Use the CI `force-unlock` path if one reappears.

### Sequence to drive the run
1. PD-1 / PD-2 / PD-3 above.
2. Dispatch `teardown.yml`: `target = all`, `confirm = destroy`, `include_bootstrap = false`.
   (Approve the `production-destroy` environment gate if/when reviewer protection is live; it is currently
   ungated per OQ-015.)
3. Let it run to full success - expect identity (Entra DS) and connectivity (firewalls / VPN GW) to be long.
   `synthetic` is a no-op.
4. Run the Section 4 verification checklist (V-1..V-12).
5. **Only after a clean verification:** perform the Section 3 revocations - items 1-3 (Owner @ MG, user as
   UAA/Owner admin) and items 4-5 (directory roles, user as Privileged Role Administrator / Global Admin).
6. If PD-1 option (a) was used, restore the state SA `default_action = Deny`.

---

## 6. What I need from you to drive the run
- The CI SP **object ID** and the 3 MG resource IDs (globaris / platform / connectivity) for the Section 3
  revocation commands - hard-to-find IDs, hand them from the portal / az per the project rule.
- The state SA name + its `rg-tfstate-mgmt-*` RG name (for PD-1 option (a) and V-10).
- Confirmation of `include_bootstrap` intent (default recommended `false`).

---

## Hand-off
This is a pre-clearance / runbook (architect lane, docs only). Execution is operator-driven:
- **PD-1 state-SA firewall handling** and the `teardown.yml` dispatch are the **DevSecOps / operator** lane.
- The **Section 3 revocations are USER-MANUAL** (items 4-5 mandatorily so - the SP cannot self-revoke
  directory roles; items 1-3 recommended user-manual).
- If the durable fix "wire `manage_runner_ip` into a single-root teardown path, or pre-open the SA for
  `target=all`" is wanted as a workflow change rather than a manual pre-step, that is a **DevSecOps** task
  (new ADR / OQ), not required for this teardown.
