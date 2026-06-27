# Azure Landing Zone POC

> **Status:** 🚧 In progress — See [WORKLOG.md](WORKLOG.md) for current state.

Portfolio-grade Proof of Concept implementing the **Microsoft Cloud Adoption Framework Azure Landing Zone (Hub & Spoke)** architecture using Terraform with Azure Verified Modules (AVM).

---

## Prerequisites

<!-- Populated in Section 11 -->

- Terraform >= 1.9
- Azure CLI >= 2.x
- GitHub Actions with OIDC federated credential (see `bootstrap/`)
- Permissions: Owner on target subscriptions, Global Administrator on tenant (for MG + Entra configuration)

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

<!-- Populated in Section 11 -->

```bash
# 1. Bootstrap remote state and OIDC
cd bootstrap && terraform init && terraform apply

# 2. Deploy platform layer (order matters)
cd platform/management  && terraform init && terraform apply
cd platform/connectivity && terraform init && terraform apply
cd platform/identity    && terraform init && terraform apply
cd platform/security    && terraform init && terraform apply

# 3. Deploy landing zones
cd landing-zones/corp-a1  && terraform init && terraform apply
cd landing-zones/corp-a2  && terraform init && terraform apply
cd landing-zones/online-p1 && terraform init && terraform apply
```

## Cost Estimate

<!-- Populated in Section 11 / COST.md -->

| Component | Monthly (USD) | Notes |
|-----------|--------------|-------|
| Azure Firewall Premium (x2) | ~$900 | Primary + DR hub |
| VPN Gateways (x2) | ~$280 | VpnGw1 active-active primary, standby DR |
| Log Analytics | ~$120 | Platform + Security workspaces |
| Other | TBD | See [COST.md](COST.md) |
| **Estimated total** | **~$1,400–1,800/mo** | Varies by traffic |

> Run `terraform destroy` and `enable_synthetic_workload=false` when not actively demoing to minimise cost.

## Teardown

```bash
# Disable synthetic workload first (fast, <5 min)
terraform apply -var='enable_synthetic_workload=false'

# Then destroy all landing zones before platform
cd landing-zones/corp-a1 && terraform destroy
# ... repeat per landing zone ...

# Then destroy platform in reverse dependency order
cd platform/security    && terraform destroy
cd platform/identity    && terraform destroy
cd platform/connectivity && terraform destroy
cd platform/management  && terraform destroy
cd bootstrap            && terraform destroy
```

---

## Further Reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — Mermaid diagrams, RTO/RPO, decisions
- [SECURITY.md](SECURITY.md) — Threat model, Zero Trust mapping, compliance posture
- [RUNBOOK.md](RUNBOOK.md) — Failover drill, incident triage, cost spike response
- [COST.md](COST.md) — Per-component cost breakdown and FinOps levers
- [DECISIONS.md](DECISIONS.md) — Architectural decision records
- [landing-zone-kit/](landing-zone-kit/README.md) — reusable LZ build kit: live-apply lessons, decision framework, role process
