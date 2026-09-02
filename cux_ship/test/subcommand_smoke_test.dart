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

import 'cli_snapshot.dart';

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

/// Runs the CLI in [repo] and returns its combined output.
///
/// A snapshot rather than the source, because every case here spawns the binary
/// and compiling it per invocation was most of this package's test time — see
/// cli_snapshot.dart, which also explains why the entrypoint is found rather
/// than interpolated. That last part is load-bearing: a first version built the
/// path from `Directory.current`, which resolves from the workspace root and
/// not from the package directory, and CI runs `dart test` with
/// `working-directory: cux_ship`. The subprocess then died with "No such file
/// or directory", which contains none of the phrases below, so every case that
/// exists to pin the 3.2.0 crash passed while asserting nothing.
ProcessResult _run(Directory repo, List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['--enable-asserts', cliSnapshot, ...args],
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
    ['play', 'data-safety'],
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
    ['appstore', 'beta-release'],
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

  // Offline refusals, testable end to end because they fire before any
  // credential is loaded. The build number is required by decision rather
  // than accident — the 2.2.0 `wait` note made the same call — so the
  // refusal, not just the option, is what gets pinned.
  test('beta-release without its arguments refuses, naming each', () {
    // The bundle id is passed because the fixture has no Xcode project to
    // infer one from, and that refusal would otherwise arrive first.
    final noGroup = _run(repo, [
      'appstore',
      'beta-release',
      '--bundle-id',
      'design.codeux.consumer',
    ]);
    expect('${noGroup.stderr}', contains('--beta-group'));
    expect(noGroup.exitCode, isNot(0));

    final noBuild = _run(repo, [
      'appstore',
      'beta-release',
      '--bundle-id',
      'design.codeux.consumer',
      '--beta-group',
      'friends',
    ]);
    expect('${noBuild.stderr}', contains('--build-number'));
    expect('${noBuild.stderr}', contains('deliberately not defaulted'));
    expect(noBuild.exitCode, isNot(0));

    // A bare positional is most likely a build number that the run would
    // otherwise silently not use, while demanding --build-number anyway.
    final positional = _run(repo, [
      'appstore',
      'beta-release',
      '--bundle-id',
      'design.codeux.consumer',
      '--beta-group',
      'friends',
      '--build-number',
      '5',
      '52',
    ]);
    expect('${positional.stderr}', contains('unexpected argument "52"'));
    expect(positional.exitCode, isNot(0));
  });

  // The description guards are offline by design — on `upload --beta-group`
  // the artifact and the processing wait land before the group step, so
  // anything about the description that can refuse has to refuse before a
  // credential is loaded. That design is also what makes these testable end
  // to end: no network, no secrets, a spawned CLI and an exit code.
  group('the beta description refuses offline', () {
    test('a dirty tree description stops an upload, despite --no-metadata', () {
      Directory(
        '${repo.path}/store/appstore/listings/en-US',
      ).createSync(recursive: true);
      File(
        '${repo.path}/store/appstore/listings/en-US/beta_description.txt',
      ).writeAsStringSync('half-written\n');
      File('${repo.path}/app.ipa').writeAsStringSync('not really an ipa');

      final result = _run(repo, [
        'appstore', 'upload',
        '--bundle-id', 'design.codeux.consumer',
        '--artifact', 'app.ipa',
        '--build-number', '5',
        '--version-name', '1.0.0',
        // The decision under test: --no-metadata declines the *listing*, and
        // the beta description is test information, so the tree file is
        // still consulted.
        '--no-metadata',
        '--beta-group', 'Friends',
      ]);
      final output = '${result.stdout}${result.stderr}';
      expect(output, contains('the beta app description'));
      expect(output, contains('uncommitted'));
      // Refused before any credential was even looked for — the proof this
      // ran in the offline block rather than after the artifact went up.
      expect(output, isNot(contains('credentials')));
      expect(result.exitCode, isNot(0));
    });

    test('--beta-description without --beta-group refuses', () {
      Directory('${repo.path}/store/appstore').createSync(recursive: true);
      final result = _run(repo, [
        'appstore',
        'upload',
        '--bundle-id',
        'design.codeux.consumer',
        '--beta-description',
        'missing.txt',
      ]);
      expect('${result.stderr}', contains('without --beta-group'));
      expect(result.exitCode, isNot(0));
    });

    test('--skip-waiting and --beta-group refuse together', () {
      File('${repo.path}/app.ipa').writeAsStringSync('not really an ipa');
      final result = _run(repo, [
        'appstore',
        'upload',
        '--bundle-id',
        'design.codeux.consumer',
        '--artifact',
        'app.ipa',
        '--build-number',
        '5',
        '--version-name',
        '1.0.0',
        '--skip-waiting',
        '--beta-group',
        'Friends',
      ]);
      expect('${result.stderr}', contains('incompatible'));
      expect(result.exitCode, isNot(0));
    });
  });

  group('promote --beta-group leaves the listing alone', () {
    test('the inferred tree is not even loaded', () {
      // An empty store/appstore fails loadMetadata with "nothing to
      // publish", so its absence from the output is proof the tree was never
      // consulted — the run gets all the way to the missing credentials.
      Directory('${repo.path}/store/appstore').createSync(recursive: true);
      final result = _run(repo, [
        'appstore',
        'promote',
        '--bundle-id',
        'design.codeux.consumer',
        '--beta-group',
        'Friends',
        '--dry-run',
      ]);
      final output = '${result.stdout}${result.stderr}';
      expect(output, isNot(contains('nothing to publish')));
      expect(output, contains('credentials'));
    });

    test('an explicit --metadata alongside is a contradiction', () {
      Directory('${repo.path}/store/appstore').createSync(recursive: true);
      final result = _run(repo, [
        'appstore',
        'promote',
        '--bundle-id',
        'design.codeux.consumer',
        '--beta-group',
        'Friends',
        '--metadata',
        'store/appstore',
      ]);
      expect('${result.stderr}', contains('opposite things on promote'));
      expect(result.exitCode, isNot(0));
    });
  });

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
