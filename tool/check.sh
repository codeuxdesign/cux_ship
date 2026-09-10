#!/usr/bin/env bash
# Runs everything CI runs, so a green local check means a green push.
#
#   tool/check.sh                       every workspace member
#   tool/check.sh cux_ship              one of them
#   tool/check.sh --docs cux_ship       ...and the doc-reference check
#   tool/check.sh --docs-only cux_ship  only that check — the CI step, verbatim
#
# **Why this exists.** CI runs five steps per member; CLAUDE.md documented
# three:
#
#     dart pub get && dart analyze --fatal-infos && dart test
#
# `dart format --set-exit-if-changed` and `dart pub publish --dry-run` were not
# in it, so the loop the project told a contributor to run could not go red on
# the two steps that bracket it. That is not a hypothetical gap: it cost a red
# board on a change whose author had run the documented three and had no reason
# to think anything was missing, and it went unnoticed by a second contributor
# only because they happen to run `dart format` out of habit. A gap that one
# person's habit covers is a gap that lands entirely on whoever lacks the habit.
#
# It is a script rather than a longer line in CLAUDE.md because docs/CONTRIBUTING.md's
# rule about the rules says prose is for what cannot be a check, and "run these
# five" plainly can. It also stops the list being maintained twice, which is how
# it came to be three of five in the first place.
#
# **The two steps that were missing are the two worth having.**
# `pub publish --dry-run` is the furthest from anything a contributor thinks to
# run, and this repository is strange on exactly that axis: it carries a
# `resolution: workspace` key whose whole documented history is publishing
# behaving differently from everything local. `format` is the one a habit hides.
#
# **`--docs` is the one step CI runs that a default run here does not, and it
# is behind a flag for time rather than for doubt.** `dart doc` spends about
# ninety-five seconds on `cux_ship` — it precaches 1.35 million elements,
# because googleapis is in the dependency tree — against roughly ninety seconds
# for the entire five-step suite over all three members. Doubling the loop to
# ask a question that only moves when a doc comment is edited is a bad trade
# for the loop; skipping the question entirely is a bad trade for the docs. So
# CI always asks it and a contributor asks it when they have touched dartdoc.
#
# **It is written here rather than in the workflow so that the asymmetry is
# *when* it runs and not *where* it is written.** ci.yaml calls
# `tool/check.sh --docs-only <member>`; that is the whole CI step, and it runs
# here unchanged. Restating the command in yaml would rebuild the two-places
# drift the rest of this file exists to remove — and it would be worse than the
# original, because a workflow step cannot be watched failing the way
# docs/CONTRIBUTING.md requires without pushing a branch to find out.
set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "check: $*" >&2; exit 1; }

# **Derived, not listed.** CI builds its matrix from the root pubspec's
# `workspace:` key for the stated reason that a member added there is covered
# from the moment it is added. A second list here would be the same drift this
# script exists to remove, one level up.
#
# Read with a `while` loop rather than `mapfile`, which is bash 4 and this is
# a repository whose contributors are on macOS, where `/bin/bash` is 3.2. The
# first version used it and died on the machine it was written on.
MEMBERS=()
while IFS= read -r member; do
  [ -n "$member" ] && MEMBERS+=("$member")
done < <(
  awk '/^workspace:/{f=1;next} f&&/^  - /{print $2; next} f&&NF&&!/^ /{exit}' pubspec.yaml
)
[ ${#MEMBERS[@]} -gt 0 ] ||
  die "no workspace members found in pubspec.yaml — a check that runs nothing
    passes, which is the failure this script exists to close"

DOCS=0
DOCS_ONLY=0
SELECTED=

for arg in "$@"; do
  case "$arg" in
    --docs) DOCS=1 ;;
    --docs-only)
      DOCS=1
      DOCS_ONLY=1
      ;;
    -*) die "unknown option $arg. Options: --docs, --docs-only" ;;
    *)
      # Rejected rather than ignored: `tool/check.sh cux_ship cux_buildnumber`
      # silently checking only the first is the shape of failure this whole
      # script is about.
      [ -z "$SELECTED" ] || die "name one member, not two: $SELECTED and $arg"
      SELECTED=$arg
      ;;
  esac
done

if [ -n "$SELECTED" ]; then
  printf '%s\n' "${MEMBERS[@]}" | grep -qx "$SELECTED" ||
    die "$SELECTED is not a workspace member. Members: ${MEMBERS[*]}"
  MEMBERS=("$SELECTED")
fi

# **Warned about, not enforced.** CI pins the SDK to what Flutter stable
# bundles, and the pin is there because an unpinned formatter changed what the
# check asserted without anyone touching the repository — 3.13 reformatted two
# files 3.12 called clean, so `format` passed for every contributor and failed
# on every push. A local SDK that differs from the pin reproduces exactly that,
# and silently. Read from the workflow rather than repeated here, so bumping the
# pin moves both.
PINNED=$(sed -n 's/^ *sdk: \([0-9][0-9.]*\)$/\1/p' .github/workflows/ci.yaml | sed -n '1p')
LOCAL=$(dart --version 2>&1 | sed -n 's/.*version: \([0-9][0-9.]*\).*/\1/p')
if [ -n "$PINNED" ] && [ -n "$LOCAL" ] && [ "$PINNED" != "$LOCAL" ]; then
  echo "check: warning — CI pins Dart $PINNED and this is $LOCAL." >&2
  echo "    Formatting differs between versions, so a clean run here can still" >&2
  echo "    fail there. This is a warning rather than a refusal because the" >&2
  echo "    other four steps are still worth running." >&2
fi

# From the workspace root, because that is where the single lockfile is —
# `pub get` inside a member refuses with "is part of a workspace" rather than
# resolving something subtly different.
echo "==> dart pub get"
dart pub get

for package in "${MEMBERS[@]}"; do
  echo
  echo "==> $package"
  # Two subshells rather than one, so `--docs-only` is a step this loop skips
  # rather than a branch wrapped around forty lines of it.
  [ "$DOCS_ONLY" = 1 ] || (
    cd "$package"
    # **A stale `.g.dart` analyzes clean, which is the whole problem.** The
    # generated code is committed so that neither a consumer nor
    # `dart pub publish` ever runs a generator — and the cost of committing it
    # is that editing an annotated class and forgetting to regenerate leaves a
    # file that is valid Dart, passes every other step here, and describes the
    # class as it used to be. So it is regenerated and the tree is asked
    # whether anything moved.
    #
    # The condition is `build_runner` in the member's own dev_dependencies
    # rather than a list of names, so a second member that starts generating is
    # covered from the moment it does.
    # **Compared against itself before and after, not against git.** The first
    # version of this asked `git diff --quiet -- lib`, which is wrong in the
    # ordinary case rather than the exotic one: any uncommitted source edit
    # fails it, so the check went red for every local run with work in
    # progress — which is every run this script exists for. What is being
    # asked is whether *regenerating changes anything*, and that question has
    # nothing to do with what is committed.
    if grep -q '^  build_runner:' pubspec.yaml; then
      echo "--> generated code is current"
      generated() {
        find lib -name '*.g.dart' -exec shasum {} \; | sort
      }
      before=$(generated)
      dart run build_runner build >/dev/null
      if [ "$before" != "$(generated)" ]; then
        echo "check: generated code in $package/lib is not what the sources" >&2
        echo "  produce — regenerating just changed it. It has been rewritten;" >&2
        echo "  review the diff and commit it." >&2
        exit 1
      fi
    fi
    echo "--> format"
    dart format --output=none --set-exit-if-changed .
    echo "--> analyze"
    dart analyze --fatal-infos
    # The condition is the directory existing rather than a list of names, so a
    # suite added to a member runs from the moment it is written. CI says the
    # same thing in `hashFiles`.
    if [ -d test ]; then
      echo "--> test"
      dart test --reporter expanded
    fi
    # Publishing is permanent — a retraction is a seven-day window, not an undo
    # — so the metadata that gates it is checked on every run rather than
    # discovered at release time. Needs no credentials.
    echo "--> would publish"
    dart pub publish --dry-run
  )

  # **The dartdoc is asked whether its own cross-references resolve.**
  # `documents.dart` says in its header, and docs/design/json-output.md says at
  # length, that this package's dartdoc *is* the published statement of the
  # `--json` format: pub.dev renders it per version and it is the only place a
  # consumer can read the format without reading an encoder. A `[reference]`
  # that resolves to nothing renders there as bare text with square brackets —
  # so the specification points at a name the reader cannot follow, and
  # `dart analyze` says nothing, because a doc comment is a comment.
  #
  # Second occurrence with the analyzer silent both times. The first was an
  # orphaned `///` block found by a consumer reading the published dev.2 (see
  # `documents_test.dart`, "no doc comment is orphaned from the thing it
  # documents"); that check catches a block attached to nothing and cannot see
  # a link that dangles. Four of these were live when this was written.
  [ "$DOCS" = 0 ] || (
    cd "$package"
    echo "--> doc references"
    docs=$(mktemp -d)
    trap 'rm -rf "$docs"' EXIT
    # **`dart doc` exits 0 having warned, so the exit code is not the answer
    # and the output is.** A non-zero exit is dartdoc itself failing, which is
    # a different thing and is reported as one. Warnings go to stdout; stderr
    # is folded in so a crash cannot be lost alongside them.
    if ! dart doc --output "$docs/api" >"$docs/log" 2>&1; then
      cat "$docs/log" >&2
      die "dart doc failed in $package"
    fi
    # **This warning, not any warning.** `documents.dart` and `exit_codes.dart`
    # both reexport names from `src/appstore/app_store.dart` — `AscPlatform`
    # from the first, the two exit-code constants from the second — and dartdoc
    # calls that an ambiguous reexport of `app_store` on every single run. A check that counted warnings would have
    # been red on the day it was written, and the only way to get it green
    # would be to silence it — which is how a guard stops being read.
    # To stderr with the explanation under it, so the two halves of one
    # failure do not land on different streams.
    if grep -F -A 1 'unresolved doc reference' "$docs/log" >&2; then
      echo "check: a doc reference above resolves to nothing, so it renders" >&2
      echo "  on pub.dev as plain text in square brackets. Qualify it" >&2
      echo "  ([Class.member]) if it is on another class, or fix the name." >&2
      die "unresolved doc references in $package"
    fi
  )
done

echo
# **The closing line says what actually ran, because `--docs-only` runs one
# thing.** It said "all checks passed" unconditionally, so that mode — and a
# contributor running the CI step verbatim, which CLAUDE.md invites — got
# `all checks passed for cux_ship` having skipped format, analyze, test,
# `publish --dry-run` and the generated-code check.
#
# **That is this script's own subject, one level up.** The header is about a
# documented loop that could not go red on the two steps bracketing it, and the
# `die` for an empty member list says in as many words that a check which runs
# nothing passes. A success message overstating its own coverage is the same
# defect in the same file, and it is worse in CI, where the line outlives the
# terminal that printed it and is read by somebody who did not choose the flag.
if [ "$DOCS_ONLY" = 1 ]; then
  echo "==> doc references resolve in ${MEMBERS[*]} — nothing else ran"
elif [ "$DOCS" = 1 ]; then
  echo "==> all checks passed, doc references included, for ${MEMBERS[*]}"
else
  echo "==> all checks passed for ${MEMBERS[*]}"
fi
