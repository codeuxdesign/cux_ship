// The first tests in this package that need a repository, because this is the
// first thing in it that writes one. They build a real one in a temporary
// directory and let `cux_ship` do the writing, which is the point: the
// behaviour under test is the *join* — which commit the record lands on, what
// the tag is called, what the body says and which failures are tolerable —
// rather than git plumbing already covered in `cux_ship/test/provenance_test`.
import 'dart:io';

import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

late Directory _root;
late Git _git;

String _commit(String message) {
  File('${_root.path}/file.txt').writeAsStringSync(message);
  _git.run(['add', '-A']);
  _git.run(['commit', '-q', '-m', message]);
  return _git.run(['rev-parse', 'HEAD']);
}

/// The `uploaded/` tag `cux_ship` writes at upload, which is where the commit
/// for every promotion of that build comes from.
void _uploaded(String commit, {String tag = 'uploaded/v1.9.13+2196'}) {
  _git.run(['tag', '-a', tag, commit, '-m', 'build 2196 of 1.9.13']);
}

PromotionRecord _record({
  String destination = 'huawei',
  Stage stage = Stage.production,
  PromotionOutcome outcome = PromotionOutcome.handedOver,
}) => PromotionRecord(
  destination: destination,
  stage: stage,
  version: '1.9.13',
  build: 2196,
  outcome: outcome,
);

String _body(String tag) => _git.run(['tag', '-l', '-n99', tag]);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_train_record_writer');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('records at the commit the build was made from, not at HEAD', () {
    // The failure this prevents is the one `UploadRecord.commit` describes: a
    // version bump lands, review adds more commits, and the release is built
    // from the branch tip. Anything that finds a commit by looking for the
    // version names code predating every one of those later fixes.
    final built = _commit('what build 2196 was made from');
    _uploaded(built);
    _commit('review feedback, after the build');

    writePromotion(
      git: _git,
      record: _record(),
      uploadedTag: 'uploaded/v1.9.13+2196',
      push: false,
    );

    expect(
      _git.run([
        'rev-parse',
        'refs/tags/promoted/huawei/production/v1.9.13+2196^{commit}',
      ]),
      built,
    );
  });

  test('a family:member destination records under a path, and reads back', () {
    // `git check-ref-format` refuses a colon, so `appstore:ios` travels as
    // `appstore/ios`. The round trip is what makes that safe rather than lossy.
    final built = _commit('built');
    _uploaded(built);

    writePromotion(
      git: _git,
      record: _record(destination: 'appstore:ios'),
      uploadedTag: 'uploaded/v1.9.13+2196',
      push: false,
    );

    final written = _git.run([
      'tag',
      '-l',
      'promoted/appstore/ios/production/*',
    ]);
    expect(written, 'promoted/appstore/ios/production/v1.9.13+2196');
    expect(
      PromotionRecord.parse(written, source: 'the repository').destination,
      'appstore:ios',
    );
  });

  test('the tag body says what the name cannot', () {
    final built = _commit('built');
    _uploaded(built);

    writePromotion(
      git: _git,
      record: _record(destination: 'appstore:ios'),
      uploadedTag: 'uploaded/v1.9.13+2196',
      push: false,
    );

    final body = _body('promoted/appstore/ios/production/v1.9.13+2196');
    expect(body, contains('build 2196 of 1.9.13'));
    expect(
      body,
      contains('appstore:ios production'),
      reason:
          'the colon spelling survives in the body, where a person reads it',
    );
    expect(body, contains('handed over'));
  });

  test('a refusal is recorded under its own namespace, with the reason', () {
    final built = _commit('built');
    _uploaded(built);

    writePromotion(
      git: _git,
      record: _record(outcome: PromotionOutcome.attemptedAndRefused),
      uploadedTag: 'uploaded/v1.9.13+2196',
      note: 'console rejected the APK: 32-bit libs missing',
      push: false,
    );

    expect(
      _git.run(['tag', '-l', 'refused/*']),
      'refused/huawei/production/v1.9.13+2196',
    );
    expect(
      _git.run(['tag', '-l', 'promoted/*']),
      isEmpty,
      reason:
          'a refusal under promoted/ would be counted as a promotion by '
          'anything that globs and does not parse',
    );
    expect(
      _body('refused/huawei/production/v1.9.13+2196'),
      allOf(
        contains('32-bit libs missing'),
        contains('attempted and refused'),
        isNot(contains('handed over')),
      ),
      reason:
          'the body states the outcome too — the namespace is what a glob '
          'sees, and this is what a person reading the tag sees',
    );
  });

  test('refuses to record a refusal with no reason', () {
    // §6.1 gives the operator `s` as well as `f`. An unexplained refusal is a
    // permanent, pushed tag saying no more than leaving the cell unrecorded
    // already says — and the step it describes is one only a person can repeat.
    final built = _commit('built');
    _uploaded(built);

    expect(
      () => writePromotion(
        git: _git,
        record: _record(outcome: PromotionOutcome.attemptedAndRefused),
        uploadedTag: 'uploaded/v1.9.13+2196',
        push: false,
      ),
      throwsA(isA<PromotionWriteException>()),
    );
    expect(
      _git.run(['tag', '-l', 'refused/*', 'promoted/*']),
      isEmpty,
      reason: 'the refusal is checked before anything is written',
    );
  });

  test('whitespace is not a reason', () {
    final built = _commit('built');
    _uploaded(built);

    expect(
      () => writePromotion(
        git: _git,
        record: _record(outcome: PromotionOutcome.attemptedAndRefused),
        uploadedTag: 'uploaded/v1.9.13+2196',
        note: '   \n  ',
        push: false,
      ),
      throwsA(isA<PromotionWriteException>()),
    );
  });

  test('a reason starting with # is still a reason', () {
    // An issue number is the likeliest first word of a refusal's reason, and
    // git's default message cleanup deletes any line starting with `#`. The
    // check above would pass and the tag would say nothing — the unexplained
    // refusal this file refuses to write, written anyway.
    final built = _commit('built');
    _uploaded(built);

    writePromotion(
      git: _git,
      record: _record(outcome: PromotionOutcome.attemptedAndRefused),
      uploadedTag: 'uploaded/v1.9.13+2196',
      note: '#418: console rejects the 32-bit libs',
      push: false,
    );

    expect(
      _body('refused/huawei/production/v1.9.13+2196'),
      contains('#418: console rejects the 32-bit libs'),
    );
  });

  test('a hand-over needs no reason, and may still carry one', () {
    final built = _commit('built');
    _uploaded(built);

    writePromotion(
      git: _git,
      record: _record(),
      uploadedTag: 'uploaded/v1.9.13+2196',
      note: 'submitted for review, 24h quoted',
      push: false,
    );

    expect(
      _body('promoted/huawei/production/v1.9.13+2196'),
      contains('24h quoted'),
    );
  });

  test('refuses when the build has no uploaded tag here', () {
    // The checkout is shallow, or the tags were never fetched, or the build
    // never happened. All three are the same answer: there is no commit to
    // record against, and guessing one is the failure above.
    _commit('built');

    expect(
      () => writePromotion(
        git: _git,
        record: _record(),
        uploadedTag: 'uploaded/v1.9.13+2196',
        push: false,
      ),
      throwsA(
        isA<PromotionWriteException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('uploaded/v1.9.13+2196'), contains('git fetch')),
        ),
      ),
    );
  });

  test('the uploaded tag name is the callers, not this packages', () {
    // `tag.upload.format` is configurable in `.cux-ship.yaml`, so composing
    // the name here would send a consumer that changed it looking for a tag
    // nobody writes.
    final built = _commit('built');
    _uploaded(built, tag: 'shipped-1.9.13-2196');

    writePromotion(
      git: _git,
      record: _record(),
      uploadedTag: 'shipped-1.9.13-2196',
      push: false,
    );

    expect(
      _git.run([
        'rev-parse',
        'refs/tags/promoted/huawei/production/v1.9.13+2196^{commit}',
      ]),
      built,
    );
  });

  test('re-recording the same promotion is ordinary', () {
    // A resumed run reaches a console the operator already finished. Stopping
    // there would make the resume useless.
    final built = _commit('built');
    _uploaded(built);

    writePromotion(
      git: _git,
      record: _record(),
      uploadedTag: 'uploaded/v1.9.13+2196',
      push: false,
    );
    final again = writePromotion(
      git: _git,
      record: _record(),
      uploadedTag: 'uploaded/v1.9.13+2196',
      push: false,
    );

    expect(again, UploadRecordResult.alreadyRecorded);
  });

  test('a push it cannot make is reported rather than thrown', () {
    // The operator has already pressed the button in the console. Failing here
    // does not un-promote anything; it costs them the step and sends the next
    // run back to the same console.
    final built = _commit('built');
    _uploaded(built);
    _git.run(['remote', 'add', 'origin', '${_root.path}/no-such-remote']);

    final result = writePromotion(
      git: _git,
      record: _record(),
      uploadedTag: 'uploaded/v1.9.13+2196',
    );

    expect(result, UploadRecordResult.writtenNotPushed);
    expect(
      _git.run(['tag', '-l', 'promoted/*']),
      'promoted/huawei/production/v1.9.13+2196',
      reason: 'and the tag is here, so the resumed run on this machine sees it',
    );
  });

  test('a dry run writes nothing', () {
    final built = _commit('built');
    _uploaded(built);

    final result = writePromotion(
      git: _git,
      record: _record(),
      uploadedTag: 'uploaded/v1.9.13+2196',
      dryRun: true,
    );

    expect(result, UploadRecordResult.created, reason: 'meaning *would* be');
    expect(_git.run(['tag', '-l', 'promoted/*']), isEmpty);
  });

  test('refuses when the name already names another commit', () {
    // Inherited from `recordUpload` rather than written here, and tested here
    // because this is the call that has to keep passing it through.
    final built = _commit('built');
    _uploaded(built);
    writePromotion(
      git: _git,
      record: _record(),
      uploadedTag: 'uploaded/v1.9.13+2196',
      push: false,
    );

    final other = _commit('a different commit');
    _uploaded(other, tag: 'uploaded/other');

    expect(
      () => writePromotion(
        git: _git,
        record: _record(),
        uploadedTag: 'uploaded/other',
        push: false,
      ),
      throwsA(isA<UploadCollisionException>()),
    );
  });
}
