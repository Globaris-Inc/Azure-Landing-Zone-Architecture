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
  # v0.19.1 schema: each value is { subscription_id, management_group_name }.
  # The map key is arbitrary; management_group_name is the MG name, which the
  # module sets to the architecture definition `id` (management/connectivity/
  # identity/security/corp).
  subscription_placement = {
    management = {
      subscription_id       = var.management_subscription_id
      management_group_name = "management"
    }
    connectivity = {
      subscription_id       = var.connectivity_subscription_id
      management_group_name = "connectivity"
    }
    identity = {
      subscription_id       = var.identity_subscription_id
      management_group_name = "identity"
    }
    security = {
      subscription_id       = var.security_subscription_id
      management_group_name = "security"
    }
    corp = {
      subscription_id       = var.landingzones_subscription_id
      management_group_name = "corp"
    }
  }
}
