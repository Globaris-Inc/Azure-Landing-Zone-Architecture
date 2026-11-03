# Cost Model and FinOps Controls

This document explains the cost shape of the architecture proven on 2026-08-01, the current greenfield cost
posture, and the controls used to avoid accidental POC spend. Values are planning ranges, not an invoice or a
current Azure quote.

## 1. Read this first

- The managed estate is currently greenfield after the 2026-08-03 teardown. Only the protected bootstrap
  backend remains, so the full-estate monthly range is not the current run rate.
- The last complete estate existed for validation and was time-boxed.
- Azure pricing varies by region, agreement, currency, data volume, operations, egress, reservations and
  feature configuration.
- The estimates below use the project's July/August 2026 planning assumptions and the exact August 1 BOM.
- Re-price through the Azure Pricing Calculator before funding a new deployment.

## 2. Cost states

| State | Cost interpretation |
| --- | --- |
| Current greenfield | Protected bootstrap Key Vault, key, Storage Account, state blobs, identity and alerting only. No full-estate estimate is claimed. |
| Proven August 1 estate | Planning envelope approximately **$4,500-$6,200/month** if left running for a full month at the validated POC scale. |
| Production target | Not estimated as one number. Multi-region banking, full Defender coverage, DDoS, CMK, higher availability, backups, ingestion and traffic require workload measurements and business RTO/RPO. |

The full-estate range is consistent with the pre-build banking design. It has not been reconciled to a full
month of invoice data because the estate was torn down after validation.

## 3. Proven estate cost model

| Component | Proven shape | Planning range/month | Confidence and driver |
| --- | --- | ---: | --- |
| Azure Firewall Premium | 2 instances, zone-redundant | $2,500-$3,000 | High confidence that this dominates fixed cost; data processing adds usage cost. |
| Service Bus Premium | 1 namespace, 1 messaging unit | $650-$750 | High fixed-cost component selected because private endpoints require Premium. |
| AKS compute | 3 `D2s_v4` system nodes | $250-$450 | VM/disk/uptime dependent; control-plane cost depends on tier. |
| Application Gateway WAF_v2 | 1 gateway/capacity unit | $250-$400 | Fixed gateway plus capacity/data processing. |
| Microsoft Fabric | F2 capacity | $250-$350 while active | Pausable; should be suspended outside validation windows. |
| Entra Domain Services | Standard | $100-$150 | Managed identity platform fixed cost. |
| APIM | Developer tier, single region | $50-$100 | POC tier; production Premium/multi-region changes the order of magnitude. |
| ACR | Premium | $45-$75 | Premium chosen for private-link capability. |
| Event Hubs | Standard, 1 throughput unit | $25-$75 | Throughput/capture/retention dependent. |
| AI Search | Basic | $70-$110 | Fixed service tier; capacity/replicas change cost. |
| Databricks | Premium workspace, no clusters/jobs | $0-$100 platform idle/limited validation | DBUs and VM compute dominate when clusters or warehouses run. |
| ADLS Gen2 | ZRS account, private endpoints | $20-$100 | Capacity, transactions, redundancy and PE hours/data. |
| Foundry/model usage | AIServices account and small model deployment | $20-$150 | Token/request consumption; no PTU reservation. |
| Log Analytics and Sentinel data | 2 workspaces, 90-day retention | $100-$600 | Ingestion/retention is usage-driven; Sentinel service cost follows eligible data tiers. |
| Defender for Cloud | 11 Standard plans in Security subscription | $100-$700 | Resource-count and plan dependent; extending to all subscriptions is a separate cost decision. |
| Private endpoints | Approximately 8 service paths in the BOM | $50-$100 plus data | Per-endpoint hours and processed data. |
| Storage, DNS, Public IPs, RSVs, flow logs | 89 private DNS zones, multiple storage accounts, vaults and IPs | $100-$350 | Operations, stored data, retention and backup instances. |
| Static Web App and supporting low-cost resources | POC scale | $0-$50 | Tier/traffic dependent. |

Ranges overlap and are not additive with accounting precision; the **$4,500-$6,200** envelope is the governing
planning estimate. The table explains its shape.

## 4. Cost excluded from the proven August 1 BOM

| Capability | Status | Historical planning impact |
| --- | --- | --- |
| DDoS Network Protection | Off/absent | Approximately $2,944/month avoided in the project's planning model. |
| VPN Gateway | Off/absent | Fixed gateway and public-IP cost avoided. |
| DNS Private Resolver | Off/absent | Endpoint-hour cost avoided. |
| Azure Bastion | Off/absent | On-demand capability not kept running. |
| Corporate App Service and SQL | Gated off | Subscription offer caps prevented deployment. |
| Synthetic workload/signal generator | Off | No demo load or cost-pattern resources. |
| Databricks clusters/jobs/warehouses | Not created | Avoided DBU and VM compute spend. |
| Fabric artifacts/workloads | Not created | Capacity only; no in-Fabric platform build. |
| Multi-region banking services | Design-only | Avoided duplicate AKS/APIM/messaging/data/AI service cost. |
| Banking data-tier CMK | Designed, not implemented | Key Vault/key/identity/transaction costs not included. |
| Full Defender coverage across all 5 subscriptions | Not implemented | Cost-bearing expansion requires explicit decision. |

## 5. Cost allocation and governance

### 5.1 Budgets

The environment configuration defines:

- $200 monthly budget per subscription across five subscriptions;
- $600 management-group budget; and
- alerts at 50, 75, 90 and 100 percent.

Budgets are alerts, not hard spending caps. They will not stop a firewall, messaging unit or capacity.

The Azure Consumption API requires the monthly budget/export start date to be in the current month. This
caused a real Step 2 rebuild failure when the calendar rolled from July to August. The durable control is a
preflight property check; a comment reminding an operator is not sufficient.

### 5.2 Tags and ownership

Management-group policy applies/assesses common tags such as environment, workload, owner, cost center and
managed-by. Azure Policy also injects a `CreatedDate` tag, which creates accepted Terraform cosmetic drift
because policy adds the tag and Terraform removes it from its desired tag set.

Cost analysis should start at:

1. subscription;
2. resource group;
3. service/meter;
4. region;
5. workload/owner/cost-center tag; and
6. daily change versus the deployment calendar.

### 5.3 Exports and anomaly monitoring

The Management root includes cost exports, anomaly-notification plumbing, budgets and FinOps workbooks. These
improve visibility but were not validated against a full billing month. The carbon-optimization workbook must
not be treated as production reporting without content and data-source verification.

## 6. Cost-control levers

### 6.1 Fastest safe levers

1. Suspend Fabric F2 after validation.
2. Stop AKS when no workload test is running.
3. Keep Databricks free of running clusters/jobs unless a test requires them.
4. Disable or destroy unused workload gates through their Terraform root.
5. Control Log Analytics retention and ingestion with security/compliance approval.
6. Run the full verified teardown when the POC window ends.

### 6.2 High-impact architectural levers

- **Firewalls:** biggest fixed cost. Removing them requires stopping or redesigning dependent AKS/APIM/
  Databricks routes and applying connectivity; never delete while spokes route to `10.0.0.4`/`10.1.0.4`.
- **Service Bus:** Premium was selected for private endpoints. Standard is cheaper but changes network and
  policy posture; it is an architectural tradeoff, not a right-size setting.
- **Fabric:** suspend when idle; do not provision a larger SKU without measured CU demand.
- **Defender:** decide coverage by subscription/resource type and quantify the security benefit/cost before
  extending the 11-plan set.
- **Multi-region:** production resilience duplicates service capacity and data transfer. Fund it from business
  RTO/RPO, not from an unqualified “must be highly available” statement.

### 6.3 Rightsizing sequence

1. Remove idle resources.
2. Stop/suspend pausable compute.
3. Right-size SKUs and node counts from metrics.
4. Reduce unnecessary data retention/ingestion.
5. Use schedules/autoscale where the service and workload support them.
6. Evaluate reservations/savings plans only after a stable utilization baseline.
7. Revisit architecture choices such as Premium/private-link and multi-region with risk owners.

## 7. Cost-performance-security tradeoffs demonstrated

| Decision | Cost result | Security/performance result |
| --- | --- | --- |
| Premium Service Bus | Higher fixed cost | Enabled private endpoint and local-auth-disabled posture. |
| Two Firewall Premium instances | Largest fixed cost | Regional forced routing, policy and IDPS capability. |
| DDoS plan off | Avoided major idle cost | Accepted reliance on DDoS Basic/WAF/firewall for POC. |
| Single Landing Zones subscription | Lower subscription/operational overhead | Online and Corp cannot receive distinct subscription placement. |
| Single-region banking POC | Avoided duplicate platform cost | Does not meet production regional availability objectives. |
| Report-only Conditional Access | No direct Azure resource savings | Reduced lockout risk during rollout but did not enforce access controls. |
| Fabric F2 with suspension | Demonstrates platform at small scale | Requires operational discipline to avoid idle capacity cost. |
| Databricks without clusters/jobs | Proves workspace/network architecture cheaply | Does not demonstrate data processing performance or governance. |

## 8. Cost review checklist

Before deployment:

- re-price every fixed-cost Premium service;
- confirm flags and region/SKU values;
- confirm `budget_start_date` is current;
- set real notification recipients through secrets;
- define the validation window and teardown owner;
- record expected daily burn and the stop/suspend schedule; and
- obtain approval for any new Defender, DDoS, multi-region or reserved capacity.

During deployment:

- compare actual resource creation to the plan bars and BOM;
- watch Firewall, Service Bus, Fabric, AKS, APIM, Search and Log Analytics first;
- suspend Fabric and stop idle compute promptly; and
- investigate duplicates or unexpected region placement.

After teardown:

- verify resources and soft-deleted billable objects are gone;
- confirm Fabric/AKS/Databricks are not still consuming capacity;
- validate the next Cost Management export/invoice; and
- compare actual cost against the deployment timeline and update this model.

## 9. Pricing references

Re-price using official sources:

- [Azure Pricing Calculator](https://azure.microsoft.com/en-us/pricing/calculator/)
- [Azure Firewall pricing](https://azure.microsoft.com/en-us/pricing/details/azure-firewall/)
- [Service Bus pricing](https://azure.microsoft.com/en-us/pricing/details/service-bus/)
- [API Management pricing](https://azure.microsoft.com/en-us/pricing/details/api-management/)
- [Microsoft Fabric pricing](https://azure.microsoft.com/en-us/pricing/details/microsoft-fabric/)
- [Azure Kubernetes Service pricing](https://azure.microsoft.com/en-us/pricing/details/kubernetes-service/)
- [Azure AI Search pricing](https://azure.microsoft.com/en-us/pricing/details/search/)
- [Microsoft Defender for Cloud pricing](https://azure.microsoft.com/en-us/pricing/details/defender-for-cloud/)
- [Azure Monitor pricing](https://azure.microsoft.com/en-us/pricing/details/monitor/)

## 10. Evidence and decisions

- [`docs/estate-bom.md`](docs/estate-bom.md): exact resource shape used for this model.
- [`docs/banking-platform-design.md`](docs/banking-platform-design.md): original banking cost envelope.
- [`docs/advisor-remediation-plan.md`](docs/advisor-remediation-plan.md): cost-bearing hardening decisions.
- [`RUNBOOK.md`](RUNBOOK.md): cost-spike response.
- ADR-013, ADR-042, ADR-044-053, ADR-060 and ADR-069 in [`DECISIONS.md`](DECISIONS.md).
