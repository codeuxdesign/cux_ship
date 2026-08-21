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
    expect(
      _git.run(['tag', '-l', '-n99', 'uploaded/v1.0.0+49']),
      contains('build 49'),
    );
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
          allOf(
            contains(first),
            contains(second),
            contains('Nothing was uploaded'),
          ),
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

    final result = recordUpload(
      _git,
      _record(built),
      push: false,
      dryRun: true,
    );

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

  test('refuses a collision raised on another machine', () {
    // **The case the push exists for, and the only one the local comparison
    // cannot see.** Concurrent CI on two runners, one build number allocated
    // twice: this clone has no tag at all, so every local check passes and the
    // tag is created cleanly. What stops the upload is the remote rejecting a
    // tag it already holds at a different commit. Without this test the push is
    // covered only by the happy path, where a no-op and a guard look identical.
    final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
    addTearDown(() => origin.deleteSync(recursive: true));
    Process.runSync('git', ['init', '-q', '--bare', origin.path]);
    _git.run(['remote', 'add', 'origin', origin.path]);

    final ours = _commit('our artifact');
    final theirs = _commit('their artifact');

    // The other runner got there first. Only origin knows.
    _git.run(['tag', '-a', 'uploaded/v1.0.0+49', theirs, '-m', 'theirs']);
    _git.run(['push', '-q', 'origin', 'refs/tags/uploaded/v1.0.0+49']);
    _git.run(['tag', '-d', 'uploaded/v1.0.0+49']);

    expect(
      () => recordUpload(_git, _record(ours)),
      throwsA(isA<ReleaseException>()),
      reason: 'the remote holds this name at another commit',
    );

    expect(
      Git(
        origin.path,
      ).run(['rev-parse', 'refs/tags/uploaded/v1.0.0+49^{commit}']),
      theirs,
      reason: 'and the record that was already published must not move',
    );
  });

  test('two runners recording the same build is not a collision', () {
    // **The half the test above could not see, and the one that happens.** It
    // uses a *different* commit, which is the rare case; a release matrix
    // sharing one commit and one build number is every release. Both jobs mint
    // their own annotated tag object — different timestamp, different message —
    // and git refuses to replace one with the other, rejecting the push with
    // `! [rejected] ... (already exists)`: the same words as a real collision.
    //
    // Read as one, it blocked an upload that had done nothing wrong, and AuthPass
    // found it by half-shipping a release: playstoredev pushed first, playstore
    // was refused, and nothing was left to distinguish them but the commit the
    // remote tag actually names.
    final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
    addTearDown(() => origin.deleteSync(recursive: true));
    Process.runSync('git', ['init', '-q', '--bare', origin.path]);
    _git.run(['remote', 'add', 'origin', origin.path]);

    final shared = _commit('one artifact, two jobs');

    // The other runner recorded this exact build first, with its own wording.
    _git.run([
      'tag',
      '-a',
      'uploaded/v1.0.0+49',
      shared,
      '-m',
      'build 49 of 1.0.0\nstore: playstoredev',
    ]);
    _git.run(['push', '-q', 'origin', 'refs/tags/uploaded/v1.0.0+49']);
    _git.run(['tag', '-d', 'uploaded/v1.0.0+49']);

    expect(
      recordUpload(_git, _record(shared)),
      UploadRecordResult.alreadyRecorded,
      reason: 'same commit, someone else got there first — not a collision',
    );

    expect(
      Git(
        origin.path,
      ).run(['rev-parse', 'refs/tags/uploaded/v1.0.0+49^{commit}']),
      shared,
      reason: 'and the published record still names the right commit',
    );
  });

  test('a push that fails once and then works is not a collision', () {
    // **The branch that reported a collision for a tag it had just published.**
    // When the push is rejected and origin turns out not to hold the tag, the
    // failure was operational rather than a race — so it is re-run without
    // `ok`, to surface git's own message. But if that retry *succeeds*, the
    // remote lookup's `null` was still in hand, and `null != commit` threw
    // `UploadCollisionException` saying `origin points at: null`: exit 3, the
    // code a release wrapper is documented to treat as unrecoverable, for a
    // record that is on origin and correct.
    //
    // Reached here with a pre-receive hook that refuses exactly once, which is
    // what a transient credential or network failure looks like from this side.
    final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
    addTearDown(() => origin.deleteSync(recursive: true));
    Process.runSync('git', ['init', '-q', '--bare', origin.path]);
    final hook = File('${origin.path}/hooks/pre-receive')
      ..writeAsStringSync(
        // A marker beside the hook, named absolutely: `git` runs hooks with a
        // cwd this test should not have to predict, and `\$GIT_DIR` would be
        // interpolated by Dart before the shell ever saw it.
        '#!/bin/sh\n'
        'marker="${origin.path}/refused-once"\n'
        'if [ ! -f "\$marker" ]; then\n'
        '  touch "\$marker"\n'
        '  echo "transient" >&2\n'
        '  exit 1\n'
        'fi\n'
        'exit 0\n',
      );
    Process.runSync('chmod', ['+x', hook.path]);
    _git.run(['remote', 'add', 'origin', origin.path]);

    final built = _commit('built');

    expect(
      recordUpload(_git, _record(built)),
      UploadRecordResult.created,
      reason: 'the second push landed, so this is the record it created',
    );

    expect(
      Git(
        origin.path,
      ).run(['rev-parse', 'refs/tags/uploaded/v1.0.0+49^{commit}']),
      built,
      reason: 'and it really is on origin, which is what makes it a record',
    );
  });

  test('a collision is its own exception type, so a wrapper can tell', () {
    // Release scripts tolerate a store refusing a build it already holds — the
    // upload runs under `|| exitCode=$?` so a re-run is a no-op. A collision
    // exiting through that same path is reported as the tolerable kind and the
    // release finishes green, which turns the loudest error here into the
    // quietest. The type is what lets a wrapper distinguish them.
    final first = _commit('first artifact');
    recordUpload(_git, _record(first), push: false);
    final second = _commit('second artifact');

    expect(
      () => recordUpload(_git, _record(second), push: false),
      throwsA(isA<UploadCollisionException>()),
    );

    // The refusals that are *not* collisions must stay ordinary, or the
    // distinction buys nothing.
    expect(
      () =>
          recordUpload(_git, _record(first, name: 'refs/tags/x'), push: false),
      throwsA(
        allOf(isA<ReleaseException>(), isNot(isA<UploadCollisionException>())),
      ),
    );
  });

  test('refuses a name given as a ref path', () {
    final built = _commit('built here');

    // git would nest this under refs/tags/ rather than read it as one, and
    // because every use here is consistent the run would be green with the
    // record under a name nothing will look up.
    expect(
      () => recordUpload(
        _git,
        _record(built, name: 'refs/tags/uploaded/v1.0.0+49'),
        push: false,
      ),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          contains('nest'),
        ),
      ),
    );
  });

  test('a retry after a failed push publishes the tag', () {
    final built = _commit('built here');
    final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
    addTearDown(() => origin.deleteSync(recursive: true));
    Process.runSync('git', ['init', '-q', '--bare', origin.path]);

    // The first attempt cannot reach its remote — a network failure, a token
    // that had expired, a runner without the route. The tag is created locally
    // and the caller is told.
    _git.run(['remote', 'add', 'origin', '${origin.path}-does-not-exist']);
    expect(
      () => recordUpload(_git, _record(built)),
      throwsA(isA<ReleaseException>()),
    );
    expect(_git.run(['tag', '-l', 'uploaded/v1.0.0+49']), isNotEmpty);

    // The job is retried once the cause is gone. Finding its own tag locally
    // must not be read as the record already existing: nothing has reached the
    // remote, and the machine holding this one is about to be torn down.
    _git.run(['remote', 'set-url', 'origin', origin.path]);
    final again = recordUpload(_git, _record(built));

    expect(again, UploadRecordResult.alreadyRecorded);
    expect(
      Git(
        origin.path,
      ).run(['rev-parse', 'refs/tags/uploaded/v1.0.0+49^{commit}']),
      built,
      reason: 'the retry is the only chance this record has of being published',
    );
  });

  test('accepts a commit that is not written as a full sha', () {
    final built = _commit('built here');

    // Callers pass what their manifest or their CI happens to hold. The tag
    // side of the comparison is always `rev-parse` output, so anything short of
    // normalizing this side reports the *repeat* as a collision — the first
    // call succeeds and the ordinary retry is accused of naming a second
    // commit, which is the loudest error here and would be false.
    recordUpload(_git, _record('HEAD'), push: false);

    expect(
      recordUpload(_git, _record(built.substring(0, 8)), push: false),
      UploadRecordResult.alreadyRecorded,
    );
    expect(
      recordUpload(_git, _record('HEAD'), push: false),
      UploadRecordResult.alreadyRecorded,
    );
  });

  test('refuses a commit this clone does not have', () {
    _commit('built here');
    const absent = '1234567890123456789012345678901234567890';

    // A shallow clone, or an upload job triggered separately from the build.
    // git's own words for this are `fatal: bad object type.`
    expect(
      () => recordUpload(_git, _record(absent), push: false),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains(absent), contains('shallow')),
        ),
      ),
    );
  });

  test('refuses an existing lightweight tag, even at the right commit', () {
    final built = _commit('built here');
    _git.run(['tag', 'uploaded/v1.0.0+49', built]);

    // The commit matches, so a comparison by commit alone calls this recorded.
    // It is not: a lightweight tag has no body, so the build number, the
    // checksum and the store are absent from the thing standing as the record.
    expect(
      () => recordUpload(_git, _record(built), push: false),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('lightweight'), contains('Nothing was uploaded')),
        ),
      ),
    );
  });
}
