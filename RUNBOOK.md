# Operational Runbook

This runbook covers the operational scenarios required by Section 11: regional failover assessment, incident
triage, and cost-spike response. It also captures the apply/recovery and teardown procedures that were exercised
during the build.

The managed estate is currently greenfield after the verified 2026-08-03 teardown. Procedures that require a
live estate are ready for the next deployment; they are not evidence that resources are currently running.

## 1. Operating model

### 1.1 Sources of truth

Use these in order:

1. [`README.md`](README.md) for current state.
2. [`docs/2026-07-22-full-estate-rebuild-runbook.md`](docs/2026-07-22-full-estate-rebuild-runbook.md) for full rebuild commands and gates.
3. [`docs/estate-bom.md`](docs/estate-bom.md) for the expected live inventory.
4. GitHub Actions run logs for plan/apply/destroy evidence.
5. Direct Azure API/portal checks for live state.
6. Terraform state as an ownership record, not as proof that Azure contains or does not contain an object.

### 1.2 Severity model

| Severity | Definition | Initial response |
| --- | --- | --- |
| Sev 0 | Tenant-wide security compromise, destructive automation, or unrecoverable control-plane impact | Stop all changes, revoke/disable automation identity as appropriate, activate leadership/security response. |
| Sev 1 | Multi-subscription outage, regional platform failure, state corruption, or active high-confidence compromise | Freeze applies, establish incident command, contain, preserve evidence, update stakeholders. |
| Sev 2 | Single platform/workload outage, failed deployment with material partial state, or major cost anomaly | Stop dependent work, assign owner, diagnose with live evidence, publish recovery plan. |
| Sev 3 | Degraded performance, non-blocking policy/monitoring failure, or low-confidence alert | Triage in normal operations window; track remediation. |
| Sev 4 | Documentation, cosmetic drift, or accepted advisory | Backlog with owner and review date. |

### 1.3 First five minutes of any incident

1. Record UTC start time, reporter, affected subscription/root, and the last known good commit/run.
2. Stop new applies and overlapping deployment/teardown runs.
3. Determine whether the issue is Azure service health, identity/authentication, network, policy, quota,
   application, Terraform state, or cost.
4. Preserve logs and the exact error before retrying or changing anything.
5. Decide whether containment is safer than continued availability.
6. Name an incident owner and a communications owner for Sev 0-2.

## 2. Regional failure and failover assessment

### 2.1 What the POC can and cannot fail over

Central US is primary and East US 2 is secondary/DR.

| Capability | Available in secondary | Failover reality |
| --- | --- | --- |
| Hub network | Secondary VNet and Firewall Premium | Regional network path exists and was live-verified. |
| Corporate network | `corp-a2` VNet and GRS Recovery Services vault | Cold network/backup pattern; no replicated application was proven. |
| Corporate SQL/App Service | No | Those tiers were gated off; there is nothing to fail over. |
| Online workload | No secondary Application Gateway/Static Web App root | No regional application failover. |
| Banking AKS/APIM/messaging | No secondary platform instances | Single-region POC; production DR is design-only. |
| Banking data/AI | No secondary service instances | ZRS protects within region; it is not regional DR. |
| Private DNS | Central zones linked across estate VNets | Zone data is global, but service endpoints still depend on target resources. |

Do not call this “active-active application DR.” The proven result is dual-region network topology and a
recovery foundation.

### 2.2 Failover decision process

1. **Confirm the event.** Check Azure Service Health, Resource Health, AMBA alerts, and the platform/security
   workspaces. Distinguish a regional outage from a single resource, identity, or routing defect.
2. **Freeze platform changes.** Do not run a connectivity apply during an unconfirmed regional incident.
3. **Assess primary dependencies.** Check the Central US hub firewall, peerings, route tables, AKS, APIM,
   messaging, Databricks, Foundry, Search, and platform Log Analytics.
4. **Validate the secondary foundation.** Confirm the East US 2 hub firewall is `Succeeded`, peering is
   `Connected`, `corp-a2` routes to `10.1.0.4`, and its vault is accessible.
5. **Classify recoverability.** For network-only workloads, recovery may mean deploying a replacement workload
   into `corp-a2`. For banking platforms, invoke the production DR design process; the POC has no automatic
   replica to promote.
6. **Make the business decision.** Compare expected primary recovery time with the time and data risk of
   building/restoring in East US 2.
7. **Communicate the limitation.** State which service is restored, reconstructed, degraded, or unavailable.

### 2.3 Corporate recovery drill

This drill validates the foundation without claiming data/application failover:

1. Confirm both regional hub/firewall resources are healthy.
2. Confirm hub-to-hub and hub-to-spoke peerings are `Connected`.
3. Confirm `corp-a2` has a `0.0.0.0/0` route to `10.1.0.4`.
4. Confirm the private DNS zones are linked to the secondary hub and `corp-a2` VNet.
5. Confirm the `corp-a2` Recovery Services vault is GeoRedundant with cross-region restore enabled.
6. Deploy a disposable test workload only through an approved Terraform change, then validate DNS and egress.
7. Remove the test through Terraform and record timing, failures, and evidence.

Target for the network/recovery foundation: 30 minutes to validate the secondary path. Workload RTO/RPO is not
measurable until a real protected workload and restore procedure exist.

### 2.4 Failback

1. Confirm Azure Service Health and all Central US platform dependencies are stable.
2. Plan the primary root and inspect for drift; do not apply merely to “make it healthy.”
3. Reconcile any data created in the recovery environment through an application-owned process.
4. Restore traffic only after health, security, data consistency, and monitoring checks pass.
5. Remove temporary recovery resources through Terraform.
6. Write a post-incident report with actual RTO/RPO and architecture follow-ups.

## 3. Security incident triage

### 3.1 Sentinel incident

1. Open the incident in the Security subscription's Microsoft Sentinel workspace.
2. Record alert name, severity, entities, tactics/techniques, creation time, and source connector.
3. Verify the data source is live. A scheduled rule can exist even when its tenant connector is gated.
4. Pivot to related identity, Azure Activity, resource, firewall, WAF, and Defender events.
5. Establish whether the event is true positive, benign positive, expected test, or insufficient data.
6. Contain using the owning service's procedure; no generic Logic App playbook was proven in this POC.
7. Preserve evidence before deleting/rebuilding resources.
8. Close with classification, impacted resources, actions, and a detection/control improvement.

Useful starting queries:

```kusto
SecurityAlert
| where TimeGenerated > ago(24h)
| summarize Alerts = count() by AlertSeverity, AlertName
| order by Alerts desc
```

```kusto
AzureActivity
| where TimeGenerated > ago(4h)
| where ActivityStatusValue !in ("Success", "Succeeded")
| project TimeGenerated, SubscriptionId, ResourceGroup, OperationNameValue,
          ActivityStatusValue, Caller, CorrelationId
| order by TimeGenerated desc
```

Use `SigninLogs` only after confirming the Entra connector/diagnostic source is enabled for the current
deployment.

### 3.2 Defender for Cloud alert

1. Confirm the affected subscription. The proven Standard plan set was limited to the Security subscription.
2. Open the recommendation/alert and record the plan, resource, attack path, severity, and evidence.
3. Validate the resource still exists and is in Terraform state.
4. Determine whether the control is preventive, detective, or an Advisor recommendation.
5. Contain the resource without bypassing Terraform ownership unless active compromise requires emergency
   action. If emergency portal action is taken, record it and reconcile in code afterward.
6. Re-query the alert and secure-score state after the documented convergence period.

### 3.3 Identity compromise

1. Disable or revoke the affected user/service principal session as appropriate.
2. For CI identity compromise, pause workflows and remove/disable federated credentials before changing Azure
   resources.
3. Enumerate role assignments at Tenant Root, `globaris`, platform child groups, and subscriptions.
4. Compare to ADR-021 and the live drift register; pay special attention to Owner/User Access Administrator.
5. Review GitHub workflow runs, commits, environment jobs, Azure Activity and directory audit events.
6. Rotate or replace any non-OIDC secrets exposed through workload configuration.
7. Restore the minimum role set and re-enable automation only after a clean plan and independent review.

## 4. Platform and workload triage

### 4.1 Network path failure

Check in this order:

1. Service Health and regional network status.
2. Hub and spoke peering state.
3. Spoke route table and expected next hop (`10.0.0.4` primary or `10.1.0.4` secondary).
4. Firewall provisioning state, policy, rule collection group, and diagnostics.
5. NSG effective rules.
6. Private DNS zone link and A record.
7. Private endpoint connection approval/state.
8. Target service network/public-access configuration.

Do not “fix” a blackholed route by deleting the UDR. The route/firewall pair is one architectural unit and
must change through Terraform with dependent services assessed.

### 4.2 AKS unavailable

1. Confirm the cluster and node resource group exist and the control plane reports `Succeeded`.
2. Check private API DNS resolution from the intended network.
3. Confirm firewall egress rules required for AKS bootstrap are live.
4. Confirm the three-node system pool and VMSS power/provisioning state.
5. Check identity, ACR private endpoint/DNS, and the kubelet `AcrPull` assignment.
6. Review Container Insights only after verifying its diagnostic/agent configuration.
7. Stop before recreating the cluster; unexpected replacement is a plan-scan stop condition.

### 4.3 APIM unavailable or unhealthy

1. Check APIM provisioning and dependency-network status.
2. Validate its subnet, route table, service endpoints and firewall egress rule collection group.
3. Confirm private DNS for the scoped gateway name.
4. Do not cancel a long create before the provider timeout; an interrupted APIM create can leave a soft-deleted
   instance that blocks the same name in the next rebuild.
5. Purge a soft-deleted instance only through the documented preflight procedure.

### 4.4 Data/AI platform failure

1. Validate private endpoint status and both private DNS resolution and service health.
2. For Databricks, distinguish workspace control plane, managed resource group, network intent policies, and
   compute (the POC did not create clusters/jobs).
3. For ADLS, validate blob and dfs endpoints separately.
4. For Foundry/Search, confirm public access remains disabled and the request originates on an approved path.
5. For Fabric, determine whether capacity is intentionally suspended before treating it as an outage.

## 5. Failed Terraform apply and state recovery

### 5.1 Classification

| Failure class | Response |
| --- | --- |
| Authentication/authorization | Verify OIDC token refresh, ARM role, and Entra directory role. Do not retry until the missing boundary is identified. |
| Policy Deny | Read the exact assignment and parameter; decide whether the resource is wrong or a scoped exemption is justified. |
| Quota/offer cap | Do not loop retries. Gate, resize, move region/subscription, or obtain quota. |
| `already exists`/import message on greenfield | Treat as soft-delete, orphan extension, or state/ownership failure; follow the class-specific runbook. |
| Unexpected replacement/destroy | Stop; classify every instance before apply. |
| State lock | Use the workflow's single-root `force-unlock` action after proving no writer is active. |
| Long-running managed service | Allow its documented timeout; cancellation can make cleanup harder. |

### 5.2 Current Sentinel 401 case

The second rebuild attempt reached Step 3 and nine Sentinel scheduled-rule writes returned 401. Six hypotheses
were disproved. The remaining check is whether the CI service principal still has Security Administrator in
Entra. Do not restart from Step 1 before completing that read.

### 5.3 Full restart rule

The current rebuild policy is: a failed full-estate attempt is torn down to independently verified greenfield,
the cause is corrected, and the build restarts at Step 1. This prevents partially adopted state and hidden
greenfield regressions. The policy is expensive late in a build, so preflight and plan-shape gates are the
primary prevention mechanism.

## 6. Cost-spike response

### 6.1 Signals

- Five subscription budgets at $200 each.
- Management-group budget at $600.
- Alerts at 50, 75, 90 and 100 percent.
- Cost exports, anomaly-notification plumbing and ownership/cost tags.
- Azure Cost Management, Advisor and billing exports as independent views.

### 6.2 Response procedure

1. Validate that the alert is current and identify subscription, resource group, meter, region and day-over-day
   change.
2. Compare against planned time-boxed resources: two Firewall Premium instances, Service Bus Premium, Fabric
   F2, AKS nodes, APIM, Search, private endpoints and Log Analytics ingestion.
3. Attribute using `Workload`, `Owner`, `CostCenter`, environment and resource-group boundaries.
4. Check whether the spike is usage, an accidentally unsuspended service, a duplicate resource, data
   ingestion, or a pricing/tier change.
5. Select the least disruptive lever and record expected savings.
6. Make the change through the owning root/workflow and validate both cost posture and architecture afterward.

### 6.3 Containment levers

Use roughly this order:

1. Suspend Fabric F2 when validation is complete.
2. Stop AKS when no workload test is running.
3. Remove/disable unused banking platform gates through a reviewed plan.
4. Reduce avoidable Log Analytics ingestion/retention only after security and compliance owners approve.
5. Remove paid firewalls only as an architecture change: stop dependent AKS/APIM/Databricks paths and reconcile
   routing/rules first. Never delete a firewall while spokes still route to its private IP.
6. Run the verified full teardown when the POC window ends.

Do not enable DDoS Network Protection, a VPN Gateway, DNS Resolver, or Bastion as an incident reaction; those
are additive cost decisions.

### 6.4 After-action review

Record:

- root cause and avoidability;
- actual daily/monthly impact;
- which alert fired and at what threshold;
- time to ownership and containment;
- lasting configuration/control change; and
- whether budgets/forecasts need recalibration.

## 7. Teardown and decommissioning

Use `teardown.yml`. A full teardown contains policy disarm, Databricks/diagnostic pre-cascade, serialized root
destroys, attachment cleanup, Azure remnant sweep, independent verification and state reset.

Completion is not “Terraform destroy exited zero.” It is:

- zero managed resource groups across all five subscriptions;
- zero relevant soft-deleted workspaces;
- only intended management groups remain;
- zero subscription/MG extension objects in scope;
- protected bootstrap resources remain unless final decommission was requested; and
- eligible state blobs are canonical-empty.

The 2026-08-03 teardown proved this state with zero managed RGs, zero soft-deleted Log Analytics workspaces,
Tenant Root only, and 11 canonical-empty state blobs.

## 8. Incident record template

```text
Incident:
UTC start/end:
Severity:
Owner / communications owner:
Affected subscriptions, roots and services:
Last known good commit and workflow run:
Customer/business impact:
Detection source:
Immediate containment:
Evidence collected:
Root cause:
Recovery steps and validation:
Actual RTO/RPO:
Security/compliance impact:
Cost impact:
Follow-up owner and due date:
ADR/OQ/runbook changes required:
```

## 9. References

- [`ARCHITECTURE.md`](ARCHITECTURE.md)
- [`SECURITY.md`](SECURITY.md)
- [`COST.md`](COST.md)
- [`DEPLOYMENT.md`](DEPLOYMENT.md)
- [`docs/estate-bom.md`](docs/estate-bom.md)
- [`docs/teardown-redesign.md`](docs/teardown-redesign.md)
- [`docs/advisor-remediation-plan.md`](docs/advisor-remediation-plan.md)
