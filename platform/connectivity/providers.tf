# Purpose: Provider configuration for the Connectivity platform root module.
# Section: 8 — Standard Platform Components (Connectivity sub)
# Last updated: 2026-05-14
#
# Providers required:
#   azurerm — Connectivity subscription (hub VNets, firewalls, VPN GW)
#   azapi   — Required by avm-ptn-alz-connectivity-hub-and-spoke-vnet v0.17.1
#   modtm   — AVM telemetry provider (required by all AVM pattern modules)

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.4.0"
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
  subscription_id = var.connectivity_subscription_id
  features {}
}

provider "azapi" {
  subscription_id = var.connectivity_subscription_id
}

provider "modtm" {}
