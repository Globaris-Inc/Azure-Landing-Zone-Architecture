#!/usr/bin/env bash
# scripts/check-adr-landed.sh - every Accepted ADR from the baseline onward must say where
# its decision landed in code.
#
# Why this exists: ADR-034 named `-parallelism=1` as its sanctioned control for the Defender
# pricing race. Nothing ever wired it into the apply step. The gap surfaced 33 ADRs later,
# in ADR-067, as a live apply failure on a clean-state security root - and only because a
# human went looking. With 71 ADR entries and no traceability from decision to code, "we decided
# that" and "that is running" had drifted apart with nothing able to tell the difference.
#
# The check: each `### ADR-NNN` block with `**Status:** Accepted` and NNN >= BASELINE must
# carry a `**Landed:**` line whose value is one of:
#   - a commit sha (optionally "(PR #N)")   - the decision is in the tree
#   - NOT IMPLEMENTED                        - honest backlog, passes the check by design
#   - N/A                                   - the decision requires no code (naming, process)
# A missing field fails. NOT IMPLEMENTED passing is deliberate: the goal is an accurate
# register, not a coerced one. Lying costs more than admitting.
#
# Usage:
#   scripts/check-adr-landed.sh            check ADRs >= baseline
#   scripts/check-adr-landed.sh --legacy   also list pre-baseline ADRs as unverifiable
# Exit 0 = PASS, 1 = at least one Accepted ADR missing the field, 2 = setup error.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 2
cd "$repo_root" || exit 2

BASELINE=68   # ADR-001..067 predate the field (added 2026-07-30) and are exempt.
adr_file="DECISIONS.md"
[ -f "$adr_file" ] || { echo "check-adr-landed: $adr_file not found" >&2; exit 2; }

show_legacy=0
[ "${1:-}" = "--legacy" ] && show_legacy=1

awk -v baseline="$BASELINE" -v show_legacy="$show_legacy" '
function flush_block() {
  if (num == 0) return
  # The template block itself is not an ADR.
  if (in_template) return
  # Anchored on purpose. A bare /Accepted/ substring test also matches a line reading
  # "Superseded by ADR-072 (was previously Accepted on ...)", and Status lines in this file
  # carry rich parentheticals by convention, so the loose test would fail a Superseded ADR
  # for missing a field it does not need.
  is_accepted = (status ~ /^- \*\*Status:\*\*[[:space:]]*Accepted([^A-Za-z]|$)/)

  if (num < baseline) {
    legacy++
    if (show_legacy && is_accepted)
      printf "  legacy  ADR-%03d (pre-baseline, landing unverifiable): %.70s\n", num, title
    return
  }
  if (!is_accepted) { skipped++; return }
  checked++
  if (!has_landed) {
    printf "  FAIL ADR-%03d has Status: Accepted but no **Landed:** field\n", num
    printf "       %.90s\n", title
    fail = 1
  } else if (landed == "") {
    printf "  FAIL ADR-%03d has a **Landed:** field with no value\n", num
    printf "       %.90s\n", title
    fail = 1
  }
}

/^## Template/ { in_template = 1 }
/^## ADRs/     { in_template = 0 }

/^### ADR-[0-9]+/ {
  flush_block()
  num = 0; status = ""; landed = ""; has_landed = 0; title = $0
  if (match($0, /ADR-[0-9]+/)) num = substr($0, RSTART + 4, RLENGTH - 4) + 0
  next
}

/^- \*\*Status:\*\*/  { if (status == "") status = $0 }
/^- \*\*Landed:\*\*/  {
  # has_landed tracks the LINE, landed tracks its VALUE, so "field absent" and "field
  # present but empty" stay distinguishable. Collapsing them made one branch unreachable
  # and its message wrong about which condition fired.
  #
  # Take the LAST such line in the block, not the first. DECISIONS.md updates are made by
  # dated, append-only addendum - the body is never edited - so a later Landed line
  # supersedes an earlier one. Keeping the first line reported an ADR as NOT IMPLEMENTED
  # forever even after an addendum recorded its landing commit: confirmed against ADR-069,
  # whose body (written pre-implementation) still reads NOT IMPLEMENTED while its
  # 2026-07-31 addendum records Landed: 91523dc (PR #60).
  has_landed = 1
  landed = $0
  sub(/^- \*\*Landed:\*\*[[:space:]]*/, "", landed)
}

END {
  flush_block()
  printf "check-adr-landed: %d ADR(s) at or after ADR-%03d checked", checked, baseline
  printf ", %d pre-baseline exempt, %d not Accepted\n", legacy, skipped
  if (fail) {
    print "check-adr-landed: FAIL - add a **Landed:** line (a commit sha, NOT IMPLEMENTED, or N/A)."
    print "  An Accepted decision with no landing reference cannot be shown to be running."
  } else {
    print "check-adr-landed: PASS"
  }
  exit fail
}
' "$adr_file"
