// SPDX-License-Identifier: Apache-2.0
//
// What the binary exits with, driven through the binary.
//
// **A shell wrapper cannot match on a Dart type.** `UploadCollisionException`
// has existed since 3.3.0 with a doc comment saying it "gives the CLI a distinct
// exit code" — and nothing mapped it, so the only thing a caller could observe
// was 1, indistinguishable from the failure a release script deliberately
// swallows. The type was the half that was easy to write and the half that
// nothing outside this package can see.
//
// So these cases spawn the real entrypoint. A test that called `main()` in
// process could not observe `exit()` at all.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cux_ship/src/provenance.dart' show uploadCollisionExit;
import 'package:test/test.dart';

import 'cli_snapshot.dart';

/// Runs the entrypoint — as a snapshot rather than from source, because
/// compiling it per invocation was most of this package's test time. See
/// cli_snapshot.dart.
ProcessResult _run(List<String> args, {String? cwd}) => Process.runSync(
  Platform.resolvedExecutable,
  ['--enable-asserts', cliSnapshot, ...args],
  workingDirectory: cwd,
);

/// A repository with a build recorded as uploaded, from a *different* commit.
///
/// The collision is raised before any store is contacted, so this reaches
/// exit 3 with no credentials and no network.
String _repoWithCollidingRecord() {
  final root = Directory.systemTemp.createTempSync('cux_ship_collide');
  String git(List<String> args) =>
      (Process.runSync('git', args, workingDirectory: root.path).stdout
              as String)
          .trim();

  Process.runSync('git', [
    'init',
    '-q',
    '-b',
    'main',
  ], workingDirectory: root.path);
  git(['config', 'user.email', 'test@example.invalid']);
  git(['config', 'user.name', 'Test']);
  File('${root.path}/pubspec.yaml').writeAsStringSync(
    'name: app\nversion: 1.1.0+67\nenvironment:\n  sdk: ^3.6.0\n',
  );
  File(
    '${root.path}/.cux-ship.yaml',
  ).writeAsStringSync('tag:\n  upload:\n    enabled: true\n');
  git(['add', '-A']);
  git(['commit', '-qm', 'first']);
  final first = git(['rev-parse', 'HEAD']);
  // The record exists, naming the *first* commit...
  git(['tag', '-a', 'uploaded/v1.1.0+67', '-m', 'recorded', first]);
  // ...and then the tree moves, so the artifact about to be uploaded under the
  // same version and build was built somewhere else.
  File('${root.path}/second.txt').writeAsStringSync('moved on');
  git(['add', '-A']);
  git(['commit', '-qm', 'second']);

  final dist = Directory('${root.path}/dist')..createSync();
  final artifact = File('${dist.path}/app.aab')..writeAsStringSync('pretend');
  // A real digest: `verify()` checks it before anything reaches the record, so
  // a placeholder would fail this for the wrong reason and the case would
  // "pass" against a bug it never got near. No `format`, so the cross-check
  // has no reader to run — the artifact is not a real bundle.
  final digest = sha256.convert(artifact.readAsBytesSync()).toString();
  File('${dist.path}/manifest.json').writeAsStringSync(
    '{"schema":2,"platform":"android","versionName":"1.1.0",'
    '"buildNumber":67,"gitSha":"${git(['rev-parse', 'HEAD'])}",'
    '"dirty":false,"artifact":"app.aab","sha256":"$digest"}',
  );
  return root.path;
}

void main() {
  test('a collision exits with the collision code, not 1', () {
    // **The half that was missing.** `uploadCollisionExit` existed, and the
    // catch that maps it existed — but nothing drove a real collision through
    // the binary, so deleting the `on UploadCollisionException` clause left
    // every test green while a release wrapper went back to seeing 1 and
    // swallowing it. The record is written before the store is contacted,
    // which is what makes this reachable with no credentials.
    final root = _repoWithCollidingRecord();
    try {
      final result = _run([
        'play',
        'upload',
        '--manifest',
        'dist/manifest.json',
        '--track',
        'internal',
      ], cwd: root);

      expect(
        result.exitCode,
        uploadCollisionExit,
        reason: '${result.stdout}${result.stderr}',
      );
      expect('${result.stderr}', contains('already names a different commit'));
      expect(
        '${result.stderr}${result.stdout}',
        isNot(contains('Unhandled exception')),
      );
    } finally {
      Directory(root).deleteSync(recursive: true);
    }
  });

  test('the collision code is not one another failure already uses', () {
    // The whole point is that a wrapper can tell this apart from the failure it
    // tolerates. Sharing a number with anything else gives that back.
    expect(uploadCollisionExit, isNot(0));
    expect(uploadCollisionExit, isNot(1), reason: 'every other failure');
    expect(
      uploadCollisionExit,
      isNot(2),
      reason: 'screenshots flatten --check',
    );
    expect(uploadCollisionExit, isNot(64), reason: 'EX_USAGE, a usage error');
  });

  test('a usage error still exits 64, not the collision code', () {
    final result = _run(['play', 'upload', '--nonesuch']);

    expect(result.exitCode, 64);
    expect('${result.stderr}', contains('Could not find an option'));
  });

  test('an unknown command is a usage error, not a crash', () {
    final result = _run(['nonesuch']);

    expect(result.exitCode, 64);
  });

  test('a ReleaseException prints its sentence rather than a stack trace', () {
    // A release path that dies with `Unhandled exception:` and forty lines of
    // frames buries the one sentence the operator needs. Driven through a
    // manifest that does not exist, which is the cheapest way to reach one.
    final result = _run([
      'appstore',
      'upload',
      '--platform',
      'ios',
      '--manifest',
      '/nonexistent/manifest.json',
    ]);

    expect(result.exitCode, isNot(0));
    expect(
      '${result.stderr}${result.stdout}',
      isNot(contains('Unhandled exception')),
      reason: 'the message is the product here, not the frames',
    );
    expect(
      '${result.stderr}${result.stdout}',
      contains('no build manifest'),
      reason: 'and it must still say what was wrong',
    );
  });
}
