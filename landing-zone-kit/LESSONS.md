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
> and lint the workflows. The kit's [`preflight.sh`](templates.md) automates this.
>
> **Proven the hard way (ALZ build):** in the ALZ platform build, **5 of 10 roots the worklog had marked
> 🟢 Complete did not actually `validate`** — because validate was logged "NOT RUN" every session. The
> module calls had drifted from their pinned versions' schemas and nobody knew. See §E.

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

## How to use this on the next LZ

Before the first `apply`, walk A–D and ask "does this apply to my resources?" Most of A (storage/CMK/state,
`for_each` discipline, version-floor) and all of C/D (auth, CI) are **landing-zone-agnostic** and carry
over directly. B is feature-specific — re-derive it from the specific services your LZ deploys (for a
**security** LZ: think Sentinel/Defender onboarding state, Log Analytics solution prerequisites, policy
assignment RBAC, diagnostic-settings-at-scale `for_each` keys).
