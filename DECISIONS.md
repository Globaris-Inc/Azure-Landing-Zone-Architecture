# DECISIONS.md — Architectural Decision Records

> Append-only log of architectural decisions made during the build.
> Each ADR follows the template below. Once written, an ADR is never edited — if a decision is reversed, write a new ADR that supersedes it.

---

## Template

```
### ADR-XXX: [Short Title]

- **Date:** YYYY-MM-DD
- **Section:** [N from PROMPT.md]
- **Status:** Proposed / Accepted / Superseded by ADR-YYY
- **Decision makers:** [user / claude]

**Context:**
[What's the situation that requires a decision?]

**Decision:**
[What was decided, in one or two sentences.]

**Alternatives considered:**
- [Alt A] — rejected because [reason]
- [Alt B] — rejected because [reason]

**Consequences:**
- Positive: [...]
- Negative / trade-offs: [...]
- Follow-ups required: [...]
```

---

## ADRs

<!-- Newest at the top. -->

### ADR-034: Gate the cross-workspace firewall_threat_intel_hit analytics rule off, remove the deprecated Dns Defender plan, and hold the (now also deprecated) KeyVaults + Arm plans as latent debt

- **Date:** 2026-07-10
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Status:** Accepted. Resolves the ADR-033 firewall_threat_intel_hit contingency (the rule failed a second
  time on run 29134695521 with the same cross-workspace error, exactly as ADR-033 predicted) and records the
  Defender-plan deprecation audit that the run-2 failures forced.
- **Decision makers:** user, claude (architect)

**Context:**
The `platform/security` retry (run 29134695521) applied the ADR-033 fixes cleanly: the connector 401s are
gone (dc-aad and dc-ti gated off), and the "workspace not onboarded" automation-rule 400 cleared because
onboarding propagated from the partial apply. Four issues remained. Two require design decisions (this ADR);
two are execution mechanics recorded in `docs/preclearance/platform-security.md` (the SqlServerVirtualMachines
state import and the pricing-write parallelism).

Verified facts this session:
- **firewall_threat_intel_hit (second failure, same error):** 400 "Could not locate all the workspaces in
  your query." This is the only one of the 11 analytics rules that uses a cross-workspace reference. Its KQL
  (via `local.platform_law_workspace_function`) is
  `workspace('law-platform-<org>-<env>').AzureDiagnostics | ...` - a **name-only** reference to the platform
  LAW, which lives in the **management** subscription while the Sentinel rule is created against the security
  workspace in the **security** subscription. Name-only `workspace('name')` resolution does not resolve
  cross-subscription at rule-create validation time, so the create fails deterministically. The design reason
  the rule is cross-workspace is intentional (sentinel.tf DEVIATION header): hub Azure Firewall diagnostics
  land in the platform LAW, and the rule reads them from there to avoid duplicate ingestion cost. The other 10
  scheduled rules reference tables in their own (security) workspace with no `workspace()` prefix and create
  fine even where the source table has no data yet.
- **Dns Defender plan deprecated:** `azurerm_security_center_subscription_pricing.extended["Dns"]` failed 400
  "The 'Dns' plan is deprecated and can no longer be enabled." Dns is live-Free on the security sub (it never
  landed), so removing it from config is a no-op against live state.
- **Defender-plan deprecation audit (done now, this session):** VERIFIED 2026-07-10 against the Defender for
  Cloud release notes ("Plan enablement API now blocks onboarding to five deprecated Defender plans,"
  July 5, 2026). The five plans blocked for **new** enablement are: Azure Kubernetes Service
  (`KubernetesService`), Azure Container Registry (`ContainerRegistry`), Key Vault (`KeyVaults`), DNS (`Dns`),
  and Azure Resource Manager (`Arm`). Mapping to this root:
  - `Dns` (in `defender_extended_plans`, defender.tf) - deprecated AND live-Free -> actively failing -> remove.
  - `KeyVaults` and `Arm` (in `defender_basic_plans`, main.tf) - **also deprecated**, but both are live-Standard
    and already reconciled in Terraform state (they were created in the run-1 partial apply before the block
    matters to us; run 2 reported no error on them). The block applies to **new enablement only**; existing
    enabled plans keep working, so they do **not** block the next apply. They are latent debt: any future
    re-PUT (config change, or a state drift that makes Terraform try to re-create them like
    SqlServerVirtualMachines drifted) would hit the same deprecation block.
  - `KubernetesService` and `ContainerRegistry` - deprecated but **not used** here (we use `Containers`,
    which supersedes them). No action.
  - `AppServices`, `SqlServers`, `SqlServerVirtualMachines`, `Containers`, `OpenSourceRelationalDatabases`,
    `CloudPosture`, `VirtualMachines`, `StorageAccounts` - current/supported. No action.
  This is a process gap: the pre-clearance deprecation audit (step 3d) was run for the policy/module lane but
  the Defender-plan list was not re-audited against the release notes before run 1.

**Decision:**
1. **Gate firewall_threat_intel_hit off** behind a new `var.enable_firewall_ti_rule` (bool, default `false`)
   in `platform/security`. Rather than gate a whole resource, filter the single map key out of the
   `azurerm_sentinel_alert_rule_scheduled.this` `for_each` when the flag is false. The
   `firewall_threat_intel_hit` entry stays in `local.analytics_rules` (pre-staged), so re-enabling is a flag
   flip **plus** the two follow-ups below. The other 10 scheduled rules and the MDC incident rule are
   unaffected.
2. **Remove `Dns`** from the `defender_extended_plans` set in defender.tf. Dns is live-Free and never entered
   state, so the removal is a no-op against live and state (no destroy).
3. **Hold `KeyVaults` and `Arm` as-is** (do not remove, do not re-PUT). They are live-Standard, in state, and
   do not block the next apply. Removing them from config would issue a DELETE that disables Defender for Key
   Vault / Resource Manager protection - a real security-posture downgrade, out of scope for this retry. Add a
   code comment marking both deprecated so no one re-triggers a PUT, and track the migration decision as an
   open question (OQ-028).

**Alternatives considered:**
- **firewall_threat_intel_hit: fully-qualify the cross-workspace reference** to the platform LAW ARM resource
  ID (the ADR-033 contingency) - rejected for this retry: it requires threading the management-sub platform
  LAW resource ID into a root that is deliberately isolated from the platform workspace (main.tf), AND the
  scheduled rule needs the Sentinel workspace's query identity to hold Log Analytics Reader on the platform
  LAW or it creates but fails at runtime. Two new moving parts (cross-root input + cross-workspace RBAC) on a
  tight retry budget is the riskiest path; parked as the re-enable design in OQ-027.
- **firewall_threat_intel_hit: rewrite to single-workspace** - rejected: the firewall logs are not in the
  security workspace by design (cost), so there is nothing single-workspace to query.
- **firewall_threat_intel_hit: delete the rule** - rejected: loses a pre-staged detection; gating keeps it for
  a persistent environment, consistent with the ADR-031/032/033 pre-staged-behind-a-flag pattern.
- **KeyVaults + Arm: remove from config now** - rejected: issues a DELETE that downgrades security posture and
  is out of scope for the retry; they are not blocking. Deferred to OQ-028.
- **KeyVaults + Arm: add `lifecycle { ignore_changes }` or similar to freeze them** - rejected as unnecessary:
  state matches live (tier Standard), so no PUT is planned; the real risk is drift, which is handled by the
  pre-apply plan-scan guard in the pre-clearance doc (import, never re-create, any drifted deprecated plan).

**Consequences:**
- Positive: the third apply's Sentinel and Defender lanes reduce to resources that create cleanly. The
  recurring cross-workspace 400 is removed deterministically; the deprecated Dns PUT is gone; the newly found
  KeyVaults/Arm deprecation is documented before it can bite. 10 of 11 scheduled rules, the MDC incident rule,
  watchlists, and all supported Defender plans stand.
- Negative / trade-offs: no firewall threat-intel cross-workspace detection until it is re-enabled with a
  fully-qualified reference plus cross-workspace RBAC (OQ-027). A third default-false feature flag now lives in
  `platform/security`. KeyVaults and Arm remain on deprecated plans (latent debt, OQ-028). The Defender-plan
  deprecation audit is now a required pre-clearance step for any root that sets pricing plans.
- Follow-ups required: (1) **OQ-027** - re-enable firewall_threat_intel_hit (fully-qualified platform LAW
  reference + Sentinel cross-workspace RBAC) for a persistent environment. (2) **OQ-028** - migrate KeyVaults
  and Arm off the deprecated plans (remove from IaC vs keep until Microsoft enforces retirement). (3)
  Execution mechanics in `docs/preclearance/platform-security.md` run-2 section: import
  `azurerm_security_center_subscription_pricing.extended["SqlServerVirtualMachines"]` (devsecops) and reduce
  pricing-write parallelism on the security apply (devsecops). (4) Add "re-audit the Defender pricing-plan list
  against the current release notes" to the pre-clearance deprecation-audit step for any root that enables
  Defender plans.

### ADR-033: Gate the tenant-scoped Sentinel data connectors (Entra ID + Threat Intelligence) off - both need a Security Administrator directory role the CI SP lacks

- **Date:** 2026-07-10
- **Section:** 6 (Defender for Cloud + Sentinel)
- **Status:** Accepted. Extends the same tenant-permission gating rationale already applied to
  `enable_aad_diagnostics` and `enable_ueba` (recorded in `envs/poc.tfvars` and
  `docs/preclearance/platform-security.md` prereq 1) to the two tenant-scoped Sentinel data connectors.
- **Decision makers:** user, claude (architect)

**Context:**
The `platform/security` apply (run 29133588369) partially applied. LAW, Key Vault, Event Hub, Defender
pricing plans, and regulatory compliance landed. Among the failures were the two **tenant-scoped** Sentinel
data connectors:
- `azurerm_sentinel_data_connector_azure_active_directory.this` (dc-aad) failed **401 Access denied**.
- `azurerm_sentinel_data_connector_threat_intelligence.this` (dc-ti) failed **401 Access denied**.

Verified facts this session:
- Both failing connectors carry `tenant_id` and enable a **tenant-level** data source (Entra
  Sign-in/Audit logs for dc-aad; the Microsoft Threat Intelligence indicator feed for dc-ti). The
  **subscription-scoped** connector `azurerm_sentinel_data_connector_azure_security_center.this` (dc-mdc,
  carries `subscription_id`) **succeeded** in the same apply. The clean split is: sub-scoped connector works
  under the SP's Contributor; tenant-scoped connectors need an Entra directory role the SP does not hold.
- This is the **same permission class** already gated for `enable_aad_diagnostics`
  (`azurerm_monitor_aad_diagnostic_setting`) and `enable_ueba` (the azapi Sentinel settings writes): all need
  **Security Administrator** (or Global Administrator) in Entra, which the CI OIDC SP does not hold. See
  `docs/preclearance/platform-security.md` prereq 1.
- A **401 is an authorization failure, not a propagation lag.** A rerun does not clear a standing
  directory-role gap, so dc-aad and dc-ti will fail identically on every retry until the role is granted.

**Decision:**
Gate both tenant-scoped Sentinel data connectors behind two new default-`false` feature flags in
`platform/security`:
- `var.enable_aad_connector` (bool, default `false`) gates `azurerm_sentinel_data_connector_azure_active_directory.this`.
- `var.enable_ti_connector` (bool, default `false`) gates `azurerm_sentinel_data_connector_threat_intelligence.this`.

Each connector takes `count = var.<flag> ? 1 : 0`. The two `outputs.tf` entries that reference them
(`aad`, `ti` in `sentinel_data_connector_ids`) convert to the `one(...[*].id)` pattern already used for the
count-gated MDE connector. Two separate flags (not one combined flag) because the connectors represent
different data sources and different downstream re-enable triggers; they may be turned on independently. The
sub-scoped dc-mdc connector stays ungated and is unaffected.

The two Sentinel resources that got **400-class** errors in the same apply -
`azurerm_sentinel_alert_rule_scheduled.this["firewall_threat_intel_hit"]` (400 "Could not locate all the
workspaces in your query") and `azurerm_sentinel_automation_rule.ti_enrichment_tag` (400 "Workspace not
onboarded to Microsoft Sentinel") - are **NOT gated**. Neither reads the ThreatIntelligenceIndicator table
that dc-ti populates: the firewall rule cross-workspace-queries the platform LAW for Azure Firewall
threat-intel block logs, and the automation rule only tags incidents by severity. They have no data
dependency on dc-ti, so gating dc-ti does not force gating them. Their 400s are onboarding-propagation /
cross-workspace-validation timing, not permission or code faults (see Consequences for the retry rationale).

**Alternatives considered:**
- Grant a time-boxed Security Administrator directory role to the CI SP and keep both connectors enabled -
  rejected for this retry: same operator-action deferral already chosen for `enable_aad_diagnostics` and
  `enable_ueba`; enabling only these two connectors would be inconsistent, and the directory-role grant is a
  standing follow-up, not a blocker for landing the rest of the root. The flags make the connectors a
  one-variable flip once the role exists.
- One combined flag for both connectors - rejected: dc-aad (Entra sign-in/audit, needs Entra ID P1/P2) and
  dc-ti (Microsoft TI feed) have different licensing and different re-enable triggers; a shared flag would
  couple two unrelated re-enable decisions.
- Rerun dc-ti as-is (treat the 401 as transient) - rejected: a 401 is authorization, not propagation; a
  rerun cannot clear a missing directory role and would just burn a retry.
- Also gate the firewall_threat_intel_hit alert rule and ti_enrichment_tag automation rule - rejected:
  neither consumes dc-ti data, so they are not blocked by the connector being off; their failures are timing,
  and gating working detections that a retry is expected to clear would remove security value for no reason.

**Consequences:**
- Positive: the retry's Sentinel lane reduces to resources the SP is actually authorized to create. The two
  tenant-scoped connectors are captured as scoped, documented gates consistent with the existing
  `enable_aad_diagnostics` / `enable_ueba` pattern, not blind retries against a permission the SP lacks. The
  MDE connector, the sub-scoped MDC connector, the 10 scheduled analytics rules, watchlists, and the MDC
  high-severity incident rule are unaffected.
- Negative / trade-offs: no Entra ID sign-in/audit ingestion and no Microsoft TI indicator feed into the
  Security workspace until the Security Administrator role is granted and the flags are flipped. Two more
  default-false feature flags now live in `platform/security`. Detections that would benefit from TI
  enrichment (the ti_enrichment_tag automation rule still tags, but no TI indicators are ingested to enrich
  against) run without that feed until re-enable.
- Follow-ups required: (1) When the time-boxed Security Administrator grant is arranged (the same operator
  action that unblocks `enable_aad_diagnostics` and `enable_ueba`), flip `enable_aad_connector`,
  `enable_ti_connector`, `enable_aad_diagnostics`, and `enable_ueba` to `true` in one later pass and re-apply.
  Tracked in `docs/preclearance/platform-security.md` (apply-time findings, Class B). (2) Contingency for the
  firewall_threat_intel_hit rule: if it fails a SECOND time on the retry with the same "Could not locate all
  the workspaces" error, the root cause is name-only cross-workspace resolution
  (`workspace('law-platform-globaris-poc')`), not timing; the durable fix is to switch that KQL reference to
  the fully-qualified platform LAW ARM resource ID (which requires threading the platform LAW resource ID
  into this root as a new input). Do not blind-retry that rule more than once.

### ADR-032: Gate the corp-spoke App Service tier off - `landingzones` subscription dedicated App Service compute quota is 0 (offer cap)

- **Date:** 2026-07-10
- **Section:** 9 (Landing Zone Spokes)
- **Status:** Accepted.
- **Decision makers:** user, claude (architect)

**Context:**
Deploying the corp landing-zone spokes. After the azapi-anchor and zone-balancing fixes cleared the prior
errors, the corp-a1 apply (deploy run 29126639533) failed on `module.app_service_plan` with
`400 Unauthorized / ExtendedCode 70007: "Operation cannot be completed without additional quota. Current
Limit (Total VMs): 0, Amount required: 3."` Verified facts this session:
- This is the **dedicated App Service compute quota** (provider `Microsoft.Web`, the reserved VM instances
  behind a Basic+ App Service Plan), **not** the IaaS Compute vCPU quota. Two portal quota exports for the
  **Compute** provider confirm the `landingzones` subscription has healthy VM/vCPU quota in East US 2 (Total
  Regional vCPUs limit 10, VMs limit 25000, every family limit 10, 0 usage). So this is **not** a used-up
  quota - it is an **offer cap** on dedicated App Service (Basic and above), the same class of restriction as
  the Azure SQL `ProvisioningDisabled` in ADR-031.
- Serverless / PaaS-shared compute is **unaffected**: Consumption / Flex Consumption Functions and Static Web
  Apps do not draw on the dedicated App Service VM quota. online-p1's Static Web App provisions fine; it has
  no App Service Plan.
- The failing resources are the App Service tier only: `module.app_service_plan` (the
  `Microsoft.Web/serverFarms` dedicated plan) and `module.app_service` (the site). The `snet-integration`
  subnet and its `Microsoft.Web/serverFarms` delegation are topology, not compute, and are unaffected.

**Decision:**
Gate the corp App Service tier behind a new `var.enable_app_service` (bool, default `false`) in
`landing-zones/corp-a1` and `landing-zones/corp-a2`. The flag gates `module "app_service"` and
`module "app_service_plan"`; the App Service outputs return `null` via `one(...)` when the tier is off. The
`snet-integration` subnet and its `Microsoft.Web/serverFarms` delegation **stay** (pre-staged topology), so
re-enabling is a single-variable flip. Re-enable by setting `enable_app_service = true` once an unrestricted
subscription is available or a quota/offer exception lifts the cap.

Broader finding: the `landingzones` subscription is **compute-restricted for dedicated / reserved resources.**
This ADR (dedicated App Service) and ADR-031 (Azure SQL) together establish that **both** dedicated App
Service and SQL are offer-capped in this subscription, while **serverless and PaaS-shared** compute works. Any
future workload tier in these spokes should assume dedicated/reserved SKUs are unavailable here.

**Alternatives considered:**
- Request a quota increase on the dedicated App Service offer - rejected: offer-cap increases on sponsored /
  restricted subscription types are commonly slow or denied outright, which does not fit the planned
  end-of-week teardown; the tier would stay down while the request is pending.
- Redesign the workload tier to serverless (Flex Consumption Functions, plus serverless alternatives that fit
  the offer) - rejected: that is a real application redesign, out of scope for a POC being torn down at the end
  of the week. Parked in OQ-026 for a persistent environment.

**Consequences:**
- Positive: the corp spokes stand as **network landing zones** - VNet, hub peering, NSG, UDR-to-firewall,
  Recovery Services Vault, VNet flow logs, and policy compliance/exemptions all provision. The running App
  Service and SQL workloads (POC filler, not the landing-zone story) are the only things gated off. The
  failure is captured as a scoped, documented gate rather than a blind retry against a capability the
  subscription does not have.
- Negative / trade-offs: no App Service plan or site exists in the corp spokes until an unrestricted
  subscription or an offer exception is available and `enable_app_service` is flipped. Combined with ADR-031,
  the corp spoke's "app + database" workload story is fully pre-staged-off; the spokes demonstrate topology and
  governance, not a running workload. A second default-false feature flag now lives in both corp landing-zone
  roots.
- Follow-ups required: **OQ-026** tracks the persistent-environment path (request quota / relocate to an
  unrestricted subscription vs redesign to serverless). Non-blocking and likely moot given the planned
  teardown. See also **ADR-031** (the SQL half of the same offer-cap finding) and **OQ-025** (SQL re-enable
  trigger).

### ADR-031: Gate the corp-spoke SQL tier off - Azure SQL `ProvisioningDisabled` in the `landingzones` subscription region

- **Date:** 2026-07-10
- **Section:** 9 (Landing Zone Spokes)
- **Status:** Accepted.
- **Decision makers:** user, claude (architect)

**Context:**
Deploying the corp landing-zone spokes. The corp-a1 apply (deploy run 29120479723) failed on
`azurerm_mssql_server.this` with `Status: ProvisioningDisabled` and the message "Provisioning is restricted
in this region. Please choose a different region...". Verified facts this session:
- This is a **subscription/region capability restriction, not a code or design fault.** Azure SQL logical
  server provisioning is disabled for the `landingzones` subscription in **eastus2** (corp-a1's region), and
  is expected to be disabled in **centralus** (corp-a2's region) for the same reason. This restriction is
  common on sponsored / Visual Studio subscription types and is imposed by Azure capacity/policy, not by our
  Terraform.
- The failing resources are the SQL tier only: `azurerm_mssql_server.this` (with its Entra admin nested
  block), `azurerm_mssql_database.app`, and `azurerm_private_endpoint.sql` (with its SQL DNS zone group). The
  corp App Service has **no** dependency on the SQL server, so it is not affected. online-p1 has no SQL tier.

**Decision:**
Gate the entire corp SQL tier behind a new `var.enable_sql` (bool, default `false`) in `landing-zones/corp-a1`
and `landing-zones/corp-a2`. The flag gates `random_id.sql_suffix`, `azurerm_mssql_server.this`,
`azurerm_mssql_database.app`, and `azurerm_private_endpoint.sql` (including its SQL DNS zone group nested
block). The 5 (corp-a1) / 4 (corp-a2) SQL-related outputs return `null` via `one(...)` when the tier is off.
The rest of the spoke stands. The pre-staged SQL wiring stays in place: the SQL private DNS zone data source
plus its vnet link in `dns_links.tf` are **not** provisioning-dependent, so they remain so a future re-enable
is a single-variable flip. Re-enable by setting `enable_sql = true` once an allowed region/subscription is
available or a support-request exception lifts the restriction.

**Alternatives considered:**
- Move the SQL tier to an Azure region where provisioning is allowed - rejected: introduces cross-region
  fragmentation (SQL split from the rest of the spoke, its VNet, and its private endpoint subnet), and corp-a2
  in centralus is expected to hit the same restriction, so it does not generalise. Not worth the topology
  distortion for a POC.
- Raise an Azure support-request exception to lift the regional provisioning restriction - rejected: too slow
  for the planned end-of-week teardown timeline; the tier would still be down while the request is pending.

**Consequences:**
- Positive: the full corp spoke topology stands minus the SQL database - VNet, peering, App Service, Recovery
  Services Vault, NSG, flow logs, and the PE subnet all provision. The App Service has no SQL dependency so it
  is unaffected. The pre-staged SQL DNS wiring (zone data source + vnet link) remains, so re-enabling is a
  one-variable flip. The failure is captured as a scoped, documented gate rather than silent debt or a blind
  retry against a capability the subscription does not have.
- Negative / trade-offs: no SQL server or database exists in the corp spokes until an allowed
  region/subscription is available and `enable_sql` is flipped; the spoke's "app + database" story is
  app-only until then. A default-false feature flag now lives in both corp landing-zone roots.
- Follow-ups required: (1) **OQ-025** tracks the re-enable trigger (which allowed region or support exception,
  and relocate-vs-wait), non-blocking and likely moot given the planned teardown. (2) **.tf comment cleanup
  (do not fix now, next touch of those files):** `landing-zones/corp-a1/policy_exemptions.tf:38-39` and
  `landing-zones/corp-a2/policy_exemptions.tf:28` still describe `SqlServerDenyPaasPublicIP` as "keeps
  governing the (already-private) SQL server" - now moot while `enable_sql = false` because no SQL server
  exists. The implementer should refresh those comments the next time those files are edited.

### ADR-030: Gate the geo_block Conditional Access policy off by default - Graph 1040 named-location reference failure persists after the ADR-029 fixes

- **Date:** 2026-07-10
- **Section:** 5 (azuread Conditional Access) / 8 (Identity)
- **Status:** Accepted. Amends the geo_block prediction in ADR-029 Part C (proven wrong - see Context).
- **Decision makers:** user, claude (architect)

**Context:**
ADR-029 Part C predicted geo_block would succeed on the recovery apply for two independent reasons: (1) the
post-import apply is short, so the OIDC client assertion stays valid; (2) the approved_countries named
location is days old, so error 1040 could not be propagation lag. **That prediction was WRONG.**

Evidence gathered this session (all verified):
- In deploy run 29068343843 (the recovery apply, ~34 min total), `azuread_conditional_access_policy.geo_block`
  was attempted about 1 minute into the apply - the OIDC token was unambiguously valid at that point - and
  still failed with Graph `400 / 1040 "NamedLocation ... does not exist in the directory."` So the cause is
  NOT token expiry. (ADR-029 conflated two failure modes: run 5's trailing-op failure was AADSTS700024 token
  expiry, but the 1040 itself is a separate, reproducible reference failure.) This is roughly the 5th
  recurrence of 1040 on geo_block.
- The named location DOES exist and is readable: a live Graph GET on its object id (created 2026-07-08)
  returns the object, yet the conditionalAccessPolicies create endpoint reports it does not exist. So this is
  neither "location missing" nor simple replication lag on a fresh object.
- Leading (unproven) hypothesis for a future root-cause pass: the policy references the named location by its
  full resource path (`/identity/conditionalAccess/namedLocations/<id>`) where the CA policy store expects the
  bare object id (or vice versa); OR a Graph CA-store consistency issue distinct from ordinary propagation.
  Secondary data-quality smell: the named location displayName came back with a replacement character where an
  em dash was likely intended - worth checking during diagnosis.

**Decision:**
Gate `azuread_conditional_access_policy.geo_block` behind a new `var.enable_geo_block_ca_policy`
(default `false`), so the identity root applies green with **7 of 8** CA policies. `time_sleep.wait_named_location`
(ADR-028) is gated on the same variable - it exists only to serialise geo_block behind the named location.
`azuread_named_location.approved_countries` STAYS created unconditionally: it is harmless, intended geo
configuration and is the object a re-enabled geo_block will reference. Re-enable by setting
`enable_geo_block_ca_policy = true` once the reference bug is root-caused.

Justification: **no enforcement or posture is lost by deferring geo_block.** All 8 CA policies in this POC are
report-only (they enforce nothing), and geo_block is 1 of 8. Deferring its CREATION while its named location
stays in place costs nothing operationally and unblocks a green identity apply, which the 4-fail bar makes the
priority. This is a scoped defer plus a bounded diagnosis follow-up, explicitly NOT another blind retry.

**Alternatives considered:**
- Keep retrying geo_block as-is - rejected: 5 identical 1040 failures make a 6th deterministic, and it keeps
  the whole identity root red for one report-only policy.
- Blind-add more `time_sleep` / propagation wait - rejected: the location is days old and a live GET resolves
  it, so this is not propagation; more sleep cannot fix a reference-format or CA-store-consistency bug.
- Speculatively switch geo_block's named-location reference (bare id vs full path) in this pass - rejected as
  premature: the correct reference form is exactly what the diagnosis pass must establish; changing it blind
  risks a 6th failure and burns the failure budget. Park it as the hypothesis to test (OQ-023).
- Delete and recreate the named location - rejected: it resolves on GET, so recreating it is unlikely to
  change the create-endpoint behaviour and only adds churn.

**Consequences:**
- Positive: identity root applies green (7/8 CA policies, all report-only); no posture lost; the named
  location stays in place so re-enabling is a one-variable flip; the failure is captured as a bounded
  diagnosis task, not carried as silent debt.
- Negative / trade-offs: geo_block does not exist in the directory until the reference bug is root-caused and
  the variable is flipped; the "8 CA policies" story is 7/8 until then (documented). A default-false feature
  flag now lives in the identity root.
- Follow-ups required: (1) **OQ-023** tracks the bounded named-location-reference diagnosis (test the
  full-path-vs-bare-id hypothesis and the CA-store-consistency angle; check the displayName
  replacement-character smell) and the re-enable via `enable_geo_block_ca_policy = true`; (2)
  `docs/preclearance/platform-identity.md` records geo_block as deferred (post-recovery addendum).

### ADR-029: Entra DS recovery - restore the default NSG inbound rules (AADDS104 fix), config-driven import of the built-but-unstated managed domain, and OIDC-token-expiry-on-long-apply mitigation

- **Date:** 2026-07-10
- **Section:** 8 (Identity subscription, Entra DS) / 5 (azuread Conditional Access) / 10 (CI auth)
- **Status:** Accepted
- **Decision makers:** user (mandated systemic fix after the 4-fail bar), claude (architect)

**Context:**
The 5th platform/identity apply (run 29055619749) failed after the ADR-028 exemption had already done its
job. Evidence that ADR-028 worked: the managed domain was actually built in Azure this time (the
service-created Standard PIP was admitted, `provisioningState: Succeeded`, replica set `Running`, one DC IP
`10.2.0.4`). The run then produced three errors, with a single primary root cause and two consequences.

Primary root cause - **AADDS104 CRITICAL health alert "The managed domain is experiencing a network
error"** (raised 2026-07-10 01:25 UTC, replica set East US 2 / vnet-identity-globaris-poc / snet-aadds).
Live network evidence gathered 2026-07-10 via az: `snet-aadds` has NSG `nsg-identity-aadds-globaris-poc`
and **routeTable = null** (no UDR, so the UDR branch of AADDS104 is ruled out - it is the NSG). The NSG's
only two custom rules are `Allow-AADDS-Management-5986` @301 (Allow TCP 5986 from the
`AzureActiveDirectoryDomainServices` service tag) and `Deny-All-Inbound` @4000 (Deny * / * / *).

The `Deny-All-Inbound` @4000 is the defect, now confirmed against MS Learn (not taken on faith):
- The AADDS104 troubleshooting article (learn.microsoft.com, entra/identity/domain-services/alert-nsg,
  reviewed 2026-07-10) lists the default inbound rules the managed domain relies on:
  `AllowPSRemoting` 5986 @301 (from `AzureActiveDirectoryDomainServices`), optional `AllowRD` 3389 @201
  (from `CorpNetSaw`), **`AllVnetInBound` Any @65000 (from `VirtualNetwork`)**, **`AllowAzureLoadBalancerInBound`
  Any @65001 (from `AzureLoadBalancer`)**, and `DenyAllInBound` Any @65500.
- The network-considerations article (entra/identity/domain-services/network-considerations, reviewed
  2026-07-10) is explicit: "Domain Services also relies on the Default Security rules AllowVnetInBound and
  AllowAzureLoadBalancerInBound." AllowVnetInBound lets the two DCs communicate and replicate and lets
  domain members join. AllowAzureLoadBalancerInBound is "required so that the service can properly
  communicate over the loadbalancer to manage the DCs." The domain sits behind an internal Standard SKU
  load balancer, and the platform health probe source is `AzureLoadBalancer` (168.63.129.16).
- NSG rules evaluate lowest-priority-number first. Our custom `Deny-All-Inbound` @4000 sits ABOVE (numerically
  below) both required defaults (`AllVnetInBound` @65000 and `AllowAzureLoadBalancerInBound` @65001), so it
  wins and blocks both intra-VNet DC replication and the load-balancer management/health path. The single
  5986 management allow is not sufficient. Result: Microsoft cannot reach the DCs, the second DC never
  becomes reachable, and AADDS104 fires. The network-considerations article warns directly: "Don't create
  or use an existing network security group with your own custom rules"; the alert-nsg article says to
  "delete any custom rules that block required traffic."

Consequence 1 - **the domain create timed out (`waiting for both domain controllers to become available ...
last state 'pending', 2h11m46s`).** This is create-only wait behaviour of
`azurerm_active_directory_domain_service` (provider docs confirm create defaults to a 3h timeout that
"accommodates the lengthy provisioning process ... for domain controller infrastructure"). Because
AADDS104 blocked the 2nd DC, the wait never returned and the create errored during polling. IMPORTANT STATE
FACT: the domain exists in Azure but is NOT in Terraform state (the provider records the ID only after the
create's polling returns). A plain rerun hits azurerm's requires-import guard ("already exists") and fails
again.

Consequence 2 - **`azuread_conditional_access_policy.geo_block` failed 400/1040 (named-location), and the
run surfaced `AADSTS700024: Client assertion is not within its valid time range`** (assertion valid
22:49:19Z to 22:54:19Z; the trailing Graph ops ran at 01:55:24Z). The GitHub OIDC federated assertion
(~5 min) and its derived access tokens (~1h) do not survive a 3h apply. The 1040 "named location not found"
is NOT propagation lag: the named location has existed since 2026-07-08 (days old, well past the Graph
replication window that ADR-028's `time_sleep.wait_named_location` guards). The true blocker was the expired
client assertion - the azuread/Graph operations at the tail of a multi-hour apply could no longer
authenticate. This is architectural: the identity root co-locates a 1-3h AADDS create with azuread
Graph/Conditional-Access operations in one CI apply. (The azurerm/ARM operations survived the long apply -
the domain was built - so the exposure is specifically the azuread provider's tail-end Graph calls.)

**Decision:**

**Part A - NSG: remove the custom `Deny-All-Inbound` rule and fall back to the Azure default rules
(Option a).** Correct the `azurerm_network_security_group.entra_ds` rule set to:
- KEEP `Allow-AADDS-Management-5986` @301 (Allow TCP 5986 from `AzureActiveDirectoryDomainServices`). This
  equals Microsoft's own `AllowPSRemoting` @301.
- DELETE the `Deny-All-Inbound` @4000 rule entirely.
- The Azure default rules then govern, exactly as Microsoft requires: `AllowVnetInBound` @65000,
  `AllowAzureLoadBalancerInBound` @65001, and `DenyAllInBound` @65500. Internet inbound remains denied by the
  default @65500, so removing our custom deny loses no protection. The resulting NSG reproduces Microsoft's
  documented default managed-domain NSG (minus the optional `CorpNetSaw` RDP rule, which is deny-by-default
  and not needed).
This does not trip policy: `Deny-Subnet-Without-Nsg` is still satisfied (the NSG still exists on the subnet),
and `Deny-MgmtPorts-Internet` is satisfied (the 5986 rule sources a service tag, not Internet). No ALZ
policy requires a custom explicit deny-all rule.

**Part B - config-driven import of the built-but-unstated domain.** The domain exists in Azure but not in
state; a rerun would fail the requires-import guard. Recover it with a Terraform **`import {}` block** (config-
driven import, supported since Terraform 1.5; the root pins `required_version >= 1.9`, so this is available)
processed during the normal CI plan/apply - NO local `terraform import`, respecting the CI-only-apply rule.
CRITICAL FORMAT DETAIL (verified against the provider import docs, v4.71.0): the import ID for
`azurerm_active_directory_domain_service` is a **composite**, not the plain resource ID -
`<domain resource ID>/initialReplicaSetId/<initial replica set GUID>`. A plain resource-ID import would fail.
The initial replica set GUID must be read from the live domain (portal, or
`az resource show --ids <domain-id> --query "properties.replicaSets[0].replicaSetId"`) and supplied to the
cloud-engineer; it is implementation detail, not committed prose. After import, the domain is in state; the
create-wait (a create-only operation) is never re-entered, so subsequent plans do a Read (GET, seconds) and
show 0 changes on the domain. The 2nd DC IP populating after the NSG heals lands in the computed
`domain_controller_ip_addresses` of the replica set, so it causes no config diff (benign).

**Part C - OIDC token expiry on long applies: import is the fix for the POC now; a durable greenfield fix
is tracked, not built.** Once the domain is imported, the identity root has no remaining multi-hour long
pole, so every future apply is short and the OIDC assertion/token never expires. `geo_block` then succeeds
on the recovery apply for two independent reasons: the apply is short (valid token) and the named location
is days old (resolves immediately). Keep `time_sleep.wait_named_location` (ADR-028) - it is harmless and
keeps the greenfield DEPLOYMENT.md path deterministic. Import ALONE suffices for the POC because the domain
is created once and thereafter only refreshed. Splitting the identity root into a Phase-1 (network + AADDS)
and Phase-2 (azuread CA) apply, or adding a CI job-level re-auth for the azuread provider, is the durable
fix for a from-scratch greenfield rebuild (where the 3h create would again precede the Graph ops), but that
is a non-trivial refactor (new root, state migration, cross-root data passing) and speculative scope for a
POC that must go green. Tracked as OQ-022. platform/identity stays CI-only.

**Ordered recovery runbook:**
1. Cloud-engineer (code, `platform/identity`, one batch, code-reviewer gates):
   (a) remove the `Deny-All-Inbound` @4000 `security_rule` from `azurerm_network_security_group.entra_ds`
   and update the NSG header comment to cite the alert-nsg / network-considerations requirement that the
   default AllowVnetInBound + AllowAzureLoadBalancerInBound rules must remain in effect and that a custom
   low-priority deny-all breaks AADDS; (b) add an `import {}` block with
   `to = azurerm_active_directory_domain_service.this[0]` and `id = "<composite import ID>"` (domain
   resource ID + `/initialReplicaSetId/<replica-set GUID>` obtained from the operator/az).
2. Operator supplies the initial replica set GUID (portal or az) to the cloud-engineer for the import ID.
3. CI plan: expect the NSG updated in place (1 rule removed), the domain IMPORTED (plan shows import, not
   create), and `geo_block` created (1 to add); 0 destroy. Gate: verify the plan shows "import" (not
   "create") for the domain and the NSG diff removes only the deny rule.
4. CI apply: NSG deny rule removed, domain imported into state, geo_block created. The apply is short (no
   multi-hour create-wait), so the OIDC token stays valid.
5. Post-apply verification (operator, az): AADDS104 clears and the domain health returns to green, and the
   2nd DC IP appears (replica set shows two DC IPs). Per the alert-nsg article, the managed domain's health
   auto-updates within ~2 hours of the NSG fix. Verify via `az ad ds show` / the portal health blade.
6. Post-apply cleanup: once the domain is healthy, REMOVE the two temp directory roles (Application
   Administrator + Groups Administrator) from the CI SP (standing follow-up from ADR-028 / the 2026-07-08
   session).
7. Confirm steady state: a subsequent CI plan shows 0 changes on the domain (Read-only refresh), proving the
   token-expiry exposure is closed for the POC lifetime.

Sequencing note (why NSG-fix and import ship together, not NSG-first-then-import): an NSG-only apply is not
viable while the domain is in config but not in state - the domain resource would attempt a CREATE and fail
the requires-import guard. The `import {}` block must therefore ship in the same change as the NSG fix so
the domain resolves to import, not create. This is safe: import is a metadata read with no create-wait, so
it succeeds even while the 2nd DC is still healing, and the heal completes asynchronously afterward (benign
computed-attribute update). Healing before import is not achievable without a local import or a -target,
both of which the CI-only rule forbids.

**Alternatives considered:**
- NSG Option (b): keep a custom `Deny-All-Inbound` and add explicit Allow-inbound rules for `VirtualNetwork`
  and `AzureLoadBalancer` (plus 5986) above priority 4000 - rejected: it merely reproduces the Azure default
  rules with two extra self-managed rules, adds maintenance surface, and gives zero additional protection
  (Internet is already denied at the default @65500). MS guidance names the default rules as the required
  ones and says to remove custom rules that block them, so Option (a) is both simpler and canonical.
- Delete the failed domain and redeploy from scratch (the ADR-028 shell-delete pattern) - rejected here: in
  run 4 the object was a hollow shell (empty replica set); in run 5 the domain is genuinely built (Succeeded,
  replica set Running, a live DC). Deleting a real, healthy-after-NSG-fix managed domain to recreate it would
  incur another 1-3h create and re-expose the token-expiry problem. Import preserves the built domain.
- Split the identity root now (Phase 1 network+AADDS, Phase 2 azuread CA) - deferred (OQ-022): the durable
  greenfield fix, but a non-trivial refactor and speculative scope for the immediate recovery. Import alone
  closes the token-expiry for the POC.
- Blame propagation for geo_block and add more sleep - rejected: the named location is days old, so 1040 was
  not propagation; the real cause was the expired client assertion, fixed by the short (post-import) apply.

**Consequences:**
- Positive: AADDS104 is fixed at the IaC layer with the MS-canonical minimal NSG; the built domain is
  recovered into state without destroying it; every future apply is short, closing the OIDC-token-expiry
  exposure; geo_block succeeds; the greenfield-reproducibility gap is captured rather than silently carried.
- Negative / trade-offs: the subnet now relies on the Azure default rules for AllowVnetInBound /
  AllowAzureLoadBalancerInBound / DenyAllInBound rather than an explicit repo-authored deny (documented and
  MS-recommended, but the deny-all is now implicit at @65500). The import ID carries a live replica set GUID
  that must be fetched operationally. A from-scratch greenfield rebuild still hits the 3h create before the
  Graph ops until OQ-022 is addressed.
- Follow-ups required: (1) operator supplies the initial replica set GUID for the import ID; (2) post-apply,
  verify AADDS104 clears and the 2nd DC heals within ~2h; (3) remove the two temp directory roles from the CI
  SP after the domain is healthy; (4) OQ-022 tracks the durable greenfield token-expiry fix (root split or CI
  re-auth); (5) OQ-021 (unwired Deploy-Diag-LogsCat LAW parameter) and OQ-008 (standing Owner removal) are
  unchanged by this ADR.

**Addendum (2026-07-10, post-recovery-apply run 29068343843) - what actually happened vs the plan above.**
The core diagnosis held: the AADDS104 NSG deny-all was the root cause, and removing it healed the domain (the
2nd DC IP appeared). But three mechanisms played out differently in execution. Recorded here for accuracy; the
decision above is not rewritten.

1. **Recovery was `terraform untaint`, NOT the config-driven import.** The timed-out create did not leave the
   domain absent from state - it left it **tainted** in state (the provider had recorded the ID, then marked
   it tainted when the create-wait errored). Config-driven `import {}` is skipped for any resource already in
   state, so Part B's import block was a **no-op** and the plan fell through to a destructive **REPLACE**
   (create-new + destroy-old) of the live managed domain. The actual recovery mechanism was `terraform
   untaint` on the domain address, run as a new **CI-only `action=untaint`** path added to `deploy.yml` /
   `_tf-root.yml`, single-target-guarded (untaint is scoped to one resource address, never a whole root). The
   `import {}` block and the `aadds_import_replica_set_id` variable are retained but re-scoped to the
   **greenfield-redeploy adoption path only** (where the domain genuinely is built-but-unstated), not this
   recovery.

2. **A second ForceNew replace surfaced after untaint: `domain_configuration_type`.** Untaint cleared the
   taint, but the next plan still proposed a ForceNew replace because `domain_configuration_type` was unset in
   config (planned null) while Azure had defaulted it server-side to `"FullySynced"`. Fixed by pinning
   `domain_configuration_type = "FullySynced"` in the module call (committed 305757f). General lesson:
   `azurerm_active_directory_domain_service` has **Optional + ForceNew + not-Computed** arguments that Azure
   fills in server-side; any such argument must be pinned explicitly in config or every plan proposes a
   destructive replace.

3. **The AADDS post-deploy DNS step was missed and had to be done manually, now wired in IaC.** A managed
   domain requires the identity VNet's DNS servers to point at the two DC IPs, which are only knowable AFTER
   the domain exists. Our AVM VNet module call omitted `dns_servers`, so the operator set them manually in the
   portal to make the domain usable. This is now in IaC by passing the DC IPs through the AVM VNet module's
   `dns_servers` input. A separate `azapi_update_resource` to set VNet DNS was rejected: the AVM VNet module
   asserts `dhcpOptions = null` and would fight an out-of-band update, causing perpetual drift. Checklist gap
   recorded: **"AADDS post-deploy: identity VNet DNS -> DC IPs"** is now a required step in the identity
   pre-clearance / runbook.

Net: the domain is healthy and in clean steady state (untaint + FullySynced pin + DNS-in-IaC), and the NSG
diagnosis in the decision above stands. Only the recovery MECHANISM (untaint, not import) and the two
follow-on ForceNew / DNS details differed from the plan. geo_block, which Part C predicted would now succeed,
did NOT - see **ADR-030**.

### ADR-028: Resource-group-scoped policy exemption for Entra Domain Services vs the ALZ Deny-Public-IP assignment at the Identity MG

- **Date:** 2026-07-09
- **Section:** 8 (Identity subscription, Entra DS) / 2 (ALZ policy stack)
- **Status:** Accepted
- **Decision makers:** user (mandated systemic fix), claude (architect)

**Context:**
Deploy run 28978396902 (platform/identity, 4th apply) failed with the Entra DS managed domain reaching
terminal `Failed`: `ResourceActionsBlockedByPolicy - Unable to deploy network resources into
rg-identity-aadds-globaris-poc because there is a policy preventing this action`. Activity Log evidence
(captured live): the denied write was `Microsoft.Network/publicIPAddresses/aadds-...-pip` in
`rg-identity-aadds-globaris-poc`, and the caller was the Entra Domain Services service principal, NOT our
CI SP. The denying assignment is `Deny-Public-IP` at the `identity` MG (built-in definition
`6c112d4e-5bc7-47ae-a041-ea2d9dccd749` "Not allowed resource types", effect `Deny`,
`listOfResourceTypesNotAllowed = ["Microsoft.Network/publicIPAddresses"]`, enforcementMode `Default`,
verified live 2026-07-09). That assignment is the ALZ identity-archetype DEFAULT, deployed by our own
`platform/management-groups` root via avm-ptn-alz.

This is a structural collision, not a bug in either side:
- The managed domain's Standard SKU public IP is a MANDATORY service-created resource. MS Learn
  (entra/identity/domain-services/network-considerations, verified 2026-07-09) lists it in "Network
  resources used by Domain Services": "Domain Services communicates with the synchronization and
  management service using a Standard SKU public IP address", with an explicit warning not to delete or
  modify these resources. There is no SKU, argument, or configuration that suppresses it.
- Azure Policy `Deny` evaluates every write at the scope regardless of caller, so no permission grant to
  any principal can bypass it. The only levers are: exemption, enforcement mode, or parameter change.
- The AADDS-vs-identity-MG-deny collision is a known pattern class in the Enterprise-Scale/ALZ community
  (same family as the Enable-DDoS-VNET placeholder trap, ADR-026). No single canonical upstream issue was
  found to cite; the load-bearing verification here is the MS Learn requirement doc plus our live
  Activity Log and policy-assignment evidence.

**Decision:**
Create a **resource-group-scoped policy exemption** on `rg-identity-aadds-globaris-poc` for the
`Deny-Public-IP` assignment, category **Waiver**, managed as code in `platform/identity` with
`azurerm_resource_group_policy_exemption` (resource verified present in azurerm v4.71.0; args `name`,
`resource_group_id`, `policy_assignment_id`, `exemption_category` in {Waiver, Mitigated}, optional
`display_name`/`description`/`expires_on`). The exemption must be created BEFORE the domain create
retries, with a propagation wait between them. `Deny-Public-IP` stays fully enforced everywhere else in
the identity MG, including `rg-identity-network-globaris-poc`.

**Implementation brief (cloud-engineer lane, all in `platform/identity`):**
1. `providers.tf`: add `time = { source = "hashicorp/time", version = "~> 0.13.1" }` to
   required_providers (same pin as bootstrap). Regenerate the lock file for windows_amd64 + linux_amd64.
2. `domain-services.tf`, before the domain resource:
   - `resource "azurerm_resource_group_policy_exemption" "aadds_deny_public_ip"`:
     `provider = azurerm.identity`, `count = local.entra_ds_enabled ? 1 : 0`,
     `name = "exempt-deny-public-ip-aadds"`,
     `resource_group_id = azurerm_resource_group.identity_aadds[0].id`,
     `policy_assignment_id = "/providers/Microsoft.Management/managementGroups/identity/providers/Microsoft.Authorization/policyAssignments/Deny-Public-IP"`
     (literal string; the assignment is owned by the management-groups root, there is no cross-root
     output for it - add a comment saying so and referencing this ADR),
     `exemption_category = "Waiver"`, plus display_name/description referencing ADR-028. No
     `expires_on`: the PIP is required for the lifetime of the managed domain.
   - `resource "time_sleep" "wait_aadds_policy_exemption"`: `count` same gate,
     `create_duration = "300s"`, `depends_on = [azurerm_resource_group_policy_exemption.aadds_deny_public_ip]`.
     Rationale: exemptions propagate to policy-engine caches asynchronously; the domain deploys its
     network resources within the first minutes of provisioning, and a lost race costs another
     multi-hour failed provisioning cycle.
   - Add `time_sleep.wait_aadds_policy_exemption` to the domain resource's `depends_on` list.
3. `main.tf` (greenfield hardening, same time provider): `resource "time_sleep" "wait_named_location"`
   with `create_duration = "300s"` and `depends_on = [azuread_named_location.approved_countries]`; make
   `azuread_conditional_access_policy.geo_block` depend on it. This encodes the known Graph
   replication lag on FRESHLY created named locations (error 1040 fired 1 second after creation in run
   28978396902). For THIS tenant no wait is strictly needed anymore (the named location has existed
   since 2026-07-08, well past the lag window; a plain rerun clears geo_block), but the sleep makes the
   greenfield DEPLOYMENT.md path deterministic. It only costs 5 minutes when the named location is
   newly created.
4. **Manual pre-apply step (operator, az CLI): delete the failed managed-domain shell.** The failed
   create left a hollow `Microsoft.AAD/domainServices` object (ARM envelope `provisioningState:
   Succeeded` but replica set empty - no subnet, no DC IPs, verified live 2026-07-09). It is NOT in
   Terraform state: the provider only records the ID after successful polling, and the run-4 log shows
   the create errored during polling. Consequence of NOT deleting: azurerm v4's requires-import guard
   GETs the resource at create start, finds it, and fails fast with "already exists ... needs to be
   imported". Import-then-replace is pointless for a broken shell; Microsoft's guidance for a failed
   managed-domain deployment is delete and redeploy. Command shape:
   `az resource delete --ids /subscriptions/<identity-sub>/resourceGroups/rg-identity-aadds-globaris-poc/providers/Microsoft.AAD/domainServices/aadds-globaris-poc`
   (wait for completion before the next apply).
5. RBAC check (verified live 2026-07-09, `az role assignment list`): the exemption write
   (`Microsoft.Authorization/policyExemptions/write`) is AUTHORIZED and will not 403 at
   `rg-identity-aadds-globaris-poc`. It is covered TWO independent ways, both inherited to the RG:
   (a) the standing **Owner** @ managementGroups/globaris (org root MG), and (b) **Resource Policy
   Contributor** @ managementGroups/globaris, which grants `Microsoft.Authorization/policyExemptions/*`.
   Least-privilege note: ADR-028 does NOT depend on the broad Owner grant. Even after the OQ-008
   Owner-at-globaris grant is eventually removed (the ADR-021 scope-down), the exemption write still
   succeeds via Resource Policy Contributor @ globaris, which survives that scope-down by design. See
   [OQ-008](OPEN-QUESTIONS.md) for the standing-Owner removal that is still pending.
6. Expected next plan: 5 to add (exemption, 2x time_sleep, domain, geo_block CA policy), 0 change,
   0 destroy. 7 of 8 CA policies already exist after run 4.

**Alternatives considered:**
- `policy_assignments_to_modify` -> `enforcementMode = DoNotEnforce` for `Deny-Public-IP` at the identity
  MG (ADR-026 precedent) - rejected: disables public-IP denial for the ENTIRE identity subscription to
  admit one service-managed PIP in one RG; also couples the identity deploy to a management-groups
  re-apply. ADR-026 used this lever because the DDoS Modify policy was broken tenant-wide by a
  placeholder parameter; here the policy is correct and should stay live.
- Parameter-modify `listOfResourceTypesNotAllowed` (drop publicIPAddresses) - rejected: functionally
  disables the assignment at the whole MG, worse than DoNotEnforce for observability (compliance still
  reports green), same blast radius problem.
- `notScopes` on the assignment - rejected: same effect as an exemption but managed in the
  management-groups root, invisible to compliance reporting (exemptions are first-class, auditable
  objects with category and expiry; notScopes are not), and Azure Policy documentation positions
  exemptions as the purpose-built mechanism for exactly this.
- Do nothing / retry - rejected: Deny is caller-independent and the PIP is mandatory; the failure is
  deterministic, proven by 1 failed provisioning cycle.

**Consequences:**
- Positive: unblocks the Entra DS create; the deny stays enforced across the identity MG; the exemption
  is IaC-managed, auditable, and scoped to the one RG that structurally requires it; the time provider
  pattern also fixes the named-location race for greenfield deploys.
- Negative / trade-offs: everything in `rg-identity-aadds-globaris-poc` (currently the domain + the
  identity RSV) is exempt from Deny-Public-IP; acceptable - the RG is dedicated and the RSV creates no
  PIPs. Two 5-minute sleeps on fresh creates. The literal policy-assignment ID string couples
  platform/identity to the ALZ assignment name `Deny-Public-IP`; if the ALZ library renames it, the
  exemption dangles (documented in the code comment).
- Follow-ups required: (1) operator deletes the failed domain shell BEFORE the next apply (step 4);
  (2) after the domain reaches Running, REMOVE the two directory roles (Application Administrator +
  Groups Administrator) from the CI SP - standing mandatory follow-up from the 2026-07-08 session;
  (3) **Correction (2026-07-09, run 29055619749):** the failed `Deploy-Diag-LogsCat` DINE deployment
  (aad-domainservices diagnostics to the platform LAW) is NOT follow-on noise from the failed domain and
  does NOT self-heal. Verified root cause: the assignment's central Log Analytics workspace parameter is
  unwired, so the diagnostic setting's workspace resource ID resolves to the zero-GUID subscription
  `00000000-...` and the deploy fails with `LinkedAuthorizationFailed`. This fails for every resource the
  policy targets tenant-wide, not just AADDS; `az policy remediation create` would re-fail. It needs a real
  fix - wire the platform LAW resource ID into the assignment in `platform/management-groups` - not a wait.
  Tracked in [OQ-021](OPEN-QUESTIONS.md). It does not block the identity apply;
  (4) pre-clearance doc for platform/identity (docs/preclearance/platform-identity.md) carries the full
  re-apply runbook.

### ADR-027: Migrate subscription cost exports to azapi with a system-assigned managed identity (keyless destination SA)

- **Date:** 2026-07-08
- **Section:** 7 - FinOps: Tagging & Budgets
- **Status:** Accepted (user-ratified direction 2026-07-08)
- **Decision makers:** user, claude

**Context:**
Deploy run 28911617973 (platform/management apply): 4 of 5 `azurerm_subscription_cost_management_export`
creates failed with `400: Key-based authentication is currently disabled on this storage account. To
proceed, please enable "Allow storage account key access"`. The destination cost-exports SA is Entra-only
(`shared_access_key_enabled = false`) by design (repo-wide keyless pattern, LESSONS #1). The azurerm
~>4.71.0 resource drives an older CostManagement API version that hard-rejects key-disabled destination
SAs at PUT, so export CREATION fails, not just delivery - this closes OQ-020's "wait and verify" option.
Microsoft's supported path for keyless/firewalled SAs is CostManagement API 2023-08-01 or newer with a
system-assigned managed identity on the export; per the improved-exports tutorial, when the creating
principal holds `Microsoft.Authorization/roleAssignments/write` on the destination SA, the service
auto-assigns the export's MI Storage Blob Data Contributor scoped to the destination container. Our CI SP
holds User Access Administrator at subscription scope (ADR-021 row 6), which covers the SA. The 5th export
(identity sub) failed only on a STALE "RP Not Registered" check - Microsoft.CostManagementExports was
registered by the same apply and the service check lagged; a plain rerun clears it (propagation lag, no
design impact).

Verified against the ARM template reference (learn.microsoft.com/azure/templates,
microsoft.costmanagement/exports, page updated 2026-01-20): GA API versions 2023-08-01 / 2023-09-01 /
2023-11-01 / 2024-08-01 / 2025-03-01 (latest); `identity` accepts `SystemAssigned`; `location` is "only
required when utilizing managed identity"; `schedule.recurrencePeriod.from` "must be in future";
delivery destination takes the STORAGE ACCOUNT `resourceId` plus container NAME (not a container ARM ID).
Verified against azapi provider docs: `ignore_body_changes` was removed in azapi 2.0 and
`lifecycle.ignore_changes` on nested `body` paths is the supported replacement (dynamic properties);
identity block exports read-only `principal_id`/`tenant_id`; OIDC auth honors the ARM_* env vars plus
GitHub's ACTIONS_ID_TOKEN_REQUEST_* - all already exported by `_tf-root.yml`.

**Decision:**
Replace `azurerm_subscription_cost_management_export` in `modules/finops` with `azapi_resource` of type
**`Microsoft.CostManagement/exports@2025-03-01`** (latest GA per the ARM reference; MI support exists from
2023-08-01, the newest GA is chosen so the FocusCost dataset is a one-line future option), created as an
extension resource with `parent_id = "/subscriptions/<sub-guid>"`, `identity { type = "SystemAssigned" }`,
and `location` set from the management root's `var.primary_location`. The SA stays keyless. Dataset parity
is preserved: ActualCost / MonthToDate / Daily granularity / Csv / Active daily schedule / per-sub root
folder. The future-start guard carries over unchanged: `schedule.recurrencePeriod.from =
local.export_recurrence_start` with `lifecycle { ignore_changes =
[body.properties.schedule.recurrencePeriod.from] }`. Role grant for the export MI: rely on the DOCUMENTED
service-side auto-assignment (creator SP holds roleAssignments/write on the SA via UAA); do NOT add an
explicit `azurerm_role_assignment` now. Provider pins: `modules/finops` adds `azapi ~> 2.5` alongside
azurerm; `platform/management` adds the same pin plus an empty `provider "azapi" {}` block (auth via the
existing ARM_* OIDC env vars; no CI changes). Module interface change: `export_container_arm_id` is
replaced by `export_storage_account_id` + `export_container_name` to match the ARM body shape without
string parsing.

**Alternatives considered:**
- Re-enable shared keys on the cost-exports SA (`shared_access_key_enabled = true`) - rejected: weakens
  posture and breaks the repo-wide keyless pattern for a single consumer; the MI path is the supported fix.
- Drop the cost exports - rejected: loses the Section 7 FinOps export evidence for a solvable problem.
- Wait for azurerm to expose `identity` on the export resource - rejected: no upstream timeline; azapi is
  the sanctioned escape hatch for API-version gaps (same rationale as prior azapi uses, ADR-017).
- Explicit `azurerm_role_assignment` on the MI principal as the PRIMARY grant - rejected as primary: the
  service may ALSO auto-assign (our SP always holds roleAssignments/write at create time), producing
  duplicate assignments, and it adds an apply-order dependency on the post-create principal id. Kept as the
  documented FALLBACK: if the first export run fails delivery with an authorization error, add
  `azurerm_role_assignment` (scope = SA id, role `Storage Blob Data Contributor`, principal =
  `azapi_resource...identity[0].principal_id`) inside `modules/finops`. A 409 duplicate is only possible on
  identical role+scope+principal; the service assigns at CONTAINER scope, the fallback at SA scope, so they
  cannot collide.
- API version 2023-08-01 (minimum for MI, used in Microsoft's own azapi sample) - not chosen as primary:
  older versions age out and FocusCost is absent; it is the designated FALLBACK if azapi plan-time schema
  validation rejects 2025-03-01 (see UNVERIFIED below). Never disable `schema_validation_enabled` to force
  a version through.

**Consequences:**
- Positive: keyless SA preserved end to end; exports move to the supported MI delivery path; the
  plantimestamp future-start guard and `export_enabled` gating carry over; FocusCost is one version-string
  away; no CI/workflow changes (azapi OIDC already proven in this pipeline by platform/connectivity).
- Negative / trade-offs: second provider in modules/finops; the export body loses azurerm's typed schema
  (azapi embedded-schema validation covers it at plan); the service-side role assignment lives outside
  Terraform state (documented here, verified operationally); azapi pin drift across roots grows by one
  (picked `~> 2.5` to match ADR-017; the OQ-017 standardization pass reconciles all azapi pins later).
- Follow-ups required: (1) rerun clears the stale RP check on the 5th export; (2) after the first
  scheduled run, verify blobs land in `cost-exports` AND that the auto-created MI role assignment exists on
  the container - if delivery fails with an auth error, implement the explicit role-assignment fallback;
  (3) migration is a clean swap - all 5 exports failed to create, so nothing exists in Azure or in state
  (engineer confirms with `terraform state list` before deleting the old resource block; no
  import/moved blocks).
- UNVERIFIED (marked honestly): whether the azapi release resolved by `~> 2.5` embeds api-version
  2025-03-01 in its validation schema cannot be enumerated offline; failure mode is a plan-time validation
  error (fail-fast, no Azure mutation), remedy is the 2023-08-01 fallback above. The tutorial documents MI
  auto-assignment for export creation generally; it has not yet been observed in this tenant - hence
  follow-up (2) is mandatory, not optional.

### ADR-026: Neutralise the ALZ `Enable-DDoS-VNET` Modify policy at the Connectivity MG for the POC

- **Date:** 2026-07-06
- **Section:** 2 — Management Group Hierarchy (policy) / 4 — Connectivity (impact)
- **Status:** Accepted (user-approved 2026-07-06)
- **Decision makers:** user, claude

**Context:**
Both hub VNet creates in the connectivity subscription failed at apply with
`403 LinkedAuthorizationFailed`: ARM ran a `Microsoft.Network/ddosProtectionPlans/join/action`
linked-auth check against the non-existent subscription `00000000-0000-0000-0000-000000000000`.
Root-caused (after a two-PUT test refuted the earlier azapi null-key theory): `avm-ptn-alz`
0.19.1 applies the ALZ default assignment **`Enable-DDoS-VNET`** (Modify, built-in def
`94de2ad3-e0c1-4caf-ad78-5d47bbc83d3d`, "Virtual networks should be protected by Azure DDoS
Protection") at the **Connectivity management group**, enforced, with its `ddosPlan` parameter set
to the placeholder `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/
providers/Microsoft.Network/ddosProtectionPlans/placeholder`. The Modify rule does
`addOrReplace` on `Microsoft.Network/virtualNetworks/ddosProtectionPlan.id` (and
`enableDdosProtection = true`) at admission time, so **every** VNet PUT in the connectivity
subscription is rewritten to reference a DDoS plan in the zero-GUID subscription, which fails the
linked-auth check. This is body-independent (Modify injects regardless of request body — PUT with
`ddosProtectionPlan: null` and PUT with the key omitted both failed identically) and
subscription-specific (the Management MG has no such assignment, so the identical body succeeds
there). Confirmed placement of the connectivity sub under the Connectivity MG via
`management-group show --expand`; corroborated upstream by Enterprise-Scale #1053/#983 and
ALZ-Bicep #181/#596 (the known "enforced DDoS Modify policy with placeholder plan id breaks all
VNet creates" trap). The failure originates in the `platform/management-groups` root module
(policy), not in `platform/connectivity`, azapi, or the AVM VNet leaf module.

**Decision:**
Set `enforcement_mode = "DoNotEnforce"` on the `Enable-DDoS-VNET` assignment at the `connectivity`
management group via the `policy_assignments_to_modify` input of `Azure/avm-ptn-alz/azurerm` 0.19.1
in `platform/management-groups/main.tf`. This stops the Modify effect from mutating VNet requests,
unblocking all hub/identity/spoke VNet creates at zero cost, consistent with the existing POC
decision to run without DDoS Standard. When DDoS is later enabled, supply a real plan id via
`policy_default_values` (the assignment binds `ddosPlan` to a library default) and restore
enforcement.

**Alternatives considered:**
- Disable via the assignment `effect` parameter (`Disabled`) or `overrides = [{ kind = "policyEffect", value = "Disabled" }]`, or drop it with `creation_enabled = false` — equivalent outcomes; `DoNotEnforce` chosen as the simplest reversible form that keeps the assignment visible.
- Supply a real DDoS Standard plan id via `policy_default_values` — rejected for the POC: DDoS Standard is a flat ~$2,944/mo and DDoS governance is out of scope.
- Manual `az policy assignment update` — rejected: would drift and be reverted on the next `management-groups` apply. The fix must be version-controlled in the root module.
- Fixing it in `platform/connectivity` (the `enable_ddos_standard` plan gate) — rejected: that gate governs the plan resource, not the Modify policy; it cannot affect an admission-time policy in a different root module (this is the coupling caveat below).

**Consequences:**
- Positive: unblocks every VNet create in the connectivity subscription at zero cost; reversible; keeps the assignment present for a future real-plan re-enforcement.
- Negative / trade-offs: no DDoS auto-enable enforcement during the POC (accepted). Introduces a documented coupling — the DDoS decision now spans two root modules (`management-groups` policy + `connectivity` plan) that must be flipped together.
- Follow-ups required: OQ-019 (single shared `enable_ddos_standard` variable driving both stacks so they cannot diverge). Supersedes commit `e2733db` as the **fix location** for this failure; `e2733db` remains valid as the cost gate for the DDoS plan resource itself.

**ADDENDUM 2026-07-10 - DoNotEnforce extended to the `landingzones` MG (committed 2581bd4):**
The original decision only DoNotEnforce'd `Enable-DDoS-VNET` at the **Connectivity** MG. Live
pre-clearance for the landing-zone spokes found the SAME `Enable-DDoS-VNET` assignment still
**ENFORCED at the `landingzones` MG**, with the same placeholder-plan `ddosPlan` parameter. Left as-is
it would inject the invalid zero-GUID plan id into every spoke VNet PUT and reproduce the identical
`403 LinkedAuthorizationFailed` outage on corp-a1 / corp-a2 / online-p1. Extended the DoNotEnforce to
the `landingzones` MG via the same `policy_assignments_to_modify` input of `Azure/avm-ptn-alz/azurerm`
0.19.1 in `platform/management-groups/main.tf` (committed 2581bd4). This is the **OQ-019 split-toggle
risk materialising**: because the plan resource in `platform/connectivity` and the `Enable-DDoS-VNET`
policy in `platform/management-groups` were never linked, neutralising the policy at one MG scope did
nothing at another, and the enforced assignment had to be found and DoNotEnforce'd per MG. This
reinforces the OQ-019 recommendation (a single `enable_ddos_standard` driving the plan resource AND
the policy assignment enforcement across every relevant MG scope). See OQ-019.

### ADR-025: CI state-SA firewall — JIT default_action Allow/Deny flip, not single-IP allow-list (fixes LESSON 16 race)

- **Date:** 2026-07-06
- **Section:** 10 — Pipeline & Tooling (state backend access)
- **Status:** Accepted (Option A; user-approved 2026-07-06)
- **Decision makers:** user, claude

**Context:**
The state SA is default_action=Deny with a static ip_rules list. The manage_runner_ip step
(LESSON 16) JIT-adds the runner's api.ipify.org egress IP, polls a blob-list until admitted,
then runs init. connectivity init failed on 4 attempts; management-groups succeeded on 3 —
misread as a deterministic per-root split. Log analysis refutes that: connectivity itself
REACHED the blob (409 BlobImmutableDueToPolicy, then a blob-lock error) in 2 of 4 runs and
only got 403 AuthorizationFailure in the other 2 — a flipping, non-deterministic outcome.
Every run drew a different random hosted-runner egress IP. In run 28798776899 the az poll was
admitted (14:24:48) yet Terraform's own read 403'd 19s later (14:25:07) from the same job.
403 AuthorizationFailure (not AuthorizationPermissionMismatch) with a network-deny SA is a
NETWORK block, not RBAC; the SP's Blob Data role is proven intact. Root cause: pinning ONE IP
is unreliable from hosted runners because (a) outbound SNATs across a dynamic IP pool so the
ipify IP is not necessarily Terraform's egress IP, and (b) Storage IP-rule propagation is
eventually consistent per front-end node, so single-IP admittance is non-monotonic within the
window. The provider subscription_id and the 0-byte connectivity state blob were both excluded
as causes by evidence.

**Decision:**
Replace the JIT single-IP allow-list with a JIT flip of the account default_action to Allow
before init and back to Deny on exit (if: always()). Allow-all is monotonic once propagated, so
the readiness poll is meaningful and the egress-IP roulette is eliminated. Retain the single-root
guard (target != 'all') to avoid concurrent default_action flips racing. Data stays protected by
Entra-only auth (shared keys disabled) + Storage Blob Data Contributor RBAC + TLS1.2 + CMK.

**Alternatives considered:**
- Keep single-IP allow-list, poll longer / retry init on 403 — rejected: cannot certify
  Terraform's specific connection path; still racy and non-monotonic.
- Private Endpoint + VNet/self-hosted runner — deferred to production (Option B, OQ-018): correct
  ALZ pattern, but needs runner VNet, private DNS, runner infra; out of scope for the POC turn.
- GitHub larger runners with static outbound IP range in permanent ip_rules — deferred (Option C):
  clean and deterministic but requires the larger-runners plan.

**Consequences:**
- Positive: unblocks connectivity and every subsequent root; removes a latent flaky gate on all
  CI state access.
- Negative / trade-offs: during the ~2-3 min job window the blob endpoint is reachable from any
  IP, defended by Entra token + RBAC + TLS + CMK (network layer dropped, time-boxed). Single-root
  only; target=all still relies on the documented permanent ip_allow_list prerequisite.
- Negative / residual-leak edge case: if the runner is cancelled or crashes between the Allow flip
  and job end, the `if: always()` restore cannot run, so the SA stays default_action=Allow until the
  next single-root run's restore step or a manual fix (a target=all run does NOT restore it —
  manage_runner_ip=false there). Inherent to any JIT-open design; exposure stays Entra-only + RBAC +
  TLS + CMK-defended, just no longer strictly time-boxed. Mitigation: on abnormal termination, run
  `az storage account update --default-action Deny` on the state SA, or dispatch any single-root plan
  (restores it on exit).
- Follow-ups: (1) implement the flip in _tf-root.yml (Cloud Engineer / DevSecOps — workflow lane).
  (2) OQ-018: adopt Private Endpoint + VNet runner as the production state-access model.
  (3) overwrite the leftover 0-byte connectivity state blob on next successful init (no apply ran).

---

### ADR-024: Remove the state-container WORM immutability policy (incompatible with the Terraform azurerm backend)

- **Date:** 2026-07-06
- **Section:** 10a (bootstrap / state backend)
- **Status:** Accepted (removes the immutability-policy portion of the ADR-004 bootstrap design)
- **Decision makers:** user, claude

**Context:**
Bootstrap created an `azurerm_storage_container_immutability_policy` (container-level, time-based, 7-day) on
the `tfstate` container, `locked = false`. The original intent was a WORM audit trail; the header even noted a
*locked* policy would break state, so it was left unlocked on the assumption that unlocked + blob versioning
was safe for active state. It is not. The first state operation on a **new** root after the policy existed
(`platform/connectivity` init) failed:
`Error loading state: failed to lock azure state: 409 This operation is not permitted as the blob is immutable
due to a policy (BlobImmutableDueToPolicy)`. The azurerm backend takes a **blob lease (lock)** and rewrites the
state blob on every run; a container time-based retention policy rejects that path with 409 **regardless of
versioning** (versioning only protects overwrite history, not the lease/lock). `management-groups` had worked
only because its state blob was written *before* the bootstrap re-apply added the policy; every future apply
on it would have failed too. Discovered during the first CI plan of connectivity, 2026-07-06.

**Decision:**
Remove the immutability policy entirely (it was `locked = false`, so removable — a *locked* policy would have
been unrecoverable without deleting the SA). State protection is provided by the Storage Account's existing,
backend-compatible controls: **blob versioning + 14-day blob/container soft-delete + Entra-ID-only (no
shared-key) access + CMK-at-rest**. WORM is not an appropriate protection model for a live Terraform state
container.

**Alternatives considered:**
- Keep the policy, disable Terraform state locking — rejected: removes concurrency safety on shared state; far
  more dangerous than losing WORM.
- Version-level immutability instead of container-level — rejected: still intercepts the lease/lock path and
  adds operational complexity for no real benefit on a state blob.
- A separate immutable audit copy of state (lifecycle-management export to a WORM container) — deferred: valid
  future enhancement, but out of scope and not on the live backend.

**Consequences:**
- Positive: unblocks all CI state operations (connectivity and every subsequent root); removes a latent bomb
  that would have broken existing roots' next applies.
- Negative / trade-offs: no WORM/immutability on state history — accepted; versioning + soft-delete + CMK +
  Entra-only auth remain. Lesson: never put a container-level immutability policy on a Terraform azurerm
  backend, locked or unlocked.
- Follow-ups required: none blocking. If an immutable state-audit trail is later required, do it as an
  out-of-band lifecycle export to a dedicated WORM container, not on the active backend.

---

### ADR-023: Pin ALZ library to platform/alz 2026.04.2 (bump the ref, not the module) to clear the Enforce-EncryptTransit apply break

- **Date:** 2026-07-05
- **Section:** 2 (Management Group Hierarchy) / 10 (first CI apply)
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
The first CI `apply` of `platform/management-groups` (run 28725677856) created the MG hierarchy and all 5
subscription placements, then failed hard on one policy set definition: `Enforce-EncryptTransit`. Azure
returned `400 InvalidPolicyParameters` — the initiative's `effect` parameter default of lowercase `deny` is
rejected by referenced built-in policy `1a5b4dca-0b6f-4cf5-907c-56316bc1bf3d` v9.0.0, whose allowed values
are the capitalized `Audit | Deny | Disabled`. This is version skew between the pinned ALZ library
(`platform/alz@2026.01.3`) and a built-in policy that bumped major version; `Enforce-EncryptTransit` is itself
deprecated upstream. The `alz` provider config carries the library reference (`providers.tf`), and the
provider is already at `~> 0.21.0`.

**Decision:**
Bump the ALZ **library** reference `platform/alz` from `2026.01.3` to **`2026.04.2`** and leave everything
else unchanged. `platform/alz/2026.04.0` explicitly "remov[ed] a number of deprecated and superseded policies
to avoid breaking changes like seen with `Enforce-EncryptTransit`" (Azure-Landing-Zones issues #4128 / #411);
`2026.04.2` is the latest patch of that line. avm-ptn-alz stays pinned at 0.19.1; no provider versions change.

**Alternatives considered:**
- Bump avm-ptn-alz 0.19.1 → 0.21.0 — rejected (for now): heavier change that also moves the `alz`/`azapi`
  provider floors and would need re-validation across every root; the library ref alone resolves the break.
- Local `lib` override patching only the `Enforce-EncryptTransit` effect default `deny`→`Deny` — rejected:
  keeps a deprecated initiative alive and forks us from the canonical library for a problem upstream already
  fixed by removal.
- Exclude the initiative from the Globaris architecture — rejected: silently drops an encryption-in-transit
  guardrail and masks the version-skew root cause.

**Consequences:**
- Positive: canonical, upstream-blessed fix; stays on the maintained library; unblocks the apply with a
  one-line, reviewable change.
- Negative / trade-offs: 2026.01→2026.04 is ~3 months of library drift — the re-plan will show more than the
  single initiative (deprecated policies removed, other definitions refreshed). Mitigated by re-running a CI
  **plan** to review the diff before the next apply.
- Follow-ups required: (1) CI plan review then re-apply management-groups; (2) any other root that pins
  `platform/alz` should move to 2026.04.2 in lock-step for library consistency; (3) reconsider the full
  avm-ptn-alz 0.21.0 bump as a separate, deliberate change later.

---

### ADR-022: Section 11 documentation set - greenfield DEPLOYMENT.md runbook; brownfield designed now, built later

- **Date:** 2026-07-03
- **Section:** 11 (Documentation Deliverables)
- **Status:** Accepted
- **Decision makers:** user, claude (architect)

**Context:**
The platform is a green-field build, validate-clean across all 10 roots, but undocumented for an operator to
deploy or hand off. PROMPT.md §11 names six deliverables (README, ARCHITECTURE, RUNBOOK, SECURITY, COST,
per-module terraform-docs). Two needs surfaced that §11 does not name explicitly: (1) a step-by-step,
per-landing-zone greenfield deployment runbook - the pipeline already supports per-root deploys via
`deploy.yml target=<root>`, but the ordered operator procedure is undocumented; (2) a forward path for using
this platform against a brown-field tenant (adopting existing subscriptions/resources into the ALZ
hierarchy).

**Decision:**
1. Author a dedicated **`DEPLOYMENT.md`** greenfield runbook, ordered to the `deploy.yml` `needs:` graph
   (bootstrap -> management-groups -> management -> {connectivity, security, identity} -> spokes ->
   synthetic). Each step is self-contained: what it creates, the exact `deploy.yml` inputs, its
   dependencies, the `terraform output` values carried forward, and a post-apply validation. README
   quickstart links to it; `docs/cicd-deploy-teardown.md` stays the pipeline reference (mechanics),
   DEPLOYMENT.md is the operator procedure (how to run).
2. **Brownfield is designed now, built later.** This pass produces a "Brownfield adoption approach" design
   deliverable (`docs/brownfield-adoption.md`) plus this ADR and OQ-014. It does not document brownfield
   capability as if it exists. The actual capability (state `import`, grafting existing subscriptions into
   the MG hierarchy, audit-first non-enforcing policy rollout, DNS/peering coexistence) is a future build.

**Alternatives considered:**
- Fold the deployment steps into README quickstart - rejected: makes README long, mixes overview with
  operational detail.
- Extend `docs/cicd-deploy-teardown.md` into the operator runbook - rejected: blurs pipeline-reference vs
  operator-guide.
- Write a full brownfield runbook now - rejected: risks documenting untested capability; brownfield is a
  distinct design problem deserving its own build + validation.
- Defer brownfield entirely - rejected: the user wants a credible adoption story; capturing the approach now
  is low-cost and portfolio-valuable.

**Consequences:**
- Positive: an operator can deploy the whole platform or any single LZ from a followable guide; the
  greenfield runbook doubles as the §12 acceptance path; the brownfield direction is on record without
  over-committing.
- Negative / trade-offs: DEPLOYMENT.md must stay in sync with the `deploy.yml` target list and root order;
  the brownfield design section names capability that does not yet exist and must be clearly labelled
  roadmap.
- Follow-ups: OQ-014 (brownfield unknowns); a future section/wave to build + validate brownfield adoption;
  per-module `terraform-docs` generation is its own step in the §11 sequence.

---

### ADR-021: OIDC SP least-privilege scope-down — replace Tenant Root Owner with a scoped role set (refines/supersedes ADR-006)

- **Date:** 2026-06-29
- **Section:** 12 (Hardening) — resolves OQ-008; refines [ADR-006](#adr-006-initial-oidc-sp-rbac-scope--owner-at-tenant-root-mg)
- **Status:** Accepted — **supersedes the RBAC-scope decision of ADR-006** (Owner at Tenant Root MG). ADR-006
  remains the historical record of the deliberate build-phase compromise; this ADR is the steady-state grant.
- **Decision makers:** claude (architect); user to ratify; devsecops to implement in `bootstrap/identity.tf`;
  a real CI `apply`+`destroy` of all roots is the only true validation (see Consequences).

**Context:**
ADR-006 granted the CI OIDC SP `sp-alz-poc-cicd` **Owner at the Tenant Root Management Group** (the MG named
after the tenant ID) plus **Storage Blob Data Contributor** on the state Storage Account. Owner-at-tenant-root
is the single most over-privileged grant in the platform: it lets the SP do anything in any subscription the
tenant ever contains, including `elevateAccess`-adjacent control. OQ-008 has tracked the scope-down since
build. The platform now has 10 Terraform roots driven by `deploy.yml` (apply) and `teardown.yml` (destroy,
ADR-019/ADR-020); the exact privileged operations the SP must perform are finally enumerable, so the scope-down
can be computed precisely. **Under-scoping breaks CI** (a missing grant fails `apply` or, worse, fails
`destroy` and orphans resources), so the matrix was derived by auditing every privileged operation in the repo,
not by guessing a "minimal" set.

Audit of privileged operations (grep of `azurerm_role_assignment`, `azurerm_management_group_policy_assignment`,
`azurerm_pim_eligible_role_assignment`, `azurerm_role_management_policy`, and the `avm-ptn-alz` MG call,
excluding `.terraform/`):

| Operation in IaC | Root(s) | Scope | ARM permission family |
|---|---|---|---|
| Create/move/delete the Globaris MG tree + place 5 subs (`avm-ptn-alz` `subscription_placement`) | `platform/management-groups` | Tenant Root Group → Globaris | `Microsoft.Management/managementGroups/*` (incl. `/subscriptions/write` to move subs) |
| MG-scoped **policy assignments** w/ system identities (FinOps tag initiative @ globaris; MCSB/NIST/CIS @ root MG; deny-public-net @ landingzones) | `platform/management`, `platform/security` | globaris MG, landingzones MG | `Microsoft.Authorization/policyAssignments/write,delete` |
| **Role assignments** for those policy remediation identities (`Contributor` @ globaris MG) + PIM eligible assignments + `azurerm_role_management_policy` @ globaris/landingzones MG | `platform/security`, `platform/management`, `platform/identity` (pim.tf) | globaris MG, landingzones MG | `Microsoft.Authorization/roleAssignments/write,delete`, `roleManagementPolicies/*`, `roleEligibilityScheduleRequests/*` |
| Resource create/destroy across all 5 subs (hub/firewall/DNS, LAW/automation/budgets, Entra DS/RSV, Sentinel/Defender/KV, spokes, synthetic RGs) | `platform/*`, `landing-zones/*`, `synthetic` | each of the 5 subscriptions | `*` minus `Microsoft.Authorization/*/Write,Delete` |
| **Role assignments** inside subs (guardrails MI → Contributor on synthetic RGs; red-team MI → Network Contributor / Storage Blob Data Reader / Key Vault Reader; KV/Storage data-plane roles in spokes) | `synthetic`, `landing-zones/*`, `platform/*` | RGs/resources within the 5 subs | `Microsoft.Authorization/roleAssignments/write,delete` at sub scope |
| State backend data plane (blob read/write/lease for `terraform.tfstate`) | every root (backend) | state Storage Account | `Microsoft.Storage/.../blobServices/...` data actions |

The decisive finding: **`Contributor` is insufficient** for this platform because the IaC itself creates
role assignments and policy assignments at MG and sub scope, and Contributor explicitly excludes
`Microsoft.Authorization/*/Write` and `*/Delete`. So the SP needs an authorization-management role (UAA) and a
policy-management role (Resource Policy Contributor) **in addition to** Contributor — at the scopes where those
operations occur.

**Decision:**
Delete the single `oidc_owner_tenant_root` Owner assignment and replace it with the following **scoped role
matrix**. Keep the Storage Blob Data Contributor assignment unchanged. All role names/GUIDs verified against
the Microsoft Learn built-in-roles reference (2026-06-20 revision).

| # | Built-in role (GUID) | Scope | Why it is needed | Root(s) that require it |
|---|---|---|---|---|
| 1 | **Management Group Contributor** `5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c` | Tenant Root Group (`/providers/Microsoft.Management/managementGroups/<tenantId>`) | Create/update/**delete** management groups and **move subscriptions** under them — `apply` builds the Globaris tree and places 5 subs; `destroy` deletes the tree. Contributor cannot touch `Microsoft.Management`. | `platform/management-groups` |
| 2 | **Resource Policy Contributor** `36243c78-bf99-498c-9df9-86d9f8d28608` | Globaris root MG (`/providers/Microsoft.Management/managementGroups/globaris`) | Create/**delete** MG-scoped policy & policy-set assignments (FinOps tag initiative @ globaris; MCSB/NIST/CIS @ root MG via `var.root_management_group_id`). `apply` writes them, `destroy` deletes them. | `platform/management`, `platform/security` |
| 3 | **User Access Administrator** `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | Globaris root MG | Create/**delete** role assignments at MG scope (Contributor for policy remediation identities; PIM eligible assignments + role-management policies @ globaris). `Microsoft.Authorization/*` is exactly UAA's grant; Contributor and Resource Policy Contributor both lack `roleAssignments/write`. | `platform/security`, `platform/management`, `platform/identity` |
| 4 | **User Access Administrator** `18d7d88d-…` | Landing Zones MG (`/providers/Microsoft.Management/managementGroups/landingzones`) | PIM eligible Contributor assignment + role-management policy are written at the **landingzones** MG (pim.tf); deny-public-net policy remediation identity also lands here. Separate row because UAA at globaris does **not** auto-cover a child MG for *all* operations cleanly in a destroy graph, and keeping it explicit documents the second scope. (Inheritance does flow down, so row 4 is technically redundant given row 3 inherits to children; it is retained for clarity and to survive any future re-parenting — see residual-risk note.) | `platform/identity` (pim.tf), `platform/management` |
| 5 | **Contributor** `b24988ac-6180-42a0-ab88-20f7382dd24c` | each of the **5 subscriptions** (management, connectivity, identity, security, landingzones) — via `for_each` over a static map | Create/**destroy** all resources in every sub: hub/firewall/DNS, LAW/automation/budgets, Entra DS/RSV, Sentinel/Defender/KV, spokes, synthetic RGs. Subscription-level Defender plan onboarding also runs at sub scope. | all `platform/*`, `landing-zones/*`, `synthetic` |
| 6 | **User Access Administrator** `18d7d88d-…` | each of the **5 subscriptions** — via the same `for_each` map | The IaC creates role assignments **inside** the subs (guardrails MI → Contributor on synthetic RGs; red-team MI → Network Contributor / Storage Blob Data Reader / Key Vault Reader; KV & Storage data-plane roles in spokes). Contributor cannot create these; UAA at sub scope can, and `destroy` needs `roleAssignments/delete` too. | `synthetic`, `landing-zones/*`, `platform/security`, `platform/identity` |
| 7 | **Storage Blob Data Contributor** `ba92f5b4-2d11-453d-a403-e96b0029c9fe` | state Storage Account (`azurerm_storage_account.tfstate.id`) | **Unchanged from today.** Entra-ID-only state SA (`shared_access_key_enabled = false`) requires a data-plane role for blob read/write/lease on `terraform.tfstate`. | every root (backend) |

Rows 1–6 replace Owner; row 7 is the existing assignment kept as-is. Rows 3 and 4 could be collapsed to a
single UAA at globaris (inherits to landingzones); they are kept distinct in the spec for auditability, and the
spec marks row 4 `OPTIONAL (inherited)` so devsecops may drop it without loss of function.

**Why not just Owner-at-each-sub + something for MGs?** Owner at sub scope re-introduces unrestricted
`Microsoft.Authorization/*` per sub — strictly broader than Contributor+UAA and with no functional gain, since
UAA already supplies the only Authorization actions the IaC needs. Contributor+UAA is the tighter pair.

**Alternatives considered:**
- **Keep Owner at Tenant Root MG (status quo / ADR-006)** — rejected: the entire purpose of OQ-008; tenant-root
  Owner is unbounded across all current and future subscriptions and is unacceptable steady-state.
- **Single Owner at Globaris MG (one level down from tenant root)** — rejected: still Owner (unrestricted
  `Microsoft.Authorization/*` + every resource action) across the whole hierarchy; only marginally narrower than
  tenant-root Owner and does not demonstrate least-privilege. Also the MG-create/sub-move operations and the
  tenant-root-scoped Globaris-creation need a grant **at** the Tenant Root Group, which a Globaris-scoped
  assignment does not provide.
- **Per-sub Contributor only (no UAA, no Resource Policy Contributor)** — rejected: **breaks apply** — the IaC
  creates role assignments and MG/sub policy assignments that Contributor's `NotActions`
  (`Microsoft.Authorization/*/Write`, `*/Delete`) explicitly forbid. This is the classic under-scope trap.
- **Custom role definition** carved to the exact action set — rejected for the POC: meaningfully tighter
  (e.g. UAA without `*/read` on the whole tenant), but adds a `azurerm_role_definition` to maintain and re-test
  on every new resource type. Logged as a future hardening option (G-series) rather than POC scope.
- **RBAC Administrator instead of UAA** — rejected: `Role Based Access Control Administrator`
  (`f58310d9-…`) grants only `roleAssignments/write,delete` + `*/read`, which **would** cover the role-assignment
  operations and is narrower than UAA — but it does **not** cover `roleManagementPolicies/*` /
  `roleEligibilityScheduleRequests/*` used by PIM (pim.tf), so it under-scopes the identity root. UAA is required
  for the PIM operations. (Noted as a partial-tightening option for the non-PIM scopes in a future custom-role pass.)

**Consequences:**
- Positive: removes tenant-root Owner — the SP can no longer act outside the Globaris hierarchy + the 5 named
  subs, cannot grant itself access at tenant scope (`elevateAccess` is Owner-only and now gone), and cannot
  touch subscriptions added to the tenant later unless they are explicitly placed and granted.
- Positive: every grant is now justified by a specific resource in the repo; the matrix is auditable row-by-row.
- Negative / **honest residual broad grants** (this is **not** "fully minimal"):
  - **Management Group Contributor at Tenant Root Group** is inherently powerful — it can create/delete **any**
    management group in the tenant and move subscriptions between them. It is the minimum that still lets CI
    build/destroy the MG tree, but it is a tenant-wide control-plane grant. Cannot be reduced further without a
    custom role, because MG-create must be authorized at the parent (Tenant Root Group).
  - **User Access Administrator at Globaris MG** can create **any** role assignment (including Owner) anywhere in
    the Globaris hierarchy. A compromised CI SP could self-escalate to Owner within Globaris. This is intrinsic to
    any self-deploying platform SP that manages RBAC as code; mitigated by OIDC (no stored secret), environment
    gates (ADR-019), and branch/PR-scoped federation — not by the role itself.
  - **Contributor at each of the 5 subs** is broad *within* a sub (all resource actions). It is the standard
    deploy grant and the floor for an IaC SP that owns the whole sub's resources.
  - Net reduction is **Owner-at-tenant-root → {MG Contributor @ root, scoped UAA/Policy @ 2 MGs, Contributor+UAA
    @ 5 subs}**: the blast radius drops from "the entire tenant, forever" to "the Globaris hierarchy + 5 named
    subs," and the SP loses unrestricted Owner (no `elevateAccess`, no implicit future-sub access). Real but not
    total.
- **Validation caveat:** `terraform validate`/`plan` will **not** prove sufficiency — RBAC gaps only surface as
  `AuthorizationFailed` at `apply`/`destroy` time. The only true test is a CI `target=all` **apply** followed by a
  **teardown** against a tenant where the SP holds exactly this set. Until that runs green, treat the matrix as
  *resolved-by-design, pending live validation*. If a specific operation 403s, the fix is to add the precise
  missing scope/role — do **not** fall back to Owner.
- **Graph (azuread) app permissions are out of scope and unchanged.** The Conditional Access work uses
  Microsoft Graph application permissions (`Policy.ReadWrite.ConditionalAccess`, etc.), which are **directory**
  permissions on the app registration, not ARM RBAC. OQ-008 concerns only ARM RBAC; the Graph grants stay exactly
  as they are. (Note: the current `bootstrap/identity.tf` header says "No API permissions needed" — if CA policies
  are applied by this same SP elsewhere, those Graph grants live outside bootstrap and are untouched here.)
- Follow-ups required:
  1. devsecops implements the spec in `docs/oq-008-rbac.md` into `bootstrap/identity.tf` (rows 1–6 replace
     `oidc_owner_tenant_root`; row 7 unchanged) and adds 4 new subscription-ID variables to `bootstrap/variables.tf`.
  2. code-reviewer gates: no Owner remains; `for_each` over a static map; every assignment has a justifying comment.
  3. a real `apply`+`destroy` of all 10 roots validates sufficiency; any 403 → add the precise scope, never Owner.
  4. (future, optional) custom role definitions to tighten UAA → RBAC Administrator where PIM is not used, and to
     drop tenant-wide `*/read`.

---

### ADR-020: Teardown mechanics — uniform `terraform destroy` (supersedes the ADR-019 brute-force split)

- **Date:** 2026-06-27
- **Section:** 10 (Pipeline & Tooling) — amends ADR-019
- **Status:** Accepted — amends the teardown-mechanics portion of [ADR-019](#adr-019-cicd-deploy--teardown--parameterized-deployyml--guarded-teardownyml-two-environments)
- **Decision makers:** claude (architect), code-reviewer (raised the finding)

**Context:**
Code review (finding B1) found that ADR-019 and `docs/cicd-deploy-teardown.md` §6/§9 specify the
full-environment teardown (`target=all`) as a **split** — `az group delete` brute force for the RG-bound
regional roots **plus** `terraform destroy` for the non-RG control-plane roots (`platform/management-groups`,
`platform/identity`, MG-scoped `platform/security`) — and §6 calls that split "the key correctness point
for this design," justified by LESSON 19 (`terraform destroy` gets stuck on Azure ordering quirks). **But
the implemented and validated `teardown.yml` does not do the split:** it runs `terraform destroy` for every
root uniformly, in reverse dependency order, via the reusable `_tf-root.yml`. The docs asserted behavior the
code does not implement; this had to be reconciled before merge. The reconciliation is a choice between
implementing the split in CI (Option 1) or accepting uniform `terraform destroy` and amending the docs
(Option 2).

**Decision:**
Adopt **uniform `terraform destroy`** for both single-root and `target=all` teardown — i.e. keep the
already-implemented `teardown.yml` / `_tf-root.yml` behavior — and amend the docs to match. The
`az group delete` brute-force / Terraform split is **demoted to a deferred refinement / manual fallback**
for the case where a `target=all` `terraform destroy` wedges; it lives only in the runbook (the
`include_bootstrap=true` scorched-earth path and a per-RG fallback note), not in the workflow. OQ-012
(teardown scope, `include_bootstrap=false` default), OQ-013 (two GitHub Environments), the
typed-`confirm=destroy` guard, and the reverse-order `needs:` graph are **unchanged**.

**LESSON 19 — why it does not force the split here:**
LESSON 19's stuck-`terraform destroy` failures originated in the AVD landing zone and were
**session-host VM**-driven (stopped-VM extension deletes, agent/DSC extension races, the resources that
most reliably wedge an ARM delete). **This CAF POC has no VMs.** Its workload is PaaS and control-plane
only — App Service, SQL, VNets/peerings, Key Vault, Sentinel/Defender onboarding, policy/role/MG objects —
all of which `terraform destroy` removes cleanly. Moreover the **non-RG roots** (management groups,
MG-scoped policy assignments, Entra/CA objects) are precisely what `az group delete` **cannot** touch, so
the split's "brute force handles RGs, Terraform handles control-plane" framing always needed Terraform for
the hard part anyway; using Terraform for everything is simpler and keeps state consistent for a clean
re-apply. The LESSON-19 brute-force path is retained as the documented fallback if a `target=all` run ever
does wedge in practice.

**Alternatives considered:**
- **Option 1 — implement the split in `teardown.yml`** (`az group delete` for RG-bound roots + `terraform
  destroy` for control-plane roots): rejected — it adds per-root branching and loses state fidelity (state
  must be reconciled or recreated) to solve a VM-driven failure mode this no-VM workload is not expected to
  hit; the implementation is already validated as uniform `terraform destroy`.
- **Promote brute force to the default but keep Terraform for control-plane roots only:** rejected for the
  same reason — same complexity, same state-fidelity loss, no benefit absent the VM failure mode.

**Consequences:**
- Positive: docs ↔ code are consistent (ADR-019/§6/§9 ↔ `teardown.yml` ↔ `_tf-root.yml`); one destroy
  mechanism for single-root and full reset; state stays consistent so any scope re-applies cleanly; no new
  workflow code is required to merge.
- Negative / trade-offs: if a `target=all` `terraform destroy` ever wedges on an Azure ordering quirk, the
  operator must fall back to the **manual** brute-force runbook (per-RG `az group delete` in reverse order,
  then `terraform destroy`/targeted `az` for the non-RG control-plane roots). This is documented but not
  automated. Should that prove common, re-open with a new ADR that promotes the split.
- Follow-ups required: none blocking — `teardown.yml` already implements the accepted behavior. Its header
  comment (lines 14-17) already describes uniform `terraform destroy` with brute force as "a documented
  refinement," so it is consistent with this ADR; no workflow edit is needed.

---

### ADR-019: CI/CD deploy + teardown — parameterized `deploy.yml` + guarded `teardown.yml`, two Environments

- **Date:** 2026-06-27
- **Section:** 10 (Pipeline & Tooling) — extends the bootstrap pipeline
- **Status:** Accepted — **teardown mechanics amended by [ADR-020](#adr-020-teardown-mechanics--uniform-terraform-destroy-supersedes-the-adr-019-brute-force-split)** (the `az group delete` brute-force / Terraform split below is replaced by uniform `terraform destroy`; the rest of ADR-019 — structure, scope OQ-012, two-Environment model OQ-013, OIDC federation — stands)
- **Decision makers:** user (decisions), claude (architect/design), devsecops-engineer (execution)

**Context:**
CI/CD must (1) deploy any single platform/landing-zone root individually, (2) deploy the whole
environment in dependency order, and (3) tear everything down — all via OIDC, no stored secrets,
appropriately gated. The pre-existing `apply-on-merge.yml` auto-applied on every push to `main`, which
contradicts LESSON 17 (deploys must be explicit, not merge-triggered) and the destroy-then-recreate demo
cadence. Two user decisions were outstanding: whether "tear down everything" includes the bootstrap
state backend + OIDC app (OQ-012), and the approval model (OQ-013). Full design in
[docs/cicd-deploy-teardown.md](docs/cicd-deploy-teardown.md).

**Decision:**
- **Deploy:** one parameterized `workflow_dispatch` workflow `deploy.yml` with `target`
  (choice: the 9 deployable roots + `all`) and `action` (choice: `plan` | `apply`). `target=all` runs
  the 9 backend-state roots via a `needs:` job graph in dependency order; a single `target` runs just
  that root. `apply` jobs gate on the `production` GitHub Environment.
- **Teardown:** a separate guarded workflow `teardown.yml` (`workflow_dispatch`) — not a third `action`
  on deploy — because destroy needs stronger/different guards and reverse ordering. Inputs: `confirm`
  (typed; the run hard-fails unless it equals `destroy`) and `include_bootstrap` (boolean, default
  `false`). Destroys in reverse dependency order, using `az group delete` brute force for the RG-bound
  regional roots **and** `terraform destroy` for the control-plane/tenant roots (`management-groups`,
  `identity`, MG-scoped `security`), which are not resource groups (LESSON 19). **[Amended by ADR-020:
  the brute-force / Terraform split is replaced by uniform `terraform destroy` for all roots; the
  split is now a deferred manual fallback.]**
- **Teardown scope (OQ-012):** workload + platform only by default. `include_bootstrap` **defaults to
  `false`** so the state backend (state SA, CMK KV) and the OIDC app/SP/federation survive a full reset
  and redeploy is immediate. `true` is full scorched-earth (decommission) and additionally needs a
  documented manual `az ad app delete` (the SP cannot delete its own Entra app via ARM Owner).
- **Approval model (OQ-013):** TWO GitHub Environments — `production` gates apply in `deploy.yml`;
  `production-destroy` gates teardown in `teardown.yml` — each with a required reviewer, plus the typed
  `confirm=destroy` guard on teardown. This keeps destroy approval a separate, more deliberate gate.
- **Retire** `apply-on-merge.yml` (deleted; deploys are now explicit — LESSON 17). Keep
  `plan-on-pr.yml` (always-on PR plan) and `validate.yml` (static gate).
- **OIDC federation:** two new federated credentials are required for the gated jobs (their OIDC `sub`
  becomes `repo:<org>/<repo>:environment:<env>`): subjects `...:environment:production` and
  `...:environment:production-destroy` added to `azuread_application.oidc` in `bootstrap/identity.tf`.
  **Bootstrap must be re-applied** for the gated jobs to authenticate.

**Alternatives considered:**
- Third `action=destroy` value on `deploy.yml` — rejected: destroy needs a different gate, reverse
  ordering, and a typed confirm; a separate file makes the blast radius obvious in the Actions UI.
- A `matrix` for `target=all` — rejected: a matrix cannot express the partial cross-root order
  (spokes wait for connectivity + security); a `needs:` graph can, and preserves legitimate parallelism.
- `terraform destroy` for the full reset — rejected: LESSON 19 documents it reliably gets stuck on Azure
  ordering quirks; `az group delete` brute force is the proven demo-reset path for RG-bound roots.
  **[Reversed by ADR-020: LESSON 19's stuck-destroy failures were VM-driven; this no-VM PaaS/control-plane
  POC destroys cleanly with uniform `terraform destroy`, so that is now the accepted full-reset path.]**
- Single Environment for both apply and destroy — rejected: destroy warrants a tighter, separate
  reviewer gate (OQ-013).

**Consequences:**
- Positive: explicit, auditable deploys; one-root and whole-environment paths from one entrypoint;
  destroy is hard to trigger accidentally (typed confirm + dedicated environment); default teardown
  keeps the backend so redeploy needs no re-bootstrap or GitHub-Variable re-wiring.
- Negative / trade-offs: relies on ADR-006's broad SP scope (Owner at Tenant Root MG) for both apply and
  destroy (tracked under OQ-008); `az group delete` brute force loses state fidelity for the reset roots
  (acceptable for a demo — state is recreated greenfield-safe on next apply); `include_bootstrap=true`
  needs a manual `az ad app delete` and (until LESSON 18 deterministic naming lands) a manual
  `poc.backend.hcl` update.
- Follow-ups required: re-apply `bootstrap/` to register the two environment federated credentials;
  create the `production` and `production-destroy` Environments with reviewers; cloud-engineer to migrate
  bootstrap to deterministic (sub-ID-derived) state-backend naming (LESSON 18) before relying on
  `include_bootstrap=true`.

---

### ADR-018: OQ-011 remediation — reconcile module calls to pinned AVM schemas, commit lock files per root, add a CI `terraform validate` gate

- **Date:** 2026-06-27
- **Section:** Cross-cutting (infra hygiene; touches Sections 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** claude (architect), cloud-engineer (execution)

**Context:**
Every section was marked 🟢 Complete in the WORKLOG, but those statuses **predated any real
`terraform validate`** — the work log repeatedly recorded "validate NOT RUN" (no remote-state/firewalled
backend creds during build, and no committed `.terraform.lock.hcl`, so a clean `init` re-resolved modules
to whatever the registry served). The 2026-06-26 remediation pass ran `terraform init -backend=false` +
`validate` on all 10 roots and found schema drift: several calls were written against a module build that
differed from the published pinned tag. Concretely, across the tree the following were stale against the
**pinned** AVM schemas:
- `avm-res-network-virtualnetwork` v0.17.1 — VNet sub-module is `parent_id` (RG resource ID), not
  `resource_group_name` (all 3 spokes + the connectivity hub path).
- `avm-ptn-network-private-link-private-dns-zones` v0.23.1 — `parent_id`, no `resource_group_creation_enabled`.
- `avm-ptn-alz` v0.19.1 — `subscription_placement` object shape `{ subscription_id, management_group_name }`.
- `avm-res-keyvault-vault` — outputs are `name`/`uri`, not a `resource` object.
- `azurerm_private_dns_zone_group` — **not a provider resource type**; the canonical pattern is the nested
  `private_dns_zone_group {}` block on `azurerm_private_endpoint`.
- `azurerm_sentinel_watchlist` — `log_analytics_workspace_id` (azurerm v4), not `workspace_id`.

**Decision:**
Adopt **Option B** (reconcile each call to its already-pinned module/provider schema — *no version bumps*)
as the remediation standard, plus **Option A** (generate and **commit** a `.terraform.lock.hcl` for every
init-able root) so module/provider builds are reproducible and `validate`/`plan` are deterministic going
forward. Lock files for `platform/*` and `landing-zones/*` are now committed; `bootstrap/.terraform.lock.hcl`
stays git-ignored (ADR-005 — one-time local apply). The single exception requiring a version action is the
connectivity azapi pin, handled separately in **ADR-017**. A CI `terraform validate` gate (run
`init -backend=false` + `validate` per root, `fmt -check -recursive`) is added so a 🟢 status can never
again outrun an actual validate; the gate is the new definition of "Complete" for any IaC section.

**Alternatives considered:**
- Bump module versions to match the as-written calls (Option C) — rejected: larger, cross-root change that
  re-opens verification on every consumed input/output; the pinned versions are fine, only the *calls* drifted.
- Leave roots unlocked and rely on registry "latest 0.x" — rejected: that is exactly the drift that let
  "Complete" sections fail a first real validate; non-reproducible by construction.

**Consequences:**
- Positive: 9/10 roots now `init -backend=false` + `validate` clean with committed locks; drift is frozen;
  CI gate makes regressions visible at PR time, not demo time. No behavioral change, no apply.
- Negative / trade-offs: committed lock files must be refreshed deliberately (`terraform init -upgrade`) on
  any future intentional uplift; the CI gate adds ~1–2 min per root to PR runs.
- Follow-ups: cloud-engineer applies ADR-017 (azapi pin) to make connectivity the 10th clean root and commit
  its lock; devsecops-engineer wires the `validate` gate into `.github/workflows/`; reviewer treats a green
  validate gate as a merge precondition. The pre-existing uncommitted G4 files
  (`landing-zones/corp-a1/backup.tf` + corp-a1 outputs/variables) validate clean and should be committed with
  this pass.

---

### ADR-017: Connectivity `azapi` provider pin aligned to `~> 2.5` (module requirement)

- **Date:** 2026-06-27
- **Section:** 8 — Standard Platform Components (Connectivity sub)
- **Status:** Accepted
- **Decision makers:** claude (architect); cloud-engineer applies

**Context:**
`platform/connectivity/providers.tf:19` pins `azapi = "~> 2.4.0"`. A **three-component** `~>` pin means
`>= 2.4.0, < 2.5.0`. The connectivity root composes `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet`
v0.17.1 and `Azure/avm-ptn-network-private-link-private-dns-zones` v0.23.1. Verified at the pinned tags
(2026-06-27): both top-level modules pin `azapi ~> 2.4` (two-component → `>= 2.4.0, < 3.0.0`), but their
nested sub-modules — notably the `subnet` sub-module of `avm-res-network-virtualnetwork` v0.17.1 (consumed
by the hub-and-spoke module) — pin **`azapi ~> 2.5`** (two-component → `>= 2.5.0, < 3.0.0`). The root's
`>= 2.4.0, < 2.5.0` and the sub-modules' `>= 2.5.0` are **disjoint on the lower bound**, so no azapi
version satisfies the whole graph and `terraform init` aborts before producing a lock file. (NOTE: the
remediation note described the sub-module ceiling as `< 2.6.0`; that was a mis-read — a two-component
`~> 2.5` has no 2.6 ceiling. The conflict is purely the root's `< 2.5.0` lower-bound ceiling. The fix is
the same either way.) azapi's latest is 2.10.0 (May 2026), so the 2.5.x line is well-established and stable.

**Decision:**
Bump the connectivity root pin from `azapi = "~> 2.4.0"` to **`azapi = "~> 2.5"`** (i.e. `>= 2.5.0, < 3.0.0`).
This aligns the root with the floor its own sub-modules already require and removes the disjoint constraint;
`init` then selects the highest 2.x azapi satisfying every node (currently 2.10.0) and writes a lock file.
No upper-bound conflict is introduced: every azapi constraint in the graph (`~> 2.4`, `~> 2.5`) intersects
`~> 2.5` at `>= 2.5.0`. The other root providers are independent of azapi and unaffected — `azurerm
~> 4.71.0` (matches modules' `~> 4.0`), `modtm ~> 0.3.0`, `random ~> 3.8.1`. This is the minimal, lowest-risk
resolution.

**Alternatives considered:**
- Pin `azapi = "~> 2.5.0"` (three-component, `>= 2.5.0, < 2.6.0`) — rejected: needlessly tight; would pin
  off 2.6+ while the modules accept the whole 2.x line and the rest of the repo uses two-component azapi
  pins. `~> 2.5` matches module convention and leaves room for in-band patch/minor uplifts.
- Bump the hub-and-spoke / private-dns module versions instead — rejected: a far larger change (re-verify
  every input/output of two pattern modules and their consumed sub-modules) to solve a one-line provider
  pin; the pinned module versions are correct, only the root's provider floor was stale.
- Downgrade the modules to a build that needs only `~> 2.4` — rejected: no such v0.17.1/v0.23.1 build; would
  mean abandoning the pinned, verified versions and is strictly worse.

**Consequences:**
- Positive: connectivity `init -backend=false` should succeed and produce a committable lock file, making it
  the 10th clean-validating root and closing the last OQ-011 item. One-line change, no resource/behavior
  change.
- Negative / trade-offs: a newer azapi (2.10.x) will be locked; azapi 2.x is API-stable (the 2.0 breaking
  change is long past), so risk is low. The committed lock fixes the exact version, so the bump is explicit
  and auditable.
- Follow-ups: cloud-engineer edits `providers.tf:19`, re-runs `init -backend=false` + `validate`, and commits
  `platform/connectivity/.terraform.lock.hcl`. If validate surfaces *further* schema drift in `dns.tf` after
  init finally resolves, treat it under ADR-018 (same reconcile-to-pinned-schema rule) — see task 4 note.

---

### ADR-016: Gap-closure execution sequence (G1–G6) — plan of record

- **Date:** 2026-06-25
- **Section:** Cross-cutting (slots into Sections 8, 9, 11, 12)
- **Status:** Accepted
- **Decision makers:** claude (architect); user to approve cost OQs (OQ-009, OQ-010)

**Context:**
The 2026-06-25 fidelity analysis (ARCHITECTURE.md "ALZ Reference Architecture Fidelity Map") identified
six gaps (G1–G6) vs the Microsoft ALZ Hub & Spoke reference (diagram 2026-04-02). The user directed that
**all gaps be closed**, sequenced by the architect, then handed to the engineering roles under the
reviewer gate. ADR-010…ADR-015 below record the per-gap close/deviation calls; this ADR records the
ordering and the hand-off contract.

**Decision:**
Close G1, G2, G4, G6 outright. Close G3 (DDoS) and G5 (Sandbox/Online subs) **conditionally on user
cost approval** (OQ-009, OQ-010); if not approved, both remain *documented deviations* with the
implementation pre-staged behind a disabled feature flag. Execute in five waves with explicit
dependencies, detailed in `docs/gap-closure-plan.md`:

1. **Wave 1 — G6 Bastion** (connectivity hub; flip existing module flag). No new module.
2. **Wave 2 — G4 corp-a1 backup vault** (parity with corp-a2). Independent; can run parallel to Wave 1.
3. **Wave 3 — G1 Identity subscription domain services** (Entra Domain Services — see ADR-010). New
   `platform/identity/domain-services.tf` + identity VNet + RSV. Depends on connectivity hub (peering)
   and reverses OQ-002.
4. **Wave 4 — G2 Compliant VM template** (Compute Gallery + image definition + Guest Configuration +
   backup policy + tag enforcement). Depends on G4-pattern backup vault precedent; consumes the FinOps
   tag initiative (ADR-008).
5. **Wave 5 — G3 DDoS (conditional) + G5 Sandbox/Online subs (conditional)**. Gated on OQ-009/OQ-010.

**Alternatives considered:**
- Close everything in one mega-session — rejected: violates the one-section-per-session rule and the
  reviewer gate; G1 and G2 alone are each a full section's worth of IaC.
- Defer G1 again — rejected: the user explicitly reversed the deferral; G1 is the only platform pillar
  with zero resources and is the highest-value gap to close.

**Consequences:**
- Positive: an ordered, dependency-aware backlog the cloud-engineer/devsecops-engineer execute one wave
  per session; each wave is independently reviewable and revertible.
- Negative / trade-offs: full closure spans ~5 build sessions plus review; idle cost rises (see per-ADR
  deltas — roughly +$130–190/mo for G1+G2+G4+G6, before the conditional G3/G5).
- Follow-ups: OQ-009 (DDoS cost), OQ-010 (real Sandbox/Online subs) must be answered before Wave 5.

---

### ADR-015: G6 — Deploy Azure Bastion in the primary hub (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (connectivity)
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
The reference diagram places Azure Bastion in the connectivity hub for secure management-plane access to
VMs with no public IP. The repo sets `bastion = false` in both hubs. Closing G1 (Entra DS) and G2 (image
build VM) introduces VMs that need RDP/SSH without public exposure, so Bastion becomes load-bearing.

**Decision:**
CLOSE. Enable Bastion in the **primary** hub only via the existing
`avm-ptn-alz-connectivity-hub-and-spoke-vnet` module's `enabled_resources.bastion = true` plus a
`bastion` config block (Standard SKU, dedicated `AzureBastionSubnet` /26). Secondary hub stays
`bastion = false` to control idle cost; DR-region VM access in a drill routes via the primary hub or a
just-in-time portal Bastion. No new module — this is a config change to a module already in state.

**[Amended 2026-06-27 — on-demand cost posture]:** per the gap-closure cost decision (Entra DS +
on-demand Bastion), Bastion is gated behind **`var.enable_bastion` (default `false`)**, not always-on.
Idle cost is therefore **$0**; operators set `enable_bastion = true` + apply (via `deploy.yml`) to bring
it up on demand, and `false` + apply to remove it. The "Negative" consequence below is superseded.

**Alternatives considered:**
- Bastion in both hubs — rejected: doubles idle cost (~$280/mo) for a POC; secondary-region interactive
  access is rare and can be served by the primary or temporary deployment.
- Native `azurerm_bastion_host` outside the module — rejected: the pattern module owns the hub VNet;
  using its native toggle keeps subnet/IP wiring inside one module and avoids a split-brain VNet.
- Developer SKU Bastion — rejected: does not support the per-VNet peering reach needed across spokes.

**Consequences:**
- Positive: secure management access to Entra DS DCs and the image-build VM with no public IPs; closes
  the reference gap with zero new modules.
- Negative: ~$140/mo idle for the Standard SKU instance + its public IP.
- Follow-ups: cloud-engineer adds the `AzureBastionSubnet` prefix to the hub subnet locals; verify the
  module input shape for `bastion` against v0.17.1 before writing.

---

### ADR-014: G5 — Keep Sandbox + Online collapsed into the shared LZ sub (DEVIATION, conditional close)

- **Date:** 2026-06-25
- **Section:** 9 / 12
- **Status:** Accepted (as deviation) — conditional close tracked in OQ-010
- **Decision makers:** claude (recommends keep-as-deviation); user may override via OQ-010

**Context:**
ADR-003 collapsed the Sandbox and Online archetypes into the single shared Landing Zones subscription to
keep the POC within Visual Studio benefit limits (idle ~$80–150/mo). The reference diagram shows Sandbox
and Online as **separate subscriptions**. The Sandbox and Online **management-group nodes already exist**;
only the subscription boundary is simulated.

**Decision:**
Recommend KEEP-AS-DEVIATION for the POC. Provisioning two more subscriptions is a billing/tenant action
that (a) cannot be done in Terraform without the subscription-vending pattern and EA/MCA billing-account
privileges the POC does not have, and (b) adds no new *architectural* construct — the MG nodes, policy
inheritance, and RG segmentation already demonstrate the boundary. This is a **subscription-count**
fidelity gap, not a capability gap. The user wants all gaps addressed: if faithful multi-sub is required,
OQ-010 captures the override — moving `online-p1` (and a sandbox placeholder) into real subscriptions via
`azurerm_subscription` association under the existing MG nodes once two more sub IDs are supplied.

**Alternatives considered:**
- Provision two real subs now via `azurerm-subscription`/EA vending — rejected for POC: requires billing
  scope the VS-benefit account lacks; risks cost and provisioning failure mid-build.
- Use `avm-ptn-lz-vending` to create the subscriptions — valid production path; deferred to OQ-010
  because it presumes an EA/MCA enrollment account ID the POC does not have.

**Consequences:**
- Positive: no extra idle cost; MG-level boundary already demonstrable; ADR-003 stays coherent.
- Negative: subscription count (5) is below the reference's 7+; documented as a known, intentional POC
  scope limit. Reviewer must accept the deviation explicitly.
- Follow-ups: if OQ-010 is answered "provision real subs," this ADR is superseded and Wave 5 binds
  `online-p1` + a sandbox RG-set to two new subscription IDs under the existing Online/Sandbox MG nodes.

---

### ADR-013: G3 — Azure DDoS Network Protection plan (conditional close, cost-gated)

- **Date:** 2026-06-25
- **Section:** 8 (connectivity)
- **Status:** Accepted (pre-staged, disabled) — conditional close tracked in OQ-009
- **Decision makers:** claude (recommends pre-stage disabled); user decides via OQ-009

**Context:**
The reference diagram shows an Azure DDoS Network Protection plan attached to the hub VNet (protecting
public-facing workloads, e.g. online-p1's AFD/App Gateway). DDoS Network Protection is **~$2,944/mo flat**
(plan covers up to 100 public IPs). The POC's whole-platform idle target is ~$80–150/mo (ADR-003); DDoS
alone is ~20–35x the entire rest of the platform.

**Decision:**
CLOSE *conditionally*. The cloud-engineer writes the construct now — `Azure/avm-res-network-ddosprotectionplan/azurerm`
v0.3.0 (verified on registry 2026-06-25) creating the plan, plus wiring `ddos_protection_plan` onto the
hub VNet and online-p1 spoke VNet — but **behind `var.enable_ddos_protection` defaulting to `false`**.
With the flag false the plan is not created and the repo carries no idle DDoS cost; the documented
deviation in ARCHITECTURE.md is replaced by a one-line flag flip. The user answers OQ-009 to decide
whether to set the flag `true` for any live/faithful-posture demo. This satisfies "all gaps addressed"
(the capability is built and one toggle away) without forcing ~$3k/mo on a portfolio POC.

**Alternatives considered:**
- Deploy DDoS unconditionally — rejected: ~$2,944/mo is indefensible for a portfolio POC; the user
  should make this call, not the architect.
- Leave as a pure documented deviation with no code — rejected: the user wants gaps *addressed*; a
  flag-gated, registry-verified construct is "addressed and one toggle away," strictly better than a doc
  note. (DDoS IP Protection per-IP tier was considered as a cheaper alternative but does not match the
  reference's network-tier plan and is per-IP billed — out of scope; noted in OQ-009.)

**Consequences:**
- Positive: faithful construct exists, version-pinned, reviewer-approved, zero idle cost while disabled.
- Negative: not *active* by default; a live demo of DDoS telemetry requires the flag + the monthly cost.
- Follow-ups: OQ-009 — user decides default flag state and whether to fund DDoS for any recorded demo.

---

### ADR-012: G4 — Add a corp-a1 backup vault (Recovery Services Vault) for parity (CLOSE)

- **Date:** 2026-06-25
- **Section:** 9 (landing zones)
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
corp-a2 has a Recovery Services Vault (`avm-res-recoveryservices-vault` v1.1.3, GeoRedundant). corp-a1 —
the **primary** workload spoke — has none. The reference shows backup in every landing-zone subscription.
This is an availability/asymmetry gap: the primary workload is currently less protected than its DR pair.

**Decision:**
CLOSE. Add an RSV to corp-a1's `rg-corp-a1-shared` using the **same module + pinned version already in
state for corp-a2** (`Azure/avm-res-recoveryservices-vault/azurerm` v1.1.3 — keep the existing pin for
parity and to avoid a cross-spoke version skew; latest is 1.1.11 and can be a separate uplift later).
Storage mode `ZoneRedundant` for corp-a1 (primary stays in-region for RPO; corp-a2 keeps GeoRedundant for
cross-region DR) and a default Azure Backup policy ready for the synthetic-workload VM / future IaaS.

**Alternatives considered:**
- Bump both spokes to v1.1.11 in the same change — rejected: version uplift is a separate concern from
  closing the parity gap; bundling risks a corp-a2 regression in a gap-closure change. Track uplift
  separately.
- GeoRedundant for corp-a1 too — rejected: corp-a1 is the primary; GRS doubles storage egress cost for a
  POC with no cross-region restore requirement on the primary. ZoneRedundant is the cost-right default.

**Consequences:**
- Positive: backup parity across both corp spokes; primary workload now protected; matches reference.
- Negative: ~$5–10/mo (vault is free; cost is protected-instance + storage once items are enrolled —
  near-zero until the synthetic VM is backed up).
- Follow-ups: G2's backup policy and the synthetic §13.4 VM can enrol into this vault later.

---

### ADR-011: G2 — Compliant VM template via Azure Compute Gallery + Guest Configuration (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (new platform component) / 12
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
Design area **G** of the reference calls for a "compliant VM template": a golden image in a shared gallery,
in-guest configuration (DSC / Guest Configuration), a backup policy, and required-tag enforcement. The repo
has **no** gallery, image definition, or guest-configuration construct anywhere. This is a genuine
capability gap, not just a count/cost gap.

**Decision:**
CLOSE. Compose three layers in a new `platform/management/compute-gallery.tf` (gallery is a shared platform
asset, lives in the Management subscription alongside the platform LAW/Automation):

1. **Azure Compute Gallery + image definition** — `Azure/avm-res-compute-gallery/azurerm` **v0.2.0**
   (verified on registry 2026-06-25; the module creates the gallery *and* image definitions via its
   `shared_image_definitions` map input). Define one Linux (Ubuntu 24.04 gen2) image definition to match
   the synthetic workload's distro; image **versions** are produced out-of-band by an Azure Image Builder /
   packer pipeline (documented as the build path; the POC ships the definition + a "bring your own version"
   note rather than running a full bake, to avoid a long-running build dependency).
2. **Guest Configuration assignment** — assign the built-in Azure Policy initiative *"\[Preview\]: Windows/
   Linux machines should meet requirements for the Azure compute security baseline"* (Guest Configuration /
   machineConfiguration) at the Landing Zones MG so any VM (synthetic §13.4 VM, future IaaS) is audited for
   baseline compliance. DEVIATION: full DSC authoring is out of POC scope; the built-in machineConfiguration
   audit initiative is the realistic, maintainable substitute and produces the same "in-guest compliance"
   signal.
3. **Backup policy + required-tag enforcement** — reuse the FinOps tag initiative (ADR-008) already at the
   Globaris root for tag enforcement; the backup policy is provided by the G4 RSV (ADR-012). No new tag
   policy authored.

**Alternatives considered:**
- Hand-author a full DSC configuration + Image Builder bake in-repo — rejected for POC: Image Builder runs
  take 30–60 min and need a build identity + staging RG; the gallery + definition + built-in
  machineConfiguration initiative demonstrates the design area without a brittle long-running bake.
- `avm-ptn-*` for image building — none confirmed published on registry (only the resource-level gallery
  module exists); per CLAUDE.md rule 5 we do not depend on unverified pattern modules.

**Consequences:**
- Positive: design area G is represented end-to-end (gallery, definition, in-guest baseline audit, backup,
  tag enforcement) using one verified AVM module + built-in policy; no custom policy JSON.
- Negative: no actual image *version* is baked by default — the gallery ships empty of versions until a
  packer/Image Builder run populates it. Documented as a follow-up, not a gap in the construct itself.
- Follow-ups: optional §13.x — add an Azure Image Builder template that bakes a version into the definition;
  enrol the baked image's VMs into the G4/corp-a1 RSV.

---

### ADR-010: G1 identity mode — Microsoft Entra Domain Services (reverses OQ-002 "none") (CLOSE)

- **Date:** 2026-06-25
- **Section:** 8 (Identity subscription)
- **Status:** Accepted — supersedes the OQ-002 "none" resolution (2026-05-14)
- **Decision makers:** claude (architect) — user had deferred the DCs-vs-Entra-DS choice to the architect

**Context:**
G1 is the highest-value gap: the Identity subscription is the only platform pillar with zero resources
(`identity_mode = "none"`, OQ-002). The reference shows the Identity sub hosting either self-managed AD DS
domain controllers on IaaS **or** Microsoft Entra Domain Services, plus an identity VNet and a backup vault.
The user deferred the DCs-vs-Entra-DS decision to the architect and flagged the POC as cost-sensitive
(~$80–150/mo idle target). Verified 2026-06-25: current 2026 CAF identity guidance favours an
"AD-minimization", cloud-first posture — managed **Microsoft Entra Domain Services** over self-managed DCs
when AD DS capability is needed. No AVM module exists for Entra DS (registry 404 for
`avm-res-aad-domainservice`); the native `azurerm_active_directory_domain_service` resource is current
(API 2021-05-01, not deprecated; requires a one-time DS service-principal pre-step in the tenant).

**Decision:**
CLOSE with **Microsoft Entra Domain Services (managed)** as `identity_mode = "entra-ds"`. Reverses the
OQ-002 "none" resolution. The cloud-engineer builds, in `platform/identity/` (which today holds only the
CA/PIM policies):

- An **identity VNet** via `Azure/avm-res-network-virtualnetwork/azurerm` (repo pin **0.17.1**, the version
  already in state across spokes) with a dedicated Entra DS subnet + NSG carrying the
  Microsoft-mandated inbound rules, peered to the **primary hub** (ADR-009 hub).
- A native `azurerm_active_directory_domain_service` (no AVM module exists — `# DEVIATION:` documented),
  **Standard SKU** (single replica set; lowest cost ~$110/mo), `domain_name` from a new
  `var.identity_domain_name` (POC default `aadds.<orgprefix>.onmicrosoft.com` — ties to OQ-003).
- A **Recovery Services Vault** for the identity VNet's future DC/management VMs, same module/pin as G4.

**Alternatives considered:**
- Two B2s DCs on IaaS (`identity_mode = "ad-ds"`, ~$60/mo) — rejected as the default: cheaper, but
  contradicts 2026 CAF AD-minimization guidance, adds OS-patching/DC-promotion/replication management the
  POC would have to demo and maintain, and Entra DS better showcases a modern managed-identity posture.
  Kept as a documented *alternative mode* (the `var.identity_mode` toggle is retained so an operator can
  select `ad-ds` if a self-managed-DC demo is wanted) — but **not** the shipped default.
- Keep `none` — rejected: the user reversed the deferral and wants the gap closed.

**Consequences:**
- Positive: closes the top gap with the CAF-recommended managed option; less to manage/demo than DCs;
  identity VNet + RSV complete the pillar to match the reference. Cheaper than the assumed Entra DS price
  in OQ-002 if Standard SKU is used (~$110/mo vs the DCs' ~$60/mo — the delta funds "no DC management").
- Negative: ~$110/mo idle (Entra DS Standard) — the single biggest line in the gap-closure cost. Requires a
  one-time **manual** tenant pre-step (create the "Domain Controller Services" service principal +
  an `AAD DC Administrators` group) that Terraform cannot do — documented as an operator prerequisite.
  Entra DS only supports User-forest mode (no resource-forest) — acceptable for POC.
- Follow-ups: OQ-002 resolved to `entra-ds`; OQ-003 (domain name) becomes relevant — needs the POC domain.
  Confirm the `azurerm_active_directory_domain_service` argument shape against the provider pinned in
  `platform/identity` before writing; mark `# UNVERIFIED:` if the pin predates the resource's current schema.

---

### ADR-009: Firewall Policy hierarchy — independent policies per hub (no shared parent for POC)

- **Date:** 2026-05-21
- **Section:** 3 — Multi-Region DR Topology
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
PROMPT.md §3 requires a shared Azure Firewall Policy with a parent policy in the primary hub and a child policy in the secondary hub (inheriting via `base_policy_id`). The hub VNets are deployed via `Azure/avm-ptn-alz-connectivity-hub-and-spoke-vnet/azurerm` v0.17.1, which creates firewall policies internally and does not expose a `base_policy_id` input in the `firewall_policy` configuration block.

**Decision:**
Each hub has an independent Azure Firewall Premium policy with identical configuration (IDPS Alert mode). A shared parent policy is not implemented for the POC. This is documented as a DEVIATION in `platform/connectivity/dr.tf`.

**Alternatives considered:**
- Fork the hub module to expose `base_policy_id` — rejected; forking AVM modules breaks the upgrade path and adds maintenance burden for a POC.
- Migrate firewall policies to standalone `azurerm_firewall_policy` resources outside the module, then link via `base_policy_id` — valid production path; deferred to Section 12 hardening because it requires refactoring the hub module invocation.
- Create a disconnected parent policy resource — rejected; dead code that isn't wired to anything is misleading in a demo context.

**Consequences:**
- Positive: Hub module stays unmodified; upgrade path to newer AVM versions preserved.
- Negative: Rule changes must be applied to both hub policies independently until production path is taken.
- Follow-ups: Section 12 should migrate firewall policies out of the hub module and establish the parent/child hierarchy.

---

### ADR-008: Tag governance via built-in Azure Policy Modify initiatives (no AVM, no custom policy JSON)

- **Date:** 2026-05-12
- **Section:** 7
- **Status:** Accepted
- **Decision makers:** claude

**Context:**
Section 7 requires Modify + DINE tag policies on every resource group for 8 mandatory tags, with tag inheritance to child resources. Options were: (A) custom policy definition JSON per tag, (B) built-in Azure Policy definitions composed into a custom initiative, or (C) AVM module.

**Decision:**
Use two built-in Azure Policy definitions composed into a custom `azurerm_policy_set_definition` via `dynamic "policy_definition_reference"` blocks:

- `d157c373-a6c4-483d-aaad-570756956268` — "Add or replace a tag on resource groups" (Modify, RG scope)
- `cd3aa116-8754-49c9-a813-ad46512ece54` — "Inherit a tag from the resource group" (Modify, resource scope)

Both IDs confirmed on azadvertizer.net 2026-05-12. The initiative is scoped to the `globaris` root MG and assigned there with a system-assigned managed identity. The remediation identity receives `Contributor` at the root MG scope.

**Alternatives considered:**

- Custom policy definition JSON per tag — rejected: 16 custom policy definitions (8 tags × 2 effects) creates excessive state surface and maintenance overhead for a POC.
- AVM module for policy — rejected: no `avm-res-authorization-policysetdefinition` module confirmed on registry.terraform.io 2026-05-12.
- `ea3f2387-9b95-492a-a190-fcdc54f7b070` ("Inherit a tag from the resource group if missing") instead of `cd3aa116` — rejected: the "if missing" variant does not overwrite existing incorrect tag values; `cd3aa116` always enforces the correct value from the parent RG.

**Consequences:**

- Positive: no custom policy JSON to maintain; built-in policies are kept current by Microsoft.
- Negative: `CreatedDate` default value is static ("1970-01-01") — the Modify effect cannot use a dynamic `utcNow()` expression. Teams must set `CreatedDate` manually on their RGs.
- Follow-ups: Section 9 landing zone modules should set `CreatedDate` on their RGs at creation time via the `tags` block.

---

### ADR-007: Custom Globaris root management group — override standard ALZ root id

- **Date:** 2026-05-06
- **Section:** 2
- **Status:** Accepted
- **Decision makers:** claude (structural), user (naming)

**Context:**
The `avm-ptn-alz` module loads architecture definitions from the ALZ Library. The standard `alz` architecture uses root MG id `"alz"` and display name `"Azure Landing Zones"`. The POC uses `"Globaris"` as the organisation name, requiring a custom root MG id.

**Decision:**
Create `platform/management-groups/lib/globaris.alz_architecture_definition.json` — a custom architecture definition that retains all standard ALZ archetypes (root, platform, landing_zones, management, connectivity, identity, security, corp, online, decommissioned, sandbox) but sets root id `"globaris"` and display name `"Globaris"`. The custom lib directory is passed as a second `library_references` entry to the `alz` provider.

**Alternatives considered:**
- Use standard `alz` root MG id — rejected: produces `alz` in the Azure portal hierarchy, inconsistent with organisation branding and the expected demo narrative.
- Rename via `azurerm_management_group` rename — rejected: the AVM module owns the lifecycle; external rename would create a state conflict.

**Consequences:**
- Positive: hierarchy displays as "Globaris" in Azure portal; consistent with all naming in `poc.tfvars` and `ARCHITECTURE.md`.
- Negative: a custom lib file must be maintained alongside future ALZ Library updates.
- Follow-ups: when upgrading ALZ Library ref, re-validate that standard archetype names have not changed.

---

### ADR-006: Initial OIDC SP RBAC scope — Owner at Tenant Root MG

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted (temporary; see OQ-008 for scope-down at Section 12)
- **Decision makers:** user

**Context:**
The OIDC service principal must create Management Groups, Policy assignments, role assignments, and resources across all 5 subscriptions. The granular-minimum role set cannot be computed until all sections are built.

**Decision:**
Assign `Owner` to the OIDC SP at Tenant Root Management Group scope for the duration of the POC build (Sections 10a–12). At Section 12, replace with the principle-of-least-privilege role set tracked in OQ-008.

**Alternatives considered:**

- Per-subscription Contributor + scoped UAA — rejected for now: cannot enumerate required role assignments until all resource types are known.
- Owner at subscription level per sub — rejected: Management Group operations (Section 2) require tenant-root scope.

**Consequences:**

- Positive: zero RBAC-related CI failures during build phases 2–11.
- Negative: over-privileged SP; mitigated by POC being a dedicated demo tenant and OQ-008 tracking remediation.
- Follow-ups: OQ-008 must be resolved at Section 12.

---

### ADR-005: Bootstrap layer Terraform state — local, never committed

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user

**Context:**
The bootstrap layer creates the Azure Storage Account used as remote state backend by all other layers — a chicken-and-egg situation.

**Decision:**
Bootstrap uses local Terraform state (`bootstrap/terraform.tfstate`), gitignored and never committed. Bootstrap is a one-time manual `terraform apply`. After apply, outputs are pasted into `envs/poc.backend.hcl` for all subsequent root modules.

**Alternatives considered:**

- Local state committed to `bootstrap-state/` — rejected: state files can contain sensitive values; git history is permanent.
- Azure CLI imperative bootstrap — rejected: defeats "everything as code" and creates undocumented manual state.

**Consequences:**

- Positive: simple, no circular dependency.
- Negative: bootstrap state is not backed up; if lost, `terraform import` is required (documented in `bootstrap/README.md`).
- Follow-ups: `bootstrap/terraform.tfstate*` and `bootstrap/.terraform/` added to `.gitignore`.

---

### ADR-004: State storage CMK — bootstrap dedicated Key Vault in Management sub

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user

**Context:**
PROMPT.md Section 10 requires CMK encryption for the Terraform state Storage Account. CMK requires a Key Vault not yet built in any other section.

**Decision:**
Create a dedicated Key Vault (`kv-tfstate-<suffix>-001`) in `rg-tfstate-mgmt-eus2-001` (Management subscription) as part of the bootstrap layer. The KV holds a single RSA-2048 key for Storage Account CMK. It is NOT replaced by the Security sub KV built in Section 8 — that KV is purpose-built for workload secrets.

**Alternatives considered:**

- Microsoft-managed keys now, upgrade later — rejected: PROMPT.md explicitly requires CMK; a deviation marker would persist for 6+ sessions.
- Security sub KV (built in Section 8) — rejected: blocking CMK on that dependency leaves the state SA unencrypted for 6+ sessions.

**Consequences:**

- Positive: state SA is CMK-encrypted from first `terraform apply`; no deviation markers.
- Negative: a second Key Vault alongside the future Security sub KV; adds ~$5/mo.
- Follow-ups: bootstrap KV is referenced (not replaced) when Section 8 builds the Security sub KV.

---

### ADR-003: Subscription model — Option C (4 platform subs + 1 shared LZ sub)

- **Date:** 2026-05-05
- **Section:** 10a (resolves OQ-001, unblocks Section 2)
- **Status:** Accepted
- **Decision makers:** user

**Context:**
ALZ assumes 6+ subscriptions. For a portfolio POC on a Visual Studio benefit account, options ranged from a single subscription (cheapest) to full multi-sub (most realistic).

**Decision:**
Option C: 4 platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription hosting all Landing Zones and Sandbox. The platform/workload subscription boundary — the most architecturally significant in ALZ — is real. Within-LZ sub boundaries are simulated via MG scope and Resource Group segmentation.

**Alternatives considered:**

- Full multi-sub (Option A) — rejected: Visual Studio benefit accounts are typically capped at 1–5 subs; cost compounds.
- Single sub (Option B) — rejected: collapses the platform/workload boundary; cannot demonstrate MG policy inheritance.

**Consequences:**

- Positive: 5 subscriptions feasible on VS Enterprise; MG hierarchy is real; policy at MG scope behaves correctly.
- Negative: within-LZ sub-level isolation is simulated; documented in `ARCHITECTURE.md`.
- Follow-ups: Section 2 MG hierarchy maps 5 subscription IDs to MG nodes; IDs supplied via `poc.tfvars`.

---

### ADR-002: Treat repo root as alz-poc/ — no nested subdirectory

- **Date:** 2026-05-04
- **Section:** 1
- **Status:** Accepted
- **Decision makers:** claude (structural, low-risk)

**Context:**
PROMPT.md shows `alz-poc/` as the top-level path in the directory tree. The working directory `d:\Azure POC\Azure-Architecture\` already contains the bootstrap files (CLAUDE.md, PROMPT.md, WORKLOG.md, etc.) at its root. Two options: (a) treat the current directory as the repo root and create all subdirectories directly here, or (b) create a nested `alz-poc/` subdirectory inside the existing repo.

**Decision:**
Treat `d:\Azure POC\Azure-Architecture\` as the repo root (equivalent to `alz-poc/`). All directories from the PROMPT.md tree are created directly here, at the same level as CLAUDE.md and WORKLOG.md.

**Alternatives considered:**

- Nested `alz-poc/` subfolder — rejected: bootstrap files already live at the repo root; nesting would split Claude Code workflow files from Terraform files and break the `CLAUDE.md` read-at-start assumption.

**Consequences:**

- Positive: single working directory, no path confusion between Claude workflow files and Terraform structure
- Negative: root is slightly noisier than a clean Terraform project root (contains CLAUDE.md, WORKLOG.md etc.)
- Follow-ups: none

---

### ADR-001: Use AVM Pattern Module for ALZ Foundation

- **Date:** 2026-05-06
- **Section:** 2
- **Status:** Accepted — `Azure/avm-ptn-alz` v0.19.1 confirmed on registry.terraform.io 2026-05-06
- **Decision makers:** user, claude

**Context:**
The ALZ pattern can be implemented via (a) the official `Azure/avm-ptn-alz` Terraform pattern module, (b) the older `Azure/caf-enterprise-scale` module, or (c) hand-rolled MG and policy resources.

**Decision:**
Use `Azure/avm-ptn-alz` v0.19.1. Module confirmed published on Terraform Registry. Pinned to exact version in `platform/management-groups/providers.tf`.

**Alternatives considered:**
- Hand-rolled — rejected: defeats the purpose of using AVM and adds maintenance burden
- `caf-enterprise-scale` only — rejected for primary path: AVM is the forward-looking standard

**Consequences:**
- Positive: aligned with current Microsoft guidance, less custom code to maintain
- Negative: AVM pattern modules are newer and may have rough edges
- Follow-ups: none — ADR resolved

---


### ADR-002: Subscription Model — Platform Multi-Sub, Shared LZ Sub

- **Date:** 2026-05-05
- **Section:** 1 (foundational, surfaces in 2, 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
ALZ canonical pattern uses 6+ subscriptions. Portfolio POC on a Visual Studio benefit account needs to balance architectural fidelity with realistic provisioning constraints and idle cost.

**Decision:**
4 dedicated platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription for all Landing Zones (corp-a1, corp-a2, online-p1) and Sandbox, with separation enforced via Resource Groups, Management Group placement, and policy assignment.

**Alternatives considered:**
- Option A (full 6+ sub multi-sub): rejected for cost (~$200–500/mo idle) and provisioning complexity on Visual Studio benefits
- Option B (single sub everything): rejected because it eliminates the platform/workload boundary that ALZ exists to demonstrate

**Consequences:**
- Positive: Demonstrates the most architecturally important boundary (platform vs workload) at sub-scope; idle cost ~$80–150/mo manageable
- Negative: Corp-vs-online and individual LZ isolation is simulated via RG, not enforced at sub level — must be called out in ARCHITECTURE.md
- Follow-ups: All Terraform module designs must accept a `subscription_id` variable and not assume sub-per-LZ; policy assignments at the Landing Zones MG must compensate for the shared-sub blast radius

---


### ADR-003: Subscription Model — Platform Multi-Sub, Shared LZ Sub

- **Date:** 2026-05-05
- **Section:** Foundational (impacts 2, 8, 9, 10)
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
ALZ canonical pattern uses 6+ subscriptions. Portfolio POC on a Visual Studio benefit account needs to balance architectural fidelity with realistic provisioning constraints and idle cost.

**Decision:**
4 dedicated platform subscriptions (Connectivity, Management, Security, Identity) + 1 shared subscription for all Landing Zones (corp-a1, corp-a2, online-p1) and Sandbox, with separation enforced via Resource Groups, Management Group placement, and policy assignment.

**Alternatives considered:**
- Option A (full 6+ sub multi-sub) — rejected: ~$200–500/mo idle cost; provisioning complexity on Visual Studio benefits
- Option B (single sub everything) — rejected: eliminates the platform/workload boundary that ALZ exists to demonstrate

**Consequences:**
- Positive: demonstrates platform/workload boundary at sub-scope; idle cost ~$80–150/mo
- Negative: corp/online and individual LZ isolation simulated via RG, not enforced at sub level — must be called out in ARCHITECTURE.md
- Follow-ups: all module designs accept `subscription_id` variable; policy assignments at Landing Zones MG must compensate for shared-sub blast radius

---

### ADR-004: State Backend CMK Approach — Dedicated Bootstrap Key Vault

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
PROMPT.md Section 10 mandates CMK encryption on the Terraform state Storage Account. CMK requires a Key Vault with an encryption key, but the security-subscription Key Vault doesn't exist until Section 8.

**Decision:**
Bootstrap a dedicated Key Vault in the Management subscription as part of 10a. This Key Vault holds only the storage encryption key plus any future bootstrap-layer secrets. It is referenced (not destroyed) by later sections.

**Alternatives considered:**
- Microsoft-managed keys — rejected: creates a deviation marker that compounds with later changes
- Use Security-sub Key Vault — rejected: that sub doesn't exist yet

**Consequences:**
- Positive: aligned with PROMPT.md from day one, no deviation marker
- Negative: Management sub now has two Key Vaults (bootstrap + future shared) — naming must distinguish them
- Follow-ups: Section 8 must NOT replace this KV; it must add a separate `kv-mgmt-shared-*` for application secrets

---

### ADR-005: Bootstrap Layer State Strategy — Local, Never Committed

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted
- **Decision makers:** user, claude

**Context:**
The bootstrap layer creates the remote state backend. Its own state cannot live in the backend it creates — chicken-and-egg.

**Decision:**
Bootstrap layer uses local Terraform state. The state file is gitignored and never committed. Procedure documented as one-time manual apply in `bootstrap/README.md`. If the bootstrap state is lost, recovery path is `terraform import` against existing Azure resources.

**Alternatives considered:**
- Local state in private gitignored folder, committed encrypted — rejected: adds SOPS/git-crypt overhead for a one-time apply
- Imperative Azure CLI bootstrap — rejected: loses Terraform's state and import benefits

**Consequences:**
- Positive: simplest possible bootstrap; clear separation between "platform" and "platform of platform"
- Negative: bootstrap can drift if applied from a different machine; recovery requires `terraform import`
- Follow-ups: Section 12 acceptance criteria must include a documented bootstrap recovery drill

---

### ADR-006: Initial OIDC Service Principal RBAC Scope

- **Date:** 2026-05-05
- **Section:** 10a
- **Status:** Accepted (with deliberate scope-down deferral — see OQ-008)
- **Decision makers:** user, claude

**Context:**
The OIDC SP needs sufficient privilege to deploy ALZ — creating Management Groups, applying policies at MG scope, creating resources across 5 subscriptions. Strict least-privilege would require careful per-scope role assignments before any deployment can succeed.

**Decision:**
For Days 2–11, grant the OIDC SP **Owner at Tenant Root Management Group**. This is documented as a deliberate POC compromise. Section 12 must replace this with scoped roles before the POC is treated as "done."

**Alternatives considered:**
- Per-sub Contributor + Resource Policy Contributor + UAA from day one — rejected: would consume an entire session of RBAC plumbing before any architectural work, and would still need adjustment as new sections add new resource types
- Owner at each sub individually — rejected: doesn't grant MG-scope policy creation

**Consequences:**
- Positive: unblocks all subsequent sessions immediately; minimizes RBAC churn during build
- Negative: SP is over-privileged for the duration of the build; MUST NOT be reused in any other tenant or repurposed for a customer environment
- Follow-ups (tracked in OQ-008): Section 12 replaces with per-sub Contributor + Resource Policy Contributor at MG + UAA where role assignments are managed

---
