# Wave B9 - Security & Compliance hardening target design

> **Status:** READY FOR IMPLEMENTATION. B9 is THINNER than the founding scope because most of it is
> already built (live-verified below); its real net-new is CMK (a costed fork, OQ-047), the
> PCI/SOC compliance-visibility additions, and the AUDIT-FIRST policy-posture establishment that
> B-R later promotes to Deny. Design/docs only; no Terraform written here.
> **Owner:** Cloud Solutions Architect. **Date:** 2026-07-19.
> **Reads:** docs/b-restoration-design.md (register b1-b14), docs/banking-platform-design.md 2.7,
> ADR-033/034 (tenant-gated), ADR-046/048 (CMK deferrals), ADR-043 (Defender-for-Containers).
> **New records:** ADR-053 (B9 rulings + the B9/B-R split), OQ-047 (CMK scope/cost fork).
> **Sequencing (user 2026-07-19):** B9 (now) -> B-R -> B8 -> B10.
> **Root:** extends `platform/security` (Defender/compliance/CMK-policy) + `platform/management-groups`
> (the b11 platform-MG Audit assignment) + the data-store roots for CMK config. No new root/spoke.

---

## 0. Executive summary

- **Live verification collapsed most of the founding B9 scope into "already built":** Defender for
  Cloud runs 11 plans INCLUDING **Containers** (the ADR-043 B2 flip landed) **and AI**; the **NIST
  SP 800-53 R5 + CIS Azure 2.0** regulatory initiatives are already assigned at the Globaris root
  (reg-nist_sp_800_53_r5, reg-cis_azure_2_0_0 live). So B9 does NOT re-build those.
- **The central deliverable is the B9-vs-B-R responsibility matrix (section 1).** The deconfliction
  PRINCIPLE that resolves every register item cleanly: **B9 does the ADDITIVE, NON-ENFORCING,
  NON-BREAKING half** (net-new capability + Audit-first visibility that cannot block a create or
  break a running estate / a later wave's CI); **B-R does the ENFORCEMENT (Deny-promotion) and the
  live-resource network FLIPS that carry operational/CI risk** (which the user explicitly confirmed
  for B-R). Nothing is enforced or flipped at B9.
- **B9 net-new (this wave):** (a) CMK breadth - build the CMK infrastructure and apply it to the
  data stores, gated behind the OQ-047 cost fork; (b) PCI DSS v4.0.1 + SOC 2 Type 2 regulatory
  initiatives at root (assessment visibility, additive); (c) b11 stage 1 - assign the public-
  endpoint initiative at the platform MG parameterized to AUDIT (the visibility the platform tree
  lacks today); (d) b13 - move the OpenAI/CogServ guardrails to Audit for visibility. All behind a
  default-false `enable_security_hardening` flag (LESSON 42), CMK behind its own sub-flag.
- **B9 DESIGNS but does NOT deploy (honoring the user's b10-at-B-R confirmation):** the KV network
  hardening (b10) - the tfstate-KV JIT/Deny spec and the security-KV consumer inventory are
  produced here; the actual network-Deny FLIP happens at B-R alongside the b11 Deny-promotion, so
  the KV goes private exactly when the enforcing policy lands (no unprotected window; CI-risk
  verification bundled into the restoration wave).
- **CMK is a genuine fork (OQ-047):** the estate has ZERO customer-managed keys / disk encryption
  sets today (live-verified). CMK is net-new infrastructure (a purge-protected KV + keys + managed
  identities with Key Vault Crypto roles + per-resource CMK config + DES for any disks) with real
  cost and an availability-coupling risk (lose the key -> lose data access). Scope + cost surfaced
  as OQ-047; if deferred, CMK becomes documented-design and the rest of B9 still ships.
- **Cost:** near-zero except CMK. Reg-compliance initiatives, Audit assignments = free (assessment
  only). CMK adds a KV (~$0-5/mo + key ops) + operational care. B9 delta ~$0-2/day without CMK;
  CMK cost is the OQ-047 line.

## 1. THE B9-vs-B-R RESPONSIBILITY MATRIX (the key deliverable)

Deconfliction principle: **ADDITIVE/visibility/net-new -> B9; ENFORCE(Deny)/live-network-flip/
deviation-reversal -> B-R.** This honors the user's confirmation that b9/b10/b11 ENFORCE at B-R
(Audit != enforce; a spec != a flip).

| Register / scope item | B9 (now) | B-R (restoration) | Why the split falls here |
|---|---|---|---|
| **b10 - tfstate KV + security KV open (pna Enabled, no ACL)** - live-verified today | **DESIGN only:** the tfstate-KV JIT/Deny spec + the security-KV consumer inventory (enumerate live readers from KV diagnostics) | **DEPLOY:** the network-Deny FLIP on both KVs (ACL default Deny + AzureServices bypass, firewall mode, tfstate KV CI JIT-allowlist) | Flipping a live KV to network-Deny carries CI/operational break risk (esp. tfstate KV, read during every plan); user confirmed b10 at B-R; the flip lands with the b11 enforcing policy so there is no hardened-but-unenforced window |
| **b11 - platform MG has no public-endpoint Deny coverage** (live: guardrail Enforce-GR-* exist but no Deny-Public-Endpoints; corp/landingzones have it) | **DEPLOY stage 1:** assign the Deny-PublicPaaSEndpoints initiative at the platform MG parameterized to ALL members AUDIT (visibility, never blocks) | **DEPLOY stage 2:** promote storage+KV members to Deny + the 4 RG-scoped exemptions (state SA, finops SA, both KVs) | Audit is additive/non-blocking = safe now (the architect's original Audit-first@B9 ruling, user-confirmed); Deny enforces = B-R |
| **b13 - Enforce-GR-OpenAI0/CogServ0 DoNotEnforce** at landingzones MG | **DEPLOY:** move to AUDIT (visibility; the account is already compliant on enforced members) | **DEPLOY:** enforce decision (Deny) with b11 stage 2 | Same Audit-first/Deny-at-B-R pattern; siblings of b11 |
| **CMK breadth** (ADR-046/048 deferrals; estate CMK = 0 live) | **DEPLOY (if OQ-047 = yes):** CMK infra + CMK on the data stores | (nothing - or the CMK-enforcement policy Audit->Deny if the user wants CMK guardrails) | Net-new capability, founding-B9 line ("extend the CMK pattern to the new data stores"); additive to data-at-rest; fork-gated |
| **PCI DSS v4.0.1 + SOC 2 Type 2 reg compliance** (NIST+CIS already live) | **DEPLOY:** assign at root MG (assessment visibility, no enforcement) | - | Assessment-only, additive, founding-B9 line |
| **b9 - finops GZRS SA open** (management sub) | - | **DEPLOY:** harden to state-SA pattern (Deny+bypass) | Live-network-flip + deviation-reversal; user confirmed at B-R; management-sub, not B9's security scope |
| **Defender for Containers** (ADR-043 deferred-from-B2) | **none - ALREADY LIVE** (verified: Containers plan Standard) | - | Built in B2; B9 confirms, no action |
| Regulatory NIST+CIS | none - already live | - | Built at B0a |
| ADR-033/034 tenant-gated (UEBA, dc-aad, dc-ti, MDE, firewall TI) | none (stay flag-off) | **B-R f10:** flip after the Security-Admin grant | Authorization-gated (LESSON 49); user f10 = grant+flip at B-R |
| Flag-restore deviations (VPN GW, DNS resolver, etc.), OQ-046 forks | - | **DEPLOY** (B-R register a1-a5 + OQ-046) | Deviation-reversals by definition |

**One-line rule for future readers:** if it could BLOCK a create, ENFORCE a Deny, or FLIP a live
resource to a more-restricted network state, it is B-R; if it only ADDS visibility or net-new
capability, it is B9.

## 2. Live-verified state (2026-07-19) - what is already built vs net-new

| Thing B9 was to touch | Live state today | B9 action |
|---|---|---|
| Defender plans | 11 Standard incl. **Containers + AI** + StorageAccounts + SqlServers + CloudPosture/FoundationalCspm | none - built |
| Regulatory: NIST 800-53 R5, CIS Azure 2.0 | assigned at Globaris root (live) | none - built |
| Regulatory: PCI DSS, SOC 2 | NOT assigned | **B9 net-new** (section 3.2) |
| tfstate KV, security KV | both pna=Enabled, networkAcls=null (b10 reproduced) | **B9 designs; B-R flips** |
| CMK / Disk Encryption Sets | **0 estate-wide** (greenfield) | **B9 net-new if OQ-047=yes** (section 3.1) |
| Platform MG public-endpoint Deny coverage | absent (guardrails present, DoNotEnforce; no Deny-Public-Endpoints) | **B9 Audit assign (b11 stage 1)** |
| OpenAI/CogServ guardrails | DoNotEnforce at landingzones MG | **B9 to Audit (b13)** |

## 3. B9 net-new specifications (implementer contract)

### 3.1 CMK breadth (gated behind OQ-047; sub-flag `enable_cmk`)

Estate CMK = 0 today, so this is greenfield. Scope (which data stores get CMK) is the OQ-047 fork.
Mechanism (no NEW module - config on existing modules + a KV + keys + identities):
- A purge-protected, soft-delete Key Vault for the CMK keys (the estate KV module
  `avm-res-keyvault-vault` at its existing pin; purge protection MANDATORY for CMK) + one RSA key
  per protected store (or one shared key - OQ-047 granularity).
- **Storage CMK (ADLS `stlake`, and any future storage):** the `avm-res-storage-storageaccount`
  0.7.3 `customer_managed_key` input (verified present in the module) + a user-assigned identity
  with Key Vault Crypto Service Encryption User on the CMK KV. NOTE: the RP-managed `dbstorage`
  (Databricks) is NOT customer-configurable for CMK the same way - Databricks managed-services CMK
  is a workspace-level input (avm-res-databricks-workspace `managed_services_cmk_key_vault_key_id`
  / `dbfs_root_cmk...`, verified present) and is its OWN decision (OQ-047 sub-item; requires
  workspace update).
- **Foundry / AI Search CMK:** both modules expose `customer_managed_key` (verified in the B6
  module reads); additive config.
- **Disks:** a native `azurerm_disk_encryption_set` only if any managed disks exist (AKS node OS
  disks use platform-managed by default; CMK-on-AKS-disks is a distinct AKS setting) - likely
  design-only at POC.
- **Availability-coupling risk (state it):** CMK couples data availability to KV key availability;
  a deleted/inaccessible key = inaccessible data. Purge protection + soft delete + key backup are
  mandatory; this is the operational cost of CMK, not just the KV bill.

### 3.2 PCI DSS v4.0.1 + SOC 2 Type 2 (assessment visibility)

Extend the existing `local.regulatory_compliance_initiatives` map + the
`azurerm_management_group_policy_assignment.regulatory_compliance` for_each in
`platform/security/defender.tf` (proven pattern; NIST+CIS use it) with:
- SOC 2 Type 2: `/providers/Microsoft.Authorization/policySetDefinitions/4054785f-702b-4a98-9215-009cbd58b141` (VERIFIED live today; 242 params - implementer confirms 0 required-without-default, matching the NIST/CIS pattern).
- PCI DSS v4.0.1: `/providers/Microsoft.Authorization/policySetDefinitions/a06d5deb-24aa-4991-9d58-fa7563154e31` (VERIFIED live today; 392 params - confirm required-param defaults; prefer v4.0.1 over the lighter "PCI DSS v4" GUID c676748e). Assessment-only (assignment creates the compliance dashboard stream, enforces nothing).
- Founding design named PCI/NIST/SOC; NIST is live, so B9 adds PCI + SOC (+ CIS already there as a bonus framework). Assigned at the Globaris root like the existing two.

### 3.3 b11 stage 1 - platform MG Audit assignment

Assign the `Deny-PublicPaaSEndpoints` initiative (the same one corp uses) at the PLATFORM MG,
parameterized so ALL members = **Audit** (the deny-pub-net-globaris-at-landingzones precedent:
a custom assignment of the deny initiative with Audit effect). Delivered via the estate policy
mechanism (either avm-ptn-alz policy_assignments at platform scope, or a native
`azurerm_management_group_policy_assignment` in platform/security - implementer picks the one that
does not perturb the avm-ptn-alz state; a native assignment at platform MG is the lower-blast-radius
choice and mirrors how deny-pub-net-globaris was done). Audit never blocks -> safe now. B-R
promotes storage+KV members to Deny + the 4 exemptions.

### 3.4 b13 - OpenAI/CogServ guardrails to Audit

Move `Enforce-GR-OpenAI0` / `Enforce-GR-CogServ0` from DoNotEnforce to Audit (visibility). Same
non-blocking additive change; B-R decides Deny.

## 4. CMK fork (OQ-047) - the one genuine user decision

CMK is material cost+complexity+risk, and the estate has none today, so it is a real fork not an
architect ruling. Options (per data-store granularity):
- **A (recommended for a banking posture claim):** CMK on the lakehouse ADLS (`stlake`) + Foundry +
  AI Search + Databricks managed-services/DBFS - the data stores holding banking/analytics/AI data.
  One purge-protected CMK KV + keys + identities. Cost ~$1-5/mo KV/key-ops + operational care.
- **B (minimal):** CMK on ADLS only (the primary lakehouse); others documented-design.
- **C (defer):** CMK documented-design, deployed at a later hardening pass or B-R; B9 ships without
  it. Zero cost, thinner banking-encryption story.
Recommendation: A if the production claim needs customer-managed encryption at rest across the data
tier; else B. The per-store list + the availability-coupling acceptance is the user's call (OQ-047).

## 5. What B9 does NOT include (tight boundary)

- No Deny/enforcement of anything (all B9 policy work is Audit/assessment) - Deny is B-R.
- No KV network flip, no finops-SA flip, no flag-restore deviations (all B-R).
- No tenant-Security-Admin-gated features (UEBA/dc-aad/dc-ti/MDE/firewall-TI stay flag-off; B-R f10
  after the grant).
- No CA-policy enforcement-mode flip (the 8 report-only CA policies - a recorded user decision,
  not pulled into B9 unless the user asks).
- No Defender plan changes (11 plans already live incl. Containers+AI).
- No new Sentinel analytics/UEBA, no PIM access reviews (documented gaps, out of scope).
- No AKS workload-identity federation build (founding 2.7 listed it B1/B9; OIDC issuer + workload
  identity were enabled at B2 create - the federation of specific workload identities is
  application scope, not B9 platform scope).

## 6. Module / policy verification (2026-07-19)

| Item | Verification |
|---|---|
| Defender plans incl. Containers + AI | LIVE (`az security pricing list`) |
| NIST 800-53 R5 + CIS Azure 2.0 assigned at root | LIVE (`az policy assignment list`) |
| PCI DSS v4.0.1 (a06d5deb-...), SOC 2 Type 2 (4054785f-...) built-in initiatives exist | LIVE (`az policy set-definition list`); GUIDs captured; required-param-default check at build |
| Both KVs pna=Enabled, networkAcls=null | LIVE (`az keyvault show`) |
| CMK/DES estate-wide = 0 | LIVE (`az resource list` diskEncryptionSets = 0) |
| Platform MG lacks Deny-Public-Endpoints (guardrails present, DoNotEnforce) | LIVE (`az policy assignment list` platform MG) |
| Storage CMK input (`customer_managed_key`) on avm-res-storage-storageaccount 0.7.3 | source-verified (B5 read) |
| Databricks CMK inputs (`managed_services_cmk_key_vault_key_id`, `dbfs_root_cmk_key_vault_key_id`) on avm-res-databricks-workspace 0.5.0 | source-verified (B5 read) |
| Foundry/Search `customer_managed_key` inputs | source-verified (B6 read) |
| Reg-compliance assignment pattern (`azurerm_management_group_policy_assignment`) | existing in platform/security/defender.tf |
| NOT verified (build/pre-clearance): PCI/SOC required-param defaults; the exact KV CMK module pin/purge-protection wiring; whether a native platform-MG assignment vs avm-ptn-alz is lower-blast-radius (implementer picks); Databricks CMK requires a workspace UPDATE (plan-scan for ForceNew) | flagged |

## 7. ADR + fork

- **ADR-053:** the B9 rulings + the B9/B-R split principle (additive/Audit -> B9; enforce/flip ->
  B-R), honoring the user's b9/b10/b11-at-B-R confirmation (Audit != enforce; spec != flip).
- **OQ-047:** CMK scope/cost fork (which data stores; per section 4). The ONLY genuine user fork in
  B9; everything else is architect rulings within the accepted founding + register scope.

## 8. Pre-clearance / QA feed (for docs/preclearance/b9-security.md, before any apply)

- Live re-verify: Defender plans unchanged; NIST/CIS still assigned; the PCI/SOC GUIDs + param
  defaults; the two KV states (design input, not flipped); platform MG assignment set.
- Plan bars: pure adds/Audit-assignments only - ZERO Deny effects, ZERO KV network changes, ZERO
  changes to existing Defender plans or the NIST/CIS assignments; the platform-MG Audit assignment
  must NOT perturb the avm-ptn-alz state (native assignment = isolated) - any change/replace to an
  existing policy object or MG = STOP. CMK (if enabled): plan-scan the Databricks CMK for a
  workspace ForceNew/replace (LESSON 26) - if CMK-on-Databricks forces a workspace replace, that is
  a STOP (the workspace is live/QA-green); prefer CMK on the storage stores where it is additive.
- QA: PCI/SOC compliance streams appear in Defender; the platform-MG Audit assignment reports
  (non-compliant flags expected, never blocks); CMK (if deployed) - data stores show CMK with keys
  resolvable, access intact; the b10 KVs UNCHANGED (design-only, flipped at B-R).
- Standing gates: single-dispatcher, plan-scan, QA-before-green.
