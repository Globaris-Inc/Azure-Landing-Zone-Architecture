# Architecture

> **Status:** 🚧 Diagrams and detail populated incrementally as sections complete.
> Sections referenced: PROMPT.md §1–13.

---

## Management Group Hierarchy

<!-- Populated: Section 2 -->

```mermaid
graph TD
    TR[Tenant Root]
    TR --> C[Globaris]
    C --> P[Platform]
    C --> LZ[Landing Zones]
    C --> D[Decommissioned]
    C --> SB[Sandbox]
    P --> SEC[Security]
    P --> MGMT[Management]
    P --> ID[Identity]
    P --> CONN[Connectivity]
    LZ --> CORP[Corp]
    LZ --> ONL[Online]
```

---

## Hub & Spoke Network Topology

<!-- Populated: Sections 3, 8, 9 -->

```mermaid
graph LR
    subgraph eastus2 [Primary — eastus2]
        HUB1[Hub VNet\nAzure Firewall Premium\nVPN GW active-active\nDNS Private Resolver]
        CA1[corp-a1\nApp Service + SQL\nPrivate Endpoints]
    end
    subgraph centralus [DR — centralus]
        HUB2[Hub VNet\nAzure Firewall Premium\nVPN GW standby\nDNS Private Resolver]
        CA2[corp-a2\nCold standby]
    end
    subgraph online [Online]
        OP1[online-p1\nApp Gateway WAF v2\nStatic Web App]
    end

    CA1 <-->|VNet Peering| HUB1
    CA2 <-->|VNet Peering| HUB2
    HUB1 <-->|Global VNet Peering| HUB2
    OP1 <-->|VNet Peering| HUB1
```

---

## Zero Trust Pillar Mapping

<!-- Populated: Section 5 -->

| Pillar | Control | Implementation |
|--------|---------|----------------|
| Identity | MFA for all admins | Conditional Access policy |
| Identity | No legacy auth | CA block policy |
| Identity | PIM for privileged roles | eligible-only, 8h max |
| Devices | Compliant device required | CA — Azure portal + mgmt API |
| Network | Private Endpoints only | Azure Policy Deny on Landing Zones MG |
| Network | Firewall inspection | Azure Firewall Premium TLS inspection |
| Data | CMK on state storage | Customer-managed key on SA |
| Applications | WAF in front of online workloads | App Gateway WAF v2 |
| Infrastructure | JIT VM access | Defender for Cloud JIT |

---

## DR / Business Continuity

<!-- Populated: Section 3 -->

| Target | RTO | RPO | Mechanism |
|--------|-----|-----|-----------|
| corp-a1 VMs | 4 hours | 15 minutes | Azure Site Recovery (ASR) |
| SQL Database | 1 hour | 5 minutes | Active Geo-Replication to corp-a2 |
| Platform state | Near-zero | Near-zero | GZRS storage account |
| Hub connectivity | 30 minutes | N/A | VPN GW standby in centralus |

> RTO/RPO values are targets for the POC demo; they are not contractual SLAs.

---

## Private DNS Zone Architecture

<!-- Populated: Section 4 -->

- All `privatelink.*` zones hosted in Connectivity subscription
- Zones linked to every hub VNet and spoke VNet
- DNS Private Resolver in each hub forwards to Azure DNS and receives on-premises queries
- No public DNS resolution for PaaS resources in `Corp` landing zone

---

## Defender for Cloud + Sentinel

<!-- Populated: Section 6 -->

```mermaid
graph LR
    D[Defender for Cloud]
    A[Azure Activity]
    E[Entra ID Sign-in/Audit]
    FW[Azure Firewall Logs]
    NS[NSG Flow Logs]
    D -->|Continuous Export| SEC_LA[Security LA Workspace]
    A --> SEC_LA
    E --> SEC_LA
    FW --> SEC_LA
    NS --> SEC_LA
    SEC_LA --> S[Microsoft Sentinel]
    S --> AR[Analytics Rules\n8–12 high-value]
    S --> WB[Workbooks]
    S --> PB[Playbooks\nauto-assign / isolate VM]
```

---

## Architectural Decision Records

<!-- See DECISIONS.md for full ADR text. Listed here for quick reference. -->

| ADR | Title | Date | Status |
|-----|-------|------|--------|
| ADR-001 | Repo root is the working directory, not a nested alz-poc/ subfolder | 2026-05-04 | Accepted |
