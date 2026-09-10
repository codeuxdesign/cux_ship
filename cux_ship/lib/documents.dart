// SPDX-License-Identifier: Apache-2.0
//
// The documents `--json` prints, as classes — so a Dart caller decodes this
// command's output instead of writing a reader against a format it learned by
// reading the encoder.
//
//   import 'dart:convert';
//   import 'package:cux_ship/documents.dart';
//
//   final result = await Process.run('cux_ship', [
//     'appstore', 'builds', '--platform', 'ios', '--json',
//   ]);
//   if (result.exitCode != 0) {
//     throw StateError(result.stderr as String);   // stdout is empty; stderr says why
//   }
//   final builds = AppStoreBuildsDocument.fromJson(
//     jsonDecode(result.stdout as String) as Map<String, dynamic>,
//   );
//   if (builds.schema != 1) {
//     throw StateError('schema ${builds.schema} is not one this knows');
//   }
//   print(builds.newestBuildNumberAsInt);
//   for (final line in builds.display) {
//     stdout.writeln(line);
//   }
//
// **The commands stay commands.** Nothing here talks to a store: these are
// value types over what one printed. That is the point rather than a
// limitation — the printed command line is what makes a failed release step
// re-runnable by hand, and per-step `secrets exec --only …` is what keeps a
// credential out of a step with no use for it. A caller that spawns keeps
// both. An in-process read gives up both by construction, which is half of why
// `read.dart` was removed rather than kept beside this — see read-api.md.
//
// **This dartdoc is the published statement of the format.** pub.dev renders
// it per version, and the field names are the JSON keys — a test fails if they
// ever differ. docs/design/json-output.md argues the parts a class cannot
// carry: why JSON rather than YAML, why the envelope is the build manifest's,
// and why a rendering travels inside a data document on purpose.
//
// **Three rules before you parse one.** Check the exit code first, because a
// failure leaves stdout empty and reports on stderr. Read [DocumentKind]
// before `schema`, because the counters are per kind. And print `display`
// rather than rendering the fields yourself — its text is not promised, its
// shape is, and a caller that renders the same values its own way reports
// something different from what the command reports, silently.
library;

export 'src/appstore/app_store.dart' show AscPlatform;
export 'src/documents.dart'
    show
        AppStoreBuildEntry,
        AppStoreBuildsDocument,
        AppStoreListingDiffDocument,
        AppStorePreviewEntry,
        AppStorePreviewsDocument,
        AppStoreState,
        AppStoreVersionEntry,
        AppStoreVersionsDocument,
        DocumentKind,
        ListingChangeSet,
        PlayReleaseEntry,
        PlayReleaseStatus,
        PlayTrackEntry,
        PlayTracksDocument,
        ProcessingState,
        ReleaseType,
        VerifyCheck,
        VerifyDocument,
        isEditableVersionState;
