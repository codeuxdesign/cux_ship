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

import 'package:cux_ship/src/provenance.dart' show uploadCollisionExit;
import 'package:test/test.dart';

/// The entrypoint, resolved against both layouts — CI runs from the package
/// directory, a developer from the workspace root, and a path that does not
/// resolve would make every case here pass while running nothing.
final String _cli = () {
  for (final candidate in ['bin/cux_ship.dart', 'cux_ship/bin/cux_ship.dart']) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.absolute.path;
    }
  }
  throw StateError(
    'cannot find bin/cux_ship.dart from ${Directory.current.path}',
  );
}();

ProcessResult _run(List<String> args, {String? cwd}) => Process.runSync(
  Platform.resolvedExecutable,
  ['--enable-asserts', _cli, ...args],
  workingDirectory: cwd,
);

void main() {
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
