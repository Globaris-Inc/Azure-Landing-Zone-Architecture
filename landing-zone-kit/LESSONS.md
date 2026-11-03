# LESSONS — the live-apply reality checklist

The single biggest lesson from this build: **a green `terraform validate` (and even a green `plan`) is
necessary but nowhere near sufficient.** Static checks see syntax, types, and provider schemas. They cannot
see runtime Azure behaviour, tenant policy, subscription features, quota, RBAC propagation, provider
quirks, the CI runner environment, GitHub settings, or transitive module constraints. **Every item below
passed `validate` and only failed at a real `apply` / real CI run.**

Use this as a **pre-flight checklist** for any Azure landing zone. For each: *symptom → why static review
misses it → the guardrail to apply up front.* Most are not AVD-specific.

> **Meta-principle: "validate the way CI runs."** Don't trust "it validated locally." Validate with the
> *same* Terraform version CI pins, run `terraform init` so transitive module constraints are exercised,
> and lint the workflows. The kit's `scripts/preflight.sh` automates this.
>
> **Proven the hard way (ALZ build):** in the ALZ platform build, **5 of 10 roots the worklog had marked
> 🟢 Complete did not actually `validate`** — because validate was logged "NOT RUN" every session. The
> module calls had drifted from their pinned versions' schemas and nobody knew. See §E.
>
> **Sharpened by the full deploy campaign (2026-05 to 2026-07, sections F to J below): even a green
> `plan` is not the truth.** Azure Policy effects, tenant licensing and directory roles, resource-type
> retirements, subscription offer caps, and cross-service propagation are all evaluated only at PUT time
> or later. The operating loop that finally made deploys land: an architect-owned **pre-clearance gate
> before ANY first apply or retry** (live policy matrix + tenant prerequisites + known-issues harvest +
> resource-type lifecycle audit), a **plan-scan for forced replacements** before every apply, **one
> consolidated fix-spec per failure set** after any failure, and a **post-apply QA pass** that verifies
> live state against intent. Apply-success is not green; QA-verified is green. (49 of 92 CI deploy runs
> failed and were fixed forward. That ratio is the real shape of a live-tenant campaign; budget for it.)

---

## A. Terraform / provider code (caught only at plan/apply)

1. **`storage_use_azuread = true` when shared keys are disabled.**
   *Symptom:* `KeyBasedAuthenticationNotPermitted` creating/using a storage account. *Why missed:* the
   provider's blob data-plane poll defaults to shared-key auth; nothing in the config hints at it.
   *Guardrail:* any storage account with `shared_access_key_enabled = false` ⇒ set `storage_use_azuread =
   true` on the provider, and grant the deployer a **data-plane** role (`Storage Blob Data Contributor`)
   **at a scope that exists before the account** (RG, not the account) **with a propagation wait**.

2. **Storage/KV `ip_rules` reject `/31` and `/32`.**
   *Symptom:* `must start with IPV4 address ... number of bits (0-30)`. *Why missed:* a valid-looking
   `/32` is a runtime API rejection. *Guardrail:* strip `/32` to a bare IP for **both** storage
   `network_rules` and KV `network_acls` (`[for ip in var.ips : trimsuffix(ip, "/32")]`).

3. **No WORM/immutability on a Terraform-state container.**
   *Symptom:* `BlobImmutableDueToPolicy` on state lock/overwrite. *Why missed:* "unlocked" immutability
   still enforces write-once. *Guardrail:* never put an immutability policy on a state container; use blob
   **versioning** for recovery.

4. **CMK flip-flop with the separate `customer_managed_key` resource.**
   *Symptom:* every apply silently reverts the SA to Microsoft-managed keys. *Why missed:* a provider
   reconciliation quirk between the SA resource and the separate CMK resource. *Guardrail:*
   `lifecycle { ignore_changes = [customer_managed_key] }` on the storage account.

5. **`for_each` over apply-time-unknown values fails on a greenfield plan.**
   *Symptom:* `Invalid for_each argument ... known only after apply`. *Why missed:* on a *fresh* deploy the
   referenced IDs are unknown; on a re-plan against existing state they're known, so it "works" once
   created. *Guardrails:* (a) `for_each` **keys must be static** — put apply-time values only in the
   *values*; (b) **never gate a map on an unknown** (e.g. `id == "" ? {} : {...}`) — gate on a **static
   bool**; (c) **don't `try()` over a map with unknown values** — it makes the whole result (keys
   included) unknown; use `one(values(module.x))` + a null check instead.

6. **An AVM module output that's an object, not a string.**
   *Symptom:* `Inappropriate value for attribute "x": string required, but have object`. *Why missed:* some
   AVM `resource_id` outputs return the whole resource object; the type is `any` so `validate` passes.
   *Guardrail:* confirm each consumed output's actual shape (`.resource_id.id`, not `.resource_id`) — read
   the module's `outputs.tf`, don't assume.

7. **AVM module `required_version` floor exceeds your Terraform pin.**
   *Symptom:* `Unsupported Terraform Core version` at `init` — **in CI only**. *Why missed:* the floor lives
   in *gitignored downloaded module code*, and locally you ran a newer Terraform that satisfied it.
   *Guardrail:* keep the **CI pin == local pin** (a `.terraform-version` file), and run a check that fails
   when any module's `required_version` floor exceeds your pin (see `preflight.sh`).

**Campaign additions to A (2026-07 deploy arc):**

23. **The default `azapi` provider must be anchored to the root's subscription.**
    *Symptom:* AVM modules that build `parent_id` from `data.azapi_client_config` PUT resources into the
    WRONG subscription: RSV 404 `ResourceGroupNotFound` (vault aimed at the management sub instead of the
    identity sub), then the identical failure in all 3 spokes. *Why missed:* nothing in the root hints the
    module resolves its scope from the azapi client config, which falls back to `ARM_SUBSCRIPTION_ID`.
    *Guardrail:* every multi-subscription root that pulls in AVM modules gets an explicit
    `provider "azapi" { subscription_id = var.<root>_subscription_id }`, the same discipline as azurerm
    aliases (ADR-027 arc).

24. **Keyless storage accounts are rejected by service-side writers, not just the provider.**
    *Symptom:* Cost Management exports 400 "Key-based authentication is currently disabled" at create;
    a refresh 403 `KeyBasedAuthenticationNotPermitted` reading queue properties. *Why missed:* lesson 1
    fixes the provider's own data-plane calls; the export SERVICE also writes to the SA with keys on old
    API versions, and refresh reads data-plane properties nobody authored. *Guardrail:*
    `storage_use_azuread = true` on every root touching a keyless SA, and move service-side writers to an
    api-version plus identity that supports Entra auth (exports: azapi
    `Microsoft.CostManagement/exports@2025-03-01` + SystemAssigned MI, ADR-027).

25. **Retrofitting a feature flag (`count`) requires a whole-root reference sweep.**
    *Symptom:* plan-time errors on stray `.this` / bare references to a now-gated resource; stale module
    output attributes that had been invalid since authoring (only surfaced at plan); outputs failing the
    "sensitive value" check. *Why missed:* validate passes until the gated resource's addresses change,
    and output-shape errors are plan-time only. *Guardrail:* when gating, grep the ENTIRE root for every
    reference to the gated address, convert to `one(...[*])` or a guarded `[0]`, re-verify each consumed
    output against the module's `outputs.tf`, and mark outputs derived from sensitive values
    `sensitive = true`.

26. **Unset Optional+ForceNew attributes that Azure populates cause silent forced replacement.**
    *Symptom:* a post-recovery plan wants to destroy+recreate the AADDS domain
    (`domain_configuration_type` null in config vs Azure's `FullySynced`); Defender basic plans show
    `subplan = <value> -> null # forces replacement`, which would have downgraded two
    cannot-be-recreated plans to Free (ADR-035). *Why missed:* the destroy is buried inside a "replace"
    and the posture consequence is invisible to a summary line. *Guardrail:* pin every mutable
    Azure-assigned attribute so config == state, and ALWAYS scan plan output for `forces replacement`
    and unexpected destroys before approving an apply. The plan-scan guard caught the Defender landmine
    on a dry run instead of a posture regression.

27. **PUT-time value and combination constraints: rendered lengths, future dates, SKU couplings.**
    *Symptom:* storage-account names over the 24-char limit once `org_prefix` + env + suffix rendered
    (3 synthetic names blew it); a cost scheduled-action display name over 50 chars; export
    `recurrencePeriod.from` "must be in future" (a past tfvars date); Basic App Service plans reject
    zone redundancy (`zone_balancing_enabled` must be false, ARM 52050); the App Gateway WAF_v2 subnet
    accepts an NSG but NOT a route table. *Why missed:* all ARM-side validation; the provider schema
    accepts the values. *Guardrail:* compute the FINAL rendered string length for every globally-named
    resource; derive time windows from `plantimestamp()` with `ignore_changes` instead of static dates;
    sweep documented ARM constraints for every still-uncreated resource before any rerun.

28. **A dead variable can silently deploy a four-figure monthly resource.**
    *Symptom:* `enable_ddos_standard = false` was declared and documented but referenced nowhere; the hub
    pattern module defaulted the DDoS plan ON, and the green 707-resource plan included roughly $3k/mo of
    unwanted spend. *Why missed:* validate/plan cannot flag an unreferenced variable, and a huge plan
    hides one module default. *Guardrail:* wire every declared toggle (grep for unreferenced variables),
    and have pre-apply review read the plan against COST intent, not just correctness. This single catch
    justified the mandatory review gate.

29. **Know what the pattern module and the service already create before adding your own resources.**
    *Symptom:* `400 AnotherPeeringAlreadyReferencesRemoteVnet` (the hub module auto-meshes hub-to-hub
    peering; a hand-authored dr.tf duplicated it); `400 SubnetMissingRequiredDelegation` (the DNS
    resolver outbound endpoint auto-injects a delegation Terraform then tried to strip). *Why missed:*
    the overlap lives in module internals and Azure-side auto-attachment, invisible to validate.
    *Guardrail:* read the pattern module's sub-resources at the PINNED tag before authoring adjacent
    resources; declare service-injected subnet delegations in config so Terraform does not fight them.

---

## B. Subscription prerequisites (control-plane, not in the repo)

8. **Resource-provider *features* must be registered.**
   *Symptom:* e.g. `EncryptionAtHost feature is not enabled for this subscription`. *Why missed:* it's
   subscription state, not config. *Guardrail:* enumerate required features up front
   (`az feature register --namespace … --name …` + `az provider register`) or toggle the feature off.

9. **First-party service principals need RBAC for platform features.**
   *Symptom:* e.g. AVD scaling plan `400 ... give the Azure Virtual Desktop service permissions`. *Why
   missed:* the requirement is a Microsoft first-party SP role, documented in the feature's docs, not the
   module. *Guardrail:* check each platform feature's docs for a required first-party-SP role assignment
   (e.g. *Desktop Virtualization Power On Off Contributor* for AVD autoscale).

10. **vCPU / SKU quota — especially on PoC subs.**
    *Symptom:* `OperationNotAllowed ... approved <family> Cores quota. Current Limit: 0`. *Why missed:*
    quota is per-subscription/region, default-0 for many families. *Guardrail:* `az vm list-usage` early;
    pick a family with quota (or request an increase); mind the **Total Regional vCPUs** cap.

11. **Azure default outbound access is retired — VMs need explicit egress.**
    *Symptom:* extensions/agents `Unable to connect to the remote server` despite the NSG allowing outbound.
    *Why missed:* the NSG looks fine; the missing piece is a *route to the internet*. *Guardrail:* give
    private-only subnets a defined egress path — **NAT gateway** (or firewall/UDR). Don't rely on implicit
    default outbound.

12. **Vendor bootstrap artifacts drift (pin a known-good version).**
    *Symptom:* e.g. the AVD agent DSC `Configuration.zip` "always-latest" dropped a parameter
    (`aadJoin`) and failed. *Why missed:* the artifact changes outside your repo. *Guardrail:* pin a
    *versioned* artifact you've verified; treat "always-latest" as a liability for anything load-bearing.

---

## C. Auth & environment

13. **Tenant MFA Conditional Access blocks *user* ARM access.**
    *Symptom:* `RequestDisallowedByAzure ... MFA`. OIDC/federation **cannot** authenticate a *local*
    terminal run. *Guardrail:* for local driving use a **service principal** (client secret/cert) or get
    the user token to carry the `mfa` claim; reserve **OIDC federation for CI**. (Verify a token's `amr`
    claim before assuming MFA.)

14. **Shell/tooling friction is real — script around it.**
    *Symptom:* Windows PowerShell 5.1 mangles native-exe args; `az`/`terraform` not on a hook's PATH.
    *Guardrail:* pass CLI flags via an array (`& terraform @args`), `Set-Location` instead of `-chdir` when
    paths contain spaces, and locate tools explicitly in scripts/hooks.

---

## D. CI / pipeline

15. **GitHub repo *Variables* ≠ *Secrets*.**
    *Symptom:* `azure/login` ... `auth-type: SERVICE_PRINCIPAL. Not all values are present` because
    `${{ vars.X }}` is empty. *Why missed:* the values exist — under the wrong tab. *Guardrail:* OIDC IDs
    (client/tenant/subscription) are **Variables** (`vars.*`), not Secrets. Add a preflight step that fails
    early if a required var is empty.

16. **A firewalled state account blocks hosted runners.**
    *Symptom:* slow/blocked backend `init` from CI. *Why missed:* it works from your allow-listed deployer
    IP. *Guardrail:* a default-Deny state account needs the **runner's egress IP** added for the run and
    removed after (`az storage account network-rule add/remove` around `init`), or a private/self-hosted
    runner.

17. **Deploys should be explicit, not merge-triggered.**
    *Lesson:* "merge = auto-apply prod" fires on routine commits (docs, workflows) and doesn't match a
    destroy-then-recreate cadence. *Guardrail:* gate applies behind `workflow_dispatch` + a typed
    confirmation + a required-reviewer Environment. PRs run **plan only**.

18. **Make re-bootstrap reproducible (deterministic state-backend naming).**
    *Symptom:* after a cleanup the random-suffixed state account name changes, breaking `backend.hcl`.
    *Guardrail:* derive the state SA/KV suffix from the **subscription ID** (`substr(sha1(lower(id)),0,8)`),
    so every re-bootstrap yields the same names. Bootstrap state can be **ephemeral** if teardown is
    `az group delete` and deploys reach the account by name.

19. **Teardown ordering bites; brute force is fine for demos.**
    *Symptom:* `terraform destroy` stuck on stopped-VM extension deletes / orphaned child objects (e.g. AVD
    `sessionHost` records blocking host-pool delete). *Guardrails:* start deallocated VMs before deleting
    their extensions; force-clear orphaned child objects via REST; **for demo resets, `az group delete`**
    (control-plane, brute force) sidesteps the whole ordering problem.

**Campaign additions to D (2026-07 deploy arc):**

30. **A JIT single-IP allowlist for the state SA is inherently racy on hosted runners.**
    *Symptom:* intermittent init 403 `AuthorizationFailure` even AFTER a readiness poll passed. The
    ipify-reported IP is not always Terraform's egress IP (runner SNAT pool), and firewall-rule and
    default-action propagation is non-monotonic across storage front-end nodes: one probe can pass while
    the next connection hits a node still on Deny. *Why missed:* it works from an allow-listed deployer
    IP and wins some runs, so it looks environmental. *Guardrail:* flip the state SA `default_action` to
    Allow for the job window and restore Deny on exit (`if: always()`, guarded), keep the readiness poll,
    AND add a bounded init retry loop for cross-node lag (ADR-025). Data stays protected during the
    window by Entra-only auth + blob RBAC + TLS + CMK.

31. **Serialize everything that touches the state SA, and know that every run restores Deny.**
    *Symptom:* two concurrent runs raced the firewall flip and a state save 403'd; a manually opened
    firewall (for a teardown window) was silently reverted to Deny by an unrelated deploy run's cleanup
    step; the teardown workflow deliberately does NOT wire the JIT flip (it would race across parallel
    target=all jobs), so teardown needs a manual firewall open before dispatch and a manual Deny restore
    after (PD-1). *Why missed:* each workflow is correct in isolation; the failures are cross-run
    interactions. *Guardrail:* one state-SA-touching run at a time; document that ANY run of the reusable
    root workflow restores Deny at exit; make the manual open/close an explicit teardown runbook step.

32. **Repo Secrets are write-only; malformed values surface as plan parse errors much later.**
    *Symptom:* a hub VNet ID Secret failed ARM ID parsing at plan ("segment at position 0 didn't match")
    and the stored value could not be read back to diagnose. Related: ARM returns some IDs with
    non-canonical casing (uppercase GUID, lowercase `microsoft.insights`) that azurerm v4 strict parsers
    can reject. *Why missed:* setting a secret gives zero feedback; the consumer runs days later.
    *Guardrail:* set Secrets from live `az` queries in the same shell session, store azurerm-canonical
    casing, re-set rather than diagnose when one misbehaves, and verify each root's consumed Secrets in
    its pre-clearance (`gh secret list` against the workflow's `TF_VAR_*` map).

33. **Environment-gated OIDC has a bootstrap cycle, and apply-run gating may not be purchasable.**
    *Symptom:* the first gated apply cannot log in - the `environment:production` federated credential
    only exists after a bootstrap re-apply, which itself 403s on MG-scoped RBAC rows until the MG tree
    exists; Environment required-reviewers returned HTTP 422 (a billing-plan feature); one apply dispatch
    raced the git push and ran the pre-fix SHA (cancelled before damage). *Why missed:* all GitHub/tenant
    server-side state. *Guardrail:* break the cycle with a TARGETED bootstrap apply of just the env
    federated credentials; when Environment reviewer gates are unavailable, gate merges with a
    version-controlled branch ruleset and record that the apply-run gate is open; after pushing a fix,
    confirm the run's headSha is the fixed commit before letting it write to Azure.

---

## E. The ALZ platform build — proof of the meta-principle

The lessons above came from the AVD (application-LZ) build. The **ALZ Hub & Spoke platform** build (this
repo) then proved the meta-principle the hard way — a repo marked "complete" across 13 sections where
`validate` had never actually run in CI.

20. **AVM module-call arguments silently drift from the *pinned* version's schema.**
    *Symptom:* `terraform validate` fails (`An argument named "x" is not expected here` / missing required
    arg) across roots previously marked complete. *Why missed:* the repo pinned
    `avm-res-network-virtualnetwork 0.17.1` but called it with `resource_group_name` — 0.17.1 takes
    `parent_id`; validate was never run, so the drift sat latent in 3 spokes. *Guardrail:* reconcile every
    module call against the **pinned version's** `variables.tf` (read the tag, not the latest registry
    docs), and enforce lesson 21.

21. **Commit a `.terraform.lock.hcl` per root + a CI `validate` gate.**
    *Symptom:* non-deterministic provider/module resolution; CI init noise; drift (20) landing unnoticed.
    *Guardrail:* commit a **multi-platform** lock for every root (`terraform providers lock
    -platform=linux_amd64 -platform=windows_amd64`), and add a PR workflow that runs `fmt -check` + per-root
    `init -backend=false && validate` over **all** roots. It needs **no credentials** (validate-only), so
    it's cheap and always-on — the CI enforcement of the meta-principle.

22. **A hallucinated/renamed resource passes authoring but fails `validate`.**
    *Symptom:* a standalone `azurerm_private_dns_zone_group` resource (doesn't exist — it's a *nested block*
    on `azurerm_private_endpoint`) shipped; the private-endpoint DNS registration would never have worked.
    *Why missed:* never validated. *Guardrail:* same gate as 21 — it catches non-existent resource types
    and stale argument names the instant they're written.

---

## F. Azure Policy and governance at runtime (evaluated only at PUT)

Nothing in this section is visible to `validate` or `plan`: ARM evaluates policy when the resource is
written, and the denying/mutating assignment usually lives in a DIFFERENT root's deployed state. The
blanket guardrail is the pre-clearance **live policy matrix**: enumerate every Deny/Modify/DINE assignment
at EVERY ancestor MG scope of the target subscription and disposition each one against the resource types
the root creates, before the first apply (see lesson 58).

34. **Your own ALZ policy stack rewrites your own deploys: the placeholder-parameter Modify trap.**
    *Symptom:* both hub VNets fail `403 LinkedAuthorizationFailed ... ddosProtectionPlans/join/action ...
    subscription 00000000-... not found` even though the request body contains NO DDoS reference. The ALZ
    `Enable-DDoS-VNET` Modify assignment ships with a placeholder plan ID and, enforced, rewrites every
    VNet PUT in scope (known ALZ trap). *Why missed:* the block comes from another root's deployed
    policy; three plausible hypotheses were "confirmed" before a minimal `az rest` PUT isolated it as
    subscription-specific and body-independent. *Guardrail:* set `enforcement_mode = "DoNotEnforce"` (or
    wire a real plan ID) for the assignment at EVERY MG the resource chain inherits, not just the first
    one that bites - the identical trap was flagged for the landingzones MG at connectivity time and
    still had to be applied before the spokes. When debugging a mystery 403 on a write, test a minimal
    REST PUT of the same body in a sibling subscription to split code from environment.

35. **Deny policies vs mandatory service-created resources: exemption + propagation sleep + depends_on.**
    *Symptom:* the Entra DS managed domain reached terminal `Failed` with
    `ResourceActionsBlockedByPolicy`: its REQUIRED Standard public IP is created by the first-party
    service principal (not the CI SP) and was denied by our own `Deny-Public-IP` assignment at the
    identity MG. There is no suppression lever on the service side. *Why missed:* the denied resource
    never appears in the plan (service-created), and the caller in the Activity Log is not your
    deployer. *Guardrail:* an RG-scoped policy exemption (category Waiver) keeps the Deny enforced
    everywhere else (ADR-028), followed by a ~300s `time_sleep` for exemption propagation, and an
    explicit `depends_on` from EVERY protected resource to the sleep - the exemption-vs-create race is
    real and a missed dependency costs a multi-hour create cycle. The same Waiver+sleep+depends_on
    pattern was reused for the spoke flow-log SAs and the synthetic RGs.

36. **Pinned policy-library content skews against moving built-in policies.**
    *Symptom:* `InvalidPolicyParameters` at the MG apply: the pinned ALZ library supplied a lowercase
    `deny` default that built-in policy v9.0.0 now rejects (case-sensitive allowed values). *Why missed:*
    policy parameterization is validated only by ARM at PUT; the library ref sat months stale.
    *Guardrail:* bump the ALZ `library_references` ref (the library, not the module - ADR-023), re-plan
    and review the diff after any bump (deprecated definitions get destroyed), and expect
    assignment-before-definition-delete `Conflict`s to resolve on rerun.

37. **Built-ins referenced by GUID without explicit parameters are PUT-time bombs; DINE needs wiring.**
    *Symptom:* a Key Vault policy GUID with the right prefix but wrong tail (hallucination class) would
    have 404'd at apply; initiative members defaulting to `Deny` would have hard-blocked the flow-log
    SAs; the ALZ `Deploy-Diag-LogsCat` DINE failed remediation with a zero-GUID
    `LinkedAuthorizationFailed` because its central LAW parameter was never wired (it does NOT
    self-heal). *Why missed:* GUIDs and parameter defaults are opaque strings to Terraform.
    *Guardrail:* `az policy [set-]definition show` every referenced built-in before apply; pass `effect`
    and required parameters explicitly; wire every DINE parameter or set the assignment DoNotEnforce.
    Also expect DINE (e.g. Deploy-Private-DNS-Zones) to contend with resources you manage - post-apply
    drift, not a create blocker, but disposition it in pre-clearance.

38. **Tag Modify policies: add-if-missing, never overwrite; and expect policy-injected tag drift.**
    *Symptom:* tag governance built on overwrite variants churned every resource's tags on every apply;
    after fixing to add-if-missing, the policy still injects `CreatedDate = "1970-01-01"` (a Modify
    effect cannot compute dates) that Terraform strips on every plan - an estate-wide, perpetual, benign
    `0 add / N change / 0 destroy` diff (OQ-032). *Why missed:* policy mutates tags out-of-band AFTER
    apply; the drift only appears on the next plan. *Guardrail:* use add-if-missing/inherit built-ins;
    then either declare the policy-injected tags in config, `ignore_changes = [tags["..."]]`, or record
    the drift as formally accepted so nobody burns time chasing it later.

39. **Policy assignment names and display strings have ARM-side limits.**
    *Symptom:* a regulatory-compliance assignment `name` over the 24-character limit failed the run;
    em dashes in policy `display_name` strings rendered live in the portal as mojibake replacement
    characters. *Why missed:* the provider schema accepts any string. *Guardrail:* keep assignment names
    at or under 24 chars (derive short keys like `reg-${each.key}`) and keep display strings ASCII-only.

---

## G. Service lifecycle, deprecations, and subscription offer caps

40. **Azure retires resource types mid-project; no default gate checks the retirement calendar.**
    *Symptom:* `azurerm_network_watcher_flow_log` with an NSG target hard-errors at apply - NSG flow
    logs were RETIRED for new creation on 2025-06-30, blocking all three spokes with code authored weeks
    earlier. *Why missed:* validate checks schema, review checks the diff, and pre-clearance (as first
    designed) checked policy/prereqs/known issues; nothing checked the provider's lifecycle calendar.
    *Guardrail:* a **resource-type lifecycle audit** is now a required pre-clearance step: classify every
    type a root creates as CURRENT / DEPRECATED / RETIRING / RETIRED against the Azure updates feed and
    Learn migration docs. For flow logs specifically: migrate to VNet flow logs (`target_resource_id` =
    the VNet), collapse per-NSG logs to one per VNet, and RECREATE rather than update in place (known
    provider bug on target swap); subnet-scoped targeting is not reliably supported.

41. **Defender plan availability churns: deprecated plans 400 on enable, live ones become latent debt.**
    *Symptom:* the `Dns` plan 400 "deprecated, can no longer be enabled"; five plans
    (KubernetesService, ContainerRegistry, KeyVaults, Dns, Arm) blocked for NEW Standard enablement;
    plans already live at Standard (KeyVaults, Arm) must be held and NEVER recreated - a destroy+create
    would drop them to Free permanently (see lesson 26 for the subplan ForceNew that nearly did exactly
    that). Parallel pricing PUTs also 409 "another operation in progress", and a failed run left one plan
    Standard in Azure but absent from state ("already exists, import"). *Why missed:* deprecations live
    in release notes, not the provider; the 409s and the drift only manifest across runs. *Guardrail:*
    re-audit the Defender plan list against release notes in every pre-clearance touching pricing;
    serialize pricing PUTs with `depends_on`; treat the 409 as rerunnable; adopt any drifted plan with a
    config-driven import; standing rule - plan-scan before ANY apply of a root managing Defender pricing.

42. **Subscription OFFER caps are a separate axis from quota.**
    *Symptom:* Azure SQL `ProvisioningDisabled` in both target regions for the landingzones sub; App
    Service dedicated compute quota 0 (ARM 70007) while IaaS/compute quota was verified HEALTHY in two
    portal exports; serverless/shared PaaS (Static Web App) unaffected. These are restrictions of the
    subscription offer type, not usage limits, and no quota page predicted the SQL one. *Why missed:*
    plan cannot see offer restrictions, and lesson 10's quota checks look at the wrong axis.
    *Guardrail:* probe offer restrictions per subscription per region for every dedicated/reserved-compute
    service before placing workloads, and architect workload tiers behind default-off flags
    (`enable_sql`, `enable_app_service`) so a spoke can ship as a network landing zone and the tier
    becomes a flag-flip when capacity is granted (ADR-031/032) - a toggle, not rework.

43. **Regional co-location constraints resolve only at apply: Traffic Analytics and Network Watcher.**
    *Symptom:* `InvalidTAWorkspaceRegion` on the DR spoke - Traffic Analytics requires a Log Analytics
    workspace in the flow log's region, and the platform LAW is single-region; separately, flow-log
    plans fail when the per-region `NetworkWatcher_<region>` instance does not exist, because the data
    source resolves at PLAN time before any VNet exists to auto-create it. *Why missed:* region
    compatibility matrices live in service docs, not provider schemas. *Guardrail:* map every
    region-coupled dependency in pre-clearance; either provision a regional LAW or disable TA on the DR
    leg deliberately (documented deviation); create/verify `NetworkWatcher_<region>` before the first
    spoke plan.

---

## H. Identity platform: Entra Domain Services, Conditional Access, Sentinel tenant permissions

44. **AADDS has a tenant prerequisite stack the provider never mentions.**
    *Symptom:* successive 400s across four applies: `Microsoft.AAD` RP NotRegistered (it is in NONE of
    azurerm's auto-register sets - register it in-root with a `depends_on` from the domain); the
    "Domain Controller Services" publisher SP and the exact-named "AAD DC Administrators" group missing;
    "user does not have administrative privileges to manage AAD Domain Services" even AFTER group
    membership - ENABLING domain services requires the deploying principal to hold the **Application
    Administrator + Groups Administrator directory roles** (the group only delegates post-create
    management); `SyncKerberosPasswords cannot be Disabled` (the API mandates Kerberos hash sync Enabled;
    NTLM and on-prem sync can stay off); and the domain FQDN must be a real org-owned name (immutable
    after create). *Why missed:* all tenant/directory state plus API-mandated values, invisible to plan.
    *Guardrail:* clear the full manifest in pre-clearance; grant the 2 directory roles time-boxed and
    TRACK THEM FOR REVOCATION - they are needed again at destroy (lesson 57) and at any greenfield
    re-create.

45. **AADDS networking: never shadow the NSG default allows; DNS derives from the subnet.**
    *Symptom:* AADDS104 health alert, the second DC never came up, and the create hit its 3-hour timeout
    leaving the domain built in Azure but NOT in state. A custom `Deny-All-Inbound@4000` NSG rule
    overrode the default `AllowVnetInBound` / `AllowAzureLoadBalancerInBound` rules AADDS requires (DC
    replication and the internal load balancer / 168.63.129.16 health path). *Why missed:* the deny rule
    was generic hardening; nothing connects it to a managed service's internal dependencies.
    *Guardrail:* the AADDS subnet NSG carries ONLY the documented required rules - internet inbound is
    already denied by the default `DenyAllInBound@65500`, so a custom low-priority deny adds nothing but
    breakage (ADR-029). Derive the VNet DNS servers as `cidrhost(<aadds subnet>, 4)` and `cidrhost(...,
    5)` fed through the VNet module's own `dns_servers` input - single writer; do not PATCH DNS via
    azapi against an AVM module that asserts `dhcpOptions = null`, they will fight every apply.

46. **Multi-hour creates outlive OIDC federated tokens; do not co-locate them with Graph operations.**
    *Symptom:* `AADSTS700024: Client assertion is not within its valid time range` near the end of a
    3-hour apply - the trailing azuread/Graph resources (a CA policy) fail auth even though the ARM
    resources succeeded. *Why missed:* token lifetime is a CI-environment property, not config.
    *Guardrail:* keep applies short. Once a long-running resource exists, a config-driven `import` block
    (ID interpolated from resources/vars, no hardcoded GUIDs - ADR-029) adopts a built-but-unstated
    resource so future applies are refresh-only seconds. Longer term, split hour-scale creates into their
    own root away from Graph/CA resources. (And remove the import block after it lands - lesson 52.)

47. **Conditional Access failure codes decode to licensing and store-state, not propagation.**
    *Symptom:* all 8 CA policies 403 "tenant is not licensed" (Entra P1/P2 licensing, NOT Graph
    permissions - the trial activation fixed it); the geo-block 1040 "NamedLocation does not exist"
    recurred for days: the named location was created during the UNLICENSED window and the CA policy
    store refused it (delete + recreate under the active license), and the policy must reference the
    named location by `.object_id` (bare GUID), not `.id` (full path). *Why missed:* every one of these
    reads like eventual consistency; retrying fixes none of them. *Guardrail:* verify tenant licensing
    BEFORE creating any CA/named-location object; recreate identity objects born unlicensed; reference
    named locations by `.object_id`; after ONE retry, treat a recurring 1040/403 as state or
    authorization, never propagation.

48. **Graph rejects hallucination-class IDs and first-party app targets with misleading errors.**
    *Symptom:* CA 1103 "non-built in role ids" - two directory-role template GUIDs had correct prefixes
    but wrong tails (the exact hallucination class the anti-hallucination checklist exists for); CA 1034
    `UnsupportedFirstPartyApplication` - the Azure portal first-party app ID cannot be a direct CA app
    target (Microsoft Azure Management covers portal sign-ins); a 403 demanded `Application.Read.All`
    just to PIN app IDs in a policy condition. *Why missed:* GUIDs are opaque; validate cannot know the
    published template list. *Guardrail:* copy role-template GUIDs and app IDs from the published
    Microsoft reference at authoring time, never from memory; target only supported app IDs; grant and
    admin-consent Graph app roles via direct `appRoleAssignments` (grant = consent in one step).

49. **A whole class of Sentinel/Entra resources needs a Security Administrator directory role - 401
    means authorization, not propagation.**
    *Symptom:* tenant-scoped Sentinel data connectors (Azure AD, Threat Intelligence), UEBA / entity
    analytics, and `azurerm_monitor_aad_diagnostic_setting` all 401 while the CI SP's ARM roles were
    fully intact. *Why missed:* these are DIRECTORY-permission operations behind ARM-shaped resources;
    provider docs do not separate them. *Guardrail:* gate every tenant-permission-class resource behind
    a default-false flag (ADR-033) so the root deploys without the grant and the features light up when
    a Security-Administrator-holding principal enables them. Budget exactly one retry to split real
    propagation from authorization, then gate.

50. **Sentinel mechanics: onboarding propagation, cross-subscription KQL, exact enum strings.**
    *Symptom:* connectors and automation rules 400 "workspace not onboarded to Sentinel" even with
    `depends_on` on the onboarding resource (eventual consistency; cleared on the next run); the
    firewall threat-intel scheduled rule 400 "could not locate all the workspaces" TWICE, because a
    name-only `workspace('law-platform-...')` reference cannot resolve across SUBSCRIPTIONS (ADR-034 -
    gated off, re-enable path is a fully-qualified reference + cross-sub RBAC); the
    `azurerm_security_center_automation` Log Analytics action type is `"Workspace"`, not
    `"LogAnalytics"`. *Why missed:* server-side validation of strings the schema happily accepts.
    *Guardrail:* expect one onboarding-propagation rerun; never ship a name-only cross-subscription
    workspace reference in an analytics rule; verify enum strings against provider source, not intuition.

---

## I. State operations, locks, and teardown

51. **State locks orphan: dead CI runners and local plans against a JIT-firewalled SA.**
    *Symptom:* a LOCAL plan acquired the state lease, the machine's egress IP rotated mid-run, the lock
    RELEASE 403'd, and the orphaned lease would have hung the teardown; a second stale lock came from a
    dead runner. A failed init can also leave an empty 0-byte blob `leased` with an EMPTY lock ID, where
    `force-unlock` is useless. *Why missed:* lock hygiene is invisible until the next operation hangs.
    *Guardrail:* never run local plans against the firewalled state SA; build a CI-native `force-unlock`
    action (explicit `lock_id` input, injection-safe env, runs inside the JIT firewall window); for
    empty-ID leases use `az storage blob lease break`; check for stale locks in every teardown
    pre-clearance.

52. **One-shot `import` blocks must be removed immediately after they land - and their `id` must never
    reference a managed resource's attribute.**
    *Symptom:* three incidents from config-driven imports. A later plan broke on an import whose ID no
    longer matched reality. A teardown destroy failed with "Invalid import id argument" because the ID
    interpolated a just-destroyed resource group. Then, **a third time and in the mirror-image
    direction**, a greenfield plan failed with the SAME error because the ID interpolated a resource
    group that did not exist YET (`.id` is "known after apply" before its resource is created). Same
    defect class, opposite trigger: resource already gone versus resource not yet created. *Why
    missed:* the block is inert on the apply where it succeeds, so nothing forces cleanup; and
    `validate` cannot evaluate an import ID at all, so an unplannable ID sits latent until a plan runs
    against a state where the referenced resource is absent. Writing this lesson did not prevent
    recurrence, because the original text described the teardown trigger as the symptom rather than
    naming the underlying rule. *Guardrails, both mandatory:*
    (a) **An import block's `id` MUST be constructible from input variables, locals over variables, and
    string literals ONLY - never from an attribute of a resource Terraform manages.** An import exists
    to adopt something not yet in state, so it may run in a plan where the surrounding resources do not
    exist either. Build the resource ID by string composition
    (`/subscriptions/${var.sub_id}/resourceGroups/${local.rg_name}/providers/...`) rather than reaching
    for `azurerm_resource_group.x.id`. This keeps GUIDs out of committed HCL just as well, so there is
    no trade-off. It is a one-line, greppable check on any import block.
    (b) Every config-driven import ships with a follow-up commit that deletes it as soon as
    `terraform state list` shows the resource adopted. Track the cleanup as blocking, not cosmetic.
    *Related trap, learned in the same incident:* **a `Plan: N to add ...` tally is NOT evidence that a
    plan succeeded.** Terraform renders the hypothetical plan for context even when a resource has
    already errored the run out - observed with the fatal `Error:` emitted 29 milliseconds BEFORE a
    full tally and `Changes to Outputs:` block, all in one stream, ending in a non-zero exit. Judge a
    plan by its EXIT STATUS and the absence of any `Error:` diagnostic, never by the summary line.

53. **Targeted/partial bootstrap applies silently drop declared resources.**
    *Symptom:* first CI init 404 `ContainerNotFound` - the state container was declared in bootstrap but
    the Phase-0 `-target` set never included it (a WORM policy went missing the same way, then caused its
    own incident when the full re-apply added it back - see lesson 3). *Why missed:* `-target` succeeds
    with a warning, and the log said "bootstrap applied". *Guardrail:* after any targeted apply, diff
    `terraform state list` against the config and schedule the full reconcile re-apply; record "applied
    with -target" as "PARTIALLY applied" in the log.

54. **Resource-provider unregistration races async deletes at destroy time.**
    *Symptom:* the identity destroy failed unregistering `Microsoft.AAD` with a 409 while the managed
    domain was still mid-async-delete. *Why missed:* Terraform's graph only knows the delete CALL
    returned, not that Azure's background deletion finished. *Guardrail:* rerun the destroy after the
    deletion settles, or better, do not manage RP registration in the same root as the resources
    (register out-of-band or accept registrations as permanent subscription state).

55. **Resource-group deletes are blocked by service-created artifacts Terraform never owned.**
    *Symptom:* the management RG destroy failed on auto-created Network Watcher Traffic Analytics
    (NWTA-*) objects that nothing in state created. *Why missed:* the artifacts appear only after the
    services have been running. *Guardrail:* lesson 19's `az group delete` control-plane fallback is the
    documented answer for POC teardowns; enumerate and delete strays first only if state fidelity
    matters.

56. **Purge-protected Key Vaults constrain the redeploy window for 90 days.**
    *Symptom:* the security KV soft-deletes at destroy and CANNOT be purged (purge protection); a
    same-name redeploy inside the window 409s unless the provider recovers the soft-deleted vault.
    *Why missed:* destroy reports clean success; the constraint bites the NEXT deploy. *Guardrail:* any
    root with a purge-protected KV documents
    `features { key_vault { recover_soft_deleted_key_vaults = true } }` as the redeploy path, in the
    teardown runbook, BEFORE teardown runs.

57. **Revocation timing: elevated grants stay attached through destroy; directory roles outlive the
    estate.**
    *Symptom:* the MG-scoped Owner grants self-resolved when their MGs were deleted (cascade), but the 2
    temporary AADDS directory roles on the CI SP persisted past the full teardown and needed Graph
    removal by a privileged human - and revoking them EARLY would have 403'd the AADDS delete itself
    (unwinding AADDS directory objects needs them). *Why missed:* nothing ties directory-role lifecycle
    to ARM teardown. *Guardrail:* the teardown runbook carries an explicit revocation list executed
    strictly AFTER a verified-clean destroy: confirm MG-scoped grants cascaded, then remove directory
    roles via Graph (the SP cannot self-revoke them), then VERIFY with a membership query, not
    assumption.

63. **A stale local `.terraform` directory forges 403s - delete it before diagnosing RBAC or firewall.**
    *Symptom:* local `terraform init` on platform/connectivity returned 403 against the state SA and
    looked exactly like a JIT-firewall or RBAC failure; the real cause was a stale `.terraform`
    directory whose cached backend pointer predated backend/root changes. Deleting `.terraform` and
    re-initializing fixed it instantly (B3 batch review, 2026-07-18). *Why missed:* the cached backend
    config is invisible - the error surface is indistinguishable from the two failure classes this
    estate actually has (state-SA firewall windows, scoped RBAC), so diagnosis starts in the wrong
    place. *Guardrail:* on ANY local init/state failure, step zero is `rm -rf .terraform` + re-init
    BEFORE touching firewall rules or role assignments; never "fix" access based on an error produced
    by a stale pointer. (CI is immune - fresh checkout every run - which is also why the failure
    appears only locally.)

---

## J. The operating loop that made deploys land (process lessons)

58. **Pre-clearance before ANY first apply or retry is architect work, and it pays for itself.**
    *Symptom:* the failures that hurt most (Deny-Public-IP vs AADDS, the DDoS placeholder at a second MG,
    missing SQL secrets, missing NetworkWatcher, offer caps, retired flow logs) were ALL knowable in
    advance from live tenant, policy, and lifecycle state. Once the gate existed, would-be apply failures
    repeatedly became dry-run catches: the Defender subplan landmine, a would-be empty-import-variable
    failure, and a synthetic first apply stopped on paper with 3 hard blockers. *Why missed (before):*
    per-diff code review sees the diff; validate sees schema; nobody owned the environment.
    *Guardrail:* no root gets a first apply or a retry without a written per-root pre-clearance: (a) live
    policy matrix at every ancestor MG, (b) tenant/directory prerequisite manifest, (c) public
    known-issues harvest, (d) resource-type lifecycle audit, plus the plan-scan at apply time. It is a
    separate gate from code review, owned by the architect.

59. **After a failed apply: one consolidated fix-spec per failure set, never fix-and-rerun one error at
    a time.**
    *Symptom:* early roots burned 4-6 runs discovering one PUT-time error per run. The turn came with the
    PUT-time constraint sweep (check every still-uncreated resource against documented API constraints
    BEFORE rerunning) and per-failure-set batches: each subsequent security retry strictly NARROWED the
    failure class (three classes, then one, then green). *Guardrail:* diagnose the full error set,
    sweep for the next latent constraint, ship ONE reviewed fix batch, then rerun. Reviews are batched
    per deploy iteration - the reviewer still gates every batch; no self-approval.

60. **Apply-success is not green. QA-verified is green.**
    *Symptom:* "Apply complete" coexisted with: partially-applied roots, a plan that was Standard in
    Azure but absent from state, policy tag churn, mojibake display names, a stuck state lock, and
    gated-off resources that could have silently existed. The post-deploy QA pass (live
    resource-for-resource verification, gated-off resources confirmed ABSENT via state list + az, a
    refreshed plan as the drift check) found real issues on most roots it stamped. *Guardrail:* every
    deployed root gets a post-deploy QA pass validating live state against intent before it is marked
    complete; the final acceptance validation reports honest PASS / FAIL / UNVERIFIED / DEFERRED per
    criterion instead of assumed passes.

61. **Budget for iteration honestly, and keep the log current per action, not per session.**
    *Symptom:* 49 of 92 CI deploy runs failed and were fixed forward - the real shape of a live-tenant
    campaign. Session-end-only logging drifted from reality more than once (roots marked complete that
    had never validated; a stale "clean tree" snapshot). *Guardrail:* schedule for multi-run convergence
    per root; append the worklog after every meaningful action; never trust a prior status line without
    verifying the files/state it claims.

62. **Mechanical rules need deterministic enforcement, not agent memory.**
    *Symptom:* em dashes kept reaching commits (and even ARM display strings, where they render as
    mojibake - lesson 39) despite a written rule: subagents do not inherit user memory, and passive
    style notes get ignored under load. *Guardrail:* enforce mechanical invariants with a pre-commit
    hook (byte/codepoint check on staged additions only) plus an active self-check in each agent
    definition. If a rule matters, it gets a hook, not a habit.

---

## How to use this on the next LZ

Run the loop, not just the checklist:

1. **While authoring:** lessons 20-22 (reconcile every call to the PINNED version's schema, commit
   multi-platform locks, always-on CI validate gate). Sections A and H tell you which arguments, GUIDs,
   and app IDs to verify at write time; never write an ID from memory (22, 37, 48).
2. **Before the FIRST apply of every root, and before every retry: architect pre-clearance (58).**
   Live policy matrix at every ancestor MG (F), tenant/directory prerequisite manifest (B, H),
   subscription offer-cap and quota probe per region (G, 10), resource-type lifecycle audit (40),
   region-coupling map (43), cross-root Secrets verification (32), public known-issues harvest.
3. **At every apply:** plan-scan for `forces replacement` and unexpected destroys (26, 41); read the
   plan against cost intent (28); confirm the run's SHA (33); one state-SA-touching run at a time
   (30, 31).
4. **After a failure:** PUT-time constraint sweep plus one consolidated fix-spec per failure set (59);
   expect each retry to narrow the failure class; treat recurring 401/403/1040 as authorization or
   store-state after one retry, never propagation (47, 49).
5. **After apply-success:** post-deploy QA pass - live state vs intent, gated-off resources confirmed
   absent, refreshed plan as drift check (60). Only then mark the root green. Remove any one-shot
   import blocks now (52).
6. **At teardown:** section I is the runbook skeleton - manual state-firewall window (31), stale-lock
   check (51), elevated grants attached THROUGH destroy and revoked strictly after verification (57),
   RP/RG/KV quirks (54-56), and the `az group delete` fallback (19, 55).

Most of A, C, D, F, I, and J are **landing-zone-agnostic** and carry over directly. B, G, and H are
service-specific - re-derive them from the services your LZ actually deploys, using the same method:
enumerate what each root creates, then check that list against live policy, tenant state, licensing,
offer caps, and the retirement calendar before ARM does it for you.
