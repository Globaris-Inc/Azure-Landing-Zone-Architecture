# Resource-Type Lifecycle / Deprecation-and-Retirement Audit

> **Status:** Architect-owned pre-clearance evidence (proactive sweep).
> **Owner:** Cloud Solutions Architect.
> **Scope:** Every not-yet-fully-deployed root, plus a spot-check of the three deployed platform roots.
> **azurerm pin at time of audit:** `~> 4.71.0`.
> **Date:** 2026-07-10.

---

## 0. Why this document exists

A RETIRED Azure feature reached apply-time before any gate caught it. `azurerm_network_watcher_flow_log`
with an NSG target (`network_security_group_id`) can no longer be created for new NSGs (Microsoft blocked
creation on 2025-06-30; full retirement 2027-09-30). None of the three existing pre-clearance parts (live
policy enumeration, tenant prerequisites, known-issues harvest) audit for cloud-provider **resource-type
lifecycle**. This sweep closes that gap by enumerating every distinct Azure resource type each root creates
and classifying its lifecycle status against authoritative sources.

This audit is now a **required pre-clearance step** (see `docs/deploy-preclearance.md` section 3(d)). Every
per-root pre-clearance file, existing and future, must carry a lifecycle-audit section.

### Classification legend

| Status | Meaning |
|--------|---------|
| CURRENT | Fully supported, no announced end date. |
| DEPRECATED | Still creatable, discouraged, successor exists. Plan a migration, not a blocker. |
| RETIRING | Announced end date, still creatable until then. Track the date. |
| RETIRED | Creation blocked by Azure. Hard blocker for a first apply. |

### Sources used

- Azure retirements feed and updates: `https://azure.microsoft.com/en-us/updates`.
- Learn migration/retirement docs (per item, linked in the Evidence column).
- `hashicorp/terraform-provider-azurerm` resource docs pinned at `v4.71.0`.

---

## 1. Critical findings (read first)

1. **RETIRED - the only hard blocker: NSG-targeted flow logs.** `azurerm_network_watcher_flow_log` with
   `network_security_group_id` is present in **all three** landing-zone roots. `corp-a1` and `corp-a2`
   have one each; **`online-p1` has two** (appgw NSG + workload NSG). Creation of new NSG flow logs was
   blocked by Azure on 2025-06-30. These roots cannot apply as written. Disposition: migrate to VNet flow
   logs (section 3).
2. **No second RETIRED type was found.** Every other type these roots create is CURRENT or DEPRECATED.
   Notably, the common landmines were checked and are clean: **no Basic-SKU public IPs** (online-p1 uses
   Standard, zonal), **no App Gateway v1** (online-p1 uses WAF_v2), **no classic Application Insights**
   (only workbooks), **no MMA / Log Analytics agent VM extension**, **no Automation Run As accounts**
   (System-Assigned MI), and the synthetic VM is **Ubuntu 24.04 LTS**, not a retired 18.04 image.
3. **RETIRING (watch, not a blocker): Microsoft Sentinel in the Azure portal retires 2027-03-31**
   (consolidates into the Defender portal). This is a platform-experience retirement, not a resource-create
   block. The subscription-based Defender for Cloud Sentinel connector is now **Legacy / DEPRECATED**
   (tenant-based connector recommended). Both affect `platform/security`. Acceptable for the POC; noted for
   the migration backlog.

**Bottom line: one RETIRED type (NSG flow logs), contained entirely in the three landing-zone roots. Fix it
before those roots apply. Nothing else blocks a first apply.**

---

## 2. Per-root audit tables

Types are ranked RETIRED first, then RETIRING/DEPRECATED, then CURRENT. Non-Azure helper resources
(`random_*`, `time_sleep`, `null_resource`, `tls_private_key`) are omitted (no Azure lifecycle).

### 2.1 landing-zones/corp-a1 and landing-zones/corp-a2 (identical type sets)

| Resource type | Status | Evidence | Disposition |
|---------------|--------|----------|-------------|
| `azurerm_network_watcher_flow_log` (NSG target) | **RETIRED** | learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate (create blocked 2025-06-30; retire 2027-09-30); provider v4.71.0 doc notes NSG flow-log creation is no longer possible | **MIGRATE to VNet flow log** (`target_resource_id` = spoke VNet id). See section 3. BLOCKER for apply. |
| `azurerm_storage_account` (flow-log sink, Standard LRS, `min_tls_version = TLS1_2`) | CURRENT | learn.microsoft.com/azure/storage - TLS 1.0/1.1 retired, 1.2 is the floor and is set | No action. |
| `azurerm_mssql_server` / `azurerm_mssql_database` | CURRENT | registry.terraform.io azurerm v4.71.0 docs; Azure SQL TLS 1.0/1.1 disablement handled by min TLS setting | No action. Ensure `minimum_tls_version` stays >= 1.2. |
| `azurerm_private_endpoint` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_private_dns_zone_virtual_network_link` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_network_security_group` / `azurerm_route_table` / `azurerm_virtual_network_peering` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_resource_group` / `azurerm_resource_group_policy_exemption` | CURRENT | provider v4.71.0 docs | No action. |
| module `Azure/avm-res-network-virtualnetwork/azurerm` `0.17.1` | CURRENT | registry.terraform.io/modules/Azure/avm-res-network-virtualnetwork | No action. |
| module `Azure/avm-res-recoveryservices-vault/azurerm` | CURRENT | RSV is current; classic Backup alerts deprecation does not block create | No action. |
| module `Azure/avm-res-web-serverfarm/azurerm` + `Azure/avm-res-web-site/azurerm` | CURRENT | App Service Plan + App Service current | No action. Confirm the App Service SKU tier is not a retiring tier at implement time. |

### 2.2 landing-zones/online-p1

| Resource type | Status | Evidence | Disposition |
|---------------|--------|----------|-------------|
| `azurerm_network_watcher_flow_log` x2 (appgw NSG + workload NSG) | **RETIRED** | Same as 2.1 | **MIGRATE**. This root has TWO NSG-targeted logs; collapse to ONE VNet-scoped flow log for the spoke VNet (section 3). BLOCKER. |
| `azurerm_public_ip` (Standard SKU, zones 1/2/3, Static) | CURRENT | learn.microsoft.com/azure/virtual-network/ip-services/public-ip-basic-upgrade-guidance - Basic PIP retired 2025-09-30; this is **Standard**, the successor | No action. Explicitly NOT the retired Basic SKU. |
| `azurerm_application_gateway` (WAF_v2 tier) | CURRENT | App Gateway v1 (Standard/WAF) retired 2026-04-28; this is v2 | No action. Explicitly NOT v1. |
| `azurerm_web_application_firewall_policy` (OWASP 3.2) | CURRENT | provider v4.71.0 docs; OWASP CRS 3.2 supported | No action. |
| `azurerm_static_web_app` (Standard) | CURRENT | Static Web Apps current; native resource per existing DEVIATION note (no AVM module) | No action. |
| `azurerm_storage_account` (flow-log sink) | CURRENT | as 2.1 | No action. |
| `azurerm_monitor_diagnostic_setting` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_private_dns_zone_virtual_network_link` / NSG / route_table / vnet_peering / resource_group / policy_exemption | CURRENT | provider v4.71.0 docs | No action. |
| module `Azure/avm-res-network-virtualnetwork/azurerm` `0.17.1` | CURRENT | registry | No action. |

### 2.3 platform/security

| Resource type | Status | Evidence | Disposition |
|---------------|--------|----------|-------------|
| `azurerm_sentinel_data_connector_azure_security_center` (subscription-based MDC) | DEPRECATED | learn.microsoft.com/azure/sentinel/data-connectors/subscription-based-microsoft-defender-for-cloud-legacy - marked Legacy; tenant-based connector recommended | POC-acceptable. Backlog: migrate to the tenant-based Defender for Cloud connector. Not a blocker. |
| `azurerm_sentinel_data_connector_azure_active_directory` (Entra ID) | DEPRECATED (watch) | learn.microsoft.com/azure/sentinel/move-to-defender - Sentinel portal consolidates into Defender by 2027-03-31; Entra connectors being reorganized | POC-acceptable. Watch for connector reshuffle. Not a blocker. |
| `azurerm_sentinel_data_connector_microsoft_defender_advanced_threat_protection` (MDATP) | CURRENT | provider v4.71.0 docs | No lifecycle action. Already gated on tenant licensing in `platform-security.md` (separate issue). |
| `azurerm_sentinel_data_connector_threat_intelligence` | CURRENT | provider v4.71.0 docs; upload-indicators API is the newer TI path but the TAXII/legacy connector still functions | No action. Watch for TI connector consolidation. |
| `azurerm_sentinel_log_analytics_workspace_onboarding` / `_alert_rule_*` / `_automation_rule` / `_watchlist` / `_watchlist_item` | CURRENT | provider v4.71.0 docs | No action. Portal-experience retirement (2027-03-31) does not block API create. |
| `azapi_resource` `Microsoft.SecurityInsights/settings@2024-09-01` (UEBA / entity analytics) | CURRENT | API version 2024-09-01 is recent and supported | No action. |
| `azurerm_security_center_subscription_pricing` (Defender plans) | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_security_center_contact` | CURRENT (watch) | securityContacts API schema evolved (email-as-`default` resource); provider abstracts it | No action. Watch provider notes on contact schema. |
| `azurerm_security_center_automation` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_monitor_aad_diagnostic_setting` / `azurerm_monitor_diagnostic_setting` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_eventhub` / `_eventhub_namespace` / `_eventhub_authorization_rule` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_application_insights_workbook` | CURRENT | Workbook, NOT classic Application Insights (classic AI retired 2024-02-29). No `azurerm_application_insights` component created | No action. |
| `azurerm_management_group_policy_assignment` | CURRENT | provider v4.71.0 docs | No action. |
| module `Azure/avm-res-keyvault-vault/azurerm` + `Azure/avm-res-operationalinsights-workspace/azurerm` | CURRENT | registry | No action. |

**Platform-level watch for this root:** Microsoft Sentinel in the Azure portal retires 2027-03-31 and moves
to the Defender portal (learn.microsoft.com/azure/sentinel/move-to-defender). No create-time impact now.

### 2.4 synthetic

| Resource type | Status | Evidence | Disposition |
|---------------|--------|----------|-------------|
| `azurerm_linux_virtual_machine` (image Canonical `ubuntu-24_04-lts` / `server`) | CURRENT | Ubuntu 24.04 LTS is a supported Marketplace image; NOT the retired 18.04 (EOL/removed) | No action. Confirmed not on a retired image. |
| `azurerm_automation_account` (Basic SKU, System-Assigned MI) | CURRENT | Automation Run As accounts retired 2023-09-30; this uses **managed identity**, the successor. "Basic" is the standard Automation tier, unrelated to Basic-PIP/LB retirement | No action. Explicitly NOT a Run As account. |
| `azurerm_automation_runbook` / `_schedule` / `_job_schedule` / `_webhook` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_container_app_environment` / `_environment_storage` / `_job` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_key_vault` (standard) | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_managed_disk` / `_network_interface` / `_virtual_network` / `_subnet` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_storage_account` / `_blob` / `_container` / `_queue` / `_share` / `_share_file` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_consumption_budget_subscription` / `_consumption_budget_resource_group` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_monitor_action_group` / `_monitor_diagnostic_setting` | CURRENT | provider v4.71.0 docs | No action. |
| `azurerm_role_assignment` | CURRENT | provider v4.71.0 docs | No action. |

**Note:** no `azurerm_virtual_machine_extension` (no MMA/OMS agent), so the Log Analytics agent retirement
(2024-08-31) does not apply to this root.

---

## 3. VNet flow-log migration - confirmation and spec for the cloud-engineer

**Confirmed: VNet flow logs are the correct replacement, and provider v4.71.0 supports it.**

- The provider v4.71.0 `azurerm_network_watcher_flow_log` resource exposes `target_resource_id` (The ID of
  the resource for which to enable flow logs). Per Microsoft's migration doc and the provider, that target
  can be a **virtual network** (VNet flow logs supersede NSG flow logs; Traffic Analytics remains supported).
- Migration per landing zone: **remove** `network_security_group_id = <nsg id>` and **set**
  `target_resource_id = module.spoke_vnet.resource_id`. Keep `enabled`, `retention_policy`, and
  `traffic_analytics` blocks; keep the `version = 2` schema. Storage-sink account is unchanged.

**Does online-p1 differ?** online-p1 does NOT use a different target type. It uses the same RETIRED
NSG-target pattern as corp, but has **two** NSG-scoped flow logs (appgw NSG and workload NSG) rather than
one. A single VNet flow log covers the whole VNet, so the recommendation is to **collapse the two into one
VNet-scoped flow log** for the online-p1 spoke VNet. Do not attempt subnet-scoped VNet flow logs in
Terraform: subnet-scoped targeting is not fully supported by the provider yet (hashicorp/terraform-provider-azurerm
issue #28175), so VNet scope is the safe granularity.

**Two implementation constraints the cloud-engineer must respect:**

1. **Force replacement, do not update in place.** There is a known provider bug where changing the target
   in place leaves Azure still pointing at the old NSG (hashicorp/terraform-provider-azurerm issue #31136).
   The migration should destroy the NSG flow log and create the VNet flow log (a `-replace` / recreate),
   not an in-place attribute swap. Because Azure has already blocked NSG-flow-log creation, any drift-repair
   apply that tries to recreate the NSG-target log will fail regardless, which reinforces recreate-as-VNet.
2. **`Microsoft.Network` provider feature / VNet flow logs prerequisite.** VNet flow logs require Network
   Watcher enabled in the region (already a known prerequisite in `landing-zones.md`: the per-region
   `NetworkWatcher_<region>` must exist). No new RP registration beyond what NSG flow logs already needed.

This is a cloud-engineer implementation task, not an architecture change. The topology (per-spoke flow
logging into the platform Log Analytics workspace via Traffic Analytics) is unchanged.

---

## 4. Spot-check of the already-deployed roots

These three roots are already applied. Checked for anything retiring soon.

| Root | Types checked | Finding |
|------|---------------|---------|
| platform/connectivity | `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet`, `Azure/avm-ptn-network-private-link-private-dns-zones`, azapi, resource groups | No NSG flow logs created here (flow logs live only in the landing zones). Residual check: confirm the hub pattern's public IPs (firewall / gateway / bastion, if deployed) are Standard SKU - AVM defaults to Standard, so no Basic-PIP exposure. CURRENT. |
| platform/management | LAW (avm-res-operationalinsights-workspace), automation account, storage, policy set definition, budgets, portal dashboards, action groups, cost anomaly alert | All CURRENT. Portal dashboards and cost-management resources are current. No retiring types. |
| platform/identity | Entra Domain Services (`azurerm_active_directory_domain_service`), RSV, NSG, PIM eligible assignments, Conditional Access policies, named locations | Entra DS is CURRENT (not retiring). Conditional Access and named-location resources CURRENT. No retiring types. |

**No RETIRED or RETIRING-soon type is being created by any deployed root.** The RETIRED NSG-flow-log
landmine is confined to the three landing-zone roots.

---

## 5. How this reached apply-time (root cause) and the institutional fix

The NSG-flow-log retirement was publicly announced and documented well before apply. It slipped because the
pre-clearance gate audited **policy, prerequisites, and known issues** but never audited **resource-type
lifecycle**. Per-diff code review sees the diff, not the cloud provider's retirement calendar. The fix:
`docs/deploy-preclearance.md` now carries a fourth required procedure step, 3(d) "Resource-type lifecycle /
deprecation-and-retirement audit", and every per-root pre-clearance file (existing and future) must include
a lifecycle-audit section that classifies each resource type the root creates. This document is the first
run of that step, applied retroactively across the whole remaining deploy chain.
