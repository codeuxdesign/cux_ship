// SPDX-License-Identifier: Apache-2.0
//
// The cases that matter here are the ones where recording should *refuse*, and
// the one where it must not. A tag that already exists is ordinary — a second
// store, a retried job — while a tag that names a different commit means one
// build number reached two commits, and publishing under it records the wrong
// one permanently.
import 'dart:io';

import 'package:cux_ship/src/provenance.dart';
import 'package:cux_ship/src/release.dart' show Git, ReleaseException;
import 'package:test/test.dart';

late Directory _root;
late Git _git;

String _commit(String message) {
  File('${_root.path}/file.txt').writeAsStringSync(message);
  _git.run(['add', '-A']);
  _git.run(['commit', '-q', '-m', message]);
  return _git.run(['rev-parse', 'HEAD']);
}

UploadRecord _record(String commit, {String name = 'uploaded/v1.0.0+49'}) =>
    UploadRecord(
      name: name,
      commit: commit,
      annotation: 'build 49\nsha256 abc123\nstore: play',
    );

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_provenance_test');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('records an upload at the commit it was built from', () {
    final built = _commit('built here');
    _commit('later work');

    final result = recordUpload(_git, _record(built), push: false);

    expect(result, UploadRecordResult.created);
    expect(
      _git.run(['rev-parse', 'refs/tags/uploaded/v1.0.0+49^{commit}']),
      built,
      reason: 'the tag must name the built commit, not HEAD',
    );
  });

  test('the tag is annotated, so it can carry what the commit cannot', () {
    final built = _commit('built here');
    recordUpload(_git, _record(built), push: false);

    expect(
      _git.run(['cat-file', '-t', 'refs/tags/uploaded/v1.0.0+49']),
      'tag',
      reason: 'a lightweight tag has nowhere to record the build number',
    );
    expect(_git.run(['tag', '-l', '-n99', 'uploaded/v1.0.0+49']),
        contains('build 49'));
  });

  test('re-recording the same artifact is not an error', () {
    final built = _commit('built here');
    recordUpload(_git, _record(built), push: false);

    // A second store, or the same job retried. This must be ordinary.
    final again = recordUpload(_git, _record(built), push: false);

    expect(again, UploadRecordResult.alreadyRecorded);
  });

  test('an annotated tag is compared by commit, not by tag object', () {
    final built = _commit('built here');
    recordUpload(_git, _record(built), push: false);

    // `rev-parse <annotated tag>` yields the tag object. If the comparison
    // forgets `^{commit}` this test fails, because the happy path starts
    // reporting a collision with itself.
    final tagObject = _git.run(['rev-parse', 'refs/tags/uploaded/v1.0.0+49']);
    expect(tagObject, isNot(built), reason: 'otherwise this proves nothing');

    expect(
      recordUpload(_git, _record(built), push: false),
      UploadRecordResult.alreadyRecorded,
    );
  });

  test('refuses when the name already points at a different commit', () {
    final first = _commit('first artifact');
    recordUpload(_git, _record(first), push: false);
    final second = _commit('second artifact');

    expect(
      () => recordUpload(_git, _record(second), push: false),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains(first), contains(second), contains('Nothing was uploaded')),
        ),
      ),
      reason: 'one build number reaching two commits must stop the upload',
    );
  });

  test('leaves the existing tag alone when it refuses', () {
    final first = _commit('first artifact');
    recordUpload(_git, _record(first), push: false);
    final second = _commit('second artifact');

    try {
      recordUpload(_git, _record(second), push: false);
    } on ReleaseException {
      // expected
    }

    expect(
      _git.run(['rev-parse', 'refs/tags/uploaded/v1.0.0+49^{commit}']),
      first,
      reason: 'a refusal must not move the record it refused to overwrite',
    );
  });

  test('a dry run writes nothing', () {
    final built = _commit('built here');

    final result = recordUpload(_git, _record(built), push: false, dryRun: true);

    expect(result, UploadRecordResult.created);
    expect(_git.run(['tag', '-l', 'uploaded/v1.0.0+49']), isEmpty);
  });

  test('a failed push fails the caller rather than warning', () {
    final built = _commit('built here');

    // No remote is configured, so the push cannot succeed. An unpushed tag is
    // indistinguishable from no tag on the machine that will do the upload, so
    // this must not be swallowed.
    expect(
      () => recordUpload(_git, _record(built), push: true),
      throwsA(isA<ReleaseException>()),
    );
  });

  test('the caller owns the tag name, including its namespace', () {
    final built = _commit('built here');

    recordUpload(_git, _record(built, name: 'v1.0.0'), push: false);

    expect(_git.run(['tag', '-l', 'v1.0.0']), 'v1.0.0');
  });
}
