# AWS Landing Zone POC - Draft Blueprint (seed document for the `AWS-Architecture` repo)

> **Status:** DRAFT for user review. Docs only, no code. This file lives in the Azure repo temporarily and
> moves to the new `AWS-Architecture` repo at scaffold time (its Section 1).
> **Author:** Cloud Solutions Architect. **Date:** 2026-07-11.
> **Purpose:** rebuild the Azure Landing Zone POC (PROMPT.md, 13 sections) as an AWS Organizations
> multi-account landing zone aligned to the AWS Security Reference Architecture (SRA) and the
> Well-Architected Framework, using Terraform with community-standard modules, the same CI discipline, and
> the full LESSONS.md operating loop.
> **How to read:** every recommendation here is opinionated but NOT decided. Anything marked `OQ-A*` is an
> open question for the user (section 9). Anything marked `UNVERIFIED` was not confirmed against current AWS
> docs and must be verified before it reaches a spec (LESSONS 40-41 apply to AWS exactly as they did to
> Azure). Load-bearing claims below were verified by web search dated 2026-07-11; see section 10.

---

## 0. Executive summary

- **Same project, different substrate.** The Azure build proved a process (pre-clearance, plan-scan,
  one-fix-spec, QA-before-green, modules-direct, gated CI). The AWS build reuses that process unchanged and
  re-derives only the platform-specific knowledge (policy runtime, quotas, identity, state semantics).
- **Recommended shape:** DIY AWS Organizations in Terraform (not Control Tower), 8 member accounts mirroring
  the 5-subscription Azure model, Transit Gateway + AWS Network Firewall centralized inspection in a Network
  account, Identity Center for human access, Security Hub + GuardDuty + Inspector for security posture,
  CloudWatch + a central S3 log-archive account for telemetry, GitHub OIDC into per-account IAM roles for CI.
- **Honest gaps up front:** Conditional Access has NO AWS equivalent (section 1.2), Azure Policy's
  Modify/DeployIfNotExists has no preventive-plus-mutating twin (SCPs are deny-only; Config remediation is
  detective and lagging), and PIM maps only approximately onto Identity Center.
- **Cost:** roughly **$1,000 - $1,700 / month** as-gated at POC scale (section 8), materially cheaper than
  the Azure estate ($3,600 - $4,800) mainly because AWS Network Firewall endpoints cost a fraction of two
  Azure Firewall Premium instances and SSM Session Manager removes the bastion tier entirely.

---

## 1. Framework mapping: Azure CAF ALZ to the AWS landing zone

Target frame: **AWS Organizations multi-account landing zone** structured per the **AWS Security Reference
Architecture (SRA)** (management account kept empty of workloads; dedicated Security Tooling, Log Archive,
and Network accounts; org-wide delegated administration for security services) and assessed against the
**Well-Architected Framework** pillars. The SRA plays the role CAF ALZ played on Azure: the named,
Microsoft/AWS-endorsed reference that keeps the build credible rather than bespoke.

### 1.1 Core mapping table

Verified against current AWS docs where marked; the rest is standing AWS platform knowledge that still gets
re-verified at pre-clearance time per root (stale-by-default rule).

| # | Azure (as built) | AWS equivalent | Fidelity | Notes |
|---|---|---|---|---|
| 1 | Management groups (Globaris tree) | **Organizations OUs** | High | OUs nest under the org root; SCPs/tag policies attach per OU. May 2026: SCP quota doubled to 10 per node, 10,240 chars (verified). |
| 2 | Subscriptions (5) | **Member accounts** | High | The account is the isolation and billing boundary. More accounts than subs is idiomatic on AWS (section 3). |
| 3 | Azure Policy (Deny / Modify / DINE / Audit) | **SCPs** (preventive, deny-only) + **RCPs** (resource control policies, resource-perimeter) + **AWS Config rules / conformance packs** (detective) + **Config auto-remediation via SSM** (nearest DINE analog) + policy-as-code in CI (OPA/Conftest, carries over) | **Partial** | The big honest gap: no single engine does prevent+mutate+deploy. SCP = Deny only. Config = detect after the fact, with evaluation lag. Remediation = bolt-on per rule. Section 6.F re-derives the policy-runtime lessons. RCP scope: verify current service coverage at spec time (UNVERIFIED detail). |
| 4 | Hub-spoke VNets + Global VNet Peering + Azure Firewall Premium (TLS inspection) | **Transit Gateway** (per region, peered cross-region) + **AWS Network Firewall** in a central inspection VPC in the Network account | High | Centralized east-west + egress inspection is the standard TGW appliance-mode pattern. NFW supports TLS inspection; Feb 2026 removed the extra data charge for advanced (TLS) inspection (verified). |
| 5 | Private Endpoints + central Private DNS zones + DNS Private Resolver | **VPC interface endpoints (PrivateLink)** + **Route 53 private hosted zones** + **Route 53 Resolver endpoints/rules** | High | Centralized-endpoint pattern: shared interface endpoints in the Network account, PHZ associated to all spoke VPCs. Resolver endpoints only needed for hybrid/Managed-AD DNS (they are a big-ticket item, section 8). |
| 6 | Entra Domain Services | **AWS Managed Microsoft AD** | High (if kept) | $0.06/DC-hour Standard, 2 DCs minimum, ~ $88/mo (verified). Whether the POC needs a directory tier at all is OQ-A4 (recommend: drop/gate). Multi-account directory sharing edition constraints: UNVERIFIED, check before spec. |
| 7 | Conditional Access (8 policies as code) | **No equivalent.** Nearest posture: IAM Identity Center with enforced MFA, session duration, permission-set least privilege; external IdP (Entra ID!) federation if CA-grade sign-in policy is required | **Gap** | Be honest in the portfolio narrative: AWS has no tenant-level, context-aware sign-in policy engine. Geo-block, device compliance, sign-in frequency per app do not exist natively. If the demo must show CA, federate Identity Center to an external IdP that has it. |
| 8 | PIM (eligible roles, MFA + approval + max activation) | **Approximate:** Identity Center permission sets with short session durations; temporary elevated access via the AWS **TEAM** solution (open source) or third party | **Partial** | No native eligible-vs-active model. TEAM status/maintenance: UNVERIFIED, check before recommending in a spec. |
| 9 | Defender for Cloud (8 plans, CSPM, secure score) | **Security Hub** + **GuardDuty** + **Inspector** | High | 2025 repackaging (verified): old Security Hub renamed **Security Hub CSPM**; a new unified Security Hub is GA with consolidated per-resource pricing bundling Inspector + CSPM, 30-day trial. Pre-clearance must pin WHICH Security Hub is being enabled; this is a live churn zone (lifecycle-audit class). |
| 10 | Sentinel (SIEM, analytics rules, automation, UEBA) | Two honest options: **(a)** Security Hub as the finding plane + EventBridge rules for automation (no SIEM claim), or **(b)** **Security Lake** (OCSF, org-wide) + a query layer (Athena/OpenSearch) | **Partial** | Neither is a SIEM the way Sentinel is. Recommendation in OQ-A5: option (a) for the POC, Security Lake designed-not-built. |
| 11 | Log Analytics workspaces (platform + security) | **CloudWatch Logs** (per account/region, operational) + **org CloudTrail + Config + centralized logs in the Log Archive account S3** | Medium | AWS telemetry is decentralized by default; the Log Archive account S3 buckets are the durable central plane, CloudWatch is the query/alarm plane. No single KQL-style cross-estate workspace without Security Lake/Athena. |
| 12 | Recovery Services Vault + ASR | **AWS Backup** (vaults, plans, cross-region copy) + **Elastic Disaster Recovery (DRS)** for VM replication | High | Backup maps cleanly; DRS is the ASR analog and, like ASR in the Azure build, likely stays designed-not-drilled at POC scale. |
| 13 | App Gateway WAF_v2 | **ALB + AWS WAF** (web ACL) | High | Managed rule groups replace OWASP CRS config. |
| 14 | Static Web App | **S3 + CloudFront** (origin access control) | High | Cheaper and more idiomatic than the Azure equivalent. |
| 15 | Bastion (on-demand) | **SSM Session Manager** | High, **AWS win** | No bastion host, no public IP, no open inbound port, IAM-audited sessions, free. Delete the bastion line item. |
| 16 | Budgets + cost exports (FOCUS) + anomaly alerts | **AWS Budgets** + **Data Exports (CUR 2.0, FOCUS 1.0 available)** to S3 + **Cost Anomaly Detection** | High | Same three-plane FinOps model as the Azure build. Budgets actions can trigger stop-automation like the Azure guardrail runbook. |
| 17 | Tag governance (Modify add-if-missing + inherit) | **Organizations tag policies** + **required-tags Config rule** (+ optional SSM auto-remediation) | **Partial** | Tag policies mostly report and only enforce on tagging operations for supported types; there is no estate-wide add-if-missing mutator. Expect weaker enforcement than Azure and say so in docs. LESSON 38's drift-churn analog is smaller here. |
| 18 | DDoS Standard (flag, default OFF) | **Shield Standard** (free, always on) / **Shield Advanced** (subscription, ~ $3k/mo UNVERIFIED, 1-year commit) | High | Shield Advanced is the DDoS-flag analog: default OFF, documented as a production lever. |
| 19 | AMBA alert baseline (ADR-037, designed-not-built) | **No named AWS twin.** Analog = curated CloudWatch alarm baseline + AWS Health events via EventBridge + Config conformance packs for operational best practice | Medium | O&M stays a designed platform capability (section 4, AWS Section 13). |
| 20 | `azuread` provider (Graph) | Not needed; IAM + Identity Center resources live in the `aws` provider (`aws_ssoadmin_*`, `aws_identitystore_*`) | High | One provider fewer; one token-lifetime class fewer (but see section 6.H for the session-duration analog of LESSON 46). |

### 1.2 The gaps to own in the narrative

1. **Conditional Access has no AWS twin.** The portfolio story becomes "identity perimeter via Identity
   Center + MFA + short sessions + SCP guardrails," not "context-aware sign-in policy." If CA-grade control
   is a must-show, the design federates Identity Center to an external IdP and demonstrates the policy there.
2. **No Modify/DINE.** Azure Policy could rewrite and deploy; AWS prevention is deny-only (SCP/RCP) and
   correction is detective remediation with lag. Tag inheritance in particular degrades.
3. **No Sentinel.** Security Hub aggregates findings and EventBridge automates responses, but analytics
   rules over raw logs need Security Lake + a query layer, which is real additional build.
4. **Telemetry is federated, not centralized.** There is no single Log Analytics workspace; the central
   plane is S3 in Log Archive plus per-account CloudWatch. Cross-estate query is a design choice, not a
   default.

---

## 2. The structural decision: Control Tower vs DIY Organizations (OQ-A1)

Verified state of play (2026-07-11): Control Tower is AWS's managed landing zone (Account Factory, 750+
managed controls mapped to compliance frameworks); **AFT (Account Factory for Terraform)** is its
Terraform-native account-vending add-on, but AFT requires an existing Control Tower landing zone, runs
customizations at vending time, has no native deprovisioning workflow, and Control Tower itself makes
landing-zone changes through the console/its own APIs rather than as plain Terraform state. Community
consensus in 2026 still splits exactly along this line: managed guardrails vs full-IaC fidelity.

| Criterion | A. Control Tower (+ AFT) | B. DIY Organizations in Terraform |
|---|---|---|
| IaC fidelity | Low-medium: CT owns the landing zone; Terraform manages around it; drift between CT and TF state is a known pain | **Full**: org, OUs, SCPs, accounts, baselines all in Terraform state, plan-reviewable |
| Assembly effort | Low: guardrails, org CloudTrail, Config baseline, Account Factory out of the box | Higher: we assemble org trail, Config recorders/aggregator, SCP baseline, account baseline pipeline ourselves |
| Matches this project's ethos (everything in Terraform, modules-direct, CI-gated, ADR-038 lineage) | Poor | **Exact match** |
| Portfolio value | "I can operate CT" | **"I can BUILD a landing zone"** - mirrors the Azure build's demonstrated skill |
| Vendor endorsement | CT is the AWS-recommended default for most orgs | SRA + Organizations is fully supported and documented for orgs that want IaC control |
| Teardown/POC lifecycle | CT decommissioning is coarse and slow; AFT has no deprovision path | `terraform destroy` discipline carries from ADR-019/020 (account closure caveats aside, section 6.I) |
| Friction discovered in research | AFT's own pipeline infra; AFT's historic default VCS was CodeCommit, now closed to new customers (GitHub supported) | SCP/OU/account creation quirks we own directly |

**Recommendation: Option B, DIY Organizations in Terraform.** It is the faithful analog of how this team
built the Azure estate (native control plane + community modules consumed directly, no black-box wrapper),
it demos more skill, it keeps plan/apply/destroy as the single lifecycle, and it avoids a standing
CT-vs-Terraform drift war for a POC that will be torn down and rebuilt. The trade-off accepted: we hand-roll
the baselines CT gives for free, which is exactly the portfolio content we want to show. Formal decision:
**OQ-A1**.

---

## 3. Account topology draft

Mirrors the Azure 5-subscription model, expanded to idiomatic AWS account boundaries per the SRA.

| # | Account | OU | Azure analog | Purpose |
|---|---|---|---|---|
| 1 | **management** (org root account) | org root | (tenant + bootstrap) | Organizations, Identity Center, tag policies, budgets/CUR at payer level, NOTHING else. SCPs do not apply here (section 6.F), so it stays empty by discipline, not policy. |
| 2 | **log-archive** | Security OU | (part of management sub) | Org CloudTrail bucket, Config history, centralized flow logs, immutable-ish retention. |
| 3 | **security-tooling** | Security OU | security sub | Delegated admin for Security Hub, GuardDuty, Inspector, (Security Lake if OQ-A5 says so), security KMS keys. |
| 4 | **network** | Infrastructure OU | connectivity sub | TGWs (both regions), inspection VPCs + Network Firewall, shared VPC interface endpoints, Route 53 PHZs/Resolver, egress NAT. |
| 5 | **identity** (optional, OQ-A4) | Infrastructure OU | identity sub | AWS Managed Microsoft AD + its VPC. Only exists if the directory tier is kept. |
| 6 | **workload-corp-a** | Workloads/Corp OU | corp-a1 + corp-a2 | Corp workload, primary region + DR region resources in ONE account, two regions (the AWS-idiomatic cut; see OQ-A3 alternative of splitting DR into its own account). |
| 7 | **workload-online-p** | Workloads/Online OU | online-p1 | Internet-facing: ALB + WAF, S3 + CloudFront. |
| 8 | **sandbox** | Sandbox OU | sandbox sub | Loose-policy experimentation, hard budget. |

OU tree: `Root -> {Security, Infrastructure, Workloads {Corp, Online}, Sandbox, Suspended}`. The
`Suspended` OU is the `Decommissioned` MG analog (closed accounts get moved there with a deny-all SCP).

**Account-creation friction to plan for (the AWS analog of our purge-protection lesson):**

- Every account needs a **unique email address**. Strategy: plus-addressing aliases on a single controlled
  mailbox (e.g. `<user>+aws-network@...`); confirm the mail provider preserves plus-addresses. This is
  OQ-A3.
- **Closure is slow and rate-limited:** a closed account enters a ~90-day suspended state before deletion,
  and Organizations limits how many member accounts you can close per rolling period (quota exists; exact
  percentage UNVERIFIED, check at pre-clearance). Practical consequence: unlike Azure subs, accounts are
  effectively append-only during the POC. Create the small set once and reuse; teardown destroys resources
  IN accounts, not the accounts.
- New-account **service quotas start low** (vCPU, VPCs, EIPs) and some regions are opt-in; both go in every
  pre-clearance (section 6.G).

---

## 4. The 13 sections re-cut for AWS

Same numbering discipline as PROMPT.md, same dependency-driven build order (order column). One section per
session, one root per pre-clearance, unchanged.

| Build order | Section | Title (AWS) | Azure lineage | Contents sketch |
|---|---|---|---|---|
| 1 | 1 | Repository structure | S1 | `AWS-Architecture` scaffold: composition roots under `platform/` (org, network, security, identity, management) + `landing-zones/` + `bootstrap/`; NO local `modules/` layer (ADR-038 carries; a bespoke local module only for a proven gap, finops-class). |
| 2 | 10 | Pipeline and tooling (bootstrap) | S10 | S3 state backend + `use_lockfile`, GitHub OIDC provider + per-account deploy roles, `plan-on-pr.yml` / `deploy.yml` / `teardown.yml` / drift + policy-compliance schedules, preflight, validate gate, hooks. Section 5 below is its spec. |
| 3 | 2 | Organization, OUs, SCP/RCP baseline | S2 (MGs + policy) | Org resource, OU tree, account resources (or import of pre-created accounts), delegated admins, SCP baseline (region-deny with global-service exemptions, root-user deny, guardrails), tag policies. |
| 4 | 7 | FinOps: tagging, budgets, cost exports | S7 | Tag policy + required-tags Config rule, AWS Budgets at payer + per-account, Data Exports (CUR 2.0/FOCUS) to S3, Cost Anomaly Detection, sandbox hard-stop budget action. Early so everything after inherits governance, same as Azure. |
| 5 | 8 | Platform network core | S8 (connectivity parts) | Network account: TGW per region, inspection VPC + Network Firewall (single-AZ endpoints, gated), egress NAT, TGW route tables (spoke-to-inspection), org CloudTrail/Config/central log buckets in log-archive (the S8 management-sub analog folds in here and into order 11). |
| 6 | 4 | PrivateLink endpoints + private DNS | S4 | Centralized interface endpoints in network account, PHZ per service endpoint, PHZ association to spoke VPCs, Resolver rules (only if hybrid DNS needed), endpoint policies. |
| 7 | 3 | Multi-region DR topology | S3 | Second-region TGW + inspection VPC, TGW peering + static routes, cross-region AWS Backup copy, (DRS designed-not-built), RTO/RPO table. |
| 8 | 9 | Workload landing zones | S9 | Spoke VPCs in workload accounts attached to TGW, corp private-only workload behind endpoints, online ALB + WAF + S3/CloudFront. Workload tiers behind default-off flags (LESSON 42 carries: every spoke shippable network-only). |
| 9 | 5 | Identity posture | S5 | Identity Center (permission sets, MFA posture, session durations, groups), the CA-gap documentation, optional Managed AD behind `enable_managed_ad = false` (OQ-A4), CI role trust-policy hygiene. |
| 10 | 6 | Security services | S6 | Delegated-admin enablement (GuardDuty, Security Hub, Inspector, Config aggregator), org-wide auto-enable, finding aggregation region, EventBridge automation rules, conformance packs (CIS/NIST analog of the Azure compliance pins). Tenant-permission-gated analog: anything needing management-account-only APIs gets a default-false flag (LESSON 49 class). |
| 11 | 13 | Operations and monitoring (designed platform capability) | S13 as repositioned by ADR-036/037 | The AMBA-analog: CloudWatch alarm baseline + AWS Health/EventBridge routing + SNS topics (action-group analog) + dashboards, designed now, MVP-bounded, built when the estate persists. The synthetic load/red-team layer stays deferred-by-design from day one (OQ-A7). |
| 12 | 11 | Documentation | S11 | README, ARCHITECTURE, RUNBOOK, SECURITY, COST, per-root terraform-docs. Same deliverable list. |
| 13 | 12 | Acceptance validation | S12 | Honest PASS/FAIL/UNVERIFIED/DEFERRED per criterion (LESSON 60), post-deploy QA per root, teardown drill. |

Sections 13.1-13.7 of the Azure PROMPT (synthetic workload) do NOT get an AWS build phase; their successor
is the O&M design in order 11, per the ADR-036/037 posture. That is a recommendation, surfaced as OQ-A7.

---

## 5. Module + pipeline strategy

### 5.1 Modules: terraform-aws-modules, consumed directly (ADR-038 carries)

- **Source:** the `terraform-aws-modules` collection is the community standard and is healthy as of
  2026-07-11 (verified: actively maintained, vpc at 5.x, vpc/iam are the most-downloaded registry modules).
  Consume them **directly in composition roots**, pinned to exact versions, exactly as AVM was consumed
  (ADR-038). No local wrapper layer; a bespoke local module only when a proven gap appears (the
  `modules/finops` precedent).
- **Verified to exist:** `terraform-aws-modules/vpc/aws`, `terraform-aws-modules/iam/aws`. Widely used
  siblings expected but **UNVERIFIED by this draft** (verify name + exact version on the registry before any
  spec references them, anti-hallucination rule): security-group, alb, s3-bucket, cloudfront, kms, rds,
  and a transit-gateway module. Where no module exists (likely: Organizations/OUs/SCPs, Network Firewall,
  Identity Center, Security Hub org config), use native `aws_*` resources with the same
  `# DEVIATION:`-style honesty.
- **Same anti-hallucination checklist** as CLAUDE.md: confirm module exists, pin exact version, reconcile
  every call against the PINNED version's inputs/outputs (LESSON 20), commit multi-platform
  `.terraform.lock.hcl` per root, always-on credential-free CI validate gate (LESSON 21).
- **Provider pinning:** `aws` provider `~>` minor-pinned; every multi-account root declares **explicit
  provider aliases with `assume_role` per target account**. This is the AWS face of LESSON 23 (the azapi
  default-subscription trap): never let a resource land in whatever account the default credentials point
  at. One alias per account, wired explicitly into every module call.

### 5.2 State backend: S3 with native locking

- **Recommendation (verified 2026-07-11):** S3 backend with **`use_lockfile = true`**, Terraform pinned
  **>= 1.11** (native S3 locking is GA from 1.11 via conditional writes; the DynamoDB `dynamodb_table`
  arguments are deprecated and slated for removal). No DynamoDB table. Pin the exact Terraform version in
  `.terraform-version` and CI (LESSON 7 carries).
- **Bucket design:** dedicated state bucket, versioning ON (the recovery mechanism, LESSON 3's analog:
  never bolt immutability/Object Lock onto a state bucket; the lockfile write pattern needs plain
  conditional PUTs), SSE-KMS with a CMK, Public Access Block all-on, TLS-only bucket policy, deterministic
  name derived from the account ID (LESSON 18: `substr(sha1(account_id),0,8)` class suffix so re-bootstrap
  is reproducible).
- **Placement:** in the management account or a dedicated bootstrap slice of it (OQ-A8 flags the
  alternative of a separate shared-services account). Keep it OUT of workload accounts.

**Re-deriving the LESSONS 30-31/51 class (state-access protection) for S3 - this is a different animal:**

| Azure reality (what bit us) | S3 reality | Design consequence |
|---|---|---|
| State SA default-Deny firewall; hosted runners have unstable SNAT egress IPs; single-IP JIT allow-listing was racy and non-monotonic (LESSON 30); ADR-025 flipped default_action JIT | S3 has **no account-level network firewall to flip**; access control is IAM-first. IP conditions (`aws:SourceIp`) in a bucket policy would recreate the exact LESSON 30 race with hosted runners | **Do NOT build an IP allow-list at all.** Protect state with: least-priv IAM (only the CI deploy roles and break-glass principal can touch the state prefix), `aws:PrincipalOrgID`/explicit-principal bucket policy, KMS CMK whose key policy grants only those principals, TLS-only, versioning. Network-layer privacy (VPC endpoint + `aws:SourceVpce` condition + self-hosted runner in a VPC) is the ADR-025 Option-B analog: correct for production, deferred for the POC. No JIT flip step exists in the workflows, which also deletes the LESSON 31 serialization/restore-Deny problem class. |
| Blob lease locks orphaned by dead runners / rotating IPs; empty-ID leases needed `az storage blob lease break` (LESSON 51) | The S3 lockfile is a **`.tflock` object created with a conditional write; there is no lease expiry**. A crashed runner leaves the object behind and every subsequent run fails to acquire | Same operational answer, new mechanics: a CI-native **force-unlock action** (`terraform force-unlock` with explicit lock ID) plus the documented fallback of deleting the `.tflock` object after verifying no run is live. Stale-lock check stays in every teardown pre-clearance. Locks are simpler (no lease semantics, no firewall window) but still orphanable. |
| KV purge protection constrained same-name redeploy for 90 days (LESSON 56) | **KMS CMK deletion has a mandatory 7-30 day pending window**, and a bad key policy can lock everyone out of the key (and thus the state bucket) unrecoverably; S3 buckets must be emptied (all versions) before delete; bucket names are globally unique and briefly unreclaimable | Teardown runbook designs these in from day one: schedule key deletion LAST and only after verified-clean destroy; never write a key policy without the break-glass root/admin statement; empty versioned buckets via lifecycle or explicit version purge; treat bucket names as reusable-not-immediately. |

### 5.3 CI: GitHub OIDC into IAM roles

The exact analog of the Azure fed-cred model, with the trust policy playing the federated-credential role:

- **One GitHub OIDC identity provider** per account that CI touches (or provider in each account; small
  fixed cost of setup, no secrets ever).
- **Per-account deploy roles** (`role-ci-deploy-<account>`) with trust-policy `sub` conditions pinned per
  repo AND per GitHub Environment: `repo:<org>/AWS-Architecture:environment:production` for applies,
  `...:environment:production-destroy` for teardown, `...:pull_request` for plan-only. This is
  fed-cred-per-Environment (ADR-019 model) verbatim.
- **Bootstrap cycle warning (LESSON 33 carries with a new face):** the trust policy that admits
  `environment:production` only exists after bootstrap applies it, and bootstrap itself needs credentials.
  Break the cycle the same way: an initial human-credentialed targeted bootstrap apply of the OIDC provider
  + roles, then CI takes over; after any targeted apply, diff state vs config and schedule the full
  reconcile (LESSON 53).
- **Role permissions:** the ADR-021 discipline re-derived: start enumerable, not Administrator-everywhere.
  Realistic POC floor: `AdministratorAccess` scoped per member account for the build phase with a written
  scope-down ADR planned (the honest ADR-006 -> ADR-021 arc, compressed), because AWS has no
  Contributor-vs-UAA split; the analog of the "IaC writes IAM" problem is that Terraform creates roles and
  policies, which requires `iam:*` anyway. Document the residual risk the same way ADR-021 did.
- **Workflows:** same trio + schedules as Azure (`plan-on-pr.yml`, `deploy.yml` dispatch-gated with typed
  confirmation + Environment, `teardown.yml` double-gated, nightly drift plan, weekly policy compliance),
  same preflight (tool versions, required `vars.*` non-empty - LESSON 15, role ARNs are Variables not
  Secrets), same validate-only credential-free PR gate, same SHA-confirmation before apply (LESSON 33),
  same plan-scan gate before every apply (LESSON 26).
- **Session duration:** set the deploy roles' max session to cover the longest root apply with margin
  (configurable up to 12h). This is the LESSON 46 analog: `aws-actions/configure-aws-credentials` default
  1-hour sessions WILL expire mid-apply on long roots. Keep applies short, lengthen sessions deliberately,
  and keep long-running creates (Managed AD ~ 30-45 min) in their own root away from everything else.

---

## 6. Lessons carry-over analysis (LESSONS.md, all 62)

The section that matters most. Verdicts: **VERBATIM** (apply unchanged), **TRANSLATED** (same class, new
face, re-derived here), **AZURE-ONLY** (retire).

### Carries VERBATIM (process and Terraform discipline)

| Lessons | Verdict |
|---|---|
| **A 5, 6, 7** (`for_each` static keys, output shapes vs the pinned module, required_version floor vs CI pin) | VERBATIM. Cloud-agnostic Terraform truths. |
| **A 25, 27, 28, 29** (flag-retrofit reference sweeps; API-side value/length/date constraints; dead-variable cost landmines; know what modules/services auto-create) | VERBATIM classes. AWS faces: S3 bucket-name global uniqueness + 63-char limit, IAM name limits, ALB name limits; terraform-aws-modules/vpc auto-creating NACLs/routes you must not duplicate. |
| **D 15, 17, 18, 19, 32, 33** (vars vs secrets; dispatch-gated deploys; deterministic backend naming; teardown ordering; write-only secrets set from live queries; bootstrap cycles + SHA confirmation) | VERBATIM (33's cycle re-derived in 5.3). |
| **E 20, 21, 22** (reconcile calls to the PINNED version; committed multi-platform locks + always-on CI validate; hallucinated resource names die at validate) | VERBATIM. The registry changes, the rule does not. |
| **J 58-62** (pre-clearance gate before ANY first apply or retry; one consolidated fix-spec per failure set; apply-success is not green, QA-verified is green; honest iteration budgeting + per-action logging; hooks not habits) | **VERBATIM AND NON-NEGOTIABLE.** The operating loop is the product of the Azure campaign and transfers wholesale. The pre-clearance template gains AWS-specific rows (below) but the gate itself is unchanged. |
| **40-41 meta-rule** (your platform knowledge is stale by default; lifecycle-audit every resource type/SKU/plan before specifying) | VERBATIM. AWS retires and repackages too, proven this week by research: **CodeCommit, Cloud9, CloudSearch, S3 Select, SimpleDB, Forecast, Data Pipeline, OpsWorks, WorkDocs, FinSpace are closed to new customers** (a validate-green Terraform config for any of them fails only at apply, the exact NSG-flow-logs failure mode); **Security Hub was repackaged in 2025** (CSPM rename + new unified service + consolidated pricing); **DynamoDB state locking is deprecated in Terraform itself**. Current audit sources for the AWS pre-clearance: the AWS News/What's-New feed, service FAQ "new customer" notices, and the community `aws_breaking_changes` list. |

### TRANSLATED (same failure class, AWS face) - the re-derivations

**F. Policy runtime -> SCP/RCP/Config pitfalls**

| Azure lesson | AWS face |
|---|---|
| 34 (your own policy stack rewrites your deploys; placeholder-parameter Modify trap) | SCPs cannot rewrite requests (no Modify), so this exact trap dies. Its cousins: a **region-deny SCP silently breaking global services** (IAM, CloudFront, Route 53, Organizations, WAF-for-CloudFront all live in us-east-1/global and need explicit exemption in the region-deny template), and **the management account is exempt from ALL SCPs**, so a control "verified working" from the management account proves nothing about member accounts. Test guardrails from a member account, always. |
| 35 (Deny vs mandatory service-created resources; exemption + propagation + depends_on as ONE unit) | The AWS twin: deny-flavored SCPs blocking **service-linked-role creation** (`iam:CreateServiceLinkedRole`) that services perform implicitly at first use (GuardDuty, Config, TGW, NFW all create SLRs), and endpoint/bucket policies blocking service principals. Same design rule: the exemption (SCP condition/carve-out) ships in the SAME unit as the resource that needs it, with explicit ordering. SCP propagation is fast (minutes) but not instant; keep a bounded wait before dependent creates. |
| 36, 37 (pinned policy content skews; GUID built-ins are PUT-time bombs; DINE needs wiring) | Conformance-pack and managed-Config-rule identifiers churn; verify every managed rule identifier against current docs before spec (same GUID-class discipline). Config **auto-remediation** is the DINE analog and has the identical wiring lesson: the remediation SSM document's IAM role must be explicitly created and permissioned or remediation silently never heals. Config rule evaluation **lags** (minutes to hours): a detective control is not a gate, and post-apply QA must not read "no findings yet" as "compliant". |
| 38 (tag Modify churn) | Smaller: no mutating tag engine, so no out-of-band tag drift war. The cost: weaker enforcement (1.1 row 17). `default_tags` on every provider alias is the Terraform-side answer and can itself cause perpetual diffs if mixed with resource-level tags; pick one layering and document it. |
| 39 (name/display limits, ASCII-only) | VERBATIM class: SCP 10,240-char cap, policy name limits, ASCII discipline everywhere (and the em-dash hook already enforces the repo side). |

**G. Offer caps and lifecycle -> quotas, new-account limits, region opt-ins**

- LESSON 42's offer-cap axis (distinct from quota) maps to: **new-account default quotas** (on-demand vCPU,
  VPCs/region, EIPs, TGW attachments), **opt-in regions** disabled by default, **account-level service
  enablement states**, and **new-customer service closures** (list above). All become pre-clearance rows:
  probe `service-quotas` per account per region for every service a root creates, before first apply.
- LESSON 42's design consequence carries VERBATIM: **every workload tier ships behind a default-off flag**
  so a spoke can land network-only when a quota/closure blocks a tier.
- LESSON 43 (regional co-location) maps to: single-region services and same-region couplings (Identity
  Center lives in ONE region per org; Security Hub cross-region aggregation needs a designated aggregation
  region; CloudFront/WAF-for-CloudFront/ACM-for-CloudFront are us-east-1-bound). Map region couplings per
  root in pre-clearance.

**H. Identity -> Managed AD, Identity Center**

- LESSON 44 (AADDS tenant-prereq stack) -> Managed AD prereqs: a VPC with 2 subnets in 2 AZs, DNS settings,
  ~ 30-45 min create, immutable name after create, sharing/trust constraints (edition dependency
  UNVERIFIED). Same rule: clear the FULL manifest in pre-clearance, keep the create in its own root.
- LESSON 45 (never shadow required NSG rules) -> Managed AD security groups are **service-managed**; do not
  fight them, and NACLs must not block the directory's required ports between its subnets.
- LESSON 46 (long creates vs token lifetime) -> role session duration (5.3). Same guardrail: import-block
  recovery for built-but-unstated resources, removed immediately after landing (LESSON 52 VERBATIM).
- LESSON 47 (licensing/store-state, not propagation) -> Identity Center org instance must be enabled in the
  management account first; some security services demand the management account or a delegated admin
  designation before org-wide APIs work. A recurring AccessDenied after one retry is authorization or
  enablement state, never propagation. VERBATIM rule, new error codes.
- LESSON 48 (GUID hallucination class) -> AWS managed policy ARNs, service principal names
  (`*.amazonaws.com`), and managed Config rule identifiers are the same opaque-string risk: copy from
  current docs at authoring time, never from memory.
- LESSON 49 (tenant-permission-gated features behind default-false flags) -> VERBATIM for: anything
  requiring management-account-only APIs, delegated-admin registration, Security Lake, Identity Center
  external-IdP federation.

**I. State ops and teardown**

- 51 (orphaned locks) -> TRANSLATED in 5.2 (lockfile object, no lease semantics, force-unlock runbook).
- 54 (RP unregistration races) -> Organizations-level trusted-access/delegated-admin disablement racing
  resource deletion; same answer: treat org-level enablement as near-permanent, do not manage it in the
  same root as the resources.
- 55 (service-created artifacts block RG deletes) -> service-created S3 objects (access logs, Config
  history) block bucket deletion; SLRs linger after service disable; the `az group delete` brute-force
  fallback has NO clean AWS analog (no resource-group container), so teardown design leans harder on
  correct destroy ordering. ADR-019/020's designed-teardown posture carries with more weight, not less.
- 56 (purge-protection windows) -> KMS 7-30 day deletion window + account 90-day closure (5.2, section 3).
- 57 (revocation strictly after verified destroy; grants outlive the estate) -> VERBATIM: the human
  bootstrap credentials and any management-account roles outlive member-account teardown; the runbook
  carries an explicit post-destroy revocation list with verification queries.

### AZURE-ONLY (retire)

- 1, 2, 4, 24 (storage_use_azuread, /32 ip_rules, CMK flip-flop, keyless-SA service writers): azurerm
  provider quirks. Watch for AWS-provider cousins but do not port them.
- 23's literal azapi form (the CLASS carries as provider-alias-per-account, 5.1).
- 30, 31's literal JIT-firewall mechanics (the CLASS is redesigned away, 5.2).
- 44-45's AADDS specifics beyond the translated rows; 47's Entra-licensing specifics; 50 (Sentinel
  onboarding/KQL/enums) unless Security Lake + Athena is built, where "exact enum strings and cross-account
  query references" will rhyme.
- 13 (MFA CA blocking local ARM), 16 (firewalled state SA vs runners), 34's DDoS-placeholder specifics.

---

## 7. What copies into the new repo on day one

| Artifact | Action |
|---|---|
| `CLAUDE.md` | Copy, adapt: AVM references -> terraform-aws-modules + native `aws_*`; azurerm/azuread pins -> `aws` provider + Terraform >= 1.11; same hard rules, session workflow, anti-hallucination checklist, section-per-session discipline. |
| `.claude/agents/` (architect, cloud-engineer, devsecops-engineer, code-reviewer, qa-engineer) | Copy all 5. Add an "AWS lessons addendum" block to each, appended as AWS-specific lessons are learned (subagents do not inherit memory, LESSON 62). |
| `landing-zone-kit/` (`process.md`, `LESSONS.md`, `templates.md`, OQ template) | Copy. `LESSONS.md` is the SEED: it carries as-is with this draft's section 6 verdicts noted at top; new AWS lessons append under new letters. |
| Hooks (em-dash pre-commit, review-approve, preflight) | Copy verbatim; preflight retargets tool checks (aws CLI instead of az). |
| Workflow patterns (`plan-on-pr.yml`, `deploy.yml`, `teardown.yml`, `_tf-root.yml` reusable, drift + compliance schedules) | Copy structure; swap `azure/login` for `aws-actions/configure-aws-credentials`, drop the JIT state-firewall steps entirely (5.2), keep preflight/validate/lock-file/SHA-confirmation/plan-scan steps. |
| `docs/preclearance/` structure + `deprecation-audit.md` pattern | Copy the structure empty; every AWS root gets its own pre-clearance doc before first apply, now including the service-quota probe and the AWS lifecycle audit rows. |
| `WORKLOG.md` / `DECISIONS.md` / `OPEN-QUESTIONS.md` discipline | Fresh files, same rules. This draft's OQ-A list seeds OPEN-QUESTIONS.md; the day-one ADRs to write: modules-direct (ADR-038 analog), state backend, CI identity model, Control Tower decision, teardown design. |
| This document | Moves in as the founding `docs/aws-architecture-draft.md`, superseded progressively by ARCHITECTURE.md. |

---

## 8. Cost sketch + gates (list prices, POC scale, same honesty as COST.md)

All figures are list-price estimates for US regions at 730 hrs/mo, no discounts, data-plane near the floor
for a POC. Items marked `†` were not price-verified by this draft and need confirmation before COST.md is
written. Verified anchors (2026-07-11): Network Firewall $0.395/endpoint-hr + $0.065/GB (Feb 2026 price
reductions; secondary endpoints $0.158/hr; TLS-inspection data surcharge removed); TGW VPC attachment
$0.05/hr (~ $36.50/mo); NAT Gateway $0.045/hr + $0.045/GB; Managed AD Standard $0.06/DC-hr x 2 DCs
(~ $88/mo).

| # | Component | Basis | Est. monthly (USD) | Gate |
|---|---|---|---|---|
| 1 | **Network Firewall endpoints x2** (1 per region, single-AZ) | $0.395/hr x 730 x 2 | **~ $577** | Single-AZ from day one (the DDoS-off analog); dual-AZ is a documented production flag. Data processing at POC: + $5-20. |
| 2 | **TGW attachments** (~ 8: inspection + endpoints + 2-3 spokes per region) + cross-region peering | $0.05/hr each + data | ~ $300 - $380 | Attach only VPCs that exist; spokes are flag-gated anyway. |
| 3 | NAT Gateway x2 (1 per region) | $0.045/hr + $0.045/GB | ~ $66 + data | Single NAT per region, not per AZ, at POC scale. |
| 4 | VPC interface endpoints (~ 10 shared, single-AZ) | ~ $7.30/mo each `†` | ~ $73 `†` | Centralized in network account; add per service actually used. |
| 5 | Route 53 Resolver endpoints (2 x 2 ENIs) | ~ $0.125/ENI-hr `†` | ~ $365 `†` | **Gated OFF by default**; only exists if Managed AD / hybrid DNS is kept (OQ-A4). |
| 6 | AWS Managed Microsoft AD (Standard) | $0.06/DC-hr x 2 | ~ $88 | **Gated OFF by default** (OQ-A4). |
| 7 | Security services (GuardDuty, Security Hub, Inspector, Config) | per-resource/per-event; 30-day trials; new consolidated Security Hub pricing | ~ $40 - $150 `†` | Config recorder scope (regions x accounts) is the quiet cost driver; record only deployed regions. |
| 8 | CloudTrail (org trail) + CloudWatch + central S3 logs | first copy of management events free; storage low | ~ $15 - $50 | Log retention lifecycle policies from day one. |
| 9 | ALB + AWS WAF (online spoke) | ALB ~ $16 + LCU; WAF ACL + rules + requests | ~ $30 - $50 | Flag-gated with the online tier. |
| 10 | S3 + CloudFront (static site) | POC traffic | ~ $1 - $5 | - |
| 11 | AWS Backup | per-GB backup storage, POC volume | ~ $5 - $20 | - |
| 12 | KMS CMKs (~ 6-10) | $1/key/mo + requests | ~ $10 | - |
| 13 | Route 53 PHZs (~ 10-15) | $0.50/zone (first 25) | ~ $7 | Far fewer zones than Azure's 89 privatelink zones; create per consumed endpoint service only. |
| 14 | Budgets, Data Exports (CUR 2.0), Cost Anomaly Detection | near-free | ~ $0 - $5 | - |
| 15 | Shield Advanced | ~ $3,000/mo + 1-yr commit `†` | **$0 (OFF)** | The DDoS-Standard analog: documented lever, never on for the POC. |
| 16 | Bastion | n/a - SSM Session Manager | **$0** | The AWS win; no bastion line item exists. |
| | **Total (as-gated: no Managed AD, no resolver endpoints, single-AZ NFW)** | | **~ $1,000 - $1,400 / mo** | |
| | **Total (directory tier ON)** | | **~ $1,400 - $1,700 / mo** | |

Flag-gated for cost from day one: dual-AZ firewall endpoints, Managed AD + resolver endpoints, Shield
Advanced, every workload tier, Security Lake. Budget alert thresholds mirror the Azure model
(50/75/90/100%) with a sandbox hard-stop budget action.

---

## 9. Open questions for the user (OQ-A1 .. OQ-A8)

| # | Question | Options | Recommendation |
|---|---|---|---|
| **OQ-A1** | **Control Tower vs DIY Organizations** | (a) Control Tower + AFT: managed guardrails and Account Factory, Terraform friction, drift, no AFT deprovision path. (b) DIY Organizations/SCPs/accounts fully in Terraform: full IaC fidelity, more assembly. | **(b) DIY** - matches the project ethos (everything in Terraform, modules-direct, CI-gated), demos more skill, cleaner POC lifecycle. Section 2 has the full trade-off table. |
| **OQ-A2** | **Region pair** | (a) us-east-1 + us-west-2: the canonical pair, everything available, us-east-1 hosts the global/CloudFront/ACM plane anyway. (b) us-east-2 + us-west-2: avoids the us-east-1 blast-radius reputation, but CloudFront/WAF-global work still touches us-east-1. | **(a) us-east-1 primary + us-west-2 DR** - least service-availability friction for a POC; the us-east-1 concentration risk is a documented trade-off, not a blocker at POC stakes. |
| **OQ-A3** | **Account count + email alias strategy** | (a) 8 accounts (section 3), plus-addressing aliases on one mailbox. (b) 7 accounts (fold identity away per OQ-A4). (c) 9 accounts (split corp DR into its own account for a stricter corp-a2 mirror). Alias alternatives: distinct mailboxes, or a domain with catch-all. | **(a)/(b): 7-8 accounts with plus-addressing** - one mailbox, deterministic alias scheme, documented in bootstrap. Verify the mail provider preserves plus-addresses before account creation day. Accounts are effectively append-only (90-day closure), so this list is decided once. |
| **OQ-A4** | **Keep the directory tier (AWS Managed Microsoft AD) or drop it for the POC?** | (a) Keep, gated default-off flag (+ ~ $88/mo + ~ $365/mo resolver endpoints when on). (b) Drop entirely: Identity Center covers human access; the Azure build only had Entra DS to demonstrate the identity-sub pattern. | **(b) with a written design stub** - the POC's identity story on AWS is Identity Center; Managed AD adds cost, a long-create root, and prereq surface for a pattern the portfolio already proved on Azure. Keep the account slot + design doc so it is a flag-flip if reinstated. |
| **OQ-A5** | **SIEM depth** | (a) Security Hub as the finding plane + EventBridge automations (no SIEM claim, near-zero extra cost). (b) Security Lake (OCSF) + Athena/OpenSearch query layer (real SIEM-ish story, real build + storage/query cost). | **(a) for the POC, (b) designed-not-built** - mirrors the ADR-036/037 pattern: honest capability now, documented target architecture for the persistent estate. |
| **OQ-A6** | **Budget ceiling** | (a) ~ $1,200/mo (as-gated envelope + headroom). (b) ~ $1,700/mo (room for the directory tier experiment). (c) User-set other. | **(a) $1,200/mo ceiling** with alerts at 50/75/90/100 and the sandbox hard-stop; raise deliberately if OQ-A4 flips to keep. |
| **OQ-A7** | **Synthetic layer deferred-by-design from day one?** | (a) Yes: Section 13 is the O&M platform capability (ADR-036/037 posture), designed in order 11, built only if the estate persists; no k6/red-team build phase. (b) No: port the synthetic workload sections. | **(a) Yes** - the Azure arc already proved the synthetic layer is the wrong device and the O&M design is the right successor; start the AWS build with that conclusion instead of re-learning it. |
| **OQ-A8** | **Inspection posture + state placement details** | Firewall scope: (a) egress + east-west through inspection VPCs in both regions from the start, single-AZ; (b) primary-region-only firewall until DR section lands. State bucket: (a) management account; (b) a dedicated shared-services/bootstrap account. | **Firewall (b) then (a)**: primary-only until Section 3 (DR) builds the second region, single-AZ endpoints throughout the POC. **State (a)**: management account, IAM-perimetered per 5.2; a dedicated account is production polish the POC does not need. |

---

## 10. Verification log (what this draft checked, 2026-07-11)

Verified by web search against current sources, per the stale-by-default rule:

- **Control Tower / AFT current state:** AFT requires an existing CT landing zone, vends via git push,
  customizes at vending time, no native deprovision; CT changes flow through its own console/APIs; May 2026
  SCP quota doubling (10 per node, 10,240 chars).
- **S3 native state locking:** `use_lockfile` GA since Terraform 1.11 (experimental in 1.10), conditional
  writes create a `.tflock` object; DynamoDB locking arguments deprecated, removal planned; community best
  practice for new setups is S3-native.
- **AWS Network Firewall pricing:** $0.395/endpoint-hr, $0.065/GB, secondary endpoints $0.158/hr; Feb 2026
  price reductions, TLS advanced-inspection data surcharge removed, NAT-GW service-chaining discounts.
- **terraform-aws-modules health:** actively maintained (vpc 5.x line current; vpc/iam lead registry
  downloads at 126M+/235M+).
- **AWS lifecycle traps (the 40-41 proof for AWS):** CodeCommit, Cloud9, CloudSearch, S3 Select, SimpleDB,
  Forecast, Data Pipeline, OpsWorks, WorkDocs, FinSpace closed to new customers (2024-2025 wave).
- **Security Hub repackaging:** old service renamed Security Hub CSPM; new unified Security Hub GA with
  consolidated per-resource pricing (bundles Inspector + CSPM), 30-day trial.
- **Managed AD pricing:** $0.06/DC-hr Standard us-east-1, 2 DCs minimum, ~ $87.60/mo.
- **TGW / NAT pricing:** $0.05/attachment-hr (~ $36.50/mo); NAT $0.045/hr + $0.045/GB.

**UNVERIFIED in this draft (must be verified before any spec/COST.md references them):** Route 53 Resolver
endpoint ENI pricing; VPC interface endpoint hourly price; Shield Advanced price and commit terms; the
account-closure rate quota's exact value; Managed AD directory-sharing edition constraints; the exact
existence/names/versions of terraform-aws-modules beyond vpc and iam (registry check per module at
authoring time); RCP current service coverage; TEAM solution maintenance status; new unified Security Hub
per-resource price points; Config/GuardDuty/Inspector line-item prices at POC scale.

---

*End of draft. Next step after user review: resolve OQ-A1 through OQ-A8, then this document seeds the
`AWS-Architecture` repo and its Section 1 session.*
