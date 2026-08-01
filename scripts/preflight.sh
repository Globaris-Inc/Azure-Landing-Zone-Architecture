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
#   5. shellcheck on scripts/*.sh (best-effort; skipped if not installed). Added
#      2026-07-31: a PR #59 draft deleted a `cut -f3` extraction and left a lowercasing on
#      the now-unassigned variable. Under `set -u` that is a fatal abort at the next
#      teardown, not a misread, and `bash -n` (syntactically valid) plus a clean preflight
#      caught nothing - only a careful human diff read did. SC2154 (referenced but not
#      assigned) is exactly what shellcheck exists to flag. Run at --severity=warning so it
#      catches that class of correctness bug without blocking on pure style/quoting nits;
#      the teardown scripts already carry `# shellcheck disable=SC2154` /
#      `# shellcheck source=` directives for their legitimate indirect-assignment and
#      dynamic-source patterns.
#   6. check-adr-landed.sh - Accepted ADRs from ADR-068 on must say where they landed.
#      Catches the ADR-034 class: a sanctioned control that nobody ever wired up.
#   7. check-worktrees.sh - uncommitted work in a volatile path (Temp/scratchpad) fails.
#      This repo has lost agent output twice that way; see the script header. Also WARNs
#      (not a fail - `ops/*` rebuild-dispatch branches checked out in the main tree are a
#      routine, sanctioned pattern, so this cannot be a hard gate) when the shared repo tree
#      is checked out on anything but main/banking, the precondition behind the 2026-07-31
#      collision.
#
# NOT wired in: scripts/check-claims.sh. It is useful and it found a real defect nothing
# else did, but it parses English prose heuristically, and a heuristic has unbounded edge
# cases. Four review rounds each found another one, in both directions. That is the wrong
# shape for a check that can block every commit, so it stays a hand-run tool:
#     bash scripts/check-claims.sh [file ...]
# Run it when touching prose that asserts a flag value. Do not wire it back into this
# script without a parser that is exact rather than heuristic.
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

# --- 5. shellcheck (best-effort) ---
hr; echo "[5] shellcheck (scripts/*.sh)"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning scripts/*.sh; then note "OK"; else note "FAIL"; fail=1; fi
else
  note "SKIP: shellcheck not installed"
fi

# --- 6. Accepted ADRs record where they landed ---
hr; echo "[6] check-adr-landed (Accepted ADRs cite a landing)"
if bash scripts/check-adr-landed.sh > /tmp/pf_adr.log 2>&1; then
  note "OK: $(tail -2 /tmp/pf_adr.log | head -1)"
else
  note "FAIL:"; sed 's/^/    /' /tmp/pf_adr.log; fail=1
fi

# --- 7. no uncommitted work parked somewhere volatile ---
hr; echo "[7] check-worktrees (uncommitted work in volatile paths)"
if bash scripts/check-worktrees.sh > /tmp/pf_wt.log 2>&1; then
  note "OK: $(tail -1 /tmp/pf_wt.log)"
  grep '^  WARN' /tmp/pf_wt.log | sed 's/^/  /' || true
else
  note "FAIL:"; sed 's/^/    /' /tmp/pf_wt.log; fail=1
fi

hr
if [ "$fail" -ne 0 ]; then echo "PREFLIGHT: FAIL"; exit 1; fi
echo "PREFLIGHT: PASS"
