# Purpose: Section 6 - diagnostic settings that pipe identity + control-plane
#          logs into the Security LA workspace so Sentinel can detect on them.
#          Entra ID (AAD) tenant-scope logs and the Security subscription's
#          Activity Log both flow here; other subscriptions' activity logs are
#          covered by the per-sub Azure Activity Sentinel data connector
#          (configured via the management-plane data connector pattern).
# Section: 6 - Defender for Cloud + Sentinel Tuning
# Last updated: 2026-05-29

# ---------------------------------------------------------------------------
# Entra ID (AAD) diagnostic settings → Security LA workspace
# ---------------------------------------------------------------------------
#
# azurerm_monitor_aad_diagnostic_setting is tenant-scoped - no resource_group
# or subscription parameter. The OIDC SP must hold Security Administrator (or
# at minimum Security Reader + Reports Reader) at the tenant root.
#
# DEVIATION: ADFSSignInLogs and NetworkAccessTrafficLogs are intentionally
# omitted - ADFS is not in scope for this Entra-first POC, and Network Access
# Traffic Logs require Entra Internet/Private Access licences not assumed
# here. Add them if those workloads come online.

resource "azurerm_monitor_aad_diagnostic_setting" "security_law" {
  count = var.enable_aad_diagnostics ? 1 : 0

  name                       = "diag-aad-to-security-law"
  log_analytics_workspace_id = module.security_law.resource_id

  enabled_log {
    category = "SignInLogs"
  }
  enabled_log {
    category = "AuditLogs"
  }
  enabled_log {
    category = "NonInteractiveUserSignInLogs"
  }
  enabled_log {
    category = "ServicePrincipalSignInLogs"
  }
  enabled_log {
    category = "ManagedIdentitySignInLogs"
  }
  enabled_log {
    category = "ProvisioningLogs"
  }
  enabled_log {
    category = "RiskyUsers"
  }
  enabled_log {
    category = "UserRiskEvents"
  }
}

# ---------------------------------------------------------------------------
# Security subscription Activity Log → Security LA workspace
# ---------------------------------------------------------------------------
#
# The per-subscription Azure Activity connector for Sentinel writes to the
# AzureActivity table on the workspace. The modern (post-2021) integration
# uses a subscription-scope diagnostic setting; Sentinel reads from
# AzureActivity transparently. Only the Security subscription is wired here -
# other subscriptions need their own diagnostic settings or the connector
# enabled per sub. Section 12 hardening tracks that fan-out via DINE.

resource "azurerm_monitor_diagnostic_setting" "security_sub_activity" {
  count = var.enable_subscription_activity_log ? 1 : 0

  name                       = "diag-activity-to-security-law"
  target_resource_id         = "/subscriptions/${var.security_subscription_id}"
  log_analytics_workspace_id = module.security_law.resource_id

  enabled_log {
    category = "Administrative"
  }
  enabled_log {
    category = "Security"
  }
  enabled_log {
    category = "Alert"
  }
  enabled_log {
    category = "Policy"
  }
  enabled_log {
    category = "ServiceHealth"
  }
  enabled_log {
    category = "Recommendation"
  }
  enabled_log {
    category = "ResourceHealth"
  }
  enabled_log {
    category = "Autoscale"
  }
}
