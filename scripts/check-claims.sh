#!/usr/bin/env bash
# scripts/check-claims.sh - fail when prose asserts a feature-flag value that the live
# tfvars contradicts.
#
# Why this exists: comments and runtime echo strings are invisible to fmt, validate and
# actionlint, and code review is diff-scoped, so a false statement outside the diff
# survives a review that corrects its siblings. That is exactly how six separate claims that
# enable_data_platform was OFF accumulated while envs/poc.tfvars said it was on: five were
# corrected in one review, and the sixth was missed because it sat in a runtime echo rather
# than a comment. A seventh turned up in the same file's header afterwards.
#
# What it checks: every enable_* claim written in a COMMENT or an echo/printf/::error::
# STRING is compared against the real value in envs/poc.tfvars. Real HCL assignments and
# shell variable assignments are deliberately NOT checked - those are code, and a module
# input that happens to share a variable's name is not a claim about that variable.
#
# What it does NOT check: any other kind of factual claim. Statements about git state,
# job wiring, or provider behaviour are still only as good as the command that was run to
# support them. Assert no more than you actually verified.
#
# Escape hatch: put "claims-ok" anywhere on the line, with a short reason. Three valid uses:
#   - deliberately historical text (a superseded note describing what a flag used to be)
#   - a hypothetical ("if this were false, X would happen")
#   - a genuine mid-sentence "etc." that this parser reads as a full stop, which drops the
#     conditional governing the claim and reports it as unconditional. That is a known and
#     accepted misparse: see last_clause() for why the alternative was worse.
#
# Usage: scripts/check-claims.sh [file ...]   (default: tracked code and workflow files)
# Exit 0 = PASS, 1 = at least one contradicted claim, 2 = setup error.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 2
cd "$repo_root" || exit 2

tfvars="envs/poc.tfvars"
[ -f "$tfvars" ] || { echo "check-claims: $tfvars not found" >&2; exit 2; }

# Historical records are append-only and legitimately describe past state: a struck-through
# 2026-07-23 note saying a flag was false is correct history, not a defect.
EXCLUDE_RE='^(WORKLOG|DECISIONS|OPEN-QUESTIONS)\.md$|^docs/|^landing-zone-kit/LESSONS\.md$'

# Held in an array, not a word-split command substitution: this repo's own path contains a
# space ("Claude Projects"), so a filename with one is a matter of time.
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(git ls-files '*.sh' '*.yml' '*.yaml' '*.tf' '*.md' | grep -vE "$EXCLUDE_RE")
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "check-claims: no files to scan"; exit 0
fi

awk -v tfvars="$tfvars" '
# Return the trailing clause of s: everything after the last sentence break.
#
# Only "e.g." and "i.e." are neutralised, and the asymmetry is deliberate. Those two are
# effectively never the last word of a sentence: something always follows the example or
# the restatement, so their period is always mid-sentence and treating it as a full stop
# strands the conditional governing the rest ("If tested for e.g. cost overruns, enable_x
# is true" was reported as a bare assertion).
#
# "etc.", "vs." and "cf." are deliberately NOT neutralised, because "etc." routinely ends a
# sentence and English does not double the period. Stripping it removed the only sentence
# break in the span, which kept an earlier "if" in scope and SILENTLY SUPPRESSED a real
# claim after it. Given the choice, this script takes the visible error: leaving the period
# in can over-report a genuine mid-sentence "etc." (noise, and claims-ok exists for it),
# while removing it can hide exactly the defect the script exists to find. A gate that is
# occasionally noisy gets fixed; a gate that lies gets trusted.
function last_clause(s,   t) {
  t = s
  gsub(/[Ee]\.[Gg]\./, "eg", t)
  gsub(/[Ii]\.[Ee]\./, "ie", t)
  while (match(t, /[.;:!?][ \t]/)) t = substr(t, RSTART + RLENGTH)
  return t
}

BEGIN {
  nflags = 0
  while ((getline line < tfvars) > 0) {
    if (line ~ /^[ \t]*#/) continue
    if (match(line, /^[ \t]*enable_[A-Za-z0-9_]+[ \t]*=[ \t]*(true|false)/)) {
      s = substr(line, RSTART, RLENGTH)
      sub(/^[ \t]*/, "", s)
      split(s, kv, /[ \t]*=[ \t]*/)
      actual[kv[1]] = kv[2]
      nflags++
    }
  }
  close(tfvars)
  if (nflags == 0) { print "check-claims: no enable_* flags parsed from " tfvars > "/dev/stderr"; exit 2 }
  fail = 0; checked = 0; nfiles = 0
}

FNR == 1 { nfiles++; carry = ""; in_fence = 0; is_md = (FILENAME ~ /\.md$/) }

# Markdown is prose end to end, so the comment/echo test that gates code files would skip
# all of it. The default glob has always included *.md, which advertised a coverage this
# script did not actually provide: COST.md carries a table of enable_* values and
# DEPLOYMENT.md asserts two more in body text, and every one of them scored zero claims
# checked. Fenced blocks are skipped because a sample in a doc is an illustration, not an
# assertion about this estate.
is_md && /^[ \t]*```/ { in_fence = !in_fence; carry = ""; next }
is_md && in_fence     { next }
is_md && /^[ \t]*$/   { carry = ""; next }   # blank line ends the paragraph, so ends carry
# Markdown has its own dividers: a horizontal rule, and a table separator row. Neither can
# hold a claim, and both end the block above them.
is_md && /^[ \t]*([-*_=][ \t]*){3,}$/     { carry = ""; next }
is_md && /^[ \t]*\|[-: |]+\|[ \t]*$/      { carry = ""; next }

# claims-ok opts a line out entirely.
/claims-ok/ { next }

{
  prose = ""
  # In markdown every surviving line is prose, and each counts as a continuation line so a
  # conditional can carry across a wrapped sentence exactly as it does in a comment block.
  if (is_md) {
    prose = $0; is_comment = 1
    # A heading opens a new section, so nothing above it governs anything below it. The
    # heading line is still scanned, it just does not inherit.
    if ($0 ~ /^[ \t]*#{1,6}[ \t]/) carry = ""
  }
  else is_comment = ($0 ~ /^[ \t]*(#|\/\/)/)

  # A divider ends the paragraph, so it ends the carry. Without this, a subordinate clause
  # left un-punctuated before a divider stayed in scope across it and suppressed a claim in
  # what any reader sees as a new paragraph.
  #
  # Three shapes count as a divider, and the breadth is the point. The first version of this
  # matched ONLY a bare "#", which missed the dashed banner this repo actually uses in 72
  # tracked files, so the defect it was written to close stayed wide open. That was fixing
  # the instance instead of the class - the same failure the code-reviewer rules in this
  # change now name explicitly.
  #   1. a marker with nothing after it            ->  #
  #   2. a marker followed by no alphanumerics     ->  # ----------  /  # ==========
  #   3. a marker followed by a punctuation run    ->  # --- section name ---------
  if ($0 ~ /^[ \t]*(#|\/\/)[ \t]*$/ ||
      $0 ~ /^[ \t]*(#|\/\/)[^A-Za-z0-9]*$/ ||
      $0 ~ /^[ \t]*(#|\/\/)[ \t]*[-=*_~]{3,}/) { carry = ""; next }
  # whole-line comment
  if (is_comment) prose = $0
  # runtime message: the whole line is close enough, the claim is inside the string
  else if ($0 ~ /(echo|printf|::error::|::warning::|::notice::)/) prose = $0
  # trailing comment: take everything after the marker
  else if (match($0, /[ \t](#|\/\/)[ \t]/)) prose = substr($0, RSTART)
  if (prose == "") { carry = ""; next }

  rest = prose
  # Seed the clause context with the tail of the previous comment line. A wrapped comment
  # puts the conditional and the claim it governs on different lines, so a per-line scan
  # reports "If ... , enable_x is false" as an assertion. prefix is context only: it is
  # never scanned for claims, so nothing is counted twice.
  # The separator is load-bearing, not cosmetic. Concatenating carry directly onto the next
  # line joins "...confirmed pricing." to "# enable_x is false" as "pricing.#", where the
  # sentence-break pattern [.;:!?][ \t] cannot match - so an unrelated "When" from the
  # previous sentence stayed in scope and suppressed a real claim. Joining with a space
  # makes a line break exactly as strong a boundary as an in-line sentence break when the
  # previous line ended one, and no stronger when it did not (a wrapped sentence still
  # carries its conditional).
  prefix = (carry == "" ? "" : carry " ")
  while (match(rest, /enable_[A-Za-z0-9_]+[ \t]*(=|is[ \t]+(not[ \t]+)?(set[ \t]+)?)[ \t]*(true|false)/)) {
    claim  = substr(rest, RSTART, RLENGTH)
    before = prefix substr(rest, 1, RSTART - 1)
    prefix = before claim
    rest   = substr(rest, RSTART + RLENGTH)

    # A conditional is not an assertion. A comment saying the hub route tables are absent
    # WHILE the firewall flag is off states a rule that holds whatever the flag is set to,
    # so only report claims NOT governed by a conditional in the SAME CLAUSE.
    #
    # Three things this deliberately does not do, all learned from reviews that broke
    # earlier versions:
    #   - It does not treat "were", "would" or "should" as conditionals. Those are ordinary
    #     past tense and the prose in this repo is full of them (were merged, were struck
    #     through), so any claim near one was silently suppressed. A gate that reports PASS
    #     while missing the defect it exists to catch is worse than no gate. "assuming" is
    #     genuinely a subordinator and is also excluded, on the deliberate trade that a
    #     false positive (noise, visible) beats a false negative (silence, trusted); it is
    #     also commonly an ordinary participle, as in "assuming the role".
    #   - It does not use a fixed-width lookback. A conditional governs its whole clause,
    #     however long, so scan back to the last sentence break rather than an arbitrary 40
    #     characters. A period only breaks the clause when followed by whitespace, which
    #     keeps filenames like poc.tfvars intact.
    #   - It does not let an abbreviation end a clause. "for e.g. cost overruns" was read as
    #     a sentence break, which discarded the governing "If" and turned a correctly scoped
    #     conditional into a reported assertion.
    # tolower because a conditional opening a sentence is capitalised ("If the flag ...")
    # and awk regex is case sensitive - one version silently missed every one of them.
    clause = last_clause(tolower(before))
    if (clause ~ /(^|[^a-z])(if|when|while|unless|whenever)([^a-z]|$)/) continue

    match(claim, /enable_[A-Za-z0-9_]+/); flag = substr(claim, RSTART, RLENGTH)
    want = (claim ~ /true[ \t]*$/) ? "true" : "false"
    if (claim ~ /is[ \t]+not[ \t]/) want = (want == "true") ? "false" : "true"

    if (!(flag in actual)) continue
    checked++
    if (want != actual[flag]) {
      line = $0; sub(/^[ \t]*/, "", line)
      printf "  FAIL %s:%d\n", FILENAME, FNR
      printf "       claims:      %s = %s\n", flag, want
      printf "       %s says: %s = %s\n", tfvars, flag, actual[flag]
      printf "       line: %.120s\n", line
      fail = 1
    }
  }

  # Hand the trailing clause to the next line, but only along a contiguous run of comment
  # lines, and only as far as the last sentence break. Bounded so a long comment block
  # cannot drag a conditional across an entire file and suppress a real claim.
  if (is_comment) {
    c = last_clause(carry " " prose)
    if (length(c) > 200) c = substr(c, length(c) - 199)
    carry = c
  } else {
    carry = ""
  }
}

END {
  printf "check-claims: %d flags in %s, %d claim(s) checked across %d file(s)\n", nflags, tfvars, checked, nfiles
  if (fail) {
    print "check-claims: FAIL - the prose above contradicts " tfvars "."
    print "  Fix the prose, fix the flag, or mark the line claims-ok if it is deliberately historical."
  } else {
    print "check-claims: PASS"
  }
  exit fail
}
' "${files[@]}"
