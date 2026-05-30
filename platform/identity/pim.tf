# Purpose: PIM eligible role assignments + activation rules at MG scope.
# Section: 5 — Zero Trust + Conditional Access
# Last updated: 2026-05-26
#
# All resources in this file are skipped when var.pim_privileged_group_object_id
# is empty ("") — set it to the object ID of your privileged-access group and
# re-apply to activate PIM.
#
# UNVERIFIED: azurerm_pim_eligible_role_assignment and azurerm_role_management_policy
# attribute names confirmed against azurerm ~> 4.0 documentation. Verify exact
# block/attribute names on registry.terraform.io/providers/hashicorp/azurerm if
# plan fails with "unsupported argument" errors.
#
# Roles made eligible (Owner, Contributor, UAA, Security Admin at MG scope):
#   Owner (8e3af657)             — globaris root MG
#   User Access Administrator (18d7d88d) — globaris root MG
#   Contributor (b24988ac)       — landingzones MG
#   Security Admin (fb1c8493)    — globaris root MG
#
# Activation rules (applied via azurerm_role_management_policy):
#   Maximum duration : 8 hours
#   MFA required     : yes
#   Justification    : required
#   Approval         : optional (requires var.pim_approver_group_object_id)

locals {
  globaris_mg_id     = "/providers/Microsoft.Management/managementGroups/globaris"
  landingzones_mg_id = "/providers/Microsoft.Management/managementGroups/landingzones"

  # Map of eligible assignments: key → {scope, role_definition_id, description}
  pim_assignments = {
    owner-globaris = {
      scope              = local.globaris_mg_id
      role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
      description        = "Owner at Globaris root MG — full platform control"
    }
    uaa-globaris = {
      scope              = local.globaris_mg_id
      role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"
      description        = "User Access Administrator at Globaris root MG — RBAC management"
    }
    contributor-landingzones = {
      scope              = local.landingzones_mg_id
      role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
      description        = "Contributor at Landing Zones MG — workload deployment"
    }
    security-admin-globaris = {
      scope              = local.globaris_mg_id
      role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/fb1c8493-542b-48eb-b624-b4c8fea62acd"
      description        = "Security Admin at Globaris root MG — Defender and policy management"
    }
  }

  # Active assignment map only when pim group is configured.
  active_pim = var.pim_privileged_group_object_id != "" ? local.pim_assignments : {}
}

# ---------------------------------------------------------------------------
# PIM eligible role assignments
# ---------------------------------------------------------------------------

resource "azurerm_pim_eligible_role_assignment" "this" {
  for_each = local.active_pim

  scope              = each.value.scope
  role_definition_id = each.value.role_definition_id
  principal_id       = var.pim_privileged_group_object_id

  justification = "Terraform-managed PIM eligible assignment — ${each.value.description}"

  schedule {
    start_date_time = null

    expiration {
      end_date_time = null # no expiration on the eligible assignment itself
    }
  }

  ticket {
    number = "PLATFORM-PIM-${upper(each.key)}"
    system = "Terraform"
  }
}

# ---------------------------------------------------------------------------
# PIM role management policies — activation rules per role per scope
# Configures the existing Azure-managed policy (one exists per role per scope);
# Terraform updates it rather than creating a new resource.
# ---------------------------------------------------------------------------

resource "azurerm_role_management_policy" "this" {
  for_each = local.active_pim

  scope              = each.value.scope
  role_definition_id = each.value.role_definition_id

  activation_rules {
    maximum_duration                   = "PT8H"
    require_justification              = true
    require_multifactor_authentication = true
    require_ticket_info                = false

    dynamic "approval_stage" {
      for_each = var.pim_approver_group_object_id != "" ? [1] : []
      content {
        primary_approver {
          object_id = var.pim_approver_group_object_id
          type      = "groupMembers"
        }
      }
    }
  }

  eligible_assignment_rules {
    expiration_required = false
  }

  active_assignment_rules {
    expiration_required                = false
    require_justification              = true
    require_multifactor_authentication = true
  }

  depends_on = [azurerm_pim_eligible_role_assignment.this]
}
