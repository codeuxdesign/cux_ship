// SPDX-License-Identifier: Apache-2.0
//
// `readTracks` opens a Play edit because listing tracks is impossible without
// one, and then has to put it back. Two claims about that, and the second is
// the one review caught.
//
// **The edit is deleted whether the read worked or not.** An edit left open is
// harmless — Play expires them — but it means the next person to open the
// console finds a stale draft nobody made on purpose.
//
// **And deleting it must not replace the failure that is being reported.** A
// `finally` that awaits a throwing call discards the exception already in
// flight, so a 403 from `tracks.list` — the most common Play failure there is,
// a service account that was never granted the app — would reach the operator
// as whatever the cleanup happened to fail with. The upload path has said this
// in a comment since it was written ("Losing the cleanup is not worth masking
// the original failure"); the read path had not, because when the deletion sat
// beside the catch in one function the catch ran first.
import 'package:cux_ship/src/play/reads.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:test/test.dart';

/// Canned `androidpublisher`, narrowed to the four calls a track read makes.
///
/// **It fails `delete` independently of the listings, because the tested
/// branch selects on exactly that difference.** A fake that failed both, or
/// neither, cannot tell "the original error survived cleanup" from "the
/// cleanup happened to succeed" — which is the whole question here.
class _FakeApi implements AndroidPublisherApi {
  _FakeApi({
    this.tracks = const [],
    this.bundles = const [],
    this.editId = 'edit-1',
    this.failListing,
    this.failDelete,
  });

  final List<Track> tracks;
  final List<Bundle> bundles;
  final String? editId;
  final Object? failListing;
  final Object? failDelete;

  final List<String> calls = <String>[];

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
    return AppEdit(id: api.editId);
  }

  @override
  Future<void> delete(
    String packageName,
    String editId, {
    String? $fields,
  }) async {
    api.calls.add('delete $editId');
    final failure = api.failDelete;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTracks implements EditsTracksResource {
  _FakeTracks(this.api);

  final _FakeApi api;

  @override
  Future<TracksListResponse> list(
    String packageName,
    String editId, {
    String? $fields,
  }) async {
    api.calls.add('tracks.list');
    final failure = api.failListing;
    if (failure != null) {
      throw failure;
    }
    return TracksListResponse(tracks: api.tracks);
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
    return BundlesListResponse(bundles: api.bundles);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The 403 a service account gets for an app it was never granted.
DetailedApiRequestError _forbidden() =>
    DetailedApiRequestError(403, 'The caller does not have permission');

void main() {
  const packageName = 'design.codeux.example';

  test('a successful read opens an edit and puts it back', () async {
    final api = _FakeApi(
      tracks: [
        Track(
          track: 'internal',
          releases: [
            TrackRelease(name: '1.4.0', versionCodes: ['2132']),
          ],
        ),
      ],
      bundles: [Bundle(versionCode: 2132)],
    );

    final result = await readTracks(api, packageName);

    expect(result.newestVersionCodeOn('internal'), 2132);
    expect(api.calls, [
      'insert',
      'tracks.list',
      'bundles.list',
      'delete edit-1',
    ]);
  });

  test('a failed read still puts the edit back', () async {
    // Otherwise every failed run leaves a draft in the console.
    final api = _FakeApi(failListing: _forbidden());

    await expectLater(
      readTracks(api, packageName),
      throwsA(isA<DetailedApiRequestError>()),
    );

    expect(api.calls, contains('delete edit-1'));
  });

  test(
    'and a cleanup that also fails does not replace the read failure',
    () async {
      // The regression this guards: `tracks.list` says 403 — the service account
      // was never granted this app, which is the actionable message — and the
      // delete then fails with something unrelated. Awaiting the delete bare in
      // a `finally` discards the 403 and reports the cleanup instead, sending
      // the operator to diagnose the wrong call.
      final api = _FakeApi(
        failListing: _forbidden(),
        failDelete: DetailedApiRequestError(500, 'backend error'),
      );

      await expectLater(
        readTracks(api, packageName),
        throwsA(
          isA<DetailedApiRequestError>().having((e) => e.status, 'status', 403),
        ),
      );
    },
  );

  test('a cleanup failure on its own is swallowed, not raised', () async {
    // A read that answered correctly must not fail because Play would not
    // take its edit back. Play expires an abandoned edit on its own.
    final api = _FakeApi(
      tracks: [Track(track: 'internal', releases: const [])],
      failDelete: DetailedApiRequestError(500, 'backend error'),
    );

    final result = await readTracks(api, packageName);

    expect(result.track('internal'), isNotNull);
    expect(api.calls, contains('delete edit-1'));
  });

  test(
    'an edit Play would not open is named as that, not as a null id',
    () async {
      final api = _FakeApi(editId: null);

      await expectLater(
        readTracks(api, packageName),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('did not return an edit id'),
          ),
        ),
      );
      // Nothing to delete, and nothing that pretends there was.
      expect(api.calls, ['insert']);
    },
  );
}
