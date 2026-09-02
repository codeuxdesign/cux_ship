// SPDX-License-Identifier: Apache-2.0
//
// What an upload *says* about its record, against what it did. `recordUpload`
// returns `created` under a dry run to mean "would be", and the runner printed
// that as "recorded this upload" — so a `--dry-run` rehearsal claimed a tag
// that existed nowhere, and a reader who then checked origin for it read the
// absence as a push that had failed. Found by a consumer thinning its upload
// script against 4.0.0: the line printed, and `git tag -l` was empty.
//
// Spawned, because the sentence is written in `_recordUploadIfAsked` and the
// record is written before any store is contacted — so the line and the tag
// are both observable with no credentials, on both branches.
import 'dart:io';

import 'package:test/test.dart';

import 'cli_snapshot.dart';

late Directory _repo;
late Directory _origin;

String _git(List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: _repo.path);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}

void _write(String relative, String contents) {
  final file = File('${_repo.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

ProcessResult _upload(List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  [
    '--enable-asserts',
    cliSnapshot,
    '--yes',
    'appstore',
    'upload',
    '--bundle-id',
    'design.codeux.consumer',
    '--artifact',
    'dist/app.ipa',
    '--commit',
    'HEAD',
    '--version-name',
    '1.0.0',
    '--build-number',
    '1',
    '--no-metadata',
    ...args,
  ],
  workingDirectory: _repo.path,
  // Not asked for here, and a machine that has them would go on to Apple.
  environment: {'APPLE_API_KEY_ID': '', 'APPLE_API_PRIVATE_KEY_PATH': ''},
);

void main() {
  setUp(() {
    _repo = Directory.systemTemp.createTempSync('cux_ship_record_dry');
    _origin = Directory.systemTemp.createTempSync('cux_ship_record_origin');
    Process.runSync('git', ['init', '-q', '--bare', _origin.path]);
    _git(['init', '-q', '-b', 'main']);
    _git(['config', 'user.email', 'test@example.com']);
    _git(['config', 'user.name', 'Test']);
    _git(['remote', 'add', 'origin', _origin.path]);
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.0+1\n');
    _write('.cux-ship.yaml', 'tag:\n  upload:\n    enabled: true\n');
    _write('dist/app.ipa', 'not really an ipa');
    _git(['add', '-A']);
    _git(['commit', '-q', '-m', 'first']);
  });

  tearDown(() {
    _repo.deleteSync(recursive: true);
    _origin.deleteSync(recursive: true);
  });

  test('a dry run says it would record, and writes no tag', () {
    final result = _upload(['--dry-run']);
    final stderr = '${result.stderr}';

    expect(stderr, contains('==> would record this upload'));
    expect(stderr, isNot(contains('==> recorded this upload')));
    expect(_git(['tag', '--list', 'uploaded/*']), isEmpty);
  });

  test('a real run says it recorded, and the tag is there', () {
    final result = _upload([]);
    final stderr = '${result.stderr}';

    expect(stderr, contains('==> recorded this upload'));
    expect(stderr, isNot(contains('would record')));
    expect(_git(['tag', '--list', 'uploaded/*']), 'uploaded/v1.0.0+1');
  });
}
