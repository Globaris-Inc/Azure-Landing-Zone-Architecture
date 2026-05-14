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
# Synthetic workload  (Section 13)
# ---------------------------------------------------------------------------

enable_synthetic_workload = false
