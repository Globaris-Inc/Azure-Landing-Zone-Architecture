# scripts/teardown-common.sh - shared constants for the 4-phase teardown (ADR-054).
# Sourced by teardown-disarm.sh, teardown-az-sweep.sh, teardown-verify.sh so the MG scope
# list and the RG naming-pattern match are defined ONCE. Drift between what DISARM clears
# and what VERIFY checks would silently defeat the loud-failure guarantee (design principle
# 5, docs/teardown-redesign.md). Not a standalone script (no shebang execution expected,
# no `set -e` here so it does not change the sourcing script's shell options) - `source` it.
#
# AMENDED 2026-07-20 (ADR-054 amendment, docs/teardown-redesign.md sections 9-10): added the
# token-durability primitives (`az_relogin`, `is_auth_error`, `wait_for_rgs_gone`) used by
# teardown-az-sweep.sh's --no-wait submission pass + bounded reconcile loop, and by the
# auth-fail-loud hardening in teardown-verify.sh. See each function's own comment for the
# locked mechanism it implements.
#
# AMENDED again 2026-07-20 (third amendment / ADR-054 point 12, docs/teardown-redesign.md
# section 12): added `mg_snapshot_load` / `mg_in_snapshot` - the ONE-TIME `az account
# management-group list` snapshot oracle that REPLACES the per-MG `az account management-group
# show <name>` existence probe everywhere in the teardown scripts. See `mg_snapshot_load`'s own
# comment for why: `show` is principal-dependent and returns a 403 (not a 404) for the scoped
# teardown SP on a deleted MG.
#
# AMENDED a fourth time 2026-07-21 (ADR-057, docs/teardown-redesign.md section 12.3): added
# `DEFENDER_PLANS_TO_FREE` and `RP_NAMESPACES_TO_UNREGISTER` - fixed allow-lists consumed by
# the new Phase 2 step 6 (teardown-az-sweep.sh) and by VERIFY 6-8 (teardown-verify.sh). This
# closes the subscription-scope gap: the az sweep finds things by RESOURCE GROUP naming
# pattern and structurally cannot see a subscription-scoped extension resource, a Defender
# pricing plan, or a provider registration - see each array's own comment below for the exact
# coupling it must be kept in lock-step with.
#
# AMENDED a fifth time 2026-07-21 (ADR-062, docs/teardown-redesign.md section 14): added
# `is_owned_policy_object` and `SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST` / `is_subscription_scope_benign`
# - the ownership predicate and the discovery-scan allow-list for subscription-scoped policy
# exemptions (Phase 2 sub-step 6d, teardown-az-sweep.sh) and the Resource Graph discovery scan
# (VERIFY 6d and VERIFY 9, teardown-verify.sh). Root cause: `exempt-dbx-managed-storage-bank-data-p1`
# (a subscription-scoped policy exemption) survived both teardowns and the ADR-057 step 6 sweep
# because its parent scope is a subscription, which is never deleted, so it never cascades away
# on its own - and the existing RG_SWEEP_QUERY filter (`contains(name,'globaris')`) does not
# match it. `is_owned_policy_object` is the ONE shared implementation of the three-limb OWNED
# predicate so the delete side (6d) and the verify side (VERIFY 6d/9) can never drift apart - see
# the function's own comment for the exact limbs and why a naive `contains(name,'globaris')`
# reuse would have shipped as a silent no-op.
#
# AMENDED a sixth time 2026-07-23 (teardown-completeness extension sweep, root cause: the
# 2026-07-23 rebuild failed at Step 2 because a JIT-firewalled state SA and an az-sweep pass
# that skips Phase 1 terraform-destroy leaves scope-path-keyed EXTENSION resources orphaned -
# budgets/diagnostic-settings/policy-exemptions at MG/RG scope are extension resources: their
# ARM ID is formed by appending the provider's own path onto WHATEVER scope they were attached
# to, and Azure Resource Manager does NOT cascade-delete an extension resource just because its
# host scope is deleted. An orphaned MG-scoped exemption then COLLIDES the next time Step 1
# recreates an MG with the same name). Added: the new API-version constants and small discovery
# helpers below, shared by the new read-only probe (scripts/teardown-probe-state.sh,
# scripts/teardown-probe-extensions.sh) and the new Phase 2 sweep sub-steps (FIX-1 through
# FIX-5, teardown-az-sweep.sh) so the probe and the sweep can never drift apart on API version or
# scope math - the same discipline `is_owned_policy_object` already established for the
# exemption predicate. Every api-version constant below was re-verified live against Microsoft
# Learn on 2026-07-23 (not copied from an assumption) - see each constant's own comment for what
# was confirmed and what was corrected from the original brief.
#
# FIX-6 note (state-blob deletion ordering): NONE of the three teardown-phase scripts (disarm,
# az-sweep, verify) contain any reference to the tfstate container or to deleting a Terraform
# state blob - confirmed by a full-repo grep on 2026-07-23 and independently confirmed by
# OPEN-QUESTIONS.md OQ-053 (a prior architect-ruled investigation into two state blobs that went
# missing out-of-band: "the three teardown scripts contain zero references to the tfstate
# container"). There is therefore no existing state-blob DELETE code path for FIX-6 to gate. The
# durable fix implemented here is the one OQ-053 itself recommends (option A(ii) - a state-
# provenance probe, not a gate on a deletion that does not exist):
# scripts/teardown-probe-state.sh is the read-only DETECTION half - it inventories all 12
# known state-blob keys (exists + contentLength) and reports every absent-or-tiny key as a
# Class-A lost-state root. The INVARIANT this codebase must preserve is: if ANY future change
# ever adds a state-blob-delete code path (here or elsewhere), it MUST run that delete strictly
# after a verified destroy for that root - `terraform state list` empty (Phase 1 success) OR a
# completed az-sweep with a confirm-GET 404 on every class at that root's scopes (Phase 2 +
# Phase 3 VERIFY, mirroring VERIFY 9's own ARG-proposes/ARM-disposes confirm pattern) - and
# strictly after Phase 3 VERIFY has passed for target=all. Do not add a blob-delete code path
# without wiring that gate first.
#
# OQ-053's OTHER recommended piece, option A(i) - enabling blob change feed on the state
# Storage Account - is bootstrap Terraform (bootstrap/main.tf), not teardown script logic, and
# is intentionally OUT OF SCOPE for this fix (a different owner/lane and a different PR). Not
# silently dropped: it remains open and tracked as its own item in OPEN-QUESTIONS.md (OQ-053,
# "Recommended default: A now... with B considered if it recurs").
#
# AMENDED a seventh time 2026-07-29 (ADR-066, folds in OQ-063): added the SECURITY_LAW_*
# constants below, consumed by the new Phase 2 step (teardown-az-sweep.sh, "step 3b" as
# originally added, MOVED to "step 7b" 2026-07-30 - code-review Finding 1, see that script's own
# header) that purges the soft-deleted Security Log Analytics workspace. Root cause: absent a
# native purge-on-destroy provider feature, a `platform/security` destroy or RG delete only
# SOFT-deletes the LAW, so a redeploy within the 14-day soft-delete window RECOVERS the
# same-named workspace together with its prior Microsoft.SecurityInsights children (Sentinel
# analytics rules, data connector) - objects the freshly-emptied Terraform state does not know
# about, producing the "already exists" Class 2 failure OQ-063 diagnoses. See that step's own
# comment for the full recover-then-purge mechanism, the resource-group-recreation caveat it is
# built around, and why it is now a BACKSTOP (`platform/security/providers.tf` purges the LAW
# natively on terraform destroy as of 2026-07-30, Cloud Engineer fix).
#
# AMENDED a ninth time 2026-08-01 (ADR-073 decision 4, generalises OQ-063/ADR-066 - resolves
# OQ-069): the SECURITY_LAW_* constants above are RETIRED. Live evidence found a second
# soft-deleted-workspace class member the old single-hardcoded-name purge structurally cannot
# reach: two entries in the management subscription, both named law-platform-globaris-poc,
# sharing ONE ARM resource ID because region is not part of a Log Analytics workspace's ARM
# identity (ADR-073's own context has the full live evidence). SECURITY_LAW_WORKSPACE_NAME and
# SECURITY_LAW_RESOURCE_GROUP_NAME are REMOVED (ADR-062: "an enumerated list plus a promise to
# maintain it is not a control" - this class has now demonstrated a second member).
# SECURITY_LAW_API_VERSION is RENAMED to LAW_PURGE_API_VERSION (same "2025-07-01" value,
# re-verified live 2026-08-01 against Microsoft's own recovery PUT example - it was never
# actually security-specific). Added LAW_PURGE_BLAST_RADIUS_CAP. See the constants' own comment
# block below (where SECURITY_LAW_* used to sit) for the full discovery-based mechanism, and
# teardown-az-sweep.sh's own "step 7b" comment for the two real defects this generalisation also
# fixes (a false-positive completion check when two entries share an ARM ID, and a CLI recover
# verb that cannot select between them at all).
#
# AMENDED a tenth time 2026-08-01 (convergence fast-follow, live incident: teardown runs
# 30719487245 and 30719803427, both target=all mode=az-sweep, identical failure both times -
# "Workspace cannot be deleted while current provisioning state is 'Restoring' please retry in a
# few minutes"). The ninth amendment's own "KNOWN RESIDUAL RISK" note (the recovery PUT does not
# poll provisioningState) fired on first contact, and - because the failed cycle left the
# workspace LIVE rather than soft-deleted - a naive retry was a FIXED POINT, not a transient: the
# next run's own general RG sweep (step 2, teardown-az-sweep.sh) deleted the RG holding the live
# workspace, soft-deleting it again, and step 7b recovered it again and raced the identical
# window. Two fixes, both in `law_purge_soft_deleted_workspaces`: `law_wait_provisioned`, a
# bounded poll for provisioningState="Succeeded" before every force-delete (fails loud, never
# loops forever, never proceeds on an unconfirmed state); and `law_get_live`, an already-live
# pre-check that skips a redundant, race-reintroducing recovery PUT when a prior cycle already
# recovered the workspace at the same location. See LAW_PROVISION_POLL_ATTEMPTS's own comment for
# the poll bound and law_purge_soft_deleted_workspaces's own "FORMER RESIDUAL RISK, NOW CLOSED"
# note for the full incident account.
#
# AMENDED 2026-08-01, SAME DAY, because the two fixes above SHIPPED NON-FUNCTIONAL. Run
# 30722259306 failed a third time, but NOT on the Restoring race - that part worked. The recovery
# PUT succeeded, Azure reported provisioningState=Succeeded within ~30s and held it for 5 minutes,
# and the poll timed out anyway without ever attempting the delete. Cause: `law_get_live` parsed
# `az --query "[location, properties.provisioningState]" -o tsv` as TAB-separated columns, but
# that projection is an array of SCALARS and the CLI emits it one value PER LINE, so `cut -f1` and
# `cut -f2` (which pass delimiter-free lines through untouched without `-s`) both returned the
# whole "centralus\nSucceeded" blob. The poll never matched "Succeeded", and the already-live
# pre-check never matched a plain location, so gap 2 had NEVER fired in any run. The regression
# suite scored 28/28 throughout because its `az` stub emitted a tab; corrected to newline, that
# same suite fails 13 assertions against the pre-fix code. Both call sites are fixed by parsing
# per line, plus a short-read guard that returns indeterminate rather than an empty out-var.
# Class-swept: every other `cut -f` in these scripts reads a `[].[a, b, c]` row projection, which
# IS genuinely tab-separated. This was the only instance.
#
# AMENDED an eighth time 2026-07-30 (transient-list-failure fix round): added `is_transient_error`
# and `az_run_retry` below. Root cause: teardown run 30597640251 died at Phase 2 step 4-pre on a
# single ARM 500 (Internal Server Error) returned for one MG-scope budget LIST call - `az_run` has
# no retry at all, so a transient server blip failed the whole teardown, the VERIFY pass that would
# have run after it, and Phase 4. The identical call succeeded on the immediate rerun (30598510031),
# confirming the failure was transient, not a real finding. The fail-loud rule itself (section 9.4,
# ADR-063 - a failed list must never be read as "empty/clean") is correct and stays UNCHANGED here;
# what was missing is a bounded retry BEFORE that fail-loud path fires, and ONLY for a failure shape
# that is genuinely worth retrying. `az_run_retry` is a drop-in replacement for `az_run` at LIST/GET
# (read) call sites: same signature, same return contract (non-zero + AZ_RUN_STDERR set on the last
# attempt), so every existing caller needed nothing beyond the function name changing. See each
# function's own comment below for the exact classification and retry bounds. Applied at every
# LIST/GET call site across teardown-disarm.sh, teardown-az-sweep.sh, teardown-verify.sh,
# teardown-state-reset.sh, and the two probe scripts (see each file's own header note for what
# changed there) - the ONE exception is `wait_for_rgs_gone`'s own `group exists` call further down
# this file, deliberately left on plain `az_run`: that call already lives inside a loop that never
# fails loud on a non-auth error (it reads an indeterminate/transient result as "still pending" and
# retries on its own next 20s iteration, re-authenticating via `az_relogin` each time) - wrapping it
# in `az_run_retry` too would just nest one bounded retry inside an already-retrying wait for no
# behavioural gain. Never wired in at a DELETE/write call site - see `az_run_retry`'s own comment
# for why.

# ARM management-plane base URL, used by every direct `az rest` call in teardown-disarm.sh,
# teardown-az-sweep.sh, teardown-verify.sh, and scripts/teardown-probe-extensions.sh. Promoted
# here (2026-07-23, teardown-phase0-mg-sweep follow-up) from three separate identical local
# declarations - one constant, sourced once, instead of three copies that could drift.
ARM_BASE="https://management.azure.com"

# The full globaris MG tree: root + all descendants (docs/teardown-redesign.md section 3):
# globaris -> platform -> {connectivity, security, identity, management};
# globaris -> landingzones -> {online, corp}; globaris -> {decommissioned, sandbox}.
# Hardcoded to this hierarchy rather than walked dynamically, so DISARM still runs even if
# `az account management-group list` itself is degraded mid-incident. If the tree is ever
# restructured (an MG added/removed/re-parented under globaris), this list and
# MG_DELETE_ORDER below must be updated together - drift here would leave a scope unswept.
MG_SCOPES=(globaris platform landingzones decommissioned sandbox connectivity identity management security corp online)

# Bottom-up delete order for remove_mg_hierarchy: every leaf before its parent, parents
# before globaris. Matches the live tree above (children listed before platform and
# landingzones; platform/landingzones/decommissioned/sandbox listed before globaris).
MG_DELETE_ORDER=(connectivity security identity management online corp decommissioned sandbox platform landingzones globaris)

# RG naming-pattern match. Every workload/platform RG in this estate is named
# "rg-<workload>-${var.org_prefix}-${var.environment}" (org_prefix=globaris, confirmed
# against platform/*/main.tf and landing-zones/*/main.tf), so "contains globaris" is a
# single catch-all that needs no per-root maintenance as new roots are added (avoids the
# maintenance-coupling downside ADR-054 calls out for an explicit rg-bank-*/rg-corp-*/...
# prefix list). rg-amba-monitoring-001 is the one fixed-name exception (defined directly in
# platform/management-groups and platform/management, not suffixed with org_prefix), so it
# is matched separately by substring rather than relying on the org_prefix suffix.
RG_SWEEP_QUERY="[?contains(name,'globaris') || contains(name,'amba-monitoring')].name"

# Defender for Cloud pricing allow-list for the Phase 2 step 6b reset-to-Free WRITE
# (docs/teardown-redesign.md section 12.3 / ADR-057 decisions 3-5). MUST be kept in
# lock-step with what platform/security actually configures - the same coupling note
# RG_SWEEP_QUERY above carries. Mirrors platform/security exactly: local.defender_basic_plans
# (StorageAccounts, main.tf), the "servers" resource (VirtualMachines, main.tf), and
# local.defender_extended_plans (the remaining six, defender.tf).
#
# Never iterate the LIVE pricing list instead of this allow-list: a live-list loop would
# eventually reset a plan this estate does not own, and setting a plan to Free can be
# permanently irreversible - Microsoft blocks NEW enablement of deprecated plans (LESSON 41).
# That residual risk is tracked as OQ-050, not solved here - do not widen this list without
# updating that item. Never write "Standard" from teardown code; only ever move toward Free.
#
# Explicit never-touch list (must stay OUT of this array): KeyVaults, Arm, Dns,
# KubernetesService, ContainerRegistry, CosmosDbs, Api, AI, Discovery, FoundationalCspm.
DEFENDER_PLANS_TO_FREE=(VirtualMachines StorageAccounts AppServices SqlServers \
                        SqlServerVirtualMachines Containers OpenSourceRelationalDatabases CloudPosture)

# Resource-provider namespaces the teardown must return to a not-Registered state (Phase 2
# step 6c, docs/teardown-redesign.md section 12.3 / ADR-057 decision 6). Only
# Microsoft.CostManagementExports today: platform/management registers it (main.tf) because
# the ADR-027 cost exports need it, and until now the only thing that ever unregistered it
# was a `terraform destroy` of that same resource. One line to extend for a future wave; one
# line to empty if OQ-049 lands (moving registration out of the root removes this need
# entirely, per LESSON 54).
RP_NAMESPACES_TO_UNREGISTER=(Microsoft.CostManagementExports)

# Log Analytics workspace soft-delete purge (ADR-073 decision 4, 2026-08-01) - generalises the
# OQ-063/ADR-066 mechanism (originally a fixed-identifier purge of exactly ONE known object,
# law-security-<org>-<env> in rg-security-<org>-<env>) into a DISCOVERY-based sweep across every
# estate subscription, after live evidence showed a second class member the single-name filter
# structurally cannot reach: two soft-deleted workspaces in the management subscription, both
# named law-platform-globaris-poc, sharing ONE ARM resource ID (region is not part of a Log
# Analytics workspace's ARM identity - see ADR-073's own context). There is no per-workspace
# name/RG constant here any more - teardown-az-sweep.sh step 7b calls
# `list-deleted-workspaces --subscription <sub>` with NO name filter, for every subscription
# `teardown_subscriptions` returns, and decides what to purge with the two safety-bar gates
# below, never with an enumerated list (ADR-062: "an enumerated list plus a promise to maintain
# it is not a control").
#
# Gate A (containment) is NOT a new constant - it reuses `is_estate_owned --resource-id`
# (the existing T1(c) predicate, above) unchanged. This is the correct test specifically BECAUSE
# a soft-deleted workspace's resource group is already gone, so no live RG-existence lookup is
# possible - only a string test on the ARM ID itself is possible.
#
# LAW_PURGE_API_VERSION - Microsoft.OperationalInsights/workspaces (the Create Or Update /
# recovery PUT and the deletedWorkspaces list). "2025-07-01" is the version Microsoft's own
# "Delete and Recover a Log Analytics Workspace" doc uses verbatim in its REST recovery example
# (learn.microsoft.com/en-us/azure/azure-monitor/logs/delete-workspace, ms.date 2024-10-31, page
# re-verified live 2026-08-01). RENAMED from SECURITY_LAW_API_VERSION (same value, unchanged) -
# it was never actually security-specific, it is the Log Analytics workspace API version, used
# for BOTH the recovery PUT (issued via `az rest`, since `az monitor log-analytics workspace
# recover` has no `--location` parameter and cannot select between two entries sharing one ARM
# ID - verified live against the current CLI reference 2026-08-01) and the post-purge
# deletedWorkspaces re-list that replaces the old ARM-GET completion check (that GET is keyed on
# the ARM ID ALONE, so it cannot tell two same-ID entries apart and would report a false
# "purged" the moment either one is gone - ADR-073 decision 4 gate D).
LAW_PURGE_API_VERSION="2025-07-01"

# LAW_PURGE_BLAST_RADIUS_CAP - ADR-073 decision 4 gate B. If discovery (post-containment)
# returns MORE purge-eligible entries than this across the WHOLE estate, step 7b aborts with
# `::error::` and purges NOTHING, rather than acting on a result that large unattended. Set to
# 10: five estate subscriptions, and the live incident this generalisation was built for found at
# most 2 entries in any one subscription (both in `management`) - 10 gives a 5x margin over the
# worst case actually observed while still being small enough that a real over-reach (a wrong
# subscription list, a containment predicate gone wrong) trips it long before it could reach
# double digits. Not derived from a formula - ADR-073 itself says DevSecOps may argue the number,
# not the existence of the cap; revisit if it ever fires on a legitimate run.
LAW_PURGE_BLAST_RADIUS_CAP=10

# LAW_PROVISION_POLL_ATTEMPTS / LAW_PROVISION_POLL_SLEEP_SECONDS - convergence fast-follow
# (2026-08-01, live incident: teardown runs 30719487245 and 30719803427, both target=all
# mode=az-sweep, identical failure both times: "Workspace cannot be deleted while current
# provisioning state is 'Restoring' please retry in a few minutes"). The recovery PUT (gate C)
# is asynchronous - Microsoft's own sample response for this exact PUT shows provisioningState
# "Creating" even on a 200/201 - and a raw `az rest` call does not poll for completion the way
# the CLI's `recover` verb's default behaviour (called without `--no-wait`) would have. This was
# named and consciously deferred as a residual risk when ADR-073 decision 4 landed, and it fired
# on first contact with the live estate, exactly as flagged. No documented Microsoft SLA for this
# transition was found (live-searched 2026-08-01); the bound below is a judgment call, sized the
# same way LAW_PURGE_BLAST_RADIUS_CAP was - generous enough for what the live evidence shows (a
# metadata-level workspace re-creation, not a data restore: the 409 fired within seconds of the
# PUT, not minutes), short enough that a genuinely stuck operation fails loud within a few
# minutes rather than consuming a meaningful slice of the job's own ceiling. 20 attempts, 15s
# apart = 5 minutes total. Revisit if it ever fires on a legitimate run.
LAW_PROVISION_POLL_ATTEMPTS="${LAW_PROVISION_POLL_ATTEMPTS:-20}"
LAW_PROVISION_POLL_SLEEP_SECONDS="${LAW_PROVISION_POLL_SLEEP_SECONDS:-15}"

# law_get_live <out_location_var> <out_state_var> "<url>" - GET the LIVE (non-deleted) workspace
# at <url> (the identical ARM-id URL law_recover_url already builds - live and soft-deleted share
# one URL shape, only the deletedWorkspaces LIST endpoint is different). Populates
# <out_location_var>/<out_state_var> with the resource's current `location` and
# `properties.provisioningState` on success. Return codes:
#   0 = found - the two out-vars are populated.
#   1 = CONFIRMED NOT FOUND (404/NotFound-shaped, including a ResourceGroupNotFound when the RG
#       itself does not exist yet) - safe to read as "not currently live".
#   2 = auth-shaped or INDETERMINATE failure - caller MUST treat as fail loud, never as "not
#       live", the same section-9.4 discipline confirm_gone_by_get already enforces for the
#       mirror-image "confirmed gone" question. A response that parses into fewer than two
#       non-empty fields is INDETERMINATE and returns 2, never a silent empty-string out-var.
# Shared by two call sites in law_purge_soft_deleted_workspaces below - the already-live
# pre-check (gap 2, decides whether to skip the recovery PUT) and the provisioning-state poll
# (gap 1, law_wait_provisioned) - both need the identical GET, so there is one implementation
# rather than two that could drift.
#
# OUTPUT SHAPE, THE DEFECT THAT COST TEARDOWN RUN 30722259306, AND WHY THIS PARSES BY LINE.
# `--query "[location, properties.provisioningState]"` projects a top-level array of SCALARS.
# `-o tsv` renders that as ONE VALUE PER LINE. It emits TAB-separated columns only for a table of
# rows (an array of arrays or objects) - which is why the `[].[id, location]` deletedWorkspaces
# LIST elsewhere in this file IS legitimately tab-separated and read with `cut`. The two shapes
# are different and must be parsed differently.
#
# The original implementation assumed columns and used `cut -f1` / `cut -f2`. POSIX `cut` passes a
# line containing NO delimiter through untouched unless `-s` is given, so on newline-separated
# input BOTH calls returned the entire two-line blob and BOTH out-vars were set to
# "centralus\nSucceeded". Live consequences, both silent:
#   - law_wait_provisioned compared that against "Succeeded" and never matched. Azure reached
#     Succeeded in ~30s and held it for 5 minutes while the poll timed out on a workspace that
#     was ready the whole time, then failed loud without ever attempting the delete.
#   - the gap-2 already-live pre-check compared it against the entry's plain location and could
#     therefore NEVER be true. The mechanism added specifically to break the recover-delete fixed
#     point was dead on arrival and had never once fired.
# The regression suite scored 28/28 throughout, because its `az` stub emitted a TAB. A stub that
# does not reproduce the real tool's output shape does not test the parser at all. The fixture is
# now newline-separated and fails 13 assertions against the pre-fix code.
LAW_GET_LIVE_ERR=""
law_get_live() {
  local __loc_var="$1" __state_var="$2" url="$3"
  # EVERY local here is __law_get_-prefixed ON PURPOSE. This function assigns to CALLER-NAMED
  # variables via `printf -v`, and bash locals are dynamically scoped: a local named `loc` or
  # `state` would SHADOW the caller's out-var of the same name, so `printf -v loc` would write to
  # the shadow and the caller would see nothing (an unbound-variable abort under `set -u`, which
  # is exactly what a plain `local out loc state` caused here). The two call sites in
  # law_purge_soft_deleted_workspaces pass `loc`/`state` and `law_live_loc`/`law_live_state`, so
  # any short generic name is unsafe. Do not rename these to something convenient.
  local __law_get_out __law_get_loc __law_get_state
  LAW_GET_LIVE_ERR=""
  if __law_get_out="$(az rest --method get --url "$url" --query "[location, properties.provisioningState]" -o tsv 2>&1)"; then
    __law_get_loc="$(printf '%s\n' "$__law_get_out" | sed -n '1p')"
    __law_get_state="$(printf '%s\n' "$__law_get_out" | sed -n '2p')"
    # A 200 that does not yield BOTH fields is indeterminate, not "found". Falling through with an
    # empty state would read as a non-Succeeded value and silently exhaust the poll; an empty
    # location would read as a location mismatch and silently re-issue the racy recovery PUT.
    # Both are exactly the class of quiet misread this function exists to prevent.
    if [ -z "$__law_get_loc" ] || [ -z "$__law_get_state" ]; then
      LAW_GET_LIVE_ERR="the GET returned success but the response did not parse into both a location and a provisioningState (raw response: ${__law_get_out})"
      return 2
    fi
    printf -v "$__loc_var" '%s' "$__law_get_loc"
    printf -v "$__state_var" '%s' "$__law_get_state"
    return 0
  fi
  # is_auth_error is checked BEFORE is_not_found_error deliberately (ADR-062 section 9.4): an
  # indeterminate or auth-shaped read must never be misread as "not currently live".
  if is_auth_error "$__law_get_out"; then
    LAW_GET_LIVE_ERR="$__law_get_out"
    return 2
  fi
  if is_not_found_error "$__law_get_out"; then
    return 1
  fi
  LAW_GET_LIVE_ERR="$__law_get_out"
  return 2
}

# law_wait_provisioned "<url>" "<description>" - GATE C-POLL, the gap-1 fast-follow fix
# (LAW_PROVISION_POLL_ATTEMPTS's own comment has the full incident and the bound's
# justification). Bounded poll for the live workspace at <url> to reach provisioningState
# "Succeeded" before the caller force-deletes it. Runs UNCONDITIONALLY before every force-delete
# below, regardless of whether this cycle just issued a fresh recovery PUT or found the
# workspace already live (gap 2) - either path can leave the resource mid-transition, and
# force-deleting one that has not reached a terminal state is the exact 409 the live incident
# hit verbatim. Returns 0 once Succeeded; returns 1 on EVERY other outcome (Failed, not-found
# mid-poll, an auth/indeterminate GET, or the attempt ceiling reached) - all FAIL LOUD, never a
# silent proceed-anyway and never an unbounded loop.
law_wait_provisioned() {
  local url="$1" desc="$2"
  local attempt=1 loc state rc
  while [ "$attempt" -le "$LAW_PROVISION_POLL_ATTEMPTS" ]; do
    law_get_live loc state "$url"
    rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "::error::${desc}: checking provisioningState failed with an auth/transport error or an indeterminate result (attempt ${attempt}/${LAW_PROVISION_POLL_ATTEMPTS}) - cannot safely proceed to delete: ${LAW_GET_LIVE_ERR}"
      return 1
    fi
    if [ "$rc" -eq 1 ]; then
      echo "::error::${desc}: the workspace was not found while polling for provisioningState (expected to be live at this point) - cannot safely proceed to delete."
      return 1
    fi
    if [ "$state" = "Succeeded" ]; then
      return 0
    fi
    if [ "$state" = "Failed" ]; then
      echo "::error::${desc}: provisioningState reported Failed - the recovery did not complete successfully, cannot safely proceed to delete."
      return 1
    fi
    if [ "$attempt" -ge "$LAW_PROVISION_POLL_ATTEMPTS" ]; then
      break
    fi
    echo "    ${desc}: provisioningState is ${state} (attempt ${attempt}/${LAW_PROVISION_POLL_ATTEMPTS}) - waiting ${LAW_PROVISION_POLL_SLEEP_SECONDS}s"
    sleep "$LAW_PROVISION_POLL_SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done
  echo "::error::${desc}: provisioningState never reached Succeeded within ${LAW_PROVISION_POLL_ATTEMPTS} attempts (${LAW_PROVISION_POLL_SLEEP_SECONDS}s apart) - failing loud rather than looping forever or proceeding to delete on an unconfirmed state."
  return 1
}

# law_confirm_purged "<sub>" "<id>" "<location>" "<description>" - ADR-073 decision 4 gate D,
# the per-entry completion check `law_purge_soft_deleted_workspaces` (below) calls after every
# permanent delete. Re-lists deletedWorkspaces in <sub> and fails loud unless NO row matches
# BOTH <id> and <location>. This replaces the PRIOR version's ARM GET on the shared resource ID
# alone, which was a REAL DEFECT once two entries can share an ID: purging ONE of them made that
# GET 404 while the other was still soft-deleted, a FALSE "purged" confirmation. Same
# "caller must treat non-zero as fail loud" contract as confirm_gone_or_fail_primary above.
law_confirm_purged() {
  local sub="$1" id="$2" loc="$3" desc="$4"
  local relist_out
  if ! az_run_retry relist_out monitor log-analytics workspace list-deleted-workspaces \
      --subscription "$sub" --query "[].[id, location]" -o tsv; then
    echo "::error::${desc}: post-purge deletedWorkspaces re-list failed for subscription ${sub} - a failed list is never read as 'purged' (section 9.4): ${AZ_RUN_STDERR}"
    return 1
  fi
  # shellcheck disable=SC2154  # relist_out is assigned indirectly by az_run's printf -v
  local -a relist_rows
  mapfile -t relist_rows <<< "$relist_out"
  local rrow rid rloc
  for rrow in "${relist_rows[@]:-}"; do
    [ -z "$rrow" ] && continue
    rid="$(printf '%s' "$rrow" | cut -f1)"
    rloc="$(printf '%s' "$rrow" | cut -f2)"
    if [ "$rid" = "$id" ] && [ "$rloc" = "$loc" ]; then
      echo "::error::${desc}: still present in the post-purge deletedWorkspaces re-list (id ${id}, location ${loc}) - this class has no separate Phase 3 VERIFY step, so this re-list is the ONLY completion check it will ever get. Treating a remaining match as a hard remnant, not a warning."
      return 1
    fi
  done
  return 0
}

# law_purge_soft_deleted_workspaces - ADR-073 decision 4 (2026-08-01), generalises the
# OQ-063/ADR-066 mechanism (originally a fixed-identifier purge of exactly ONE known object)
# into a DISCOVERY-based sweep across every estate subscription. Called from
# teardown-az-sweep.sh's step 7b - see that call site for WHY it runs where it does (after step
# 7's reconcile). Shared here, not left inline in that flat script, so it can be sourced and
# exercised in isolation with a stubbed `az` (the same reason databricks_force_delete_cascade and
# attachment_sweep_cross_root_objects above are functions rather than inline steps). Returns 0 on
# success (including "nothing found" - idempotent, matching every other class in this codebase),
# 1 on any failure; the caller's own `if ! law_purge_soft_deleted_workspaces; then exit 1; fi`
# turns that into the flat script's usual fail-loud exit.
#
# Root cause this generalisation closes: live evidence found a SECOND soft-deleted-workspace
# class member the old single-name filter structurally could not reach - two entries in the
# management subscription, both named law-platform-globaris-poc, sharing ONE ARM resource ID
# because region is not part of a Log Analytics workspace's ARM identity (ADR-073's own context).
#
# GATE A - CONTAINMENT: every discovered entry is tested with `is_estate_owned --resource-id`
# (the existing T1(c) predicate) before it is eligible for anything below. Correct specifically
# because the entry's resource group is already gone - no live RG-existence lookup is possible,
# only a string test on the ARM ID itself. An entry that fails is SKIPPED with `::warning::`
# naming it - not deleted, not a hard failure.
#
# GATE B - BLAST-RADIUS CAP: if the number of entries that PASS gate A, summed across the whole
# estate, exceeds LAW_PURGE_BLAST_RADIUS_CAP (above), this function ABORTS with `::error::` and
# purges NOTHING. Containment bounds WHICH object is eligible; the cap bounds HOW MANY can be
# acted on unattended - ADR-073 is explicit that only both together make a discovery-based sweep
# safe to run without a human in the loop.
#
# GATE C - RECOVER BY REST PUT, NOT THE CLI VERB, ONLY WHEN NOT ALREADY LIVE: `az monitor
# log-analytics workspace recover` takes only `--workspace-name` and `--resource-group` -
# verified live against the current CLI reference 2026-08-01, it has NO `--location` parameter
# at all, so it physically cannot select between two soft-deleted entries that share an ARM ID.
# Recovery is therefore issued as a raw `az rest --method put` at LAW_PURGE_API_VERSION with an
# explicit `{"location": "<loc>"}` body, matching Microsoft's own documented recovery contract
# verbatim ("Delete and Recover a Log Analytics Workspace", the REST tab, re-verified live
# 2026-08-01). BEFORE issuing this PUT, `law_get_live` checks whether the workspace is already
# live at this exact (rg, name, location) - convergence fast-follow, 2026-08-01, live incident:
# a prior interrupted cycle can leave the workspace already recovered, and re-issuing another PUT
# on an already-live resource only re-triggers a fresh, unnecessary state transition. When
# already live at a MATCHING location, the PUT is skipped entirely and the cycle goes straight
# to the poll below. A live workspace at a DIFFERENT location is not treated as a match (region
# is part of ADR-073 decision 1's four-part key) - the normal PUT still fires, and Azure's own
# conflict rejection is the safety net if that is genuinely unsafe.
#
# GATE C-POLL, convergence fast-follow (2026-08-01, live incident: teardown runs 30719487245 and
# 30719803427, target=all mode=az-sweep, identical failure both times: "Workspace cannot be
# deleted while current provisioning state is 'Restoring' please retry in a few minutes"): a
# bounded poll (`law_wait_provisioned`) for provisioningState to reach "Succeeded" runs BEFORE
# every force-delete, regardless of whether this cycle just recovered the workspace or found it
# already live - either path can leave it mid-transition. See LAW_PROVISION_POLL_ATTEMPTS's own
# comment for the incident and the bound's justification. FAILS LOUD (never loops forever, never
# proceeds to delete on an unconfirmed state) when the poll is exhausted.
#
# GATE D - COMPLETION CHECK BY RE-LIST: see law_confirm_purged above.
#
# ORDERING, MANDATORY: purge cycles are STRICTLY SEQUENTIAL. Every eligible entry runs its full
# recover -> permanently-delete -> re-list-confirm cycle, including its own placeholder RG
# create/delete/confirm-gone, before the next entry's cycle starts. This holds structurally (one
# single-threaded `for` loop, never backgrounded) rather than by detecting which entries share an
# ID - after recovering entry A a LIVE workspace occupies the shared ARM ID, so starting entry
# B's recovery PUT before A is fully purged would be an immutable LOCATION CHANGE on an existing
# resource, which ARM rejects. Placeholder resource groups are created and torn down PER CYCLE,
# and this function WAITS (`wait_for_rgs_gone`) for each placeholder's delete to be confirmed
# gone before the next cycle begins - ADR-073 permits ONE placeholder RG to serve every cycle
# sharing a name (a resource group's own location is independent of what is inside it), but only
# after that is verified live in a run log, which has not happened; this takes the conservative
# fallback the ADR itself names instead of assuming it.
#
# RESOURCE-GROUP-RECREATION CAVEAT (Microsoft's own documented behaviour, unchanged from the
# original single-workspace version): recovering an already soft-deleted workspace is a PUT that
# recreates the workspace inside its ORIGINAL resource group, and fails "ResourceGroupNotFound"
# if that RG no longer exists - which it will not, here, since the owning root's own destroy (or
# teardown-az-sweep.sh's own RG sweep) already removed it. Each cycle recreates a minimal
# placeholder RG (the entry's own RG name, parsed from its ARM ID - never a constant - at the
# entry's own location), recovers the workspace into it, force-purges the workspace, then deletes
# the placeholder RG and waits for it to be confirmed gone.
#
# FORMER RESIDUAL RISK, NOW CLOSED (2026-08-01): the original version of this function accepted,
# as a documented but unclosed risk, that the recovery PUT (a raw `az rest` call) does not poll
# `provisioningState` the way the CLI's own `recover` verb's default behaviour would have. That
# risk fired on first contact with the live estate (teardown runs 30719487245 and 30719803427,
# both target=all mode=az-sweep) - the force-delete raced a still-"Restoring" workspace, 409'd,
# and because the workspace was left LIVE (not soft-deleted) by the failed cycle, a naive retry
# was a FIXED POINT rather than a transient: the next run's own general RG sweep (step 2,
# teardown-az-sweep.sh) deleted the RG containing the live workspace, soft-deleting it again,
# and step 7b recovered it again and raced the exact same "Restoring" window, byte-identical to
# the first failure. The gate C-POLL above (waits for Succeeded before every delete) and the
# already-live check (skips a redundant, race-reintroducing PUT when a prior cycle already
# recovered the workspace) together close this. See LAW_PROVISION_POLL_ATTEMPTS's own comment
# for the poll bound's justification and its own documented limits.
#
# List-call failure: a SUBSCRIPTION-scoped list can never legitimately be gone (section 9.4
# design boundary), so ANY non-zero is FAIL LOUD. Recover/purge-call failure: classify with
# is_auth_error - auth-shaped fails loud; anything else is ALSO fail loud (no separate Phase 3
# VERIFY step exists for this class), same discipline as the original single-workspace version.
law_purge_soft_deleted_workspaces() {
  local law_sub law_sub_rows_out row row_name row_loc row_id row_cid
  local -a law_sub_rows
  local -a law_elig_subs=() law_elig_names=() law_elig_locs=() law_elig_ids=() law_elig_cids=()
  local law_skipped_count=0 law_elig_count
  local law_idx law_name law_loc law_id law_cid law_rg
  local law_rg_exists_out law_purge_rg_created law_rg_create_out
  local law_recover_url law_recover_out law_purge_out
  local law_rg_del_out law_wait_rc
  local law_live_loc law_live_state law_live_rc

  for law_sub in $(teardown_subscriptions); do
    if ! az_run_retry law_sub_rows_out monitor log-analytics workspace list-deleted-workspaces \
        --subscription "$law_sub" \
        --query "[].[name, location, id, properties.customerId]" -o tsv; then
      echo "::error::list-deleted-workspaces failed for subscription ${law_sub} - a failed list is never read as 'not soft-deleted' (section 9.4): ${AZ_RUN_STDERR}"
      return 1
    fi
    # shellcheck disable=SC2154  # law_sub_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t law_sub_rows <<< "$law_sub_rows_out"
    for row in "${law_sub_rows[@]:-}"; do
      [ -z "$row" ] && continue
      row_name="$(printf '%s' "$row" | cut -f1)"
      row_loc="$(printf '%s' "$row" | cut -f2)"
      row_id="$(printf '%s' "$row" | cut -f3)"
      row_cid="$(printf '%s' "$row" | cut -f4)"
      case "$row_id" in
        /subscriptions/*/resourceGroups/*) ;;
        *)
          echo "::error::deleted-workspace id '${row_id}' for ${row_name} (sub ${law_sub}) does not contain a /resourceGroups/ segment - cannot determine which RG to recreate for recovery. Aborting rather than guessing."
          return 1
          ;;
      esac
      if ! is_estate_owned --resource-id "$row_id"; then
        echo "::warning::LAW purge gate A: soft-deleted workspace ${row_name} (location ${row_loc}, sub ${law_sub}, id ${row_id}, customerId ${row_cid}) did NOT pass containment (is_estate_owned --resource-id) - skipping, not this script's business."
        law_skipped_count=$((law_skipped_count + 1))
        continue
      fi
      law_elig_subs+=("$law_sub")
      law_elig_names+=("$row_name")
      law_elig_locs+=("$row_loc")
      law_elig_ids+=("$row_id")
      law_elig_cids+=("$row_cid")
    done
  done

  law_elig_count="${#law_elig_ids[@]}"
  echo "  LAW purge discovery: ${law_elig_count} purge-eligible soft-deleted workspace(s) across the estate (${law_skipped_count} skipped at gate A)."

  if [ "$law_elig_count" -gt "$LAW_PURGE_BLAST_RADIUS_CAP" ]; then
    echo "::error::LAW purge gate B: ${law_elig_count} purge-eligible entries exceeds the blast-radius cap of ${LAW_PURGE_BLAST_RADIUS_CAP} (ADR-073 decision 4) - aborting WITHOUT purging anything. This is a signal the containment predicate or the subscription list is wrong, not an instruction to destroy this many workspaces unattended."
    return 1
  fi

  if [ "$law_elig_count" -eq 0 ]; then
    echo "  No purge-eligible soft-deleted Log Analytics workspaces found in any estate subscription - nothing to do."
    return 0
  fi

  for law_idx in "${!law_elig_ids[@]}"; do
    law_sub="${law_elig_subs[$law_idx]}"
    law_name="${law_elig_names[$law_idx]}"
    law_loc="${law_elig_locs[$law_idx]}"
    law_id="${law_elig_ids[$law_idx]}"
    law_cid="${law_elig_cids[$law_idx]}"
    law_rg="${law_id#*/resourceGroups/}"
    law_rg="${law_rg%%/*}"

    echo "  [$((law_idx + 1))/${law_elig_count}] Purging ${law_name} (sub ${law_sub}, rg ${law_rg}, location ${law_loc}, customerId ${law_cid})"

    if ! az_run_retry law_rg_exists_out group exists --name "$law_rg" --subscription "$law_sub" -o tsv; then
      echo "::error::checking existence of ${law_rg} (sub ${law_sub}) failed - an auth/transport error, not a clean true/false: ${AZ_RUN_STDERR}"
      return 1
    fi
    law_purge_rg_created=0
    if [ "$law_rg_exists_out" != "true" ]; then
      echo "    RG ${law_rg} does not exist (expected - the owning root's own destroy or teardown-az-sweep.sh's own RG sweep already removed it) - recreating as a placeholder so the recover PUT has a container"
      if ! law_rg_create_out="$(az group create --name "$law_rg" --location "$law_loc" \
          --subscription "$law_sub" --tags "Purpose=teardown-law-purge-scratch" --output none 2>&1)"; then
        if is_auth_error "$law_rg_create_out"; then
          echo "::error::creating placeholder RG ${law_rg} (sub ${law_sub}) failed with an auth/transport error: ${law_rg_create_out}"
          return 1
        fi
        echo "::error::creating placeholder RG ${law_rg} (sub ${law_sub}) failed - cannot recover the workspace without it: ${law_rg_create_out}"
        return 1
      fi
      law_purge_rg_created=1
    else
      echo "    RG ${law_rg} already exists - reusing it (not created by this cycle, will not be deleted after purge)"
    fi

    law_recover_url="${ARM_BASE}${law_id}?api-version=${LAW_PURGE_API_VERSION}"

    # GAP 2, convergence fast-follow (2026-08-01, live incident): check whether a LIVE workspace
    # already sits at this exact (rg, name, location) BEFORE issuing a recovery PUT. A prior
    # interrupted cycle - this exact live incident: the force-delete below 409'd on 'Restoring'
    # and the function returned 1, leaving the just-recovered workspace live - means the entry
    # discovery found (from a STALE deletedWorkspaces snapshot, or because this estate's own
    # step 2 RG sweep re-soft-deleted a leftover live workspace on a later run) may already be
    # live by the time this cycle reaches it. Re-issuing another recovery PUT on an
    # already-existing resource only re-triggers a FRESH state transition (Updating, not
    # Restoring, but the identical race) for no reason - this is what turned two consecutive live
    # runs into a byte-identical failure instead of forward progress. A live workspace found at a
    # DIFFERENT location than this entry is deliberately NOT treated as a match (ADR-073
    # decision 1: region is part of the four-part recovery key) - falls through to the normal
    # recovery PUT below, which Azure itself will reject as a conflict if that is genuinely
    # unsafe, rather than this function guessing which entry a mismatched live object belongs to.
    law_get_live law_live_loc law_live_state "$law_recover_url"
    law_live_rc=$?
    if [ "$law_live_rc" -eq 2 ]; then
      echo "::error::checking whether ${law_name} (rg ${law_rg}, sub ${law_sub}) is already live failed with an auth/transport error or an indeterminate result: ${LAW_GET_LIVE_ERR}"
      return 1
    fi
    if [ "$law_live_rc" -eq 0 ] && [ "$law_live_loc" = "$law_loc" ]; then
      echo "    ${law_name} is already LIVE at ${law_loc} (provisioningState ${law_live_state}) - a prior cycle recovered it but did not finish purging it. Skipping the recovery PUT (gate C) and proceeding straight to the provisioning-state wait and force-delete."
    else
      # GATE C: recover by REST PUT (not the CLI verb - see this function's own comment for
      # why), carrying the entry's own location in the body, matching Microsoft's documented
      # recovery PUT.
      if ! law_recover_out="$(az rest --method put --url "$law_recover_url" \
          --body "{\"location\": \"${law_loc}\"}" --output none 2>&1)"; then
        if is_auth_error "$law_recover_out"; then
          echo "::error::recovering ${law_name} (rg ${law_rg}, sub ${law_sub}) via REST PUT failed with an auth/transport error: ${law_recover_out}"
          return 1
        fi
        echo "::error::recovering ${law_name} (rg ${law_rg}, sub ${law_sub}) via REST PUT failed - cannot purge without first recovering it (Microsoft's own documented recover-then-purge sequence): ${law_recover_out}"
        return 1
      fi
    fi

    # GAP 1, convergence fast-follow (2026-08-01, live incident): bounded poll for
    # provisioningState to reach Succeeded BEFORE force-deleting - see
    # LAW_PROVISION_POLL_ATTEMPTS's own comment for the full incident and the bound's
    # justification. This is the direct fix for the exact error the live runs hit verbatim:
    # "Workspace cannot be deleted while current provisioning state is 'Restoring' please retry
    # in a few minutes". Runs regardless of which branch above fired - an already-live workspace
    # can be just as mid-transition as a freshly-recovered one.
    law_wait_provisioned "$law_recover_url" "${law_name} (rg ${law_rg}, sub ${law_sub})" || return 1

    echo "    Force-purging (permanent delete, releases the name) ${law_name} (rg ${law_rg}, sub ${law_sub})"
    if ! law_purge_out="$(az monitor log-analytics workspace delete \
        --resource-group "$law_rg" --workspace-name "$law_name" \
        --subscription "$law_sub" --force --yes --output none 2>&1)"; then
      if is_auth_error "$law_purge_out"; then
        echo "::error::force-purging ${law_name} (rg ${law_rg}, sub ${law_sub}) failed with an auth/transport error: ${law_purge_out}"
        return 1
      fi
      echo "::error::force-purging ${law_name} (rg ${law_rg}, sub ${law_sub}) failed - no separate VERIFY step covers this class, so this is the only completion check it will ever get: ${law_purge_out}"
      return 1
    fi

    # GATE D: re-list, not an ARM GET on the shared id - see law_confirm_purged's own comment.
    law_confirm_purged "$law_sub" "$law_id" "$law_loc" "LAW purge (${law_name}, rg ${law_rg}, sub ${law_sub})" || return 1

    if [ "$law_purge_rg_created" -eq 1 ]; then
      echo "    Deleting placeholder RG ${law_rg} (sub ${law_sub}, created by this cycle) and waiting for it to be confirmed gone before the next cycle"
      if ! law_rg_del_out="$(az group delete --name "$law_rg" --subscription "$law_sub" --yes --no-wait --output none 2>&1)"; then
        if is_auth_error "$law_rg_del_out"; then
          echo "::error::deleting placeholder RG ${law_rg} (sub ${law_sub}) failed with an auth/transport error: ${law_rg_del_out}"
          return 1
        fi
        echo "    ::warning::deleting placeholder RG ${law_rg} (sub ${law_sub}) failed (continuing - VERIFY 2's RG naming-pattern scan will catch it as a remnant if it survives): ${law_rg_del_out}"
      else
        # Ordering, mandatory (see this function's own comment): wait for the placeholder to be
        # confirmed gone before the NEXT cycle in this loop can try to recreate the same-named
        # RG. A ceiling straggler (rc=1) is a warn-and-continue, matching every other RG wait in
        # this codebase - the next cycle's own `az group create` will simply surface a clean,
        # loud failure if the straggler is still mid-delete, rather than this wait silently
        # papering over it.
        wait_for_rgs_gone "$law_sub" "$law_rg"
        law_wait_rc=$?
        if [ "$law_wait_rc" -eq 2 ]; then
          echo "::error::waiting for placeholder RG ${law_rg} (sub ${law_sub}) to be confirmed gone hit an auth/transport failure - failing loud (section 9.4)."
          return 1
        elif [ "$law_wait_rc" -ne 0 ]; then
          echo "    ::warning::placeholder RG ${law_rg} (sub ${law_sub}) did not confirm gone within the wait ceiling - continuing (idempotent retry / VERIFY 2 remain the safety net)."
        fi
      fi
    fi
  done

  return 0
}

# is_owned_policy_object "<name>" "<policyAssignmentId>" - the ADR-062 decision 2 ownership
# predicate (docs/teardown-redesign.md section 14.2), shared by Phase 2 sub-step 6d (what gets
# deleted, teardown-az-sweep.sh) and Phase 3 VERIFY 6d / VERIFY 9 (what VERIFY expects to be
# gone, and how VERIFY 9's discovery scan classifies a row as OWNED, teardown-verify.sh). ONE
# implementation so the delete side and the verify side can never drift apart - that exact drift
# (an enumerated class list VERIFY checks against a DIFFERENT filter than what the sweep
# deletes) is the failure mode ADR-062 exists to close.
#
# OWNED if ANY of three limbs holds (deliberately redundant on the known survivor - see ADR-062
# decision 2 - a single limb being wrong about some future object must not silently drop it):
#   Limb 1 (structural, primary): policyAssignmentId contains "/managementGroups/<mg>/" for any
#     <mg> in MG_SCOPES, matched with BOTH slashes present as a literal substring test (not a
#     prefix/suffix test), so a longer MG name cannot match - "/managementGroups/corp/" must
#     appear verbatim, so "corporate" cannot satisfy "corp". Durable across the MG's own
#     deletion: the exemption's stored policyAssignmentId string does not change when the MG it
#     names is later deleted.
#   Limb 2 (naming): name begins with "exempt-".
#   Limb 3 (org, inherited convention): name contains "globaris".
#
# Do NOT collapse this to `contains(name,'globaris')` alone - that is the existing RG/KV sweep
# filter (RG_SWEEP_QUERY above) and it does NOT match the live survivor
# (exempt-dbx-managed-storage-bank-data-p1, which has no globaris substring). A naive reuse
# would ship as a silent no-op; this is the second time that exact trap has fired on this
# codebase (the first was the diag-activity-to-security-law special case in step 6a). Limbs 1
# and 2 both match the live survivor, redundantly, by design.
#
# The second positional arg may be empty - VERIFY 9's discovery scan applies this SAME predicate
# to policy-plane row types other than exemptions (a policy ASSIGNMENT row carries no
# policyAssignmentId of its own), per docs/teardown-redesign.md section 14.3 point 1 ("for any
# other type, the same name limbs plus the assignmentId limb"). An empty assignment_id simply
# never matches limb 1 and the test falls through to limbs 2/3 on name alone, which is correct.
is_owned_policy_object() {
  local name="${1:-}" assignment_id="${2:-}"
  local mg
  for mg in "${MG_SCOPES[@]}"; do
    case "$assignment_id" in
      */managementGroups/"${mg}"/*) return 0 ;;
    esac
  done
  case "$name" in
    exempt-*) return 0 ;;
    *globaris*) return 0 ;;
  esac
  return 1
}

# SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST - the ADR-062 decision 6 allow-list
# (docs/teardown-redesign.md section 14.3) consumed by VERIFY 9's discovery scan
# (teardown-verify.sh) only - sub-step 6d and VERIFY 6d never consult it (they only ever handle
# policy exemptions, all of which are estate-owned-or-skipped by is_owned_policy_object). A row
# VERIFY 9 finds that is NOT estate-owned (does not match is_owned_policy_object) but IS a known,
# benign, Microsoft-auto-provisioned object is a PASS only if its exact "type|name" pair is a key
# here. Matching is EXACT type plus EXACT name - NEVER a substring, NEVER a wildcard - so the
# list can only grow deliberately, via a reviewed PR with a dated justification comment. Anything
# else at subscription scope that is neither OWNED nor on this list is UNCLASSIFIED and fails the
# run loud under the TEARDOWN-VERIFY-UNCLASSIFIED label - see is_subscription_scope_benign below.
#
# Seeded 2026-07-21 (ADR-062 decision 6) with the two rows found in the live baseline scan across
# all 5 subscriptions (docs/teardown-redesign.md section 14.3): both are Microsoft
# system-created policy assignments, and neither is declared anywhere in this repo.
declare -gA SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST=(
  ["microsoft.authorization/policyassignments|SecurityCenterBuiltIn"]=1
  ["microsoft.authorization/policyassignments|SqlVmAndArcSqlServersProtection"]=1
)

# is_subscription_scope_benign "<type>" "<name>" - exact-match test against
# SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST. `type` is lowercased before the lookup (Resource Graph's
# own `type` column is always lowercase, confirmed against the live VERIFY 9 baseline) so a
# caller does not have to get casing exactly right; `name` is matched byte-for-byte, never
# case-folded (allow-list membership must stay exact per decision 6). Returns 0 (true, benign) on
# an exact pair match, 1 (false) otherwise.
is_subscription_scope_benign() {
  local type_lc name
  type_lc="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  name="${2:-}"
  [ -n "${SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST["${type_lc}|${name}"]+x}" ]
}

# ---------------------------------------------------------------------------
# ADR-063 decision 6 (2026-07-23): the T1/T2/T3 CONTAINMENT-based ownership predicate.
# Retires the name-only test as the PRIMARY ownership test. T3 (is_owned_policy_object /
# is_globaris_owned above) stays in force UNCHANGED as the last-resort tier - see each
# function's own comment above. ONE shared implementation (is_estate_owned, at the bottom of
# this block) is wired into the Phase-0 MG-scope sweep (teardown-disarm.sh) and into
# FIX-1/FIX-2/FIX-4 (teardown-az-sweep.sh) and VERIFY 6e/10 (teardown-verify.sh), so every one
# of those sites classifies the same object the same way and can never drift apart.
#
# Root cause this closes (ADR-063): two live estate objects were classified UNOWNED by the
# name-only predicate even though both were provably estate-created - diag-aa-to-law (a
# resource-scoped diagnostic setting whose host resource lives inside
# rg-management-globaris-poc) and securityContacts/default (whose name is dictated by the Azure
# API, not by this estate's Terraform - azurerm_security_center_contact's configured name is
# never what ends up live, see is_singleton_owned's own comment below). Neither carries a name
# the old predicate could ever match, so a correctly-ordered sweep would still have walked past
# both.
#
# T1 CONTAINMENT (primary, structural) - is_mg_owned / is_rg_owned / is_resource_in_owned_rg.
# An object is owned if its HOST SCOPE is owned:
#   (a) an MG in MG_SCOPES.
#   (b) an RG matching RG_SWEEP_QUERY (the same pattern the RG sweep and every
#       discover_live_rgs caller already use).
#   (c) any resource whose id contains "/resourceGroups/{rg}/" where {rg} matches (b), AND
#       whose subscription segment is one of the 5 estate subscriptions
#       (is_estate_subscription) - binds the anti-widening rule structurally rather than
#       relying on every caller only ever looping over the 5 known subscriptions.
# T1 claims strictly LESS than the sweep already claims: step 2 deletes the entire RG and step 4
# deletes the entire MG (when remove_mg_hierarchy=true). If T1 is ever wrong about an object, the
# sweep was already wrong about its much larger HOST - so this is not a widening of blast radius,
# it closes a gap the sweep already implied. T1 may NEVER be inverted (owning a child never
# implies owning its host) - none of the three helpers below ever tests a CHILD to conclude
# something about its PARENT.
#
# T2 FIXED-NAME SINGLETON - is_singleton_owned. For a singleton whose NAME AZURE ITSELF
# dictates (not this estate's Terraform), ownership is: the scope is one of the 5 estate
# subscriptions (is_estate_subscription) AND the resource type exact-matches an entry in
# ESTATE_DECLARED_SINGLETON_TYPES. The object's own NAME is never consulted - that is the whole
# point of this tier. Seeded with Microsoft.Security/securityContacts (ADR-063 decision 7: the
# live object is always named "default", pinned by the API's own
# `securityContactName: pattern ^(default)$` constraint at api-version 2023-12-01-preview - no
# Terraform-configured name can ever change that; see platform/security/main.tf's
# azurerm_security_center_contact.this block). Grows only by reviewed PR with a dated
# justification, the same discipline SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST already uses. Defender
# pricing plans stay on the separate DEFENDER_PLANS_TO_FREE allow-list (ADR-057 decision 5);
# autoProvisioningSettings / workspaceSettings keep their existing no-predicate treatment (both
# are reverted-to-baseline WRITES on a known fixed surface, not delete-if-owned classifications -
# see FIX-4(iv)'s own comment, teardown-az-sweep.sh).
#
# T3 NAME (retained, last resort) - is_owned_policy_object / is_globaris_owned, UNCHANGED.
# Applies to objects whose host scope is NOT itself estate-owned under T1 (subscription-scope
# non-singletons, tenant scope) - never as a substitute for T1 where containment already
# applies.
#
# Anti-widening rules (binding): T1 may never be inverted (see above). T1(c) and T2 may never
# match outside the 5 estate subscription ids - enforced STRUCTURALLY inside
# is_resource_in_owned_rg and is_singleton_owned via is_estate_subscription, not left to caller
# discipline alone. T2's type list is exact-match only (case-insensitive on the type string,
# exact on the value - same discipline SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST already uses) and
# grows only by reviewed PR with a dated justification.
# ---------------------------------------------------------------------------

# is_mg_owned "<mg>" - T1(a). True if <mg> is a member of MG_SCOPES (the full, hardcoded
# globaris tree this estate owns - see MG_SCOPES's own comment above). Deliberately does NOT
# consult mg_snapshot/mg_in_snapshot - existence and ownership are different questions; a caller
# that also needs to know whether the MG currently EXISTS must check mg_in_snapshot separately
# (every call site in this codebase already does, before it ever reaches an ownership question).
is_mg_owned() {
  local mg="${1:-}" m
  for m in "${MG_SCOPES[@]}"; do
    [ "$m" = "$mg" ] && return 0
  done
  return 1
}

# is_rg_owned "<rg-name>" - T1(b). The SAME test RG_SWEEP_QUERY encodes as a JMESPath filter
# (contains(name,'globaris') || contains(name,'amba-monitoring')), re-expressed as a bash case so
# a caller that already has a bare RG name in hand (rather than a fresh JMESPath list) can test
# it directly. Kept in lock-step with RG_SWEEP_QUERY BY HAND - the same maintenance coupling that
# constant's own comment already documents; if the naming convention ever changes, update both
# together.
is_rg_owned() {
  case "${1:-}" in
    *globaris*|*amba-monitoring*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_estate_subscription "<sub-id>" - true if <sub-id> is one of the 5 subscription IDs this
# estate spans (teardown_subscriptions, above). Structural backing for the T1(c)/T2
# anti-widening rule - never hardcodes a subscription ID (populated from the same
# job-environment GitHub Secrets teardown_subscriptions already reads).
is_estate_subscription() {
  local target="${1:-}" s
  for s in $(teardown_subscriptions); do
    [ "$s" = "$target" ] && return 0
  done
  return 1
}

# is_resource_in_owned_rg "<arm-resource-id>" - T1(c). True if <arm-resource-id> both (i) names
# a subscription that is one of the 5 estate subscriptions (is_estate_subscription - binds the
# anti-widening rule structurally, not just by caller-loop discipline) and (ii) contains
# "/resourceGroups/{rg}/" where {rg} satisfies is_rg_owned. Matches ADR-063 decision 6's literal
# T1(c) wording ("any resource whose id contains /resourceGroups/{rg}/ where {rg} matches
# RG_SWEEP_QUERY"). Literal "/resourceGroups/" segment match only (ARM's own canonical casing,
# the casing every `az` list/show call in this codebase already returns ids in) - not a
# case-insensitive scan, matching how the policyAssignmentId limb in is_owned_policy_object
# above is also a literal-substring test, not a normalized one.
is_resource_in_owned_rg() {
  local id="${1:-}" sub rg
  case "$id" in
    /subscriptions/*/resourceGroups/*)
      sub="${id#/subscriptions/}"
      sub="${sub%%/*}"
      is_estate_subscription "$sub" || return 1
      rg="${id#*/resourceGroups/}"
      rg="${rg%%/*}"
      is_rg_owned "$rg"
      ;;
    *) return 1 ;;
  esac
}

# ESTATE_DECLARED_SINGLETON_TYPES - the T2 type list (ADR-063 decision 6). Exact-match only
# (case-insensitive on the string, never a substring/wildcard) - grows only by reviewed PR with a
# dated justification, mirroring SUBSCRIPTION_SCOPE_BENIGN_ALLOWLIST's own discipline.
#   - Microsoft.Security/securityContacts: seeded 2026-07-23 (ADR-063 decision 7). The live
#     object is always named "default" - pinned by the API's own `securityContactName` regex
#     constraint (`^(default)$`, api-version 2023-12-01-preview) - regardless of what name this
#     estate's Terraform configures. The name-only predicate could never match this object,
#     which is exactly why FIX-4(i) and VERIFY 6e were certifying the subscription clean with it
#     still live (ADR-063 decision 7).
declare -ga ESTATE_DECLARED_SINGLETON_TYPES=("Microsoft.Security/securityContacts")

# is_singleton_owned "<sub-id>" "<type>" - T2. True if <sub-id> is one of the 5 estate
# subscriptions (is_estate_subscription) AND <type> exact-matches (case-insensitive) an entry in
# ESTATE_DECLARED_SINGLETON_TYPES. The object's own NAME is NEVER consulted - callers must not
# pass a name to this function and must not gate on one themselves; that is what distinguishes
# this tier from T3.
is_singleton_owned() {
  local sub="${1:-}" type="${2:-}" type_lc want want_lc
  is_estate_subscription "$sub" || return 1
  type_lc="$(printf '%s' "$type" | tr '[:upper:]' '[:lower:]')"
  for want in "${ESTATE_DECLARED_SINGLETON_TYPES[@]}"; do
    want_lc="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
    [ "$type_lc" = "$want_lc" ] && return 0
  done
  return 1
}

# is_estate_owned - THE single dispatcher for the ADR-063 decision 6 three-tier predicate. Every
# call site (the Phase-0 MG-scope sweep, FIX-1/FIX-2/FIX-4 in teardown-az-sweep.sh, VERIFY 6e/10
# in teardown-verify.sh) goes through this one function, so none of them can independently drift
# on what "owned" means. The tier is selected explicitly by the caller via its first argument,
# because each tier's inputs are shaped differently (an MG name is not an RG name is not a
# resource id is not a sub+type pair) - "one shared implementation" means one place where all
# three tiers are defined and reachable under one name, not one call signature.
#
#   is_estate_owned --mg          "<mg-name>"                  T1(a)
#   is_estate_owned --rg          "<rg-name>"                  T1(b)
#   is_estate_owned --resource-id "<arm-resource-id>"           T1(c)
#   is_estate_owned --singleton   "<sub-id>" "<type>"           T2
#   is_estate_owned --name        "<name>" ["<assignment-id>"]  T3 (delegates to
#                                                                    is_owned_policy_object,
#                                                                    UNCHANGED from ADR-062)
is_estate_owned() {
  case "${1:-}" in
    --mg)          is_mg_owned "${2:-}" ;;
    --rg)          is_rg_owned "${2:-}" ;;
    --resource-id) is_resource_in_owned_rg "${2:-}" ;;
    --singleton)   is_singleton_owned "${2:-}" "${3:-}" ;;
    --name)        is_owned_policy_object "${2:-}" "${3:-}" ;;
    *)             return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Extension-resource sweep constants (teardown-completeness fix, 2026-07-23).
# Shared by scripts/teardown-probe-extensions.sh (report-only) and the new
# FIX-1..FIX-5 sub-steps in teardown-az-sweep.sh (report-and-delete), so the
# probe and the sweep can never read a different API version for the same
# class - the exact drift ADR-062 already closed once for policy exemptions.
#
# Each constant's provenance (re-verified live against Microsoft Learn on
# 2026-07-23, not carried over from assumption):
#   BUDGETS_API_VERSION - Microsoft.Consumption/budgets. 2024-08-01 confirmed
#     current (learn.microsoft.com/en-us/rest/api/consumption/budgets/list).
#     Uniform across MG/subscription/RG scope (Consumption budgets are scope-
#     parametrised, not scope-specific API surfaces).
#   POLICY_EXEMPTIONS_API_VERSION_NEW - Microsoft.Authorization/policyExemptions.
#     Same pin as sub-step 6d's existing inline literal (2022-07-01-preview -
#     this type has no GA version). Kept as its OWN constant rather than
#     retrofitting 6d/VERIFY 6d's existing inline literals, to avoid touching
#     tested code outside this fix's scope - the two must still be kept in
#     lock-step by hand if either is ever re-verified.
#   MG_DIAGNOSTIC_SETTINGS_API_VERSION - management-GROUP diagnostic settings
#     are a DISTINCT operation group from resource/subscription diagnostic
#     settings ("Management Group Diagnostic Settings", not the generic
#     "Diagnostic Settings" op group), pinned at 2020-01-01-preview
#     (learn.microsoft.com/en-us/rest/api/monitor/management-group-diagnostic-settings/list).
#     CORRECTION from the original brief, which assumed the generic
#     2021-05-01-preview applies uniformly to every scope - it does not; MG
#     scope needs this older, distinct preview version. Verified live 2026-07-23.
#   RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION - the generic per-resource
#     "Diagnostic Settings - Get/List" op group, 2021-05-01-preview confirmed
#     current (learn.microsoft.com/en-us/rest/api/monitor/diagnostic-settings/get).
#     Used for resource-scoped diagnostic settings on resources inside a
#     surviving RG. Subscription-scope (activity log) stays on the existing
#     `az monitor diagnostic-settings subscription list/delete` CLI wrapper
#     (already used by step 6a / VERIFY 6) rather than a raw api-version pin.
#   TENANT_AAD_DIAGNOSTIC_SETTINGS_API_VERSION - Microsoft.AadIam/diagnosticSettings,
#     tenant-scoped (no subscription/RG segment in the URL). 2017-04-01
#     confirmed current and the only version documented
#     (learn.microsoft.com/en-us/azure/templates/microsoft.aadiam/2017-04-01/diagnosticsettings).
#   SECURITY_PRICINGS_API_VERSION - Microsoft.Security/pricings, 2024-01-01.
#     Same pin already used and verified by VERIFY 7 (teardown-verify.sh) -
#     reused here unchanged, not re-derived.
#   SECURITY_CONTACTS_API_VERSION - Microsoft.Security/securityContacts.
#     CORRECTION from the original brief's 2020-01-01-preview guess: the
#     current live List/Create/Delete op group is 2023-12-01-preview
#     (learn.microsoft.com/en-us/rest/api/defenderforcloud/security-contacts/list).
#     2020-01-01-preview still exists only as an older ARM-template schema
#     version, not the current REST surface. Verified live 2026-07-23.
#   SECURITY_AUTOMATIONS_API_VERSION - Microsoft.Security/automations,
#     2023-12-01-preview confirmed current
#     (learn.microsoft.com/en-us/rest/api/defenderforcloud/automations).
#     Matches the original brief.
#   SECURITY_AUTOPROVISIONING_API_VERSION / SECURITY_WORKSPACESETTINGS_API_VERSION -
#     Microsoft.Security/autoProvisioningSettings and Microsoft.Security/workspaceSettings,
#     both 2017-08-01-preview confirmed current (only version documented for
#     either op group - learn.microsoft.com/en-us/rest/api/defenderforcloud/auto-provisioning-settings/list
#     and .../workspace-settings/update). Neither is Terraform-managed anywhere
#     in this repo (grep-confirmed, platform/security) - "baseline" for FIX-4
#     therefore means Azure's own unconfigured default, not a Terraform value.
#   AADDS_DOMAINSERVICES_API_VERSION - Microsoft.AAD/domainServices, 2022-12-01
#     confirmed current and the latest documented version
#     (learn.microsoft.com/en-us/azure/templates/Microsoft.AAD/2022-12-01/domainservices).
#     Matches the original brief. REPORT ONLY everywhere in this codebase - an
#     existing AADDS domain is imported (platform/identity's existing
#     TF_VAR_aadds_import_replica_set_id mechanism, ADR-029/ADR-055), never
#     deleted or recreated by teardown tooling (FIX-7 note, below).
BUDGETS_API_VERSION="2024-08-01"
POLICY_EXEMPTIONS_API_VERSION_NEW="2022-07-01-preview"
MG_DIAGNOSTIC_SETTINGS_API_VERSION="2020-01-01-preview"
RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION="2021-05-01-preview"
TENANT_AAD_DIAGNOSTIC_SETTINGS_API_VERSION="2017-04-01"
SECURITY_PRICINGS_API_VERSION="2024-01-01"
SECURITY_CONTACTS_API_VERSION="2023-12-01-preview"
SECURITY_AUTOMATIONS_API_VERSION="2023-12-01-preview"
SECURITY_AUTOPROVISIONING_API_VERSION="2017-08-01-preview"
SECURITY_WORKSPACESETTINGS_API_VERSION="2017-08-01-preview"
AADDS_DOMAINSERVICES_API_VERSION="2022-12-01"

# The fixed tenant AAD diagnostic setting name (platform/security/diagnostics.tf,
# azurerm_monitor_aad_diagnostic_setting.security_law) - NOT org-prefixed, same special-case
# class as diag-activity-to-security-law in step 6a. Kept as its own constant (rather than an
# inline literal repeated in the probe and in FIX-5) so the two can never drift.
TENANT_AAD_DIAG_SETTING_NAME="diag-aad-to-security-law"

# mg_scope_path "<mg>" - echoes the ARM scope path for a management group. Small helper so
# FIX-1 (teardown-az-sweep.sh) and the probe (scripts/teardown-probe-extensions.sh) build the
# identical scope string VERIFY 1 already uses inline (teardown-verify.sh) instead of each
# re-deriving it.
mg_scope_path() {
  printf '/providers/Microsoft.Management/managementGroups/%s' "${1:-}"
}

# is_globaris_owned "<name>" - the simple single-limb ownership test already used inline by
# step 6a (budgets/exports/scheduled actions) and reused here for the NEW classes this fix adds
# (security contacts, security automations, tenant AAD diagnostic setting) whose Terraform-
# defined names all carry a `globaris` substring (security-contact-globaris,
# automation-mdc-export-globaris-<env>) - confirmed against platform/security/main.tf and
# platform/security/defender.tf. NOT used for policy exemptions (those use the three-limb
# is_owned_policy_object predicate above, which is deliberately broader) and not used for the
# tenant AAD diagnostic setting (that one matches by exact name, TENANT_AAD_DIAG_SETTING_NAME,
# the same special-case pattern step 6a already uses for diag-activity-to-security-law).
is_globaris_owned() {
  case "${1:-}" in
    *globaris*) return 0 ;;
    *) return 1 ;;
  esac
}

# discover_live_rgs <out_var> <sub> - list every currently-live RG in <sub> that matches the
# SAME RG_SWEEP_QUERY naming-pattern filter step 2's RG sweep already uses, via az_run_retry
# (stdout/stderr kept separate, Finding #2 discipline; bounded retry on a transient 5xx/429,
# 2026-07-30 fix round - see this file's "AMENDED an eighth time" header note). Shared discovery
# primitive for every NEW RG-scope check this fix adds (FIX-2 budgets, FIX-3 exemptions, the
# probe's RG-scoped budgets/exemptions/diagnostic-settings sections) - discovery BY LIST, never a
# hardcoded RG name list, matching the lesson ADR-062 already drew ("enumerated class lists are the
# wrong mechanism") and step 6a's own stated design ("Discovery is by LIST, never a hardcoded name
# list, so a renamed or added object is still caught"). Returns az_run_retry's own exit code -
# callers MUST treat a non-zero return as FAIL LOUD (a live subscription's RG list can never
# legitimately fail, same section 9.4 boundary as every other subscription-scoped list in this
# codebase), not as "no RGs".
discover_live_rgs() {
  local __out_var="$1" __sub="$2"
  az_run_retry "$__out_var" group list --subscription "$__sub" --query "$RG_SWEEP_QUERY" -o tsv
}

# sweep_resource_diagnostic_settings - deletes every estate-owned RESOURCE-scoped
# `microsoft.insights/diagnosticSettings` object reachable while its host resource is still LIVE.
# Enumeration shape: teardown_subscriptions -> discover_live_rgs -> `az resource list` per RG ->
# diagnosticSettings LIST per resource id -> DELETE + confirm-GET per name.
#
# EXTRACTED 2026-08-01 from teardown-az-sweep.sh's inline Phase 2 step 2-pre (ADR-071 decision 4b),
# unchanged in behaviour, api-version, containment predicate, failure handling and confirm-GET. It
# is shared for exactly the reason `databricks_force_delete_cascade` is: there are now TWO call
# sites (Phase 0.5 precascade and Phase 2 step 2-pre) and they must not drift on the az invocation.
# The ONLY difference from the original inline body is `return 1` where it said `exit 1`, so the
# caller decides whether a failure is fatal - the two callers genuinely differ on that.
#
# WHY A SECOND CALL SITE EXISTS AT ALL (ADR-071 decision 4b, the ordering regression). Step 2-pre
# can only see a setting whose HOST IS STILL LIVE, and it sits in Phase 2, which `needs` all of
# Phase 1. Under ADR-066 `mode=terraform` at `target=all` runs the per-root `terraform destroy`
# jobs FIRST, deleting the hosts, after which no enumeration can reach any setting the destroying
# root did not hold in state. So on the mode=terraform path the sweep is structurally unable to
# catch the residue it was written for. This is the identical shape ADR-066 decision 4 found for
# Databricks and fixed by moving the operation to a Phase 0.5 job that runs while the target is
# still live. G-1 / FM-3: a diagnosticSettings object is keyed to its host's URI, outlives the
# host, outlives the state, and is invisible to every discovery-based greenfield proof - which is
# why it silently re-collides on the next apply that recreates a same-named host, and why the fix
# has to happen at teardown rather than at apply.
#
# LIST-FAILURE HANDLING DIFFERS FROM EVERY OTHER LIST IN THIS CODEBASE, deliberately. A
# resource-scoped diagnosticSettings GET can legitimately 404/BadRequest for a resource TYPE that
# does not support diagnostic settings at all (most do; some do not). Only an AUTH-shaped failure
# fails loud; any other failure is expected noise and skips that one resource. It is never read as
# "this resource has no diagnostic settings" for a class that never existed on it.
sweep_resource_diagnostic_settings() {
  local sub rg res_id name
  local rgnames_out rgnames resource_ids_out resource_ids diag_names_out diag_names diag_url diag_del_out
  for sub in $(teardown_subscriptions); do
    if ! discover_live_rgs rgnames_out "$sub"; then
      echo "::error::RG list failed for subscription ${sub} while discovering resource-scoped diagnostic-settings targets - a failed list is never read as 'no RGs' (section 9.4): ${AZ_RUN_STDERR}"
      return 1
    fi
    mapfile -t rgnames <<< "$rgnames_out"
    for rg in "${rgnames[@]:-}"; do
      [ -z "$rg" ] && continue
      if ! az_run_retry resource_ids_out resource list --resource-group "$rg" --subscription "$sub" --query "[].id" -o tsv; then
        echo "::error::resource list failed for RG ${rg} (sub ${sub}) while enumerating resources for the resource-scoped diagnostic-settings sweep: ${AZ_RUN_STDERR}"
        return 1
      fi
      mapfile -t resource_ids <<< "$resource_ids_out"
      for res_id in "${resource_ids[@]:-}"; do
        [ -z "$res_id" ] && continue
        if ! az_run_retry diag_names_out rest --method get \
            --url "${ARM_BASE}${res_id}/providers/Microsoft.Insights/diagnosticSettings?api-version=${RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION}" \
            --query "value[].name" -o tsv; then
          if is_auth_error "$AZ_RUN_STDERR"; then
            echo "::error::resource-scoped diagnostic-settings list failed for ${res_id} with an auth/transport error: ${AZ_RUN_STDERR}"
            return 1
          fi
          # Expected noise for a resource type that does not support diagnostic settings at all -
          # not a class that "has none"; skip this resource, not the whole sweep.
          continue
        fi
        mapfile -t diag_names <<< "$diag_names_out"
        for name in "${diag_names[@]:-}"; do
          [ -z "$name" ] && continue
          if ! is_estate_owned --resource-id "$res_id"; then
            # Structurally unreachable (res_id came from a discover_live_rgs-filtered RG) - kept
            # as a hard stop rather than a silent skip, same defensive posture as every other
            # "should be impossible" branch this class's original fix added.
            echo "::error::resource-scoped diagnostic setting ${name} on ${res_id} did not classify as estate-owned by is_estate_owned - this should be structurally impossible for a resource inside an RG_SWEEP_QUERY-matched RG. Failing loud rather than silently skipping."
            return 1
          fi
          echo "  Deleting resource-scoped diagnostic setting ${name} (resource ${res_id})"
          diag_url="${ARM_BASE}${res_id}/providers/Microsoft.Insights/diagnosticSettings/${name}?api-version=${RESOURCE_DIAGNOSTIC_SETTINGS_API_VERSION}"
          if ! diag_del_out="$(az rest --method delete --url "$diag_url" --output none 2>&1)"; then
            echo "::error::resource-scoped diagnostic setting delete for ${name} (resource ${res_id}) failed: ${diag_del_out}"
            return 1
          fi
          # This delete's own confirm-GET is the ONLY completion check this class will ever get:
          # by the time Phase 3 VERIFY runs, the host and its RG are expected to be gone, so there
          # is no later discovery that could re-observe the object (FM-3). Same PRIMARY-evidence
          # rationale FIX-1's MG-scope confirm-GETs use.
          confirm_gone_or_fail_primary "resource-scoped diagnostic setting ${name} (resource ${res_id})" "$diag_url" || return 1
        done
      done
    done
  done
  return 0
}

# databricks_force_delete_cascade <managed_rgs_outvar> <managed_rg_subs_outvar> - lists every
# Databricks workspace across every estate subscription (teardown_subscriptions) and submits a
# --no-wait --force-deletion delete for each (architect pre-clearance C1: --force-deletion is
# what makes the workspace delete itself cascade the RP-managed resource group cleanup instead
# of retaining it - a plain delete RETAINS the managed RG, per Microsoft's own "Delete a
# workspace" doc). Appends the managed resource-group name/subscription pair for every
# successfully-submitted delete onto the two NAMED arrays (bash nameref, `local -n`, bash >=4.3 -
# ubuntu-latest ships bash 5) so a caller can wait on them later.
#
# Shared by TWO call sites (ADR-066 decision 4, ADR-066 Finding 2 code-review follow-up,
# 2026-07-30): the unchanged Phase 2 az-sweep step 1 below, and the new Phase 0.5
# `scripts/teardown-databricks-precascade.sh` belt that runs BEFORE Phase 1 so the cascade acts
# on a still-live workspace - promoted here so the exact az invocation cannot drift between the
# two call sites, the same discipline already applied to confirm_gone_by_get/discover_live_rgs/
# is_estate_owned above after each was independently duplicated.
#
# List-call failure: a live subscription's own Databricks workspace list can never legitimately
# fail (section 9.4 design boundary, same as every other subscription-scoped list in this
# codebase) - FAIL LOUD, return 1 (caller's own ::error:: convention applies; this function
# prints its own ::error:: before returning, matching az_run_retry-consuming callers elsewhere).
# Bounded retry on a transient 5xx/429 before that fail-loud path fires (2026-07-30 fix round -
# see this file's "AMENDED an eighth time" header note). Delete-submission failure: classify with
# is_auth_error - auth-shaped fails loud (return 1); anything else is a warn-and-continue
# (idempotent retry on next run), matching every other delete in this codebase - deletes never go
# through az_run_retry (see that function's own comment for why). Zero workspaces found in any
# subscription is success (both arrays left empty), not an error.
databricks_force_delete_cascade() {
  local -n __dbx_out_rgs="$1"
  local -n __dbx_out_subs="$2"
  local sub row ws_name ws_rg managed_rg_id managed_rg_name
  local dbx_rows_out dbx_del_out
  local -a dbx_rows
  for sub in $(teardown_subscriptions); do
    if ! az_run_retry dbx_rows_out databricks workspace list --subscription "$sub" \
        --query "[].[name, resourceGroup, managedResourceGroupId]" -o tsv; then
      echo "::error::Databricks workspace list failed for subscription ${sub} - a failed list is never read as 'no workspaces' (section 9.4): ${AZ_RUN_STDERR}"
      return 1
    fi
    # shellcheck disable=SC2154  # dbx_rows_out is assigned indirectly by az_run's printf -v
    mapfile -t dbx_rows <<< "$dbx_rows_out"
    for row in "${dbx_rows[@]:-}"; do
      [ -z "$row" ] && continue
      ws_name="$(printf '%s' "$row" | cut -f1)"
      ws_rg="$(printf '%s' "$row" | cut -f2)"
      managed_rg_id="$(printf '%s' "$row" | cut -f3)"
      managed_rg_name="${managed_rg_id##*/}"
      echo "  Submitting delete for Databricks workspace ${ws_name} (rg ${ws_rg}, sub ${sub}, --no-wait --force-deletion) - cascades managed rg ${managed_rg_name}"
      if ! dbx_del_out="$(az databricks workspace delete --name "$ws_name" --resource-group "$ws_rg" \
          --subscription "$sub" --yes --no-wait --force-deletion --output none 2>&1)"; then
        if is_auth_error "$dbx_del_out"; then
          echo "::error::Databricks workspace delete submission for ${ws_name} failed with an auth/transport error: ${dbx_del_out}"
          return 1
        fi
        echo "  ::warning::workspace delete submission for ${ws_name} failed or already gone (continuing - idempotent retry on next run): ${dbx_del_out}"
        continue
      fi
      if [ -n "$managed_rg_name" ]; then
        __dbx_out_rgs+=("$managed_rg_name")
        __dbx_out_subs+=("$sub")
      fi
    done
  done
  return 0
}

# ---------------------------------------------------------------------------
# ADR-072 (2026-08-01) - the PRE-DESTROY ATTACHMENT SWEEP. A cross-root RP-ATTACHED object is
# one an Azure resource provider or platform addon creates inside root B's resource group as a
# side effect of a configuration DECLARED in a DIFFERENT root A (ADR-072 decision 5,
# "attachment declares ownership" - root A owns the object, root B only owns the container).
# Two live classes today, both landing in platform/management's resource group:
#   - Traffic Analytics' Microsoft.Insights/dataCollectionEndpoints and .../dataCollectionRules,
#     named NWTA-<derived from the platform workspace's regenerated customerId> - created and
#     ACTIVELY MANAGED by Traffic Analytics itself (four spoke roots' flow-log blocks point at
#     the platform workspace: corp-a1, online-p1, bank-app-p1, bank-data-p1 - corp-a2's block is
#     commented out). Microsoft's own "Manage virtual network flow logs" reference
#     (learn.microsoft.com/en-us/azure/network-watcher/vnet-flow-logs-manage, verified
#     2026-08-01) states verbatim that Traffic Analytics creates and manages this DCR/DCE pair
#     in the workspace's own resource group, prefixed NWTA, and warns against operating on them
#     directly - Traffic Analytics creates ONE pair per WORKSPACE, not per flow log.
#   - Microsoft.OperationsManagement/solutions - the ContainerInsights object created by
#     landing-zones/bank-app-p1's AKS monitoring addon (`use_aad_auth = false`, the legacy
#     workspace-key Container Insights path - OQ-068). No root in this estate declares
#     azurerm_log_analytics_solution (grep-confirmed 2026-08-01), so this type is narrow enough
#     that any instance found in an estate-owned RG belongs to this class.
#
# ORDERING CONSTRAINT - the exact MIRROR of ADR-063 G-1 (a resource-scoped diagnostic setting,
# keyed to its HOST's URI, must be swept BEFORE the host is destroyed - teardown-az-sweep.sh's
# "step 2-pre"). An attachment object is keyed to its CONTAINER, not a host resource, so the
# ordering inverts: it must be swept AFTER every declaring root has destroyed (sweeping while a
# creator is still live invites the live RP to simply recreate what was just deleted - Microsoft
# explicitly documents Traffic Analytics as actively managing its pair) and BEFORE the
# container-owning root (platform/management) destroys its resource group (or the delete is
# refused by `prevent_deletion_if_contains_resources`, ADR-072 decision 2's rejected
# alternative). Callers must run this between the LAST declaring root's destroy and
# platform/management's own destroy - see teardown.yml's "Phase 1.5" job for the exact position.
#
# SCOPE, a three-part predicate, in this exact order (ADR-072 decision 4):
#   (a) CONTAINMENT - the resource group is estate-owned (is_estate_owned --rg, matching the
#       SAME RG_SWEEP_QUERY discover_live_rgs already filters on).
#   (b) TYPE - exactly the two Insights types in ATTACHMENT_SWEEP_DCE_DCR_TYPES below, or
#       Microsoft.OperationsManagement/solutions.
#   (c) For the two Insights types ONLY, NAME PREFIX "NWTA-" (Microsoft's documented, stable
#       prefix for this class - see above). The solutions type carries no name-prefix filter -
#       the type itself is the discriminator (decision 4's own wording: "the type filter is what
#       keeps this a sweep of a named class rather than a delete-everything-here").
#
# DISCOVERY, NOT ENUMERATION (ADR-062 discipline, decision 4's own instruction): list by type
# within every estate-owned RG across all 5 subscriptions, never a hardcoded name - the NWTA
# names are non-deterministic (they inherit the workspace's regenerated customerId,
# docs/estate-bom.md finding 1), so a name-literal list would already be wrong on the very next
# rebuild.
#
# API versions verified live against Microsoft Learn 2026-08-01 (this ADR's own context table):
#   Microsoft.Insights/dataCollectionEndpoints and .../dataCollectionRules - 2024-03-11 is the
#     current documented version (learn.microsoft.com/en-us/azure/templates/microsoft.insights/
#     datacollectionendpoints lists Latest/2024-03-11/2023-03-11/2022-06-01/...).
#   Microsoft.OperationsManagement/solutions - 2015-11-01-preview is the ONLY version Microsoft
#     documents for this type (learn.microsoft.com/en-us/azure/templates/
#     microsoft.operationsmanagement/solutions lists only Latest and 2015-11-01-preview) - it has
#     never left preview, matching the AVM module's own pinned version for this resource.
ATTACHMENT_SWEEP_DCE_DCR_TYPES=("Microsoft.Insights/dataCollectionEndpoints" "Microsoft.Insights/dataCollectionRules")
ATTACHMENT_DCE_DCR_API_VERSION="2024-03-11"
ATTACHMENT_SOLUTIONS_TYPE="Microsoft.OperationsManagement/solutions"
ATTACHMENT_SOLUTIONS_API_VERSION="2015-11-01-preview"

# attachment_sweep_cross_root_objects - runs the decision-4 sweep across all 5 estate
# subscriptions. List-call failure: FAIL LOUD (section 9.4) - a live RG's own resource-type list
# can never legitimately fail. Delete-submission failure: is_auth_error fails loud; anything
# else warns and continues (idempotent retry on the next run), matching every other delete in
# this codebase. Confirm-GET after every delete via confirm_gone_or_fail_primary (ADR-072
# decision 4's own instruction) - this class has NO separate Phase 3 VERIFY step (VERIFY
# enumerates known RG-scope classes - budgets, policy exemptions - but has no per-type resource
# scan within a surviving RG), so this confirm-GET is the ONLY completion check this class will
# ever get, the same "no separate VERIFY step" rationale that function's own comment documents
# for MG scope. Zero matching objects anywhere is success, not an error - most RGs, most of the
# time, have nothing here.
#
# NOT A HARD GATE (ADR-072 decision 4, mirrors ADR-066 decision 4's Databricks-precascade
# wiring): this function's own non-zero return must be loud, but the CALLER (teardown.yml's
# Phase 1.5 job) must never be read by `management`'s own `if:` - a residual left behind by a
# failure here surfaces instead as platform/management's own
# `prevent_deletion_if_contains_resources` error (a genuine, informative Phase 1 red) or a Phase
# 2 RG-sweep / Phase 3 VERIFY 2 remnant, never as a silently-skipped mandatory layer.
attachment_sweep_cross_root_objects() {
  local overall_fail=0
  local sub rg_names_out rg
  for sub in $(teardown_subscriptions); do
    if ! discover_live_rgs rg_names_out "$sub"; then
      echo "::error::attachment sweep: RG list failed for subscription ${sub} - a failed list is never read as 'no RGs' (section 9.4): ${AZ_RUN_STDERR}"
      overall_fail=1
      continue
    fi
    local -a rg_names
    mapfile -t rg_names <<< "$rg_names_out"
    for rg in "${rg_names[@]:-}"; do
      [ -z "$rg" ] && continue
      if ! is_estate_owned --rg "$rg"; then
        echo "::error::attachment sweep: RG ${rg} (sub ${sub}) returned by discover_live_rgs did not classify as estate-owned by is_estate_owned - structurally impossible for an RG_SWEEP_QUERY-matched row. Failing loud rather than silently skipping."
        overall_fail=1
        continue
      fi
      local rg_id="/subscriptions/${sub}/resourceGroups/${rg}"

      # (b)+(c): the two Traffic Analytics types, filtered client-side to the NWTA- prefix.
      local dce_dcr_type
      for dce_dcr_type in "${ATTACHMENT_SWEEP_DCE_DCR_TYPES[@]}"; do
        local dce_dcr_names_out
        if ! az_run_retry dce_dcr_names_out resource list --resource-group "$rg" --subscription "$sub" \
            --resource-type "$dce_dcr_type" --query "[].name" -o tsv; then
          echo "::error::attachment sweep: ${dce_dcr_type} list failed for RG ${rg} (sub ${sub}) - a failed list is never read as 'none present' (section 9.4): ${AZ_RUN_STDERR}"
          overall_fail=1
          continue
        fi
        local -a dce_dcr_names
        mapfile -t dce_dcr_names <<< "$dce_dcr_names_out"
        local dce_dcr_name
        for dce_dcr_name in "${dce_dcr_names[@]:-}"; do
          [ -z "$dce_dcr_name" ] && continue
          case "$dce_dcr_name" in
            NWTA-*) ;;
            *) continue ;;  # name-prefix predicate (c) - not this class
          esac
          echo "  Deleting attachment object ${dce_dcr_type}/${dce_dcr_name} (RG ${rg}, sub ${sub})"
          local dce_dcr_url="${ARM_BASE}${rg_id}/providers/${dce_dcr_type}/${dce_dcr_name}?api-version=${ATTACHMENT_DCE_DCR_API_VERSION}"
          local dce_dcr_del_out
          if ! dce_dcr_del_out="$(az rest --method delete --url "$dce_dcr_url" --output none 2>&1)"; then
            if is_auth_error "$dce_dcr_del_out"; then
              echo "::error::attachment sweep: delete for ${dce_dcr_type}/${dce_dcr_name} (RG ${rg}, sub ${sub}) failed with an auth/transport error: ${dce_dcr_del_out}"
              overall_fail=1
            else
              echo "  ::warning::attachment sweep: delete for ${dce_dcr_type}/${dce_dcr_name} failed or already gone (continuing - idempotent retry on next run): ${dce_dcr_del_out}"
            fi
            continue
          fi
          confirm_gone_or_fail_primary "attachment sweep: ${dce_dcr_type}/${dce_dcr_name} (RG ${rg}, sub ${sub})" "$dce_dcr_url" \
            "this class has no separate Phase 3 VERIFY step - VERIFY has no per-type resource scan within a surviving RG" \
            || overall_fail=1
        done
      done

      # (b): Microsoft.OperationsManagement/solutions - no name-prefix filter (the type itself
      # is the discriminator, decision 4).
      local sol_names_out
      if ! az_run_retry sol_names_out resource list --resource-group "$rg" --subscription "$sub" \
          --resource-type "$ATTACHMENT_SOLUTIONS_TYPE" --query "[].name" -o tsv; then
        echo "::error::attachment sweep: ${ATTACHMENT_SOLUTIONS_TYPE} list failed for RG ${rg} (sub ${sub}) - a failed list is never read as 'none present' (section 9.4): ${AZ_RUN_STDERR}"
        overall_fail=1
        continue
      fi
      local -a sol_names
      mapfile -t sol_names <<< "$sol_names_out"
      local sol_name
      for sol_name in "${sol_names[@]:-}"; do
        [ -z "$sol_name" ] && continue
        echo "  Deleting attachment object ${ATTACHMENT_SOLUTIONS_TYPE}/${sol_name} (RG ${rg}, sub ${sub})"
        local sol_url="${ARM_BASE}${rg_id}/providers/${ATTACHMENT_SOLUTIONS_TYPE}/${sol_name}?api-version=${ATTACHMENT_SOLUTIONS_API_VERSION}"
        local sol_del_out
        if ! sol_del_out="$(az rest --method delete --url "$sol_url" --output none 2>&1)"; then
          if is_auth_error "$sol_del_out"; then
            echo "::error::attachment sweep: delete for ${ATTACHMENT_SOLUTIONS_TYPE}/${sol_name} (RG ${rg}, sub ${sub}) failed with an auth/transport error: ${sol_del_out}"
            overall_fail=1
          else
            echo "  ::warning::attachment sweep: delete for ${ATTACHMENT_SOLUTIONS_TYPE}/${sol_name} failed or already gone (continuing - idempotent retry on next run): ${sol_del_out}"
          fi
          continue
        fi
        confirm_gone_or_fail_primary "attachment sweep: ${ATTACHMENT_SOLUTIONS_TYPE}/${sol_name} (RG ${rg}, sub ${sub})" "$sol_url" \
          "this class has no separate Phase 3 VERIFY step - VERIFY has no per-type resource scan within a surviving RG" \
          || overall_fail=1
      done
    done
  done
  return "$overall_fail"
}
# ---------------------------------------------------------------------------

# confirm_gone_by_get "<url>" - the confirm-GET pattern VERIFY 9 already established (ARG
# proposes, ARM disposes: confirm liveness with a direct GET before trusting a list/discovery
# result), promoted to a shared helper so the probe and FIX-1..FIX-5 do not each re-implement
# the same four-way branch. Prints nothing itself - purely a classifier. Return codes:
#   0 = CONFIRMED GONE (GET failed with a 404/NotFound-shaped error - is_not_found_error matched).
#   1 = CONFIRMED LIVE (GET succeeded).
#   2 = INDETERMINATE (GET failed, but neither auth-shaped nor 404-shaped - e.g. a 429/500/
#       transport blip).
#   3 = AUTH ERROR (is_auth_error matched).
# On return 2 or 3 the caller-visible error text is left in CONFIRM_GONE_BY_GET_ERR (global,
# like AZ_RUN_STDERR) so the caller can print it without re-running the GET.
#
# Caller obligation depends on WHAT this GET is the evidence FOR - there are two valid usage
# patterns in this codebase and they classify return 2 differently. Use the matching wrapper
# below (confirm_gone_or_fail_primary / confirm_gone_or_warn_belt) rather than hand-rolling the
# case statement at each call site - promoted here 2026-07-23 (code-review BLOCK follow-up)
# after the same four-way branch was independently duplicated at five call sites:
#   (a) PRIMARY evidence (this GET is the ONLY signal deciding pass/fail - the MG-scope classes
#       FIX-1 deletes, and FIX-2's MG-scope budget re-sweep, are this pattern: MG-scoped
#       extension objects are 403-shadowed for this SP once their MG is deleted, so NO separate
#       Phase 3 VERIFY step can ever check them after the fact - this inline confirm-GET, while
#       the MG still exists, is the only completion check these classes will ever get) - use
#       confirm_gone_or_fail_primary. Treats 2 the SAME as 3, FAIL LOUD. Never read an
#       indeterminate result as "gone" - that is the exact false-negative class ADR-062 exists
#       to close, arriving through a different failure shape than the one it originally closed.
#   (b) SECONDARY/belt evidence (this GET runs AFTER a delete call that already returned
#       success, AND a separate deterministic Phase 3 VERIFY step exists for this same scope/
#       class and is the true completion gate - the RG-scope and subscription-scope/tenant/
#       security-singleton FIX-2/3/4/5 deletes are this pattern) - use
#       confirm_gone_or_warn_belt. 2 may be downgraded to a warn-and-continue, consistent with
#       how every delete call's OWN failure handling in this script already treats a non-auth
#       failure (is_auth_error fails loud, anything else warns and continues - the delete was
#       already accepted; a lingering/ambiguous read immediately after is most likely
#       propagation lag). Return 3 (auth) still MUST fail loud in BOTH patterns - a
#       directory-role or token gap is never "probably fine".
CONFIRM_GONE_BY_GET_ERR=""
confirm_gone_by_get() {
  local url="${1:-}" out
  CONFIRM_GONE_BY_GET_ERR=""
  if out="$(az rest --method get --url "$url" --output none 2>&1)"; then
    return 1
  fi
  if is_auth_error "$out"; then
    CONFIRM_GONE_BY_GET_ERR="$out"
    return 3
  fi
  if is_not_found_error "$out"; then
    return 0
  fi
  CONFIRM_GONE_BY_GET_ERR="$out"
  return 2
}

# confirm_gone_or_fail_primary "<description>" "<url>" ["<no-verify-reason>"] - pattern (a)
# wrapper. Prints its own ::error:: and returns 1 on anything other than confirmed-gone; prints
# nothing and returns 0 on confirmed-gone. Callers MUST still `exit 1` themselves on a non-zero
# return (this function never exits the script itself - these are flat top-level scripts, not
# `set -e`, and every other fail-loud path in them follows the same `if ! fn; then exit 1; fi`
# shape).
#
# The optional third argument (added 2026-07-30, code-review Finding 4 - dedupe a hand-rolled
# copy of this exact 4-way branch) overrides WHY this scope has no separate Phase 3 VERIFY
# step, so a non-MG-scope caller with the same "this confirm-GET is the only completion check"
# shape can reuse this helper instead of hand-rolling its own copy of the case statement.
# Defaults to the ORIGINAL MG-scope wording verbatim, so every existing caller (FIX-1's three
# MG-scope confirm-GETs, teardown-az-sweep.sh) is BYTE-IDENTICAL and unaffected by this change.
confirm_gone_or_fail_primary() {
  local desc="$1" url="$2"
  local no_verify_reason="${3:-MG-scoped extension objects are 403-shadowed for this SP once their MG is deleted}"
  confirm_gone_by_get "$url"
  case $? in
    0) return 0 ;;
    1)
      echo "::error::${desc}: still confirmed LIVE immediately after a successful delete submission. This scope has no separate Phase 3 VERIFY step (${no_verify_reason}), so this confirm-GET is the ONLY completion check this class will ever get - treating a still-live result as a hard remnant, not a warning."
      return 1
      ;;
    2)
      echo "::error::${desc}: confirm-GET after delete was indeterminate (neither confirmed gone nor confirmed live) - cannot certify this object clean off an ambiguous result, and no separate VERIFY step exists to catch it later: ${CONFIRM_GONE_BY_GET_ERR}"
      return 1
      ;;
    3)
      echo "::error::${desc}: confirm-GET after delete failed with an auth/transport error: ${CONFIRM_GONE_BY_GET_ERR}"
      return 1
      ;;
  esac
}

# confirm_gone_or_warn_belt "<description>" "<url>" - pattern (b) wrapper. Prints a
# `::warning::` (not fatal) on still-live/indeterminate, `::error::` and returns 1 on an
# auth-shaped failure, returns 0 (no output) on confirmed-gone. Same "callers must `exit 1`
# themselves on non-zero" contract as confirm_gone_or_fail_primary.
confirm_gone_or_warn_belt() {
  local desc="$1" url="$2"
  confirm_gone_by_get "$url"
  case $? in
    0) return 0 ;;
    1)
      echo "  ::warning::${desc}: still reads live immediately after a successful delete submission (likely propagation lag) - a separate Phase 3 VERIFY step covers this scope/class and is the authoritative completion gate; re-check on a later run."
      return 0
      ;;
    2)
      echo "  ::warning::${desc}: confirm-GET after delete was indeterminate - a separate Phase 3 VERIFY step covers this scope/class: ${CONFIRM_GONE_BY_GET_ERR}"
      return 0
      ;;
    3)
      echo "::error::${desc}: confirm-GET after delete failed with an auth/transport error: ${CONFIRM_GONE_BY_GET_ERR}"
      return 1
      ;;
  esac
}

# The 5 workload/platform subscriptions the estate spans (bootstrap identity.tf /
# _tf-root.yml TF_VAR_*_subscription_id secrets). All landing-zones/* roots share the single
# landingzones subscription (see any landing-zones/*/providers.tf). Populated from env vars
# the calling job must export from GitHub Secrets - never hardcoded here (no GUIDs in
# source, per DevSecOps secrets-hygiene rules).
teardown_subscriptions() {
  local subs=()
  [ -n "${MANAGEMENT_SUBSCRIPTION_ID:-}" ]   && subs+=("$MANAGEMENT_SUBSCRIPTION_ID")
  [ -n "${CONNECTIVITY_SUBSCRIPTION_ID:-}" ] && subs+=("$CONNECTIVITY_SUBSCRIPTION_ID")
  [ -n "${IDENTITY_SUBSCRIPTION_ID:-}" ]     && subs+=("$IDENTITY_SUBSCRIPTION_ID")
  [ -n "${SECURITY_SUBSCRIPTION_ID:-}" ]     && subs+=("$SECURITY_SUBSCRIPTION_ID")
  [ -n "${LANDINGZONES_SUBSCRIPTION_ID:-}" ] && subs+=("$LANDINGZONES_SUBSCRIPTION_ID")
  printf '%s\n' "${subs[@]}"
}

# is_auth_error "<text>" - classify captured az/curl stderr (or any error text) as an
# auth/token/transport failure, case-insensitive (docs/teardown-redesign.md section 9.4 /
# ADR-054 amendment point 9). Matches AADSTS / "valid time range" / "not within" /
# AuthenticationFailed / ExpiredAuthenticationToken / token / credential / 401 / 403 /
# "az login". Returns 0 (true - IS an auth error) on a match, 1 (false) otherwise. A caller
# must treat a match as FAIL LOUD - never as "resource absent / already gone / nothing to do".
# Deliberately broad ("token" / "credential" alone match) per the locked design - a caller
# distinguishes a genuine NotFound from everything else itself; this classifier only answers
# "is this specific failure text auth-shaped".
#
# 401/403 are word-boundary anchored (`\b401\b` / `\b403\b`), NOT bare substrings (fix for
# run 30181672979, which false-failed a confirmed-gone MG-scope budget delete - the
# confirm-GET's own 404 NotFound body carries an ARM Request ID GUID, and the bare `403`
# match fired on the digits `403` embedded inside that GUID's `4038` segment, so a genuine
# NotFound was misclassified as a fatal auth error before is_not_found_error ever ran (see
# confirm_gone_by_get above - is_auth_error is checked first by design, so it must not
# false-fire on digits that merely co-occur inside an unrelated GUID/request-id/byte-count).
# A word boundary requires a non-word character (or string edge) immediately adjacent, so a
# real status code standalone ("403", "(403)", "403 Forbidden") still matches, while `403`
# sitting inside a longer digit/hex run (`4038`, `1403`, `403a`) does not - and a genuine
# GUID segment (4/8/12 hex chars) can never hold `401`/`403` as a boundary-anchored substring,
# since the match is shorter than every segment length. The non-numeric tokens are untouched.
is_auth_error() {
  local text="${1:-}"
  printf '%s' "$text" | grep -qiE 'AADSTS|valid time range|not within|AuthenticationFailed|ExpiredAuthenticationToken|token|credential|\b401\b|\b403\b|az login'
}

# is_not_found_error "<text>" - classify captured az/curl stderr (or any error text) as a
# CONFIRMED-ABSENT (404/NotFound-shaped) signal, case-insensitive (docs/teardown-redesign.md
# section 14.3, ADR-062 code-review finding 2026-07-21). Grounded in shapes already recorded in
# this codebase as confirmed live, not invented: sub-step 6d's own comment
# (teardown-az-sweep.sh) states "A genuine 404 returns `PolicyExemptionNotFound` / `Not Found`,
# which was confirmed live NOT to match is_auth_error" - `NotFound` (no space) matches
# PolicyExemptionNotFound and the equivalent `<Type>NotFound` codes ARM returns for the other
# VERIFY 9 confirm-GET types (policyAssignments/policyDefinitions/policySetDefinitions all
# follow the same `<Type>NotFound` error-code convention); `Not Found` (with the space) matches
# the literal HTTP reason phrase; `404` is the bare status code, included for the same reason
# is_auth_error above includes bare `401`/`403`. Returns 0 (true - IS a confirmed-absent signal)
# on a match, 1 (false) otherwise.
#
# This exists because "stale, pass" must be reserved for a CONFIRMED-ABSENT signal, never for
# "not auth-shaped, so assume gone". A confirm-GET that fails with a 429 throttle, a 500, or a
# transient network error is NOT auth-shaped and is NOT confirmed-absent either - it is
# INDETERMINATE, and a caller must fail loud on it rather than read it as evidence the row is
# gone. Falling through a bare `else` after only checking is_auth_error reopens exactly the
# false-negative class ADR-062 exists to close, arriving through a transport error instead of a
# wrong name filter. Checked AFTER is_auth_error at every call site (never before) so a message
# that happens to match both stays classified as the auth failure, which is the already-locked,
# more severe classification.
is_not_found_error() {
  local text="${1:-}"
  printf '%s' "$text" | grep -qiE 'NotFound|Not Found|404'
}

# is_transient_error "<text>" - classify captured az stderr as a TRANSIENT server-side failure
# (HTTP 5xx or 429/throttling), case-insensitive (2026-07-30 transient-list-failure fix round, live
# evidence: teardown run 30597640251, section 9.4). Returns 0 (true - IS transient) on a match, 1
# (false) otherwise. Consumed ONLY by `az_run_retry` below to decide whether a failed LIST/GET is
# worth a bounded retry - never consumed as a substitute for `is_auth_error`'s fail-loud role, and
# `az_run_retry` always checks `is_auth_error` FIRST (an auth/token failure must never be retried).
#
# Matches BOTH textual shapes this codebase's az calls can produce an error in:
#   - `az rest` renders a non-2xx response as `<Reason Phrase>({...json body...})` - e.g. the live
#     evidence line, `ERROR: Internal Server Error({"error":{...`. "Too Many Requests" is the
#     equivalent reason phrase for a 429.
#   - Every other az CLI command (SDK-wrapped, not raw `az rest`) surfaces an azure-core
#     HttpResponseError, typically `(<ErrorCode>) <message>` - e.g. `(InternalServerError) ...` /
#     `(TooManyRequests) ...` - or occasionally the bare reason phrase again
#     ("Operation returned an invalid status 'Service Unavailable'").
# Bare status codes (429/500/502/503/504) are ALSO matched, word-boundary anchored
# (`\b500\b` etc.) - the SAME discipline `is_auth_error` above already established for bare
# `401`/`403`, so a digit run that merely CONTAINS one of these codes (a GUID segment, a
# content-length, a resource count) cannot false-match. This is deliberately still broad enough to
# accept a residual false-positive risk (some other unrelated digit sequence, word-boundary
# anchored, coincidentally reading as one of these codes) - unlike `is_auth_error`, where a
# false-positive would incorrectly SUPPRESS a retry (harmless - the caller still fails loud
# immediately, exactly as `az_run` always did), a false positive HERE only costs one bounded extra
# retry cycle (~`AZ_RUN_RETRY_SLEEP_SECONDS` seconds) before the SAME fail-loud outcome the codebase
# already guarantees - it can never turn a real failure into a silent pass, so accepting the wider
# net here does not weaken section 9.4's invariant.
is_transient_error() {
  local text="${1:-}"
  printf '%s' "$text" | grep -qiE 'Internal Server Error|InternalServerError|Bad Gateway|BadGateway|Service Unavailable|ServiceUnavailable|Gateway Timeout|GatewayTimeout|Too Many Requests|TooManyRequests|RetryableError|\b429\b|\b500\b|\b502\b|\b503\b|\b504\b'
}

# is_storage_network_rule_error "<text>" - classifies captured az/curl stderr as a STORAGE-
# ACCOUNT-FIREWALL PROPAGATION race (2026-08-01, live evidence: Phase 4 STATE RESET runs
# `30707957054` and `30709287789`, plus one earlier occurrence - three reproductions, not one).
# Matches Azure's own literal hint text, case-insensitive: "may be blocked by network rules of
# storage account".
#
# THIS IS NOT is_transient_error (it is not an HTTP 5xx/429 server error) and it is deliberately
# checked BEFORE is_auth_error even though it is very likely also 403-shaped - the SAME
# precedence flip this codebase already uses once, for the SAME reason
# (`_is_authz_denied_design_gap` in teardown-disarm.sh/teardown-az-sweep.sh): the two failure
# shapes are structurally distinct. A genuine dead/expired OIDC token fails at the AUTHENTICATION
# layer (AADSTS7xxxxx / "valid time range" - Azure AD rejects the token before Storage ever sees
# the request). This error is a STORAGE-SERVICE-side response: the calling principal IS
# authenticated and IS authorized (RBAC), and the account's `default_action` WAS flipped to
# Allow moments earlier by THIS SAME job - it is rejected by the account's NETWORK rules
# specifically, which is a materially different, and non-auth, failure.
#
# Live evidence this is a genuine PER-FRONT-END-NODE race, not an unpropagated rule caught
# early (ADR-025/LESSON 30 already documents that the Allow flip is monotonic once propagated
# but propagation itself is "not instant and not consistent across front-end nodes" - this is
# that same behaviour recurring on a DIFFERENT call shape than the one LESSON 30 first found
# it on): a `blob show` succeeded and the VERY NEXT `blob download` against the SAME blob,
# seconds later, failed with this exact text - two consecutive requests landed on two different
# front ends, one settled and one not. Reproduced at 153 bytes (the canonical empty document)
# as well as 24 MB, so blob size is not the variable either.
#
# THE EXISTING 3-CONSECUTIVE-PROBE-SUCCESS GATE (`_tf-root.yml`/`teardown.yml`'s "Open state SA
# firewall" step) IS INSUFFICIENT EVIDENCE AGAINST THIS, NOT BROKEN, AND MUST NOT BE WIDENED
# FURTHER TO "FIX" IT: succeeding against whichever front end that probe happens to land on says
# nothing about the front end an unrelated LATER request lands on - raising the probe count only
# makes the SAME kind of claim more confidently, it does not change what the claim can prove.
# The fix is retrying the INDIVIDUAL blocked operation instead: each retry re-rolls which front
# end serves it, and the bounded wait gives Azure's own propagation (documented as taking "up to
# a few minutes") real time to finish settling everywhere. This does not widen the firewall
# model in any way - default_action is never touched here, only whether a single request is
# retried before failing loud.
is_storage_network_rule_error() {
  local text="${1:-}"
  printf '%s' "$text" | grep -qiE 'may be blocked by network rules of storage account'
}

# az_run <out_var> <az subcommand args...> - run `az <args>`, capturing STDOUT ONLY into the
# named variable and STDERR into the global AZ_RUN_STDERR. Returns az's own exit code
# unmolested.
#
# Locked reason this exists (code-review BLOCK, Finding #2, 2026-07-20): the az CLI writes
# WARNING banners to stderr even on a clean exit-0 call (update-available nags, "this command
# is from the following extension: databricks/account" advisories). Merging stdout+stderr with
# `2>&1` into a variable that then feeds `mapfile` or a scalar comparison can inject a bogus
# row into an otherwise-successful list result - a false VERIFY failure on a genuinely clean
# scope, or a bogus RG/KV "name" pushed through a delete and the 30-min reconcile wait. This
# helper is the ONLY sanctioned way in this codebase to capture az list/show output destined
# for mapfile or a scalar compare - stderr is only ever inspected (via AZ_RUN_STDERR and
# is_auth_error) on the non-zero-exit-code path, never mixed into the data channel.
AZ_RUN_STDERR=""
az_run() {
  local __az_run_outvar="$1"
  shift
  local __az_run_err_file __az_run_rc __az_run_out
  __az_run_err_file="$(mktemp)"
  __az_run_out="$(az "$@" 2>"$__az_run_err_file")"
  __az_run_rc=$?
  AZ_RUN_STDERR="$(cat "$__az_run_err_file")"
  rm -f "$__az_run_err_file"
  printf -v "$__az_run_outvar" '%s' "$__az_run_out"
  return "$__az_run_rc"
}

# az_run_retry <out_var> <az subcommand args...> - drop-in replacement for `az_run` at LIST/GET
# (read) call sites ONLY (2026-07-30 transient-list-failure fix round - see this file's own
# "AMENDED an eighth time" header note for the live incident that motivated it). Same signature,
# same return contract as `az_run` (0 on success with `out_var` populated; non-zero with
# `AZ_RUN_STDERR` set to the failing attempt's stderr) - every existing caller works unmodified
# with no change beyond the function name, including the three-way
# `if az_run ...; then ... elif is_auth_error ...; else ...; fi` form teardown-disarm.sh/
# teardown-verify.sh use, because a retry that ultimately still fails is observationally identical
# to `az_run` failing on the first and only attempt.
#
# Retries a BOUNDED number of times (AZ_RUN_RETRY_ATTEMPTS total attempts, default 3;
# AZ_RUN_RETRY_SLEEP_SECONDS apart, default 10) ONLY when BOTH hold on a failed attempt:
#   - `is_auth_error` does NOT match. An auth/token failure is a real finding, not a server blip,
#     and MUST stay immediately fail-loud with zero retries - never widen this to "retry anything",
#     or a genuinely dead token would just burn extra wall-clock time before failing anyway, which
#     would blur exactly the signal `is_auth_error` exists to surface fast.
#   - `is_transient_error` DOES match (HTTP 5xx or 429 - see that function's own comment for the
#     exact text matched and why its residual false-positive risk is safe to accept).
# `is_auth_error` is checked FIRST and unconditionally wins if it matches, even on text that also
# happens to look transient - the same "auth is the more severe classification, checked first"
# convention `is_not_found_error`'s own comment already documents for its relationship to
# `is_auth_error`.
#
# Any OTHER failure shape (non-auth, non-transient - e.g. a genuine 400 this codebase does not
# expect on a list call at all) returns on the FIRST attempt, unretried, exactly like plain `az_run`
# always did: retrying a deterministic error only delays the same fail-loud outcome, it does not
# change it.
#
# NEVER use this for a DELETE/write submission. Every delete call site in this codebase captures
# its own output directly (`az ... 2>&1`, not `az_run`) specifically because a write's error text
# is only ever inspected on ITS OWN failure branch, never fed to a compare/mapfile as data (the
# `az_run` Finding #2 discipline above) - retrying a write is a materially different and more
# dangerous problem (the idempotency of the OPERATION, not just of reading its result) that this
# helper does not attempt to solve. Do not wire it in at a delete call site. (The one exception in
# this codebase, `retry_blob_action_on_network_rule` below, is a DIFFERENT helper for a DIFFERENT,
# narrower reason - see its own comment for why retrying THOSE specific writes is safe.)
#
# AMENDED 2026-08-01 (Phase 4 firewall-race fix, three reproductions - see
# is_storage_network_rule_error's own comment for the full incident). Added a SECOND, separately-
# bounded retry branch, checked BEFORE is_auth_error: `is_storage_network_rule_error` needs a
# LONGER window than a transient 5xx/429 (Azure's own firewall propagation is documented as
# taking "up to a few minutes", not the seconds a server blip clears in), so it gets its own
# attempt/sleep constants rather than sharing AZ_RUN_RETRY_ATTEMPTS/SLEEP_SECONDS. This is safe to
# apply UNIVERSALLY to every `az_run_retry` caller in this codebase (not just
# scripts/teardown-state-reset.sh, where it was found) because the exact matched text can only
# ever be produced by an `az storage` call against a network-ACL'd account - no other command
# family in this codebase (`az policy`, `az group`, `az keyvault`, `az databricks`, `az account
# management-group`, `az rest` against ARM) can produce it, so no other caller's behaviour changes
# at all.
AZ_RUN_RETRY_ATTEMPTS="${AZ_RUN_RETRY_ATTEMPTS:-3}"
AZ_RUN_RETRY_SLEEP_SECONDS="${AZ_RUN_RETRY_SLEEP_SECONDS:-10}"
AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS="${AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS:-8}"
AZ_RUN_RETRY_STORAGE_NETWORK_SLEEP_SECONDS="${AZ_RUN_RETRY_STORAGE_NETWORK_SLEEP_SECONDS:-20}"
az_run_retry() {
  local __out_var="$1"
  shift
  local __attempt=1 __network_attempt=1 __rc
  while :; do
    az_run "$__out_var" "$@"
    __rc=$?
    if [ "$__rc" -eq 0 ]; then
      return 0
    fi
    if is_storage_network_rule_error "$AZ_RUN_STDERR"; then
      if [ "$__network_attempt" -ge "$AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS" ]; then
        echo "  ::warning::az_run_retry: attempt ${__network_attempt}/${AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS} of 'az $*' still blocked by a storage-account network rule (front-end propagation race, not an auth failure - see is_storage_network_rule_error) - no attempts remain, returning the failure to the caller: ${AZ_RUN_STDERR}"
        return "$__rc"
      fi
      echo "  ::warning::az_run_retry: attempt ${__network_attempt}/${AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS} of 'az $*' blocked by a storage-account network rule (front-end propagation race, not an auth failure) - retrying in ${AZ_RUN_RETRY_STORAGE_NETWORK_SLEEP_SECONDS}s: ${AZ_RUN_STDERR}"
      sleep "$AZ_RUN_RETRY_STORAGE_NETWORK_SLEEP_SECONDS"
      __network_attempt=$((__network_attempt + 1))
      continue
    fi
    if is_auth_error "$AZ_RUN_STDERR"; then
      return "$__rc"
    fi
    if ! is_transient_error "$AZ_RUN_STDERR"; then
      return "$__rc"
    fi
    if [ "$__attempt" -ge "$AZ_RUN_RETRY_ATTEMPTS" ]; then
      echo "  ::warning::az_run_retry: attempt ${__attempt}/${AZ_RUN_RETRY_ATTEMPTS} of 'az $*' still failed with a transient error (HTTP 5xx/429) - no attempts remain, returning the failure to the caller: ${AZ_RUN_STDERR}"
      return "$__rc"
    fi
    echo "  ::warning::az_run_retry: attempt ${__attempt}/${AZ_RUN_RETRY_ATTEMPTS} of 'az $*' failed with a transient error (HTTP 5xx/429) - retrying in ${AZ_RUN_RETRY_SLEEP_SECONDS}s: ${AZ_RUN_STDERR}"
    sleep "$AZ_RUN_RETRY_SLEEP_SECONDS"
    __attempt=$((__attempt + 1))
  done
}

# retry_blob_action_on_network_rule <out_text_var> <az storage blob ... args...> - the
# ACTION-call (download/upload) counterpart to az_run_retry's new is_storage_network_rule_error
# branch above (2026-08-01, Phase 4 firewall-race fix). `az storage blob download`/`upload` are
# not LIST/GET calls whose stdout is consumed as data (download writes to `--file`; upload passes
# `--output none`), so they are captured directly with `2>&1` at every call site in this codebase
# already, never through `az_run` - this helper preserves that same direct-capture shape (never
# touches `az_run`'s separated-stream plumbing, which these calls do not need) and adds ONLY the
# bounded retry, into `out_text_var`, matching `az_run`'s own "populate the named var, return az's
# exit code" contract so callers change nothing beyond the function name.
#
# Retrying THESE specific writes is safe where az_run_retry's own header forbids retrying a write
# in general: both call sites this helper exists for are IDEMPOTENT by construction - a download
# of an existing blob into a fresh temp file, and an upload of the canonical empty state document
# this same script just built with `--overwrite true` - re-running either produces the identical
# result. This is a narrower guarantee than "never retry a write" needs to assume, not a
# contradiction of it; a caller reaching for this helper for an ARM POST/DELETE with side effects
# would be using it wrong.
#
# Same precedence and bound as az_run_retry's new branch: is_storage_network_rule_error is
# checked FIRST (before this function would otherwise just fail on the first attempt), using the
# SAME AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS/SLEEP_SECONDS constants so an operator reasons about
# one number for this whole failure class regardless of which call shape hit it.
#
# CORRECTED 2026-08-01 at the code-review gate, before this ever ran live. The first version
# wrote `if __out="$(az "$@" 2>&1)"; then ... ; fi` with no `else`, then read `__rc=$?`
# immediately after the `fi`. Under POSIX/bash, an `if` construct whose condition is false and
# which has no `else` clause has its OWN exit status defined as 0, regardless of the failing
# condition's real exit code (`bash -c 'if false; then :; fi; echo $?'` prints `0`) - so `__rc`
# was ALWAYS 0, and both failure branches below always returned success. Fixed by mirroring
# `az_run_retry`'s own correct shape: assign in a plain statement, capture `$?` on the very next
# line with no `if` in between, THEN branch on the captured value with an explicit numeric test.
retry_blob_action_on_network_rule() {
  local __out_var="$1"
  shift
  local __attempt=1 __rc __out
  while :; do
    __out="$(az "$@" 2>&1)"
    __rc=$?
    if [ "$__rc" -eq 0 ]; then
      printf -v "$__out_var" '%s' "$__out"
      return 0
    fi
    if ! is_storage_network_rule_error "$__out"; then
      printf -v "$__out_var" '%s' "$__out"
      return "$__rc"
    fi
    if [ "$__attempt" -ge "$AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS" ]; then
      printf -v "$__out_var" '%s' "$__out"
      echo "  ::warning::retry_blob_action_on_network_rule: attempt ${__attempt}/${AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS} of 'az $*' still blocked by a storage-account network rule (front-end propagation race, not an auth failure) - no attempts remain: ${__out}"
      return "$__rc"
    fi
    echo "  ::warning::retry_blob_action_on_network_rule: attempt ${__attempt}/${AZ_RUN_RETRY_STORAGE_NETWORK_ATTEMPTS} of 'az $*' blocked by a storage-account network rule (front-end propagation race, not an auth failure) - retrying in ${AZ_RUN_RETRY_STORAGE_NETWORK_SLEEP_SECONDS}s: ${__out}"
    sleep "$AZ_RUN_RETRY_STORAGE_NETWORK_SLEEP_SECONDS"
    __attempt=$((__attempt + 1))
  done
}

# mg_snapshot_load / mg_in_snapshot - the ONE-TIME `az account management-group list` snapshot
# oracle (docs/teardown-redesign.md section 12 / ADR-054 point 12). REPLACES the per-MG
# `az account management-group show <name>` existence probe everywhere in the teardown scripts.
#
# Why: the teardown OIDC SP's MG-read grants are scoped to the globaris subtree (identity.tf)
# and are deleted WITH that subtree, so a `show` on a DELETED globaris-tree MG evaluates RBAC on
# a scope the SP no longer holds any grant over and returns HTTP-403 `AuthorizationFailed` -
# NOT the clean 404 `ManagementGroupNotFound` a tenant-root-privileged human would see. Since
# `is_auth_error` correctly matches that 403 (as designed), a `show`-based existence gate fails
# loud on every benign already-gone MG for this specific principal (proved empirically, probe
# run 29756715840, run AS the teardown SP: `list` succeeds and returns only the tenant root;
# `show --name globaris` returns 403; `show` on the tenant root itself succeeds). The SP's
# surviving grant is Management Group Contributor AT THE TENANT ROOT (identity.tf; the tenant
# root is never deleted), which carries `Microsoft.Management/managementGroups/read` - a `list`
# over that readable collection is always available to the SP, so existence resolves by NAME
# MEMBERSHIP in one list call, with NO per-scope call and therefore no deleted-scope 403.
#
# `mg_snapshot_load` captures the set ONCE per script run via `az_run` (kept stdout/stderr
# separate - merging them here would reintroduce the exact Finding #2 stderr-banner-corrupts-
# the-data-channel bug this codebase already closed everywhere else a list's stdout is consumed
# as data) and populates the global associative array MG_SNAPSHOT (name -> 1 for every MG that
# currently exists). Auth-fail-loud lives HERE: a non-zero exit is the single call the SP is
# always entitled to make, so a failure classifies with `is_auth_error` (or any non-zero) as a
# genuine dead token / transport error - callers MUST treat a failed mg_snapshot_load as FAIL
# LOUD and never proceed with a stale/absent snapshot. A SUCCESSFUL list is authoritative ground
# truth for the rest of the run - a dead token cannot return a clean list. Uses az_run_retry (not
# plain az_run, 2026-07-30 fix round - see this file's "AMENDED an eighth time" header note): this
# ONE call gates the start of every DISARM/az-sweep/VERIFY run, so a single transient 5xx/429 here
# would otherwise kill the whole run before any real work started - exactly the failure class this
# fix round closes.
declare -gA MG_SNAPSHOT
mg_snapshot_load() {
  MG_SNAPSHOT=()
  local names_out name
  if ! az_run_retry names_out account management-group list --query "[].name" -o tsv; then
    echo "::error::mg_snapshot_load: az account management-group list failed - this is the single call the SP is always entitled to make (Management Group Contributor at the tenant root, never deleted), so a failure here is a genuine dead token / transport error: ${AZ_RUN_STDERR}"
    return 1
  fi
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    MG_SNAPSHOT["$name"]=1
  done <<< "$names_out"
  return 0
}

# mg_in_snapshot "<name>" - membership test against the snapshot loaded by mg_snapshot_load.
# Returns 0 (true, MG exists) if present, 1 (false, MG gone) if absent. `${MG_SNAPSHOT[$name]+x}`
# is the standard unset-or-null-safe existence test and never errors under `set -u`, even when
# the key is not present.
mg_in_snapshot() {
  local name="${1:-}"
  [ -n "${MG_SNAPSHOT[$name]+x}" ]
}

# az_relogin - mint a FRESH GitHub OIDC federated assertion on demand and re-authenticate the
# az CLI with it (docs/teardown-redesign.md section 9.2b / ADR-054 amendment point 7b).
#
# Why this exists: the `azure/login` step at job start consumes GitHub's federated assertion,
# which is only valid inside GitHub's own ~5-minute issuance window. Once consumed, az's own
# token-refresh has no live assertion left to refresh with, so any operation that outlives the
# resulting ~1h Azure access token dies with AADSTS700024. GitHub will happily issue a BRAND
# NEW assertion on request for the entire lifetime of the job, so this helper requests one and
# logs in again rather than ever leaning on az's structurally-broken refresh.
#
# Requires (never hardcoded - sourced from the job environment):
#   $ACTIONS_ID_TOKEN_REQUEST_URL, $ACTIONS_ID_TOKEN_REQUEST_TOKEN (auto-present because the
#     workflow already sets `permissions: id-token: write` - do NOT hardcode these).
#   $AZURE_CLIENT_ID, $AZURE_TENANT_ID, $AZURE_SUBSCRIPTION_ID (exported by the workflow step
#     from the repo Variables, per DevSecOps secrets-hygiene: identity via Variables, never a
#     client secret).
#
# The audience "api://AzureADTokenExchange" is sent URL-encoded (api%3A%2F%2FAzureADTokenExchange)
# matching the GitHub Actions toolkit's own OidcClient.getIDToken (encodeURIComponent(audience)),
# confirmed against actions/toolkit's packages/core/src/oidc-utils.ts. The az login form
# (`--service-principal --username <id> --tenant <tenant> --federated-token <token>` then a
# separate `az account set --subscription <id>`) matches Azure/login's own
# src/Cli/AzureCliLogin.ts implementation, confirmed against the upstream source.
#
# On ANY failure (missing env, no id-token in the response, az login non-zero, az account set
# non-zero) this prints ::error:: and returns non-zero. Callers MUST treat a failed re-login as
# FAIL LOUD and never continue past it (locked decision 9.2b) - never retried silently here.
az_relogin() {
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    echo "::error::az_relogin: ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN not set - the job is missing 'permissions: id-token: write'. Cannot mint a fresh OIDC assertion."
    return 1
  fi
  if [ -z "${AZURE_CLIENT_ID:-}" ] || [ -z "${AZURE_TENANT_ID:-}" ] || [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
    echo "::error::az_relogin: AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID not set in the environment - cannot re-authenticate."
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "::error::az_relogin: curl and jq are both required to mint a fresh OIDC assertion (ubuntu-latest ships both by default)."
    return 1
  fi

  local id_token_response id_token
  id_token_response="$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=api%3A%2F%2FAzureADTokenExchange")"
  if [ -z "$id_token_response" ]; then
    echo "::error::az_relogin: empty response from the GitHub OIDC token endpoint."
    return 1
  fi
  id_token="$(printf '%s' "$id_token_response" | jq -r '.value // empty' 2>/dev/null)"
  if [ -z "$id_token" ]; then
    echo "::error::az_relogin: GitHub returned no id-token value (response: ${id_token_response})."
    return 1
  fi

  local login_err
  if ! login_err="$(az login --service-principal --username "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" \
      --federated-token "$id_token" --output none 2>&1)"; then
    echo "::error::az_relogin: az login with the fresh federated assertion failed: ${login_err}"
    return 1
  fi
  if ! login_err="$(az account set --subscription "$AZURE_SUBSCRIPTION_ID" --output none 2>&1)"; then
    echo "::error::az_relogin: az account set --subscription failed after login: ${login_err}"
    return 1
  fi
  return 0
}

# wait_for_rgs_gone - bounded reconciliation wait for a set of (sub, rg) pairs to report gone
# (docs/teardown-redesign.md section 9.3 / ADR-054 amendment point 8). The WAIT lives here, in
# Phase 2 - Phase 3 VERIFY stays an instant, unwaited truth-gate (never put a wait inside the
# auditor). Calls `az_relogin` at the START of every iteration (locked decision 9.2c) so a poll
# can never outlive the token that started it, no matter how long the wait runs. Ceiling is 30
# minutes (1800s), well under the 360-min job ceiling.
#
# Args: alternating "<sub> <rg>" pairs, e.g. wait_for_rgs_gone "$sub1" "$rg1" "$sub2" "$rg2" ...
# Return codes (NEVER a silent success):
#   0 = every pair confirmed gone.
#   1 = the ceiling was reached with pair(s) still present (a plain still-deleting straggler,
#       not an auth problem) - advisory; Phase 3 VERIFY is the authoritative completion gate
#       and an idempotent operator re-dispatch is the documented safety net.
#   2 = a re-login failed OR an existence check came back auth-classified mid-wait - this is
#       the section-9.4 "auth error must fail loud" case, distinct from a slow delete. Callers
#       MUST treat a 2 as a hard failure of the calling script (docs/teardown-redesign.md
#       section 10.3: "any auth-classified failure at any step is a hard non-zero exit"), not
#       just a Phase-3-will-catch-it warning.
wait_for_rgs_gone() {
  local ceiling=1800 interval=20 waited=0
  local -a subs=() rgs=()
  while [ "$#" -gt 0 ]; do
    subs+=("$1")
    rgs+=("$2")
    shift 2
  done
  if [ "${#rgs[@]}" -eq 0 ]; then
    echo "  wait_for_rgs_gone: nothing to wait on."
    return 0
  fi

  while [ "$waited" -lt "$ceiling" ]; do
    if ! az_relogin; then
      echo "::error::wait_for_rgs_gone: az_relogin failed mid-wait - hard failure, not a plain timeout."
      return 2
    fi

    local -a still_subs=() still_rgs=()
    local i exists exists_rc
    for i in "${!rgs[@]}"; do
      # Deliberately plain az_run here, NOT az_run_retry (2026-07-30 fix round) - this call
      # already lives inside a loop that never fails loud on a non-auth failure (below, a
      # non-zero/unexpected result is treated as "still pending" and retried on the next 20s
      # iteration, re-authenticating via az_relogin every time). Wrapping it in az_run_retry too
      # would nest one bounded retry inside an already-retrying wait for no behavioural gain.
      # az_run is called DIRECTLY here (never inside a `$(...)` subshell) - az_run's
      # AZ_RUN_STDERR global side effect would otherwise be lost the instant a subshell exits.
      # A stderr WARNING banner on an otherwise-clean call must never corrupt the "true"/"false"
      # data channel this comparison relies on.
      az_run exists group exists --name "${rgs[$i]}" --subscription "${subs[$i]}"
      exists_rc=$?
      if [ "$exists_rc" -eq 0 ] && [ "$exists" = "true" ]; then
        still_subs+=("${subs[$i]}")
        still_rgs+=("${rgs[$i]}")
      elif [ "$exists_rc" -eq 0 ] && [ "$exists" = "false" ]; then
        : # gone - not re-added to still_subs/still_rgs
      else
        # Non-zero exit, or an unexpected (non-true/false) stdout value. Classify the failure
        # (section 9.4) instead of silently assuming the RG is gone.
        if is_auth_error "$AZ_RUN_STDERR"; then
          echo "::error::wait_for_rgs_gone: auth/transport error checking ${rgs[$i]} in ${subs[$i]}: ${AZ_RUN_STDERR}"
          return 2
        fi
        echo "  ::warning::wait_for_rgs_gone: could not confirm state of ${rgs[$i]} (rc=${exists_rc}, stdout='${exists}', stderr: ${AZ_RUN_STDERR}) - treating as still pending."
        still_subs+=("${subs[$i]}")
        still_rgs+=("${rgs[$i]}")
      fi
    done

    if [ "${#still_rgs[@]}" -eq 0 ]; then
      echo "  wait_for_rgs_gone: all RG(s) confirmed gone (waited ${waited}s)."
      return 0
    fi
    subs=("${still_subs[@]}")
    rgs=("${still_rgs[@]}")
    echo "  wait_for_rgs_gone: ${#rgs[@]} RG(s) still present after ${waited}s (${rgs[*]}) - sleeping ${interval}s."
    sleep "$interval"
    waited=$((waited + interval))
  done

  echo "::warning::wait_for_rgs_gone: ${#rgs[@]} RG(s) still present after the ${ceiling}s ceiling (${rgs[*]}) - Phase 3 VERIFY will report these as remnants; re-dispatch (idempotent) is the safety net for this straggler."
  return 1
}
