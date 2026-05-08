# Purpose: Management Group hierarchy — calls avm-ptn-alz to create the Globaris MG tree
#          and places all 5 POC subscriptions under their respective management groups.
# Section: 2 — Management Group Hierarchy
# Last updated: 2026-05-06
#
# Architecture (defined in lib/globaris.alz_architecture_definition.json):
#
#   Tenant Root Group
#   └── Globaris                     (root — id: globaris)
#       ├── Platform                (id: platform)
#       │   ├── Management          (id: management)   ← sub-management-poc-01
#       │   ├── Connectivity        (id: connectivity) ← sub-connectivity-poc-01
#       │   ├── Identity            (id: identity)     ← sub-identity-poc-01
#       │   └── Security            (id: security)     ← sub-security-poc-01
#       ├── Landing Zones           (id: landingzones)
#       │   ├── Corp                (id: corp)         ← sub-landingzones-poc-01
#       │   └── Online              (id: online)
#       ├── Decommissioned          (id: decommissioned)
#       └── Sandbox                 (id: sandbox)

# ---------------------------------------------------------------------------
# Current tenant context (needed for parent_resource_id)
# ---------------------------------------------------------------------------

data "azapi_client_config" "current" {}

# ---------------------------------------------------------------------------
# Management Group hierarchy + subscription placement
# ---------------------------------------------------------------------------

module "alz_management_groups" {
  source  = "Azure/avm-ptn-alz/azurerm"
  version = "0.19.1"

  # "globaris" matches the name field in globaris.alz_architecture_definition.json.
  architecture_name = "globaris"

  location = var.primary_location

  # Parent of the Globaris root MG is the Tenant Root Group.
  parent_resource_id = "/providers/Microsoft.Management/managementGroups/${data.azapi_client_config.current.tenant_id}"

  # Map each subscription to its target management group.
  # Keys are management group IDs from the architecture definition.
  subscription_placement = {
    management = {
      subscription_ids = [var.management_subscription_id]
    }
    connectivity = {
      subscription_ids = [var.connectivity_subscription_id]
    }
    identity = {
      subscription_ids = [var.identity_subscription_id]
    }
    security = {
      subscription_ids = [var.security_subscription_id]
    }
    corp = {
      subscription_ids = [var.landingzones_subscription_id]
    }
  }
}
