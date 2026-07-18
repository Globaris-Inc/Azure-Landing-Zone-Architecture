# envs/poc.tfvars
# Purpose: POC environment variable overrides — non-sensitive config only.
# Section: 1 (scaffold), populated incrementally through Section 13.
# Last updated: 2026-05-07
#
# Usage:
#   CI   — TF_VAR_* environment variables supply IDs from GitHub Actions secrets.
#   Local — terraform apply -var-file=../../envs/poc.tfvars \
#                           -var-file=../../envs/poc.secret.tfvars
#
# Tenant ID, subscription IDs, and other identifiers live in:
#   - CI:    GitHub Actions secrets (TF_VAR_tenant_id, TF_VAR_*_subscription_id)
#   - Local: envs/poc.secret.tfvars  (gitignored — see poc.secret.tfvars.example)

# ---------------------------------------------------------------------------
# Global / shared
# ---------------------------------------------------------------------------

environment = "poc"

# Primary Azure region
primary_location = "eastus2"

# Secondary / DR region
secondary_location = "centralus"

# Short org prefix used in resource naming (e.g. "cto" → cto-hub-vnet-eastus2)
org_prefix = "globaris"

# ---------------------------------------------------------------------------
# Management Groups  (Section 2)
# ---------------------------------------------------------------------------
# IDs supplied via GitHub Actions secrets in CI, or poc.secret.tfvars locally.
# See: envs/poc.secret.tfvars.example

# ---------------------------------------------------------------------------
# FinOps / Tagging  (Section 7)
# ---------------------------------------------------------------------------

# Monthly budget cap (USD) per subscription. 5 subs × $200 = $1,000/mo ceiling.
budget_amount_per_subscription = 200

# Monthly budget cap (USD) at management group scope.
budget_amount_per_mg = 600

# Thresholds (%) at which alert emails fire. Must match across all modules.
budget_alert_thresholds = [50, 75, 90, 100]

# Budget and cost export start date — first of current month, RFC 3339.
# NOTE: Azure's Consumption API rejects a start date prior to the current month
# (400 "Start date for monthly time grain should not be prior to current month"
# on budgets AND cost-export scheduled actions). Bump to the first of the
# CURRENT month whenever platform/management is freshly deployed.
budget_start_date = "2026-07-01T00:00:00Z"

# Cost export end date — set far enough in the future to cover the POC lifecycle.
export_end_date = "2030-12-01T00:00:00Z"

# Email addresses for budget threshold breach and cost anomaly alert notifications.
# Supplied via TF_VAR_budget_alert_contact_emails in CI; set locally in poc.secret.tfvars.
# budget_alert_contact_emails = ["ops@example.com"]

# ---------------------------------------------------------------------------
# Platform components  (Section 8)
# ---------------------------------------------------------------------------

enable_ddos_standard = false # DDoS Standard ~$2,944/mo — disabled for POC cost

# ---------------------------------------------------------------------------
# Identity  (Section 8 — G1 / Gap-Closure Wave 3 / ADR-010)
# ---------------------------------------------------------------------------

# Domain-services mode for the Identity subscription.
#   "entra-ds" — Microsoft Entra Domain Services (managed) — shipped default (ADR-010).
#   "ad-ds"    — documented-only branch (VNet + RSV, no Entra DS / DC VMs this wave).
#   "none"     — Identity sub left empty.
identity_mode = "entra-ds"

# Managed-domain FQDN (required when identity_mode = "entra-ds"). Set 2026-07-08
# (resolves the OQ-003 placeholder): subdomain of the org-owned domain, first label
# 15 chars or less (NetBIOS), IMMUTABLE after the managed domain is created.
identity_domain_name = "aadds.globaris.org"

# Identity VNet CIDR — non-overlapping with hubs (10.0/16, 10.1/16) and spokes
# (10.10/16, 10.11/16, 10.20/16). Entra DS subnet is carved from this.
identity_vnet_address_space = "10.2.0.0/24"

# AADDS DC IPs the identity VNet uses for DNS are now DERIVED from the AADDS subnet
# CIDR (cidrhost offsets 4/5 of local.snet_entra_ds - ADR-029), so no static value is
# set here: greenfield gets the self-adjusting default. Leaving identity_vnet_dns_servers
# unset (empty list) selects the derived pair; set it to a non-empty list only to
# override. For 10.2.0.0/24 the derivation yields sort(10.2.0.4, 10.2.0.5).

# Hub peering targets for the identity VNet. Populate from platform/connectivity
# outputs after that module is applied (same values the corp-a1 spoke consumes).
# Set in poc.secret.tfvars locally / TF_VAR_* in CI:
#   primary_hub_vnet_id, primary_hub_vnet_name, primary_hub_rg_name

# ---------------------------------------------------------------------------
# DR / Networking  (Section 3)
# ---------------------------------------------------------------------------

hub_primary_address_space   = "10.0.0.0/16"
hub_secondary_address_space = "10.1.0.0/16"

# ---------------------------------------------------------------------------
# Landing Zone Spokes  (Section 9)
# ---------------------------------------------------------------------------

# Spoke VNet CIDR allocations — non-overlapping with hubs (10.0/16, 10.1/16)
# and with each other.
corp_a1_spoke_address_space   = "10.10.0.0/16"
corp_a2_spoke_address_space   = "10.11.0.0/16"
online_p1_spoke_address_space = "10.20.0.0/16"

# App Service Plan SKU — B2 for POC (2 vCores, 3.5 GB RAM, Linux).
# Upgrade to P1v3 for production-like performance testing.
app_service_sku = "B2"

# Recovery Services Vault — GeoRedundant ensures DR data survives region failure.
rsv_geo_redundant = true

# WAF mode — Prevention blocks malicious requests; Detection only logs them.
waf_mode = "Prevention"

# App Gateway capacity — minimum 1 for POC; increase for load testing.
appgw_capacity = 1

# Hub VNet IDs + Firewall IPs — populate from `terraform output` in platform/connectivity
# after that module is applied. Values look like:
#   /subscriptions/<conn-sub>/resourceGroups/rg-connectivity-primary-.../providers/Microsoft.Network/virtualNetworks/vnet-hub-primary-...
#
# primary_hub_vnet_id         = "TODO: from platform/connectivity output primary_hub_vnet_id"
# primary_hub_vnet_name       = "TODO: from platform/connectivity output primary_hub_vnet_name"
# primary_hub_rg_name         = "TODO: rg-connectivity-primary-globaris-poc"
# primary_firewall_private_ip  = "TODO: from platform/connectivity output primary_firewall_private_ip"
# secondary_hub_vnet_id        = "TODO: from platform/connectivity output secondary_hub_vnet_id"
# secondary_hub_vnet_name      = "TODO: from platform/connectivity output secondary_hub_vnet_name"
# secondary_hub_rg_name        = "TODO: rg-connectivity-secondary-globaris-poc"
# secondary_firewall_private_ip = "TODO: from platform/connectivity output secondary_firewall_private_ip"

# Platform LA workspace ID — populate from `terraform output` in platform/management.
# platform_law_workspace_id = "TODO: from platform/management output platform_law_workspace_id"
# platform_action_group_id  = "TODO: from platform/management output platform_action_group_id"

# SQL Entra admin — set in poc.secret.tfvars (not committed).
# sql_aad_admin_object_id = "TODO"
# sql_aad_admin_login     = "TODO"

# ---------------------------------------------------------------------------
# Banking Spokes  (Banking wave B1 - docs/banking-platform-design.md)
# ---------------------------------------------------------------------------

# Banking spoke VNet CIDR allocations - ARCHITECT-CONFIRMED (B1 amendment ruling).
# Full banking allocation table:
#   10.30.0.0/16 - bank-app-p1 (eastus2, deployed)
#   10.31.0.0/16 - RESERVED bank-app DR (centralus, design-only, NOT deployed)
#   10.32.0.0/16 - bank-data-p1 (eastus2, deployed)
#   10.33.0.0/16 - RESERVED bank-data DR (centralus, design-only, NOT deployed)
# Non-overlapping with the estate (hubs 10.0/16 + 10.1/16, identity 10.2.0.0/24,
# spokes 10.10/16, 10.11/16, 10.20/16).
# NOTE: like the Section 9 entries above, each root declares its own
# `spoke_address_space` variable carrying the same value as its default; these
# entries document the estate-wide allocation map.
bank_app_p1_spoke_address_space  = "10.30.0.0/16"
bank_data_p1_spoke_address_space = "10.32.0.0/16"

# The banking spokes reuse the Section 9 spoke inputs supplied via TF_VAR_* in CI /
# poc.secret.tfvars locally: primary_hub_vnet_id, primary_hub_vnet_name,
# primary_hub_rg_name, primary_firewall_private_ip, platform_law_workspace_id,
# platform_law_customer_id, private_dns_rg_name (below), flow_log_retention_days
# (below). No new secret values are introduced by wave B1.

# ---------------------------------------------------------------------------
# Banking wave B2 - time-boxed firewall sprint (ADR-044)
# ---------------------------------------------------------------------------
# Both flags below are the reviewed-commit flag supply ADR-044 rules (visible to
# plan-on-pr and drift checks - NOT a workflow-dispatch override).
#
# enable_firewall = true fires the ADR-042 re-enable trigger: the Azure Firewall
# Premium pair returns in both hubs (~$3.5/hr for the pair) plus the AKS egress
# rule collection group on the primary policy. TIME-BOXED: the user re-gates or
# tears down by END OF DAY (ADR-044 Frames A/B). EOD revert path (Frame A) is the
# one-line change `enable_firewall = false` + connectivity apply, paired with an
# out-of-band `az aks stop`.
#
# ORDERING IS HARD (ADR-044): apply platform/connectivity first, confirm firewall
# private IPs are exactly 10.0.0.4 / 10.1.0.4, THEN apply landing-zones/bank-app-p1
# with enable_kubernetes_platform = true (private AKS + Premium ACR, ADR-043;
# outbound_type userDefinedRouting rides the B1 UDR). Nodes cannot bootstrap
# through a blackholed route.
#
# aks_admin_group_object_ids is REQUIRED by the bank-app-p1 root and arrives via
# TF_VAR_aks_admin_group_object_ids from the repo secret (poc.secret.tfvars
# locally) - never committed here.
enable_firewall            = true
enable_kubernetes_platform = true

# ---------------------------------------------------------------------------
# Banking wave B3 - messaging platform (ADR-045 / ADR-046)
# ---------------------------------------------------------------------------
# OQ-044 resolved shape A: Service Bus PREMIUM 1 MU + private endpoint (the only
# PE-capable tier - compliant with the corp deny initiative by design, NO policy
# exemption) alongside the Event Hubs Standard namespace (1 TU + PE). Both are
# public-access-off and AAD-only (local/SAS auth disabled). Sprint posture per
# ADR-045: the estate stands up through the week, teardown at EOW; B3 adds roughly
# $24/day while enabled (design doc section 8). Flag defaults false in the root
# (LESSON 42); this reviewed-commit entry is the flag supply, same pattern as the
# B2 flags above.
enable_messaging_platform = true

# ---------------------------------------------------------------------------
# Private DNS + NSG Flow Logs  (Section 4)
# ---------------------------------------------------------------------------

# Days to retain NSG flow log data in the landing zone storage accounts.
# Increase to 30 for production-grade forensic retention.
flow_log_retention_days = 7

# Private DNS RG name — deterministic; matches the name built in platform/connectivity/dns.tf.
private_dns_rg_name = "rg-dns-globaris-poc"

# platform_law_customer_id is the LA workspace GUID (not the ARM resource ID).
# Get it with: az monitor log-analytics workspace show \
#   --resource-group rg-management-globaris-poc \
#   --workspace-name law-platform-globaris-poc \
#   --query customerId -o tsv
# Set this in poc.secret.tfvars (not here — it's a workspace GUID, not a secret
# but keep it out of the non-secret file to avoid confusion).

# ---------------------------------------------------------------------------
# Zero Trust + Conditional Access  (Section 5)
# ---------------------------------------------------------------------------

# Conditional Access policy state.
# "enabledForReportingButNotEnforced" = report-only (safe default for POC).
# Switch to "enabled" once break-glass accounts are confirmed and tested.
# Valid values: enabled | disabled | enabledForReportingButNotEnforced
ca_policy_state = "enabledForReportingButNotEnforced"

# Two-letter ISO 3166-1 country codes that are permitted sign-in locations.
# Sign-ins from all other countries are blocked by CA-005.
approved_sign_in_countries = ["US", "CA", "GB"]

# ---------------------------------------------------------------------------
# Defender for Cloud + Sentinel  (Section 6)
# ---------------------------------------------------------------------------

# Globaris root MG ARM resource ID — scope of the NIST + CIS compliance assignments.
root_management_group_id = "/providers/Microsoft.Management/managementGroups/globaris"

# Assign the NIST SP 800-53 R5 + CIS Azure Foundations 2.0 built-in policy
# initiatives at the root MG scope. Disable for the very first apply if the
# OIDC SP doesn't yet hold Resource Policy Contributor at MG scope.
enable_regulatory_compliance = true

# Stream MDC alerts / recommendations / assessments to an Event Hub alongside
# the Security LA workspace, enabling downstream SIEMs (Splunk, Elastic) to
# consume the same stream without re-querying the workspace.
enable_mdc_event_hub_export  = true
event_hub_namespace_capacity = 1 # 1 TU = 1 MB/s ingress (~2.5 GB/day)

# Pipe Security-sub Activity logs into the Security LA workspace.
# enable_aad_diagnostics gated OFF: azurerm_monitor_aad_diagnostic_setting needs a
# Security Administrator directory role the CI SP does not hold. Re-enable in a
# later pass once the role is granted (see docs/preclearance/platform-security.md).
enable_aad_diagnostics           = false
enable_subscription_activity_log = true

# Sentinel UEBA + Entity Analytics gated OFF: the azapi settings writes need a
# Security Administrator directory role the CI SP does not hold. Re-enable once
# the role is granted. ~7 days of data needed before baselines stabilise.
enable_ueba = false

# Microsoft Defender for Endpoint Sentinel connector gated OFF: tenant lacks an
# MDE license so the connector create fails. Pre-staged for a later pass.
enable_mde_connector = false

# Entra ID (Azure AD) Sentinel data connector gated OFF: the tenant-scoped connector
# PUT needs a Security Administrator directory role the CI SP does not hold (401 Access
# denied, same class as enable_aad_diagnostics / enable_ueba). Re-enable once granted.
enable_aad_connector = false

# Microsoft Threat Intelligence Sentinel data connector gated OFF: same Security
# Administrator directory-role requirement; the connector PUT returns 401 without it.
# Re-enable once the role is granted.
enable_ti_connector = false

# firewall_threat_intel_hit cross-workspace analytics rule gated OFF: its name-only
# workspace('law-platform-...') reference does not resolve cross-subscription at rule
# create (400 Could not locate all the workspaces). Re-enable needs a fully-qualified
# platform LAW reference plus cross-workspace RBAC - see OQ-027.
enable_firewall_ti_rule = false

# Default scheduled-rule cadence. Per-rule overrides live in sentinel.tf.
analytics_rule_lookback_minutes        = 60
analytics_rule_query_frequency_minutes = 60

# ---------------------------------------------------------------------------
# Synthetic workload  (Section 13)
# ---------------------------------------------------------------------------

enable_synthetic_workload = false
