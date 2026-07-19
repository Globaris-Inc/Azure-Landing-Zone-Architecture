# Purpose: Management Group hierarchy - calls avm-ptn-alz to create the Globaris MG tree
#          and places all 5 POC subscriptions under their respective management groups.
# Section: 2 - Management Group Hierarchy
# Last updated: 2026-07-19
#
# Architecture (defined in lib/globaris.alz_architecture_definition.json):
#
#   Tenant Root Group
#   └── Globaris                     (root - id: globaris)
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
# Wave B7 - Operations & Monitoring Phase 1 (AMBA-ALZ) locals - ADR-052
# ---------------------------------------------------------------------------

locals {
  # AMBA-ALZ well-known resource names. These are the DEFAULTS of
  # avm-ptn-monitoring-amba-alz 0.4.0 (deployed by platform/management); they are
  # repeated here so the Deploy-AMBA-* policy assignments target the exact resource
  # group + user-assigned MI the companion module creates. MUST stay in lock-step
  # with platform/management/main.tf module "amba" (resource_group_name +
  # user_assigned_managed_identity_name).
  amba_resource_group_name   = "rg-amba-monitoring-001"
  amba_managed_identity_name = "id-amba-prod-001"

  # Deterministic resource id of the AMBA user-assigned MI. The companion module
  # creates it at management-sub / rg-amba-monitoring-001 / id-amba-prod-001, so the
  # id is fully derivable here without a cross-root state dependency. This is the
  # bring-your-own remediation identity the Deploy-AMBA-* DINE alert policies attach
  # to the alert resources they deploy (Monitoring Reader, granted by the companion
  # module). Identity/scope match is the hard correctness point (design doc 3.1).
  amba_byo_uami_id = "/subscriptions/${var.management_subscription_id}/resourceGroups/${local.amba_resource_group_name}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${local.amba_managed_identity_name}"

  # policy_default_values for avm-ptn-alz 0.19.1: each value is jsonencode({ value = X }).
  # Keys are the AMBA library default_names (platform/amba 2026.06.2
  # alz_policy_default_values.json, verified 2026-07-19). Applied only when
  # enable_om_phase1 selects the globaris-amba architecture; the operator email key is
  # merged in only when supplied (never committed - TF_VAR / secret).
  amba_policy_default_values = merge(
    {
      amba_alz_management_subscription_id            = jsonencode({ value = var.management_subscription_id })
      amba_alz_resource_group_name                   = jsonencode({ value = local.amba_resource_group_name })
      amba_alz_resource_group_location               = jsonencode({ value = var.primary_location })
      amba_alz_resource_group_tags                   = jsonencode({ value = { _deployed_by_amba = true } })
      amba_alz_user_assigned_managed_identity_name   = jsonencode({ value = local.amba_managed_identity_name })
      amba_alz_byo_user_assigned_managed_identity_id = jsonencode({ value = local.amba_byo_uami_id })
    },
    var.om_operator_notification_email == "" ? {} : {
      amba_alz_action_group_email = jsonencode({ value = var.om_operator_notification_email })
    }
  )
}

# ---------------------------------------------------------------------------
# Management Group hierarchy + subscription placement
# ---------------------------------------------------------------------------

module "alz_management_groups" {
  source  = "Azure/avm-ptn-alz/azurerm"
  version = "0.19.1"

  # Wave B7 (ADR-052): select the AMBA-extended architecture when O&M Phase 1 is
  # enabled. "globaris" and "globaris-amba" both live in lib/ and share an identical
  # 11-MG topology; globaris-amba only ADDS the amba_* archetypes to the root,
  # platform-family, and landingzones MGs. Default (false) = the exact B0a-green
  # "globaris" architecture, so the policy engine is unchanged until the wave lands.
  architecture_name = var.enable_om_phase1 ? "globaris-amba" : "globaris"

  location = var.primary_location

  # Parent of the Globaris root MG is the Tenant Root Group. The module wants the
  # bare parent MG *name* (the tenant id for a tenant-root child) - NOT the full
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

  # Wave B7 (ADR-052): supply the AMBA library default values (RG name/location, the
  # management subscription, the AMBA MI name, the BYO remediation-identity resource id,
  # and the converged operator notification email) to the Deploy-AMBA-* assignments.
  # Only applied when the globaris-amba architecture is selected; null otherwise so the
  # B0a-green globaris path is untouched.
  policy_default_values = var.enable_om_phase1 ? local.amba_policy_default_values : null
}
