# Purpose: Input variables for the bank-app-p1 landing zone root module (banking
#          application spoke - B1 network foundation + B2 Kubernetes platform +
#          B3 messaging platform + B4 API platform inputs).
# Section: Banking waves B1-B4 (docs/banking-platform-design.md,
#          docs/b2-aks-platform-design.md, docs/b3-messaging-platform-design.md,
#          docs/b4-apim-platform-design.md) plus the PC-2S greenfield gate
#          (docs/preclearance/2026-07-22-full-estate-rebuild.md)
# Last updated: 2026-07-21

# ---------------------------------------------------------------------------
# Subscription targeting
# ---------------------------------------------------------------------------

variable "landingzones_subscription_id" {
  description = "Subscription ID for the Landing Zones subscription (banking spoke placement per OQ-035)."
  type        = string
}

variable "connectivity_subscription_id" {
  description = "Subscription ID for the Connectivity platform subscription (hub-to-spoke return peering and Private DNS zone links only)."
  type        = string
}

# ---------------------------------------------------------------------------
# Location + naming
# ---------------------------------------------------------------------------

variable "primary_location" {
  description = "Primary Azure region for bank-app-p1 resources. Authoritative value is envs/poc.tfvars (ADR-069); this default only matches it."
  type        = string
  default     = "centralus"
}

variable "org_prefix" {
  description = "Short organisation identifier used in resource naming (e.g. 'globaris')."
  type        = string
}

variable "environment" {
  description = "Deployment environment label used in resource names and tags (e.g. 'poc')."
  type        = string
  default     = "poc"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "spoke_address_space" {
  description = "CIDR block for the bank-app-p1 spoke VNet. All subnet prefixes are computed from this block. 10.30.0.0/16 is ARCHITECT-CONFIRMED (B1 amendment ruling); 10.31.0.0/16 is RESERVED for the bank-app DR spoke (eastus2, design-only). Full banking allocation table in this root's README and main.tf header."
  type        = string
  default     = "10.30.0.0/16"
}

variable "primary_hub_vnet_id" {
  description = "ARM resource ID of the primary hub VNet. From platform/connectivity output 'primary_hub_vnet_id'."
  type        = string
}

variable "primary_hub_vnet_name" {
  description = "Name of the primary hub VNet. Required for the hub-to-spoke return peering."
  type        = string
}

variable "primary_hub_rg_name" {
  description = "Resource group name of the primary hub VNet in the Connectivity subscription."
  type        = string
}

variable "primary_firewall_private_ip" {
  description = "Private IP of the primary Azure Firewall. Used as the 0.0.0.0/0 next-hop for all bank-app-p1 subnets."
  type        = string
}

# ---------------------------------------------------------------------------
# Private DNS (Section 4 pattern)
# ---------------------------------------------------------------------------

variable "private_dns_rg_name" {
  description = "Name of the resource group in the Connectivity subscription that holds all Private Link DNS zones. From platform/connectivity output 'private_dns_rg_name'."
  type        = string
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "platform_law_workspace_id" {
  description = "ARM resource ID of the platform Log Analytics workspace (centralus, region-matched to this spoke - LESSON 43)."
  type        = string
}

variable "platform_law_customer_id" {
  description = "GUID (customer ID) of the platform Log Analytics workspace. Required for Traffic Analytics on the VNet flow log."
  type        = string
}

variable "flow_log_retention_days" {
  description = "Number of days to retain VNet flow log data in the storage account."
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# Policy exemptions (OQ-024 / ADR-028)
# ---------------------------------------------------------------------------

variable "enable_corp_policy_exemptions" {
  description = "Create the RG-scoped Waiver policy exemption for the corp-MG Deny-Public-Endpoints StorageDenyPaasPublicIP member on the flow-log storage account, which cannot be made compliant without breaking flow-log delivery. Default true; set false only if this spoke is moved out from under the corp MG or the governance changes (OQ-024)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Kubernetes platform (wave B2 - ADR-043 / ADR-044)
# ---------------------------------------------------------------------------

variable "enable_kubernetes_platform" {
  description = "Deploy the wave B2 Kubernetes platform: private AKS cluster (Standard tier, 3x D2s_v4 across zones 1-3, CNI Overlay, Entra-only auth, outbound_type userDefinedRouting) plus the Premium ACR with private endpoint (ADR-043). Default false per the LESSON 42 shippable-network-only flag pattern. ORDERING (ADR-044): flip only after platform/connectivity is applied with enable_firewall = true and the primary firewall private IP is confirmed as 10.0.0.4 - AKS nodes cannot bootstrap through a blackholed default route."
  type        = bool
  default     = false
}

variable "aks_admin_group_object_ids" {
  description = "Entra ID group object IDs granted the cluster admin role via the AKS aad_profile (Azure RBAC enabled, local accounts disabled - ADR-043). REQUIRED when enable_kubernetes_platform is true; no default on purpose. The value arrives via TF_VAR_aks_admin_group_object_ids from the repo secret in CI (poc.secret.tfvars locally) - never commit the GUIDs."
  type        = list(string)
}

# DO NOT flip this default to true. It is false BY DESIGN, not by oversight.
# The AcrPull principal id is read from data.azurerm_kubernetes_cluster.aks_lookup
# in acr.tf, which looks up a cluster THIS SAME ROOT creates. That data source has
# static arguments, so Terraform resolves it during the PLAN phase; on a greenfield
# estate the read 404s and the plan exits non-zero before anything can be created.
# A default of true would therefore make this root unplannable on an empty tenant,
# which is exactly the PC-2S defect this flag exists to fix. The value is supplied
# for Pass 2 only, from envs/poc.tfvars, in its own reviewed one-line commit.
variable "enable_acr_kubelet_binding" {
  description = "Create the registry-scoped AcrPull role assignment binding the AKS cluster's kubelet identity to the Premium ACR. Default false because the principal id comes from a same-root data source lookup of the AKS cluster (acr.tf), which Terraform must resolve at plan time and which cannot resolve until the cluster exists (PC-2S, docs/preclearance/2026-07-22-full-estate-rebuild.md). Two-pass sequence: Pass 1 applies with false and creates the cluster and the registry; Pass 2 sets true in envs/poc.tfvars and plans as exactly 1 to add, 0 to change, 0 to destroy. LESSON 42 flag pattern with the ADR-055 two-pass precedent. Inert while enable_kubernetes_platform is false, since the registry itself is not deployed."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Messaging platform (wave B3 - ADR-045 / ADR-046)
# ---------------------------------------------------------------------------

variable "enable_messaging_platform" {
  description = "Deploy the wave B3 messaging/eventing backbone: Event Hubs Standard namespace (1 TU, public access off, SAS auth off) plus the Service Bus Premium namespace (1 MU, public access off, local auth off, TLS 1.2 min) per the OQ-044 shape A resolution - Premium is the only Service Bus tier that attaches private endpoints, making both namespaces compliant with the corp deny initiative by design, no exemption (docs/b3-messaging-platform-design.md; rulings ADR-046 under the ADR-045 sprint frame, EOW teardown). Both PE into snet-private-endpoints on the shared privatelink.servicebus.windows.net zone. Default false per the LESSON 42 flag pattern."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# API platform (wave B4 - ADR-047)
# ---------------------------------------------------------------------------

variable "enable_api_platform" {
  description = "Deploy the wave B4 API platform: APIM Developer_1 stv2 in internal VNet mode injected into snet-apim (no public IP, no zones, system-assigned MI), the dedicated snet-apim route table (0.0.0.0/0 -> firewall + ApiManagement service tag -> Internet), snet-apim service endpoints (Sql/Storage/EventHub/KeyVault), the scoped gateway-FQDN private DNS zone + apex A record + spoke/hub links, and the mock health API (docs/b4-apim-platform-design.md; ADR-047). Default false per the LESSON 42 flag pattern. ORDERING (design doc section 7): flip only AFTER platform/connectivity is applied with rcg-apim-egress-primary live - the APIM create needs firewall passage for its force-tunneled dependency traffic mid-provision."
  type        = bool
  default     = false
}

variable "apim_publisher_email" {
  description = "Publisher email for the APIM instance (required by the service; surfaces in APIM notifications config). Generic non-personal alias by default - never a personal address in the repo (standing rule); override in tfvars if a real distribution list exists."
  type        = string
  default     = "platform-team@example.com"
}

# ---------------------------------------------------------------------------
# Common
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Additional tags merged into all resources created by this module."
  type        = map(string)
  default     = {}
}
