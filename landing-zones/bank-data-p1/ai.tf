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

  # ONE deployment (ADR-051): gpt-5.4-nano 2026-03-17, selected as the newest
  # current-GA nano-class chat model (the founding-design examples were Deprecating
  # in the live catalog - LESSON 40 class). Model catalogs are PER REGION and the
  # account follows var.primary_location, which ADR-069 moved to centralus, so this
  # selection is re-verified in the centralus catalog by pre-clearance check RC-3
  # before dispatch. DataZoneStandard = US data-zone processing (banking residency
  # posture); capacity 10 = 10K TPM of the 2000 K-TPM verified free. GlobalStandard
  # is the recorded fallback if DataZone caps.
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

  # ONE account PE (module builds the NIC + subresource "account", hardcoded in
  # the v0.11.1 main.privateendpoint.tf source). The THREE-zone group
  # (cognitiveservices + openai + services.ai) is authored NATIVELY below, NOT by
  # the module.
  #
  # MODULE BUG WORKAROUND (fix-spec CLASS 2, docs/preclearance/b6-ai-platform.md
  # addendum 2026-07-19; ADR-051 correction): 0.11.1's PE interfaces submodule
  # names EVERY privateDnsZoneConfig "default"
  # (.terraform/modules/foundry.private_endpoint_interfaces/locals.private_endpoints.tf
  # line 15), so a multi-zone set on ONE PE collides with DuplicateResourceName
  # ("two child resources with the same name (default)"). Single-zone PEs (e.g.
  # datalake.tf) are unaffected, which is why B5 was clean. Setting the
  # module-level toggle false makes the module build ONLY the account + PE NIC
  # (azapi_resource.private_endpoints_unmanaged) and emit NO zone group; the
  # native azapi_resource.foundry_pe_dns_zone_group below supplies the group with
  # three explicitly-named configs, killing the collision.
  private_endpoints_manage_dns_zone_group = false

  private_endpoints = {
    account = {
      name                            = "pe-aif-bank-data-p1-${var.org_prefix}-${var.environment}"
      subnet_resource_id              = module.spoke_vnet.subnets["private-endpoints"].resource_id
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
# Foundry account PE - native private DNS zone group (3 configs)
# ---------------------------------------------------------------------------
# DEVIATION (fix-spec CLASS 2, docs/preclearance/b6-ai-platform.md addendum
# 2026-07-19; ADR-051 post-apply correction): native privateDnsZoneGroup for the
# Foundry account PE, replacing the module-managed group disabled above. The
# 0.11.1 module cannot express a multi-zone group without a DuplicateResourceName
# collision (every config named "default"). Here each config carries a UNIQUE
# name, so the three-zone set (cognitiveservices + openai + services.ai) is legal.
#
# Body shape mirrors the module's own interfaces submodule
# (.terraform/modules/foundry.private_endpoint_interfaces/locals.private_endpoints.tf):
# type Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01 (the
# api-version the module itself pins for this child), body =
# properties.privateDnsZoneConfigs[] of { name, properties.privateDnsZoneId }; a
# zone group is a child proxy resource with no location. parent_id is the
# module-created PE (module output private_endpoints returns the unmanaged PE map
# when zone-group management is off - verified in v0.11.1 outputs.tf). Zone IDs
# come from the existing data.azurerm_private_dns_zone lookups in dns_links.tf
# (central connectivity sub) - never hardcoded. Uses the root's anchored default
# azapi provider (LESSON 23).
resource "azapi_resource" "foundry_pe_dns_zone_group" {
  for_each = var.enable_ai_platform ? { main = "main" } : {}

  name      = "default"
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01"
  parent_id = module.foundry[each.key].private_endpoints["account"].id

  body = {
    properties = {
      privateDnsZoneConfigs = [
        {
          name = "cognitiveservices"
          properties = {
            privateDnsZoneId = data.azurerm_private_dns_zone.linked["cognitiveservices"].id
          }
        },
        {
          name = "openai"
          properties = {
            privateDnsZoneId = data.azurerm_private_dns_zone.linked["openai"].id
          }
        },
        {
          name = "servicesai"
          properties = {
            privateDnsZoneId = data.azurerm_private_dns_zone.linked["servicesai"].id
          }
        },
      ]
    }
  }
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
  # var.search_location, NOT var.primary_location. As of ADR-069 the two are EQUAL
  # (both centralus), so this is no longer a deviation and the ADR-051 cross-region
  # PE no longer exists: service and PE NIC are both in the primary region, and
  # deviation register entry d7 is retired by construction.
  # The separate input is KEPT on purpose. AI Search returned
  # InsufficientResourcesAvailable (regional capacity exhaustion) in what is now the
  # SECONDARY region on apply 29678062833 (fix-spec CLASS 1,
  # docs/preclearance/b6-ai-platform.md addendum 2026-07-19; ADR-051 correction), and
  # this input is the proven escape hatch if centralus ever runs short too.
  location = var.search_location

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
      name = "pe-srch-bank-data-p1-${var.org_prefix}-${var.environment}"
      # DO NOT DELETE THIS location LINE (ADR-069 decision 5). It is numerically a
      # no-op while search_location == primary_location, and load-bearing the moment
      # they differ. The PE NIC MUST match the region of its subnet
      # (snet-private-endpoints, always var.primary_location). Without this override
      # the per-PE location (v0.3.0 variables.tf line 218, consumed at
      # main.privateendpoint.tf line 5 as coalesce(each.value.location,
      # var.location)) falls through to the SERVICE location and collides with the
      # subnet - the actual apply 29678062833 PE failure (architect rerun-addendum
      # correction). Removing it re-arms exactly that failure.
      location                        = var.primary_location
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
