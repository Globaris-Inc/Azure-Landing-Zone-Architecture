#!/usr/bin/env bash
# scripts/check-worktrees.sh - fail when uncommitted work is sitting somewhere it can
# vanish.
#
# Why this exists: this repo has lost agent output twice. ADR-066 was written, never
# committed, and lost outright - commit 9974efa exists only to "re-record" it, and a whole
# session STOPPED because the ADR it was told to implement did not exist anywhere in the
# repository. Then on 2026-07-30 a 225-line pre-clearance REFRESH ADDENDUM carrying a GO
# verdict was found uncommitted in a worktree under the Windows Temp tree, on a branch that
# was already merged, i.e. one cleanup pass away from gone.
#
# The mechanism in both cases was the same: role agents are told never to commit, so their
# output lives only in a working tree, and if that tree is volatile or its branch gets
# cleaned up, the work is unrecoverable. The rule meant to protect the work is what exposes
# it.
#
# The check:
#   FAIL  - a worktree in a volatile path (Temp/tmp/scratchpad) has uncommitted tracked
#           changes. This is the loss scenario, and it is loud on purpose.
#   WARN  - a worktree in a durable path has uncommitted tracked changes. Normal mid-change,
#           but worth seeing before branch cleanup.
# `.terraform/` noise is ignored throughout.
#
# Usage: scripts/check-worktrees.sh [--strict]   (--strict: WARN also fails)
# Exit 0 = PASS, 1 = at-risk work found, 2 = setup error.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 2
cd "$repo_root" || exit 2

strict=0
[ "${1:-}" = "--strict" ] && strict=1

# Matched case-insensitively (grep -i below). Hand-picking one alternation's casing, as an
# earlier version did with [Tt]emp, missed TEMP, TMP and SCRATCHPAD entirely - the same
# case-sensitivity class that bit the sibling check-claims.sh in this same change.
VOLATILE_RE='[/\\](temp|tmp)[/\\]|scratchpad'

fail=0
warn=0
checked=0

while IFS= read -r line; do
  case "$line" in
    worktree\ *) wt_path="${line#worktree }" ;;
    branch\ *)   wt_branch="${line#branch refs/heads/}" ;;
    "")
      [ -n "${wt_path:-}" ] || continue
      checked=$((checked + 1))

      if [ ! -d "$wt_path" ]; then
        echo "  STALE   $wt_path (registered but missing on disk - run: git worktree prune)"
        wt_path=""; wt_branch=""
        continue
      fi

      dirty="$(git -C "$wt_path" status --porcelain 2>/dev/null | grep -v '\.terraform' | head -20)"
      if [ -n "$dirty" ]; then
        n="$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')"
        if printf '%s' "$wt_path" | grep -qiE "$VOLATILE_RE"; then
          echo "  FAIL    $wt_path"
          echo "          branch: ${wt_branch:-<detached>}"
          echo "          $n uncommitted file(s) in a VOLATILE path - this is how work gets lost."
          printf '%s\n' "$dirty" | sed 's/^/            /'
          echo "          Fix: commit it to its branch, or copy it out of the volatile path, then"
          echo "          remove the worktree. Do not leave it here."
          fail=1
        else
          echo "  WARN    $wt_path (${wt_branch:-<detached>}): $n uncommitted file(s)"
          warn=1
        fi
      fi
      wt_path=""; wt_branch=""
      ;;
  esac
done < <(git worktree list --porcelain; echo "")

echo "check-worktrees: $checked worktree(s) checked"
if [ "$fail" -ne 0 ]; then
  echo "check-worktrees: FAIL - uncommitted work in a volatile path."
  exit 1
fi
if [ "$warn" -ne 0 ] && [ "$strict" -eq 1 ]; then
  echo "check-worktrees: FAIL (--strict) - uncommitted work outstanding."
  exit 1
fi
echo "check-worktrees: PASS"
exit 0
