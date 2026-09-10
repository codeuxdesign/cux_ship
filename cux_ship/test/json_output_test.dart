// SPDX-License-Identifier: Apache-2.0
//
// The documents `--json` prints, and the one guard among them.
//
// **Most of this file is shape rather than behaviour**, and that is deliberate:
// docs/design/json-output.md says the models are the field list and that what
// a document promises is its envelope, its nesting and which stream it goes
// to. A key set held in a test is what makes growing the surface an edit
// somebody has to make on purpose — `read_api_test.dart` holds the export
// names for the same reason.
//
// The guard is stdout purity. Under `--json`, stdout carries the document and
// nothing else, and the line that would otherwise land there is the one
// naming the app. That is the test observed failing with the branch removed.
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:cux_ship/src/appstore/reads.dart';
import 'package:cux_ship/src/documents.dart';
import 'package:cux_ship/src/json_output.dart';
import 'package:cux_ship/src/play/cli.dart';
import 'package:cux_ship/src/play/reads.dart';
import 'package:googleapis/androidpublisher/v3.dart';
import 'package:test/test.dart';

/// A build resource as Apple sends one.
///
/// [platform] is not part of the payload — Apple filters on
/// `preReleaseVersion.platform` server-side and does not echo it back. The
/// fake carries it so it can filter the way the real endpoint does.
Map<String, dynamic> _build(
  String version, {
  String? state = 'VALID',
  bool expired = false,
  String? uploaded = '2026-09-04T09:12:33-07:00',
  String platform = 'IOS',
}) => {
  'type': 'builds',
  'id': 'build-$platform-$version',
  '_platform': platform,
  'attributes': {
    'version': version,
    'processingState': state,
    'expired': expired,
    'uploadedDate': uploaded,
  },
};

Map<String, dynamic> _version(
  String versionString, {
  String state = 'READY_FOR_SALE',
  String? copyright = '2026 Example',
}) => {
  'type': 'appStoreVersions',
  'id': 'version-$versionString',
  'attributes': {
    'versionString': versionString,
    'appStoreState': state,
    'releaseType': 'MANUAL',
    'copyright': copyright,
  },
};

/// Canned App Store Connect, narrowed to the two reads `appstore builds`
/// makes: resolving the app, and listing its builds.
///
/// **It filters by platform, because the listing selects on it.** iOS and
/// macOS builds of one commit carry the same build number, so a fake that
/// returned its whole list regardless would let a dropped platform filter pass
/// — the trap `AppStore._platformFilter` exists for, and the one
/// `upload_reuse_test.dart`'s fake carries for the same reason.
class _FakeClient implements AscClient {
  _FakeClient(this.builds);

  final List<Map<String, dynamic>> builds;

  @override
  void close() {}

  @override
  AscCredentials get credentials => AscCredentials(
    keyId: 'FAKEKEYID',
    issuerId: 'fake-issuer',
    privateKeyPem:
        'NOT A KEY — this fake never signs, because no path in '
        'json_output_test.dart reaches AscClient.bearerToken. If you are '
        'reading this in a signing error, one now does.',
  );

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/v1/apps') {
      return [
        {
          'type': 'apps',
          'id': 'app-1',
          'attributes': {
            'name': 'Example',
            'bundleId': query?['filter[bundleId]'],
          },
        },
      ];
    }
    expect(path, '/v1/builds');
    final platform = query?['filter[preReleaseVersion.platform]'];
    return builds
        .where((b) => platform == null || b['_platform'] == platform)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Canned Play, narrowed to the four calls a tracks read makes.
///
/// **`bundles.list` answers for the app rather than for this edit**, which is
/// what `play_upload_reuse_test.dart`'s fake carries for the same reason and
/// what a live edit was observed doing: an edit opened today lists a bundle
/// uploaded days earlier. A fake scoping it to the edit would report an empty
/// `uploadedVersionCodes` and the trailing display line would go untested.
class _FakePlay implements AndroidPublisherApi {
  @override
  EditsResource get edits => _FakePlayEdits();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayEdits implements EditsResource {
  @override
  EditsTracksResource get tracks => _FakePlayTracks();

  @override
  EditsBundlesResource get bundles => _FakePlayBundles();

  @override
  Future<AppEdit> insert(
    AppEdit request,
    String packageName, {
    String? $fields,
  }) async => AppEdit(id: 'edit-1');

  @override
  Future<void> delete(
    String packageName,
    String editId, {
    String? $fields,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayTracks implements EditsTracksResource {
  @override
  Future<TracksListResponse> list(
    String packageName,
    String editId, {
    String? $fields,
  }) async => TracksListResponse(
    tracks: [
      Track(
        track: 'internal',
        releases: [
          TrackRelease(
            name: '1.4.0',
            versionCodes: ['152'],
            status: 'completed',
          ),
        ],
      ),
    ],
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlayBundles implements EditsBundlesResource {
  @override
  Future<BundlesListResponse> list(
    String packageName,
    String editId, {
    String? $fields,
  }) async => BundlesListResponse(bundles: [Bundle(versionCode: 152)]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Captures a stream. `build_listing_test.dart`'s shape.
class _Memory implements Stdout {
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

/// Runs [body] with both streams captured separately.
///
/// Both, and not just stdout, because the claim under test is about *which*
/// one a line reached. A harness that only captured stdout could tell that the
/// banner was absent from it and could not tell that it had been printed at
/// all — absence and misdirection look identical from there.
Future<({String out, String err})> _streams(
  Future<void> Function() body,
) async {
  final out = _Memory();
  final err = _Memory();
  await IOOverrides.runZoned(body, stdout: () => out, stderr: () => err);
  await out.close();
  await err.close();
  return (out: out.buffer.toString(), err: err.buffer.toString());
}

void main() {
  // **The documents as JSON, which is what this file is about.** The builders
  // return the typed classes in `documents.dart` now; the claims here are
  // about the *document* — its keys, its nesting, what survives an encode —
  // so each one goes through `toJson` rather than reading a field back off the
  // object that just set it. `documents_test.dart` is the other half, and
  // tests the classes as a caller meets them.
  Map<String, dynamic> appStoreBuildsJson(
    AppStoreBuilds listing, {
    required String bundleId,
  }) => appStoreBuildsDocument(listing, bundleId: bundleId).toJson();

  Map<String, dynamic> appStoreVersionsJson(
    AppStoreVersions listing, {
    required String bundleId,
  }) => appStoreVersionsDocument(listing, bundleId: bundleId).toJson();

  Map<String, dynamic> playTracksJson(PlayTracks tracks) =>
      playTracksDocument(tracks).toJson();

  AppStoreBuilds buildsOf(List<Map<String, dynamic>> payload) =>
      appStoreBuildsFrom(payload, AscPlatform.ios);

  AppStoreVersions versionsOf(List<Map<String, dynamic>> payload) =>
      appStoreVersionsFrom(payload, AscPlatform.ios);

  PlayTracks tracksOf() => const PlayTracks(
    packageName: 'design.codeux.example',
    tracks: [
      PlayTrack(
        name: 'internal',
        releases: [
          // Play sends no `userFraction` for a completed rollout, which is
          // what makes `audienceFraction` more than a rename of it.
          PlayTrackRelease(
            name: '1.4.0',
            versionCodes: [152],
            status: 'completed',
            userFraction: null,
          ),
          PlayTrackRelease(
            name: '1.3.0',
            versionCodes: [151],
            status: 'halted',
            userFraction: 0.2,
          ),
        ],
      ),
    ],
    uploadedVersionCodes: [151, 152],
  );

  group('the envelope', () {
    test('declares a schema and a kind, and the kind names the counter', () {
      final document = appStoreBuildsJson(
        buildsOf([_build('169')]),
        bundleId: 'design.codeux.example',
      );

      expect(document['schema'], appStoreBuildsSchema);
      expect(document['kind'], 'appstore.builds');
    });

    test('and the three kinds version independently', () {
      // Not that the numbers differ — they are all 1 today — but that there
      // are three of them. One shared constant is the arrangement where a
      // change to tracks bumps the number builds declares.
      final builds = appStoreBuildsJson(buildsOf(const []), bundleId: 'x');
      final versions = appStoreVersionsJson(
        versionsOf(const []),
        bundleId: 'x',
      );
      final tracks = playTracksJson(tracksOf());

      expect(builds['kind'], isNot(versions['kind']));
      expect(versions['kind'], isNot(tracks['kind']));
    });

    test('carries exactly these keys, so growing it is on purpose', () {
      // The list is here rather than in prose for the reason read_api_test
      // holds the export names: a document nobody decided to widen should not
      // widen.
      expect(
        appStoreBuildsJson(
          buildsOf([_build('169')]),
          bundleId: 'x',
        ).keys.toSet(),
        {
          'schema',
          'kind',
          'platform',
          'bundleId',
          'newestBuildNumber',
          'newestBuildNumberAsInt',
          'builds',
          'display',
        },
      );
      expect(
        ((appStoreBuildsJson(buildsOf([_build('169')]), bundleId: 'x')['builds']
                        as List)
                    .single
                as Map)
            .keys
            .toSet(),
        {
          'buildNumber',
          'buildNumberAsInt',
          'processingState',
          'processingStateRaw',
          'uploadedDate',
          'expired',
          'usable',
          'needsNewUpload',
          'display',
        },
      );
    });

    test('and so does an App Store version, which had none either', () {
      expect(
        ((appStoreVersionsJson(
                          versionsOf([_version('1.4.0')]),
                          bundleId: 'x',
                        )['versions']
                        as List)
                    .single
                as Map)
            .keys
            .toSet(),
        {
          'versionString',
          'appStoreState',
          'appStoreStateRaw',
          'releaseType',
          'releaseTypeRaw',
          'copyright',
          'editable',
          'buildNumber',
          'buildNumberAsInt',
          'display',
        },
      );
    });

    test('and so does a Play release, which had no such list', () {
      // **Added when the rollout fraction widened this entry**, which is when
      // its absence showed: the App Store side has held its keys since
      // `--json` shipped and the Play side did not, so `play.tracks` could
      // grow a key with nothing to make that a decision. Two fields arrived at
      // once here, which is exactly the change this shape is meant to make
      // somebody type out.
      expect(
        ((((playTracksJson(tracksOf())['tracks'] as List).single
                            as Map)['releases']
                        as List)
                    .first
                as Map)
            .keys
            .toSet(),
        {
          'name',
          'status',
          'statusRaw',
          'versionCodes',
          'newestVersionCode',
          'serving',
          'userFraction',
          'audienceFraction',
          'display',
        },
      );
    });
  });

  group('display', () {
    test('is a list of strings at both levels, for every kind', () {
      final documents = <Map<String, Object?>>[
        appStoreBuildsJson(buildsOf([_build('169')]), bundleId: 'x'),
        appStoreVersionsJson(versionsOf([_version('1.4.0')]), bundleId: 'x'),
        playTracksJson(tracksOf()),
      ];

      for (final document in documents) {
        expect(document['display'], isA<List<String>>());
      }
      // And the item level, which is the half that would have been a String
      // under the shape this replaced.
      final build = ((documents[0]['builds'] as List).single as Map)['display'];
      final version =
          ((documents[1]['versions'] as List).single as Map)['display'];
      final track = ((documents[2]['tracks'] as List).single as Map)['display'];
      expect(build, isA<List<String>>());
      expect(version, isA<List<String>>());
      expect(track, isA<List<String>>());
    });

    test('gives a version two entries, which a string could not', () {
      // A version renders its state and its copyright on separate lines. This
      // is the case that makes the uniform array load-bearing rather than
      // tidy: collapsing it to a string forces a join here and a split in the
      // caller, which is parsing `display`.
      final document = appStoreVersionsJson(
        versionsOf([_version('1.4.0')]),
        bundleId: 'x',
      );

      final display =
          ((document['versions'] as List).single as Map)['display'] as List;
      expect(display, hasLength(2));
      expect(display.first, contains('1.4.0'));
      expect(display.last, contains('copyright'));
    });

    test('is one entry per release, so a halted rollout is its own line', () {
      final document = playTracksJson(tracksOf());

      final track = (document['tracks'] as List).single as Map;
      expect(track['display'], hasLength(2));
      expect(track['releases'] as List, hasLength(2));
      for (final release in track['releases'] as List) {
        expect((release as Map)['display'], hasLength(1));
      }
    });

    test("is not the document's items concatenated — builds are capped", () {
      // `AppStoreBuilds.lines` renders twenty at most and `builds` carries
      // everything. A consumer deriving one from the other is wrong here in
      // one direction and wrong on the Play side in the other.
      final document = appStoreBuildsJson(
        buildsOf([
          for (var i = 0; i < 21; i++) ...[_build('${100 + i}')],
        ]),
        bundleId: 'x',
      );

      expect(document['builds'] as List, hasLength(21));
      expect(document['display'] as List, hasLength(20));
    });

    test('and is never empty, because a silent store reads as a fine one', () {
      // **The dangerous half of "not the items concatenated".** Deriving a
      // document's `display` from its items' is correct for every non-empty
      // document and yields an empty array exactly when that array is the only
      // thing carrying meaning: `lines` answers the empty case with a
      // sentence, and the items answer it with nothing at all. A store nothing
      // has ever been uploaded to and a store the reader forgot to render then
      // look identical — absence and failure again.
      //
      // Raised by the consumer, which routes its empty case through `lines`
      // for exactly this reason and has two branches instead of one.
      final builds = appStoreBuildsJson(buildsOf(const []), bundleId: 'x');
      final versions = appStoreVersionsJson(
        versionsOf(const []),
        bundleId: 'x',
      );
      final tracks = playTracksJson(
        const PlayTracks(
          packageName: 'design.codeux.example',
          tracks: [],
          uploadedVersionCodes: [],
        ),
      );

      expect(builds['builds'], isEmpty);
      expect(builds['display'], hasLength(1));
      expect(
        (builds['display'] as List).single,
        contains('nothing has ever been uploaded'),
      );

      expect(versions['versions'], isEmpty);
      expect(versions['display'], hasLength(1));
      expect(
        (versions['display'] as List).single,
        contains('no App Store versions'),
      );

      expect(tracks['tracks'], isEmpty);
      expect(tracks['display'], isNotEmpty);
    });

    test('and `serving` answers the question Play only spells', () {
      // **The derivation, driven from real statuses.** This is the one place
      // it can be tested: `documents_test.dart`'s fixtures supply the field,
      // so a check there would assert the decoder read what the fixture wrote.
      //
      // It is computed by the encoder rather than offered as a Dart getter so
      // a shell caller gets it too, which is the argument the App Store side's
      // `usable` and `editable` already carry.
      PlayTracks trackWith(String? status) => PlayTracks(
        packageName: 'design.codeux.example',
        tracks: [
          PlayTrack(
            name: 'internal',
            releases: [
              PlayTrackRelease(
                name: '1.4.0',
                versionCodes: const [152],
                status: status,
                userFraction: null,
              ),
            ],
          ),
        ],
        uploadedVersionCodes: const [152],
      );

      bool? servingFor(String? status) =>
          ((((playTracksJson(trackWith(status))['tracks'] as List).single
                              as Map)['releases']
                          as List)
                      .single
                  as Map)['serving']
              as bool?;

      expect(servingFor('completed'), isTrue);
      expect(servingFor('inProgress'), isTrue, reason: 'some of the audience');
      expect(servingFor('halted'), isFalse);
      expect(servingFor('draft'), isFalse);

      // **Null, not false, for the three ways of not being told.** A `bool`
      // would have to answer, and both answers are wrong: false reports a
      // possibly-healthy rollout as reaching nobody, true calls a state nobody
      // here names healthy. The field this is derived from is three-valued and
      // so is this one — a derived field that flattened it would be a worse
      // answer than its own input.
      //
      // `statusUnspecified` sits with the other two because Play saying
      // "unspecified" and Play saying nothing carry the same information.
      expect(servingFor('statusUnspecified'), isNull);
      expect(servingFor('somethingGoogleAdded'), isNull);
      expect(servingFor(null), isNull);

      // **And the encoder answers what the published rule answers.** The rows
      // above are the rule; this is the guarantee that the field a consumer
      // decodes and the static a consumer can call cannot drift apart. The
      // consumer's fixtures are built from the static, so if these two ever
      // disagreed their whole suite would be asserting against documents this
      // command never emits.
      for (final status in PlayReleaseStatus.values) {
        expect(
          servingFor(status.playValue),
          PlayReleaseStatus.serving(status.playValue == null ? null : status),
          reason:
              'encoder and PlayReleaseStatus.serving disagree on '
              '${status.name}',
        );
      }
    });

    test('and the review states are answered by the vocabulary, not a flag', () {
      // **The decision this pins is a removal.** An `underReview` boolean was
      // built here, argued to three drafts, and taken out: the one consumer
      // that would read it renders *five* distinct outcomes across these
      // states — not submitted, queued, in review, approved-waiting-on-a-human,
      // Apple publishing — so every boolean over them is a coarsening of what
      // it already prints rather than an answer it lacks.
      //
      // What replaced it is the four enum members, which is what that consumer
      // asked for: `IN_REVIEW` stops arriving as `unknown`, and a caller that
      // wants two of these states together says so in its own switch, where it
      // can also want three or five. docs/design/rollout-state.md carries the
      // drafts and why each died.
      AppStoreState? stateFor(String state) => AppStoreState.read(
        ((appStoreVersionsJson(
                          versionsOf([_version('1.4.0', state: state)]),
                          bundleId: 'x',
                        )['versions']
                        as List)
                    .single
                as Map)['appStoreStateRaw']
            as String?,
      );

      // The five a report distinguishes, distinguishable here.
      expect(stateFor('READY_FOR_REVIEW'), AppStoreState.readyForReview);
      expect(stateFor('WAITING_FOR_REVIEW'), AppStoreState.waitingForReview);
      expect(stateFor('IN_REVIEW'), AppStoreState.inReview);
      expect(
        stateFor('PENDING_DEVELOPER_RELEASE'),
        AppStoreState.pendingDeveloperRelease,
      );
      expect(
        stateFor('PENDING_APPLE_RELEASE'),
        AppStoreState.pendingAppleRelease,
      );

      // And the entry carries exactly one derived answer, which is the shape
      // the removal restored. The key set above is the other half of this.
      expect(
        (appStoreVersionsJson(
                      versionsOf([_version('1.4.0')]),
                      bundleId: 'x',
                    )['versions']
                    as List)
                .single
            as Map,
        isNot(contains('underReview')),
      );
    });

    test('and `audienceFraction` fills the hole Play leaves at 100%', () {
      // **Play omits `userFraction` exactly when it means one.** Google sets
      // it only for `inProgress` and `halted`, so a completed rollout carries
      // none — and a caller reading Play's own number gets `null` for the one
      // release that reached everybody. That is the case this field exists
      // for, and the one a rename of `userFraction` would not cover.
      PlayTracks trackWith(String? status, double? userFraction) => PlayTracks(
        packageName: 'design.codeux.example',
        tracks: [
          PlayTrack(
            name: 'internal',
            releases: [
              PlayTrackRelease(
                name: '1.4.0',
                versionCodes: const [152],
                status: status,
                userFraction: userFraction,
              ),
            ],
          ),
        ],
        uploadedVersionCodes: const [152],
      );

      Map<String, dynamic> releaseFor(String? status, double? userFraction) =>
          ((((playTracksJson(trackWith(status, userFraction))['tracks'] as List)
                                  .single
                              as Map)['releases']
                          as List)
                      .single
                  as Map)
              .cast<String, dynamic>();

      double? fractionFor(String? status, double? userFraction) =>
          releaseFor(status, userFraction)['audienceFraction'] as double?;

      // The two Play states, and the two it does not send a number for.
      expect(fractionFor('completed', null), 1.0);
      expect(fractionFor('draft', null), 0.0);
      expect(fractionFor('inProgress', 0.2), 0.2);
      // **A halted release keeps its fraction**, because the users who took it
      // keep the release: `serving` is false and this is non-zero, and both
      // are true at once. That pair is the whole reason this is not called
      // `rolloutFraction`.
      expect(fractionFor('halted', 0.2), 0.2);
      expect(releaseFor('halted', 0.2)['serving'], isFalse);

      // Null on the same terms as `serving`, plus one of its own: an
      // `inProgress` release Play sent no fraction for is Play contradicting
      // its own documentation, and guessing 1.0 there would report a rollout
      // that has barely started as finished.
      expect(fractionFor('statusUnspecified', null), isNull);
      expect(fractionFor('somethingGoogleAdded', null), isNull);
      expect(fractionFor(null, null), isNull);
      expect(fractionFor('inProgress', null), isNull);

      // **Play's own number travels beside ours, and they differ where it
      // matters.** A completed rollout is the case: Play said nothing, we say
      // one. A consumer that cannot tell those apart cannot tell an inference
      // from a measurement.
      expect(releaseFor('completed', null)['userFraction'], isNull);
      expect(releaseFor('inProgress', 0.2)['userFraction'], 0.2);

      // **The one claim in this design that comes from Google rather than from
      // here is `0 < fraction < 1`, and this is what happens if it is false.**
      // It is cited on `PlayReleaseStatus.audienceFraction` — googleapis'
      // dartdoc, from the discovery document — phrased as a constraint on what
      // may be *set*, and measured against no live account by this repository.
      //
      // If Play answered `1.0` for an `inProgress` release, `audienceFraction`
      // would be `1.0`: the same number this package infers for `completed`.
      // The two are still distinguishable, and **`status` is what
      // distinguishes them** — the derivation is a function of `status` and
      // `userFraction`, and the document carries both inputs, so a caller can
      // see which branch produced the number.
      expect(fractionFor('inProgress', 1.0), 1.0);
      expect(releaseFor('inProgress', 1.0)['status'], 'inProgress');
      expect(releaseFor('completed', null)['audienceFraction'], 1.0);
      expect(releaseFor('completed', null)['status'], 'completed');

      // **Not the raw field's nullness, which is the tempting answer and only
      // holds while Google's sentence holds in its *second* half** — set only
      // for `inProgress` and `halted`. Let Play set it on a `completed`
      // release and both cases read `1.0` beside `1.0`, with nullness no
      // longer separating them, while `status` still does. Pinned so the
      // weaker claim cannot come back as a simplification.
      expect(releaseFor('completed', 1.0)['userFraction'], 1.0);
      expect(releaseFor('completed', 1.0)['audienceFraction'], 1.0);
      expect(releaseFor('inProgress', 1.0)['userFraction'], 1.0);
      expect(releaseFor('inProgress', 1.0)['audienceFraction'], 1.0);

      // The common case, where nullness does tell them apart. A convenience,
      // and worth keeping true.
      expect(releaseFor('completed', null)['userFraction'], isNull);

      // The encoder and the published rule cannot drift, for the reason
      // `serving`'s own row above says: a consumer's fixtures are built from
      // the static.
      //
      // **It cannot reach `unknown`, deliberately and not usefully.**
      // `unknown.playValue` is null, so the map below turns it into the
      // absent-status case before the static sees it. The `unknown` arm is
      // pinned by `fractionFor('somethingGoogleAdded', null)` above; if that
      // expect is ever deleted this loop will keep passing while the arm goes
      // unchecked.
      for (final status in PlayReleaseStatus.values) {
        expect(
          fractionFor(status.playValue, 0.2),
          PlayReleaseStatus.audienceFraction(
            status.playValue == null ? null : status,
            userFraction: 0.2,
          ),
          reason:
              'encoder and PlayReleaseStatus.audienceFraction disagree on '
              '${status.name}',
        );
      }
    });

    test('and `needsNewUpload` reads correctly in every state, alone', () {
      // **The axis `usable` hides.** A consumer built its Apple advice on
      // `usable == false` and told an operator to wait for `VALID` in every
      // case — right for PROCESSING, and "wait forever" for FAILED and
      // INVALID, which are Apple refusing the binary and never change again.
      //
      // **Alone is the requirement, and it is what named this field.** An
      // earlier draft called it `mayBecomeUsable`, which is false for a
      // healthy `VALID` build — and false there reads as "give up" to anyone
      // who has not also read `usable` first. A pair that is only safe in one
      // reading order gets read in the other one, which is how the defect
      // above happened. So each row below is asserted for what it says on its
      // own, not for what it says next to `usable`.
      bool? needsNewUploadFor(String? state, {bool expired = false}) =>
          ((appStoreBuildsJson(
                            buildsOf([
                              _build('169', state: state, expired: expired),
                            ]),
                            bundleId: 'x',
                          )['builds']
                          as List)
                      .single
                  as Map)['needsNewUpload']
              as bool?;

      expect(needsNewUploadFor('VALID'), isFalse, reason: 'nothing to fix');
      expect(needsNewUploadFor('PROCESSING'), isFalse, reason: 'wait, do not');
      expect(needsNewUploadFor('FAILED'), isTrue, reason: 'Apple refused it');
      expect(needsNewUploadFor('INVALID'), isTrue);

      // **The row that decided the rename.** Expiry is terminal reached from a
      // healthy state, and the older phrasing gave it the same answer as a
      // healthy build — `mayBecomeUsable` was false for both `VALID` and
      // `VALID`-but-expired, flattening the one case where the operator has
      // work to do into the one where they do not.
      expect(needsNewUploadFor('VALID', expired: true), isTrue);
      expect(needsNewUploadFor('PROCESSING', expired: true), isTrue);

      // And the question an unrecognized state cannot answer.
      expect(needsNewUploadFor('SOMETHING_APPLE_ADDED'), isNull);
      expect(needsNewUploadFor(null), isNull);
    });

    test('nor on the Play side, where a trailing line belongs to no track', () {
      final document = playTracksJson(tracksOf());

      final tracks = (document['tracks'] as List)
          .expand((t) => (t as Map)['display'] as List)
          .toList();
      final display = document['display'] as List;
      expect(display, hasLength(tracks.length + 1));
      expect(display.last, contains('uploaded bundles'));
      expect(tracks.join('\n'), isNot(contains('uploaded bundles')));
    });
  });

  group('the number and the string are different questions', () {
    test('a build carries both, and the int survives JSON', () {
      final document =
          jsonDecode(
                jsonEncode(
                  appStoreBuildsJson(buildsOf([_build('169')]), bundleId: 'x'),
                ),
              )
              as Map<String, dynamic>;

      final build = (document['builds'] as List).single as Map<String, dynamic>;
      expect(build['buildNumber'], '169');
      expect(build['buildNumber'], isA<String>());
      expect(build['buildNumberAsInt'], 169);
    });

    test('and a dotted CFBundleVersion gives null rather than a guess', () {
      // Apple accepts `1.2.3`. Zero would sort it below every real build and
      // say something false about it; null says the question does not apply.
      final document = appStoreBuildsJson(
        buildsOf([_build('1.2.3')]),
        bundleId: 'x',
      );

      final build = (document['builds'] as List).single as Map;
      expect(build['buildNumber'], '1.2.3');
      expect(build['buildNumberAsInt'], isNull);
      expect(document['newestBuildNumberAsInt'], isNull);
    });

    test('newestBuildNumberAsInt answers what the string cannot be asked', () {
      // `newestBuildNumber`'s own doc comment says to compare via
      // `buildNumberAsInt` — a route only a caller holding the objects has. A
      // document carrying the string alone hands a shell caller the string
      // comparison that comment forbids.
      final document = appStoreBuildsJson(
        buildsOf([_build('9'), _build('100'), _build('10')]),
        bundleId: 'x',
      );

      expect(document['newestBuildNumber'], '100');
      expect(document['newestBuildNumberAsInt'], 100);
    });
  });

  group('stdout carries the document and nothing else', () {
    Future<({String out, String err})> builds({bool json = true}) {
      final args = buildAscParser(AscCommand.builds).parse([
        '--platform',
        'ios',
        '--bundle-id',
        'design.codeux.example',
        ...json ? const ['--json'] : const <String>[],
      ]);
      return _streams(
        () => runAsc(
          AscCommand.builds,
          args,
          ascClient: _FakeClient([_build('169')]),
        ),
      );
    }

    test('so stdout parses whole, with the app banner on stderr', () async {
      final streams = await builds();

      // Parses at all, which is the claim: one extra line on stdout and this
      // throws rather than merely reading oddly.
      final document = jsonDecode(streams.out) as Map<String, dynamic>;
      expect(document['kind'], 'appstore.builds');
      expect(document['bundleId'], 'design.codeux.example');

      expect(streams.out, isNot(contains('is app app-1')));
      expect(
        streams.err,
        contains('==> Example (design.codeux.example) is app app-1'),
      );
    });

    test(
      'and without --json that same line is on stdout, as it always was',
      () async {
        // The other half of the guard. Without it, a branch that sent the banner
        // to stderr unconditionally would pass the test above and change what
        // every existing caller sees.
        final streams = await builds(json: false);

        expect(streams.out, contains('==> Example (design.codeux.example)'));
        expect(streams.out, contains('build 169'));
        expect(streams.err, isEmpty);
      },
    );

    test('and `play tracks --json` is wired to the same writer', () async {
      // The Play half of the flag, through `runPlay` rather than through the
      // document builder — the builders are covered above, and what is
      // unproven without this is the wiring. A flag declared on a parser and
      // never read reaches nothing, and every test over the builder still
      // passes.
      final args = buildPlayParser(
        PlayCommand.tracks,
      ).parse(['--package', 'design.codeux.example', '--json']);

      final streams = await _streams(
        () => runPlay(PlayCommand.tracks, args, androidPublisher: _FakePlay()),
      );

      final document = jsonDecode(streams.out) as Map<String, dynamic>;
      expect(document['kind'], 'play.tracks');
      expect(document['packageName'], 'design.codeux.example');
      expect(document['uploadedVersionCodes'], [152]);
      // The prose rendering is inside `display` and is not loose on stdout.
      expect(streams.out.split('\n').first, '{');
    });
  });
}
