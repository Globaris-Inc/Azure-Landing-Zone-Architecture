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
budget_start_date = "2026-05-01T00:00:00Z"

# Cost export end date — set far enough in the future to cover the POC lifecycle.
export_end_date = "2030-12-01T00:00:00Z"

# Email addresses for budget threshold breach and cost anomaly alert notifications.
# Supplied via TF_VAR_budget_alert_contact_emails in CI; set locally in poc.secret.tfvars.
# budget_alert_contact_emails = ["<email-redacted>"]

# ---------------------------------------------------------------------------
# Platform components  (Section 8)
# ---------------------------------------------------------------------------

enable_ddos_standard = false   # DDoS Standard ~$2,944/mo — disabled for POC cost

# ---------------------------------------------------------------------------
# Identity  (Section 8)
# ---------------------------------------------------------------------------

identity_mode = "none"   # Options: "dc_vms" | "aadds" | "none"

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
corp_a1_spoke_address_space  = "10.10.0.0/16"
corp_a2_spoke_address_space  = "10.11.0.0/16"
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
# Synthetic workload  (Section 13)
# ---------------------------------------------------------------------------

enable_synthetic_workload = false
