# Purpose: Provider configuration for the corp-a1 landing zone root module.
# Section: 9 — Landing Zone Spokes
# Last updated: 2026-05-14
#
# Apply order: After platform/connectivity (hub VNet IDs and firewall IPs are required inputs).
#
# Providers:
#   azurerm (default) → Landing Zones subscription — all corp-a1 spoke resources
#   azurerm.connectivity → Connectivity subscription — hub-to-spoke return VNet peering only
#
# The OIDC SP holds Owner at Tenant Root MG (ADR-006) so it can create peering
# resources in the Connectivity subscription without additional RBAC grants.

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
