// SPDX-License-Identifier: Apache-2.0
//
// `package:cux_ship/cli.dart` is a launchable entry, and stays one.
//
// **This guards a contract whose only users are outside this repository.** A
// pinning project launches the CLI as `dart --packages=<config>
// package:cux_ship/cli.dart` precisely so that it does not have to find this
// package in the pub cache — see that library's header, and
// `publishing-from-a-workspace.md` for why it is `dart <entry>` and not `dart
// run`. Nothing else here spawns that form: the four suites that run the CLI go
// through `cli_snapshot.dart`, which compiles `bin/cux_ship.dart`. So renaming
// the library, dropping `main` from it, or moving the body back into `bin/`
// would leave this package's own suite entirely green and break every consumer
// on their next `pub upgrade`.
//
// Driven as a subprocess because the claim is about what the *VM* will accept
// as a script. Calling `main()` in process would assert that a function exists,
// which is not the thing consumers depend on.
import 'dart:io';

import 'package:test/test.dart';

/// The workspace root's package config, resolved against both layouts — CI runs
/// `dart test` from the package directory and a developer runs it from the
/// workspace root.
///
/// **One level up from the member, which is the trap
/// `publishing-from-a-workspace.md` records.** `resolution: workspace` means
/// `pub get` writes one config at the root and none beside `cux_ship/`, so the
/// obvious path here resolves to nothing.
final String _packageConfig = () {
  for (final candidate in [
    '../.dart_tool/package_config.json',
    '.dart_tool/package_config.json',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.absolute.path;
    }
  }
  throw StateError(
    'cannot find the workspace package_config.json from '
    '${Directory.current.path} — run dart pub get at the workspace root',
  );
}();

ProcessResult _run(String script) => Process.runSync(
  Platform.resolvedExecutable,
  ['--packages=$_packageConfig', script, '--help'],
);

void main() {
  group('the library entry', () {
    test('runs when named as a package: URI', () {
      final result = _run('package:cux_ship/cli.dart');

      expect(
        result.exitCode,
        0,
        reason:
            'package:cux_ship/cli.dart did not run:\n'
            '${result.stdout}${result.stderr}',
      );
      // The command's own usage, so this is the real tree rather than a library
      // that merely happened to have a `main`.
      expect(result.stdout, contains('Available commands:'));
    });

    test('is the same program as bin/cux_ship.dart', () {
      // Byte-identical rather than both-non-empty: `bin/` is an `export` of
      // this library, and the point of that form is that there is no wrapper
      // able to drift. If the two ever diverge, one of them is not the CLI.
      final viaBin = _run(
        File('bin/cux_ship.dart').existsSync()
            ? 'bin/cux_ship.dart'
            : 'cux_ship/bin/cux_ship.dart',
      );
      final viaLibrary = _run('package:cux_ship/cli.dart');

      // **Success asserted before equality, because equality alone passes when
      // both of them are broken** — which is not hypothetical: deleting
      // `lib/cli.dart` and running this suite, as `docs/CONTRIBUTING.md`
      // requires, left this case green while the other two went red. `bin/` is
      // an export of the missing library, so both entries failed with the same
      // message and the same code, and "the same program" was satisfied by two
      // identical failures. That is the vacuous pass `cli_snapshot.dart`'s
      // header is about, found the way that file's own history says these are
      // found.
      expect(viaBin.exitCode, 0, reason: '${viaBin.stdout}${viaBin.stderr}');
      expect(viaLibrary.exitCode, 0);
      expect(viaLibrary.stdout, viaBin.stdout);
    });

    test('prints no workspace warning, which is why consumers use it', () {
      // The whole reason a consumer passes an entry instead of `dart run`:
      // `resolution: workspace` in the published pubspec makes `dart run` emit
      // four lines of advice addressed to whoever published the package. A
      // launcher that reintroduced them would still pass the two cases above.
      final result = _run('package:cux_ship/cli.dart');

      expect(result.stderr, isNot(contains('resolution `workspace`')));
      expect(result.stderr, isEmpty);
    });
  });
}
