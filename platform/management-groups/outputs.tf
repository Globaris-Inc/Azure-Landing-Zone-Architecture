# Purpose: Outputs for Management Group hierarchy root module.
# Section: 2 - Management Group Hierarchy
# Last updated: 2026-05-06
#
# Management Group resource IDs are deterministic:
#   /providers/Microsoft.Management/managementGroups/{id}
# They do not require a data source lookup - downstream modules can construct
# them from the known MG IDs in the architecture definition.

output "management_group_ids" {
  description = "Map of management group logical name to resource ID for all MGs in the Globaris hierarchy."
  value = {
    globaris       = "/providers/Microsoft.Management/managementGroups/globaris"
    platform       = "/providers/Microsoft.Management/managementGroups/platform"
    management     = "/providers/Microsoft.Management/managementGroups/management"
    connectivity   = "/providers/Microsoft.Management/managementGroups/connectivity"
    identity       = "/providers/Microsoft.Management/managementGroups/identity"
    security       = "/providers/Microsoft.Management/managementGroups/security"
    landingzones   = "/providers/Microsoft.Management/managementGroups/landingzones"
    corp           = "/providers/Microsoft.Management/managementGroups/corp"
    online         = "/providers/Microsoft.Management/managementGroups/online"
    decommissioned = "/providers/Microsoft.Management/managementGroups/decommissioned"
    sandbox        = "/providers/Microsoft.Management/managementGroups/sandbox"
  }
}

output "alz_module_outputs" {
  description = "Full output object from the avm-ptn-alz module - useful for debugging policy assignments and archetype details."
  value       = module.alz_management_groups
  sensitive   = false
}
