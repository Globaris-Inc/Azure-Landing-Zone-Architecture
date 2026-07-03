#!/usr/bin/env bash
# scripts/preflight.sh - "validate the way CI runs" (landing-zone-kit process.md §3).
#
# Checks, in order:
#   1. CI terraform pin == local terraform pin (drift catches the version-floor class).
#   2. terraform fmt -check -recursive (whole repo).
#   3. terraform init -backend=false + validate, per root. init itself enforces the
#      core/provider required_version floors, so a local version below any module's
#      floor fails here.
#   4. actionlint on .github/workflows (best-effort; skipped if not installed).
#
# Usage: scripts/preflight.sh [root ...]   (default: all roots with a providers.tf)
# Exit 0 = PASS, non-zero = FAIL.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 2
cd "$repo_root" || exit 2

fail=0
note() { printf '  %s\n' "$*"; }
hr()   { printf -- '----------------------------------------------------------------\n'; }

# --- 1. CI pin == local pin ---
hr; echo "[1] Terraform version: CI pin == local pin"
ci_pin="$(grep -oE 'TERRAFORM_VERSION: *"[0-9]+\.[0-9]+\.[0-9]+"' .github/workflows/validate.yml 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
local_pin="$(terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
note "CI pin (validate.yml): ${ci_pin:-<none>}"
note "local terraform:       ${local_pin:-<none>}"
if [ -z "$ci_pin" ] || [ -z "$local_pin" ]; then
  note "WARN: could not determine one of the pins"
elif [ "$ci_pin" != "$local_pin" ]; then
  note "FAIL: local terraform ($local_pin) != CI pin ($ci_pin)"; fail=1
else
  note "OK: pins match"
fi

# --- resolve roots ---
if [ "$#" -gt 0 ]; then
  roots=("$@")
else
  mapfile -t roots < <(git ls-files '*/providers.tf' 'providers.tf' | sed 's#/providers.tf$##' | sort -u)
fi

# --- 2. fmt ---
hr; echo "[2] terraform fmt -check -recursive"
if terraform fmt -check -recursive >/dev/null 2>&1; then
  note "OK: all files formatted"
else
  note "FAIL: unformatted files:"; terraform fmt -check -recursive 2>&1 | sed 's/^/    /'; fail=1
fi

# --- 3. init -backend=false + validate per root ---
hr; echo "[3] init -backend=false + validate per root"
for r in "${roots[@]}"; do
  printf '  %-38s ' "$r"
  if ( cd "$r" && terraform init -backend=false -input=false >/tmp/pf_init.log 2>&1 && terraform validate -no-color >/tmp/pf_val.log 2>&1 ); then
    echo "PASS"
  else
    echo "FAIL"; sed 's/^/      /' /tmp/pf_init.log /tmp/pf_val.log 2>/dev/null | tail -20; fail=1
  fi
done
note "(init enforces core/provider required_version floors)"

# --- 4. actionlint (best-effort) ---
hr; echo "[4] actionlint (.github/workflows)"
if command -v actionlint >/dev/null 2>&1; then
  if actionlint; then note "OK"; else note "FAIL"; fail=1; fi
else
  note "SKIP: actionlint not installed (CI still lints workflows)"
fi

hr
if [ "$fail" -ne 0 ]; then echo "PREFLIGHT: FAIL"; exit 1; fi
echo "PREFLIGHT: PASS"
