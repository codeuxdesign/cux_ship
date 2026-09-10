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
          PlayTrackRelease(
            name: '1.4.0',
            versionCodes: [152],
            status: 'completed',
          ),
          PlayTrackRelease(
            name: '1.3.0',
            versionCodes: [151],
            status: 'halted',
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
          'uploadedDate',
          'expired',
          'usable',
          'mayBecomeUsable',
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
    });

    test('and `mayBecomeUsable` separates waiting from giving up', () {
      // **The axis `usable` hides.** A consumer built its Apple advice on
      // `usable == false` and told an operator to wait for `VALID` in every
      // case — right for PROCESSING, and "wait forever" for FAILED and
      // INVALID, which are Apple refusing the binary and never change again.
      bool? mayBecomeUsableFor(String? state, {bool expired = false}) =>
          ((appStoreBuildsJson(
                            buildsOf([
                              _build('169', state: state, expired: expired),
                            ]),
                            bundleId: 'x',
                          )['builds']
                          as List)
                      .single
                  as Map)['mayBecomeUsable']
              as bool?;

      expect(mayBecomeUsableFor('PROCESSING'), isTrue);
      expect(mayBecomeUsableFor('FAILED'), isFalse, reason: 'terminal');
      expect(mayBecomeUsableFor('INVALID'), isFalse, reason: 'terminal');
      expect(mayBecomeUsableFor('VALID'), isFalse, reason: 'already settled');
      // Expiry settles it whatever processing said.
      expect(mayBecomeUsableFor('PROCESSING', expired: true), isFalse);
      // And the question an unrecognized state most plainly cannot answer.
      expect(mayBecomeUsableFor('SOMETHING_APPLE_ADDED'), isNull);
      expect(mayBecomeUsableFor(null), isNull);
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
