#!/usr/bin/env bash
# scripts/teardown-attachment-sweep.sh - Phase 1.5 ATTACHMENT SWEEP (ADR-072 decision 4).
# Runs in the ADR-066 serialized target=all chain, positioned AFTER `identity` and BEFORE
# `management` - the exact mirror of where ADR-063 G-1's precascade sits (before its host dies),
# because this class is keyed to its CONTAINER instead of a host, so the correct window is after
# every declaring root has destroyed and before the container-owning root (platform/management)
# destroys its own resource group.
#
# Root cause this closes (ADR-072). Teardown run 30685705802 failed platform/management's Phase
# 1 destroy: the resource-group delete was refused by the provider's own
# `prevent_deletion_if_contains_resources` guard because three objects survived inside
# rg-management-globaris-poc after the Log Analytics workspace itself destroyed cleanly - two
# Microsoft.Insights objects (a data collection endpoint and a data collection rule, both named
# NWTA-<derived from the workspace customerId>) created and managed by Traffic Analytics (NOT
# AMBA - see ADR-072 decision 1, correcting docs/estate-bom.md finding 1's original
# attribution), and one Microsoft.OperationsManagement/solutions ContainerInsights object
# created by landing-zones/bank-app-p1's AKS monitoring addon (the legacy `use_aad_auth = false`
# Container Insights path - OQ-068). None of these is managed by platform/management's own
# Terraform, and none is managed by the root that actually causes it either (Terraform
# structurally cannot own an RP-created side effect) - see ADR-072 decision 5, "attachment
# declares ownership".
#
# ADR-072 decision 2 REJECTS `prevent_deletion_if_contains_resources = false` for
# platform/management permanently (five reasons - the provider-level/root-wide/forever nature
# of the flag on the one root that is by design the estate's attachment sink, chief among them).
# ADR-072 decision 3 REJECTS "Phase 1 fails, Phase 2 catches it" as the standing design (a layer
# red on every teardown by construction carries no information - the exact masking failure
# ADR-066 INV-1 exists to prevent, reintroduced one layer over). This sweep is decision 4's
# mechanism instead: clear the three-object class BEFORE platform/management's own destroy runs,
# so that destroy can go green on its own merits again.
#
# Gated identically to Phase 0.5 DATABRICKS PRECASCADE plus a chain position: target=all AND
# mode=terraform only (ADR-072 decision 4's own gating spec, mirroring that job's header).
# mode=az-sweep is deliberately NOT wired here: Phase 1 never runs in that path, and the
# API-level `az group delete` on platform/management's RG (if it is ever reached that way)
# already cascades whatever the RG contains - a second mechanism there would be a redundant
# duplicate, not a fix.
#
# NOT A HARD GATE (ADR-072 decision 4, "not a gate", mirrors ADR-066 decision 4's Databricks
# precascade wiring - see that job's own header). A failure here is loud (this script exits
# non-zero and the JOB reports red) but must NEVER be read by `management`'s own `if:` in
# teardown.yml - `management` needs this job for ORDERING only (the same F1 convention every
# other Phase 1 job already uses). A residual left behind by a failure here surfaces instead as
# platform/management's own `prevent_deletion_if_contains_resources` error (a genuine,
# informative Phase 1 red - INV-1 stays meaningful) or a Phase 2 RG-sweep / Phase 3 VERIFY 2
# remnant, never as a silently-skipped mandatory layer.
#
# Idempotent: zero matching objects in any estate-owned RG is success, not an error - most
# estates most of the time have nothing here (this class only fires when Traffic Analytics or
# the legacy Container Insights path is actually configured against a shared workspace, which
# this estate's spokes do). Shares its entire implementation with
# `attachment_sweep_cross_root_objects` (teardown-common.sh) - see that function's own comment
# for the full three-part scope predicate, the ordering-mirror rationale, and the two verified
# api-version pins.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

echo "== Phase 1.5: Attachment sweep (cross-root RP-attached objects, ADR-072 decision 4) =="
if ! attachment_sweep_cross_root_objects; then
  echo "::error::Attachment sweep failed or found a residual it could not clear - see the errors above. This is Phase 1.5, a load-bearing predecessor of Phase 1's platform/management destroy (ADR-072 decision 4). NOTE: this is NOT a gate - platform/management needs this job for ORDERING only and still runs (INV-1' unaffected for this root). A surviving object here will surface as platform/management's own prevent_deletion_if_contains_resources error, or as a loud Phase 2/Phase 3 VERIFY remnant, never as a silently-skipped mandatory layer."
  exit 1
fi

echo "Attachment sweep complete - no cross-root RP-attached objects remain in any estate-owned resource group."
exit 0
