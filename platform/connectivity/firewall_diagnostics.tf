# Purpose: Diagnostic settings for the hub Azure Firewalls -> platform LAW. Closes
#          the B2 QA MEDIUM finding (neither hub firewall had ANY diagnostic setting,
#          so no AZFW logs reached the LAW - blocking firewall-log evidence for B4+
#          QA, forced-tunneling checks and egress verification). Rides the wave B3
#          batch per the design doc's fix-spec.
# Section: Banking wave B3 ride-along (docs/b3-messaging-platform-design.md section 6)
# Last updated: 2026-07-18
#
# The pinned pattern module (avm-ptn-alz-connectivity-hub-and-spoke-vnet 0.17.1) has
# no diagnostic-settings input on its firewall config (variables.tf grep, 2026-07-18),
# so this is a standalone resource over the module's firewall_resource_ids output
# (map keyed primary/secondary, verified in the cached module source outputs.tf).
#
# Gated on var.enable_firewall via for_each (estate no-count rule): when the flag
# re-gates to false at the EOW teardown decision (ADR-045), these settings drop out
# of the plan with the firewalls - a diagnostic setting dies with its target resource,
# no extra teardown step.
#
# Block forms verified against azurerm 4.71.0 docs (enabled_log with category_group,
# enabled_metric): the allLogs category group avoids hardcoding the AZFW category
# list (LESSON 40 rot class), and log_analytics_destination_type "Dedicated" lands
# the structured firewall logs in resource-specific tables (AZFWApplicationRule,
# AZFWNetworkRule, ...) - the current MS-recommended mode. Unlike Traffic Analytics
# (LESSON 43), diagnostic settings are cross-region-safe, so the single eastus2
# platform LAW serves both hub firewalls.

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  for_each = var.enable_firewall ? module.hub_and_spoke.firewall_resource_ids : {}

  name                           = "diag-fw-${each.key}-${var.org_prefix}-${var.environment}"
  target_resource_id             = each.value
  log_analytics_workspace_id     = var.platform_law_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
