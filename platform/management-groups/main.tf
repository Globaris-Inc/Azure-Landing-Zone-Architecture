# Purpose: Management Group hierarchy — calls avm-ptn-alz to create the Globaris MG tree
#          and places all 5 POC subscriptions under their respective management groups.
# Section: 2 — Management Group Hierarchy
# Last updated: 2026-07-06
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

  # Parent of the Globaris root MG is the Tenant Root Group. The module wants the
  # bare parent MG *name* (the tenant id for a tenant-root child) — NOT the full
  # `/providers/Microsoft.Management/managementGroups/...` path (validated in the
  # module: variables.tf parent_resource_id must not contain `/`). Confirmed
  # against avm-ptn-alz 0.19.1. Last updated: 2026-07-04.
  parent_resource_id = data.azapi_client_config.current.tenant_id

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

  # Stop enforcing the ALZ Enable-DDoS-VNET Modify assignment at the Connectivity MG.
  # The ALZ default ddosPlan parameter is a PLACEHOLDER
  # (/subscriptions/0000...0000/.../ddosProtectionPlans/placeholder). Being enforced
  # (Modify effect, addOrReplace), it rewrites every VNet PUT in the connectivity
  # subscription to reference that non-existent plan in subscription 0000..., causing
  # 403 LinkedAuthorizationFailed on all VNet creates. This POC runs WITHOUT DDoS
  # Standard (~$2,944/mo), so we set enforcement to DoNotEnforce.
  #
  # COUPLED-IN-INTENT to platform/connectivity `var.enable_ddos_standard = false`.
  # If DDoS Standard is ever enabled, BOTH must change together (re-enforce this
  # assignment AND supply a real ddosPlan id). Tracked in OQ / ADR-026.
  # Schema: Azure/avm-ptn-alz 0.19.1 variables.tf L392-455 (map(MG-id) ->
  # policy_assignments -> assignment-name -> { enforcement_mode }). enforcement_mode
  # allowed values: "Default" | "DoNotEnforce".
  #
  # ADR-026 amendment (2026-07-10): the SAME placeholder-plan trap is still live at the
  # landingzones MG, where enforcementMode=Default injects the invalid ddosProtectionPlan
  # into every SPOKE VNet PUT (the connectivity-MG fix above never reached this scope).
  # Extend the DoNotEnforce lever to the landingzones MG so all three spokes can create
  # their VNets. Same policy, same rationale, next MG down; see
  # docs/preclearance/landing-zones.md section 6 + matrix row 1. This root MUST be applied
  # before any spoke. Verify after apply: `az policy assignment show --name Enable-DDoS-VNET
  # --scope /providers/Microsoft.Management/managementGroups/landingzones --query
  # enforcementMode` == "DoNotEnforce".
  policy_assignments_to_modify = {
    connectivity = {
      policy_assignments = {
        "Enable-DDoS-VNET" = {
          enforcement_mode = "DoNotEnforce"
        }
      }
    }
    landingzones = {
      policy_assignments = {
        "Enable-DDoS-VNET" = {
          enforcement_mode = "DoNotEnforce"
        }
      }
    }
  }
}
