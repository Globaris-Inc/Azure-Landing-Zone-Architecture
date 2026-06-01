# Purpose: Provider configuration for the Security platform root module.
# Section: 8 — Standard Platform Components (Security sub) / extended in Section 6
# Last updated: 2026-05-29

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

# Default provider targets the Security subscription.
provider "azurerm" {
  subscription_id = var.security_subscription_id
  features {}
}

# azapi used for Microsoft.SecurityInsights/settings resources (UEBA + Entity
# Analytics) that have no native azurerm equivalent in 4.x.
provider "azapi" {}

provider "modtm" {}
