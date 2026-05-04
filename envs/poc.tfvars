# envs/poc.tfvars
# Purpose: POC environment variable overrides — passed to all terraform apply invocations.
# Section: 1 (scaffold), populated incrementally through Section 13.
# Last updated: 2026-05-04
#
# Usage: terraform apply -var-file=../../envs/poc.tfvars
#
# IMPORTANT: No subscription IDs, tenant IDs, client secrets, or passwords in this file.
# Those values come from environment variables (ARM_SUBSCRIPTION_ID etc.) or Key Vault.
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

# management_group_root_name = "Contoso"

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
