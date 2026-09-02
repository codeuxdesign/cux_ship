// SPDX-License-Identifier: Apache-2.0
//
// The data safety declaration is sent when it is asked for, and not otherwise.
//
// **This exists because "publish it on every upload" is invisible from the
// tool's own output.** `applications.dataSafety` is write-only — v3 has no GET
// for the labels and the POST answers `$Empty` — so Play files every send as a
// pending "App content → Data safety" change whether or not the CSV moved, and
// the run that caused it printed `data safety declaration updated` either way.
// A consuming project uploaded a build and then re-pushed its listing minutes
// later; both lines claimed an update, the console listed an unsubmitted Data
// safety change, and nothing in the CSV had changed for weeks.
//
// **Two suites, because the subprocess cases cannot see the thing that
// matters.** The POST is after `edits.commit`; a spawned CLI with no credential
// stops long before it, so those cases can only ever observe what the run
// *says*. An earlier version of this file asserted that a non-sending run never
// prints `data safety declaration sent` — which was unfalsifiable, since the
// process always died first, and a review proved it by typoing that string and
// watching all five cases pass.
//
// So the decision itself is a pure function, `planDataSafety`, tested in
// process against its return value; the subprocess cases cover the arguments
// and the announcement, which is all they can honestly cover. The one thing
// still unpinned is the call site handing `plan.send` to the POST — nothing
// offline reaches it, and this file no longer implies otherwise.
import 'dart:io';

import 'package:cux_ship/src/play/cli.dart';
import 'package:test/test.dart';

import 'cli_snapshot.dart';

/// A minimal well-formed export: the header, one REQUIRED question answered,
/// and one multiple-choice row that is legitimately blank. The same shape
/// cux_ship_verify's own suite uses — a CSV that fails `checkDataSafety` would
/// stop these runs before they reach what they are about.
const _csv = '''
Question ID (machine readable),Response ID (machine readable),Response value,Answer requirement,Human-friendly question label
PSL_DATA_COLLECTION_COLLECTS_PERSONAL_DATA,,FALSE,REQUIRED,Does your app collect or share any of the required user data types?
PSL_SUPPORTED_ACCOUNT_CREATION_METHODS,PSL_ACM_OAUTH,,MULTIPLE_CHOICE,Which of the following methods of account creation does your app support? Select all that apply / OAuth
''';

/// A repository the CLI will accept, with the declaration written into it.
///
/// No `android/` tree, so every case passes `--package` — the package name is
/// read from `build.gradle.kts` and a run without one dies before it reaches
/// any of this.
Directory _repo() {
  final dir = Directory.systemTemp.createTempSync('cux_ship_data_safety');
  addTearDown(() => dir.deleteSync(recursive: true));

  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: consumer\nversion: 1.0.0+1\nenvironment:\n  sdk: ^3.12.2\n',
  );
  File('${dir.path}/safety.csv').writeAsStringSync(_csv);
  // ProjectContext looks for the repository root via git.
  Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
  return dir;
}

/// Runs `play upload` in [repo] and returns stdout and stderr together.
///
/// **The service account variable is pointed at a path that does not exist**
/// rather than left to the environment. A developer with a real one set would
/// otherwise have these cases authenticate against Google — and the two that
/// get as far as the credential are the two that must not send anything, so
/// the one machine where the test could do damage is the one where it would.
/// `_loadCredentials` refuses a missing file, which is a deterministic stop
/// just past the last line these cases assert on.
String _run(Directory repo, List<String> args) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    [
      '--enable-asserts',
      cliSnapshot,
      '--yes',
      'play',
      'upload',
      '--package',
      'com.example.consumer',
      ...args,
    ],
    workingDirectory: repo.path,
    environment: {
      'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH': '${repo.path}/absent.json',
    },
  );
  return '${result.stdout}${result.stderr}';
}

void main() {
  group('planDataSafety', () {
    test('without the flag it hands over nothing to send', () {
      final plan = planDataSafety(csv: _csv, send: false);
      // The assertion the subprocess cases cannot make. Restoring the 3.6.2
      // behaviour means this returning the CSV, and nothing about the printed
      // output would change.
      expect(plan.send, isNull);
      expect(plan.notice, contains('checked, not sent'));
    });

    test('with the flag it hands over the CSV verbatim', () {
      final plan = planDataSafety(csv: _csv, send: true);
      // Verbatim matters: Play validates the whole export, and a declaration
      // that arrives trimmed or re-joined is rejected one cell at a time.
      expect(plan.send, _csv);
      expect(plan.notice, isNull);
    });

    test('it never both sends and says it did not', () {
      // The invariant the record exists for. 3.6.2 could hold both positions
      // at once because the announcement and the POST were separate
      // statements; here one value carries both and they cannot disagree.
      for (final send in [true, false]) {
        final plan = planDataSafety(csv: _csv, send: send);
        expect(
          (plan.send == null) != (plan.notice == null),
          isTrue,
          reason: 'exactly one of send/notice must be set, for send=$send',
        );
      }
    });
  });

  late Directory repo;
  setUp(() => repo = _repo());

  test('a declaration to check is not a job, so a run carrying only one '
      'refuses instead of committing an empty edit', () {
    // Before the send was gated this was a real job and the run was valid. It
    // is now a local check and nothing else, and a run whose entire content is
    // a local check would open an edit, commit it unchanged and report
    // success.
    final output = _run(repo, ['--data-safety', 'safety.csv']);
    expect(output, contains('nothing to do'));
    expect(output, contains('--send-data-safety'));
    // It says why the CSV was not enough. A refusal that lists four flags at
    // somebody who did supply one of them reads as the tool not having seen
    // it.
    expect(output, contains('checked rather than published'));
  });

  test('a run with no arguments at all is refused without being told about a '
      'declaration it does not have', () {
    // The other half of that message. The fixture has no
    // store/play/data-safety.csv, so nothing resolves a path and the advice
    // about publishing one would be about a file that does not exist.
    final output = _run(repo, []);
    expect(output, contains('nothing to do'));
    expect(output, isNot(contains('checked rather than published')));
  });

  test(
    '--send-data-safety with no CSV refuses before the release, not after',
    () {
      // The send is after the commit, so a flag naming a file that was never
      // resolved would otherwise surface once the release is already public.
      final output = _run(repo, ['--send-data-safety']);
      expect(output, contains('--send-data-safety has nothing to send'));
      // The remediation, and deliberately not `contains('--data-safety')`:
      // that is a substring of `--send-data-safety`, so it would have passed
      // on the flag name in the first half of the same sentence and asserted
      // nothing at all.
      expect(output, contains('store/play/data-safety.csv'));
    },
  );

  test('without the flag the run says it checked the declaration and did not '
      'send it', () {
    final output = _run(repo, [
      '--data-safety',
      'safety.csv',
      '--delete-locale',
      'de-DE',
    ]);
    expect(output, contains('data safety declaration checked, not sent'));
    // Deliberately no `isNot(contains('declaration sent'))` here. That line is
    // emitted after `edits.commit` and this process dies at the credential, so
    // the assertion could never have failed — `planDataSafety` above is what
    // actually pins it.
    //
    // The confirmation prompt does not list a file it will not publish.
    expect(output, isNot(contains('data safety   ')));
  });

  test('with the flag the declaration is what the run is for, and the '
      'confirmation says so', () {
    final output = _run(repo, [
      '--send-data-safety',
      '--data-safety',
      'safety.csv',
    ]);
    expect(output, isNot(contains('checked, not sent')));
    expect(output, contains('data safety   safety.csv'));
    // Stopped at the credential, holding the CSV — which is as far as an
    // offline test can follow it.
    expect(output, contains('absent.json'));
  });
}
