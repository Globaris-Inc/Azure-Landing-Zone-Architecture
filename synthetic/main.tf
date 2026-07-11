# Purpose: Synthetic workload root module — entry point.
# Section: 13.1 (this commit) — Workload targets only.
#          Future commits add 13.2 (k6 ACI), 13.3 (red-team simulator), 13.4 (cost patterns).
# Last updated: 2026-06-02
#
# Resource grouping:
#   corp_a1.tf   — REST API stub on corp-a1 App Service + supporting storage
#   corp_a2.tf   — Cold standby reference (no resources today; ASR drill comes in 13.5)
#   online_p1.tf — Storage Queue for the online-p1 contact form
#
# Every resource in this layer is gated by `var.enable_synthetic_workload`.
# When the flag is false the entire layer plans to zero — see synthetic/README.md.

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  enabled = var.enable_synthetic_workload ? 1 : 0

  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "synthetic-poc"
      Owner              = "platform-team"
      Workload           = "synthetic"
      DataClassification = "Synthetic"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
      Layer              = "Synthetic"
      Lifecycle          = "Ephemeral"
    },
    var.tags
  )

  # Deterministic name fragments mirroring landing-zones/* so data sources resolve
  # without needing remote_state lookups.
  #
  # The corp-a1 App Service (app-corp-a1-...) was gated off at deploy time
  # (enable_app_service=false, ADR-032), so the synthetic k6 load test targets
  # the LIVE online-p1 Application Gateway WAF_v2 public endpoint instead
  # (OQ-030 decision B). online-p1 is the internet-facing spoke; its App Gateway
  # access + WAF logs already flow to the platform LAW, giving the app-traffic
  # signal. The App Gateway public IP lives in the online-p1 network RG.
  online_p1_shared_rg_name   = "rg-online-p1-shared-${var.org_prefix}-${var.environment}"
  online_p1_workload_rg_name = "rg-online-p1-workload-${var.org_prefix}-${var.environment}"
  online_p1_network_rg_name  = "rg-online-p1-network-${var.org_prefix}-${var.environment}"
  online_p1_appgw_pip_name   = "pip-appgw-online-p1-${var.org_prefix}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Random suffix used by globally-unique resource names (storage accounts)
# ---------------------------------------------------------------------------

resource "random_string" "sa_suffix" {
  count   = local.enabled
  length  = 6
  upper   = false
  special = false
  numeric = true
}
