# Purpose: online-p1 landing zone — internet-facing spoke with Application Gateway WAF_v2
#          and Azure Static Web App; peered to the primary hub.
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-05-14
#
# Architecture:
#   - Spoke VNet (10.20.0.0/16) peered to primary hub VNet (eastus2)
#   - snet-appgateway (/24) — Application Gateway WAF_v2; NO firewall UDR on this subnet
#     (App Gateway WAF_v2 is incompatible with UDRs pointing to NVAs on its own subnet)
#   - snet-workload (/24) and snet-private-endpoints (/24) — firewall UDR applied
#   - Application Gateway WAF_v2 with OWASP 3.2 ruleset (Prevention mode by default)
#   - Azure Static Web App (Standard tier) — hosted behind the App Gateway
#
# DEVIATIONS:
#   - Azure/avm-res-web-staticsite/azurerm does not exist (HTTP 404 on registry 2026-05-14);
#     using native azurerm_static_web_app instead.
#   - App Gateway configured with HTTP (port 80) listener only. HTTPS/TLS termination
#     requires a certificate; add ssl_certificate block and HTTPS listener in Section 12
#     (Acceptance Criteria hardening) once a certificate is provisioned in the Security KV.

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "online-p1"
      Owner              = "platform-team"
      Workload           = "online-p1"
      DataClassification = "Public"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
    },
    var.tags
  )

  # Subnet prefixes computed from spoke_address_space (default 10.20.0.0/16).
  snet_appgateway = cidrsubnet(var.spoke_address_space, 8, 0) # /24 — App Gateway (requires /24 minimum for WAF_v2)
  snet_workload   = cidrsubnet(var.spoke_address_space, 8, 1) # /24 — workload tier
  snet_pe         = cidrsubnet(var.spoke_address_space, 8, 2) # /24 — private endpoints
}

# ---------------------------------------------------------------------------
# Resource Groups
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "network" {
  name     = "rg-online-p1-network-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-online-p1-shared-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "workload" {
  name     = "rg-online-p1-workload-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-online-p1-monitoring-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Network Security Groups
# ---------------------------------------------------------------------------

# NSG for the App Gateway subnet — must allow GatewayManager service tag
# and Azure Load Balancer probes per Microsoft requirements.
resource "azurerm_network_security_group" "appgw" {
  name                = "nsg-appgw-online-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.primary_location

  security_rule {
    name                       = "Allow-GatewayManager"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
    description                = "Required for App Gateway WAF_v2 management plane communication."
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    description                = "Required for App Gateway health probes."
  }

  security_rule {
    name                       = "Allow-HTTP-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    description                = "Allow inbound HTTP from internet to App Gateway public frontend."
  }

  tags = local.common_tags
}

# NSG for workload and PE subnets.
resource "azurerm_network_security_group" "workload" {
  name                = "nsg-workload-online-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.primary_location

  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
    description                = "Belt-and-suspenders deny; firewall UDR is the primary control."
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Route Table — applied to workload + PE subnets only (NOT App Gateway subnet)
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "workload" {
  name                          = "rt-workload-online-p1-${var.org_prefix}-${var.environment}"
  resource_group_name           = azurerm_resource_group.network.name
  location                      = var.primary_location
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.primary_firewall_private_ip
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Spoke VNet
# Module: Azure/avm-res-network-virtualnetwork/azurerm v0.17.1
# ---------------------------------------------------------------------------

module "spoke_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.17.1"

  name          = "vnet-spoke-online-p1-${var.org_prefix}-${var.environment}"
  parent_id     = azurerm_resource_group.network.id # v0.17.1: parent_id (RG resource ID) replaces resource_group_name
  location      = var.primary_location
  address_space = [var.spoke_address_space]

  subnets = {
    appgateway = {
      name             = "snet-appgateway"
      address_prefixes = [local.snet_appgateway]

      # No route_table on this subnet — App Gateway WAF_v2 is incompatible with
      # UDRs to NVAs (Azure Firewall). Internet traffic enters the App Gateway
      # directly; its backend traffic exits to the workload subnet.
      network_security_group = {
        id = azurerm_network_security_group.appgw.id
      }
    }

    workload = {
      name             = "snet-workload"
      address_prefixes = [local.snet_workload]

      route_table = {
        id = azurerm_route_table.workload.id
      }

      network_security_group = {
        id = azurerm_network_security_group.workload.id
      }
    }

    private-endpoints = {
      name             = "snet-private-endpoints"
      address_prefixes = [local.snet_pe]

      private_endpoint_network_policies = "Disabled"

      route_table = {
        id = azurerm_route_table.workload.id
      }

      network_security_group = {
        id = azurerm_network_security_group.workload.id
      }
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# VNet Peering — spoke ↔ primary hub
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-online-p1-to-primary-hub"
  resource_group_name       = azurerm_resource_group.network.name
  virtual_network_name      = module.spoke_vnet.name
  remote_virtual_network_id = var.primary_hub_vnet_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider                  = azurerm.connectivity
  name                      = "peer-primary-hub-to-online-p1"
  resource_group_name       = var.primary_hub_rg_name
  virtual_network_name      = var.primary_hub_vnet_name
  remote_virtual_network_id = module.spoke_vnet.resource_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

# ---------------------------------------------------------------------------
# Static Web App (Standard tier)
#
# DEVIATION: Azure/avm-res-web-staticsite/azurerm does not exist on the
# Terraform Registry (HTTP 404 confirmed 2026-05-14). Using native
# azurerm_static_web_app resource. Migrate to AVM module when available.
# ---------------------------------------------------------------------------

resource "azurerm_static_web_app" "this" {
  name                = "stapp-online-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = var.primary_location
  sku_tier            = "Standard"
  sku_size            = "Standard"

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Public IP — App Gateway WAF_v2 frontend
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "appgw" {
  name                = "pip-appgw-online-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.primary_location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# WAF Policy — OWASP 3.2 in Prevention mode
# ---------------------------------------------------------------------------

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "wafpol-online-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.primary_location

  policy_settings {
    enabled                     = true
    mode                        = var.waf_mode
    request_body_check          = true
    max_request_body_size_in_kb = 128
    file_upload_limit_in_mb     = 100
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Application Gateway WAF_v2
#
# DEVIATION: Using native azurerm_application_gateway instead of
# Azure/avm-res-network-applicationgateway/azurerm v0.5.2. The AVM module
# requires deeply nested inputs (gateway_ip_configuration, backend_address_pools,
# backend_http_settings, frontend_ports, http_listeners, request_routing_rules)
# whose exact object types were not fully verified against the module source.
# Migrate to AVM module when interface is confirmed.
#
# HTTP only: HTTPS listener deferred to Section 12 (certificate provisioning
# in the Security Key Vault).
# ---------------------------------------------------------------------------

resource "azurerm_application_gateway" "this" {
  name                = "appgw-online-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.primary_location

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = var.appgw_capacity
  }

  zones = ["1", "2", "3"]

  firewall_policy_id = azurerm_web_application_firewall_policy.this.id

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = module.spoke_vnet.subnets["appgateway"].resource_id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "public-frontend"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  backend_address_pool {
    name  = "backend-pool-static-site"
    fqdns = [azurerm_static_web_app.this.default_host_name]
  }

  backend_http_settings {
    name                                = "backend-settings-https"
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 30
    pick_host_name_from_backend_address = true
  }

  http_listener {
    name                           = "listener-http"
    frontend_ip_configuration_name = "public-frontend"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rule-http-to-backend"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = "listener-http"
    backend_address_pool_name  = "backend-pool-static-site"
    backend_http_settings_name = "backend-settings-https"
  }

  tags = local.common_tags

  depends_on = [module.spoke_vnet, azurerm_public_ip.appgw]
}

# ---------------------------------------------------------------------------
# Diagnostic settings — App Gateway → Platform LA workspace
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                       = "diag-appgw-to-platform-law"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = var.platform_law_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
