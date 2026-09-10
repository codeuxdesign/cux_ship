// SPDX-License-Identifier: Apache-2.0
//
// `appstore previews` — the reader, where everything else previews had was a
// doer.
//
// **The poster frame is why it earns a command of its own.** It is the one
// input nobody can change after approval, no other output shows it, and Apple
// reports "never set" as an empty string rather than by omitting the field —
// so the two conditions a reader has to collapse are `null` and `''`, and a
// check for either alone prints a blank where the answer was "5 seconds in,
// because you did not say".
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

Map<String, dynamic> _preview({
  String id = 'preview-1',
  String fileName = 'promo.mp4',
  String videoState = 'COMPLETE',
  String frameState = 'COMPLETE',
  String? frameTimeCode,
}) => {
  'type': 'appPreviews',
  'id': id,
  'attributes': {
    'fileName': fileName,
    if (frameTimeCode != null) ...{'previewFrameTimeCode': frameTimeCode},
    'videoDeliveryState': {'state': videoState},
    'previewFrameImage': {
      'state': {'state': frameState},
    },
  },
};

/// Canned App Store Connect for a version carrying [previews].
///
/// It answers the three nested collections separately, because that is what
/// `previewsOn` walks: a version has localizations, a localization has preview
/// sets, a set has previews. A fake that flattened them would agree with a
/// reader that had the nesting wrong.
class _FakeClient implements AscClient {
  _FakeClient({
    this.versionName = '1.1.6',
    this.previews = const [],
    this.appStoreState = 'PREPARE_FOR_SUBMISSION',
  });

  final String? versionName;
  final List<Map<String, dynamic>> previews;

  /// **Settable, because hard-coding an editable state hid a defect.** Both
  /// fakes on this branch pinned `PREPARE_FOR_SUBMISSION`, which made the
  /// `editableVersionStates` check unreachable from the suite — so `previews`
  /// refusing to *read* a `READY_FOR_SALE` version passed every test.
  final String appStoreState;

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/v1/apps') {
      return [
        if (query?['filter[bundleId]'] == 'design.codeux.example')
          {
            'type': 'apps',
            'id': 'app-1',
            'attributes': {
              'bundleId': 'design.codeux.example',
              'name': 'Example',
            },
          },
      ];
    }
    if (path.endsWith('/appStoreVersions')) {
      final wanted = query?['filter[versionString]'];
      if (versionName == null || (wanted != null && wanted != versionName)) {
        return const [];
      }
      return [
        {
          'type': 'appStoreVersions',
          'id': 'version-1',
          'attributes': {
            'versionString': versionName,
            'appStoreState': appStoreState,
          },
        },
      ];
    }
    if (path.endsWith('/appStoreVersionLocalizations')) {
      return previews.isEmpty
          ? const []
          : [
              {
                'type': 'appStoreVersionLocalizations',
                'id': 'loc-1',
                'attributes': {'locale': 'en-US'},
              },
            ];
    }
    if (path.endsWith('/appPreviewSets')) {
      return [
        {
          'type': 'appPreviewSets',
          'id': 'set-1',
          'attributes': {'previewType': 'IPHONE_67'},
        },
      ];
    }
    if (path.endsWith('/appPreviews')) {
      return previews;
    }
    return const [];
  }

  @override
  AscCredentials get credentials =>
      AscCredentials(keyId: 'K', issuerId: 'I', privateKeyPem: 'unused');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

/// Runs the command and returns `(out, err)` **separately**.
///
/// Kept apart rather than merged into one buffer because the thing most worth
/// asserting about `--json` is precisely which stream a line went to, and a
/// merged buffer cannot tell a document from a document with a banner in front
/// of it — it reports both as "the output contains the JSON".
Future<({String out, String err})> _previews(
  _FakeClient client, {
  List<String> extra = const ['--version-name', '1.1.6'],
}) async {
  final args = buildAscParser(
    AscCommand.previews,
  ).parse(['--bundle-id', 'design.codeux.example', ...extra]);
  final out = _MemoryStdout();
  final err = _MemoryStdout();
  await IOOverrides.runZoned(
    () => runAsc(AscCommand.previews, args, ascClient: client),
    stdout: () => out,
    stderr: () => err,
  );
  await out.close();
  await err.close();
  return (out: out.buffer.toString(), err: err.buffer.toString());
}

void main() {
  setUp(() => exitCode = 0);
  tearDown(() => exitCode = 0);

  test('the report names locale, type, both states and the poster', () async {
    final client = _FakeClient(
      previews: [_preview(frameTimeCode: '00:00:02:06')],
    );

    final said = await _previews(client);

    expect(said.out, contains('en-US'));
    expect(said.out, contains('IPHONE_67'));
    expect(said.out, contains('promo.mp4'));
    expect(said.out, contains('video COMPLETE'));
    expect(said.out, contains('frame COMPLETE'));
    expect(said.out, contains('poster 00:00:02:06'));
  });

  test(
    'a poster frame Apple reports as an empty string reads as not set',
    () async {
      // **Apple's own shape, and the one a `!= null` check gets wrong.** A
      // preview uploaded without a time code comes back with
      // `previewFrameTimeCode: ""`, which survives both `??` and `== null` and
      // prints as a blank column — telling a reader nothing where the true
      // answer is "Apple picked one for you". The blank is worse than silence
      // because it reads as a rendering fault rather than a decision.
      final said = await _previews(
        _FakeClient(previews: [_preview(frameTimeCode: '')]),
      );

      expect(said.out, contains('poster (not set)'));
    },
  );

  test('a missing time code reads the same as an empty one', () async {
    final said = await _previews(_FakeClient(previews: [_preview()]));

    expect(said.out, contains('poster (not set)'));
  });

  // **The `--version-name` refusal has no test, and cannot have one here.**
  // `fail` in `cli.dart` calls `exit(1)` deliberately — so that it reaches no
  // catch clause and can report state left behind — which means an in-process
  // test of it takes the whole test run down with it rather than failing one
  // case. Nor can a subprocess reach it: the check sits after the app has been
  // resolved, so a run without credentials refuses earlier and for a different
  // reason. This is the same gap every other `fail` in this file has, and it
  // is recorded here rather than papered over with a test of something else.

  test(
    'a version that does not exist is distinct from one with none',
    () async {
      // Two different answers a reader must not see collapsed: "1.1.6 is not a
      // version" and "1.1.6 has no previews". The first means the version name
      // is wrong or the version was never created; the second means the upload
      // has not run. A single "nothing to show" would send someone hunting in
      // the wrong half.
      //
      // **The first arrives as a 404, not as a line this command writes.**
      // That is what the code does, and the first draft of this test asserted
      // otherwise — against a `version == null` branch that could never run,
      // because `ensureVersion(create: false)` throws rather than returning
      // null. The branch is gone; this asserts the refusal that actually
      // reaches a person, on the stream it reaches them on.
      final said = await _previews(_FakeClient(versionName: null));

      // **Exit 5, and not 1, which is the point of the code.** Exit 1 is
      // also wrong credentials, an unreachable network and a metadata tree
      // that will not load — so a consumer could not tell the commonest state
      // on the way to a release from the broken ones without matching prose.
      expect(exitCode, noSuchVersionExit);
      expect(exitCode, isNot(1));
      expect(exitCode, isNot(0));
      expect(said.err, contains('404'));
      expect(said.err, contains('no App Store version 1.1.6'));
      expect(said.out, isNot(contains('carries no previews')));
    },
  );

  test('a version with no previews says so', () async {
    final said = await _previews(_FakeClient());

    expect(said.out, contains('carries no previews'));
  });

  test("--json carries Apple's field names, so the docs read across", () async {
    // The consumer asked for these names explicitly and they are right:
    // `videoDeliveryState`, `previewFrameImageState` and
    // `previewFrameTimeCode` are what the App Store Connect reference calls
    // them, so a reader can hold the two side by side without a translation
    // table. Where this package has an opinion — `done` — it says so in a
    // field of its own rather than by renaming Apple's.
    final client = _FakeClient(
      previews: [_preview(frameTimeCode: '00:00:02:06')],
    );

    final said = await _previews(
      client,
      extra: ['--version-name', '1.1.6', '--json'],
    );

    final document = jsonDecode(said.out) as Map<String, dynamic>;
    expect(document['kind'], 'appstore.previews');
    expect(document['schema'], 1);
    expect(document['versionName'], '1.1.6');
    expect(document['bundleId'], 'design.codeux.example');

    final entry = (document['previews'] as List).single as Map<String, dynamic>;
    expect(entry['locale'], 'en-US');
    expect(entry['previewType'], 'IPHONE_67');
    expect(entry['fileName'], 'promo.mp4');
    expect(entry['videoDeliveryState'], 'COMPLETE');
    expect(entry['previewFrameImageState'], 'COMPLETE');
    expect(entry['previewFrameTimeCode'], '00:00:02:06');
    expect(entry['done'], isTrue);
  });

  test('--json puts the document on stdout and the banner on stderr', () async {
    // **The invariant every other `--json` command in `cli.dart` holds.**
    // Resolving the app prints `==> Example (…) is app app-1`, which is useful
    // to a person and fatal to a parser: a program pipes stdout to
    // `jsonDecode`, so one stray human line makes the whole document
    // unreadable, and the failure arrives as a parse error about character 1
    // that names neither the line nor the command that emitted it.
    //
    // Asserted on the *streams*, not on a merged buffer. The first draft of
    // this file merged them, and it failed against correct code — the banner
    // was on stderr all along and a merged buffer cannot tell that from a
    // banner printed in front of the document. A harness that cannot
    // distinguish the bug from the fix is not a test of either.
    final client = _FakeClient(
      previews: [_preview(frameTimeCode: '00:00:02:06')],
    );

    final said = await _previews(
      client,
      extra: ['--version-name', '1.1.6', '--json'],
    );

    expect(() => jsonDecode(said.out), returnsNormally);
    expect(said.out, isNot(contains('==>')));
    // Not dropped, though — moved. A person running this by hand still wants
    // to know which app answered.
    expect(said.err, contains('is app app-1'));
  });

  test('a version Apple has already taken can still be read', () async {
    // **A read must not inherit a write's precondition.** `ensureVersion`
    // refuses anything outside `editableVersionStates` so that a PATCH is not
    // rejected field by field — correct for a write, and nonsense here: it
    // answered `appstore previews` on a live version with *"1.1.6 is
    // READY_FOR_SALE, which cannot be edited. Release a new version
    // instead."*, a refusal to look.
    //
    // And it landed on exactly the versions worth looking at. A version stops
    // being editable the moment it is submitted, which is when somebody most
    // wants to know which poster frame went with it — the attribute that is
    // fixed from then on.
    for (final state in const [
      'READY_FOR_SALE',
      'WAITING_FOR_REVIEW',
      'IN_REVIEW',
    ]) {
      final said = await _previews(
        _FakeClient(
          appStoreState: state,
          previews: [_preview(frameTimeCode: '00:00:02:06')],
        ),
      );

      expect(exitCode, 0, reason: state);
      expect(said.out, contains('poster 00:00:02:06'), reason: state);
      expect(said.err, isNot(contains('cannot be edited')), reason: state);
    }
  });

  test('an empty time code reaches --json as null, not as ""', () async {
    // **The document promises `HH:MM:SS:FF` or null**, and Apple sends `""`
    // for a poster it has not cut. Passing that through published
    // `"previewFrameTimeCode": ""` against that dartdoc — so a consumer
    // checking `!= null` took the "set" branch and printed an empty value,
    // which is the identical blank-column failure the prose line was fixed
    // for, arriving by a second route.
    //
    // `done` does not cover it: `done` is over the two *states*, and both are
    // COMPLETE for a preview sitting at Apple's default frame.
    final said = await _previews(
      _FakeClient(previews: [_preview(frameTimeCode: '')]),
      extra: ['--version-name', '1.1.6', '--json'],
    );

    final entry =
        ((jsonDecode(said.out) as Map<String, dynamic>)['previews'] as List)
                .single
            as Map<String, dynamic>;
    expect(entry['previewFrameTimeCode'], isNull);
    expect(entry['previewFrameTimeCode'], isNot(''));
    expect(entry['done'], isTrue);
  });

  test('a preview still ingesting is not done', () async {
    // `done` is this package's opinion over two of Apple's states, so it has
    // to be false while *either* is unfinished — a video that has landed with
    // no poster frame cut yet is not a preview anyone can submit.
    final client = _FakeClient(
      previews: [_preview(videoState: 'COMPLETE', frameState: 'PROCESSING')],
    );

    final said = await _previews(
      client,
      extra: ['--version-name', '1.1.6', '--json'],
    );

    final entry =
        ((jsonDecode(said.out) as Map<String, dynamic>)['previews'] as List)
                .single
            as Map<String, dynamic>;
    expect(entry['done'], isFalse);
    expect(entry['videoDeliveryState'], 'COMPLETE');
    expect(entry['previewFrameImageState'], 'PROCESSING');
  });
}
