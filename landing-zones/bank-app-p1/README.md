# landing-zones/bank-app-p1

bank-app-p1 landing zone (banking application spoke). Spoke VNet (10.30.0.0/16 default,
eastus2) peered to the primary hub, firewall-routed, private-endpoint-only. Wave B1
ships the NETWORK FOUNDATION ONLY: VNet + subnets (snet-aks-nodes, snet-apim,
snet-private-endpoints), NSGs (APIM stv2 required rules pre-staged), 0.0.0.0/0 UDR to
the primary hub firewall, hub peering, Private DNS zone links (aks/acr/servicebus),
VNet flow log with Traffic Analytics, and the OQ-024/ADR-028 flow-log-SA Waiver
exemption.

## Banking address-space allocation (architect-confirmed, B1 amendment ruling)

| CIDR | Assignment | Status |
|------|------------|--------|
| 10.30.0.0/16 | bank-app-p1 (eastus2) | Deployed by THIS root |
| 10.31.0.0/16 | bank-app DR (centralus) | RESERVED - design-only, NOT deployed |
| 10.32.0.0/16 | bank-data-p1 (eastus2) | Deployed by `landing-zones/bank-data-p1` |
| 10.33.0.0/16 | bank-data DR (centralus) | RESERVED - design-only, NOT deployed |

Non-overlapping with the existing estate (hubs 10.0/16 + 10.1/16, identity
10.2.0.0/24, spokes 10.10/16, 10.11/16, 10.20/16).

## snet-aks-nodes: wave B2 inheritance requirement (architect ruling)

At wave B2 the AKS cluster (Azure CNI Overlay) MUST pin its pod CIDR explicitly -
architect recommends **192.168.0.0/16** - and never leave it to the module default.
The overlay pod CIDR is logically separate from the VNet space but must not collide
with any routed estate range; pinning it keeps config == intent and avoids a silent
module-default drift. Recorded here so B2 inherits the requirement.

Banking wave B1 (docs/banking-platform-design.md). Placement per OQ-035 resolution:
landingzones subscription under the Corp MG, conditional on the B1 pre-clearance quota
gate. Workload tiers (AKS + ACR wave B2, Event Hubs / Service Bus wave B3, APIM wave
B4) land in this root later behind their own gates - LESSON 42 shippable-network-only.
Apply after platform/connectivity.
