# scripts/teardown-probe-state.sh - READ-ONLY state-blob inventory probe (teardown-completeness
# extension sweep, 2026-07-23). Deliverable 1, Part A. Operationalises OPEN-QUESTIONS.md
# OQ-053 option A(ii): "wire the pre-plan state-provenance probe into CI so an absent blob is
# DETECTED and surfaced rather than silently read as greenfield". This script deletes nothing -
# it inventories all 12 known Terraform-state blob keys on the firewalled state Storage Account
# (exists + contentLength for each) and reports every absent-or-tiny key as a Class-A
# lost-state root: a root whose state cannot be trusted, so a plan/apply against it would
# silently treat live-but-unstated Azure resources as greenfield (ImportAsExistsError at best,
# a duplicate-name collision or a false "clean slate" at worst).
#
# Root cause this closes (2026-07-23 rebuild failure at Step 2): the estate's teardown tooling
# is entirely az-sweep-mode-driven for some roots because Phase 1 terraform-destroy is
# impossible for a root whose state blob is already gone (OQ-053). Before this probe existed,
# nobody had a single authoritative answer to "which roots actually have trustworthy state
# right now" - this script is that answer, read-only and CI-runnable.
#
# WHY THIS RUNS IN CI, NOT LOCALLY (hard rule, DevSecOps lane): the state Storage Account is
# Entra-only (shared_access_key_enabled = false, bootstrap/main.tf) and firewalled
# default_action=Deny with a static ip_rules list (ADR-025) - a local session's rotating egress
# IP cannot reach it. Only the deploy/teardown CI runner, authenticated via OIDC and holding
# Storage Blob Data Contributor on the account (bootstrap/identity.tf), can reach the blob data
# plane with `--auth-mode login`. The calling workflow (.github/workflows/teardown-probe.yml)
# opens the SA firewall for this run's window (the same JIT open/3-consecutive-probe-wait/
# restore-Deny pattern _tf-root.yml already uses for manage_runner_ip, ADR-025) and restores
# Deny on exit - this script assumes that window is already open when it runs and does not
# manage the firewall itself.
#
# 12 state-blob keys (matches every `-backend-config="key=<root>/terraform.tfstate"` used by
# .github/workflows/_tf-root.yml, plus one defensive check - see BOOTSTRAP_KEY below):
#   platform/management-groups, platform/management, platform/connectivity, platform/identity,
#   platform/security, landing-zones/bank-app-p1, landing-zones/bank-data-p1,
#   landing-zones/corp-a1, landing-zones/corp-a2, landing-zones/online-p1, synthetic, bootstrap.
#
# BOOTSTRAP KEY NOTE (verify-before-write catch, 2026-07-23): bootstrap/providers.tf states
# explicitly "This root module uses LOCAL state (ADR-005). Do not configure a backend block
# here." - bootstrap has NEVER written to the remote tfstate container by design, so an ABSENT
# bootstrap/terraform.tfstate blob is the CORRECT, EXPECTED state, not a loss signal. This
# script still probes for it (defensive - in case someone ever experimented with a remote
# bootstrap backend) but classifies an absent bootstrap key as INFO, never as Class-A. Every
# other key IS expected to exist once its root has been applied at least once.
#
# AMENDED 2026-07-30 (transient-list-failure fix round - see teardown-common.sh's "AMENDED an
# eighth time" header note for the full incident and mechanism). Both `storage blob exists` / `az
# storage blob show` reads below now use `az_run_retry` (teardown-common.sh) instead of `az_run` -
# same signature, bounded retry (3 attempts, ~10s apart by default) ONLY for a transient HTTP
# 5xx/429 that is not also auth-shaped. A false Class-A finding from one transient blip here would
# be a costly false alarm (this probe's whole purpose is to be trusted evidence for whether a
# root's state is safe to plan/apply against).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./teardown-common.sh
source "${script_dir}/teardown-common.sh"

# "Tiny" threshold (bytes) below which a PRESENT blob is still flagged Class-A. A genuinely
# empty-but-valid Terraform state (fresh init, zero resources) is a small JSON document -
# `{"version":4,"terraform_version":"...","serial":1,"lineage":"<uuid>","outputs":{},
# "resources":[]}` - typically 150-250 bytes depending on the terraform_version string length
# and the lineage UUID. This is an ENGINEERING HEURISTIC (not a verified Azure/Terraform fact -
# there is no documented minimum state-file size), chosen conservatively below that natural
# floor so a truncated/corrupted/zero-byte blob is caught without flagging a legitimate empty
# state as lost. Re-tune if a real empty-state blob is ever observed below this value.
TINY_BLOB_THRESHOLD_BYTES=100

# repo_root: this script always runs from the repository root in CI (checkout@v4 default
# working directory) - resolved relative to this script's own location so it also works when
# invoked from a developer's local clone for a syntax/dry-run check (no live Azure calls made
# during such a check - only reached once az calls actually run).
repo_root="$(cd "${script_dir}/.." && pwd)"
backend_hcl="${repo_root}/envs/poc.backend.hcl"

if [ ! -f "$backend_hcl" ]; then
  echo "::error::${backend_hcl} not found - cannot resolve the state Storage Account name/RG/container."
  exit 1
fi

SA_NAME="$(grep -E '^\s*storage_account_name' "$backend_hcl" | sed -E 's/.*=\s*"?([^"#[:space:]]+)"?.*/\1/')"
SA_RG="$(grep -E '^\s*resource_group_name'  "$backend_hcl" | sed -E 's/.*=\s*"?([^"#[:space:]]+)"?.*/\1/')"
CONTAINER="$(grep -E '^\s*container_name'     "$backend_hcl" | sed -E 's/.*=\s*"?([^"#[:space:]]+)"?.*/\1/')"

if [ -z "$SA_NAME" ] || [ -z "$SA_RG" ] || [ -z "$CONTAINER" ]; then
  echo "::error::Could not parse storage_account_name/resource_group_name/container_name from ${backend_hcl}."
  exit 1
fi

echo "== State-blob inventory probe: SA=${SA_NAME} RG=${SA_RG} container=${CONTAINER} =="

# BOOTSTRAP_KEY is checked defensively (see the header note) but never contributes to the
# Class-A count on absence - only on presence-with-tiny-content, which would be a genuine
# anomaly worth flagging (someone wrote something small there).
BOOTSTRAP_KEY="bootstrap/terraform.tfstate"
declare -a STATE_KEYS=(
  "platform/management-groups/terraform.tfstate"
  "platform/management/terraform.tfstate"
  "platform/connectivity/terraform.tfstate"
  "platform/identity/terraform.tfstate"
  "platform/security/terraform.tfstate"
  "landing-zones/bank-app-p1/terraform.tfstate"
  "landing-zones/bank-data-p1/terraform.tfstate"
  "landing-zones/corp-a1/terraform.tfstate"
  "landing-zones/corp-a2/terraform.tfstate"
  "landing-zones/online-p1/terraform.tfstate"
  "synthetic/terraform.tfstate"
  "$BOOTSTRAP_KEY"
)

declare -a CLASS_A_ROOTS=()
fail=0

for key in "${STATE_KEYS[@]}"; do
  # `az storage blob exists` - stdout is a bare "true"/"false" (or "{...}" with -o json; -o tsv
  # keeps it a bare scalar). A non-zero exit here is INDETERMINATE (could be a transient
  # transport error, could be an auth error) - never read as "false" (that would be exactly the
  # false-negative class ADR-062/section 9.4 already closed for other list calls in this
  # codebase). az_run keeps stdout/stderr separate (Finding #2 discipline).
  if ! az_run_retry exists_out storage blob exists \
      --account-name "$SA_NAME" --container-name "$CONTAINER" --name "$key" \
      --auth-mode login --query exists -o tsv; then
    if is_auth_error "$AZ_RUN_STDERR"; then
      echo "::error::blob exists check for ${key} failed with an auth/transport error - cannot certify this key's state (the firewall-open window in the calling workflow may not have settled, or the Storage Blob Data Contributor grant is missing): ${AZ_RUN_STDERR}"
    else
      echo "::error::blob exists check for ${key} failed for an unexpected non-auth reason - cannot certify this key's state: ${AZ_RUN_STDERR}"
    fi
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # exists_out is assigned indirectly by az_run's printf -v

  if [ "$exists_out" != "true" ]; then
    if [ "$key" = "$BOOTSTRAP_KEY" ]; then
      echo "  INFO  ${key}: absent - EXPECTED (bootstrap uses LOCAL state by design, ADR-005; this is not a loss signal)."
    else
      echo "  CLASS-A  ${key}: ABSENT (BlobNotFound) - this root's state cannot be trusted. terraform destroy is impossible here; this root can only be reconciled via az-sweep + confirm-GET or a config-driven import."
      CLASS_A_ROOTS+=("$key")
    fi
    continue
  fi

  # Present - check contentLength. `az storage blob show` failing here (blob just confirmed to
  # exist) is itself an anomaly - classify and fail loud rather than silently skip the size
  # check (a present-but-unreadable blob is not "fine").
  if ! az_run_retry length_out storage blob show \
      --account-name "$SA_NAME" --container-name "$CONTAINER" --name "$key" \
      --auth-mode login --query properties.contentLength -o tsv; then
    if is_auth_error "$AZ_RUN_STDERR"; then
      echo "::error::blob show for ${key} (confirmed to exist) failed with an auth/transport error - cannot certify its size: ${AZ_RUN_STDERR}"
    else
      echo "::error::blob show for ${key} (confirmed to exist) failed for an unexpected non-auth reason - cannot certify its size: ${AZ_RUN_STDERR}"
    fi
    fail=1
    continue
  fi
  # shellcheck disable=SC2154  # length_out is assigned indirectly by az_run's printf -v
  case "$length_out" in
    ''|*[!0-9]*)
      echo "::error::blob show for ${key} returned a non-numeric contentLength ('${length_out}') - cannot certify its size."
      fail=1
      continue
      ;;
  esac

  if [ "$length_out" -lt "$TINY_BLOB_THRESHOLD_BYTES" ]; then
    if [ "$key" = "$BOOTSTRAP_KEY" ]; then
      echo "  ANOMALY  ${key}: present but tiny (${length_out} bytes) - unexpected for a root that should never have remote state at all (ADR-005). Worth a manual look, not auto-classified Class-A."
    else
      echo "  CLASS-A  ${key}: present but TINY (${length_out} bytes, below the ${TINY_BLOB_THRESHOLD_BYTES}-byte heuristic floor) - likely truncated/corrupted, cannot be trusted as a real Terraform state."
      CLASS_A_ROOTS+=("$key")
    fi
  else
    echo "  OK  ${key}: present, ${length_out} bytes."
  fi
done

echo "----------------------------------------------------------------"
if [ "${#CLASS_A_ROOTS[@]}" -gt 0 ]; then
  echo "Class-A lost-state roots (${#CLASS_A_ROOTS[@]}):"
  for r in "${CLASS_A_ROOTS[@]}"; do
    echo "  - ${r}"
  done
  echo "These roots cannot go through Phase 1 terraform-destroy (mode=terraform) - dispatch teardown with mode=az-sweep for a whole-estate run, or reconcile the specific root via config-driven import (LESSON 46) before any apply against it."
else
  echo "No Class-A lost-state roots found - every checked key (except the intentionally-local bootstrap key) is present and above the tiny-blob threshold."
fi

if [ "$fail" -ne 0 ]; then
  echo "::error::STATE-BLOB PROBE FAILED - one or more keys could not be certified (see the errors above). This is a probe-availability failure, distinct from 'Class-A roots were found' - treat as indeterminate, not as evidence of a clean estate."
  exit 1
fi

echo "State-blob inventory probe complete."
exit 0
