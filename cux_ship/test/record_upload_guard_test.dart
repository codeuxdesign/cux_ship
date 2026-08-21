// SPDX-License-Identifier: Apache-2.0
//
// The guard that decides whether an upload records itself.
//
// It read `ArgResults.options`, which holds what was *provided or defaulted* —
// while the question it meant to ask is what the subcommand *declares*. So
// `record-uploads: true` recorded nothing unless `--commit` was typed by hand,
// which is every caller using `--manifest`: the flag whose entire purpose is
// supplying that commit.
//
// Nothing failed. The guard returns early and silently, so the configuration
// read as working for as long as nobody went looking for the tag. It was found
// by turning the feature on in a real repository, uploading, and finding no tag
// — not by any test, because no test asked what the two `options` mean.
//
// **These cases used to assert that around the guard rather than through it.**
// They pinned `package:args` semantics and a name equality, and every one of
// them passed with the original bug restored — so the fix shipped as untested
// as the defect had been. They call `uploadRecordFor` now, which is the
// decision itself, and the first case below goes red against the old guard.
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/runner.dart';
import 'package:cux_ship/src/build_manifest.dart';
import 'package:test/test.dart';

late Directory _dist;

/// The decision, for one real subcommand parser and one real argument list.
///
/// The parser comes from `buildRunner()` rather than being rebuilt here, so a
/// flag renamed in the CLI shows up as a failure instead of as a fixture that
/// quietly stops matching what ships.
UploadRecordRequest? _decide(
  String store,
  String sub,
  List<String> args, {
  BuildManifest? manifest,
}) {
  final command = buildRunner().commands[store]!.subcommands[sub]!;
  return uploadRecordFor(
    commandName: command.name,
    parser: command.argParser,
    args: command.argParser.parse(args),
    manifest: manifest,
  );
}

/// A manifest on disk, as an upload would be handed one.
BuildManifest _manifest() {
  final path = '${_dist.path}/manifest.json';
  File(path).writeAsStringSync(
    jsonEncode({
      'schema': 2,
      'platform': 'android',
      'versionName': '1.1.0',
      'buildNumber': 67,
      'gitSha': 'd9c394bd9c394bd9c394bd9c394bd9c394bd9c39',
      'dirty': false,
      'format': 'aab',
      'artifact': 'how-it-went-1.1.0-67.aab',
      'sha256': 'd' * 64,
    }),
  );
  return BuildManifest.read(path);
}

void main() {
  setUp(() => _dist = Directory.systemTemp.createTempSync('cux_ship_guard'));
  tearDown(() => _dist.deleteSync(recursive: true));

  test('an upload driven by --manifest records, taking the commit from it', () {
    // The case the feature exists for, and the one that was dead from 3.3.0
    // until this branch: --manifest supplies the commit, so nothing has to be
    // typed, so the old guard's "was --commit provided" was always false.
    final request = _decide('play', 'upload', [
      '--manifest',
      '/dist/android/manifest.json',
      '--track',
      'internal',
    ], manifest: _manifest());

    expect(request, isNotNull, reason: 'this is the whole point of the fix');
    expect(request!.commit, 'd9c394bd9c394bd9c394bd9c394bd9c394bd9c39');
    expect(request.version, '1.1.0');
    expect(request.build, '67');
    expect(request.checksum, 'd' * 64);
    expect(request.dryRun, isFalse);
  });

  test('a listing-only push records nothing, having uploaded nothing', () {
    // `play upload --metadata` publishes a store listing and hands over no
    // build. Recording it would tag a commit as an upload of a version that
    // was never sent, and — because the tag is keyed by version and build —
    // would refuse the *next* real upload of that version as a collision.
    expect(
      _decide('play', 'upload', [
        '--package',
        'design.codeux.howitwent',
        '--metadata',
        'store/play',
      ]),
      isNull,
    );
  });

  test('an explicit artifact records even with no manifest', () {
    final request = _decide('play', 'upload', [
      '--aab',
      'dist/app.aab',
      '--track',
      'internal',
      '--commit',
      'a' * 40,
      '--version-name',
      '1.2.0',
      '--build-number',
      '70',
    ]);

    expect(request, isNotNull);
    expect(request!.commit, 'a' * 40);
    expect(request.version, '1.2.0');
    expect(request.build, '70');
  });

  test('the App Store side reaches the same decision', () {
    // Two parsers, two flag spellings for the artifact — `--aab` against
    // `--artifact` — and one guard reading both. A fix applied to one store
    // and not the other is the shape this pins.
    expect(
      _decide('appstore', 'upload', [
        '--manifest',
        '/dist/ios/manifest.json',
      ], manifest: _manifest()),
      isNotNull,
    );
  });

  test('a dry run is decided as a dry run', () {
    // It deletes its store edit rather than committing, so nothing is
    // published and there is nothing to record.
    expect(
      _decide('play', 'upload', [
        '--manifest',
        '/dist/android/manifest.json',
        '--track',
        'internal',
        '--dry-run',
      ], manifest: _manifest())!.dryRun,
      isTrue,
    );
  });

  test('promote records nothing, whatever it is given', () {
    // A promote moves a build the store already holds; it is not the moment
    // anything was published from this repository.
    // No arguments: the two stores' promote parsers do not take the same ones,
    // and the name is what decides this — so passing any would be testing the
    // parsers rather than the guard.
    for (final store in ['play', 'appstore']) {
      expect(_decide(store, 'promote', []), isNull, reason: '$store promote');
    }
  });

  test('both upload subcommands declare --commit', () {
    // The guard skips a parser that never declared it, which is correct and is
    // why it cannot simply be deleted. These are the two that must not be
    // skipped.
    final runner = buildRunner();
    for (final store in ['play', 'appstore']) {
      expect(
        runner.commands[store]!.subcommands['upload']!.argParser.options
            .containsKey('commit'),
        isTrue,
        reason: '$store upload must be able to record',
      );
    }
  });
}
