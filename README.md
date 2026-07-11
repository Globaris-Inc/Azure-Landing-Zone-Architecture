# Azure Landing Zone POC

> **Status:** 🚧 In progress - See [WORKLOG.md](WORKLOG.md) for current state.

Portfolio-grade Proof of Concept implementing the **Microsoft Cloud Adoption Framework Azure Landing Zone (Hub & Spoke)** architecture using Terraform with Azure Verified Modules (AVM).

---

## Prerequisites

- Terraform **1.15.6** (pinned in CI) + Azure CLI >= 2.x
- **5 Azure subscriptions** (management, connectivity, identity, security, landing zones) in one Entra tenant
- GitHub Actions with **OIDC** federated credentials - no stored client secrets (see [`bootstrap/`](bootstrap/))
- Permissions to run bootstrap: **Global Administrator** on the tenant (MG + Entra) with elevated access; the CI
  service principal then runs on the scoped role matrix in [ADR-021](DECISIONS.md)
- Full prerequisite list (Variables/Secrets, Environments, Entra DS pre-step) is in [DEPLOYMENT.md](DEPLOYMENT.md)

## Repository Layout

```
.
├── bootstrap/               # OIDC service principal, remote state backend, MG seeding
├── modules/                 # Reusable local Terraform modules
│   ├── management-groups/
│   ├── policy-baseline/
│   ├── hub-network/
│   ├── spoke-network/
│   ├── private-dns/
│   ├── monitoring/
│   ├── security-sentinel/
│   ├── identity/
│   ├── finops/
│   └── synthetic-workload/
├── platform/                # Root module deployments per platform subscription
│   ├── connectivity/
│   ├── identity/
│   ├── management/
│   └── security/
├── landing-zones/           # Landing zone spoke deployments
│   ├── corp-a1/             # Primary region, private workloads
│   ├── corp-a2/             # DR region, geo-paired to corp-a1
│   └── online-p1/           # Internet-facing, WAF-protected
├── synthetic/               # Synthetic workload + security signal generators
├── demo/                    # Demo orchestration scripts and walkthrough
├── envs/                    # Environment-specific tfvars and backend config
├── policies/                # OPA/Conftest policy files for PR gates
└── .github/workflows/       # CI/CD pipelines
```

## Quick Deploy

**Bootstrap is the only local step; every other root deploys via CI** (GitHub Actions, OIDC, gated). Full
ordered runbook with per-step validation and the Secrets each root needs: **[DEPLOYMENT.md](DEPLOYMENT.md)**.

```bash
# 1. Bootstrap remote state + OIDC (local, one-time) - creates the backend the CI needs
cd bootstrap && terraform init && terraform apply
```

Then set the GitHub Variables/Secrets and Environments, and deploy each root via the
`Deploy (manual)` workflow ([`deploy.yml`](.github/workflows/deploy.yml)) - `action=plan`, then `action=apply`
(gated by the `production` environment) - in dependency order:

```
management-groups -> management -> {connectivity, security, identity} -> spokes (corp-a1, corp-a2, online-p1)
```

`target=all` runs the whole graph in order once the cross-root output Secrets exist. The `synthetic` root is
**deferred** and not deployed (ADR-036 / ADR-037). See [DEPLOYMENT.md](DEPLOYMENT.md) for the exact procedure and
[`docs/cicd-deploy-teardown.md`](docs/cicd-deploy-teardown.md) for pipeline mechanics.

## Cost Estimate

As deployed and gated today (DDoS off, corp App Service + SQL gated, Bastion on-demand, synthetic deferred), the
estate is estimated at **~$3,600 to $4,800 per month** (list prices, POC scale, not billed actuals). The two
**Azure Firewall Premium** instances (~$2,555/mo fixed, ~55-65% of the bill) plus the **Defender for Cloud**
plans are the dominant levers.

| Component | Monthly (USD) | Notes |
|-----------|--------------|-------|
| Azure Firewall Premium (x2) | ~$2,555 | Primary + DR hub, fixed hourly (biggest line) |
| VPN Gateway (VpnGw1AZ, primary only) | ~$260 | DR hub transits via peering (no 2nd gateway) |
| DNS Private Resolver + App Gateway WAF_v2 | ~$695 | inbound/outbound endpoints + WAF cap 1 |
| Log Analytics x2 + Defender for Cloud plans | ~$135 - $400 | scales with traffic + resource count |
| Entra DS, Event Hub, RSVs, Static Web App, DNS zones, storage, IPs | ~$220 | per COST.md |
| **Estimated total** | **~$3,600 - $4,800/mo** | Varies by traffic; full breakdown in [COST.md](COST.md) |

> Biggest saving already applied: DDoS off (~$2,944/mo avoided). Run teardown (`teardown.yml`) and keep
> `enable_synthetic_workload=false` / Bastion off when not demoing. See [COST.md](COST.md) for FinOps levers.

## Teardown

Teardown is **CI-driven** via the `teardown.yml` workflow (uniform `terraform destroy` in reverse dependency
order, `production-destroy` gate + typed `confirm=destroy`, ADR-020). `include_bootstrap` defaults to **false**
(keeps the state backend + OIDC so redeploy is immediate); set `true` only for full decommission. Single-root
teardown (`target=<one root>`) is the cheap "cut cost on one spoke" path.

Full procedure and the scorched-earth fallback: [`docs/cicd-deploy-teardown.md`](docs/cicd-deploy-teardown.md)
§5-§6 and [DEPLOYMENT.md](DEPLOYMENT.md) §6.

---

## Further Reading

- [DEPLOYMENT.md](DEPLOYMENT.md) - greenfield end-to-end deploy runbook (ordered, per-root, with validation)
- [ARCHITECTURE.md](ARCHITECTURE.md) - Mermaid diagrams, RTO/RPO, decisions, ALZ fidelity map
- [COST.md](COST.md) - per-component monthly estimate and FinOps levers
- [SECURITY.md](SECURITY.md) - threat model, Zero Trust mapping, compliance posture
- [RUNBOOK.md](RUNBOOK.md) - failover drill, incident triage, cost spike response
- [DECISIONS.md](DECISIONS.md) - architectural decision records
- [`docs/cicd-deploy-teardown.md`](docs/cicd-deploy-teardown.md) - CI/CD deploy + teardown pipeline reference
- [`docs/operations-monitoring-design.md`](docs/operations-monitoring-design.md) - Day-2 Operations and Monitoring target architecture (ADR-037)
- [landing-zone-kit/](landing-zone-kit/README.md) - reusable LZ build kit: live-apply lessons, decision framework, role process
