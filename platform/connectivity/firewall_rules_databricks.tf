# Purpose: Databricks control-plane egress rule collection group on the PRIMARY hub
#          firewall policy (wave B5, ADR-048). Both Databricks subnets carry the B1
#          0.0.0.0/0 -> firewall UDR (secure cluster connectivity egress-with-UDR);
#          this RCG is what lets a FUTURE cluster reach the Databricks control plane,
#          DBFS/artifact storage, telemetry Event Hubs, the legacy Hive metastore and
#          Entra ID through that route. DORMANT at B5 (hard boundary: zero clusters,
#          so no compute-plane egress exists) but it makes the posture QA-verifiable
#          and closes the B1-parked caveat in landing-zones/bank-data-p1/main.tf.
#          PRIMARY policy only (ADR-044/ADR-009 pattern): nothing in eastus2 routes
#          to the secondary firewall. A NEW RCG rather than extending the AKS/APIM
#          ones: source prefix, lifecycle, and review blast radius differ per wave.
# Section: Banking wave B5 (docs/b5-data-platform-design.md section 5; ADR-048)
# Last updated: 2026-07-18
#
# Rule mechanism (design doc section 5, verified against MS Learn vnet-inject NSG
# rules table + the Databricks UDR doc at design time 2026-07-18): built ENTIRELY
# from Microsoft-maintained SERVICE TAGS - the current Databricks-RECOMMENDED
# mechanism ("prevent service outages due to IP changes"). Deliberately NO FQDN
# rules: FQDN-based network rules would force the firewall DNS proxy ON, a policy
# behavior change with spoke-wide blast radius - DNS proxy stays OFF (ADR-044
# rationale, LESSON 40 IP/FQDN rot class avoided). No service-tag BYPASS routes are
# added either (unlike APIM's stv2 management-plane requirement, Databricks
# documents firewall/NVA egress as fully supported - everything rides the existing
# 0.0.0.0/0 UDR through AZFW inspection).
#
# Rule set = the documented required NSG outbound set plus the optional Entra tag:
#   AzureDatabricks TCP 443/3306/8443-8451 (control plane API, SCC relay/NPIP
#     tunnel, webapp, UC logging), Storage TCP 443 (GLOBAL tag deliberately, not
#     region-scoped - kills the documented secondary-region artifact-storage
#     landmine), EventHub TCP 9093 (telemetry/log shipping), Sql TCP 3306 (legacy
#     Hive metastore - being phased out for new workspaces but still current;
#     matches the RP NSG rule set), AzureActiveDirectory TCP 443 (cluster AAD
#     auth; needed for AAD-only storage access).
#
# Gated on var.enable_firewall via for_each (estate no-count rule, same as the
# AKS/APIM RCGs): when the flag re-gates to false this RCG drops out of the plan
# with the policy.

resource "azurerm_firewall_policy_rule_collection_group" "dbx_egress_primary" {
  for_each = var.enable_firewall ? { primary = "primary" } : {}

  name               = "rcg-dbx-egress-primary"
  firewall_policy_id = module.hub_and_spoke.firewall_policies[each.key].id
  priority           = 320

  network_rule_collection {
    name     = "dbx-egress-net"
    priority = 100
    action   = "Allow"

    # Databricks control plane: API + secure cluster connectivity relay (the NPIP
    # tunnel), webapp, and Unity Catalog logging (8444).
    rule {
      name                  = "dbx-control-plane"
      protocols             = ["TCP"]
      source_addresses      = var.dbx_egress_source_prefixes
      destination_addresses = ["AzureDatabricks"]
      destination_ports     = ["443", "3306", "8443-8451"]
    }

    # Artifact + log + DBFS blob/dfs storage. GLOBAL Storage tag deliberately
    # (not Storage.EastUS2): Databricks documents artifact storage in the
    # region's SECONDARY as a landmine for region-scoped rules.
    rule {
      name                  = "dbx-storage"
      protocols             = ["TCP"]
      source_addresses      = var.dbx_egress_source_prefixes
      destination_addresses = ["Storage"]
      destination_ports     = ["443"]
    }

    # Telemetry / log shipping (Kafka endpoint).
    rule {
      name                  = "dbx-eventhub"
      protocols             = ["TCP"]
      source_addresses      = var.dbx_egress_source_prefixes
      destination_addresses = ["EventHub"]
      destination_ports     = ["9093"]
    }

    # Legacy Hive metastore (Azure Database for MySQL behind the Sql tag).
    rule {
      name                  = "dbx-metastore"
      protocols             = ["TCP"]
      source_addresses      = var.dbx_egress_source_prefixes
      destination_addresses = ["Sql"]
      destination_ports     = ["3306"]
    }

    # Entra ID auth from cluster nodes (optional per the UDR doc; required for
    # AAD-only storage access - the estate data-plane bar).
    rule {
      name                  = "dbx-entra"
      protocols             = ["TCP"]
      source_addresses      = var.dbx_egress_source_prefixes
      destination_addresses = ["AzureActiveDirectory"]
      destination_ports     = ["443"]
    }
  }
}
