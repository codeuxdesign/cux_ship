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
// Nothing here reaches Play, and nothing here can: the POST is after the commit
// and past anything an offline suite can follow. So the gate is deliberately
// *one* condition — the CSV is held for the send or the notice is printed
// instead, in the same `if` — and these cases assert on the half that happens
// before a credential is even loaded. Which one ran is the observable for which
// one the POST will get.
import 'dart:io';

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
  });

  test(
    '--send-data-safety with no CSV refuses before the release, not after',
    () {
      // The send is after the commit, so a flag naming a file that was never
      // resolved would otherwise surface once the release is already public.
      final output = _run(repo, ['--send-data-safety']);
      expect(output, contains('--send-data-safety has nothing to send'));
      expect(output, contains('--data-safety'));
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
    // The claim the console contradicted. Neither "updated" nor "sent" may
    // appear on a run that published nothing.
    expect(output, isNot(contains('data safety declaration sent')));
    expect(output, isNot(contains('data safety declaration updated')));
    // And the confirmation prompt does not list a file it will not publish.
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
