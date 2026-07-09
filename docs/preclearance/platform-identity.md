# Pre-clearance: platform/identity (RE-APPLY)

> Artifact of the deploy pre-clearance gate (see `docs/deploy-preclearance.md`).
> Prepared by: architect. Date: 2026-07-09. Status: CLEARED once the actions below are done.
> Evidence: live az CLI enumeration 2026-07-09 + deploy run 28978396902 logs + MS Learn docs.

## State of the root

7 of 8 CA policies exist; the named location exists (fresh id, created 2026-07-08). Remaining to
create: `geo_block` CA policy, the Entra DS managed domain, plus the ADR-028 exemption resources.
A HOLLOW failed domain object exists in Azure (ARM envelope `Succeeded`, replica set empty) and is
NOT in Terraform state.

## Policy collisions (verified live)

| Assignment | Scope | Effect / mode | Fires on | Verdict |
|---|---|---|---|---|
| `Deny-Public-IP` (builtin 6c112d4e-5bc7-47ae-a041-ea2d9dccd749, notAllowed = publicIPAddresses) | identity MG | Deny / Default | The service-created Standard PIP the managed domain MUST deploy (MS Learn network-considerations) | **BLOCKER. Fixed by ADR-028 RG-scoped Waiver exemption on rg-identity-aadds-globaris-poc + 300s propagation sleep, ordered before the domain create.** |
| `Deny-Subnet-Without-Nsg` | identity MG | Deny / Default | Subnet PUTs | PASS: the Entra DS subnet already exists with its NSG (created run 1) |
| `Deny-MgmtPorts-Internet` | identity MG | Deny / Default | NSG rules allowing mgmt ports from Internet | PASS: AADDS NSG rules use service tags, proven in run 1 |
| `Deploy-VM-Backup` | identity MG | DINE / Default | VMs | N/A (no VMs) |
| `Deploy-Diag-LogsCat` | globaris MG | DINE / Default | aad-domainservices diagnostics to platform LAW | Noise: the failed DINE from run 4 was follow-on from the failed domain. Self-heals on the next compliance cycle once the domain is Running; verify within ~24h, else `az policy remediation create` |

## Tenant / directory prerequisites (all verified in place 2026-07-08 sessions)

- Graph app roles on the CI SP: Policy.Read.All, Policy.ReadWrite.ConditionalAccess, Application.Read.All (admin-consented).
- "Domain Controller Services" publisher SP exists; "AAD DC Administrators" group exists; CI SP is a member.
- TEMP directory roles on the CI SP: Application Administrator + Groups Administrator. **Remove both after the domain reaches Running (mandatory ADR follow-up).**
- Entra ID P2 trial active (all 8 CA policies licensed). Watch expiry (30 days from 2026-07-08 activation).
- Microsoft.AAD RP registered (in state, `azurerm_resource_provider_registration.aad`).

## Known provider/service behaviors in play

- Graph replication lag on FRESHLY created named locations (error 1040): run 4 hit it 1 second after
  create. For THIS re-apply no action is needed (the location is days old); ADR-028 adds the durable
  `time_sleep` for greenfield.
- azurerm v4 requires-import guard: the create GETs the resource first; the leftover hollow domain
  object WILL fail the create with "already exists". Hence the mandatory delete below.
- Entra DS create runs ~45-75 min (resource timeout 3h, CI job timeout 360 min - fine).

## Ordered actions before re-apply

1. Cloud-engineer implements ADR-028 (exemption + time provider + 2x time_sleep + depends_on wiring)
   in `platform/identity`. Code-reviewer gates the batch.
2. Operator deletes the failed domain shell (az CLI):
   `az resource delete --ids /subscriptions/<identity-sub>/resourceGroups/rg-identity-aadds-globaris-poc/providers/Microsoft.AAD/domainServices/aadds-globaris-poc`
   and waits for completion (verify with `az resource list -g rg-identity-aadds-globaris-poc`).
3. CI plan: expect 5 to add (exemption, 2 sleeps, domain, geo_block), 0 change, 0 destroy.
4. CI apply.
5. Post-apply: domain reaches Running -> remove the 2 temp directory roles; verify the
   aad-domainservices diagnostic setting exists (~24h) or remediate.
