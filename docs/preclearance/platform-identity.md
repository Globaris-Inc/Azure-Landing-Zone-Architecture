# Pre-clearance: platform/identity (RE-APPLY - RECOVERY after run 29055619749)

> Artifact of the deploy pre-clearance gate (see `docs/deploy-preclearance.md`).
> Prepared by: architect. Date: 2026-07-10. Status: CLEARED once the actions below are done.
> Evidence: live az CLI enumeration 2026-07-09 + 2026-07-10, deploy run 29055619749 logs,
> MS Learn (alert-nsg + network-considerations), and the azurerm v4.71.0 provider import docs.
> Governing decision: **ADR-029** (this recovery), building on ADR-028.

## State of the root (after run 29055619749)

ADR-028 worked: the exemption admitted the service PIP and the managed domain was BUILT in Azure this run
(`provisioningState: Succeeded`, replica set `Running`, one DC IP `10.2.0.4`). But the run then failed on a
CRITICAL AADDS104 network-error health alert, which cascaded into a create timeout and a token-expiry
failure of the trailing azuread operations. Net position now:

- Managed domain: **exists in Azure, NOT in Terraform state** (the create never returned, so the provider
  never recorded the ID). A plain rerun hits the azurerm requires-import guard ("already exists").
- `geo_block` CA policy: still not created (the 8th of 8). 7 of 8 CA policies exist.
- NSG `nsg-identity-aadds-globaris-poc`: carries a custom `Deny-All-Inbound` @4000 that is the AADDS104
  root cause (see below).
- ADR-028 exemption + the two `time_sleep` resources: already applied (they are why the PIP was admitted).

## AADDS104 finding (primary root cause, verified 2026-07-10)

CRITICAL health alert "The managed domain is experiencing a network error" (replica set East US 2 /
vnet-identity-globaris-poc / snet-aadds). Live evidence: `snet-aadds` has **routeTable = null** (no UDR, so
the UDR branch of AADDS104 is ruled out), NSG = `nsg-identity-aadds-globaris-poc`. The NSG's custom
`Deny-All-Inbound` @4000 sits above (numerically below) the Azure default rules `AllVnetInBound` @65000 and
`AllowAzureLoadBalancerInBound` @65001 and therefore overrides them - blocking intra-VNet DC replication and
the load-balancer management/health-probe path (168.63.129.16). MS Learn (alert-nsg, network-considerations,
reviewed 2026-07-10) is explicit that Domain Services relies on those two default rules and that custom rules
must not block them. Fix in code per ADR-029: remove the `Deny-All-Inbound` @4000 rule; the Azure defaults
(AllowVnetInBound @65000, AllowAzureLoadBalancerInBound @65001, DenyAllInBound @65500) then govern, which is
the MS-recommended default managed-domain NSG. Internet inbound stays denied at @65500.

## Policy collisions (verified live)

| Assignment | Scope | Effect / mode | Fires on | Verdict |
|---|---|---|---|---|
| `Deny-Public-IP` (builtin 6c112d4e-..., notAllowed = publicIPAddresses) | identity MG | Deny / Default | The service-created Standard PIP the managed domain MUST deploy | **CLEARED by ADR-028 RG-scoped Waiver exemption + 300s sleep. PROVEN this run: the PIP was admitted and the domain built.** |
| `Deny-Subnet-Without-Nsg` | identity MG | Deny / Default | Subnet PUTs | PASS: the Entra DS subnet already exists with its NSG. Removing the custom deny-all rule (ADR-029) does NOT remove the NSG, so this stays satisfied. |
| `Deny-MgmtPorts-Internet` | identity MG | Deny / Default | NSG rules allowing mgmt ports from Internet | PASS: the retained 5986 rule sources the `AzureActiveDirectoryDomainServices` service tag, not Internet. **CORRECTION: the earlier "proven in run 1" claim was false - run 1 only CREATED the NSG; no domain existed then to prove reachability. Reachability is only now being proven, and the run-5 AADDS104 shows the prior rule set was in fact WRONG (the deny-all blocked the DCs). ADR-029 corrects it.** |
| `Deploy-VM-Backup` | identity MG | DINE / Default | VMs | N/A (no VMs) |
| `Deploy-Diag-LogsCat` | globaris MG | DINE / Default | aad-domainservices diagnostics to platform LAW | **Does NOT self-heal.** Structural unwired-LAW-parameter defect (resolves to the zero-GUID subscription -> `LinkedAuthorizationFailed`), fails tenant-wide for every targeted resource. Does NOT block the identity apply. Fix = wire the real platform LAW resource ID into the assignment in `platform/management-groups`. Tracked in **OQ-021**. |

## Tenant / directory prerequisites (verified in place)

- Graph app roles on the CI SP: Policy.Read.All, Policy.ReadWrite.ConditionalAccess, Application.Read.All
  (admin-consented).
- "Domain Controller Services" publisher SP exists; "AAD DC Administrators" group exists; CI SP is a member.
- TEMP directory roles on the CI SP: Application Administrator + Groups Administrator. **Remove both after
  the domain is healthy (mandatory ADR-028/ADR-029 follow-up).**
- Entra ID P2 trial active (all 8 CA policies licensed). Watch expiry (30 days from 2026-07-08 activation).
- Microsoft.AAD RP registered (in state).
- RBAC for the ADR-028 exemption write: CLEARED (Resource Policy Contributor @ globaris, independent of the
  standing Owner grant that OQ-008 will remove).

## Known provider/service behaviors in play

- **Config-driven import is the recovery mechanism (ADR-029).** The domain is built but unstated; an
  `import {}` block brings it into state during the normal CI plan/apply (no local `terraform import`). The
  import ID is a COMPOSITE: `<domain resource ID>/initialReplicaSetId/<initial replica set GUID>` - a plain
  resource-ID import fails. The replica set GUID must be read from the live domain (portal or
  `az resource show --ids <domain-id> --query "properties.replicaSets[0].replicaSetId"`) and handed to the
  cloud-engineer. Root pins `required_version >= 1.9`, so import blocks are supported.
- The `azurerm_active_directory_domain_service` create waits for both DCs (create-only, 3h default timeout).
  After import, the wait is never re-entered; subsequent applies do a Read (seconds).
- **OIDC token expiry on long applies (ADR-029 Part C):** the GitHub OIDC assertion (~5 min) and derived
  tokens (~1h) do not survive a 3h apply, which is why the trailing azuread/Graph ops failed with
  AADSTS700024 in run 5. Import removes the multi-hour long pole, so future applies are short and the token
  stays valid. `geo_block`'s 1040 was NOT propagation (the named location is days old); it was the expired
  assertion. Durable greenfield fix (root split or CI re-auth) tracked in **OQ-022**.

## Ordered actions before / during re-apply (ADR-029 runbook)

1. Cloud-engineer (code, `platform/identity`, one batch, code-reviewer gates):
   (a) remove the `Deny-All-Inbound` @4000 `security_rule` from `azurerm_network_security_group.entra_ds`
   (keep the 5986 rule; update the NSG header comment to cite the alert-nsg / network-considerations
   default-rule requirement); (b) add an `import {}` block for
   `azurerm_active_directory_domain_service.this[0]` with the composite import ID.
2. Operator supplies the initial replica set GUID (portal or az) for the import ID.
3. CI plan: expect NSG updated in place (1 rule removed), domain **IMPORTED** (not created), `geo_block`
   created (1 to add); 0 destroy. Gate the plan: it must show "import" (not "create") for the domain, and the
   NSG diff must remove only the deny rule.
4. CI apply: NSG deny rule removed, domain imported, geo_block created. Short apply -> OIDC token stays valid.
5. Post-apply verification (operator, az): AADDS104 clears and the 2nd DC IP appears. Health auto-updates
   within ~2h of the NSG fix (alert-nsg article). Verify via `az ad ds show` / the portal health blade.
6. Post-apply cleanup: remove the two temp directory roles (Application Administrator + Groups Administrator)
   from the CI SP once the domain is healthy. The `Deploy-Diag-LogsCat` diagnostic setting will NOT appear
   via auto-remediation (OQ-021, unwired LAW parameter, separate `platform/management-groups` fix).
7. Confirm steady state: a later CI plan shows 0 changes on the domain (Read-only refresh), proving the
   token-expiry exposure is closed for the POC.

Sequencing note: NSG fix and the import block MUST ship together. An NSG-only apply would try to CREATE the
still-unstated domain and fail the requires-import guard. Import has no create-wait, so it succeeds even
while the 2nd DC is still healing; the heal completes asynchronously afterward (benign computed update).
Healing before import is not achievable without a local import or -target, both forbidden by the CI-only rule.

## ADDENDUM - post-recovery outcome (run 29068343843, 2026-07-10)

The recovery apply completed (~34 min, domain healthy). The NSG root-cause analysis above was correct, but
the recovery MECHANISM differed from the import-based plan. This addendum records the REAL sequence and
supersedes the ordered actions above where they conflict. Governing decisions: ADR-029 addendum + ADR-030.

Real sequence that green-lit the domain (untaint -> plan-gate -> apply -> DNS-in-IaC -> geo_block deferred):
1. **NSG:** `Deny-All-Inbound` @4000 removed (as planned) - AADDS104 cleared, the 2nd DC IP appeared.
2. **Recovery was `terraform untaint`, NOT config-driven import.** The timed-out create left the domain
   **tainted** in state (not absent), and `import {}` is skipped for in-state resources, so the import block
   was a no-op and the plan fell through to a destructive REPLACE. Used a new CI-only `action=untaint`
   (`deploy.yml` / `_tf-root.yml`, single-target-guarded). The import block + `aadds_import_replica_set_id`
   variable are retained for the greenfield-redeploy adoption path only.
3. **Plan-gate:** after untaint, a second ForceNew replace surfaced - `domain_configuration_type` unset in
   config (null) vs Azure default `"FullySynced"`. Fixed by pinning `domain_configuration_type = "FullySynced"`
   (305757f). The plan gate MUST confirm 0 destroy on the domain before apply.
4. **Apply:** short, OIDC token valid throughout.
5. **AADDS post-deploy DNS (NEW checklist item, was missed):** the identity VNet DNS servers must point at the
   DC IPs (known only after the domain exists). Initially set manually in the portal; now wired in IaC via the
   AVM VNet module `dns_servers` input. An out-of-band `azapi_update_resource` was rejected - the module
   asserts `dhcpOptions = null` and would fight it (perpetual drift).
6. **geo_block: DEFERRED, not created.** It failed Graph 1040 again ~1 min into the apply with a VALID token,
   so it is a genuine named-location reference bug, not token expiry. Gated off via
   `enable_geo_block_ca_policy = false` (ADR-030). 7 of 8 report-only CA policies applied green. Diagnosis
   tracked in **OQ-023**.

Identity pre-clearance checklist gap now closed: **"AADDS post-deploy: identity VNet DNS -> DC IPs (via the
AVM VNet module `dns_servers` input)"** is a required post-deploy step for any greenfield identity redeploy.

Steady state: a subsequent CI plan shows 0 changes on the domain (untaint + FullySynced pin + DNS-in-IaC),
confirming clean state and that the token-expiry exposure is closed for the POC.

---

# ADDENDUM 2026-07-20 - GREENFIELD RE-CLEARANCE for the ADR-055 two-pass (Wednesday production rebuild)

> **Event:** the Wednesday greenfield production redeploy of `platform/identity` from an EMPTY Azure estate
> (the banking estate was torn down green E2E, ADR-054). This is a NEW pre-clearance on the same root, not
> the 2026-07-10 recovery above - it clears the ADR-055 durable-token fix (OQ-022 resolution) on its FIRST
> live greenfield exercise.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-20.
> **Code identity:** branch `feature/adr-055-oidc-durability` @ `c5c9a23`, code-reviewer APPROVED (BLOCK ->
> APPROVE arc). This gate clears the DEPLOY, not the code.
> **Governing decisions:** ADR-055 (this fix), building on ADR-029 (NSG fix + import/untaint recovery) and
> ADR-028 (Deny-Public-IP RG-scoped Waiver). Resolves OQ-022.
> **Honesty note:** the estate is torn down, so there is NOTHING live to enumerate except tenant-directory
> prerequisites. The live-check items below are therefore framed as OPERATOR-VERIFIED REBUILD-TIME GATES
> (portal / az), not this-session enumerations. No az CLI was run from the architect seat.
>
> ## VERDICT: **GO - CONDITIONAL** on PC-1G through PC-8G below.
> The crux is that the durable-token fix (ADR-055 Part 1 + Part 2) is STRUCTURALLY sound but only PROVABLE by
> the live multi-hour greenfield apply - it cannot be proven statically (PC-6G). Part 1 makes the long pole
> azurerm-only (the proven-safe path), so even if Part 2's refresh has an edge case, the expensive pass is
> not the one at risk; only Pass 2 (short, cheap, retryable) touches Graph.

## A1. Lifecycle + plan-shape audit of the two-pass

**Resource-type lifecycle (step 3d), verified 2026-07-20:**
- `azurerm_active_directory_domain_service` (native; NO AVM module exists - registry 404 for
  `avm-res-aad-domainservice`, re-confirmed) is CURRENT in azurerm `~> 4.71` (resolves 4.71.x). azurerm 4.72.0
  now exists but the `~> 4.71.0` pin holds on 4.71.x by design (ADR-055 floor). Not deprecated.
- Microsoft Entra Domain Services **Standard SKU** is CURRENT (not retired / not blocked for new enablement);
  Standard = a single replica set, the lowest-cost tier (MS Learn pricing + change-sku, 2026-07-20). No
  lifecycle regression since the founding design.
- `azuread` provider resolves **3.9.0** (latest, published 2026-06-18) under `~> 3.9`; `azurerm` 4.71.x under
  `~> 4.71.0`. Both current, both read the OIDC request inputs (ADR-055 mechanism).

**The count-gate flip is PURELY ADDITIVE (the central correctness finding).** On greenfield the FIRST-ever
apply is Pass 1 with `enable_conditional_access = false`, so all ten umbrella-gated addresses evaluate
`count = 0` and are simply ABSENT from state (never created). Pass 2 flips the flag to `true`, taking each
`count` 0 -> 1. Because these instances never existed in state, `[0]` is a first CREATE, NOT a replace and NOT
a destroy. There is no `[0] -> [0]` identity mutation. **Net: Pass 1 -> Pass 2 is ten pure adds, zero
destroy/replace on the gated set - the core verdict is UNCHANGED by the geo_block correction below (this is a
count correction, not a shape change: still all creates, still zero destroy/replace on greenfield).**

**CORRECTION 2026-07-20 (coordinator code-verified) - the Pass 2 count is TEN, geo_block IS created.** An
earlier draft of this addendum read `geo_block`/CA-005 as OFF ("9 adds / 7 of 8 CA policies") from stale
DEPLOYMENT.md narrative. That is WRONG. `geo_block` gates on
`var.enable_conditional_access && var.enable_geo_block_ca_policy`; code-verified, `enable_geo_block_ca_policy`
defaults `true` (re-enabled in commit `efde82f`, OQ-023/ADR-030 resolved - the earlier NamedLocation Graph
error 1040 was fixed by referencing the provider's `object_id` attribute, not `.id`), and `envs/poc.tfvars`
does NOT override it. So in Pass 2 BOTH flags are true and geo_block IS created. The correct Pass 2 shape is
**TEN plan addresses = nine azuread/Graph writes (all EIGHT CA policies CA-001..CA-008 INCLUDING geo_block/
CA-005, plus the `azuread_named_location.approved_countries`) + one `time_sleep.wait_named_location`** =
8 of 8 CA policies present. The umbrella-gated set that goes count 0 -> 1 is exactly these ten.

**`[0]` hard-index safety at count=0 (Pass 1).** The only hard `[0]` index on a CA-gated resource is inside
`geo_block`: `excluded_locations = [azuread_named_location.approved_countries[0].object_id]`. `geo_block` is
itself gated on the SAME umbrella flag, so at Pass 1 its `count = 0` and its body is never evaluated -
Terraform evaluates `count` before the block, so there is no index-out-of-range against the absent named
location. SAFE.

**Output safety.** All CA outputs use `one(resource[*].attr)` which returns `null` at count=0 (Pass 1) and the
single value at count=1 (Pass 2) - no `[0]` panic when the flag is false. `entra_domain_service_id` uses
`local.entra_ds_enabled ? ...[0].id : null`; `entra_ds_enabled` is true in BOTH passes (independent of the CA
flag), so that `[0]` is always valid. Verified no unguarded `[0]` on any CA-gated address.

**ForceNew on the AADDS domain.** `domain_configuration_type = "FullySynced"` is pinned (ADR-029) precisely to
kill the null -> "FullySynced" ForceNew replace. On greenfield the domain is a fresh `+ create` in Pass 1; in
Pass 2 it is already in state so it must plan as a Read / no-op (0 change, **0 replace**). A `-/+ replace` on
the domain in EITHER the Pass-2 plan or a Pass-1 recovery re-apply is a STOP (LESSON 26 / ADR-055 follow-up):
it would mean the FullySynced pin (or another Azure-assigned ForceNew attribute) drifted, and re-creating a
managed domain is a fresh multi-hour create.

## A2. Live policy matrix at greenfield (rebuild-time order matters)

The estate is torn down, so NO policy is in force right now. At Wednesday rebuild the ALZ policy layer lands
via **Step 1 `platform/management-groups`**, which is applied BEFORE **Step 4 `platform/identity`**. So by the
time identity applies, these assignments ARE in force at the Identity MG ancestry:

| Assignment | Scope | Fires on | Disposition for the identity apply |
|---|---|---|---|
| `Deny-Public-IP` | identity MG | The mandatory service-created Standard PIP the managed domain deploys | **Handled IN-ROOT by ADR-028:** the RG-scoped `Waiver` exemption `exempt-deny-public-ip-aadds` + its 300s `time_sleep` are part of `platform/identity` itself (count-gated on `entra_ds_enabled`), created in the SAME Pass-1 apply BEFORE the domain create. **HARD PREREQ (PC-2G):** the exemption references `Deny-Public-IP` by LITERAL id at the identity MG, so that assignment MUST already exist (Step 1) or the exemption PUT 404s. |
| `Deny-Subnet-Without-Nsg` | identity MG | Subnet PUTs | PASS: the Entra DS subnet is created WITH the `entra_ds` NSG attached in the same root. |
| `Deny-MgmtPorts-Internet` | identity MG | NSG rules allowing mgmt ports from Internet | PASS: the retained 5986 rule sources the `AzureActiveDirectoryDomainServices` service tag, not Internet. The ADR-029 fix removed the custom `Deny-All-Inbound @4000` (verified present-in-code this session: `identity-network.tf` carries ONLY the 5986 rule + the explicit no-deny-all comment), so Azure's required `AllowVnetInBound`/`AllowAzureLoadBalancerInBound` defaults govern - the AADDS104 root cause cannot recur. |
| `Enable-DDoS-VNET` | Connectivity + landingzones MGs | VNet creates | **PREREQ:** must be `DoNotEnforce` (ADR-026) or the identity VNet create 403s. Set in Step 1. The identity VNet is under the identity MG, but confirm the DDoS assignment scope/effect at rebuild. |
| `Deploy-Diag-LogsCat` | globaris root MG | aad-domainservices diagnostics | Non-blocking DINE; structural unwired-LAW defect (OQ-021). Does NOT block the identity apply. |
| tag-governance Modify (CreatedDate) | root MG | all resources | The standing OQ-032 cosmetic tag-strip noise class - allowed in the plan scan, not a functional diff. |

## A3. Tenant / directory prerequisites

- **MANUAL (not automatable), before Pass 1:** the "Domain Controller Services" publisher SP / enterprise
  application AND the "AAD DC Administrators" group must exist in the tenant, with the CI SP a member. Terraform
  cannot create the Entra DS publisher SP (README + `domain-services.tf` header).
- **`Microsoft.AAD` RP registration:** handled IN-ROOT (`azurerm_resource_provider_registration.aad`,
  count-gated), and the CI SP holds Contributor (=> `*/register/action`) on the identity sub. Registration
  blocks up to 2h; not in any azurerm auto-register set, so the in-root registration is required and present.
- **Graph app roles on the CI SP (Pass 2 only):** `Policy.Read.All`, `Policy.ReadWrite.ConditionalAccess`,
  `Application.Read.All` (admin-consented). NOT needed for Pass 1 (no Graph write), so a missing Graph role
  cannot fail the expensive pass - but all three must be in place before Pass 2.
- **Entra ID P2 licensing (Pass 2 gate for the risk policies):** CA-007 (user-risk) and CA-008 (sign-in-risk)
  carry Identity Protection risk conditions that REQUIRE Entra ID P2; Graph rejects their create without it.
  The 2026-07-10 recovery doc noted a P2 TRIAL activated 2026-07-08 with a ~30-day window - that trial may
  still be inside its window on 2026-07-20 but is close enough to warrant an explicit check. **This needs the
  user / operator to confirm live (it is a licensing fact only they can see).** Framed as PC-3G: verify P2
  active before Pass 2; if lapsed, CA-007/008 fail on a SHORT retryable pass - it does NOT endanger the
  multi-hour Pass 1. **CONFIRMED 2026-07-20: operator reports P2 ACTIVE - sub-condition satisfied.**
- **`aadds_import_replica_set_id` recovery input:** leave the `AADDS_IMPORT_REPLICA_SET_ID` CI Secret UNSET for
  the first Pass-1 apply. Unset => `TF_VAR_...=""` => the `import{}` block's `for_each` is an empty set => zero
  import ops => a normal plan/apply is unaffected. It is ARMED only if Pass 1's create-wait times out (see A5 /
  PC-4G).
- **`break_glass_group_object_id`:** if the emergency-access group does not yet exist, the CA policies still
  create with an empty exclusion (report-only, no lockout risk). Set `BREAK_GLASS_GROUP_OBJECT_ID` before ever
  switching `ca_policy_state` to `enabled`. Not a greenfield blocker.
- **CI OIDC export (Part 2):** `_tf-root.yml` exports `ARM_OIDC_REQUEST_URL` / `ARM_OIDC_REQUEST_TOKEN` from the
  runtime `ACTIONS_*` vars via a `$GITHUB_ENV` run-step (verified present, lines ~188-191), and
  `permissions: id-token: write` is set (line ~92). `TF_VAR_aadds_import_replica_set_id` passthrough restored
  (line ~144). These are the Part-2 wiring - present in the reviewed code.

## A4. GitHub / provider known-issues sweep

| Item | Disposition |
|---|---|
| **AADSTS700024** ("Client assertion is not within its valid time range") - run 29055619749 failure mode | This is the exact class ADR-055 closes. Part 1 removes exposure structurally (no Graph write at the multi-hour tail in Pass 1); Part 2 makes the assertion re-mint reliable for Pass 2 and every long apply. A recurrence in Pass 1 would contradict the azurerm-only guarantee and is a STOP-and-diagnose. |
| ADR-055 refresh MECHANISM (go-azure-sdk `github_oidc_authorizer` re-mints per access-token acquisition when the request URL/token resolve) | Code-verified against provider source, NOT live-proven. Explicitly a PC-6G live-proof item. |
| azuread 3.9.0 / azurerm 4.71.x idle-gap token behaviour | The run-29055619749 divergence (azurerm re-minted across 2h11m; azuread reused a stale job-start assertion) is attributed to version-gated auto-detection + a multi-hour idle gap; the explicit request-input export + current pins remove the auto-detection dependency. Still only provable live. |
| No open azurerm/azuread issue found that BLOCKS `azurerm_active_directory_domain_service` create or CA-policy create on the pinned versions (2026-07-20) | PASS - no new blocking known-issue since the founding build. |

## A5. PUT-time constraint sweep (AADDS create)

Verified against the current "Network considerations for Microsoft Entra Domain Services" + "AADDS104" +
change-sku docs (2026-07-20):
- **SKU** `Standard` = single `initial_replica_set` - valid, matches the module shape; the subnet_id is
  supplied from the identity VNet's `entra-ds` subnet (a /27 = `cidrsubnet(/24,3,0)`).
- **Region** `eastus2` (`identity_location` default) - AADDS is available there; co-located with the primary
  hub it peers to.
- **Subnet + NSG:** the DS subnet has the `entra_ds` NSG (5986-from-service-tag only, NO custom deny-all) and
  **no route table** (a UDR on the DS subnet is a documented AADDS104 trigger - the code creates no route table
  on this subnet; confirm none is injected by policy at rebuild).
- **`security` block:** `sync_kerberos_passwords = true` is API-MANDATED (a `Disabled` value 400s -
  run 28950922048); NTLM/TLSv1/on-prem sync off is supported hardening. `domain_configuration_type =
  "FullySynced"` pinned (ForceNew - A1).
- **Service PIP:** the mandatory Standard PIP is admitted by the ADR-028 exemption (A2). `filtered_sync_enabled
  = false` (cloud-only). `domain_name` = `var.identity_domain_name` must be supplied in tfvars (e.g. an
  `*.onmicrosoft.com`-based managed-domain name); an empty value fails the create.
- **AADDS post-deploy DNS (required checklist item, ADR-029 addendum):** the identity VNet DNS servers must
  point at the two managed-domain DC IPs. This is wired IN IaC via the AVM VNet module `dns_servers` derived
  default (cidrhost offsets 4/5 of the DS subnet); confirm it resolves post-Pass-1. Do NOT set it out-of-band
  (the module asserts `dhcpOptions` and would fight a portal/azapi edit - perpetual drift).

## A6. Greenfield two-pass run sequence + placement in the Wednesday order

Position in the `deploy.yml` graph: **Step 4**, after **Step 1 `platform/management-groups`** (policy layer +
the `Deny-Public-IP` assignment the ADR-028 exemption targets) and after **Step 3 `platform/connectivity`**
(the primary-hub Secrets the identity-to-hub peering consumes). Parallelizable with Steps 2 / 5.

1. **Pass 1** - dispatch `platform/identity`, `plan` then `apply`, with a `enable_conditional_access = false`
   tfvars OVERRIDE (dispatch-time only; the code default stays `true`). Creates identity VNet / subnet / NSG /
   RG(s) + the `Microsoft.AAD` RP registration + the ADR-028 exemption and its 300s sleep + the AADDS managed
   domain (the 1-3h create-wait) + the RSV + the hub peering. **azurerm-ONLY** - the umbrella gate means ZERO
   azuread resources in this plan. Expected duration dominated by the AADDS create (~1-3h). Token-safe:
   azurerm re-mints across the poll and Part 2's export backs it.
2. **Pass 1 recovery (only if the create-wait times out, e.g. slow DC2 / AADDS104):** TWO documented paths -
   (a) if the domain landed in state TAINTED, run `action=untaint` on
   `azurerm_active_directory_domain_service.this[0]` (the empirically-real recovery in run 29068343843 per the
   addendum above), then re-plan (must show 0 destroy on the domain) and re-apply; (b) if the domain exists in
   Azure but is ABSENT from state, set `AADDS_IMPORT_REPLICA_SET_ID` to the live replica-set GUID (operator
   reads it from the portal / `az`) so the reinstated `import{}` block adopts it. EITHER way, re-apply still at
   `enable_conditional_access = false`. Remove the import block in a cleanup commit once recovery lands
   (LESSON 52).
3. **Pass 2** - dispatch `platform/identity`, `apply`, with `enable_conditional_access = true` (the default -
   dispatch WITHOUT the Pass-1 override). The domain is already in state (azurerm Read, seconds), so the ten
   azuread/time adds (named location + `time_sleep` + all 8 CA policies CA-001..CA-008 INCLUDING geo_block) run
   EARLY in a SHORT apply under a fresh, just-minted token. The apply crosses the `time_sleep.wait_named_
   location` 300s replication buffer (geo_block consumes the named location; ADR-028), so "SHORT" means roughly
   5 minutes of wait plus fast Graph writes - still trivially inside the ~60-75 min token window, still a
   single fresh assertion, so the SHORT-Pass-2 framing holds WITH the 300s wait and the extra geo_block Graph
   write included. Steady-state and every non-greenfield apply is exactly this single pass.

**Plan-scan bars (LESSON 26):**
- **Pass 1:** azurerm-only adds; **ZERO azuread resources** in the plan (the gate proof - any
  `azuread_conditional_access_policy` / `azuread_named_location` address at flag-false = STOP); ZERO
  destroy/replace; the AADDS domain is a `+ create`.
- **Pass 2:** the AADDS domain plans as **0 change / 0 replace** (a `-/+` on the domain = STOP); exactly TEN
  pure adds (all 8 CA policies CA-001..CA-008 INCLUDING `geo_block`/CA-005 + the named location +
  `time_sleep.wait_named_location`); ZERO change/replace to the VNet / subnet / `entra_ds` NSG / RSV /
  ADR-028 exemption / peering. OQ-032 CreatedDate tag-strip is the only tolerated noise class.

## A7. GO conditions

| # | GO condition |
|---|---|
| **PC-1G** | Pass 1 gate proof: the flag-false plan is azurerm-ONLY; ZERO azuread resources appear. Any azuread address at flag-false = STOP (the umbrella gate did not take). |
| **PC-2G** | Ordering: Step 1 `platform/management-groups` applied and the identity-MG `Deny-Public-IP` assignment LIVE before Pass 1 (the ADR-028 exemption targets it by literal id; missing => exemption PUT 404s). `Enable-DDoS-VNET` = DoNotEnforce confirmed. Step 3 primary-hub Secrets present for the peering. |
| **PC-3G** | Tenant prereqs: manual DS publisher SP + "AAD DC Administrators" group + CI SP membership in place (Pass 1); Graph app roles (Policy.ReadWrite.ConditionalAccess, Policy.Read.All, Application.Read.All) + **Entra ID P2 active** before Pass 2. P2 gates CA-007/008; a lapse fails only the short Pass 2 (cheap retry after relicensing), never the multi-hour Pass 1. **Operator confirmed P2 ACTIVE 2026-07-20 - PC-3G P2 sub-condition SATISFIED.** |
| **PC-4G** | Recovery armed but inert: `AADDS_IMPORT_REPLICA_SET_ID` UNSET for the first Pass-1 apply. On a create-wait timeout use `untaint` (tainted-in-state) or supply the replica-set GUID (absent-from-state / import); re-apply still at flag-false. Remove the import block after recovery (LESSON 52). |
| **PC-5G** | Plan-scan both passes to the A6 bars. Pass 1: azurerm-only, 0 destroy/replace. Pass 2: domain 0 change/0 replace (FullySynced pin holds - a `-/+` on the domain = STOP), **TEN pure adds** = all 8 CA policies CA-001..CA-008 INCLUDING geo_block/CA-005 + the named location + `time_sleep.wait_named_location` (geo_block IS created - `enable_geo_block_ca_policy` defaults true, code-verified; a plan showing geo_block ABSENT or only 9 adds = investigate before apply), no touch to VNet/NSG/RSV/exemption/peering. |
| **PC-6G** | LIVE-PROOF caveat (the honest crux): the durable-token fix is STRUCTURAL but only PROVEN by this multi-hour greenfield apply. QA/architect confirm on the run: Pass 1 completes (or times out + recovers) with NO AADSTS700024 and azurerm token refresh across the long poll; Pass 2 Graph writes succeed under a fresh token. A SECOND identical AADSTS700024 = STOP (do not burn a 3rd multi-hour cycle - counts against the user's 4-fail bar). |
| **PC-7G** | The `enable_conditional_access = false` override is GREENFIELD-ONLY. NEVER apply it to a live estate that already carries the CA policies - true -> false on a populated estate DESTROYS all ten gated addresses (the nine azuread Graph resources - 8 CA policies incl. geo_block + the named location - plus the `time_sleep`) via count 1 -> 0. On greenfield they never existed, so Pass 1 -> Pass 2 is purely additive. Guard the override to the clean-room rebuild. |
| **PC-8G** | Post-apply: confirm the identity VNet DNS resolves to the DC IPs (module `dns_servers` derived default, ADR-029 addendum); remove any temp directory roles granted for the build; the `Deploy-Diag-LogsCat` diagnostic will NOT self-heal (OQ-021, separate fix). |

## A8. QA feed (before green)

- Pass 1 plan/apply archived: azurerm-only, no azuread, domain `provisioningState: Succeeded`, replica set
  `Running`, both DC IPs present (or the documented recovery exercised).
- Pass 2 plan/apply archived: TEN pure adds, 8/8 CA policies present (report-only) INCLUDING geo_block/CA-005,
  domain Read/no-op, NO AADSTS700024 in either pass.
- Live-vs-intent: AADDS Standard, FullySynced, security block (kerberos on, ntlm/tls1/on-prem off), the ADR-028
  exemption scoped to `rg-identity-aadds` only, RSV ZoneRedundant, identity VNet DNS -> DC IPs.
- Token-durability evidence (PC-6G): the smoking-gun check - the Pass 1 log shows azurerm polling the create
  for its full duration with NO auth failure, and Pass 2 Graph writes under a fresh assertion.
