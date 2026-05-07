# envs/poc.tfvars
# Purpose: POC environment variable overrides — passed to all terraform apply invocations.
# Section: 1 (scaffold), populated incrementally through Section 13.
# Last updated: 2026-05-06
#
# Usage: terraform apply -var-file=../../envs/poc.tfvars
#
# Subscription IDs and tenant IDs are non-sensitive identifiers (GUIDs visible in the
# Azure portal) and are safe to commit. Only true secrets (client secrets, passwords,
# SAS tokens, certificates) must be kept out of source control.
# This file is safe to commit.

# ---------------------------------------------------------------------------
# Global / shared
# ---------------------------------------------------------------------------

environment = "poc"

# Primary Azure region
primary_location = "eastus2"

# Secondary / DR region
secondary_location = "centralus"

# Short org prefix used in resource naming (e.g. "cto" → cto-hub-vnet-eastus2)
org_prefix = "contoso"

# ---------------------------------------------------------------------------
# Management Groups  (Section 2)
# ---------------------------------------------------------------------------

# Tenant ID — set as a TODO so reviewers know it must be populated before apply.
# Retrieve with: az account show --query tenantId -o tsv
tenant_id = "<tenant-id>"

# Platform subscriptions (4 dedicated subs — ADR-003 Option C)
connectivity_subscription_id = "<subscription-id>"
management_subscription_id   = "<subscription-id>"
identity_subscription_id     = "<subscription-id>"
security_subscription_id     = "<subscription-id>"

# Shared landing zone subscription — placed under Corp MG for POC
landingzones_subscription_id = "<subscription-id>"

# ---------------------------------------------------------------------------
# FinOps / Tagging  (Section 7)
# ---------------------------------------------------------------------------

# default_tags = {
#   Environment      = "poc"
#   CostCenter       = "DEMO-9999"
#   Owner            = "platform-team"
#   BusinessUnit     = "Platform Engineering"
#   DataClassification = "Internal"
# }

# ---------------------------------------------------------------------------
# Platform components  (Section 8)
# ---------------------------------------------------------------------------

# enable_ddos_standard = false   # DDoS Standard ~$2,944/mo — disabled for POC cost

# ---------------------------------------------------------------------------
# Identity  (Section 8)
# ---------------------------------------------------------------------------

# identity_mode = "none"   # Options: "dc_vms" | "aadds" | "none"

# ---------------------------------------------------------------------------
# DR / Networking  (Section 3)
# ---------------------------------------------------------------------------

# hub_primary_address_space   = "10.0.0.0/16"
# hub_secondary_address_space = "10.1.0.0/16"

# ---------------------------------------------------------------------------
# Synthetic workload  (Section 13)
# ---------------------------------------------------------------------------

enable_synthetic_workload = false
