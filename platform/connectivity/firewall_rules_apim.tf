# Purpose: APIM egress rule collection group on the PRIMARY hub firewall policy
#          (wave B4, ADR-047). snet-apim keeps a 0.0.0.0/0 -> firewall default route
#          (dedicated rt-apim in the bank-app-p1 root); with default-deny, the stv2
#          instance's remaining force-tunneled platform dependencies (cert validation,
#          Entra, Azure Monitor, NTP, KMS, infrastructure diagnostics) need this set or
#          the APIM create hangs toward its 3h timeout. FQDN/port sets verified against
#          MS Learn api-management virtual-network-reference (ms.date 2026-04-30,
#          fetched at design 2026-07-18). PRIMARY policy only (ADR-044/ADR-009
#          pattern): nothing in the primary region (centralus, ADR-069) routes to
#          the secondary firewall. A NEW RCG
#          rather than extending rcg-aks-egress-primary: source prefix, lifecycle, and
#          review blast radius differ per wave.
# Section: Banking wave B4 (docs/b4-apim-platform-design.md section 6; ADR-047)
# Last updated: 2026-07-18
#
# Gated on var.enable_firewall via for_each (estate no-count rule, same as the AKS
# RCG): when the flag re-gates to false this RCG drops out of the plan with the policy.
#
# DELIBERATELY NO RULE FOR (mirrored from the design doc section 6 - posture wins,
# do not add):
#   - Storage / Sql / KeyVault / EventHub service tags - snet-apim carries service
#     endpoints for all four (design doc section 5b): APIM's own dependency traffic
#     rides the Azure backbone and never reaches the firewall.
#   - Developer portal CAPTCHA (client.hip.live.com / partner.hip.live.com) and
#     portal-publish Storage egress - the developer portal is not published at POC.
#   - SMTP relay - no email features in scope.
#   - dc.services.visualstudio.com - portal diagnostics extension, optional; add
#     later only if troubleshooting needs it.
#   - AzureActiveDirectory network tag - covered more tightly by the entra-auth FQDN
#     application rules below.
#   - graph.microsoft.com - only needed for developer portal Entra sign-in, out of
#     scope at POC.

resource "azurerm_firewall_policy_rule_collection_group" "apim_egress_primary" {
  for_each = var.enable_firewall ? { primary = "primary" } : {}

  name               = "rcg-apim-egress-primary"
  firewall_policy_id = module.hub_and_spoke.firewall_policies[each.key].id
  priority           = 310

  application_rule_collection {
    name     = "apim-egress-app"
    priority = 100
    action   = "Allow"

    # TLS certificate revocation checking (CRL/OCSP). Port 80 is REQUIRED here:
    # CRL/OCSP endpoints serve over HTTP by design.
    rule {
      name = "cert-validation"

      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = var.apim_egress_source_prefixes
      destination_fqdns = [
        "mscrl.microsoft.com",
        "crl.microsoft.com",
        "oneocsp.microsoft.com",
        "cacerts.digicert.com",
        "crl3.digicert.com",
        "csp.digicert.com",
      ]
    }

    # Entra ID authentication for the APIM platform (regional login endpoints ride
    # the *.login.microsoft.com wildcard).
    rule {
      name = "entra-auth"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = var.apim_egress_source_prefixes
      destination_fqdns = [
        "login.microsoftonline.com",
        "*.login.microsoft.com",
      ]
    }

    # stv2 platform internal diagnostics/telemetry set, including the Azure PKI
    # issuer endpoint.
    rule {
      name = "internal-diagnostics"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = var.apim_egress_source_prefixes
      destination_fqdns = [
        "azurewatsonanalysis-prod.core.windows.net",
        "*.data.microsoft.com",
        "azureprofiler.trafficmanager.net",
        "shavamanifestazurecdnprod1.azureedge.net",
        "shavamanifestcdnprod1.azureedge.net",
        "issuer.pki.azure.com",
      ]
    }

    # Windows Update / CTL download for the stv2 platform VMs.
    rule {
      name = "windows-platform"

      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = var.apim_egress_source_prefixes
      destination_fqdns = [
        "*.update.microsoft.com",
        "*.ctldl.windowsupdate.com",
        "ctldl.windowsupdate.com",
        "download.windowsupdate.com",
        "go.microsoft.com",
      ]
    }

    # Microsoft Defender definition/telemetry endpoints on the platform VMs.
    rule {
      name = "defender"

      protocols {
        type = "Https"
        port = 443
      }

      source_addresses = var.apim_egress_source_prefixes
      destination_fqdns = [
        "wdcp.microsoft.com",
        "wdcpalt.microsoft.com",
      ]
    }
  }

  network_rule_collection {
    name     = "apim-egress-net"
    priority = 200
    action   = "Allow"

    # APIM diagnostics/metrics publication: TCP 1886 (Resource Health) + 443.
    rule {
      name                  = "azure-monitor"
      protocols             = ["TCP"]
      source_addresses      = var.apim_egress_source_prefixes
      destination_addresses = ["AzureMonitor"]
      destination_ports     = ["1886", "443"]
    }

    # NTP time sync. Destination * deliberately (NOT an FQDN): an FQDN-based
    # NETWORK rule would force the firewall DNS proxy on, a policy behavior change
    # with spoke-wide blast radius - DNS proxy stays off (ADR-044 rationale).
    rule {
      name                  = "ntp"
      protocols             = ["UDP"]
      source_addresses      = var.apim_egress_source_prefixes
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }

    # Windows activation (KMS) for the stv2 platform VMs. Port-scoped with
    # destination * for the same keep-DNS-proxy-off trade as NTP.
    rule {
      name                  = "kms"
      protocols             = ["TCP"]
      source_addresses      = var.apim_egress_source_prefixes
      destination_addresses = ["*"]
      destination_ports     = ["1688"]
    }
  }
}
