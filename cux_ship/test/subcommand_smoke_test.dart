// SPDX-License-Identifier: Apache-2.0
//
// Every subcommand reaches its own body against a repository that declares
// store blocks.
//
// **This exists because 3.2.0 shipped a crash that no test could see.**
// `_derivationProblem` read `--require-screenshot-type` out of `ArgResults`;
// that option is declared on `verify` alone, and the function was also wired
// into the App Store path. So every `appstore` subcommand — `builds`,
// `versions`, `signing`, `upload`, `promote`, `wait` — died with
// `Invalid argument(s): Could not find an option named
// "--require-screenshot-type"` before it did anything, in a published release,
// on the path that reaches Apple.
//
// Nothing here could have caught it, and the reason is worth stating rather
// than fixing quietly: the crash needs a repository with an `appstore:` block,
// and every test in this package runs against fixtures that have none. The
// consuming repository had one, which is where it surfaced — one command after
// the migration, by a person running something unrelated.
//
// So these tests are deliberately shallow. They assert only that a command
// gets *past argument handling and configuration* and into its own body, which
// is where a missing credential or a network call stops it. That is the whole
// class of failure being guarded: a command that cannot start is broken for
// everyone, whatever it would have gone on to do.
import 'dart:io';

import 'package:test/test.dart';

/// A repository shaped like a consumer: a store block, and the trees it names.
Directory _repo() {
  final dir = Directory.systemTemp.createTempSync('cux_ship_smoke');
  addTearDown(() => dir.deleteSync(recursive: true));

  File('${dir.path}/.cux-ship.yaml').writeAsStringSync('''
appstore:
  locales: [en-US]
play:
  locales: [en-US]
  screenshots: [phoneScreenshots]
''');
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: consumer\nversion: 1.0.0+1\nenvironment:\n  sdk: ^3.12.2\n',
  );
  // ProjectContext looks for the repository root via git.
  Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
  return dir;
}

/// The entrypoint to spawn, found rather than assumed.
///
/// **This is asserted rather than interpolated, because getting it wrong fails
/// in the vacuous direction.** A first version built the path from
/// `Directory.current`, which resolves from the workspace root and not from the
/// package directory — and CI runs `dart test` with `working-directory:
/// cux_ship`. The subprocess then died with "No such file or directory", which
/// contains none of the phrases below, so every case that exists to pin the
/// 3.2.0 crash passed while asserting nothing.
///
/// A test for a silent failure that can itself fail silently is worse than no
/// test, so the path is resolved against both layouts and its absence is a
/// hard error at load.
final String _cli = () {
  for (final candidate in ['bin/cux_ship.dart', 'cux_ship/bin/cux_ship.dart']) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.absolute.path;
    }
  }
  throw StateError(
    'cannot find bin/cux_ship.dart from ${Directory.current.path} — these '
    'tests spawn the CLI, and a path that does not resolve makes every one of '
    'them pass without running anything',
  );
}();

/// Runs the CLI from source in [repo] and returns its combined output.
ProcessResult _run(Directory repo, List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['--enable-asserts', _cli, ...args],
  workingDirectory: repo.path,
);

/// What a command must never say. An arg-parsing failure means it never began.
const _cannotStart = [
  'Could not find an option named',
  'Invalid argument(s)',
  'Unhandled exception',
];

void main() {
  late Directory repo;
  setUp(() => repo = _repo());

  /// Every subcommand that takes no positional argument and can be reached
  /// without one. `upload` and `promote` are covered by `--help` below, since
  /// running them for real would need credentials and an artifact.
  const reachable = [
    ['appstore', 'builds'],
    ['appstore', 'versions'],
    ['appstore', 'signing'],
    ['appstore', 'screenshot-types'],
    ['appstore', 'build-number'],
    ['play', 'tracks'],
    ['play', 'listing'],
    ['play', 'version-code'],
    ['verify'],
  ];

  for (final command in reachable) {
    test('${command.join(' ')} starts', () {
      final result = _run(repo, command);
      final output = '${result.stdout}${result.stderr}';
      for (final phrase in _cannotStart) {
        expect(
          output,
          isNot(contains(phrase)),
          reason:
              '`cux_ship ${command.join(' ')}` did not get past argument '
              'handling:\n$output',
        );
      }
    });
  }

  /// `--help` covers the commands that cannot be run without credentials or an
  /// artifact.
  ///
  /// **It would not have caught the 3.2.0 crash**, and saying so matters: that
  /// crash was in `_AscSubcommand.run`, *after* parsing, so `--help` returns
  /// before reaching it — checked against v3.2.0, where these three pass. What
  /// protects `upload`, `promote` and `wait` is that they share
  /// `_AscSubcommand.run` with the five commands run for real above. An option
  /// read added to a write-only path would escape this suite entirely.
  const helpOnly = [
    ['appstore', 'upload'],
    ['appstore', 'promote'],
    ['appstore', 'wait'],
    ['play', 'upload'],
    ['play', 'promote'],
    ['release', 'finish'],
    ['secrets', 'list'],
    ['keychain', 'exec'],
  ];

  for (final command in helpOnly) {
    test('${command.join(' ')} --help starts', () {
      final result = _run(repo, [...command, '--help']);
      final output = '${result.stdout}${result.stderr}';
      for (final phrase in _cannotStart) {
        expect(output, isNot(contains(phrase)), reason: output);
      }
      expect(result.exitCode, 0, reason: output);
    });
  }

  test('a repository with no config still starts every command', () {
    // The other half of the 3.2.0 shape: the crash fired only when a block was
    // declared, so a fixture without one proved nothing. Both are asserted.
    final bare = Directory.systemTemp.createTempSync('cux_ship_smoke_bare');
    addTearDown(() => bare.deleteSync(recursive: true));
    Process.runSync('git', ['init', '-q'], workingDirectory: bare.path);

    for (final command in reachable) {
      final result = _run(bare, command);
      final output = '${result.stdout}${result.stderr}';
      for (final phrase in _cannotStart) {
        expect(
          output,
          isNot(contains(phrase)),
          reason: '`${command.join(' ')}` without config:\n$output',
        );
      }
    }
  });
}
