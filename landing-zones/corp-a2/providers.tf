# Purpose: Provider configuration for the corp-a2 landing zone root module (DR spoke).
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-05-14
#
# Apply order: After platform/connectivity (secondary hub VNet ID and firewall IP required).
#
# Providers:
#   azurerm (default) → Landing Zones subscription — all corp-a2 spoke resources (centralus)
#   azurerm.connectivity → Connectivity subscription — hub-to-spoke return VNet peering only

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
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

provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  features {}
}

provider "modtm" {}
