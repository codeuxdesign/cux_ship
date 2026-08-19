#!/usr/bin/env bash
#
# Runs the shell tool's own test suite against this port.
#
# test/acceptance/test.sh is git-buildnumber.sh v1.3's test.sh, vendored
# byte-for-byte — it is the acceptance contract, so it is never edited here.
# It resolves the tool as `git-buildnumber.sh` beside itself, so this harness
# compiles the Dart entrypoint once and plants a wrapper of that name next to
# a copy of the suite in a temp directory.
#
#   cux_buildnumber/tool/acceptance.sh

set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Compiling git_buildnumber ..." >&2
dart compile exe "$PKG/bin/git_buildnumber.dart" -o "$WORK/git-buildnumber-dart" >&2

cp "$PKG/test/acceptance/test.sh" "$WORK/test.sh"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$WORK/git-buildnumber-dart" \
  > "$WORK/git-buildnumber.sh"
chmod +x "$WORK/test.sh" "$WORK/git-buildnumber.sh"

bash "$WORK/test.sh"
