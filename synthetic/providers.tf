# Purpose: Provider configuration for the synthetic workload layer.
# Section: 13 — Synthetic Workload & Telemetry Generation
# Last updated: 2026-06-02
#
# Apply order: After all landing zones (corp-a1, corp-a2, online-p1) — synthetic
# resources sit alongside existing workload resource groups in the Landing Zones
# subscription and look up App Services / spoke VNets via data sources.
#
# Providers:
#   azurerm (default) → Landing Zones subscription — all synthetic resources
#
# Kill switch: every resource is gated by `var.enable_synthetic_workload`.
# Setting the variable to false produces a plan that destroys every synthetic
# resource in <5 min. See synthetic/README.md.

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1.0"
    }
    # Added for the OQ-029 policy-exemption propagation wait (policy_exemptions.tf).
    # Same pin used by bootstrap / platform/identity / landing-zones/* (ADR-028).
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13.1"
    }
  }
  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.landingzones_subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
