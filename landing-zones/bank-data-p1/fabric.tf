# Purpose: bank-data-p1 Microsoft Fabric F2 capacity (wave B5) - smallest F-SKU,
#          shared RG (BI/reporting shared face). Gated behind its OWN flag
#          var.enable_fabric_capacity (default false; stays false until OQ-045
#          supplies the capacity admin principal - empty administration_members
#          ARM acceptance is UNVERIFIED, so an empty list never reaches ARM this
#          wave). NO Fabric workspaces/lakehouses/items and NO microsoft/fabric
#          provider - the capacity resource is the entire Fabric surface (design
#          doc section 1 boundary).
# Section: Banking wave B5 (docs/b5-data-platform-design.md section 7.2; ADR-048)
# Last updated: 2026-07-18
#
# DEVIATION: native azurerm_fabric_capacity - NO AVM module exists for Fabric
# capacity (registry NOT-FOUND check carried from the founding design, re-verified
# at the B5 design 2026-07-18). Schema verified against the azurerm v4.71.0 tag
# docs (resource added by provider PR #28080; covered by the root pin ~> 4.71.0).
#
# Pause mechanic (design doc section 7.2): the capacity deploys ACTIVE (~$0.36/hr
# for F2) - ARM has no create-paused and azurerm has no pause argument. Ruled
# posture: suspend same-day immediately after QA via
#   az fabric capacity suspend --capacity-name <name> -g <rg>
# (resume symmetric; Contributor on the RG suffices). An out-of-band suspend does
# NOT drift the Terraform plan (provisioning state is not a tracked argument);
# EOW teardown deletes the capacity in any state (delete timeout 30 min).

resource "azurerm_fabric_capacity" "this" {
  for_each = var.enable_fabric_capacity ? { main = "main" } : {}

  # DEVIATION (naming): Fabric capacity names must be lowercase letters and
  # numbers only, starting with a letter - hyphens are REJECTED (azurerm provider
  # issue #29302), so the estate hyphen convention cannot apply. Rendered:
  # "fabbankdata" (11) + org "globaris" (8) + env "poc" (3) = 22 chars, all
  # lowercase alphanumeric. Re-check if org_prefix/environment ever carry
  # non-alphanumeric characters.
  name                = "fabbankdata${var.org_prefix}${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.primary_location

  sku {
    name = "F2"
    tier = "Fabric"
  }

  # UPN for user principals, object ID for service principals. Supplied via CI
  # TF_VAR_fabric_admin_members from a GitHub Actions variable once OQ-045
  # resolves - no personal values are ever committed (estate rule).
  administration_members = var.fabric_admin_members

  tags = local.common_tags
}
