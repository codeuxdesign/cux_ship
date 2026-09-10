// SPDX-License-Identifier: Apache-2.0
//
// `package:cux_ship/documents.dart` — the classes a consumer decodes `--json`
// into, and the promises their dartdoc makes on pub.dev.
//
// Three claims worth a test, and they are the three a reader of the published
// API docs would be relying on without being able to check:
//
//   - **The field names are the JSON keys.** The dartdoc is only a description
//     of the format while that holds; one `@JsonKey(name:)` and it becomes
//     merely adjacent to it, with no way for a reader to tell.
//   - **A store vocabulary degrades, and this package's own does not.** An
//     `unknown` member is the answer for a value Apple or Google added; a
//     `kind` or a `platform` nobody here names is a document from the future
//     and is refused.
//   - **Absent and unknown are different facts.** A null field is a store that
//     sent nothing; `unknown` is a store that sent something this version does
//     not name. Collapsing them is the failure this repository keeps paying
//     for in other shapes.
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/documents.dart';
import 'package:test/test.dart';

/// The source of the classes, from wherever the suite is run.
///
/// Throwing rather than skipping: a rule about what the source may not contain
/// is worth nothing from a test that cannot find the source.
File _documentsSource() {
  for (final path in [
    'lib/src/documents.dart',
    'cux_ship/lib/src/documents.dart',
  ]) {
    final file = File(path);
    if (file.existsSync()) {
      return file;
    }
  }
  throw StateError(
    'cannot find lib/src/documents.dart from ${Directory.current.path} — and '
    'a rule about its contents would pass by default',
  );
}

/// [processingState] is *this package's* spelling and [processingStateRaw] is
/// Apple's — the two are different fields on purpose, and a fixture that let
/// them drift would be testing a document nothing produces.
Map<String, dynamic> _buildsJson({
  String? processingState = 'valid',
  String? processingStateRaw = 'VALID',
  String platform = 'IOS',
}) => <String, dynamic>{
  'schema': 1,
  'kind': 'appstore.builds',
  'platform': platform,
  'bundleId': 'design.codeux.example',
  'newestBuildNumber': '169',
  'newestBuildNumberAsInt': 169,
  'builds': [
    {
      'buildNumber': '169',
      'buildNumberAsInt': 169,
      'processingState': processingState,
      'processingStateRaw': processingStateRaw,
      'uploadedDate': '2026-09-09T14:02:11-07:00',
      'expired': false,
      'usable': true,
      'needsNewUpload': false,
      'display': ['  build 169  VALID  uploaded 2026-09-09T14:02:11-07:00'],
    },
  ],
  'display': ['  build 169  VALID  uploaded 2026-09-09T14:02:11-07:00'],
};

/// **`serving` and `audienceFraction` are derived here rather than written
/// down**, which is the whole point of both rules being reachable on
/// `PlayReleaseStatus`. A fixture that states one can state one the encoder
/// would never emit — `halted` and `serving: true`, or `completed` and
/// `audienceFraction: null` — and a test asserting against that is testing a
/// document that cannot exist.
///
/// `userFraction` is null throughout, which is what Play sends for the
/// `completed` default. The non-null case is a round trip of its own below,
/// because a `double` that survives `jsonEncode` and comes back an `int` is a
/// failure this shape can have and a null cannot.
Map<String, dynamic> _tracksJson({
  String? status = 'completed',
  String? statusRaw = 'completed',
}) => <String, dynamic>{
  'schema': 1,
  'kind': 'play.tracks',
  'packageName': 'design.codeux.example',
  'tracks': [
    {
      'name': 'internal',
      'newestVersionCode': 152,
      'releases': [
        {
          'name': '1.4.0',
          'status': status,
          'statusRaw': statusRaw,
          'versionCodes': [152],
          'newestVersionCode': 152,
          'serving': PlayReleaseStatus.serving(
            status == null
                ? null
                : PlayReleaseStatus.values.firstWhere((s) => s.wire == status),
          ),
          'userFraction': null,
          'audienceFraction': PlayReleaseStatus.audienceFraction(
            status == null
                ? null
                : PlayReleaseStatus.values.firstWhere((s) => s.wire == status),
            userFraction: null,
          ),
          'display': ['  internal: "1.4.0" codes=[152] $status'],
        },
      ],
      'display': ['  internal: "1.4.0" codes=[152] $status'],
    },
  ],
  'uploadedVersionCodes': [151, 152],
  'display': [
    '  internal: "1.4.0" codes=[152] $status',
    '  uploaded bundles: [151, 152]',
  ],
};

void main() {
  group('decoding is the inverse of encoding', () {
    test('a builds document round-trips unchanged', () {
      // Not "the fields came back" — the *document* came back. A decoder that
      // silently drops a key it does not know would pass a field-by-field
      // check written against the fields it does know.
      final json = _buildsJson();

      expect(AppStoreBuildsDocument.fromJson(json).toJson(), json);
    });

    test('and so does a tracks document, nesting and all', () {
      final json = _tracksJson();

      expect(PlayTracksDocument.fromJson(json).toJson(), json);
    });

    test('including a staged rollout, whose fractions survive a real encode', () {
      // **A `double` is the one type in this document that `jsonEncode` can
      // hand back as something else.** `1.0` is a legal JSON number and
      // `jsonDecode` may answer an `int` for it, so a fraction that round-trips
      // as a hand-written literal can still come back the wrong type from the
      // text a caller actually pipes in. The fixture above is null throughout
      // and cannot reach this.
      final json = _tracksJson(status: 'inProgress', statusRaw: 'inProgress');
      final release =
          ((json['tracks'] as List).single as Map)['releases'] as List;
      (release.single as Map)['userFraction'] = 0.2;
      (release.single as Map)['audienceFraction'] = 0.2;

      final document = PlayTracksDocument.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );

      expect(document.tracks.single.releases.single.userFraction, 0.2);
      expect(document.tracks.single.releases.single.audienceFraction, 0.2);
      expect(document.toJson(), json);
    });

    test('and a completed one, where ours is 1.0 and Play sent nothing', () {
      // The asymmetry that makes two fields two facts rather than one fact
      // twice: `1.0` here is this package's inference and `null` beside it is
      // what Play actually said. Encoding `1.0` and decoding it back as an
      // `int` would be silent — the field is `double?` and `1 == 1.0`.
      final document = PlayTracksDocument.fromJson(
        jsonDecode(jsonEncode(_tracksJson())) as Map<String, dynamic>,
      );
      final release = document.tracks.single.releases.single;

      expect(release.userFraction, isNull);
      expect(release.audienceFraction, 1.0);
      expect(release.audienceFraction, isA<double>());
    });

    test('through a real encode, which is where a type would surface', () {
      // `jsonDecode` hands back `List<dynamic>` and `num`, not `List<String>`
      // and `int` — so a class that only ever saw hand-written literals can
      // pass every test above and throw on the first document it is given.
      final text = jsonEncode(_buildsJson());

      final document = AppStoreBuildsDocument.fromJson(
        jsonDecode(text) as Map<String, dynamic>,
      );

      expect(document.builds.single.buildNumber, '169');
      expect(document.newestBuildNumberAsInt, 169);
      expect(document.display, isA<List<String>>());
    });
  });

  group('a store vocabulary degrades into ours, and the raw word survives', () {
    test(
      'an unnamed processingState is unknown, with Apple\'s word beside it',
      () {
        // **Both halves matter, and only together.** `unknown` alone says this
        // version did not understand; the raw alone makes every consumer learn
        // Apple's vocabulary. The pair is what lets a caller write against a
        // closed list and still see what actually arrived.
        final document = AppStoreBuildsDocument.fromJson(
          _buildsJson(
            processingState: 'unknown',
            processingStateRaw: 'SOMETHING_APPLE_ADDED',
          ),
        );

        final build = document.builds.single;
        expect(build.processingState, ProcessingState.unknown);
        expect(build.processingStateRaw, 'SOMETHING_APPLE_ADDED');
      },
    );

    test('and it survives a round trip, which the alternative did not', () {
      // The measured failure of typing the field with Apple's own spellings:
      // `unknown` mapped to nothing, so re-encoding wrote null and the word
      // was gone. Our vocabulary gives `unknown` a spelling of its own.
      final json = _buildsJson(
        processingState: 'unknown',
        processingStateRaw: 'SOMETHING_APPLE_ADDED',
      );

      final out = AppStoreBuildsDocument.fromJson(json).toJson();

      expect((out['builds'] as List).single, (json['builds'] as List).single);
    });

    test('and an unnamed Play status does the same', () {
      final document = PlayTracksDocument.fromJson(
        _tracksJson(status: 'unknown', statusRaw: 'somethingGoogleAdded'),
      );

      final release = document.tracks.single.releases.single;
      expect(release.status, PlayReleaseStatus.unknown);
      expect(release.statusRaw, 'somethingGoogleAdded');
    });

    test('but absent stays absent, which is a different fact', () {
      // Null means the store sent nothing. `unknown` means it sent something
      // this version does not name. A reader that cannot tell those apart
      // cannot tell "no answer" from "an answer we did not understand".
      final builds = AppStoreBuildsDocument.fromJson(
        _buildsJson(processingState: null, processingStateRaw: null),
      );
      final tracks = PlayTracksDocument.fromJson(
        _tracksJson(status: null, statusRaw: null),
      );

      expect(builds.builds.single.processingState, isNull);
      expect(builds.builds.single.processingStateRaw, isNull);
      expect(tracks.tracks.single.releases.single.status, isNull);
    });

    test('but a state Apple has always had is named, not degraded', () {
      // **`unknown` is for a value Apple *added*, and these are not that.**
      // `IN_REVIEW` was absent from this enum until the rollout-state work went
      // looking for it, so the single most ordinary mid-release state decoded
      // as `unknown` — whose own doc comment tells the reader Apple sent
      // something this version does not name. A version Apple is looking at
      // right now is not a version in a state nobody has seen.
      //
      // Each of these has an independent sighting in this repository; see
      // docs/design/rollout-state.md, which also records the one candidate
      // deliberately left out and why.
      const named = {
        'IN_REVIEW': AppStoreState.inReview,
        'PENDING_APPLE_RELEASE': AppStoreState.pendingAppleRelease,
        'PROCESSING_FOR_APP_STORE': AppStoreState.processingForAppStore,
        'REPLACED_WITH_NEW_VERSION': AppStoreState.replacedWithNewVersion,
      };

      for (final entry in named.entries) {
        expect(
          AppStoreState.read(entry.key),
          entry.value,
          reason: '${entry.key} degraded to unknown',
        );
      }

      // The polarity, so this cannot pass by naming everything: a value Apple
      // really has not shipped still degrades.
      expect(
        AppStoreState.read('SOME_STATE_APPLE_HAS_NOT_SHIPPED_YET'),
        AppStoreState.unknown,
      );
    });
  });

  group('every kind has a type a consumer can name', () {
    test('each document class is reachable from the public library', () {
      // **The defect this exists for was invisible from inside this
      // repository.** `appstore previews --json` shipped with its flag
      // working, its document emitted, and `DocumentKind.appStorePreviews`
      // exported — riding along inside the enum — while
      // `AppStorePreviewsDocument` and `AppStorePreviewEntry` were absent from
      // `lib/documents.dart`'s `show` list. So the feature was complete except
      // that nothing outside could name the type it decodes into.
      //
      // Nothing here could see it: the tests import `src/documents.dart`
      // directly, and CI's git-dependency probe asserts resolution and runs
      // `--help`. It took a consumer writing `Future<AppStorePreviewsDocument>`
      // in another package. That is absence and success looking alike, which is
      // the failure this repository keeps paying for in new shapes.
      //
      // Written as a type literal per kind rather than reflectively, because
      // Dart cannot enumerate a library's exports at runtime. The list below
      // is only as good as its completeness, which is what the length
      // assertion underneath is for.
      const documents = <Type>[
        AppStoreBuildsDocument,
        AppStoreVersionsDocument,
        AppStorePreviewsDocument,
        PlayTracksDocument,
        VerifyDocument,
      ];
      // The repeated element type each document carries. `verify`'s
      // [VerifyCheck] fills two fields rather than one — this asserts it is
      // nameable from outside, not how often it appears.
      const entries = <Type>[
        AppStoreBuildEntry,
        AppStoreVersionEntry,
        AppStorePreviewEntry,
        PlayTrackEntry,
        VerifyCheck,
      ];

      // **The assertion that keeps this honest, and it has already earned its
      // place.** `DocumentKind.verify` was added in the very next change, and
      // this failed with `Expected: an object with length of <5>` before the
      // types were exported — which is the whole of what it was written to do,
      // on its first real occasion rather than in a consumer's package a
      // release later.
      expect(
        documents,
        hasLength(DocumentKind.values.length),
        reason: 'a kind whose document is not exported cannot be decoded',
      );
      expect(entries, hasLength(DocumentKind.values.length));
      expect(documents.toSet(), hasLength(documents.length));
      expect(entries.toSet(), hasLength(entries.length));
    });
  });

  group('this package’s own vocabularies are closed', () {
    test('DocumentKind has no unknown member, unlike the store enums', () {
      // The asymmetry is the design. A `kind` nobody here names means a
      // document from a version that knows more than this one, and reading it
      // optimistically is what the schema field exists to prevent.
      expect(
        DocumentKind.values.map((k) => k.name),
        isNot(contains('unknown')),
      );
      expect(
        ProcessingState.values.map((s) => s.name),
        contains('unknown'),
        reason: 'the store-owned ones must degrade',
      );
    });

    test('so unknown has a wire spelling and no store spelling', () {
      // **The two columns, and what each is for.** `wire` is ours and every
      // member has one, including `unknown` — which is what lets it survive a
      // round trip. `appleValue` is Apple's, and `unknown` has none, because
      // it is the member that exists precisely when Apple said something this
      // version has no word for.
      expect(ProcessingState.unknown.wire, 'unknown');
      expect(ProcessingState.unknown.appleValue, isNull);
      expect(AppStoreState.unknown.appleValue, isNull);
      expect(ReleaseType.unknown.appleValue, isNull);
      expect(PlayReleaseStatus.unknown.playValue, isNull);

      // And every named member has both, so a null in either column is a
      // statement rather than an entry nobody filled in.
      for (final state in ProcessingState.values) {
        expect(state.wire, isNotEmpty);
        if (state != ProcessingState.unknown) {
          expect(state.appleValue, isNotNull);
        }
      }
    });

    test('and our spellings are ours, not a copy of the store’s', () {
      // The document says `valid`; Apple says `VALID`. Visibly different, so a
      // reader of one field is never in doubt which vocabulary they are in.
      expect(ProcessingState.valid.wire, 'valid');
      expect(ProcessingState.valid.appleValue, 'VALID');
      expect(AppStoreState.readyForSale.wire, 'readyForSale');
      expect(AppStoreState.readyForSale.appleValue, 'READY_FOR_SALE');
    });

    test('and a platform nobody names is refused rather than degraded', () {
      expect(
        () =>
            AppStoreBuildsDocument.fromJson(_buildsJson(platform: 'WATCH_OS')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a kind nobody names is refused too', () {
      final json = _buildsJson()..['kind'] = 'appstore.somethingelse';

      expect(() => AppStoreBuildsDocument.fromJson(json), throwsA(anything));
    });
  });

  group('the dartdoc describes the JSON', () {
    test('and no doc comment is orphaned from the thing it documents', () {
      // **Found in the published dev.2, by the consumer reading pub.dev.**
      // Twenty lines written for `AppStoreBuildsDocument.newest` sat between
      // `builds` and `display` with a blank line under them, attached to
      // nothing, while `newest` itself said only "see the note on [builds]" —
      // which was one line and did not contain it. The analyzer says nothing:
      // a dangling `///` block is valid Dart.
      //
      // It matters here more than it would elsewhere, because this file's
      // dartdoc *is* the published statement of the format. A paragraph
      // explaining why a member is a getter, rendered under no member at all,
      // is a specification with a hole in it.
      //
      // The shape: a `///` line, then a blank line, then another `///` line —
      // two blocks with nothing between them, so the first documents nothing.
      final lines = _documentsSource().readAsLinesSync();
      final orphans = <String>[];

      for (var i = 1; i < lines.length - 1; i++) {
        final blank = lines[i].trim().isEmpty;
        final before = lines[i - 1].trimLeft().startsWith('///');
        final after = lines[i + 1].trimLeft().startsWith('///');
        if (blank && before && after) {
          orphans.add('line ${i + 1}: ${lines[i - 1].trim()}');
        }
      }

      expect(
        orphans,
        isEmpty,
        reason:
            'a doc comment separated from the next one by a blank line '
            'documents nothing — put it on the member it describes',
      );
    });

    test('because no field is renamed on the way out', () {
      // **The published API docs are the format's only statement.** A
      // `@JsonKey(name:)` would leave every class reading correctly and every
      // key subtly different, with nothing on the page to say so — so the rule
      // is that the source contains no rename at all, and this is the check.
      // **Comments are stripped first, and the first run is why.** The header
      // of documents.dart states this rule — "no `@JsonKey(name:)` appears
      // here" — and a check over the raw text matched the sentence describing
      // what it forbids. A rule and its own statement are not the same thing,
      // and a check that cannot tell them apart is red for a reason nobody
      // can act on.
      final code = _documentsSource()
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');

      expect(
        code,
        isNot(contains('@JsonKey(name:')),
        reason:
            "a renamed key makes documents.dart's dartdoc a description of "
            'something other than the JSON, and a reader cannot tell',
      );
    });
  });

  group('a caller reaches the newest build, not just its number', () {
    // Both of these come from the port. The consumer wrote a loop matching on
    // `newestBuildNumber` rather than take `builds.first`, because re-deriving
    // "which one is newest" is the ordering this package has been wrong about
    // twice and they would not assume it.
    test('newest is the entry, so every other field of it is reachable', () {
      final document = AppStoreBuildsDocument.fromJson(_buildsJson());

      expect(document.newest, isNotNull);
      expect(document.newest!.buildNumber, document.newestBuildNumber);
      // The point of the accessor: the fields a caveat is built from.
      expect(document.newest!.needsNewUpload, isFalse);
      expect(document.newest!.expired, isFalse);
      expect(document.newest!.processingStateRaw, 'VALID');
    });

    test('and it agrees with newestBuildNumber by construction', () {
      // Not a coincidence to be re-checked at each call site: `builds` is
      // ordered newest-first and `newestBuildNumber` is that element's. The
      // accessor exists so a caller relies on this once, here, rather than on
      // array position wherever they happen to need it.
      final json = _buildsJson();
      (json['builds'] as List).add({
        'buildNumber': '9',
        'buildNumberAsInt': 9,
        'processingState': 'valid',
        'processingStateRaw': 'VALID',
        'uploadedDate': '2026-09-01T09:00:00-07:00',
        'expired': true,
        'usable': false,
        'needsNewUpload': true,
        'display': ['  build 9  VALID  uploaded 2026-09-01T09:00:00-07:00'],
      });

      final document = AppStoreBuildsDocument.fromJson(json);

      expect(document.builds, hasLength(2));
      expect(document.newest!.buildNumber, '169');
      expect(document.newest!.buildNumber, document.newestBuildNumber);
    });

    test('and it is null for an account with no builds', () {
      final json = _buildsJson()
        ..['builds'] = <dynamic>[]
        ..['newestBuildNumber'] = null
        ..['newestBuildNumberAsInt'] = null;

      expect(AppStoreBuildsDocument.fromJson(json).newest, isNull);
    });
  });

  group('both derived rules are reachable, not just one', () {
    // **The asymmetry the port paid for.** `needsNewUpload` was a public
    // static and `serving` was a private function in the encoder, so the
    // consumer's fixtures could call one rule and had to restate the other —
    // a second copy of a rule this package owns, in a tree it cannot see,
    // which is the drift the derived field exists to prevent.
    test('serving is on the vocabulary that defines it', () {
      expect(PlayReleaseStatus.serving(PlayReleaseStatus.completed), isTrue);
      expect(PlayReleaseStatus.serving(PlayReleaseStatus.inProgress), isTrue);
      expect(PlayReleaseStatus.serving(PlayReleaseStatus.halted), isFalse);
      expect(PlayReleaseStatus.serving(PlayReleaseStatus.draft), isFalse);
      expect(
        PlayReleaseStatus.serving(PlayReleaseStatus.statusUnspecified),
        isNull,
      );
      expect(PlayReleaseStatus.serving(PlayReleaseStatus.unknown), isNull);
      expect(PlayReleaseStatus.serving(null), isNull);
    });

    test('so a fixture cannot state a serving the encoder would not emit', () {
      // `_tracksJson` derives the field rather than writing it down, which is
      // only possible because the rule is reachable — and it is what stops a
      // hand-built document saying `halted` and `serving: true`, a state no
      // run can produce and a test can happily assert against.
      //
      // **This was written the wrong way round first**, asserting the fixture
      // against the static while the fixture hardcoded `serving: true`. It
      // failed, which was the fixture's flaw arriving on schedule.
      //
      // Whether the *encoder* agrees with this static is a cross-file claim
      // and lives in `json_output_test.dart`, which drives the encoder.
      for (final status in PlayReleaseStatus.values) {
        final serving = PlayTracksDocument.fromJson(
          _tracksJson(status: status.wire, statusRaw: status.playValue),
        ).tracks.single.releases.single.serving;

        expect(serving, PlayReleaseStatus.serving(status));
      }
    });
  });

  group('the raw status stays readable beside serving', () {
    // **`serving`'s derivation is not tested here, and could not be.** These
    // fixtures supply the field, so a test over them would assert that the
    // decoder read back what the fixture wrote — which is true of every field
    // and says nothing about the rule. The rule lives in the encoder, and
    // `json_output_test.dart` drives it with real statuses.
    PlayReleaseEntry releaseWith(String? status) => PlayTracksDocument.fromJson(
      _tracksJson(status: status, statusRaw: status),
    ).tracks.single.releases.single;

    test('so a halted rollout and an unsent draft stay distinguishable', () {
      // `serving` is false for both, and they are not the same thing. The
      // boolean answers the common question; the status is there for the one
      // it cannot.
      expect(releaseWith('halted').status, PlayReleaseStatus.halted);
      expect(releaseWith('draft').status, PlayReleaseStatus.draft);
      expect(
        releaseWith('statusUnspecified').status,
        PlayReleaseStatus.statusUnspecified,
      );
    });
  });
}
