#!/usr/bin/env bash
# scripts/check-worktrees.sh - fail when uncommitted work is sitting somewhere it can
# vanish, or when the shared repo tree is set up to collide with an agent worktree.
#
# Why this exists: this repo has lost agent output twice. ADR-066 was written, never
# committed, and lost outright - commit 9974efa exists only to "re-record" it, and a whole
# session STOPPED because the ADR it was told to implement did not exist anywhere in the
# repository. Then on 2026-07-30 a 225-line pre-clearance REFRESH ADDENDUM carrying a GO
# verdict was found uncommitted in a worktree under the Windows Temp tree, on a branch that
# was already merged, i.e. one cleanup pass away from gone. Then on 2026-07-31 an agent ran
# `git checkout -b` in the shared repo tree (the main worktree) between an operator `git
# commit` and `git push`, which silently moved the commit onto the agent's new branch and
# broke the PR create - recovered only by hand. Agent instructions now require a dedicated
# worktree under `.claude/worktrees/` for every turn, never the shared repo tree, so the
# main worktree should always sit on an integration branch (main/banking) and never be the
# place agent work happens.
#
# The mechanism in the first two cases was the same: role agents are told never to commit,
# so their output lives only in a working tree, and if that tree is volatile or its branch
# gets cleaned up, the work is unrecoverable. The third case shows the inverse hazard: the
# shared tree is durable, but precisely because it is shared, whoever switches its branch
# can silently redirect someone else's in-flight commit.
#
# The check:
#   FAIL  - a worktree in a volatile path (Temp/tmp/scratchpad) has uncommitted tracked
#           changes. This is the loss scenario, and it is loud on purpose.
#   WARN  - a worktree in a durable path has uncommitted tracked changes. Normal mid-change,
#           but worth seeing before branch cleanup.
#   WARN  - the main worktree (the shared repo tree at the repo root) is checked out on
#           anything other than an integration branch (main/banking), including a detached
#           HEAD. Started as a hard FAIL and was demoted by code review 2026-08-01: `ops/*`
#           rebuild-dispatch branches checked out directly in the main tree are this
#           project's routine, SANCTIONED pattern (`origin/banking` history shows
#           `ops/rebuild-steps-1-3-centralus`, `ops/rebuild-steps-4-8-centralus` and
#           `ops/rebuild-step9-diag-orphan-class` all merged from exactly that shape), so a
#           hard FAIL here was red on every ordinary rebuild session - the "gate nobody can
#           keep green" class, which trains people to ignore it and destroys the signal from
#           the volatile-path check next to it. Narrowing the condition to exempt `ops/*` by
#           name was considered and rejected: the 2026-07-31 collision that motivated this
#           check could equally have landed on an `ops/*`-named branch, so exempting the
#           prefix reopens the exact hazard. WARN keeps the signal visible without being
#           chronically red; `--strict` still promotes it to a failure when that is wanted.
# `.terraform/` noise is ignored throughout.
#
# On checking "one worktree per branch" separately: git itself refuses to check out a
# branch that is already checked out in another worktree ("fatal: ... is already checked
# out"), so that failure mode cannot occur without --force, and a --force use is a deliberate
# operator override this script should not second-guess.
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

# The only branches the main worktree may legitimately sit on. Everything else in this repo
# is a topic branch (feat/*, fix/*, docs/*, ops/*, chore/*) per the branch strategy (feature
# -> banking -> main), and none of those belong checked out in the shared tree.
INTEGRATION_BRANCH_RE='^(main|banking)$'

# Identifying "the main worktree" by comparing paths to `git rev-parse --show-toplevel`
# does NOT work here: that command returns the toplevel of whatever worktree the script
# happens to run from, which is the CURRENT worktree, not necessarily the repo's original
# main one - confirmed live: running this from a linked worktree under `.claude/worktrees/`
# made `--show-toplevel` return that linked worktree's own path, so it matched itself and
# wrongly flagged an agent worktree as "the main tree". `git worktree list --porcelain`
# always lists the main worktree FIRST regardless of cwd, so position, not path comparison
# against `--show-toplevel`, is the reliable signal - tracked via `checked == 1` below.

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

      # Empty/detached (wt_branch unset) counts as a NON-match, not a skip: a detached-HEAD
      # main tree is exactly as "not main/banking" as a topic branch is, per the policy this
      # check states above.
      main_branch_ok=0
      if [ -n "${wt_branch:-}" ] && printf '%s' "$wt_branch" | grep -qE "$INTEGRATION_BRANCH_RE"; then
        main_branch_ok=1
      fi
      if [ "$checked" -eq 1 ] && [ "$main_branch_ok" -eq 0 ]; then
        echo "  WARN    $wt_path (MAIN TREE): checked out on '${wt_branch:-<detached HEAD>}', not main/banking."
        echo "          Fine for a routine ops/* rebuild-dispatch session (the sanctioned"
        echo "          pattern). Worth a second look if this is agent work instead - see"
        echo "          .claude/worktrees/<branch> for that case."
        warn=1
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
  echo "check-worktrees: FAIL (--strict) - warning(s) outstanding (uncommitted work in a durable"
  echo "path, and/or the main tree not on main/banking)."
  exit 1
fi
echo "check-worktrees: PASS"
exit 0
