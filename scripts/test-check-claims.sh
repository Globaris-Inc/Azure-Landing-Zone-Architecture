#!/usr/bin/env bash
# scripts/test-check-claims.sh - regression suite for check-claims.sh and
# check-worktrees.sh path detection.
#
# Every case here is a defect that actually shipped in a draft of these scripts and was
# caught at the code-reviewer gate, not a hypothetical. The two scripts are preflight gates,
# so a defect in them either blocks all work (false positive) or silently passes the exact
# thing they exist to catch (false negative). Run this before changing either script.
#
# Usage: scripts/test-check-claims.sh
# Exit 0 = all cases pass, 1 = at least one case failed.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 2
cd "$repo_root" || exit 2

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0; failed=0

# want_fails: how many FAIL lines check-claims.sh should emit for this fixture.
case_claims() {
  local name="$1" want="$2" body="$3" f="$tmp/case.sh"
  printf '%s' "$body" > "$f"
  local got
  got="$(bash scripts/check-claims.sh "$f" 2>&1 | grep -cE '^  FAIL')"
  if [ "$got" = "$want" ]; then
    printf '  PASS  %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s (expected %s FAIL line(s), got %s)\n' "$name" "$want" "$got"
    sed 's/^/          | /' "$f"
    failed=$((failed + 1))
  fi
}

echo "== check-claims.sh =="

# --- the reviewer BLOCK cases ----------------------------------------------------------
case_claims "ordinary past tense 'were' does not suppress" 1 \
'# The last three CI runs were green: enable_data_platform is false right now.
'
case_claims "unrelated earlier subordinator does not carry across a finished sentence" 1 \
'# When Fabric capacity was reviewed last month, we confirmed pricing.
# enable_data_platform is false right now.
'
case_claims "abbreviation period does not strand a governing conditional" 0 \
'# If the platform is tested for e.g. cost overrun scenarios,
# enable_om_phase1 is true only in that test harness.
'
# "etc." routinely ends a sentence and English does not double the period. Neutralising it
# removed the only sentence break in the span, kept the earlier "If" in scope, and silently
# suppressed the claim after it. The claim here is unconditional and MUST be reported.
case_claims "sentence-ending 'etc.' still breaks the clause" 1 \
'# If a real outage ever forced a rollback for pools, workers, etc. enable_data_platform is false, unconditionally, regardless of that history.
'
case_claims "sentence-ending 'etc.' breaks the clause across lines too" 1 \
'# If a real outage ever forced a rollback for pools, workers, etc.
# enable_data_platform is false, unconditionally, regardless of that history.
'
case_claims "bare comment divider ends the paragraph and the carry" 1 \
'# If retries were ever attempted here that would matter
#
# Now unconditionally enable_data_platform is false in this new paragraph
'
# The first divider fix matched only a bare "#" and missed the dashed banner this repo uses
# in 72 tracked files, leaving the defect it was written to close wide open. All three
# divider shapes are tested now, because the class is what matters, not the instance.
case_claims "dashed divider ends the paragraph and the carry" 1 \
'# If retries were ever attempted here that would matter
# --------------------------------------------------------------------------
# Now unconditionally enable_data_platform is false in this new paragraph
'
case_claims "titled dashed banner ends the paragraph and the carry" 1 \
'# If retries were ever attempted here that would matter
# --- section name ---------------------------------------------------------
# Now unconditionally enable_data_platform is false in this new paragraph
'
case_claims "equals divider ends the paragraph and the carry" 1 \
'# If retries were ever attempted here that would matter
# ==========================================================================
# Now unconditionally enable_data_platform is false in this new paragraph
'
case_claims "a divider does not wrongly clear a same-paragraph conditional" 0 \
'# If the estate is torn down for a rebuild,
# enable_data_platform is false during that window
'

# --- conditional handling ----------------------------------------------------------------
case_claims "same-line conditional suppresses" 0 \
'# route tables are ABSENT while enable_firewall = false, so nothing may assume them
'
case_claims "wrapped conditional still suppresses across the line break" 0 \
'# If the platform were to be considered fully cost constrained under the current estate
# design and budget posture, enable_data_platform is false in this scenario.
'
case_claims "uppercase WHEN suppresses" 0 \
'# WHEN the flag is off, enable_data_platform = false applies
'

# --- the defect the script exists to catch ------------------------------------------------
case_claims "plain false claim in a comment is caught" 1 \
'# enable_data_platform=false in this estate, nothing to do
'
case_claims "false claim in a runtime echo is caught" 1 \
'echo "nothing to cascade (enable_data_platform=false in this estate)"
'
case_claims "true claim is not reported" 0 \
'# enable_data_platform is true in this estate
'
case_claims "claim with no conditional anywhere is caught" 1 \
'# Notify the team. enable_data_platform=false is wrong here
'

# --- carry bounds -------------------------------------------------------------------------
case_claims "carry does not leak past a code line" 1 \
'# If something were true here, that is one thing.
code_line=1
# enable_data_platform=false right now
'
case_claims "carry does not leak past a sentence break" 1 \
'# If the flag were off we would skip. That is settled now.
# enable_data_platform=false today
'

# --- scope --------------------------------------------------------------------------------
case_claims "real HCL assignment is not a claim" 0 \
'enable_data_platform = false
'
case_claims "claims-ok suppresses deliberately historical text" 0 \
'# enable_data_platform=false back in July (claims-ok: historical)
'
case_claims "flag absent from tfvars is ignored" 0 \
'# enable_not_a_real_flag_xyz = false
'

echo
echo "== check-worktrees.sh volatile-path matching =="
# The regex is the security-relevant half of that script; test it directly.
VOL='[/\\](temp|tmp)[/\\]|scratchpad'
case_path() {
  local name="$1" want="$2" path="$3" got=no
  printf '%s' "$path" | grep -qiE "$VOL" && got=yes
  if [ "$got" = "$want" ]; then
    printf '  PASS  %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s (expected volatile=%s, got %s) [%s]\n' "$name" "$want" "$got" "$path"
    failed=$((failed + 1))
  fi
}
case_path "title-case Temp"    yes 'C:\Users\x\Temp\wt'
case_path "upper-case TEMP"    yes 'C:\Users\x\TEMP\wt'
case_path "lower-case tmp"     yes '/home/u/tmp/wt'
case_path "upper-case TMP"     yes '/home/u/TMP/wt'
case_path "SCRATCHPAD"         yes '/home/u/SCRATCHPAD/wt'
case_path "durable repo path"  no  'C:\Users\x\OneDrive\Documents\Claude Projects\Azure-Architecture'
case_path "no false hit on 'template'" no '/home/u/templates/wt'

echo
echo "== script integrity =="
# An apostrophe inside a single-quoted awk body silently terminates the string, and bash
# then fails on the next parenthesis with an error pointing at the wrong line entirely.
# This broke check-claims.sh and check-adr-landed.sh three times during one session, always
# from ordinary prose in a comment (repo's, file's, codebase's). Cheaper to test than to
# rediscover.
for s in scripts/check-claims.sh scripts/check-adr-landed.sh scripts/check-worktrees.sh scripts/preflight.sh; do
  if bash -n "$s" 2>/dev/null; then
    printf '  PASS  %s parses\n' "$s"; pass=$((pass + 1))
  else
    printf '  FAIL  %s does not parse (apostrophe inside an awk body?)\n' "$s"
    bash -n "$s" 2>&1 | sed 's/^/          | /'
    failed=$((failed + 1))
  fi
done

echo
echo "test-check-claims: $pass passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
