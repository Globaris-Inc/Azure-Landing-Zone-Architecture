# Purpose: bank-app-p1 private AKS cluster (wave B2 Kubernetes platform) - control-plane
#          UAI + RBAC propagation sleep + AVM managed cluster module. ALL resources are
#          gated behind var.enable_kubernetes_platform (default false, LESSON 42 flag
#          pattern / ADR-015). Egress is userDefinedRouting through the primary hub
#          firewall (ADR-044): the connectivity root MUST be applied with
#          enable_firewall = true and its firewall private IP confirmed as 10.0.0.4
#          BEFORE this flag flips - nodes cannot bootstrap through a blackholed route.
# Section: Banking wave B2 (docs/b2-aks-platform-design.md sections 3 + 6; ADR-043/044)
# Last updated: 2026-07-18
#
# Module: Azure/avm-res-containerservice-managedcluster/azurerm 0.6.7 (azapi-based;
# pin verified on the Terraform Registry 2026-07-18, schema read from the v0.6.7 tag
# source). The default azapi provider is anchored to the landingzones sub in
# providers.tf (LESSON 23), which this module's parent_id pattern requires.

# ---------------------------------------------------------------------------
# Control-plane user-assigned identity (pre-created, ordered BEFORE the cluster).
# BYO private DNS zone on a private cluster REQUIRES a user-assigned control-plane
# identity holding rights on the zone - the control plane writes the API server
# A record itself (this is NOT a PE zone group; that pattern applies to ACR only).
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "aks" {
  for_each = var.enable_kubernetes_platform ? { main = "main" } : {}

  name                = "uai-aks-bank-app-p1-${var.org_prefix}-${var.environment}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = var.primary_location
  tags                = local.common_tags
}

# Private DNS Zone Contributor at the shared privatelink.centralus.azmk8s.io zone scope
# (the zone name tracks var.primary_location - the AVM private-DNS module substitutes
# {regionName} - so the grant scope is derived, never a literal)
# (Connectivity subscription - zone looked up in dns_links.tf, spoke + hub links live
# since B1).
resource "azurerm_role_assignment" "aks_uai_private_dns_zone" {
  for_each = var.enable_kubernetes_platform ? { main = "main" } : {}

  provider             = azurerm.connectivity
  scope                = data.azurerm_private_dns_zone.linked["aks"].id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# Network Contributor at the spoke network RG scope - covers the VNet, subnets AND the
# route table (the route-table grant is required when outbound_type is
# userDefinedRouting; RG scope covers all modes with one assignment).
resource "azurerm_role_assignment" "aks_uai_network_rg" {
  for_each = var.enable_kubernetes_platform ? { main = "main" } : {}

  scope                = azurerm_resource_group.network.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# 300s RBAC propagation buffer before cluster create (LESSON 35 timing class - a fresh
# role assignment 403s at create otherwise). Same idiom as the exemption sleep in
# policy_exemptions.tf.
resource "time_sleep" "wait_aks_uai_rbac" {
  for_each = var.enable_kubernetes_platform ? toset(["this"]) : toset([])

  create_duration = "300s"

  depends_on = [
    azurerm_role_assignment.aks_uai_private_dns_zone,
    azurerm_role_assignment.aks_uai_network_rg,
  ]
}

# ---------------------------------------------------------------------------
# AKS managed cluster - private, Entra-only, CNI Overlay, UDR egress
# ---------------------------------------------------------------------------

module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "0.6.7"

  for_each = var.enable_kubernetes_platform ? { main = "main" } : {}

  name       = "aks-bank-app-p1-${var.org_prefix}-${var.environment}"
  dns_prefix = "aks-bank-app-p1-${var.org_prefix}-${var.environment}"
  location   = var.primary_location
  parent_id  = azurerm_resource_group.workload.id

  # OQ-036 resolution: Standard tier (SLA-backed control plane).
  sku = {
    name = "Base"
    tier = "Standard"
  }

  # kubernetes_version omitted deliberately: AKS default GA version at create;
  # auto-upgrade keeps patches current (patch channel + NodeImage node OS channel,
  # enum values verified against the pinned module source).
  auto_upgrade_profile = {
    upgrade_channel         = "patch"
    node_os_upgrade_channel = "NodeImage"
  }

  # ADR-043: D2s_v4 supersedes the founding design's v5 family (offer-capped at 0 in
  # this sub); 3 nodes AZ-spread = 6/10 regional vCPUs, surge 1 keeps upgrades at 8/10.
  # Single system pool - user pools are quota-blocked at POC (OQ-043).
  default_agent_pool = {
    name                = "systempool"
    count_of            = 3
    vm_size             = "Standard_D2s_v4"
    availability_zones  = ["1", "2", "3"]
    enable_auto_scaling = false
    os_disk_type        = "Managed"
    vnet_subnet_id      = module.spoke_vnet.subnets["aks-nodes"].resource_id
    upgrade_settings = {
      max_surge = "1"
    }
  }

  # ADR-043 CIDR pins - NEVER leave these to defaults: the AKS default service CIDR
  # 10.0.0.0/16 COLLIDES with the primary hub VNet and would silently break
  # pod/node-to-hub routing. Pod CIDR 192.168.0.0/16 is non-routed (CNI Overlay,
  # NATed at node) and overlaps nothing in the estate.
  # ADR-044: outbound_type userDefinedRouting - egress rides the B1-shipped
  # 0.0.0.0/0 -> 10.0.0.4 UDR on snet-aks-nodes through the primary hub firewall.
  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.20.0.0/16"
    dns_service_ip      = "172.20.0.10"
    load_balancer_sku   = "standard"
    outbound_type       = "userDefinedRouting"
  }

  # Private cluster on the estate's shared central zone (ADR-043): the control-plane
  # UAI above writes the API server A record into privatelink.centralus.azmk8s.io.
  api_server_access_profile = {
    enable_private_cluster             = true
    enable_private_cluster_public_fqdn = false
    private_dns_zone                   = data.azurerm_private_dns_zone.linked["aks"].id
  }

  managed_identities = {
    user_assigned_resource_ids = [azurerm_user_assigned_identity.aks[each.key].id]
  }

  # Entra-only auth with Azure RBAC; local accounts disabled (banking bar - no static
  # credentials). tenant_id omitted: the module defaults to the deployment sub tenant.
  aad_profile = {
    managed                = true
    enable_azure_rbac      = true
    admin_group_object_ids = var.aks_admin_group_object_ids
  }

  disable_local_accounts = true

  # Workload identity federation (founding design 2.7).
  oidc_issuer_profile = {
    enabled = true
  }

  security_profile = {
    workload_identity = {
      enabled = true
    }
  }

  # Container Insights to the platform LAW (centralus, region-matched - LESSON 43).
  # use_aad_auth = false (verified at build per the design's fallback ruling): the
  # module only wires the required MSCI data collection rule through its
  # onboard_monitoring path, which also drags in managed Prometheus resources -
  # deferred to the B7 O&M wave. Legacy workspace-key auth needs no DCR.
  addon_profile_oms_agent = {
    enabled = true
    config = {
      log_analytics_workspace_resource_id = var.platform_law_workspace_id
      use_aad_auth                        = false
    }
  }

  # Control-plane diagnostics: kube-audit-admin instead of full kube-audit (volume),
  # per the design's estate diagnostics pattern. log_groups emptied so categories and
  # the allLogs group are not sent together.
  diagnostic_settings = {
    control_plane = {
      name                  = "diag-aks-bank-app-p1-${var.org_prefix}-${var.environment}"
      log_categories        = ["kube-apiserver", "kube-audit-admin", "guard", "cluster-autoscaler"]
      log_groups            = []
      workspace_resource_id = var.platform_law_workspace_id
    }
  }

  # Deterministic node RG name for QA/policy checks.
  node_resource_group = "rg-bank-app-p1-aks-nodes-${var.org_prefix}-${var.environment}"

  tags = local.common_tags

  # ADR-070 NOTE - deliberately NOT gated on
  # time_sleep.wait_dine_ownership_exemptions, and the reason is written down so
  # the omission is not read as an oversight. There is simply nothing to exempt:
  # Deploy-Diag-LogsCat's resourceTypeList has no
  # microsoft.containerservice/managedclusters entry and the initiative carries
  # no member for that type, so there is no reference id and inventing one would
  # produce an exemption that silently does nothing (live enumeration
  # 2026-07-31, PC-2DINE). The only AKS diagnostics policy above this
  # root is "Resource logs in Azure Kubernetes Service should be enabled"
  # (245fc9df-fa96-4414-9a0b-3738c2f7341c) inside Deploy-ASC-Monitoring and
  # Deploy-MCSB2-Monitoring, whose allowedValues are AuditIfNotExists and
  # Disabled only.
  #
  # Note that even where a member DOES exist, the diagnostics half of this ruling
  # is a duplicate-ingestion control and not a create blocker (see the reasoning
  # in policy_exemptions.tf), so diag-aks-* is no more exposed than its four
  # siblings. The cluster also creates no private endpoint - the API server
  # A record is written by the control-plane UAI into the shared azmk8s.io zone,
  # which is a zone record and not a privateDnsZoneGroups child - so the workload
  # RG needs no exemption at all.
  depends_on = [time_sleep.wait_aks_uai_rbac]
}
