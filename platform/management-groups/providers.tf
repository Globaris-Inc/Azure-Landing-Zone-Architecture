# Purpose: Provider configuration for Management Group hierarchy root module.
# Section: 2 — Management Group Hierarchy
# Last updated: 2026-05-06

terraform {
  required_version = ">= 1.9"

  required_providers {
    alz = {
      source  = "azure/alz"
      version = "~> 0.21.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.9.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3.5"
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

provider "alz" {
  library_references = [
    {
      # Microsoft's canonical ALZ library — provides built-in archetypes
      # (root, platform, landing_zones, corp, online, management, connectivity,
      # identity, security, decommissioned, sandbox).
      path = "platform/alz"
      ref  = "2026.01.3"
    },
    {
      # Custom Globaris hierarchy — defines the globaris architecture,
      # overriding root MG id "alz" with "globaris".
      custom_url = "${path.root}/lib"
    }
  ]
}

provider "azapi" {}

provider "azurerm" {
  features {}
}
