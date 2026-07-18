# Purpose: AKS egress rule collection group on the PRIMARY hub firewall policy
#          (wave B2, ADR-044). The ADR-009-era hub policies hold zero allow rules;
#          with default-deny, a UDR-egress AKS cluster cannot bootstrap without this
#          set. Rules verified against Microsoft Learn aks/outbound-rules-control-egress
#          (page dated 2026-06-18, fetched 2026-07-18). PRIMARY policy only: the bank
#          spokes are eastus2-only and their UDRs point at 10.0.0.4; the secondary
#          policy stays rule-less (its firewall returns for mesh-route integrity).
# Section: Banking wave B2 (docs/b2-aks-platform-design.md section 6; ADR-044)
# Last updated: 2026-07-18
#
# The pinned pattern module (avm-ptn-alz-connectivity-hub-and-spoke-vnet 0.17.1) has
# no rule-collection support in its firewall_policy schema, so this is a standalone
# resource. Gated on var.enable_firewall via for_each (estate no-count rule): when the
# ADR-042/044 flag re-gates to false, this RCG drops out of the plan with the policy -
# the EOD re-gate needs no extra step.
#
# DELIBERATELY NO RULE FOR (each already carried by the private-networking path -
# posture wins, do not add):
#   - Node/pod -> API server (konnectivity tunnel: UDP 1194 / TCP 9000 / 443 /
#     *.hcp.<region>.azmk8s.io) - private cluster; the API server private endpoint
#     lives in the cluster VNet, so traffic matches the more-specific VNet system
#     route and never reaches the firewall.
#   - Pulls from OUR ACR - registry PE in snet-private-endpoints (10.30.2.0/24);
#     privatelink.azurecr.io resolves registry + data endpoints to the PE, in-VNet.
#   - Azure DNS 168.63.129.16 - host-routed platform traffic; never hits the UDR.
#   - Hub/spoke private traffic - peering + system routes are more specific than
#     0.0.0.0/0.
# Also excluded: GPU/Windows FQDNs, Azure Policy add-on and Key Vault CSI FQDNs
# (add-ons not deployed at B2).

resource "azurerm_firewall_policy_rule_collection_group" "aks_egress_primary" {
  for_each = var.enable_firewall ? { primary = "primary" } : {}

  name               = "rcg-aks-egress-primary"
  firewall_policy_id = module.hub_and_spoke.firewall_policies[each.key].id
  priority           = 300

  application_rule_collection {
    name     = "aks-required-fqdns"
    priority = 100
    action   = "Allow"

    # Azure-Firewall-maintained FQDN tag covering the AKS base required set
    # (mcr.microsoft.com, *.data.mcr.microsoft.com, management.azure.com,
    # login.microsoftonline.com, packages.microsoft.com, packages.aks.azure.com, ...).
    # Auto-tracks Microsoft's list; FQDN tags in application rules do NOT need the
    # firewall DNS proxy, which stays OFF in our policy config.
    rule {
      name = "aks-fqdn-tag"

      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }

      source_addresses      = var.aks_egress_source_prefixes
      destination_fqdn_tags = ["AzureKubernetesService"]
    }

    # Documented recommended set: node OS security patches between node-image
    # upgrades. Split by protocol so each FQDN gets only the port it needs.
    rule {
      name = "aks-ubuntu-repos"

      protocols {
        type = "Http"
        port = 80
      }

      source_addresses = var.aks_egress_source_prefixes
      destination_fqdns = [
        "security.ubuntu.com",
        "azure.archive.ubuntu.com",
        "changelogs.ubuntu.com",
      ]
    }

    rule {
      name = "aks-ubuntu-snapshot"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses  = var.aks_egress_source_prefixes
      destination_fqdns = ["snapshot.ubuntu.com"]
    }

    # Defender for Containers event upload + LAW auth (login.microsoftonline.com is
    # already in the FQDN tag). The opinsights pair overlaps the AzureMonitor network
    # rule below; harmless, keeps the L7 path explicit if the network rule is ever
    # tightened.
    rule {
      name = "aks-defender"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = var.aks_egress_source_prefixes
      destination_fqdns = [
        "*.cloud.defender.microsoft.com",
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
      ]
    }
  }

  network_rule_collection {
    name     = "aks-required-network"
    priority = 200
    action   = "Allow"

    # Container Insights / AMA ingestion + DCR fetch to the platform LAW - the
    # documented service-tag form for UDR clusters.
    rule {
      name                  = "azure-monitor"
      protocols             = ["TCP"]
      source_addresses      = var.aks_egress_source_prefixes
      destination_addresses = ["AzureMonitor"]
      destination_ports     = ["443"]
    }

    # NTP: docs say not required for post-2021 node images - kept as one cheap line
    # to remove the failure class. Destination * deliberately (NOT ntp.ubuntu.com):
    # an FQDN-based NETWORK rule would force the firewall DNS proxy on, a policy
    # behavior change with spoke-wide blast radius - DNS proxy stays off.
    rule {
      name                  = "ntp"
      protocols             = ["UDP"]
      source_addresses      = var.aks_egress_source_prefixes
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }
  }
}
