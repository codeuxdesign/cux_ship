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

Map<String, dynamic> _buildsJson({
  String? processingState = 'VALID',
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
      'uploadedDate': '2026-09-09T14:02:11-07:00',
      'expired': false,
      'usable': true,
      'mayBecomeUsable': false,
      'display': ['  build 169  VALID  uploaded 2026-09-09T14:02:11-07:00'],
    },
  ],
  'display': ['  build 169  VALID  uploaded 2026-09-09T14:02:11-07:00'],
};

Map<String, dynamic> _tracksJson({String? status = 'completed'}) =>
    <String, dynamic>{
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
              'versionCodes': [152],
              'newestVersionCode': 152,
              'serving': true,
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

  group('a store vocabulary degrades', () {
    test(
      'an unnamed processingState is unknown, and the raw value survives',
      () {
        // The whole reason these are not Dart enums on the wire. Apple ships a
        // state, and a consumer pinned to this version keeps parsing.
        final document = AppStoreBuildsDocument.fromJson(
          _buildsJson(processingState: 'SOMETHING_APPLE_ADDED'),
        );

        final build = document.builds.single;
        expect(build.processingStateKnown, ProcessingState.unknown);
        expect(build.processingState, 'SOMETHING_APPLE_ADDED');
      },
    );

    test('and an unnamed Play status does the same', () {
      final document = PlayTracksDocument.fromJson(
        _tracksJson(status: 'somethingGoogleAdded'),
      );

      final release = document.tracks.single.releases.single;
      expect(release.statusKnown, PlayReleaseStatus.unknown);
      expect(release.status, 'somethingGoogleAdded');
    });

    test('but absent stays absent, which is a different fact', () {
      // Null means the store sent nothing. `unknown` means it sent something
      // this version does not name. A reader that cannot tell those apart
      // cannot tell "no answer" from "an answer we did not understand".
      final builds = AppStoreBuildsDocument.fromJson(
        _buildsJson(processingState: null),
      );
      final tracks = PlayTracksDocument.fromJson(_tracksJson(status: null));

      expect(builds.builds.single.processingState, isNull);
      expect(builds.builds.single.processingStateKnown, isNull);
      expect(tracks.tracks.single.releases.single.statusKnown, isNull);
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

    test("and unknown's wire is null, because there is no such spelling", () {
      // **The one case where a caller most needs the raw value is the one an
      // enum cannot carry.** An earlier draft spelled this `''`, which reads
      // like a store that sent an empty string — plausible, wrong, and wrong
      // exactly where the truth matters. Null sends the reader to the sibling
      // field, which has it.
      expect(ProcessingState.unknown.wire, isNull);
      expect(AppStoreState.unknown.wire, isNull);
      expect(ReleaseType.unknown.wire, isNull);
      expect(PlayReleaseStatus.unknown.wire, isNull);
      // And every named member does have one, so the null is a statement
      // rather than an oversight nobody filled in.
      for (final state in ProcessingState.values) {
        if (state != ProcessingState.unknown) {
          expect(state.wire, isNotNull);
        }
      }
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

  group('the raw status stays readable beside serving', () {
    // **`serving`'s derivation is not tested here, and could not be.** These
    // fixtures supply the field, so a test over them would assert that the
    // decoder read back what the fixture wrote — which is true of every field
    // and says nothing about the rule. The rule lives in the encoder, and
    // `json_output_test.dart` drives it with real statuses.
    PlayReleaseEntry releaseWith(String? status) => PlayTracksDocument.fromJson(
      _tracksJson(status: status),
    ).tracks.single.releases.single;

    test('so a halted rollout and an unsent draft stay distinguishable', () {
      // `serving` is false for both, and they are not the same thing. The
      // boolean answers the common question; the status is there for the one
      // it cannot.
      expect(releaseWith('halted').statusKnown, PlayReleaseStatus.halted);
      expect(releaseWith('draft').statusKnown, PlayReleaseStatus.draft);
      expect(
        releaseWith('statusUnspecified').statusKnown,
        PlayReleaseStatus.statusUnspecified,
      );
    });
  });
}
