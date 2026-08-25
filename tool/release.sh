#!/usr/bin/env bash
# Publishes one workspace member, and refuses to leave the release untraceable.
#
#   tool/release.sh cux_ship
#   tool/release.sh cux_ship_verify
#   tool/release.sh --dry-run cux_ship
#
# **Why this exists at all.** Three of the five releases before it had something
# wrong at the tagging step — 2.3.2 and 3.2.0 shipped untagged, and one was
# tagged seven commits behind what it published. None of them broke anything,
# which is exactly why it kept happening: the tag is the step after the
# irreversible one, so skipping it costs nothing at the time and everything
# later, when somebody needs to know what 3.2.0 actually was.
#
# Two silences are being closed, and they are different in kind:
#
#   - **A stale version line.** `dart pub publish` refuses a dirty tree, which
#     is a real guard, and says nothing about how long ago the version was
#     written. 3.2.0 was set seven commits before it shipped, so "the commit
#     that set the version" and "the commit that was published" were different
#     commits and only one of them was right.
#
#   - **A missing tag.** Nothing looks. `dart pub publish` succeeds, the shell
#     returns, and the release is public and unfindable in the same instant.
#
# The first is closed by convention — a dedicated release commit, see
# docs/RELEASING.md — and this checks it. The second is closed here, because
# there is nowhere else it can be: CI does not know a publish happened, and by
# the time it could, the untagged commit is already the released one.
set -euo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=false
PACKAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    -*) echo "usage: $0 [--dry-run] <package>" >&2; exit 64 ;;
    *) PACKAGE="$1" ;;
  esac
  shift
done
[ -n "$PACKAGE" ] || { echo "usage: $0 [--dry-run] <package>" >&2; exit 64; }
[ -d "$PACKAGE" ] || { echo "no such workspace member: $PACKAGE" >&2; exit 64; }

die() { echo "release: $*" >&2; exit 1; }

VERSION=$(sed -n 's/^version: *//p' "$PACKAGE/pubspec.yaml" | head -1)
[ -n "$VERSION" ] || die "could not read version from $PACKAGE/pubspec.yaml"

# The tag this release will carry. Prefixed for every member except cux_ship,
# whose bare series predates the split — and the collision is not theoretical:
# cux_ship published its own 1.8.0 and 1.9.0, so a bare v1.9.0 would name an
# existing cux_ship version at a commit belonging to cux_ship_verify.
if [ "$PACKAGE" = cux_ship ]; then
  TAG="v$VERSION"
else
  TAG="$PACKAGE-v$VERSION"
fi

# ------------------------------------------------------------ before publish

[ -z "$(git status --porcelain)" ] || die "working tree is dirty"

git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null &&
  die "$TAG already exists — bump the version, or this release has happened"

# **The version has to have been set by HEAD.** This is the check that would
# have caught 3.2.0: the version line was written seven commits earlier, on a
# feature commit, so publishing from the branch tip meant the released commit
# and the version-setting commit were different — and a tag at either one is
# defensible, which is how you end up with the wrong one.
#
# A dedicated release commit makes them the same commit by construction. See
# docs/RELEASING.md; this only enforces it.
SET_BY=$(git log --format=%H -S"version: $VERSION" -- "$PACKAGE/pubspec.yaml" | head -1)
HEAD_SHA=$(git rev-parse HEAD)
if [ "$SET_BY" != "$HEAD_SHA" ]; then
  BEHIND=$(git rev-list --count "$SET_BY..$HEAD_SHA" 2>/dev/null || echo '?')
  die "version $VERSION was set $BEHIND commit(s) ago, in $(git log --format=%h\ %s -1 "$SET_BY").
    Publishing here means the released commit is not the one that names the
    version, and a tag at either is arguable. Make a release commit that only
    sets the version — see docs/RELEASING.md."
fi

# **The baked version has to say what the pubspec says.** cux_ship carries its
# version as a hand-maintained constant — a manifest records which producer
# wrote it — and the test that keeps the two honest lives in a suite this
# script never runs, because `dart pub publish` runs no tests either. So the
# drift the test exists for shipped anyway: 3.5.0 was published with the
# constant still saying 3.4.2, and every manifest it writes names a producer
# version that never released. Checked here, where the publish is; skipped for
# a member that bakes no version.
BAKED_FILE="$PACKAGE/lib/src/version.dart"
if [ -f "$BAKED_FILE" ]; then
  BAKED=$(sed -n "s/^const [A-Za-z]*[Vv]ersion = '\([^']*\)';\$/\1/p" "$BAKED_FILE")
  [ -n "$BAKED" ] || die "$BAKED_FILE exists but no version constant was found in it —
    the check would pass by default, which is the failure it exists to close"
  [ "$BAKED" = "$VERSION" ] ||
    die "pubspec.yaml says $VERSION but $BAKED_FILE bakes $BAKED.
    Set the constant in the release commit; a manifest naming the wrong
    producer reads exactly like one naming the right one."
fi

echo "==> $PACKAGE $VERSION at $(git rev-parse --short HEAD), tag $TAG"

if $DRY_RUN; then
  (cd "$PACKAGE" && dart pub publish --dry-run)
  echo "==> dry run — nothing published, nothing tagged"
  exit 0
fi

# ------------------------------------------------------------------ publish

(cd "$PACKAGE" && dart pub publish --force)

# ---------------------------------------------------------------- and a tag
#
# Immediately, and not conditionally. Everything above this line is reversible;
# nothing below it is, so the tag is placed before anything else can go wrong,
# fail, or be interrupted.

git tag -a "$TAG" -m "$PACKAGE $VERSION"
git push origin "$TAG"

# The guard, said as an assertion rather than assumed. If the tag did not land,
# this is the last moment anyone is looking.
git describe --exact-match HEAD >/dev/null 2>&1 ||
  die "published $PACKAGE $VERSION and HEAD carries no tag — place $TAG by hand, now"

echo "==> published and tagged $TAG"
echo "    pub.dev may take up to 10 minutes to serve it; the web API reports it"
echo "    live before the resolver will accept it, so check with a real"
echo "    'dart pub get' rather than the API before publishing anything that"
echo "    depends on it."
