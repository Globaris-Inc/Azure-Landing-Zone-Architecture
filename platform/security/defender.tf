# Purpose: Section 6 — Defender for Cloud extension.
#          Adds the remaining Defender plans, MDC continuous export to the
#          Security LA workspace and an Event Hub (SIEM-ready), and assigns the
#          NIST SP 800-53 R5 + CIS Azure Foundations 2.0 built-in policy
#          initiatives at the Globaris root management group scope.
# Section: 6 — Defender for Cloud + Sentinel Tuning
# Last updated: 2026-07-06
#
# Apply order: After platform/management-groups (root MG must exist for the
#              compliance assignments). The Defender plans + Event Hub depend
#              only on the resource group created in main.tf.

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  # Additional Defender for Cloud resource types enabled on the Security sub.
  # The four foundational plans (VirtualMachines/P2, StorageAccounts, KeyVaults,
  # Arm) are already enabled in main.tf — this set adds the workload-tier
  # plans and Defender CSPM.
  #
  # resource_type values are taken from the azurerm_security_center_subscription_pricing
  # docs. "Containers" supersedes the legacy "ContainerRegistry" + "KubernetesService"
  # combination. "CloudPosture" enables Defender CSPM (asset graph, attack paths,
  # agentless scanning).
  defender_extended_plans = toset([
    "AppServices",
    "SqlServers",
    "SqlServerVirtualMachines",
    "Containers",
    "OpenSourceRelationalDatabases",
    "CloudPosture",
  ])

  # Built-in policy set (initiative) definitions for the two regulatory
  # compliance frameworks called out in PROMPT.md §6. Both initiatives are
  # tenant-wide built-ins published by Microsoft and assigned at the root MG
  # scope so every subscription inherits the compliance posture.
  #
  # VERIFIED 2026-07-06 (via `az policy set-definition show`, both GUIDs confirmed):
  #   179d1daa-458f-4e47-8086-2a68d0d6c38f = "NIST SP 800-53 Rev. 5" (initiative v14.19.0)
  #   06f19060-9e68-4070-92ca-f15cc126059e = "CIS Microsoft Azure Foundations Benchmark
  #     v2.0.0" (initiative v1.10.0) — this GUID IS the intended v2.0.0 benchmark.
  # Neither initiative has any required parameter without a default (0 of 122 each),
  # so the parameterless assignment below supplies everything needed. GUIDs are
  # correct as-is — do not change.
  regulatory_compliance_initiatives = {
    nist_sp_800_53_r5 = {
      definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/179d1daa-458f-4e47-8086-2a68d0d6c38f"
      display_name  = "NIST SP 800-53 Rev. 5"
    }
    cis_azure_2_0_0 = {
      definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/06f19060-9e68-4070-92ca-f15cc126059e"
      display_name  = "CIS Microsoft Azure Foundations Benchmark v2.0.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Defender for Cloud — extended plans (workload + CSPM)
# ---------------------------------------------------------------------------

# One-shot config-driven import (ADR-035): reconcile run-1 state drift where the raced
# pricing PUT set SqlServerVirtualMachines=Standard in Azure but the state write did not
# persist. Remove in a cleanup commit after the apply lands.
import {
  to = azurerm_security_center_subscription_pricing.extended["SqlServerVirtualMachines"]
  id = "/subscriptions/${var.security_subscription_id}/providers/Microsoft.Security/pricings/SqlServerVirtualMachines"
}

resource "azurerm_security_center_subscription_pricing" "extended" {
  for_each      = local.defender_extended_plans
  tier          = "Standard"
  resource_type = each.value

  # Serialize the remaining pricing PUTs to avoid the 409 concurrency error seen
  # in the 2nd apply: VirtualMachines (the servers resource) and AppServices
  # (in this extended set) were the two still needing a PUT. Ordering the whole
  # extended set after servers keeps only one pricing PUT in flight at a time
  # (code-side serialization, ref ADR-034).
  depends_on = [azurerm_security_center_subscription_pricing.servers]
}

# ---------------------------------------------------------------------------
# Event Hub for MDC continuous export — SIEM-ready alert + recommendation stream
# ---------------------------------------------------------------------------

resource "random_id" "mdc_eh_namespace" {
  count       = var.enable_mdc_event_hub_export ? 1 : 0
  byte_length = 3
}

resource "azurerm_eventhub_namespace" "mdc_export" {
  count = var.enable_mdc_event_hub_export ? 1 : 0

  name                = "evhns-mdc-${var.org_prefix}-${random_id.mdc_eh_namespace[0].hex}"
  resource_group_name = azurerm_resource_group.security.name
  location            = var.primary_location

  sku                           = "Standard"
  capacity                      = var.event_hub_namespace_capacity
  auto_inflate_enabled          = true
  maximum_throughput_units      = 5
  public_network_access_enabled = true # DEVIATION: PE deferred (Section 12 hardening)

  tags = local.common_tags
}

resource "azurerm_eventhub" "mdc_export" {
  count = var.enable_mdc_event_hub_export ? 1 : 0

  name              = "evh-mdc-export"
  namespace_id      = azurerm_eventhub_namespace.mdc_export[0].id
  partition_count   = 4
  message_retention = 1 # day — MDC alerts are streamed for downstream SIEM, not retained here
}

# Authorisation rule the MDC export consumer uses. Listen + Send (Send is
# required so MDC can publish; Listen lets downstream tools (Splunk, Elastic,
# Sentinel via custom collector) read).
resource "azurerm_eventhub_authorization_rule" "mdc_export" {
  count = var.enable_mdc_event_hub_export ? 1 : 0

  name                = "mdc-export-publisher"
  namespace_name      = azurerm_eventhub_namespace.mdc_export[0].name
  eventhub_name       = azurerm_eventhub.mdc_export[0].name
  resource_group_name = azurerm_resource_group.security.name

  listen = true
  send   = true
  manage = false
}

# ---------------------------------------------------------------------------
# Defender for Cloud — continuous export automation
# ---------------------------------------------------------------------------
#
# MDC continuous export uses azurerm_security_center_automation with two
# action blocks — one targeting the Security LA workspace, one targeting the
# Event Hub. Sources cover alerts (high/medium severity) and the full
# assessment + sub-assessment + regulatory compliance stream.
#
# Scope is the Security subscription only in the POC; production ALZ assigns
# this at root MG scope via Azure Policy (DINE) so all subs export uniformly.

resource "azurerm_security_center_automation" "mdc_export" {
  count = var.enable_mdc_event_hub_export ? 1 : 0

  name                = "automation-mdc-export-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.security.name
  location            = var.primary_location
  enabled             = true

  scopes = ["/subscriptions/${var.security_subscription_id}"]

  source {
    event_source = "Alerts"
    rule_set {
      rule {
        property_path  = "Severity"
        operator       = "Equals"
        expected_value = "High"
        property_type  = "String"
      }
    }
    rule_set {
      rule {
        property_path  = "Severity"
        operator       = "Equals"
        expected_value = "Medium"
        property_type  = "String"
      }
    }
  }

  source {
    event_source = "Assessments"
  }

  source {
    event_source = "SubAssessments"
  }

  source {
    event_source = "RegulatoryComplianceAssessment"
  }

  action {
    type        = "Workspace"
    resource_id = module.security_law.resource_id
  }

  action {
    type              = "EventHub"
    resource_id       = azurerm_eventhub.mdc_export[0].id
    connection_string = azurerm_eventhub_authorization_rule.mdc_export[0].primary_connection_string
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Regulatory compliance — NIST SP 800-53 R5 + CIS Azure Foundations 2.0
# ---------------------------------------------------------------------------
#
# Defender for Cloud surfaces a regulatory compliance dashboard for any
# initiative assigned to the subscription's MG ancestry. Assigning both
# initiatives at the Globaris root MG scope makes them apply to every
# subscription in the hierarchy.
#
# All audit-effect policies in these initiatives produce evidence in the
# compliance dashboard without modifying resources. The handful of
# DeployIfNotExists / AuditIfNotExists policies need a managed identity for
# any future remediation tasks — we attach a system-assigned identity but do
# not create remediation jobs in this section (Section 12 hardening).

resource "azurerm_management_group_policy_assignment" "regulatory_compliance" {
  for_each = var.enable_regulatory_compliance ? local.regulatory_compliance_initiatives : {}

  name                 = "reg-${each.key}" # <= 24 chars: reg-nist_sp_800_53_r5 (21), reg-cis_azure_2_0_0 (19)
  display_name         = each.value.display_name
  description          = "Regulatory compliance initiative assigned at Globaris root MG for the Defender for Cloud compliance dashboard (Section 6)."
  management_group_id  = var.root_management_group_id
  policy_definition_id = each.value.definition_id
  location             = var.primary_location
  enforce              = false # POC: audit-only; do not enforce DeployIfNotExists side-effects yet.

  identity {
    type = "SystemAssigned"
  }
}
