# ---------------------------------------------------------------------------
# region-restriction.tf - data-residency guardrail for the whole estate
#
# Purpose:  Restrict every resource and resource group created anywhere under the
#           Globaris hierarchy to continental US regions, enforced as Deny.
# Section:  2 (Management Group Hierarchy) / 7 (FinOps and Governance). ADR-074.
# Updated:  2026-08-02
#
# WHY THIS FILE EXISTS. Until 2026-08-02 this estate had NO enforcing region
# restriction at any scope, which was found while reviewing an Azure Advisor export.
# Three things had masked it:
#   1. `sys.blockwesteurope` is enforcing at Tenant Root and looks like a region
#      control, but it is MICROSOFT-MANAGED (created 2025-11-11 by a Microsoft
#      service principal, `sys.` prefix) and blocks exactly one region we never use.
#   2. The ALZ `root` archetype (library platform/alz 2026.04.2) carries
#      `Audit-ResourceRGLocation`, whose name reads like a region control. It is not:
#      it audits whether a resource's location MATCHES ITS RESOURCE GROUP's location,
#      which is a consistency check, and its effect is Audit.
#   3. The ALZ `landing_zones` archetype has 53 assignments and not one of them
#      constrains location. (Counted from the PINNED library artifact in
#      `platform/management-groups/.alzlib`, not from a summary of the upstream repo.)
# Verified 2026-08-02: no `listOfAllowedLocations` reference existed anywhere in the
# repository before this file.
#
# SCOPE DECISION - Globaris root MG, NOT Tenant Root. Globaris covers all five
# estate subscriptions. Assigning at Tenant Root would additionally capture the two
# subscriptions that sit outside the landing zone (OQ-071 limb B), which this project
# does not own, cannot test against, and must not silently constrain.
#
# EFFECT DECISION - Deny, not Audit. Unlike the `deny_public_network_access` set in
# main.tf (held at Audit because a Deny there would block legitimate POC workloads
# under `landingzones`), nothing the CURRENTLY DISPATCHED 14 steps build lands outside
# continental US: the 2026-07-31 rebuild created 1,808 resources (the authoritative
# per-step sum in docs/estate-bom.md, NOT the superseded "roughly 1,721" narrative
# checkpoint) exclusively in `centralus` and `eastus2`, both on the allow-list.
#
# THE SCOPE OF THAT CLAIM IS THE 14 DISPATCHED STEPS, NOT THE WHOLE REPOSITORY, and
# the difference is load-bearing. `synthetic/red_team.tf:157` creates a resource group
# at `var.red_team_geo_location`, default `westeurope` (`synthetic/variables.tf:63`),
# DELIBERATELY outside the US so the impossible-travel detection scenario has a real
# signal, and `synthetic`'s provider targets the landingzones subscription, which is
# under this MG. It cannot fire during this rebuild - `enable_synthetic_workload` is
# false and the root is not one of the 14 steps - but this Deny WILL block it the day
# Section 13.3 ships. Tracked as OQ-073; do not flip that flag before it is resolved.
#
# `global` IS SAFE. Verified against the live policy definition on 2026-08-02, not
# assumed: `Allowed locations` (e56962a6) carries an explicit
# `{"field": "location", "notEquals": "global"}` clause, so the estate's 89 private
# DNS zones and every other global-scoped resource are outside its reach. The
# resource-group policy (e765b5de) has no such clause and needs none, because a
# resource group always carries a real region.
# ---------------------------------------------------------------------------

locals {
  # jsonencode'd once and reused by both assignments below. Both built-ins expose
  # BOTH `listOfAllowedLocations` AND `effect` as parameters (confirmed against the
  # live definitions 2026-08-02), so `effect` is passed EXPLICITLY per OQ-016 -
  # never rely on a built-in's implicit default.
  allowed_locations_parameters = jsonencode({
    listOfAllowedLocations = { value = var.allowed_locations }
    effect                 = { value = "Deny" }
  })
}

# Built-in "Allowed locations" - mode Indexed, applies to resources.
# Definition id verified live 2026-08-02.
#
# NAME LENGTH (LESSON 27): policy assignment names are capped at 24 characters at
# management group scope. Rendered with org_prefix "globaris" this is
# "allow-loc-res-globaris" = 22 characters.
resource "azurerm_management_group_policy_assignment" "allowed_locations_resources" {
  name                 = "allow-loc-res-${var.org_prefix}"
  management_group_id  = local.globaris_mg_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
  display_name         = "Allowed locations - ${title(var.org_prefix)} (continental US only)"
  description          = "Denies creation of any resource outside the continental US regions listed in var.allowed_locations. Resources whose location is 'global' are excluded by the built-in policy rule itself. ADR-074."

  parameters = local.allowed_locations_parameters
}

# Built-in "Allowed locations for resource groups" - mode All, applies to RGs only.
# Definition id verified live 2026-08-02.
#
# NAME LENGTH (LESSON 27): rendered "allow-loc-rg-globaris" = 21 characters.
resource "azurerm_management_group_policy_assignment" "allowed_locations_resource_groups" {
  name                 = "allow-loc-rg-${var.org_prefix}"
  management_group_id  = local.globaris_mg_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e765b5de-1225-4ba3-bd56-1ac6695af988"
  display_name         = "Allowed locations for resource groups - ${title(var.org_prefix)} (continental US only)"
  description          = "Denies creation of any resource group outside the continental US regions listed in var.allowed_locations. ADR-074."

  parameters = local.allowed_locations_parameters
}
