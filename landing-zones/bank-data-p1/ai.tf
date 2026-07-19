# Purpose: bank-data-p1 AI platform (wave B6) - Microsoft Foundry account
#          (Microsoft.CognitiveServices/accounts, kind AIServices, S0) carrying ONE
#          chat model deployment (gpt-5.4-nano, DataZoneStandard, capacity 10) plus
#          an AI Search basic service. Both PE-only into snet-private-endpoints,
#          AAD-only (local auth off), diagnostics to the platform LAW. Compliant BY
#          DESIGN with all three corp Deny members (cognitive pna 0725b4dd, cognitive
#          networkAcls 037eea7a, search pna ee980b6d) - ZERO policy exemptions.
#          Gated behind var.enable_ai_platform (default false, LESSON 42 flag pattern).
# Section: Banking wave B6 (docs/b6-ai-platform-design.md sections 3-4; ADR-051)
# Last updated: 2026-07-19
#
# Modules (pins re-verified on the Terraform Registry 2026-07-19; schemas read from
# the tag sources - FIRST estate consumption of both):
#   Azure/avm-res-cognitiveservices-account/azurerm 0.11.1 (latest; azapi-shaped -
#     takes parent_id = the RG resource ID; kind AIServices routes to the module's
#     azapi_resource.ai_service path; the root's anchored default azapi provider
#     carries the landingzones sub, LESSON 23)
#   Azure/avm-res-search-searchservice/azurerm 0.3.0 (latest; azurerm-shaped -
#     takes resource_group_name, NOT parent_id)
#
# Boundary (design doc section 1): NO Foundry projects/agents (0.11.1 defaults
# verified in the tag source: allow_project_management defaults false and
# default_project defaults null, so NO project is created - both left unset), NO
# RAG pipeline/indexes/shared private links, NO Document Intelligence, NO second
# model, NO PTU. Zero firewall/UDR/NSG delta (section 5): all data-plane traffic
# rides the PEs; inference is served through the account PE.

# ---------------------------------------------------------------------------
# Microsoft Foundry account (kind AIServices) + gpt-5.4-nano deployment + PE
# ---------------------------------------------------------------------------

module "foundry" {
  source  = "Azure/avm-res-cognitiveservices-account/azurerm"
  version = "0.11.1"

  for_each = var.enable_ai_platform ? { main = "main" } : {}

  name      = "aif-bank-data-p1-${var.org_prefix}-${var.environment}"
  kind      = "AIServices"
  sku_name  = "S0"
  parent_id = azurerm_resource_group.workload.id
  location  = var.primary_location

  # REQUIRED for PE + AAD data-plane access; globally unique (pre-clearance
  # availability check per design doc section 7).
  custom_subdomain_name = "aif-bank-data-p1-${var.org_prefix}-${var.environment}"

  # BOTH controls are required (design doc section 3): pna false satisfies Deny
  # member 0725b4dd; network_acls default Deny satisfies member 037eea7a, which
  # checks networkAcls.defaultAction - pna false alone does NOT satisfy it.
  public_network_access_enabled = false
  network_acls = {
    default_action = "Deny"
  }

  # AAD-only estate bar (keys off, B2/B3 precedent).
  local_auth_enabled = false

  # Future RAG wiring target; no role assignments at B6.
  managed_identities = {
    system_assigned = true
  }

  # ONE deployment (ADR-051): gpt-5.4-nano 2026-03-17, the newest current-GA
  # nano-class chat model in eastus2 (the founding-design examples are Deprecating
  # in the live catalog - LESSON 40 class). DataZoneStandard = US data-zone
  # processing (banking residency posture); capacity 10 = 10K TPM of the 2000
  # K-TPM verified free. GlobalStandard is the recorded fallback if DataZone caps.
  cognitive_deployments = {
    chat = {
      name = "chat"
      model = {
        format  = "OpenAI"
        name    = "gpt-5.4-nano"
        version = "2026-03-17"
      }
      scale = {
        type     = "DataZoneStandard"
        capacity = 10
      }
    }
  }

  # ONE account PE with the THREE-zone group (cognitiveservices + openai +
  # services.ai) per current Foundry PE guidance - one PE serves all three FQDN
  # families. The module hardcodes the PE subresource to "account" (verified in
  # the v0.11.1 main.privateendpoint.tf source). Zones looked up in dns_links.tf;
  # openai/cognitiveservices spoke-linked since B1, services.ai linked at B6.
  private_endpoints_manage_dns_zone_group = true

  private_endpoints = {
    account = {
      name               = "pe-aif-bank-data-p1-${var.org_prefix}-${var.environment}"
      subnet_resource_id = module.spoke_vnet.subnets["private-endpoints"].resource_id
      private_dns_zone_resource_ids = [
        data.azurerm_private_dns_zone.linked["cognitiveservices"].id,
        data.azurerm_private_dns_zone.linked["openai"].id,
        data.azurerm_private_dns_zone.linked["servicesai"].id,
      ]
      private_service_connection_name = "psc-aif-bank-data-p1"
      tags                            = local.common_tags
    }
  }

  diagnostic_settings = {
    platform_law = {
      name                  = "diag-aif-bank-data-p1-${var.org_prefix}-${var.environment}"
      workspace_resource_id = var.platform_law_workspace_id
      log_groups            = ["allLogs"]
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# AI Search basic + PE
# ---------------------------------------------------------------------------

module "search" {
  source  = "Azure/avm-res-search-searchservice/azurerm"
  version = "0.3.0"

  for_each = var.enable_ai_platform ? { main = "main" } : {}

  # Globally unique DNS name (pre-clearance availability check); lowercase +
  # hyphen legal, 30 chars rendered at poc defaults (limit 60).
  name                = "srch-bank-data-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = var.primary_location

  # Smallest PE-capable tier (free has no PE support), smallest basic topology.
  sku             = "basic"
  partition_count = 1
  replica_count   = 1

  # pna false satisfies Deny member ee980b6d; local auth off = AAD-only estate
  # bar. authentication_failure_mode deliberately left unset (defaults null -
  # only meaningful when key auth is on).
  public_network_access_enabled = false
  local_authentication_enabled  = false

  # Future RAG outbound identity; no role assignments at B6.
  managed_identities = {
    system_assigned = true
  }

  # ONE PE on the search zone (live + spoke-linked since B1); module-managed
  # zone group (the module hardcodes subresource "searchService" - verified in
  # the v0.3.0 main.privateendpoint.tf source).
  private_endpoints_manage_dns_zone_group = true

  private_endpoints = {
    search = {
      name                            = "pe-srch-bank-data-p1-${var.org_prefix}-${var.environment}"
      subnet_resource_id              = module.spoke_vnet.subnets["private-endpoints"].resource_id
      private_dns_zone_resource_ids   = [data.azurerm_private_dns_zone.linked["search"].id]
      private_service_connection_name = "psc-srch-bank-data-p1"
      tags                            = local.common_tags
    }
  }

  diagnostic_settings = {
    platform_law = {
      name                  = "diag-srch-bank-data-p1-${var.org_prefix}-${var.environment}"
      workspace_resource_id = var.platform_law_workspace_id
      log_groups            = ["allLogs"]
    }
  }

  tags = local.common_tags
}
