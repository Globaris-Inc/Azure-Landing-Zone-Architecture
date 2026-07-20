# platform/identity - ADR-055 greenfield two-pass dispatch runbook

> **Owner:** devsecops. **Audience:** the operator dispatching Wednesday's production rebuild.
> **Status:** operationalizes the architect's GO-CONDITIONAL pre-clearance
> (`docs/preclearance/platform-identity.md`, PC-1G through PC-8G, dated 2026-07-20) into an
> executable procedure. This is a dispatch/operations doc - it does not change the deploy
> intent, only how to invoke it correctly.
> **Governing decisions:** ADR-055 (the two-pass fix), ADR-029 (NSG fix + import/untaint
> recovery), ADR-028 (Deny-Public-IP RG-scoped Waiver), ADR-030 (geo_block re-enabled by
> default). **Resolves:** the operational half of OQ-022.
> **Prerequisite reading:** `DEPLOYMENT.md` Step 4 (ordering summary), `docs/preclearance/
> platform-identity.md` (the GO-CONDITIONAL bars this runbook operationalizes),
> `docs/cicd-deploy-teardown.md` (general pipeline mechanics - JIT state-SA firewall,
> gating, force-unlock).

---

## 0. IMPORTANT - a code-verified correction to the pre-clearance CA-policy count

Before dispatching, know this: `docs/preclearance/platform-identity.md` (A6/A7, PC-5G) and the
pre-existing text in `DEPLOYMENT.md` Step 4 both describe Pass 2 as "9 pure adds, geo_block
ABSENT (7 of 8 CA policies)". That describes the state of the root **before** commit `efde82f`
(`fix(identity): geo_block references named-location object_id not .id, re-enable CA-005 -
OQ-023/ADR-030`). Verified live against the code on this branch, 2026-07-20:

- `platform/identity/variables.tf` - `enable_geo_block_ca_policy` **defaults to `true`**
  (ADR-030 resolved: the Graph 1040 root cause was a wrong attribute reference, fixed by
  switching to `.object_id`; the flag was re-enabled, not left off).
- `envs/poc.tfvars` does **not** override `enable_geo_block_ca_policy` - so the live default
  (`true`) applies. `geo_block` (CA-005) creates in Pass 2 along with the other seven.
- `platform/identity/main.tf` declares exactly 8 `azuread_conditional_access_policy` resources
  (CA-001..CA-008) plus `azuread_named_location.approved_countries` plus
  `time_sleep.wait_named_location`, ALL gated on the same `enable_conditional_access` umbrella.

**Corrected Pass 2 plan-scan bar (supersedes the "9 pure adds / geo_block absent" text
wherever it appears until the architect updates those docs):**

| Resource address | Type |
|---|---|
| `azuread_named_location.approved_countries[0]` | azuread (Graph) |
| `time_sleep.wait_named_location[0]` | time (non-Graph wait) |
| `azuread_conditional_access_policy.require_mfa_admins[0]` (CA-001) | azuread (Graph) |
| `azuread_conditional_access_policy.block_legacy_auth[0]` (CA-002) | azuread (Graph) |
| `azuread_conditional_access_policy.require_compliant_device_portal[0]` (CA-003) | azuread (Graph) |
| `azuread_conditional_access_policy.phishing_resistant_mfa_pim[0]` (CA-004) | azuread (Graph) |
| `azuread_conditional_access_policy.geo_block[0]` (CA-005) | azuread (Graph) |
| `azuread_conditional_access_policy.signin_frequency_admins[0]` (CA-006) | azuread (Graph) |
| `azuread_conditional_access_policy.block_high_user_risk[0]` (CA-007) | azuread (Graph) |
| `azuread_conditional_access_policy.mfa_signin_risk[0]` (CA-008) | azuread (Graph) |

**Ten total plan addresses, all pure adds (count 0 -> 1). Nine of the ten are azuread
(Graph-write) resources - named location + all 8 CA policies, matching ADR-055's own "all
eight are gated" language in DECISIONS.md. `geo_block` PRESENT is the correct expected shape,
not a STOP condition.** Flagged for the architect to reconcile in `docs/preclearance/
platform-identity.md` and the older `DEPLOYMENT.md` validate line - not edited here since that
pre-clearance file is architect-owned; this runbook uses the verified-correct count.

---

## 1. The actual override mechanism (verify-before-write finding)

The pre-clearance and the original `DEPLOYMENT.md` text described the Pass 1 flag flip as "a
tfvars override at dispatch time." That mechanism **did not exist** in the workflow before this
session: `_tf-root.yml` only ever ran `terraform plan|apply -var-file=envs/poc.tfvars`, with no
`-var` override capability, and `enable_conditional_access` has no entry in `envs/poc.tfvars`
(so the live value was always the code default `true`, un-overridable per-run).

**Fixed as minor, scoped CI wiring (this session, `.github/workflows/deploy.yml` +
`_tf-root.yml`):** a new `workflow_dispatch` input `enable_conditional_access_override`
(choice: `""` / `"false"` / `"true"`), threaded ONLY into the `identity` job's call to
`_tf-root.yml` (every other root ignores it - a new guard job,
`guard-enable-conditional-access-target`, rejects dispatching it against any other single
target). `_tf-root.yml` exports `TF_VAR_enable_conditional_access` via `$GITHUB_ENV` only when
the value is non-blank (mirrors the existing ADR-055 Part 2 OIDC-export pattern); blank means
no `TF_VAR_enable_conditional_access` is ever set, so Terraform falls through to the variable's
own default (`true`) - byte-identical to every apply before this input existed. This is now
the real, verified dispatch mechanism used throughout this runbook.

---

## 2. Placement in the Wednesday order

Per `DEPLOYMENT.md` §2 (deploy order) and §3 Step 4: `platform/identity` is parallelizable with
Steps 2/3/5, but two things must be LIVE first:

- **Step 1 `platform/management-groups`** applied, with the identity-MG `Deny-Public-IP`
  assignment present. The in-root ADR-028 exemption
  (`azurerm_resource_group_policy_exemption.aadds_deny_public_ip`) references it by a LITERAL
  policy-assignment ID; if that assignment does not exist yet, the exemption PUT 404s and Pass
  1 fails before it ever reaches the AADDS create.
- **`Enable-DDoS-VNET` = `DoNotEnforce`** at the relevant MG (ADR-026), confirmed live -
  otherwise the identity VNet create 403s before anything else runs.
- **Step 3 `platform/connectivity` Secrets present**: `PRIMARY_HUB_VNET_ID`,
  `PRIMARY_HUB_VNET_NAME`, `PRIMARY_HUB_RG_NAME`, `PRIMARY_FIREWALL_PRIVATE_IP` - the identity
  VNet peers to the primary hub in the same Pass-1 apply. Missing Secrets fail the peering
  resource, not the whole apply cleanly, so confirm they are pasted in before dispatching.

Do not dispatch `platform/identity` before both are true. `target = all` handles this ordering
automatically via the `needs:` graph; a manual single-target dispatch does not - verify by hand.

---

## 3. Pre-dispatch checklist (every PC bar, one concrete action each)

| PC bar | Concrete pre-flight action |
|---|---|
| **PC-1G** (Pass 1 gate proof) | No action pre-dispatch; this is the Pass-1 plan-scan gate, §5 below. |
| **PC-2G** (ordering) | Confirm Step 1 applied and the identity-MG `Deny-Public-IP` assignment exists (`az policy assignment show` at the identity MG scope, or the Step-1 apply log). Confirm `Enable-DDoS-VNET` = `DoNotEnforce`. Confirm the four `PRIMARY_HUB_*` repo Secrets are set from Step 3's `terraform output`. |
| **PC-3G** (tenant prereqs) | **Before Pass 1:** confirm the "Domain Controller Services" publisher SP and "AAD DC Administrators" group exist with the CI SP a member (`platform/identity/README.md` §"Manual operator prerequisite" - `az ad sp show --id 2565bd9d-da50-47d4-8b85-4c97f669dc36`, `az ad group show --group "AAD DC Administrators"`). **Before Pass 2:** confirm the three Graph app roles (`Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`, `Application.Read.All`) are admin-consented on the CI SP. **Entra ID P2: operator-confirmed ACTIVE 2026-07-20 - this sub-condition is already satisfied, no further action.** |
| **PC-4G** (recovery armed but inert) | Confirm the `AADDS_IMPORT_REPLICA_SET_ID` repo Secret is **UNSET** (blank) before the FIRST Pass-1 dispatch (`gh secret list` - it should not appear, or should resolve empty). Leaving it unset makes the `import {}` block's `for_each` an empty set - zero import operations, a normal create. |
| **PC-5G** (plan-scan bars) | No pre-action; enforced at each plan review, §5 and §7 below (using the corrected §0 count for Pass 2). |
| **PC-6G** (live-proof) | No pre-action; this is the live-monitoring procedure, §8 below. |
| **PC-7G** (greenfield-only override) | Confirm this is in fact the greenfield rebuild (estate torn down, ADR-054) before ever setting `enable_conditional_access_override=false`. **Never** dispatch `false` against an estate that already carries the CA policies in state - see the STOP matrix §9. |
| **PC-8G** (post-apply) | No pre-action; post-apply checklist, §10 below. |

**Repo Secrets/Variables needed for `platform/identity` specifically** (from `DEPLOYMENT.md`
§1.3, cross-checked against `_tf-root.yml`'s `env:` block): `IDENTITY_SUBSCRIPTION_ID`,
`AZURE_TENANT_ID`, `BREAK_GLASS_GROUP_OBJECT_ID` (optional - empty means CA policies create
with no break-glass exclusion, not a blocker), `PIM_PRIVILEGED_GROUP_OBJECT_ID` /
`PIM_APPROVER_GROUP_OBJECT_ID` (optional - PIM eligible assignments are `azurerm`/ARM-plane,
NOT Graph, so they are ungated and run in Pass 1; leaving these unset just skips PIM, not a
blocker), the four `PRIMARY_HUB_*` Secrets from Step 3 (required for peering), and
`AADDS_IMPORT_REPLICA_SET_ID` (leave unset - PC-4G). The ADR-055 Part 2 OIDC export
(`ARM_OIDC_REQUEST_URL` / `ARM_OIDC_REQUEST_TOKEN`) needs no Secret - it is derived at runtime
from `permissions: id-token: write`, already wired in `_tf-root.yml`.

---

## 4. Pass 1 dispatch

**Workflow:** `Deploy (manual)` (`.github/workflows/deploy.yml`).

**Step A - plan (ungated):**

| Input | Value |
|---|---|
| `target` | `platform/identity` |
| `action` | `plan` |
| `enable_conditional_access_override` | `false` |
| `resource_address` | (blank) |
| `lock_id` | (blank) |

Review the plan output in the Actions job log (there is no saved plan artifact in this
workflow - the log IS the record).

**PC-1G plan-scan gate (STOP if violated):**
- **Zero `azuread_*` resource addresses anywhere in the plan.** Any `azuread_named_location` or
  `azuread_conditional_access_policy` address appearing means the umbrella gate did not take -
  STOP, do not apply, escalate to the architect/cloud-engineer.
- **Zero destroy, zero replace.** Every address is a `+ create` (this is a from-empty-state
  greenfield root).
- Expect creates covering: the identity resource group(s), the identity VNet + subnet(s) +
  `entra_ds` NSG (peered to the primary hub), `azurerm_resource_provider_registration.aad`,
  `azurerm_resource_group_policy_exemption.aadds_deny_public_ip` +
  `time_sleep.wait_aadds_policy_exemption` (the ADR-028 exemption pair - note this is a
  DIFFERENT `time_sleep` from the Pass-2 one, and it belongs in Pass 1),
  `azurerm_active_directory_domain_service.this[0]` (a `+ create`, not an import - the import
  path is only used for recovery, §6), the identity Recovery Services Vault module, and (if the
  PIM group Secrets are set) the PIM eligible role assignments - all `azurerm`, none `azuread`.

**Step B - apply (gated by the `production` GitHub Environment):**

Same inputs as Step A but `action = apply`. Approve the `production` environment gate when
prompted. `manage_runner_ip` is automatically `true` for this single-target dispatch (the
workflow computes it from `target != 'all'`), so the firewalled state SA opens for the job
window and restores to `Deny` on exit - including on a timeout or failure (§9).

**Expected duration:** dominated by the AADDS create-wait, 1-3 hours (the managed domain must
report both DCs `Running` before the resource returns). This is the long pole ADR-055 makes
azurerm-only and therefore token-safe - no `azuread` Graph write runs at the tail of this pass.

**Success looks like:** the job completes green, the domain shows
`provisioningState: Succeeded` with two DC IPs in the Azure portal / `az resource show`, and NO
`AADSTS700024` appears anywhere in the log.

**Create-wait timeout looks like:** the job fails on the `azurerm_active_directory_domain_
service` resource specifically (not on auth) after its create-wait budget, typically because
the second DC never became reachable (AADDS104-class). Go to §6 (recovery). This is NOT
automatically a STOP - it is the documented, expected failure mode this runbook has a recovery
path for.

---

## 5. (folded into §4 above - PC-1G is the Pass 1 plan-scan gate)

---

## 6. Pass 1 recovery (AADDS create-wait timeout, PC-4G)

Two documented paths, chosen by where the domain landed:

### 6a. Domain TAINTED in state (the empirically-proven path, run `29068343843`)

If the create timed out but Terraform DID record a resource instance (tainted, not absent):

1. Dispatch `action = untaint`, `target = platform/identity`,
   `resource_address = azurerm_active_directory_domain_service.this[0]`,
   `enable_conditional_access_override = false` (harmless either way for this action - untaint
   does not read Terraform variables - but keep it consistent to avoid confusion in the run
   history). This is a pure state write, no Azure mutation, ungated (same OIDC credential path
   as plan).
2. Dispatch `action = plan`, same target and override. **Gate: 0 destroy on the domain.** An
   untaint that still shows `-/+ replace` on the domain means something else changed (e.g. the
   `domain_configuration_type = "FullySynced"` pin drifted) - STOP, diagnose before applying.
3. Dispatch `action = apply`, same target and override. Short apply (the domain is now a Read),
   OIDC token stays comfortably valid.

### 6b. Domain built in Azure but ABSENT from state (the import path, ADR-029 original design)

If the domain exists live (`provisioningState: Succeeded` in the portal / `az resource show`)
but a plan tries to CREATE it (requires-import guard, "already exists"):

1. Operator reads the live initial replica-set GUID (portal, or
   `az resource show --ids <domain-id> --query "properties.replicaSets[0].replicaSetId"`) - keep
   this value out of any committed doc/chat (abstract reference only).
2. Set the `AADDS_IMPORT_REPLICA_SET_ID` repo Secret to that GUID.
3. Dispatch `action = plan`, `target = platform/identity`,
   `enable_conditional_access_override = false`. **Gate: the domain must show `import`, not
   `create`.** If it still shows `create`, the import block did not pick up the Secret - stop
   and check the Secret was actually saved before the run started.
4. Dispatch `action = apply`, same inputs. Import is a metadata read, not a create-wait, so it
   succeeds even while a second DC is still healing.
5. **After recovery lands (either path):** unset the `AADDS_IMPORT_REPLICA_SET_ID` Secret again
   (blank it out) - LESSON 52, a stale-but-armed import block has broken a later plan before.
   The `import {}` block itself stays in code (inert when the Secret is blank); only the Secret
   value needs clearing.

Either recovery path re-applies still at `enable_conditional_access_override = false` - recovery
never touches Pass 2's flag.

---

## 7. Pass 2 dispatch

Only after Pass 1 (or its recovery) lands green and PC-3G's Graph-role / P2 sub-conditions are
confirmed (P2 already confirmed active 2026-07-20).

**Step A - plan (ungated):**

| Input | Value |
|---|---|
| `target` | `platform/identity` |
| `action` | `plan` |
| `enable_conditional_access_override` | `true` |

**PC-5G plan-scan gate (STOP if violated), using the §0-corrected shape:**
- **The AADDS domain plans as 0 change / 0 replace** (a pure Read/refresh). A `-/+ replace` on
  `azurerm_active_directory_domain_service.this[0]` here is a STOP (LESSON 26) - it means a
  ForceNew attribute drifted (e.g. the `FullySynced` pin) and re-creating the domain is another
  multi-hour create. Do not apply; escalate.
- **Exactly ten pure adds**, all `count 0 -> 1`: the ten addresses listed in §0. Nine are
  `azuread` (Graph); one (`time_sleep.wait_named_location`) is not. `geo_block` (CA-005) IS
  present - this is correct per the §0 correction, not a STOP.
- **Zero change/replace** to the VNet, subnet, `entra_ds` NSG, the RSV, the ADR-028 exemption +
  its Pass-1 `time_sleep`, or the hub peering. Only the standing OQ-032 CreatedDate tag-strip
  noise class is tolerated on any of those.

**Step B - apply (gated by `production`):** same inputs, `action = apply`. This is a SHORT apply
(seconds for the domain Read, then the nine Graph writes under a fresh, just-minted token) - the
whole point of the two-pass split.

**Success looks like:** the job completes green in minutes (not hours), all ten addresses show
`Apply complete`, and NO `AADSTS700024` appears in this pass either.

**Non-greenfield / every future apply:** leave `enable_conditional_access_override` **blank**.
The code default (`true`) is exactly this Pass-2 behavior, applied in the normal single pass -
the two-pass sequence is a greenfield-rebuild-only runbook step, never a standing default.

---

## 8. Live-run monitoring (PC-6G, the crux)

The durable-token fix is structurally sound (verified against provider source, DECISIONS.md
ADR-055) but only PROVEN by this live multi-hour apply. While Pass 1 is polling:

- Watch the Actions job log stream (not just the final result) for any `AADSTS700024` string.
  Since Pass 1 is azurerm-only, a clean run shows the domain create polling silently for
  1-3 hours with no auth errors, then a single `Apply complete` at the end.
- Confirm (from the log) that the "Export OIDC request inputs for provider token refresh"
  step ran early in the job (ADR-055 Part 2) - its presence is the durability mechanism, not
  optional instrumentation.
- **Hard STOP rule:** if `AADSTS700024` appears ANYWHERE in Pass 1 (it should not, structurally),
  that is one failure. **A SECOND identical `AADSTS700024` on a retry is a hard STOP - do not
  burn a third multi-hour cycle.** This counts toward the user's 4-consecutive-failure bar
  (project-level, not just this root). Escalate to the architect for a fix before any further
  attempt; do not blind-retry a third time.
- Pass 2's fresh-token proof is simpler to observe: it is short, so if it succeeds at all with
  no `AADSTS700024`, PC-6G's Pass-2 half is satisfied immediately.

---

## 9. STOP / rollback matrix

| Condition | Where it can occur | Action |
|---|---|---|
| Any `azuread_*` address in the Pass 1 plan | Pass 1 plan-scan (PC-1G) | STOP. Do not apply. The umbrella gate is broken - escalate to cloud-engineer/architect, do not work around by hand-editing the plan. |
| Any destroy/replace in the Pass 1 plan | Pass 1 plan-scan | STOP. A from-empty-state root should be pure adds only; a replace/destroy means state is not actually empty or something else is wrong - diagnose before applying. |
| `-/+ replace` on the AADDS domain (Pass 2 plan, or any recovery re-plan) | PC-5G / §6a step 2 | STOP. Do not apply. A ForceNew attribute drifted (check the `FullySynced` pin first). Applying would destroy-and-recreate a multi-hour resource. |
| Domain plans as `create` instead of `import` during the §6b recovery plan | Pass 1 recovery | STOP. The `AADDS_IMPORT_REPLICA_SET_ID` Secret did not take - re-check it was saved, re-plan before applying. |
| First `AADSTS700024` in any pass | Live run (PC-6G) | Not an automatic STOP on its own, but treat as a serious signal. Capture the full log, do not blind-retry more than once. |
| **Second identical `AADSTS700024`** on retry | Live run (PC-6G) | **HARD STOP.** Do not dispatch a third multi-hour attempt. Escalate to the architect - this counts toward the 4-fail project bar. |
| `enable_conditional_access_override = false` dispatched against a non-empty identity state (CA policies already exist) | Any dispatch | **STOP before dispatch, not after (PC-7G).** This flips the 9 azuread resources `count 1 -> 0` and DESTROYS them. Confirm greenfield (empty state / post-teardown) before ever using `false`. If this was dispatched by mistake, do not apply the resulting plan - it will show 9 destroys, which is the tell. |
| Any Deny-policy failure referencing `Deny-Public-IP` at the identity MG | Pass 1 apply | Check PC-2G was actually satisfied (Step 1 applied, assignment live) before assuming the ADR-028 exemption itself is broken. |
| State-SA firewall 403 on init | Any dispatch | Not specific to identity - see `docs/cicd-deploy-teardown.md` §8 (JIT firewall) and LESSON 51 (force-unlock via the failed run's Lock Info block). Do not run local plans against the firewalled state SA. |

---

## 10. Post-run handoff (before the root is marked green)

Per the project's QA gate (apply-success is not enough - live-state vs intent must be
validated):

- **Pass 1 archive:** azurerm-only plan/apply log, domain `provisioningState: Succeeded`,
  replica set `Running`, both DC IPs present (or the documented recovery exercised and
  recorded).
- **Pass 2 archive:** the ten-address plan/apply log (§0 corrected shape), all eight CA
  policies present (`ca_policy_state = enabledForReportingButNotEnforced` per
  `envs/poc.tfvars` - report-only, not enforced), `geo_block` present with the approved
  countries named location resolved, domain Read/no-op, NO `AADSTS700024` in either pass.
- **Live-vs-intent (PC-8G):**
  - AADDS Standard SKU, `FullySynced`, security block as coded (Kerberos sync on; NTLM, TLS
    1.0, on-prem sync off).
  - The ADR-028 exemption scoped to `rg-identity-aadds` ONLY (not the whole identity MG).
  - RSV `ZoneRedundant`, `public_network_access_enabled = false`.
  - **Identity VNet DNS resolves to the two DC IPs** (module `dns_servers` derived default,
    ADR-029 addendum) - confirm via `az network vnet show` or the portal, do not set this
    out-of-band (the module asserts `dhcpOptions` and would fight a manual/`azapi` edit).
  - Remove any temporary directory roles granted to the CI SP for this build (if any were
    granted beyond the standing Graph app roles) - track from the day they were granted.
  - `Deploy-Diag-LogsCat` will NOT self-heal (OQ-021, separate `platform/management-groups`
    fix) - expected, not a blocker for marking identity green.
- **Token-durability evidence (PC-6G close-out):** the Pass 1 log shows azurerm polling the
  full create-wait duration with no auth failure, and the Pass 2 log shows the Graph writes
  succeeding under a freshly-minted token. Both need to be true to close PC-6G, not just "the
  apply eventually succeeded."

Once QA signs off against this list, hand to the code reviewer's next-gate as applicable and
update `WORKLOG.md` / `DEPLOYMENT.md` Step 4's "Validate" line with the live run ID.

---

## 11. Quick reference - exact dispatch inputs by phase

| Phase | `target` | `action` | `enable_conditional_access_override` | `resource_address` | `lock_id` |
|---|---|---|---|---|---|
| Pass 1 plan | `platform/identity` | `plan` | `false` | blank | blank |
| Pass 1 apply | `platform/identity` | `apply` | `false` | blank | blank |
| Recovery - untaint | `platform/identity` | `untaint` | `false` (no effect, kept for log clarity) | `azurerm_active_directory_domain_service.this[0]` | blank |
| Recovery - plan (post-untaint or with import Secret set) | `platform/identity` | `plan` | `false` | blank | blank |
| Recovery - apply | `platform/identity` | `apply` | `false` | blank | blank |
| Pass 2 plan | `platform/identity` | `plan` | `true` | blank | blank |
| Pass 2 apply | `platform/identity` | `apply` | `true` | blank | blank |
| Every future (non-greenfield) apply | `platform/identity` (or `all`) | `plan`/`apply` | blank (`""`) | blank | blank |
