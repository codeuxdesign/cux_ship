// SPDX-License-Identifier: Apache-2.0
//
// Checks a consuming repository's release inputs, so that what a store would
// reject is caught when the file is committed rather than after the artifact
// has been uploaded.
//
// Everything here runs offline and needs no credentials. That is the property
// worth protecting: these are meant to be called from a consumer's ordinary
// test suite, on every push, by somebody who is not releasing anything.
//
// Why the logic is here and the data is not. These checks began as test cases
// inside cux_ship_notes and cux_ship_appstore, reading '../../CHANGELOG.md' and
// '../../store/appstore' — the app that happened to contain them. Both carried
// a comment explaining that they deliberately read the real files, because "the
// guard is worth nothing if it only ever sees fixtures". Extracting the
// packages into their own repository broke those paths and left three bad
// options: delete the guards, let them skip silently, or vendor a frozen copy
// of the app's changelog. Moving the logic into a library the consumer calls
// keeps the guarantee exactly as it was — the real files, checked by the same
// code that will publish them.
import 'dart:io';

import 'metadata.dart';
import 'release_notes.dart';
import 'release_problem.dart';

// Exported as whole libraries rather than by `show`. An enumerated list gets
// out of step the first time something is added — the first draft exported
// `loadPlayMetadata` without its return type, and `playRequiredImages` without
// the edge bounds beside it, so a caller could name a function and not the
// thing it hands back.
export 'data_safety.dart';
export 'play_metadata.dart';
export 'release_problem.dart';

/// The platforms a release note is filtered for, and the cap each one carries.
///
/// Both App Store platforms are listed even though their limit is identical:
/// the filtering differs, so a `[macos]`-prefixed entry and an `[ios]`-prefixed
/// one produce different text from the same section, and only checking both
/// checks both.
const defaultReleaseNotesLimits = <String, int>{
  'android': playReleaseNotesLimit,
  'ios': appStoreReleaseNotesLimit,
  'macos': appStoreReleaseNotesLimit,
};

/// Matches a version heading: `## 1.2.0`, or `## [1.2.0] - 2026-08-05`.
///
/// Anchored on a digit so that prose headings — `## Unreleased`, `## Rules` —
/// are not mistaken for versions. The parser in cux_ship_notes agrees with this
/// by construction; a heading this misses is simply not checked, which is why
/// [checkChangelog] also reports a changelog with no versions at all.
final _versionHeading = RegExp(r'^##\s+\[?(\d[^\]\s]*)\]?', multiLine: true);

/// Every version heading in [markdown], newest first, as written.
List<String> changelogVersions(String markdown) =>
    _versionHeading.allMatches(markdown).map((m) => m.group(1)!).toList();

/// Checks every version section of [markdown] against each platform's limit.
///
/// Two failures are reported, and they are different in kind:
///
/// * a version with no section at all, which means somebody forgot — the
///   uploaders refuse this rather than inventing a note; and
/// * a section that survives filtering for a platform but is longer than that
///   store accepts, which the store itself would only say after the upload.
///
/// A changelog with no version headings is itself a problem: it is far more
/// likely that the format drifted than that a project has no releases, and
/// silently checking nothing is the failure this whole function exists to
/// prevent.
List<ReleaseProblem> checkChangelog(
  String markdown, {
  Map<String, int> limits = defaultReleaseNotesLimits,
}) {
  final problems = <ReleaseProblem>[];
  final versions = changelogVersions(markdown);

  if (versions.isEmpty) {
    problems.add(
      const ReleaseProblem(
        'CHANGELOG.md',
        'no version headings found — expected at least one "## 1.2.3", '
            'optionally bracketed and dated',
      ),
    );
    return problems;
  }

  for (final version in versions) {
    for (final limit in limits.entries) {
      final where = 'CHANGELOG.md § $version → ${limit.key}';
      final notes = changelogNotes(markdown, version, platform: limit.key);
      if (notes is! NotesText) {
        problems.add(
          ReleaseProblem(
            where,
            'no section for this version, which the uploaders also refuse',
          ),
        );
        continue;
      }
      if (notes.text.length > limit.value) {
        problems.add(
          ReleaseProblem(
            where,
            'filtered to ${notes.text.length} characters, over the '
            '${limit.value} this store accepts — shorten it in '
            'CHANGELOG.md',
          ),
        );
      }
    }
  }

  return problems;
}

/// [checkChangelog] over the file at [path].
List<ReleaseProblem> checkChangelogFile(
  String path, {
  Map<String, int> limits = defaultReleaseNotesLimits,
}) {
  final file = File(path);
  if (!file.existsSync()) {
    return [ReleaseProblem(path, 'no such file')];
  }
  return checkChangelog(file.readAsStringSync(), limits: limits);
}

/// Loads the App Store metadata tree at [path] and reports what it refuses.
///
/// The loading *is* the check: [loadMetadata] validates text limits, URL
/// schemes, category ids, screenshot dimensions and — the one that fires most
/// often in practice — the alpha channel every simulator screen capture
/// carries. Anything it throws becomes a problem here rather than an exception,
/// so a caller sees it alongside whatever else is wrong.
///
/// [requireScreenshotTypes] covers the case the loader cannot know about on its
/// own: a universal app declaring `TARGETED_DEVICE_FAMILY = "1,2"` must carry an
/// iPad set as well as an iPhone one, and Apple refuses the submission if it
/// does not. Which types are required is a property of the app, so the consumer
/// names them.
List<ReleaseProblem> checkAppStoreTree(
  String path, {
  Set<String> requireScreenshotTypes = const {},
  Set<String> requireLocales = const {},
}) {
  final AppStoreMetadata metadata;
  try {
    metadata = loadMetadata(path);
  } on MetadataException catch (e) {
    return [ReleaseProblem(path, e.message)];
  }

  final problems = <ReleaseProblem>[];

  if (metadata.locales.isEmpty) {
    problems.add(ReleaseProblem(path, 'no locales — nothing would publish'));
    return problems;
  }

  for (final locale in requireLocales) {
    if (!metadata.locales.any((l) => l.locale == locale)) {
      problems.add(
        ReleaseProblem(path, 'no listing for required locale $locale'),
      );
    }
  }

  for (final locale in metadata.locales) {
    if (requireLocales.isNotEmpty && !requireLocales.contains(locale.locale)) {
      continue;
    }
    for (final type in requireScreenshotTypes) {
      final shots = locale.screenshots[type];
      if (shots == null || shots.isEmpty) {
        problems.add(
          ReleaseProblem(
            '$path → ${locale.locale}',
            'no $type screenshots, which this app is required to carry',
          ),
        );
      }
    }
  }

  return problems;
}
