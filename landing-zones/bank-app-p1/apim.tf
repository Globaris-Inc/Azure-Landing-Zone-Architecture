# Purpose: bank-app-p1 API platform (wave B4) - APIM Developer stv2 in internal VNet
#          mode injected into snet-apim, the dedicated APIM route table (forced-tunneling
#          resolution part (a)), the scoped private DNS zone + apex A record + VNet links
#          (ADR-047 scoped-FQDN ruling - the apex azure-api.net zone is NOT SUPPORTED per
#          current MS Learn), one mock health API for QA data-plane evidence, and
#          diagnostics to the platform LAW. ALL resources gated behind
#          var.enable_api_platform (default false, LESSON 42 flag pattern).
# Section: Banking wave B4 (docs/b4-apim-platform-design.md sections 3-5; ADR-047)
# Last updated: 2026-07-18
#
# Module: Azure/avm-res-apimanagement-service/azurerm 0.9.0 (pin re-verified on the
# Terraform Registry 2026-07-18; input shapes and outputs read from the registry-pinned
# source commit for 0.9.0 - the apis input carries operations + operation-level policy,
# so NO native azurerm_api_management_api* fallback is needed).
#
# ORDERING IS HARD (design doc section 7): apply platform/connectivity with
# rcg-apim-egress-primary FIRST - the APIM create needs the firewall to pass its
# force-tunneled dependency traffic mid-provision, or the create hangs toward the 3h
# timeout. Duration reality: this is the longest single create of the build (30-90+ min,
# occasionally ~3h). Mid-apply-death disposition: design doc section 9 (check
# provisioningState live BEFORE any retry; import if Succeeded - LESSON 46 class).

# ---------------------------------------------------------------------------
# Dedicated route table for snet-apim (forced-tunneling resolution part (a)).
# Carries BOTH the estate 0.0.0.0/0 -> firewall default route AND the ApiManagement
# service-tag route with next hop Internet: stv2 control-plane traffic enters on 3443
# from the ApiManagement tag and its return path MUST NOT ride the firewall
# (asymmetric-routing failure, verified against MS Learn 2026-07-18). The shared
# rt-spoke is deliberately NOT touched - putting the service-tag route there would
# bypass the firewall for the AKS and PE subnets too, silently widening the exception.
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "apim" {
  for_each = var.enable_api_platform ? { main = "main" } : {}

  name                          = "rt-apim-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name           = azurerm_resource_group.network.name
  location                      = var.primary_location
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.primary_firewall_private_ip
  }

  # UDR address_prefix accepts service tags (GA since 2020; syntax re-confirmed on
  # azurerm 4.x at build). Management-plane return path only - data-plane and all
  # other snet-apim egress still rides the firewall default route above.
  route {
    name           = "apim-management-return"
    address_prefix = "ApiManagement"
    next_hop_type  = "Internet"
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# API Management - Developer stv2, internal VNet mode, no public IP, no zones
# ---------------------------------------------------------------------------

module "apim" {
  source  = "Azure/avm-res-apimanagement-service/azurerm"
  version = "0.9.0"

  for_each = var.enable_api_platform ? { main = "main" } : {}

  # LESSON 27 rendered-length check: "apim-bank-app-p1-" (17) + org "globaris" (8) +
  # "-" (1) + env "poc" (3) = 29 chars, within the 1-50 APIM bound. Global DNS name;
  # verified AVAILABLE via checkNameAvailability at design time (2026-07-18).
  name                = "apim-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.primary_location

  # Recorded intent (founding design 2.2 / B1 main.tf; ADR-047): Developer is the
  # VNet-capable POC tier (~$1.6/day). Premium + zones + multi-region is the
  # production design target (design doc section 10), NOT deployed.
  sku_name = "Developer_1"

  publisher_name  = "Globaris Banking Platform"
  publisher_email = var.apim_publisher_email

  # Internal mode: gateway answers only inside the VNet on its private VIP. NO
  # public_ip_address_id (not required for stv2 internal injection since May 2024,
  # verified against MS Learn 2026-07-18) and NO zones (Premium classic only).
  # public_network_access_enabled stays the module default: it governs only the
  # management plane, and the corp ApiManDenyPublicIP policy member is
  # AuditIfNotExists (live sweep, design doc section 2).
  virtual_network_type      = "Internal"
  virtual_network_subnet_id = module.spoke_vnet.subnets["apim"].resource_id

  managed_identities = {
    system_assigned = true
  }

  # One mock health API so QA has a data-plane surface (design doc section 3): the
  # 0.9.0 apis input carries operations and operation-level policies natively.
  # subscription_required = false: the QA evidence path is a bare in-VNet curl of
  # /health/ping (no subscription key); mock-response returns the operation's
  # declared 200 without any backend.
  apis = {
    health = {
      display_name          = "Health Probe API"
      path                  = "health"
      protocols             = ["https"]
      description           = "B4 QA data-plane probe - mock response only, no backend."
      subscription_required = false

      operations = {
        ping = {
          display_name = "Health ping"
          method       = "GET"
          url_template = "/ping"
          description  = "Returns a mocked 200 for QA data-plane evidence."

          responses = [
            {
              status_code = 200
              description = "OK (mocked)."
            }
          ]

          policy = {
            xml_content = <<-XML
              <policies>
                <inbound>
                  <base />
                  <mock-response status-code="200" content-type="application/json" />
                </inbound>
                <backend>
                  <base />
                </backend>
                <outbound>
                  <base />
                </outbound>
                <on-error>
                  <base />
                </on-error>
              </policies>
            XML
          }
        }
      }
    }
  }

  # Estate diagnostics pattern: module defaults send the allLogs group + AllMetrics.
  diagnostic_settings = {
    platform_law = {
      name                  = "diag-apim-bank-app-p1-${var.org_prefix}-${var.environment}"
      workspace_resource_id = var.platform_law_workspace_id
    }
  }

  # No timeouts input on the 0.9.0 service resource: the azurerm APIM create default
  # (3h) governs, which covers the documented worst case (design doc section 9).

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Scoped private DNS zone for the gateway FQDN (ADR-047 DNS ruling).
# Internal-mode APIM registers NOTHING in DNS and answers only on its hostnames -
# without this zone the gateway is unreachable even in-VNet. The zone is scoped to
# the EXACT instance FQDN: a private zone for the apex azure-api.net is explicitly
# NOT SUPPORTED (MS Learn internal-vnet doc, updated 2026-06-25 - the widespread
# community apex-zone pattern is a stale trap, LESSON 40 class) and would shadow
# every other azure-api.net consumer. Central rg-dns placement in the Connectivity
# sub via the azurerm.connectivity provider (dns_links.tf cross-sub precedent).
# Design-only, NOT created: developer/portal/management/scm records (portal not
# published at POC; direct management API retired March 2025).
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "apim" {
  for_each = var.enable_api_platform ? { main = "main" } : {}

  provider            = azurerm.connectivity
  name                = "apim-bank-app-p1-${var.org_prefix}-${var.environment}.azure-api.net"
  resource_group_name = var.private_dns_rg_name
  tags                = local.common_tags
}

# Apex A record -> the APIM private VIP. private_ip_addresses is a list output on the
# pinned 0.9.0 module (azurerm_api_management.this.private_ip_addresses); a Developer
# internal-mode instance has exactly one VIP - first entry per the design contract.
# Known after the APIM create completes; same-apply chaining is fine.
resource "azurerm_private_dns_a_record" "apim_apex" {
  for_each = var.enable_api_platform ? { main = "main" } : {}

  provider            = azurerm.connectivity
  name                = "@"
  zone_name           = azurerm_private_dns_zone.apim[each.key].name
  resource_group_name = var.private_dns_rg_name
  ttl                 = 300
  records             = [module.apim[each.key].private_ip_addresses[0]]
}

# Zone links: bank-app-p1 spoke (QA + future AKS consumers resolve in-spoke) and the
# PRIMARY hub (hub-connected clients via the DNS Private Resolver path). Secondary
# hub link is design-only until a multi-region APIM exists (design doc section 4).
resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  for_each = var.enable_api_platform ? {
    spoke = module.spoke_vnet.resource_id
    hub   = var.primary_hub_vnet_id
  } : {}

  provider              = azurerm.connectivity
  name                  = "vnetlink-apim-bank-app-p1-${each.key}-${var.org_prefix}-${var.environment}"
  resource_group_name   = var.private_dns_rg_name
  private_dns_zone_name = azurerm_private_dns_zone.apim["main"].name
  virtual_network_id    = each.value
  registration_enabled  = false
  tags                  = local.common_tags
}
