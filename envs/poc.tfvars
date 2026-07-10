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

# AADDS domain-controller IPs the identity VNet uses for DNS (mandatory AADDS
# post-deploy step - ADR-029). Order matches the live portal value the operator
# set to heal the domain, so the first apply aligns state with no Azure change and
# steady-state re-plans are 0 changes. Private RFC-1918 IPs, safe to commit.
identity_vnet_dns_servers = ["10.2.0.5", "10.2.0.4"]

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

# Pipe Entra ID + Security-sub Activity logs into the Security LA workspace.
enable_aad_diagnostics           = true
enable_subscription_activity_log = true

# Enable Sentinel UEBA + Entity Analytics. ~7 days of data needed before
# behaviour baselines stabilise.
enable_ueba = true

# Default scheduled-rule cadence. Per-rule overrides live in sentinel.tf.
analytics_rule_lookback_minutes        = 60
analytics_rule_query_frequency_minutes = 60

# ---------------------------------------------------------------------------
# Synthetic workload  (Section 13)
# ---------------------------------------------------------------------------

enable_synthetic_workload = false
