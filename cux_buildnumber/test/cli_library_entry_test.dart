// `package:cux_buildnumber/cli.dart` is a launchable entry, and stays one.
//
// **This guards a contract whose only users are outside this repository**, the
// same way `cux_ship`'s test of the same name does. A pinning project launches
// the tool as `dart --packages=<config> package:cux_buildnumber/cli.dart` so
// that it does not have to find this package in the pub cache. Nothing else
// here spawns that form, so renaming the library or dropping `main` from it
// would leave this suite green and break every consumer on their next
// `pub upgrade`.
//
// `help` rather than `generate`: it is the one command that touches no git, so
// this says nothing about whether the allocator works — `logic_test.dart` and
// the acceptance script own that. The claim here is only that the VM will
// accept the library as a script.
import 'dart:io';

import 'package:test/test.dart';

/// The workspace root's package config, resolved against both layouts — CI runs
/// `dart test` from the package directory and a developer runs it from the
/// workspace root.
///
/// One level up from the member, because `resolution: workspace` means `pub
/// get` writes one config at the root and none beside this package. See
/// `docs/design/publishing-from-a-workspace.md`.
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
  ['--packages=$_packageConfig', script, 'help'],
);

void main() {
  group('the library entry', () {
    test('runs when named as a package: URI', () {
      final result = _run('package:cux_buildnumber/cli.dart');

      expect(
        result.exitCode,
        0,
        reason:
            'package:cux_buildnumber/cli.dart did not run:\n'
            '${result.stdout}${result.stderr}',
      );
      // The tool's own usage, so this is the real program rather than a library
      // that merely happened to have a `main`.
      expect(result.stdout, contains('git-buildnumber'));
    });

    test('is the same program as bin/git_buildnumber.dart', () {
      final viaBin = _run(
        File('bin/git_buildnumber.dart').existsSync()
            ? 'bin/git_buildnumber.dart'
            : 'cux_buildnumber/bin/git_buildnumber.dart',
      );
      final viaLibrary = _run('package:cux_buildnumber/cli.dart');

      // **Success asserted before equality, because equality alone passes when
      // both of them are broken.** `bin/` is an export of this library, so
      // deleting the library makes both entries fail with the same message and
      // the same code — which satisfies "the same program" while the contract
      // is gone. Observed, in `cux_ship`'s copy of this test, by deleting the
      // library as `docs/CONTRIBUTING.md` requires.
      expect(viaBin.exitCode, 0, reason: '${viaBin.stdout}${viaBin.stderr}');
      expect(viaLibrary.exitCode, 0);
      expect(viaLibrary.stdout, viaBin.stdout);
    });

    test('prints no workspace warning, which is why consumers use it', () {
      // The whole reason a consumer passes an entry instead of `dart run`:
      // `resolution: workspace` in the published pubspec makes `dart run` emit
      // four lines of advice addressed to whoever published the package.
      final result = _run('package:cux_buildnumber/cli.dart');

      expect(result.stderr, isNot(contains('resolution `workspace`')));
      expect(result.stderr, isEmpty);
    });
  });
}
