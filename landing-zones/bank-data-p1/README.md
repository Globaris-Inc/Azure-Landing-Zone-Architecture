# landing-zones/bank-data-p1

bank-data-p1 landing zone (banking data + AI spoke). Spoke VNet (10.32.0.0/16 default,
eastus2) peered to the primary hub, firewall-routed, private-endpoint-only. Wave B1
ships the NETWORK FOUNDATION ONLY: VNet + subnets (snet-databricks-host and
snet-databricks-container, both delegated to Microsoft.Databricks/workspaces for the
wave B5 VNet injection, plus snet-private-endpoints), NSGs (dedicated Databricks NSG;
the service injects its managed rules at workspace create), 0.0.0.0/0 UDR to the
primary hub firewall, hub peering, Private DNS zone links
(blob/dfs/databricks/openai/cognitiveservices/search), VNet flow log with Traffic
Analytics, and the OQ-024/ADR-028 flow-log-SA Waiver exemption.

## Banking address-space allocation (architect-confirmed, B1 amendment ruling)

| CIDR | Assignment | Status |
|------|------------|--------|
| 10.30.0.0/16 | bank-app-p1 (eastus2) | Deployed by `landing-zones/bank-app-p1` |
| 10.31.0.0/16 | bank-app DR (centralus) | RESERVED - design-only, NOT deployed |
| 10.32.0.0/16 | bank-data-p1 (eastus2) | Deployed by THIS root |
| 10.33.0.0/16 | bank-data DR (centralus) | RESERVED - design-only, NOT deployed |

Non-overlapping with the existing estate (hubs 10.0/16 + 10.1/16, identity
10.2.0.0/24, spokes 10.10/16, 10.11/16, 10.20/16).

Banking wave B1 (docs/banking-platform-design.md). Placement per OQ-035 resolution:
landingzones subscription under the Corp MG, conditional on the B1 pre-clearance quota
gate. Workload tiers (Databricks + ADLS Gen2 wave B5, Foundry / AI Search / Document
Intelligence wave B6) land in this root later behind their own gates - LESSON 42
shippable-network-only. Apply after platform/connectivity.
