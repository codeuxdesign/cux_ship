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
// The image header and the encoding rules over it, which are neither store's:
// both trees here check them, and so does the Play uploader in cux_ship, which
// reaches this package through this file. Exported so that third caller cannot
// re-derive them — the last time an image check was written twice, one of the
// two copies never got the alpha rule.
export 'store_image.dart';
// And the video header beside it, for the same reason one level along: the
// App Store preview uploader in cux_ship reads previews out of this package
// and reports what Apple would refuse, and a rule reachable from only one of
// the two callers is how the alpha check came to exist in one tree and not the
// other.
export 'store_video.dart';

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
/// And a third, of a different kind again: an entry that reaches an Apple
/// store naming Android, which App Review rejects — see [checkPlatformNames].
///
/// A changelog with no version headings is itself a problem: it is far more
/// likely that the format drifted than that a project has no releases, and
/// silently checking nothing is the failure this whole function exists to
/// prevent.
///
/// [name] is what the problems call the file. A locale file is checked by the
/// same rules and has to be named as itself — `CHANGELOG.de-DE.md § 1.1.9 →
/// android` — because a German section over Play's cap, reported against
/// `CHANGELOG.md`, sends somebody to shorten the English one.
List<ReleaseProblem> checkChangelog(
  String markdown, {
  Map<String, int> limits = defaultReleaseNotesLimits,
  String name = 'CHANGELOG.md',
}) {
  final problems = <ReleaseProblem>[];
  final versions = changelogVersions(markdown);

  if (versions.isEmpty) {
    problems.add(
      ReleaseProblem(
        name,
        'no version headings found — expected at least one "## 1.2.3", '
        'optionally bracketed and dated',
      ),
    );
    return problems;
  }

  for (final version in versions) {
    for (final limit in limits.entries) {
      final where = '$name § $version → ${limit.key}';
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
            '$name',
          ),
        );
      }
    }
  }

  problems.addAll(checkPlatformNames(markdown, name: name));
  return problems;
}

/// [checkChangelog] over the file at [path].
List<ReleaseProblem> checkChangelogFile(
  String path, {
  Map<String, int> limits = defaultReleaseNotesLimits,
  String name = 'CHANGELOG.md',
}) {
  final file = File(path);
  if (!file.existsSync()) {
    return [ReleaseProblem(path, 'no such file')];
  }
  return checkChangelog(file.readAsStringSync(), limits: limits, name: name);
}

/// Checks the per-locale release notes beside [changelog] against the
/// [locales] a repository declares.
///
/// `CHANGELOG.md` is the notes for every locale without a file of its own,
/// and `CHANGELOG.<locale>.md` is that locale's — see `release_notes.dart`.
/// Four things are reported, each a way for a store to show the wrong text
/// with nothing having said so:
///
/// * **a locale file with no section for [version]** — the "forgot to
///   translate this release" case, refused by the uploaders exactly as the
///   English one is. Skipped when [version] is null, which is a project that
///   does not say what it is about to ship;
/// * **a locale file over a store's cap**, by [checkChangelog] and named as
///   itself. A German section is routinely longer than its English source,
///   so it meets Play's 500 first;
/// * **a locale file for a locale nothing declares**, which publishes nowhere
///   — most likely a misspelt filename, `CHANGELOG.de.md` beside `de-DE`;
/// * **a dangling symlink** where a locale file would be, which the
///   filesystem reports as absent and which would therefore publish the
///   default text in silence.
///
/// **A declared locale with no file is not a problem**, and that is the
/// design rather than a gap: it is how a listing gaining a language costs
/// nothing, and the stores themselves fall back the same way. `verify` names
/// every such locale on every run instead, so the choice stays visible.
List<ReleaseProblem> checkLocaleChangelogs(
  String changelog, {
  required Set<String> locales,
  String? version,
  Map<String, int> limits = defaultReleaseNotesLimits,
}) {
  final problems = <ReleaseProblem>[];
  final defaultName = _fileName(changelog);

  for (final locale in locales) {
    switch (localeNotesSource(changelog, locale)) {
      case DefaultFile():
        break;
      case DanglingLink(:final path):
        problems.add(
          ReleaseProblem(
            path,
            'is a symlink to nothing, so $locale would silently publish '
            "$defaultName's notes — point it at a file, or delete it to "
            'publish those notes deliberately',
          ),
        );
      case OwnFile(:final path):
        final name = _fileName(path);
        final markdown = File(path).readAsStringSync();
        problems.addAll(checkChangelog(markdown, limits: limits, name: name));
        if (version != null &&
            changelogNotes(markdown, version, platform: 'ios') is NoSection) {
          problems.add(
            ReleaseProblem(
              '$name § $version',
              'no section — $name is $locale\'s release notes, and the '
                  'uploaders refuse this version without one. Add '
                  '"## $version" (empty if nothing changed for $locale '
                  "readers), or delete the file to publish $defaultName's "
                  'notes to $locale',
            ),
          );
        }
    }
  }

  final beside = localeChangelogsBeside(changelog);
  for (final MapEntry(key: locale, value: path) in beside.entries) {
    if (!locales.contains(locale)) {
      problems.add(
        ReleaseProblem(
          path,
          'exists and no store declares $locale, so it publishes nowhere — '
          'rename it to a declared locale '
          '(${locales.isEmpty ? 'none are declared' : (locales.toList()..sort()).join(', ')}), '
          'or declare $locale in .cux-ship.yaml',
        ),
      );
    }
  }

  return problems;
}

String _fileName(String path) =>
    path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);

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
///
/// [requirePreviewFrames] is the same kind of requirement about a different
/// field: every preview must name its poster frame rather than inheriting
/// Apple's five-second default.
///
/// **Here rather than in the loader, and that is the whole design decision.**
/// The tree's standing rule is *present means owned* — a file that exists
/// replaces what App Store Connect holds, one that does not is left alone — so
/// a missing `.timecode` means "leave the poster Apple has", which is the right
/// answer for a project that set one in the console and does not want it
/// reasserted. Making the sidecar mandatory in `loadMetadata` would make that
/// state unreachable for *every* consumer, to serve a policy only some of them
/// have.
///
/// But the policy is a good one and the argument for it is strong: Apple's
/// default is invisible everywhere except a search result, and a preview
/// freezes with the version, so a poster that quietly shipped wrong cannot be
/// corrected without a new submission. A flag here is how this package already
/// says "the store permits it and this project does not" — it is what
/// [requireScreenshotTypes] is — and it puts the requirement in the consumer's
/// test suite, where it fails on the push that introduces it.
List<ReleaseProblem> checkAppStoreTree(
  String path, {
  Set<String> requireScreenshotTypes = const {},
  Set<String> requireLocales = const {},
  bool requirePreviewFrames = false,
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

    if (requirePreviewFrames) {
      for (final type in locale.previews.entries) {
        for (final preview in type.value) {
          if (preview.frameTimeCode != null) {
            continue;
          }
          final name = preview.file.uri.pathSegments.last;
          problems.add(
            ReleaseProblem(
              '$path → ${locale.locale}',
              'previews/${type.key}/$name names no poster frame, so Apple '
                  'would pose it at $defaultPreviewFrameTimeCode.\n'
                  '  Write the frame to '
                  'previews/${type.key}/$name$previewTimeCodeSuffix — a '
                  'preview freezes with the version, so a default that ships '
                  'by accident needs a new submission to correct.',
            ),
          );
        }
      }
    }
  }

  return problems;
}
