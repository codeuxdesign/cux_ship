// SPDX-License-Identifier: Apache-2.0
//
// An upload's three phases, and the seam between them.
//
// `appstore upload --artifact` transfers a binary, waits five to fifteen
// minutes for Apple to process it, and then writes the TestFlight notes.
// `appstore wait` has always been able to take the middle phase somewhere
// else; `appstore what-to-test` is the last phase given the same treatment,
// and until it existed moving the wait cost the notes, because
// `setWhatToTest` had exactly one call site and it sat inside the branch that
// did the waiting.
//
// **What is guarded here is the seam, not the notes.** Writing a
// `betaBuildLocalizations` record is `app_store.dart`'s job and is exercised
// where the other Apple writes are. What no other suite can see is the way a
// caller arrives at the second command — every case below is a refusal or a
// suggested command line, which is to say the part of the split that is only
// ever text.
//
// **And text is exactly what rots.** `finishAfterSkippedWait` exists as a
// function rather than three interpolations because its most important caller
// prints *after* the artifact has gone up, past the credential and past
// Apple, where nothing offline can reach it. The unit cases below are the only
// thing that will ever run that string.
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart' show AscPlatform;
import 'package:cux_ship/src/appstore/cli.dart' show finishAfterSkippedWait;
import 'package:test/test.dart';

import '../cli_snapshot.dart';

/// A repository the App Store commands will infer a bundle id and a version
/// from, with an *optional* changelog — several cases below turn on the
/// difference between "no notes anywhere" and "notes that have no section".
Directory _repo({String? changelog}) {
  final dir = Directory.systemTemp.createTempSync('cux_ship_phases');
  addTearDown(() => dir.deleteSync(recursive: true));

  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: consumer\nversion: 1.0.0+1\nenvironment:\n  sdk: ^3.12.2\n',
  );
  Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
  if (changelog != null) {
    File('${dir.path}/CHANGELOG.md').writeAsStringSync(changelog);
    // **Committed, not merely written.** `requireCommittedNotes` refuses a
    // dirty file, so a changelog left uncommitted would refuse for that
    // reason instead — and every case below asserting a *different* refusal
    // would pass while proving nothing.
    Process.runSync('git', ['add', '.'], workingDirectory: dir.path);
    Process.runSync('git', [
      '-c',
      'user.email=test@example.com',
      '-c',
      'user.name=test',
      'commit',
      '-qm',
      'notes',
    ], workingDirectory: dir.path);
  }
  return dir;
}

ProcessResult _run(Directory repo, List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['--enable-asserts', cliSnapshot, ...args],
  workingDirectory: repo.path,
);

/// Everything the CLI printed, wherever it printed it.
String _output(ProcessResult result) => '${result.stdout}${result.stderr}';

void main() {
  group('finishAfterSkippedWait', () {
    test('the default platform is left off every line', () {
      expect(
        finishAfterSkippedWait(
          platform: AscPlatform.ios,
          buildNumber: '52',
          notes: true,
          betaGroup: 'Friends',
        ),
        [
          'cux_ship appstore wait 52',
          'cux_ship appstore what-to-test --build-number 52',
          'cux_ship appstore beta-release --build-number 52 '
              '--beta-group "Friends"',
        ],
      );
    });

    test('macOS carries --platform on every line, not only the first', () {
      // The case this function exists for. iOS and macOS are given the *same*
      // build number from one commit by design, so a suggested command that
      // drops the platform names the other platform's build and reports
      // success — and the operator has nothing in the output to tell them.
      expect(
        finishAfterSkippedWait(
          platform: AscPlatform.macos,
          buildNumber: '52',
          notes: true,
          betaGroup: 'Friends',
        ),
        [
          'cux_ship appstore wait --platform macos 52',
          'cux_ship appstore what-to-test --platform macos --build-number 52',
          'cux_ship appstore beta-release --platform macos --build-number 52 '
              '--beta-group "Friends"',
        ],
      );
    });

    test('a phase the run did not ask for contributes no line', () {
      expect(
        finishAfterSkippedWait(platform: AscPlatform.ios, buildNumber: '9'),
        ['cux_ship appstore wait 9'],
      );
    });

    test('the notes argument is carried through when one was named', () {
      expect(
        finishAfterSkippedWait(
          platform: AscPlatform.ios,
          buildNumber: '9',
          notes: true,
          notesArgument: '--release-notes notes.txt',
        ).last,
        'cux_ship appstore what-to-test --build-number 9 '
        '--release-notes notes.txt',
      );
    });

    test('an unknown build number is a placeholder, never invented', () {
      // Reachable: `--skip-waiting --changelog` is refused whether or not an
      // artifact was passed, and it is `--artifact` that requires a number.
      expect(
        finishAfterSkippedWait(platform: AscPlatform.ios, buildNumber: null),
        ['cux_ship appstore wait <build-number>'],
      );
    });
  });

  group('upload --skip-waiting no longer drops the notes silently', () {
    test('an explicit --changelog is refused, before any credential', () {
      final repo = _repo(changelog: '# Changelog\n\n## 1.0.0\n\n- a change\n');
      File('${repo.path}/app.ipa').writeAsStringSync('not really an ipa');
      final result = _run(repo, [
        'appstore',
        'upload',
        '--bundle-id',
        'design.codeux.consumer',
        '--artifact',
        'app.ipa',
        '--build-number',
        '52',
        '--version-name',
        '1.0.0',
        '--skip-waiting',
        '--changelog',
        'CHANGELOG.md',
      ]);
      final output = _output(result);
      expect(output, contains('incompatible'));
      expect(
        output,
        contains('cux_ship appstore what-to-test --build-number 52'),
      );
      // Refused with no credential in scope at all — the proof this ran in
      // the offline block rather than after the binary went up, which is the
      // only placement that makes the refusal safe to add.
      expect(output, isNot(contains('credentials')));
      expect(result.exitCode, isNot(0));
    });

    test('--release-notes is refused the same way, naming itself', () {
      final repo = _repo();
      File('${repo.path}/app.ipa').writeAsStringSync('not really an ipa');
      File('${repo.path}/notes.txt').writeAsStringSync('a change');
      final result = _run(repo, [
        'appstore',
        'upload',
        '--bundle-id',
        'design.codeux.consumer',
        '--artifact',
        'app.ipa',
        '--build-number',
        '52',
        '--version-name',
        '1.0.0',
        '--skip-waiting',
        '--release-notes',
        'notes.txt',
      ]);
      final output = _output(result);
      expect(output, contains('--release-notes'));
      expect(output, contains('--release-notes notes.txt'));
      expect(result.exitCode, isNot(0));
    });

    test('the suggested commands carry the platform the run was for', () {
      final repo = _repo(changelog: '# Changelog\n\n## 1.0.0\n\n- a change\n');
      File('${repo.path}/app.pkg').writeAsStringSync('not really a pkg');
      final result = _run(repo, [
        'appstore',
        'upload',
        '--platform',
        'macos',
        '--bundle-id',
        'design.codeux.consumer',
        '--artifact',
        'app.pkg',
        '--build-number',
        '52',
        '--version-name',
        '1.0.0',
        '--skip-waiting',
        '--changelog',
        'CHANGELOG.md',
      ]);
      expect(
        _output(result),
        contains('cux_ship appstore what-to-test --platform macos'),
      );
      expect(result.exitCode, isNot(0));
    });

    test('--beta-group is still refused, and now says how to finish', () {
      // The refusal predates the split and was already right; what is new is
      // that it names `beta-release` instead of leaving the caller to find
      // it. Kept here rather than in subcommand_smoke_test.dart, which pins
      // only that the command started.
      final repo = _repo();
      File('${repo.path}/app.ipa').writeAsStringSync('not really an ipa');
      final result = _run(repo, [
        'appstore',
        'upload',
        '--bundle-id',
        'design.codeux.consumer',
        '--artifact',
        'app.ipa',
        '--build-number',
        '52',
        '--version-name',
        '1.0.0',
        '--skip-waiting',
        '--beta-group',
        'Friends',
      ]);
      final output = _output(result);
      expect(output, contains('incompatible'));
      expect(
        output,
        contains(
          'cux_ship appstore beta-release --build-number 52 '
          '--beta-group "Friends"',
        ),
      );
      expect(result.exitCode, isNot(0));
    });
  });

  group('what-to-test refuses offline, before it asks Apple anything', () {
    test('no --build-number, and it is not defaulted to the newest', () {
      final result = _run(_repo(), [
        'appstore',
        'what-to-test',
        '--bundle-id',
        'design.codeux.consumer',
      ]);
      final output = _output(result);
      expect(output, contains('which build?'));
      expect(output, isNot(contains('credentials')));
      expect(result.exitCode, isNot(0));
    });

    test('a build number that is not an integer', () {
      final result = _run(_repo(), [
        'appstore',
        'what-to-test',
        '--bundle-id',
        'design.codeux.consumer',
        '--build-number',
        'newest',
      ]);
      expect(_output(result), contains('must be an integer'));
      expect(result.exitCode, isNot(0));
    });

    test('a stray positional, which `wait` accepts and this does not', () {
      final result = _run(_repo(), [
        'appstore',
        'what-to-test',
        '--bundle-id',
        'design.codeux.consumer',
        '--build-number',
        '52',
        '53',
      ]);
      expect(_output(result), contains('unexpected argument "53"'));
      expect(result.exitCode, isNot(0));
    });

    test('nothing to publish, when no notes were found anywhere', () {
      final result = _run(_repo(), [
        'appstore',
        'what-to-test',
        '--bundle-id',
        'design.codeux.consumer',
        '--build-number',
        '52',
      ]);
      final output = _output(result);
      expect(output, contains('no notes to publish'));
      expect(output, isNot(contains('credentials')));
      expect(result.exitCode, isNot(0));
    });

    test('a changelog with no section for the version', () {
      // The ordinary mistake, and the one the upload path finds *late* — its
      // own doc comment says moving the read into the offline phase is the
      // better fix and does not do it. This command starts there, so the
      // refusal arrives with no credential loaded and nothing left behind.
      final repo = _repo(changelog: '# Changelog\n\n## 0.9.0\n\n- older\n');
      final result = _run(repo, [
        'appstore',
        'what-to-test',
        '--bundle-id',
        'design.codeux.consumer',
        '--build-number',
        '52',
      ]);
      final output = _output(result);
      expect(output, contains('no section for 1.0.0'));
      expect(output, isNot(contains('credentials')));
      expect(result.exitCode, isNot(0));
    });

    test('resolved notes get all the way to the missing credential', () {
      // The positive half of the two cases above: with a section to publish,
      // the offline phase passes and the run stops at the one thing a test
      // cannot supply. Without this, "refuses offline" would be satisfied by
      // a command that refuses everything.
      final repo = _repo(changelog: '# Changelog\n\n## 1.0.0\n\n- a change\n');
      final result = _run(repo, [
        'appstore',
        'what-to-test',
        '--bundle-id',
        'design.codeux.consumer',
        '--build-number',
        '52',
        '--yes',
      ]);
      final output = _output(result);
      expect(output, contains('App Store Connect credentials'));
      expect(result.exitCode, isNot(0));
    });
  });
}
