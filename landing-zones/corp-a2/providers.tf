# Purpose: Provider configuration for the corp-a2 landing zone root module (DR spoke).
# Section: 9 - Landing Zone Spokes
# Last updated: 2026-07-10
#
# Apply order: After platform/connectivity (secondary hub VNet ID and firewall IP required).
#
# Providers:
#   azurerm (default) -> Landing Zones subscription - all corp-a2 spoke resources (centralus)
#   azurerm.connectivity -> Connectivity subscription - hub-to-spoke return VNet peering only
#   azapi (default) -> Landing Zones subscription - anchors the AVM RSV +
#     app_service_plan azapi parent_id to the correct sub

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.5"
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

# Default azapi provider MUST be anchored to the Landing Zones sub (same fix as
# platform/identity providers.tf, commit c901d88). The
# AVM RSV and app_service_plan modules build parent_id from
# data.azapi_client_config.current.subscription_id (this provider's sub), not from
# the azurerm default. Without this block azapi fell back to ARM_SUBSCRIPTION_ID
# (the management sub) and the RSV/plan PUT hit RGs that only exist in the
# landingzones sub: 404 ResourceGroupNotFound (corp-a1 run 29124283164). The spoke
# VNet module is immune (takes a full RG resource ID) but inherits this harmlessly.
provider "azapi" {
  subscription_id = var.landingzones_subscription_id
}

provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  features {}
}

provider "modtm" {}
