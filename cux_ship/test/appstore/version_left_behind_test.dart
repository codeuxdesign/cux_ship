// SPDX-License-Identifier: Apache-2.0
//
// A promotion creates the App Store version early and submits it last, so
// every failure in between exits non-zero having already changed what App
// Store Connect holds. "Exit 1" reads as "nothing happened", and here it is
// false — which invites running the command again, and the second run then
// behaves differently from the first, because `ensureVersion` adopts the
// record rather than making a second one.
//
// So the assertions here are about a fact surviving to the failure, and about
// a dry run having no such fact to report.
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:test/test.dart';

/// Canned App Store Connect, narrowed to the version collection.
class _FakeClient implements AscClient {
  _FakeClient({this.existing = const []});

  final List<Map<String, dynamic>> existing;

  /// Honours `filter[versionString]` the way App Store Connect does, because
  /// `ensureVersion` asks twice — once for the exact name, once for every
  /// version on the platform — and takes different branches on the answers.
  /// A double that ignored the filter would send every case down the rename
  /// branch and quietly agree with whatever the code did.
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    final wanted = query?['filter[versionString]'];
    if (wanted == null) {
      return existing;
    }
    return existing
        .where((v) => (v['attributes'] as Map)['versionString'] == wanted)
        .toList();
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async => {
    'data': {'type': 'appStoreVersions', 'id': 'new-version'},
  };

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async => {
    'data': {'type': 'appStoreVersions', 'id': 'renamed-version'},
  };

  // Anything these tests do not reach throws rather than answering, so a
  // reader cannot mistake silence for a canned response.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppStore _store(AscClient client, {required bool dryRun}) => AppStore(
  client,
  Writer(client, dryRun: dryRun),
  platform: AscPlatform.macos,
);

Map<String, dynamic> _version(String versionString, String state) => {
  'type': 'appStoreVersions',
  'id': 'existing',
  'attributes': {'versionString': versionString, 'appStoreState': state},
};

void main() {
  final app = App('APP', 'Example', 'design.codeux.example');

  test(
    'creating a version is recorded, so a later failure can name it',
    () async {
      final store = _store(_FakeClient(), dryRun: false);
      expect(store.versionChange, isNull, reason: 'nothing done yet');

      await store.ensureVersion(app, '1.1.3', create: true);

      expect(store.versionChange?.change, VersionChange.created);
      expect(store.versionChange?.versionString, '1.1.3');
    },
  );

  test('adopting an editable version by renaming it is recorded too', () async {
    // The rename is equally a change that outlives a failure: the name the
    // record had before is gone.
    final store = _store(
      _FakeClient(existing: [_version('1.0.0', 'PREPARE_FOR_SUBMISSION')]),
      dryRun: false,
    );

    await store.ensureVersion(app, '1.1.3', create: true);

    expect(store.versionChange?.change, VersionChange.renamed);
    expect(store.versionChange?.versionString, '1.1.3');
  });

  test('a dry run leaves nothing behind, so it reports nothing', () async {
    // The distinction that makes the message trustworthy. A dry run that
    // claimed to have created a version would be worse than saying nothing.
    final store = _store(_FakeClient(), dryRun: true);

    await store.ensureVersion(app, '1.1.3', create: true);

    expect(store.versionChange, isNull);
  });

  test('a dry run that would rename reports nothing either', () async {
    final store = _store(
      _FakeClient(existing: [_version('1.0.0', 'PREPARE_FOR_SUBMISSION')]),
      dryRun: true,
    );

    await store.ensureVersion(app, '1.1.3', create: true);

    expect(store.versionChange, isNull);
  });

  test('a rename records the name it took away', () async {
    // The remedy for an adopted record is putting the name back, not deleting
    // it — and a message that says "renamed something to 1.1.3" without
    // saying what it was called cannot be acted on.
    final store = _store(
      _FakeClient(existing: [_version('1.0.0', 'PREPARE_FOR_SUBMISSION')]),
      dryRun: false,
    );

    await store.ensureVersion(app, '1.1.3', create: true);

    expect(store.versionChange?.previousVersionString, '1.0.0');
  });

  test('a created version has no previous name to report', () async {
    final store = _store(_FakeClient(), dryRun: false);

    await store.ensureVersion(app, '1.1.3', create: true);

    expect(store.versionChange?.previousVersionString, isNull);
  });

  test('creating a review submission is recorded too', () async {
    // The sibling, found by a run that failed at POST reviewSubmissionItems
    // and left a container in READY_FOR_REVIEW with no version in it.
    final store = _store(_FakeClient(), dryRun: false);
    expect(store.createdReviewSubmission, isNull);

    await store.submitForReview(
      app,
      _version('1.1.3', 'PREPARE_FOR_SUBMISSION'),
    );

    expect(store.createdReviewSubmission, isNotNull);
  });

  test('a dry run opens no submission, so it reports none', () async {
    final store = _store(_FakeClient(), dryRun: true);

    await store.submitForReview(
      app,
      _version('1.1.3', 'PREPARE_FOR_SUBMISSION'),
    );

    expect(store.createdReviewSubmission, isNull);
  });

  test('finding the version already there changes nothing', () async {
    // Nothing was written, so there is nothing to warn about — the record
    // existed before this run and will exist after it.
    final store = _store(
      _FakeClient(existing: [_version('1.1.3', 'PREPARE_FOR_SUBMISSION')]),
      dryRun: false,
    );

    await store.ensureVersion(app, '1.1.3', create: true);

    expect(store.versionChange, isNull);
  });
}
