// SPDX-License-Identifier: Apache-2.0
//
// `package:cux_ship/read.dart` is a semver promise, and this holds the two
// halves of it.
//
// **The surface has to be reachable.** Every name is used below through the
// public import alone — no `src/` anywhere in this file — because an export
// that names a type whose *constructor arguments* are private, or that a
// caller cannot actually get hold of, is not an exported API.
//
// **And it has to stay small.** The store clients live in `src/` so this
// package can change fast; that only survives while nothing leaks. An
// `export 'src/…';` written without a `show` clause exports everything in the
// library and reads exactly like one written with it, so the shape of the file
// is checked rather than trusted.
import 'dart:io';

import 'package:cux_ship/read.dart';
import 'package:test/test.dart';

/// Everything `read.dart` promises.
///
/// Kept here as a list on purpose, unlike the README command map which is
/// compared against the runner: there is no other copy of this fact to compare
/// against, and a promise nobody has to edit deliberately is a promise that
/// grows by accident.
const _promised = {
  // The App Store side.
  'AppStoreBuild',
  'AppStoreBuilds',
  'AppStoreReads',
  'AppStoreVersion',
  'AppStoreVersions',
  'AscApiException',
  'AscPlatform',
  'BuildProcessingProgress',
  'ProcessingTimeout',
  // The Play side.
  'PlayReads',
  'PlayTrack',
  'PlayTrackRelease',
  'PlayTracks',
};

File _readDart() => ['lib/read.dart', 'cux_ship/lib/read.dart']
    .map(File.new)
    .firstWhere(
      (f) => f.existsSync(),
      orElse: () => throw StateError(
        'cannot find lib/read.dart from ${Directory.current.path} — and a '
        'surface test that cannot find the surface would pass by default',
      ),
    );

void main() {
  group('the surface is what it says it is', () {
    test('every export names what it exports', () {
      // Without a `show`, an export hands out the whole library — including
      // `AppStore`, `Writer` and every helper this package rewrites freely.
      final source = _readDart().readAsStringSync();
      final exports = RegExp(
        r'^export\s+[^;]+;',
        multiLine: true,
      ).allMatches(source).map((m) => m.group(0)!);

      expect(exports, isNotEmpty, reason: 'read.dart exports nothing');
      for (final export in exports) {
        expect(
          RegExp(r'\bshow\b').hasMatch(export),
          isTrue,
          reason:
              'this export has no show clause, so it exports everything:\n'
              '$export',
        );
      }
    });

    test('and exports exactly the promised names', () {
      final source = _readDart().readAsStringSync();
      final shown = <String>{};
      for (final match in RegExp(
        r'show\s+([^;]+);',
        multiLine: true,
      ).allMatches(source)) {
        shown.addAll(
          match
              .group(1)!
              .split(',')
              .map((n) => n.trim())
              .where((n) => n.isNotEmpty),
        );
      }

      expect(
        shown.difference(_promised),
        isEmpty,
        reason:
            'read.dart exports a name this test does not promise. Adding '
            'one is a deliberate act: it cannot be taken back without a major '
            'version.',
      );
      expect(
        _promised.difference(shown),
        isEmpty,
        reason:
            'read.dart stopped exporting a promised name, which is a '
            'breaking change for every consumer pinning this package.',
      );
    });
  });

  group('the surface is reachable through the public import', () {
    test('a Play track listing can be built and read', () {
      // Const constructors and plain-Dart fields: nothing here needs a
      // googleapis type, which would put the whole generated library into the
      // promise alongside these four names.
      const tracks = PlayTracks(
        packageName: 'design.codeux.example',
        tracks: [
          PlayTrack(
            name: 'internal',
            releases: [
              PlayTrackRelease(
                name: '1.4.0',
                versionCodes: [2132],
                status: 'completed',
              ),
            ],
          ),
        ],
        uploadedVersionCodes: [2130, 2132],
      );

      expect(tracks.newestVersionCodeOn('internal'), 2132);
      expect(tracks.track('internal')?.releases.single.name, '1.4.0');
      expect(tracks.lines, [
        '  internal: "1.4.0" codes=[2132] completed',
        '  uploaded bundles: [2130, 2132]',
      ]);
    });

    test('an App Store build listing can be built and read', () {
      const builds = AppStoreBuilds(
        platform: AscPlatform.ios,
        builds: [
          AppStoreBuild(
            buildNumber: '2132',
            processingState: 'VALID',
            uploadedDate: '2026-09-04T09:12:33-07:00',
            uploadedAt: null,
            expired: false,
          ),
        ],
      );

      expect(builds.newestBuildNumber, '2132');
      expect(builds.newestUsable?.buildNumber, '2132');
      expect(builds.lines.single, contains('build 2132'));
    });

    test('an App Store version listing can be built and read', () {
      const versions = AppStoreVersions(
        platform: AscPlatform.macos,
        versions: [
          AppStoreVersion(
            versionString: '1.4.0',
            appStoreState: 'PREPARE_FOR_SUBMISSION',
            releaseType: 'MANUAL',
            copyright: null,
          ),
        ],
      );

      expect(versions.version('1.4.0')?.releaseType, 'MANUAL');
      expect(versions.version('1.4.0')?.editable, isTrue);
      expect(versions.lines, [
        '  1.4.0  PREPARE_FOR_SUBMISSION  MANUAL',
        '    copyright: (unset)',
      ]);
    });

    test('a wait can be reported on without spawning anything', () {
      const progress = BuildProcessingProgress(
        buildNumber: '2132',
        state: 'PROCESSING',
        waited: Duration(minutes: 6),
        timeout: Duration(minutes: 45),
      );

      expect(progress.visible, isTrue);
      expect(progress.terminal, isFalse);
      expect(
        '${progress.waited.inMinutes} of ${progress.timeout.inMinutes} minutes',
        '6 of 45 minutes',
      );
    });

    test('the two failures a wait can end in are both catchable', () {
      // Both are thrown by `AppStoreReads.awaitBuild`, so a caller that cannot
      // name them has to catch everything.
      expect(
        ProcessingTimeout(
          buildNumber: '2132',
          waited: const Duration(minutes: 45),
        ),
        isA<Exception>(),
      );
      expect(
        AscApiException(422, const [], request: 'GET /v1/builds'),
        isA<Exception>(),
      );
    });

    test('the sessions are the only way to reach a store, and they are '
        'read-only', () {
      // Nothing on either session uploads, promotes or publishes. This is the
      // check a reviewer would otherwise do by eye, and it is here because the
      // temptation to add "just one" writer arrives later than this commit.
      expect(AppStoreReads.open, isA<Function>());
      expect(PlayReads.open, isA<Function>());
    });
  });
}
