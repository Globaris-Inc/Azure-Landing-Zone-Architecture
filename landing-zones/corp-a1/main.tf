# Purpose: corp-a1 landing zone — private spoke VNet (eastus2), App Service + Azure SQL
#          with Private Endpoint, peered to the primary hub.
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-05-14
#
# Architecture:
#   - Spoke VNet (10.10.0.0/16) peered to primary hub VNet (eastus2)
#   - All subnet traffic forced through Azure Firewall Premium via UDR
#   - App Service (Linux B2) with VNet integration in snet-integration (/26)
#   - Azure SQL Server (Entra-only auth, no public access) + SQL DB (GP_S_Gen5_1 serverless)
#   - SQL Private Endpoint in snet-private-endpoints (/24)
#   - Private DNS zone wiring deferred to Section 4

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "corp-a1"
      Owner              = "platform-team"
      Workload           = "corp-a1"
      DataClassification = "Internal"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
    },
    var.tags
  )

  # Subnet prefixes computed from spoke_address_space (default 10.10.0.0/16).
  snet_integration = cidrsubnet(var.spoke_address_space, 10, 0) # /26 — App Service VNet integration (needs /26+ for scale)
  snet_data        = cidrsubnet(var.spoke_address_space, 8, 1)  # /24 — data tier (reserved)
  snet_pe          = cidrsubnet(var.spoke_address_space, 8, 2)  # /24 — private endpoints
}

# ---------------------------------------------------------------------------
# Resource Groups (4 per spoke — network, shared, workload, monitoring)
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "network" {
  name     = "rg-corp-a1-network-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-corp-a1-shared-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "workload" {
  name     = "rg-corp-a1-workload-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-corp-a1-monitoring-${var.org_prefix}-${var.environment}"
  location = var.primary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Network Security Group — deny Internet inbound; applied to data + PE subnets
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "spoke" {
  name                = "nsg-spoke-corp-a1-${var.org_prefix}-${var.environment}"
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
# Route Table — default route forces all spoke traffic through Azure Firewall
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "spoke" {
  name                          = "rt-spoke-corp-a1-${var.org_prefix}-${var.environment}"
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
# Confirmed on registry.terraform.io 2026-05-14
# ---------------------------------------------------------------------------

module "spoke_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "0.17.1"

  name                = "vnet-spoke-corp-a1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.primary_location
  address_space       = [var.spoke_address_space]

  subnets = {
    integration = {
      name             = "snet-integration"
      address_prefixes = [local.snet_integration]

      # Delegation required for App Service regional VNet integration.
      delegations = [{
        name = "delegation-app-service"
        service_delegation = {
          name = "Microsoft.Web/serverFarms"
        }
      }]

      route_table = {
        id = azurerm_route_table.spoke.id
      }
    }

    data = {
      name             = "snet-data"
      address_prefixes = [local.snet_data]

      route_table = {
        id = azurerm_route_table.spoke.id
      }

      network_security_group = {
        id = azurerm_network_security_group.spoke.id
      }
    }

    private-endpoints = {
      name             = "snet-private-endpoints"
      address_prefixes = [local.snet_pe]

      # Required to allow Private Endpoint NICs in this subnet.
      private_endpoint_network_policies = "Disabled"

      route_table = {
        id = azurerm_route_table.spoke.id
      }

      network_security_group = {
        id = azurerm_network_security_group.spoke.id
      }
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# VNet Peering — spoke ↔ primary hub (bidirectional, cross-subscription)
# ---------------------------------------------------------------------------

# Spoke → Hub (in Landing Zones subscription, default provider)
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-corp-a1-to-primary-hub"
  resource_group_name       = azurerm_resource_group.network.name
  virtual_network_name      = module.spoke_vnet.name
  remote_virtual_network_id = var.primary_hub_vnet_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

# Hub → Spoke return peering (in Connectivity subscription, connectivity alias provider)
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider                  = azurerm.connectivity
  name                      = "peer-primary-hub-to-corp-a1"
  resource_group_name       = var.primary_hub_rg_name
  virtual_network_name      = var.primary_hub_vnet_name
  remote_virtual_network_id = module.spoke_vnet.resource_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

# ---------------------------------------------------------------------------
# App Service Plan (Linux B2)
# Module: Azure/avm-res-web-serverfarm/azurerm v2.0.4
# Confirmed on registry.terraform.io 2026-05-14
# ---------------------------------------------------------------------------

module "app_service_plan" {
  source  = "Azure/avm-res-web-serverfarm/azurerm"
  version = "2.0.4"

  name      = "asp-corp-a1-${var.org_prefix}-${var.environment}"
  location  = var.primary_location
  parent_id = azurerm_resource_group.workload.id
  os_type   = "Linux"
  sku_name  = var.app_service_sku

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# App Service (Linux Node.js 20 LTS, VNet-integrated)
# Module: Azure/avm-res-web-site/azurerm v0.22.0
# Confirmed on registry.terraform.io 2026-05-14
# ---------------------------------------------------------------------------

module "app_service" {
  source  = "Azure/avm-res-web-site/azurerm"
  version = "0.22.0"

  name                     = "app-corp-a1-${var.org_prefix}-${var.environment}"
  location                 = var.primary_location
  parent_id                = azurerm_resource_group.workload.id
  service_plan_resource_id = module.app_service_plan.resource_id

  # VNet integration — routes outbound App Service traffic through the spoke VNet.
  virtual_network_subnet_id = module.spoke_vnet.subnets["integration"].resource_id

  https_only = true

  site_config = {
    always_on                   = false # Not supported on B-series plans
    vnet_route_all_enabled      = true  # Force all outbound through VNet (and then Firewall)
    ftps_state                  = "Disabled"
    http2_enabled               = true
    minimum_tls_version         = "1.2"
    scm_minimum_tls_version     = "1.2"
    scm_use_main_ip_restriction = true
    application_stack = {
      node_version = "20-lts"
    }
  }

  app_settings = {
    "WEBSITE_RUN_FROM_PACKAGE" = "1"
  }

  diagnostic_settings = {
    to_platform_law = {
      name                      = "diag-app-to-platform-law"
      workspace_resource_id     = var.platform_law_workspace_id
      log_categories_and_groups = ["allLogs"]
      metric_categories         = ["AllMetrics"]
    }
  }

  tags = local.common_tags

  depends_on = [module.spoke_vnet]
}

# ---------------------------------------------------------------------------
# Azure SQL Server + Database
#
# DEVIATION: Using native azurerm_mssql_server / azurerm_mssql_database instead of
# Azure/avm-res-sql-server/azurerm v0.2.1. The AVM module's `databases` variable
# was not present in the published source at v0.2.1 (confirmed 2026-05-14).
# Migrate to AVM module when the databases interface is stable.
# ---------------------------------------------------------------------------

resource "random_id" "sql_suffix" {
  byte_length = 4
}

resource "azurerm_mssql_server" "this" {
  name                = "sql-corp-a1-${var.org_prefix}-${var.environment}-${random_id.sql_suffix.hex}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = var.primary_location
  version             = "12.0"
  minimum_tls_version = "1.2"

  # Entra-only authentication — no SQL local admin login.
  azuread_administrator {
    login_username              = var.sql_aad_admin_login
    object_id                   = var.sql_aad_admin_object_id
    azuread_authentication_only = true
  }

  # Public access disabled — SQL is reachable only via the Private Endpoint.
  # DEVIATION: GitHub Actions runner must be in-VNet or connected via VPN Gateway
  # to apply SQL-related resources. See bootstrap/README.md for self-hosted runner
  # options if the default GitHub-hosted runner cannot reach the PE.
  public_network_access_enabled = false

  tags = local.common_tags
}

resource "azurerm_mssql_database" "app" {
  name      = "sqldb-app-corp-a1-${var.org_prefix}-${var.environment}"
  server_id = azurerm_mssql_server.this.id

  sku_name    = "GP_S_Gen5_1" # Serverless, 1 vCore; auto-pauses after idle period
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb = 5

  # Serverless auto-pause: pause after 60 minutes of inactivity to reduce POC cost.
  auto_pause_delay_in_minutes = 60
  min_capacity                = 0.5

  # Zone redundancy is not available for serverless SKU.
  zone_redundant = false

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# SQL Private Endpoint
#
# DEVIATION: Private DNS zone group omitted — centralised Private DNS zones for
# privatelink.database.windows.net are deployed in Section 4 (Private Endpoints
# + Private DNS). The PE NIC IP is allocated here; DNS wiring follows in Section 4.
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "sql" {
  name                = "pe-sql-corp-a1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.primary_location
  subnet_id           = module.spoke_vnet.subnets["private-endpoints"].resource_id

  private_service_connection {
    name                           = "psc-sql-corp-a1"
    private_connection_resource_id = azurerm_mssql_server.this.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  tags = local.common_tags

  depends_on = [module.spoke_vnet]
}
