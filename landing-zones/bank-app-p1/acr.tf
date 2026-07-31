# Purpose: bank-app-p1 Azure Container Registry (wave B2) - Premium ACR, private
#          endpoint into snet-private-endpoints wired to the live privatelink.azurecr.io
#          zone via the module-managed zone group (the estate's proven SQL-PE pattern),
#          AcrPull for the cluster kubelet identity, diagnostics to the platform LAW.
#          Gated behind var.enable_kubernetes_platform with aks.tf.
# Section: Banking wave B2 (docs/b2-aks-platform-design.md section 4; ADR-043).
#          Wave B4 ride-along: kubelet RA durable fix (B3 PC-3M disposition,
#          docs/b4-apim-platform-design.md section 8).
#          PC-2S: greenfield-plannability gate on the kubelet lookup and binding
#          (docs/preclearance/2026-07-22-full-estate-rebuild.md)
# Last updated: 2026-07-21
#
# Module: Azure/avm-res-containerregistry-registry/azurerm 0.5.1 (pin verified on the
# Terraform Registry 2026-07-18, schema read from the v0.5.1 tag source).
#
# Premium is RULED, not optional (ADR-043): private endpoints require Premium, and a
# public Basic/Standard registry would violate the estate's deny-public posture. Node
# image pulls from this registry stay in-VNet (PE + zone resolution) and never touch
# the firewall - one reason the AKS egress rule set needs no ACR FQDNs.

# ---------------------------------------------------------------------------
# Kubelet identity lookup - MANDATED durable fix (B3 PC-3M disposition, verbatim
# spec in docs/b4-apim-platform-design.md section 8). Decouples the AcrPull RA
# principal_id from the AKS module's azapi computed output, which deferred to
# apply-time on every plan and cascaded a ForceNew replace of the RA. The name and
# resource_group_name are the root's OWN deterministic strings (literal
# interpolations of root variables ONLY - NOT azurerm_resource_group.workload.name,
# NOT any module output, NO depends_on; any of those would re-defer the read), so
# the data source resolves at refresh time and module-internal churn can no longer
# cascade. kubelet_identity[0].object_id verified in the azurerm v4.71.0 data-source
# schema. The interim one-accepted-replace plan bar is RETIRED with this fix.
#
# PC-2S GREENFIELD GATE (docs/preclearance/2026-07-22-full-estate-rebuild.md).
# Those static arguments are precisely why this read happens in the PLAN phase, and
# the cluster it reads is created by module.aks in THIS root. On an empty tenant the
# read 404s and the plan fails outright, so the lookup is now gated on
# var.enable_acr_kubelet_binding (default false) as well as the platform flag. Pass 1
# runs with the flag false: no lookup, no AcrPull assignment, cluster and registry get
# created. Pass 2 sets the flag true in envs/poc.tfvars, the cluster is live, the
# lookup resolves and the binding lands as a single add. Adding depends_on here
# instead is REJECTED: it defers the read to apply time and reintroduces the exact
# ForceNew role-assignment churn the wave B4 fix removed.
# ---------------------------------------------------------------------------

data "azurerm_kubernetes_cluster" "aks_lookup" {
  for_each = var.enable_kubernetes_platform && var.enable_acr_kubelet_binding ? { main = "main" } : {}

  name                = "aks-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = "rg-bank-app-p1-workload-${var.org_prefix}-${var.environment}"
}

module "acr" {
  source  = "Azure/avm-res-containerregistry-registry/azurerm"
  version = "0.5.1"

  for_each = var.enable_kubernetes_platform ? { main = "main" } : {}

  # LESSON 27 rendered-length check: "acrbankappp1" (12) + org "globaris" (8) +
  # env "poc" (3) = 23 chars, within the 5-50 ACR bound; alphanumeric only.
  # Re-check if org_prefix/environment ever change.
  name                = "acrbankappp1${var.org_prefix}${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = var.primary_location
  sku                 = "Premium"

  public_network_access_enabled = false
  admin_enabled                 = false
  zone_redundancy_enabled       = true # free with Premium
  # AzureServices bypass keeps Defender image scanning functional against a
  # private registry.
  network_rule_bypass_option = "AzureServices"

  # One PE into snet-private-endpoints; the module manages the zone group against the
  # central privatelink.azurecr.io zone (looked up in dns_links.tf). Note the ACR PE
  # writes TWO A records (registry + <registry>.<region>.data) - QA verifies both.
  private_endpoints = {
    registry = {
      name                            = "pe-acr-bank-app-p1-${var.org_prefix}-${var.environment}"
      subnet_resource_id              = module.spoke_vnet.subnets["private-endpoints"].resource_id
      private_dns_zone_resource_ids   = [data.azurerm_private_dns_zone.linked["acr"].id]
      private_service_connection_name = "psc-acr-bank-app-p1"
    }
  }

  # AcrPull for the cluster kubelet identity at registry scope. B4 durable fix
  # (design doc section 8): principal_id now comes from the static-argument data
  # source above (plan-time-known), not the AKS module's computed output. Expected
  # plan impact at this address once bound: ZERO changes (identical value, known at
  # plan). Gated with the lookup on the PC-2S two-pass flag; the map KEY stays static
  # so the address identity never moves between passes (LESSON 5a). The false branch
  # yields an empty map, which the module accepts: role_assignments is
  # map(object(...)) with default {} and nullable = false, consumed as
  # for_each = var.role_assignments on azurerm_role_assignment.this (schema read from
  # the pinned 0.5.1 source), so no key is ever required to exist.
  role_assignments = var.enable_acr_kubelet_binding ? {
    kubelet_acr_pull = {
      role_definition_id_or_name = "AcrPull"
      principal_id               = data.azurerm_kubernetes_cluster.aks_lookup["main"].kubelet_identity[0].object_id
      principal_type             = "ServicePrincipal"
    }
  } : {}

  diagnostic_settings = {
    platform_law = {
      name                  = "diag-acr-bank-app-p1-${var.org_prefix}-${var.environment}"
      workspace_resource_id = var.platform_law_workspace_id
    }
  }

  tags = local.common_tags

  # ADR-070 decision 2 / LESSON 35: the registry create must not race the two DINE
  # assignments it overlaps with.
  #   - Deploy-Private-DNS-Zones member DINE-Private-DNS-Azure-ACR (groupId
  #     registry) would write a single-zone "deployedByPolicy" group onto
  #     pe-acr-*. Azure allows only ONE zone group per private endpoint, so that
  #     group and the module-managed one are mutually exclusive. LIVE race.
  #   - Deploy-Diag-LogsCat member containerregistry-registries would write a
  #     second setting named "setByPolicy-LogAnalytics" beside diag-acr-*. That
  #     is duplicate ingestion and cost, NOT a create blocker (different name,
  #     five settings allowed per resource, and the azurerm pre-create GET is
  #     scoped to the exact configured name), and it is dormant while the
  #     assignment's logAnalytics parameter is the zero-GUID placeholder
  #     (OQ-021).
  # Both are exempted in policy_exemptions.tf; this edge waits for that to
  # propagate.
  depends_on = [time_sleep.wait_dine_ownership_exemptions]
}
