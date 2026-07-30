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

# Security Log Analytics workspace purge (OQ-063, ADR-066) - fixed identifiers,
# not a naming-pattern match, because this step targets exactly ONE known object by name, not
# a discovered class. Sourced from platform/security/main.tf's own naming
# ("law-security-${var.org_prefix}-${var.environment}" / "rg-security-${var.org_prefix}-${var.
# environment}") and envs/poc.tfvars (org_prefix=globaris, environment=poc) - MUST be kept in
# lock-step with those two files if either ever renames the security root's workspace or RG
# (same coupling discipline RG_SWEEP_QUERY and DEFENDER_PLANS_TO_FREE above already carry).
# api-version matches the REST example in Microsoft's own "Delete and recover an Azure Log
# Analytics workspace" doc (learn.microsoft.com/en-us/azure/azure-monitor/logs/delete-workspace,
# ms.date verified live 2026-07-29) - used only for the post-purge confirm-GET below; every
# CLI command (recover/delete) uses the CLI's own bundled api-version, never this constant.
SECURITY_LAW_WORKSPACE_NAME="law-security-globaris-poc"
SECURITY_LAW_RESOURCE_GROUP_NAME="rg-security-globaris-poc"
SECURITY_LAW_API_VERSION="2025-07-01"

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
# SAME RG_SWEEP_QUERY naming-pattern filter step 2's RG sweep already uses, via az_run (stdout/
# stderr kept separate, Finding #2 discipline). Shared discovery primitive for every NEW
# RG-scope check this fix adds (FIX-2 budgets, FIX-3 exemptions, the probe's RG-scoped
# budgets/exemptions/diagnostic-settings sections) - discovery BY LIST, never a hardcoded RG
# name list, matching the lesson ADR-062 already drew ("enumerated class lists are the wrong
# mechanism") and step 6a's own stated design ("Discovery is by LIST, never a hardcoded name
# list, so a renamed or added object is still caught"). Returns az_run's own exit code - callers
# MUST treat a non-zero return as FAIL LOUD (a live subscription's RG list can never legitimately
# fail, same section 9.4 boundary as every other subscription-scoped list in this codebase), not
# as "no RGs".
discover_live_rgs() {
  local __out_var="$1" __sub="$2"
  az_run "$__out_var" group list --subscription "$__sub" --query "$RG_SWEEP_QUERY" -o tsv
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
# prints its own ::error:: before returning, matching az_run-consuming callers elsewhere).
# Delete-submission failure: classify with is_auth_error - auth-shaped fails loud (return 1);
# anything else is a warn-and-continue (idempotent retry on next run), matching every other
# delete in this codebase. Zero workspaces found in any subscription is success (both arrays
# left empty), not an error.
databricks_force_delete_cascade() {
  local -n __dbx_out_rgs="$1"
  local -n __dbx_out_subs="$2"
  local sub row ws_name ws_rg managed_rg_id managed_rg_name
  local dbx_rows_out dbx_del_out
  local -a dbx_rows
  for sub in $(teardown_subscriptions); do
    if ! az_run dbx_rows_out databricks workspace list --subscription "$sub" \
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
# truth for the rest of the run - a dead token cannot return a clean list.
declare -gA MG_SNAPSHOT
mg_snapshot_load() {
  MG_SNAPSHOT=()
  local names_out name
  if ! az_run names_out account management-group list --query "[].name" -o tsv; then
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
