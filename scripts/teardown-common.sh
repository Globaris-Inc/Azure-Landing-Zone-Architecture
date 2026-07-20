# scripts/teardown-common.sh - shared constants for the 4-phase teardown (ADR-054).
# Sourced by teardown-disarm.sh, teardown-az-sweep.sh, teardown-verify.sh so the MG scope
# list and the RG naming-pattern match are defined ONCE. Drift between what DISARM clears
# and what VERIFY checks would silently defeat the loud-failure guarantee (design principle
# 5, docs/teardown-redesign.md). Not a standalone script (no shebang execution expected,
# no `set -e` here so it does not change the sourcing script's shell options) - `source` it.

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
