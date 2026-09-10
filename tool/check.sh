#!/usr/bin/env bash
# Runs everything CI runs, so a green local check means a green push.
#
#   tool/check.sh              every workspace member
#   tool/check.sh cux_ship     one of them
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

if [ $# -gt 0 ]; then
  printf '%s\n' "${MEMBERS[@]}" | grep -qx "$1" ||
    die "$1 is not a workspace member. Members: ${MEMBERS[*]}"
  MEMBERS=("$1")
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
  (
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
done

echo
echo "==> all checks passed for ${MEMBERS[*]}"
