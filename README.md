# Azure Landing Zone and Banking Platform POC

Portfolio-grade Azure platform engineering project built with Terraform, Azure Verified Modules (AVM),
GitHub Actions, and Microsoft Cloud Adoption Framework landing-zone patterns.

The repository started as a five-subscription hub-and-spoke Azure Landing Zone and was extended with a
private banking application and data platform. It includes governance, identity, security, FinOps,
multi-region networking, workload landing zones, deployment automation, teardown automation, operational
runbooks, and an evidence trail of architectural decisions and live failures.

## Project state

This project distinguishes three different facts:

| State | Meaning | Evidence |
| --- | --- | --- |
| **Repository capability** | Terraform and workflows can build the complete platform described below. | Composition roots, pinned lock files, CI workflows, ADRs |
| **Proven deployment** | A complete 14-step build was live-verified on 2026-08-01: 5 subscriptions, 12 management groups including Tenant Root, 5 spokes, 8 connected peerings, and 404 top-level ARM resources by the BOM counting method. | [`docs/estate-bom.md`](docs/estate-bom.md) |
| **Current Azure state** | The managed estate is intentionally greenfield. The last recorded live verification was on 2026-08-10: all five subscriptions had zero managed resource groups, soft-deleted Log Analytics workspaces were zero, and only Tenant Root remained. | [`docs/teardown-redesign.md`](docs/teardown-redesign.md) |

“Built” in this documentation means implemented in Terraform and proven in a live deployment. It does not
mean the resources are currently incurring cost.

## Proven architecture

- Five Azure subscriptions: Connectivity, Identity, Landing Zones, Management, and Security.
- Custom `globaris` management-group hierarchy with Platform and Landing Zones branches, plus Corp,
  Online, Sandbox, and Decommissioned archetypes.
- Central US primary and East US 2 secondary/DR, selected after recorded capacity constraints
  ([ADR-069](DECISIONS.md)).
- Dual hub VNets with Azure Firewall Premium, global hub peering, and forced-tunnel routes from five spokes.
- Five workload spokes:
  - `corp-a1`: primary private corporate network landing zone.
  - `corp-a2`: secondary/DR corporate network landing zone.
  - `online-p1`: internet-facing Application Gateway WAF_v2 and Static Web App pattern.
  - `bank-app-p1`: private AKS, Premium ACR, APIM, Event Hubs, and Service Bus platform.
  - `bank-data-p1`: Databricks, ADLS Gen2, Fabric F2, Microsoft Foundry, and AI Search platform.
- Microsoft Entra Domain Services in a dedicated identity VNet.
- Central Log Analytics workspaces, Microsoft Sentinel, Defender for Cloud configuration, budgets, cost
  exports, policy-as-governance, and AMBA/operations-monitoring capability.
- GitHub Actions OIDC authentication with no stored Azure client secret.
- Plan-before-apply, sequential single-root deployment, plan-shape gates, two-pass identity/AKS operations,
  and independent teardown verification.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for diagrams and the fidelity map, and
[`docs/estate-bom.md`](docs/estate-bom.md) for the live-verified resource inventory.

## Prerequisites

- Terraform `1.15.6` in CI. Individual roots declare minimum versions of `>= 1.9` or `>= 1.11`.
- Azure CLI 2.x.
- One Microsoft Entra tenant and five pre-provisioned Azure subscriptions.
- GitHub Actions with workload-identity federation.
- Bootstrap permissions for management-group, subscription RBAC, and required directory operations.
- Required Azure resource-provider registrations, quotas, and tenant prerequisites documented in
  [`DEPLOYMENT.md`](DEPLOYMENT.md).

Provider and AVM selections are pinned per composition root, and each deployable root carries a committed
`.terraform.lock.hcl` except the one-time local bootstrap root by design.

## Repository layout

```text
.
|-- bootstrap/                    # One-time local state backend and OIDC bootstrap
|-- platform/
|   |-- management-groups/        # ALZ hierarchy and policy assignments
|   |-- management/               # Logging, FinOps, alerts, AMBA support
|   |-- security/                 # Defender for Cloud and Microsoft Sentinel
|   |-- connectivity/             # Regional hubs, firewalls, DNS and routing
|   `-- identity/                 # Entra DS, Conditional Access and PIM code
|-- landing-zones/
|   |-- corp-a1/                  # Primary corporate spoke
|   |-- corp-a2/                  # DR corporate spoke
|   |-- online-p1/                # WAF-protected online spoke
|   |-- bank-app-p1/              # AKS, ACR, APIM and messaging
|   `-- bank-data-p1/             # Databricks, ADLS, Fabric, Foundry and Search
|-- modules/finops/               # The only local reusable Terraform module
|-- synthetic/                    # Implemented but default-off signal generator
|-- .github/workflows/            # Validate, plan, deploy and teardown automation
|-- scripts/                      # Preflight, claim checks and teardown safeguards
|-- docs/                         # Designs, runbooks, pre-clearance and evidence
|-- demo/                         # Demonstration and acceptance assets
`-- envs/                         # Non-secret environment configuration
```

AVM is consumed directly in composition roots; unused local wrapper scaffolds were deliberately removed
under [ADR-038](DECISIONS.md).

## Deployment

Bootstrap is the only local apply. All platform and workload roots deploy through GitHub Actions.

```powershell
Set-Location bootstrap
terraform init
terraform apply
```

Full-estate applies are intentionally dispatched one root at a time. `target=all` is not a supported apply
path because the state account uses a just-in-time firewall window per runner. The proven high-level order is:

```text
management-groups
  -> management
  -> security
  -> connectivity
  -> five landing-zone spokes
  -> identity pass 1
  -> identity pass 2
  -> bank-app-p1 ACR binding pass
  -> management AMBA pass
  -> management-groups AMBA policy pass
```

Every root is planned, its resource shape is inspected, and only then is it applied. Use
[`docs/2026-07-22-full-estate-rebuild-runbook.md`](docs/2026-07-22-full-estate-rebuild-runbook.md) for the
current 14-step operator procedure and [`DEPLOYMENT.md`](DEPLOYMENT.md) for the supported deployment model.

## Cost posture

The last full deployment was intentionally time-boxed. The dominant cost drivers were the two Azure Firewall
Premium instances and Service Bus Premium. DDoS Network Protection, VPN Gateway, DNS Private Resolver,
Bastion, corporate SQL/App Service tiers, and the synthetic workload were not part of the proven August 1
inventory. Fabric capacity was designed to be suspended outside its validation window.

Cost figures are planning estimates, not invoices. See [`COST.md`](COST.md) for the component-level model,
assumptions, and shutdown levers.

## Teardown

Teardown is a first-class engineering capability, not an afterthought. The `teardown.yml` workflow provides:

- a typed destruction guard and dedicated environment;
- policy disarm before resource deletion;
- Databricks and diagnostic-setting pre-cascade handling;
- serialized reverse-dependency Terraform destroys;
- an Azure API remnant sweep;
- independent verification across subscriptions and management groups; and
- canonical empty-state reset after verified deletion.

Two complete estate teardowns were proven on 2026-08-01, and the shallow post-failure estate teardown was
proven again on 2026-08-03. See [`docs/teardown-redesign.md`](docs/teardown-redesign.md),
[`docs/cicd-deploy-teardown.md`](docs/cicd-deploy-teardown.md), and ADR-054 through ADR-073.

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md): architecture layers, diagrams, RTO/RPO and fidelity.
- [`DEPLOYMENT.md`](DEPLOYMENT.md): deployment prerequisites, ordering and verification.
- [`RUNBOOK.md`](RUNBOOK.md): failover, incident, cost-spike and platform recovery procedures.
- [`SECURITY.md`](SECURITY.md): threat model, Zero Trust mapping and compliance posture.
- [`COST.md`](COST.md): cost model and FinOps levers.
- [`DECISIONS.md`](DECISIONS.md): 74 architectural decision records and amendments.
- [`docs/acceptance-validation.md`](docs/acceptance-validation.md): original Section 12 validation, including failed criteria.
- [`docs/estate-bom.md`](docs/estate-bom.md): live-verified August 1 estate baseline.
- [`docs/advisor-remediation-plan.md`](docs/advisor-remediation-plan.md): post-build hardening findings.

Session worklogs and AI-assistant tooling are kept private. References to them in ADRs, pre-clearance records, and code comments point to records that are not published here.

## Known boundaries

- The five subscriptions are pre-provisioned; this repository does not vend subscriptions.
- All five workload spokes share one Landing Zones subscription, so the subscription is placed under the
  Corp management group. Online is represented as an archetype and network pattern, not a separate subscription.
- Conditional Access policies were proven in report-only mode.
- DDoS Network Protection, private DNS Resolver, VPN Gateway, Bastion, and the synthetic workload are
  implemented or designed as gated capabilities but were absent from the August 1 BOM.
- Customer-managed keys for the banking data tier were designed but not implemented.
- VNet diagnostic settings and several Azure Advisor hardening items remain follow-up work.
- A second full 14-step build has not been recorded since August 1. The last recorded attempt, on 2026-08-09, passed Steps 1-7 and stopped at Step 8.

These boundaries are documented to separate a credible POC from an unsupported production-readiness claim.
