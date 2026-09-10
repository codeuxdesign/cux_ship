#!/usr/bin/env bash
# What is still open, derived from the design docs rather than listed anywhere.
#
#   tool/status.sh             everything, grouped
#   tool/status.sh open        one state
#
# **Why this exists.** Every document in docs/design/ opens with a `Status:`
# line, and some carry one per section — so the record of what is unfinished
# already exists, next to the argument that produced it. What did not exist was
# a way to *ask*. "Where do we stand" was answered with a list of open pull
# requests, because that is what is enumerable from the outside, while nine
# open design questions sat in files nobody thought to grep.
#
# A script rather than a checked-in list for the reason tool/check.sh is one:
# a second copy of this drifts, and a stale index of open questions is worse
# than none, because it is believed. Nothing here is maintained. Add a document
# with a `Status:` line and it appears; change a status and the index changes.
#
# **This is not a task tracker, deliberately.** GitHub issues hold defects and
# anything reported from outside — `issue_tracker:` in all three pubspecs
# points there. These are decisions not yet made, and the reason they live in
# prose is that the argument is the useful part: a line saying "decide whether
# read.dart survives" is worth almost nothing without the four sections under
# it. The same reasoning is why this repository has no TODO comments at all,
# in any file — a tag records that somebody once had a thought, and a comment
# records what the thought was.
set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "status: $*" >&2; exit 1; }

# The vocabulary, in the order somebody scanning this cares about: undecided
# first, finished last.
#
# **This line is the only copy.** `cux_ship/test/design_status_test.dart`
# parses it out of this file rather than repeating the words, and then fails
# any document whose status is not among them — because a status this script
# does not recognize is not an error here, it is a document that silently
# disappears from the report. Editing this list therefore changes what the
# index reports *and* what the test enforces, together.
STATES=(open proposed decided built)

wanted="${1:-}"
if [[ -n "$wanted" ]]; then
  found=
  for state in "${STATES[@]}"; do
    if [[ "$state" == "$wanted" ]]; then
      found=1
    fi
  done
  [[ -n "$found" ]] || die "no such state: $wanted (${STATES[*]})"
fi

# **`-- .` on the git grep, so this reads the tracked tree.** An index built
# over whatever happens to be in the working directory would quietly include a
# scratch file somebody never intends to commit.
lines="$(git grep -n '^Status: \*\*' -- 'docs/design/*.md' || true)"
[[ -n "$lines" ]] || die \
  'no Status: lines in docs/design/ — an index that finds nothing would
       report "all clear" and be believed'

total=0
for state in "${STATES[@]}"; do
  if [[ -n "$wanted" && "$state" != "$wanted" ]]; then
    continue
  fi

  # The heading a status sits under, so a document with two of them says which
  # is which. store-preview-rules.md is `built` at the top and carries three
  # `open` sections, and a report naming only the file cannot tell those apart.
  # **A document's own status is the state of its subject, and a section may
  # carry its own.** Preview videos ship; how long an ingestion normally takes
  # is still unmeasured. So a heading is printed beside every hit rather than
  # the filename alone: without it a report saying `store-preview-rules.md`
  # four times, under two states, is unreadable, and a header that says `built`
  # reads as a claim that nothing inside it is open.
  #
  # This used to cite read-api.md, which was `decided` at the top and `open`
  # two hundred lines down until the library it argues about was removed and
  # every section in it settled. An example has to be one somebody can go and
  # look at.
  body="$(
    for file in docs/design/*.md; do
      awk -v file="$file" -v want="$state" '
        /^#/ { heading = $0; sub(/^#+[ ]*/, "", heading) }
        /^Status: \*\*/ {
          state = $0
          sub(/^Status: \*\*/, "", state)
          sub(/\*\*.*$/, "", state)
          if (state == want) {
            printf "  %s:%d  %s\n", file, FNR, heading
          }
        }
      ' "$file"
    done
  )"

  if [[ -n "$body" ]]; then
    count="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
    total=$((total + count))
    printf '%s (%s)\n%s\n\n' "$state" "$count" "$body"
  fi
done

printf '==> %d in docs/design/. The argument is in the file; this only says where.\n' "$total"
