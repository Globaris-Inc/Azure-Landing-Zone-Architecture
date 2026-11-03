# Deployment Guide

This is the supported deployment model for the Azure Landing Zone and banking-platform POC. It describes
prerequisites, identity/state bootstrap, root ordering, feature gates, verification, and teardown boundaries.

The command-by-command full-estate procedure is
[`docs/2026-07-22-full-estate-rebuild-runbook.md`](docs/2026-07-22-full-estate-rebuild-runbook.md). That runbook
contains current pre-clearance gates, recovery matrices, and operator commands; do not reconstruct them from
this summary.

## 1. Current stop condition

The managed Azure estate is greenfield after teardown run `30785098012`. Do **not** restart the full rebuild
until the current handoff is cleared:

1. Check whether the CI service principal is assigned the Microsoft Entra **Security Administrator** role.
2. If absent, restore the time-bounded role before Step 1.
3. If present, the last remaining role hypothesis for the Sentinel scheduled-rule 401 is refuted and a clean
   retry can determine whether the error was transient/Azure-side.

See [`docs/worklog/2026-08-03.md`](docs/worklog/2026-08-03.md). A teardown resets Azure resources; it does not
reset an identity or repository-side cause.

## 2. Deployment model

| Operation | Supported path | Reason |
| --- | --- | --- |
| Bootstrap | Local Terraform from `bootstrap/` | Creates the remote backend and OIDC identity before either exists. |
| Validate | GitHub Actions matrix | Validates every deployable root against pinned providers/modules. |
| Plan | GitHub Actions, one root or `target=all` | Read-only; plans may run across the graph. |
| Apply | GitHub Actions, **one root at a time** | The state account firewall opens for one runner; `target=all` apply is blocked by ADR-060. |
| State recovery | Single-root `force-unlock` or `untaint` action | Avoids unmanaged local state access. |
| Teardown | GitHub Actions `teardown.yml` | Reverse dependency order, remnant verification, then canonical state reset. |

Every apply follows: **plan -> inspect resource shape -> resolve stop conditions -> apply -> verify live state**.

## 3. Prerequisites

### 3.1 Azure and tenant prerequisites

- One Microsoft Entra tenant.
- Five pre-provisioned subscriptions: Management, Connectivity, Identity, Security, and Landing Zones.
- Bootstrap operator permissions for management-group creation, RBAC assignment, and required directory work.
- Elevated access at Tenant Root while establishing the hierarchy and bootstrap role model.
- Microsoft Entra Domain Services tenant prerequisites described in
  [`platform/identity/README.md`](platform/identity/README.md).
- An organization-owned subdomain for the immutable managed-domain name.
- Resource providers, service quotas, and regional availability required by the selected feature gates.
- Central US available as primary and East US 2 as secondary/DR.

Known offer constraints in the POC subscription are handled explicitly:

- Corporate App Service and SQL tiers remain off.
- AKS uses a small, single system node pool.
- Region-specific capacity drove Fabric and AI Search to Central US.

### 3.2 Tool versions

| Tool | Repository requirement |
| --- | --- |
| Terraform | `1.15.6` in CI; use the same for bootstrap. |
| Azure CLI | 2.x. |
| GitHub Actions | Hosted runners with OIDC federation. |
| Providers | Pinned in each root; most roots use `azurerm ~> 4.71.0`, with root-specific `azapi`, `azuread`, `alz`, `modtm`, `random`, and `time` pins. |

### 3.3 GitHub identity and configuration

The bootstrap identity uses GitHub workload-identity federation; no Azure client secret is created.
Federated subjects must cover pull requests, the deployment branch/ref, `production`, and
`production-destroy` environment jobs.

Repository variables provide OIDC login identifiers. Secrets provide Terraform IDs and operational values:

- tenant and five subscription IDs;
- CI service-principal object ID;
- alert/security contact destinations;
- hub VNet IDs/names/resource groups and firewall private IPs;
- platform Log Analytics workspace ID/customer ID and action-group ID;
- privileged, break-glass, AKS admin, Sentinel owner, and Fabric admin identities; and
- workload-specific values that are never committed.

Cross-root values are set only after their producer is live. The main handoffs are:

1. Management outputs -> Log Analytics and action-group repository values.
2. Connectivity outputs -> hub IDs/names/resource groups, firewall private IPs, and private DNS resource group.
3. Workload/identity-specific principal values -> their later roots or second pass.

### 3.4 Approval and review reality

- Main-branch protection is configured and version-controlled.
- `production` and `production-destroy` environments exist so the OIDC subjects resolve.
- Required environment reviewers were not supported by the active GitHub billing entitlement; the
  environments are not a proven human approval gate (OQ-015).
- The local review hook has known fail-open/worktree limitations. A review claim must cite the actual reviewer
  verdict and reviewed tree hash, not merely the fact that a commit succeeded.

## 4. Bootstrap

The `bootstrap/` root uses local state, which is ignored and never committed. It creates:

- the OIDC application/service principal and federated credentials;
- a dedicated bootstrap resource group in East US 2;
- a purge-protected Key Vault and RSA key;
- a Storage Account with shared-key access disabled, CMK encryption, versioning, and network restrictions;
- a state container; and
- the RBAC assignments needed to build the estate.

```powershell
Set-Location bootstrap
terraform init
terraform plan
terraform apply
```

The bootstrap resource group is outside normal full-estate teardown. Destroy it only during deliberate final
decommissioning, after all remote state is no longer needed.

## 5. Greenfield preflight

Before Step 1, verify all of the following through the current rebuild runbook:

- no managed resource groups remain in the five subscriptions;
- no soft-deleted Log Analytics workspace can be recovered into a conflicting name;
- the management-group hierarchy is absent except Tenant Root;
- the 11 root state blobs are canonical-empty;
- the state Storage Account rests at `defaultAction = Deny`;
- no stale state leases exist;
- `budget_start_date` is the first day of the current UTC month;
- region and feature flags match the certified plan;
- the Security Administrator directory-role prerequisite above is resolved;
- current pre-clearance applies to the exact commit being deployed; and
- no second deployment run is active.

Do not rely on Terraform state alone to prove greenfield. Soft-deleted resources, extension objects, policy
assignments, and subscription-scope resources require Azure API checks.

## 6. Feature-gate posture

| Gate | Greenfield/rebuild posture | Reason |
| --- | --- | --- |
| `enable_firewall` | `true` for the banking build | Required for forced-tunnel AKS/APIM/Databricks paths; time-box cost. |
| `enable_kubernetes_platform` | `true` | Builds private AKS and Premium ACR. |
| `enable_acr_kubelet_binding` | `false` in Pass 1, then `true` in Pass 2 | Cluster identity does not exist during the greenfield plan. |
| `enable_messaging_platform` | `true` | Builds Event Hubs and Service Bus. |
| `enable_api_platform` | `true` | Builds internal-mode APIM. |
| `enable_data_platform` | `true` | Builds Databricks and ADLS. |
| `enable_fabric_capacity` | `true` during build, suspend after validation | Capacity is independently cost-bearing. |
| `enable_ai_platform` | `true` | Builds Foundry and AI Search. |
| `enable_om_phase1` | `false` for Steps 1-12, then `true` for Steps 13-14 | Prevents AMBA policy architecture from landing before its identity/supporting resources. |
| `enable_synthetic_workload` | `false` | Synthetic signal generator was not part of the proven estate. |
| Corporate SQL/App Service | `false` | Subscription offer caps. |
| DDoS/VPN/DNS Resolver/Bastion | off | Cost/scope controls; absent from the August 1 BOM. |
| Conditional Access override | `false` in identity Pass 1, `true` in Pass 2 | Separates multi-hour Entra DS ARM work from directory operations. |

## 7. Ordered full-estate build

Dispatch one plan and one apply for each step. Never overlap runs.

| Step | Root/pass | August 1 proven bar | Next certified bar | Key gate |
| --- | --- | ---: | ---: | --- |
| 1 | `platform/management-groups` | 537 | 537 | Policy shape and region restrictions. |
| 2 | `platform/management` | 36 | 38 | Current-month budgets; reset LAW handoff. |
| 3 | `platform/security` | 48 | 48 | Sentinel LAW purge and directory role; `-parallelism=1`. |
| 4 | `platform/connectivity` | 696 | 696 | DDoS policy override; firewall IP contract. |
| 5 | `landing-zones/corp-a1` | 24 | 24 | Primary hub/security ready. |
| 6 | `landing-zones/corp-a2` | 24 | 24 | Secondary hub/security ready. |
| 7 | `landing-zones/online-p1` | 26 | 26 | WAF shape and primary hub ready. |
| 8 | `landing-zones/bank-data-p1` | 73 | 76 | Data exemption, diagnostics ownership, no unexpected replacement. |
| 9 | `landing-zones/bank-app-p1` Pass 1 | 67 | 67 | Firewall/rule groups live; ACR binding off; allow long APIM create. |
| 10 | `platform/identity` Pass 1 | 16 | 16 | Conditional Access override off; allow long Entra DS create. |
| 11 | `platform/identity` Pass 2 | 10 | 10 | Conditional Access override on. |
| 12 | `bank-app-p1` Pass 2 | 1 | 1 | Enable only the kubelet `AcrPull` binding. |
| 13 | `platform/management` O&M pass | 3 | 3 | Enable O&M support identity/resources only. |
| 14 | `platform/management-groups` O&M pass | 223 | 223 | AMBA policy architecture; no existing policy churn. |

Plan counts are regression bars for the pinned dependency set, not resource inventory totals. AVM telemetry
objects inflate Terraform counts; a module/version change requires re-deriving the bar rather than blindly
accepting a mismatch.

High-level dispatch pattern:

```powershell
gh workflow run deploy.yml `
  -R Globaris-Inc/Azure-Architecture `
  --ref banking `
  -f target="platform/management-groups" `
  -f action="plan"
```

After the plan is inspected, repeat with `action="apply"`. Use the exact commands and inputs from the full
rebuild runbook, especially for the two identity passes.

## 8. Plan inspection rules

Stop before apply if any of the following appears without a written disposition:

- an unexpected destroy or `-/+` replacement;
- a plan count or resource class outside the certified shape;
- an import/adoption requirement on a supposedly greenfield resource;
- policy assignment, definition, initiative, or management-group churn during the O&M re-land;
- a live resource absent from state;
- an expired or missing policy exemption;
- an unresolved soft-delete recovery;
- a firewall address different from `10.0.0.4` or `10.1.0.4`; or
- an output/secret handoff that cannot be independently verified.

Do not use a bare retry. Diagnose the failure, change the repository or external prerequisite that caused it,
run a new plan, and scan it again.

## 9. Verification after the build

At minimum, compare the result to [`docs/estate-bom.md`](docs/estate-bom.md):

- management-group topology and policy counts;
- resource-group and resource-type counts;
- both firewalls' zones and private IPs;
- eight peering states;
- five spoke default routes;
- WAF Prevention mode;
- private endpoint and DNS inventory;
- Defender pricing state;
- AKS, APIM, messaging, Databricks, Fabric, Foundry, and Search properties;
- diagnostic-setting coverage; and
- resources that must remain absent.

The BOM records non-deterministic naming rules. Compare those resources by stable prefix and count, not by a
GUID-bearing name.

## 10. Teardown and rebuild

Use `teardown.yml`, not ad hoc portal deletion. Full teardown performs:

1. guard and policy disarm;
2. Databricks and diagnostic pre-cascade handling;
3. serialized reverse-order Terraform destroys for owned roots;
4. cross-root attachment cleanup;
5. Azure API remnant sweep;
6. independent verification; and
7. canonical state reset.

The management-group root uses the API cascade in the full path because provider refresh was measured at more
than five hours before issuing a delete. Single-root Terraform destroy remains available when exact provider
ownership is needed.

After teardown, verify Azure and state independently. A green workflow conclusion alone is not sufficient.

## 11. References

- [`docs/2026-07-22-full-estate-rebuild-runbook.md`](docs/2026-07-22-full-estate-rebuild-runbook.md): authoritative operator procedure.
- [`docs/preclearance/2026-07-22-full-estate-rebuild.md`](docs/preclearance/2026-07-22-full-estate-rebuild.md): current pre-clearance evidence and amendments.
- [`docs/cicd-deploy-teardown.md`](docs/cicd-deploy-teardown.md): workflow mechanics.
- [`docs/estate-bom.md`](docs/estate-bom.md): proven live inventory and comparison method.
- [`docs/teardown-redesign.md`](docs/teardown-redesign.md): teardown architecture.
- [`docs/identity-two-pass-dispatch-runbook.md`](docs/identity-two-pass-dispatch-runbook.md): identity-specific two-pass procedure.
- [`WORKLOG.md`](WORKLOG.md): current state and handoff.
