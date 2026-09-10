// SPDX-License-Identifier: Apache-2.0
//
// `appstore wait-previews` — the sibling `appstore wait` has had since builds
// needed one, and previews did not, despite having the longest documented tail
// of any asset this tool uploads.
//
// **The exit code is the point, not a detail.** The one project running
// previews branches on exit status and never on text, deliberately, after a
// status of theirs escaped from four regular expressions matched against
// stdout. So "still ingesting" has to be distinguishable from "done" and from
// "broken" without reading a word — three states, three codes.
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

Map<String, dynamic> _preview({
  String id = 'preview-1',
  String fileName = 'promo.mp4',
  String? videoState,
  String? frameState,
  String? frameTimeCode,
}) => {
  'type': 'appPreviews',
  'id': id,
  'attributes': {
    'fileName': fileName,
    if (frameTimeCode != null) ...{'previewFrameTimeCode': frameTimeCode},
    if (videoState != null) ...{
      'videoDeliveryState': {'state': videoState},
    },
    if (frameState != null) ...{
      'previewFrameImage': {
        'state': {'state': frameState},
      },
    },
  },
};

/// Canned App Store Connect for a version carrying one preview.
///
/// **It answers the three nested collections separately**, because that is
/// what `previewsOn` walks and what the command's report is built from: a
/// version has localizations, a localization has preview sets, a set has
/// previews. A fake that flattened them would agree with a reader that had the
/// nesting wrong.
class _FakeClient implements AscClient {
  _FakeClient({this.versions = const [], this.previews = const []});

  final List<Map<String, dynamic>> versions;

  /// What Apple reports on each poll of a single preview, in order; the last
  /// entry repeats.
  final List<Map<String, dynamic>> previews;
  var _poll = 0;

  final requests = <String>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add('GET $path');
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
      if (wanted == null) {
        return versions;
      }
      return versions
          .where(
            (v) =>
                (v['attributes'] as Map<String, dynamic>)['versionString'] ==
                wanted,
          )
          .toList();
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
      // **The collection reflects where the polling has got to**, because
      // Apple's does: the document `--json` prints is built from a re-read
      // *after* the wait, and a fake that always answered with the first
      // scripted state would report a preview as PROCESSING in the document
      // of a run that had just watched it finish.
      return [previews[_poll == 0 ? 0 : previews.length - 1]];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    requests.add('GET $path');
    final data =
        previews[_poll < previews.length ? _poll : previews.length - 1];
    _poll++;
    return {'data': data};
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

Map<String, dynamic> _version(String name) => {
  'type': 'appStoreVersions',
  'id': 'version-1',
  'attributes': {
    'versionString': name,
    'appStoreState': 'PREPARE_FOR_SUBMISSION',
  },
};

/// Runs the command and returns `(out, err)` **separately**.
///
/// **This helper used to point both streams at one buffer**, and that is why
/// the `--json` defect below went unseen: the no-previews case asserted only
/// that a line appeared *somewhere*, so it passed whether the line went to
/// stdout — where it made the document unparseable — or to stderr, where it
/// belongs. A harness that cannot tell those apart is not a test of either,
/// which `previews_command_test.dart` learned first and this file inherited
/// late.
Future<({String out, String err})> _wait(
  _FakeClient client, {
  List<String> extra = const [],
}) async {
  final args = buildAscParser(AscCommand.awaitPreviews).parse([
    '--bundle-id',
    'design.codeux.example',
    '--version-name',
    '1.1.6',
    '--poll',
    '0s',
    ...extra,
  ]);
  final out = _MemoryStdout();
  final err = _MemoryStdout();
  await IOOverrides.runZoned(
    () => runAsc(AscCommand.awaitPreviews, args, ascClient: client),
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

  test('a finished preview exits zero', () async {
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [_preview(videoState: 'COMPLETE', frameState: 'COMPLETE')],
    );

    final said = await _wait(client);

    expect(exitCode, 0);
    expect(said.out, contains('previews are ready'));
    expect(said.out, contains('en-US IPHONE_67: promo.mp4'));
  });

  test(
    'one still ingesting exits the pending code, not zero and not one',
    () async {
      // **The whole reason this command exists.** Exit zero would make "still
      // going" indistinguishable from "done" to a caller that branches on
      // status; exit 1 would call an outcome the design document describes as
      // ordinary a failure. Three states, three codes.
      final client = _FakeClient(
        versions: [_version('1.1.6')],
        previews: [_preview(videoState: 'PROCESSING')],
      );

      final said = await _wait(client, extra: ['--timeout', '0s']);

      expect(exitCode, previewsPendingExit);
      expect(exitCode, isNot(0));
      expect(exitCode, isNot(1));
      expect(said.err, contains('not a failure'));
      // The per-asset detail, because "1 preview(s) pending" cannot tell a video
      // still uploading from a poster frame not yet cut.
      expect(said.err, contains('promo.mp4'));
      expect(said.err, contains('video PROCESSING'));
      expect(said.err, contains('Re-run'));
    },
  );

  test('a rejected preview is a failure, not a pending state', () async {
    // The third state. `FAILED` is Apple refusing the asset, which is not
    // "not yet" — conflating the two is how a broken upload waits for ever.
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [_preview(videoState: 'FAILED')],
    );

    final said = await _wait(client);

    expect(exitCode, 1);
    expect(exitCode, isNot(previewsPendingExit));
    expect(said.err, contains('rejected the preview'));
  });

  test('a version with no previews says so rather than waiting', () async {
    final client = _FakeClient(versions: [_version('1.1.6')]);

    final said = await _wait(client);

    expect(exitCode, 0);
    expect(said.out, contains('carries no previews'));
  });

  test('--json puts the document on stdout and progress on stderr', () async {
    // **A wait is progress and *then* an answer**, so one document at the end
    // cannot be rendered as progress. Splitting by stream rather than by flag
    // gives a person the live report and a program a clean document without
    // either having to choose — and it keeps the invariant every other
    // `--json` command in this file states: stdout carries the document and
    // nothing else.
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [
        _preview(videoState: 'PROCESSING'),
        _preview(
          videoState: 'COMPLETE',
          frameState: 'COMPLETE',
          frameTimeCode: '00:00:02:06',
        ),
      ],
    );

    final out = _MemoryStdout();
    final err = _MemoryStdout();
    final args = buildAscParser(AscCommand.awaitPreviews).parse([
      '--bundle-id',
      'design.codeux.example',
      '--version-name',
      '1.1.6',
      '--poll',
      '0s',
      '--json',
    ]);
    await IOOverrides.runZoned(
      () => runAsc(AscCommand.awaitPreviews, args, ascClient: client),
      stdout: () => out,
      stderr: () => err,
    );
    await out.close();
    await err.close();

    // stdout is exactly one document and nothing else.
    final document = jsonDecode(out.buffer.toString()) as Map<String, dynamic>;
    expect(document['kind'], 'appstore.previews');
    expect(document['schema'], 1);
    expect(document['versionName'], '1.1.6');

    // Apple's own field names, so a reader can hold this beside Apple's docs.
    final entry = (document['previews'] as List).single as Map<String, dynamic>;
    expect(entry['videoDeliveryState'], 'COMPLETE');
    expect(entry['previewFrameImageState'], 'COMPLETE');
    expect(entry['previewFrameTimeCode'], '00:00:02:06');
    expect(entry['locale'], 'en-US');
    expect(entry['previewType'], 'IPHONE_67');
    expect(entry['done'], isTrue);

    // And the progress went somewhere a person can read without spoiling it.
    expect(err.buffer.toString(), contains('video PROCESSING'));
  });

  test('--json emits a document even when there are no previews', () async {
    // **A success must still be decodable.** This case returned early, before
    // the `--json` branch, printing prose on stdout — so a run that exited 0
    // handed its consumer a parse error at character 1. And it is the input a
    // readiness check meets *first*, on a version whose previews have not been
    // uploaded yet, which makes it the worst one to answer with a shape no
    // decoder can take.
    final client = _FakeClient(versions: [_version('1.1.6')]);

    final said = await _wait(client, extra: ['--json']);

    expect(exitCode, 0);
    final document = jsonDecode(said.out) as Map<String, dynamic>;
    expect(document['kind'], 'appstore.previews');
    expect(document['versionName'], '1.1.6');
    expect(document['previews'], isEmpty);
    // **The invariant is that stdout *parses*, not that a phrase is absent
    // from it.** The first draft asserted stdout did not contain "carries no
    // previews" and failed against correct output, because `display` carries
    // that sentence and `display` is inside the document. `jsonDecode`
    // succeeding above is the assertion; a phrase check would forbid the
    // document from describing itself.
    //
    // The sentence a person needs is not dropped — it goes to stderr as
    // progress, and survives in `display` so a renderer has something to show.
    expect(said.err, contains('carries no previews'));
    expect(
      (document['display'] as List).single,
      contains('carries no previews'),
    );
  });

  test('--json display reports the states rather than the word ready', () async {
    // `display` hard-coded `ready` on every line while the document computed
    // `done` from the same re-read. On the grace-period exit — Apple never
    // reports `previewFrameImage`, and the wait returns anyway — that produced
    // one document saying `done: false` and `ready` about the same preview.
    // `display` is the half a person reads, which makes it the worse half to
    // be wrong about.
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [
        _preview(videoState: 'PROCESSING'),
        _preview(videoState: 'COMPLETE', frameState: 'COMPLETE'),
      ],
    );

    final said = await _wait(client, extra: ['--json']);

    final document = jsonDecode(said.out) as Map<String, dynamic>;
    final line = (document['display'] as List).single as String;
    expect(line, contains('video COMPLETE'));
    expect(line, contains('frame COMPLETE'));
    expect(line, isNot(contains('ready')));
  });

  test('the report names the locale and type, not just an id', () async {
    // Apple identifies a preview by an opaque id; a person waiting on one
    // wants "the en-US IPHONE_67 one", and those live two collections up.
    final client = _FakeClient(
      versions: [_version('1.1.6')],
      previews: [_preview(videoState: 'COMPLETE', frameState: 'COMPLETE')],
    );

    final said = await _wait(client);

    expect(said.out, contains('en-US'));
    expect(said.out, contains('IPHONE_67'));
  });
}
