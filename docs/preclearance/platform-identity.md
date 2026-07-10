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
