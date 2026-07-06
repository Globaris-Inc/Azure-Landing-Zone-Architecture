# Purpose: Provider configuration for Management Group hierarchy root module.
# Section: 2 — Management Group Hierarchy
# Last updated: 2026-07-05

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
      #
      # Pinned 2026.04.2 (was 2026.01.3). 2026.04.0 removed a set of deprecated/
      # superseded built-in policies that caused a hard apply failure on
      # `Enforce-EncryptTransit` (400 InvalidPolicyParameters: the initiative's
      # lowercase `deny` effect default is rejected by built-in policy
      # 1a5b4dca-… v9.0.0, which requires `Audit|Deny|Disabled`). See
      # Azure-Landing-Zones issues #4128 / #411. Provider stays `alz ~> 0.21.0`.
      # Verified against the library release notes 2026-07-05.
      path = "platform/alz"
      ref  = "2026.04.2"
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
