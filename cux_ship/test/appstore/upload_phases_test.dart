// SPDX-License-Identifier: Apache-2.0
//
// An upload's three phases, and the seam between them.
//
// `appstore upload --artifact` transfers a binary, waits for Apple to process
// it, and then writes the TestFlight notes. `appstore wait` has always been
// able to take the middle phase somewhere else; `appstore what-to-test` is the
// last phase given the same treatment, and until it existed moving the wait
// cost the notes, because `setWhatToTest` had exactly one call site and it sat
// inside the branch that did the waiting.
//
// **What is guarded here is the seam, not the notes.** Writing a
// `betaBuildLocalizations` record is `app_store.dart`'s job and is exercised
// where the other Apple writes are. What no other suite can see is the way a
// caller arrives at the second command — every case below is a refusal or a
// suggested command line, which is to say the part of the split that is only
// ever text.
//
// **And text is exactly what rots.** Each of the three functions below exists
// as a function rather than as interpolations at its call sites, and each is
// unit-tested here, because the branches that print them cannot be driven:
// they end in `fail`, which `exit`s rather than throwing, so no in-process
// test survives one and no subprocess test gets past the missing credential.
//
// Two live TestFlight runs sharpened that. `unusableBuildState`'s
// still-processing branch may never fire at all — a build appears already
// `VALID` — and `noSuchBuild` turned out to be the message operators actually
// meet. A string nothing runs and nobody reads until the worst moment is the
// definition of the thing this file is for.
//
// The exception is `finishAfterSkippedWait`'s warning, which prints rather
// than failing and is driven end to end in upload_reuse_test.dart through the
// client seam. It was unreachable when written; it is not now.
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart' show AscPlatform;
import 'package:cux_ship/src/appstore/cli.dart'
    show finishAfterSkippedWait, noSuchBuild, unusableBuildState;
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

  group('unusableBuildState', () {
    // **Tested precisely because it may never fire.** Two live runs, on both
    // Apple platforms, at 15- and 4-second sampling, never once saw
    // `/v1/builds` list a build in any state but `VALID` — it goes from absent
    // to processed with no observable window. So the branch an operator meets
    // is `noSuchBuild` below, and this one is defensive.
    //
    // Which is exactly the shape `docs/CONTRIBUTING.md` says rots: a failure
    // path no happy-path test can reach, and now one no *real run* reaches
    // either. If it is kept it has to be exercised, or it is a comment that
    // compiles.

    String? refusal(String state, {AscPlatform platform = AscPlatform.ios}) =>
        unusableBuildState(
          state: state,
          buildNumber: '169',
          platform: platform,
          waitingFor: 'its notes cannot be written',
        );

    test('VALID is the one state that is not a refusal', () {
      expect(refusal('VALID'), isNull);
    });

    test('a terminal state says upload a new build, not wait', () {
      // The fork exists because `appstore wait` *raises* on these — sending
      // somebody to it would be sending them to a command that can only
      // restate the problem.
      for (final state in ['FAILED', 'INVALID']) {
        final message = refusal(state)!;
        expect(message, contains('will never be releasable'));
        expect(message, contains('upload a new build'));
        expect(message, isNot(contains('appstore wait')));
      }
    });

    test('any other state sends the reader to wait', () {
      final message = refusal('PROCESSING')!;
      expect(message, contains('is PROCESSING'));
      expect(message, contains('cux_ship appstore wait 169'));
    });

    test('an unreported state is refused rather than assumed usable', () {
      // `(unknown)` is what the caller substitutes when Apple sends no
      // `processingState` at all. Treating an absent state as VALID would
      // write to a build on the strength of a field that was not there.
      expect(refusal('(unknown)'), isNotNull);
    });

    test('the wait it suggests carries the platform', () {
      // The reason this became one function. Both copies said
      // `appstore wait 169`, and iOS and macOS hold different builds at that
      // number — so the recovery command named the wrong one, in the message
      // whose whole job is recovery.
      expect(
        refusal('PROCESSING', platform: AscPlatform.macos),
        contains('cux_ship appstore wait --platform macos 169'),
      );
    });

    test('it says what this caller was going to do', () {
      // Two callers, one function, and a generic refusal would tell a
      // `beta-release` operator about notes.
      expect(
        unusableBuildState(
          state: 'PROCESSING',
          buildNumber: '169',
          platform: AscPlatform.ios,
          waitingFor: 'a build cannot reach a group',
        ),
        contains('a build cannot reach a group'),
      );
    });
  });

  group('noSuchBuild', () {
    // **Unit-tested for the same reason `finishAfterSkippedWait` is**: the
    // branch that prints it calls `fail`, which `exit`s rather than throwing,
    // so no in-process test can reach it and the subprocess tests below
    // cannot get past the missing credential. The string is the only part
    // reachable at all.
    //
    // What it has to get right is *which command it names first*. There is a
    // window — about two minutes for a 28 MB iOS build, measured on a live
    // run — where the transfer has finished, the build number is correct, and
    // `/v1/builds` still answers with nothing.

    test('names wait before builds, because builds is empty too', () {
      final message = noSuchBuild(
        platform: AscPlatform.ios,
        buildNumber: '169',
        bundleId: 'design.codeux.example',
      );

      expect(message, contains('cux_ship appstore wait 169'));
      // The old message sent the reader straight to `appstore builds`, which
      // is empty in exactly that window — so the advice contradicted the
      // suggestion block `upload --skip-waiting` had just printed, and an
      // operator following it concludes their build number is wrong when it
      // is right. Order is the whole assertion.
      expect(
        message.indexOf('appstore builds'),
        greaterThan(message.indexOf('cux_ship appstore wait 169')),
      );
    });

    test('still names the bundle id, which is the other cause', () {
      // Two causes, one empty answer, and the API cannot separate them. The
      // wrong bundle id resolves to a different app and reports nothing
      // uploaded — `appstore wait`'s own help says so, and dropping it here
      // would trade one half-right message for another.
      final message = noSuchBuild(
        platform: AscPlatform.ios,
        buildNumber: '169',
        bundleId: 'design.codeux.example',
      );

      expect(message, contains('design.codeux.example'));
      expect(message, contains('bundle id'));
    });

    test('the wait it suggests carries the platform', () {
      expect(
        noSuchBuild(
          platform: AscPlatform.macos,
          buildNumber: '169',
          bundleId: 'design.codeux.example',
        ),
        contains('cux_ship appstore wait --platform macos 169'),
      );
    });
  });

  group('upload --skip-waiting no longer drops the notes silently', () {
    // **These were refusals in the first version, and review was right that
    // they should not have been.** `--changelog` and `--release-notes` name
    // *where the text lives*, not *write it now*: a repository keeping its
    // changelog anywhere but the root must pass `--changelog` on every
    // invocation, and `--release-notes` has no inferred default at all, so
    // refusing them sorted callers by directory layout and shut a whole class
    // out of the decomposition. The loudness is a warning, and the cases that
    // cover it are in upload_reuse_test.dart, which can reach the point after
    // the upload where it prints. What remains here is the one refusal that
    // *is* earned, and it is earned because `--beta-group` names an action.
    test('an explicit --changelog is not a refusal', () {
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
        '--yes',
        '--skip-waiting',
        '--changelog',
        'CHANGELOG.md',
      ]);
      final output = _output(result);
      expect(output, isNot(contains('incompatible')));
      // It gets all the way to the one thing this cannot supply, which is
      // where a run that was going to work stops. Asserting the absence of
      // the refusal alone would pass on a run refused for any other reason.
      expect(output, contains('App Store Connect credentials'));
    });

    test('--release-notes is not a refusal either', () {
      // The case that decided it. This flag has no default anywhere, so a
      // caller who keeps notes in a file rather than a changelog must always
      // pass it — and under the old rule could therefore never use
      // `--skip-waiting` at all.
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
        '--yes',
        '--skip-waiting',
        '--release-notes',
        'notes.txt',
      ]);
      final output = _output(result);
      expect(output, isNot(contains('incompatible')));
      expect(output, contains('App Store Connect credentials'));
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
