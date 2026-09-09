// SPDX-License-Identifier: Apache-2.0
//
// Re-running an upload for a versionCode Play already holds is a no-op, not a
// 403.
//
// The App Store half of this claim is `test/appstore/upload_reuse_test.dart`,
// and the two are deliberately separate files rather than one parameterised
// over a store. **What the check costs is not the same on each side**, which
// is the thing a shared suite would flatten: Play has an edit transaction, so
// a run that gets this wrong discards everything and publishes nothing, while
// App Store Connect has none and every write lands as it is made. Here the
// failure is a 403 that ends a release; there it is a half-applied one.
//
// **The behaviour is old; being able to see it is not.** `runPlay` built its
// `AndroidPublisherApi` at the point of use from the service-account
// credential, so this branch was reachable only by uploading to Play — the
// guard has been correct and unexercised since it was written.
// `androidPublisher` is the seam that closes that.
//
// Why it is load-bearing rather than a convenience, in the words of the
// comment it guards: `main` publishes every commit to the internal track, so
// tagging a commit that is already on main asks Play for a number it has, and
// the tagged release would die on an artifact Play is already holding. A
// consumer pipelining its release train so builds overlap uploads makes a
// partly-published release the design rather than the accident, and the retry
// then has to be the same command typed again.
import 'dart:io';

import 'package:cux_ship/src/play/cli.dart';
// `Media` and `UploadOptions` arrive through this export rather than from
// `_discoveryapis_commons` directly — that package is private to googleapis
// and naming it here would be reaching around the API this code uses.
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:test/test.dart';

/// Canned `androidpublisher`, narrowed to the five calls an upload makes.
///
/// **`bundles.list` answers for the app rather than for this edit, because
/// that is what the tested branch depends on.** The real endpoint lists every
/// bundle the app has, including ones committed by earlier edits — which is
/// the only reason the check works across runs at all. A fake that returned
/// only what *this* edit had received would report every re-run as a fresh
/// upload, so the reuse branch would be unreachable and the case below could
/// not fail.
///
/// It records `bundles.upload` rather than refusing it, so "did not upload"
/// is observed rather than inferred from the absence of a crash.
class _FakeApi implements AndroidPublisherApi {
  _FakeApi({this.bundles = const []});

  /// What Play already holds for this app.
  final List<Bundle> bundles;

  /// Every call, in order.
  final List<String> calls = <String>[];

  /// The tracks written, so a test can say which versionCode was assigned.
  final List<Track> assigned = <Track>[];

  @override
  EditsResource get edits => _FakeEdits(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEdits implements EditsResource {
  _FakeEdits(this.api);

  final _FakeApi api;

  @override
  EditsTracksResource get tracks => _FakeTracks(api);

  @override
  EditsBundlesResource get bundles => _FakeBundles(api);

  @override
  Future<AppEdit> insert(
    AppEdit request,
    String packageName, {
    String? $fields,
  }) async {
    api.calls.add('insert');
    return AppEdit(id: 'edit-1');
  }

  @override
  Future<void> delete(
    String packageName,
    String editId, {
    String? $fields,
  }) async {
    api.calls.add('delete');
  }

  @override
  Future<AppEdit> commit(
    String packageName,
    String editId, {
    bool? changesNotSentForReview,
    String? $fields,
  }) async {
    api.calls.add('commit');
    return AppEdit(id: editId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBundles implements EditsBundlesResource {
  _FakeBundles(this.api);

  final _FakeApi api;

  @override
  Future<BundlesListResponse> list(
    String packageName,
    String editId, {
    String? $fields,
  }) async {
    api.calls.add('bundles.list');
    // **Absent rather than empty when there is nothing**, because the field is
    // nullable in the generated model and the code guards it with `?? <Bundle>[]`
    // — so a fake that always sent a list would leave that guard unreachable
    // and the "app with nothing on it" case would prove only that an empty
    // list works, which was never in doubt.
    return BundlesListResponse(
      bundles: api.bundles.isEmpty ? null : api.bundles,
    );
  }

  @override
  Future<Bundle> upload(
    String packageName,
    String editId, {
    bool? ackBundleInstallationWarning,
    String? deviceTierConfigId,
    String? $fields,
    UploadOptions uploadOptions = UploadOptions.defaultOptions,
    Media? uploadMedia,
  }) async {
    api.calls.add('bundles.upload');
    // What Play reports back is what it read out of the bundle, so the fake
    // answers with the number the test's .aab is standing in for. The
    // mismatch guard downstream compares this against --build-number, and a
    // fake that echoed something else would be testing that guard instead of
    // this one.
    return Bundle(versionCode: 2132);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTracks implements EditsTracksResource {
  _FakeTracks(this.api);

  final _FakeApi api;

  @override
  Future<Track> update(
    Track request,
    String packageName,
    String editId,
    String track, {
    String? $fields,
  }) async {
    api.calls.add('tracks.update');
    api.assigned.add(request);
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures what a command printed. `play_tracks_edit_test.dart`'s neighbour
/// shape, and the same one the App Store reuse suite uses.
class _MemoryStdout implements Stdout {
  final buffer = StringBuffer();

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void write(Object? object) => buffer.write(object);

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> _printed(Future<void> Function() body) async {
  final captured = _MemoryStdout();
  await IOOverrides.runZoned(body, stdout: () => captured);
  await captured.close();
  return captured.buffer.toString();
}

void main() {
  late File aab;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('cux_ship_play_reuse');
    addTearDown(() => dir.deleteSync(recursive: true));
    aab = File('${dir.path}/app.aab')..writeAsStringSync('not really an aab');
  });

  /// One `play upload --aab`, against [api].
  ///
  /// **Not `--dry-run`.** Play's dry run does every step and discards the edit
  /// rather than committing it, so the bundle upload happens either way — the
  /// flag would change what is *kept*, not what is called, and this suite is
  /// about what is called. Committing against a fake costs nothing and keeps
  /// the run the one an operator makes.
  Future<String> upload(_FakeApi api) {
    final args = buildPlayParser(PlayCommand.upload).parse([
      '--package',
      'design.codeux.example',
      '--aab',
      aab.path,
      '--build-number',
      '2132',
      '--version-name',
      '1.0.0',
      '--track',
      'internal',
    ]);
    return _printed(
      () => runPlay(PlayCommand.upload, args, androidPublisher: api),
    );
  }

  test('a versionCode Play already holds is reused, not re-uploaded', () async {
    final api = _FakeApi(bundles: [Bundle(versionCode: 2132)]);

    final output = await upload(api);

    expect(
      output,
      contains(
        '==> Play already holds versionCode 2132 — reusing that bundle rather '
        'than re-uploading',
      ),
    );
    // The load-bearing half: the line above is a claim about what did not
    // happen, and only the call log can say whether it is true.
    expect(api.calls, isNot(contains('bundles.upload')));
    expect(api.calls, ['insert', 'bundles.list', 'tracks.update', 'commit']);
  });

  test('the reused bundle is the one the track is pointed at', () async {
    // Skipping the upload is only half the job. A run that skipped it and then
    // assigned nothing — or assigned the wrong number — would print the same
    // line and publish nothing, which is the worse failure of the two because
    // it reports success.
    final api = _FakeApi(bundles: [Bundle(versionCode: 2132)]);

    await upload(api);

    expect(api.assigned.single.releases!.single.versionCodes, ['2132']);
    expect(api.assigned.single.releases!.single.name, '1.0.0 (2132)');
  });

  test('a versionCode Play does not hold is uploaded', () async {
    // The negative case, and the reason the fake is asked for a *list*. Play
    // holding some bundle is not Play holding this one, and a check that
    // answered the first question would skip every upload after the first.
    final api = _FakeApi(bundles: [Bundle(versionCode: 2131)]);

    final output = await upload(api);

    expect(output, contains('==> Play accepted versionCode 2132'));
    expect(api.calls, contains('bundles.upload'));
    expect(output, isNot(contains('already holds versionCode')));
  });

  test('data-safety refuses a supplied client rather than ignoring it', () {
    // **The seam does not reach this command**, because it posts through a
    // plain authenticated client instead of the generated API — so a fake
    // passed here would be dropped and the run would authenticate for real.
    //
    // The first version left that to reveal itself: with no credentials the
    // run fails, loudly. That reasoning describes CI, not the machine where
    // somebody iterates on a test, which often has the service-account
    // variable exported or is inside a `secrets exec` shell. There the run
    // would send a real declaration, and Play files every send as a pending
    // "App content → Data safety" change whether or not an answer moved —
    // the accumulation 4.0.0 cut this command out of the upload to stop.
    //
    // Synchronous on purpose: it must throw before anything is awaited, so
    // there is no window in which a credential could be loaded.
    final args = buildPlayParser(
      PlayCommand.dataSafety,
    ).parse(['--package', 'design.codeux.example', '--csv', 'nonexistent.csv']);

    expect(
      () => runPlay(PlayCommand.dataSafety, args, androidPublisher: _FakeApi()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('cannot take an androidPublisher'),
        ),
      ),
    );
  });

  test('an app with no bundles at all is uploaded', () async {
    // The listing comes back with the field *absent*, which is what
    // `?? <Bundle>[]` stands between and a null dereference. The run it would
    // happen on is a first-ever release — the one nobody gets to retry,
    // because there is nothing on the app to retry against.
    final api = _FakeApi();

    final output = await upload(api);

    expect(output, contains('==> Play accepted versionCode 2132'));
    expect(api.calls, contains('bundles.upload'));
  });
}
