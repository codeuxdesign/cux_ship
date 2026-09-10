// SPDX-License-Identifier: Apache-2.0
//
// `cux_ship verify --json`.
//
// **`skipped` is why this document exists in the shape it does**, and it is
// the field a test can most easily make vacuous. `checked` alone lets a reader
// notice an omission only by already holding the expected set in their head —
// so a check that silently did not run is invisible unless somebody is keeping
// the list. That is the same failure the `checked` lines were added to close,
// one level up, and it was the consumer who spotted that the fix had it too.
//
// Spawned rather than called, because the wiring is in `VerifyCommand.run`:
// which artifacts were found, which were not, and the exit code. A unit test
// of the encoder would assert that a list this file never builds is rendered
// correctly.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'cli_snapshot.dart';

late Directory _repo;

void _write(String relative, String contents) {
  final file = File('${_repo.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

ProcessResult _verify([List<String> args = const []]) => Process.runSync(
  Platform.resolvedExecutable,
  ['--enable-asserts', cliSnapshot, 'verify', '--json', ...args],
  workingDirectory: _repo.path,
);

Map<String, dynamic> _document(ProcessResult result) =>
    jsonDecode('${result.stdout}') as Map<String, dynamic>;

/// The `what` of every entry in [field], so a case can name kinds rather than
/// index into a list whose order it would then be pinning by accident.
Set<String> _kinds(Map<String, dynamic> document, String field) => {
  for (final entry in document[field] as List)
    (entry as Map<String, dynamic>)['what'] as String,
};

void main() {
  setUp(() {
    _repo = Directory.systemTemp.createTempSync('cux_ship_verify_json');
    Process.runSync('git', ['init', '-q'], workingDirectory: _repo.path);
  });

  tearDown(() => _repo.deleteSync(recursive: true));

  test('a clean run is one document on stdout, and nothing else', () async {
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', '# Changelog\n\n## 1.0.1\n\n- Next\n');

    final result = _verify();

    expect(result.exitCode, 0, reason: '${result.stderr}');
    final document = _document(result);
    expect(document['kind'], 'verify');
    expect(document['schema'], 1);
    expect(document['ok'], isTrue);
    expect(document['problems'], isEmpty);
  });

  test('what was NOT checked is named, with a reason', () {
    // **The point of the field.** This repository has a changelog and nothing
    // else, so three artifacts went uninspected — and `ok: true` beside them
    // is a true statement a reader would take for coverage.
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', '# Changelog\n\n## 1.0.1\n\n- Next\n');

    final document = _document(_verify());

    expect(document['ok'], isTrue);
    expect(_kinds(document, 'checked'), {'changelog', 'section'});
    expect(_kinds(document, 'skipped'), {
      'appstore',
      'play',
      'data-safety',
    }, reason: 'a check that did not run must not be invisible');
    // Each carries why, so the reader is not left to guess between "absent"
    // and "not implemented".
    for (final entry in document['skipped'] as List) {
      expect((entry as Map<String, dynamic>)['why'], isNotEmpty);
      expect(entry['where'], isNull, reason: 'nothing was there to name');
    }
  });

  test('a checked artifact names where it was, and skips no reason', () {
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', '# Changelog\n\n## 1.0.1\n\n- Next\n');

    final document = _document(_verify());

    final section = (document['checked'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) => e['what'] == 'section');
    // **The qualifier is part of it.** `where` is not a path: `section` is a
    // version and the file that declared it, which is why the field is not
    // called `path`.
    expect(section['where'], '1.0.1 (pubspec.yaml)');
    expect(section['why'], isNull);
  });

  test('problems are carried, ok is false, and the status is 1', () {
    // **Two channels for one fact, and allowed here.** `verify` exists to fail
    // a build, so a caller wiring it into CI expects the status to mean what
    // every other checker's does. That is the opposite call from `matches` in
    // the listing diff, where the answer is ordinary and the status must not
    // carry it — see dry-run-json.md.
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', '# Changelog\n\n## 1.0.0\n\n- Shipped\n');

    final result = _verify();

    expect(result.exitCode, 1);
    final document = _document(result);
    expect(document['ok'], isFalse);
    expect(document['problems'], isNotEmpty);
    // The section was still *checked* — reporting it missing is the finding,
    // not a reason to say it was skipped.
    expect(_kinds(document, 'checked'), contains('section'));
  });

  test('ok agrees with problems, because one computes the other', () {
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', '# Changelog\n\n## 1.0.0\n\n- Shipped\n');

    final document = _document(_verify());

    expect(
      document['ok'],
      (document['problems'] as List).isEmpty,
      reason: 'a document saying both would be two answers under one key',
    );
  });

  test('display carries the prose, so a renderer needs no second format', () {
    _write('pubspec.yaml', 'name: consumer\nversion: 1.0.1+2\n');
    _write('CHANGELOG.md', '# Changelog\n\n## 1.0.1\n\n- Next\n');

    final document = _document(_verify());

    final display = (document['display'] as List).cast<String>();
    expect(display, contains('    checked section    1.0.1 (pubspec.yaml)'));
    expect(display, contains('==> release inputs are publishable'));
  });

  test('nothing to check is still a refusal, not an empty document', () {
    // The command's oldest rule: checking nothing and reporting success is the
    // failure it exists to prevent. `--json` must not turn that into `ok: true`
    // with empty lists, which is what a document assembled without the guard
    // would say.
    final result = _verify();

    expect(result.exitCode, 1);
    expect('${result.stdout}', isEmpty, reason: 'no document, nothing to say');
    expect('${result.stderr}', contains('nothing to check'));
  });
}
