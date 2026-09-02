// SPDX-License-Identifier: Apache-2.0
//
// An upload checks the data safety declaration and never sends it; sending it
// is `play data-safety`.
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
// **What these cases can and cannot see.** They spawn the CLI with the service
// account pointed at a file that does not exist, so no case gets past the
// credential: most stop earlier, at a refusal or a dry run, and the ones that
// would go on to write stop there. That is after all argument handling and
// after the confirmation, and before any network call — so the arguments a run
// resolved, and what it says it is about to do, are observable, and the POST
// is not.
//
// An earlier version of this file asserted that a non-sending upload never
// prints `data safety declaration sent`, which was unfalsifiable: the process
// always died first, and a review proved it by typoing that string and watching
// every case pass. The separation of commands is what removed the need for that
// assertion — `upload` no longer contains the send at all, so the question is
// which command ran, and that is a fact about the parser rather than about a
// branch nothing can reach.
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

/// A repository shaped like a real consumer: the CSV in its documented place,
/// which is *inside* the listing tree.
///
/// **That overlap is the whole point of this fixture.** `store/play/` existing
/// is what makes `--metadata` infer, and the default CSV path is
/// `store/play/data-safety.csv`, so any project following the docs has both
/// defaults resolving together. [_repo] deliberately has neither, which is why
/// it cannot see what these cases see.
Directory _repoWithTree() {
  final dir = Directory.systemTemp.createTempSync('cux_ship_ds_tree');
  addTearDown(() => dir.deleteSync(recursive: true));

  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: consumer\nversion: 1.0.0+1\nenvironment:\n  sdk: ^3.12.2\n',
  );
  Directory(
    '${dir.path}/store/play/listings/en-US',
  ).createSync(recursive: true);
  File('${dir.path}/store/play/data-safety.csv').writeAsStringSync(_csv);
  for (final name in ['title', 'short_description', 'full_description']) {
    File(
      '${dir.path}/store/play/listings/en-US/$name.txt',
    ).writeAsStringSync('text\n');
  }
  Process.runSync('git', ['init', '-q'], workingDirectory: dir.path);
  return dir;
}

/// Runs `play upload` in [repo] and returns stdout and stderr together.
///
/// **The service account variable is pointed at a path that does not exist**
/// rather than left to the environment. A developer with a real one set would
/// otherwise have these cases authenticate against Google — and the cases that
/// get as far as the credential are exactly the ones that would go on to write,
/// so the one machine where the test could do damage is the one where it would.
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

/// Runs `play data-safety` in [repo], the same way.
String _runDataSafety(Directory repo, List<String> args) {
  final result = Process.runSync(
    Platform.resolvedExecutable,
    [
      '--enable-asserts',
      cliSnapshot,
      '--yes',
      'play',
      'data-safety',
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
  group('play upload', () {
    late Directory repo;
    setUp(() => repo = _repoWithTree());

    test('refuses the retired flags by name rather than ignoring them', () {
      // The whole bug, in the only form an offline test can put it: the flag
      // that used to make an upload send is gone, so there is nothing to pass
      // that would make one send. Refusing it by name is the loud half of the
      // break — silence would be the worse failure, because a script that
      // keeps passing `--data-safety` and keeps parsing would go on believing
      // it publishes, and find out from the console filling with pending
      // reviews rather than at upgrade.
      //
      // Deliberately no assertion that an upload never prints `data safety
      // declaration sent`: every upload here dies at the credential before any
      // send could run, so that assertion could not fail — see the top of this
      // file.
      // And refused with somewhere to go. `Could not find an option named` is
      // what a parser says about a typo; a flag that was deliberately deleted
      // is a different event, and the first consumer to upgrade read the
      // generic version as cux_ship being broken rather than as the flag
      // having moved.
      for (final flag in ['--data-safety=x.csv', '--send-data-safety']) {
        final output = _run(repo, [flag]);
        expect(
          output,
          contains('was removed'),
          reason: '$flag must not be silently accepted',
        );
        expect(
          output,
          contains('cux_ship play data-safety'),
          reason: '$flag must say where it went',
        );
        // The refusal is the whole run: naming the replacement must not read
        // as an offer to carry on without the flag.
        expect(output, isNot(contains('About to')));
      }
    });

    test('still checks the declaration it will never send', () {
      // The reason `upload` reads the CSV at all. A file only ever validated by
      // the command that publishes it is validated on the day it is published,
      // which is the worst day for it to be wrong.
      File(
        '${repo.path}/store/play/data-safety.csv',
      ).writeAsStringSync('one,two\n1,2\n');
      final output = _run(repo, ['--delete-locale', 'de-DE']);
      expect(output, contains('not well formed'));
    });

    test('says it checked, so silence cannot be read as skipping', () {
      // A silent check and an absent check produce identical output, and the
      // consumer who upgraded to this hit exactly that: their upload mentioned
      // the declaration nowhere, and "it still validates" and "the check left
      // with the flag" both fitted. The second reading costs somebody their
      // structural validation without telling them.
      final output = _run(repo, ['--delete-locale', 'de-DE']);
      expect(output, contains('data safety declaration checked'));
      // And names where sending went, since this is the line a reader who
      // just dropped the flag will actually see.
      expect(output, contains('cux_ship play data-safety'));
    });

    test('publishes the listing it is asked for, unchanged by any of this', () {
      // The direction that would break every consumer if the split went wrong.
      final output = _run(repo, ['--delete-locale', 'de-DE']);
      expect(output, contains('listing   '));
    });
  });

  group('play data-safety', () {
    late Directory repo;
    setUp(() => repo = _repoWithTree());

    test('finds the CSV in its documented place and says what it will do', () {
      final output = _runDataSafety(repo, []);
      expect(output, contains('About to send the data safety declaration'));
      expect(output, contains('store/play/data-safety.csv'));
      // The claims a release summary would have made here and this one must
      // not: there is no track, no version and no listing in this command.
      expect(output, isNot(contains('to track')));
      expect(output, isNot(contains('notes from')));
      expect(output, isNot(contains('public immediately')));
      // Reached the credential, so everything before the POST ran.
      expect(output, contains('absent.json'));
    });

    test('a dry run says the file is good and that nothing went', () {
      final output = _runDataSafety(repo, ['--dry-run']);
      expect(output, contains('was not sent'));
      expect(output, isNot(contains('data safety declaration sent')));
      // No credential is loaded at all, which is what makes this the offline
      // rehearsal that `play upload --dry-run` is not.
      expect(output, isNot(contains('absent.json')));
    });

    test('refuses a malformed CSV before it loads a credential', () {
      File(
        '${repo.path}/store/play/data-safety.csv',
      ).writeAsStringSync('one,two\n1,2\n');
      final output = _runDataSafety(repo, []);
      expect(output, contains('not well formed'));
      expect(output, isNot(contains('absent.json')));
    });

    test('names the default path when there is no CSV anywhere', () {
      final bare = _repo();
      final output = _runDataSafety(bare, []);
      expect(output, contains('no data safety CSV'));
      // The remediation names where it looked, not just the flag.
      expect(output, contains('store/play/data-safety.csv'));
    });

    test('takes an explicit --csv outside the listing tree', () {
      // The default is removed first, so that a run ignoring --csv cannot
      // pass: an earlier version of this case passed a path that resolved to
      // the default file, and could not have told the two apart.
      File('${repo.path}/store/play/data-safety.csv').deleteSync();
      File('${repo.path}/elsewhere.csv').writeAsStringSync(_csv);
      final output = _runDataSafety(repo, ['--csv', 'elsewhere.csv']);
      expect(output, contains('About to send the data safety declaration'));
      expect(output, contains('file   elsewhere.csv'));
      expect(output, isNot(contains('no data safety CSV')));
    });

    test('takes none of the release arguments', () {
      // It is not a release, so accepting and ignoring `--track` would be a
      // worse answer than refusing it.
      for (final flag in [
        '--track=production',
        '--aab=x.aab',
        '--metadata=x',
      ]) {
        expect(
          _runDataSafety(repo, [flag]),
          contains('Could not find an option named'),
          reason: '$flag has no meaning for a declaration',
        );
      }
    });
  });
}
