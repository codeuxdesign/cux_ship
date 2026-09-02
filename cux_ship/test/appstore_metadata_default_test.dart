// SPDX-License-Identifier: Apache-2.0
//
// Which tree an App Store publish reads when nothing names one, pinned end to
// end because the default is wired in `_AscSubcommand.run` and no unit test
// reaches that. `verify` resolved a split `store/appstore/{ios,macos}` layout
// correctly while upload and promote defaulted to the parent directory, which
// holds a README and two subtrees — so every Apple promote in the repository
// that has the layout passed `--metadata store/appstore/<platform>` by hand,
// and the tool's own default was the thing being worked around.
//
// The tree the command read is proven by making it refuse: a lower-case
// category id is rejected by the loader with the value quoted, before any
// credential is looked for, so the value names the tree. A refusal is the only
// offline evidence of which directory was opened, and it is deliberately not
// the "holds no info/" message — that is what the parent produces, and a test
// asserting on it could not tell the fix from the defect.
import 'dart:io';

import 'package:test/test.dart';

import 'cli_snapshot.dart';

late Directory _repo;

void _write(String relative, String contents) {
  final file = File('${_repo.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

ProcessResult _promote(List<String> args) =>
    Process.runSync(Platform.resolvedExecutable, [
      '--enable-asserts',
      cliSnapshot,
      '--yes',
      'appstore',
      'promote',
      '--bundle-id',
      'design.codeux.consumer',
      ...args,
    ], workingDirectory: _repo.path);

void main() {
  setUp(() {
    _repo = Directory.systemTemp.createTempSync('cux_ship_asc_default');
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.0+1\n');
    Process.runSync('git', ['init', '-q'], workingDirectory: _repo.path);
  });

  tearDown(() => _repo.deleteSync(recursive: true));

  group('a split layout', () {
    setUp(() {
      _write('store/appstore/README.md', 'The two trees below.\n');
      _write('store/appstore/ios/info/primary_category.txt', 'ios_lower');
      _write('store/appstore/macos/info/primary_category.txt', 'macos_lower');
    });

    test('defaults to the platform subtree', () {
      final result = _promote(['--platform', 'macos']);
      final stderr = '${result.stderr}';
      expect(result.exitCode, isNot(0), reason: '$result.stdout$stderr');
      expect(stderr, contains('"macos_lower"'));
      expect(
        stderr,
        isNot(contains('holds no info/')),
        reason: 'that is the parent directory being read',
      );
    });

    test('defaults to ios when no platform is given', () {
      final stderr = '${_promote([]).stderr}';
      expect(stderr, contains('"ios_lower"'));
    });

    test('an explicit --metadata still wins', () {
      final stderr =
          '${_promote(['--platform', 'macos', '--metadata', 'store/appstore/ios']).stderr}';
      expect(stderr, contains('"ios_lower"'));
      expect(stderr, isNot(contains('"macos_lower"')));
    });
  });

  test('a flat layout still reads store/appstore for either platform', () {
    _write('store/appstore/info/primary_category.txt', 'flat_lower');

    for (final platform in ['ios', 'macos']) {
      final stderr = '${_promote(['--platform', platform]).stderr}';
      expect(stderr, contains('"flat_lower"'), reason: platform);
    }
  });
}
