// SPDX-License-Identifier: Apache-2.0
//
// Whether the version about to ship has a changelog section at all.
//
// `checkChangelogFile` checks every section the file *has*, and is silent
// about the one it lacks — it walks the headings, so a version with no
// heading is never looked at. The uploaders refuse that version, but on Play
// they refuse it after the confirmation prompt and inside an open edit, which
// is late enough that two of a consumer's scripts grew a `grep '^## <version>'`
// of their own before calling anything here. That grep is the check `verify`
// should have been; this is it.
import 'dart:io';

import 'package:cux_ship_verify/release_notes.dart';
import 'package:cux_ship_verify/release_problem.dart';

/// Why [version] cannot ship with [changelog] as it stands, or null.
///
/// A missing section is the only finding. An *empty* section is a deliberate
/// answer — "nothing user-visible changed" — and `changelogNotes` falls back
/// through it to the newest earlier section that says something, so it is
/// left alone here exactly as the uploaders leave it alone.
///
/// A missing file is not reported either: `checkChangelogFile` already says
/// "no such file" for it, and a second problem for the same absence would read
/// as two things wrong.
ReleaseProblem? changelogSectionProblem({
  required String changelog,
  required String version,
}) {
  if (!File(changelog).existsSync()) {
    return null;
  }
  // The platform is a filter over the section's entries; whether the section
  // exists does not depend on it.
  final notes = changelogNotesOf(changelog, version, platform: 'ios');
  if (notes is! NoSection) {
    return null;
  }
  return ReleaseProblem(
    '$changelog § $version',
    'pubspec.yaml says $version and there is no section for it — add '
        '"## $version", empty if nothing user-visible changed. The uploaders '
        'refuse this version without one, on Play after the prompt and inside '
        'an open edit.',
  );
}
