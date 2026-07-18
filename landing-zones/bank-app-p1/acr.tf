# Purpose: bank-app-p1 Azure Container Registry (wave B2) - Premium ACR, private
#          endpoint into snet-private-endpoints wired to the live privatelink.azurecr.io
#          zone via the module-managed zone group (the estate's proven SQL-PE pattern),
#          AcrPull for the cluster kubelet identity, diagnostics to the platform LAW.
#          Gated behind var.enable_kubernetes_platform with aks.tf.
# Section: Banking wave B2 (docs/b2-aks-platform-design.md section 4; ADR-043)
# Last updated: 2026-07-18
#
# Module: Azure/avm-res-containerregistry-registry/azurerm 0.5.1 (pin verified on the
# Terraform Registry 2026-07-18, schema read from the v0.5.1 tag source).
#
# Premium is RULED, not optional (ADR-043): private endpoints require Premium, and a
# public Basic/Standard registry would violate the estate's deny-public posture. Node
# image pulls from this registry stay in-VNet (PE + zone resolution) and never touch
# the firewall - one reason the AKS egress rule set needs no ACR FQDNs.

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

  # AcrPull for the cluster kubelet identity at registry scope, after cluster create
  # (the reference to the module output orders it). kubelet_identity output name and
  # its objectId attribute verified in the pinned 0.6.7 module source (outputs.tf,
  # exported via response_export_values properties.identityProfile.kubeletidentity).
  role_assignments = {
    kubelet_acr_pull = {
      role_definition_id_or_name = "AcrPull"
      principal_id               = module.aks["main"].kubelet_identity.objectId
      principal_type             = "ServicePrincipal"
    }
  }

  diagnostic_settings = {
    platform_law = {
      name                  = "diag-acr-bank-app-p1-${var.org_prefix}-${var.environment}"
      workspace_resource_id = var.platform_law_workspace_id
    }
  }

  tags = local.common_tags
}
