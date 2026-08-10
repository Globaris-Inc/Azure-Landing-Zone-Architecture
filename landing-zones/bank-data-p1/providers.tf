# Purpose: Provider configuration for the bank-data-p1 landing zone root module.
# Section: Banking wave B1 - banking network foundation (docs/banking-platform-design.md)
# Last updated: 2026-08-10
#
# Apply order: After platform/connectivity (primary hub VNet ID and firewall IP required).
#
# Providers:
#   azurerm (default) -> Landing Zones subscription - all bank-data-p1 resources
#     (placement per OQ-035 resolution: existing landingzones sub under the Corp MG,
#     conditional on the B1 pre-clearance quota gate)
#   azurerm.connectivity -> Connectivity subscription - hub-to-spoke return VNet peering
#     and Private DNS zone lookups/links
#   azapi (default) -> Landing Zones subscription - anchors any AVM azapi-based module
#     parent_id to the correct sub (prevents wrong-sub 404s, LESSON 23)

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    azapi = {
      # Floor raised 2.5 -> 2.9 (ADR-076 decision 4, 2026-08-10):
      # azapi_resource.dbw_diag_platform_law in databricks.tf uses
      # ignore_other_items_in_list and list_unique_id_property, introduced in
      # azapi v2.9.0 (provider CHANGELOG). The committed lock already selects
      # 2.11.0, which satisfies both the old and new constraint, so this changes
      # what the constraint ADMITS, not what any run USES.
      source  = "Azure/azapi"
      version = "~> 2.9"
    }
    modtm = {
      source  = "Azure/modtm"
      version = "~> 0.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8.1"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13.1"
    }
  }
  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.landingzones_subscription_id
  features {}
}

# Default azapi provider MUST be anchored to the Landing Zones sub (same fix as the
# Section 9 spokes and platform/identity, commit c901d88 / WORKLOG 2026-07-10). AVM
# azapi-based modules build parent_id from data.azapi_client_config.current.subscription_id
# (this provider's sub), not from the azurerm default. Without this block azapi falls
# back to ARM_SUBSCRIPTION_ID (the management sub) and PUTs hit RGs that only exist in
# the landingzones sub: 404 ResourceGroupNotFound. The spoke VNet module is immune
# (takes a full RG resource ID) but inherits this harmlessly; the B5/B6 workload
# modules in this root will need it.
provider "azapi" {
  subscription_id = var.landingzones_subscription_id
}

provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  features {}
}

provider "modtm" {}
