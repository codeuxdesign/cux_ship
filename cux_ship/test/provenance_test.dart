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

  test('an annotation line starting with # is kept', () {
    // `git tag -m` cleans its message in `strip` mode unless told otherwise,
    // and that mode deletes every line starting with `#` as an editor comment.
    // The annotation is the record, so a line lost from it is a record that
    // says less than its caller wrote — silently, with the tag created.
    final built = _commit('built here');
    recordUpload(
      _git,
      UploadRecord(
        name: 'refused/huawei/production/v1.0.0+49',
        commit: built,
        annotation: 'build 49 of 1.0.0\n#418 is why the console said no',
      ),
      push: false,
    );

    expect(
      _git.run(['tag', '-l', '-n99', 'refused/huawei/production/v1.0.0+49']),
      contains('#418 is why the console said no'),
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

  test('refuses a collision with a lightweight tag on origin', () {
    // **The same collision as above, written by something that was not this
    // tool, and for a while it was invisible.** `ls-remote` emits a `^{}` line
    // only for an annotated tag, so asking origin for the peeled ref alone got
    // nothing back from a lightweight one and read as "origin has no such
    // tag" — after which the rejected push looked like a transport failure and
    // the operator got raw git output instead of the collision.
    //
    // Not hypothetical: a `promoted/` namespace this repository is about to
    // share with a shell script that writes tags by hand is precisely where a
    // lightweight tag at the wrong commit comes from.
    final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
    addTearDown(() => origin.deleteSync(recursive: true));
    Process.runSync('git', ['init', '-q', '--bare', origin.path]);
    _git.run(['remote', 'add', 'origin', origin.path]);

    final ours = _commit('our artifact');
    final theirs = _commit('their artifact');

    // No `-a`: whatever wrote this did not make a tag object.
    _git.run(['tag', 'uploaded/v1.0.0+49', theirs]);
    _git.run(['push', '-q', 'origin', 'refs/tags/uploaded/v1.0.0+49']);
    _git.run(['tag', '-d', 'uploaded/v1.0.0+49']);

    expect(
      () => recordUpload(_git, _record(ours)),
      throwsA(isA<UploadCollisionException>()),
      reason:
          'a lightweight tag at another commit is still two commits under '
          'one build number, and still exit 3 rather than a git error',
    );
  });

  test('refuses an empty record on origin at the right commit', () {
    // **The case the fix above opened, found reviewing it.** Asking for both
    // refs made a lightweight tag on origin visible, and the commit matched,
    // so this stopped being read as "no tag on origin" and started being read
    // as "another job recorded it" — `alreadyRecorded`, quietly, where before
    // it threw. But a bare ref is not a record: `recordUpload` refuses that
    // very tag three screens up when it finds it *locally*, because the
    // annotation is where the build number, the checksum and the store live.
    //
    // Accepting it here would have made one tag a record or an empty one
    // depending only on which clone found it first, and the annotated tag this
    // run wrote would never have left the machine.
    final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
    addTearDown(() => origin.deleteSync(recursive: true));
    Process.runSync('git', ['init', '-q', '--bare', origin.path]);
    _git.run(['remote', 'add', 'origin', origin.path]);

    final shared = _commit('one artifact');

    // No `-a`: a hand-written or script-written tag, which is where the
    // `promoted/` namespace's lightweight tags come from.
    _git.run(['tag', 'uploaded/v1.0.0+49', shared]);
    _git.run(['push', '-q', 'origin', 'refs/tags/uploaded/v1.0.0+49']);
    _git.run(['tag', '-d', 'uploaded/v1.0.0+49']);

    expect(
      () => recordUpload(_git, _record(shared)),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('lightweight'), contains('the annotation is')),
        ),
      ),
      reason: 'the local path refuses this same tag for this same reason',
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

  // The group below is the record written *after* its event rather than before
  // it. Everything above assumes the upload has not happened yet, which is what
  // makes a failed push fatal there: an unpushed tag protects nothing and the
  // upload must not proceed. A promotion record is written once a person has
  // already pressed the button in a console, and failing the run then does not
  // un-promote anything — it costs the operator the step they just did and
  // sends the next run back to the same console.
  group('failedPushIsFatal: false', () {
    test('reports a tag it could not push instead of failing', () {
      // An origin that is not there at all, which is what a dropped network or
      // a revoked credential looks like from here: both pushes fail, and so
      // does asking it what the tag names.
      final built = _commit('built here');
      _git.run(['remote', 'add', 'origin', '${_root.path}/no-such-remote']);

      final result = recordUpload(
        _git,
        _record(built, name: 'promoted/huawei/production/v1.0.0+49'),
        failedPushIsFatal: false,
      );

      expect(result, UploadRecordResult.writtenNotPushed);
      expect(
        _git.run([
          'rev-parse',
          'refs/tags/promoted/huawei/production/'
              'v1.0.0+49^{commit}',
        ]),
        built,
        reason: 'the local tag is what the next run on this machine resumes on',
      );
    });

    test('still retries, so a transient failure is not reported as unpushed', () {
      // The retry is the reason that branch exists at all, and making the
      // failure non-fatal must not quietly remove it: a push that fails once
      // and succeeds on the second attempt is the ordinary case, and reporting
      // it as `writtenNotPushed` would have an operator chase a record that is
      // on origin and correct.
      final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
      addTearDown(() => origin.deleteSync(recursive: true));
      Process.runSync('git', ['init', '-q', '--bare', origin.path]);
      final hook = File('${origin.path}/hooks/pre-receive')
        ..writeAsStringSync(
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
        recordUpload(_git, _record(built), failedPushIsFatal: false),
        UploadRecordResult.created,
      );
      expect(
        Git(
          origin.path,
        ).run(['rev-parse', 'refs/tags/uploaded/v1.0.0+49^{commit}']),
        built,
        reason: 'the second push landed, so the record is published',
      );
    });

    test('does not soften a collision on origin', () {
      // A transport failure and a disagreement about what happened are
      // different things, and only the first is tolerable. A remote tag naming
      // another commit means this name has been used twice; continuing would
      // leave a record pointing at the wrong code whichever side of its event
      // it was written on.
      final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
      addTearDown(() => origin.deleteSync(recursive: true));
      Process.runSync('git', ['init', '-q', '--bare', origin.path]);
      _git.run(['remote', 'add', 'origin', origin.path]);

      final theirs = _commit('what origin recorded');
      recordUpload(_git, _record(theirs));
      _git.run(['tag', '-d', 'uploaded/v1.0.0+49']);
      final ours = _commit('what this machine has');

      expect(
        () => recordUpload(_git, _record(ours), failedPushIsFatal: false),
        throwsA(isA<UploadCollisionException>()),
      );
    });

    test('does not soften a lightweight collision either', () {
      // **The quiet half of the same bug, and the worse half.** On the fatal
      // path an invisible collision at least stopped the run, with the wrong
      // message. Here it returned `writtenNotPushed` — a result that reads as
      // "write it again next time" — on every run forever, while this clone's
      // record and origin's named different commits and nothing said so.
      final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
      addTearDown(() => origin.deleteSync(recursive: true));
      Process.runSync('git', ['init', '-q', '--bare', origin.path]);
      _git.run(['remote', 'add', 'origin', origin.path]);

      final theirs = _commit('what origin recorded');
      _git.run(['tag', 'uploaded/v1.0.0+49', theirs]);
      _git.run(['push', '-q', 'origin', 'refs/tags/uploaded/v1.0.0+49']);
      _git.run(['tag', '-d', 'uploaded/v1.0.0+49']);
      final ours = _commit('what this machine has');

      expect(
        () => recordUpload(_git, _record(ours), failedPushIsFatal: false),
        throwsA(isA<UploadCollisionException>()),
      );
    });

    test('an empty record on origin is refused here too', () {
      // Same commit, so not a collision — and not a record either. The flag
      // softens a push that could not be made, and this push *was* made and
      // refused, by an origin holding a bare ref where the annotation should
      // be. Reported as `alreadyRecorded` it would end the run claiming a
      // record that holds no build number, no checksum and, for a refusal,
      // none of the operator's reason.
      final origin = Directory.systemTemp.createTempSync('cux_ship_origin');
      addTearDown(() => origin.deleteSync(recursive: true));
      Process.runSync('git', ['init', '-q', '--bare', origin.path]);
      _git.run(['remote', 'add', 'origin', origin.path]);

      final shared = _commit('one artifact');
      _git.run(['tag', 'uploaded/v1.0.0+49', shared]);
      _git.run(['push', '-q', 'origin', 'refs/tags/uploaded/v1.0.0+49']);
      _git.run(['tag', '-d', 'uploaded/v1.0.0+49']);

      expect(
        () => recordUpload(_git, _record(shared), failedPushIsFatal: false),
        throwsA(
          isA<ReleaseException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('lightweight'), contains('the annotation is')),
          ),
        ),
      );
    });

    test(
      'a tag already here and still unpushable is not "already recorded"',
      () {
        // The resumed run: the first attempt left the tag locally and could not
        // push it, and the second finds it. `alreadyRecorded` would be true of
        // this clone and would tell the caller the record is done, when the only
        // question it has left is whether another machine can read it.
        final built = _commit('built here');
        recordUpload(_git, _record(built), push: false);
        _git.run(['remote', 'add', 'origin', '${_root.path}/no-such-remote']);

        expect(
          recordUpload(_git, _record(built), failedPushIsFatal: false),
          UploadRecordResult.writtenNotPushed,
        );
      },
    );

    test('a local collision is refused before the push is reached', () {
      // The local check runs first and is untouched by this flag. Without this
      // the non-fatal path could be read as "nothing about this record can
      // fail", which is the reading that would make it dangerous.
      final first = _commit('first artifact');
      recordUpload(_git, _record(first), push: false);
      final second = _commit('second artifact');

      expect(
        () => recordUpload(
          _git,
          _record(second),
          push: false,
          failedPushIsFatal: false,
        ),
        throwsA(isA<UploadCollisionException>()),
      );
    });
  });

  test('package:cux_ship/provenance.dart exports these names and no others', () {
    // That library's header argues itself an exception to `read-api.md`'s
    // "reads only", and the argument covers exactly this: one function that
    // writes a tag, the types in its signature and its failures, and the
    // lookup for the commit to hand it. `read-api.md` also says a surface is
    // grown by "an edit somebody has to make on purpose" — this is the edit. A
    // name added to a `show` list, or an export with no `show` at all, widens
    // what the exception has to defend and fails here until someone says so.
    final library = [
      'lib/provenance.dart',
      'cux_ship/lib/provenance.dart',
    ].map(File.new).firstWhere((file) => file.existsSync());
    // Comments dropped first, because the header quotes an `import` line and
    // prose with semicolons in it.
    final code = library
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    final exports = RegExp(r'export [^;]*;').allMatches(code).toList();
    final shown = RegExp(
      r'export [^;]*?\sshow\s([^;]*);',
    ).allMatches(code).toList();
    expect(exports, isNotEmpty);
    expect(
      shown.length,
      exports.length,
      reason: 'an export without `show` hands out the whole library',
    );
    expect(
      {
        for (final clause in shown)
          ...clause.group(1)!.split(',').map((name) => name.trim()),
      },
      {
        'Git',
        'ReleaseException',
        'UploadCollisionException',
        'UploadRecord',
        'UploadRecordResult',
        'recordUpload',
        'taggedCommit',
        'uploadCollisionExit',
      },
    );
  });
}
