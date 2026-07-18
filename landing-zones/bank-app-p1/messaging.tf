# Purpose: bank-app-p1 messaging/eventing backbone (wave B3) - Event Hubs Standard
#          namespace (1 TU, PE-only, AAD-only) and Service Bus Premium namespace
#          (1 MU, PE-only, AAD-only; OQ-044 resolved shape A). Both private-endpoint
#          into snet-private-endpoints on the shared privatelink.servicebus.windows.net
#          zone (Event Hubs uses the servicebus Private Link domain; the two PEs write
#          DISTINCT A records into the SAME zone - one per namespace FQDN). Diagnostics
#          to the platform LAW. ALL resources gated behind var.enable_messaging_platform
#          (default false, LESSON 42 flag pattern).
# Section: Banking wave B3 (docs/b3-messaging-platform-design.md sections 3-5; ADR-045/046)
# Last updated: 2026-07-18
#
# Modules (pins re-verified on the Terraform Registry 2026-07-18, schemas read from
# the tag sources):
#   Azure/avm-res-eventhub-namespace/azurerm  0.1.0 (latest; single release - MATURITY
#     FLAG per the design doc; native fallback pre-authorized if it misbehaves at apply)
#   Azure/avm-res-servicebus-namespace/azurerm 0.4.0 (latest)
#
# Policy shape (design doc section 2, verified live 2026-07-18): the corp deny
# initiative members for EH and SB public network access both default to Deny; both
# namespaces ship public-access-off = compliant by design. NO exemption anywhere
# (shape A ruling - Premium SB attaches a PE; Standard could not).
#
# No new network surface: PE data-plane traffic is in-VNet (more-specific route) and
# never reaches the firewall - zero firewall rule changes ride this wave for the spoke.

# ---------------------------------------------------------------------------
# Event Hubs Standard namespace + demo event hub + PE
# ---------------------------------------------------------------------------

module "event_hubs" {
  source  = "Azure/avm-res-eventhub-namespace/azurerm"
  version = "0.1.0"

  for_each = var.enable_messaging_platform ? { main = "main" } : {}

  # LESSON 27 rendered-length check: "evhns-bank-app-p1-" (18) + org "globaris" (8) +
  # "-" (1) + env "poc" (3) = 30 chars, within the 6-50 EH namespace bound; matches
  # the module's ^[a-zA-Z][a-zA-Z0-9-]{0,48}[a-zA-Z0-9]$ validation. Namespace names
  # are global DNS - the org prefix carries uniqueness. Re-check on prefix/env change.
  name                = "evhns-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.primary_location

  # Founding design: Standard 1 TU is the cheapest PE-capable tier. Auto-inflate off
  # at POC (production design target documents TU scale-out - design doc section 7).
  sku                  = "Standard"
  capacity             = 1
  auto_inflate_enabled = false

  # Deny-by-design posture: public access off satisfies the corp deny member; SAS off
  # makes the data plane AAD-only (banking bar). Module hardcodes min TLS 1.2.
  public_network_access_enabled = false
  local_authentication_enabled  = false

  # One tiny demo hub so QA has a data-plane surface (design doc section 3).
  event_hubs = {
    evh-demo = {
      # namespace_name / resource_group_name are TYPE-required by the 0.1.0 schema but
      # IGNORED by the module implementation (main.eventhub.tf derives both from the
      # namespace it creates; the hub name is the map key). Supplied to satisfy the
      # type only - part of the 0.1.0 maturity flag.
      namespace_name      = "evhns-bank-app-p1-${var.org_prefix}-${var.environment}"
      resource_group_name = azurerm_resource_group.shared.name
      partition_count     = 2
      message_retention   = 1
    }
  }

  # One PE into snet-private-endpoints; module-managed zone group against the central
  # privatelink.servicebus.windows.net zone (looked up in dns_links.tf, spoke-linked
  # since B1) - the estate's proven SQL/ACR zone-group pattern. subresource_name is
  # type-required; 0.1.0 hardcodes "namespace" internally (the only EH subresource).
  private_endpoints = {
    namespace = {
      name                            = "pe-evhns-bank-app-p1-${var.org_prefix}-${var.environment}"
      subnet_resource_id              = module.spoke_vnet.subnets["private-endpoints"].resource_id
      subresource_name                = "namespace"
      private_dns_zone_resource_ids   = [data.azurerm_private_dns_zone.linked["servicebus"].id]
      private_service_connection_name = "psc-evhns-bank-app-p1"
      tags                            = local.common_tags
    }
  }

  tags = local.common_tags
}

# DEVIATION: native diagnostic setting for the Event Hubs namespace. The 0.1.0 module
# DECLARES a diagnostic_settings input but never consumes it - no
# azurerm_monitor_diagnostic_setting resource exists anywhere in the module source
# (verified in the v0.1.0 tag, 2026-07-18); passing the input would silently ship no
# diagnostics. This is the maturity-flag gap the design doc pre-authorizes working
# around. Block forms (enabled_log category_group / enabled_metric) verified against
# azurerm 4.71.0 docs; Event Hubs supports resource-specific (Dedicated) AZMS* tables.
resource "azurerm_monitor_diagnostic_setting" "event_hubs" {
  for_each = var.enable_messaging_platform ? { main = "main" } : {}

  name                           = "diag-evhns-bank-app-p1-${var.org_prefix}-${var.environment}"
  target_resource_id             = module.event_hubs[each.key].resource_id
  log_analytics_workspace_id     = var.platform_law_workspace_id
  log_analytics_destination_type = "Dedicated"

  # Category group instead of a hardcoded category list (LESSON 40 rot class).
  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ---------------------------------------------------------------------------
# Service Bus Premium namespace + demo queue + PE (OQ-044 shape A)
# ---------------------------------------------------------------------------

module "service_bus" {
  source  = "Azure/avm-res-servicebus-namespace/azurerm"
  version = "0.4.0"

  for_each = var.enable_messaging_platform ? { main = "main" } : {}

  # LESSON 27 rendered-length check: "sbns-bank-app-p1-" (17) + org "globaris" (8) +
  # "-" (1) + env "poc" (3) = 29 chars, within the module's 6-50 bound. Namespace
  # names are global DNS - the org prefix carries uniqueness.
  name                = "sbns-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.primary_location

  # Shape A (OQ-044 user resolution under the ADR-045 sprint frame): Premium 1
  # messaging unit, 1 partition - the ONLY tier that attaches private endpoints, so
  # the namespace is compliant by design with zero policy exemptions. ~$22.4/day
  # while the sprint runs (design doc section 8), accepted by the shape A ruling.
  sku                          = "Premium"
  capacity                     = 1
  premium_messaging_partitions = 1

  # Deny-by-design posture, same bar as Event Hubs: public access off, SAS off
  # (AAD-only data plane), min TLS 1.2 explicit.
  public_network_access_enabled = false
  local_auth_enabled            = false
  minimum_tls_version           = "1.2"

  # One demo queue for QA (module defaults: no sessions, no dead-letter tuning -
  # the entity exists as a data-plane surface only; queue name = map key).
  queues = {
    sbq-demo = {}
  }

  # Same servicebus zone as the Event Hubs PE - the zone group writes a distinct
  # A record for this namespace's FQDN alongside the EH one (QA verifies both).
  private_endpoints = {
    namespace = {
      name                            = "pe-sbns-bank-app-p1-${var.org_prefix}-${var.environment}"
      subnet_resource_id              = module.spoke_vnet.subnets["private-endpoints"].resource_id
      private_dns_zone_resource_ids   = [data.azurerm_private_dns_zone.linked["servicebus"].id]
      private_service_connection_name = "psc-sbns-bank-app-p1"
      tags                            = local.common_tags
    }
  }

  # In-module diagnostics (implemented in 0.4.0, verified in the tag source):
  # defaults are allLogs category group + AllMetrics + Dedicated destination.
  diagnostic_settings = {
    platform_law = {
      name                  = "diag-sbns-bank-app-p1-${var.org_prefix}-${var.environment}"
      workspace_resource_id = var.platform_law_workspace_id
    }
  }

  tags = local.common_tags
}
