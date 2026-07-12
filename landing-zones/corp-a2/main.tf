# Purpose: corp-a2 landing zone - DR spoke VNet (centralus), App Service + SQL mirroring
#          corp-a1, Recovery Services Vault for Azure Site Recovery.
# Section: 9 - Landing Zone Spokes
# Last updated: 2026-07-10
#
# Architecture:
#   - Spoke VNet (10.11.0.0/16) peered to secondary (DR) hub VNet (centralus)
#   - All subnet traffic forced through secondary Azure Firewall via UDR
#   - App Service (Linux B2) with VNet integration - mirrors corp-a1 workload tier
#   - Azure SQL Server (Entra-only auth) - independent; geo-replication to/from corp-a1
#     can be configured via creation_source_database_id after both spokes are deployed
#   - Recovery Services Vault (Standard, GeoRedundant) for ASR replication
#   - Private Endpoint for SQL (DNS deferred to Section 4)

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  common_tags = merge(
    {
      Environment        = var.environment
      CostCenter         = "corp-a2"
      Owner              = "platform-team"
      Workload           = "corp-a2"
      DataClassification = "Internal"
      BusinessUnit       = var.org_prefix
      CreatedBy          = "terraform"
      ManagedBy          = "terraform"
    },
    var.tags
  )

  # Subnet prefixes computed from spoke_address_space (default 10.11.0.0/16).
  snet_integration = cidrsubnet(var.spoke_address_space, 10, 0) # /26 - App Service VNet integration
  snet_data        = cidrsubnet(var.spoke_address_space, 8, 1)  # /24 - data tier (reserved)
  snet_pe          = cidrsubnet(var.spoke_address_space, 8, 2)  # /24 - private endpoints
}

# ---------------------------------------------------------------------------
# Resource Groups
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "network" {
  name     = "rg-corp-a2-network-${var.org_prefix}-${var.environment}"
  location = var.secondary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-corp-a2-shared-${var.org_prefix}-${var.environment}"
  location = var.secondary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "workload" {
  name     = "rg-corp-a2-workload-${var.org_prefix}-${var.environment}"
  location = var.secondary_location
  tags     = local.common_tags
}

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-corp-a2-monitoring-${var.org_prefix}-${var.environment}"
  location = var.secondary_location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Network Security Group
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "spoke" {
  name                = "nsg-spoke-corp-a2-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.network.name
  location            = var.secondary_location

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
# Route Table
# ---------------------------------------------------------------------------

resource "azurerm_route_table" "spoke" {
  name                          = "rt-spoke-corp-a2-${var.org_prefix}-${var.environment}"
  resource_group_name           = azurerm_resource_group.network.name
  location                      = var.secondary_location
  bgp_route_propagation_enabled = false

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.secondary_firewall_private_ip
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

  name          = "vnet-spoke-corp-a2-${var.org_prefix}-${var.environment}"
  parent_id     = azurerm_resource_group.network.id # v0.17.1: parent_id (RG resource ID) replaces resource_group_name
  location      = var.secondary_location
  address_space = [var.spoke_address_space]

  subnets = {
    integration = {
      name             = "snet-integration"
      address_prefixes = [local.snet_integration]

      delegations = [{
        name = "delegation-app-service"
        service_delegation = {
          name = "Microsoft.Web/serverFarms"
        }
      }]

      route_table = {
        id = azurerm_route_table.spoke.id
      }

      # NSG required to satisfy the landingzones-MG Deny-Subnet-Without-Nsg policy
      # (docs/preclearance/landing-zones.md matrix row 4, OQ-024). Reuses the spoke
      # NSG (deny Internet inbound); App Service regional VNet integration delegated
      # subnets support NSGs and need no inbound rules (egress-only). Clean compliance
      # fix - no exemption.
      network_security_group = {
        id = azurerm_network_security_group.spoke.id
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
# VNet Peering - spoke ↔ secondary hub
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-corp-a2-to-secondary-hub"
  resource_group_name       = azurerm_resource_group.network.name
  virtual_network_name      = module.spoke_vnet.name
  remote_virtual_network_id = var.secondary_hub_vnet_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider                  = azurerm.connectivity
  name                      = "peer-secondary-hub-to-corp-a2"
  resource_group_name       = var.secondary_hub_rg_name
  virtual_network_name      = var.secondary_hub_vnet_name
  remote_virtual_network_id = module.spoke_vnet.resource_id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = false
  use_remote_gateways       = false
}

# ---------------------------------------------------------------------------
# App Service tier (Plan + Site) - mirrors corp-a1 for DR parity
# Module: Azure/avm-res-web-serverfarm/azurerm v2.0.4
#
# DEVIATION (App Service tier gated off - enable_app_service = false, default):
# The landingzones subscription's DEDICATED App Service compute quota is 0
# (ARM ExtendedCode 70007 "Total VMs: 0, required 3", corp-a1 run 29126639533 -
# a Microsoft.Web dedicated-compute offer cap, NOT the Microsoft.Compute quota,
# which was confirmed fine). The App Service Plan create failed on the quota, and
# the App Service depends on the plan, so neither entered state. The App Service
# tier (plan + site) is gated behind var.enable_app_service so the DR spoke
# topology stands. Pre-staged capability: set enable_app_service = true once a
# quota increase is granted, or redesign serverless (Consumption/Flex Functions
# or a Static Web App, as online-p1 uses). Same class as the SQL gate (enable_sql).
# See ADR-032, DECISIONS.md, OPEN-QUESTIONS.md.
# ---------------------------------------------------------------------------

module "app_service_plan" {
  source  = "Azure/avm-res-web-serverfarm/azurerm"
  version = "2.0.4"

  count = var.enable_app_service ? 1 : 0

  name      = "asp-corp-a2-${var.org_prefix}-${var.environment}"
  location  = var.secondary_location
  parent_id = azurerm_resource_group.workload.id
  os_type   = "Linux"
  sku_name  = var.app_service_sku

  # Basic SKU does not support zone redundancy (ARM 52050); the module defaults
  # zone_balancing_enabled to true, so disable it explicitly for the POC. Zone
  # redundancy is not required here and would force a costlier Premium tier.
  zone_balancing_enabled = false

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# App Service - DR mirror of corp-a1 App Service
# Module: Azure/avm-res-web-site/azurerm v0.22.0
# ---------------------------------------------------------------------------

module "app_service" {
  source  = "Azure/avm-res-web-site/azurerm"
  version = "0.22.0"

  count = var.enable_app_service ? 1 : 0

  name                     = "app-corp-a2-${var.org_prefix}-${var.environment}"
  location                 = var.secondary_location
  parent_id                = azurerm_resource_group.workload.id
  service_plan_resource_id = module.app_service_plan[0].resource_id

  virtual_network_subnet_id = module.spoke_vnet.subnets["integration"].resource_id

  https_only = true

  site_config = {
    always_on                   = false
    vnet_route_all_enabled      = true
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

  # Wait for the AsDenyPublicIP Waiver exemption to propagate before the App Service
  # PUT (OQ-024 / ADR-028), otherwise the corp-MG Deny fires on a lost race.
  depends_on = [module.spoke_vnet, time_sleep.wait_corp_policy_exemptions]
}

# ---------------------------------------------------------------------------
# Azure SQL Server + Database (DR - independent; link to corp-a1 via geo-replication)
#
# DEVIATION: Native azurerm resources used (see corp-a1/main.tf deviation note).
#
# DEVIATION (SQL tier gated off - enable_sql = false, default):
# Azure SQL provisioning is restricted in eastus2/centralus for the landingzones
# subscription (ProvisioningDisabled, returned during the server PUT polling - a
# subscription/region restriction, not a code bug). The SQL data tier (server +
# database + private endpoint) is gated behind var.enable_sql so the rest of the DR
# spoke stands. It is pre-staged capability: set enable_sql = true once an allowed
# region/subscription is available or a support-request exception lifts the
# restriction. See DECISIONS.md / OPEN-QUESTIONS.md.
#
# Geo-replication: to configure SQL geo-replication between corp-a1 and corp-a2,
# add a secondary database using creation_source_database_id referencing the
# corp-a1 database ID after both spokes are deployed.
# ---------------------------------------------------------------------------

resource "random_id" "sql_suffix" {
  count       = var.enable_sql ? 1 : 0
  byte_length = 4
}

resource "azurerm_mssql_server" "this" {
  count               = var.enable_sql ? 1 : 0
  name                = "sql-corp-a2-${var.org_prefix}-${var.environment}-${random_id.sql_suffix[0].hex}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = var.secondary_location
  version             = "12.0"
  minimum_tls_version = "1.2"

  azuread_administrator {
    login_username              = var.sql_aad_admin_login
    object_id                   = var.sql_aad_admin_object_id
    azuread_authentication_only = true
  }

  public_network_access_enabled = false

  tags = local.common_tags
}

resource "azurerm_mssql_database" "app" {
  count     = var.enable_sql ? 1 : 0
  name      = "sqldb-app-corp-a2-${var.org_prefix}-${var.environment}"
  server_id = azurerm_mssql_server.this[0].id

  sku_name    = "GP_S_Gen5_1"
  collation   = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb = 5

  auto_pause_delay_in_minutes = 60
  min_capacity                = 0.5

  zone_redundant = false

  tags = local.common_tags
}

resource "azurerm_private_endpoint" "sql" {
  count               = var.enable_sql ? 1 : 0
  name                = "pe-sql-corp-a2-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.secondary_location
  subnet_id           = module.spoke_vnet.subnets["private-endpoints"].resource_id

  private_service_connection {
    name                           = "psc-sql-corp-a2"
    private_connection_resource_id = azurerm_mssql_server.this[0].id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  # azurerm has no standalone azurerm_private_dns_zone_group resource - the zone
  # group is a nested block on the private endpoint. Zone looked up via
  # data.azurerm_private_dns_zone.sql (see dns_links.tf).
  private_dns_zone_group {
    name                 = "pdzg-sql-corp-a2"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.sql.id]
  }

  tags = local.common_tags

  depends_on = [module.spoke_vnet]
}

# ---------------------------------------------------------------------------
# Recovery Services Vault (Azure Site Recovery)
# Module: Azure/avm-res-recoveryservices-vault/azurerm v1.1.3
# Confirmed on registry.terraform.io 2026-05-14
#
# The vault is created here; actual ASR replication policies and VM enrollment
# are configured in Section 13 (Synthetic Workload Layer) once source VMs exist.
# ---------------------------------------------------------------------------

module "recovery_services_vault" {
  source  = "Azure/avm-res-recoveryservices-vault/azurerm"
  version = "1.1.3"

  name                = "rsv-corp-a2-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.secondary_location

  # Standard SKU; RS0 is legacy (pre-2017 vaults only).
  sku = "Standard"

  # GeoRedundant ensures replicated data is durable across region pairs.
  storage_mode_type            = var.rsv_geo_redundant ? "GeoRedundant" : "LocallyRedundant"
  cross_region_restore_enabled = var.rsv_geo_redundant

  soft_delete_enabled           = true
  immutability                  = "Unlocked"
  public_network_access_enabled = false

  tags = local.common_tags
}
