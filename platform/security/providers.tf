# Purpose: Provider configuration for the Security platform root module.
# Section: 8 — Standard Platform Components (Security sub)
# Last updated: 2026-05-14

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
  subscription_id = var.security_subscription_id
  features {}
}

provider "modtm" {}
